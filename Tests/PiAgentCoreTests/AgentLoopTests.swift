import Foundation
import Testing
@testable import PiAgentCore
@testable import PiAgentTestSupport

struct AgentLoopTests {
    let model = Model(id: "faux-1", name: "faux", api: "faux", provider: "faux", baseUrl: "", reasoning: false, input: ["text"], cost: .zero, contextWindow: 1000, maxTokens: 100)

    private func echoTool(results: [ScenarioToolResult], mode: ToolExecutionMode? = nil) -> (FauxAgentTool, CompletionBarrier) {
        let barrier = CompletionBarrier()
        let tool = FauxAgentTool(
            scenarioTool: ScenarioTool(name: "echo", description: "echo", parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]], executionMode: mode, results: results),
            script: FauxToolScript(tools: [ScenarioTool(name: "echo", description: "echo", parameters: [:], executionMode: mode, results: results)]),
            barrier: barrier
        )
        return (tool, barrier)
    }

    @Test func textOnlyRunEmitsPiSequence() async {
        let provider = FauxProvider(responses: [ScenarioResponse(content: [.text("hello world")], stopReason: .stop, errorMessage: nil)], tokenSize: 2)
        let log = EventLog()
        let context = AgentContext(systemPrompt: "sys", messages: [], tools: [])
        let config = AgentLoopConfig(model: model)
        let prompt = AgentMessage.user(UserMessage(content: .text("hi"), timestamp: 1))
        let produced = await AgentLoop.run(prompts: [prompt], context: context, config: config, streamFn: provider.makeStreamFn()) { await log.append($0) }
        let kinds = await log.kinds.filter { $0 != "message_update" }
        #expect(kinds == ["agent_start", "turn_start", "message_start(user)", "message_end(user)", "message_start(assistant)", "message_end(assistant)", "turn_end(0)", "agent_end"])
        #expect(await log.kinds.filter { $0 == "message_update" }.count == 4)   // text_start + 2 条 text_delta + text_end；start 对应的是 message_start
        #expect(produced.count == 2)
    }

    @Test func toolCallRunsToolAndContinues() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [.toolCall(id: "call_1", name: "echo", argumentsText: #"{"text":"a"}"#)], stopReason: .toolUse, errorMessage: nil),
            ScenarioResponse(content: [.text("done")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, _) = echoTool(results: [ScenarioToolResult(updates: ["echo: "], content: [.text("echo: a")], details: nil, throw: nil)])
        let log = EventLog()
        let context = AgentContext(systemPrompt: "sys", messages: [], tools: [tool])
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: context, config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { await log.append($0) }
        let kinds = await log.kinds.filter { $0 != "message_update" }
        #expect(kinds == [
            "agent_start", "turn_start", "message_start(user)", "message_end(user)",
            "message_start(assistant)", "message_end(assistant)",
            "tool_start(call_1)", "tool_update(call_1)", "tool_end(call_1,false)",
            "message_start(toolResult)", "message_end(toolResult)", "turn_end(1)",
            "turn_start", "message_start(assistant)", "message_end(assistant)", "turn_end(0)", "agent_end",
        ])
        #expect(produced.count == 4)
        if case .toolResult(let r) = produced[2] { #expect(r.content == [.text(TextContent(text: "echo: a"))]) } else { Issue.record("expected tool result") }
    }

    @Test func parallelBatchEndsInCompletionOrderButResultsInSourceOrder() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [
                .toolCall(id: "c1", name: "echo", argumentsText: #"{"text":"a"}"#),
                .toolCall(id: "c2", name: "echo", argumentsText: #"{"text":"b"}"#),
            ], stopReason: .toolUse, errorMessage: nil),
            ScenarioResponse(content: [.text("done")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, barrier) = echoTool(results: [
            ScenarioToolResult(updates: nil, content: [.text("A")], details: nil, throw: nil),
            ScenarioToolResult(updates: nil, content: [.text("B")], details: nil, throw: nil),
        ])
        await barrier.register(batch: ["c1", "c2"], completionOrder: [2, 1])
        let log = EventLog()
        let context = AgentContext(systemPrompt: "sys", messages: [], tools: [tool])
        // 屏障在 tool_execution_end 事件里放行下一个，这样完成顺序和事件顺序一定一致。
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: context, config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { event in
            await log.append(event)
            if case .toolExecutionEnd(let id, _, _, _) = event { await barrier.finished(id) }
        }
        let kinds = await log.kinds.filter { $0.hasPrefix("tool_") || $0.hasPrefix("message_end(toolResult") }
        #expect(kinds == ["tool_start(c1)", "tool_start(c2)", "tool_end(c2,false)", "tool_end(c1,false)", "message_end(toolResult)", "message_end(toolResult)"])
        if case .toolResult(let first) = produced[2], case .toolResult(let second) = produced[3] {
            #expect(first.toolCallId == "c1")
            #expect(second.toolCallId == "c2")
        } else { Issue.record("expected two tool results in source order") }
    }

    @Test func sequentialToolForcesWholeBatchSequential() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [
                .toolCall(id: "c1", name: "echo", argumentsText: #"{"text":"a"}"#),
                .toolCall(id: "c2", name: "echo", argumentsText: #"{"text":"b"}"#),
            ], stopReason: .toolUse, errorMessage: nil),
            ScenarioResponse(content: [.text("done")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, _) = echoTool(results: [
            ScenarioToolResult(updates: nil, content: [.text("A")], details: nil, throw: nil),
            ScenarioToolResult(updates: nil, content: [.text("B")], details: nil, throw: nil),
        ], mode: .sequential)
        let log = EventLog()
        _ = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: [tool]), config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { await log.append($0) }
        let kinds = await log.kinds.filter { $0.hasPrefix("tool_") || $0.hasPrefix("message_end(toolResult") }
        #expect(kinds == ["tool_start(c1)", "tool_end(c1,false)", "message_end(toolResult)", "tool_start(c2)", "tool_end(c2,false)", "message_end(toolResult)"])
    }

    @Test func lengthStopFailsEveryToolCallWithoutExecuting() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [.toolCall(id: "c1", name: "echo", argumentsText: #"{"text":"a"}"#)], stopReason: .length, errorMessage: nil),
            ScenarioResponse(content: [.text("recovered")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, _) = echoTool(results: [ScenarioToolResult(updates: nil, content: [.text("never")], details: nil, throw: nil)])
        let log = EventLog()
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: [tool]), config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { await log.append($0) }
        #expect(await log.kinds.contains("tool_end(c1,true)"))
        if case .toolResult(let r) = produced[2] {
            #expect(r.isError)
            #expect(r.content == [.text(TextContent(text: "Tool call \"echo\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."))])
        } else { Issue.record("expected error tool result") }
        #expect(produced.count == 4)   // 截断后还会再跑一轮
    }

    @Test func beforeToolCallCanBlockAndTerminate() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [.toolCall(id: "c1", name: "echo", argumentsText: #"{"text":"a"}"#)], stopReason: .toolUse, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, _) = echoTool(results: [])
        let log = EventLog()
        let config = AgentLoopConfig(model: model, beforeToolCall: { _ in BeforeToolCallResult(block: true, reason: "nope", terminate: true) })
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: [tool]), config: config, streamFn: provider.makeStreamFn()) { await log.append($0) }
        #expect(await log.kinds.last == "agent_end")
        #expect(await provider.callCount == 1)   // terminate：没有再请求模型
        if case .toolResult(let r) = produced[2] { #expect(r.isError); #expect(r.content == [.text(TextContent(text: "nope"))]) } else { Issue.record("expected blocked result") }
    }

    @Test func afterToolCallOverridesResult() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [.toolCall(id: "c1", name: "echo", argumentsText: #"{"text":"a"}"#)], stopReason: .toolUse, errorMessage: nil),
            ScenarioResponse(content: [.text("done")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let (tool, _) = echoTool(results: [ScenarioToolResult(updates: nil, content: [.text("raw")], details: nil, throw: nil)])
        let config = AgentLoopConfig(model: model, afterToolCall: { _ in AfterToolCallResult(content: [.text(TextContent(text: "rewritten"))], isError: true) })
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: [tool]), config: config, streamFn: provider.makeStreamFn()) { _ in }
        if case .toolResult(let r) = produced[2] { #expect(r.isError); #expect(r.content == [.text(TextContent(text: "rewritten"))]) } else { Issue.record("expected rewritten result") }
    }

    @Test func steeringFollowUpAndPrepareNextTurn() async {
        let provider = FauxProvider(responses: [
            ScenarioResponse(content: [.text("first")], stopReason: .stop, errorMessage: nil),
            ScenarioResponse(content: [.text("second")], stopReason: .stop, errorMessage: nil),
            ScenarioResponse(content: [.text("third")], stopReason: .stop, errorMessage: nil),
        ], tokenSize: 2)
        let queues = Queues()
        await queues.steer(.user(UserMessage(content: .text("wait"), timestamp: 2)))
        await queues.followUp(.user(UserMessage(content: .text("and then?"), timestamp: 3)))
        let prepared = Counter()
        let config = AgentLoopConfig(
            model: model,
            prepareNextTurn: { _ in prepared.increment(); return nil },
            getSteeringMessages: { await queues.drainSteering() },
            getFollowUpMessages: { await queues.drainFollowUps() }
        )
        let log = EventLog()
        let produced = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: []), config: config, streamFn: provider.makeStreamFn()) { await log.append($0) }
        let kinds = await log.kinds.filter { $0 != "message_update" }
        #expect(kinds == [
            "agent_start", "turn_start", "message_start(user)", "message_end(user)",   // hi
            "message_start(user)", "message_end(user)",                                // 开跑前就在队列里的插话，pi 在第一轮注入
            "message_start(assistant)", "message_end(assistant)", "turn_end(0)",       // first
            "turn_start", "message_start(user)", "message_end(user)",                  // 追问
            "message_start(assistant)", "message_end(assistant)", "turn_end(0)",       // second
            "agent_end",
        ])
        #expect(prepared.value == 1)   // 只在确定要再跑一轮时调（0.84.4 起）
        #expect(produced.count == 5)
        #expect(await provider.callCount == 2)
    }

    @Test func shouldStopAfterTurnEndsRunBeforeQueuesArePolled() async {
        let provider = FauxProvider(responses: [ScenarioResponse(content: [.text("first")], stopReason: .stop, errorMessage: nil)], tokenSize: 2)
        let queues = Queues()
        await queues.followUp(.user(UserMessage(content: .text("more"), timestamp: 3)))
        let config = AgentLoopConfig(model: model, shouldStopAfterTurn: { _ in true }, getFollowUpMessages: { await queues.drainFollowUps() })
        _ = await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: []), config: config, streamFn: provider.makeStreamFn()) { _ in }
        #expect(await provider.callCount == 1)
        #expect(await queues.followUpCount == 1)   // 没被消费
    }

    @Test func cancellationEndsWithAbortedMessage() async {
        let provider = FauxProvider(responses: [ScenarioResponse(content: [.text(String(repeating: "x", count: 200))], stopReason: .stop, errorMessage: nil)], tokenSize: 2)
        let log = EventLog()
        let task = Task {
            await AgentLoop.run(prompts: [.user(UserMessage(content: .text("hi"), timestamp: 1))], context: AgentContext(systemPrompt: "", messages: [], tools: []), config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { event in
                await log.append(event)
                if case .messageUpdate = event, await log.kinds.filter({ $0 == "message_update" }).count == 3 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let produced = await task.value
        let kinds = await log.kinds.filter { $0 != "message_update" }
        #expect(kinds.suffix(3) == ["message_end(assistant)", "turn_end(0)", "agent_end"])
        if case .assistant(let m) = produced.last { #expect(m.stopReason == .aborted) } else { Issue.record("expected aborted assistant") }
    }

    @Test func continueRejectsAssistantTail() async {
        let provider = FauxProvider(responses: [], tokenSize: 2)
        let assistant = AgentMessage.assistant(AssistantMessage(content: [], api: "f", provider: "f", model: "m", stopReason: .stop, timestamp: 1))
        await #expect(throws: AgentLoopError.self) {
            _ = try await AgentLoop.runContinue(context: AgentContext(systemPrompt: "", messages: [assistant], tools: []), config: AgentLoopConfig(model: model), streamFn: provider.makeStreamFn()) { _ in }
        }
    }
}
