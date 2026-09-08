// 对应上游：packages/ai/src/utils/validation.ts。typebox 换成自写子集校验器，纠偏规则照搬。
import Foundation

public struct ToolArgumentValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
    public var description: String { "\(path): \(message)" }
}

public enum JSONSchemaValidator {
    /// 删可选 null → 纠偏 → 校验。顺序和上游 validateToolArguments 一致
    /// （先 normalizeOptionalNulls，再 Value.Convert / coerceWithJsonSchema），
    /// 否则 `note: null` 会先被纠偏成 ""，就删不掉了。
    /// 返回纠偏后的参数；第一条错误抛出。
    public static func validate(schema: JSONValue, arguments: JSONValue) throws -> JSONValue {
        var value = normalizeOptionalNulls(arguments, schema: schema)
        value = coerce(value, schema: schema)
        if let error = check(value, schema: schema, path: []).first {
            throw error
        }
        return value
    }

    /// 只校验不纠偏。
    public static func matches(_ value: JSONValue, schema: JSONValue) -> Bool {
        check(value, schema: schema, path: []).isEmpty
    }

    // MARK: - 校验

    static func check(_ value: JSONValue, schema: JSONValue, path: [String]) -> [ToolArgumentValidationError] {
        var errors: [ToolArgumentValidationError] = []
        let pathText = path.isEmpty ? "root" : path.joined(separator: ".")

        if let allOf = schema["allOf"]?.arrayValue {
            for nested in allOf { errors += check(value, schema: nested, path: path) }
        }
        if let anyOf = schema["anyOf"]?.arrayValue, !anyOf.isEmpty {
            if !anyOf.contains(where: { check(value, schema: $0, path: path).isEmpty }) {
                errors.append(ToolArgumentValidationError(path: pathText, message: "Expected value to match one of the schemas"))
            }
        }
        if let oneOf = schema["oneOf"]?.arrayValue, !oneOf.isEmpty {
            if !oneOf.contains(where: { check(value, schema: $0, path: path).isEmpty }) {
                errors.append(ToolArgumentValidationError(path: pathText, message: "Expected value to match one of the schemas"))
            }
        }
        if let constant = schema["const"], value != constant {
            errors.append(ToolArgumentValidationError(path: pathText, message: "Expected constant value"))
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            let names = options.map { $0.stringValue ?? ((try? $0.serialized()) ?? "?") }.joined(separator: ", ")
            errors.append(ToolArgumentValidationError(path: pathText, message: "Expected one of: \(names)"))
        }

        let types = schemaTypes(schema)
        if !types.isEmpty, !types.contains(where: { matchesType(value, $0) }) {
            errors.append(ToolArgumentValidationError(path: pathText, message: "Expected \(types.joined(separator: " | "))"))
            return errors
        }

        if case .object(let object) = value {
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[required] == nil {
                errors.append(ToolArgumentValidationError(path: (path + [required]).joined(separator: "."), message: "Required property"))
            }
            for (key, propertySchema) in properties {
                if let propertyValue = object[key] {
                    errors += check(propertyValue, schema: propertySchema, path: path + [key])
                }
            }
            if schema["additionalProperties"] == .bool(false) {
                for key in object.keys.sorted() where properties[key] == nil {
                    errors.append(ToolArgumentValidationError(path: pathText, message: "Unexpected property '\(key)'"))
                }
            } else if let extraSchema = schema["additionalProperties"], case .object = extraSchema {
                for (key, propertyValue) in object where properties[key] == nil {
                    errors += check(propertyValue, schema: extraSchema, path: path + [key])
                }
            }
        }

        if case .array(let array) = value, let items = schema["items"] {
            if let tuple = items.arrayValue {
                for (offset, element) in array.enumerated() where offset < tuple.count {
                    errors += check(element, schema: tuple[offset], path: path + [String(offset)])
                }
            } else {
                for (offset, element) in array.enumerated() {
                    errors += check(element, schema: items, path: path + [String(offset)])
                }
            }
        }
        return errors
    }

    static func schemaTypes(_ schema: JSONValue) -> [String] {
        if let single = schema["type"]?.stringValue { return [single] }
        if let many = schema["type"]?.arrayValue { return many.compactMap(\.stringValue) }
        return []
    }

    static func matchesType(_ value: JSONValue, _ type: String) -> Bool {
        switch type {
        case "number": return value.doubleValue != nil
        case "integer": return value.intValue != nil
        case "boolean": return value.boolValue != nil
        case "string": return value.stringValue != nil
        case "null": return value.isNull
        case "array": return value.arrayValue != nil
        case "object": return value.objectValue != nil
        default: return false
        }
    }

