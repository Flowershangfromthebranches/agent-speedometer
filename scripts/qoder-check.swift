import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func close(_ value: Double?, _ expected: Double) -> Bool {
    value.map { abs($0 - expected) < 0.0000001 } ?? false
}
func consume(_ json: String, into parser: QoderParser) {
    parser.consume(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
}
let parser = QoderParser()
consume(#"{"type":"user","timestamp":1000,"message":{"content":[{"type":"text"}]}}"#, into: parser)
let billable = #"{"type":"assistant","timestamp":1010,"message":{"id":"a","model":"dfmodel","stop_reason":"tool_use","usage":{"request_id":"r1","credits":2,"original_credits":4,"billable":true,"context_usage_ratio":0.4}}}"#
consume(billable, into: parser)
consume(billable, into: parser) // duplicate assistant block
consume(#"{"type":"user","timestamp":1015,"message":{"content":[{"type":"tool_result"}]}}"#, into: parser)
consume(#"{"type":"assistant","timestamp":1045,"message":{"id":"b","model":"dfmodel","stop_reason":"end_turn","usage":{"request_id":"r2","credits":9,"original_credits":10,"billable":false}}}"#, into: parser)
consume(#"{"type":"user","timestamp":1050,"message":{"content":[{"type":"text"}]}}"#, into: parser)
consume(#"{"type":"assistant","timestamp":1060,"message":{"id":"c","usage":{"request_id":"r3","credits":8}}}"#, into: parser)
let stats = parser.acc.snapshot(source: AgentSource(id: "qoder-cn"), path: "test", contextWindowOverride: nil)
check(stats.steps == 3 && stats.turns == 2, "duplicate blocks and tool results must not inflate counts")
check(close(stats.credits, 2) && stats.creditRequests == 2 && stats.missingCreditRequests == 1, "billable and missing fields")
check(close(stats.lastCreditRate, 0), "non-billable request has zero actual rate")
check(close(stats.sessionCreditRate, 2.0 / 40.0), "weighted rate must exclude tool time and missing metering")
check(close(stats.recentCreditRate, 2.0 / 40.0), "recent rate")
check(stats.creditStepSpeeds.map(\.step) == [1, 2], "chart and request metering align")
check(close(stats.creditStepSpeeds[0].rate, 0.2), "2 Credits / 10 seconds")
check(close(stats.contextFraction, 0.4), "reported context works without token counts")
check(stats.totalTokens == 0 && stats.speedUnit == "Credits/s", "Credits must not become token counts")

let orphan = QoderParser()
consume(billable, into: orphan)
let orphanStats = orphan.acc.snapshot(source: AgentSource(id: "qoder-cn"), path: "orphan", contextWindowOverride: nil)
check(close(orphanStats.credits, 2) && orphanStats.sessionCreditRate == nil, "missing start still counts usage but cannot produce speed")

var totals = TokenTotals()
for request in parser.acc.requests { totals.add(request) }
check(close(totals.credits, 2) && close(totals.creditRate, 0.05), "historical and live metering agree")
let now = Date()
let day = Calendar.current.startOfDay(for: now)
let events = [
    UsageEvent(sourceID: "qoder-cn", sessionKey: "cn", day: day, model: "dfmodel", totals: totals),
    UsageEvent(sourceID: "qoder", sessionKey: "global", day: day, model: "dfmodel", totals: totals)
]
let summary = UsageAggregation.summary(events: events, range: .all, tool: nil, now: now)
check(summary.creditGroups.count == 2 && summary.models.isEmpty, "editions stay separate; Credits-only data has no token price")
check(summary.creditGroups.allSatisfy { close($0.totals.credits, 2) }, "no cross-edition credit sum")
let filtered = UsageAggregation.summary(events: events, range: .all, tool: "qoder-cn", now: now)
check(filtered.creditGroups.count == 1 && close(filtered.buckets.last?.totals.credits, 2), "tool and date aggregation")

var tokenOnly = SessionAccumulator()
var request = RequestRecord(id: "token", start: now, firstOutput: now.addingTimeInterval(2), end: now.addingTimeInterval(12))
request.outputTokens = 200
tokenOnly.requests = [request]
let tokenStats = tokenOnly.snapshot(source: .codex, path: "codex", contextWindowOverride: nil)
check(close(tokenStats.sessionTPS, 20) && tokenStats.speedUnit == "tok/s", "existing token speed remains unchanged")
print("PASS: request dedupe, billable=false, missing fields/start, weighted Credits/s, tool time, context, date/model/edition aggregation, token speed regression")
