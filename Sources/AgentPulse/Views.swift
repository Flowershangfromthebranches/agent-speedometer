import SwiftUI

enum Segment: Hashable {
    case speed, tokens, context, sessions
}

// MARK: - Bar (the DeepSeek-style strip)

struct StatusBarView: View {
    let stats: SessionStats?
    var active: Segment?
    var onTap: (Segment) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 6) {
            segment(.speed) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                if let s = stats {
                    Text("\(s.turns) 轮 \(s.steps) 步 ·")
                    SpeedText(stats: s)
                } else {
                    Text("等待会话…")
                }
            }
            segment(.tokens) {
                Image(systemName: "cylinder.split.1x2")
                Text(stats.map { "\(Fmt.compactTokens($0.totalTokens)) tok · 缓存命中 \(Fmt.percent($0.cacheHitRate))" } ?? "—")
            }
            segment(.context) {
                RingView(fraction: stats?.contextFraction ?? 0)
                    .frame(width: 14, height: 14)
                Text(Fmt.percent(stats?.contextFraction, digits: 0))
            }
        }
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func segment<C: View>(_ seg: Segment, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(active == seg ? 0.10 : 0))
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap(seg) }
    }
}

/// Recent tok/s plus a status slot (live timer while a request is in flight).
/// Both parts have fixed widths so the bar never changes size as the timer ticks.
struct SpeedText: View {
    let stats: SessionStats

    var body: some View {
        HStack(spacing: 6) {
            Text(Fmt.tps(stats.recentTPS))
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) {
                if let w = stats.waitingSince {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Fmt.shortElapsed(ctx.date.timeIntervalSince(w)))
                    }
                } else {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text("空闲").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 54, alignment: .leading)
            .help(stats.waitingSince == nil ? "空闲" : "生成中")
        }
    }
}

struct RingView: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(fraction > 0.85 ? Color.orange : Color.primary.opacity(0.75),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Detail cards

struct DetailCard<Content: View>: View {
    let icon: String?
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 16)
                if let trailing { Text(trailing).fontWeight(.semibold) }
            }
            .foregroundStyle(.primary)
            Divider()
            content
        }
        .font(.system(size: 12.5).monospacedDigit())
        .frame(width: 300, alignment: .leading)
    }
}

struct Row: View {
    let label: String
    let value: String
    var hint: String? = nil
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.primary)
        }
    }
}

