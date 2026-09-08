// 对应上游：packages/agent/src/agent.ts（0.85.1）。
// 差异：actor 隔离状态；监听器串行 await；abort 是 Task 取消；prompt/continue 抛 AgentError。
import Foundation

public enum AgentError: Error, Equatable {
    case alreadyProcessing
    case noMessagesToContinue
    case cannotContinueFromAssistant
}

public struct AgentOptions: Sendable {
    public var initialState: AgentState
    public var streamFn: StreamFn
    public var convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])?
    public var transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)?
    public var shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)?
    public var prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)?
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var sessionId: String?
    public var thinkingBudgets: [String: Int]?
    public var toolExecution: ToolExecutionMode

    public init(
        initialState: AgentState,
        streamFn: @escaping StreamFn,
        convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])? = nil,
        transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)? = nil,
        shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)? = nil,
        prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)? = nil,
        steeringMode: QueueMode = .oneAtATime,
        followUpMode: QueueMode = .oneAtATime,
        sessionId: String? = nil,
        thinkingBudgets: [String: Int]? = nil,
        toolExecution: ToolExecutionMode = .parallel
    ) {
        self.initialState = initialState; self.streamFn = streamFn; self.convertToLlm = convertToLlm
        self.transformContext = transformContext; self.getApiKey = getApiKey
        self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
        self.shouldStopAfterTurn = shouldStopAfterTurn; self.prepareNextTurn = prepareNextTurn
        self.steeringMode = steeringMode; self.followUpMode = followUpMode
        self.sessionId = sessionId; self.thinkingBudgets = thinkingBudgets; self.toolExecution = toolExecution
    }
}

/// pi 的 PendingMessageQueue。
struct PendingMessageQueue: Sendable {
    var mode: QueueMode
    private(set) var messages: [AgentMessage] = []
    mutating func enqueue(_ message: AgentMessage) { messages.append(message) }
    var hasItems: Bool { !messages.isEmpty }
    mutating func drain() -> [AgentMessage] {
        switch mode {
        case .all:
            defer { messages = [] }
            return messages
        case .oneAtATime:
            guard let first = messages.first else { return [] }
            messages.removeFirst()
            return [first]
        }
    }
    mutating func clear() { messages = [] }
}

