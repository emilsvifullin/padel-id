import Foundation

/// A loosely typed JSON value for heterogeneous payloads (insight values,
/// compatibility reasons, rating explanations).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    var double: Double? {
        switch self {
        case .number(let v): v
        case .string(let s): Double(s)
        default: nil
        }
    }

    var int: Int? { double.map { Int($0.rounded()) } }

    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Re-decodes this value as a concrete model.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONCoding.decoder.decode(T.self, from: data)
    }
}
