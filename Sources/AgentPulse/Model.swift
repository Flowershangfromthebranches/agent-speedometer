import Foundation

enum BoundaryKind {
    case prompt
    case tool
}

/// One model request (one "step"). Only metadata — never message content.
struct RequestRecord {
    var id: String
    var model: String?
    /// When the request was (approximately) sent: the user prompt / tool result that preceded it.
    var start: Date
    var startKind: BoundaryKind?
    /// Precise first-output time, when the log records it (Codex `started_at_ms`).
    var firstOutput: Date?
    var end: Date
    var outputTokens: Int = 0
    var uncachedInput: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    /// Tokens occupying the context window for this request (input side).
    var contextTokens: Int = 0

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var ttft: TimeInterval? {
        guard let f = firstOutput else { return nil }
        let t = f.timeIntervalSince(start)
        return t >= 0 ? t : nil
    }
    /// Time spent producing output. Excludes TTFT when it is known.
    var decodeDuration: TimeInterval {
        if let f = firstOutput, f >= start, f <= end { return end.timeIntervalSince(f) }
        return duration
    }
    var totalTokens: Int { outputTokens + uncachedInput + cacheRead + cacheWrite }
}

struct RateLimitWindow {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

/// Snapshot handed to the UI.
struct SessionStats {
    var source: AgentSource
    /// Unique session key (the log file path for file-based tools).
    var path: String
    var cwd: String?
    var title: String?
    var model: String?
    var turns: Int = 0
    var steps: Int = 0
    var lastTPS: Double?
    var recentTPS: Double?
    var sessionTPS: Double?
    /// Output speed of the most recent usable steps, oldest first (for the sparkline).
    var stepTPS: [Double] = []
    var avgTTFT: TimeInterval?
    var ttftAvailable: Bool = false
    var modelTime: TimeInterval = 0
    var toolTime: TimeInterval = 0
    var uncachedInput: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var outputTokens: Int = 0
    var contextTokens: Int = 0
    var contextWindow: Int?
    var contextWindowIsEstimate: Bool = false
    /// Non-nil while a request appears to be in flight.
    var waitingSince: Date?
    var lastActivity: Date?
    var rateLimitPrimary: RateLimitWindow?
    var rateLimitSecondary: RateLimitWindow?
    /// Why speed can't be shown for this tool, if that's the case.
    var speedNote: String?

    var totalTokens: Int { uncachedInput + cacheRead + cacheWrite + outputTokens }
    var cacheHitRate: Double? {
        let denom = uncachedInput + cacheRead + cacheWrite
        return denom > 0 ? Double(cacheRead) / Double(denom) : nil
    }
    var contextFraction: Double? {
        guard let w = contextWindow, w > 0, contextTokens > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(w))
    }
    var projectName: String {
        if let t = title, !t.isEmpty { return t }
        if let c = cwd { return (c as NSString).lastPathComponent }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Accumulates requests and boundaries; parsers feed it, the UI reads `snapshot`.
struct SessionAccumulator {
    var requests: [RequestRecord] = []
    var turns = 0
    var lastBoundary: Date?
    var lastBoundaryKind: BoundaryKind?
    var lastActivity: Date?
    var model: String?
    var cwd: String?
    var title: String?
    var contextWindow: Int?
    var rateLimitPrimary: RateLimitWindow?
    var rateLimitSecondary: RateLimitWindow?
    var speedNote: String?

    mutating func boundary(_ ts: Date, _ kind: BoundaryKind) {
        if lastBoundary.map({ ts >= $0 }) ?? true {
            lastBoundary = ts
            lastBoundaryKind = kind
        }
        touch(ts)
    }

    /// The turn finished, was interrupted or errored: nothing is in flight any more.
    mutating func endTurn(_ ts: Date) {
        lastBoundary = nil
        lastBoundaryKind = nil
        touch(ts)
    }

    mutating func touch(_ ts: Date) {
        lastActivity = max(lastActivity ?? ts, ts)
    }

    /// Start time for a request whose first output appears now.
    func pendingStart(fallback ts: Date) -> (Date, BoundaryKind?) {
        let prevEnd = requests.last?.end
        if let b = lastBoundary, prevEnd.map({ b >= $0 }) ?? true {
            return (b, lastBoundaryKind)
        }
        return (prevEnd ?? ts, nil)
    }

    /// - Parameter estimateContextWindow: guess 200K / 1M when the log doesn't say (Claude Code).
    ///   Otherwise an unknown window stays unknown rather than showing a wrong percentage.
    func snapshot(source: AgentSource, path: String, contextWindowOverride: Int?,
                  estimateContextWindow: Bool = false) -> SessionStats {
        var s = SessionStats(source: source, path: path)
        s.speedNote = speedNote
        s.cwd = cwd
        s.title = title
        s.model = model ?? requests.last?.model
        s.turns = turns
        s.steps = requests.count
        s.lastActivity = lastActivity
        s.rateLimitPrimary = rateLimitPrimary
        s.rateLimitSecondary = rateLimitSecondary

        var outSum = 0, durSum: TimeInterval = 0
        var ttftSum: TimeInterval = 0, ttftN = 0
        var prev: RequestRecord?
        for r in requests {
            s.uncachedInput += r.uncachedInput
            s.cacheRead += r.cacheRead
            s.cacheWrite += r.cacheWrite
            s.outputTokens += r.outputTokens
            s.modelTime += r.duration
            if let t = r.ttft, t < 600 { ttftSum += t; ttftN += 1 }
            if r.startKind == .tool, let p = prev {
                let gap = r.start.timeIntervalSince(p.end)
                if gap > 0 && gap < 3600 { s.toolTime += gap }
            }
            if Self.usableForSpeed(r) {
                outSum += r.outputTokens
                durSum += r.decodeDuration
            }
            prev = r
        }
        if durSum > 0 { s.sessionTPS = Double(outSum) / durSum }
        if ttftN > 0 { s.avgTTFT = ttftSum / Double(ttftN); s.ttftAvailable = true }

        let speedy = requests.filter(Self.usableForSpeed)
        s.stepTPS = speedy.suffix(40).map { Double($0.outputTokens) / $0.decodeDuration }
        if let last = speedy.last { s.lastTPS = Double(last.outputTokens) / last.decodeDuration }
        let recent = speedy.suffix(5)
        let rDur = recent.reduce(0) { $0 + $1.decodeDuration }
        if rDur > 0 { s.recentTPS = Double(recent.reduce(0) { $0 + $1.outputTokens }) / rDur }

        if let last = requests.last { s.contextTokens = last.contextTokens }
        if let w = contextWindow {
            s.contextWindow = w
        } else if let o = contextWindowOverride {
            s.contextWindow = o
        } else if estimateContextWindow {
            // Unknown window: pick the smallest common size that fits what we've seen.
            let maxSeen = requests.map(\.contextTokens).max() ?? 0
            let modelName = (s.model ?? "").lowercased()
            s.contextWindow = (modelName.contains("[1m]") || maxSeen > 200_000) ? 1_000_000 : 200_000
            s.contextWindowIsEstimate = true
        }

        if let b = lastBoundary, requests.last.map({ b > $0.end }) ?? true,
           Date().timeIntervalSince(b) < 15 * 60 {
            s.waitingSince = b
        }
        return s
    }

    /// Ignore tiny / instant requests: their timings are dominated by log granularity.
    static func usableForSpeed(_ r: RequestRecord) -> Bool {
        r.outputTokens >= 20 && r.decodeDuration >= 0.25
    }
}
