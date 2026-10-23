import Foundation

func printStats(_ s: SessionStats, requests: [RequestRecord]?) {
    print("== \(s.source.displayName)  \(s.projectName)  [\(s.model ?? "?")]")
    if s.usesCredits {
        print("   \(s.turns) 轮 \(s.steps) 步 · 最近5步 \(s.speedText(s.displayRecentSpeed)) · 最近一步 \(s.speedText(s.displayLastSpeed)) · 会话 \(s.speedText(s.displaySessionSpeed))")
        print("   实际 \(Fmt.creditsNumber(s.credits)) Credits · 已知计费 \(s.creditRequests) 次 · 缺失 \(s.missingCreditRequests) 次 · 上下文 \(Fmt.percent(s.contextFraction))")
        for r in (requests ?? []).suffix(5) {
            let rate = r.hasRequestStart && r.duration >= 0.25 ? r.chargedCredits.map { $0 / r.duration } : nil
            print("     credits=\(Fmt.creditsNumber(r.chargedCredits)) billable=\(r.billable.map(String.init) ?? "unknown") dur=\(Fmt.duration(r.hasRequestStart ? r.duration : nil)) rate=\(Fmt.creditsNumber(rate)) Credits/s")
        }
        if let note = s.speedNote { print("   注：\(note)") }
        return
    }
    print("   \(s.turns) 轮 \(s.steps) 步 · 最近5步 \(Fmt.tps(s.recentTPS)) · 最近一步 \(Fmt.tps(s.lastTPS)) · 会话 \(Fmt.tps(s.sessionTPS))")
    print("   模型用时 \(Fmt.duration(s.modelTime)) · 工具用时 \(Fmt.duration(s.toolTime)) · TTFT \(s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "n/a")")
    print("   总 \(Fmt.tokens(s.totalTokens)) · 缓存命中 \(Fmt.percent(s.cacheHitRate)) · 未缓存 \(s.uncachedInput) · 写缓存 \(s.cacheWrite) · 读缓存 \(s.cacheRead) · 输出 \(s.outputTokens)")
    print("   上下文 \(Fmt.compactTokens(s.contextTokens)) / \(s.contextWindow.map(Fmt.compactTokens) ?? "?")\(s.contextWindowIsEstimate ? " (估)" : "") = \(Fmt.percent(s.contextFraction, digits: 0))")
    if let w = s.waitingSince { print("   生成中，已等待 \(Fmt.shortElapsed(Date().timeIntervalSince(w)))") }
    if let n = s.speedNote { print("   注：\(n)") }
    for r in (requests ?? []).suffix(5) {
        let tps = AgentPulseSpeed.tps(r)
        print(String(format: "     out=%6d  dur=%6.1fs  ttft=%@  tps=%@  ctx=%@",
                     r.outputTokens, r.duration, r.ttft.map { String(format: "%.1fs", $0) } ?? "—",
                     tps.map { String(format: "%.0f", $0) } ?? "—", Fmt.compactTokens(r.contextTokens)))
    }
}

let args = CommandLine.arguments

// `AgentPulse --tools` lists the agent tools found on this Mac and how many sessions each has.
if args.contains("--tools") {
    for t in ToolScanner.scan() {
        let n = t.supported ? "\(SessionDiscovery.sessions(for: t.spec, since: nil, limit: 100_000).count) 个会话" : (t.spec.note ?? "")
        print(String(format: "%@ %-20@ %-14@ %@", t.supported ? "✓" : "·", t.spec.name as NSString,
                     t.installKinds as NSString, n as NSString))
    }
    exit(0)
}

