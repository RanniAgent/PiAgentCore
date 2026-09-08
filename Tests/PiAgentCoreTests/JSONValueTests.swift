import Foundation
import Testing
@testable import PiAgentCore

struct JSONValueTests {
    @Test func decodesEveryJSONKind() throws {
        let value = try JSONValue.parse(#"{"a":1,"b":"x","c":true,"d":null,"e":[1,2.5],"f":{"g":false}}"#)
        #expect(value["a"] == .number(1))
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.stringValue == "x")
        #expect(value["c"]?.boolValue == true)
        #expect(value["d"] == .null)
        #expect(value["e"]?[1] == .number(2.5))
        #expect(value["f"]?["g"] == .bool(false))
    }

    @Test func encodesWithSortedKeysDeterministically() throws {
        let value: JSONValue = ["z": 1, "a": ["y": true, "b": "s"]]
        #expect(try value.serialized() == #"{"a":{"b":"s","y":true},"z":1}"#)
    }

    @Test func literalsBuildValues() {
        let value: JSONValue = ["n": 3, "f": 1.5, "s": "t", "b": false, "nil": nil, "arr": [1, "two"]]
        #expect(value["n"] == .number(3))
        #expect(value["f"] == .number(1.5))
        #expect(value["nil"] == .null)
        #expect(value["arr"]?.arrayValue?.count == 2)
    }

    @Test func bridgesFoundationValuesIncludingBooleans() throws {
        let any: [String: Any] = ["flag": true, "count": 2, "ratio": 0.5, "name": "n", "list": [1, "a"], "none": NSNull()]
        let value = try JSONValue(any: any)
        #expect(value["flag"] == .bool(true))       // NSNumber 的布尔要认出来，不能变成 1
        #expect(value["count"] == .number(2))
        #expect(value["ratio"] == .number(0.5))
        #expect(value["none"] == .null)
        let back = value.anyValue as? [String: Any]
        #expect(back?["flag"] as? Bool == true)
        #expect(back?["count"] as? Int == 2)
    }

    @Test func rejectsUnsupportedFoundationTypes() {
        #expect(throws: JSONValueError.self) { _ = try JSONValue(any: Date()) }
    }
}
