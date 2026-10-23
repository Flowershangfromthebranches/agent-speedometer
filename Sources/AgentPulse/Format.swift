import Foundation

enum Fmt {
    static func creditsNumber(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value == 0 { return "0" }
        if value < 0.0001 { return "<0.0001" }
        return String(format: value < 1 ? "%.4f" : "%.2f", value)
    }

    static func compactTokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1e9)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 10_000...: return String(format: "%.0fK", d / 1e3)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()

    static func tokens(_ n: Int) -> String { (grouped.string(from: NSNumber(value: n)) ?? "\(n)") + " tok" }

    static func tps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "— tok/s" }
        return v >= 100 ? String(format: "%.0f tok/s", v) : String(format: "%.1f tok/s", v)
    }

    static func tpsNumber(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func percent(_ f: Double?, digits: Int = 1) -> String {
        guard let f else { return "—" }
        return String(format: "%.\(digits)f%%", f * 100)
    }

    static func usd(_ v: Double?) -> String {
        guard let v, v.isFinite, v >= 0 else { return "—" }
        if v == 0 { return "$0.00" }
        if v < 0.01 { return "<$0.01" }
        if v < 10 { return String(format: "$%.2f", v) }
        if v < 1000 { return String(format: "$%.1f", v) }
        if v < 10_000 { return String(format: "$%.0f", v) }
        return String(format: "$%.1fK", v / 1000)
    }

    static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "—" }
        if t < 60 { return String(format: "%.1f秒", t) }
        let s = Int(t.rounded())
        if s < 3600 { return "\(s / 60)分\(s % 60)秒" }
        return "\(s / 3600)小时\((s % 3600) / 60)分"
    }

    static func shortElapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s < 60 ? "\(s)s" : "\(s / 60)m\(s % 60)s"
    }

    static func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}
