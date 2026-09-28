#if os(iOS)
import NativeBlockEditorEngine
import SwiftUI
import WebKit

/// Inline sizing for HTML blocks. Content taller than the inline limit is
/// shown as a faded preview that opens full screen, never as a scroll view
/// nested inside the reading scroll view.
enum HTMLBlockLayout {
    static let inlineMaximumHeight: CGFloat = 640
    static let minimumHeight: CGFloat = 80
    /// Breathing room below the measured body so the last line never clips.
    static let contentPadding: CGFloat = 12

    static func blockHeight(forMeasuredBody measured: Double) -> CGFloat {
        max(minimumHeight, CGFloat(measured) + contentPadding)
    }

    static func displayedHeight(for blockHeight: CGFloat) -> CGFloat {
        min(inlineMaximumHeight, blockHeight)
    }

    static func isClipped(_ blockHeight: CGFloat) -> Bool {
        blockHeight > inlineMaximumHeight + 1
    }
}

/// An uncaught JavaScript error reported by a rendered HTML block.
struct HTMLBlockScriptError: Equatable {
    var message: String
    /// The error happened while the block was starting and nothing visible
    /// rendered, so the block is unusable rather than partly broken.
    var breaksFirstFrame: Bool
}

public struct BrowserHTMLBlockContainer: View {
    let html: String
    let allowNetwork: Bool
    let allowJavaScript: Bool
    let identifier: String
    @State private var blockHeight: CGFloat = 220
    @State private var loadFailed = false
    @State private var brokenOnStart = false
    @State private var brokenAfterStart = false
    @State private var retryID = 0
    @State private var showsFullScreen = false

    public init(html: String, allowNetwork: Bool, allowJavaScript: Bool, identifier: String) {
        self.html = html
        self.allowNetwork = allowNetwork
        self.allowJavaScript = allowJavaScript
        self.identifier = identifier
    }

    private var contentFingerprint: String {
        "\(allowNetwork)|\(allowJavaScript)|\(html)"
    }

    private var isClipped: Bool { HTMLBlockLayout.isClipped(blockHeight) }

    public var body: some View {
        Group {
            if loadFailed || brokenOnStart {
                HTMLBlockFailureCard(
                    isInteractive: allowJavaScript,
                    identifier: identifier,
                    retry: retry
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    BrowserHTMLBlockView(
                        html: html,
                        allowNetwork: allowNetwork,
                        allowJavaScript: allowJavaScript,
                        identifier: identifier,
                        height: $blockHeight,
                        loadFailed: $loadFailed,
                        onScriptError: handle
                    )
                    .id(retryID)
                    .frame(height: HTMLBlockLayout.displayedHeight(for: blockHeight))
                    .mask {
                        // Fade the cut edge so a clipped preview reads as
                        // "there is more", on any page background.
                        LinearGradient(
                            stops: isClipped
                                ? [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)]
                                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .overlay(alignment: .bottom) {
                        if isClipped { expandButton.padding(.bottom, 10) }
                    }
                    if brokenAfterStart {
                        HTMLBlockRuntimeNotice(identifier: identifier, reload: retry)
                    }
                }
            }
        }
        // The failure branch has no web view to clear the flag, so replacing a
        // failed block’s HTML would otherwise leave the error card forever.
        .onChange(of: contentFingerprint) { _, _ in
            resetFailureState()
        }
        .sheet(isPresented: $showsFullScreen) {
            HTMLBlockFullScreenView(
                html: html,
                allowNetwork: allowNetwork,
                allowJavaScript: allowJavaScript,
                identifier: identifier
            )
        }
    }

    private var expandButton: some View {
        Button {
            showsFullScreen = true
        } label: {
            Label(
                allowJavaScript ? "Open full interactive" : "Show all",
                systemImage: "arrow.up.left.and.arrow.down.right"
            )
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5) }
        .accessibilityHint("Shows the whole visualization on one screen")
        .accessibilityIdentifier("html-block-expand-\(identifier)")
    }

    private func handle(_ error: HTMLBlockScriptError) {
        if error.breaksFirstFrame {
            brokenOnStart = true
        } else {
            brokenAfterStart = true
        }
    }

    private func retry() {
        resetFailureState()
        retryID += 1
    }

    private func resetFailureState() {
        loadFailed = false
        brokenOnStart = false
        brokenAfterStart = false
    }
}

private struct HTMLBlockFailureCard: View {
    let isInteractive: Bool
    let identifier: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(isInteractive ? "This interactive couldn’t run" : "This block couldn’t load")
                    .font(.headline)
                Text("The rest of the lesson is unaffected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("html-block-retry-\(identifier)")
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("html-block-failure-\(identifier)")
    }
}

private struct HTMLBlockRuntimeNotice: View {
    let identifier: String
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Part of this interactive stopped working.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reload", action: reload)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("html-block-reload-\(identifier)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("html-block-runtime-notice-\(identifier)")
    }
}

