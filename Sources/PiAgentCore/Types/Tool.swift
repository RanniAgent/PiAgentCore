// 对应上游：packages/ai/src/types.ts 的 Tool，packages/agent/src/types.ts 的 AgentTool / AgentToolResult / ToolExecutionMode。
import Foundation

/// 给模型看的工具定义。parameters 是 JSON Schema。
public struct ToolDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public enum ToolExecutionMode: String, Sendable, Codable {
    case sequential, parallel
}

public struct AgentToolResult: Sendable, Hashable {
    public var content: [ToolResultContent]
    public var details: JSONValue?
    public var usage: Usage?
    public var addedToolNames: [String]?
    /// 整批都为 true 才提前收工。
    public var terminate: Bool?

    public init(content: [ToolResultContent], details: JSONValue? = nil, usage: Usage? = nil, addedToolNames: [String]? = nil, terminate: Bool? = nil) {
        self.content = content; self.details = details; self.usage = usage
        self.addedToolNames = addedToolNames; self.terminate = terminate
    }

    public static func text(_ text: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: text))])
    }
}

/// 运行时执行的工具。失败请抛错，不要把错误编码进 content（和 pi 一致）。
/// pi 的 signal 参数在 Swift 里是 Task 取消：实现里用 Task.checkCancellation()。
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    var label: String { get }
    var executionMode: ToolExecutionMode? { get }
    func prepareArguments(_ raw: JSONValue) -> JSONValue
    func execute(
        toolCallId: String,
        args: JSONValue,
        onUpdate: @escaping @Sendable (AgentToolResult) -> Void
    ) async throws -> AgentToolResult
}

public extension AgentTool {
    var name: String { definition.name }
    var executionMode: ToolExecutionMode? { nil }
    func prepareArguments(_ raw: JSONValue) -> JSONValue { raw }
}
