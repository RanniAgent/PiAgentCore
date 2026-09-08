import Foundation
import Testing
@testable import PiAgentCore
@testable import PiAgentTestSupport

struct FauxStreamFnTests {
    let model = Model(id: "faux-1", name: "faux", api: "faux", provider: "faux", baseUrl: "", reasoning: true, input: ["text"], cost: .zero, contextWindow: 1000, maxTokens: 100)

    @Test func splitsTextIntoFixedSizeChunksLikePiFaux() {
        #expect(FauxProvider.chunks("abcdefghijk", tokenSize: 2) == ["abcdefgh", "ijk"])
        #expect(FauxProvider.chunks("", tokenSize: 2) == [""])
        #expect(FauxProvider.chunks("12345678", tokenSize: 2) == ["12345678"])
    }

    @Test func streamsBlocksInPiOrder() async throws {
        let response = ScenarioResponse(content: [
            .thinking("hmm hmm hmm"),
            .text("hello"),
            .toolCall(id: "call_1", name: "echo", argumentsText: #"{"text":"a"}"#),
        ], stopReason: .toolUse, errorMessage: nil)
        let provider = FauxProvider(responses: [response], tokenSize: 2)
        let streamFn = provider.makeStreamFn()
        let stream = await streamFn(model, LLMContext(systemPrompt: nil, messages: [], tools: nil), SimpleStreamOptions())
        var kinds: [String] = []
        for await event in stream.events {
            switch event {
            case .start: kinds.append("start")
            case .thinkingStart: kinds.append("thinking_start")
            case .thinkingDelta(_, let d, _): kinds.append("thinking_delta:\(d)")
            case .thinkingEnd: kinds.append("thinking_end")
            case .textStart: kinds.append("text_start")
            case .textDelta(_, let d, _): kinds.append("text_delta:\(d)")
            case .textEnd: kinds.append("text_end")
            case .toolcallStart: kinds.append("toolcall_start")
            case .toolcallDelta(_, let d, _): kinds.append("toolcall_delta:\(d)")
            case .toolcallEnd(_, let call, _): kinds.append("toolcall_end:\(call.id)")
            case .done(let r, _): kinds.append("done:\(r.rawValue)")
            case .error(let r, _): kinds.append("error:\(r.rawValue)")
            }
        }
        #expect(kinds == [
            "start",
            "thinking_start", "thinking_delta:hmm hmm ", "thinking_delta:hmm", "thinking_end",
            "text_start", "text_delta:hello", "text_end",
            "toolcall_start", "toolcall_delta:{\"text\":", "toolcall_delta:\"a\"}", "toolcall_end:call_1",
            "done:toolUse",
        ])
        let final = await stream.result()
        #expect(final?.content[2] == .toolCall(ToolCall(id: "call_1", name: "echo", arguments: ["text": "a"])))
        #expect(await provider.callCount == 1)
    }

    @Test func runsOutOfResponsesAsError() async {
        let provider = FauxProvider(responses: [], tokenSize: 2)
        let stream = await provider.makeStreamFn()(model, LLMContext(systemPrompt: nil, messages: [], tools: nil), SimpleStreamOptions())
        for await _ in stream.events {}
        #expect(await stream.result()?.stopReason == .error)
    }

    @Test func completionBarrierReleasesInConfiguredOrder() async {
        let barrier = CompletionBarrier()
        await barrier.register(batch: ["c1", "c2"], completionOrder: [2, 1])
        let log = OrderLog()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await barrier.waitForTurn("c1"); log.append("c1"); await barrier.finished("c1") }
            group.addTask { await barrier.waitForTurn("c2"); log.append("c2"); await barrier.finished("c2") }
        }
        #expect(log.items == ["c2", "c1"])
    }
}
