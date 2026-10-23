import SwiftUI

/// Settings → Token 消耗: a standalone overview of how many tokens each agent tool spent.
struct UsagePage: View {
    @EnvironmentObject var monitor: Monitor
    @ObservedObject private var store = TokenUsageStore.shared
    @AppStorage("usageRange") private var rangeRaw = UsageRange.month.rawValue
    @State private var tool: String?

    /// Screenshot helpers: `--render --demo` opens the page in a fixed state.
    private let previewRange: UsageRange?
    private let previewTool: String?

    init(previewRange: UsageRange? = nil, previewTool: String? = nil) {
        self.previewRange = previewRange
        self.previewTool = previewTool
        _tool = State(initialValue: previewTool)
    }

    private var range: UsageRange { previewRange ?? (UsageRange(rawValue: rangeRaw) ?? .month) }
    private var summary: UsageSummary { store.summary(range: range, tool: tool) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                rangeRow
                toolChips

                if !store.loaded || (store.loading && store.events.isEmpty) {
                    UsageLoadingCard(progress: store.progress)
                } else if summary.totals.total == 0 && !summary.totals.hasCreditData {
                    UsageEmptyCard(hasTools: !chipTools.isEmpty) { store.load(range: range) }
                } else {
                    if !summary.creditGroups.isEmpty { UsageCreditsCard(summary: summary) }
                    if summary.totals.total > 0 {
                        kpis
                        UsageBarCard(summary: summary)
                        UsageCompositionCard(summary: summary, selectedTool: tool,
                                             toolColors: toolColors, onSelect: { tool = $0 })
                        UsageModelCostCard(summary: summary)
                    }
                    footnotes
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { store.loadIfNeeded(range: range) }
        .onChange(of: rangeRaw) { _ in store.load(range: range) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("用量统计").font(.system(size: 22, weight: .bold))
                Text("按工具与时间查看 Token 和 Credits 用量")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(alignment: .center, spacing: 12) {
                if summary.totals.total > 0 {
                    costBadge
                }
                HStack(spacing: 10) {
                    if store.loading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        store.load(range: range)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.large)
                    .disabled(store.loading)
                    .help("重新统计")
                    .accessibilityLabel("重新统计 Token 用量")
                }
            }
            .padding(.top, 2)
        }
    }