// `AgentPulse --dump-tool <id> [n]` prints stats for the n most recent sessions of a tool.
// `AgentPulse --dump <session.jsonl>...` prints stats for specific log files.
if let i = args.firstIndex(of: "--dump-tool"), i + 1 < args.count, let spec = ToolRegistry.spec(args[i + 1]) {
    let n = i + 2 < args.count ? Int(args[i + 2]) ?? 3 : 3
    for ref in SessionDiscovery.sessions(for: spec, since: nil, limit: n) {
        let t0 = Date()
        guard let reader = Readers.make(ref) else { continue }
        let s = reader.refresh(contextWindowOverride: nil)
        printStats(s, requests: (reader as? JSONLReader)?.parser.acc.requests)
        print("   \(ref.isSubagent ? "子代理 · " : "")\(Fmt.relative(ref.modified)) · 解析 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    }
    exit(0)
}
if let i = args.firstIndex(of: "--dump") {
    var paths = Array(args[(i + 1)...])
    if paths.isEmpty, let latest = Monitor.latestForDump() { paths = [latest] }
    for p in paths {
        guard let source = ToolRegistry.source(forPath: p) else { print("不认识的日志：\(p)"); continue }
        let ref = SessionRef(path: p, source: source, locator: .file(p), modified: Date())
        guard let reader = Readers.make(ref) else { continue }
        printStats(reader.refresh(contextWindowOverride: nil), requests: (reader as? JSONLReader)?.parser.acc.requests)
    }
    exit(0)
}

// `AgentPulse --usage [7|30|90|all]` prints token totals from local logs (debugging aid).
if let i = args.firstIndex(of: "--usage") {
    let arg = i + 1 < args.count ? args[i + 1].lowercased() : "30"
    let days = Int(arg) ?? 30
    let range: UsageRange = arg == "all" ? .all : (days <= 7 ? .week : (days <= 30 ? .month : .quarter))
    let scanner = TokenUsageScanner()
    let token = UsageScanToken()
    let started = Date()
    let tool = args.firstIndex(of: "--tool").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let events = scanner.scan(since: range.startDate(), token: token, sourceID: tool) { done, total, name in
        FileHandle.standardError.write(Data("\r\(name) \(done)/\(total)".utf8))
    }
    FileHandle.standardError.write(Data("\r".utf8))
    let summary = UsageAggregation.summary(events: events, range: range, tool: tool)
    print("== 用量统计 · \(range.title) · \(summary.sessionCount) 个会话 · \(summary.totals.requests) 次请求 · 用时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    if summary.totals.total > 0 || !summary.totals.hasCreditData {
        print("   总 \(Fmt.tokens(summary.totals.total)) · 输出 \(Fmt.tokens(summary.totals.output)) · 输入 \(Fmt.tokens(summary.totals.input)) · 缓存命中 \(Fmt.percent(summary.totals.cacheHitRate))")
        print("   估算费用 \(Fmt.usd(summary.cost.usd)) · 已计价 \(Fmt.tokens(summary.cost.pricedTokens)) · 未匹配价格 \(Fmt.tokens(summary.cost.unpricedTokens))")
    } else { print("   Token 估算未启用：没有经过验证的换算规则") }
    for t in summary.tools {
        if t.totals.hasCreditData {
            print("   \(t.source.displayName): 实际 \(Fmt.creditsNumber(t.totals.credits)) Credits · \(t.totals.creditRequests) 次有计费记录 · \(t.totals.missingCreditRequests) 次缺失 · 平均 \(Fmt.creditsNumber(t.totals.creditRate)) Credits/s")
            if t.totals.total == 0 { continue }
        }
        print("   \(t.source.displayName): 总 \(Fmt.compactTokens(t.totals.total)) · 输出 \(Fmt.compactTokens(t.totals.output)) · 未缓存 \(Fmt.compactTokens(t.totals.uncachedInput)) · 读缓存 \(Fmt.compactTokens(t.totals.cacheRead)) · 写缓存 \(Fmt.compactTokens(t.totals.cacheWrite)) · \(t.totals.requests) 次请求 · \(t.sessionCount) 个会话 · \(Fmt.usd(t.cost.usd))")
    }
    for m in summary.models.prefix(12) {
        print("   [模型] \(m.displayName) (\(m.model ?? "unknown")): \(Fmt.compactTokens(m.totals.total)) tok · \(m.cost.unpricedTokens > 0 ? "价格未知" : Fmt.usd(m.cost.usd))")
    }
    for m in summary.models where m.cost.unpricedTokens > 0 {
        print("   [未定价] \(m.displayName) (\(m.model ?? "unknown")): \(Fmt.compactTokens(m.totals.total)) tok")
    }
    for b in summary.buckets.suffix(14) {
        if summary.totals.total == 0 && summary.totals.hasCreditData {
            if summary.tools.count == 1 && b.totals.hasCreditData {
                print("   \(b.tooltipTitle): \(Fmt.creditsNumber(b.totals.credits)) Credits · \(b.totals.creditRequests) 次有计费记录 · \(b.totals.missingCreditRequests) 次缺失")
            }
            continue
        }
        print("   \(b.tooltipTitle): \(Fmt.compactTokens(b.totals.total)) tok · 输出 \(Fmt.compactTokens(b.totals.output)) · 请求 \(b.totals.requests)")
    }
    exit(0)
}

// `AgentPulse --render <dir> [--demo]` writes PNG previews of the UI; `--demo` uses made-up sessions.
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1])
    MainActor.assumeIsolated { PreviewRenderer.render(to: dir, demo: args.contains("--demo")) }
    exit(0)
}

enum AgentPulseSpeed {
    static func tps(_ r: RequestRecord) -> Double? {
        SessionAccumulator.usableForSpeed(r) ? Double(r.outputTokens) / r.decodeDuration : nil
    }
}

AgentPulseApp.main()
