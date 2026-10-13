import AppKit
import ServiceManagement
import SwiftUI

struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Everything lives in the menu-bar modules, the floating bar and the settings window.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "AgentPulse 设置"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 420, height: 420)
            w.contentView = NSHostingView(rootView: SettingsView()
                .environmentObject(Monitor.shared)
                .environmentObject(HUDController.shared)
                .environmentObject(MenuBarModules.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var hud: HUDController
    @EnvironmentObject var modules: MenuBarModules
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("当前会话") {
                if let s = monitor.stats {
                    Row(label: s.projectName, value: "\(s.source.displayName) · \(s.model ?? "未知模型")")
                    Row(label: "输出速度（近 5 步）", value: Fmt.tps(s.recentTPS))
                    Row(label: "\(s.turns) 轮 \(s.steps) 步 · TTFT", value: s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "日志未记录")
                    Row(label: "Token · 缓存命中", value: "\(Fmt.compactTokens(s.totalTokens)) · \(Fmt.percent(s.cacheHitRate))")
                    Row(label: "上下文", value: "\(Fmt.compactTokens(s.contextTokens)) / \(s.contextWindow.map(Fmt.compactTokens) ?? "?") · \(Fmt.percent(s.contextFraction, digits: 0))")
                } else {
                    Text("还没有找到最近的 Claude Code / Codex 会话，开始一次对话后会自动出现。")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("自动跟随范围", selection: $monitor.sourceFilter) {
                    ForEach(SourceFilter.allCases) { Text($0.label).tag($0) }
                }
                SessionListView(compact: true)
                    .padding(.horizontal, -8)
            } header: {
                Text("会话")
            } footer: {
                Text("也可以在任意菜单栏模块的详情页、或点击悬浮条左侧的模型名来切换。")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach(MenuBarModule.allCases) { m in
                    Toggle(m.label, isOn: modules.binding(m))
                        // Keep at least one module so the details and settings stay reachable.
                        .disabled(modules.isOn(m) && modules.enabled.count == 1)
                }
            } header: {
                Text("顶部菜单栏模块")
            } footer: {
                Text("每个模块单独显示在菜单栏，点击可看详情、切换会话和打开设置（⚙︎）。至少保留一个。按住 ⌘ 拖动可调整顺序。")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("显示与启动") {
                Toggle("显示悬浮条", isOn: $hud.visible)
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Claude 上下文窗口", selection: $monitor.claudeContextWindow) {
                    Text("自动").tag(0)
                    Text("200K").tag(200_000)
                    Text("1M").tag(1_000_000)
                }
            }

            Section {
                HStack {
                    Text(verbatim: "只读本机日志（~/.claude、~/.codex），不联网、不读取凭据与对话内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("退出 AgentPulse") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(minWidth: 420, minHeight: 420)
    }
}
