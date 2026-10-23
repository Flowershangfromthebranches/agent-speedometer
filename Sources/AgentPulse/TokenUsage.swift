import Foundation
import Combine

// Token usage statistics: how many tokens each agent tool spent, per day.
// Everything here reads the same local logs the rest of the app reads — timestamps and
// token counts only, never message content.

enum UsageRange: String, CaseIterable, Identifiable {
    case week, month, quarter, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .quarter: return "近 90 天"
        case .all: return "全部"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }
}

struct TokenTotals: Equatable {
    var output = 0
    var uncachedInput = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Subset of `cacheWrite` written with a 1-hour TTL, billed at 2× input.
    var cacheWrite1h = 0
    var requests = 0
    var credits: Double?
    var creditRequests = 0
    var missingCreditRequests = 0
    var timedCredits = 0.0
    var creditDuration: TimeInterval = 0

    var creditRate: Double? { creditDuration > 0 ? timedCredits / creditDuration : nil }
    var hasCreditData: Bool { creditRequests > 0 || missingCreditRequests > 0 }

    var total: Int { output + uncachedInput + cacheRead + cacheWrite }
    var input: Int { uncachedInput + cacheRead + cacheWrite }
    var cacheHitRate: Double? {
        let denom = input
        return denom > 0 ? Double(cacheRead) / Double(denom) : nil
    }

    mutating func add(_ other: TokenTotals) {
        output += other.output
        uncachedInput += other.uncachedInput
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        cacheWrite1h += other.cacheWrite1h
        requests += other.requests
        if let amount = other.credits { credits = (credits ?? 0) + amount }
        creditRequests += other.creditRequests
        missingCreditRequests += other.missingCreditRequests
        timedCredits += other.timedCredits
        creditDuration += other.creditDuration
    }

    mutating func add(_ r: RequestRecord) {
        output += max(0, r.outputTokens)
        uncachedInput += max(0, r.uncachedInput)
        cacheRead += max(0, r.cacheRead)
        cacheWrite += max(0, r.cacheWrite)
        cacheWrite1h += max(0, min(r.cacheWrite1h, r.cacheWrite))
        requests += 1
        if let amount = r.chargedCredits {
            credits = (credits ?? 0) + amount
            creditRequests += 1
            if r.hasRequestStart && r.duration >= 0.25 {
                timedCredits += amount
                creditDuration += r.duration
            }
        }
    }
}

/// One session's usage for one model on one calendar day. Aggregated so the
/// in-memory event list stays small even for thousands of requests.
struct UsageEvent: Identifiable {
    let sourceID: String
    let sessionKey: String
    let day: Date
    let model: String?
    var totals: TokenTotals

    var id: String {
        "\(sourceID)|\(sessionKey)|\(model ?? "")|\(day.timeIntervalSince1970)"
    }
}

struct UsageModel: Identifiable {
    let model: String?
    let displayName: String
    let totals: TokenTotals
    let cost: CostEstimate
    var id: String { model ?? "~unknown" }
}

struct UsageTool: Identifiable {
    let source: AgentSource
    let totals: TokenTotals
    let sessionCount: Int
    let cost: CostEstimate
    var id: String { source.id }
}

struct UsageDayBucket: Identifiable {
    let start: Date
    let axisLabel: String
    let tooltipTitle: String
    let totals: TokenTotals
    var id: Date { start }
}

struct UsageSummary {
    let totals: TokenTotals
    let tools: [UsageTool]
    let models: [UsageModel]
    let cost: CostEstimate
    let buckets: [UsageDayBucket]
    let granularityNote: String
    let sessionCount: Int
    let periodDays: Int
    var creditGroups: [CreditUsageGroup] = []
}

struct CreditUsageGroup: Identifiable {
    let source: AgentSource
    let model: String
    let totals: TokenTotals
    var id: String { "\(source.id)|\(model)" }
}

// MARK: - Aggregation

