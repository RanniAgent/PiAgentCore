// 对应上游：packages/agent/src/agent-loop.ts（0.85.1）。函数名和顺序尽量一对一，方便跟版 diff。
// 差异：signal → Task.isCancelled，检查点位置相同；流函数没有 signal，改用 stream.cancel()。
import Foundation

public enum AgentLoopError: Error, Equatable {
    case noMessagesToContinue
    case cannotContinueFromAssistant
}

public typealias AgentEventEmitter = @Sendable (AgentEvent) async -> Void

public enum AgentLoop {
    /// 新 prompt 开跑：prompts 进上下文并发事件。
    public static func run(
        prompts: [AgentMessage],
        context: AgentContext,
        config: AgentLoopConfig,
        streamFn: @escaping StreamFn,
        emit: @escaping AgentEventEmitter
    ) async -> [AgentMessage] {
        var newMessages = prompts
        var currentContext = context
        currentContext.messages.append(contentsOf: prompts)
        await emit(.agentStart)
        await emit(.turnStart)
        for prompt in prompts {
            await emit(.messageStart(message: prompt))
            await emit(.messageEnd(message: prompt))
        }
        await runLoop(context: &currentContext, newMessages: &newMessages, config: config, streamFn: streamFn, emit: emit)
        return newMessages
    }

    /// 从现有上下文续跑（重试用）。末尾必须是 user 或 toolResult。
    public static func runContinue(
        context: AgentContext,
        config: AgentLoopConfig,
        streamFn: @escaping StreamFn,
        emit: @escaping AgentEventEmitter
    ) async throws -> [AgentMessage] {
        guard let last = context.messages.last else { throw AgentLoopError.noMessagesToContinue }
        if case .assistant = last { throw AgentLoopError.cannotContinueFromAssistant }
        var newMessages: [AgentMessage] = []
        var currentContext = context
        await emit(.agentStart)
        await emit(.turnStart)
        await runLoop(context: &currentContext, newMessages: &newMessages, config: config, streamFn: streamFn, emit: emit)
        return newMessages
    }

    // MARK: - runLoop

    private static func runLoop(
        context currentContext: inout AgentContext,
        newMessages: inout [AgentMessage],
        config initialConfig: AgentLoopConfig,
        streamFn: @escaping StreamFn,
        emit: @escaping AgentEventEmitter
    ) async {
        var config = initialConfig
        var lastCompletedTurn: ShouldStopAfterTurnContext?
        var pendingMessages = await config.getSteeringMessages?() ?? []

        while true {
            var hasMoreToolCalls = true
            while hasMoreToolCalls || !pendingMessages.isEmpty {
                if let completed = lastCompletedTurn {
                    if let update = await config.prepareNextTurn?(completed) {
                        if let context = update.context { currentContext = context }
                        if let model = update.model { config.model = model }
                        if let level = update.thinkingLevel {
                            config.options.reasoning = level == .off ? nil : level
                        }
                    }
                    // 准备可能很慢（比如压缩），期间来的插话要捡起来；上一轮已经拿到就不再问，免得 one-at-a-time 一轮进两条。
                    if pendingMessages.isEmpty {
                        pendingMessages = await config.getSteeringMessages?() ?? []
                    }
                    await emit(.turnStart)
                }
                if !pendingMessages.isEmpty {
                    for message in pendingMessages {
                        await emit(.messageStart(message: message))
                        await emit(.messageEnd(message: message))
                        currentContext.messages.append(message)
                        newMessages.append(message)
                    }
                    pendingMessages = []
                }

                let message = await streamAssistantResponse(context: &currentContext, config: config, streamFn: streamFn, emit: emit)
                newMessages.append(.assistant(message))
                if message.stopReason == .error || message.stopReason == .aborted {
                    await emit(.turnEnd(message: .assistant(message), toolResults: []))
                    await emit(.agentEnd(messages: newMessages))
                    return
                }

                let toolCalls = message.toolCalls
                var toolResults: [ToolResultMessage] = []
                hasMoreToolCalls = false
                if !toolCalls.isEmpty {
                    // length 截断：参数可能不完整，整批标失败，一个都不执行。
                    let batch = message.stopReason == .length
                        ? await failToolCallsFromTruncatedMessage(toolCalls, emit: emit)
                        : await executeToolCalls(context: currentContext, assistantMessage: message, config: config, emit: emit)
                    toolResults = batch.messages
                    hasMoreToolCalls = !batch.terminate
                    for result in toolResults {
                        currentContext.messages.append(.toolResult(result))
                        newMessages.append(.toolResult(result))
                    }
                }
                await emit(.turnEnd(message: .assistant(message), toolResults: toolResults))
                lastCompletedTurn = ShouldStopAfterTurnContext(message: message, toolResults: toolResults, context: currentContext, newMessages: newMessages)
                if let completed = lastCompletedTurn, await config.shouldStopAfterTurn?(completed) == true {
                    await emit(.agentEnd(messages: newMessages))
                    return
                }
                pendingMessages = await config.getSteeringMessages?() ?? []
            }
            let followUps = await config.getFollowUpMessages?() ?? []
            if !followUps.isEmpty {
                pendingMessages = followUps
                continue
            }
            break
        }
        await emit(.agentEnd(messages: newMessages))
    }

