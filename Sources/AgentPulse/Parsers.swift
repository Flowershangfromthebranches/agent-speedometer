import Foundation

/// Parses one JSONL line at a time. Implementations read only metadata fields
/// (timestamps, token usage, model, cwd) and never keep message content.
protocol SessionParser: AnyObject {
    var source: AgentSource { get }
    var acc: SessionAccumulator { get }
    func consume(_ obj: [String: Any])
}

// MARK: - Helpers

enum J {
    static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }
    static func str(_ v: Any?) -> String? { v as? String }
    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    /// Fast parser for "2026-10-13T03:00:23.999Z" (UTC). Falls back to ISO8601DateFormatter.
    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let u = Array(s.utf8)
        if u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58 {
            func num(_ a: Int, _ b: Int) -> Int? {
                var r = 0
                for i in a..<b { let c = Int(u[i]) - 48; if c < 0 || c > 9 { return nil }; r = r * 10 + c }
                return r
            }
            if let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
               let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19) {
                var frac = 0.0
                var i = 19
                if i < u.count, u[i] == 46 {
                    i += 1
                    var scale = 0.1
                    while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
                }
                if i < u.count, u[i] == 90 {
                    var t = tm()
                    t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
                    t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(se)
                    return Date(timeIntervalSince1970: Double(timegm(&t)) + frac)
                }
            }
        }
        return isoFallback.date(from: s) ?? isoFallbackNoFrac.date(from: s)
    }
    private static let isoFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoFallbackNoFrac = ISO8601DateFormatter()
}

// MARK: - Claude Code (~/.claude/projects/<project>/<session>.jsonl)
//
// Each content block of an assistant response is a separate entry sharing `message.id`,
// timestamped when the block finished. `message.usage` carries token counts.
// Claude Code does not log the first-token time, so TTFT is unavailable and
// speed is measured end-to-end (from the preceding user/tool_result entry).

final class ClaudeParser: SessionParser {
    let source = AgentSource.claude
    private(set) var acc = SessionAccumulator()

    func consume(_ o: [String: Any]) {
        if let cwd = J.str(o["cwd"]), acc.cwd == nil { acc.cwd = cwd }
        let type = J.str(o["type"])
        if type == "custom-title", let t = J.str(o["customTitle"]) { acc.title = t; return }
        if (o["isSidechain"] as? Bool) == true { return }
        guard let ts = J.date(o["timestamp"]) else { return }

        switch type {
        case "user":
            if (o["isMeta"] as? Bool) == true || (o["isCompactSummary"] as? Bool) == true { return }
            let msg = J.dict(o["message"])
            let blocks = msg?["content"] as? [[String: Any]]
            // Only the first characters are checked, to recognise the interruption marker.
            let firstText = (msg?["content"] as? String) ?? blocks?.first.flatMap { J.str($0["text"]) }
            if firstText?.hasPrefix("[Request interrupted") == true {
                acc.endTurn(ts)
            } else if blocks?.contains(where: { J.str($0["type"]) == "tool_result" }) == true {
                acc.boundary(ts, .tool)
            } else if blocks != nil || firstText != nil {
                acc.turns += 1
                acc.boundary(ts, .prompt)
            }

        case "assistant":
            if (o["isApiErrorMessage"] as? Bool) == true { acc.endTurn(ts); return }
            guard let msg = J.dict(o["message"]) else { return }
            let model = J.str(msg["model"])
            if model == "<synthetic>" { return }
            let id = J.str(msg["id"]) ?? J.str(o["requestId"]) ?? J.str(o["uuid"]) ?? UUID().uuidString
            let u = J.dict(msg["usage"]) ?? [:]
            let input = J.int(u["input_tokens"])
            let cRead = J.int(u["cache_read_input_tokens"])
            let cWrite = J.int(u["cache_creation_input_tokens"])
            let out = J.int(u["output_tokens"])
            acc.touch(ts)
            if let model { acc.model = model }

            var r: RequestRecord
            let isContinuation = acc.requests.last?.id == id
            if isContinuation {
                r = acc.requests.removeLast()
                r.end = max(r.end, ts)
            } else {
                let (start, kind) = acc.pendingStart(fallback: ts)
                r = RequestRecord(id: id, model: model, start: start, startKind: kind, firstOutput: nil, end: ts)
            }
            // Later blocks of the same message carry the same or newer usage.
            r.outputTokens = max(r.outputTokens, out)
            r.uncachedInput = input
            r.cacheWrite = cWrite
            r.cacheRead = cRead
            r.contextTokens = input + cRead + cWrite
            acc.requests.append(r)

        default:
            break
        }
    }
}

// MARK: - Codex (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
//
// `token_usage_record` (or, in older versions, `event_msg/token_count`) closes each
// model response. `item_completed` events for Reasoning / AgentMessage carry
// `started_at_ms`, which gives a real first-output time (TTFT).

final class CodexParser: SessionParser {
    let source = AgentSource.codex
    private(set) var acc = SessionAccumulator()

    private var pendingStart: (Date, BoundaryKind?)?
    private var pendingFirstOutput: Date?
    private var sawUsageRecord = false
    private var lastTokenCountTotal = -1

