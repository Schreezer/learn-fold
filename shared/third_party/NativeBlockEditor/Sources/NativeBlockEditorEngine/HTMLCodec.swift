import Foundation

public enum HTMLImportMode: Sendable {
    /// Convert supported HTML into editable document nodes, like AppFlowy.
    case semantic
    /// Preserve the source in one native `html` extension block for an isolated
    /// browser renderer. This is the only mode that promises browser CSS fidelity.
    case browserFidelity(allowNetwork: Bool = false)
}

public struct HTMLImportPolicy: Sendable {
    public var allowsLocalResources: Bool
    public var allowedLinkSchemes: Set<String>
    public var allowedNativeBlockTypes: Set<String>
    public var maximumDataImageBytes: Int

    public init(
        allowsLocalResources: Bool = false,
        allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"],
        allowedNativeBlockTypes: Set<String> = ["nbe/plugin", "nbe/database", "nbe/child_page", "nbe/page_reference"],
        maximumDataImageBytes: Int = 10 * 1_024 * 1_024
    ) {
        self.allowsLocalResources = allowsLocalResources
        self.allowedLinkSchemes = Set(allowedLinkSchemes.map { $0.lowercased() })
        self.allowedNativeBlockTypes = allowedNativeBlockTypes
        self.maximumDataImageBytes = max(0, maximumDataImageBytes)
    }

    public static let semantic = HTMLImportPolicy()
    public static let trustedLocal = HTMLImportPolicy(allowsLocalResources: true)
}

public indirect enum HTMLCustomContent: Hashable, Sendable {
    case text(String)
    case element(HTMLCustomElement)
}

public struct HTMLCustomElement: Hashable, Sendable {
    public var tag: String
    public var attributes: [String: String]
    public var text: String
    public var children: [HTMLCustomElement]
    /// Ordered mixed content, retaining text around nested elements.
    public var content: [HTMLCustomContent]

    public init(
        tag: String,
        attributes: [String: String],
        text: String,
        children: [HTMLCustomElement],
        content: [HTMLCustomContent] = []
    ) {
        self.tag = tag
        self.attributes = attributes
        self.text = text
        self.children = children
        self.content = content
    }
}

public typealias HTMLCustomDecoder = @Sendable (HTMLCustomElement) -> [BlockNode]
public typealias HTMLCustomEncoder = @Sendable (BlockNode) -> String?

/// AppFlowy-style HTML import/export with opt-in custom element hooks.
public struct AppFlowyHTMLCodec: Sendable {
    public var mode: HTMLImportMode
    public var customDecoders: [String: HTMLCustomDecoder]
    public var customEncoders: [String: HTMLCustomEncoder]
    public var importPolicy: HTMLImportPolicy

    public init(
        mode: HTMLImportMode = .semantic,
        importPolicy: HTMLImportPolicy = .semantic,
        customDecoders: [String: HTMLCustomDecoder] = [:],
        customEncoders: [String: HTMLCustomEncoder] = [:]
    ) {
        self.mode = mode
        self.importPolicy = importPolicy
        self.customDecoders = Dictionary(uniqueKeysWithValues: customDecoders.map { ($0.key.lowercased(), $0.value) })
        self.customEncoders = customEncoders
    }

    public func decode(_ html: String) throws -> BlockDocument {
        if case let .browserFidelity(allowNetwork) = mode {
            return BlockDocument(root: BlockNode(type: "page", children: [.html(html, allowNetwork: allowNetwork)]))
        }
        let dom = ForgivingHTMLParser(html: html).parse()
        let body = dom.firstDescendant(named: "body") ?? dom
        let nodes = HTMLDocumentDecoder(customDecoders: customDecoders, policy: importPolicy).decodeChildren(of: body)
        let document = BlockDocument(root: BlockNode(type: "page", children: nodes))
        try document.validate()
        return document
    }

    public func encode(_ document: BlockDocument) -> String {
        HTMLDocumentEncoder(customEncoders: customEncoders).encode(document)
    }
}

public func htmlToDocument(_ html: String) throws -> BlockDocument {
    try AppFlowyHTMLCodec().decode(html)
}

public func documentToHTML(_ document: BlockDocument) -> String {
    AppFlowyHTMLCodec().encode(document)
}

private final class HTMLDOMNode {
    enum Kind {
        case root
        case element(String, [String: String])
        case text(String)
    }

    let kind: Kind
    var children: [HTMLDOMNode] = []

