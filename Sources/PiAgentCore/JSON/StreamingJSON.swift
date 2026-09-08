// 对应上游：packages/ai/src/utils/json-parse.ts。残缺解析器替代 partial-json。
import Foundation

public enum StreamingJSON {
    private static let validEscapes: Set<Character> = ["\"", "\\", "/", "b", "f", "n", "r", "t", "u"]

    /// 修复字符串字面量里的两类问题：裸控制字符、非法转义前的反斜杠。
    public static func repair(_ json: String) -> String {
        let chars = Array(json)
        var repaired = ""
        var inString = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if !inString {
                repaired.append(char)
                if char == "\"" { inString = true }
                index += 1
                continue
            }
            if char == "\"" {
                repaired.append(char)
                inString = false
                index += 1
                continue
            }
            if char == "\\" {
                guard index + 1 < chars.count else {
                    repaired += "\\\\"
                    index += 1
                    continue
                }
                let next = chars[index + 1]
                if next == "u" {
                    let digits = chars[(index + 2)..<min(index + 6, chars.count)]
                    if digits.count == 4, digits.allSatisfy(\.isHexDigit) {
                        repaired += "\\u" + String(digits)
                        index += 6
                        continue
                    }
                }
                if validEscapes.contains(next), next != "u" {
                    repaired.append("\\")
                    repaired.append(next)
                    index += 2
                    continue
                }
                repaired += "\\\\"
                index += 1
                continue
            }
            repaired += escapeIfControl(char)
            index += 1
        }
        return repaired
    }

    private static func escapeIfControl(_ char: Character) -> String {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1, scalar.value <= 0x1f else {
            return String(char)
        }
        switch char {
        case "\u{08}": return "\\b"
        case "\u{0C}": return "\\f"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default: return String(format: "\\u%04x", scalar.value)
        }
    }

    public static func parseWithRepair(_ json: String) throws -> JSONValue {
        do {
            return try JSONValue.parse(json)
        } catch {
            let repaired = repair(json)
            if repaired != json {
                return try JSONValue.parse(repaired)
            }
            throw error
        }
    }

    /// 流式期间的尽力解析：永远返回一个值，解析不了给空对象。
    public static func parseStreaming(_ partialJson: String) -> JSONValue {
        if partialJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .object([:])
        }
        if let value = try? parseWithRepair(partialJson) { return value }
        var parser = PartialJSONParser(partialJson)
        if let value = parser.parse() { return value }
        var repairedParser = PartialJSONParser(repair(partialJson))
        if let value = repairedParser.parse() { return value }
        return .object([:])
    }
}

/// 宽容的递归下降解析器：走到哪算哪，遇到结尾就把已经解析出来的部分交出去。
struct PartialJSONParser {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) { chars = Array(text) }

    mutating func parse() -> JSONValue? {
        skipWhitespace()
        let value = parseValue()
        return value
    }

    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard index < chars.count else { return nil }
        switch chars[index] {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return .string(parseString())
        case "t": return parseLiteral("true", .bool(true))
        case "f": return parseLiteral("false", .bool(false))
        case "n": return parseLiteral("null", .null)
        case "-", "0"..."9": return parseNumber()
        default: return nil
        }
    }

    private mutating func parseObject() -> JSONValue {
        index += 1  // {
        var object: [String: JSONValue] = [:]
        while true {
            skipWhitespace()
            guard index < chars.count else { return .object(object) }
            if chars[index] == "}" { index += 1; return .object(object) }
            if chars[index] == "," { index += 1; continue }
            guard chars[index] == "\"" else { return .object(object) }
            let keyStart = index
            let key = parseString()
            // 键没闭合（到了结尾）就不算这一对
            if index >= chars.count, chars[keyStart...].filter({ $0 == "\"" }).count < 2 { return .object(object) }
            skipWhitespace()
            guard index < chars.count, chars[index] == ":" else { return .object(object) }
            index += 1
            guard let value = parseValue() else { return .object(object) }
            object[key] = value
        }
    }

    private mutating func parseArray() -> JSONValue {
        index += 1  // [
        var array: [JSONValue] = []
        while true {
            skipWhitespace()
            guard index < chars.count else { return .array(array) }
            if chars[index] == "]" { index += 1; return .array(array) }
            if chars[index] == "," { index += 1; continue }
            guard let value = parseValue() else { return .array(array) }
            array.append(value)
        }
    }

    private mutating func parseString() -> String {
        index += 1  // 开引号
        var result = ""
        while index < chars.count {
            let char = chars[index]
            if char == "\"" { index += 1; return result }
            if char == "\\" {
                guard index + 1 < chars.count else { index += 1; return result }  // 尾巴上的孤反斜杠丢掉
                let next = chars[index + 1]
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    let digits = chars[(index + 2)..<min(index + 6, chars.count)]
                    if digits.count == 4, let code = UInt32(String(digits), radix: 16), let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                        index += 6
                        continue
                    }
                    index = chars.count
                    return result
                default: result.append(next)
                }
                index += 2
                continue
            }
            result.append(char)
            index += 1
        }
        return result
    }

    private mutating func parseNumber() -> JSONValue? {
        var token = ""
        while index < chars.count, "-+.eE0123456789".contains(chars[index]) {
            token.append(chars[index])
            index += 1
        }
        while let last = token.last, "-+.eE".contains(last) { token.removeLast() }
        guard let value = Double(token) else { return nil }
        return .number(value)
    }

    private mutating func parseLiteral(_ literal: String, _ value: JSONValue) -> JSONValue? {
        var matched = 0
        for char in literal {
            guard index + matched < chars.count else { break }
            guard chars[index + matched] == char else { return nil }
            matched += 1
        }
        guard matched > 0 else { return nil }
        index += matched
        return value
    }

    private mutating func skipWhitespace() {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }
}
