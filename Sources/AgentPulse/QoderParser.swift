import Foundation
import CoreFoundation

/// Metadata only. Qoder writes several assistant blocks per response; only the
/// final block normally carries request-level usage. Never add block usage twice.
final class QoderParser: SessionParser {
    private(set) var acc: SessionAccumulator = {
        var value = SessionAccumulator()
        value.speedNote = "Credits/s = 实际计费 Credits ÷ 请求耗时（含等待）；请求结束后更新，不代表输出 token 速度。未计费请求按 0 统计，缺失计费字段不计入；未启用未经验证的 token 换算。"
        return value
    }()
    private var indices: [String: Int] = [:]
    private let includeSidechains: Bool

    init(includeSidechains: Bool = false) { self.includeSidechains = includeSidechains }

    func consume(_ object: [String: Any]) {
        if !includeSidechains && object["isSidechain"] as? Bool == true { return }
        if acc.cwd == nil { acc.cwd = J.str(object["cwd"]) }
        if J.str(object["type"]) == "custom-title" {
            acc.title = J.str(object["customTitle"])
            return
        }
        guard let timestamp = J.date(object["timestamp"]) else { return }
        acc.touch(timestamp)
        let message = J.dict(object["message"]) ?? [:]
        switch J.str(object["type"]) {
        case "user":
            if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let toolResult = blocks.contains { J.str($0["type"]) == "tool_result" }
            if !toolResult { acc.turns += 1 }
            acc.boundary(timestamp, toolResult ? .tool : .prompt)
        case "system":
            if J.str(object["subtype"]) == "turn_duration" { acc.endTurn(timestamp) }
        case "assistant":
            guard object["isApiErrorMessage"] as? Bool != true,
                  let usage = J.dict(message["usage"]),
                  let id = J.str(usage["request_id"]) ?? J.str(message["id"]) ?? J.str(object["uuid"]),
                  !id.isEmpty else { return }
            if let model = J.str(message["model"]), model != "<synthetic>" { acc.model = model }
            let existing = indices[id]
            var request: RequestRecord
            if let existing {
                request = acc.requests[existing]
                request.end = max(request.end, timestamp)
            } else {
                let start = acc.lastBoundary.flatMap { candidate -> Date? in
                    guard candidate <= timestamp,
                          acc.requests.last.map({ candidate >= $0.end }) ?? true else { return nil }
                    return candidate
                }
                request = RequestRecord(id: id, model: acc.model, start: min(start ?? timestamp, timestamp),
                                        startKind: acc.lastBoundaryKind, firstOutput: nil, end: timestamp)
                request.hasRequestStart = start != nil
            }
            request.model = J.str(message["model"]) ?? request.model
            request.outputTokens = J.int(usage["output_tokens"])
            request.uncachedInput = J.int(usage["input_tokens"])
            request.cacheRead = J.int(usage["cache_read_input_tokens"])
            request.cacheWrite = J.int(usage["cache_creation_input_tokens"])
            request.contextTokens = request.uncachedInput + request.cacheRead + request.cacheWrite
            request.credits = Self.nonnegative(usage["credits"]) ?? request.credits
            request.originalCredits = Self.nonnegative(usage["original_credits"]) ?? request.originalCredits
            if let flag = usage["billable"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                request.billable = flag.boolValue
            }
            if let ratio = Self.nonnegative(usage["context_usage_ratio"]) {
                acc.reportedContextFraction = min(1, ratio)
            }
            if let existing { acc.requests[existing] = request }
            else { indices[id] = acc.requests.count; acc.requests.append(request) }
            if let stop = J.str(message["stop_reason"]), stop != "tool_use" { acc.endTurn(timestamp) }
        default:
            break
        }
    }

    private static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}
