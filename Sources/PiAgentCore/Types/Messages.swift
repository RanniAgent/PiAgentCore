// 对应上游：packages/ai/src/types.ts 的 Usage / StopReason / UserMessage / AssistantMessage / ToolResultMessage / Message，
// packages/agent/src/types.ts 的 AgentMessage（自定义消息用 custom 分支 + JSON 载荷代替 TS 的声明合并）。
import Foundation

public struct Usage: Sendable, Hashable, Codable {
    public struct Cost: Sendable, Hashable, Codable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
        public var total: Double
        public static let zero = Cost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0)
        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, total: Double) {
            self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.total = total
        }
    }

    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cacheWrite1h: Int?
    public var reasoning: Int?
    public var totalTokens: Int
    public var cost: Cost

    public static let zero = Usage(input: 0, output: 0)

    public init(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int? = nil, reasoning: Int? = nil, totalTokens: Int? = nil, cost: Cost = .zero) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.reasoning = reasoning
        self.totalTokens = totalTokens ?? (input + output + cacheRead + cacheWrite)
        self.cost = cost
    }
}

public enum StopReason: String, Sendable, Codable {
    case pending, stop, length, toolUse, error, aborted, deferred
}

public struct UserMessage: Sendable, Hashable, Codable {
    public var content: UserContent
    public var timestamp: Int64
    public init(content: UserContent, timestamp: Int64 = Clock.nowMilliseconds()) {
        self.content = content
        self.timestamp = timestamp
    }
}

public struct AssistantMessage: Sendable, Hashable, Codable {
    public var content: [AssistantContent]
    public var api: String
    public var provider: String
    public var model: String
    public var responseModel: String?
    public var responseId: String?
    public var providerThinkingLevel: String?
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var rawStopReason: String?
    public var endTurn: Bool?
    public var timestamp: Int64

    public init(
        content: [AssistantContent], api: String, provider: String, model: String,
        responseModel: String? = nil, responseId: String? = nil, providerThinkingLevel: String? = nil,
        usage: Usage = .zero, stopReason: StopReason, errorMessage: String? = nil,
        rawStopReason: String? = nil, endTurn: Bool? = nil, timestamp: Int64 = Clock.nowMilliseconds()
    ) {
        self.content = content; self.api = api; self.provider = provider; self.model = model
        self.responseModel = responseModel; self.responseId = responseId; self.providerThinkingLevel = providerThinkingLevel
        self.usage = usage; self.stopReason = stopReason; self.errorMessage = errorMessage
        self.rawStopReason = rawStopReason; self.endTurn = endTurn; self.timestamp = timestamp
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { if case .toolCall(let call) = $0 { return call }; return nil }
    }
}

public struct ToolResultMessage: Sendable, Hashable, Codable {
    public var toolCallId: String
    public var toolName: String
    public var content: [ToolResultContent]
    public var details: JSONValue?
    public var usage: Usage?
    public var addedToolNames: [String]?
    public var isError: Bool
    public var timestamp: Int64

    public init(toolCallId: String, toolName: String, content: [ToolResultContent], details: JSONValue? = nil, usage: Usage? = nil, addedToolNames: [String]? = nil, isError: Bool, timestamp: Int64 = Clock.nowMilliseconds()) {
        self.toolCallId = toolCallId; self.toolName = toolName; self.content = content; self.details = details
        self.usage = usage; self.addedToolNames = addedToolNames; self.isError = isError; self.timestamp = timestamp
    }
}

/// App 自定义消息。convertToLlm 决定它给模型看成什么。
public struct CustomAgentMessage: Sendable, Hashable, Codable {
    public var customType: String
    public var payload: JSONValue
    public var timestamp: Int64
    public init(customType: String, payload: JSONValue, timestamp: Int64 = Clock.nowMilliseconds()) {
        self.customType = customType; self.payload = payload; self.timestamp = timestamp
    }
}

enum RoleKey: String, CodingKey { case role }

/// 模型能看懂的三种消息。
public enum Message: Sendable, Hashable, Codable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RoleKey.self)
        switch try container.decode(String.self, forKey: .role) {
        case "user": self = .user(try UserMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult": self = .toolResult(try ToolResultMessage(from: decoder))
        case let other: throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Unknown LLM message role \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RoleKey.self)
        switch self {
        case .user(let value): try container.encode("user", forKey: .role); try value.encode(to: encoder)
        case .assistant(let value): try container.encode("assistant", forKey: .role); try value.encode(to: encoder)
        case .toolResult(let value): try container.encode("toolResult", forKey: .role); try value.encode(to: encoder)
        }
    }
}

/// 循环内部流转的消息：三种模型消息 + App 自定义消息。
public enum AgentMessage: Sendable, Hashable, Codable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(CustomAgentMessage)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RoleKey.self)
        switch try container.decode(String.self, forKey: .role) {
        case "user": self = .user(try UserMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult": self = .toolResult(try ToolResultMessage(from: decoder))
        case "custom": self = .custom(try CustomAgentMessage(from: decoder))
        case let other: throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Unknown agent message role \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RoleKey.self)
        switch self {
        case .user(let value): try container.encode("user", forKey: .role); try value.encode(to: encoder)
        case .assistant(let value): try container.encode("assistant", forKey: .role); try value.encode(to: encoder)
        case .toolResult(let value): try container.encode("toolResult", forKey: .role); try value.encode(to: encoder)
        case .custom(let value): try container.encode("custom", forKey: .role); try value.encode(to: encoder)
        }
    }

    public var role: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolResult: return "toolResult"
        case .custom: return "custom"
        }
    }

    public var timestamp: Int64 {
        switch self {
        case .user(let m): return m.timestamp
        case .assistant(let m): return m.timestamp
        case .toolResult(let m): return m.timestamp
        case .custom(let m): return m.timestamp
        }
    }

    /// 默认的 convertToLlm：三种模型消息原样过，自定义消息丢掉。
    public var llmMessage: Message? {
        switch self {
        case .user(let m): return .user(m)
        case .assistant(let m): return .assistant(m)
        case .toolResult(let m): return .toolResult(m)
        case .custom: return nil
        }
    }
}

public enum Clock {
    /// 毫秒时间戳，和 JS 的 Date.now() 同尺度。
    public static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
