import BackgroundTasks
import Foundation

@MainActor
protocol ContinuedTurnBackgroundControlling: AnyObject {
    var hasScheduledOrRunningTasks: Bool { get }

    func beginUserInitiatedTurn(
        key: ThreadKey,
        title: String,
        agentName: String,
        keepsAliveAcrossTurns: Bool
    ) -> UUID?
    func markTurnAccepted(_ token: UUID)
    func markTurnStartFailed(_ token: UUID)
    func reuseMultiTurnSessionIfPresent(key: ThreadKey, agentName: String) -> UUID?
    func finishMultiTurnSession(key: ThreadKey, success: Bool)
    func handleSnapshot(_ snapshot: AppSnapshotRecord?)
}

@available(iOS 26.0, *)
protocol ContinuedProcessingTaskHandling: AnyObject {
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }

    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@available(iOS 26.0, *)
extension BGContinuedProcessingTask: ContinuedProcessingTaskHandling {}

@available(iOS 26.0, *)
protocol ContinuedProcessingTaskScheduling: AnyObject {
    func register(
        identifier: String,
        handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool
    func submit(_ request: BGTaskRequest) throws
    func cancel(identifier: String)
}

@available(iOS 26.0, *)
extension BGTaskScheduler: ContinuedProcessingTaskScheduling {
    func register(
        identifier: String,
        handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool {
        register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handler(continuedTask)
        }
    }

    func cancel(identifier: String) {
        cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Keeps user-started Codex turns eligible for runtime after the app moves to
/// the background. `BGContinuedProcessingTask` is deliberately an iOS-only
/// projection: the Codex turn and its canonical state remain owned by Rust.
///
/// The system owns the task's Live Activity and cancellation affordance. When
/// it expires that task (including after a person cancels it), `onExpiration`
/// interrupts the matching Codex turn so the system UI and actual work agree.
@available(iOS 26.0, *)
@MainActor
final class ContinuedTurnBackgroundController: ContinuedTurnBackgroundControlling {
    private final class Session {
        let token: UUID
        let identifier: String
        let key: ThreadKey
        let initialAssistantItemID: String?
        var accepted = false
        var observedActiveTurn = false
        var backgroundTask: (any ContinuedProcessingTaskHandling)?
        var heartbeatTask: Task<Void, Never>?
        var lastProgressUpdate = Date.distantPast
        var agentName: String
        var keepsAliveAcrossTurns: Bool

        init(
            token: UUID,
            identifier: String,
            key: ThreadKey,
            initialAssistantItemID: String?,
            agentName: String,
            keepsAliveAcrossTurns: Bool
        ) {
            self.token = token
            self.identifier = identifier
            self.key = key
            self.initialAssistantItemID = initialAssistantItemID
            self.agentName = agentName
            self.keepsAliveAcrossTurns = keepsAliveAcrossTurns
        }
    }

    /// The first 5% represents observable streaming/tool activity. When Codex
    /// publishes a plan, its completed steps occupy 5...95%. The final 5% is
    /// only closed when the canonical thread state reports that the turn ended.
    private static let progressUnitCeiling: Int64 = 10_000
    private static let activityUnitCeiling: Int64 = 500

    private let scheduler: any ContinuedProcessingTaskScheduling
    private let bundleIdentifier: String
    private let snapshotProvider: () -> AppSnapshotRecord?
    private let onExpiration: (ThreadKey) -> Void
    private var sessions: [UUID: Session] = [:]
    private var tokenByThreadKey: [ThreadKey: UUID] = [:]

    var hasScheduledOrRunningTasks: Bool {
        !sessions.isEmpty
    }

    init(
        scheduler: any ContinuedProcessingTaskScheduling = BGTaskScheduler.shared,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chirag.learnfold",
        snapshotProvider: @escaping () -> AppSnapshotRecord?,
        onExpiration: @escaping (ThreadKey) -> Void
    ) {
        self.scheduler = scheduler
        self.bundleIdentifier = bundleIdentifier
        self.snapshotProvider = snapshotProvider
        self.onExpiration = onExpiration
    }

    func beginUserInitiatedTurn(
        key: ThreadKey,
        title: String,
        agentName: String,
        keepsAliveAcrossTurns: Bool
    ) -> UUID? {
        if let existingToken = tokenByThreadKey[key],
           let existing = sessions[existingToken] {
            existing.agentName = agentName
            existing.keepsAliveAcrossTurns = existing.keepsAliveAcrossTurns
                || keepsAliveAcrossTurns
            return existingToken
        }

        let token = UUID()
        let identifier = "\(bundleIdentifier).codex-turn.\(token.uuidString.lowercased())"
        let initialAssistantItemID = snapshotProvider()?
            .threadSnapshot(for: key)?
            .latestAssistantSnippetSnapshot?
            .sourceItemId
        let session = Session(
            token: token,
            identifier: identifier,
            key: key,
            initialAssistantItemID: initialAssistantItemID,
            agentName: agentName,
            keepsAliveAcrossTurns: keepsAliveAcrossTurns
        )

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            Task { @MainActor [weak self] in
                self?.activate(task, token: token)
            }
        }

        guard registered else {
            LLog.warn(
                "background-turn",
                "continued processing handler registration was rejected",
                fields: ["identifier": identifier]
            )
            return nil
        }

        sessions[token] = session
        tokenByThreadKey[key] = token

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "\(agentName) is working",
            subtitle: Self.taskSubtitle(title)
        )
        request.strategy = .queue
        request.requiredResources = []

        do {
            try scheduler.submit(request)
            LLog.info(
                "background-turn",
                "submitted continued processing task",
                fields: ["identifier": identifier, "thread": Self.threadLabel(key)]
            )
            return token
        } catch {
            removeSession(token: token, cancelPendingRequest: true)
            LLog.error(
                "background-turn",
                "continued processing task submission failed",
                error: error,
                fields: ["identifier": identifier, "thread": Self.threadLabel(key)]
            )
            return nil
        }
    }