public actor Agent {
    public private(set) var state: AgentState
    private var listeners: [(id: UUID, listener: @Sendable (AgentEvent) async -> Void)] = []
    private var steeringQueue: PendingMessageQueue
    private var followUpQueue: PendingMessageQueue
    private let options: AgentOptions
    private var activeRun: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var skipInitialSteeringPoll = false

    public init(options: AgentOptions) {
        self.options = options
        self.state = options.initialState
        self.steeringQueue = PendingMessageQueue(mode: options.steeringMode)
        self.followUpQueue = PendingMessageQueue(mode: options.followUpMode)
    }

    // MARK: - 订阅

    /// 监听器按订阅顺序依次 await；agent_end 的监听器跑完 Agent 才算空闲。
    @discardableResult
    public func subscribe(_ listener: @escaping @Sendable (AgentEvent) async -> Void) -> UUID {
        let id = UUID()
        listeners.append((id, listener))
        return id
    }

    public func unsubscribe(_ id: UUID) {
        listeners.removeAll { $0.id == id }
    }

    // MARK: - 状态修改

    public func setSystemPrompt(_ value: String) { state.systemPrompt = value }
    public func setModel(_ value: Model) { state.model = value }
    public func setThinkingLevel(_ value: ThinkingLevel) { state.thinkingLevel = value }
    public func setTools(_ value: [any AgentTool]) { state.tools = value }
    public func setMessages(_ value: [AgentMessage]) { state.messages = value }
    public func appendMessage(_ value: AgentMessage) { state.messages.append(value) }

    public var steeringMode: QueueMode { steeringQueue.mode }
    public var followUpMode: QueueMode { followUpQueue.mode }
    public func setSteeringMode(_ mode: QueueMode) { steeringQueue.mode = mode }
    public func setFollowUpMode(_ mode: QueueMode) { followUpQueue.mode = mode }

    // MARK: - 队列

    public func steer(_ message: AgentMessage) { steeringQueue.enqueue(message) }
    public func followUp(_ message: AgentMessage) { followUpQueue.enqueue(message) }
    public func clearSteeringQueue() { steeringQueue.clear() }
    public func clearFollowUpQueue() { followUpQueue.clear() }
    public func clearAllQueues() { clearSteeringQueue(); clearFollowUpQueue() }
    public var hasQueuedMessages: Bool { steeringQueue.hasItems || followUpQueue.hasItems }

    // MARK: - 运行

    public var isRunning: Bool { activeRun != nil }

    public func abort() { activeRun?.cancel() }

    public func waitForIdle() async {
        guard activeRun != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func reset() throws {
        guard activeRun == nil else { throw AgentError.alreadyProcessing }
        state.messages = []
        state.isStreaming = false
        state.streamingMessage = nil
        state.pendingToolCalls = []
        state.errorMessage = nil
        clearAllQueues()
    }

    /// 和上游 normalizePromptInput 一致：字符串 prompt 一律变成块数组（哪怕没有图片），
    /// 不是 `.text(...)`，否则金标准序列里的 user content 形状对不上。
    public func prompt(_ text: String, images: [ImageContent] = []) async throws {
        var blocks: [UserContentBlock] = [.text(TextContent(text: text))]
        blocks.append(contentsOf: images.map { .image($0) })
        try await prompt(messages: [.user(UserMessage(content: .blocks(blocks)))])
    }

    public func prompt(messages: [AgentMessage]) async throws {
        guard activeRun == nil else { throw AgentError.alreadyProcessing }
        await runPromptMessages(messages, skipInitialSteeringPoll: false)
    }

    /// 从当前上下文续跑。末尾是助手消息时，先看队列：有插话当作新 prompt 跑，有追问同理；都没有就报错。
    public func `continue`() async throws {
        guard activeRun == nil else { throw AgentError.alreadyProcessing }
        guard let last = state.messages.last else { throw AgentError.noMessagesToContinue }
        if case .assistant = last {
            let steering = steeringQueue.drain()
            if !steering.isEmpty {
                await runPromptMessages(steering, skipInitialSteeringPoll: true)
                return
            }
            let followUps = followUpQueue.drain()
            if !followUps.isEmpty {
                await runPromptMessages(followUps, skipInitialSteeringPoll: false)
                return
            }
            throw AgentError.cannotContinueFromAssistant
        }
        let context = contextSnapshot()
        let config = loopConfig()
        let streamFn = options.streamFn
        let agent = self
        await runWithLifecycle {
            _ = try? await AgentLoop.runContinue(context: context, config: config, streamFn: streamFn) { event in
                await agent.processEvents(event)
            }
        }
    }

    private func runPromptMessages(_ messages: [AgentMessage], skipInitialSteeringPoll: Bool) async {
        self.skipInitialSteeringPoll = skipInitialSteeringPoll
        let context = contextSnapshot()
        let config = loopConfig()
        let streamFn = options.streamFn
        let agent = self
        await runWithLifecycle {
            _ = await AgentLoop.run(prompts: messages, context: context, config: config, streamFn: streamFn) { event in
                await agent.processEvents(event)
            }
        }
    }

    private func contextSnapshot() -> AgentContext {
        AgentContext(systemPrompt: state.systemPrompt, messages: state.messages, tools: state.tools)
    }

    private func loopConfig() -> AgentLoopConfig {
        var streamOptions = SimpleStreamOptions()
        streamOptions.reasoning = state.thinkingLevel == .off ? nil : state.thinkingLevel
        streamOptions.sessionId = options.sessionId
        streamOptions.thinkingBudgets = options.thinkingBudgets
        return AgentLoopConfig(
            model: state.model,
            options: streamOptions,
            convertToLlm: options.convertToLlm ?? { $0.compactMap(\.llmMessage) },
            transformContext: options.transformContext,
            getApiKey: options.getApiKey,
            shouldStopAfterTurn: options.shouldStopAfterTurn,
            prepareNextTurn: options.prepareNextTurn,
            getSteeringMessages: { [weak self] in await self?.drainSteering() ?? [] },
            getFollowUpMessages: { [weak self] in await self?.drainFollowUps() ?? [] },
            toolExecution: options.toolExecution,
            beforeToolCall: options.beforeToolCall,
            afterToolCall: options.afterToolCall
        )
    }

    private func drainSteering() -> [AgentMessage] {
        if skipInitialSteeringPoll {
            skipInitialSteeringPoll = false
            return []
        }
        return steeringQueue.drain()
    }

    private func drainFollowUps() -> [AgentMessage] { followUpQueue.drain() }

    private func runWithLifecycle(_ executor: @escaping @Sendable () async -> Void) async {
        state.isStreaming = true
        state.streamingMessage = nil
        state.errorMessage = nil
        let task = Task { await executor() }
        activeRun = task
        await task.value
        finishRun()
    }

    private func finishRun() {
        state.isStreaming = false
        state.streamingMessage = nil
        state.pendingToolCalls = []
        activeRun = nil
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// 先按事件改状态，再依次 await 监听器（和 pi 的 processEvents 一致）。
    private func processEvents(_ event: AgentEvent) async {
        switch event {
        case .messageStart(let message), .messageUpdate(let message, _):
            state.streamingMessage = message
        case .messageEnd(let message):
            state.streamingMessage = nil
            state.messages.append(message)
        case .toolExecutionStart(let id, _, _):
            state.pendingToolCalls.insert(id)
        case .toolExecutionEnd(let id, _, _, _):
            state.pendingToolCalls.remove(id)
        case .turnEnd(let message, _):
            if case .assistant(let assistant) = message, let error = assistant.errorMessage {
                state.errorMessage = error
            }
        case .agentEnd:
            state.streamingMessage = nil
        default:
            break
        }
        for entry in listeners {
            await entry.listener(event)
        }
    }
}
