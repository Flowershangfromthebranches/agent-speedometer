import AppKit
import SwiftUI

/// Renders the UI to PNG files without opening visible windows.
/// With `demo`, uses made-up sessions so screenshots contain no real project names.
@MainActor
enum PreviewRenderer {
    static func render(to dir: URL, demo: Bool) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let monitor = Monitor.shared

        if demo {
            DemoData.load(into: monitor)
            TokenUsageStore.shared.loadDemo()
        } else {
            // Let the monitor parse the tracked sessions first.
            monitor.start()
            let deadline = Date().addingTimeInterval(8)
            while monitor.stats == nil || monitor.allStats.count < min(2, monitor.sessions.count), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        guard let s = monitor.stats else { print("no session found"); return }

        // Glass can't blur a real desktop here: draw it as a tinted fill over a painted wallpaper.
        // Real windows (not ImageRenderer) so AppKit controls like switches and pickers show up.
        func save<V: View>(_ name: String, _ view: V, wallpaper: Bool = true) {
            let content = view
                .padding(28)
                .background(wallpaper ? AnyView(Wallpaper()) : AnyView(Color(white: 0.08)))
                .environment(\.colorScheme, .dark)
                .environment(\.staticGlass, true)
                .environmentObject(monitor)
                .fixedSize()
            let probe = NSHostingView(rootView: content)
            snapshot(content, size: probe.fittingSize, wait: 0.6, to: dir.appendingPathComponent(name))
        }

        // The floating bar with its speed card open.
        let hero = VStack(alignment: .leading, spacing: -20) {
            HUDDetailCard(seg: .speed, s: s).padding(16)
            HStack(spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: s.source.symbol).font(.system(size: 12, weight: .medium))
                    Text(s.model ?? "").font(.system(size: 12.5))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20)
                StatusBarView(stats: s, active: .speed)
            }
            .padding(6)
            .glassSurface(Capsule())
            .padding(16)
        }
        save("hud.png", hero)

        save("bar.png", StatusBarView(stats: s, active: .speed).padding(6).glassSurface(Capsule()))
        save("sessions.png", SessionListView(compact: false)
            .padding(14).frame(width: 372)
            .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous)))
        let popover = { (m: MenuBarModule) in
            ModulePopoverView(module: m, close: {})
                .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        save("popover-speed.png", popover(.speed))
        save("popover-tokens.png", popover(.tokens))
        save("popover-context.png", popover(.context))
        save("popover-session.png", popover(.session))
        for (name, seg) in [("speed.png", Segment.speed), ("tokens.png", .tokens), ("context.png", .context)] {
            save(name, HUDDetailCard(seg: seg, s: s))
        }

        // The session browser ("更多会话") window.
        if !demo, let ref = monitor.sessions.first, let st = monitor.allStats[ref.path] {
            save("browser-detail.png", SessionDetailView(ref: ref, s: st).environmentObject(monitor).frame(width: 460))
        }
        if !demo {
            snapshot(SessionBrowserView(preselectTool: "deepseek-harness").environmentObject(monitor), size: NSSize(width: 980, height: 620),
                     wait: 2.5, to: dir.appendingPathComponent("browser.png"))
        }

        // Form uses AppKit controls, which ImageRenderer can't draw: snapshot a real hosting view instead.
        // The window background isn't part of the hosting view's snapshot; paint it in.
        func saveSettingsPage(_ page: SettingsPage, name: String, size: NSSize,
                              usageRange: UsageRange? = nil, usageTool: String? = nil) {
            let host = NSHostingView(rootView: SettingsView(page: page,
                                                            usagePreviewRange: usageRange,
                                                            usagePreviewTool: usageTool)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.staticGlass, true)
                .environmentObject(monitor).environmentObject(HUDController.shared).environmentObject(MenuBarModules.shared))
            let win = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: size.width, height: size.height),
                               styleMask: [.titled], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                print("wrote \(name)")
            }
            win.orderOut(nil)
        }
        saveSettingsPage(.display, name: "settings.png", size: NSSize(width: 860, height: 660))
        if demo {
            saveSettingsPage(.usage, name: "settings-usage.png", size: NSSize(width: 860, height: 1440))
            saveSettingsPage(.usage, name: "settings-usage-all.png", size: NSSize(width: 860, height: 1440),
                             usageRange: .all)
            saveSettingsPage(.usage, name: "settings-usage-tool.png", size: NSSize(width: 860, height: 1440),
                             usageRange: .month, usageTool: "claude")
        } else {
            TokenUsageStore.shared.load(range: .month)
            let deadline = Date().addingTimeInterval(30)
            while TokenUsageStore.shared.loading && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            if TokenUsageStore.shared.loaded {
                saveSettingsPage(.usage, name: "settings-usage.png", size: NSSize(width: 860, height: 1440),
                                 usageRange: .month)
            }
        }
    }
}

