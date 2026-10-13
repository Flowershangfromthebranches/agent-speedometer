import AppKit
import ServiceManagement
import SwiftUI

/// Plain AppKit entry point. Everything lives in the menu-bar modules, the floating bar and
/// our own windows; a SwiftUI `App` would need a scene, and macOS opens an empty
/// "Settings" scene window at launch when that is the only one.
enum AgentPulseApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Not visible for an accessory app, but provides ⌘, / ⌘W / ⌘Q and copy-paste shortcuts.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 AgentPulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        return menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showSettings() {
        Task { @MainActor in SettingsWindow.show() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Monitor.shared.start()
            HUDController.shared.apply()
            MenuBarModules.shared.start()
        }
    }

    /// Opening the app again (Finder, Spotlight, Dock) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in SettingsWindow.show() }
        return false
    }
}

/// A standalone settings window (not attached to the menu bar).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "AgentPulse 设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 680, height: 460)
            w.contentView = NSHostingView(rootView: SettingsView()
                .environmentObject(Monitor.shared)
                .environmentObject(HUDController.shared)
                .environmentObject(MenuBarModules.shared))
            w.center()
            w.setFrameAutosaveName("AgentPulseSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case current, sessions, tools, display, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return "当前会话"
        case .sessions: return "会话与跟随"
        case .tools: return "Agent 工具"
        case .display: return "菜单栏与悬浮条"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .current: return "gauge.with.dots.needle.67percent"
        case .sessions: return "list.bullet"
        case .tools: return "chevron.left.forwardslash.chevron.right"
        case .display: return "menubar.rectangle"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var page: SettingsPage?

    init(page: SettingsPage = .current) {
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(SettingsPage.allCases) { p in
                    Label {
                        HStack {
                            Text(p.title)
                            if p == .tools, !monitor.supportedTools.isEmpty {
                                Spacer()
                                Text("\(monitor.supportedTools.count)").font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: p.symbol)
                    }
                    .tag(Optional(p))
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock")
                    Text(verbatim: "只读本机日志，不联网、不读取凭据与对话内容。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(14)
            }
        } detail: {
            Group {
                switch page ?? .current {
                case .current: CurrentSessionPage()
                case .sessions: SessionsPage()
                case .tools: ToolsPage()
                case .display: DisplayPage()
                case .about: AboutPage()
                }
            }
            .navigationTitle((page ?? .current).title)
        }
        .toggleStyle(.switch)
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// Title above a settings page's content (the window has no visible title bar text).
private struct PageTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 22, weight: .bold)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CurrentSessionPage: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(text: "当前会话")
                if let s = monitor.stats {
                    SessionOverview(s: s)
                    SpeedDetail(s: s, layout: .list)
                } else {
                    Text("还没有运行中的会话，在任一已检测到的 agent 工具里开始对话后会自动出现。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A session's name and its three headline numbers (speed, tokens, context).
struct SessionOverview: View {
    let s: SessionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ToolBadge(symbol: s.source.symbol, generating: s.waitingSince != nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.projectName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text([s.source.displayName, s.model].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ActivityLabel(s: s)
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    OverviewTile(label: "输出速度（近 5 步）", value: Fmt.tpsNumber(s.recentTPS), unit: "tok/s")
                    OverviewTile(label: "Token · 缓存命中", value: Fmt.compactTokens(s.totalTokens),
                                 unit: Fmt.percent(s.cacheHitRate), unitColor: Theme.accent)
                    OverviewTile(label: "上下文 · \(Fmt.compactTokens(s.contextTokens)) / \(s.contextWindow.map(Fmt.compactTokens) ?? "?")",
                                 value: Fmt.percent(s.contextFraction, digits: 0), bar: s.contextFraction)
                }
            }
        }
    }
}

struct OverviewTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var unitColor: Color = .secondary
    var bar: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 26, weight: .semibold).monospacedDigit()).tracking(-0.6)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit { Text(unit).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(unitColor) }
            }
            if let bar {
                GeometryReader { g in MiniBar(fraction: bar, width: g.size.width, height: 6) }.frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}