enum UsageAggregation {
    static func summary(events: [UsageEvent], range: UsageRange, tool: String?,
                        now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let today = calendar.startOfDay(for: now)
        let lower = range.startDate(now: now, calendar: calendar)
        let filtered = events.filter { e in
            guard tool == nil || e.sourceID == tool else { return false }
            guard e.day <= today else { return false }
            if let lower, e.day < lower { return false }
            return true
        }

        var totals = TokenTotals()
        var toolTotals: [String: TokenTotals] = [:]
        var toolSessions: [String: Set<String>] = [:]
        var modelTotals: [String: TokenTotals] = [:]
        var toolModelTotals: [String: [String: TokenTotals]] = [:]
        var sessions = Set<String>()
        var canonicalCache: [String: String] = [:]
        func canonical(_ model: String?) -> String {
            guard let model, !model.isEmpty else { return "" }
            if let cached = canonicalCache[model] { return cached }
            let key = ModelPricingTable.canonicalKey(for: model) ?? model
            canonicalCache[model] = key
            return key
        }
        for e in filtered {
            let modelKey = canonical(e.model)
            totals.add(e.totals)
            toolTotals[e.sourceID, default: TokenTotals()].add(e.totals)
            toolSessions[e.sourceID, default: []].insert(e.sessionKey)
            modelTotals[modelKey, default: TokenTotals()].add(e.totals)
            toolModelTotals[e.sourceID, default: [:]][modelKey, default: TokenTotals()].add(e.totals)
            sessions.insert(e.sessionKey)
        }

        func cost(for modelKey: String, _ t: TokenTotals) -> CostEstimate {
            ModelPricingTable.estimate(totals: t, model: modelKey.isEmpty ? nil : modelKey)
        }

        var totalCost = CostEstimate()
        var models: [UsageModel] = []
        for (key, t) in modelTotals {
            guard t.total > 0 else { continue }
            let estimate = cost(for: key, t)
            totalCost.add(estimate)
            models.append(UsageModel(model: key.isEmpty ? nil : key,
                                     displayName: ModelPricingTable.displayName(for: key.isEmpty ? nil : key),
                                     totals: t, cost: estimate))
        }
        models.sort {
            if $0.cost.usd != $1.cost.usd { return $0.cost.usd > $1.cost.usd }
            if $0.totals.total != $1.totals.total { return $0.totals.total > $1.totals.total }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        let tools = toolTotals.map { id, t in
            var toolCost = CostEstimate()
            for (model, mt) in toolModelTotals[id] ?? [:] {
                toolCost.add(cost(for: model, mt))
            }
            return UsageTool(source: AgentSource(id: id), totals: t,
                             sessionCount: toolSessions[id]?.count ?? 0,
                             cost: toolCost)
        }
        .sorted {
            if $0.totals.total != $1.totals.total { return $0.totals.total > $1.totals.total }
            return $0.source.displayName.localizedCaseInsensitiveCompare($1.source.displayName) == .orderedAscending
        }

        let earliest = filtered.map(\.day).min()
        let start = lower ?? earliest ?? today
        let periodDays = max(1, (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
        let (buckets, note) = buckets(for: filtered, start: start, end: today, calendar: calendar)

        let creditGroups = toolModelTotals.flatMap { sourceID, models in
            models.compactMap { model, totals -> CreditUsageGroup? in
                guard totals.hasCreditData else { return nil }
                return CreditUsageGroup(source: AgentSource(id: sourceID), model: model, totals: totals)
            }
        }.sorted {
            if $0.source.id != $1.source.id { return $0.source.id < $1.source.id }
            if $0.totals.credits != $1.totals.credits { return ($0.totals.credits ?? -1) > ($1.totals.credits ?? -1) }
            return $0.id < $1.id
        }

        return UsageSummary(totals: totals, tools: tools, models: models, cost: totalCost,
                            buckets: buckets, granularityNote: note, sessionCount: sessions.count,
                            periodDays: periodDays, creditGroups: creditGroups)
    }

    private enum Granularity { case day, week, month }

    private static func buckets(for events: [UsageEvent], start: Date, end: Date,
                                calendar: Calendar) -> ([UsageDayBucket], String) {
        let span = max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
        let granularity: Granularity = span <= 92 ? .day : (span <= 731 ? .week : .month)

        switch granularity {
        case .day:
            var byDay: [Date: TokenTotals] = [:]
            for e in events { byDay[e.day, default: TokenTotals()].add(e.totals) }
            var out: [UsageDayBucket] = []
            for i in 0...span {
                guard let d = calendar.date(byAdding: .day, value: i, to: start) else { continue }
                out.append(UsageDayBucket(start: d,
                                          axisLabel: monthDay(d, calendar: calendar),
                                          tooltipTitle: monthDayCN(d, calendar: calendar) + " · " + weekday(d, calendar: calendar),
                                          totals: byDay[d] ?? TokenTotals()))
            }
            return (out, "按天")

        case .week:
            var byWeek: [Date: TokenTotals] = [:]
            for e in events {
                let w = weekStart(e.day, calendar: calendar)
                byWeek[w, default: TokenTotals()].add(e.totals)
            }
            var out: [UsageDayBucket] = []
            var cursor = weekStart(start, calendar: calendar)
            let last = weekStart(end, calendar: calendar)
            while cursor <= last {
                let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) ?? cursor
                let finish = min(calendar.date(byAdding: .day, value: -1, to: next) ?? next, end)
                let title = calendar.isDate(cursor, inSameDayAs: finish)
                    ? monthDayCN(cursor, calendar: calendar)
                    : monthDayCN(cursor, calendar: calendar) + " – " + monthDayCN(finish, calendar: calendar)
                out.append(UsageDayBucket(start: cursor,
                                          axisLabel: monthDay(cursor, calendar: calendar),
                                          tooltipTitle: title,
                                          totals: byWeek[cursor] ?? TokenTotals()))
                cursor = next
            }
            return (out, "按周")

        case .month:
            var byMonth: [Date: TokenTotals] = [:]
            for e in events {
                let m = monthStart(e.day, calendar: calendar)
                byMonth[m, default: TokenTotals()].add(e.totals)
            }
            var out: [UsageDayBucket] = []
            var cursor = monthStart(start, calendar: calendar)
            let last = monthStart(end, calendar: calendar)
            while cursor <= last {
                let next = calendar.date(byAdding: .month, value: 1, to: cursor) ?? cursor
                out.append(UsageDayBucket(start: cursor,
                                          axisLabel: yearMonth(cursor, calendar: calendar),
                                          tooltipTitle: yearMonthCN(cursor, calendar: calendar),
                                          totals: byMonth[cursor] ?? TokenTotals()))
                cursor = next
            }
            return (out, "按月")
        }
    }

    private static func weekStart(_ d: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? calendar.startOfDay(for: d)
    }

    private static func monthStart(_ d: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: d)?.start ?? calendar.startOfDay(for: d)
    }

    private static func monthDay(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    private static func monthDayCN(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    private static func yearMonth(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: d)
        return "\(c.year ?? 0)/\(c.month ?? 0)"
    }

    private static func yearMonthCN(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: d)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    private static func weekday(_ d: Date, calendar: Calendar) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let i = calendar.component(.weekday, from: d) - 1
        return names[max(0, min(names.count - 1, i))]
    }
}

// MARK: - Scanner

final class UsageScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Reads every supported tool's logs and turns each model request into a per-day
/// `UsageEvent`. File scans are cached by (mtime, size); unchanged logs are free.
final class TokenUsageScanner: @unchecked Sendable {
    private struct CachedFile {
        let stamp: String
        let events: [UsageEvent]
    }

    /// One deduplicated Claude API call. Claude Code writes a separate JSONL entry
    /// per content block and resumed/forked sessions copy history into new files,
    /// so the same message id can appear many times.
    private struct ClaudeUsage {
        let sourceID: String
        let sessionKey: String
        let timestamp: Date
        let model: String?
        let stopReason: String?
        let output: Int
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cacheWrite1h: Int
    }

    /// One Codex response. `input` includes cache reads/writes.
    private struct CodexUsage {
        let timestamp: Date
        let model: String?
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let signature: CodexSignature
    }

    /// Forked Codex sessions replay the parent's token events, often with new
    /// timestamps but identical counters. This tuple is the replay fingerprint.
    private struct CodexSignature: Hashable {
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int
    }

    private struct CodexFileUsage {
        let sessionID: String
        let parentID: String?
        let events: [CodexUsage]
    }

    private struct CachedCodexFile {
        let stamp: String
        let usage: CodexFileUsage?
    }

