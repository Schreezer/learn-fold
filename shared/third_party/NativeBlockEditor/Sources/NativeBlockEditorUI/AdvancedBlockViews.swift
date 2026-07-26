#if os(iOS)
import AVKit
import NativeBlockEditorEngine
import SwiftUI
import WebKit

struct DocumentImageBlockView: View {
    let node: BlockNode
    let identifier: String
    let onResize: (Double) -> Void

    private var source: String { node.data["url"]?.stringValue ?? "" }
    private var width: Double { min(680, max(96, node.data["width"]?.doubleValue ?? 360)) }

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 6) {
            resolvedImage
                .frame(width: width)
                .frame(maxWidth: .infinity, alignment: alignment)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 8) {
                Button { onResize(max(96, width - 48)) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel("Make image smaller")
                .accessibilityIdentifier("image-smaller-\(identifier)")

                Text("\(Int(width)) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button { onResize(min(680, width + 48)) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel("Make image larger")
                .accessibilityIdentifier("image-larger-\(identifier)")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(node.data["alt"]?.stringValue ?? "Image block")
        .accessibilityIdentifier("image-block-\(identifier)")
    }

    @ViewBuilder
    private var resolvedImage: some View {
        if let image = localImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFit()
                case .failure:
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                        .frame(minHeight: 120)
                default:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        } else {
            ContentUnavailableView("Image unavailable", systemImage: "photo")
                .frame(minHeight: 120)
        }
    }

    private var localImage: UIImage? {
        if source.lowercased().hasPrefix("data:image/"),
           let comma = source.firstIndex(of: ","),
           let data = Data(base64Encoded: String(source[source.index(after: comma)...])) {
            return UIImage(data: data)
        }
        if let url = URL(string: source), url.isFileURL,
           let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return UIImage(data: data)
        }
        if source.hasPrefix("/"), let data = try? Data(contentsOf: URL(fileURLWithPath: source), options: [.mappedIfSafe]) {
            return UIImage(data: data)
        }
        return nil
    }

    private var alignment: Alignment {
        switch node.data["align"]?.stringValue {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
    }
}

struct NativeMediaBlockView: View {
    let node: BlockNode
    let identifier: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var kind: String { node.data["kind"]?.stringValue ?? "file" }
    private var url: URL? { URL(string: node.data["url"]?.stringValue ?? "") }

