import Foundation

// `AgentPulse --dump <session.jsonl>...` prints the computed stats without launching the UI.
// `AgentPulse --dump` with no paths uses the most recently active session.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dump") {
    var paths = Array(args[(i + 1)...])
    if paths.isEmpty, let latest = SessionDiscovery.discover().first { paths = [latest.path] }
    for p in paths {
        let tail = SessionTail(path: p, source: SessionDiscovery.source(forPath: p))
        let t0 = Date()
        tail.poll()
        let parseTime = Date().timeIntervalSince(t0)
        let s = tail.parser.acc.snapshot(source: tail.source, path: p, contextWindowOverride: nil)
        print("== \(s.source.displayName)  \(s.projectName)  [\(s.model ?? "?")]")
        print("   file: \(p)  (parsed in \(String(format: "%.2f", parseTime))s)")
        print("   \(s.turns) 轮 \(s.steps) 步 · 最近5步 \(Fmt.tps(s.recentTPS)) · 最近一步 \(Fmt.tps(s.lastTPS)) · 会话 \(Fmt.tps(s.sessionTPS))")
        print("   模型用时 \(Fmt.duration(s.modelTime)) · 工具用时 \(Fmt.duration(s.toolTime)) · TTFT \(s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "n/a")")
        print("   总 \(Fmt.tokens(s.totalTokens)) · 缓存命中 \(Fmt.percent(s.cacheHitRate)) · 未缓存 \(s.uncachedInput) · 写缓存 \(s.cacheWrite) · 读缓存 \(s.cacheRead) · 输出 \(s.outputTokens)")
        print("   上下文 \(Fmt.compactTokens(s.contextTokens)) / \(s.contextWindow.map(Fmt.compactTokens) ?? "?")\(s.contextWindowIsEstimate ? " (估)" : "") = \(Fmt.percent(s.contextFraction, digits: 0))")
        if let w = s.waitingSince { print("   生成中，已等待 \(Fmt.shortElapsed(Date().timeIntervalSince(w)))") }
        print("   最近 8 步:")
        for r in tail.parser.acc.requests.suffix(8) {
            let tps = AgentPulseSpeed.tps(r)
            print(String(format: "     out=%6d  dur=%6.1fs  ttft=%@  tps=%@  ctx=%@",
                         r.outputTokens, r.duration, r.ttft.map { String(format: "%.1fs", $0) } ?? "—",
                         tps.map { String(format: "%.0f", $0) } ?? "—", Fmt.compactTokens(r.contextTokens)))
        }
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