    private struct CodexEventKey: Hashable {
        let timestamp: Date
        let signature: CodexSignature
    }

    /// Grok Build logs one `turn_completed` event per user prompt, with the
    /// turn's aggregate usage. Input includes cached reads.
    private struct GrokUsage {
        let timestamp: Date
        let sessionKey: String
        let model: String?
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
    }

    private struct CachedGrokFile {
        let stamp: String
        let events: [GrokUsage]
    }

    private var fileCache: [String: CachedFile] = [:]
    private var dbCache: [String: CachedFile] = [:]
    private var claudeCache: [String: (stamp: String, entries: [String: ClaudeUsage])] = [:]
    private var codexCache: [String: CachedCodexFile] = [:]
    private var grokCache: [String: CachedGrokFile] = [:]
    private var qoderCache: [String: (stamp: String, requests: [RequestRecord])] = [:]
    private let cacheLock = NSLock()

    private let calendar: Calendar
    private let assistantMarker = Data("\"assistant\"".utf8)
    private let usageMarker = Data("\"usage\"".utf8)

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func scan(since: Date?, token: UsageScanToken, sourceID: String? = nil,
              progress: @escaping (Int, Int, String) -> Void) -> [UsageEvent] {
        let specs = ToolRegistry.all.filter { $0.format != nil && (sourceID == nil || $0.id == sourceID) }
        let fileSpecs = specs.filter { $0.format != .opencodeDB }
        let dbSpecs = specs.filter { $0.format == .opencodeDB }

        var jobs: [(spec: AgentToolSpec, refs: [SessionRef])] = []
        var codexRefs: [SessionRef] = []
        for spec in fileSpecs {
            let refs: [SessionRef]
            if spec.format == .codex {
                codexRefs = SessionDiscovery.codexUsageSessions(since: since)
                continue
            } else {
                refs = SessionDiscovery.sessions(for: spec, since: since, limit: 5000)
                    .filter { if case .file = $0.locator { return true } else { return false } }
            }
            if !refs.isEmpty { jobs.append((spec, refs)) }
        }
        let grokSpec = sourceID == nil || sourceID == "grok" ? ToolRegistry.spec("grok") : nil
        let grokRefs = grokSpec == nil ? [] : grokUsageFiles(since: since)
        let dbJobCount = dbSpecs.reduce(0) { $0 + $1.sessionRoots.count }
        let total = jobs.reduce(0) { $0 + $1.refs.count } + codexRefs.count + grokRefs.count + dbJobCount
        var done = 0
        var out: [UsageEvent] = []
        out.reserveCapacity(1024)
        var claudeEntries: [String: ClaudeUsage] = [:]
        var claudeSources = Set<String>()
        // Copies in resumed/forked Qoder logs retain request ids. Count each once
        // within its edition; international and CN Credits are separate units.
        var qoderRequests: [String: (ref: SessionRef, request: RequestRecord)] = [:]

        for job in jobs {
            for ref in job.refs {
                if token.isCancelled { return [] }
                if job.spec.format == .qoder {
                    for request in scanQoderFile(ref) {
                        let key = "\(job.spec.id)|\(request.id)"
                        if let previous = qoderRequests[key] {
                            if previous.request.chargedCredits == nil && request.chargedCredits != nil {
                                qoderRequests[key] = (ref, request)
                            }
                        } else { qoderRequests[key] = (ref, request) }
                    }
                } else if job.spec.format == .claudeCode {
                    claudeSources.insert(job.spec.id)
                    for (key, entry) in scanClaudeFile(ref, sourceID: job.spec.id) {
                        let dedupe = "\(entry.sourceID)|\(key)"
                        if let existing = claudeEntries[dedupe] {
                            if Self.prefer(entry, over: existing) { claudeEntries[dedupe] = entry }
                        } else {
                            claudeEntries[dedupe] = entry
                        }
                    }
                } else {
                    out.append(contentsOf: scanFile(ref, spec: job.spec))
                }
                done += 1
                progress(done, total, job.spec.name)
            }
        }

        for sourceID in claudeSources {
            out.append(contentsOf: claudeEvents(claudeEntries, sourceID: sourceID))
        }
        for entries in Dictionary(grouping: qoderRequests.values, by: { $0.ref.path }).values {
            guard let entry = entries.first else { continue }
            out.append(contentsOf: aggregate(entries.map(\.request), sourceID: entry.ref.source.id, sessionKey: entry.ref.path))
        }

        if !codexRefs.isEmpty {
            let files = scanCodexFiles(codexRefs, token: token) { completed in
                progress(done + completed, total, "Codex")
            }
            done += codexRefs.count
            if token.isCancelled { return [] }
            if !files.isEmpty {
                out.append(contentsOf: codexEvents(files,
                                                   index: SessionDiscovery.codexSessionIndex(),
                                                   sourceID: "codex"))
            }
        }

        for spec in dbSpecs {
            for root in spec.sessionRoots {
                if token.isCancelled { return [] }
                let path = SessionDiscovery.home.appendingPathComponent(root).path
                out.append(contentsOf: scanOpencode(path, sourceID: spec.id))
                done += 1
                progress(done, total, spec.name)
            }
        }

        if let grokSpec {
            var grokEventsOut: [GrokUsage] = []
            for (i, ref) in grokRefs.enumerated() {
                if token.isCancelled { return [] }
                grokEventsOut.append(contentsOf: scanGrokFile(ref))
                done += 1
                if i % 10 == 0 || i == grokRefs.count - 1 {
                    progress(done, total, grokSpec.name)
                }
            }
            out.append(contentsOf: aggregateGrok(grokEventsOut))
        }
        return out
    }

    /// Codex archives can contain hundreds of zstd rollouts. Process a bounded
    /// number in parallel so first-run scans don't serialize hundreds of `zstd`
    /// subprocesses. Results are collected by index to keep the order stable.
    private func scanCodexFiles(_ refs: [SessionRef], token: UsageScanToken,
                                progress: (Int) -> Void) -> [CodexFileUsage] {
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 1), refs.count)
        var results = [CodexFileUsage?](repeating: nil, count: refs.count)
        let lock = NSLock()
        var next = 0
        var completed = 0

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                lock.lock()
                if next >= refs.count || token.isCancelled {
                    lock.unlock()
                    return
                }
                let index = next
                next += 1
                lock.unlock()

