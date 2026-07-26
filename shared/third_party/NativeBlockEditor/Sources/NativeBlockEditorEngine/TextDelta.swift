import Foundation

public typealias TextAttributes = [String: JSONValue]

/// Quill/AppFlowy text operations. Lengths and offsets are UTF-16 code units.
public enum TextOperation: Hashable, Sendable {
    case insert(String, attributes: TextAttributes? = nil)
    case retain(Int, attributes: TextAttributes? = nil)
    case delete(Int)

    public var length: Int {
        switch self {
        case let .insert(text, _): text.utf16.count
        case let .retain(length, _), let .delete(length): length
        }
    }

    public var attributes: TextAttributes? {
        switch self {
        case let .insert(_, attributes), let .retain(_, attributes): attributes
        case .delete: nil
        }
    }
}

extension TextOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case insert, retain, delete, attributes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attributes = try container.decodeIfPresent(TextAttributes.self, forKey: .attributes)
        let operationKeyCount = [
            container.contains(.insert),
            container.contains(.retain),
            container.contains(.delete),
        ].filter { $0 }.count
        guard operationKeyCount == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "A delta operation needs exactly one operation key")
            )
        }
        if container.contains(.insert) {
            self = .insert(try container.decode(String.self, forKey: .insert), attributes: attributes)
        } else if container.contains(.retain) {
            self = .retain(try container.decode(Int.self, forKey: .retain), attributes: attributes)
        } else {
            guard attributes == nil else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Delete cannot carry attributes")
                )
            }
            self = .delete(try container.decode(Int.self, forKey: .delete))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .insert(text, attributes):
            try container.encode(text, forKey: .insert)
            if let attributes, !attributes.isEmpty {
                try container.encode(attributes, forKey: .attributes)
            }
        case let .retain(length, attributes):
            try container.encode(length, forKey: .retain)
            if let attributes, !attributes.isEmpty {
                try container.encode(attributes, forKey: .attributes)
            }
        case let .delete(length):
            try container.encode(length, forKey: .delete)
        }
    }
}

public struct TextDelta: Codable, Hashable, Sendable {
    public var operations: [TextOperation]

    public init(_ operations: [TextOperation] = []) {
        self.operations = operations
    }

    public static func content(
        _ text: String,
        attributes: TextAttributes? = nil
    ) -> TextDelta {
        text.isEmpty ? TextDelta() : TextDelta([.insert(text, attributes: attributes)])
    }

    public var plainText: String {
        operations.reduce(into: "") { result, operation in
            if case let .insert(text, _) = operation { result += text }
        }
    }

    /// Quill's delta length: the sum of all operation lengths.
    public var utf16Length: Int {
        operations.reduce(0) { $0 + $1.length }
    }

    public var contentUTF16Length: Int {
        operations.reduce(0) { result, operation in
            if case let .insert(text, _) = operation { return result + text.utf16.count }
            return result
        }
    }

    /// Returns whether an offset lands on a valid UTF-16 scalar boundary.
    public func isValidUTF16Boundary(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= contentUTF16Length else { return false }
        let codeUnits = Array(plainText.utf16)
        guard offset > 0, offset < codeUnits.count else { return true }
        return !(codeUnits[offset - 1].isHighSurrogate && codeUnits[offset].isLowSurrogate)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [TextOperation] = []
        while !container.isAtEnd {
            result.append(try container.decode(TextOperation.self))
        }
        operations = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for operation in operations {
            try container.encode(operation)
        }
    }

    public var jsonValue: JSONValue {
        .array(operations.map(\.jsonValue))
    }

    public init(jsonValue: JSONValue) throws {
        guard case let .array(values) = jsonValue else {
            throw DocumentEngineError.invalidDelta("delta must be a JSON array")
        }
        operations = try values.map(TextOperation.init(jsonValue:))
    }

    public func validate(asContent: Bool = false) throws {
        for operation in operations {
            switch operation {
            case let .insert(text, _):
                if asContent, text.isEmpty {
                    throw DocumentEngineError.invalidDelta("content contains an empty insert")
                }
            case let .retain(length, _):
                if asContent {
                    throw DocumentEngineError.invalidDelta("content delta cannot contain retain")
                }
                guard length > 0 else {
                    throw DocumentEngineError.invalidDelta("retain length must be positive")
                }
            case let .delete(length):
                if asContent {
                    throw DocumentEngineError.invalidDelta("content delta cannot contain delete")
                }
                guard length > 0 else {
                    throw DocumentEngineError.invalidDelta("delete length must be positive")
                }
            }
        }
    }

