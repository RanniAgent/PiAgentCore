import Foundation
import Testing
@testable import PiAgentCore

struct AssistantMessageEventStreamTests {
    private func message(_ stop: StopReason) -> AssistantMessage {
        AssistantMessage(content: [.text(TextContent(text: "x"))], api: "t", provider: "t", model: "m", stopReason: stop, timestamp: 1)
    }

    @Test func terminalEventFinishesIterationAndResolvesResult() async {
        let stream = AssistantMessageEventStream()
        let final = message(.stop)
        await stream.push(.start(partial: message(.pending)))
        await stream.push(.done(reason: .stop, message: final))
        await stream.push(.textDelta(contentIndex: 0, delta: "late", partial: final))   // 终止后的事件被丢弃

        var kinds: [String] = []
        for await event in stream.events {
            switch event {
            case .start: kinds.append("start")
            case .done: kinds.append("done")
            default: kinds.append("other")
            }
        }
        #expect(kinds == ["start", "done"])
        #expect(await stream.result() == final)
    }

    @Test func endWithoutTerminalEventYieldsNilResult() async {
        let stream = AssistantMessageEventStream()
        await stream.end()
        var count = 0
        for await _ in stream.events { count += 1 }
        #expect(count == 0)
        #expect(await stream.result() == nil)
    }

    @Test func cancelInvokesHandlerOnce() async {
        let stream = AssistantMessageEventStream()
        let counter = Counter()
        await stream.setCancellationHandler { counter.increment() }
        await stream.cancel()
        await stream.cancel()
        #expect(counter.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