    func markTurnAccepted(_ token: UUID) {
        sessions[token]?.accepted = true
        handleSnapshot(snapshotProvider())
    }

    func markTurnStartFailed(_ token: UUID) {
        if sessions[token]?.keepsAliveAcrossTurns == true {
            return
        }
        finish(token: token, success: false)
    }

    func reuseMultiTurnSessionIfPresent(key: ThreadKey, agentName: String) -> UUID? {
        guard let token = tokenByThreadKey[key], let session = sessions[token] else {
            return nil
        }
        session.agentName = agentName
        return token
    }

    func finishMultiTurnSession(key: ThreadKey, success: Bool) {
        guard let token = tokenByThreadKey[key] else { return }
        finish(token: token, success: success)
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        guard let snapshot else { return }

        for session in Array(sessions.values) {
            guard let thread = snapshot.threadSnapshot(for: session.key) else { continue }

            if thread.hasActiveTurn {
                session.observedActiveTurn = true
                reportProgress(for: session, snapshot: snapshot)
                continue
            }

            let assistantItemID = thread.latestAssistantSnippetSnapshot?.sourceItemId
            let receivedNewAssistantOutput = session.accepted
                && assistantItemID != nil
                && assistantItemID != session.initialAssistantItemID

            if !session.keepsAliveAcrossTurns
                && (session.observedActiveTurn || receivedNewAssistantOutput) {
                finish(token: session.token, success: true)
            }
        }
    }

    private func activate(_ task: any ContinuedProcessingTaskHandling, token: UUID) {
        guard let session = sessions[token] else {
            task.setTaskCompleted(success: false)
            return
        }

        session.backgroundTask = task
        task.progress.totalUnitCount = Self.progressUnitCeiling
        task.progress.completedUnitCount = 1
        session.lastProgressUpdate = Date()
        updatePresentation(for: session, snapshot: snapshotProvider())

        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expire(token: token)
            }
        }