struct SpeedCard: View {
    let s: SessionStats
    var body: some View {
        DetailCard(icon: "gauge.with.dots.needle.67percent", title: "会话统计") {
            Row(label: "模型用时", value: Fmt.duration(s.modelTime))
            Row(label: "工具调用用时", value: Fmt.duration(s.toolTime))
            Row(label: "首 token 平均（TTFT）",
                value: s.ttftAvailable ? Fmt.duration(s.avgTTFT) : "日志未记录")
            Row(label: "输出速度（近 5 步）", value: Fmt.tps(s.recentTPS))
            Row(label: "最近一步", value: Fmt.tps(s.lastTPS))
            Row(label: "会话平均", value: Fmt.tps(s.sessionTPS))
            Text(s.ttftAvailable
                 ? "速度 = 输出 token ÷ 首个输出到响应结束的时间"
                 : "Claude Code 日志不含首 token 时间，速度含首 token 等待（略偏低）")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TokenCard: View {
    let s: SessionStats
    var body: some View {
        DetailCard(icon: "cylinder.split.1x2", title: "Token 用量", trailing: Fmt.tokens(s.totalTokens)) {
            Row(label: "缓存命中", value: Fmt.percent(s.cacheHitRate))
            Row(label: "未缓存输入", value: Fmt.tokens(s.uncachedInput))
            if s.cacheWrite > 0 { Row(label: "缓存写入", value: Fmt.tokens(s.cacheWrite)) }
            Row(label: "缓存读取", value: Fmt.tokens(s.cacheRead))
            Row(label: "输出", value: Fmt.tokens(s.outputTokens))
            if let p = s.rateLimitPrimary {
                Row(label: "额度窗口 \(windowName(p.windowMinutes))", value: String(format: "%.0f%% 已用", p.usedPercent))
            }
            if let p = s.rateLimitSecondary {
                Row(label: "额度窗口 \(windowName(p.windowMinutes))", value: String(format: "%.0f%% 已用", p.usedPercent))
            }
        }
    }

    private func windowName(_ m: Int) -> String {
        m >= 1440 ? "\(m / 1440)天" : (m >= 60 ? "\(m / 60)小时" : "\(m)分")
    }
}

struct ContextCard: View {
    let s: SessionStats
    var body: some View {
        let frac = s.contextFraction ?? 0
        let window = s.contextWindow.map(Fmt.compactTokens) ?? "?"
        DetailCard(icon: nil, title: "上下文已用  \(Fmt.percent(s.contextFraction, digits: 0))",
                   trailing: "~\(Fmt.compactTokens(s.contextTokens)) / \(window)") {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(frac > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: max(4, g.size.width * frac))
                }
            }
            .frame(height: 6)
            Row(label: "模型", value: s.model ?? "—")
            Row(label: "上下文窗口", value: window + (s.contextWindowIsEstimate ? "（估计）" : ""))
            Text("按最近一次请求的输入 token 计算")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

struct CardFor: View {
    let seg: Segment
    let s: SessionStats
    var body: some View {
        switch seg {
        case .speed: SpeedCard(s: s)
        case .tokens: TokenCard(s: s)
        case .context: ContextCard(s: s)
        case .sessions: EmptyView()
        }
    }
}

// MARK: - Session picker

/// Lists recent sessions with their live speed; picking one pins it.
struct SessionListView: View {
    @EnvironmentObject var monitor: Monitor
    var compact: Bool
    var limit = Monitor.trackedLimit
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !compact {
                HStack {
                    Text("选择会话").fontWeight(.semibold)
                    Spacer()
                    Text("\(generatingCount) 个生成中").foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            autoRow
            ForEach(monitor.trackedSessions.prefix(limit)) { ref in
                row(ref)
            }
            if monitor.trackedSessions.isEmpty {
                Text("最近 3 天没有会话").foregroundStyle(.secondary).padding(8)
            }
        }
        .font(.system(size: 12.5).monospacedDigit())
    }

    private var generatingCount: Int {
        monitor.allStats.values.filter { $0.waitingSince != nil }.count
    }

    private var autoRow: some View {
        let target = monitor.pinnedPath == nil ? monitor.stats?.projectName : nil
        return pickRow(selected: monitor.pinnedPath == nil, action: { monitor.pinnedPath = nil }) {
            Image(systemName: "wand.and.stars").frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text("自动跟随最新会话")
                Text(target.map { "当前：\($0)" } ?? "跟随最近有写入的会话")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }

    private func row(_ ref: SessionRef) -> some View {
        let s = monitor.allStats[ref.path]
        let generating = s?.waitingSince != nil
        return pickRow(selected: monitor.pinnedPath == ref.path, action: { monitor.pinnedPath = ref.path }) {
            Circle()
                .fill(generating ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(s?.projectName ?? ref.label).lineLimit(1)
                Text(subtitle(ref, s))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.tps(s?.recentTPS))
                if let s, let f = s.contextFraction {
                    Text("上下文 \(Fmt.percent(f, digits: 0))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ ref: SessionRef, _ s: SessionStats?) -> String {
        var parts = [ref.source.displayName]
        if let m = s?.model { parts.append(m) }
        if let w = s?.waitingSince {
            parts.append("生成中 \(Fmt.shortElapsed(Date().timeIntervalSince(w)))")
        } else {
            parts.append(Fmt.relative(s?.lastActivity ?? ref.modified))
        }
        return parts.joined(separator: " · ")
    }

    private func pickRow<C: View>(selected: Bool, action: @escaping () -> Void,
                                  @ViewBuilder _ content: () -> C) -> some View {
        Button {
            action()
            onPick()
        } label: {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
