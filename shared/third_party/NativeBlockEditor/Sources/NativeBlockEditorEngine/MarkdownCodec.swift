import Foundation

public enum MarkdownNativeDirectivePolicy: Sendable {
    /// Accept only the built-in non-executable extension nodes and force safe
    /// network/resource settings on their payloads.
    case safeExtensions
    case disabled
    /// Accept any encoded node. Use only for content from a trusted source.
    case trusted
}

public struct AppFlowyMarkdownCodec: Sendable {
    public var nativeDirectivePolicy: MarkdownNativeDirectivePolicy

    public init(nativeDirectivePolicy: MarkdownNativeDirectivePolicy = .safeExtensions) {
        self.nativeDirectivePolicy = nativeDirectivePolicy
    }

    public func decode(_ markdown: String) throws -> BlockDocument {
        var parser = MarkdownDocumentParser(markdown: markdown, nativeDirectivePolicy: nativeDirectivePolicy)
        let document = BlockDocument(root: BlockNode(type: "page", children: parser.parse()))
        try document.validate()
        return document
    }

    public func encode(_ document: BlockDocument) -> String {
        MarkdownDocumentEncoder().encode(document)
    }
}

public func markdownToDocument(_ markdown: String) throws -> BlockDocument {
    try AppFlowyMarkdownCodec().decode(markdown)
}

public func documentToMarkdown(_ document: BlockDocument) -> String {
    AppFlowyMarkdownCodec().encode(document)
}

private struct MarkdownDocumentParser {
    private let lines: [String]
    private let nativeDirectivePolicy: MarkdownNativeDirectivePolicy
    private var index = 0

    init(markdown: String, nativeDirectivePolicy: MarkdownNativeDirectivePolicy) {
        lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        self.nativeDirectivePolicy = nativeDirectivePolicy
    }

    mutating func parse() -> [BlockNode] {
        var nodes: [BlockNode] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let native = decodeNativeDirective(line) {
                nodes.append(native)
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                nodes.append(parseCodeFence())
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "$$" {
                nodes.append(parseFormulaFence())
                continue
            }

            if let heading = parseHeading(line) {
                nodes.append(heading)
                index += 1
                continue
            }

            if isDivider(line) {
                nodes.append(.divider())
                index += 1
                continue
            }

            if let image = parseStandaloneImage(line) {
                nodes.append(image)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                nodes.append(parseQuote())
                continue
            }

            if isTableStart(at: index) {
                nodes.append(parseTable())
                continue
            }

            if listRecord(line) != nil {
                nodes.append(contentsOf: parseListBlock())
                continue
            }

            nodes.append(parseParagraph())
        }
        return nodes
    }

