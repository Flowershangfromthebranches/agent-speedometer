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
        case .speed: return "速度"
        case .tokens: return "Token 用量"
        case .context: return "上下文占用"
        }
    }

    var symbol: String {
        switch self {
        case .session: return "sparkle"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .tokens: return "cylinder.split.1x2"
        case .context: return "circle.dashed"
        }
    }

    /// What the module would show in the menu bar for these stats (settings preview).
    func sample(_ s: SessionStats?) -> String {
        switch self {
        case .session: return s?.model ?? s?.source.displayName ?? "AgentPulse"
        case .speed: return s.map { $0.speedText($0.displayRecentSpeed) } ?? "— tok/s"
        case .tokens: return s.map { "\($0.usageValue) \($0.usageUnit)" } ?? "—"
        case .context: return Fmt.percent(s?.contextFraction, digits: 0)
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
        case .speed:
            // Text only, to keep the menu bar compact.
            add(s.map { $0.speedText($0.displayRecentSpeed) } ?? "— tok/s")
        case .tokens:
            if let s { add(" \(s.usageValue) \(s.usageUnit)") } else { add(" —") }
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
        case .session:
            // A pinned session shows a pin in place of the tool icon.
            if Monitor.shared.pinnedPath != nil { return symbol("pin.fill") }
            return symbol(s?.source.symbol ?? "gauge.with.dots.needle.67percent")
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
/// settings, then the details, with a switcher between speed, tokens and context.
struct ModulePopoverView: View {
    @EnvironmentObject var monitor: Monitor
    let module: MenuBarModule
    var close: () -> Void

    @State private var choosingSession = false
    @State private var tab: Segment

    init(module: MenuBarModule, close: @escaping () -> Void) {
        self.module = module
        self.close = close
        switch module {
        case .tokens: _tab = State(initialValue: .tokens)
        case .context: _tab = State(initialValue: .context)
        default: _tab = State(initialValue: .speed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if module == .session {
                HStack(alignment: .center) {
                    SessionListHeader()
                    Spacer(minLength: 8)
                    settingsButton(size: 36)
                }
                SessionListView(compact: true, onPick: close)
            } else {
                HStack(spacing: 8) {
                    sessionButton
                    settingsButton(size: 44)
                }
                if choosingSession {
                    SessionListView(compact: true, onPick: { choosingSession = false })
                } else {
                    SegmentedTabs(items: [(.speed, "速度"), (.tokens, "Token"), (.context, "上下文")], selection: $tab)
                    if let s = monitor.stats {
                        CardFor(seg: tab, s: s)
                    } else {
                        Text("还没有找到最近的会话")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sessionButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { choosingSession.toggle() }
        } label: {
            HStack(spacing: 10) {
                ToolBadge(symbol: monitor.stats?.source.symbol ?? "gauge.with.dots.needle.67percent",
                          generating: monitor.stats?.waitingSince != nil, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(monitor.stats?.projectName ?? "选择会话")
                            .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        if monitor.pinnedPath != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    }
                    if let s = monitor.stats {
                        Text([s.source.displayName, s.model].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: choosingSession ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 44)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("切换要查看的会话")
    }

    private func settingsButton(size: CGFloat) -> some View {
        CircleButton(symbol: "gearshape", size: size, help: "打开设置") {
            close()
            SettingsWindow.show()
        }
    }
}

/// "切换会话" with running / generating counts.
struct SessionListHeader: View {
    @EnvironmentObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("切换会话").font(.system(size: 15, weight: .semibold))
            Text("\(monitor.runningSessions.count) 个运行中 · \(monitor.allStats.values.filter { $0.waitingSince != nil }.count) 个生成中")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }
}