    // MARK: - 纠偏（照搬 coerceWithJsonSchema）

    static func coerce(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        var next = value
        if let allOf = schema["allOf"]?.arrayValue {
            for nested in allOf { next = coerce(next, schema: nested) }
        }
        if let anyOf = schema["anyOf"]?.arrayValue { next = coerceUnion(next, schemas: anyOf) }
        if let oneOf = schema["oneOf"]?.arrayValue { next = coerceUnion(next, schemas: oneOf) }

        let types = schemaTypes(schema)
        let matchesUnionMember = types.count > 1 && types.contains(where: { matchesType(next, $0) })
        if !types.isEmpty, !matchesUnionMember {
            for type in types {
                let candidate = coercePrimitive(next, type: type)
                if candidate != next { next = candidate; break }
            }
        }
        if types.contains("object"), case .object(var object) = next {
            let properties = schema["properties"]?.objectValue ?? [:]
            for (key, propertySchema) in properties {
                if let propertyValue = object[key] { object[key] = coerce(propertyValue, schema: propertySchema) }
            }
            if let extraSchema = schema["additionalProperties"], case .object = extraSchema {
                for (key, propertyValue) in object where properties[key] == nil {
                    object[key] = coerce(propertyValue, schema: extraSchema)
                }
            }
            next = .object(object)
        }
        if types.contains("array"), case .array(var array) = next, let items = schema["items"] {
            if let tuple = items.arrayValue {
                for offset in array.indices where offset < tuple.count { array[offset] = coerce(array[offset], schema: tuple[offset]) }
            } else {
                for offset in array.indices { array[offset] = coerce(array[offset], schema: items) }
            }
            next = .array(array)
        }
        return next
    }

    static func coerceUnion(_ value: JSONValue, schemas: [JSONValue]) -> JSONValue {
        if schemas.contains(where: { matches(value, schema: $0) }) { return value }
        for schema in schemas {
            let coerced = coerce(value, schema: schema)
            if matches(coerced, schema: schema) { return coerced }
        }
        return value
    }

    static func coercePrimitive(_ value: JSONValue, type: String) -> JSONValue {
        switch type {
        case "number":
            if value.isNull { return .number(0) }
            if let string = value.stringValue, !string.trimmingCharacters(in: .whitespaces).isEmpty, let parsed = Double(string), parsed.isFinite { return .number(parsed) }
            if let bool = value.boolValue { return .number(bool ? 1 : 0) }
            return value
        case "integer":
            if value.isNull { return .number(0) }
            if let string = value.stringValue, !string.trimmingCharacters(in: .whitespaces).isEmpty, let parsed = Double(string), parsed == parsed.rounded() { return .number(parsed) }
            if let bool = value.boolValue { return .number(bool ? 1 : 0) }
            return value
        case "boolean":
            if value.isNull { return .bool(false) }
            if value.stringValue == "true" { return .bool(true) }
            if value.stringValue == "false" { return .bool(false) }
            if value.doubleValue == 1 { return .bool(true) }
            if value.doubleValue == 0 { return .bool(false) }
            return value
        case "string":
            if value.isNull { return .string("") }
            if let number = value.doubleValue {
                return .string(number == number.rounded() && abs(number) < 9_007_199_254_740_992 ? String(Int(number)) : String(number))
            }
            if let bool = value.boolValue { return .string(bool ? "true" : "false") }
            return value
        case "null":
            if value == .string("") || value == .number(0) || value == .bool(false) { return .null }
            return value
        default:
            return value
        }
    }

    // MARK: - 可选字段的 null（照搬 normalizeOptionalNulls）

    static func normalizeOptionalNulls(_ value: JSONValue, schema: JSONValue) -> JSONValue {
        if case .array(var array) = value {
            if let tuple = schema["items"]?.arrayValue {
                for offset in array.indices where offset < tuple.count { array[offset] = normalizeOptionalNulls(array[offset], schema: tuple[offset]) }
            } else if let items = schema["items"] {
                for offset in array.indices { array[offset] = normalizeOptionalNulls(array[offset], schema: items) }
            }
            return .array(array)
        }
        guard case .object(var object) = value, let properties = schema["properties"]?.objectValue else { return value }
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for (key, propertySchema) in properties {
            guard let propertyValue = object[key] else { continue }
            if propertyValue.isNull, !required.contains(key), propertySchema["$ref"] == nil, !matches(.null, schema: propertySchema) {
                object.removeValue(forKey: key)
            } else {
                object[key] = normalizeOptionalNulls(propertyValue, schema: propertySchema)
            }
        }
        return .object(object)
    }
}
