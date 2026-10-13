import Foundation
import SQLite3

/// Where a session's data lives.
enum Locator: Equatable {
    case file(String)
    case sqlite(db: String, session: String)
}

/// A session found on disk. Discovery only uses cheap metadata (mtime, ids, cwd).
struct SessionRef: Identifiable, Equatable {
    var id: String { path }
    /// Unique key: the file path, or "db#session" for SQLite-backed tools.
    let path: String
    let source: AgentSource
    let locator: Locator
    var modified: Date
    var title: String?
    var cwd: String?
    /// Set for sub-agent sessions (e.g. Codex's auto-review); they belong to the parent.
    var parentID: String?

    var isSubagent: Bool { parentID != nil }
    var label: String {
        if let t = title, !t.isEmpty { return t }
        if let c = cwd, !c.isEmpty { return (c as NSString).lastPathComponent }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Produces up-to-date stats for one session, reading incrementally where possible.
protocol SessionReader: AnyObject {
    var ref: SessionRef { get }
    func refresh(contextWindowOverride: Int?) -> SessionStats
}

enum Readers {
    static func make(_ ref: SessionRef) -> SessionReader? {
        guard let format = ref.source.spec?.format else { return nil }
        switch (format, ref.locator) {
        case (.deepseekHarness, .file(let p)):
            return DeepSeekHarnessReader(ref: ref, path: p)
        case (.opencodeDB, .sqlite(let db, let sid)):
            return OpenCodeReader(ref: ref, db: db, sessionID: sid)
        case (_, .file(let p)):
            guard let make = parserFactory(format) else { return nil }
            return JSONLReader(ref: ref, path: p, makeParser: make)
        default:
            return nil
        }
    }

    private static func parserFactory(_ f: LogFormat) -> (() -> SessionParser)? {
        switch f {
        case .claudeCode: return { ClaudeParser() }
        case .codex: return { CodexParser() }
        case .codebuddy: return { CodeBuddyParser() }
        case .pi: return { PiParser() }
        case .zcode: return { ZCodeParser() }
        case .antigravity: return { AntigravityParser() }
        case .opencodeDB, .deepseekHarness: return nil
        }
    }
}

// MARK: - Discovery

/// Finds session logs that agent tools already write to the local disk. Read-only.
enum SessionDiscovery {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Sessions of one tool, newest first. `since` limits to recently modified ones.
    static func sessions(for spec: AgentToolSpec, since: Date?, limit: Int = 400) -> [SessionRef] {
        guard let format = spec.format else { return [] }
        let source = AgentSource(id: spec.id)
        let roots = spec.sessionRoots.map { home.appendingPathComponent($0).path }
        var out: [SessionRef]
        switch format {
        case .claudeCode, .codebuddy, .pi:
            // <root>/<project>/<session>.jsonl (top level only; sub-agents live deeper)
            out = roots.flatMap { filesTwoLevels($0, ext: "jsonl", since: since) }
                .map { SessionRef(path: $0.0, source: source, locator: .file($0.0), modified: $0.1) }
        case .codex:
            out = roots.flatMap { codexFiles($0, since: since) }
                .map { SessionRef(path: $0.0, source: source, locator: .file($0.0), modified: $0.1) }
        case .zcode:
            out = roots.flatMap { files($0, since: since) { $0.hasPrefix("model-io-") && $0.hasSuffix(".jsonl") } }
                .map { SessionRef(path: $0.0, source: source, locator: .file($0.0), modified: $0.1) }
        case .deepseekHarness:
            out = roots.flatMap { files($0, since: since) { $0.hasSuffix(".json") } }
                .map { SessionRef(path: $0.0, source: source, locator: .file($0.0), modified: $0.1) }
        case .antigravity:
            out = roots.flatMap { root -> [(String, Date)] in
                subdirs(root).compactMap { dir in
                    let p = dir + "/.system_generated/logs/transcript.jsonl"
                    guard let m = mtime(p), since.map({ m > $0 }) ?? true else { return nil }
                    return (p, m)
                }
            }
            .map { SessionRef(path: $0.0, source: source, locator: .file($0.0), modified: $0.1) }
        case .opencodeDB:
            out = roots.flatMap { opencodeSessions($0, source: source, since: since, limit: limit) }
        }
        out.sort { $0.modified > $1.modified }
        if out.count > limit { out = Array(out.prefix(limit)) }
        for i in out.indices where out[i].cwd == nil || (format == .codex && out[i].parentID == nil) {
            fillMetadata(&out[i], format: format)
        }
        return out
    }

    // MARK: Metadata (cwd, parent) — cached per path, it never changes for a session.

    private static var metaCache: [String: (cwd: String?, parent: String?, title: String?)] = [:]
    private static let metaLock = NSLock()

    private static func fillMetadata(_ ref: inout SessionRef, format: LogFormat) {
        guard case .file(let path) = ref.locator else { return }
        metaLock.lock()
        let cached = metaCache[path]
        metaLock.unlock()
        let meta = cached ?? {
            let m = peekMetadata(path, format: format)
            metaLock.lock(); metaCache[path] = m; metaLock.unlock()
            return m
        }()
        if ref.cwd == nil { ref.cwd = meta.cwd }
        if ref.parentID == nil { ref.parentID = meta.parent }
        if ref.title == nil { ref.title = meta.title }
    }

    private static let cwdRegex = try! NSRegularExpression(pattern: #""cwd"\s*:\s*("(?:[^"\\]|\\.)*")"#)
    private static let parentRegex = try! NSRegularExpression(pattern: #""parent_thread_id"\s*:\s*"([^"]+)""#)

    /// Reads the head of a log for `cwd` (and Codex's `parent_thread_id`). Only those fields are extracted.
    private static func peekMetadata(_ path: String, format: LogFormat) -> (cwd: String?, parent: String?, title: String?) {
        switch format {
        case .deepseekHarness:
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let rows = J.dict(J.dict(o["record"])?["rows"]) else { return (nil, nil, nil) }
            return (nil, nil, J.str(J.dict(rows["title"])?["val"]))
        case .zcode:
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return (nil, nil, "ZCode · " + String(name.replacingOccurrences(of: "model-io-sess_", with: "").prefix(8)))
        case .antigravity:
            let id = (((path as NSString).deletingLastPathComponent as NSString)
                .deletingLastPathComponent as NSString).deletingLastPathComponent
            return (nil, nil, "Antigravity · " + String((id as NSString).lastPathComponent.prefix(8)))
        default:
            break
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
        defer { try? fh.close() }
        guard var data = try? fh.read(upToCount: 64 * 1024) else { return (nil, nil, nil) }
        // A very long first line (e.g. a forked session's summary) can push `cwd` further in.
        if data.count == 64 * 1024, data.range(of: Data(#""cwd""#.utf8)) == nil,
           let more = try? fh.read(upToCount: 960 * 1024) {
            data.append(more)
        }
        // Lossy decode: the cut can land inside a multi-byte character.
        let s = String(decoding: data, as: UTF8.self)
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        var cwd: String?
        if let m = cwdRegex.firstMatch(in: s, range: range) {
            cwd = (try? JSONSerialization.jsonObject(with: Data(ns.substring(with: m.range(at: 1)).utf8),
                                                     options: .fragmentsAllowed)) as? String
        }
        var parent: String?
        if format == .codex, let m = parentRegex.firstMatch(in: s, range: range) {
            parent = ns.substring(with: m.range(at: 1))
        }
        return (cwd, parent, nil)
    }

    // MARK: File helpers

    /// Modification time and size via a plain stat(2) — far cheaper than FileManager attributes.
    static func fileStat(_ p: String) -> (Date, Int)? {
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        let t = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (Date(timeIntervalSince1970: t), Int(st.st_size))
    }

    private static func mtime(_ p: String) -> Date? { fileStat(p)?.0 }

    private static func subdirs(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { dir + "/" + $0 }
    }

    private static func files(_ dir: String, since: Date?, match: (String) -> Bool) -> [(String, Date)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name in
            guard match(name) else { return nil }
            let p = dir + "/" + name
            guard let (m, size) = fileStat(p), since.map({ m > $0 }) ?? true else { return nil }
            // Skip empty logs and stale stubs that never got a model response (just the first prompt).
            if size == 0 || (size < 2048 && Date().timeIntervalSince(m) > 600) { return nil }
            return (p, m)
        }
    }

    private static func filesTwoLevels(_ root: String, ext: String, since: Date?) -> [(String, Date)] {
        subdirs(root).flatMap { files($0, since: since) { $0.hasSuffix("." + ext) } }
    }

    /// sessions/YYYY/MM/DD/*.jsonl. With `since`, only day folders that can contain recent files.
    private static func codexFiles(_ root: String, since: Date?) -> [(String, Date)] {
        let fm = FileManager.default
        func numbered(_ u: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: u)) ?? [])
                .filter { $0.allSatisfy(\.isNumber) }
                .sorted(by: >)
                .map { u + "/" + $0 }
        }
        // A session started days ago can still be written today, so scan a few extra days.
        let dayLimit = since.map { max(4, Int(Date().timeIntervalSince($0) / 86400) + 4) } ?? Int.max
        var days: [String] = []
        outer: for y in numbered(root) {
            for m in numbered(y) {
                for d in numbered(m) {
                    days.append(d)
                    if days.count >= dayLimit { break outer }
                }
            }
        }
        return days.flatMap { files($0, since: since) { $0.hasSuffix(".jsonl") } }
    }

    // MARK: opencode family

    private static var opencodeCache: [String: (stamp: String, refs: [SessionRef])] = [:]

    private static func opencodeSessions(_ db: String, source: AgentSource, since: Date?, limit: Int) -> [SessionRef] {
        // The database and its WAL only change when the tool writes; skip the query otherwise.
        let stamp = [db, db + "-wal"].map { fileStat($0).map { "\($0.0.timeIntervalSince1970)/\($0.1)" } ?? "-" }
            .joined(separator: "|") + "|\(since.map { Int($0.timeIntervalSince1970 / 60) } ?? -1)|\(limit)"
        let key = "\(db)|\(since == nil)"
        metaLock.lock()
        let cached = opencodeCache[key]
        metaLock.unlock()
        if let cached, cached.stamp == stamp { return cached.refs }
        let refs = queryOpencodeSessions(db, source: source, since: since, limit: limit)
        metaLock.lock(); opencodeCache[key] = (stamp, refs); metaLock.unlock()
        return refs
    }

    private static func queryOpencodeSessions(_ db: String, source: AgentSource, since: Date?, limit: Int) -> [SessionRef] {
        guard let conn = SQLiteDB(path: db) else { return [] }
        // Only the `session` table is read: ids, titles, folders, timestamps.
        let sinceMs = Int64((since?.timeIntervalSince1970 ?? 0) * 1000)
        let rows = conn.query("""
            SELECT id, title, directory, time_updated, parent_id FROM session
            WHERE time_updated > ? AND EXISTS (SELECT 1 FROM message m WHERE m.session_id = session.id)
            ORDER BY time_updated DESC LIMIT ?
            """, [sinceMs, Int64(limit)])
        return rows.compactMap { r in
            guard let id = r[0] as? String, let updated = r[3] as? Int64 else { return nil }
            var ref = SessionRef(path: "\(db)#\(id)", source: source, locator: .sqlite(db: db, session: id),
                                 modified: Date(timeIntervalSince1970: Double(updated) / 1000))
            ref.title = r[1] as? String
            ref.cwd = r[2] as? String
            ref.parentID = r[4] as? String
            return ref
        }
    }
}

// MARK: - SQLite (read-only)

/// Minimal read-only SQLite access for tools that keep sessions in a database.
final class SQLiteDB {
    private var handle: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 300)
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String, _ args: [Any] = []) -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row.append(sqlite3_column_text(stmt, c).map { String(cString: $0) })
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }
}

