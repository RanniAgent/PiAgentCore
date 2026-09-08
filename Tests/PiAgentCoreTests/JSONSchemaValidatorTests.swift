import Testing
@testable import PiAgentCore

struct JSONSchemaValidatorTests {
    let schema: JSONValue = [
        "type": "object",
        "properties": [
            "command": ["type": "string"],
            "timeout_ms": ["type": "integer"],
            "verbose": ["type": "boolean"],
            "ratio": ["type": "number"],
            "note": ["type": "string"],
            "mode": ["type": "string", "enum": ["fast", "slow"]],
            "tags": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["command"],
        "additionalProperties": false,
    ]

    @Test func passesValidArgumentsUnchanged() throws {
        let args: JSONValue = ["command": "ls", "timeout_ms": 5, "tags": ["a"]]
        #expect(try JSONSchemaValidator.validate(schema: schema, arguments: args) == args)
    }

    @Test func coercesPrimitivesTheWayPiDoes() throws {
        let args: JSONValue = ["command": 42, "timeout_ms": "12", "verbose": "true", "ratio": "0.5"]
        let validated = try JSONSchemaValidator.validate(schema: schema, arguments: args)
        #expect(validated["command"] == "42")
        #expect(validated["timeout_ms"] == 12)
        #expect(validated["verbose"] == true)
        #expect(validated["ratio"] == 0.5)
    }

    @Test func dropsNullOnOptionalPropertiesThatDoNotAcceptNull() throws {
        let validated = try JSONSchemaValidator.validate(schema: schema, arguments: ["command": "ls", "note": nil])
        #expect(validated["note"] == nil)
        #expect(validated == ["command": "ls"])
    }

    @Test func reportsMissingRequiredWithPiStylePath() {
        #expect(throws: ToolArgumentValidationError(path: "command", message: "Required property")) {
            _ = try JSONSchemaValidator.validate(schema: schema, arguments: ["timeout_ms": 1])
        }
    }

    @Test func reportsWrongTypeAndUnknownProperty() {
        #expect(throws: ToolArgumentValidationError(path: "tags.0", message: "Expected string")) {
            _ = try JSONSchemaValidator.validate(schema: schema, arguments: ["command": "ls", "tags": [[:]]])
        }
        #expect(throws: ToolArgumentValidationError(path: "root", message: "Unexpected property 'extra'")) {
            _ = try JSONSchemaValidator.validate(schema: schema, arguments: ["command": "ls", "extra": 1])
        }
        #expect(throws: ToolArgumentValidationError(path: "mode", message: "Expected one of: fast, slow")) {
            _ = try JSONSchemaValidator.validate(schema: schema, arguments: ["command": "ls", "mode": "medium"])
        }
    }

    @Test func unionKeepsValuesThatAlreadyMatchOneArm() throws {
        let unionSchema: JSONValue = ["type": "object", "properties": ["v": ["anyOf": [["type": "number"], ["type": "string"]]]]]
        #expect(try JSONSchemaValidator.validate(schema: unionSchema, arguments: ["v": "7"]) == ["v": "7"])
        #expect(try JSONSchemaValidator.validate(schema: unionSchema, arguments: ["v": 7]) == ["v": 7])
        let typeUnion: JSONValue = ["type": "object", "properties": ["v": ["type": ["number", "string"]]]]
        #expect(try JSONSchemaValidator.validate(schema: typeUnion, arguments: ["v": "7"]) == ["v": "7"])
    }
}