    var body: some View {
        Group {
            if kind == "video", let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.data["title"]?.stringValue?.isEmpty == false
                            ? node.data["title"]?.stringValue ?? "Media"
                            : kind.capitalized)
                            .font(.body.weight(.semibold))
                        Text(node.data["url"]?.stringValue ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if kind == "audio" {
                        Button {
                            guard let player else { return }
                            if isPlaying { player.pause() } else { player.play() }
                            isPlaying.toggle()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
                    } else if let url {
                        Link(destination: url) { Image(systemName: "arrow.up.right") }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: node.data["url"]?.stringValue) {
            if let url { player = AVPlayer(url: url) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.capitalized) block")
        .accessibilityIdentifier("media-block-\(identifier)")
    }

    private var icon: String {
        switch kind {
        case "audio": "waveform"
        case "video": "play.rectangle"
        default: "doc"
        }
    }
}

struct LinkPreviewBlockView: View {
    let node: BlockNode

    var body: some View {
        if let string = node.data["url"]?.stringValue, let url = URL(string: string) {
            Link(destination: url) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    VStack(alignment: .leading) {
                        Text(url.host ?? "Link preview").font(.body.weight(.semibold))
                        Text(string).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct PluginBlockView: View {
    let node: BlockNode
    let identifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.data["display_name"]?.stringValue ?? "Plugin")
                    .font(.body.weight(.semibold))
                Text(node.data["plugin_id"]?.stringValue ?? "Unknown plugin")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Payload is preserved losslessly in document JSON.")
                    .font(.caption)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plugin block")
        .accessibilityIdentifier("plugin-block-\(identifier)")
    }
}

struct DatabaseBlockView: View {
    let node: BlockNode
    let identifier: String
    let onCellChange: (String, String, String) -> Void
    let onAddRow: () -> Void

    private var columns: [(id: String, name: String)] {
        guard case let .array(values)? = node.data["columns"] else { return [] }
        return values.compactMap { value in
            guard case let .object(column) = value,
                  let id = column["id"]?.stringValue,
                  let name = column["name"]?.stringValue else { return nil }
            return (id, name)
        }
    }

    private var rows: [(id: String, cells: [String: JSONValue])] {
        guard case let .array(values)? = node.data["rows"] else { return [] }
        return values.compactMap { value in
            guard case let .object(row) = value, let id = row["id"]?.stringValue else { return nil }
            if case let .object(cells)? = row["cells"] { return (id, cells) }
            return (id, [:])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(node.data["title"]?.stringValue ?? "Database", systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                Button("Add row", systemImage: "plus", action: onAddRow)
                    .font(.caption)
                    .accessibilityIdentifier("database-add-row-\(identifier)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(columns, id: \.id) { column in
                            Text(column.name)
                                .font(.caption.weight(.semibold))
                                .frame(width: 132, alignment: .leading)
                                .padding(8)
                                .background(Color(uiColor: .secondarySystemBackground))
                        }
                    }
                    ForEach(rows, id: \.id) { row in
                        GridRow {
                            ForEach(columns, id: \.id) { column in
                                DatabaseCellField(
                                    value: row.cells[column.id]?.stringValue ?? "",
                                    onCommit: { onCellChange(row.id, column.id, $0) }
                                )
                                .frame(width: 132)
                                .padding(8)
                            }
                        }
                    }
                }
                .overlay { Rectangle().stroke(Color(uiColor: .separator), lineWidth: 0.5) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Database block")
        .accessibilityIdentifier("database-block-\(identifier)")
    }
}

private struct DatabaseCellField: View {
    @State var value: String
    let onCommit: (String) -> Void

    var body: some View {
        TextField("Empty", text: $value)
            .textFieldStyle(.plain)
            .onSubmit { onCommit(value) }
    }
}

struct BrowserHTMLBlockView: UIViewRepresentable {
    let html: String
    let allowNetwork: Bool
    let identifier: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.accessibilityLabel = "Browser HTML block"
        view.accessibilityIdentifier = "html-block-\(identifier)"
        view.loadHTMLString(HTMLSandbox.sanitize(html, allowNetwork: allowNetwork), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let fingerprint = "\(allowNetwork)|\(html)"
        guard context.coordinator.fingerprint != fingerprint else { return }
        context.coordinator.fingerprint = fingerprint
        view.loadHTMLString(HTMLSandbox.sanitize(html, allowNetwork: allowNetwork), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserHTMLBlockView
        var fingerprint = ""
        init(parent: BrowserHTMLBlockView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { value, _ in
                guard let measured = value as? Double else { return }
                DispatchQueue.main.async { self.parent.height = min(640, max(80, measured + 12)) }
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

private enum HTMLSandbox {
    static func sanitize(_ html: String, allowNetwork: Bool) -> String {
        var source = html
        let forbidden = ["script", "iframe", "frame", "object", "embed", "form", "base"]
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
        let remote = allowNetwork ? "https:" : ""
        let policy = "default-src 'none'; style-src 'unsafe-inline' \(remote); img-src data: \(remote); font-src data: \(remote); media-src data: \(remote);"
        let head = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><style>html,body{margin:0;padding:0;background:transparent;color:#111;font:-apple-system-body;overflow:hidden}*{box-sizing:border-box;max-width:100%}@media(prefers-color-scheme:dark){html,body{color:#eee}}</style>"
        if let range = source.range(of: "<head>", options: .caseInsensitive) {
            source.insert(contentsOf: head, at: range.upperBound)
            return source
        }
        return "<!doctype html><html><head>\(head)</head><body>\(source)</body></html>"
    }
}

actor ImageAssetStore {
    enum StorageMode { case localFile, embeddedBase64 }

    func importImage(_ data: Data, mode: StorageMode) throws -> String {
        guard data.count <= 20 * 1_024 * 1_024, let image = UIImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let normalized = image.jpegData(compressionQuality: 0.86) ?? data
        switch mode {
        case .embeddedBase64:
            return "data:image/jpeg;base64,\(normalized.base64EncodedString())"
        case .localFile:
            let manager = FileManager.default
            let root = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("NativeEditorMedia", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent("\(UUID().uuidString).jpg")
            try normalized.write(to: destination, options: .atomic)
            return destination.absoluteString
        }
    }
}

#endif