    public func normalized() -> TextDelta {
        var result: [TextOperation] = []

        func append(_ operation: TextOperation) {
            guard operation.length > 0 else { return }

            // Quill canonical order puts an insert before a delete at the same index.
            if case .insert = operation, case .delete = result.last {
                let deletion = result.removeLast()
                append(operation)
                append(deletion)
                return
            }

            guard let last = result.last else {
                result.append(operation)
                return
            }
            switch (last, operation) {
            case let (.insert(lhs, lhsAttributes), .insert(rhs, rhsAttributes))
                where normalizedAttributes(lhsAttributes) == normalizedAttributes(rhsAttributes):
                result[result.count - 1] = .insert(lhs + rhs, attributes: normalizedAttributes(lhsAttributes))
            case let (.retain(lhs, lhsAttributes), .retain(rhs, rhsAttributes))
                where normalizedAttributes(lhsAttributes) == normalizedAttributes(rhsAttributes):
                result[result.count - 1] = .retain(lhs + rhs, attributes: normalizedAttributes(lhsAttributes))
            case let (.delete(lhs), .delete(rhs)):
                result[result.count - 1] = .delete(lhs + rhs)
            default:
                result.append(operation.normalizingAttributes)
            }
        }

        for operation in operations { append(operation.normalizingAttributes) }
        return TextDelta(result)
    }

    public func slice(from start: Int, to end: Int? = nil) throws -> TextDelta {
        let upperBound = end ?? utf16Length
        guard start >= 0, upperBound >= start, upperBound <= utf16Length else {
            throw DocumentEngineError.invalidRange("slice \(start)..<\(upperBound) exceeds delta length \(utf16Length)")
        }
        guard start != upperBound else { return TextDelta() }

        var result: [TextOperation] = []
        var cursor = 0
        for operation in operations {
            let operationEnd = cursor + operation.length
            let overlapStart = max(start, cursor)
            let overlapEnd = min(upperBound, operationEnd)
            if overlapStart < overlapEnd {
                let localStart = overlapStart - cursor
                let localEnd = overlapEnd - cursor
                switch operation {
                case let .insert(text, attributes):
                    result.append(.insert(try text.utf16Slice(from: localStart, to: localEnd), attributes: attributes))
                case let .retain(_, attributes):
                    result.append(.retain(localEnd - localStart, attributes: attributes))
                case .delete:
                    result.append(.delete(localEnd - localStart))
                }
            }
            cursor = operationEnd
            if cursor >= upperBound { break }
        }
        return TextDelta(result).normalized()
    }

    /// Applies this change delta to an insert-only content delta.
    public func applying(to content: TextDelta) throws -> TextDelta {
        try validate()
        try content.validate(asContent: true)
        var cursor = ContentCursor(content: content)
        var output: [TextOperation] = []

        for operation in operations {
            switch operation {
            case let .insert(text, attributes):
                output.append(.insert(text, attributes: removingNulls(attributes)))
            case let .retain(length, attributes):
                let segments = try cursor.consume(length)
                output.append(contentsOf: segments.map { segment in
                    .insert(segment.text, attributes: composing(segment.attributes, with: attributes))
                })
            case let .delete(length):
                _ = try cursor.consume(length)
            }
        }
        output.append(contentsOf: try cursor.consumeRemaining().map {
            .insert($0.text, attributes: $0.attributes)
        })
        return TextDelta(output).normalized()
    }

    /// Builds a change that reverses this change when applied to its result.
    public func inverted(against content: TextDelta) throws -> TextDelta {
        try validate()
        try content.validate(asContent: true)
        var cursor = ContentCursor(content: content)
        var inverse: [TextOperation] = []

        for operation in operations {
            switch operation {
            case let .insert(text, _):
                inverse.append(.delete(text.utf16.count))
            case let .delete(length):
                let deleted = try cursor.consume(length)
                inverse.append(contentsOf: deleted.map {
                    .insert($0.text, attributes: $0.attributes)
                })
            case let .retain(length, attributes):
                let retained = try cursor.consume(length)
                guard let attributes, !attributes.isEmpty else {
                    inverse.append(.retain(length))
                    continue
                }
                for segment in retained {
                    var invertedAttributes: TextAttributes = [:]
                    for key in attributes.keys {
                        invertedAttributes[key] = segment.attributes?[key] ?? .null
                    }
                    inverse.append(.retain(segment.text.utf16.count, attributes: invertedAttributes))
                }
            }
        }
        return TextDelta(inverse).normalized()
    }
}