    func consume(_ o: [String: Any]) {
        guard let ts = J.date(o["timestamp"]) else { return }
        let type = J.str(o["type"])
        let p = J.dict(o["payload"]) ?? [:]

        switch type {
        case "session_meta":
            if let cwd = J.str(p["cwd"]) { acc.cwd = cwd }
        case "turn_context":
            if let m = J.str(p["model"]) { acc.model = m }
            if let cwd = J.str(p["cwd"]) { acc.cwd = cwd }
        case "token_usage_record":
            sawUsageRecord = true
            closeRequest(ts: ts, id: J.str(p["response_id"]), usage: J.dict(p["usage"]))
        case "response_item":
            switch J.str(p["type"]) {
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output", "tool_search_output":
                acc.boundary(ts, .tool)
            case "message":
                if J.str(p["role"]) == "assistant" { output(at: ts, precise: nil) }
            case "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call", "tool_search_call":
                output(at: ts, precise: nil)
            default:
                break
            }
        case "event_msg":
            switch J.str(p["type"]) {
            case "task_complete", "turn_aborted":
                acc.endTurn(ts)
                pendingStart = nil
                pendingFirstOutput = nil
            case "task_started":
                acc.turns += 1
                acc.boundary(ts, .prompt)
                if let w = p["model_context_window"] as? NSNumber { acc.contextWindow = w.intValue }
            case "user_message":
                acc.boundary(ts, .prompt)
            case "item_completed":
                let item = J.dict(p["item"]) ?? [:]
                switch J.str(item["type"]) {
                case "UserMessage":
                    acc.boundary(ts, .prompt)
                case "Reasoning", "AgentMessage":
                    let started = (p["started_at_ms"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                    output(at: ts, precise: started)
                default:
                    break
                }
            case "thread_settings_applied":
                if let m = J.str(J.dict(p["thread_settings"])?["model"]) { acc.model = m }
            case "token_count":
                if let info = J.dict(p["info"]) {
                    if let w = info["model_context_window"] as? NSNumber { acc.contextWindow = w.intValue }
                    if !sawUsageRecord {
                        let total = J.int(J.dict(info["total_token_usage"])?["total_tokens"])
                        if total != lastTokenCountTotal {
                            lastTokenCountTotal = total
                            closeRequest(ts: ts, id: nil, usage: J.dict(info["last_token_usage"]))
                        }
                    }
                }
                if let rl = J.dict(p["rate_limits"]) {
                    acc.rateLimitPrimary = Self.window(rl["primary"]) ?? acc.rateLimitPrimary
                    acc.rateLimitSecondary = Self.window(rl["secondary"]) ?? acc.rateLimitSecondary
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func output(at ts: Date, precise: Date?) {
        acc.touch(ts)
        if pendingStart == nil { pendingStart = acc.pendingStart(fallback: precise ?? ts) }
        if let precise {
            pendingFirstOutput = min(pendingFirstOutput ?? precise, precise)
        }
    }

    private func closeRequest(ts: Date, id: String?, usage: [String: Any]?) {
        guard let u = usage else { return }
        let (start, kind) = pendingStart ?? acc.pendingStart(fallback: ts)
        let input = J.int(u["input_tokens"])          // includes cached
        let cached = J.int(u["cached_input_tokens"])
        let cWrite = J.int(u["cache_write_input_tokens"])
        var r = RequestRecord(id: id ?? UUID().uuidString, model: acc.model, start: start, startKind: kind,
                              firstOutput: pendingFirstOutput, end: ts)
        r.outputTokens = J.int(u["output_tokens"])
        r.cacheRead = cached
        r.cacheWrite = cWrite
        r.uncachedInput = max(0, input - cached - cWrite)
        r.contextTokens = input
        acc.requests.append(r)
        acc.touch(ts)
        pendingStart = nil
        pendingFirstOutput = nil
    }

    private static func window(_ v: Any?) -> RateLimitWindow? {
        guard let d = v as? [String: Any], let used = d["used_percent"] as? NSNumber else { return nil }
        let reset = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitWindow(usedPercent: used.doubleValue, windowMinutes: J.int(d["window_minutes"]), resetsAt: reset)
    }
}

// MARK: - Incremental file tail

/// Reads only bytes appended since the last call. If the file shrinks (rewritten), starts over.
final class SessionTail: @unchecked Sendable { // only touched on the serial parse queue
    let path: String
    let source: AgentSource
    private(set) var parser: SessionParser
    private var offset: UInt64 = 0
    private var remainder = Data()
    private(set) var lastSize: UInt64 = 0

    init(path: String, source: AgentSource) {
        self.path = path
        self.source = source
        self.parser = Self.makeParser(source)
    }

    private static func makeParser(_ s: AgentSource) -> SessionParser {
        switch s {
        case .claude: return ClaudeParser()
        case .codex: return CodexParser()
        }
    }

    /// Returns true if new data was consumed.
    @discardableResult
    func poll() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        if size < offset {
            parser = Self.makeParser(source)
            offset = 0
            remainder = Data()
        }
        lastSize = size
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.readToEnd(), !chunk.isEmpty else { return false }
            offset += UInt64(chunk.count)
            var buf = remainder
            buf.append(chunk)
            var lineStart = buf.startIndex
            while let nl = buf[lineStart...].firstIndex(of: 0x0A) {
                let line = buf[lineStart..<nl]
                lineStart = buf.index(after: nl)
                if line.isEmpty { continue }
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    parser.consume(obj)
                }
            }
            remainder = Data(buf[lineStart...])
            return true
        } catch {
            return false
        }
    }
}
