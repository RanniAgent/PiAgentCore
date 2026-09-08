// 对应上游：packages/ai/src/types.ts 的 TextContent / ThinkingContent / ImageContent / ToolCall。
import Foundation

public struct TextContent: Sendable, Hashable, Codable {
    public var text: String
    public var textSignature: String?
    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

public struct ThinkingContent: Sendable, Hashable, Codable {
    public var thinking: String
    public var thinkingSignature: String?
    public var redacted: Bool?
    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

public struct ImageContent: Sendable, Hashable, Codable {
    /// base64
    public var data: String
    public var mimeType: String
    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var thoughtSignature: String?
    public var namespace: String?
    public init(id: String, name: String, arguments: JSONValue, thoughtSignature: String? = nil, namespace: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.namespace = namespace
    }
}

/// 用 `type` 字段判别的内容块编解码辅助。
enum ContentTypeKey: String, CodingKey { case type }

extension KeyedDecodingContainer where K == ContentTypeKey {
    func contentType() throws -> String { try decode(String.self, forKey: .type) }
}

public enum AssistantContent: Sendable, Hashable, Codable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ContentTypeKey.self)
        switch try container.contentType() {
        case "text": self = .text(try TextContent(from: decoder))
        case "thinking": self = .thinking(try ThinkingContent(from: decoder))
        case "toolCall": self = .toolCall(try ToolCall(from: decoder))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown assistant content type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ContentTypeKey.self)
        switch self {
        case .text(let value): try container.encode("text", forKey: .type); try value.encode(to: encoder)
        case .thinking(let value): try container.encode("thinking", forKey: .type); try value.encode(to: encoder)
        case .toolCall(let value): try container.encode("toolCall", forKey: .type); try value.encode(to: encoder)
        }
    }
}

public enum UserContentBlock: Sendable, Hashable, Codable {
    case text(TextContent)
    case image(ImageContent)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ContentTypeKey.self)
        switch try container.contentType() {
        case "text": self = .text(try TextContent(from: decoder))
        case "image": self = .image(try ImageContent(from: decoder))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown user content type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ContentTypeKey.self)
        switch self {
        case .text(let value): try container.encode("text", forKey: .type); try value.encode(to: encoder)
        case .image(let value): try container.encode("image", forKey: .type); try value.encode(to: encoder)
        }
    }
}

public typealias ToolResultContent = UserContentBlock

/// pi 的 user content 是 `string | (Text|Image)[]`。
public enum UserContent: Sendable, Hashable, Codable {
    case text(String)
    case blocks([UserContentBlock])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text); return }
        self = .blocks(try container.decode([UserContentBlock].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
}
