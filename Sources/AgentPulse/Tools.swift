import Foundation

/// How a tool stores its sessions locally. `nil` on a spec means we can detect the tool
/// but its local data has nothing we can turn into speed / token stats.
enum LogFormat {
    case claudeCode       // ~/.claude/projects/*/*.jsonl
    case codex            // ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
    case codebuddy        // CodeBuddy / WorkBuddy: projects/*/*.jsonl (agent items + providerData.usage)
    case pi               // pi-agent family (StepCode, pi): agent/sessions/*/*.jsonl
    case opencodeDB       // opencode family: SQLite `session` + `message` tables
    case deepseekHarness  // DeepSeek Harness: per-session JSON snapshot with precomputed stats
    case zcode            // ZCode CLI: rollout/model-io-*.jsonl
    case antigravity      // Antigravity: brain/*/.system_generated/logs/transcript.jsonl (tokens only)
}

/// A known agent tool: how to detect it and where its sessions live.
struct AgentToolSpec: Identifiable {
    let id: String
    let name: String
    var symbol: String = "terminal"
    /// App bundle names looked up in /Applications and ~/Applications.
    var apps: [String] = []
    /// CLI executable names looked up in common install directories.
    var clis: [String] = []
    /// Paths relative to the home directory whose presence means the tool has been used.
    var dataPaths: [String] = []
    var format: LogFormat?
    /// Where sessions are discovered (relative to home). Meaning depends on `format`.
    var sessionRoots: [String] = []
    /// Shown for tools without a usable format.
    var note: String? = nil
}

/// Identifies which tool a session belongs to.
struct AgentSource: Hashable {
    let id: String
    static let claude = AgentSource(id: "claude")
    static let codex = AgentSource(id: "codex")

    var spec: AgentToolSpec? { ToolRegistry.spec(id) }
    var displayName: String { spec?.name ?? id }
    var symbol: String { spec?.symbol ?? "terminal" }
}

enum ToolRegistry {
    static let noUsage = "本地日志不记录 token 用量，无法计算速度"
    static let noLocalData = "没有在本机找到可读取的会话记录"
    static let notAdapted = "暂未适配（本机没有该工具的会话样本）"

