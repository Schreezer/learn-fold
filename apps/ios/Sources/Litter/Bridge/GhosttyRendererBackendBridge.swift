import Foundation

/// Thin Swift implementation of the Rust-defined `TerminalRendererBackend`
/// callback interface. Holds a weak reference to the platform-side
/// `LitterGhosttyTerminal` and hops every Ghostty C call onto the main
/// thread (Ghostty's surface APIs are not thread-safe). The Rust tick task
/// invokes these methods on the shared tokio runtime.
///
/// Selection state lives here because Ghostty's C surface doesn't expose a
/// public setter for the painted selection range — the platform paints the
/// overlay itself and uses the stored range to satisfy `readSelection` via
/// `ghostty_surface_read_text`. The UI overlay view subscribes to
/// `onSelectionRangeChanged` to redraw handles when Rust pushes a new range.
final class GhosttyRendererBackendBridge: TerminalRendererBackend, @unchecked Sendable {
    /// The Obj-C terminal owns non-Sendable Ghostty C handles. Keep its weak
    /// reference isolated to the main actor so background Rust callbacks only
    /// ever transfer the actor-safe handle, never the terminal itself.
    private let terminalHandle: GhosttyTerminalHandle

    /// Most recently pushed selection range (viewport-relative). `nil` when
    /// no selection is active. Written from the Rust runtime via
    /// `setSelectionOverlay` and read from the main thread by the overlay
    /// view + edit menu. Guarded by `selectionLock` to keep the write/read
    /// race safe — the storage is a single optional, no fancy state.
    private let selectionLock = NSLock()
    private var selectionRange: TerminalCellRange?

    /// Callback fired on the main thread whenever the stored selection
    /// range changes. The terminal view installs this to drive handle
    /// repaints + edit-menu visibility.
    private let selectionCallbackStorage = SelectionCallbackStorage()
    /// All one-way renderer callbacks share this mailbox. A callback stream
    /// such as focus → key → text must reach Ghostty in that same order; an
    /// independent `Task { @MainActor in ... }` for each callback does not
    /// provide that guarantee.
    private let terminalDelivery: MainActorTerminalDelivery
    @MainActor var onSelectionRangeChanged: ((TerminalCellRange?) -> Void)? {
        didSet {
            selectionCallbackStorage.replace(onSelectionRangeChanged)
        }
    }

    @MainActor init(terminal: LitterGhosttyTerminal) {
        terminalHandle = GhosttyTerminalHandle(terminal: terminal)
        terminalDelivery = MainActorTerminalDelivery(terminalHandle: terminalHandle)
    }

    func setFocus(focused: Bool) {
        terminalDelivery.enqueue { terminal in
            terminal.terminal?.setFocused(focused)
        }
    }

    func setOcclusion(occluded: Bool) {
        terminalDelivery.enqueue { terminal in
            terminal.terminal?.setOcclusion(occluded)
        }
    }

    func requestRedraw() {
        // UIKit Ghostty surfaces render through Ghostty's own renderer thread.
        // Ghostty's wakeup callback drains the app mailbox; this Rust-side
        // renderer callback only exists for Android's app-thread EGL path.
    }

    func applyConfigFile(path: String) {
        terminalDelivery.enqueueOrDeliverImmediatelyIfIdle { terminal in
            try? terminal.terminal?.applyConfig(atPath: path)
        }
    }

    func dispatchKey(event: TerminalKeyEvent) {
        let action = Int32(GhosttyKeyTranslator.action(for: event.action))
        let litterKey = GhosttyKeyTranslator.litterKey(for: event.code)
        let mods = Int32(GhosttyKeyTranslator.mods(for: event.mods))
        let text = event.text.isEmpty ? nil : event.text
        terminalDelivery.enqueue { terminal in
            _ = terminal.terminal?.dispatchKeyAction(
                action,
                key: litterKey,
                mods: mods,
                text: text,
                composing: false
            )
        }
    }

    func dispatchText(text: String, composing: Bool) {
        terminalDelivery.enqueue { terminal in
            if composing {
                terminal.terminal?.setPreeditText(text.isEmpty ? nil : text)
            } else {
                terminal.terminal?.sendText(text)
            }
        }
    }

