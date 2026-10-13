import SwiftUI

enum Segment: Hashable {
    case speed, tokens, context, sessions

    var title: String {
        switch self {
        case .speed: return "会话统计"
        case .tokens: return "Token 用量"
        case .context: return "上下文占用"
        case .sessions: return "切换会话"
        }
    }

    var symbol: String {
        switch self {
        case .speed: return "gauge.with.dots.needle.67percent"
        case .tokens: return "cylinder.split.1x2"
        case .context: return "circle.dashed"
        case .sessions: return "rectangle.stack"
        }
    }
}

// MARK: - Bar segments (speed · tokens · context)

struct StatusBarView: View {
    let stats: SessionStats?
    var active: Segment?
    var onTap: (Segment) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            segment(.speed, label: "速度详情") {
                if let s = stats {
                    SpeedText(stats: s)
                } else {
                    LiveDot(on: false)
                    Text("等待会话…").foregroundStyle(.secondary)
                }
            }
            segment(.tokens, label: "Token 用量") {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.secondary)
                if let s = stats {
                    Text(Fmt.compactTokens(s.totalTokens)).fontWeight(.semibold)
                    Text("· 缓存 \(Fmt.percent(s.cacheHitRate))").foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            segment(.context, label: "上下文占用") {
                RingView(fraction: stats?.contextFraction ?? 0, lineWidth: 3)
                    .frame(width: 16, height: 16)
                Text(Fmt.percent(stats?.contextFraction, digits: 0)).fontWeight(.semibold)
            }
        }
        .font(.system(size: 12.5).monospacedDigit())
        .lineLimit(1)
    }

    private func segment<C: View>(_ seg: Segment, label: String, @ViewBuilder _ content: () -> C) -> some View {
        let on = active == seg
        return HStack(spacing: 8) { content() }
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                if on {
                    Capsule().fill(Color.white.opacity(0.14))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
            .onTapGesture { onTap(seg) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(label)
    }
}

/// Recent tok/s, steps and a status slot (live timer while a request is in flight).
/// The number and timer have fixed widths so the bar never changes size as they tick.
struct SpeedText: View {
    let stats: SessionStats

    var body: some View {
        HStack(spacing: 8) {
            LiveDot(on: stats.waitingSince != nil)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.tpsNumber(stats.recentTPS)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("tok/s").foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .leading)
            Text("\(stats.turns) 轮 · \(stats.steps) 步").foregroundStyle(.secondary)
            Group {
                if let w = stats.waitingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Fmt.shortElapsed(ctx.date.timeIntervalSince(w))).foregroundStyle(Theme.live)
                    }
                } else {
                    Text("空闲").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 44, alignment: .leading)
        }
        .help(stats.waitingSince == nil ? "空闲" : "生成中")
    }
}

// MARK: - Detail views

/// Big recent speed, generating state and the per-step sparkline.
struct SpeedHero: View {
    let s: SessionStats
    var sparkHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ActivityLabel(s: s)
                    HeroNumber(value: Fmt.tpsNumber(s.recentTPS), unit: "tok/s")
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("输出速度 · 近 5 步")
                    Text("\(s.turns) 轮 · \(s.steps) 步")
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }
            Sparkline(values: Array(s.stepTPS.suffix(24)), average: s.sessionTPS)
                .frame(height: sparkHeight)
        }
    }
}