    static let all: [AgentToolSpec] = [
        // Supported: local logs carry token usage.
        AgentToolSpec(id: "claude", name: "Claude Code", symbol: "sparkle",
                      apps: ["Claude.app"], clis: ["claude"], dataPaths: [".claude/projects"],
                      format: .claudeCode, sessionRoots: [".claude/projects"]),
        AgentToolSpec(id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
                      apps: ["Codex.app"], clis: ["codex"], dataPaths: [".codex/sessions"],
                      format: .codex, sessionRoots: [".codex/sessions"]),
        AgentToolSpec(id: "deepseek-harness", name: "DeepSeek Harness", symbol: "fish",
                      apps: ["DeepSeek Harness.app"], clis: ["dsh"], dataPaths: [".dsh"],
                      format: .deepseekHarness, sessionRoots: [".dsh/storages/session_projcache/sessions"]),
        AgentToolSpec(id: "opencode", name: "opencode", symbol: "curlybraces",
                      apps: ["OpenCode.app"], clis: ["opencode"], dataPaths: [".local/share/opencode"],
                      format: .opencodeDB, sessionRoots: [".local/share/opencode/opencode.db"]),
        AgentToolSpec(id: "mimocode", name: "MiMo Code", symbol: "curlybraces",
                      clis: ["mimo", "mimocode"], dataPaths: [".local/share/mimocode"],
                      format: .opencodeDB, sessionRoots: [".local/share/mimocode/mimocode.db"]),
        AgentToolSpec(id: "codebuddy", name: "CodeBuddy", symbol: "person.2",
                      apps: ["CodeBuddy.app", "CodeBuddy CN.app"], clis: ["codebuddy"],
                      dataPaths: [".codebuddy", ".codebuddycn"],
                      format: .codebuddy, sessionRoots: [".codebuddy/projects", ".codebuddycn/projects"]),
        AgentToolSpec(id: "workbuddy", name: "WorkBuddy", symbol: "briefcase",
                      apps: ["WorkBuddy.app", "WorkBuddy AI.app"], dataPaths: [".workbuddy"],
                      format: .codebuddy, sessionRoots: [".workbuddy/projects"]),
        AgentToolSpec(id: "stepcode", name: "StepCode", symbol: "figure.walk",
                      clis: ["stepcode"], dataPaths: [".stepcode"],
                      format: .pi, sessionRoots: [".stepcode/agent/sessions"]),
        AgentToolSpec(id: "pi", name: "pi", symbol: "number",
                      clis: ["pi"], dataPaths: [".pi/agent"],
                      format: .pi, sessionRoots: [".pi/agent/sessions"]),
        AgentToolSpec(id: "zcode", name: "ZCode", symbol: "z.square",
                      apps: ["ZCode.app"], clis: ["zcode"], dataPaths: [".zcode"],
                      format: .zcode, sessionRoots: [".zcode/cli/rollout"]),
        AgentToolSpec(id: "antigravity", name: "Antigravity", symbol: "arrow.up.circle",
                      apps: ["Antigravity.app"], clis: ["agy", "antigravity"],
                      dataPaths: [".gemini/antigravity", ".gemini/antigravity-cli"],
                      format: .antigravity,
                      sessionRoots: [".gemini/antigravity-cli/brain", ".gemini/antigravity/brain"]),

        // Detected only.
        AgentToolSpec(id: "qoder", name: "Qoder", symbol: "q.square",
                      apps: ["Qoder.app", "Qoder CN.app"], clis: ["qodercli", "qoder"],
                      dataPaths: [".qoder", ".qoder-cn", ".qoder-cli"],
                      note: "本地日志里的 token 用量全部为 0，无法计算速度"),
        AgentToolSpec(id: "gemini-cli", name: "Gemini CLI", symbol: "diamond", clis: ["gemini"],
                      dataPaths: [".gemini/tmp"], note: notAdapted),
        AgentToolSpec(id: "qwen", name: "Qwen Code", symbol: "q.circle", clis: ["qwen"],
                      dataPaths: [".qwen"], note: notAdapted),
        AgentToolSpec(id: "iflow", name: "iFlow CLI", symbol: "wind", clis: ["iflow"],
                      dataPaths: [".iflow"], note: notAdapted),
        AgentToolSpec(id: "kimi", name: "Kimi", symbol: "moon",
                      apps: ["Kimi.app"], clis: ["kimi"],
                      dataPaths: [".kimi", "Library/Application Support/kimi-desktop"], note: noUsage),
        AgentToolSpec(id: "commandcode", name: "Command Code", symbol: "command",
                      apps: ["Command Code.app"], clis: ["commandcode"], dataPaths: [".commandcode"],
                      note: noUsage),
        AgentToolSpec(id: "grok", name: "Grok CLI", symbol: "xmark.circle",
                      apps: ["Grok Bot.app"], clis: ["grok"], dataPaths: [".grok"], note: noUsage),
        AgentToolSpec(id: "cursor", name: "Cursor", symbol: "cursorarrow",
                      apps: ["Cursor.app"], clis: ["cursor-agent"],
                      dataPaths: [".cursor", ".local/share/cursor-agent"], note: noLocalData),
        AgentToolSpec(id: "trae", name: "Trae", symbol: "t.square",
                      apps: ["Trae.app", "Trae CN.app"], clis: ["trae", "trae-cli"],
                      dataPaths: [".trae", ".trae-cn", ".traecli", ".local/share/trae-cli"], note: noLocalData),
        AgentToolSpec(id: "kiro", name: "Kiro", symbol: "k.square",
                      apps: ["Kiro.app"], clis: ["kiro"], dataPaths: [".kiro"], note: noLocalData),
        AgentToolSpec(id: "windsurf", name: "Windsurf", symbol: "wind",
                      apps: ["Windsurf.app"], dataPaths: [".windsurf", ".codeium"], note: noLocalData),
        AgentToolSpec(id: "copilot", name: "GitHub Copilot CLI", symbol: "airplane",
                      clis: ["copilot"], dataPaths: [".copilot"], note: noLocalData),
        AgentToolSpec(id: "factory", name: "Factory Droid", symbol: "gearshape.2",
                      clis: ["droid"], dataPaths: [".factory"], note: noLocalData),
        AgentToolSpec(id: "crush", name: "Crush", symbol: "heart",
                      clis: ["crush"], dataPaths: [".crush"], note: noLocalData),
        AgentToolSpec(id: "goose", name: "Goose", symbol: "bird",
                      clis: ["goose"], dataPaths: [".goose"], note: noLocalData),
        AgentToolSpec(id: "devin", name: "Devin", symbol: "d.square",
                      apps: ["Devin.app"], clis: ["devin"], dataPaths: [".devin", ".local/share/devin"],
                      note: noLocalData),
        AgentToolSpec(id: "minimax", name: "MiniMax Code", symbol: "m.square",
                      apps: ["MiniMax Code.app"], dataPaths: [".minimax", ".mavis"], note: noLocalData),
        AgentToolSpec(id: "aider", name: "Aider", symbol: "a.square",
                      clis: ["aider"], dataPaths: [".aider"], note: noLocalData),
        AgentToolSpec(id: "cline", name: "Cline", symbol: "c.square",
                      clis: ["cline"], dataPaths: [".cline"], note: noLocalData),
        AgentToolSpec(id: "openhands", name: "OpenHands", symbol: "hand.raised",
                      clis: ["openhands"], dataPaths: [".openhands"], note: noLocalData),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static func spec(_ id: String) -> AgentToolSpec? { byID[id] }

    /// Which supported tool a log file path belongs to (for `--dump`).
    static func source(forPath path: String) -> AgentSource? {
        let home = SessionDiscovery.home.path
        for spec in all where spec.format != nil {
            for root in spec.sessionRoots where path.hasPrefix(home + "/" + root) {
                return AgentSource(id: spec.id)
            }
        }
        return nil
    }
}

/// A tool found on this Mac.
struct DetectedTool: Identifiable, Equatable {
    var id: String { spec.id }
    let spec: AgentToolSpec
    var hasApp: Bool
    var hasCLI: Bool
    var hasData: Bool

