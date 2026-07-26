import Foundation
import NativeBlockEditorCore

public enum NotionEnhancedMarkdownError: Error, Equatable, Sendable {
    case unsafeNativeDirective
    case malformedExtension(String)
    case unknownBlock(String)
}

extension NotionEnhancedMarkdownError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeNativeDirective:
            "Raw native-block directives are not accepted through the agent Markdown surface."
        case let .malformedExtension(tag):
            "The enhanced Markdown extension is malformed: \(tag)"
        case let .unknownBlock(id):
            "The referenced unknown block could not be resolved: \(id)"
        }
    }
}

/// Agent-facing Markdown modeled after Notion's enhanced Markdown surface.
///
/// The internal AppFlowy-shaped JSON never crosses this boundary. Native blocks
/// are exposed as readable XML-like references, while unknown blocks are opaque
/// references that can round-trip only when they already exist in the page.
public struct NotionEnhancedMarkdownCodec: Sendable {
    public init() {}

    public func encode(_ document: BlockDocument) -> String {
        document.root.children.map { encodeNode($0, indentation: "") }.joined(separator: "\n")
    }

    public func decode(
        _ markdown: String,
        pageID: String,
        workspace: PageWorkspace,
        previousDocument: BlockDocument? = nil
    ) throws -> BlockDocument {
        guard !markdown.contains("<!-- native-block:") else {
            throw NotionEnhancedMarkdownError.unsafeNativeDirective
        }
        let expanded = try preprocess(
            markdown,
            pageID: pageID,
            workspace: workspace,
            previousDocument: previousDocument
        )
        return try AppFlowyMarkdownCodec(nativeDirectivePolicy: .trusted).decode(expanded)
    }

    private func encodeNode(_ node: BlockNode, indentation: String) -> String {
        switch node.type {
        case "nbe/child_page", "nbe/page_reference":
            let pageID = node.data["page_id"]?.stringValue ?? ""
            let title = node.data["title"]?.stringValue ?? "Untitled"
            return "\(indentation)<page url=\"native-editor://page/\(xmlEscape(pageID))\">\(xmlEscape(title))</page>"
        case "nbe/database":
            let blockID = node.stableBlockID ?? "unassigned"
            let title = node.data["title"]?.stringValue ?? "Database"
            return "\(indentation)<database url=\"native-editor://block/\(xmlEscape(blockID))\" inline=\"true\">\(xmlEscape(title))</database>"
        case "columns":
            var lines = ["\(indentation)<columns>"]
            for column in node.children where column.type == "column" {
                lines.append("\(indentation)\t<column>")
                lines.append(contentsOf: column.children.map { encodeNode($0, indentation: indentation + "\t\t") })
                lines.append("\(indentation)\t</column>")
            }
            lines.append("\(indentation)</columns>")
            return lines.joined(separator: "\n")
        case "nbe/media":
            let kind = normalizedMediaKind(node.data["kind"]?.stringValue)
            let url = node.data["url"]?.stringValue ?? ""
            let caption = node.data["title"]?.stringValue ?? node.data["caption"]?.stringValue ?? ""
            return "\(indentation)<\(kind) src=\"\(xmlEscape(url))\">\(xmlEscape(caption))</\(kind)>"
        case "link_preview":
            let url = node.data["url"]?.stringValue ?? ""
            let title = node.data["title"]?.stringValue ?? url
            return "\(indentation)[\(title)](\(url))"
        case "nbe/plugin", "nbe/html":
            return unknownTag(for: node, indentation: indentation)
        default:
            if Self.standardTypes.contains(node.type) {
                let document = BlockDocument(root: BlockNode(type: "page", children: [node]))
                return documentToMarkdown(document)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { indentation + $0 }
                    .joined(separator: "\n")
            }
            return unknownTag(for: node, indentation: indentation)
        }
    }