    func dispatchPaste(bytes: Data) {
        // Bracketed-paste bytes must travel PTY-input direction
        // (terminal → shell), not PTY-output direction. The terminal's
        // `inputHandler` is the same closure Ghostty's
        // `external_pty_write` ultimately fires when the user types, so
        // we reuse it: the platform-side controller forwards the bytes
        // to the running process unchanged. Writing them through
        // `writeOutput` would paint the wrapper on screen instead.
        terminalDelivery.enqueue { terminal in
            terminal.terminal?.inputHandler?(bytes)
        }
    }

    func readSelection() -> String? {
        let range = currentSelectionRange()
        guard let range else { return nil }
        // `read_text` must run on the same thread as other Ghostty surface
        // calls. We're invoked from the Rust tick task, so hop to main and
        // block long enough to return — bounded waits keep this safe under
        // a misbehaving renderer (no deadlock with the renderer's tokio
        // runtime because no main-thread caller is waiting on us).
        let terminalHandle = terminalHandle
        return runOnMainBlocking { @MainActor [terminalHandle] in
            terminalHandle.terminal?.readText(
                fromRow: range.start.row,
                column: range.start.col,
                toRow: range.end.row,
                column: range.end.col
            )
        }
    }

    func readText(startRow: UInt32, startCol: UInt32, endRow: UInt32, endCol: UInt32) -> String? {
        let terminalHandle = terminalHandle
        return runOnMainBlocking { @MainActor [terminalHandle] in
            terminalHandle.terminal?.readText(
                fromRow: startRow,
                column: startCol,
                toRow: endRow,
                column: endCol
            )
        }
    }

    func cellMetrics() -> TerminalCellMetrics {
        let terminalHandle = terminalHandle
        let metrics = runOnMainBlocking { @MainActor [terminalHandle] in
            terminalHandle.terminal?.surfaceMetrics()
        } ?? LitterGhosttySurfaceMetrics()
        return TerminalCellMetrics(
            cellWidthPx: Float(metrics.cellWidthPx),
            cellHeightPx: Float(metrics.cellHeightPx),
            cols: UInt32(metrics.columns),
            rows: UInt32(metrics.rows),
            // Viewport-relative selection: top-left of the visible area is
            // always row 0 in our coordinate system. Scrollback rows live
            // outside the viewport and aren't selectable through long-press
            // yet — the OSC parser's absolute-row tracking is separate.
            viewportTop: 0
        )
    }

    func setSelectionOverlay(range: TerminalCellRange?) {
        selectionLock.lock()
        selectionRange = range
        selectionLock.unlock()
        let callback = selectionCallbackStorage.snapshot()
        terminalDelivery.enqueue { _ in
            callback?.invoke(range)
        }
    }

    /// Snapshot the current selection range. Used by `readSelection` and
    /// by the overlay view via `currentRange` to repaint.
    func currentSelectionRange() -> TerminalCellRange? {
        selectionLock.lock()
        defer { selectionLock.unlock() }
        return selectionRange
    }

    /// Run `work` on the main thread synchronously, returning its result.
    /// If we're already on main, runs inline; otherwise dispatches and
    /// waits. `DispatchQueue.main.sync` from a background thread is fine
    /// here because the Rust tick task never holds a lock the main thread
    /// could be waiting on.
    private func runOnMainBlocking<T: Sendable>(_ work: @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }
}

/// Actor-isolated indirection for the non-Sendable Obj-C terminal. The bridge
/// may be retained and invoked by Rust's concurrent executor, while all
/// accesses to Ghostty's underlying C handles stay on the main actor.
@MainActor
private final class GhosttyTerminalHandle {
    weak var terminal: LitterGhosttyTerminal?

    init(terminal: LitterGhosttyTerminal) {
        self.terminal = terminal
    }
}

/// A lock-backed FIFO mailbox whose drain is confined to the main actor.
///
/// Rust can invoke the backend from concurrent executor tasks, so the lock
/// establishes one delivery order at the bridge boundary. Exactly one main
/// queue drain consumes that order; commands appended while a drain is
/// running are consumed by the same drain before it releases ownership.
/// The queued operations only receive the main-actor terminal handle, so
/// Ghostty's non-Sendable C/UI objects never leave the main actor.
private final class MainActorTerminalDelivery: @unchecked Sendable {
    fileprivate typealias Operation = @MainActor @Sendable (GhosttyTerminalHandle) -> Void

