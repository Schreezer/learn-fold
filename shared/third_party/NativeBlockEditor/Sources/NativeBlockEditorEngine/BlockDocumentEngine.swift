import Foundation

/// A synchronous, Foundation-only block document engine.
///
/// Transactions are first applied to a staged value. The document, selection, and
/// history are committed only after every operation and the final schema validate.
public final class BlockDocumentEngine {
    public private(set) var document: BlockDocument
    public private(set) var selection: Selection?
    public private(set) var lastTransaction: Transaction?

    private struct HistoryEntry {
        var beforeDocument: BlockDocument
        var beforeSelection: Selection?
        var afterDocument: BlockDocument
        var afterSelection: Selection?
        var transaction: Transaction
    }

    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    public init(
        document: BlockDocument = .blank(),
        selection: Selection? = nil
    ) {
        self.document = document
        self.selection = selection
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func node(at path: BlockPath) -> BlockNode? {
        document.node(at: path)
    }

    public func validate() throws {
        try document.validate()
        if let selection {
            try Self.validate(selection: selection, in: document)
        }
    }

    /// Updates the directional selection without creating an undo entry.
    public func setSelection(_ selection: Selection?) throws {
        if let selection { try Self.validate(selection: selection, in: document) }
        self.selection = selection
    }

    public func apply(_ transaction: Transaction, recordingUndo: Bool = true) throws {
        if let selection {
            try Self.validate(selection: selection, in: document)
        }
        if let beforeSelection = transaction.beforeSelection {
            try Self.validate(selection: beforeSelection, in: document)
        }

        var stagedDocument = document
        var stagedSelection = selection
        for operation in transaction.operations {
            let beforeOperationDocument = stagedDocument
            try stagedDocument.apply(operation)
            if transaction.afterSelection == nil, let currentSelection = stagedSelection {
                stagedSelection = Self.transform(
                    selection: currentSelection,
                    through: operation,
                    before: beforeOperationDocument,
                    after: stagedDocument
                )
            }
        }
        try stagedDocument.validate()

        stagedSelection = transaction.afterSelection ?? stagedSelection
        if let stagedSelection {
            try Self.validate(selection: stagedSelection, in: stagedDocument)
        }

        let beforeDocument = document
        let beforeSelection = selection
        let changed = beforeDocument != stagedDocument || beforeSelection != stagedSelection

        document = stagedDocument
        selection = stagedSelection
        lastTransaction = transaction

        if !recordingUndo, changed {
            // A non-recorded mutation establishes a new history baseline. Keeping
            // snapshots from the old baseline could restore stale document state.
            undoStack.removeAll(keepingCapacity: true)
            redoStack.removeAll(keepingCapacity: true)
        } else if changed {
            undoStack.append(
                HistoryEntry(
                    beforeDocument: beforeDocument,
                    beforeSelection: beforeSelection,
                    afterDocument: stagedDocument,
                    afterSelection: stagedSelection,
                    transaction: transaction
                )
            )
            redoStack.removeAll(keepingCapacity: true)
        }
    }

    @discardableResult
    public func undo() throws -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        try entry.beforeDocument.validate()
        if let selection = entry.beforeSelection {
            try Self.validate(selection: selection, in: entry.beforeDocument)
        }
        document = entry.beforeDocument
        selection = entry.beforeSelection
        lastTransaction = Transaction(
            operations: entry.transaction.operations.reversed().map(\.inverted),
            afterSelection: entry.beforeSelection,
            beforeSelection: entry.afterSelection
        )
        redoStack.append(entry)
        return true
    }