    // MARK: - streamAssistantResponse

    private static func streamAssistantResponse(
        context: inout AgentContext,
        config: AgentLoopConfig,
        streamFn: @escaping StreamFn,
        emit: @escaping AgentEventEmitter
    ) async -> AssistantMessage {
        var messages = context.messages
        if let transform = config.transformContext {
            messages = await transform(messages)
        }
        let llmMessages = await config.convertToLlm(messages)
        let llmContext = LLMContext(systemPrompt: context.systemPrompt, messages: llmMessages, tools: context.tools.map(\.definition))
        var options = config.options
        if let getApiKey = config.getApiKey, let key = await getApiKey(config.model.provider) {
            options.apiKey = key
        }
        let response = await streamFn(config.model, llmContext, options)

        let collector = StreamCollector(messages: context.messages)
        await withTaskCancellationHandler {
            for await event in response.events {
                switch event {
                case .start(let partial):
                    await collector.appendPartial(.assistant(partial))
                    await emit(.messageStart(message: .assistant(partial)))
                case .done, .error:
                    break
                default:
                    if await collector.addedPartial {
                        await collector.replaceLast(.assistant(event.message))
                        await emit(.messageUpdate(message: .assistant(event.message), assistantMessageEvent: event))
                    }
                }
                if event.isTerminal { break }
            }
        } onCancel: {
            Task { await response.cancel() }
        }

        let finalMessage = await response.result() ?? AssistantMessage(
            content: [], api: config.model.api, provider: config.model.provider, model: config.model.id,
            stopReason: Task.isCancelled ? .aborted : .error,
            errorMessage: "Stream ended without a terminal event"
        )
        if await collector.addedPartial {
            await collector.replaceLast(.assistant(finalMessage))
        } else {
            await collector.append(.assistant(finalMessage))
            await emit(.messageStart(message: .assistant(finalMessage)))
        }
        context.messages = await collector.messages
        await emit(.messageEnd(message: .assistant(finalMessage)))
        return finalMessage
    }

    /// 流式期间的上下文消息累加器。用 actor 是因为增量回调跨 withTaskCancellationHandler 边界。
    private actor StreamCollector {
        private(set) var messages: [AgentMessage]
        private(set) var addedPartial = false

        init(messages: [AgentMessage]) { self.messages = messages }

        func appendPartial(_ message: AgentMessage) {
            messages.append(message)
            addedPartial = true
        }

        func append(_ message: AgentMessage) { messages.append(message) }

        func replaceLast(_ message: AgentMessage) {
            guard !messages.isEmpty else { return }
            messages[messages.count - 1] = message
        }
    }

    // MARK: - 工具执行

    struct FinalizedToolCall: Sendable {
        var toolCall: ToolCall
        var result: AgentToolResult
        var isError: Bool
    }

    struct ToolBatch: Sendable {
        var messages: [ToolResultMessage]
        var terminate: Bool
    }

    enum Preparation: Sendable {
        case immediate(result: AgentToolResult, isError: Bool)
        case prepared(tool: any AgentTool, args: JSONValue)
    }

    private static func failToolCallsFromTruncatedMessage(_ toolCalls: [ToolCall], emit: @escaping AgentEventEmitter) async -> ToolBatch {
        var messages: [ToolResultMessage] = []
        for toolCall in toolCalls {
            await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
            let finalized = FinalizedToolCall(
                toolCall: toolCall,
                result: errorResult("Tool call \"\(toolCall.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."),
                isError: true
            )
            await emitToolExecutionEnd(finalized, emit: emit)
            let message = toolResultMessage(finalized)
            await emitToolResultMessage(message, emit: emit)
            messages.append(message)
        }
        return ToolBatch(messages: messages, terminate: false)
    }