                let parsed = scanCodexFile(refs[index])

                lock.lock()
                results[index] = parsed
                completed += 1
                let count = completed
                lock.unlock()
                if count % 8 == 0 || count == refs.count { progress(count) }
            }
        }
        return results.compactMap { $0 }
    }

    // MARK: Files

    private func scanFile(_ ref: SessionRef, spec: AgentToolSpec) -> [UsageEvent] {
        guard let format = spec.format, case .file(let path) = ref.locator else { return [] }
        let stamp = SessionDiscovery.fileStat(path)
            .map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "missing"
        let key = "\(spec.id)|\(path)"
        if let cached = fileCache[key], cached.stamp == stamp { return cached.events }

        let events: [UsageEvent]
        switch format {
        case .deepseekHarness:
            events = scanDeepSeek(path: path, ref: ref, sourceID: spec.id)
        case .claudeCode:
            events = []
        case .codex:
            events = scanLines(path: path, sourceID: spec.id,
                               makeParser: { CodexParser() },
                               markers: [Data("token_usage_record".utf8), Data("token_count".utf8),
                                         Data("turn_context".utf8), Data("thread_settings_applied".utf8)],
                               requireAll: false)
        case .codebuddy:
            events = scanLines(path: path, sourceID: spec.id,
                               makeParser: { CodeBuddyParser() },
                               markers: [usageMarker], requireAll: false)
        case .pi:
            events = scanLines(path: path, sourceID: spec.id,
                               makeParser: { PiParser() },
                               markers: [usageMarker], requireAll: false)
        case .zcode:
            events = scanLines(path: path, sourceID: spec.id,
                               makeParser: { ZCodeParser() },
                               markers: [Data("model_io".utf8)], requireAll: false)
        case .antigravity:
            events = scanLines(path: path, sourceID: spec.id,
                               makeParser: { AntigravityParser() },
                               markers: [Data("output_tokens".utf8)], requireAll: false)
        case .opencodeDB, .qoder:
            events = []
        }

        fileCache[key] = CachedFile(stamp: stamp, events: events)
        return events
    }

    private func scanQoderFile(_ ref: SessionRef) -> [RequestRecord] {
        let stamp = SessionDiscovery.fileStat(ref.path).map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "missing"
        if let cached = qoderCache[ref.path], cached.stamp == stamp { return cached.requests }
        let parser = QoderParser(includeSidechains: true)
        UsageLineStream.forEachLine(path: ref.path) { line in
            autoreleasepool {
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    parser.consume(object)
                }
            }
        }
        let requests = parser.acc.requests
        qoderCache[ref.path] = (stamp, requests)
        return requests
    }

    // MARK: Claude Code (global message-id dedupe)

    /// Parses one Claude JSONL file into a message-id map. The caller merges the
    /// maps of all files: resumed sessions copy history, so a per-file dedupe alone
    /// inflates totals (16% on this machine). Same rule as CC-Switch: prefer the
    /// entry with `stop_reason`, otherwise the one with more output tokens.
    private func scanClaudeFile(_ ref: SessionRef, sourceID: String) -> [String: ClaudeUsage] {
        guard case .file(let path) = ref.locator else { return [:] }
        let stamp = SessionDiscovery.fileStat(path)
            .map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "missing"
        let key = "\(sourceID)|\(path)"
        if let cached = claudeCache[key], cached.stamp == stamp { return cached.entries }

        var entries: [String: ClaudeUsage] = [:]
        UsageLineStream.forEachLine(path: path) { line in
            guard line.range(of: assistantMarker) != nil, line.range(of: usageMarker) != nil else { return }
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      J.str(o["type"]) == "assistant",
                      (o["isApiErrorMessage"] as? Bool) != true,
                      let ts = J.date(o["timestamp"]),
                      ts.timeIntervalSince1970 > 0,
                      let msg = J.dict(o["message"]),
                      let model = J.str(msg["model"]), model != "<synthetic>",
                      let usage = J.dict(msg["usage"]),
                      let id = J.str(msg["id"]) ?? J.str(o["requestId"]), !id.isEmpty
                else { return }

                let entry = ClaudeUsage(
                    sourceID: sourceID,
                    sessionKey: J.str(o["sessionId"]) ?? path,
                    timestamp: ts,
                    model: model,
                    stopReason: J.str(msg["stop_reason"]),
                    output: J.int(usage["output_tokens"]),
                    input: J.int(usage["input_tokens"]),
                    cacheRead: J.int(usage["cache_read_input_tokens"]),
                    cacheWrite: J.int(usage["cache_creation_input_tokens"]),
                    cacheWrite1h: J.int(J.dict(usage["cache_creation"])?["ephemeral_1h_input_tokens"])
                )
                if let existing = entries[id] {
                    if Self.prefer(entry, over: existing) { entries[id] = entry }
                } else {
                    entries[id] = entry
                }
            }
        }

        claudeCache[key] = (stamp, entries)
        return entries
    }

    private static func prefer(_ candidate: ClaudeUsage, over existing: ClaudeUsage) -> Bool {
        if candidate.stopReason != nil && existing.stopReason == nil { return true }
        if (candidate.stopReason != nil) == (existing.stopReason != nil) {
            return candidate.output > existing.output
        }
        return false
    }

    private func claudeEvents(_ entries: [String: ClaudeUsage], sourceID: String) -> [UsageEvent] {
        struct Key: Hashable {
            let session: String
            let day: Date
            let model: String
        }
        let latest = calendar.startOfDay(for: Date().addingTimeInterval(86400))
        var byKey: [Key: TokenTotals] = [:]

        for entry in entries.values where entry.sourceID == sourceID {
            let day = calendar.startOfDay(for: entry.timestamp)
            guard day <= latest else { continue }
            var t = TokenTotals()
            t.output = max(0, entry.output)
            t.uncachedInput = max(0, entry.input)
            t.cacheRead = max(0, entry.cacheRead)
            t.cacheWrite = max(0, entry.cacheWrite)
            t.cacheWrite1h = max(0, min(entry.cacheWrite1h, entry.cacheWrite))
            t.requests = 1
            guard t.total > 0 else { continue }
            let key = Key(session: entry.sessionKey, day: day, model: normalizedModel(entry.model) ?? "")
            byKey[key, default: TokenTotals()].add(t)
        }

        return byKey.map { key, totals in
            UsageEvent(sourceID: sourceID, sessionKey: key.session, day: key.day,
                       model: key.model.isEmpty ? nil : key.model, totals: totals)
        }
    }

    private func normalizedModel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.isEmpty ? nil : model
    }

    // MARK: Codex usage (compressed rollouts, archives, fork replay dedupe)

    private func scanCodexFile(_ ref: SessionRef) -> CodexFileUsage? {
        guard case .file(let path) = ref.locator else { return nil }
        let stamp = SessionDiscovery.fileStat(path)
            .map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "missing"
        cacheLock.lock()
        let cached = codexCache[path]
        cacheLock.unlock()
        if let cached, cached.stamp == stamp { return cached.usage }

        var sessionID = SessionDiscovery.codexSessionID(from: path)
        var parentID: String?
        var model: String?
        var tokenCounts: [CodexUsage] = []
        var usageRecords: [CodexUsage] = []
        var lastTotal = Int.min

        UsageLineStream.forEachLine(path: path) { line in
            guard Self.codexLineMarkers.contains(where: { line.range(of: $0) != nil }) else { return }
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let ts = J.date(o["timestamp"]), ts.timeIntervalSince1970 > 0
                else { return }
                let type = J.str(o["type"])
                let p = J.dict(o["payload"]) ?? [:]

                switch type {
                case "session_meta":
                    if let id = J.str(p["id"]) ?? J.str(p["session_id"]) { sessionID = id }
                    if let parent = J.str(p["forked_from_id"]) { parentID = parent }
                    if let m = J.str(p["model"]) { model = m }
                case "turn_context":
                    if let m = J.str(p["model"]) { model = m }
                case "thread_settings_applied":
                    if let m = J.str(J.dict(p["thread_settings"])?["model"]) { model = m }
                case "token_usage_record":
                    if let u = J.dict(p["usage"]),
                       let usage = self.makeCodexUsage(u, timestamp: ts, model: model) {
                        usageRecords.append(usage)
                    }
                case "event_msg" where J.str(p["type"]) == "token_count":
                    let info = J.dict(p["info"]) ?? [:]
                    let total = J.int(J.dict(info["total_token_usage"])?["total_tokens"])
                    guard total != lastTotal else { break }
                    lastTotal = total
                    let eventModel = J.str(info["model"]) ?? model
                    if let u = J.dict(info["last_token_usage"]),
                       let usage = self.makeCodexUsage(u, timestamp: ts, model: eventModel) {
                        tokenCounts.append(usage)
                    }
                default:
                    break
                }
            }
        }

        // Newer Codex versions write both channels for the same responses. If the
        // file has token_usage_record rows, they are authoritative.
        let usage = CodexFileUsage(sessionID: sessionID ?? path, parentID: parentID,
                                   events: usageRecords.isEmpty ? tokenCounts : usageRecords)
        cacheLock.lock()
        codexCache[path] = CachedCodexFile(stamp: stamp, usage: usage)
        cacheLock.unlock()
        return usage
    }

    private func makeCodexUsage(_ u: [String: Any], timestamp: Date, model: String?) -> CodexUsage? {
        let input = max(0, J.int(u["input_tokens"]))
        let cacheRead = max(0, J.int(u["cached_input_tokens"]))
        let cacheWrite = max(0, J.int(u["cache_write_input_tokens"]))
        let output = max(0, J.int(u["output_tokens"]))
        let reasoning = max(0, J.int(u["reasoning_output_tokens"]))
        guard input > 0 || output > 0 else { return nil }
        return CodexUsage(timestamp: timestamp, model: normalizedModel(model),
                          input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                          signature: CodexSignature(input: input, cacheRead: cacheRead,
                                                    cacheWrite: cacheWrite, output: output,
                                                    reasoning: reasoning))
    }

    private static let codexLineMarkers: [Data] = [
        Data("\"session_meta\"".utf8), Data("\"turn_context\"".utf8),
        Data("\"thread_settings_applied\"".utf8), Data("\"token_usage_record\"".utf8),
        Data("\"token_count\"".utf8),
    ]

    private func codexEvents(_ files: [CodexFileUsage], index: [String: String],
                             sourceID: String) -> [UsageEvent] {
        struct Merged {
            var parentID: String?
            var events: [CodexUsage]
            var emitted: Bool
        }
        var sessions: [String: Merged] = [:]
        var emittedSessions = Set<String>()

        func merge(_ file: CodexFileUsage, emitted: Bool) {
            var m = sessions[file.sessionID] ?? Merged(parentID: nil, events: [], emitted: false)
            if m.parentID == nil { m.parentID = file.parentID }
            m.events.append(contentsOf: file.events)
            m.emitted = m.emitted || emitted
            sessions[file.sessionID] = m
            if emitted { emittedSessions.insert(file.sessionID) }
        }
        for file in files { merge(file, emitted: true) }

        // A resumed session can have its history copied into more than one file.
        for (sid, var m) in sessions {
            var seen = Set<CodexEventKey>()
            m.events = m.events.filter {
                seen.insert(CodexEventKey(timestamp: $0.timestamp, signature: $0.signature)).inserted
            }
            sessions[sid] = m
        }

        // Load fork parents that fell outside the selected range. Their events are
        // not emitted here (they are outside the range), but they reveal which
        // leading child events are replayed history.
        var loading = Set<String>()
        func ensureSession(_ sid: String) {
            if sessions[sid] != nil || loading.contains(sid) { return }
            guard let path = index[sid] else { return }
            loading.insert(sid)
            let ref = SessionRef(path: path, source: AgentSource(id: sourceID),
                                 locator: .file(path), modified: Date())
            if let loaded = scanCodexFile(ref) {
                merge(loaded, emitted: false)
                if let parent = loaded.parentID { ensureSession(parent) }
            }
            loading.remove(sid)
        }
        for m in Array(sessions.values) {
            if let parent = m.parentID { ensureSession(parent) }
        }

        var ownValues: [String: [CodexSignature: Int]] = [:]
        for (sid, m) in sessions {
            var counts: [CodexSignature: Int] = [:]
            for event in m.events { counts[event.signature, default: 0] += 1 }
            ownValues[sid] = counts
        }

        var budgetCache: [String: [CodexSignature: Int]] = [:]
        var visiting = Set<String>()
        func ancestorBudget(_ sid: String) -> [CodexSignature: Int] {
            if let cached = budgetCache[sid] { return cached }
            guard !visiting.contains(sid), let parent = sessions[sid]?.parentID else {
                budgetCache[sid] = [:]
                return [:]
            }
            visiting.insert(sid)
            var budget = ownValues[parent] ?? [:]
            for (signature, count) in ancestorBudget(parent) {
                budget[signature, default: 0] += count
            }
            visiting.remove(sid)
            budgetCache[sid] = budget
            return budget
        }

        struct Key: Hashable {
            let session: String
            let day: Date
            let model: String
        }
        var byKey: [Key: TokenTotals] = [:]
        let latest = calendar.startOfDay(for: Date().addingTimeInterval(86400))

        for sid in emittedSessions {
            guard let m = sessions[sid] else { continue }
            var budget = ancestorBudget(sid)
            for event in m.events.sorted(by: { $0.timestamp < $1.timestamp }) {
                if let count = budget[event.signature], count > 0 {
                    budget[event.signature] = count - 1
                    continue
                }
                let day = calendar.startOfDay(for: event.timestamp)
                guard day <= latest else { continue }
                let cacheRead = max(0, min(event.cacheRead, event.input))
                let cacheWrite = max(0, min(event.cacheWrite, event.input - cacheRead))
                var t = TokenTotals()
                t.uncachedInput = max(0, event.input - cacheRead - cacheWrite)
                t.cacheRead = cacheRead
                t.cacheWrite = cacheWrite
                t.output = event.output
                t.requests = 1
                guard t.total > 0 else { continue }
                byKey[Key(session: sid, day: day, model: event.model ?? ""),
                      default: TokenTotals()].add(t)
            }
        }

        return byKey.map { key, totals in
            UsageEvent(sourceID: sourceID, sessionKey: key.session, day: key.day,
                       model: key.model.isEmpty ? nil : key.model, totals: totals)
        }
    }

    // MARK: Grok Build (turn_completed events)

    private func grokUsageFiles(since: Date?) -> [SessionRef] {
        let source = AgentSource(id: "grok")
        let fm = FileManager.default
        var out: [SessionRef] = []

        for root in [".grok/sessions", ".grok/archived_sessions"] {
            let base = SessionDiscovery.home.appendingPathComponent(root).path
            func walk(_ dir: String, depth: Int) {
                guard depth <= 8, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
                for name in names {
                    if name.hasPrefix(".") { continue }
                    let path = dir + "/" + name
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue { walk(path, depth: depth + 1); continue }
                    guard name == "updates.jsonl",
                          let (mtime, size) = SessionDiscovery.fileStat(path),
                          // A turn_completed line is ~2.1 KB; smaller files are
                          // prompt-only stubs with no usage event.
                          size >= 2048,
                          since.map({ mtime > $0 }) ?? true
                    else { continue }
                    out.append(SessionRef(path: path, source: source,
                                          locator: .file(path), modified: mtime))
                }
            }
            walk(base, depth: 0)
        }
        return out.sorted { $0.modified > $1.modified }
    }

    private func scanGrokFile(_ ref: SessionRef) -> [GrokUsage] {
        guard case .file(let path) = ref.locator else { return [] }
        let stamp = SessionDiscovery.fileStat(path)
            .map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "missing"
        cacheLock.lock()
        let cached = grokCache[path]
        cacheLock.unlock()
        if let cached, cached.stamp == stamp { return cached.events }

        var events: [GrokUsage] = []
        UsageLineStream.forEachLine(path: path) { line in
            guard line.range(of: Self.grokMarker) != nil else { return }
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                let params = J.dict(o["params"]) ?? [:]
                let update = J.dict(params["update"]) ?? [:]
                guard J.str(update["sessionUpdate"]) == "turn_completed" else { return }
                guard let usage = J.dict(update["usage"]) ?? J.dict(params["usage"]) ?? J.dict(o["usage"]) else { return }
                let timestamp = J.date(o["timestamp"]) ?? ref.modified
                let session = J.str(params["sessionId"]) ?? J.str(update["sessionId"])
                    ?? J.str(o["sessionId"]) ?? path
                let sessionKey = "grok#\(session)"
                let models = J.dict(usage["modelUsage"]) ?? [:]

                if models.isEmpty {
                    if let event = self.makeGrokUsage(usage, timestamp: timestamp,
                                                      sessionKey: sessionKey, model: nil) {
                        events.append(event)
                    }
                } else {
                    for (model, value) in models {
                        guard let counters = J.dict(value),
                              let event = self.makeGrokUsage(counters, timestamp: timestamp,
                                                             sessionKey: sessionKey, model: model)
                        else { continue }
                        events.append(event)
                    }
                }
            }
        }

        cacheLock.lock()
        grokCache[path] = CachedGrokFile(stamp: stamp, events: events)
        cacheLock.unlock()
        return events
    }

    private func makeGrokUsage(_ u: [String: Any], timestamp: Date, sessionKey: String,
                               model: String?) -> GrokUsage? {
        let input = max(0, J.int(u["inputTokens"]))
        let output = max(0, J.int(u["outputTokens"]))
        let cacheRead = max(0, J.int(u["cachedReadTokens"]))
        let cacheWrite = max(0, J.int(u["cacheCreationTokens"]))
        guard input > 0 || output > 0 else { return nil }
        return GrokUsage(timestamp: timestamp, sessionKey: sessionKey,
                         model: normalizedModel(model), input: input,
                         cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
    }

    private static let grokMarker = Data("\"turn_completed\"".utf8)

    private func aggregateGrok(_ usages: [GrokUsage]) -> [UsageEvent] {
        struct Key: Hashable {
            let session: String
            let day: Date
            let model: String
        }
        let latest = calendar.startOfDay(for: Date().addingTimeInterval(86400))
        var byKey: [Key: TokenTotals] = [:]

        for usage in usages {
            let day = calendar.startOfDay(for: usage.timestamp)
            guard day <= latest else { continue }
            let cacheRead = max(0, min(usage.cacheRead, usage.input))
            let cacheWrite = max(0, min(usage.cacheWrite, usage.input - cacheRead))
            var t = TokenTotals()
            t.uncachedInput = max(0, usage.input - cacheRead - cacheWrite)
            t.cacheRead = cacheRead
            t.cacheWrite = cacheWrite
            t.output = usage.output
            t.requests = 1
            guard t.total > 0 else { continue }
            byKey[Key(session: usage.sessionKey, day: day, model: usage.model ?? ""),
                  default: TokenTotals()].add(t)
        }

        return byKey.map { key, totals in
            UsageEvent(sourceID: "grok", sessionKey: key.session, day: key.day,
                       model: key.model.isEmpty ? nil : key.model, totals: totals)
        }
    }

    private func scanLines(path: String, sourceID: String,
                           makeParser: @escaping () -> SessionParser,
                           markers: [Data], requireAll: Bool) -> [UsageEvent] {
        let parser = makeParser()
        UsageLineStream.forEachLine(path: path) { line in
            let hit = requireAll
                ? markers.allSatisfy { line.range(of: $0) != nil }
                : markers.contains { line.range(of: $0) != nil }
            guard hit else { return }
            autoreleasepool {
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
                parser.consume(obj)
            }
        }
        return aggregate(parser.acc.requests, sourceID: sourceID, sessionKey: path)
    }

    private func scanDeepSeek(path: String, ref: SessionRef, sourceID: String) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = J.dict(J.dict(o["record"])?["rows"]),
              let tokenUsage = J.dict(J.dict(rows["tokenUsage"])?["val"]),
              let totals = J.dict(tokenUsage["totals"])
        else { return [] }

        var t = TokenTotals()
        t.uncachedInput = J.int(totals["uncachedInputTokens"])
        t.output = J.int(totals["outputTokens"])
        t.cacheRead = J.int(totals["cacheReadTokens"])
        t.cacheWrite = J.int(totals["cacheWriteTokens"])
        guard t.total > 0 else { return [] }
        let stats = J.dict(J.dict(rows["sessionStats"])?["val"]) ?? [:]
        t.requests = max(1, J.int(stats["steps"]))
        let selection = J.dict(J.dict(rows["modelSelection"])?["val"]) ?? [:]
        let model = normalizedModel(J.str(J.dict(selection["lastUsed"])?["model"])
                                    ?? J.str(J.dict(selection["pending"])?["model"]))

        let when = min(ref.modified, Date())
        let day = calendar.startOfDay(for: when)
        return [UsageEvent(sourceID: sourceID, sessionKey: path, day: day, model: model, totals: t)]
    }

    private func aggregate(_ requests: [RequestRecord], sourceID: String, sessionKey: String) -> [UsageEvent] {
        struct DayModel: Hashable {
            let day: Date
            let model: String
        }
        let latest = calendar.startOfDay(for: Date().addingTimeInterval(86400))
        var byDay: [DayModel: TokenTotals] = [:]
        for r in requests {
            guard r.end.timeIntervalSince1970 > 0 else { continue }
            let day = calendar.startOfDay(for: r.end)
            guard day <= latest else { continue }
            var t = TokenTotals()
            t.add(r)
            if ToolRegistry.spec(sourceID)?.format == .qoder && r.chargedCredits == nil { t.missingCreditRequests = 1 }
            guard t.total > 0 || t.hasCreditData else { continue }
            byDay[DayModel(day: day, model: normalizedModel(r.model) ?? ""), default: TokenTotals()].add(t)
        }
        return byDay.map { key, totals in
            UsageEvent(sourceID: sourceID, sessionKey: sessionKey, day: key.day,
                       model: key.model.isEmpty ? nil : key.model, totals: totals)
        }
    }

    // MARK: opencode / MiMo Code SQLite

    private func scanOpencode(_ path: String, sourceID: String) -> [UsageEvent] {
        let stamp = [path, path + "-wal"].map { p in
            SessionDiscovery.fileStat(p).map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "-"
        }.joined(separator: "|")
        if let cached = dbCache[path], cached.stamp == stamp { return cached.events }
        guard let db = SQLiteDB(path: path) else { return [] }

        struct SessionDay: Hashable {
            let session: String
            let day: Date
            let model: String
        }
        let latest = calendar.startOfDay(for: Date().addingTimeInterval(86400))
        var byDay: [SessionDay: TokenTotals] = [:]

        db.each("SELECT session_id, data FROM message") { row in
            guard let sid = row[0] as? String, let text = row[1] as? String else { return }
            let data = Data(text.utf8)
            guard data.range(of: self.assistantMarker) != nil else { return }
            autoreleasepool {
                guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      J.str(o["role"]) == "assistant" else { return }
                let time = J.dict(o["time"]) ?? [:]
                guard let completed = J.date(time["completed"]) else { return }
                let day = self.calendar.startOfDay(for: completed)
                guard day <= latest else { return }
                let t = J.dict(o["tokens"]) ?? [:]
                let cache = J.dict(t["cache"]) ?? [:]
                var tt = TokenTotals()
                tt.output = J.int(t["output"]) + J.int(t["reasoning"])
                tt.uncachedInput = J.int(t["input"])
                tt.cacheRead = J.int(cache["read"])
                tt.cacheWrite = J.int(cache["write"])
                tt.requests = 1
                guard tt.total > 0 else { return }
                let model = self.normalizedModel(J.str(o["modelID"])
                                                 ?? J.str(J.dict(o["model"])?["modelID"])
                                                 ?? J.str(J.dict(o["model"])?["id"])) ?? ""
                byDay[SessionDay(session: sid, day: day, model: model), default: TokenTotals()].add(tt)
            }
        }

        let events = byDay.map { key, totals in
            UsageEvent(sourceID: sourceID, sessionKey: "\(path)#\(key.session)", day: key.day,
                       model: key.model.isEmpty ? nil : key.model, totals: totals)
        }
        dbCache[path] = CachedFile(stamp: stamp, events: events)
        return events
    }
}

