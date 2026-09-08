// 对应上游：packages/ai/src/utils/event-stream.ts 的 AssistantMessageEventStream。
// 差异：终值可能为空（生产者没发终止事件就结束时），循环负责合成错误消息；多了取消回调，
// 因为 Swift 没有 AbortSignal 可以传给流函数。
import Foundation

public actor AssistantMessageEventStream {
    public nonisolated let events: AsyncStream<AssistantMessageEvent>
    private let continuation: AsyncStream<AssistantMessageEvent>.Continuation
    private var finalMessage: AssistantMessage?
    private var isDone = false
    private var waiters: [CheckedContinuation<AssistantMessage?, Never>] = []
    private var cancellationHandler: (@Sendable () -> Void)?
    private var didCancel = false

    public init() {
        let (stream, continuation) = AsyncStream<AssistantMessageEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    /// 推一条事件。done / error 之后再推的事件一律丢弃，和 pi 一致。
    public func push(_ event: AssistantMessageEvent) {
        guard !isDone else { return }
        continuation.yield(event)
        if event.isTerminal {
            finish(with: event.message)
        }
    }

    /// 生产者主动结束。给了结果就当终值；没给且之前也没有终止事件，则终值为空。
    public func end(_ result: AssistantMessage? = nil) {
        guard !isDone else { return }
        finish(with: result)
    }

    /// 等终值。终止事件的消息，或 end() 给的结果；都没有则为空。
    public func result() async -> AssistantMessage? {
        if isDone { return finalMessage }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        cancellationHandler = handler
    }

    /// 消费方取消时调用；生产者应在回调里取消自己的任务，并以 aborted 的 error 事件收尾。
    public func cancel() {
        guard !didCancel else { return }
        didCancel = true
        cancellationHandler?()
    }

    private func finish(with result: AssistantMessage?) {
        isDone = true
        finalMessage = result
        continuation.finish()
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: result) }
    }
}