// MARK: - opencode / MiMo Code

/// Reads one session's `message` rows. Each assistant message is one model call with
/// `time.created` / `time.completed` and token counts.
final class OpenCodeReader: SessionReader {
    let ref: SessionRef
    private let db: String
    private let sessionID: String
    private var lastUpdated: Int64 = -1
    private var cached: SessionStats?

    init(ref: SessionRef, db: String, sessionID: String) {
        self.ref = ref
        self.db = db
        self.sessionID = sessionID
    }

    func refresh(contextWindowOverride: Int?) -> SessionStats {
        guard let conn = SQLiteDB(path: db) else { return cached ?? SessionStats(source: ref.source, path: ref.path) }
        let updated = conn.query("SELECT MAX(time_updated) FROM message WHERE session_id = ?", [sessionID])
            .first?.first as? Int64 ?? 0
        if updated == lastUpdated, let c = cached { return c }
        lastUpdated = updated

        var acc = SessionAccumulator()
        acc.cwd = ref.cwd
        acc.title = ref.title
        var prevFinish: String?
        for row in conn.query("SELECT data FROM message WHERE session_id = ? ORDER BY time_created", [sessionID]) {
            guard let text = row[0] as? String,
                  let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
            let time = J.dict(o["time"]) ?? [:]
            guard let created = J.date(time["created"]) else { continue }
            switch J.str(o["role"]) {
            case "user":
                acc.turns += 1
                acc.boundary(created, .prompt)
                prevFinish = nil
            case "assistant":
                if let m = J.str(o["modelID"]) { acc.model = m }
                let kind: BoundaryKind = prevFinish == "tool-calls" ? .tool : .prompt
                guard let completed = J.date(time["completed"]) else {
                    // Still streaming.
                    if o["error"] == nil { acc.boundary(created, kind) } else { acc.endTurn(created) }
                    continue
                }
                let t = J.dict(o["tokens"]) ?? [:]
                let cache = J.dict(t["cache"]) ?? [:]
                var r = RequestRecord(id: J.str(o["id"]) ?? UUID().uuidString, model: acc.model,
                                      start: created, startKind: kind, firstOutput: nil, end: completed)
                r.outputTokens = J.int(t["output"]) + J.int(t["reasoning"])
                r.uncachedInput = J.int(t["input"])
                r.cacheRead = J.int(cache["read"])
                r.cacheWrite = J.int(cache["write"])
                r.contextTokens = r.uncachedInput + r.cacheRead + r.cacheWrite
                acc.requests.append(r)
                acc.endTurn(completed)
                prevFinish = J.str(o["finish"])
                if prevFinish == "tool-calls" {
                    // Tools run after this; the next assistant message continues the turn.
                    acc.boundary(completed, .tool)
                }
            default:
                break
            }
        }
        let s = acc.snapshot(source: ref.source, path: ref.path, contextWindowOverride: nil)
        cached = s
        return s
    }
}

