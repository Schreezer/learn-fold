import Foundation

/// AppFlowy's four document operation kinds and their exact JSON `op` values.
public enum TransactionOperation: Hashable, Sendable {
    case insert(path: BlockPath, nodes: [BlockNode])
    case delete(path: BlockPath, nodes: [BlockNode])
    case update(
        path: BlockPath,
        attributes: [String: JSONValue],
        oldAttributes: [String: JSONValue]
    )
    case updateText(path: BlockPath, delta: TextDelta, inverted: TextDelta)

    public var path: BlockPath {
        switch self {
        case let .insert(path, _), let .delete(path, _): path
        case let .update(path, _, _), let .updateText(path, _, _): path
        }
    }

    public var inverted: TransactionOperation {
        switch self {
        case let .insert(path, nodes): .delete(path: path, nodes: nodes)
        case let .delete(path, nodes): .insert(path: path, nodes: nodes)
        case let .update(path, attributes, oldAttributes):
            .update(path: path, attributes: oldAttributes, oldAttributes: attributes)
        case let .updateText(path, delta, inverted):
            .updateText(path: path, delta: inverted, inverted: delta)
        }
    }
}

extension TransactionOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, path, nodes, attributes, oldAttributes, delta, inverted
    }

    private enum OperationName: String, Codable {
        case insert
        case delete
        case update
        case updateText = "update_text"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(OperationName.self, forKey: .op)
        let path = try container.decode(BlockPath.self, forKey: .path)
        switch operation {
        case .insert:
            self = .insert(path: path, nodes: try container.decode([BlockNode].self, forKey: .nodes))
        case .delete:
            self = .delete(path: path, nodes: try container.decode([BlockNode].self, forKey: .nodes))
        case .update:
            self = .update(
                path: path,
                attributes: try container.decode([String: JSONValue].self, forKey: .attributes),
                oldAttributes: try container.decode([String: JSONValue].self, forKey: .oldAttributes)
            )
        case .updateText:
            self = .updateText(
                path: path,
                delta: try container.decode(TextDelta.self, forKey: .delta),
                inverted: try container.decode(TextDelta.self, forKey: .inverted)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        switch self {
        case let .insert(_, nodes):
            try container.encode(OperationName.insert, forKey: .op)
            try container.encode(nodes, forKey: .nodes)
        case let .delete(_, nodes):
            try container.encode(OperationName.delete, forKey: .op)
            try container.encode(nodes, forKey: .nodes)
        case let .update(_, attributes, oldAttributes):
            try container.encode(OperationName.update, forKey: .op)
            try container.encode(attributes, forKey: .attributes)
            try container.encode(oldAttributes, forKey: .oldAttributes)
        case let .updateText(_, delta, inverted):
            try container.encode(OperationName.updateText, forKey: .op)
            try container.encode(delta, forKey: .delta)
            try container.encode(inverted, forKey: .inverted)
        }
    }
}

public struct Transaction: Codable, Hashable, Sendable {
    public var operations: [TransactionOperation]
    public var afterSelection: Selection?
    public var beforeSelection: Selection?

    public init(
        operations: [TransactionOperation] = [],
        afterSelection: Selection? = nil,
        beforeSelection: Selection? = nil
    ) {
        self.operations = operations
        self.afterSelection = afterSelection
        self.beforeSelection = beforeSelection
    }

    private enum CodingKeys: String, CodingKey {
        case operations
        case afterSelection = "after_selection"
        case beforeSelection = "before_selection"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operations = try container.decodeIfPresent([TransactionOperation].self, forKey: .operations) ?? []
        afterSelection = try container.decodeIfPresent(Selection.self, forKey: .afterSelection)
        beforeSelection = try container.decodeIfPresent(Selection.self, forKey: .beforeSelection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !operations.isEmpty {
            try container.encode(operations, forKey: .operations)
        }
        try container.encodeIfPresent(afterSelection, forKey: .afterSelection)
        try container.encodeIfPresent(beforeSelection, forKey: .beforeSelection)
    }
}

public typealias Operation = TransactionOperation