private struct SessionsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageTitle(text: "会话与跟随")
                SessionListView(compact: true)
                Footnote(text: "也可以在任意菜单栏模块的详情页、或点击悬浮条左侧的模型名来切换。")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ToolsPage: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        Form {
            Section {
                ForEach(monitor.supportedTools) { t in
                    HStack(spacing: 10) {
                        ToolBadge(symbol: t.spec.symbol, size: 28)
                        Text(t.spec.name)
                        Text(t.installKinds).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.live)
                    }
                }
                if monitor.supportedTools.isEmpty {
                    Text(monitor.scanning ? "扫描中…" : "还没有检测到可读取的工具").foregroundStyle(.secondary)
                }
            } header: {
                Text("已适配")
            }

            let others = monitor.tools.filter { !$0.supported }
            if !others.isEmpty {
                Section("已检测到，暂无法读取") {
                    ForEach(others) { t in
                        HStack(spacing: 10) {
                            ToolBadge(symbol: t.spec.symbol, size: 28).opacity(0.6)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(t.spec.name)
                                    Text(t.installKinds).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(t.spec.note ?? "暂不支持读取这个工具的会话")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button(monitor.scanning ? "扫描中…" : "重新扫描") { monitor.rescanTools() }
                        .disabled(monitor.scanning)
                    Spacer()
                    Button("查看全部会话…") { SessionBrowser.show() }
                }
            } footer: {
                Text("启动时扫描 /Applications、常见 CLI 安装目录和各工具的数据目录，只判断是否存在，不运行任何程序。")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplayPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var hud: HUDController
    @EnvironmentObject var modules: MenuBarModules
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                MenuBarPreview(enabled: MenuBarModule.allCases.filter(modules.isOn), stats: monitor.stats)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                ForEach(MenuBarModule.allCases) { m in
                    Toggle(isOn: modules.binding(m)) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raisedFill)
                                .frame(width: 26, height: 26)
                                .overlay(Image(systemName: m.symbol).font(.system(size: 12, weight: .medium)))
                            Text(m.label)
                            Text(m.sample(monitor.stats))
                                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                    // Keep at least one module so the details and settings stay reachable.
                    .disabled(modules.isOn(m) && modules.enabled.count == 1)
                }
            } header: {
                Text("顶部菜单栏模块")
            } footer: {
                Text("每个模块单独显示在菜单栏，点击可看详情、切换会话和打开设置。至少保留一个；按住 ⌘ 拖动可调整顺序。")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("显示与启动") {
                Toggle(isOn: $hud.visible) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示悬浮条")
                        Text("始终置顶，不抢焦点").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("数据") {
                Picker("Claude 上下文窗口", selection: $monitor.claudeContextWindow) {
                    Text("自动").tag(0)
                    Text("200K").tag(200_000)
                    Text("1M").tag(1_000_000)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A strip of desktop with the enabled modules as they'd appear in the menu bar.
private struct MenuBarPreview: View {
    let enabled: [MenuBarModule]
    let stats: SessionStats?

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            ForEach(enabled) { m in
                HStack(spacing: 4) {
                    if m != .speed { Image(systemName: m.symbol).font(.system(size: 10.5)) }
                    Text(m.sample(stats))
                }
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            Text(Date.now.formatted(date: .omitted, time: .shortened)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 6)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        .padding(.horizontal, 12)
        .frame(height: 56, alignment: .top)
        .padding(.top, 8)
        .background(
            ZStack {
                Color(red: 0.08, green: 0.14, blue: 0.23)
                RadialGradient(colors: [Color(red: 0.16, green: 0.34, blue: 0.51), .clear],
                               center: UnitPoint(x: 0.2, y: 0), startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Color(red: 0.29, green: 0.20, blue: 0.45), .clear],
                               center: UnitPoint(x: 0.9, y: 0), startRadius: 0, endRadius: 220)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("菜单栏预览：" + enabled.map(\.label).joined(separator: "、"))
    }
}

private struct AboutPage: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text("AgentPulse").font(.system(size: 22, weight: .bold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                .foregroundStyle(.secondary)
            Text(verbatim: "给本机的 agent 工具加上实时 tok/s 速度表。\n只读本机日志，不联网、不读取凭据与对话内容。")
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Button("退出 AgentPulse") { NSApp.terminate(nil) }
                .controlSize(.large)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