    private var costBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(summary.cost.pricedTokens > 0 ? Fmt.usd(summary.cost.usd) : "—")
                .font(.system(size: 21, weight: .semibold).monospacedDigit())
                .tracking(-0.4)
                .lineLimit(1)
            Text(summary.cost.isComplete ? "估算费用 · 官方标价" : "估算费用 · 部分模型价格未知")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .help("按模型官方标价（USD / 百万 token）估算，不含套餐与折扣")
        .accessibilityElement(children: .combine)
    }

    private var rangeRow: some View {
        HStack(spacing: 12) {
            SegmentedTabs(items: UsageRange.allCases.map { ($0, $0.title) },
                          selection: Binding(get: { range }, set: {
                              guard previewRange == nil else { return }
                              rangeRaw = $0.rawValue
                          }))
                .frame(width: 326)
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        if store.loading { return store.progress ?? "正在统计…" }
        if let d = store.scanDuration { return String(format: "统计用时 %.1f 秒", d) }
        return ""
    }

    // MARK: Tool filter

    /// Tool totals for the current range, regardless of the active filter: chips keep a
    /// stable order and color when one tool is selected.
    private var allTools: [UsageTool] { store.summary(range: range, tool: nil).tools }

    private var chipTools: [AgentToolSpec] {
        var specs: [AgentToolSpec] = []
        var seen = Set<String>()
        for t in allTools {
            if let spec = t.source.spec, seen.insert(spec.id).inserted { specs.append(spec) }
        }
        for t in monitor.supportedTools where seen.insert(t.id).inserted {
            specs.append(t.spec)
        }
        if let tool, seen.insert(tool).inserted, let spec = ToolRegistry.spec(tool) {
            specs.append(spec)
        }
        return specs
    }

    private var toolColors: [String: Color] {
        var map: [String: Color] = [:]
        for (i, t) in allTools.enumerated() {
            map[t.id] = UsagePalette.toolColors[i % UsagePalette.toolColors.count]
        }
        return map
    }

    private var toolChips: some View {
        UsageFlowLayout(spacing: 7) {
            UsageToolChip(title: "全部工具", symbol: "square.grid.2x2.fill", color: nil,
                          selected: tool == nil) { tool = nil }
            ForEach(chipTools) { spec in
                UsageToolChip(title: spec.name, symbol: nil,
                              color: toolColors[spec.id] ?? Color.secondary.opacity(0.4),
                              selected: tool == spec.id) {
                    tool = spec.id
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: KPI

    private var kpis: some View {
        let t = summary.totals
        let outputShare = t.total > 0 ? Double(t.output) / Double(t.total) : 0
        return HStack(spacing: 10) {
            UsageTile(label: "总消耗", value: Fmt.compactTokens(t.total), unit: "tok",
                      caption: "\(t.requests) 次请求",
                      icon: "chart.bar.fill", tint: Theme.accent)
            UsageTile(label: "输出", value: Fmt.compactTokens(t.output), unit: "tok",
                      caption: "占总消耗 \(Fmt.percent(outputShare, digits: 0))",
                      icon: "arrow.up.right", tint: Theme.warn)
            UsageTile(label: "输入", value: Fmt.compactTokens(t.input), unit: "tok",
                      caption: "未缓存 \(Fmt.compactTokens(t.uncachedInput))",
                      icon: "arrow.down.left", tint: Theme.blue)
            UsageTile(label: "缓存命中", value: Fmt.percent(t.cacheHitRate, digits: 0),
                      caption: "读取 \(Fmt.compactTokens(t.cacheRead)) tok",
                      icon: "bolt.fill", tint: Theme.live)
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Footnote(text: "只统计本机日志中的用量与时间，不保存对话内容；按每次模型请求完成的时间归入当天，包含子代理请求。")
            if !summary.creditGroups.isEmpty {
                Footnote(text: "Qoder 的 Credits 按请求 id 去重；未计费请求记为 0，缺失字段不按 0 补齐。各版本 Credits 分开统计，不与 token 或美元费用相加。")
            }
            if summary.totals.total > 0 {
                Footnote(text: "费用按模型官方标价（USD / 百万 token）估算：缓存写入按 5 分钟档，Claude 1 小时档按输入价 2 倍折算；套餐、折扣、峰谷价与免费额度未计入。")
            }
            if summary.tools.contains(where: { $0.id == "codex" }) && !ZstdSupport.isAvailable {
                Footnote(text: "未找到 zstd，Codex 的压缩归档会话（.jsonl.zst）没有计入；安装 zstd 后重新统计即可。")
            }
            if summary.tools.contains(where: { $0.id == "grok" }) {
                Footnote(text: "Grok CLI 的日志按每轮汇总记录用量，无法拆分到单次模型调用。")
            }
            if summary.tools.contains(where: { $0.id == "deepseek-harness" }) {
                Footnote(text: "DeepSeek Harness 的本地日志只保存会话累计值，整段计入最后更新当天。")
            }
        }
    }
}

private struct UsageCreditsCard: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credits 消耗").font(.system(size: 14, weight: .semibold))
            ForEach(summary.tools.filter { $0.totals.hasCreditData }) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(entry.source.displayName)\(entry.totals.missingCreditRequests > 0 ? " 已知部分" : " 合计")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.creditsNumber(entry.totals.credits)) Credits")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                }.padding(.vertical, 4)
            }
            ForEach(summary.creditGroups) { group in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group.source.displayName) · \(group.model.isEmpty ? "模型未记录" : group.model)")
                            .font(.system(size: 12, weight: .medium))
                        Text("\(group.totals.creditRequests) 次有计费记录 · \(group.totals.missingCreditRequests) 次数据缺失")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(Fmt.creditsNumber(group.totals.credits)) Credits")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        Text("平均 \(Fmt.creditsNumber(group.totals.creditRate)) Credits/s")
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.4)
            }
            if summary.tools.count == 1 {
                DisclosureGroup("\(summary.granularityNote)明细") {
                    VStack(spacing: 0) {
                        ForEach(summary.buckets.filter { $0.totals.hasCreditData }) { bucket in
                            InfoRow(label: bucket.tooltipTitle,
                                    value: "\(Fmt.creditsNumber(bucket.totals.credits)) Credits")
                        }
                    }
                }.font(.system(size: 11.5))
            }
            Text("消耗速度 = 已知实际计费 Credits ÷ 对应请求耗时（含等待），按总量加权。免费请求记为 0；耗时缺失的请求不计速度。数据缺失时统计为部分用量。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Token 估算未启用：尚无经过验证的换算规则。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.groupFill))
    }
}

