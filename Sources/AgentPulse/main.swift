import Foundation

func printStats(_ s: SessionStats, requests: [RequestRecord]?) {
    print("== \(s.source.displayName)  \(s.projectName)  [\(s.model ?? "?")]")
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
