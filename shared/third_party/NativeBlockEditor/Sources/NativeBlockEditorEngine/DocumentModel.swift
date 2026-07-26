import Foundation

public enum DocumentEngineError: Error, Equatable, Sendable {
    case invalidPath(BlockPath)
    case invalidRange(String)
    case invalidDelta(String)
    case invalidDocument(String)
    case invalidOperation(String)
}

extension DocumentEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "Invalid block path: \(path.indices)"
        case let .invalidRange(message): "Invalid range: \(message)"
        case let .invalidDelta(message): "Invalid text delta: \(message)"
        case let .invalidDocument(message): "Invalid document: \(message)"
        case let .invalidOperation(message): "Invalid operation: \(message)"
        }
    }
}

/// An AppFlowy-style path. It encodes as a bare JSON integer array.
public struct BlockPath: Hashable, Sendable, Comparable, ExpressibleByArrayLiteral {
    public var indices: [Int]

    public init(_ indices: [Int] = []) {
        self.indices = indices
    }

    public init(arrayLiteral elements: Int...) {
        indices = elements
    }

    public var isEmpty: Bool { indices.isEmpty }
    public var count: Int { indices.count }
    public var last: Int? { indices.last }
    public var parent: BlockPath { BlockPath(Array(indices.dropLast())) }

    public func appending(_ index: Int) -> BlockPath {
        BlockPath(indices + [index])
    }

    public func nextSibling() throws -> BlockPath {
        guard let last else { throw DocumentEngineError.invalidPath(self) }
        return BlockPath(Array(indices.dropLast()) + [last + 1])
    }

    public static func < (lhs: BlockPath, rhs: BlockPath) -> Bool {
        lhs.indices.lexicographicallyPrecedes(rhs.indices)
    }
}

extension BlockPath: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        indices = try container.decode([Int].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(indices)
    }
}

public struct Position: Codable, Hashable, Sendable {
    public var path: BlockPath
    public var offset: Int