// MARK: - Palette

enum UsagePalette {
    static let toolColors: [Color] = [
        Theme.accent,
        Theme.purple,
        Theme.warn,
        Theme.live,
        Theme.blue,
        Color(red: 0.96, green: 0.42, blue: 0.58),
        Color(red: 0.42, green: 0.64, blue: 1.0),
        Color(red: 0.18, green: 0.76, blue: 0.66),
        Color(red: 0.93, green: 0.72, blue: 0.28),
        Color(red: 0.62, green: 0.54, blue: 0.95),
        Color(red: 0.90, green: 0.35, blue: 0.32),
        Color(red: 0.62, green: 0.70, blue: 0.30),
    ]
    static let other = Color.secondary.opacity(0.45)
}

// MARK: - KPI tile

private struct UsageTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    let caption: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 23, weight: .semibold).monospacedDigit())
                    .tracking(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                if let unit {
                    Text(unit).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.groupFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.11), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
    }
}

// MARK: - Daily chart card

private struct UsageBarCard: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每日消耗").font(.system(size: 13, weight: .semibold))
                    Text("\(summary.granularityNote) · \(summary.periodDays) 天 · 悬停查看明细")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(Fmt.compactTokens(summary.totals.total)) tok")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            UsageBarChart(buckets: summary.buckets)
                .frame(height: 208)
            UsageLegend()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}

private struct UsageLegend: View {
    private let items: [(Color, String)] = [
        (Theme.warn, "输出"),
        (Theme.blue, "未缓存输入"),
        (Theme.purple, "缓存写入"),
        (Theme.accent, "缓存读取"),
    ]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Circle().fill(item.0).frame(width: 6, height: 6)
                    Text(item.1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
}

private struct UsageBarChart: View {
    let buckets: [UsageDayBucket]
    @Environment(\.staticGlass) private var staticGlass
    @State private var hovered: Int?

