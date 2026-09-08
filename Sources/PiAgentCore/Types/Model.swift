// 对应上游：packages/ai/src/types.ts 的 Model / ModelCost / ThinkingLevel / SimpleStreamOptions（只取循环用到的子集）。
import Foundation

public struct ModelCost: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public static let zero = ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct Model: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var api: String
    public var provider: String
    public var baseUrl: String
    public var reasoning: Bool
    public var input: [String]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    public var headers: [String: String]?

    public init(id: String, name: String, api: String, provider: String, baseUrl: String, reasoning: Bool, input: [String], cost: ModelCost, contextWindow: Int, maxTokens: Int, headers: [String: String]? = nil) {
        self.id = id; self.name = name; self.api = api; self.provider = provider; self.baseUrl = baseUrl
        self.reasoning = reasoning; self.input = input; self.cost = cost; self.contextWindow = contextWindow
        self.maxTokens = maxTokens; self.headers = headers
    }

    /// pi 的 DEFAULT_MODEL：Agent 没给模型时的占位。
    public static let unknown = Model(id: "unknown", name: "unknown", api: "unknown", provider: "unknown", baseUrl: "", reasoning: false, input: [], cost: .zero, contextWindow: 0, maxTokens: 0)
}

public enum ThinkingLevel: String, Sendable, Codable {
    case off, minimal, low, medium, high, xhigh, max
}

public enum ToolChoice: String, Sendable, Codable {
    case auto, none
}

/// 循环传给流函数的选项。pi 的 SimpleStreamOptions 只取和请求内容有关的字段。
public struct SimpleStreamOptions: Sendable, Hashable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var reasoning: ThinkingLevel?
    public var thinkingBudgets: [String: Int]?
    public var toolChoice: ToolChoice?
    public var cacheRetention: String?
    public var sessionId: String?
    public var apiKey: String?

    public init(temperature: Double? = nil, maxTokens: Int? = nil, reasoning: ThinkingLevel? = nil, thinkingBudgets: [String: Int]? = nil, toolChoice: ToolChoice? = nil, cacheRetention: String? = nil, sessionId: String? = nil, apiKey: String? = nil) {
        self.temperature = temperature; self.maxTokens = maxTokens; self.reasoning = reasoning
        self.thinkingBudgets = thinkingBudgets; self.toolChoice = toolChoice; self.cacheRetention = cacheRetention
        self.sessionId = sessionId; self.apiKey = apiKey
    }
}