    private static func executeToolCalls(context: AgentContext, assistantMessage: AssistantMessage, config: AgentLoopConfig, emit: @escaping AgentEventEmitter) async -> ToolBatch {
        let toolCalls = assistantMessage.toolCalls
        let hasSequential = toolCalls.contains { call in
            context.tools.first { $0.name == call.name }?.executionMode == .sequential
        }
        if config.toolExecution == .sequential || hasSequential {
            return await executeToolCallsSequential(context: context, assistantMessage: assistantMessage, toolCalls: toolCalls, config: config, emit: emit)
        }
        return await executeToolCallsParallel(context: context, assistantMessage: assistantMessage, toolCalls: toolCalls, config: config, emit: emit)
    }

    private static func executeToolCallsSequential(context: AgentContext, assistantMessage: AssistantMessage, toolCalls: [ToolCall], config: AgentLoopConfig, emit: @escaping AgentEventEmitter) async -> ToolBatch {
        var finalizedCalls: [FinalizedToolCall] = []
        var messages: [ToolResultMessage] = []
        for toolCall in toolCalls {
            await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
            let preparation = await prepareToolCall(context: context, assistantMessage: assistantMessage, toolCall: toolCall, config: config)
            let finalized: FinalizedToolCall
            switch preparation {
            case .immediate(let result, let isError):
                finalized = FinalizedToolCall(toolCall: toolCall, result: result, isError: isError)
            case .prepared(let tool, let args):
                let executed = await executePreparedToolCall(tool: tool, toolCall: toolCall, args: args, emit: emit)
                finalized = await finalizeExecutedToolCall(context: context, assistantMessage: assistantMessage, toolCall: toolCall, args: args, executed: executed, config: config)
            }
            await emitToolExecutionEnd(finalized, emit: emit)
            let message = toolResultMessage(finalized)
            await emitToolResultMessage(message, emit: emit)
            finalizedCalls.append(finalized)
            messages.append(message)
            if Task.isCancelled { break }
        }
        return ToolBatch(messages: messages, terminate: shouldTerminate(finalizedCalls))
    }

    private static func executeToolCallsParallel(context: AgentContext, assistantMessage: AssistantMessage, toolCalls: [ToolCall], config: AgentLoopConfig, emit: @escaping AgentEventEmitter) async -> ToolBatch {
        var immediate: [Int: FinalizedToolCall] = [:]
        var prepared: [(index: Int, toolCall: ToolCall, tool: any AgentTool, args: JSONValue)] = []
        var count = 0
        for (index, toolCall) in toolCalls.enumerated() {
            await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
            count = index + 1
            let preparation = await prepareToolCall(context: context, assistantMessage: assistantMessage, toolCall: toolCall, config: config)
            switch preparation {
            case .immediate(let result, let isError):
                let finalized = FinalizedToolCall(toolCall: toolCall, result: result, isError: isError)
                await emitToolExecutionEnd(finalized, emit: emit)
                immediate[index] = finalized
            case .prepared(let tool, let args):
                prepared.append((index, toolCall, tool, args))
            }
            if Task.isCancelled { break }
        }

        let executedResults = await withTaskGroup(of: (Int, FinalizedToolCall).self, returning: [Int: FinalizedToolCall].self) { group in
            for item in prepared {
                group.addTask {
                    if Task.isCancelled {
                        let finalized = FinalizedToolCall(toolCall: item.toolCall, result: errorResult("Operation aborted"), isError: true)
                        await emitToolExecutionEnd(finalized, emit: emit)
                        return (item.index, finalized)
                    }
                    let executed = await executePreparedToolCall(tool: item.tool, toolCall: item.toolCall, args: item.args, emit: emit)
                    let finalized = await finalizeExecutedToolCall(context: context, assistantMessage: assistantMessage, toolCall: item.toolCall, args: item.args, executed: executed, config: config)
                    await emitToolExecutionEnd(finalized, emit: emit)
                    return (item.index, finalized)
                }
            }
            var collected: [Int: FinalizedToolCall] = [:]
            for await (index, finalized) in group { collected[index] = finalized }
            return collected
        }

        var ordered: [FinalizedToolCall] = []
        for index in 0..<count {
            if let finalized = immediate[index] ?? executedResults[index] { ordered.append(finalized) }
        }
        var messages: [ToolResultMessage] = []
        for finalized in ordered {
            let message = toolResultMessage(finalized)
            await emitToolResultMessage(message, emit: emit)
            messages.append(message)
        }
        return ToolBatch(messages: messages, terminate: shouldTerminate(ordered))
    }