    private let axisWidth: CGFloat = 46
    private let bottomInset: CGFloat = 20
    private let topInset: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: axisWidth, y: topInset,
                              width: max(1, geo.size.width - axisWidth),
                              height: max(1, geo.size.height - topInset - bottomInset))
            let rawMax = max(1, buckets.map(\.totals.total).max() ?? 1)
            let niceMax = max(4, Self.niceCeil(Double(rawMax)))
            let slot = plot.width / CGFloat(max(1, buckets.count))
            let barWidth = max(2, min(40, slot * 0.62))
            let labels = labelIndices

            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { i in
                    let y = plot.minY + plot.height * CGFloat(i) / 4
                    Rectangle()
                        .fill(i == 4 ? Color.primary.opacity(0.13) : Theme.hairline)
                        .frame(width: plot.width, height: 1)
                        .position(x: plot.midX, y: y)
                    Text(Fmt.compactTokens(Int((niceMax * (1 - Double(i) / 4)).rounded())))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: axisWidth - 8, alignment: .trailing)
                        .position(x: (axisWidth - 8) / 2 + 2, y: y)
                }

                ForEach(Array(buckets.enumerated()), id: \.element.id) { i, bucket in
                    let centerX = plot.minX + slot * (CGFloat(i) + 0.5)
                    if hovered == i {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: max(3, slot - 1), height: plot.height)
                            .position(x: centerX, y: plot.midY)
                    }
                    let h = bucket.totals.total > 0
                        ? max(2, plot.height * CGFloat(Double(bucket.totals.total) / niceMax))
                        : 2
                    if bucket.totals.total > 0 {
                        UsageStackedBar(totals: bucket.totals, width: barWidth, height: h)
                            .position(x: centerX, y: plot.maxY - h / 2)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.10))
                            .frame(width: barWidth, height: 2)
                            .position(x: centerX, y: plot.maxY - 1)
                    }
                }

                ForEach(labels, id: \.self) { i in
                    Text(buckets[i].axisLabel)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .position(x: plot.minX + slot * (CGFloat(i) + 0.5), y: plot.maxY + 12)
                }

                if let i = hovered, i >= 0, i < buckets.count {
                    let centerX = plot.minX + slot * (CGFloat(i) + 0.5)
                    let tipWidth: CGFloat = 164
                    let tipX = min(max(centerX, plot.minX + tipWidth / 2 + 2), plot.maxX - tipWidth / 2 - 2)
                    UsageChartTooltip(bucket: buckets[i])
                        .frame(width: tipWidth)
                        .position(x: tipX, y: plot.minY + 46)
                        .allowsHitTesting(false)
                }

                // Full-size transparent hit area. Its coordinates start at the chart's
                // left edge, so the y-axis width must be subtracted before picking a bar.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .named("usage-chart")) { phase in
                        // Screenshots are hosted off-screen; avoid a stray tooltip.
                        guard !staticGlass else { return }
                        switch phase {
                        case .active(let p):
                            guard plot.contains(p) else { hovered = nil; return }
                            let x = p.x - plot.minX
                            let idx = Int(x / max(0.001, slot))
                            hovered = max(0, min(buckets.count - 1, idx))
                        case .ended:
                            hovered = nil
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "usage-chart")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每日 token 消耗柱状图，共 \(buckets.count) 个时间段")
    }

    private var labelIndices: [Int] {
        guard buckets.count > 1 else { return buckets.isEmpty ? [] : [0] }
        let maxLabels = 7
        let step = max(1, Int(ceil(Double(buckets.count) / Double(maxLabels))))
        var out = Array(Swift.stride(from: 0, to: buckets.count, by: step))
        let last = buckets.count - 1
        if out.last != last {
            if let tail = out.last, last - tail < step / 2 { out.removeLast() }
            out.append(last)
        }
        return out
    }

    static func niceCeil(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let nice: Double
        if fraction <= 1 { nice = 1 }
        else if fraction <= 2 { nice = 2 }
        else if fraction <= 2.5 { nice = 2.5 }
        else if fraction <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * base
    }
}

private struct UsageStackedBar: View {
    let totals: TokenTotals
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let total = max(1, totals.total)
        VStack(spacing: 0) {
            segment(totals.output, total, Theme.warn)
            segment(totals.uncachedInput, total, Theme.blue)
            segment(totals.cacheWrite, total, Theme.purple)
            segment(totals.cacheRead, total, Theme.accent)
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: min(3, width / 2), style: .continuous))
    }

    private func segment(_ value: Int, _ total: Int, _ color: Color) -> some View {
        Rectangle().fill(color).frame(height: height * CGFloat(value) / CGFloat(total))
    }
}

private struct UsageChartTooltip: View {
    let bucket: UsageDayBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bucket.tooltipTitle)
                    .font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.compactTokens(bucket.totals.total))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            row("输出", bucket.totals.output, Theme.warn)
            row("未缓存输入", bucket.totals.uncachedInput, Theme.blue)
            row("缓存写入", bucket.totals.cacheWrite, Theme.purple)
            row("缓存读取", bucket.totals.cacheRead, Theme.accent)
            HStack {
                Text("请求").foregroundStyle(.secondary)
                Spacer()
                Text("\(bucket.totals.requests)")
            }
            .font(.system(size: 9.5).monospacedDigit())
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func row(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.compactTokens(value))
        }
        .font(.system(size: 9.5).monospacedDigit())
    }
}

// MARK: - Composition (donut + tool / token split)

private struct UsageCompositionCard: View {
    let summary: UsageSummary
    let selectedTool: String?
    let toolColors: [String: Color]
    let onSelect: (String?) -> Void

