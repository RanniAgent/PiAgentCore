// 对应上游：@earendil-works/chord 的 JsonValue；pi 里所有 Record<string, any> 的载体。
import Foundation

public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum JSONValueError: Error, Equatable {
    case unsupported(String)
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - 字面量

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - 访问

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var doubleValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    /// 整数视图：只有数值本身是整数时才给。
    public var intValue: Int? {
        guard case .number(let value) = self, value == value.rounded(), abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }
}

// MARK: - Foundation 桥接与序列化

extension JSONValue {
    /// 从 JSONSerialization 产出的 Any 树构造。NSNumber 里的布尔要认出来。
    public init(any: Any) throws {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(try object.mapValues(JSONValue.init(any:)))
        default:
            throw JSONValueError.unsupported(String(describing: type(of: any)))
        }
    }

    /// 反向桥接：整数值给 Int，其余给 Double。
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// 序列化。默认按键排序，保证两端比对时输出稳定。
    public func serialized(sortedKeys: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
