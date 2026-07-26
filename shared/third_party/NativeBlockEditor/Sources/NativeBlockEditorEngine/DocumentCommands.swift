import Foundation

public struct DocumentSearchResult: Codable, Hashable, Identifiable, Sendable {
    public var path: BlockPath
    public var range: Range<Int>
    public var preview: String

    public init(path: BlockPath, range: Range<Int>, preview: String) {
        self.path = path
        self.range = range
        self.preview = preview
    }

    public var id: String { "\(path.indices)-\(range.lowerBound)-\(range.upperBound)" }
}

public extension BlockDocumentEngine {
    /// Deletes an empty editable block as one undoable operation. Any children
    /// owned by the empty block are promoted into its parent so content is never
    /// lost. The final remaining empty block is retained as the document caret.
    @discardableResult
    func deleteEmptyTextBlock(at path: BlockPath) throws -> Transaction {
        guard !path.isEmpty,
              let node = document.node(at: path),
              let delta = node.delta else {
            throw DocumentEngineError.invalidPath(path)
        }
        guard delta.contentUTF16Length == 0 else {
            throw DocumentEngineError.invalidOperation("block at \(path.indices) is not empty")
        }

        let flattened = document.flattenedNodes()
        let otherEditableBlocks = flattened.filter { $0.path != path && $0.node.delta != nil }
        guard !otherEditableBlocks.isEmpty || !node.children.isEmpty else {
            return Transaction(beforeSelection: selection)
        }

        let precedingPosition = flattened
            .prefix { $0.path != path }
            .reversed()
            .first(where: { $0.node.delta != nil })
            .map { Position(path: $0.path, offset: $0.node.delta?.contentUTF16Length ?? 0) }

        var operations: [TransactionOperation] = [.delete(path: path, nodes: [node])]
        if !node.children.isEmpty {
            operations.append(.insert(path: path, nodes: node.children))
        }

        let fallbackPosition: Position = {
            if let precedingPosition { return precedingPosition }
            // With no preceding editor, the first promoted child or following
            // sibling occupies the deleted path after this transaction.
            return Position(path: path, offset: 0)
        }()
        let transaction = Transaction(
            operations: operations,
            afterSelection: Selection(collapsedAt: fallbackPosition),
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    /// Applies a text change to a native formula block and keeps its mirrored
    /// `formula` data field synchronized in the same undoable transaction.
    @discardableResult
    func editFormula(at path: BlockPath, change: TextDelta) throws -> Transaction {
        guard let node = document.node(at: path), node.type == "nbe/formula", let content = node.delta else {
            throw DocumentEngineError.invalidOperation("node at \(path.indices) is not a formula block")
        }
        let normalized = change.normalized()
        let updated = try normalized.applying(to: content)
        let transaction = Transaction(
            operations: [
                .updateText(path: path, delta: normalized, inverted: try normalized.inverted(against: content)),
                .update(
                    path: path,
                    attributes: ["formula": .string(updated.plainText)],
                    oldAttributes: ["formula": node.data["formula"] ?? .null]
                ),
            ],
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    func replaceNode(at path: BlockPath, with replacement: BlockNode) throws -> Transaction {
        guard let current = document.node(at: path), !path.isEmpty else {
            throw DocumentEngineError.invalidPath(path)
        }
        let transaction = Transaction(
            operations: [
                .delete(path: path, nodes: [current]),
                .insert(path: path, nodes: [replacement]),
            ],
            afterSelection: selection.map {
                Self.selection($0, replacingNodeAt: path, in: document, with: replacement)
            },
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    /// Moves one subtree to an insertion path. The insertion path is interpreted
    /// against the document before removal, which makes UI drop targets stable.
    @discardableResult
    func moveNode(from source: BlockPath, to destination: BlockPath) throws -> Transaction {
        guard !source.isEmpty, !destination.isEmpty,
              let node = document.node(at: source),
              source != destination else {
            throw DocumentEngineError.invalidPath(source)
        }
        guard !destination.indices.starts(with: source.indices) else {
            throw DocumentEngineError.invalidOperation("cannot move a node into its own subtree")
        }

        let adjusted = Self.path(destination, afterDeleting: source)
        if adjusted == source { return Transaction(beforeSelection: selection) }

        let movedSelection = selection.map {
            Self.selection($0, moving: source, to: adjusted)
        }
        let transaction = Transaction(
            operations: [
                .delete(path: source, nodes: [node]),
                .insert(path: adjusted, nodes: [node]),
            ],
            afterSelection: movedSelection,
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    func search(_ query: String, caseSensitive: Bool = false) -> [DocumentSearchResult] {
        guard !query.isEmpty else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return document.flattenedNodes().flatMap { entry -> [DocumentSearchResult] in
            guard let delta = entry.node.delta else { return [] }
            let text = delta.plainText as NSString
            var results: [DocumentSearchResult] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: query, options: options, range: searchRange)
                guard match.location != NSNotFound else { break }
                let lower = match.location
                let upper = NSMaxRange(match)
                let contextStart = max(0, lower - 24)
                let contextEnd = min(text.length, upper + 24)
                results.append(
                    DocumentSearchResult(
                        path: entry.path,
                        range: lower ..< upper,
                        preview: text.substring(with: NSRange(location: contextStart, length: contextEnd - contextStart))
                    )
                )
                let next = upper == lower ? upper + 1 : upper
                guard next <= text.length else { break }
                searchRange = NSRange(location: next, length: text.length - next)
            }
            return results
        }
    }

    @discardableResult
    func replaceAll(
        _ query: String,
        with replacement: String,
        caseSensitive: Bool = false
    ) throws -> Transaction {
        let grouped = Dictionary(grouping: search(query, caseSensitive: caseSensitive), by: \.path)
        guard !grouped.isEmpty else { return Transaction(beforeSelection: selection) }
        var operations: [TransactionOperation] = []

        for entry in document.flattenedNodes() {
            guard let matches = grouped[entry.path], let content = entry.node.delta else { continue }
            let sorted = matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var change: [TextOperation] = []
            var cursor = 0
            for match in sorted {
                if match.range.lowerBound > cursor {
                    change.append(.retain(match.range.lowerBound - cursor))
                }
                let attributes = content.attributes(atUTF16Offset: match.range.lowerBound)
                change.append(.delete(match.range.count))
                if !replacement.isEmpty {
                    change.append(.insert(replacement, attributes: attributes.isEmpty ? nil : attributes))
                }
                cursor = match.range.upperBound
            }
            let delta = TextDelta(change).normalized()
            operations.append(
                .updateText(
                    path: entry.path,
                    delta: delta,
                    inverted: try delta.inverted(against: content)
                )
            )
            if entry.node.type == "nbe/formula" {
                let updated = try delta.applying(to: content)
                operations.append(
                    .update(
                        path: entry.path,
                        attributes: ["formula": .string(updated.plainText)],
                        oldAttributes: ["formula": entry.node.data["formula"] ?? .null]
                    )
                )
            }
        }
        let transaction = Transaction(operations: operations, beforeSelection: selection)
        try apply(transaction)
        return transaction
    }

    /// Returns a top-level fragment for a document-level selection. Descendants
    /// remain attached to their selected parent nodes.
    func fragment(for selection: Selection) throws -> BlockDocument {
        let normalized = selection.normalized
        guard normalized.start.path.count == 1, normalized.end.path.count == 1,
              let start = normalized.start.path.last, let end = normalized.end.path.last,
              start >= 0, end >= start, end < document.root.children.count else {
            throw DocumentEngineError.invalidOperation("cross-block fragments currently require top-level endpoints")
        }
        return BlockDocument(
            root: BlockNode(type: "page", children: Array(document.root.children[start ... end]))
        )
    }

    /// Replaces a range inside one text block with a rich document fragment in
    /// one undoable transaction. The surrounding text is merged into the first
    /// and last compatible imported text blocks.
    @discardableResult
    func replaceTextRange(
        at path: BlockPath,
        range: Range<Int>,
        with fragment: BlockDocument
    ) throws -> Transaction {
        guard let current = document.node(at: path), let content = current.delta, !path.isEmpty,
              range.lowerBound >= 0, range.upperBound <= content.contentUTF16Length else {
            throw DocumentEngineError.invalidRange("paste range is outside the target text block")
        }
        let left = try content.slice(from: 0, to: range.lowerBound)
        let right = try content.slice(from: range.upperBound, to: content.contentUTF16Length)
        var inserted = fragment.root.children

        if inserted.isEmpty {
            var replacement = current
            replacement.delta = TextDelta(left.operations + right.operations).normalized()
            if replacement.type == "nbe/formula" {
                replacement.data["formula"] = .string(replacement.delta?.plainText ?? "")
            }
            let transaction = Transaction(
                operations: [
                    .delete(path: path, nodes: [current]),
                    .insert(path: path, nodes: [replacement]),
                ],
                afterSelection: Selection(path: path, startOffset: range.lowerBound),
                beforeSelection: selection
            )
            try apply(transaction)
            return transaction
        }

        let fragmentCount = inserted.count
        let fragmentLast = inserted[fragmentCount - 1]
        var insertedPrefix = false
        if inserted[0].delta != nil {
            inserted[0].delta = TextDelta(left.operations + (inserted[0].delta?.operations ?? [])).normalized()
        } else if !left.operations.isEmpty {
            var prefix = current
            prefix.children = []
            prefix.delta = left
            inserted.insert(prefix, at: 0)
            insertedPrefix = true
        }

        let pastedLastIndex = (insertedPrefix ? 1 : 0) + fragmentCount - 1
        let caretOffset: Int
        if let pastedDelta = fragmentLast.delta {
            caretOffset = pastedDelta.contentUTF16Length + (fragmentCount == 1 && !insertedPrefix ? left.contentUTF16Length : 0)
        } else {
            caretOffset = Self.atomicSelectionTypes.contains(fragmentLast.type) ? 1 : 0
        }

        if inserted[pastedLastIndex].delta != nil {
            inserted[pastedLastIndex].delta = TextDelta(
                (inserted[pastedLastIndex].delta?.operations ?? []) + right.operations
            ).normalized()
        } else if !right.operations.isEmpty {
            var suffix = current
            suffix.children = []
            suffix.delta = right
            inserted.append(suffix)
        }
        for index in inserted.indices {
            Self.synchronizeFormulaData(in: &inserted[index])
        }

        let transaction = Transaction(
            operations: [
                .delete(path: path, nodes: [current]),
                .insert(path: path, nodes: inserted),
            ],
            afterSelection: Selection(
                path: path.parent.appending((path.last ?? 0) + pastedLastIndex),
                startOffset: caretOffset
            ),
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    func deleteBlocks(in selection: Selection) throws -> Transaction {
        let normalized = selection.normalized
        guard normalized.start.path.count == 1, normalized.end.path.count == 1,
              let start = normalized.start.path.last, let end = normalized.end.path.last,
              start >= 0, end >= start, end < document.root.children.count else {
            throw DocumentEngineError.invalidOperation("block deletion requires top-level endpoints")
        }
        let nodes = Array(document.root.children[start ... end])
        let path = BlockPath([start])
        let deletesEntireDocument = start == 0 && end == document.root.children.count - 1
        let replacement = deletesEntireDocument ? BlockNode.paragraph() : nil
        var operations: [TransactionOperation] = [.delete(path: path, nodes: nodes)]
        if let replacement { operations.append(.insert(path: path, nodes: [replacement])) }
        let transaction = Transaction(
            operations: operations,
            afterSelection: replacement.map { _ in Selection(path: path, startOffset: 0) },
            beforeSelection: self.selection
        )
        try apply(transaction)
        return transaction
    }

    /// Replaces a selected top-level block range with a document fragment as a
    /// single undoable operation. This is the document-level paste primitive.
    @discardableResult
    func replaceBlocks(in selection: Selection, with fragment: BlockDocument) throws -> Transaction {
        let normalized = selection.normalized
        guard normalized.start.path.count == 1, normalized.end.path.count == 1,
              let start = normalized.start.path.last, let end = normalized.end.path.last,
              start >= 0, end >= start, end < document.root.children.count else {
            throw DocumentEngineError.invalidOperation("block replacement requires top-level endpoints")
        }
        let removed = Array(document.root.children[start ... end])
        let inserted = fragment.root.children.isEmpty ? [BlockNode.paragraph()] : fragment.root.children
        let path = BlockPath([start])
        let last = inserted[inserted.count - 1]
        let offset = last.delta?.contentUTF16Length ?? (Self.atomicSelectionTypes.contains(last.type) ? 1 : 0)
        let finalPath = BlockPath([start + inserted.count - 1])
        let transaction = Transaction(
            operations: [
                .delete(path: path, nodes: removed),
                .insert(path: path, nodes: inserted),
            ],
            afterSelection: Selection(path: finalPath, startOffset: offset),
            beforeSelection: self.selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    func addTableRow(at path: BlockPath, index: Int? = nil) throws -> Transaction {
        try mutateTable(at: path) { table in
            let rows = table.data["rowsLen"]?.intValue ?? 0
            let columns = table.data["colsLen"]?.intValue ?? 0
            let insertion = min(max(0, index ?? rows), rows)
            for cellIndex in table.children.indices {
                if let row = table.children[cellIndex].data["rowPosition"]?.intValue, row >= insertion {
                    table.children[cellIndex].data["rowPosition"] = .integer(row + 1)
                }
            }
            for column in 0 ..< columns {
                table.children.append(Self.tableCell(row: insertion, column: column))
            }
            table.data["rowsLen"] = .integer(rows + 1)
            Self.sortTableCells(&table)
        }
    }

    @discardableResult
    func deleteTableRow(at path: BlockPath, index: Int) throws -> Transaction {
        try mutateTable(at: path) { table in
            let rows = table.data["rowsLen"]?.intValue ?? 0
            guard rows > 1, (0 ..< rows).contains(index) else {
                throw DocumentEngineError.invalidOperation("table must retain at least one row")
            }
            table.children.removeAll { $0.data["rowPosition"]?.intValue == index }
            for cellIndex in table.children.indices {
                if let row = table.children[cellIndex].data["rowPosition"]?.intValue, row > index {
                    table.children[cellIndex].data["rowPosition"] = .integer(row - 1)
                }
            }
            table.data["rowsLen"] = .integer(rows - 1)
            Self.sortTableCells(&table)
        }
    }

    @discardableResult
    func addTableColumn(at path: BlockPath, index: Int? = nil) throws -> Transaction {
        try mutateTable(at: path) { table in
            let rows = table.data["rowsLen"]?.intValue ?? 0
            let columns = table.data["colsLen"]?.intValue ?? 0
            let insertion = min(max(0, index ?? columns), columns)
            for cellIndex in table.children.indices {
                if let column = table.children[cellIndex].data["colPosition"]?.intValue, column >= insertion {
                    table.children[cellIndex].data["colPosition"] = .integer(column + 1)
                }
            }
            for row in 0 ..< rows {
                table.children.append(Self.tableCell(row: row, column: insertion))
            }
            table.data["colsLen"] = .integer(columns + 1)
            Self.sortTableCells(&table)
        }
    }

    @discardableResult
    func deleteTableColumn(at path: BlockPath, index: Int) throws -> Transaction {
        try mutateTable(at: path) { table in
            let columns = table.data["colsLen"]?.intValue ?? 0
            guard columns > 1, (0 ..< columns).contains(index) else {
                throw DocumentEngineError.invalidOperation("table must retain at least one column")
            }
            table.children.removeAll { $0.data["colPosition"]?.intValue == index }
            for cellIndex in table.children.indices {
                if let column = table.children[cellIndex].data["colPosition"]?.intValue, column > index {
                    table.children[cellIndex].data["colPosition"] = .integer(column - 1)
                }
            }
            table.data["colsLen"] = .integer(columns - 1)
            Self.sortTableCells(&table)
        }
    }

    @discardableResult
    func addColumn(at path: BlockPath) throws -> Transaction {
        guard var columns = document.node(at: path), columns.type == "columns" else {
            throw DocumentEngineError.invalidPath(path)
        }
        columns.children.append(.column(children: [.paragraph("Column \(columns.children.count + 1)")]))
        columns.data["column_count"] = .integer(columns.children.count)
        return try replaceNode(at: path, with: columns)
    }

    @discardableResult
    func deleteLastColumn(at path: BlockPath) throws -> Transaction {
        guard var columns = document.node(at: path), columns.type == "columns", columns.children.count > 1 else {
            throw DocumentEngineError.invalidOperation("columns must retain at least one column")
        }
        columns.children.removeLast()
        columns.data["column_count"] = .integer(columns.children.count)
        return try replaceNode(at: path, with: columns)
    }

    @discardableResult
    func addDatabaseRow(at path: BlockPath) throws -> Transaction {
        guard var database = document.node(at: path), database.type == "nbe/database",
              case let .array(rows)? = database.data["rows"] else {
            throw DocumentEngineError.invalidPath(path)
        }
        var next = rows
        next.append(.object(["id": .string(UUID().uuidString), "cells": .object([:])]))
        database.data["rows"] = .array(next)
        return try replaceNode(at: path, with: database)
    }

    @discardableResult
    func updateDatabaseCell(
        at path: BlockPath,
        rowID: String,
        columnID: String,
        value: String
    ) throws -> Transaction {
        guard var database = document.node(at: path), database.type == "nbe/database",
              case let .array(rows)? = database.data["rows"] else {
            throw DocumentEngineError.invalidPath(path)
        }
        var updated = rows
        guard let rowIndex = updated.firstIndex(where: { row in
            guard case let .object(object) = row else { return false }
            return object["id"]?.stringValue == rowID
        }), case var .object(row) = updated[rowIndex] else {
            throw DocumentEngineError.invalidOperation("database row was not found")
        }
        var cells: [String: JSONValue]
        if case let .object(existing)? = row["cells"] { cells = existing } else { cells = [:] }
        cells[columnID] = .string(value)
        row["cells"] = .object(cells)
        updated[rowIndex] = .object(row)
        database.data["rows"] = .array(updated)
        return try replaceNode(at: path, with: database)
    }

    private func mutateTable(
        at path: BlockPath,
        _ mutation: (inout BlockNode) throws -> Void
    ) throws -> Transaction {
        guard var table = document.node(at: path), table.type == "table" else {
            throw DocumentEngineError.invalidPath(path)
        }
        try mutation(&table)
        return try replaceNode(at: path, with: table)
    }

    private static func tableCell(row: Int, column: Int) -> BlockNode {
        BlockNode(
            type: "table/cell",
            data: ["rowPosition": .integer(row), "colPosition": .integer(column)],
            children: [.paragraph()]
        )
    }

    private static func sortTableCells(_ table: inout BlockNode) {
        table.children.sort {
            let lhs = ($0.data["rowPosition"]?.intValue ?? 0, $0.data["colPosition"]?.intValue ?? 0)
            let rhs = ($1.data["rowPosition"]?.intValue ?? 0, $1.data["colPosition"]?.intValue ?? 0)
            return lhs < rhs
        }
    }

    private static let atomicSelectionTypes: Set<String> = [
        "divider", "image", "table", "columns", "column", "nbe/media", "nbe/plugin", "nbe/database", "nbe/html", "link_preview",
    ]

    private static func synchronizeFormulaData(in node: inout BlockNode) {
        if node.type == "nbe/formula" {
            node.data["formula"] = .string(node.delta?.plainText ?? "")
        }
        for index in node.children.indices {
            synchronizeFormulaData(in: &node.children[index])
        }
    }

    private static func path(_ path: BlockPath, afterDeleting source: BlockPath) -> BlockPath {
        guard let sourceIndex = source.last else { return path }
        let depth = source.count - 1
        guard path.count > depth,
              path.indices.prefix(depth).elementsEqual(source.indices.prefix(depth)),
              path.indices[depth] > sourceIndex else { return path }
        var indices = path.indices
        indices[depth] -= 1
        return BlockPath(indices)
    }

    private static func path(_ path: BlockPath, afterInsertingAt destination: BlockPath) -> BlockPath {
        guard let destinationIndex = destination.last else { return path }
        let depth = destination.count - 1
        guard path.count > depth,
              path.indices.prefix(depth).elementsEqual(destination.indices.prefix(depth)),
              path.indices[depth] >= destinationIndex else { return path }
        var indices = path.indices
        indices[depth] += 1
        return BlockPath(indices)
    }

    private static func selection(_ selection: Selection, moving source: BlockPath, to destination: BlockPath) -> Selection {
        func move(_ position: Position) -> Position {
            if position.path.indices.starts(with: source.indices) {
                let suffix = position.path.indices.dropFirst(source.count)
                return Position(path: BlockPath(destination.indices + suffix), offset: position.offset)
            }
            let afterDelete = path(position.path, afterDeleting: source)
            let afterInsert = path(afterDelete, afterInsertingAt: destination)
            return Position(path: afterInsert, offset: position.offset)
        }
        return Selection(start: move(selection.start), end: move(selection.end))
    }

    private static func selection(
        _ selection: Selection,
        replacingNodeAt path: BlockPath,
        in document: BlockDocument,
        with replacement: BlockNode
    ) -> Selection {
        func relativePath(to id: UUID, in node: BlockNode) -> BlockPath? {
            if node.id == id { return [] }
            for (index, child) in node.children.enumerated() {
                if let suffix = relativePath(to: id, in: child) {
                    return BlockPath([index] + suffix.indices)
                }
            }
            return nil
        }

        func node(at relativePath: BlockPath, in root: BlockNode) -> BlockNode? {
            var node = root
            for index in relativePath.indices {
                guard node.children.indices.contains(index) else { return nil }
                node = node.children[index]
            }
            return node
        }

        func validOffset(_ proposed: Int, in node: BlockNode) -> Int {
            if let delta = node.delta {
                var offset = min(max(0, proposed), delta.contentUTF16Length)
                while offset > 0, !delta.isValidUTF16Boundary(offset) { offset -= 1 }
                return offset
            }
            return atomicSelectionTypes.contains(node.type) ? min(max(0, proposed), 1) : 0
        }

        func map(_ position: Position) -> Position {
            guard position.path.indices.starts(with: path.indices) else { return position }
            if let oldNode = document.node(at: position.path),
               let relative = relativePath(to: oldNode.id, in: replacement),
               let target = node(at: relative, in: replacement) {
                return Position(
                    path: BlockPath(path.indices + relative.indices),
                    offset: validOffset(position.offset, in: target)
                )
            }
            return Position(path: path, offset: validOffset(position.offset, in: replacement))
        }

        return Selection(start: map(selection.start), end: map(selection.end))
    }
}

public extension BlockDocument {
    var plainText: String {
        flattenedNodes().compactMap { entry in
            entry.node.delta?.plainText
        }.joined(separator: "\n")
    }
}

public extension TextDelta {
    func attributes(atUTF16Offset offset: Int) -> TextAttributes {
        guard offset >= 0, offset < contentUTF16Length else { return [:] }
        var cursor = 0
        for operation in operations {
            guard case let .insert(text, attributes) = operation else { continue }
            let end = cursor + text.utf16.count
            if offset < end { return attributes ?? [:] }
            cursor = end
        }
        return [:]
    }
}