    public init(path: BlockPath, offset: Int = 0) {
        self.path = path
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey { case path, offset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(BlockPath.self, forKey: .path)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

public struct Selection: Codable, Hashable, Sendable {
    public var start: Position
    public var end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }

    public init(path: BlockPath, startOffset: Int, endOffset: Int? = nil) {
        start = Position(path: path, offset: startOffset)
        end = Position(path: path, offset: endOffset ?? startOffset)
    }

    public init(collapsedAt position: Position) {
        start = position
        end = position
    }

    public var isCollapsed: Bool { start == end }
    public var isSingleBlock: Bool { start.path == end.path }
    public var reversed: Selection { Selection(start: end, end: start) }

    /// AppFlowy's selection is directional. `normalized` puts the earlier point first.
    public var normalized: Selection {
        if start.path < end.path || (start.path == end.path && start.offset <= end.offset) {
            return self
        }
        return reversed
    }
}

/// A block node compatible with AppFlowy's `type` / `data` / `children` schema.
/// `id` is deliberately runtime-only and is never serialized.
public struct BlockNode: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var type: String
    public var data: [String: JSONValue]
    public var children: [BlockNode]

    public init(
        type: String,
        data: [String: JSONValue] = [:],
        children: [BlockNode] = [],
        id: UUID = UUID()
    ) {
        self.id = id
        self.type = type
        self.data = data
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case type, data, children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        type = try container.decode(String.self, forKey: .type)
        data = try container.decodeIfPresent([String: JSONValue].self, forKey: .data) ?? [:]
        children = try container.decodeIfPresent([BlockNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        let appFlowyData = data.filter { $0.value != .null }
        if !appFlowyData.isEmpty {
            try container.encode(appFlowyData, forKey: .data)
        }
        if !children.isEmpty {
            try container.encode(children, forKey: .children)
        }
    }

    public var delta: TextDelta? {
        get {
            guard let value = data["delta"] else { return nil }
            return try? TextDelta(jsonValue: value)
        }
        set {
            if let newValue {
                data["delta"] = newValue.jsonValue
            } else {
                data.removeValue(forKey: "delta")
            }
        }
    }

    public static func paragraph(_ text: String = "") -> BlockNode {
        BlockNode(type: "paragraph", data: ["delta": TextDelta.content(text).jsonValue])
    }

    public static func heading(_ text: String = "", level: Int = 1) -> BlockNode {
        BlockNode(
            type: "heading",
            data: [
                "delta": TextDelta.content(text).jsonValue,
                "level": .integer(min(6, max(1, level))),
            ]
        )
    }

    public static func todo(_ text: String = "", checked: Bool = false) -> BlockNode {
        BlockNode(
            type: "todo_list",
            data: [
                "delta": TextDelta.content(text).jsonValue,
                "checked": .bool(checked),
            ]
        )
    }

    public static func bulletedList(
        _ text: String = "",
        children: [BlockNode] = []
    ) -> BlockNode {
        BlockNode(
            type: "bulleted_list",
            data: ["delta": TextDelta.content(text).jsonValue],
            children: children
        )
    }

    public static func numberedList(
        _ text: String = "",
        number: Int? = nil,
        children: [BlockNode] = []
    ) -> BlockNode {
        var data: [String: JSONValue] = ["delta": TextDelta.content(text).jsonValue]
        if let number { data["number"] = .integer(number) }
        return BlockNode(type: "numbered_list", data: data, children: children)
    }

    public static func quote(
        _ text: String = "",
        children: [BlockNode] = []
    ) -> BlockNode {
        BlockNode(
            type: "quote",
            data: ["delta": TextDelta.content(text).jsonValue],
            children: children
        )
    }

    public static func divider() -> BlockNode {
        BlockNode(type: "divider")
    }

    /// AppFlowy's Markdown codec uses the `code` node type and `language` data key.
    public static func code(_ text: String = "", language: String = "") -> BlockNode {
        BlockNode(
            type: "code",
            data: [
                "delta": TextDelta.content(text).jsonValue,
                "language": .string(language),
            ]
        )
    }

    /// A native block form of AppFlowy's inline `formula` rich-text attribute.
    public static func formula(_ expression: String = "") -> BlockNode {
        BlockNode(
            type: "nbe/formula",
            data: [
                "delta": TextDelta.content(expression).jsonValue,
                "formula": .string(expression),
            ]
        )
    }

    public static func columns(_ columns: [[BlockNode]]? = nil) -> BlockNode {
        let contents = columns ?? [[.paragraph("Column 1")], [.paragraph("Column 2")]]
        return BlockNode(
            type: "columns",
            data: ["column_count": .integer(contents.count)],
            children: contents.map { column(children: $0) }
        )
    }

    public static func column(children: [BlockNode] = [.paragraph()], width: Double? = nil) -> BlockNode {
        var data: [String: JSONValue] = [:]
        if let width { data["width"] = .number(width) }
        return BlockNode(type: "column", data: data, children: children)
    }

    public static func media(
        kind: String,
        url: String,
        title: String = "",
        mimeType: String? = nil
    ) -> BlockNode {
        var data: [String: JSONValue] = [
            "kind": .string(kind),
            "url": .string(url),
            "title": .string(title),
        ]
        if let mimeType { data["mime_type"] = .string(mimeType) }
        return BlockNode(type: "nbe/media", data: data)
    }

    public static func linkPreview(url: String) -> BlockNode {
        BlockNode(type: "link_preview", data: ["url": .string(url)])
    }

    public static func childPage(
        pageID: String,
        title: String,
        icon: String = "doc.text"
    ) -> BlockNode {
        BlockNode(type: "nbe/child_page", data: [
            "page_id": .string(pageID),
            "title": .string(title),
            "icon": .string(icon),
        ])
    }

    public static func pageReference(
        pageID: String,
        title: String,
        icon: String = "doc.text"
    ) -> BlockNode {
        BlockNode(type: "nbe/page_reference", data: [
            "page_id": .string(pageID),
            "title": .string(title),
            "icon": .string(icon),
        ])
    }

    public static func plugin(
        id: String,
        displayName: String,
        payload: JSONValue = .object([:])
    ) -> BlockNode {
        BlockNode(
            type: "nbe/plugin",
            data: [
                "plugin_id": .string(id),
                "display_name": .string(displayName),
                "payload": payload,
            ]
        )
    }

    public static func database(
        title: String,
        columns: [String],
        rows: [[String]] = []
    ) -> BlockNode {
        let columnValues: [JSONValue] = columns.enumerated().map { index, name in
            .object(["id": .string("column_\(index)"), "name": .string(name)])
        }
        let rowValues: [JSONValue] = rows.enumerated().map { rowIndex, values in
            var cells: [String: JSONValue] = [:]
            for (columnIndex, value) in values.enumerated() where columnIndex < columns.count {
                cells["column_\(columnIndex)"] = .string(value)
            }
            return .object(["id": .string("row_\(rowIndex)"), "cells": .object(cells)])
        }
        return BlockNode(
            type: "nbe/database",
            data: [
                "title": .string(title),
                "columns": .array(columnValues),
                "rows": .array(rowValues),
            ]
        )
    }

    /// Raw HTML is intentionally opt-in. The demo renders this node in an
    /// isolated WKWebView for browser CSS fidelity; semantic imports use the codec.
    public static func html(_ source: String, allowNetwork: Bool = false) -> BlockNode {
        BlockNode(
            type: "nbe/html",
            data: [
                "html": .string(source),
                "allow_network": .bool(allowNetwork),
            ]
        )
    }

    public static func image(
        url: String,
        align: String = "center",
        width: Double? = nil,
        height: Double? = nil
    ) -> BlockNode {
        var data: [String: JSONValue] = [
            "url": .string(url),
            "align": .string(align),
        ]
        if let width { data["width"] = .number(width) }
        if let height { data["height"] = .number(height) }
        return BlockNode(type: "image", data: data)
    }

    public static func table(rows: [[BlockNode]]) -> BlockNode {
        table(cellRows: rows.map { $0.map { [$0] } })
    }

    /// Creates a rectangular table while preserving every block contained in
    /// each cell. Ragged rows and empty cells are padded with editable paragraphs.
    public static func table(cellRows: [[[BlockNode]]]) -> BlockNode {
        let columnCount = cellRows.map(\.count).max() ?? 0
        let cells = cellRows.enumerated().flatMap { rowIndex, row in
            (0 ..< columnCount).map { columnIndex in
                let content = columnIndex < row.count && !row[columnIndex].isEmpty
                    ? row[columnIndex]
                    : [.paragraph()]
                return BlockNode(
                    type: "table/cell",
                    data: [
                        "rowPosition": .integer(rowIndex),
                        "colPosition": .integer(columnIndex),
                    ],
                    children: content
                )
            }
        }
        return BlockNode(
            type: "table",
            data: [
                "rowsLen": .integer(cellRows.count),
                "colsLen": .integer(columnCount),
                "colDefaultWidth": .number(160),
                "rowDefaultHeight": .number(40),
                "colMinimumWidth": .number(40),
            ],
            children: cells
        )
    }
}

/// A document wrapper whose encoded form is `{ "document": <root node> }`.
public struct BlockDocument: Codable, Hashable, Sendable {
    public var root: BlockNode

    public init(root: BlockNode) {
        self.root = root
    }

    public static func blank(withInitialParagraph: Bool = true) -> BlockDocument {
        BlockDocument(
            root: BlockNode(
                type: "page",
                children: withInitialParagraph ? [.paragraph()] : []
            )
        )
    }

    private enum CodingKeys: String, CodingKey { case document }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(BlockNode.self, forKey: .document)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .document)
    }

    public func node(at path: BlockPath) -> BlockNode? {
        var node = root
        for index in path.indices {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    public func validate() throws {
        guard root.type == "page" else {
            throw DocumentEngineError.invalidDocument("root node must have type 'page'")
        }
        try Self.validate(node: root, path: [])
    }

    private static let textBlockTypes: Set<String> = [
        "paragraph", "heading", "bulleted_list", "numbered_list", "todo_list", "quote", "code", "nbe/formula",
    ]

    private static func validate(node: BlockNode, path: BlockPath) throws {
        guard !node.type.isEmpty else {
            throw DocumentEngineError.invalidDocument("empty node type at \(path.indices)")
        }

        if textBlockTypes.contains(node.type) {
            guard let deltaValue = node.data["delta"] else {
                throw DocumentEngineError.invalidDocument("\(node.type) at \(path.indices) has no delta")
            }
            let delta = try TextDelta(jsonValue: deltaValue)
            try delta.validate(asContent: true)
        }

        if node.type == "heading", let levelValue = node.data["level"] {
            guard let level = levelValue.intValue, (1 ... 6).contains(level) else {
                throw DocumentEngineError.invalidDocument("heading level must be an integer from 1 through 6")
            }
        }

        if node.type == "todo_list", let checked = node.data["checked"], checked.boolValue == nil {
            throw DocumentEngineError.invalidDocument("todo_list checked, when provided, must be a boolean")
        }

        if node.type == "divider", !node.children.isEmpty {
            throw DocumentEngineError.invalidDocument("divider cannot contain children")
        }

        if node.type == "image" {
            guard let url = node.data["url"]?.stringValue, !url.isEmpty else {
                throw DocumentEngineError.invalidDocument("image at \(path.indices) has no URL")
            }
            guard node.children.isEmpty else {
                throw DocumentEngineError.invalidDocument("image cannot contain children")
            }
            for key in ["width", "height"] where node.data[key] != nil {
                guard let value = node.data[key]?.doubleValue, value.isFinite, value > 0 else {
                    throw DocumentEngineError.invalidDocument("image \(key) must be a finite positive number")
                }
            }
        }

        if node.type == "table" {
            guard let rows = node.data["rowsLen"]?.intValue, rows >= 0,
                  let columns = node.data["colsLen"]?.intValue, columns >= 0 else {
                throw DocumentEngineError.invalidDocument("table dimensions must be non-negative integers")
            }
            guard node.children.allSatisfy({ $0.type == "table/cell" }) else {
                throw DocumentEngineError.invalidDocument("table children must be table/cell nodes")
            }
            var coordinates: Set<String> = []
            for cell in node.children {
                guard let row = cell.data["rowPosition"]?.intValue,
                      let column = cell.data["colPosition"]?.intValue,
                      (0 ..< rows).contains(row), (0 ..< columns).contains(column) else {
                    throw DocumentEngineError.invalidDocument("table cell coordinates must be within table dimensions")
                }
                guard coordinates.insert("\(row):\(column)").inserted else {
                    throw DocumentEngineError.invalidDocument("table cell coordinates must be unique")
                }
            }
            guard node.children.count == rows * columns else {
                throw DocumentEngineError.invalidDocument("table requires exactly rowsLen * colsLen cells")
            }
        }

        if node.type == "table/cell" {
            guard node.data["rowPosition"]?.intValue != nil,
                  node.data["colPosition"]?.intValue != nil else {
                throw DocumentEngineError.invalidDocument("table/cell requires rowPosition and colPosition")
            }
        }

        if node.type == "nbe/formula" {
            guard let formula = node.data["formula"]?.stringValue else {
                throw DocumentEngineError.invalidDocument("formula block requires a formula string")
            }
            guard formula == node.delta?.plainText else {
                throw DocumentEngineError.invalidDocument("formula data must match its text delta")
            }
        }

        if node.type == "columns" {
            guard !node.children.isEmpty, node.children.allSatisfy({ $0.type == "column" }) else {
                throw DocumentEngineError.invalidDocument("columns must contain at least one column node")
            }
            guard let count = node.data["column_count"]?.intValue, count == node.children.count else {
                throw DocumentEngineError.invalidDocument("columns column_count must match its children")
            }
        }

        if node.type == "column" {
            guard !node.children.isEmpty else {
                throw DocumentEngineError.invalidDocument("column must contain at least one block")
            }
            if node.data["width"] != nil {
                guard let width = node.data["width"]?.doubleValue, width.isFinite, width > 0 else {
                    throw DocumentEngineError.invalidDocument("column width must be a finite positive number")
                }
            }
        }

        if node.type == "nbe/media" {
            guard let kind = node.data["kind"]?.stringValue, !kind.isEmpty,
                  let url = node.data["url"]?.stringValue, !url.isEmpty else {
                throw DocumentEngineError.invalidDocument("media requires kind and URL")
            }
        }

        if node.type == "link_preview", node.data["url"]?.stringValue?.isEmpty != false {
            throw DocumentEngineError.invalidDocument("link_preview requires a URL")
        }

        if node.type == "nbe/child_page" || node.type == "nbe/page_reference" {
            guard node.data["page_id"]?.stringValue?.isEmpty == false else {
                throw DocumentEngineError.invalidDocument("\(node.type) requires a page_id")
            }
            guard node.data["title"]?.stringValue != nil else {
                throw DocumentEngineError.invalidDocument("\(node.type) requires a fallback title")
            }
            guard node.children.isEmpty else {
                throw DocumentEngineError.invalidDocument("\(node.type) cannot contain document children")
            }
        }

        if node.type == "nbe/plugin", node.data["plugin_id"]?.stringValue?.isEmpty != false {
            throw DocumentEngineError.invalidDocument("plugin requires plugin_id")
        }

        if node.type == "nbe/database" {
            guard case .array = node.data["columns"], case .array = node.data["rows"] else {
                throw DocumentEngineError.invalidDocument("database requires columns and rows arrays")
            }
        }

        if node.type == "nbe/html", node.data["html"]?.stringValue == nil {
            throw DocumentEngineError.invalidDocument("html block requires source HTML")
        }

        for (index, child) in node.children.enumerated() {
            try validate(node: child, path: path.appending(index))
        }
    }

    /// Nodes in document/visual traversal order, excluding the page root.
    public func flattenedNodes() -> [(path: BlockPath, node: BlockNode)] {
        func walk(_ nodes: [BlockNode], parent: BlockPath) -> [(BlockPath, BlockNode)] {
            nodes.enumerated().flatMap { index, node in
                let path = parent.appending(index)
                return [(path, node)] + walk(node.children, parent: path)
            }
        }
        return walk(root.children, parent: [])
    }
}

public extension BlockNode {
    /// A serialized identity used by page links and backlinks. Runtime `id`
    /// intentionally stays out of AppFlowy JSON; this value lives in the
    /// block's lossless data map and therefore survives imports and storage.
    var stableBlockID: String? { data["block_id"]?.stringValue }

    mutating func ensureStableBlockIDs() {
        if stableBlockID == nil {
            data["block_id"] = .string(UUID().uuidString.lowercased())
        }
        for index in children.indices {
            children[index].ensureStableBlockIDs()
        }
    }
}

public extension BlockDocument {
    mutating func ensureStableBlockIDs() {
        for index in root.children.indices {
            root.children[index].ensureStableBlockIDs()
        }
    }
}

/// Familiar names for clients that do not already have a `Document` or `Node` type.
public typealias Document = BlockDocument
public typealias Node = BlockNode