/// Line-by-line reader for very large JSONL logs. Only complete lines are handed to the
/// callback; a single 64 MB line (e.g. an embedded image) is skipped so memory stays flat.
/// Codex compresses old rollouts with zstd. macOS's Compression framework has no
/// zstd codec, so we stream through a local `zstd` binary when one is installed.
enum ZstdSupport {
    static let executable: String? = {
        if let bundled = Bundle.main.path(forResource: "zstd", ofType: nil) {
            return bundled
        }
        return ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd",
                "/opt/local/bin/zstd", "/usr/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { executable != nil }
}

private enum UsageLineStream {
    static func forEachLine(path: String, _ body: (Data) -> Void) {
        if path.hasSuffix(".zst") {
            forEachZstdLine(path: path, body)
        } else {
            guard let fh = FileHandle(forReadingAtPath: path) else { return }
            defer { try? fh.close() }
            readLines(fh, body)
        }
    }

    private static func forEachZstdLine(path: String, _ body: (Data) -> Void) {
        guard let executable = ZstdSupport.executable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-dcq", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        readLines(pipe.fileHandleForReading, body)
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
    }

    /// Line-by-line reader for very large JSONL logs. Only complete lines are handed to
    /// the callback; a single 64 MB line (e.g. an embedded image) is skipped so memory
    /// stays flat.
    private static func readLines(_ fh: FileHandle, _ body: (Data) -> Void) {
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var skippingLongLine = false

        while true {
            let chunk = (try? fh.read(upToCount: 4 << 20)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: newline) {
                let line = buffer[start..<nl]
                if !skippingLongLine, !line.isEmpty { body(Data(line)) }
                skippingLongLine = false
                start = buffer.index(after: nl)
            }
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            if buffer.count > 64 << 20 {
                buffer.removeAll(keepingCapacity: false)
                skippingLongLine = true
            }
        }
        if !skippingLongLine, !buffer.isEmpty { body(buffer) }
    }
}

// MARK: - Store

@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()

    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var loadedRange: UsageRange?
    @Published private(set) var progress: String?
    @Published private(set) var scanDuration: TimeInterval?