struct SpeedDetail: View {
    enum Layout { case tiles, list }
    let s: SessionStats
    var layout: Layout = .list

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpeedHero(s: s).padding(.horizontal, 4)
            switch layout {
            case .tiles:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    StatTile(label: "最近一步", value: Fmt.tpsNumber(s.lastTPS), unit: "tok/s")
                    StatTile(label: "会话平均", value: Fmt.tpsNumber(s.sessionTPS), unit: "tok/s")
                    StatTile(label: "模型用时", value: Fmt.duration(s.modelTime))
                    StatTile(label: "工具调用用时", value: Fmt.duration(s.toolTime))
                }
                InfoRow(label: "首 token 平均（TTFT）", value: ttft, dimValue: !s.ttftAvailable, divider: false)
                    .padding(.horizontal, 4)
            case .list:
                VStack(spacing: 0) {
                    InfoRow(label: "最近一步", value: Fmt.tps(s.lastTPS))
                    InfoRow(label: "会话平均", value: Fmt.tps(s.sessionTPS))
                    InfoRow(label: "首 token 平均（TTFT）", value: ttft, dimValue: !s.ttftAvailable)
                    InfoRow(label: "模型用时", value: Fmt.duration(s.modelTime))
                    InfoRow(label: "工具调用用时", value: Fmt.duration(s.toolTime), divider: false)
                }
                .insetGroup()
            }
            Footnote(text: note)
        }
    }

    private var ttft: String { s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "日志未记录" }

    private var note: String {
        s.speedNote ?? (s.ttftAvailable
            ? "速度 = 输出 token ÷ 首个输出到响应结束的时间"
            : "\(s.source.displayName) 日志不含首 token 时间，速度含首 token 等待（略偏低）")
    }
}

struct TokenDetail: View {
    let s: SessionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本会话 Token 用量").font(.system(size: 12)).foregroundStyle(.secondary)
                    HeroNumber(value: Fmt.compactTokens(s.totalTokens), unit: "tok", size: 46)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("缓存命中").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(Fmt.percent(s.cacheHitRate))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 4)
            .help(Fmt.tokens(s.totalTokens))

            TokenBar(slices: s.tokenSlices).padding(.horizontal, 4)

            VStack(spacing: 0) {
                let slices = s.tokenSlices
                ForEach(Array(slices.enumerated()), id: \.1.id) { i, sl in
                    InfoRow(label: sl.label, value: Fmt.compactTokens(sl.value), dot: sl.color,
                            divider: i < slices.count - 1)
                        .help(Fmt.tokens(sl.value))
                }
            }
            .insetGroup()

            let limits = [s.rateLimitPrimary, s.rateLimitSecondary].compactMap { $0 }
            if !limits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(limits.enumerated()), id: \.0) { i, p in
                        HStack(spacing: 10) {
                            Text("额度窗口 \(windowName(p.windowMinutes))").foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            MiniBar(fraction: p.usedPercent / 100, width: 60)
                            Text(String(format: "%.0f%% 已用", p.usedPercent)).fontWeight(.medium)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 12.5).monospacedDigit())
                        .frame(height: 38)
                        .overlay(alignment: .bottom) {
                            if i < limits.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                }
                .insetGroup()
            }
        }
    }

    private func windowName(_ m: Int) -> String {
        m >= 1440 ? "\(m / 1440)天" : (m >= 60 ? "\(m / 60)小时" : "\(m)分")
    }
}

struct ContextDetail: View {
    let s: SessionStats

    var body: some View {
        let frac = s.contextFraction ?? 0
        let window = s.contextWindow.map(Fmt.compactTokens) ?? "?"
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ZStack {
                    RingView(fraction: frac, lineWidth: 8)
                    Text(Fmt.percent(s.contextFraction, digits: 0))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("上下文已用").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("~" + Fmt.compactTokens(s.contextTokens))
                            .font(.system(size: 30, weight: .semibold).monospacedDigit())
                        Text("/ \(window)").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if frac > 0.85 {
                        Text("快满了，模型可能很快会压缩上下文")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                InfoRow(label: "模型", value: s.model ?? "—")
                InfoRow(label: "上下文窗口", value: window + (s.contextWindowIsEstimate ? "（估计）" : ""), divider: false)
            }
            .insetGroup()

            Footnote(text: "按最近一次请求的输入 token 计算")
        }
    }
}

struct CardFor: View {
    let seg: Segment
    let s: SessionStats
    var speedLayout: SpeedDetail.Layout = .list
    var body: some View {
        switch seg {
        case .speed: SpeedDetail(s: s, layout: speedLayout)
        case .tokens: TokenDetail(s: s)
        case .context: ContextDetail(s: s)
        case .sessions: EmptyView()
        }
    }
}

// MARK: - Session picker

