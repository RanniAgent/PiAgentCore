// 对应上游：pi-ai 各 api 适配器里"原始增量 → 带 partial 快照的 AssistantMessageEvent"的公共部分。
// 一个 transport 只需要吐 RawAssistantDelta，装配器负责块的开合、索引、参数的尽力解析。
import Foundation

public enum RawAssistantDelta: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case thinkingSignature(String)
    case toolCallStart(id: String, name: String)
    case toolCallArgumentsDelta(id: String, fragment: String)
    case toolCallEnd(id: String, name: String, argumentsJSON: String)
    case finished(stopReason: StopReason, usage: Usage?, rawStopReason: String?)
    case error(message: String, aborted: Bool)
}

public struct AssistantMessageAssembler: Sendable {
    private enum OpenBlock: Sendable {
        case text(Int)
        case thinking(Int)
        case toolCall(index: Int, id: String, argumentsText: String)
    }

    public private(set) var partial: AssistantMessage
    public private(set) var isFinished = false
    private var openBlock: OpenBlock?

    public init(model: Model, timestamp: Int64 = Clock.nowMilliseconds()) {
        partial = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id, stopReason: .pending, timestamp: timestamp)
    }

    public mutating func start() -> AssistantMessageEvent {
        .start(partial: partial)
    }

    public mutating func consume(_ delta: RawAssistantDelta) -> [AssistantMessageEvent] {
        guard !isFinished else { return [] }
        var events: [AssistantMessageEvent] = []
        switch delta {
        case .textDelta(let text):
            if case .text(let index)? = openBlock {
                appendText(text, at: index)
                events.append(.textDelta(contentIndex: index, delta: text, partial: partial))
            } else {
                events += closeOpenBlock()
                partial.content.append(.text(TextContent(text: "")))
                let index = partial.content.count - 1
                openBlock = .text(index)
                events.append(.textStart(contentIndex: index, partial: partial))
                appendText(text, at: index)
                events.append(.textDelta(contentIndex: index, delta: text, partial: partial))
            }
        case .thinkingDelta(let text):
            if case .thinking(let index)? = openBlock {
                appendThinking(text, at: index)
                events.append(.thinkingDelta(contentIndex: index, delta: text, partial: partial))
            } else {
                events += closeOpenBlock()
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                let index = partial.content.count - 1
                openBlock = .thinking(index)
                events.append(.thinkingStart(contentIndex: index, partial: partial))
                appendThinking(text, at: index)
                events.append(.thinkingDelta(contentIndex: index, delta: text, partial: partial))
            }
        case .thinkingSignature(let signature):
            if case .thinking(let index)? = openBlock, case .thinking(var block) = partial.content[index] {
                block.thinkingSignature = signature
                partial.content[index] = .thinking(block)
            }
        case .toolCallStart(let id, let name):
            events += closeOpenBlock()
            partial.content.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
            let index = partial.content.count - 1
            openBlock = .toolCall(index: index, id: id, argumentsText: "")
            events.append(.toolcallStart(contentIndex: index, partial: partial))
        case .toolCallArgumentsDelta(let id, let fragment):
            guard case .toolCall(let index, let openID, var text)? = openBlock, openID == id else { break }
            text += fragment
            openBlock = .toolCall(index: index, id: id, argumentsText: text)
            if case .toolCall(var call) = partial.content[index] {
                call.arguments = StreamingJSON.parseStreaming(text)
                partial.content[index] = .toolCall(call)
            }
            events.append(.toolcallDelta(contentIndex: index, delta: fragment, partial: partial))
        case .toolCallEnd(let id, let name, let argumentsJSON):
            if case .toolCall(let index, let openID, _)? = openBlock, openID == id {
                events += finishToolCall(at: index, argumentsJSON: argumentsJSON)
            } else {
                events += closeOpenBlock()
                partial.content.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
                let index = partial.content.count - 1
                openBlock = .toolCall(index: index, id: id, argumentsText: "")
                events.append(.toolcallStart(contentIndex: index, partial: partial))
                events += finishToolCall(at: index, argumentsJSON: argumentsJSON)
            }
        case .finished(let stopReason, let usage, let rawStopReason):
            events += closeOpenBlock()
            if let usage { partial.usage = usage }
            partial.rawStopReason = rawStopReason
            isFinished = true
            if stopReason == .error || stopReason == .aborted {
                partial.stopReason = stopReason
                events.append(.error(reason: stopReason, error: partial))
            } else {
                partial.stopReason = stopReason
                events.append(.done(reason: stopReason, message: partial))
            }
        case .error(let message, let aborted):
            events += closeOpenBlock()
            partial.stopReason = aborted ? .aborted : .error
            partial.errorMessage = message
            isFinished = true
            events.append(.error(reason: partial.stopReason, error: partial))
        }
        return events
    }

    // MARK: - 内部

    private mutating func appendText(_ text: String, at index: Int) {
        if case .text(var block) = partial.content[index] {
            block.text += text
            partial.content[index] = .text(block)
        }
    }

    private mutating func appendThinking(_ text: String, at index: Int) {
        if case .thinking(var block) = partial.content[index] {
            block.thinking += text
            partial.content[index] = .thinking(block)
        }
    }

    private mutating func finishToolCall(at index: Int, argumentsJSON: String) -> [AssistantMessageEvent] {
        guard case .toolCall(var call) = partial.content[index] else { return [] }
        call.arguments = (try? StreamingJSON.parseWithRepair(argumentsJSON)) ?? StreamingJSON.parseStreaming(argumentsJSON)
        partial.content[index] = .toolCall(call)
        openBlock = nil
        return [.toolcallEnd(contentIndex: index, toolCall: call, partial: partial)]
    }

    private mutating func closeOpenBlock() -> [AssistantMessageEvent] {
        guard let open = openBlock else { return [] }
        switch open {
        case .text(let index):
            openBlock = nil
            guard case .text(let block) = partial.content[index] else { return [] }
            return [.textEnd(contentIndex: index, content: block.text, partial: partial)]
        case .thinking(let index):
            openBlock = nil
            guard case .thinking(let block) = partial.content[index] else { return [] }
            return [.thinkingEnd(contentIndex: index, content: block.thinking, partial: partial)]
        case .toolCall(let index, _, let text):
            return finishToolCall(at: index, argumentsJSON: text)
        }
    }
}