    private let queue = DispatchQueue(label: "agentpulse.usage", qos: .utility)
    private let scanner = TokenUsageScanner()
    private var token: UsageScanToken?
    private var demo = false

    private init() {}

    func loadIfNeeded(range: UsageRange) {
        guard !demo else { return }
        guard !loading, !loaded || loadedRange != range else { return }
        load(range: range)
    }

    func load(range: UsageRange) {
        guard !demo else { return }
        let t = UsageScanToken()
        token?.cancel()
        token = t
        loading = true
        let since = range.startDate()
        let started = Date()
        let scanner = self.scanner

        queue.async {
            let found = scanner.scan(since: since, token: t) { done, total, name in
                Task { @MainActor in
                    guard self.token === t else { return }
                    self.progress = "正在统计 \(name) · \(done)/\(total)"
                }
            }
            Task { @MainActor in
                guard self.token === t else { return }
                self.loading = false
                self.progress = nil
                guard !t.isCancelled else { return }
                self.events = found
                self.loaded = true
                self.loadedRange = range
                self.scanDuration = Date().timeIntervalSince(started)
            }
        }
    }

    func summary(range: UsageRange, tool: String?) -> UsageSummary {
        UsageAggregation.summary(events: events, range: range, tool: tool)
    }

    // MARK: Screenshots

