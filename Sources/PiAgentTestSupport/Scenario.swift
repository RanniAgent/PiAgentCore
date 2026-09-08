// 场景文件的 Swift 模型。字段含义见计划 B2 顶部的格式说明；TS 导出脚本吃同一份文件。
import Foundation
import PiAgentCore

public struct Scenario: Codable, Sendable {
    public var name: String
    public var systemPrompt: String
    public var prompt: String
    public var tokenSize: Int
    public var toolExecution: ToolExecutionMode
    public var steeringMode: String
    public var followUpMode: String
    public var tools: [ScenarioTool]
    public var responses: [ScenarioResponse]
    public var batches: [ScenarioBatch]
    public var actions: [ScenarioAction]

    public init(name: String, systemPrompt: String, prompt: String, tokenSize: Int = 2, toolExecution: ToolExecutionMode = .parallel, steeringMode: String = "one-at-a-time", followUpMode: String = "one-at-a-time", tools: [ScenarioTool] = [], responses: [ScenarioResponse], batches: [ScenarioBatch] = [], actions: [ScenarioAction] = []) {
        self.name = name; self.systemPrompt = systemPrompt; self.prompt = prompt; self.tokenSize = tokenSize
        self.toolExecution = toolExecution; self.steeringMode = steeringMode; self.followUpMode = followUpMode
        self.tools = tools; self.responses = responses; self.batches = batches; self.actions = actions
    }

    public static func load(from url: URL) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
    }
}

public struct ScenarioTool: Codable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var executionMode: ToolExecutionMode?
    public var results: [ScenarioToolResult]

    public init(name: String, description: String, parameters: JSONValue, executionMode: ToolExecutionMode? = nil, results: [ScenarioToolResult]) {
        self.name = name; self.description = description; self.parameters = parameters
        self.executionMode = executionMode; self.results = results
    }
}

public struct ScenarioToolResult: Codable, Sendable {
    public var updates: [String]?
    public var content: [ScenarioBlock]?
    public var details: JSONValue?
    public var `throw`: String?

    public init(updates: [String]? = nil, content: [ScenarioBlock]? = nil, details: JSONValue? = nil, throw throwMessage: String? = nil) {
        self.updates = updates; self.content = content; self.details = details; self.throw = throwMessage
    }
}

public struct ScenarioResponse: Codable, Sendable {
    public var content: [ScenarioBlock]
    public var stopReason: StopReason
    public var errorMessage: String?
    public init(content: [ScenarioBlock], stopReason: StopReason, errorMessage: String?) {
        self.content = content; self.stopReason = stopReason; self.errorMessage = errorMessage
    }
}

/// 场景里的内容块。toolCall 的参数是原始文本，切块时直接切它。
public enum ScenarioBlock: Codable, Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, argumentsText: String)

    private enum Keys: String, CodingKey { case type, text, thinking, id, name, argumentsText }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thinking": self = .thinking(try c.decode(String.self, forKey: .thinking))
        case "toolCall": self = .toolCall(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), argumentsText: try c.decode(String.self, forKey: .argumentsText))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown block \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .thinking(let t): try c.encode("thinking", forKey: .type); try c.encode(t, forKey: .thinking)
        case .toolCall(let id, let name, let args): try c.encode("toolCall", forKey: .type); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(args, forKey: .argumentsText)
        }
    }
}

public struct ScenarioBatch: Codable, Sendable {
    public var completionOrder: [Int]
    public init(completionOrder: [Int]) { self.completionOrder = completionOrder }
}

public struct ScenarioAction: Codable, Sendable {
    public var on: String
    public var occurrence: Int
    public var `do`: String
    public var text: String?
}