    private mutating func parseCodeFence() -> BlockNode {
        let fenceLength = lines[index].prefix { $0 == "`" }.count
        let language = String(lines[index].dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
        index += 1
        var content: [String] = []
        while index < lines.count, !isClosingCodeFence(lines[index], minimumLength: fenceLength) {
            content.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        return .code(content.joined(separator: "\n"), language: language)
    }

    private func isClosingCodeFence(_ line: String, minimumLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= minimumLength && trimmed.allSatisfy { $0 == "`" }
    }

    private mutating func parseFormulaFence() -> BlockNode {
        index += 1
        var content: [String] = []
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "$$" {
            content.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        return .formula(content.joined(separator: "\n"))
    }

    private func parseHeading(_ line: String) -> BlockNode? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        let text = String(trimmed.dropFirst(hashes + 1))
        return BlockNode(type: "heading", data: [
            "level": .integer(hashes),
            "delta": MarkdownInlineCodec.decode(text).jsonValue,
        ])
    }

    private mutating func parseQuote() -> BlockNode {
        var quoteLines: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return BlockNode(type: "quote", data: [
            "delta": MarkdownInlineCodec.decode(quoteLines.joined(separator: "\n")).jsonValue,
        ])
    }

    private mutating func parseParagraph() -> BlockNode {
        var content = [lines[index].trimmingCharacters(in: .whitespaces)]
        index += 1
        while index < lines.count {
            let candidate = lines[index]
            guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(candidate, at: index) else { break }
            content.append(candidate.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return BlockNode(type: "paragraph", data: [
            "delta": MarkdownInlineCodec.decode(content.joined(separator: "\n")).jsonValue,
        ])
    }

    private func startsBlock(_ line: String, at lineIndex: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("```") || trimmed == "$$" || parseHeading(line) != nil ||
            isDivider(line) || parseStandaloneImage(line) != nil || trimmed.hasPrefix(">") ||
            listRecord(line) != nil || isTableStart(at: lineIndex) || decodeNativeDirective(line) != nil
    }

    private struct ListRecord {
        var indent: Int
        var marker: String
        var text: String
    }

    private func listRecord(_ line: String) -> ListRecord? {
        let pattern = #"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#
        guard let groups = line.captureGroups(pattern: pattern), groups.count == 3 else { return nil }
        return ListRecord(indent: groups[0].count, marker: groups[1], text: groups[2])
    }

    private mutating func parseListBlock() -> [BlockNode] {
        var records: [ListRecord] = []
        while index < lines.count, let record = listRecord(lines[index]) {
            records.append(record)
            index += 1
        }
        var recordIndex = 0
        return buildList(records, index: &recordIndex, indent: records.first?.indent ?? 0)
    }

    private func buildList(_ records: [ListRecord], index: inout Int, indent: Int) -> [BlockNode] {
        var result: [BlockNode] = []
        while index < records.count {
            let record = records[index]
            if record.indent < indent { break }
            if record.indent > indent {
                if !result.isEmpty {
                    result[result.count - 1].children.append(contentsOf: buildList(records, index: &index, indent: record.indent))
                    continue
                }
                break
            }

            index += 1
            let todo = record.text.captureGroups(pattern: #"^\[([ xX])\]\s*(.*)$"#)
            var node: BlockNode
            if record.marker == "-", let todo, todo.count == 2 {
                node = BlockNode(type: "todo_list", data: [
                    "checked": .bool(todo[0].lowercased() == "x"),
                    "delta": MarkdownInlineCodec.decode(todo[1]).jsonValue,
                ])
            } else if let number = Int(record.marker.prefix { $0.isNumber }) {
                node = BlockNode(type: "numbered_list", data: [
                    "number": .integer(number),
                    "delta": MarkdownInlineCodec.decode(record.text).jsonValue,
                ])
            } else {
                node = BlockNode(type: "bulleted_list", data: [
                    "delta": MarkdownInlineCodec.decode(record.text).jsonValue,
                ])
            }

            if index < records.count, records[index].indent > indent {
                node.children = buildList(records, index: &index, indent: records[index].indent)
            }
            result.append(node)
        }
        return result
    }

    private func isTableStart(at lineIndex: Int) -> Bool {
        guard lineIndex + 1 < lines.count, lines[lineIndex].contains("|") else { return false }
        let separator = lines[lineIndex + 1].trimmingCharacters(in: .whitespaces)
        return separator.range(of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil
    }

    private mutating func parseTable() -> BlockNode {
        let header = splitTableRow(lines[index])
        index += 2
        var rows = [header]
        while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(splitTableRow(lines[index]))
            index += 1
        }
        let width = rows.map(\.count).max() ?? 0
        let blocks = rows.map { row in
            (0 ..< width).map { column in
                BlockNode(
                    type: "paragraph",
                    data: ["delta": MarkdownInlineCodec.decode(column < row.count ? row[column] : "").jsonValue]
                )
            }
        }
        return .table(rows: blocks)
    }

    private func splitTableRow(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        var cells = [""]
        var escaped = false
        for character in value {
            if character == "\\" {
                cells[cells.count - 1].append(character)
                escaped.toggle()
            } else if character == "|", !escaped {
                cells.append("")
                escaped = false
            } else {
                cells[cells.count - 1].append(character)
                escaped = false
            }
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseStandaloneImage(_ line: String) -> BlockNode? {
        guard let groups = line.trimmingCharacters(in: .whitespaces)
            .captureGroups(pattern: #"^!\[([^\]]*)\]\(([^\s\)]+)(?:\s+\"([^\"]*)\")?\)$"#),
              groups.count >= 2 else { return nil }
        var node = BlockNode.image(url: groups[1])
        node.data["alt"] = .string(groups[0])
        if groups.count > 2, !groups[2].isEmpty { node.data["title"] = .string(groups[2]) }
        return node
    }

    private func isDivider(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(
            of: #"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$"#,
            options: .regularExpression
        ) != nil
    }

    private func decodeNativeDirective(_ line: String) -> BlockNode? {
        let prefix = "<!-- native-block:"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(" -->") else { return nil }
        let encoded = trimmed.dropFirst(prefix.count).dropLast(4)
        guard let data = Data(base64Encoded: String(encoded)),
              var node = try? JSONDecoder().decode(BlockNode.self, from: data) else { return nil }
        switch nativeDirectivePolicy {
        case .disabled:
            return nil
        case .trusted:
            return node
        case .safeExtensions:
            let allowed: Set<String> = [
                "nbe/formula", "nbe/media", "nbe/plugin", "nbe/database", "nbe/html", "columns", "column", "link_preview",
                "nbe/child_page", "nbe/page_reference",
            ]
            guard allowed.contains(node.type) else { return nil }
            guard sanitizeNativeDirective(&node) else { return nil }
            return node
        }
    }

    private func sanitizeNativeDirective(_ node: inout BlockNode) -> Bool {
        if node.type == "nbe/html" { node.data["allow_network"] = .bool(false) }
        if node.type == "nbe/media" || node.type == "link_preview" {
            guard let value = node.data["url"]?.stringValue,
                  let scheme = URLComponents(string: value)?.scheme?.lowercased(),
                  ["http", "https", "data"].contains(scheme) else { return false }
        }
        for index in node.children.indices {
            if !sanitizeNativeDirective(&node.children[index]) { return false }
        }
        return true
    }
}

private enum MarkdownInlineCodec {
    static func decode(_ markdown: String) -> TextDelta {
        TextDelta(parse(markdown, attributes: [:])).normalized()
    }

    private static func parse(_ source: String, attributes: TextAttributes) -> [TextOperation] {
        var result: [TextOperation] = []
        var index = source.startIndex
        var plain = ""

        func appendPlain() {
            guard !plain.isEmpty else { return }
            result.append(.insert(plain, attributes: attributes.isEmpty ? nil : attributes))
            plain = ""
        }

        while index < source.endIndex {
            if source[index] == "\\", source.index(after: index) < source.endIndex {
                plain.append(source[source.index(after: index)])
                index = source.index(index, offsetBy: 2)
                continue
            }

            if let match = delimited(source, at: index, opener: "***", closer: "***") {
                appendPlain()
                var nested = attributes
                nested["bold"] = true
                nested["italic"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "**", closer: "**") {
                appendPlain()
                var nested = attributes
                nested["bold"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "~~", closer: "~~") {
                appendPlain()
                var nested = attributes
                nested["strikethrough"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "<u>", closer: "</u>") {
                appendPlain()
                var nested = attributes
                nested["underline"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "`", closer: "`") {
                appendPlain()
                var nested = attributes
                nested["code"] = true
                result.append(.insert(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "_", closer: "_") {
                appendPlain()
                var nested = attributes
                nested["italic"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if let match = delimited(source, at: index, opener: "*", closer: "*") {
                appendPlain()
                var nested = attributes
                nested["italic"] = true
                result.append(contentsOf: parse(match.content, attributes: nested))
                index = match.end
                continue
            }
            if source[index] == "[",
               let closeLabel = source[index...].firstIndex(of: "]"),
               source.index(after: closeLabel) < source.endIndex,
               source[source.index(after: closeLabel)] == "(",
               let closeURL = source[source.index(closeLabel, offsetBy: 2)...].firstIndex(of: ")") {
                appendPlain()
                let label = String(source[source.index(after: index) ..< closeLabel])
                let url = String(source[source.index(closeLabel, offsetBy: 2) ..< closeURL])
                var nested = attributes
                nested["href"] = .string(url)
                result.append(contentsOf: parse(label, attributes: nested))
                index = source.index(after: closeURL)
                continue
            }
            if let match = delimited(source, at: index, opener: "$", closer: "$"), !match.content.isEmpty {
                appendPlain()
                var nested = attributes
                nested["formula"] = .string(match.content)
                result.append(.insert("$", attributes: nested))
                index = match.end
                continue
            }

            plain.append(source[index])
            index = source.index(after: index)
        }
        appendPlain()
        return result
    }

    private static func delimited(
        _ source: String,
        at index: String.Index,
        opener: String,
        closer: String
    ) -> (content: String, end: String.Index)? {
        guard source[index...].hasPrefix(opener) else { return nil }
        let contentStart = source.index(index, offsetBy: opener.count)
        guard contentStart < source.endIndex,
              let closing = source.range(of: closer, range: contentStart ..< source.endIndex) else { return nil }
        return (String(source[contentStart ..< closing.lowerBound]), closing.upperBound)
    }

    static func encode(_ delta: TextDelta) -> String {
        delta.operations.compactMap { operation -> String? in
            guard case let .insert(raw, rawAttributes) = operation else { return nil }
            let attributes = rawAttributes ?? [:]
            if let formula = attributes["formula"]?.stringValue { return "$\(formula)$" }
            var text = escape(raw)
            if attributes["code"]?.boolValue == true { text = "`\(text)`" }
            if attributes["underline"]?.boolValue == true { text = "<u>\(text)</u>" }
            if attributes["strikethrough"]?.boolValue == true { text = "~~\(text)~~" }
            if let href = attributes["href"]?.stringValue { text = "[\(text)](\(href))" }
            let bold = attributes["bold"]?.boolValue == true
            let italic = attributes["italic"]?.boolValue == true
            if bold, italic { text = "***\(text)***" }
            else if bold { text = "**\(text)**" }
            else if italic { text = "_\(text)_" }
            return text
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        let reserved = CharacterSet(charactersIn: #"\*_~`$[]<>"#)
        return text.unicodeScalars.reduce(into: "") { output, scalar in
            if reserved.contains(scalar) { output.append("\\") }
            output.unicodeScalars.append(scalar)
        }
    }
}

private struct MarkdownDocumentEncoder {
    func encode(_ document: BlockDocument) -> String {
        document.root.children.map { encodeNode($0, indent: 0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func encodeNode(_ node: BlockNode, indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        switch node.type {
        case "paragraph":
            return prefix + MarkdownInlineCodec.encode(node.delta ?? TextDelta())
        case "heading":
            return prefix + String(repeating: "#", count: min(6, max(1, node.data["level"]?.intValue ?? 1))) +
                " " + MarkdownInlineCodec.encode(node.delta ?? TextDelta())
        case "quote":
            return MarkdownInlineCodec.encode(node.delta ?? TextDelta()).components(separatedBy: "\n")
                .map { prefix + "> " + $0 }.joined(separator: "\n")
        case "divider":
            return prefix + "---"
        case "code":
            let language = node.data["language"]?.stringValue ?? ""
            let content = node.delta?.plainText ?? ""
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: content) + 1))
            return prefix + "\(fence)\(language)\n" + content + "\n\(prefix)\(fence)"
        case "nbe/formula":
            return prefix + "$$\n" + (node.data["formula"]?.stringValue ?? node.delta?.plainText ?? "") + "\n\(prefix)$$"
        case "bulleted_list", "numbered_list", "todo_list":
            let marker: String
            switch node.type {
            case "numbered_list": marker = "\(node.data["number"]?.intValue ?? 1)."
            case "todo_list": marker = node.data["checked"]?.boolValue == true ? "- [x]" : "- [ ]"
            default: marker = "-"
            }
            var output = prefix + marker + " " + MarkdownInlineCodec.encode(node.delta ?? TextDelta())
            if !node.children.isEmpty {
                output += "\n" + node.children.map { encodeNode($0, indent: indent + 2) }.joined(separator: "\n")
            }
            return output
        case "image":
            guard let url = node.data["url"]?.stringValue else { return "" }
            let alt = node.data["alt"]?.stringValue ?? ""
            let title = node.data["title"]?.stringValue.map { " \"\($0)\"" } ?? ""
            return prefix + "![\(alt)](\(url)\(title))"
        case "table":
            return encodeTable(node, prefix: prefix)
        default:
            return encodeNativeDirective(node, prefix: prefix)
        }
    }

    private func encodeTable(_ table: BlockNode, prefix: String) -> String {
        let rows = table.data["rowsLen"]?.intValue ?? 0
        let columns = table.data["colsLen"]?.intValue ?? 0
        guard rows > 0, columns > 0 else { return "" }
        var cells: [String: String] = [:]
        for cell in table.children {
            guard let row = cell.data["rowPosition"]?.intValue,
                  let column = cell.data["colPosition"]?.intValue else { continue }
            let value = cell.children.compactMap { child in
                child.delta.map(MarkdownInlineCodec.encode)
            }.joined(separator: " ")
            cells["\(row):\(column)"] = value.replacingOccurrences(of: "|", with: "\\|")
        }
        var output: [String] = []
        for row in 0 ..< rows {
            let values = (0 ..< columns).map { cells["\(row):\($0)"] ?? "" }
            output.append(prefix + "| " + values.joined(separator: " | ") + " |")
            if row == 0 {
                output.append(prefix + "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
            }
        }
        return output.joined(separator: "\n")
    }

    private func encodeNativeDirective(_ node: BlockNode, prefix: String) -> String {
        guard let data = try? JSONEncoder().encode(node) else { return "" }
        return prefix + "<!-- native-block:\(data.base64EncodedString()) -->"
    }

    private func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

private extension String {
    func captureGroups(pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: self) else { return "" }
            return String(self[swiftRange])
        }
    }
}