    private struct Component: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let value: Int
        let color: Color
        let selectable: Bool
    }

    private var filteredToolName: String? {
        selectedTool.flatMap { ToolRegistry.spec($0)?.name }
    }

    private var subtitle: String {
        if let filteredToolName { return "\(filteredToolName) 的输出与缓存占比" }
        return "\(summary.tools.count) 个工具 · \(summary.sessionCount) 个会话 · 点击工具可单独查看"
    }

    private var components: [Component] {
        if selectedTool != nil {
            let t = summary.totals
            let all: [Component] = [
                Component(id: "output", label: "输出", detail: nil, value: t.output, color: Theme.warn, selectable: false),
                Component(id: "input", label: "未缓存输入", detail: nil, value: t.uncachedInput, color: Theme.blue, selectable: false),
                Component(id: "read", label: "缓存读取", detail: nil, value: t.cacheRead, color: Theme.accent, selectable: false),
                Component(id: "write", label: "缓存写入", detail: nil, value: t.cacheWrite, color: Theme.purple, selectable: false),
            ]
            return all.filter { $0.value > 0 }
        }

        let top = Array(summary.tools.prefix(5))
        var out = top.map { t in
            Component(id: t.id, label: t.source.displayName,
                      detail: toolDetail(t), value: t.totals.total,
                      color: toolColors[t.id] ?? UsagePalette.other, selectable: true)
        }
        let rest = summary.tools.dropFirst(5)
        if !rest.isEmpty {
            let value = rest.reduce(0) { $0 + $1.totals.total }
            out.append(Component(id: "other", label: "其他 \(rest.count) 个工具",
                                 detail: nil, value: value, color: UsagePalette.other, selectable: false))
        }
        return out
    }

    private func toolDetail(_ tool: UsageTool) -> String {
        var parts = ["\(tool.sessionCount) 个会话"]
        if tool.cost.pricedTokens > 0 {
            parts.append("≈ \(Fmt.usd(tool.cost.usd))")
        } else if tool.totals.total > 0 {
            parts.append("价格未知")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let total = max(1, summary.totals.total)
        let slices = components.map { DonutSlice(id: $0.id, value: $0.value, color: $0.color) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTool == nil ? "工具构成" : "Token 构成")
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selectedTool != nil {
                    Button("查看全部工具") { onSelect(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                UsageDonut(slices: slices,
                           centerValue: Fmt.compactTokens(summary.totals.total),
                           centerTitle: selectedTool == nil ? "\(summary.tools.count) 个工具" : "总 Token")
                    .frame(width: 136, height: 136)
                    .padding(.top, 2)
                VStack(spacing: 5) {
                    ForEach(components) { c in
                        UsageCompositionRow(
                            label: c.label, detail: c.detail,
                            value: c.value, total: total, color: c.color,
                            selected: c.selectable && c.id == selectedTool,
                            action: c.selectable ? { onSelect(c.id) } : nil
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}

private struct DonutSlice: Identifiable {
    let id: String
    let value: Int
    let color: Color
}

private struct UsageDonut: View {
    let slices: [DonutSlice]
    let centerValue: String
    let centerTitle: String
    var lineWidth: CGFloat = 16

    var body: some View {
        let total = max(1, slices.reduce(0) { $0 + $1.value })
        let starts = arcStarts(total: total)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
                ForEach(Array(slices.enumerated()), id: \.element.id) { i, slice in
                    let from = starts[i]
                    let to = starts[i + 1]
                    let gap = slices.count > 1 ? min(0.012, (to - from) * 0.2) : 0
                    Circle()
                        .trim(from: from + gap / 2, to: max(from + gap / 2, to - gap / 2))
                        .stroke(slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 2) {
                    Text(centerValue)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .tracking(-0.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(centerTitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, lineWidth + 6)
            }
            .frame(width: side, height: side)
            .padding(lineWidth / 2)
        }
    }

    private func arcStarts(total: Int) -> [Double] {
        var out: [Double] = []
        var running = 0.0
        for s in slices {
            out.append(running)
            running += Double(s.value) / Double(total)
        }
        out.append(1)
        return out
    }
}

private struct UsageCompositionRow: View {
    let label: String
    let detail: String?
    let value: Int
    let total: Int
    let color: Color
    let selected: Bool
    let action: (() -> Void)?
    @State private var hover = false

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        let share = total > 0 ? Double(value) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.compactTokens(value))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    Text(Fmt.percent(share, digits: 0))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(2, g.size.width * CGFloat(share)))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.10) : (hover && action != nil ? Theme.groupFill : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Model cost breakdown

private struct UsageModelCostCard: View {
    let summary: UsageSummary

    private let limit = 5

    private var visible: [UsageModel] { Array(summary.models.prefix(limit)) }
    private var rest: [UsageModel] { Array(summary.models.dropFirst(limit)) }

    private var restTokens: Int { rest.reduce(0) { $0 + $1.totals.total } }
    private var restCost: CostEstimate {
        var total = CostEstimate()
        for model in rest { total.add(model.cost) }
        return total
    }

    private var subtitle: String {
        var parts = ["\(summary.models.count) 个模型", "按官方标价估算"]
        if summary.cost.unpricedTokens > 0 {
            parts.append("\(Fmt.compactTokens(summary.cost.unpricedTokens)) tok 价格未知")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let total = max(1, summary.totals.total)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型费用").font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(summary.cost.pricedTokens > 0 ? Fmt.usd(summary.cost.usd) : "—")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }

            VStack(spacing: 7) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, model in
                    UsageModelCostRow(
                        model: model,
                        share: Double(model.totals.total) / Double(total),
                        color: UsagePalette.toolColors[index % UsagePalette.toolColors.count]
                    )
                }
            }

            if !rest.isEmpty {
                HStack(spacing: 6) {
                    Text("另有 \(rest.count) 个模型")
                    Text("\(Fmt.compactTokens(restTokens)) tok").monospacedDigit()
                    if restCost.pricedTokens > 0 {
                        Text(Fmt.usd(restCost.usd)).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}

private struct UsageModelCostRow: View {
    let model: UsageModel
    let share: Double
    let color: Color

    private var priced: Bool { model.cost.unpricedTokens == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let raw = model.model,
                       raw.localizedCaseInsensitiveCompare(model.displayName) != .orderedSame {
                        Text(raw).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(priced ? Fmt.usd(model.cost.usd) : "价格未知")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(priced ? Color.primary : Color.secondary)
                    Text("\(Fmt.compactTokens(model.totals.total)) tok · \(Fmt.percent(share, digits: 0))")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(2, g.size.width * CGFloat(share)))
                }
            }
            .frame(height: 3)
            .padding(.leading, 15)
        }
        .help(priceHelp)
    }

    private var priceHelp: String {
        guard let price = ModelPricingTable.price(for: model.model) else {
            return "未找到该模型的公开标价，仅统计 token"
        }
        func unit(_ v: Double) -> String { String(format: "$%g", v) }
        return "官方标价 / 百万 token：输入 \(unit(price.input)) · 输出 \(unit(price.output)) · 缓存读 \(unit(price.cacheRead)) · 缓存写 \(unit(price.cacheCreation))"
    }
}

// MARK: - Tool chip

/// Wraps chips onto as many rows as the settings pane needs (macOS 13 `Layout`).
private struct UsageFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 10_000
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? max(0, x - spacing), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct UsageToolChip: View {
    let title: String
    let symbol: String?
    let color: Color?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                } else if let color {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .background(
                Capsule().fill(selected ? Theme.accent.opacity(0.15)
                                        : (hover ? Theme.raisedFill : Theme.groupFill))
            )
            .overlay(
                Capsule().strokeBorder(selected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Loading / empty

private struct UsageLoadingCard: View {
    let progress: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在统计本机日志…").font(.system(size: 13, weight: .medium))
            Text(progress ?? "第一次统计需要读取历史日志，之后会使用缓存。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}

private struct UsageEmptyCard: View {
    let hasTools: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.raisedFill).frame(width: 54, height: 54)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(hasTools ? "这个时间范围内还没有 token 记录" : "还没有检测到可读取 token 的工具")
                .font(.system(size: 14, weight: .semibold))
            Text(hasTools
                 ? "在支持的 agent 工具里开始对话后，这里会自动统计。"
                 : "可以到“Agent 工具”页重新扫描本机工具。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新统计", action: refresh)
                .controlSize(.regular)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.groupFill))
    }
}