        session.heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let liveSession = self.sessions[token] else { return }
                let snapshot = self.snapshotProvider()
                if !self.applyPlanProgress(for: liveSession, snapshot: snapshot) {
                    self.advanceProgress(for: liveSession)
                }
                self.updatePresentation(for: liveSession, snapshot: snapshot)
            }
        }

        handleSnapshot(snapshotProvider())
    }

    private func reportProgress(for session: Session, snapshot: AppSnapshotRecord) {
        if applyPlanProgress(for: session, snapshot: snapshot) {
            updatePresentation(for: session, snapshot: snapshot)
            return
        }
        guard Date().timeIntervalSince(session.lastProgressUpdate) >= 2 else { return }
        advanceProgress(for: session)
        updatePresentation(for: session, snapshot: snapshot)
    }

    private func advanceProgress(for session: Session) {
        guard let task = session.backgroundTask else { return }
        task.progress.completedUnitCount = min(
            task.progress.completedUnitCount + 1,
            Self.activityUnitCeiling
        )
        session.lastProgressUpdate = Date()
    }

    @discardableResult
    private func applyPlanProgress(for session: Session, snapshot: AppSnapshotRecord?) -> Bool {
        guard let task = session.backgroundTask,
              let steps = snapshot?.threadSnapshot(for: session.key)?.activePlanProgress?.plan,
              !steps.isEmpty else {
            return false
        }

        let completed = steps.reduce(into: 0.0) { result, step in
            switch step.status {
            case .completed:
                result += 1
            case .inProgress:
                result += 0.5
            case .pending:
                break
            }
        }
        let planFraction = completed / Double(steps.count)
        let planUnits = Self.activityUnitCeiling
            + Int64(planFraction * Double(Self.progressUnitCeiling - 1_000))
        task.progress.completedUnitCount = max(
            task.progress.completedUnitCount,
            min(planUnits, Self.progressUnitCeiling - 500)
        )
        session.lastProgressUpdate = Date()
        return true
    }

    private func updatePresentation(for session: Session, snapshot: AppSnapshotRecord?) {
        guard let task = session.backgroundTask else { return }
        let threadTitle = snapshot?.threadSnapshot(for: session.key)?.displayTitle ?? "Codex task"
        let toolLabel = snapshot?
            .sessionSummary(for: session.key)?
            .lastToolLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = toolLabel.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.taskSubtitle(threadTitle)
        task.updateTitle("\(session.agentName) is working", subtitle: subtitle)
    }

    private func expire(token: UUID) {
        guard let session = sessions[token] else { return }
        let key = session.key
        finish(token: token, success: false)
        LLog.warn(
            "background-turn",
            "continued processing task expired or was cancelled",
            fields: ["thread": Self.threadLabel(key)]
        )
        onExpiration(key)
    }

    private func finish(token: UUID, success: Bool) {
        guard let session = sessions[token] else { return }
        session.heartbeatTask?.cancel()
        session.heartbeatTask = nil

        if let task = session.backgroundTask {
            if success {
                let finalUnit = max(1, task.progress.completedUnitCount + 1)
                task.progress.totalUnitCount = finalUnit
                task.progress.completedUnitCount = finalUnit
                task.updateTitle("\(session.agentName) finished", subtitle: "Your task is ready")
            }
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }

        removeSession(token: token, cancelPendingRequest: session.backgroundTask == nil)
        LLog.info(
            "background-turn",
            "completed continued processing task",
            fields: [
                "thread": Self.threadLabel(session.key),
                "success": success
            ]
        )
    }

    private func removeSession(token: UUID, cancelPendingRequest: Bool) {
        guard let session = sessions.removeValue(forKey: token) else { return }
        session.heartbeatTask?.cancel()
        if tokenByThreadKey[session.key] == token {
            tokenByThreadKey.removeValue(forKey: session.key)
        }
        if cancelPendingRequest {
            scheduler.cancel(identifier: session.identifier)
        }
    }

    private static func taskSubtitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Continuing in the background" : String(trimmed.prefix(80))
    }

    private static func threadLabel(_ key: ThreadKey) -> String {
        "\(key.serverId)|\(key.threadId)"
    }
}
