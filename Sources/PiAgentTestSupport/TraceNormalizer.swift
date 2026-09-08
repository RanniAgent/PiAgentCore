// 把 AgentEvent 归一化成两端可比的 JSON。规则见计划 B2 顶部；TS 脚本 scripts/trace-export.ts 里有同一套。
import Foundation
import PiAgentCore

public struct TraceNormalizer: Sendable {
    private var idMap: [String: String] = [:]
    private var aborted = false

    public init() {}

    public mutating func markAborted() { aborted = true }

    /// 返回 nil 表示这条事件不进序列（取消后的增量）。
    public mutating func normalize(_ event: AgentEvent) -> JSONValue? {
        switch event {
        case .agentStart: return ["type": "agent_start"]
        case .turnStart: return ["type": "turn_start"]
        case .agentEnd(let messages): return ["type": "agent_end", "messages": .array(messages.map { message($0) })]
        case .turnEnd(let m, let results): return ["type": "turn_end", "message": message(m), "toolResults": .array(results.map { toolResult($0) })]
        case .messageStart(let m): return ["type": "message_start", "message": message(m)]
        case .messageEnd(let m): return ["type": "message_end", "message": message(m)]
        case .messageUpdate(_, let e):
            if aborted { return nil }
            var out: JSONValue = ["type": "message_update"]
            switch e {
            case .start: out = out.merging(["event": "start"])
            case .textStart(let i, _): out = out.merging(["event": "text_start", "contentIndex": .number(Double(i))])
            case .textDelta(let i, let d, _): out = out.merging(["event": "text_delta", "contentIndex": .number(Double(i)), "delta": .string(d)])
            case .textEnd(let i, let c, _): out = out.merging(["event": "text_end", "contentIndex": .number(Double(i)), "content": .string(c)])
            case .thinkingStart(let i, _): out = out.merging(["event": "thinking_start", "contentIndex": .number(Double(i))])
            case .thinkingDelta(let i, let d, _): out = out.merging(["event": "thinking_delta", "contentIndex": .number(Double(i)), "delta": .string(d)])
            case .thinkingEnd(let i, let c, _): out = out.merging(["event": "thinking_end", "contentIndex": .number(Double(i)), "content": .string(c)])
            case .toolcallStart(let i, _): out = out.merging(["event": "toolcall_start", "contentIndex": .number(Double(i))])
            case .toolcallDelta(let i, let d, _): out = out.merging(["event": "toolcall_delta", "contentIndex": .number(Double(i)), "delta": .string(d)])
            case .toolcallEnd(let i, let call, _): out = out.merging(["event": "toolcall_end", "contentIndex": .number(Double(i)), "toolCallId": .string(id(call.id))])
            case .done(let r, _): out = out.merging(["event": "done", "reason": .string(r.rawValue)])
            case .error(let r, _): out = out.merging(["event": "error", "reason": .string(r.rawValue)])
            }
            return out
        case .toolExecutionStart(let callId, let name, let args):
            return ["type": "tool_execution_start", "toolCallId": .string(id(callId)), "toolName": .string(name), "args": args]
        case .toolExecutionUpdate(let callId, _, _, let partial):
            return ["type": "tool_execution_update", "toolCallId": .string(id(callId)), "partial": result(partial)]
        case .toolExecutionEnd(let callId, _, let res, let isError):
            return ["type": "tool_execution_end", "toolCallId": .string(id(callId)), "isError": .bool(isError), "result": result(res)]
        }
    }

    private mutating func id(_ raw: String) -> String {
        if let mapped = idMap[raw] { return mapped }
        let mapped = "tc\(idMap.count + 1)"
        idMap[raw] = mapped
        return mapped
    }

    private mutating func message(_ m: AgentMessage) -> JSONValue {
        switch m {
        case .user(let u):
            switch u.content {
            case .text(let t): return ["role": "user", "content": .string(t)]
            case .blocks(let blocks): return ["role": "user", "content": .array(blocks.map { userBlock($0) })]
            }
        case .assistant(let a):
            var out: [String: JSONValue] = ["role": "assistant", "stopReason": .string(a.stopReason.rawValue)]
            if let error = a.errorMessage { out["errorMessage"] = .string(error) }
            out["content"] = a.stopReason == .aborted ? .string("<aborted>") : .array(a.content.map { assistantBlock($0) })
            return .object(out)
        case .toolResult(let r):
            return toolResult(r)
        case .custom(let c):
            return ["role": "custom", "customType": .string(c.customType), "payload": c.payload]
        }
    }

    private mutating func toolResult(_ r: ToolResultMessage) -> JSONValue {
        var out: [String: JSONValue] = ["role": "toolResult", "toolCallId": .string(id(r.toolCallId)), "toolName": .string(r.toolName), "isError": .bool(r.isError), "content": .array(r.content.map { userBlock($0) })]
        if let details = r.details { out["details"] = details }
        if let added = r.addedToolNames { out["addedToolNames"] = .array(added.map { .string($0) }) }
        return .object(out)
    }

    private func result(_ r: AgentToolResult) -> JSONValue {
        var out: [String: JSONValue] = ["content": .array(r.content.map { userBlock($0) })]
        if let details = r.details { out["details"] = details }
        if let terminate = r.terminate { out["terminate"] = .bool(terminate) }
        return .object(out)
    }

    private mutating func assistantBlock(_ b: AssistantContent) -> JSONValue {
        switch b {
        case .text(let t): return ["type": "text", "text": .string(t.text)]
        case .thinking(let t): return ["type": "thinking", "thinking": .string(t.thinking)]
        case .toolCall(let c): return ["type": "toolCall", "id": .string(id(c.id)), "name": .string(c.name), "arguments": c.arguments]
        }
    }

    private func userBlock(_ b: UserContentBlock) -> JSONValue {
        switch b {
        case .text(let t): return ["type": "text", "text": .string(t.text)]
        case .image(let i): return ["type": "image", "mimeType": .string(i.mimeType)]
        }
    }
}

extension JSONValue {
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let extra) = other else { return other }
        for (k, v) in extra { base[k] = v }
        return .object(base)
    }
}
