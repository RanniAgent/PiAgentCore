import Foundation
import Testing
@testable import PiAgentCore
@testable import PiAgentTestSupport

struct AgentTests {
    let model = Model(id: "faux-1", name: "faux", api: "faux", provider: "faux", baseUrl: "", reasoning: false, input: ["text"], cost: .zero, contextWindow: 1000, maxTokens: 100)

    private func agent(responses: [ScenarioResponse]) -> (Agent, FauxProvider) {
        let provider = FauxProvider(responses: responses, tokenSize: 2)
        let agent = Agent(options: AgentOptions(initialState: AgentState(systemPrompt: "sys", model: model, thinkingLevel: .off, tools: [], messages: []), streamFn: provider.makeStreamFn()))
        return (agent, provider)
    }

    @Test func promptAppendsMessagesAndSettlesListenersBeforeReturning() async throws {
        let (agent, _) = agent(responses: [ScenarioResponse(content: [.text("hi there")], stopReason: .stop, errorMessage: nil)])
        let log = EventLog()
        _ = await agent.subscribe { event in
            try? await Task.sleep(for: .milliseconds(5))   // 监听器慢一点，prompt 也要等它
            await log.append(event)
        }
        try await agent.prompt("hello")
        #expect(await log.kinds.last == "agent_end")
        let state = await agent.state
        #expect(state.messages.count == 2)
        #expect(state.isStreaming == false)
        #expect(state.streamingMessage == nil)
    }

    @Test func listenersRunInSubscriptionOrderOneAtATime() async throws {
        let (agent, _) = agent(responses: [ScenarioResponse(content: [.text("x")], stopReason: .stop, errorMessage: nil)])
        let order = OrderLog()
        _ = await agent.subscribe { _ in try? await Task.sleep(for: .milliseconds(3)); order.append("a") }
        _ = await agent.subscribe { _ in order.append("b") }
        try await agent.prompt("hello")
        let items = order.items
        #expect(items.count % 2 == 0)
        for pair in stride(from: 0, to: items.count, by: 2) {
            #expect(items[pair] == "a" && items[pair + 1] == "b")
        }
    }

    @Test func promptWhileRunningThrowsAndResetWhileRunningThrows() async throws {
        let (agent, _) = agent(responses: [ScenarioResponse(content: [.text(String(repeating: "y", count: 100))], stopReason: .stop, errorMessage: nil)])
        let gate = Gate()
        _ = await agent.subscribe { event in
            if case .messageStart(.assistant) = event { await gate.open() }
        }
        let run = Task { try await agent.prompt("go") }
        await gate.wait()
        await #expect(throws: AgentError.alreadyProcessing) { try await agent.prompt("again") }
        await #expect(throws: AgentError.alreadyProcessing) { try await agent.reset() }
        try await run.value
        try await agent.reset()
        #expect(await agent.state.messages.isEmpty)
    }

    @Test func continueRulesMatchPi() async throws {
        let (agent, provider) = agent(responses: [
            ScenarioResponse(content: [.text("one")], stopReason: .stop, errorMessage: nil),
            ScenarioResponse(content: [.text("two")], stopReason: .stop, errorMessage: nil),
        ])
        await #expect(throws: AgentError.noMessagesToContinue) { try await agent.continue() }
        try await agent.prompt("hi")
        await #expect(throws: AgentError.cannotContinueFromAssistant) { try await agent.continue() }
        await agent.followUp(.user(UserMessage(content: .text("more"), timestamp: 2)))
        try await agent.continue()   // 末尾是助手消息但队列里有追问 → 当作新 prompt 跑
        #expect(await provider.callCount == 2)
        #expect(await agent.state.messages.count == 4)
    }

    @Test func abortEndsRunWithAbortedMessageAndErrorMessageInState() async throws {
        let (agent, _) = agent(responses: [ScenarioResponse(content: [.text(String(repeating: "z", count: 400))], stopReason: .stop, errorMessage: nil)])
        let counter = Counter()
        _ = await agent.subscribe { event in
            if case .messageUpdate = event {
                counter.increment()
                if counter.value == 3 { await agent.abort() }
            }
        }
        try await agent.prompt("go")
        let state = await agent.state
        if case .assistant(let m) = state.messages.last { #expect(m.stopReason == .aborted) } else { Issue.record("expected aborted") }
        #expect(state.errorMessage == "Request was aborted")
        #expect(state.pendingToolCalls.isEmpty)
    }

    @Test func steerIsInjectedAtTurnBoundary() async throws {
        let (agent, provider) = agent(responses: [
            ScenarioResponse(content: [.text("first")], stopReason: .stop, errorMessage: nil),
            ScenarioResponse(content: [.text("second")], stopReason: .stop, errorMessage: nil),
        ])
        let fired = Counter()
        _ = await agent.subscribe { event in
            if case .messageStart(.assistant) = event, fired.value == 0 {
                fired.increment()
                await agent.steer(.user(UserMessage(content: .text("wait"), timestamp: 2)))
            }
        }
        try await agent.prompt("hi")
        #expect(await provider.callCount == 2)
        let roles = await agent.state.messages.map(\.role)
        #expect(roles == ["user", "assistant", "user", "assistant"])
    }
}
