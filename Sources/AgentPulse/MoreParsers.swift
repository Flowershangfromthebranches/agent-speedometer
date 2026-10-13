import Foundation

// Parsers for other tools' JSONL logs. Like the Claude / Codex parsers they read only
// timestamps, token counts, model names and cwd — never message content.

// MARK: - CodeBuddy / WorkBuddy (projects/<project>/<session>.jsonl)
//
// One line per agent item (message, reasoning, function_call, function_call_result),
// `timestamp` in epoch ms. The item that closes a model response carries
// `providerData.usage` (and `message.usage`).

final class CodeBuddyParser: SessionParser {
    private(set) var acc = SessionAccumulator()

    func consume(_ o: [String: Any]) {
        if acc.cwd == nil, let cwd = J.str(o["cwd"]) { acc.cwd = cwd }
        guard let ts = J.date(o["timestamp"]) else { return }
        let type = J.str(o["type"])

        if type == "function_call_result" {
            acc.boundary(ts, .tool)
            return
        }
        if type == "message", J.str(o["role"]) == "user" {
            acc.turns += 1
            acc.boundary(ts, .prompt)
            return
        }

        let pd = J.dict(o["providerData"])
        let pu = J.dict(pd?["usage"])
        let mu = J.dict(J.dict(o["message"])?["usage"])
        guard let out = (pu?["outputTokens"] ?? mu?["output_tokens"]) as? NSNumber else {
            if type != nil { acc.touch(ts) }
            return
        }
        let input = J.int(pu?["inputTokens"] ?? mu?["input_tokens"])
        let cached = J.int((pu?["inputTokensDetails"] as? [[String: Any]])?.first?["cached_tokens"]
                           ?? mu?["cache_read_input_tokens"])
        if let m = J.str(pd?["model"]) { acc.model = m }

        let (start, kind) = acc.pendingStart(fallback: ts)
        var r = RequestRecord(id: J.str(o["id"]) ?? UUID().uuidString, model: acc.model,
                              start: start, startKind: kind, firstOutput: nil, end: ts)
        r.outputTokens = out.intValue
        r.cacheRead = cached
        r.uncachedInput = max(0, input - cached)
        r.contextTokens = input
        acc.requests.append(r)
        acc.touch(ts)
    }
}

// MARK: - pi-agent family: StepCode, pi (agent/sessions/<cwd>/<session>.jsonl)
//
// `message` entries wrap a chat message. An assistant message's own `timestamp` is when the
// request started; the entry's `timestamp` is when it was written (response finished).

final class PiParser: SessionParser {
    private(set) var acc = SessionAccumulator()

    func consume(_ o: [String: Any]) {
        switch J.str(o["type"]) {
        case "session":
            if let cwd = J.str(o["cwd"]) { acc.cwd = cwd }
        case "model_change":
            if let m = J.str(o["modelId"]) { acc.model = m }
        case "message":
            guard let m = J.dict(o["message"]) else { return }
            let entryTs = J.date(o["timestamp"])
            let msgTs = J.date(m["timestamp"])
            guard let ts = entryTs ?? msgTs else { return }
            switch J.str(m["role"]) {
            case "user":
                acc.turns += 1
                acc.boundary(msgTs ?? ts, .prompt)
            case "toolResult":
                acc.boundary(msgTs ?? ts, .tool)
            case "assistant":
                let u = J.dict(m["usage"]) ?? [:]
                if let model = J.str(m["model"]) { acc.model = model }
                let kind = acc.lastBoundaryKind
                var r = RequestRecord(id: UUID().uuidString, model: acc.model,
                                      start: min(msgTs ?? ts, ts), startKind: kind, firstOutput: nil, end: ts)
                r.outputTokens = J.int(u["output"])
                r.uncachedInput = J.int(u["input"])
                r.cacheRead = J.int(u["cacheRead"])
                r.cacheWrite = J.int(u["cacheWrite"])
                r.contextTokens = r.uncachedInput + r.cacheRead + r.cacheWrite
                acc.requests.append(r)
                let stop = J.str(m["stopReason"])
                if stop == "error" || stop == "aborted" { acc.endTurn(ts) } else { acc.touch(ts) }
            default:
                acc.touch(ts)
            }
        default:
            break
        }
    }
}

// MARK: - ZCode (cli/rollout/model-io-sess_<id>.jsonl)
//
// One `model_io` line per model call with `startedAt`, `completedAt` and `response.usage`.
// `inputTokens` already includes cached tokens.

final class ZCodeParser: SessionParser {
    private(set) var acc = SessionAccumulator()

    func consume(_ o: [String: Any]) {
        guard J.str(o["type"]) == "model_io",
              let start = J.date(o["startedAt"]), let end = J.date(o["completedAt"]) else { return }
        acc.touch(end)
        // Side calls (e.g. `session_title`) are not part of the conversation.
        if let q = J.str(o["querySource"]), q != "main_turn" { return }
        let resp = J.dict(o["response"])
        // Failed calls have no usage; their duration is just a timeout.
        guard let u = J.dict(resp?["usage"]), let out = u["outputTokens"] as? NSNumber else { return }
        let req = J.dict(o["request"])
        if let m = J.str(J.dict(req?["body"])?["model"]) ?? J.str(resp?["modelId"]) { acc.model = m }

        let messages = (req?["messages"] as? [[String: Any]]) ?? (J.dict(req?["body"])?["messages"] as? [[String: Any]])
        let kind: BoundaryKind = J.str(messages?.last?["role"]) == "tool" ? .tool : .prompt
        if kind == .prompt { acc.turns += 1 }

        let input = J.int(u["inputTokens"])
        var r = RequestRecord(id: UUID().uuidString, model: acc.model, start: start, startKind: kind,
                              firstOutput: nil, end: end)
        r.outputTokens = out.intValue
        r.cacheRead = J.int(u["cacheReadTokens"])
        r.cacheWrite = J.int(u["cacheWriteTokens"])
        r.uncachedInput = max(0, input - r.cacheRead - r.cacheWrite)
        r.contextTokens = input
        acc.requests.append(r)
    }
}

// MARK: - Antigravity (brain/<id>/.system_generated/logs/transcript.jsonl)
//
// Steps carry `created_at` (second precision) and, for model responses, token counts.
// There is no completion time, so tokens are shown but speed is not.

final class AntigravityParser: SessionParser {
    private(set) var acc: SessionAccumulator = {
        var a = SessionAccumulator()
        a.speedNote = "Antigravity 的日志只记录每一步的开始时间，没有完成时间，无法计算速度"
        return a
    }()

    func consume(_ o: [String: Any]) {
        guard let ts = J.date(o["created_at"]) else { return }
        acc.touch(ts)
        switch J.str(o["type"]) {
        case "USER_INPUT":
            acc.turns += 1
        case "PLANNER_RESPONSE":
            guard o["output_tokens"] != nil else { return }
            // Zero duration: excluded from speed, still counted for tokens and steps.
            var r = RequestRecord(id: UUID().uuidString, model: nil, start: ts, startKind: nil,
                                  firstOutput: nil, end: ts)
            r.outputTokens = J.int(o["output_tokens"])
            r.uncachedInput = J.int(o["input_tokens"])
            r.cacheRead = J.int(o["cache_read_tokens"])
            r.contextTokens = r.uncachedInput + r.cacheRead
            acc.requests.append(r)
        default:
            break
        }
    }
}