    func loadDemo() {
        demo = true
        loading = false
        progress = nil
        scanDuration = nil
        loaded = true
        loadedRange = nil
        events = UsageDemo.events()
    }
}

// MARK: - Demo data

enum UsageDemo {
    static func events(now: Date = Date(), calendar: Calendar = .current) -> [UsageEvent] {
        let tools: [(id: String, base: Double, outputShare: Double, models: [String])] = [
            ("claude", 2_400_000, 0.072, ["claude-opus-5-5", "claude-sonnet-5-5"]),
            ("codex", 1_450_000, 0.105, ["gpt-6.1-sol", "gpt-6-luna"]),
            ("opencode", 640_000, 0.12, ["mimo-v2.5-pro", "glm-5.3"]),
            ("codebuddy", 330_000, 0.088, ["hy3", "mimo-v2.6-pro"]),
            ("workbuddy", 260_000, 0.079, ["deepseek-v4.1-flash", "kimi-k3"]),
            ("stepcode", 105_000, 0.113, ["step-5-preview", "glm-5.3-flash"]),
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
        }

        let today = calendar.startOfDay(for: now)
        var out: [UsageEvent] = []
        for offset in 0..<120 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7

            for tool in tools {
                let activity = weekend ? 0.3 : 1.0
                if offset != 0, random() > 0.84 * activity { continue }
                let trend = 1.0 + Double(120 - offset) / 260.0
                let total = Int(tool.base * (0.45 + random()) * activity * trend)
                var t = TokenTotals()
                t.output = Int(Double(total) * tool.outputShare)
                t.cacheRead = Int(Double(total) * 0.76)
                t.cacheWrite = Int(Double(total) * 0.024)
                t.cacheWrite1h = Int(Double(t.cacheWrite) * 0.35)
                t.uncachedInput = max(0, total - t.output - t.cacheRead - t.cacheWrite)
                t.requests = Int(9 + random() * 42)

                var first = t
                first.output = Int(Double(t.output) * 0.82)
                first.cacheRead = Int(Double(t.cacheRead) * 0.82)
                first.cacheWrite = Int(Double(t.cacheWrite) * 0.82)
                first.cacheWrite1h = Int(Double(t.cacheWrite1h) * 0.82)
                first.uncachedInput = Int(Double(t.uncachedInput) * 0.82)
                first.requests = Int(Double(t.requests) * 0.82)

                var second = t
                second.output -= first.output
                second.cacheRead -= first.cacheRead
                second.cacheWrite -= first.cacheWrite
                second.cacheWrite1h -= first.cacheWrite1h
                second.uncachedInput -= first.uncachedInput
                second.requests -= first.requests

                out.append(UsageEvent(sourceID: tool.id, sessionKey: "demo-\(tool.id)-1", day: day,
                                      model: tool.models[0], totals: first))
                if second.total > 0 {
                    out.append(UsageEvent(sourceID: tool.id, sessionKey: "demo-\(tool.id)-2", day: day,
                                          model: tool.models[1], totals: second))
                }
            }
        }
        return out
    }
}
