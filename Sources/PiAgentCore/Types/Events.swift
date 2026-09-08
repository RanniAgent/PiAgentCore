// 对应上游：packages/ai/src/types.ts 的 AssistantMessageEvent，packages/agent/src/types.ts 的 AgentEvent。
import Foundation

public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolcallStart(contentIndex: Int, partial: AssistantMessage)
    case toolcallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolcallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    /// reason 只会是 stop / length / toolUse / deferred
    case done(reason: StopReason, message: AssistantMessage)
    /// reason 只会是 error / aborted
    case error(reason: StopReason, error: AssistantMessage)

    public var isTerminal: Bool {
        switch self {
        case .done, .error: return true
        default: return false
        }
    }

    /// 事件里附带的消息快照（终止事件给最终消息）。
    public var message: AssistantMessage {
        switch self {
        case .start(let p), .textStart(_, let p), .textDelta(_, _, let p), .textEnd(_, _, let p),
             .thinkingStart(_, let p), .thinkingDelta(_, _, let p), .thinkingEnd(_, _, let p),
             .toolcallStart(_, let p), .toolcallDelta(_, _, let p), .toolcallEnd(_, _, let p):
            return p
        case .done(_, let m), .error(_, let m):
            return m
        }
    }
}

public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd(messages: [AgentMessage])
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    case messageStart(message: AgentMessage)
    case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
    case messageEnd(message: AgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)
}
