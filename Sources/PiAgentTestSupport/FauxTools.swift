// 假工具：按脚本给结果；并行批次里按 completionOrder 决定谁先完成。
import Foundation
import PiAgentCore

/// 并行批次的完成屏障。先登记一批调用与完成顺序，工具执行开头等自己的轮次，结束时放行下一个。
public actor CompletionBarrier {
    private var order: [String] = []          // 待放行的调用 id，按完成顺序
    private var released: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func register(batch ids: [String], completionOrder: [Int]) {
        guard ids.count > 1, completionOrder.count == ids.count else { return }
        order = completionOrder.map { ids[$0 - 1] }
        released = []
        releaseNext()
    }

    public func waitForTurn(_ id: String) async {
        guard order.contains(id), !released.contains(id) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    public func finished(_ id: String) {
        guard let first = order.first, first == id else { return }
        order.removeFirst()
        releaseNext()
    }

    private func releaseNext() {
        guard let next = order.first else { return }
        released.insert(next)
        let pending = waiters.removeValue(forKey: next) ?? []
        for waiter in pending { waiter.resume() }
    }
}

/// 每个工具名一份结果队列。
public actor FauxToolScript {
    private var results: [String: [ScenarioToolResult]]
    public init(tools: [ScenarioTool]) {
        results = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.results) })
    }
    public func next(for tool: String) -> ScenarioToolResult? {
        guard var queue = results[tool], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        results[tool] = queue
        return first
    }
}

public struct FauxToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FauxAgentTool: AgentTool {
    public let definition: ToolDefinition
    public let label: String
    public let executionMode: ToolExecutionMode?
    private let script: FauxToolScript
    private let barrier: CompletionBarrier

    public init(scenarioTool: ScenarioTool, script: FauxToolScript, barrier: CompletionBarrier) {
        definition = ToolDefinition(name: scenarioTool.name, description: scenarioTool.description, parameters: scenarioTool.parameters)
        label = scenarioTool.name
        executionMode = scenarioTool.executionMode
        self.script = script
        self.barrier = barrier
    }

    /// 放行下一个调用的动作不在这里做，而是由监听器在 tool_execution_end 事件里调 barrier.finished，
    /// 这样"谁先完成"和"谁的结束事件先发"一定一致，两端都这么做。
    public func execute(toolCallId: String, args: JSONValue, onUpdate: @escaping @Sendable (AgentToolResult) -> Void) async throws -> AgentToolResult {
        await barrier.waitForTurn(toolCallId)
        guard let scripted = await script.next(for: definition.name) else {
            throw FauxToolError(message: "No scripted result left for tool \(definition.name)")
        }
        for update in scripted.updates ?? [] {
            onUpdate(AgentToolResult(content: [.text(TextContent(text: update))]))
        }
        if let message = scripted.throw {
            throw FauxToolError(message: message)
        }
        let content: [ToolResultContent] = (scripted.content ?? []).compactMap { block in
            if case .text(let t) = block { return .text(TextContent(text: t)) }
            return nil
        }
        return AgentToolResult(content: content, details: scripted.details)
    }
}
