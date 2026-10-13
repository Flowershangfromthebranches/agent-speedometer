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
        } else {
            // Let the monitor parse the tracked sessions first.
            monitor.start()
            let deadline = Date().addingTimeInterval(8)
            while monitor.stats == nil || monitor.allStats.count < min(2, monitor.sessions.count), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        guard let s = monitor.stats else { print("no session found"); return }

        func save<V: View>(_ name: String, _ view: V, background: Color = Color(white: 0.08)) {
            let r = ImageRenderer(content: view.padding(12).background(background).environment(\.colorScheme, .dark))
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent(name))
            print("wrote \(name)")
        }

        // The floating bar with its speed card open, on a desktop-like backdrop.
        let hero = VStack(alignment: .leading, spacing: 8) {
            CardFor(seg: .speed, s: s)
                .padding(16)
                .background(hudBackground(radius: 14))
            HStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
                    Text(s.model ?? "").font(.system(size: 11.5))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                StatusBarView(stats: s, active: .speed)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hudBackground(radius: 11))
        }
        .padding(28)
        .fixedSize()
        save("hud.png", hero, background: Color(red: 0.16, green: 0.20, blue: 0.27))

        save("bar.png", StatusBarView(stats: s, active: .speed).fixedSize())
        save("sessions.png", SessionListView(compact: false).environmentObject(monitor)
            .padding(12).frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13))))
        let popover = { (m: MenuBarModule) in
            ModulePopoverView(module: m, close: {}).environmentObject(monitor)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.2)))
        }
        save("popover-speed.png", popover(.speed))
        save("popover-tokens.png", popover(.tokens))
        save("popover-context.png", popover(.context))
        save("popover-session.png", popover(.session))
        for (name, seg) in [("speed.png", Segment.speed), ("tokens.png", .tokens), ("context.png", .context)] {
            save(name, CardFor(seg: seg, s: s).padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.13))))
        }

        // Form uses AppKit controls, which ImageRenderer can't draw: snapshot a real hosting view instead.
        let host = NSHostingView(rootView: SettingsView()
            .environmentObject(monitor).environmentObject(HUDController.shared).environmentObject(MenuBarModules.shared))
        let win = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 460, height: demo ? 1170 : 1100),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
            print("wrote settings.png")
        }
        win.orderOut(nil)
    }
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
            let ref = SessionRef(path: path, source: source, modified: s.lastActivity!, cwd: s.cwd)
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
            make(.claude, "docs-site", "claude-haiku-5-5", ago: 3_900, turns: 4, steps: 31, tps: 245,
                 ctx: 22_000, window: 200_000),
        ]
        monitor.loadDemo(sessions: rows.map(\.0), stats: Dictionary(uniqueKeysWithValues: rows.map { ($0.0.path, $0.1) }))
    }
}