    init(_ kind: Kind) {
        self.kind = kind
    }

    var name: String? {
        if case let .element(name, _) = kind { return name }
        return nil
    }

    var attributes: [String: String] {
        if case let .element(_, attributes) = kind { return attributes }
        return [:]
    }

    func firstDescendant(named target: String) -> HTMLDOMNode? {
        if name == target { return self }
        for child in children {
            if let result = child.firstDescendant(named: target) { return result }
        }
        return nil
    }

    func descendants(named target: String) -> [HTMLDOMNode] {
        children.flatMap { child -> [HTMLDOMNode] in
            var matches = child.name == target ? [child] : []
            matches.append(contentsOf: child.descendants(named: target))
            return matches
        }
    }

    var allText: String {
        switch kind {
        case let .text(text): text
        default: children.map(\.allText).joined()
        }
    }

    var customElement: HTMLCustomElement {
        HTMLCustomElement(
            tag: name ?? "",
            attributes: attributes,
            text: allText,
            children: children.compactMap { $0.name == nil ? nil : $0.customElement },
            content: children.compactMap { child in
                switch child.kind {
                case let .text(text): .text(text)
                case .element: .element(child.customElement)
                case .root: nil
                }
            }
        )
    }
}

private struct ForgivingHTMLParser {
    let html: String

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    private static let paragraphClosingStarts: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "menu", "nav", "ol", "p", "pre", "section", "table", "ul",
    ]

    func parse() -> HTMLDOMNode {
        let root = HTMLDOMNode(.root)
        var stack = [root]
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let end = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                let text = String(html[cursor ..< end]).htmlEntityDecoded
                if !text.isEmpty { stack.last?.children.append(HTMLDOMNode(.text(text))) }
                cursor = end
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: cursor ..< html.endIndex)?.upperBound {
                    cursor = end
                } else {
                    break
                }
                continue
            }

            guard let tagEnd = endOfTag(startingAt: cursor) else {
                stack.last?.children.append(HTMLDOMNode(.text("<")))
                cursor = html.index(after: cursor)
                continue
            }

            let insideStart = html.index(after: cursor)
            let raw = String(html[insideStart ..< tagEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = html.index(after: tagEnd)

            if raw.hasPrefix("!") || raw.hasPrefix("?") { continue }
            if raw.hasPrefix("/") {
                let closingName = raw.dropFirst().prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
                if let match = stack.lastIndex(where: { $0.name == closingName }), match > 0 {
                    stack.removeSubrange((match + 1) ..< stack.count)
                    stack.removeLast()
                }
                continue
            }

            let selfClosing = raw.hasSuffix("/")
            let tagSource = selfClosing ? String(raw.dropLast()) : raw
            let (name, attributes) = parseOpeningTag(tagSource)
            guard !name.isEmpty else { continue }

            if name == "script" || name == "style" {
                let close = "</\(name)>"
                if let range = html.range(of: close, options: [.caseInsensitive], range: cursor ..< html.endIndex) {
                    cursor = range.upperBound
                }
                continue
            }

            if Self.paragraphClosingStarts.contains(name),
               let paragraph = stack.lastIndex(where: { $0.name == "p" }), paragraph > 0 {
                stack.removeSubrange(paragraph ..< stack.count)
            }

            let implicitlyClosed: Set<String>
            switch name {
            case "li": implicitlyClosed = ["li"]
            case "tr": implicitlyClosed = ["tr"]
            case "td", "th": implicitlyClosed = ["td", "th"]
            default: implicitlyClosed = []
            }
            if let match = stack.lastIndex(where: { node in
                guard let openName = node.name else { return false }
                return implicitlyClosed.contains(openName)
            }), match > 0,
               name != "li" || match > (stack.lastIndex(where: { $0.name == "ul" || $0.name == "ol" }) ?? 0) {
                stack.removeSubrange(match ..< stack.count)
            }

            let node = HTMLDOMNode(.element(name, attributes))
            stack.last?.children.append(node)
            if !selfClosing, !Self.voidElements.contains(name) { stack.append(node) }
        }
        return root
    }

    private func endOfTag(startingAt start: String.Index) -> String.Index? {
        var index = html.index(after: start)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private func parseOpeningTag(_ source: String) -> (String, [String: String]) {
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
        let nameStart = index
        while index < source.endIndex, !source[index].isWhitespace, source[index] != "/" {
            index = source.index(after: index)
        }
        let name = source[nameStart ..< index].lowercased()
        var attributes: [String: String] = [:]

        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            guard index < source.endIndex else { break }
            if source[index] == "/" { break }

            let keyStart = index
            while index < source.endIndex,
                  !source[index].isWhitespace,
                  source[index] != "=",
                  source[index] != "/" {
                index = source.index(after: index)
            }
            let key = source[keyStart ..< index].lowercased()
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }

            var value = ""
            if index < source.endIndex, source[index] == "=" {
                index = source.index(after: index)
                while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
                if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index = source.index(after: index)
                    let valueStart = index
                    while index < source.endIndex, source[index] != quote { index = source.index(after: index) }
                    value = String(source[valueStart ..< index]).htmlEntityDecoded
                    if index < source.endIndex { index = source.index(after: index) }
                } else {
                    let valueStart = index
                    while index < source.endIndex, !source[index].isWhitespace, source[index] != "/" {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart ..< index]).htmlEntityDecoded
                }
            }
            if !key.isEmpty { attributes[key] = value }
        }
        return (name, attributes)
    }
}

