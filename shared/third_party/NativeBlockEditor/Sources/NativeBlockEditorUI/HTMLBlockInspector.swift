#if os(iOS)
import Foundation
import WebKit

/// What an offscreen dry run of an HTML block found.
public struct HTMLBlockInspection: Equatable, Sendable {
    /// Problems a reader would hit, phrased as instructions for the author.
    public var issues: [String]
    /// The rendered height in points, when the block finished rendering.
    public var contentHeight: Int?

    public var passed: Bool { issues.isEmpty }

    public init(issues: [String], contentHeight: Int? = nil) {
        self.issues = issues
        self.contentHeight = contentHeight
    }
}

/// Renders an HTML block exactly as the reader will (same sandbox and
/// scripts), pokes its controls, and reports what went wrong, so an author
/// can fix a visualization before anyone reads it.
@MainActor
public enum HTMLBlockInspector {
    /// A narrow phone reading column, so content that fits here fits everywhere.
    public static let defaultViewportWidth: CGFloat = 360

    public static func inspect(
        html: String,
        viewportWidth: CGFloat = defaultViewportWidth,
        timeout: Duration = .seconds(6)
    ) async -> HTMLBlockInspection {
        let staticIssues = sourceIssues(in: html)
        let session = HTMLBlockInspectionSession(html: html, viewportWidth: viewportWidth)
        var inspection = await session.run(timeout: timeout)
        inspection.issues = staticIssues + inspection.issues
        return inspection
    }

    /// Author mistakes the sandbox silently removes, which otherwise surface
    /// only as controls that do nothing.
    static func sourceIssues(in html: String) -> [String] {
        var issues: [String] = []
        if html.range(of: #"<[^>]*\son[a-z]+\s*="#, options: [.regularExpression, .caseInsensitive]) != nil {
            issues.append(
                "Inline event attributes such as onclick= or oninput= are removed for safety, so those controls do nothing. Attach handlers with addEventListener inside a <script>."
            )
        }
        if html.range(of: #"<\s*form\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            issues.append("<form> elements are removed. Use plain controls with event listeners instead.")
        }
        if html.range(of: #"<\s*(iframe|object|embed)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            issues.append("<iframe>, <object> and <embed> are removed. Build the visualization inline.")
        }
        if html.range(of: "javascript:", options: .caseInsensitive) != nil {
            issues.append("javascript: URLs are blocked. Use addEventListener instead.")
        }
        return issues
    }
}

