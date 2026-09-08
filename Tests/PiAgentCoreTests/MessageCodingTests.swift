import Foundation
import Testing
@testable import PiAgentCore

struct MessageCodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T, _ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func decodesAssistantMessageInPiShape() throws {
        let json = """
        {"role":"assistant","content":[
          {"type":"thinking","thinking":"hmm","thinkingSignature":"sig"},
          {"type":"text","text":"hi"},
          {"type":"toolCall","id":"call_1","name":"echo","arguments":{"text":"a"}}
        ],"api":"faux","provider":"faux","model":"faux-1",
        "usage":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"totalTokens":3,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},
        "stopReason":"toolUse","timestamp":1700000000000}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
        guard case .assistant(let assistant) = message else { Issue.record("expected assistant"); return }
        #expect(assistant.content.count == 3)
        #expect(assistant.content[0] == .thinking(ThinkingContent(thinking: "hmm", thinkingSignature: "sig")))
        #expect(assistant.content[2] == .toolCall(ToolCall(id: "call_1", name: "echo", arguments: ["text": "a"])))
        #expect(assistant.stopReason == .toolUse)
        #expect(assistant.usage.totalTokens == 3)
        #expect(assistant.timestamp == 1_700_000_000_000)
        #expect(try roundTrip(message) == message)
    }

    @Test func userContentIsStringOrBlocks() throws {
        let plain = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"role":"user","content":"hello","timestamp":1}"#.utf8))
        #expect(plain == .user(UserMessage(content: .text("hello"), timestamp: 1)))
        let blocks = try JSONDecoder().decode(AgentMessage.self, from: Data(#"{"role":"user","content":[{"type":"text","text":"see"},{"type":"image","data":"AAA=","mimeType":"image/png"}],"timestamp":2}"#.utf8))
        guard case .user(let user) = blocks, case .blocks(let items) = user.content else { Issue.record("expected blocks"); return }
        #expect(items.count == 2)
        #expect(try roundTrip(blocks) == blocks)
    }

    @Test func toolResultAndCustomRoundTrip() throws {
        let result = AgentMessage.toolResult(ToolResultMessage(
            toolCallId: "call_1", toolName: "echo",
            content: [.text(TextContent(text: "ok"))], details: ["exitCode": 0],
            usage: nil, addedToolNames: nil, isError: false, timestamp: 5
        ))
        #expect(try roundTrip(result) == result)
        let custom = AgentMessage.custom(CustomAgentMessage(customType: "notice", payload: ["text": "x"], timestamp: 6))
        let encoded = String(decoding: try JSONEncoder().encode(custom), as: UTF8.self)
        #expect(encoded.contains(#""role":"custom""#))
        #expect(try roundTrip(custom) == custom)
    }

    @Test func llmMessageRejectsCustomRole() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"custom","customType":"n","payload":null,"timestamp":1}"#.utf8))
        }
    }

    @Test func usageConvenienceFillsTotals() {
        let usage = Usage(input: 3, output: 4)
        #expect(usage.totalTokens == 7)
        #expect(usage.cacheRead == 0)
        #expect(Usage.zero.totalTokens == 0)
    }
}