// MARK: - DeepSeek Harness

/// DeepSeek Harness keeps a JSON snapshot per session with precomputed counters
/// (model time, TTFT, decode time and tokens). Speed over the last few seconds is
/// derived from how those counters grow between reads.
final class DeepSeekHarnessReader: SessionReader {
    let ref: SessionRef
    private let path: String
    private var lastMtime: Date?
    private var cached: SessionStats?
    private var prevDecode: (ms: Double, tokens: Double)?
    private var recentTPS: Double?
    private var openTurnSeen: Date?

    init(ref: SessionRef, path: String) {
        self.ref = ref
        self.path = path
    }

    func refresh(contextWindowOverride: Int?) -> SessionStats {
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let c = cached, m == lastMtime { return c }
        lastMtime = m
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = J.dict(J.dict(o["record"])?["rows"])
        else { return cached ?? SessionStats(source: ref.source, path: ref.path) }
        func val(_ k: String) -> [String: Any] { J.dict(J.dict(rows[k])?["val"]) ?? [:] }

        var s = SessionStats(source: ref.source, path: ref.path)
        s.title = J.str(J.dict(rows["title"])?["val"]) ?? ref.title
        s.lastActivity = m
        let st = val("sessionStats")
        s.turns = J.int(st["turns"])
        s.steps = J.int(st["steps"])
        s.modelTime = Double(J.int(st["llmMs"])) / 1000
        s.toolTime = Double(J.int(st["toolMs"])) / 1000
        let ttftSteps = J.int(st["ttftSteps"])
        if ttftSteps > 0 {
            s.avgTTFT = Double(J.int(st["ttftMs"])) / 1000 / Double(ttftSteps)
            s.ttftAvailable = true
        }
        let decodeMs = Double(J.int(st["decodeMs"])), decodeTokens = Double(J.int(st["decodeTokens"]))
        if decodeMs > 0 { s.sessionTPS = decodeTokens / decodeMs * 1000 }
        if let p = prevDecode, decodeMs > p.ms, decodeTokens > p.tokens {
            recentTPS = (decodeTokens - p.tokens) / (decodeMs - p.ms) * 1000
        }
        prevDecode = (decodeMs, decodeTokens)
        s.recentTPS = recentTPS ?? s.sessionTPS
        s.lastTPS = recentTPS

        let totals = J.dict(val("tokenUsage")["totals"]) ?? [:]
        s.uncachedInput = J.int(totals["uncachedInputTokens"])
        s.outputTokens = J.int(totals["outputTokens"])
        s.cacheRead = J.int(totals["cacheReadTokens"])
        s.cacheWrite = J.int(totals["cacheWriteTokens"])

        let ctx = val("contextPressure")
        s.contextTokens = J.int(ctx["pressureTokens"])
        if let w = ctx["contextWindow"] as? NSNumber { s.contextWindow = w.intValue }
        s.model = J.str(J.dict(val("modelSelection")["lastUsed"])?["model"])

        // An open turn means the agent is working right now.
        if val("turnBoundary")["openTurnStartSeq"] is NSNumber {
            openTurnSeen = openTurnSeen ?? (m ?? Date())
            s.waitingSince = openTurnSeen
        } else {
            openTurnSeen = nil
        }
        cached = s
        return s
    }
}
