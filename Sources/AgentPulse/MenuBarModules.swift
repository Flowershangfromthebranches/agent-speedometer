import AppKit
import Combine
import SwiftUI

/// Each module of the bar can live in the menu bar as its own status item.
enum MenuBarModule: String, CaseIterable, Identifiable {
    case session, speed, tokens, context
    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "会话 / 模型名"
        case .speed: return "速度（tok/s）"
        case .tokens: return "Token 用量"
        case .context: return "上下文占用"
        }
    }

    var defaultEnabled: Bool { self == .speed }
    fileprivate var defaultsKey: String { "menubar.\(rawValue)" }
}

@MainActor
final class MenuBarModules: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = MenuBarModules()

    @Published private(set) var enabled: Set<MenuBarModule>

    private var items: [MenuBarModule: NSStatusItem] = [:]
    private var popover: NSPopover?
    private var popoverModule: MenuBarModule?
    private var lastTitles: [MenuBarModule: NSAttributedString] = [:]
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        let d = UserDefaults.standard
        let on = Set(MenuBarModule.allCases.filter { d.object(forKey: $0.defaultsKey) as? Bool ?? $0.defaultEnabled })
        enabled = on.isEmpty ? [.speed] : on
        super.init()
    }

    func start() {
        apply()
        Monitor.shared.$stats
            .combineLatest(Monitor.shared.$pinnedPath)
            .receive(on: RunLoop.main)
            .sink { [weak self] stats, _ in self?.update(stats) }
            .store(in: &cancellables)
        // Keep the generating timer ticking even when nothing else changes.
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.update(Monitor.shared.stats) }
            .store(in: &cancellables)
    }

    func isOn(_ m: MenuBarModule) -> Bool { enabled.contains(m) }

    func set(_ m: MenuBarModule, _ on: Bool) {
        // At least one module must stay: it is the way to reach details and settings.
        if !on, enabled == [m] { return }
        if on { enabled.insert(m) } else { enabled.remove(m) }
        UserDefaults.standard.set(on, forKey: m.defaultsKey)
        apply()
    }

    func binding(_ m: MenuBarModule) -> Binding<Bool> {
        Binding(get: { self.isOn(m) }, set: { self.set(m, $0) })
    }

    private func apply() {
        // Status items added later appear further left, so add in reverse display order.
        for m in MenuBarModule.allCases.reversed() {
            if enabled.contains(m), items[m] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "agentpulse.\(m.rawValue)"
                if let b = item.button {
                    b.target = self
                    b.action = #selector(clicked(_:))
                    b.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
                    b.imagePosition = .imageLeading
                    b.toolTip = m.label
                }
                items[m] = item
                lastTitles[m] = nil
            } else if !enabled.contains(m), let item = items[m] {
                if popoverModule == m { popover?.performClose(nil) }
                NSStatusBar.system.removeStatusItem(item)
                items[m] = nil
            }
        }
        update(Monitor.shared.stats)
    }

    // MARK: Rendering

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func update(_ s: SessionStats?) {
        for (m, item) in items {
            guard let button = item.button else { continue }
            let title = Self.title(m, s)
            if lastTitles[m] != title {
                button.attributedTitle = title
                lastTitles[m] = title
            }
            button.image = Self.image(m, s)
        }
    }

    private static func title(_ m: MenuBarModule, _ s: SessionStats?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0]
            if let color { attrs[.foregroundColor] = color }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        switch m {
        case .session:
            var name = s?.model ?? s?.source.displayName ?? "AgentPulse"
            if name.count > 22 { name = String(name.prefix(21)) + "…" }
            add(" " + name)
            if Monitor.shared.pinnedPath != nil { add(" 📌") }
        case .speed:
            // Text only, to keep the menu bar compact.
            add(Fmt.tps(s?.recentTPS))
        case .tokens:
            if let s { add(" \(Fmt.compactTokens(s.totalTokens)) · \(Fmt.percent(s.cacheHitRate))") } else { add(" —") }
        case .context:
            add(" " + Fmt.percent(s?.contextFraction, digits: 0))
        }
        return out
    }

    private static func image(_ m: MenuBarModule, _ s: SessionStats?) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        func symbol(_ name: String) -> NSImage? {
            let img = NSImage(systemSymbolName: name, accessibilityDescription: m.label)?.withSymbolConfiguration(cfg)
            img?.isTemplate = true
            return img
        }
        switch m {
        case .session: return symbol(s?.source == .codex ? "chevron.left.forwardslash.chevron.right" : "sparkle")
        case .speed: return nil
        case .tokens: return symbol("cylinder.split.1x2")
        case .context: return ringImage(s?.contextFraction ?? 0)
        }
    }

    private static func ringImage(_ fraction: Double) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size, flipped: false) { rect in
            let r = rect.insetBy(dx: 1.75, dy: 1.75)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.001, min(1, fraction))), clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Popovers

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let m = MenuBarModule(rawValue: raw) else { return }
        if let p = popover, p.isShown {
            p.performClose(nil)
            if popoverModule == m { return }
        }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let host = NSHostingController(rootView: ModulePopoverView(module: m) { [weak p] in p?.performClose(nil) }
            .environmentObject(Monitor.shared))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        popover = p
        popoverModule = m
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.popover = nil
            self.popoverModule = nil
        }
    }
}

/// What a menu-bar module shows when clicked: a header to switch sessions or open
/// settings, then the module's details.
struct ModulePopoverView: View {
    @EnvironmentObject var monitor: Monitor
    let module: MenuBarModule
    var close: () -> Void

    @State private var choosingSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if module == .session || choosingSession {
                SessionListView(compact: true, onPick: {
                    if module == .session { close() } else { choosingSession = false }
                })
                .padding(.horizontal, -8)
                if module != .session { Divider() }
            }
            if module != .session {
                if let s = monitor.stats {
                    CardFor(seg: segment, s: s)
                } else {
                    Text("还没有找到最近的会话").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: module == .session ? 380 : 330)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if module == .session {
                Text("选择会话").font(.system(size: 13, weight: .semibold))
            } else {
                Button { choosingSession.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(monitor.stats.map { "\($0.projectName) · \($0.source.displayName)" } ?? "选择会话")
                            .lineLimit(1)
                        if monitor.pinnedPath != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                        Image(systemName: choosingSession ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("切换要查看的会话")
            }
            Spacer(minLength: 8)
            Button {
                close()
                SettingsWindow.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置")
        }
    }

    private var segment: Segment {
        switch module {
        case .speed: return .speed
        case .tokens: return .tokens
        case .context: return .context
        case .session: return .sessions
        }
    }
}