    private static func shouldTerminate(_ finalized: [FinalizedToolCall]) -> Bool {
        !finalized.isEmpty && finalized.allSatisfy { $0.result.terminate == true }
    }

    private static func prepareToolCall(context: AgentContext, assistantMessage: AssistantMessage, toolCall: ToolCall, config: AgentLoopConfig) async -> Preparation {
        guard let tool = context.tools.first(where: { $0.name == toolCall.name }) else {
            return .immediate(result: errorResult("Tool \(toolCall.name) not found"), isError: true)
        }
        let preparedArguments = tool.prepareArguments(toolCall.arguments)
        let validatedArgs: JSONValue
        do {
            validatedArgs = try JSONSchemaValidator.validate(schema: tool.definition.parameters, arguments: preparedArguments)
        } catch {
            return .immediate(result: errorResult("Validation failed for tool \"\(toolCall.name)\": \(error)"), isError: true)
        }
        if let before = config.beforeToolCall {
            let result = await before(BeforeToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, args: validatedArgs, context: context))
            if Task.isCancelled {
                return .immediate(result: errorResult("Operation aborted"), isError: true)
            }
            if result?.block == true {
                var blocked = errorResult(result?.reason ?? "Tool execution was blocked")
                if result?.terminate == true { blocked.terminate = true }
                return .immediate(result: blocked, isError: true)
            }
        }
        if Task.isCancelled {
            return .immediate(result: errorResult("Operation aborted"), isError: true)
        }
        return .prepared(tool: tool, args: validatedArgs)
    }

    /// 执行工具。中途更新按到达顺序发完再返回（对应上游 await Promise.all(updateEvents)）。
    private static func executePreparedToolCall(tool: any AgentTool, toolCall: ToolCall, args: JSONValue, emit: @escaping AgentEventEmitter) async -> (result: AgentToolResult, isError: Bool) {
        let (updates, continuation) = AsyncStream<AgentToolResult>.makeStream()
        let relay = Task {
            for await partial in updates {
                await emit(.toolExecutionUpdate(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments, partialResult: partial))
            }
        }
        do {
            let result = try await tool.execute(toolCallId: toolCall.id, args: args) { partial in
                continuation.yield(partial)
            }
            continuation.finish()
            await relay.value
            return (result, false)
        } catch {
            continuation.finish()
            await relay.value
            let message = error is CancellationError ? "Operation aborted" : ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return (errorResult(message), true)
        }
    }

    private static func finalizeExecutedToolCall(context: AgentContext, assistantMessage: AssistantMessage, toolCall: ToolCall, args: JSONValue, executed: (result: AgentToolResult, isError: Bool), config: AgentLoopConfig) async -> FinalizedToolCall {
        var result = executed.result
        var isError = executed.isError
        if let after = config.afterToolCall,
           let override = await after(AfterToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, args: args, result: result, isError: isError, context: context)) {
            if let content = override.content { result.content = content }
            if let details = override.details { result.details = details }
            if let usage = override.usage { result.usage = usage }
            if let terminate = override.terminate { result.terminate = terminate }
            if let flag = override.isError { isError = flag }
        }
        return FinalizedToolCall(toolCall: toolCall, result: result, isError: isError)
    }

    static func errorResult(_ message: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: message))], details: .object([:]))
    }

    private static func emitToolExecutionEnd(_ finalized: FinalizedToolCall, emit: @escaping AgentEventEmitter) async {
        await emit(.toolExecutionEnd(toolCallId: finalized.toolCall.id, toolName: finalized.toolCall.name, result: finalized.result, isError: finalized.isError))
    }

    private static func toolResultMessage(_ finalized: FinalizedToolCall) -> ToolResultMessage {
        ToolResultMessage(
            toolCallId: finalized.toolCall.id,
            toolName: finalized.toolCall.name,
            content: finalized.result.content,
            details: finalized.result.details,
            usage: finalized.result.usage,
            addedToolNames: (finalized.result.addedToolNames?.isEmpty == false) ? finalized.result.addedToolNames : nil,
            isError: finalized.isError
        )
    }

    private static func emitToolResultMessage(_ message: ToolResultMessage, emit: @escaping AgentEventEmitter) async {
        await emit(.messageStart(message: .toolResult(message)))
        await emit(.messageEnd(message: .toolResult(message)))
    }
}