@MainActor
private final class HTMLBlockInspectionSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct ScriptProblem: Hashable {
        var message: String
        var line: Int
        var phase: String?
    }

    private struct Metrics: Decodable {
        var height: Int
        var viewportWidth: Int
        var contentWidth: Int
        var overflowElement: String?
        var hasVisibleContent: Bool
        var controlCount: Int
        var unlabeledControls: [String]
        var hasLiveRegion: Bool
        var showsObjectText: Bool
    }

    private struct InteractionReport: Decodable {
        var actions: Int
        var invalidValues: [String]
    }

    /// WebKit reports only "Script error." for scripts in an opaque-origin
    /// document. A named (unresolvable) origin keeps the real message and
    /// line; the sandbox policy still blocks every request to it.
    private static let documentURL = URL(string: "https://visualization.learnfold.invalid/")
    private var hasLoadedDocument = false

    private let html: String
    private let viewportWidth: CGFloat
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<HTMLBlockInspection, Never>?
    private var errors: [ScriptProblem] = []
    private var blockedResources: [String] = []
    private var metrics: Metrics?
    private var interaction: InteractionReport?

    init(html: String, viewportWidth: CGFloat) {
        self.html = html
        self.viewportWidth = viewportWidth
    }

    func run(timeout: Duration) async -> HTMLBlockInspection {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.userContentController.add(self, name: HTMLBlockScripts.errorHandler)
            configuration.userContentController.addUserScript(WKUserScript(
                source: HTMLBlockScripts.errorReporter,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: viewportWidth, height: 800),
                configuration: configuration
            )
            webView.navigationDelegate = self
            self.webView = webView
            webView.loadHTMLString(
                HTMLSandbox.sanitize(html, allowNetwork: false, allowJavaScript: true),
                baseURL: Self.documentURL
            )
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(timeoutSeconds: Int(timeout.components.seconds))
            }
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { await examine(webView) }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        finish(extraIssue: "The visualization failed to load: \(error.localizedDescription)")
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        finish(extraIssue: "The visualization failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        finish(extraIssue: "The visualization crashed the web view, usually from runaway memory use or an endless loop.")
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isInitialDocument = url?.scheme == "about"
            || (url == Self.documentURL && !hasLoadedDocument)
        hasLoadedDocument = hasLoadedDocument || url == Self.documentURL
        decisionHandler(url == nil || isInitialDocument ? .allow : .cancel)
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let report = message.body as? [String: Any],
              let text = report["message"] as? String else { return }
        if report["kind"] as? String == "blocked" {
            if !blockedResources.contains(text) { blockedResources.append(text) }
            return
        }
        let problem = ScriptProblem(
            message: text,
            line: (report["line"] as? NSNumber)?.intValue ?? 0,
            phase: report["phase"] as? String
        )
        if !errors.contains(problem) { errors.append(problem) }
    }

    // MARK: Examination

    private func examine(_ webView: WKWebView) async {
        // Let start-up scripts, timers, and layout settle, as the reader does.
        try? await Task.sleep(for: .seconds(BrowserHTMLBlockView.Coordinator.settleDelay))
        guard continuation != nil else { return }
        metrics = await decode(Metrics.self, from: webView, script: Self.metricsScript)
        guard continuation != nil else { return }
        interaction = await decode(InteractionReport.self, from: webView, script: Self.interactionScript)
        try? await Task.sleep(for: .milliseconds(400))
        finish()
    }

    private func decode<T: Decodable>(_: T.Type, from webView: WKWebView, script: String) async -> T? {
        guard let json = try? await webView.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func finish(extraIssue: String? = nil, timeoutSeconds: Int? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        var issues = scriptIssues()
        if let extraIssue { issues.append(extraIssue) }
        if let timeoutSeconds, metrics == nil {
            issues.append(
                "The visualization did not finish rendering within \(timeoutSeconds) seconds. Look for an endless loop or heavy synchronous work at start-up."
            )
        }
        if let metrics { issues += layoutIssues(metrics) }
        if let interaction, !interaction.invalidValues.isEmpty {
            let actions = interaction.invalidValues.prefix(3).joined(separator: "; ")
            issues.append(
                "Invalid values such as “NaN” or “undefined” appeared on screen \(actions). Guard the calculation for edge values."
            )
        }
        if !blockedResources.isEmpty {
            let resources = blockedResources.prefix(3).joined(separator: ", ")
            issues.append(
                "It tried to use something the sandbox blocks (\(resources)). Visualizations cannot make network requests, load external files, or use eval; inline everything."
            )
        }
        teardown()
        continuation.resume(returning: HTMLBlockInspection(issues: issues, contentHeight: metrics?.height))
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: HTMLBlockScripts.errorHandler
        )
        webView = nil
    }

    private func scriptIssues() -> [String] {
        errors.prefix(4).map { problem in
            let location = problem.line > 0 ? " (line \(problem.line))" : ""
            let when = problem.phase ?? "while loading"
            var message = problem.message
            while message.hasSuffix(".") { message.removeLast() }
            return "JavaScript error \(when): \(message)\(location)."
        }
    }

    /// Native controls such as sliders carry a couple of pixels of margin
    /// past `width: 100%`, which the reader clips invisibly.
    private static let overflowTolerance = 6

    private func layoutIssues(_ metrics: Metrics) -> [String] {
        var issues: [String] = []
        if metrics.contentWidth > metrics.viewportWidth + Self.overflowTolerance {
            let element = metrics.overflowElement.map { " The first element that sticks out is \($0)." } ?? ""
            issues.append(
                "Content is \(metrics.contentWidth)px wide on a \(metrics.viewportWidth)px phone column, so it is cut off on the right.\(element) Use max-width: 100%, flexible widths, or wrap onto more lines."
            )
        }
        if !metrics.hasVisibleContent {
            issues.append(
                "The first frame is empty: nothing visible renders before the reader interacts. Draw an initial state on load."
            )
        }
        if CGFloat(metrics.height) + HTMLBlockLayout.contentPadding > HTMLBlockLayout.inlineMaximumHeight {
            issues.append(
                "It is \(metrics.height)px tall. Only the first \(Int(HTMLBlockLayout.inlineMaximumHeight))px show inline; readers must open it full screen to see the rest. Make it more compact."
            )
        }
        if !metrics.unlabeledControls.isEmpty {
            let examples = metrics.unlabeledControls.prefix(3).joined(separator: ", ")
            issues.append(
                "\(metrics.unlabeledControls.count) control(s) have no accessible name (\(examples)). Add a <label> or aria-label so VoiceOver can announce them."
            )
        }
        if metrics.controlCount > 0, !metrics.hasLiveRegion {
            issues.append(
                "Results change without a live region, so VoiceOver users never hear them. Put the result in an <output> or an element with aria-live=\"polite\"."
            )
        }
        if metrics.showsObjectText {
            issues.append("The first frame shows “[object Object]”. Format the value before displaying it.")
        }
        return issues
    }

    // MARK: Scripts

    private static let metricsScript = """
    (function() {
      var body = document.body;
      var viewport = window.innerWidth;
      var describe = function(el) {
        var label = el.tagName.toLowerCase();
        var className = typeof el.className === 'string' ? el.className : (el.className && el.className.baseVal) || '';
        if (el.id) { label += '#' + el.id; }
        else if (className.trim()) { label += '.' + className.trim().split(/\\s+/)[0]; }
        return '<' + label + '>';
      };
      var contentWidth = viewport;
      var overflowElement = null;
      var all = body.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var box = all[i].getBoundingClientRect();
        if (box.width === 0 && box.height === 0) { continue; }
        // Elements parked fully off-screen (visually hidden text) are intentional.
        if (box.right <= 0 || box.left >= viewport) { continue; }
        if (box.right > viewport + 6 || box.left < -6) {
          var extent = Math.max(box.right, viewport - box.left);
          if (extent > contentWidth) { contentWidth = extent; }
          if (!overflowElement) { overflowElement = describe(all[i]); }
        }
      }
      var visible = (body.innerText || '').trim().length > 2;
      if (!visible) {
        var graphics = body.querySelectorAll('svg, canvas, img, video');
        for (var g = 0; g < graphics.length; g++) {
          var graphic = graphics[g].getBoundingClientRect();
          if (graphic.width * graphic.height > 400) { visible = true; break; }
        }
      }
      var controls = body.querySelectorAll('button, input:not([type=hidden]), select, textarea, [role=button], [role=slider], [role=switch], [role=checkbox], [role=tab]');
      var unlabeled = [];
      var textOf = function(el) { return (el.innerText || el.textContent || '').trim(); };
      for (var c = 0; c < controls.length; c++) {
        var control = controls[c];
        var type = (control.getAttribute('type') || '').toLowerCase();
        var named = control.getAttribute('aria-label') || control.getAttribute('title');
        var labelledBy = control.getAttribute('aria-labelledby');
        if (!named && labelledBy) {
          named = labelledBy.split(/\\s+/).map(function(id) {
            var target = document.getElementById(id);
            return target ? textOf(target) : '';
          }).join(' ').trim();
        }
        var isButton = control.tagName === 'BUTTON' || control.getAttribute('role') === 'button';
        if (!named && isButton) { named = textOf(control) || (control.querySelector('img[alt]:not([alt=""])') ? 'image' : ''); }
        if (!named && (type === 'button' || type === 'submit' || type === 'reset')) { named = control.value; }
        if (!named && control.id) {
          var forLabel = document.querySelector('label[for="' + CSS.escape(control.id) + '"]');
          if (forLabel) { named = textOf(forLabel); }
        }
        if (!named && control.closest('label')) { named = textOf(control.closest('label')); }
        if (!named && control.getAttribute('placeholder')) { named = control.getAttribute('placeholder'); }
        if (!named) {
          var tag = control.tagName.toLowerCase();
          unlabeled.push('<' + tag + (type ? ' type=' + type : '') + (control.id ? ' id=' + control.id : '') + '>');
        }
      }
      return JSON.stringify({
        height: Math.ceil(body.scrollHeight),
        viewportWidth: Math.round(viewport),
        contentWidth: Math.ceil(contentWidth),
        overflowElement: overflowElement,
        hasVisibleContent: visible,
        controlCount: controls.length,
        unlabeledControls: unlabeled,
        hasLiveRegion: !!body.querySelector('[aria-live]:not([aria-live=off]), [role=status], [role=alert], [role=log], output'),
        showsObjectText: (body.innerText || '').indexOf('[object Object]') !== -1
      });
    })()
    """

    /// Taps each button, drags each slider to both ends, and picks the last
    /// option of each menu. Errors are attributed through `__learnfoldPhase`;
    /// an action that makes NaN/undefined appear is reported by name.
    private static let interactionScript = """
    (function() {
      var invalid = /(^|[^A-Za-z])(NaN|undefined)(?![A-Za-z])|\\[object Object\\]/g;
      var countInvalid = function() { var found = (document.body.innerText || '').match(invalid); return found ? found.length : 0; };
      var nameOf = function(el) {
        var text = el.getAttribute('aria-label') || (el.innerText || '').trim() || el.value || el.getAttribute('title') || el.id || el.tagName.toLowerCase();
        return String(text).replace(/\\s+/g, ' ').trim().slice(0, 40);
      };
      var actions = 0;
      var invalidValues = [];
      var act = function(label, perform) {
        var before = countInvalid();
        window.__learnfoldPhase = label;
        try { perform(); } catch (error) {}
        actions += 1;
        if (countInvalid() > before) { invalidValues.push(label); }
      };
      var fire = function(el) {
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      Array.prototype.slice.call(document.querySelectorAll('button, [role=button], input[type=button], input[type=checkbox], input[type=radio]'), 0, 8)
        .forEach(function(button) {
          if (button.disabled) { return; }
          act('after tapping “' + nameOf(button) + '”', function() { button.click(); });
        });
      Array.prototype.slice.call(document.querySelectorAll('input[type=range], input[type=number]'), 0, 4)
        .forEach(function(input) {
          var name = nameOf(input);
          ['max', 'min'].forEach(function(edge) {
            var value = input.getAttribute(edge);
            if (value === null && input.type === 'range') { value = edge === 'max' ? '100' : '0'; }
            if (value === null) { return; }
            act('after moving “' + name + '” to its ' + (edge === 'max' ? 'maximum' : 'minimum'), function() {
              input.value = value;
              fire(input);
            });
          });
        });
      Array.prototype.slice.call(document.querySelectorAll('select'), 0, 3)
        .forEach(function(select) {
          if (select.options.length < 2) { return; }
          var last = select.options[select.options.length - 1];
          act('after choosing “' + String(last.text || '').trim().slice(0, 40) + '”', function() {
            select.selectedIndex = select.options.length - 1;
            fire(select);
          });
        });
      window.__learnfoldPhase = 'shortly after interaction';
      return JSON.stringify({ actions: actions, invalidValues: invalidValues });
    })()
    """
}
#endif
