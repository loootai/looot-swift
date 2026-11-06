import Foundation

/// A JSON value. Responses keep every key the gateway sends, including ones this SDK does not
/// type yet, by holding their body as a `JSONValue`.
///
/// Build request input with literals: `["email": "jane@example.com", "limit": 5]`.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// The string, or nil when this value is not a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The number as a Double, or nil when this value is not a number.
    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The number as an Int, or nil when this value is not a whole number.
    public var intValue: Int? {
        if case .number(let n) = self { return Int(exactly: n) }
        return nil
    }

    /// The number as an Int64, or nil when this value is not a whole number.
    public var int64Value: Int64? {
        if case .number(let n) = self { return Int64(exactly: n) }
        return nil
    }

    /// The Bool, or nil when this value is not a Bool.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The elements, or nil when this value is not an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The members, or nil when this value is not an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// True for JSON null.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The member for `key`, or `.null` when this is not an object or the key is missing.
    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// The element at `index`, or `.null` when this is not an array or the index is out of range.
    public subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    /// Compact JSON text, keys sorted.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
