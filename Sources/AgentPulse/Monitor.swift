import Foundation
import Combine

struct SessionRef: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let source: AgentSource
    let modified: Date
    var cwd: String?

    var label: String {
        if let c = cwd { return (c as NSString).lastPathComponent }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Finds session logs the agent tools already write to the local disk. Read-only.
enum SessionDiscovery {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var claudeProjectsDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent("projects")
        }
        return home.appendingPathComponent(".claude/projects")
    }

    static var codexSessionsDir: URL {
        if let d = ProcessInfo.processInfo.environment["CODEX_HOME"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".codex/sessions")
    }

    static func source(forPath p: String) -> AgentSource {
        p.contains("/.codex/") || (p as NSString).lastPathComponent.hasPrefix("rollout-") ? .codex : .claude
    }

    static func discover(maxAge: TimeInterval = 3 * 86400) -> [SessionRef] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var out: [SessionRef] = []
        let fm = FileManager.default

        // Claude Code: projects/<project>/<session>.jsonl (top level only; subagents live deeper)
        if let projects = try? fm.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: nil) {
            for dir in projects {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in files where f.pathExtension == "jsonl" {
                    if let m = mtime(f), m > cutoff { out.append(SessionRef(path: f.path, source: .claude, modified: m)) }
                }
            }
        }

        // Codex: sessions/YYYY/MM/DD/rollout-*.jsonl — only the most recent day folders.
        for dayDir in recentCodexDayDirs(limit: 4) {
            guard let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                if let m = mtime(f), m > cutoff { out.append(SessionRef(path: f.path, source: .codex, modified: m)) }
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    private static func recentCodexDayDirs(limit: Int) -> [URL] {
        let fm = FileManager.default
        func sortedSubdirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.allSatisfy(\.isNumber) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var days: [URL] = []
        for y in sortedSubdirs(codexSessionsDir) {
            for m in sortedSubdirs(y) {
                for d in sortedSubdirs(m) {
                    days.append(d)
                    if days.count >= limit { return days }
                }
            }
        }
        return days
    }

    private static func mtime(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static let cwdRegex = try! NSRegularExpression(pattern: #""cwd"\s*:\s*("(?:[^"\\]|\\.)*")"#)

    /// Reads the first 64 KB to find the working directory. Only the `cwd` field is extracted.
    static func peekCwd(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 64 * 1024),
              let s = String(data: data, encoding: .utf8) ?? String(data: data.prefix(60 * 1024), encoding: .utf8)
        else { return nil }
        let ns = s as NSString
        guard let m = cwdRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let quoted = ns.substring(with: m.range(at: 1))
        return (try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed)) as? String
    }
}

enum SourceFilter: String, CaseIterable, Identifiable {
    case all, claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
    func allows(_ s: AgentSource) -> Bool {
        switch self {
        case .all: return true
        case .claude: return s == .claude
        case .codex: return s == .codex
        }
    }
}

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var stats: SessionStats?
    /// Live stats for every tracked session (the most recent few), keyed by path.
    @Published private(set) var allStats: [String: SessionStats] = [:]
    @Published private(set) var sessions: [SessionRef] = []
    @Published var pinnedPath: String? {
        didSet {
            guard oldValue != pinnedPath else { return }
            // Switch instantly using already-parsed stats, then refresh.
            if let p = activePath, let s = allStats[p] { stats = s }
            refreshNow()
        }
    }
    @Published var sourceFilter: SourceFilter {
        didSet { UserDefaults.standard.set(sourceFilter.rawValue, forKey: "sourceFilter"); refreshNow() }
    }
    /// 0 = auto. Used for Claude Code, whose logs do not record the context window size.
    @Published var claudeContextWindow: Int {
        didSet { UserDefaults.standard.set(claudeContextWindow, forKey: "claudeContextWindow"); refreshNow() }
    }

    private var tails: [String: SessionTail] = [:]
    private let queue = DispatchQueue(label: "agentpulse.parse", qos: .utility)
    private var timer: Timer?
    private var tick = 0
    private var busy = false

    private init() {
        sourceFilter = SourceFilter(rawValue: UserDefaults.standard.string(forKey: "sourceFilter") ?? "") ?? .all
        claudeContextWindow = UserDefaults.standard.integer(forKey: "claudeContextWindow")
    }

    func start() {
        guard timer == nil else { return }
        rescan()
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    var activePath: String? {
        if let p = pinnedPath { return p }
        return sessions.first { sourceFilter.allows($0.source) }?.path
    }

    private func onTick() {
        tick += 1
        if tick % 3 == 0 { rescan() }
        refreshNow()
    }

    private func rescan() {
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.path, $0.cwd) })
        queue.async {
            var found = SessionDiscovery.discover()
            for i in found.indices {
                found[i].cwd = previous[found[i].path] ?? SessionDiscovery.peekCwd(found[i].path)
            }
            Task { @MainActor in
                if found != self.sessions { self.sessions = found }
            }
        }
    }

    /// Screenshot mode: show the given sessions instead of real ones (no polling).
    func loadDemo(sessions: [SessionRef], stats: [String: SessionStats]) {
        self.sessions = sessions
        allStats = stats
        self.stats = sessions.first.flatMap { stats[$0.path] }
    }

    /// Sessions parsed every tick: the active one plus the most recently written others.
    static let trackedLimit = 8
    var trackedSessions: [SessionRef] { Array(sessions.prefix(Self.trackedLimit)) }

    func refreshNow() {
        guard !busy else { return }
        let active = activePath
        var paths = trackedSessions.map(\.path)
        if let a = active, !paths.contains(a) { paths.append(a) }
        guard !paths.isEmpty else { stats = nil; allStats = [:]; return }

        busy = true
        // Keep parsed state only for tracked sessions.
        tails = tails.filter { paths.contains($0.key) }
        let work: [SessionTail] = paths.map { p in
            let t = tails[p] ?? SessionTail(path: p, source: SessionDiscovery.source(forPath: p))
            tails[p] = t
            return t
        }
        let override = claudeContextWindow > 0 ? claudeContextWindow : nil
        queue.async {
            var snaps: [String: SessionStats] = [:]
            for tail in work {
                tail.poll()
                snaps[tail.path] = tail.parser.acc.snapshot(source: tail.source, path: tail.path,
                                                            contextWindowOverride: tail.source == .claude ? override : nil)
            }
            Task { @MainActor in
                self.busy = false
                self.allStats = snaps
                self.stats = self.activePath.flatMap { snaps[$0] }
            }
        }
    }
}