    private let lock = NSLock()
    private let terminalHandle: GhosttyTerminalHandle
    private var operations: [Operation] = []
    private var drainScheduled = false

    @MainActor
    init(terminalHandle: GhosttyTerminalHandle) {
        self.terminalHandle = terminalHandle
    }

    fileprivate func enqueue(_ operation: @escaping Operation) {
        lock.lock()
        operations.append(operation)
        let shouldScheduleDrain = !drainScheduled
        if shouldScheduleDrain {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldScheduleDrain else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.drain()
            }
        }
    }

    /// Preserve the renderer's synchronous configuration contract when the
    /// caller is already on main. This keeps the resize/flush work which
    /// follows `applyConfigFile` from overtaking its config update. If prior
    /// work is queued, configuration joins that FIFO and main drains through
    /// it before returning; a previously scheduled async drain then finds an
    /// empty mailbox and safely does nothing.
    fileprivate func enqueueOrDeliverImmediatelyIfIdle(_ operation: @escaping Operation) {
        guard Thread.isMainThread else {
            enqueue(operation)
            return
        }

        let shouldDrainBeforeReturning: Bool
        lock.lock()
        if drainScheduled {
            operations.append(operation)
            shouldDrainBeforeReturning = true
        } else {
            shouldDrainBeforeReturning = false
        }
        lock.unlock()

        MainActor.assumeIsolated {
            if shouldDrainBeforeReturning {
                drain()
            } else {
                operation(terminalHandle)
            }
        }
    }

    @MainActor
    private func drain() {
        while true {
            let operation: Operation?
            lock.lock()
            if operations.isEmpty {
                drainScheduled = false
                operation = nil
            } else {
                operation = operations.removeFirst()
            }
            lock.unlock()

            guard let operation else { return }
            operation(terminalHandle)
        }
    }
}

/// Synchronizes replacement of the UI callback with background renderer
/// updates. The wrapper is immutable after creation and its callback is only
/// invoked from a `@MainActor` task, so crossing the wrapper itself is safe.
private final class SelectionCallbackStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: MainActorSelectionCallback?

    func replace(_ callback: (@MainActor (TerminalCellRange?) -> Void)?) {
        lock.lock()
        self.callback = callback.map(MainActorSelectionCallback.init)
        lock.unlock()
    }

    func snapshot() -> MainActorSelectionCallback? {
        lock.lock()
        defer { lock.unlock() }
        return callback
    }
}

/// Immutable main-actor callback token. It retains the callback scheduled by
/// a particular selection update even if the terminal view replaces or clears
/// its handler before that main-queue turn runs.
private final class MainActorSelectionCallback: @unchecked Sendable {
    private let callback: @MainActor (TerminalCellRange?) -> Void

    init(_ callback: @escaping @MainActor (TerminalCellRange?) -> Void) {
        self.callback = callback
    }

    @MainActor
    func invoke(_ range: TerminalCellRange?) {
        callback(range)
    }
}

/// Translation: Rust `TerminalKey*` → bridge-level `LitterGhosttyKey`.
/// Bridge does the final Ghostty-enum mapping in Obj-C.
enum GhosttyKeyTranslator {
    static func action(for value: TerminalKeyAction) -> Int {
        switch value {
        case .release: return 0
        case .press: return 1
        case .repeat: return 2
        }
    }

    static func mods(for value: TerminalKeyMods) -> Int {
        var bits = 0
        if value.shift { bits |= 1 << 0 }
        if value.ctrl { bits |= 1 << 1 }
        if value.alt { bits |= 1 << 2 }
        if value.meta { bits |= 1 << 3 }
        return bits
    }

    static func litterKey(for value: TerminalKeyCode) -> LitterGhosttyKey {
        switch value {
        case .enter: return .enter
        case .tab: return .tab
        case .backspace: return .backspace
        case .escape: return .escape
        case .space: return .space
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .home: return .home
        case .end: return .end
        case .delete: return .delete
        case .insert: return .insert
        default: return .unidentified
        }
    }
}
