import Foundation

/// A JSON value. Used for sync record payloads so the file format matches the Android app exactly.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int64(d) : nil
        case .string(let s): return Int64(s)
        default: return nil
        }
    }
    /// Platform Int (32-bit on Apple Watch hardware); nil if it doesn't fit.
    public var int: Int? { int64.flatMap { Int(exactly: $0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public static func from(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    public static func from(_ i: Int?) -> JSONValue { i.map { .int(Int64($0)) } ?? .null }
    public static func from(_ i: Int64?) -> JSONValue { i.map(JSONValue.int) ?? .null }

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    public func encodedString(sorted: Bool = false) -> String {
        let enc = JSONEncoder()
        if sorted { enc.outputFormatting = [.sortedKeys] }
        return (try? String(data: enc.encode(self), encoding: .utf8)) ?? "null"
    }
}
