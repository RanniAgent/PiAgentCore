// 按场景文件跑一次 Agent，返回归一化后的事件序列。
import Foundation
import PiAgentCore

public struct TraceDocument: Codable, Sendable, Equatable {
    public var scenario: String
    public var piVersion: String
    public var events: [JSONValue]

    public init(scenario: String, piVersion: String, events: [JSONValue]) {
        self.scenario = scenario; self.piVersion = piVersion; self.events = events
    }
}

public enum ScenarioRunner {
    public static func run(_ scenario: Scenario) async throws -> TraceDocument {
        let model = Model(id: "faux-1", name: "faux", api: "faux", provider: "faux", baseUrl: "", reasoning: true, input: ["text"], cost: .zero, contextWindow: 100_000, maxTokens: 4096)
        let provider = FauxProvider(responses: scenario.responses, tokenSize: scenario.tokenSize)
        let script = FauxToolScript(tools: scenario.tools)
        let barrier = CompletionBarrier()
        let tools: [any AgentTool] = scenario.tools.map { FauxAgentTool(scenarioTool: $0, script: script, barrier: barrier) }
        let agent = Agent(options: AgentOptions(
            initialState: AgentState(systemPrompt: scenario.systemPrompt, model: model, thinkingLevel: .off, tools: tools, messages: []),
            streamFn: provider.makeStreamFn(),
            steeringMode: QueueMode(rawValue: scenario.steeringMode) ?? .oneAtATime,
            followUpMode: QueueMode(rawValue: scenario.followUpMode) ?? .oneAtATime,
            toolExecution: scenario.toolExecution
        ))

        let collector = TraceCollector(scenario: scenario, barrier: barrier, agent: agent)
        await agent.subscribe { event in await collector.handle(event) }
        try await agent.prompt(scenario.prompt)
        return TraceDocument(scenario: scenario.name, piVersion: PiAgentCoreInfo.piUpstreamVersion, events: await collector.events)
    }
}

/// 录事件、数次数、触发动作、登记并行批次。
actor TraceCollector {
    private let scenario: Scenario
    private let barrier: CompletionBarrier
    private let agent: Agent
    private var normalizer = TraceNormalizer()
    private var occurrences: [String: Int] = [:]
    private var batchIndex = 0
    private(set) var events: [JSONValue] = []

    init(scenario: Scenario, barrier: CompletionBarrier, agent: Agent) {
        self.scenario = scenario; self.barrier = barrier; self.agent = agent
    }

    func handle(_ event: AgentEvent) async {
        // 并行批次：助手消息定稿时登记完成顺序（pi 在执行工具前一定先发 message_end）
        if case .messageEnd(.assistant(let m)) = event, m.toolCalls.count > 1 {
            let order = batchIndex < scenario.batches.count ? scenario.batches[batchIndex].completionOrder : Array(1...m.toolCalls.count)
            batchIndex += 1
            await barrier.register(batch: m.toolCalls.map(\.id), completionOrder: order)
        }
        if let normalized = normalizer.normalize(event) {
            events.append(normalized)
        }
        if case .toolExecutionEnd(let id, _, _, _) = event {
            await barrier.finished(id)   // 屏障放行下一个（见 FauxAgentTool 的注释）
        }
        let type = typeName(event)
        occurrences[type, default: 0] += 1
        for action in scenario.actions where action.on == type && action.occurrence == occurrences[type] {
            switch action.do {
            case "abort":
                normalizer.markAborted()
                await agent.abort()
            case "steer":
                await agent.steer(.user(UserMessage(content: .text(action.text ?? ""))))
            case "followUp":
                await agent.followUp(.user(UserMessage(content: .text(action.text ?? ""))))
            default:
                break
            }
        }
    }

    private func typeName(_ event: AgentEvent) -> String {
        switch event {
        case .agentStart: return "agent_start"
        case .agentEnd: return "agent_end"
        case .turnStart: return "turn_start"
        case .turnEnd: return "turn_end"
        case .messageStart: return "message_start"
        case .messageUpdate: return "message_update"
        case .messageEnd: return "message_end"
        case .toolExecutionStart: return "tool_execution_start"
        case .toolExecutionUpdate: return "tool_execution_update"
        case .toolExecutionEnd: return "tool_execution_end"
        }
    }
}