/// A dark desktop for screenshots, so glass surfaces have something to sit on.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.06, blue: 0.09)
            RadialGradient(colors: [Color(red: 0.14, green: 0.31, blue: 0.48), .clear],
                           center: UnitPoint(x: 0.12, y: 0.18), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.29, green: 0.20, blue: 0.45), .clear],
                           center: UnitPoint(x: 0.9, y: 0.2), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(red: 0.05, green: 0.36, blue: 0.36), .clear],
                           center: UnitPoint(x: 0.55, y: 1.05), startRadius: 0, endRadius: 520)
        }
    }
}

@MainActor
private func snapshot<V: View>(_ view: V, size: NSSize, wait: TimeInterval, to url: URL) {
    let host = NSHostingView(rootView: view)
    let win = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: size.width, height: size.height),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    win.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(wait))
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
    win.orderOut(nil)
}

/// Made-up sessions for screenshots.
@MainActor
enum DemoData {
    static func load(into monitor: Monitor) {
        let now = Date()
        func make(_ source: AgentSource, _ project: String, _ model: String, ago: TimeInterval,
                  turns: Int, steps: Int, tps: Double, ctx: Int, window: Int, generating: TimeInterval? = nil,
                  ttft: TimeInterval? = nil) -> (SessionRef, SessionStats) {
            let path = "/demo/\(project)-\(model).jsonl"
            var s = SessionStats(source: source, path: path)
            s.cwd = "/demo/\(project)"
            s.model = model
            s.turns = turns
            s.steps = steps
            s.recentTPS = tps
            s.lastTPS = tps * 1.06
            s.sessionTPS = tps * 0.93
            let wobble: [Double] = [-0.14, -0.07, -0.12, -0.02, 0.05, -0.04, -0.10, 0.0, 0.08, 0.03,
                                    -0.04, 0.01, 0.06, -0.03, -0.09, 0.04, 0.07, -0.01, 0.02, 0.0]
            s.stepSpeeds = wobble.enumerated().map { i, delta in
                let output = Int(tps * (1 + delta) * 10)
                return StepSpeed(step: steps - wobble.count + i + 1, outputTokens: output,
                                 duration: 10, completedAt: now.addingTimeInterval(-ago - Double(wobble.count - i - 1) * 20))
            }
            s.avgTTFT = ttft
            s.ttftAvailable = ttft != nil
            s.modelTime = Double(steps) * 8.7
            s.toolTime = Double(steps) * 10.3
            s.uncachedInput = steps * 470
            s.cacheWrite = source == .claude ? steps * 9_400 : 0
            s.cacheRead = steps * 282_000
            s.outputTokens = steps * 1_700
            s.contextTokens = ctx
            s.contextWindow = window
            s.lastActivity = now.addingTimeInterval(-ago)
            s.waitingSince = generating.map { now.addingTimeInterval(-$0) }
            if source == .codex {
                s.rateLimitPrimary = RateLimitWindow(usedPercent: 18, windowMinutes: 300, resetsAt: nil)
                s.rateLimitSecondary = RateLimitWindow(usedPercent: 41, windowMinutes: 10080, resetsAt: nil)
            }
            let ref = SessionRef(path: path, source: source, locator: .file(path), modified: s.lastActivity!, cwd: s.cwd)
            return (ref, s)
        }
        let rows = [
            make(.claude, "web-dashboard", "claude-opus-5-5", ago: 2, turns: 3, steps: 223, tps: 112,
                 ctx: 382_000, window: 1_000_000, generating: 12),
            make(.codex, "api-server", "gpt-6.1-sol", ago: 20, turns: 5, steps: 96, tps: 41.5,
                 ctx: 134_000, window: 258_400, ttft: 2.2),
            make(.claude, "ios-app", "claude-sonnet-5-5", ago: 180, turns: 8, steps: 140, tps: 168,
                 ctx: 61_000, window: 200_000),
            make(.codex, "data-pipeline", "gpt-6.1-sol", ago: 720, turns: 2, steps: 47, tps: 36.2,
                 ctx: 98_000, window: 258_400, generating: 41, ttft: 3.1),
            make(AgentSource(id: "opencode"), "docs-site", "deepseek-v4", ago: 240, turns: 4, steps: 31, tps: 245,
                 ctx: 22_000, window: 128_000),
        ]
        let tools = ["claude", "codex", "opencode", "codebuddy", "workbuddy", "stepcode", "cursor"]
            .compactMap(ToolRegistry.spec).map {
                DetectedTool(spec: $0, hasApp: $0.id != "opencode", hasCLI: $0.id != "cursor", hasData: true)
            }
        monitor.loadDemo(tools: tools, sessions: rows.map(\.0), stats: Dictionary(uniqueKeysWithValues: rows.map { ($0.0.path, $0.1) }))
    }
}
