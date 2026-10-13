import AppKit
import SwiftUI

/// The "更多会话" window: detected tools → all their sessions → one session's details.
@MainActor
enum SessionBrowser {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "更多会话"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 420)
            w.contentView = NSHostingView(rootView: SessionBrowserView().environmentObject(Monitor.shared))
            w.center()
            w.setFrameAutosaveName("AgentPulseSessionBrowser")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SessionBrowserView: View {
    @EnvironmentObject var monitor: Monitor
    /// For screenshots: open this tool and select its newest session.
    var preselectTool: String? = nil
    @State private var tool: String?
    @State private var sessions: [SessionRef] = []
    @State private var loadingList = false
    @State private var selected: String?
    @State private var detail: SessionStats?
    @State private var loadingDetail = false
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            toolList.navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            sessionList.navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detailPane
        }
        .onAppear { if tool == nil { tool = preselectTool ?? monitor.supportedTools.first?.id } }
        .onChange(of: monitor.tools) { tools in
            if tool == nil { tool = tools.first(where: \.supported)?.id }
        }
        .onChange(of: tool) { t in loadSessions(t) }
        .onChange(of: selected) { p in loadDetail(p) }
    }

    // MARK: Tools

    private var toolList: some View {
        List(selection: $tool) {
            Section("已适配") {
                ForEach(monitor.tools.filter(\.supported)) { t in
                    toolRow(t).tag(Optional(t.id))
                }
            }
            let others = monitor.tools.filter { !$0.supported }
            if !others.isEmpty {
                Section("已检测到，暂无法读取") {
                    ForEach(others) { t in toolRow(t).tag(Optional(t.id)) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    monitor.rescanTools()
                } label: {
                    Label(monitor.scanning ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.scanning)
                Spacer()
                Text("\(monitor.tools.count) 个工具").foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .padding(10)
        }
    }

    private func toolRow(_ t: DetectedTool) -> some View {
        HStack(spacing: 10) {
            ToolBadge(symbol: t.spec.symbol, size: 28)
                .opacity(t.supported ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.spec.name).font(.system(size: 13, weight: .medium))
                Text(t.installKinds).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionList: some View {
        if let id = tool, let t = monitor.tools.first(where: { $0.id == id }) {
            if !t.supported {
                unsupported(t)
            } else if loadingList && sessions.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                placeholder("还没有会话", "用 \(t.spec.name) 开始一个对话后会出现在这里")
            } else {
                List(selection: $selected) {
                    ForEach(groupedByDay, id: \.0) { day, refs in
                        Section(day) {
                            ForEach(refs) { ref in sessionRow(ref).tag(Optional(ref.path)) }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { listHeader(t) }
                .navigationTitle(t.spec.name)
                .navigationSubtitle("\(sessions.count) 个会话")
            }
        } else {
            placeholder("选择一个工具", "左侧是在这台 Mac 上检测到的 agent 工具")
        }
    }

    private var groupedByDay: [(String, [SessionRef])] {
        let cal = Calendar.current
        var out: [(String, [SessionRef])] = []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? sessions : sessions.filter { ref in
            [ref.label, ref.cwd ?? "", monitor.allStats[ref.path]?.model ?? ""].contains { $0.lowercased().contains(q) }
        }
        for ref in shown {
            let key: String
            if cal.isDateInToday(ref.modified) { key = "今天" }
            else if cal.isDateInYesterday(ref.modified) { key = "昨天" }
            else { key = ref.modified.formatted(.dateTime.year().month().day()) }
            if out.last?.0 == key { out[out.count - 1].1.append(ref) } else { out.append((key, [ref])) }
        }
        return out
    }

    private func listHeader(_ t: DetectedTool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.spec.name).font(.system(size: 20, weight: .bold))
                Spacer()
                Text("\(sessions.count) 个会话").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索项目或模型", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func sessionRow(_ ref: SessionRef) -> some View {
        let running = monitor.runningSessions.contains { $0.path == ref.path }
        let live = monitor.allStats[ref.path]
        return HStack(spacing: 10) {
            LiveDot(on: live?.waitingSince != nil || running)
                .opacity(running ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(ref.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if ref.isSubagent {
                        Text("子代理").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.purple.opacity(0.18)))
                    }
                    if monitor.pinnedPath == ref.path {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(ref)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let tps = live?.recentTPS {
                Text(Fmt.tps(tps)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(_ ref: SessionRef) -> String {
        var parts = [ref.modified.formatted(date: .omitted, time: .shortened)]
        if let m = monitor.allStats[ref.path]?.model { parts.append(m) }
        if let c = ref.cwd, !c.isEmpty, ref.title != nil, ref.title != (c as NSString).lastPathComponent {
            parts.append((c as NSString).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    private func unsupported(_ t: DetectedTool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: t.spec.symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(t.spec.name).font(.title3.weight(.semibold))
            Text(t.installKinds).foregroundStyle(.secondary)
            Text(t.spec.note ?? "暂不支持读取这个工具的会话")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 280)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(sub).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let p = selected, let ref = sessions.first(where: { $0.path == p }) {
            let live = monitor.allStats[p] ?? detail
            if let s = live {
                ScrollView {
                    SessionDetailView(ref: ref, s: s, refresh: { detail = nil; loadDetail(ref.path, force: true) })
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity)
                }
            } else if loadingDetail {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("读取失败", "这个会话的日志无法解析")
            }
        } else {
            placeholder("选择一个会话", "可以查看它的速度、token 和上下文")
        }
    }

    // MARK: Loading

    private func loadSessions(_ id: String?) {
        selected = nil
        detail = nil
        sessions = []
        guard let id, monitor.tools.first(where: { $0.id == id })?.supported == true else { return }
        loadingList = true
        monitor.listSessions(tool: id) { refs in
            guard tool == id else { return }
            sessions = refs
            loadingList = false
            if preselectTool != nil, selected == nil { selected = refs.first?.path }
        }
    }

    private func loadDetail(_ path: String?, force: Bool = false) {
        guard let path, let ref = sessions.first(where: { $0.path == path }) else { detail = nil; return }
        if !force { detail = nil }
        loadingDetail = true
        monitor.loadStats(ref, cached: !force) { s in
            guard selected == path else { return }
            detail = s
            loadingDetail = false
        }
    }
}

/// One session's details: title, pin button, headline numbers, the speed curve and breakdowns.
struct SessionDetailView: View {
    @EnvironmentObject var monitor: Monitor
    let ref: SessionRef
    let s: SessionStats
    var refresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    OverviewTile(label: "输出速度（近 5 步）", value: Fmt.tpsNumber(s.recentTPS), unit: "tok/s")
                    OverviewTile(label: "Token · 缓存命中", value: Fmt.compactTokens(s.totalTokens),
                                 unit: Fmt.percent(s.cacheHitRate), unitColor: Theme.accent)
                    OverviewTile(label: "上下文 · \(Fmt.compactTokens(s.contextTokens)) / \(s.contextWindow.map(Fmt.compactTokens) ?? "?")",
                                 value: Fmt.percent(s.contextFraction, digits: 0), bar: s.contextFraction)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("每步输出速度")
                    Spacer()
                    Text("\(s.steps) 步 · 平均 \(Fmt.tps(s.sessionTPS))")
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                Sparkline(values: s.stepTPS, average: s.sessionTPS).frame(height: 84)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))

            Grid(alignment: .top, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    VStack(spacing: 0) {
                        InfoRow(label: "最近一步", value: Fmt.tps(s.lastTPS))
                        InfoRow(label: "会话平均", value: Fmt.tps(s.sessionTPS))
                        InfoRow(label: "首 token 平均（TTFT）", value: s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "日志未记录",
                                dimValue: !s.ttftAvailable, divider: false)
                    }
                    .insetGroup()
                    VStack(spacing: 0) {
                        InfoRow(label: "模型用时", value: Fmt.duration(s.modelTime))
                        InfoRow(label: "工具调用用时", value: Fmt.duration(s.toolTime))
                        InfoRow(label: "轮次 · 步数", value: "\(s.turns) 轮 · \(s.steps) 步", divider: false)
                    }
                    .insetGroup()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Token 构成").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                TokenBar(slices: s.tokenSlices).padding(.horizontal, 4)
                VStack(spacing: 0) {
                    let slices = s.tokenSlices
                    ForEach(Array(slices.enumerated()), id: \.1.id) { i, sl in
                        InfoRow(label: sl.label, value: Fmt.tokens(sl.value), dot: sl.color, divider: i < slices.count - 1)
                    }
                }
                .insetGroup()
            }

            if let n = s.speedNote { Footnote(text: n) }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.projectName).font(.system(size: 22, weight: .bold)).lineLimit(2)
                Text([ref.source.displayName, s.model, ref.isSubagent ? "子代理" : nil,
                      Fmt.relative(s.lastActivity ?? ref.modified)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let c = s.cwd ?? ref.cwd {
                    Text(verbatim: c).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
                    .accessibilityLabel("刷新")
                if monitor.pinnedPath == ref.path {
                    Button("取消固定，恢复自动跟随") { monitor.unpin() }
                } else {
                    Button { monitor.pin(ref) } label: {
                        Label("在悬浮条和菜单栏中查看", systemImage: "pin")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
    }
}