    @discardableResult
    public func redo() throws -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        try entry.afterDocument.validate()
        if let selection = entry.afterSelection {
            try Self.validate(selection: selection, in: entry.afterDocument)
        }
        document = entry.afterDocument
        selection = entry.afterSelection
        lastTransaction = entry.transaction
        undoStack.append(entry)
        return true
    }

    @discardableResult
    public func insertNode(_ node: BlockNode, at path: BlockPath) throws -> Transaction {
        try insertNodes([node], at: path)
    }

    @discardableResult
    public func insertNodes(_ nodes: [BlockNode], at path: BlockPath) throws -> Transaction {
        guard !nodes.isEmpty else { return Transaction(beforeSelection: selection) }
        let transaction = Transaction(
            operations: [.insert(path: path, nodes: nodes)],
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    public func deleteNode(at path: BlockPath) throws -> Transaction {
        guard let node = document.node(at: path), !path.isEmpty else {
            throw DocumentEngineError.invalidPath(path)
        }
        let transaction = Transaction(
            operations: [.delete(path: path, nodes: [node])],
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    public func updateNode(
        at path: BlockPath,
        attributes: [String: JSONValue]
    ) throws -> Transaction {
        guard let node = document.node(at: path) else {
            throw DocumentEngineError.invalidPath(path)
        }
        var oldAttributes: [String: JSONValue] = [:]
        for key in attributes.keys {
            oldAttributes[key] = node.data[key] ?? .null
        }
        let transaction = Transaction(
            operations: [
                .update(
                    path: path,
                    attributes: attributes,
                    oldAttributes: oldAttributes
                ),
            ],
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    public func editText(at path: BlockPath, change: TextDelta) throws -> Transaction {
        guard let node = document.node(at: path), let content = node.delta else {
            throw DocumentEngineError.invalidOperation("node at \(path.indices) has no text delta")
        }
        if node.type == "nbe/formula" {
            return try editFormula(at: path, change: change)
        }
        let normalizedChange = change.normalized()
        let inverse = try normalizedChange.inverted(against: content)
        let transaction = Transaction(
            operations: [
                .updateText(path: path, delta: normalizedChange, inverted: inverse),
            ],
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    public func formatText(
        at path: BlockPath,
        range: Range<Int>,
        attributes: TextAttributes
    ) throws -> Transaction {
        guard let content = document.node(at: path)?.delta else {
            throw DocumentEngineError.invalidOperation("node at \(path.indices) has no text delta")
        }
        guard range.lowerBound >= 0, range.upperBound <= content.contentUTF16Length else {
            throw DocumentEngineError.invalidRange(
                "format range \(range) exceeds text length \(content.contentUTF16Length)"
            )
        }
        guard !range.isEmpty, !attributes.isEmpty else {
            return Transaction(beforeSelection: selection)
        }
        var operations: [TextOperation] = []
        if range.lowerBound > 0 { operations.append(.retain(range.lowerBound)) }
        operations.append(.retain(range.count, attributes: attributes))
        return try editText(at: path, change: TextDelta(operations))
    }

    @discardableResult
    public func toggleTodo(at path: BlockPath) throws -> Transaction {
        guard let node = document.node(at: path) else {
            throw DocumentEngineError.invalidPath(path)
        }
        guard node.type == "todo_list" else {
            throw DocumentEngineError.invalidOperation("node at \(path.indices) is not a valid todo_list")
        }
        let checked = node.data["checked"]?.boolValue ?? false
        return try updateNode(at: path, attributes: ["checked": .bool(!checked)])
    }

    @discardableResult
    public func changeBlockType(
        at path: BlockPath,
        to type: String,
        attributes: [String: JSONValue] = [:]
    ) throws -> Transaction {
        guard !type.isEmpty else {
            throw DocumentEngineError.invalidOperation("block type cannot be empty")
        }
        guard let oldNode = document.node(at: path), !path.isEmpty else {
            throw DocumentEngineError.invalidPath(path)
        }
        var replacement = oldNode
        replacement.type = type
        if Self.textBlockTypes.contains(type), replacement.delta == nil {
            replacement.delta = .content("")
        }
        if type == "heading", replacement.data["level"]?.intValue == nil {
            replacement.data["level"] = .integer(1)
        }
        if type == "todo_list", replacement.data["checked"]?.boolValue == nil {
            replacement.data["checked"] = .bool(false)
        }
        if type == "nbe/formula" {
            replacement.data["formula"] = .string(replacement.delta?.plainText ?? "")
        }
        for (key, value) in attributes {
            if value == .null {
                replacement.data.removeValue(forKey: key)
            } else {
                replacement.data[key] = value
            }
        }
        let transaction = Transaction(
            operations: [
                .delete(path: path, nodes: [oldNode]),
                .insert(path: path, nodes: [replacement]),
            ],
            afterSelection: selection,
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    @discardableResult
    public func splitBlock(at path: BlockPath, offset: Int) throws -> Transaction {
        guard let node = document.node(at: path), let content = node.delta, !path.isEmpty else {
            throw DocumentEngineError.invalidOperation("node at \(path.indices) cannot be split")
        }
        guard offset >= 0, offset <= content.contentUTF16Length else {
            throw DocumentEngineError.invalidRange(
                "split offset \(offset) exceeds text length \(content.contentUTF16Length)"
            )
        }
        let leftDelta = try content.slice(from: 0, to: offset)
        let rightDelta = try content.slice(from: offset, to: content.contentUTF16Length)
        var left = node
        left.delta = leftDelta
        left.children = []
        var right = BlockNode(type: node.type, data: node.data, children: node.children)
        right.delta = rightDelta
        if node.type == "nbe/formula" {
            left.data["formula"] = .string(leftDelta.plainText)
            right.data["formula"] = .string(rightDelta.plainText)
        }

        let nextPath = try path.nextSibling()
        let transaction = Transaction(
            operations: [
                .delete(path: path, nodes: [node]),
                .insert(path: path, nodes: [left, right]),
            ],
            afterSelection: Selection(collapsedAt: Position(path: nextPath, offset: 0)),
            beforeSelection: selection
        )
        try apply(transaction)
        return transaction
    }

    private static let textBlockTypes: Set<String> = [
        "paragraph", "heading", "bulleted_list", "numbered_list", "todo_list", "quote", "code", "nbe/formula",
    ]

    private static func validate(selection: Selection, in document: BlockDocument) throws {
        try validate(position: selection.start, in: document)
        try validate(position: selection.end, in: document)
    }

    private static func validate(position: Position, in document: BlockDocument) throws {
        guard position.offset >= 0, let node = document.node(at: position.path) else {
            throw DocumentEngineError.invalidPath(position.path)
        }
        if let delta = node.delta {
            guard position.offset <= delta.contentUTF16Length else {
                throw DocumentEngineError.invalidRange(
                    "selection offset \(position.offset) exceeds text length \(delta.contentUTF16Length)"
                )
            }
            guard delta.isValidUTF16Boundary(position.offset) else {
                throw DocumentEngineError.invalidRange(
                    "selection offset \(position.offset) splits a UTF-16 surrogate pair"
                )
            }
        } else if Self.atomicBlockTypes.contains(node.type) {
            guard (0 ... 1).contains(position.offset) else {
                throw DocumentEngineError.invalidRange("atomic block offsets must be zero or one")
            }
        } else if position.offset != 0 {
            throw DocumentEngineError.invalidRange("non-text nodes only accept offset zero")
        }
    }

    private static let atomicBlockTypes: Set<String> = [
        "divider", "image", "table", "columns", "column", "nbe/media", "nbe/plugin", "nbe/database", "nbe/html", "link_preview",
    ]

    private static func transform(
        selection: Selection,
        through operation: TransactionOperation,
        before: BlockDocument,
        after: BlockDocument
    ) -> Selection {
        Selection(
            start: transform(position: selection.start, through: operation, before: before, after: after),
            end: transform(position: selection.end, through: operation, before: before, after: after)
        )
    }

    private static func transform(
        position: Position,
        through operation: TransactionOperation,
        before _: BlockDocument,
        after: BlockDocument
    ) -> Position {
        switch operation {
        case let .insert(path, nodes):
            return Position(
                path: transformPathForInsert(position.path, insertionPath: path, count: nodes.count),
                offset: position.offset
            )

        case let .delete(path, nodes):
            return transformPositionForDelete(
                position,
                deletionPath: path,
                count: nodes.count,
                after: after
            )

        case .update:
            return position

        case let .updateText(path, delta, _):
            guard position.path == path else { return position }
            return Position(
                path: position.path,
                offset: transformTextOffset(position.offset, through: delta.normalized())
            )
        }
    }

    private static func transformPathForInsert(
        _ path: BlockPath,
        insertionPath: BlockPath,
        count: Int
    ) -> BlockPath {
        let parentDepth = insertionPath.count - 1
        guard
            parentDepth >= 0,
            path.count > parentDepth,
            path.indices.prefix(parentDepth).elementsEqual(insertionPath.indices.prefix(parentDepth)),
            let insertionIndex = insertionPath.last,
            path.indices[parentDepth] >= insertionIndex
        else {
            return path
        }
        var indices = path.indices
        indices[parentDepth] += count
        return BlockPath(indices)
    }

    private static func transformPositionForDelete(
        _ position: Position,
        deletionPath: BlockPath,
        count: Int,
        after: BlockDocument
    ) -> Position {
        let parentDepth = deletionPath.count - 1
        guard
            parentDepth >= 0,
            position.path.count > parentDepth,
            position.path.indices.prefix(parentDepth).elementsEqual(
                deletionPath.indices.prefix(parentDepth)
            ),
            let deletionIndex = deletionPath.last
        else {
            return position
        }

        let selectedSiblingIndex = position.path.indices[parentDepth]
        if selectedSiblingIndex >= deletionIndex,
           selectedSiblingIndex < deletionIndex + count {
            return deletionFallbackPosition(
                deletionPath: deletionPath,
                deletionIndex: deletionIndex,
                after: after
            )
        }

        guard selectedSiblingIndex >= deletionIndex + count else { return position }
        var indices = position.path.indices
        indices[parentDepth] -= count
        return Position(path: BlockPath(indices), offset: position.offset)
    }

    private static func deletionFallbackPosition(
        deletionPath: BlockPath,
        deletionIndex: Int,
        after: BlockDocument
    ) -> Position {
        // Following siblings slide into the deleted range's first path.
        if after.node(at: deletionPath) != nil {
            return Position(path: deletionPath, offset: 0)
        }

        if deletionIndex > 0 {
            let previousPath = deletionPath.parent.appending(deletionIndex - 1)
            if after.node(at: previousPath) != nil {
                return lastSelectablePosition(in: after, startingAt: previousPath)
            }
        }

        // Delete operations cannot remove the root, so the parent always remains.
        let parentPath = deletionPath.parent
        return Position(path: after.node(at: parentPath) == nil ? [] : parentPath, offset: 0)
    }

    private static func lastSelectablePosition(
        in document: BlockDocument,
        startingAt initialPath: BlockPath
    ) -> Position {
        var path = initialPath
        var node = document.node(at: path)
        while let current = node, !current.children.isEmpty {
            let lastIndex = current.children.count - 1
            path = path.appending(lastIndex)
            node = current.children[lastIndex]
        }
        guard let node else { return Position(path: initialPath, offset: 0) }
        if let delta = node.delta {
            return Position(path: path, offset: delta.contentUTF16Length)
        }
        if atomicBlockTypes.contains(node.type) {
            return Position(path: path, offset: 1)
        }
        return Position(path: path, offset: 0)
    }

    private static func transformTextOffset(_ offset: Int, through delta: TextDelta) -> Int {
        var sourceIndex = 0
        var destinationIndex = 0

        for operation in delta.operations {
            switch operation {
            case let .insert(text, _):
                // Downstream affinity: an insertion exactly at the cursor advances it.
                if sourceIndex <= offset {
                    destinationIndex += text.utf16.count
                }

            case let .retain(length, _):
                if offset < sourceIndex + length {
                    return destinationIndex + offset - sourceIndex
                }
                sourceIndex += length
                destinationIndex += length

            case let .delete(length):
                if offset <= sourceIndex + length {
                    // Both positions inside the removed range, including its end,
                    // collapse to the range's surviving destination boundary.
                    return destinationIndex
                }
                sourceIndex += length
            }
        }

        return destinationIndex + offset - sourceIndex
    }
}

private extension BlockDocument {
    mutating func apply(_ operation: TransactionOperation) throws {
        switch operation {
        case let .insert(path, nodes):
            guard !path.isEmpty, !nodes.isEmpty, let index = path.last else {
                throw DocumentEngineError.invalidOperation("insert needs a non-root path and at least one node")
            }
            guard index >= 0 else { throw DocumentEngineError.invalidPath(path) }
            try mutateNode(at: path.parent) { parent in
                guard index <= parent.children.count else {
                    throw DocumentEngineError.invalidPath(path)
                }
                parent.children.insert(contentsOf: nodes, at: index)
            }

        case let .delete(path, nodes):
            guard !path.isEmpty, !nodes.isEmpty, let index = path.last else {
                throw DocumentEngineError.invalidOperation("delete needs a non-root path and at least one node")
            }
            guard index >= 0 else { throw DocumentEngineError.invalidPath(path) }
            try mutateNode(at: path.parent) { parent in
                guard index + nodes.count <= parent.children.count else {
                    throw DocumentEngineError.invalidPath(path)
                }
                parent.children.removeSubrange(index ..< index + nodes.count)
            }

        case let .update(path, attributes, _):
            try mutateNode(at: path) { node in
                for (key, value) in attributes {
                    if value == .null {
                        node.data.removeValue(forKey: key)
                    } else {
                        node.data[key] = value
                    }
                }
            }

        case let .updateText(path, delta, _):
            try mutateNode(at: path) { node in
                guard let content = node.delta else {
                    throw DocumentEngineError.invalidOperation("node at \(path.indices) has no text delta")
                }
                node.delta = try delta.normalized().applying(to: content)
            }
        }
    }

    mutating func mutateNode(
        at path: BlockPath,
        _ mutation: (inout BlockNode) throws -> Void
    ) throws {
        try Self.mutate(node: &root, remaining: ArraySlice(path.indices), path: path, mutation)
    }

    private static func mutate(
        node: inout BlockNode,
        remaining: ArraySlice<Int>,
        path: BlockPath,
        _ mutation: (inout BlockNode) throws -> Void
    ) throws {
        guard let index = remaining.first else {
            try mutation(&node)
            return
        }
        guard index >= 0, node.children.indices.contains(index) else {
            throw DocumentEngineError.invalidPath(path)
        }
        try mutate(
            node: &node.children[index],
            remaining: remaining.dropFirst(),
            path: path,
            mutation
        )
    }
}
