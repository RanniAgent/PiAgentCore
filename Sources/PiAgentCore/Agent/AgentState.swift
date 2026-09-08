// 对应上游：packages/agent/src/types.ts 的 AgentState。
import Foundation

public enum QueueMode: String, Sendable, Codable {
    case all
    case oneAtATime = "one-at-a-time"
}

public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [any AgentTool]
    public var messages: [AgentMessage]
    public internal(set) var isStreaming: Bool = false
    public internal(set) var streamingMessage: AgentMessage? = nil
    public internal(set) var pendingToolCalls: Set<String> = []
    public internal(set) var errorMessage: String? = nil

    public init(systemPrompt: String, model: Model = .unknown, thinkingLevel: ThinkingLevel = .off, tools: [any AgentTool] = [], messages: [AgentMessage] = []) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
    }
}
