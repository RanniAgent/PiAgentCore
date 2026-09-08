import Testing
@testable import PiAgentCore
@testable import PiAgentTestSupport

struct TraceNormalizerTests {
    @Test func remapsToolCallIdsByFirstAppearanceAndDropsVolatileFields() {
        var normalizer = TraceNormalizer()
        let call = ToolCall(id: "toolu_abc", name: "echo", arguments: ["text": "a"])
        let assistant = AssistantMessage(content: [.toolCall(call)], api: "x", provider: "y", model: "z", usage: Usage(input: 9, output: 9), stopReason: .toolUse, timestamp: 123)
        let start = normalizer.normalize(.toolExecutionStart(toolCallId: "toolu_abc", toolName: "echo", args: ["text": "a"]))
        #expect(start == ["type": "tool_execution_start", "toolCallId": "tc1", "toolName": "echo", "args": ["text": "a"]])
        let end = normalizer.normalize(.messageEnd(message: .assistant(assistant)))
        #expect(end == ["type": "message_end", "message": ["role": "assistant", "stopReason": "toolUse", "content": [["type": "toolCall", "id": "tc1", "name": "echo", "arguments": ["text": "a"]]]]])
        let second = normalizer.normalize(.toolExecutionStart(toolCallId: "toolu_def", toolName: "echo", args: [:]))
        #expect(second?["toolCallId"] == "tc2")
    }

    @Test func abortedAssistantContentIsMaskedAndUpdatesAfterAbortDropped() {
        var normalizer = TraceNormalizer()
        let partial = AssistantMessage(content: [.text(TextContent(text: "par"))], api: "x", provider: "y", model: "z", stopReason: .pending, timestamp: 1)
        #expect(normalizer.normalize(.messageUpdate(message: .assistant(partial), assistantMessageEvent: .textDelta(contentIndex: 0, delta: "par", partial: partial))) == ["type": "message_update", "event": "text_delta", "contentIndex": 0, "delta": "par"])
        normalizer.markAborted()
        #expect(normalizer.normalize(.messageUpdate(message: .assistant(partial), assistantMessageEvent: .textDelta(contentIndex: 0, delta: "tial", partial: partial))) == nil)
        var aborted = partial
        aborted.stopReason = .aborted
        aborted.errorMessage = "Request was aborted"
        #expect(normalizer.normalize(.messageEnd(message: .assistant(aborted))) == ["type": "message_end", "message": ["role": "assistant", "stopReason": "aborted", "errorMessage": "Request was aborted", "content": "<aborted>"]])
    }
}