/// Running sessions of every detected tool; picking one pins it. Older sessions live in
/// the session browser ("更多会话…").
struct SessionListView: View {
    @EnvironmentObject var monitor: Monitor
    /// Without the title row (it's embedded under another header).
    var compact: Bool
    var onPick: () -> Void = {}

    var body: some View {
        let running = monitor.runningSessions
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text("切换会话").font(.system(size: 15, weight: .semibold))
                    Text("\(running.count) 个运行中 · \(generatingCount) 个生成中")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }

            autoFollowGroup

            VStack(alignment: .leading, spacing: 2) {
                if let p = monitor.pinnedSession, !running.contains(where: { $0.path == p.path }) {
                    SectionLabel(text: "已固定")
                    row(p)
                }
                SectionLabel(text: "运行中")
                ForEach(running) { ref in row(ref) }
                if running.isEmpty {
                    Text("当前没有运行中的会话")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }

            Button {
                SessionBrowser.show()
                onPick()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                    Text("更多会话…").fontWeight(.medium)
                    Spacer(minLength: 8)
                    Text(toolSummary).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5).monospacedDigit())
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var generatingCount: Int {
        monitor.allStats.values.filter { $0.waitingSince != nil }.count
    }

    private var toolSummary: String {
        let n = monitor.supportedTools.count
        return n == 0 ? "" : "\(n) 个工具"
    }

    private var autoFollowGroup: some View {
        let following = monitor.pinnedPath == nil
        let scopeName = monitor.autoFollowTool.isEmpty ? "" : (ToolRegistry.spec(monitor.autoFollowTool)?.name ?? "") + " "
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(Theme.accent.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("自动跟随\(scopeName)最新会话").font(.system(size: 13, weight: .medium))
                    Text(following ? (monitor.stats.map { "当前：\($0.projectName)" } ?? "跟随最近有写入的会话")
                                   : "已固定：\(monitor.stats?.projectName ?? "—")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("自动跟随最新会话", isOn: Binding(
                    get: { monitor.pinnedPath == nil },
                    set: { on in
                        if on { monitor.unpin() } else if let ref = currentRef { monitor.pin(ref) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.live)
            }
            .frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            HStack {
                Text("跟随范围").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("跟随范围", selection: $monitor.autoFollowTool) {
                    Text("全部工具").tag("")
                    ForEach(monitor.supportedTools) { Text($0.spec.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .font(.system(size: 12.5))
            .frame(height: 38)
        }
        .insetGroup(radius: 20)
    }

    /// The session currently on screen, to pin when auto-follow is switched off.
    private var currentRef: SessionRef? {
        guard let p = monitor.stats?.path else { return nil }
        return monitor.sessions.first { $0.path == p }
    }

    private func row(_ ref: SessionRef) -> some View {
        let s = monitor.allStats[ref.path]
        let generating = s?.waitingSince != nil
        let current = monitor.stats?.path == ref.path
        let pinned = monitor.pinnedPath == ref.path
        return Button {
            monitor.pin(ref)
            onPick()
        } label: {
            HStack(spacing: 12) {
                ToolBadge(symbol: ref.source.symbol, generating: generating)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(s?.projectName ?? ref.label)
                            .font(.system(size: 13.5, weight: current ? .semibold : .medium))
                            .lineLimit(1)
                        if pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 0) {
                        Text(meta(ref, s)).foregroundStyle(.secondary)
                        if let w = s?.waitingSince {
                            Text(" · 生成中 \(Fmt.shortElapsed(Date().timeIntervalSince(w)))").foregroundStyle(Theme.live)
                                .layoutPriority(1)
                        }
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Fmt.tpsNumber(s?.recentTPS)).font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        Text("tok/s").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if let f = s?.contextFraction {
                        MiniBar(fraction: f).help("上下文 \(Fmt.percent(f, digits: 0))")
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 56)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raisedFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func meta(_ ref: SessionRef, _ s: SessionStats?) -> String {
        // The badge already shows the tool, so the model name gets the room.
        var parts = [s?.model ?? ref.source.displayName]
        if s?.waitingSince == nil { parts.append(Fmt.relative(s?.lastActivity ?? ref.modified)) }
        return parts.joined(separator: " · ")
    }
}