    private func unknownTag(for node: BlockNode, indentation: String) -> String {
        let id = node.stableBlockID ?? "unassigned"
        return "\(indentation)<unknown url=\"native-editor://block/\(xmlEscape(id))\" alt=\"\(xmlEscape(node.type))\"/>"
    }

    private func preprocess(
        _ markdown: String,
        pageID: String,
        workspace: PageWorkspace,
        previousDocument: BlockDocument?
    ) throws -> String {
        let lines = normalizedLines(markdown)
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "<columns>" {
                let result = try parseColumns(
                    lines,
                    startingAt: index,
                    pageID: pageID,
                    workspace: workspace,
                    previousDocument: previousDocument
                )
                output.append(try nativeDirective(result.node))
                index = result.nextIndex
                continue
            }
            if trimmed == "<empty-block/>" {
                output.append(try nativeDirective(.paragraph()))
                index += 1
                continue
            }
            if trimmed.hasPrefix("<page ") {
                guard let url = attribute("url", in: trimmed),
                      let targetID = self.pageID(from: url),
                      let title = enclosedText(in: trimmed, tag: "page") else {
                    throw NotionEnhancedMarkdownError.malformedExtension(trimmed)
                }
                let isChild = workspace.item(id: targetID)?.parentID == pageID
                let node = isChild
                    ? BlockNode.childPage(pageID: targetID, title: xmlUnescape(title))
                    : BlockNode.pageReference(pageID: targetID, title: xmlUnescape(title))
                output.append(try nativeDirective(node))
                index += 1
                continue
            }
            if trimmed.hasPrefix("<database ") {
                guard let url = attribute("url", in: trimmed),
                      let title = enclosedText(in: trimmed, tag: "database") else {
                    throw NotionEnhancedMarkdownError.malformedExtension(trimmed)
                }
                let blockID = blockID(from: url)
                let node = blockID.flatMap { existingNode(id: $0, in: previousDocument) }
                    ?? .database(title: xmlUnescape(title), columns: ["Name"], rows: [])
                output.append(try nativeDirective(node))
                index += 1
                continue
            }
            if let media = try parseMedia(trimmed) {
                output.append(try nativeDirective(media))
                index += 1
                continue
            }
            if trimmed.hasPrefix("<unknown ") {
                guard let url = attribute("url", in: trimmed), let id = blockID(from: url),
                      let node = existingNode(id: id, in: previousDocument) else {
                    throw NotionEnhancedMarkdownError.unknownBlock(attribute("url", in: trimmed) ?? trimmed)
                }
                output.append(try nativeDirective(node))
                index += 1
                continue
            }
            output.append(lines[index])
            index += 1
        }
        return separateTopLevelTextBlocks(output).joined(separator: "\n")
    }

    private func parseColumns(
        _ lines: [String],
        startingAt start: Int,
        pageID: String,
        workspace: PageWorkspace,
        previousDocument: BlockDocument?
    ) throws -> (node: BlockNode, nextIndex: Int) {
        var index = start + 1
        var columns: [[BlockNode]] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "</columns>" {
                guard !columns.isEmpty else {
                    throw NotionEnhancedMarkdownError.malformedExtension("<columns>")
                }
                return (.columns(columns), index + 1)
            }
            guard trimmed == "<column>" else {
                throw NotionEnhancedMarkdownError.malformedExtension(lines[index])
            }
            index += 1
            var content: [String] = []
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces) != "</column>" {
                content.append(removingOneIndentationLevel(from: lines[index]))
                index += 1
            }
            guard index < lines.count else {
                throw NotionEnhancedMarkdownError.malformedExtension("<column>")
            }
            let columnDocument = try decode(
                content.joined(separator: "\n"),
                pageID: pageID,
                workspace: workspace,
                previousDocument: previousDocument
            )
            columns.append(columnDocument.root.children)
            index += 1
        }
        throw NotionEnhancedMarkdownError.malformedExtension("<columns>")
    }

    private func parseMedia(_ line: String) throws -> BlockNode? {
        for tag in ["audio", "video", "file", "pdf"] where line.hasPrefix("<\(tag) ") {
            guard let url = attribute("src", in: line), let text = enclosedText(in: line, tag: tag) else {
                throw NotionEnhancedMarkdownError.malformedExtension(line)
            }
            return .media(kind: tag, url: xmlUnescape(url), title: xmlUnescape(text))
        }
        return nil
    }

    private func nativeDirective(_ node: BlockNode) throws -> String {
        let data = try JSONEncoder().encode(node)
        return "<!-- native-block:\(data.base64EncodedString()) -->"
    }

    private func existingNode(id: String, in document: BlockDocument?) -> BlockNode? {
        document?.flattenedNodes().first { $0.node.stableBlockID == id }?.node
    }

    private func normalizedLines(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Notion enhanced Markdown uses one physical line per adjacent text block;
    /// line breaks inside one block are represented by `<br>`. The AppFlowy
    /// Markdown parser accepts CommonMark-style wrapped paragraphs, so blank
    /// separators are inserted internally before parsing and never exposed to
    /// the agent.
    private func separateTopLevelTextBlocks(_ lines: [String]) -> [String] {
        var result: [String] = []
        var codeFence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = codeFence {
                result.append(line)
                if trimmed.hasPrefix(fence) { codeFence = nil }
                continue
            }
            if trimmed.hasPrefix("```") {
                codeFence = "```"
                result.append(line)
                continue
            }
            if trimmed == "$$" {
                codeFence = "$$"
                result.append(line)
                continue
            }
            result.append(line)
            guard !line.hasPrefix("\t"), !line.hasPrefix(" "), isTopLevelTextLine(trimmed) else { continue }
            result.append("")
        }
        return result
    }

    private func isTopLevelTextLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let structuralPrefixes = [
            "#", ">", "- ", "* ", "+ ", "|", "<", "<!--", "![",
        ]
        if structuralPrefixes.contains(where: line.hasPrefix) { return false }
        if line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return false }
        return true
    }

    private func removingOneIndentationLevel(from line: String) -> String {
        if line.hasPrefix("\t\t") { return String(line.dropFirst(2)) }
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        return line
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let marker = "\(name)=\""
        guard let start = tag.range(of: marker) else { return nil }
        let remainder = tag[start.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    private func enclosedText(in line: String, tag: String) -> String? {
        guard let openEnd = line.firstIndex(of: ">"),
              let closeStart = line.range(of: "</\(tag)>", options: .backwards)?.lowerBound,
              openEnd < closeStart else { return nil }
        return String(line[line.index(after: openEnd) ..< closeStart])
    }

    private func pageID(from url: String) -> String? {
        guard let components = URLComponents(string: xmlUnescape(url)), components.scheme == "native-editor" else {
            return nil
        }
        if components.host == "page" { return components.path.split(separator: "/").first.map(String.init) }
        let segments = components.path.split(separator: "/")
        guard let marker = segments.firstIndex(of: "page"), segments.indices.contains(marker + 1) else { return nil }
        return String(segments[marker + 1])
    }

    private func blockID(from url: String) -> String? {
        guard let components = URLComponents(string: xmlUnescape(url)), components.scheme == "native-editor" else {
            return nil
        }
        if components.host == "block" { return components.path.split(separator: "/").first.map(String.init) }
        return nil
    }

    private func normalizedMediaKind(_ value: String?) -> String {
        switch value?.lowercased() {
        case "audio": "audio"
        case "file": "file"
        case "pdf": "pdf"
        default: "video"
        }
    }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func xmlUnescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let standardTypes: Set<String> = [
        "paragraph", "heading", "quote", "divider", "code", "nbe/formula",
        "bulleted_list", "numbered_list", "todo_list", "image", "table",
    ]
}
