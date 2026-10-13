import Foundation
import Combine

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    /// A session counts as running if its log was written within this window.
    static let runningWindow: TimeInterval = 10 * 60

    /// Agent tools found on this Mac (scanned at launch and on demand).
    @Published private(set) var tools: [DetectedTool] = []
    @Published private(set) var scanning = false
    /// Stats of the session shown in the bar and menu bar.
    @Published private(set) var stats: SessionStats?
    /// Live stats for tracked sessions (running ones plus the pinned one), keyed by path.
    @Published private(set) var allStats: [String: SessionStats] = [:]
    /// Recent top-level sessions of all supported tools (last 3 days), newest first.
    @Published private(set) var sessions: [SessionRef] = []
    @Published private(set) var pinnedPath: String?
    /// Restrict auto-follow to one tool id ("" = any tool).
    @Published var autoFollowTool: String {
        didSet { UserDefaults.standard.set(autoFollowTool, forKey: "autoFollowTool"); refreshNow() }
    }
    /// 0 = auto. Used for Claude Code, whose logs do not record the context window size.
    @Published var claudeContextWindow: Int {
        didSet { UserDefaults.standard.set(claudeContextWindow, forKey: "claudeContextWindow"); refreshNow() }
    }

    private var readers: [String: SessionReader] = [:]
    /// The pinned session's ref, which may be older than the recent list (pinned from the browser).
    private var pinnedRef: SessionRef?
    private let queue = DispatchQueue(label: "agentpulse.parse", qos: .utility)
    private let browseQueue = DispatchQueue(label: "agentpulse.browse", qos: .userInitiated)
    private var timer: Timer?
    private var tick = 0
    private var busy = false
    private var discovering = false
    private var demo = false

    private init() {
        autoFollowTool = UserDefaults.standard.string(forKey: "autoFollowTool") ?? ""
        claudeContextWindow = UserDefaults.standard.integer(forKey: "claudeContextWindow")
    }

    func start() {
        guard timer == nil, !demo else { return }
        rescanTools()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    // MARK: Tools

    /// Looks for installed agent tools (apps, CLIs, data folders), then their sessions.
    func rescanTools() {
        scanning = true
        queue.async {
            let found = ToolScanner.scan()
            Task { @MainActor in
                self.tools = found
                self.scanning = false
                self.discover()
            }
        }
    }

    var supportedTools: [DetectedTool] { tools.filter(\.supported) }

    // MARK: Session lists

    /// Sessions written to recently: the agent is (or just was) working on them.
    var runningSessions: [SessionRef] {
        let cutoff = Date().addingTimeInterval(-Self.runningWindow)
        return sessions.filter { ref in
            ref.modified > cutoff || allStats[ref.path]?.waitingSince != nil
        }
    }

    var pinnedSession: SessionRef? {
        guard let p = pinnedPath else { return nil }
        return sessions.first { $0.path == p } ?? pinnedRef
    }

    var activePath: String? {
        if let p = pinnedPath { return p }
        let allowed = sessions.filter { autoFollowTool.isEmpty || $0.source.id == autoFollowTool }
        let cutoff = Date().addingTimeInterval(-Self.runningWindow)
        return (allowed.first { $0.modified > cutoff } ?? allowed.first)?.path
    }

    func pin(_ ref: SessionRef) {
        pinnedRef = ref
        setPinned(ref.path)
    }

    func unpin() { setPinned(nil) }

    private func setPinned(_ path: String?) {
        guard path != pinnedPath else { return }
        pinnedPath = path
        // Switch instantly using already-parsed stats, then refresh.
        if let p = activePath, let s = allStats[p] { stats = s }
        refreshNow()
    }

    // MARK: Polling

    private func onTick() {
        tick += 1
        if tick % 10 == 0 { discover() }  // new sessions; running ones refresh every tick
        refreshNow()
    }

    private func discover() {
        guard !discovering, !demo else { return }
        discovering = true
        let specs = supportedTools.map(\.spec)
        let since = Date().addingTimeInterval(-3 * 86400)
        queue.async {
            let found = specs.flatMap { SessionDiscovery.sessions(for: $0, since: since, limit: 60) }
                .filter { !$0.isSubagent }
                .sorted { $0.modified > $1.modified }
            Task { @MainActor in
                self.discovering = false
                if found != self.sessions { self.sessions = found }
            }
        }
    }

    func refreshNow() {
        guard !busy, !demo else { return }
        var refs = runningSessions
        if let a = activePath, !refs.contains(where: { $0.path == a }),
           let ref = sessions.first(where: { $0.path == a }) ?? pinnedSession {
            refs.append(ref)
        }
        guard !refs.isEmpty else { stats = nil; allStats = [:]; return }

        busy = true
        let paths = Set(refs.map(\.path))
        readers = readers.filter { paths.contains($0.key) }
        let work: [SessionReader] = refs.compactMap { ref in
            if let r = readers[ref.path] { return r }
            let r = Readers.make(ref)
            readers[ref.path] = r
            return r
        }
        let override = claudeContextWindow > 0 ? claudeContextWindow : nil
        queue.async {
            var snaps: [String: SessionStats] = [:]
            for reader in work {
                snaps[reader.ref.path] = reader.refresh(contextWindowOverride: override)
            }
            Task { @MainActor in
                self.busy = false
                self.allStats = snaps
                self.stats = self.activePath.flatMap { snaps[$0] }
            }
        }
    }

    // MARK: Session browser

    /// All sessions of one tool (including sub-agents), newest first.
    func listSessions(tool: String, completion: @escaping ([SessionRef]) -> Void) {
        guard let spec = ToolRegistry.spec(tool) else { completion([]); return }
        browseQueue.async {
            let refs = SessionDiscovery.sessions(for: spec, since: nil, limit: 300)
            Task { @MainActor in completion(refs) }
        }
    }

    /// Full stats for any session, parsed on demand.
    func loadStats(_ ref: SessionRef, cached: Bool = true, completion: @escaping (SessionStats?) -> Void) {
        if cached, let s = allStats[ref.path] { completion(s); return }
        let override = claudeContextWindow > 0 ? claudeContextWindow : nil
        browseQueue.async {
            let s = Readers.make(ref)?.refresh(contextWindowOverride: override)
            Task { @MainActor in completion(s) }
        }
    }

    /// Most recently written session of any supported tool (for `--dump`).
    nonisolated static func latestForDump() -> String? {
        ToolScanner.scan().filter(\.supported)
            .flatMap { SessionDiscovery.sessions(for: $0.spec, since: Date().addingTimeInterval(-86400), limit: 5) }
            .filter { !$0.isSubagent }
            .max { $0.modified < $1.modified }?.path
    }

    // MARK: Screenshots

    /// Screenshot mode: show the given sessions instead of real ones (no polling).
    func loadDemo(tools: [DetectedTool], sessions: [SessionRef], stats: [String: SessionStats]) {
        demo = true
        self.tools = tools
        self.sessions = sessions
        allStats = stats
        self.stats = sessions.first.flatMap { stats[$0.path] }
    }
}