    var supported: Bool { spec.format != nil }
    var installKinds: String {
        var k: [String] = []
        if hasApp { k.append("桌面端") }
        if hasCLI { k.append("CLI") }
        if k.isEmpty { k.append("有本地数据") }
        return k.joined(separator: " · ")
    }

    static func == (a: DetectedTool, b: DetectedTool) -> Bool {
        a.id == b.id && a.hasApp == b.hasApp && a.hasCLI == b.hasCLI && a.hasData == b.hasData
    }
}

/// Finds installed agent tools by looking for app bundles, CLI executables and data folders.
/// Only checks whether paths exist; nothing is executed or read.
enum ToolScanner {
    static func scan() -> [DetectedTool] {
        let fm = FileManager.default
        let home = SessionDiscovery.home.path
        let appDirs = ["/Applications", home + "/Applications"]
        var binDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                       home + "/.local/bin", home + "/bin", home + "/.bun/bin", home + "/.npm-global/bin",
                       home + "/.cargo/bin", home + "/.volta/bin", home + "/Library/pnpm",
                       home + "/.opencode/bin", home + "/.deno/bin"]
        // Node version managers keep one bin directory per installed version.
        for base in [home + "/.nvm/versions/node", home + "/.local/share/fnm/node-versions"] {
            for v in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                binDirs.append("\(base)/\(v)/bin")
                binDirs.append("\(base)/\(v)/installation/bin")
            }
        }

        return ToolRegistry.all.compactMap { spec in
            let hasApp = spec.apps.contains { app in appDirs.contains { fm.fileExists(atPath: "\($0)/\(app)") } }
            let hasCLI = spec.clis.contains { cli in binDirs.contains { fm.isExecutableFile(atPath: "\($0)/\(cli)") } }
            let hasData = spec.dataPaths.contains { fm.fileExists(atPath: "\(home)/\($0)") }
            guard hasApp || hasCLI || hasData else { return nil }
            return DetectedTool(spec: spec, hasApp: hasApp, hasCLI: hasCLI, hasData: hasData)
        }
        .sorted { a, b in
            if a.supported != b.supported { return a.supported }
            return a.spec.name.localizedCaseInsensitiveCompare(b.spec.name) == .orderedAscending
        }
    }
}
