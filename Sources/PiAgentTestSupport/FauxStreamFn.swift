// 对应上游：packages/ai/src/providers/faux.ts 的 streamWithDeltas。
// 切块规则：每块 tokenSize * 4 个字符，空文本一块空串；abort 检查点与上游相同。
import Foundation
import PiAgentCore

public actor FauxProvider {
    private var responses: [ScenarioResponse]
    private let tokenSize: Int
    public private(set) var callCount = 0

    public init(responses: [ScenarioResponse], tokenSize: Int) {
        self.responses = responses
        self.tokenSize = max(1, tokenSize)
    }

    public static func chunks(_ text: String, tokenSize: Int) -> [String] {
        let size = max(1, tokenSize * 4)
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result.isEmpty ? [""] : result
    }

    public nonisolated func makeStreamFn() -> StreamFn {
        return { model, _, _ in
            let stream = AssistantMessageEventStream()
            let producer = Task { await self.produce(model: model, into: stream) }
            await stream.setCancellationHandler { producer.cancel() }
            return stream
        }
    }

    private func nextResponse() -> ScenarioResponse? {
        callCount += 1
        guard !responses.isEmpty else { return nil }
        return responses.removeFirst()
    }

    private func produce(model: Model, into stream: AssistantMessageEventStream) async {
        let tokenSize = self.tokenSize
        guard let response = nextResponse() else {
            let error = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id, stopReason: .error, errorMessage: "Faux provider has no more scripted responses", timestamp: 0)
            await stream.push(.error(reason: .error, error: error))
            return
        }
        var partial = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id, stopReason: .pending, timestamp: 0)

        func aborted() -> AssistantMessage {
            var m = partial
            m.stopReason = .aborted
            m.errorMessage = "Request was aborted"
            return m
        }

        if Task.isCancelled {
            await stream.push(.error(reason: .aborted, error: aborted()))
            return
        }
        await stream.push(.start(partial: partial))

        for (index, block) in response.content.enumerated() {
            if Task.isCancelled {
                await stream.push(.error(reason: .aborted, error: aborted()))
                return
            }
            switch block {
            case .thinking(let thinking):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                await stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in Self.chunks(thinking, tokenSize: tokenSize) {
                    await Task.yield()
                    if Task.isCancelled {
                        await stream.push(.error(reason: .aborted, error: aborted()))
                        return
                    }
                    if case .thinking(var b) = partial.content[index] { b.thinking += chunk; partial.content[index] = .thinking(b) }
                    await stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                await stream.push(.thinkingEnd(contentIndex: index, content: thinking, partial: partial))
            case .text(let text):
                partial.content.append(.text(TextContent(text: "")))
                await stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in Self.chunks(text, tokenSize: tokenSize) {
                    await Task.yield()
                    if Task.isCancelled {
                        await stream.push(.error(reason: .aborted, error: aborted()))
                        return
                    }
                    if case .text(var b) = partial.content[index] { b.text += chunk; partial.content[index] = .text(b) }
                    await stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                await stream.push(.textEnd(contentIndex: index, content: text, partial: partial))
            case .toolCall(let id, let name, let argumentsText):
                partial.content.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
                await stream.push(.toolcallStart(contentIndex: index, partial: partial))
                for chunk in Self.chunks(argumentsText, tokenSize: tokenSize) {
                    await Task.yield()
                    if Task.isCancelled {
                        await stream.push(.error(reason: .aborted, error: aborted()))
                        return
                    }
                    await stream.push(.toolcallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                let arguments = (try? JSONValue.parse(argumentsText)) ?? .object([:])
                let call = ToolCall(id: id, name: name, arguments: arguments)
                partial.content[index] = .toolCall(call)
                await stream.push(.toolcallEnd(contentIndex: index, toolCall: call, partial: partial))
            }
        }

        var final = partial
        final.stopReason = response.stopReason
        final.errorMessage = response.errorMessage
        if response.stopReason == .error || response.stopReason == .aborted {
            await stream.push(.error(reason: response.stopReason, error: final))
        } else {
            await stream.push(.done(reason: response.stopReason, message: final))
        }
    }
}
