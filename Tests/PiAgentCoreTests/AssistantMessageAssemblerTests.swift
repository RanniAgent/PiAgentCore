import Testing
@testable import PiAgentCore

struct AssistantMessageAssemblerTests {
    let model = Model(id: "m", name: "m", api: "transport", provider: "p", baseUrl: "", reasoning: true, input: ["text"], cost: .zero, contextWindow: 1000, maxTokens: 100)

    private func kinds(_ events: [AssistantMessageEvent]) -> [String] {
        events.map { event in
            switch event {
            case .start: return "start"
            case .textStart(let i, _): return "text_start:\(i)"
            case .textDelta(let i, let d, _): return "text_delta:\(i):\(d)"
            case .textEnd(let i, let c, _): return "text_end:\(i):\(c)"
            case .thinkingStart(let i, _): return "thinking_start:\(i)"
            case .thinkingDelta(let i, let d, _): return "thinking_delta:\(i):\(d)"
            case .thinkingEnd(let i, let c, _): return "thinking_end:\(i):\(c)"
            case .toolcallStart(let i, _): return "toolcall_start:\(i)"
            case .toolcallDelta(let i, let d, _): return "toolcall_delta:\(i):\(d)"
            case .toolcallEnd(let i, let call, _): return "toolcall_end:\(i):\(call.name)"
            case .done(let r, _): return "done:\(r.rawValue)"
            case .error(let r, _): return "error:\(r.rawValue)"
            }
        }
    }

    @Test func assemblesThinkingTextAndToolCallInOrder() {
        var assembler = AssistantMessageAssembler(model: model, timestamp: 1)
        var events: [AssistantMessageEvent] = [assembler.start()]
        events += assembler.consume(.thinkingDelta("let me "))
        events += assembler.consume(.thinkingDelta("think"))
        events += assembler.consume(.thinkingSignature("sig"))
        events += assembler.consume(.textDelta("I will run ls."))
        events += assembler.consume(.toolCallStart(id: "call_1", name: "linux_command"))
        events += assembler.consume(.toolCallArgumentsDelta(id: "call_1", fragment: #"{"comm"#))
        events += assembler.consume(.toolCallArgumentsDelta(id: "call_1", fragment: #"and":"ls"}"#))
        events += assembler.consume(.toolCallEnd(id: "call_1", name: "linux_command", argumentsJSON: #"{"command":"ls"}"#))
        events += assembler.consume(.finished(stopReason: .toolUse, usage: Usage(input: 5, output: 6), rawStopReason: "tool_use"))

        #expect(kinds(events) == [
            "start",
            "thinking_start:0", "thinking_delta:0:let me ", "thinking_delta:0:think",
            "thinking_end:0:let me think",
            "text_start:1", "text_delta:1:I will run ls.",
            "text_end:1:I will run ls.",
            "toolcall_start:2", "toolcall_delta:2:{\"comm", "toolcall_delta:2:and\":\"ls\"}",
            "toolcall_end:2:linux_command",
            "done:toolUse",
        ])
        let final = assembler.partial
        #expect(final.stopReason == .toolUse)
        #expect(final.usage.input == 5)
        #expect(final.content[0] == .thinking(ThinkingContent(thinking: "let me think", thinkingSignature: "sig")))
        #expect(final.content[2] == .toolCall(ToolCall(id: "call_1", name: "linux_command", arguments: ["command": "ls"])))
        #expect(assembler.isFinished)

        // 中途的 partial 里，工具参数应是尽力解析出来的对象
        if case .toolcallDelta(_, _, let partial) = events[9], case .toolCall(let call) = partial.content[2] {
            #expect(call.arguments == [:])   // "{\"comm" 还解析不出键
        }
    }

    @Test func toolCallEndWithoutStartOpensAndClosesInOneGo() {
        var assembler = AssistantMessageAssembler(model: model, timestamp: 1)
        _ = assembler.start()
        let events = assembler.consume(.toolCallEnd(id: "c", name: "echo", argumentsJSON: #"{"text":"a"}"#))
        #expect(kinds(events) == ["toolcall_start:0", "toolcall_end:0:echo"])
    }

    @Test func errorClosesOpenBlockAndMarksMessage() {
        var assembler = AssistantMessageAssembler(model: model, timestamp: 1)
        _ = assembler.start()
        _ = assembler.consume(.textDelta("par"))
        let events = assembler.consume(.error(message: "boom", aborted: true))
        #expect(kinds(events) == ["text_end:0:par", "error:aborted"])
        #expect(assembler.partial.errorMessage == "boom")
        #expect(assembler.partial.stopReason == .aborted)
        #expect(assembler.consume(.textDelta("late")).isEmpty)   // 结束后不再吐事件
    }

    @Test func doneWithErrorStopReasonBecomesErrorEvent() {
        var assembler = AssistantMessageAssembler(model: model, timestamp: 1)
        _ = assembler.start()
        let events = assembler.consume(.finished(stopReason: .error, usage: nil, rawStopReason: nil))
        #expect(kinds(events) == ["error:error"])
    }
}