private struct HTMLDocumentDecoder {
    let customDecoders: [String: HTMLCustomDecoder]
    let policy: HTMLImportPolicy

    private static let blockTags: Set<String> = [
        "p", "div", "section", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "hr", "img", "table", "pre", "video", "audio",
    ]

    func decodeChildren(of parent: HTMLDOMNode) -> [BlockNode] {
        var result: [BlockNode] = []
        var inlineBuffer: [HTMLDOMNode] = []

        func flushInline() {
            let delta = inlineDelta(inlineBuffer).normalized()
            if !delta.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(BlockNode(type: "paragraph", data: ["delta": delta.jsonValue]))
            }
            inlineBuffer.removeAll(keepingCapacity: true)
        }

        for child in parent.children {
            if let name = child.name, let decoder = customDecoders[name] {
                flushInline()
                result.append(contentsOf: decoder(child.customElement))
            } else if let name = child.name, Self.blockTags.contains(name) {
                flushInline()
                result.append(contentsOf: decodeBlock(child))
            } else if child.children.contains(where: { descendant in
                guard let name = descendant.name else { return false }
                return Self.blockTags.contains(name)
            }) {
                // Rich clipboard HTML (notably Google Docs) often wraps all
                // block elements in one formatting tag.
                flushInline()
                result.append(contentsOf: decodeChildren(of: child))
            } else if child.name == "body" || child.name == "html" {
                flushInline()
                result.append(contentsOf: decodeChildren(of: child))
            } else if case let .text(text) = child.kind, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            } else {
                inlineBuffer.append(child)
            }
        }
        flushInline()
        return result
    }

    private func decodeBlock(_ element: HTMLDOMNode) -> [BlockNode] {
        guard let name = element.name else { return [] }
        if let decoder = customDecoders[name] { return decoder(element.customElement) }
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return [BlockNode(type: "heading", data: [
                "delta": inlineDelta(element.children).jsonValue,
                "level": .integer(Int(name.dropFirst()) ?? 1),
            ])]
        case "p":
            let delta = element.children.allSatisfy { child in
                if case let .text(text) = child.kind { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return child.name == "br"
            } ? TextDelta() : inlineDelta(element.children)
            return [BlockNode(type: "paragraph", data: ["delta": delta.jsonValue])]
        case "div", "section":
            if let encoded = element.attributes["data-native-block"],
               let data = Data(base64Encoded: encoded),
               let node = try? JSONDecoder().decode(BlockNode.self, from: data),
               policy.allowedNativeBlockTypes.contains(node.type) {
                return [node]
            }
            if let formula = element.attributes["data-native-formula"] {
                return [.formula(formula)]
            }
            if element.attributes["data-native-columns"] != nil {
                let columns = element.children.compactMap { child -> BlockNode? in
                    guard child.attributes["data-native-column"] != nil else { return nil }
                    return decodeBlock(child).first
                }
                if !columns.isEmpty {
                    return [BlockNode(type: "columns", data: ["column_count": .integer(columns.count)], children: columns)]
                }
            }
            if element.attributes["data-native-column"] != nil {
                let children = decodeChildren(of: element)
                var data: [String: JSONValue] = [:]
                if let width = Double(element.attributes["data-width"] ?? "") { data["width"] = .number(width) }
                return [BlockNode(type: "column", data: data, children: children.isEmpty ? [.paragraph()] : children)]
            }
            if let preview = element.attributes["data-native-link-preview"] {
                return [.linkPreview(url: preview)]
            }
            if let kind = element.attributes["data-native-media"],
               let url = element.attributes["data-url"] {
                return [.media(kind: kind, url: url, title: element.attributes["data-title"] ?? "")]
            }
            if let checkbox = element.descendants(named: "input").first,
               checkbox.attributes["type"]?.lowercased() == "checkbox" {
                let content = element.children.filter { $0 !== checkbox }
                let nested = content.flatMap { child -> [BlockNode] in
                    guard let childName = child.name, Self.blockTags.contains(childName) else { return [] }
                    return decodeBlock(child)
                }
                let inline = content.filter { child in
                    guard let childName = child.name else { return true }
                    return !Self.blockTags.contains(childName)
                }
                return [BlockNode(type: "todo_list", data: [
                    "delta": inlineDelta(inline, ignoring: ["input"]).jsonValue,
                    "checked": .bool(checkbox.attributes.keys.contains("checked")),
                ], children: nested)]
            }
            let nested = decodeChildren(of: element)
            return nested.isEmpty
                ? [BlockNode(type: "paragraph", data: ["delta": inlineDelta(element.children).jsonValue])]
                : nested
        case "ul":
            return decodeList(element, type: "bulleted_list", start: nil)
        case "ol":
            return decodeList(element, type: "numbered_list", start: Int(element.attributes["start"] ?? ""))
        case "blockquote":
            let nestedBlocks = element.children.compactMap { child -> BlockNode? in
                guard let childName = child.name, Self.blockTags.contains(childName) else { return nil }
                return decodeBlock(child).first
            }
            let inline = element.children.filter { child in
                guard let childName = child.name else { return true }
                return !Self.blockTags.contains(childName)
            }
            let delta = inlineDelta(inline)
            if delta.plainText.isEmpty, let first = nestedBlocks.first, let firstDelta = first.delta {
                return [BlockNode(type: "quote", data: ["delta": firstDelta.jsonValue], children: Array(nestedBlocks.dropFirst()))]
            }
            return [BlockNode(type: "quote", data: ["delta": delta.jsonValue], children: nestedBlocks)]
        case "hr":
            return [.divider()]
        case "img":
            guard let source = element.attributes["src"], isSupportedImageSource(source) else {
                return [.paragraph()]
            }
            var image = BlockNode.image(
                url: source,
                align: element.attributes["align"] ?? "center",
                width: Double(element.attributes["width"] ?? ""),
                height: Double(element.attributes["height"] ?? "")
            )
            if let alt = element.attributes["alt"] { image.data["alt"] = .string(alt) }
            return [image]
        case "table":
            return [decodeTable(element)]
        case "pre":
            let code = element.firstDescendant(named: "code")
            let language = code?.attributes["data-language"] ?? code?.attributes["class"]?
                .replacingOccurrences(of: "language-", with: "") ?? ""
            return [.code(code?.allText ?? element.allText, language: language)]
        case "video", "audio":
            let source = element.attributes["src"] ?? element.firstDescendant(named: "source")?.attributes["src"] ?? ""
            guard isSupportedMediaSource(source) else { return [] }
            return [.media(kind: name, url: source, title: element.attributes["title"] ?? "")]
        default:
            return [.paragraph(inlineDelta(element.children).plainText)]
        }
    }

    private func isSupportedImageSource(_ source: String) -> Bool {
        let lowered = source.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        if policy.allowsLocalResources, lowered.hasPrefix("file://") || source.hasPrefix("/") { return true }
        guard lowered.hasPrefix("data:image/"),
              let comma = source.firstIndex(of: ","),
              source[..<comma].lowercased().hasSuffix(";base64"),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...])) else { return false }
        let mediaType = lowered.dropFirst("data:".count).prefix { $0 != ";" }
        let allowedTypes: Set<Substring> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"]
        return allowedTypes.contains(mediaType) && data.count <= policy.maximumDataImageBytes
    }

    private func isSupportedMediaSource(_ source: String) -> Bool {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else { return false }
        if ["http", "https"].contains(scheme) { return true }
        if policy.allowsLocalResources, scheme == "file" { return true }
        return scheme == "data" && source.utf8.count <= policy.maximumDataImageBytes * 2
    }

    private func decodeList(_ list: HTMLDOMNode, type: String, start: Int?) -> [BlockNode] {
        let items = list.children.filter { $0.name == "li" }
        return items.enumerated().map { index, item in
            let nestedLists = item.children.filter { $0.name == "ul" || $0.name == "ol" }
            let inline = item.children.filter { $0.name != "ul" && $0.name != "ol" }
            let children = nestedLists.flatMap { nested in
                decodeList(
                    nested,
                    type: nested.name == "ol" ? "numbered_list" : "bulleted_list",
                    start: Int(nested.attributes["start"] ?? "")
                )
            }
            var data: [String: JSONValue] = ["delta": inlineDelta(inline).jsonValue]
            if type == "numbered_list", let start { data["number"] = .integer(start + index) }
            return BlockNode(type: type, data: data, children: children)
        }
    }

    private func decodeTable(_ table: HTMLDOMNode) -> BlockNode {
        let rows = directTableRows(in: table)
        let parsedRows: [[[BlockNode]]] = rows.map { row in
            row.children.filter { $0.name == "td" || $0.name == "th" }.map { cell in
                let blocks = decodeChildren(of: cell)
                if !blocks.isEmpty { return blocks }
                return [BlockNode(type: "paragraph", data: ["delta": inlineDelta(cell.children).jsonValue])]
            }
        }
        return .table(cellRows: parsedRows)
    }

    private func directTableRows(in parent: HTMLDOMNode) -> [HTMLDOMNode] {
        parent.children.flatMap { child -> [HTMLDOMNode] in
            if child.name == "table" { return [] }
            if child.name == "tr" { return [child] }
            return directTableRows(in: child)
        }
    }

    private func inlineDelta(_ nodes: [HTMLDOMNode], ignoring ignored: Set<String> = []) -> TextDelta {
        var operations: [TextOperation] = []
        for node in nodes { appendInline(node, inherited: [:], ignored: ignored, to: &operations) }
        return TextDelta(operations).normalized()
    }

    private func appendInline(
        _ node: HTMLDOMNode,
        inherited: TextAttributes,
        ignored: Set<String>,
        to operations: inout [TextOperation]
    ) {
        switch node.kind {
        case let .text(text):
            let normalized = text.replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
            if !normalized.isEmpty {
                operations.append(.insert(normalized, attributes: inherited.isEmpty ? nil : inherited))
            }
        case .root:
            for child in node.children { appendInline(child, inherited: inherited, ignored: ignored, to: &operations) }
        case let .element(name, attributes):
            guard !ignored.contains(name) else { return }
            if name == "br" {
                operations.append(.insert("\n", attributes: inherited.isEmpty ? nil : inherited))
                return
            }
            var combined = inherited
            for (key, value) in inlineAttributes(tag: name, htmlAttributes: attributes) {
                combined[key] = value
            }
            for child in node.children { appendInline(child, inherited: combined, ignored: ignored, to: &operations) }
        }
    }

    private func inlineAttributes(tag: String, htmlAttributes: [String: String]) -> TextAttributes {
        var attributes: TextAttributes = [:]
        switch tag {
        case "strong", "b": attributes["bold"] = true
        case "em", "i": attributes["italic"] = true
        case "u": attributes["underline"] = true
        case "s", "del", "strike": attributes["strikethrough"] = true
        case "code": attributes["code"] = true
        case "a":
            if let href = htmlAttributes["href"], isAllowedLink(href) { attributes["href"] = .string(href) }
        default: break
        }
        if let formula = htmlAttributes["data-formula"] { attributes["formula"] = .string(formula) }

        let styles = cssDeclarations(htmlAttributes["style"])
        if tag == "b", styles["font-weight"]?.lowercased() == "normal" { attributes.removeValue(forKey: "bold") }
        if let weight = styles["font-weight"]?.lowercased(), weight == "bold" || (Int(weight) ?? 0) >= 500 {
            attributes["bold"] = true
        }
        if styles["font-style"]?.lowercased() == "italic" { attributes["italic"] = true }
        if let decoration = styles["text-decoration"]?.lowercased() {
            if decoration.contains("underline") { attributes["underline"] = true }
            if decoration.contains("line-through") { attributes["strikethrough"] = true }
        }
        if let color = htmlColor(styles["color"]) { attributes["font_color"] = .string(color) }
        if let color = htmlColor(styles["background-color"] ?? styles["background"]) {
            attributes["bg_color"] = .string(color)
        }
        if let size = styles["font-size"], let number = cssNumber(size) { attributes["font_size"] = .number(number) }
        if let family = styles["font-family"]?.split(separator: ",").first {
            attributes["font_family"] = .string(family.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
        }
        return attributes
    }

    private func isAllowedLink(_ value: String) -> Bool {
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
        return policy.allowedLinkSchemes.contains(scheme)
    }

    private func cssDeclarations(_ style: String?) -> [String: String] {
        guard let style else { return [:] }
        return style.split(separator: ";").reduce(into: [:]) { result, declaration in
            guard let separator = declaration.firstIndex(of: ":") else { return }
            let key = declaration[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }
    }

    private func cssNumber(_ value: String) -> Double? {
        Double(value.prefix { $0.isNumber || $0 == "." || $0 == "-" })
    }

    private func htmlColor(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty,
              !["inherit", "currentcolor", "transparent", "none"].contains(value) else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
            if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
            if value.count == 6 { return "0xff\(value)" }
            if value.count == 8 {
                let alpha = value.suffix(2)
                return "0x\(alpha)\(value.prefix(6))"
            }
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let parts = value[value.index(after: open) ..< close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 3,
                  let red = Int(parts[0]), let green = Int(parts[1]), let blue = Int(parts[2]) else { return nil }
            let alpha: Int
            if parts.count == 4, let opacity = Double(parts[3]) {
                alpha = Int((min(1, max(0, opacity)) * 255).rounded())
            } else {
                alpha = 255
            }
            return String(format: "0x%02x%02x%02x%02x", alpha, red, green, blue)
        }
        let named: [String: String] = [
            "black": "0xff000000", "white": "0xffffffff", "red": "0xffff0000", "green": "0xff008000",
            "blue": "0xff0000ff", "yellow": "0xffffff00", "gray": "0xff808080", "grey": "0xff808080",
        ]
        return named[value]
    }
}

private struct HTMLDocumentEncoder {
    let customEncoders: [String: HTMLCustomEncoder]

    func encode(_ document: BlockDocument) -> String {
        var result = ""
        var index = 0
        let nodes = document.root.children
        while index < nodes.count {
            let node = nodes[index]
            if node.type == "bulleted_list" || node.type == "numbered_list" {
                let type = node.type
                let start = index
                while index < nodes.count, nodes[index].type == type { index += 1 }
                result += encodeList(Array(nodes[start ..< index]), type: type)
            } else {
                result += encodeNode(node)
                index += 1
            }
        }
        return result
    }

    private func encodeNode(_ node: BlockNode) -> String {
        if let custom = customEncoders[node.type], let result = custom(node) { return result }
        switch node.type {
        case "paragraph":
            let content = encodeDelta(node.delta ?? TextDelta()) + node.children.map(encodeNode).joined()
            return content.isEmpty ? "<p><br></p>" : "<p>\(content)</p>"
        case "heading":
            let level = min(6, max(1, node.data["level"]?.intValue ?? 1))
            return "<h\(level)>\(encodeDelta(node.delta ?? TextDelta()))\(node.children.map(encodeNode).joined())</h\(level)>"
        case "todo_list":
            let checked = node.data["checked"]?.boolValue == true ? " checked" : ""
            return "<div><input type=\"checkbox\"\(checked)>\(encodeDelta(node.delta ?? TextDelta()))\(node.children.map(encodeNode).joined())</div>"
        case "quote":
            return "<blockquote>\(encodeDelta(node.delta ?? TextDelta()))\(node.children.map(encodeNode).joined())</blockquote>"
        case "divider":
            return "<hr>"
        case "image":
            guard let url = node.data["url"]?.stringValue else { return "" }
            var attributes = " src=\"\(url.htmlAttributeEscaped)\""
            if let width = node.data["width"]?.doubleValue { attributes += " width=\"\(formatNumber(width))\"" }
            if let height = node.data["height"]?.doubleValue { attributes += " height=\"\(formatNumber(height))\"" }
            if let align = node.data["align"]?.stringValue { attributes += " align=\"\(align.htmlAttributeEscaped)\"" }
            if let alt = node.data["alt"]?.stringValue { attributes += " alt=\"\(alt.htmlAttributeEscaped)\"" }
            if let title = node.data["title"]?.stringValue { attributes += " title=\"\(title.htmlAttributeEscaped)\"" }
            return "<img\(attributes)>"
        case "table":
            return encodeTable(node)
        case "code":
            let language = node.data["language"]?.stringValue ?? ""
            return "<pre><code data-language=\"\(language.htmlAttributeEscaped)\">\((node.delta?.plainText ?? "").htmlTextEscaped)</code></pre>"
        case "nbe/formula":
            let formula = node.delta?.plainText ?? node.data["formula"]?.stringValue ?? ""
            return "<div data-native-formula=\"\(formula.htmlAttributeEscaped)\">\(formula.htmlTextEscaped)</div>"
        case "columns":
            let content = node.children.map(encodeNode).joined()
            return "<div data-native-columns=\"\(node.children.count)\">\(content)</div>"
        case "column":
            let width = node.data["width"]?.doubleValue.map { " data-width=\"\(formatNumber($0))\"" } ?? ""
            return "<div data-native-column\(width)>\(node.children.map(encodeNode).joined())</div>"
        case "link_preview":
            guard let url = node.data["url"]?.stringValue else { return "" }
            return "<div data-native-link-preview=\"\(url.htmlAttributeEscaped)\"><a href=\"\(url.htmlAttributeEscaped)\">\(url.htmlTextEscaped)</a></div>"
        case "nbe/media":
            guard let kind = node.data["kind"]?.stringValue,
                  let url = node.data["url"]?.stringValue else { return "" }
            if ["video", "audio"].contains(kind) {
                return "<\(kind) controls src=\"\(url.htmlAttributeEscaped)\"></\(kind)>"
            }
            let title = node.data["title"]?.stringValue ?? ""
            return "<div data-native-media=\"\(kind.htmlAttributeEscaped)\" data-url=\"\(url.htmlAttributeEscaped)\" data-title=\"\(title.htmlAttributeEscaped)\">\(title.htmlTextEscaped)</div>"
        case "nbe/plugin", "nbe/database", "nbe/child_page", "nbe/page_reference":
            return encodeNativeBlock(node)
        case "nbe/html":
            return node.data["html"]?.stringValue ?? ""
        default:
            return ""
        }
    }

    private func encodeList(_ nodes: [BlockNode], type: String) -> String {
        let tag = type == "numbered_list" ? "ol" : "ul"
        let start: String
        if type == "numbered_list", let number = nodes.first?.data["number"]?.intValue {
            start = " start=\"\(number)\""
        } else {
            start = ""
        }
        let items = nodes.map { node in
            let nested = encode(node.childrenAsDocument)
            return "<li>\(encodeDelta(node.delta ?? TextDelta()))\(nested)</li>"
        }.joined()
        return "<\(tag)\(start)>\(items)</\(tag)>"
    }

    private func encodeTable(_ table: BlockNode) -> String {
        let rows = table.data["rowsLen"]?.intValue ?? 0
        let columns = table.data["colsLen"]?.intValue ?? 0
        var cells: [String: BlockNode] = [:]
        for cell in table.children {
            guard let row = cell.data["rowPosition"]?.intValue,
                  let column = cell.data["colPosition"]?.intValue else { continue }
            cells["\(row):\(column)"] = cell
        }
        let content = (0 ..< rows).map { row in
            let columnsHTML = (0 ..< columns).map { column in
                let cell = cells["\(row):\(column)"]
                return "<td>\(cell?.children.map(encodeNode).joined() ?? "")</td>"
            }.joined()
            return "<tr>\(columnsHTML)</tr>"
        }.joined()
        return "<table>\(content)</table>"
    }

    private func encodeDelta(_ delta: TextDelta) -> String {
        delta.operations.compactMap { operation -> String? in
            guard case let .insert(text, rawAttributes) = operation else { return nil }
            let escaped = text.htmlTextEscaped.replacingOccurrences(of: "\n", with: "<br>")
            let attributes = rawAttributes ?? [:]
            if let formula = attributes["formula"]?.stringValue {
                return "<span data-formula=\"\(formula.htmlAttributeEscaped)\">\(escaped)</span>"
            }
            if let href = attributes["href"]?.stringValue {
                var nested = escaped
                nested = wrapSemanticAttributes(nested, attributes: attributes, excludingHref: true)
                return "<a href=\"\(href.htmlAttributeEscaped)\">\(nested)</a>"
            }
            return wrapSemanticAttributes(escaped, attributes: attributes, excludingHref: false)
        }.joined()
    }

    private func wrapSemanticAttributes(
        _ input: String,
        attributes: TextAttributes,
        excludingHref: Bool
    ) -> String {
        var text = input
        let semanticCount = ["bold", "italic", "underline", "strikethrough", "code"]
            .filter { attributes[$0]?.boolValue == true }.count
        let hasStyle = attributes["font_color"] != nil || attributes["bg_color"] != nil ||
            attributes["font_size"] != nil || attributes["font_family"] != nil
        let relevantCount = semanticCount + (excludingHref ? 0 : (attributes["href"] == nil ? 0 : 1))

        if !hasStyle, relevantCount == 1 {
            if attributes["bold"]?.boolValue == true { return "<strong>\(text)</strong>" }
            if attributes["italic"]?.boolValue == true { return "<i>\(text)</i>" }
            if attributes["underline"]?.boolValue == true { return "<u>\(text)</u>" }
            if attributes["strikethrough"]?.boolValue == true { return "<del>\(text)</del>" }
            if attributes["code"]?.boolValue == true { return "<code>\(text)</code>" }
        }

        var styles: [String] = []
        if attributes["bold"]?.boolValue == true { styles.append("font-weight: bold") }
        if attributes["italic"]?.boolValue == true { styles.append("font-style: italic") }
        var decorations: [String] = []
        if attributes["underline"]?.boolValue == true { decorations.append("underline") }
        if attributes["strikethrough"]?.boolValue == true { decorations.append("line-through") }
        if !decorations.isEmpty { styles.append("text-decoration: \(decorations.joined(separator: " "))") }
        if let color = attributes["font_color"]?.stringValue.flatMap(cssColor) { styles.append("color: \(color)") }
        if let color = attributes["bg_color"]?.stringValue.flatMap(cssColor) { styles.append("background-color: \(color)") }
        if let size = attributes["font_size"]?.doubleValue { styles.append("font-size: \(formatNumber(size))px") }
        if let family = attributes["font_family"]?.stringValue { styles.append("font-family: \(family)") }
        if attributes["code"]?.boolValue == true { text = "<code>\(text)</code>" }
        return styles.isEmpty ? text : "<span style=\"\(styles.joined(separator: "; ").htmlAttributeEscaped)\">\(text)</span>"
    }

    private func cssColor(_ value: String) -> String? {
        let lowered = value.lowercased()
        guard lowered.hasPrefix("0x"), lowered.count == 10 else { return nil }
        let alpha = lowered.dropFirst(2).prefix(2)
        let rgb = lowered.suffix(6)
        guard let alphaValue = Int(alpha, radix: 16) else { return nil }
        if alphaValue == 255 { return "#\(rgb)" }
        return "rgba(\(Int(rgb.prefix(2), radix: 16) ?? 0), \(Int(rgb.dropFirst(2).prefix(2), radix: 16) ?? 0), \(Int(rgb.suffix(2), radix: 16) ?? 0), \(formatNumber(Double(alphaValue) / 255)))"
    }

    private func encodeNativeBlock(_ node: BlockNode) -> String {
        guard let data = try? JSONEncoder().encode(node) else { return "" }
        let label = node.data["display_name"]?.stringValue ?? node.data["title"]?.stringValue ?? node.type
        return "<div data-native-block=\"\(data.base64EncodedString())\">\(label.htmlTextEscaped)</div>"
    }

    private func formatNumber(_ number: Double) -> String {
        number.rounded() == number
            ? String(Int(number))
            : String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

private extension BlockNode {
    var childrenAsDocument: BlockDocument {
        BlockDocument(root: BlockNode(type: "page", children: children))
    }
}

private extension String {
    var htmlTextEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var htmlAttributeEscaped: String {
        htmlTextEscaped.replacingOccurrences(of: "\"", with: "&quot;")
    }

    var htmlEntityDecoded: String {
        var output = ""
        var cursor = startIndex
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "hellip": "…", "ndash": "–", "mdash": "—",
        ]
        while cursor < endIndex {
            guard self[cursor] == "&", let end = self[cursor...].firstIndex(of: ";"), distance(from: cursor, to: end) <= 12 else {
                output.append(self[cursor])
                cursor = index(after: cursor)
                continue
            }
            let entity = String(self[index(after: cursor) ..< end])
            let scalar: UnicodeScalar?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init)
            } else {
                scalar = nil
            }
            if let scalar {
                output.unicodeScalars.append(scalar)
            } else if let character = named[entity.lowercased()] {
                output.append(character)
            } else {
                output += String(self[cursor ... end])
            }
            cursor = index(after: end)
        }
        return output
    }
}
