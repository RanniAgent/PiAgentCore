// 对应上游：packages/agent/src/types.ts 的 AgentContext / StreamFn / AgentLoopConfig 及各钩子的上下文与结果。
// 差异：pi 的钩子拿到的是可变的 context 对象，这里是值快照；prepareNextTurn 返回替换用的 context。
import Foundation

/// 循环内部的上下文。
public struct AgentContext: Sendable {
    public var systemPrompt: String
    public var messages: [AgentMessage]
    public var tools: [any AgentTool]
    public init(systemPrompt: String, messages: [AgentMessage], tools: [any AgentTool]) {
        self.systemPrompt = systemPrompt; self.messages = messages; self.tools = tools
    }
}

/// 给流函数的上下文（已经过 convertToLlm）。
public struct LLMContext: Sendable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]?
    public init(systemPrompt: String?, messages: [Message], tools: [ToolDefinition]?) {
        self.systemPrompt = systemPrompt; self.messages = messages; self.tools = tools
    }
}

/// 一次模型请求 → 一串事件 + 终值。合同：不抛错，失败编码进 error 事件。
public typealias StreamFn = @Sendable (_ model: Model, _ context: LLMContext, _ options: SimpleStreamOptions) async -> AssistantMessageEventStream

public struct BeforeToolCallResult: Sendable {
    public var block: Bool?
    public var reason: String?
    public var terminate: Bool?
    public init(block: Bool? = nil, reason: String? = nil, terminate: Bool? = nil) {
        self.block = block; self.reason = reason; self.terminate = terminate
    }
}

public struct AfterToolCallResult: Sendable {
    public var content: [ToolResultContent]?
    public var details: JSONValue?
    public var isError: Bool?
    public var usage: Usage?
    public var terminate: Bool?
    public init(content: [ToolResultContent]? = nil, details: JSONValue? = nil, isError: Bool? = nil, usage: Usage? = nil, terminate: Bool? = nil) {
        self.content = content; self.details = details; self.isError = isError; self.usage = usage; self.terminate = terminate
    }
}

public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var context: AgentContext
}

public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: ToolCall
    public var args: JSONValue
    public var result: AgentToolResult
    public var isError: Bool
    public var context: AgentContext
}

public struct ShouldStopAfterTurnContext: Sendable {
    public var message: AssistantMessage
    public var toolResults: [ToolResultMessage]
    public var context: AgentContext
    public var newMessages: [AgentMessage]
}

public typealias PrepareNextTurnContext = ShouldStopAfterTurnContext

public struct AgentLoopTurnUpdate: Sendable {
    public var context: AgentContext?
    public var model: Model?
    public var thinkingLevel: ThinkingLevel?
    public init(context: AgentContext? = nil, model: Model? = nil, thinkingLevel: ThinkingLevel? = nil) {
        self.context = context; self.model = model; self.thinkingLevel = thinkingLevel
    }
}

public struct AgentLoopConfig: Sendable {
    public var model: Model
    public var options: SimpleStreamOptions
    public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
    public var transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)?
    public var prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)?
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?
    public var toolExecution: ToolExecutionMode
    public var beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)?

    public init(
        model: Model,
        options: SimpleStreamOptions = SimpleStreamOptions(),
        convertToLlm: @escaping @Sendable ([AgentMessage]) async -> [Message] = { $0.compactMap(\.llmMessage) },
        transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (String) async -> String?)? = nil,
        shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)? = nil,
        prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)? = nil
    ) {
        self.model = model; self.options = options; self.convertToLlm = convertToLlm
        self.transformContext = transformContext; self.getApiKey = getApiKey
        self.shouldStopAfterTurn = shouldStopAfterTurn; self.prepareNextTurn = prepareNextTurn
        self.getSteeringMessages = getSteeringMessages; self.getFollowUpMessages = getFollowUpMessages
        self.toolExecution = toolExecution; self.beforeToolCall = beforeToolCall; self.afterToolCall = afterToolCall
    }
}
