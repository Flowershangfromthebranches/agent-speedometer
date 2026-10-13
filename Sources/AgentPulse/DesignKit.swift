import AppKit
import SwiftUI

// Shared look for the floating bar, the menu-bar popovers, settings and the session browser:
// Liquid Glass surfaces (macOS 26+, frosted material before that), one accent color,
// big tabular numbers and grouped inset rows.

enum Theme {
    /// The one accent: speed lines, rings, cache hit. Darker in light mode so text stays readable.
    static let accent = dynamic(light: (0.0, 0.45, 0.70), dark: (0.392, 0.824, 1.0))
    /// "Generating" only.
    static let live = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let warn = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let purple = Color(red: 0.749, green: 0.353, blue: 0.949)
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)

    static let groupFill = Color.primary.opacity(0.06)
    static let raisedFill = Color.primary.opacity(0.12)
    static let hairline = Color.primary.opacity(0.08)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Glass surface

private struct StaticGlassKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Screenshots have no real backdrop to blur: draw glass as a tinted fill instead.
    var staticGlass: Bool {
        get { self[StaticGlassKey.self] }
        set { self[StaticGlassKey.self] = newValue }
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.staticGlass) private var staticGlass
    let shape: S

    func body(content: Content) -> some View {
        if staticGlass {
            content
                .background(shape.fill(Color(red: 0.13, green: 0.14, blue: 0.17).opacity(0.86)))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.09), .clear],
                                                   startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false))
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectBackground(material: .hudWindow).clipShape(shape))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        }
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View { modifier(GlassSurface(shape: shape)) }

    /// A grouped inset box, the container for rows and tiles inside a glass surface.
    func insetGroup(radius: CGFloat = 18, padding: CGFloat = 14) -> some View {
        self.padding(.horizontal, padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.groupFill))
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Small pieces

struct LiveDot: View {
    var on: Bool
    var size: CGFloat = 7
    var body: some View {
        Circle()
            .fill(on ? Theme.live : Color.secondary.opacity(0.45))
            .frame(width: size, height: size)
            .shadow(color: on ? Theme.live.opacity(0.8) : .clear, radius: 4)
    }
}

/// Generating timer or idle, for one session.
struct ActivityLabel: View {
    let s: SessionStats
    var body: some View {
        HStack(spacing: 6) {
            LiveDot(on: s.waitingSince != nil)
            if let w = s.waitingSince {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("生成中 · \(Fmt.shortElapsed(ctx.date.timeIntervalSince(w)))")
                }
            } else {
                Text("空闲 · \(Fmt.relative(s.lastActivity ?? Date()))")
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct RingView: View {
    let fraction: Double
    var lineWidth: CGFloat = 2.5
    var color: Color? = nil
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color ?? (fraction > 0.85 ? Theme.warn : Theme.accent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct MiniBar: View {
    let fraction: Double
    var width: CGFloat = 44
    var height: CGFloat = 4
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14))
            Capsule().fill(fraction > 0.85 ? Theme.warn : Theme.accent)
                .frame(width: max(height, width * min(1, fraction)))
        }
        .frame(width: width, height: height)
    }
}

/// A tool's symbol in a circle, with a green corner dot while it's generating.
struct ToolBadge: View {
    let symbol: String
    var generating = false
    var size: CGFloat = 34
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Theme.raisedFill)
                .frame(width: size, height: size)
                .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)))
            if generating {
                Circle().fill(Theme.live)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(white: 0.17), lineWidth: 2))
            }
        }
    }
}

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 36
    var help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Big number with a small unit, the hero of each detail view.
struct HeroNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 52
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .tracking(-size * 0.035)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: size * 0.31, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).lineLimit(1)
                if let unit { Text(unit).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.groupFill))
    }
}

/// One line of an inset group; draws its own divider unless it's the last.
struct InfoRow: View {
    let label: String
    let value: String
    var dot: Color? = nil
    var dimValue = false
    var divider = true
    var body: some View {
        HStack(spacing: 10) {
            if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(dimValue ? .regular : .medium)
                .foregroundStyle(dimValue ? .secondary : .primary)
                .lineLimit(1)
        }
        .font(.system(size: 12.5).monospacedDigit())
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

struct Footnote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10.5))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Capsule segmented control.
struct SegmentedTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                let on = value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if on {
                                Capsule().fill(Color.primary.opacity(0.16))
                                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Sparkline

/// Per-step output speed, newest on the right, with the session average dashed.
struct Sparkline: View {
    let values: [Double]
    var average: Double? = nil
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                if let y = averageY(in: g.size) {
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y)) }
                        .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if pts.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 2))
                        .position(pts[pts.count - 1])
                } else {
                    Text("步数不足，暂无走势")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("最近 \(values.count) 步的输出速度走势")
    }

    private var range: (Double, Double)? {
        var all = values
        if let average { all.append(average) }
        guard let lo = all.min(), let hi = all.max() else { return nil }
        let pad = max((hi - lo) * 0.15, 1)
        return (lo - pad, hi + pad)
    }

    private func y(_ v: Double, _ size: CGSize) -> CGFloat {
        guard let (lo, hi) = range, hi > lo else { return size.height / 2 }
        let inset: CGFloat = 4
        return inset + (size.height - inset * 2) * CGFloat(1 - (v - lo) / (hi - lo))
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let step = (size.width - 4) / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in CGPoint(x: CGFloat(i) * step, y: y(v, size)) }
    }

    private func averageY(in size: CGSize) -> CGFloat? {
        guard let average, values.count >= 2 else { return nil }
        return y(average, size)
    }
}

// MARK: - Token breakdown bar

struct TokenSlice: Identifiable {
    let id: String
    let label: String
    let value: Int
    let color: Color
}

extension SessionStats {
    var tokenSlices: [TokenSlice] {
        var out = [TokenSlice(id: "read", label: "缓存读取", value: cacheRead, color: Theme.accent)]
        if cacheWrite > 0 { out.append(TokenSlice(id: "write", label: "缓存写入", value: cacheWrite, color: Theme.purple)) }
        out.append(TokenSlice(id: "input", label: "未缓存输入", value: uncachedInput, color: Theme.blue))
        out.append(TokenSlice(id: "output", label: "输出", value: outputTokens, color: Theme.warn))
        return out
    }
}

struct TokenBar: View {
    let slices: [TokenSlice]
    var body: some View {
        GeometryReader { g in
            let total = max(1, slices.reduce(0) { $0 + $1.value })
            let minW: CGFloat = 6
            let gaps = CGFloat(max(0, slices.count - 1)) * 2
            let free = g.size.width - gaps - minW * CGFloat(slices.count)
            HStack(spacing: 2) {
                ForEach(slices) { sl in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(sl.color)
                        .frame(width: minW + max(0, free) * CGFloat(sl.value) / CGFloat(total))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(slices.map { "\($0.label) \(Fmt.compactTokens($0.value))" }.joined(separator: "，"))
    }
}