private extension TextOperation {
    var normalizingAttributes: TextOperation {
        switch self {
        case let .insert(text, attributes): .insert(text, attributes: normalizedAttributes(attributes))
        case let .retain(length, attributes): .retain(length, attributes: normalizedAttributes(attributes))
        case let .delete(length): .delete(length)
        }
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue]
        switch self {
        case let .insert(text, attributes):
            object = ["insert": .string(text)]
            if let attributes, !attributes.isEmpty { object["attributes"] = .object(attributes) }
        case let .retain(length, attributes):
            object = ["retain": .integer(length)]
            if let attributes, !attributes.isEmpty { object["attributes"] = .object(attributes) }
        case let .delete(length):
            object = ["delete": .integer(length)]
        }
        return .object(object)
    }

    init(jsonValue: JSONValue) throws {
        guard case let .object(object) = jsonValue else {
            throw DocumentEngineError.invalidDelta("operation must be a JSON object")
        }
        let attributes: TextAttributes?
        if let value = object["attributes"] {
            guard case let .object(decoded) = value else {
                throw DocumentEngineError.invalidDelta("attributes must be a JSON object")
            }
            attributes = decoded
        } else {
            attributes = nil
        }
        let keys = ["insert", "retain", "delete"].filter { object[$0] != nil }
        guard keys.count == 1 else {
            throw DocumentEngineError.invalidDelta("operation needs exactly one of insert, retain, or delete")
        }
        switch keys[0] {
        case "insert":
            guard let text = object["insert"]?.stringValue else {
                throw DocumentEngineError.invalidDelta("insert must be a string")
            }
            self = .insert(text, attributes: attributes)
        case "retain":
            guard let length = object["retain"]?.intValue else {
                throw DocumentEngineError.invalidDelta("retain must be an integer")
            }
            self = .retain(length, attributes: attributes)
        default:
            guard attributes == nil, let length = object["delete"]?.intValue else {
                throw DocumentEngineError.invalidDelta("delete must be an integer and cannot have attributes")
            }
            self = .delete(length)
        }
    }
}

private struct TextSegment {
    var text: String
    var attributes: TextAttributes?
}

private struct ContentCursor {
    private var segments: [TextSegment]
    private var segmentIndex = 0
    private var offset = 0

    init(content: TextDelta) {
        segments = content.operations.compactMap { operation in
            guard case let .insert(text, attributes) = operation else { return nil }
            return TextSegment(text: text, attributes: normalizedAttributes(attributes))
        }
    }

    mutating func consume(_ requestedLength: Int) throws -> [TextSegment] {
        guard requestedLength >= 0 else {
            throw DocumentEngineError.invalidRange("negative consume length")
        }
        var remaining = requestedLength
        var result: [TextSegment] = []
        while remaining > 0 {
            guard segmentIndex < segments.count else {
                throw DocumentEngineError.invalidRange("change extends beyond content")
            }
            let segment = segments[segmentIndex]
            let available = segment.text.utf16.count - offset
            let take = min(remaining, available)
            let text = try segment.text.utf16Slice(from: offset, to: offset + take)
            result.append(TextSegment(text: text, attributes: segment.attributes))
            offset += take
            remaining -= take
            if offset == segment.text.utf16.count {
                segmentIndex += 1
                offset = 0
            }
        }
        return result
    }

    mutating func consumeRemaining() throws -> [TextSegment] {
        var result: [TextSegment] = []
        while segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            let text = try segment.text.utf16Slice(from: offset, to: segment.text.utf16.count)
            if !text.isEmpty { result.append(TextSegment(text: text, attributes: segment.attributes)) }
            segmentIndex += 1
            offset = 0
        }
        return result
    }
}

private func normalizedAttributes(_ attributes: TextAttributes?) -> TextAttributes? {
    guard let attributes, !attributes.isEmpty else { return nil }
    return attributes
}

private func removingNulls(_ attributes: TextAttributes?) -> TextAttributes? {
    guard var attributes else { return nil }
    attributes = attributes.filter { $0.value != .null }
    return attributes.isEmpty ? nil : attributes
}

private func composing(
    _ base: TextAttributes?,
    with change: TextAttributes?
) -> TextAttributes? {
    guard let change, !change.isEmpty else { return normalizedAttributes(base) }
    var result = base ?? [:]
    for (key, value) in change {
        if value == .null {
            result.removeValue(forKey: key)
        } else {
            result[key] = value
        }
    }
    return result.isEmpty ? nil : result
}

private extension String {
    func utf16Slice(from start: Int, to end: Int) throws -> String {
        guard start >= 0, end >= start, end <= utf16.count else {
            throw DocumentEngineError.invalidRange("UTF-16 slice \(start)..<\(end) exceeds string length \(utf16.count)")
        }
        let codeUnits = Array(utf16)
        if start > 0, start < codeUnits.count,
           codeUnits[start - 1].isHighSurrogate, codeUnits[start].isLowSurrogate {
            throw DocumentEngineError.invalidRange("offset splits a UTF-16 surrogate pair")
        }
        if end > 0, end < codeUnits.count,
           codeUnits[end - 1].isHighSurrogate, codeUnits[end].isLowSurrogate {
            throw DocumentEngineError.invalidRange("offset splits a UTF-16 surrogate pair")
        }
        return String(decoding: codeUnits[start ..< end], as: UTF16.self)
    }
}

private extension UInt16 {
    var isHighSurrogate: Bool { (0xD800 ... 0xDBFF).contains(self) }
    var isLowSurrogate: Bool { (0xDC00 ... 0xDFFF).contains(self) }
}