private struct HTMLBlockFullScreenView: View {
    let html: String
    let allowNetwork: Bool
    let allowJavaScript: Bool
    let identifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var blockHeight: CGFloat = 220
    @State private var loadFailed = false
    @State private var retryID = 0

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    HTMLBlockFailureCard(
                        isInteractive: allowJavaScript,
                        identifier: "\(identifier)-full",
                        retry: {
                            loadFailed = false
                            retryID += 1
                        }
                    )
                    .padding()
                } else {
                    BrowserHTMLBlockView(
                        html: html,
                        allowNetwork: allowNetwork,
                        allowJavaScript: allowJavaScript,
                        identifier: "\(identifier)-full",
                        height: $blockHeight,
                        loadFailed: $loadFailed,
                        scrollsInternally: true
                    )
                    .id(retryID)
                    .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(allowJavaScript ? "Interactive" : "Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("html-block-full-done")
                }
            }
        }
    }
}

struct BrowserHTMLBlockView: UIViewRepresentable {
    let html: String
    let allowNetwork: Bool
    let allowJavaScript: Bool
    let identifier: String
    /// The measured block height, unclamped. The container decides how much of
    /// it to show inline.
    @Binding var height: CGFloat
    @Binding var loadFailed: Bool
    var scrollsInternally = false
    var onScriptError: ((HTMLBlockScriptError) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowJavaScript
        if allowJavaScript {
            let controller = configuration.userContentController
            controller.add(context.coordinator, name: HTMLBlockScripts.heightHandler)
            controller.add(context.coordinator, name: HTMLBlockScripts.errorHandler)
            controller.addUserScript(WKUserScript(
                source: HTMLBlockScripts.errorReporter,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.addUserScript(WKUserScript(
                source: HTMLBlockScripts.heightObserver,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = scrollsInternally
        view.accessibilityLabel = allowJavaScript ? "Interactive visualization" : "Browser HTML block"
        view.accessibilityIdentifier = "html-block-\(identifier)"
        context.coordinator.loadContent(in: view)
        return view
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        let controller = view.configuration.userContentController
        controller.removeScriptMessageHandler(forName: HTMLBlockScripts.heightHandler)
        controller.removeScriptMessageHandler(forName: HTMLBlockScripts.errorHandler)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        view.scrollView.isScrollEnabled = scrollsInternally
        guard context.coordinator.fingerprint != contentFingerprint else { return }
        context.coordinator.recoveryAttempted = false
        context.coordinator.loadContent(in: view)
    }

    fileprivate var contentFingerprint: String {
        "\(allowNetwork)|\(allowJavaScript)|\(html)"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BrowserHTMLBlockView
        var fingerprint = ""
        var recoveryAttempted = false
        /// Errors raised before the block settled. They only break the block
        /// when nothing visible rendered; otherwise it is partly working.
        private var startupErrors: [String] = []
        private var hasSettled = false
        private var loadGeneration = 0

        /// How long after `didFinish` start-up scripts may keep running before
        /// later errors are treated as interaction failures.
        static let settleDelay: TimeInterval = 0.6

        init(parent: BrowserHTMLBlockView) { self.parent = parent }

        func loadContent(in webView: WKWebView) {
            fingerprint = parent.contentFingerprint
            startupErrors = []
            hasSettled = false
            loadGeneration += 1
            webView.loadHTMLString(
                HTMLSandbox.sanitize(
                    parent.html,
                    allowNetwork: parent.allowNetwork,
                    allowJavaScript: parent.allowJavaScript
                ),
                baseURL: nil
            )
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // SwiftUI may retain this view after WebKit discards its process.
            // Reload the sandboxed document once, then offer an explicit retry.
            guard !recoveryAttempted else {
                parent.loadFailed = true
                return
            }
            recoveryAttempted = true
            loadContent(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.loadFailed = true
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            webView.evaluateJavaScript(HTMLBlockScripts.bodyHeight) { value, _ in
                self.applyMeasuredHeight(value)
            }
            guard parent.allowJavaScript else { return }
            let generation = loadGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self, weak webView] in
                guard let self, let webView, generation == self.loadGeneration else { return }
                self.settle(webView)
            }
        }

        func settle(_ webView: WKWebView) {
            hasSettled = true
            guard let firstError = startupErrors.first else { return }
            webView.evaluateJavaScript(HTMLBlockScripts.hasVisibleContent) { value, _ in
                // If the probe itself cannot run, keep whatever is showing.
                let isVisible = (value as? Bool) ?? true
                self.parent.onScriptError?(HTMLBlockScriptError(
                    message: firstError,
                    breaksFirstFrame: !isVisible
                ))
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case HTMLBlockScripts.heightHandler:
                applyMeasuredHeight(message.body)
            case HTMLBlockScripts.errorHandler:
                guard let report = message.body as? [String: Any],
                      let text = report["message"] as? String else { return }
                if hasSettled {
                    parent.onScriptError?(HTMLBlockScriptError(message: text, breaksFirstFrame: false))
                } else {
                    startupErrors.append(text)
                }
            default:
                break
            }
        }

        private func applyMeasuredHeight(_ value: Any?) {
            guard let measured = (value as? NSNumber)?.doubleValue,
                  measured.isFinite,
                  measured > 0 else { return }
            let resolved = HTMLBlockLayout.blockHeight(forMeasuredBody: measured)
            DispatchQueue.main.async {
                // Ignore sub-point churn so a measurement that lands a hair
                // off the current frame cannot drive a resize loop.
                guard abs(self.parent.height - resolved) > 1 else { return }
                self.parent.height = resolved
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isInitialDocument = url == nil || url?.scheme == "about"
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }
}

/// Scripts shared by the reader and the save-time inspector, so both observe
/// the block in the same way.
enum HTMLBlockScripts {
    static let heightHandler = "contentHeight"
    static let errorHandler = "scriptError"

    // `documentElement.scrollHeight` is clamped to the viewport, which is
    // the frame this measurement sets. Measuring it fed the frame height
    // back into itself and ratcheted every block to the maximum.
    // The body is laid out by its content, so it is the stable signal.
    static let bodyHeight = "Math.ceil(document.body.scrollHeight)"

    /// Installed before any author script so start-up errors are caught too.
    /// `__learnfoldPhase` lets the inspector attribute an error to the
    /// interaction that caused it.
    static let errorReporter = """
    (function() {
      window.alert = function() {};
      window.confirm = function() { return false; };
      window.prompt = function() { return null; };
      window.open = function() { return null; };
      var post = function(payload) {
        payload.phase = window.__learnfoldPhase || null;
        try { window.webkit.messageHandlers.\(errorHandler).postMessage(payload); } catch (ignored) {}
      };
      window.addEventListener('error', function(event) {
        // Resource failures are plain events; only script errors carry a message.
        if (!(event instanceof ErrorEvent)) { return; }
        post({ kind: 'error', message: String(event.message || 'Unknown error'), line: event.lineno || 0 });
      });
      window.addEventListener('unhandledrejection', function(event) {
        var reason = event.reason;
        post({ kind: 'error', message: 'Unhandled promise rejection: ' + (reason && reason.message ? reason.message : String(reason)), line: 0 });
      });
      document.addEventListener('securitypolicyviolation', function(event) {
        post({ kind: 'blocked', message: String(event.blockedURI || 'resource'), directive: String(event.violatedDirective || '') });
      });
    })();
    """

    static let heightObserver = """
    (function() {
      var report = function() {
        var height = Math.ceil(document.body.scrollHeight);
        window.webkit.messageHandlers.\(heightHandler).postMessage(height);
      };
      // Observing documentElement watched the element the reported height
      // resizes, so every report triggered another one.
      new ResizeObserver(report).observe(document.body);
      report();
    })();
    """

    static let hasVisibleContent = """
    (function() {
      var body = document.body;
      if (!body) { return false; }
      if ((body.innerText || '').trim().length > 2) { return true; }
      var graphics = body.querySelectorAll('svg, canvas, img, video');
      for (var i = 0; i < graphics.length; i++) {
        var box = graphics[i].getBoundingClientRect();
        if (box.width * box.height > 400) { return true; }
      }
      return false;
    })()
    """
}

enum HTMLSandbox {
    static func sanitize(
        _ html: String,
        allowNetwork: Bool,
        allowJavaScript: Bool = false
    ) -> String {
        var source = html
        var forbidden = ["iframe", "frame", "object", "embed", "form", "base"]
        if !allowJavaScript { forbidden.append("script") }
        for tag in forbidden {
            source = source.replacingOccurrences(
                of: "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            source = source.replacingOccurrences(
                of: "<\\s*\(tag)\\b[^>]*?/?>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        source = source.replacingOccurrences(
            of: #"\s+on[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        source = source.replacingOccurrences(of: "javascript:", with: "blocked:", options: .caseInsensitive)
        source = source.replacingOccurrences(
            of: #"<meta\b[^>]*http-equiv\s*=\s*["']?refresh["']?[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // A `meta` policy only governs what the parser sees after it. Drop any
        // author-supplied policy and every document-structure tag so the
        // wrapper below can put ours first, ahead of all content.
        source = source.replacingOccurrences(
            of: #"<meta\b[^>]*http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        source = source.replacingOccurrences(
            of: #"<!doctype\b[^>]*>|</?\s*(?:html|head|body)\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let remote = allowNetwork ? "https:" : ""
        let scripts = allowJavaScript ? "'unsafe-inline'" : "'none'"
        let policy = "default-src 'none'; script-src \(scripts); connect-src 'none'; style-src 'unsafe-inline' \(remote); img-src data: \(remote); font-src data: \(remote); media-src data: blob: \(remote); frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
        let head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><style>html,body{margin:0;padding:0;background:transparent;color:#111;font:-apple-system-body;overflow:hidden}*{box-sizing:border-box;max-width:100%}input,select,textarea{font-size:16px}button{font:inherit}@media(prefers-color-scheme:dark){html,body{color:#eee}}</style>"
        // Always emit our own document. Inserting into a content-supplied
        // `<head>` left anything the author wrote before it parsed — and so
        // fetched — before the policy applied.
        return "<!doctype html><html><head>\(head)</head><body>\(source)</body></html>"
    }
}

#endif
