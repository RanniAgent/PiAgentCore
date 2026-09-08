// 测试共用的小工具：事件收集、顺序记录、计数、闸门、插话/追问队列。
import Foundation
@testable import PiAgentCore

/// 收集事件的监听器。
actor EventLog {
    private(set) var events: [AgentEvent] = []
    func append(_ e: AgentEvent) { events.append(e) }
    var kinds: [String] {
        events.map { e in
            switch e {
            case .agentStart: return "agent_start"
            case .agentEnd: return "agent_end"
            case .turnStart: return "turn_start"
            case .turnEnd(_, let results): return "turn_end(\(results.count))"
            case .messageStart(let m): return "message_start(\(m.role))"
            case .messageUpdate: return "message_update"
            case .messageEnd(let m): return "message_end(\(m.role))"
            case .toolExecutionStart(let id, _, _): return "tool_start(\(id))"
            case .toolExecutionUpdate(let id, _, _, _): return "tool_update(\(id))"
            case .toolExecutionEnd(let id, _, _, let isError): return "tool_end(\(id),\(isError))"
            }
        }
    }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

actor Queues {
    private var steering: [AgentMessage] = []
    private var followUps: [AgentMessage] = []
    func steer(_ m: AgentMessage) { steering.append(m) }
    func followUp(_ m: AgentMessage) { followUps.append(m) }
    func drainSteering() -> [AgentMessage] { defer { steering = [] }; return steering }
    func drainFollowUps() -> [AgentMessage] { defer { followUps = [] }; return followUps }
    var followUpCount: Int { followUps.count }
}

actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
}
