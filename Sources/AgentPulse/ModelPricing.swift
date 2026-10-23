import Foundation

/// USD per million tokens, adapted from CC-Switch's seeded price table
/// (src-tauri/src/database/schema.rs) and the vendors' public price pages.
struct ModelPrice {
    let displayName: String
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheCreation: Double
}

struct CostEstimate: Equatable {
    var usd: Double = 0
    var pricedTokens = 0
    var unpricedTokens = 0

    var totalTokens: Int { pricedTokens + unpricedTokens }
    var isComplete: Bool { unpricedTokens == 0 }

    mutating func add(_ other: CostEstimate) {
        usd += other.usd
        pricedTokens += other.pricedTokens
        unpricedTokens += other.unpricedTokens
    }
}

enum ModelPricingTable {
    /// Prices are list prices for one million tokens. Cache creation is the
    /// 5-minute TTL price; Claude 1-hour writes are billed at 2× input (1.6×
    /// this column) and handled by `estimate`.
    static let prices: [String: ModelPrice] = [
        // Anthropic
        "claude-fable-5-1": p("Claude Fable 5.1", 10, 50, 0.25, 12.50),
        "claude-mythos-5-1": p("Claude Mythos 5.1", 10, 50, 0.25, 12.50),
        "claude-fable-5": p("Claude Fable 5", 10, 50, 1.00, 12.50),
        "claude-mythos-5": p("Claude Mythos 5", 10, 50, 1.00, 12.50),
        "claude-opus-5-5": p("Claude Opus 5.5", 4, 20, 0.20, 5),
        "claude-opus-5": p("Claude Opus 5", 5, 25, 0.50, 6.25),
        "claude-opus-4-8": p("Claude Opus 4.8", 5, 25, 0.50, 6.25),
        "claude-opus-4-7": p("Claude Opus 4.7", 5, 25, 0.50, 6.25),
        "claude-opus-4-6": p("Claude Opus 4.6", 5, 25, 0.50, 6.25),
        "claude-opus-4-5": p("Claude Opus 4.5", 5, 25, 0.50, 6.25),
        "claude-opus-4-1": p("Claude Opus 4.1", 15, 75, 1.50, 18.75),
        "claude-opus-4": p("Claude Opus 4", 15, 75, 1.50, 18.75),
        "claude-sonnet-5-5": p("Claude Sonnet 5.5", 2, 10, 0.10, 2.50),
        "claude-sonnet-5": p("Claude Sonnet 5", 2, 10, 0.20, 2.50),
        "claude-sonnet-4-6": p("Claude Sonnet 4.6", 3, 15, 0.30, 3.75),
        "claude-sonnet-4-5": p("Claude Sonnet 4.5", 3, 15, 0.30, 3.75),
        "claude-sonnet-4": p("Claude Sonnet 4", 3, 15, 0.30, 3.75),
        "claude-haiku-5-5": p("Claude Haiku 5.5", 0.10, 0.50, 0.01, 0.125),
        "claude-haiku-4-5": p("Claude Haiku 4.5", 1, 5, 0.10, 1.25),
        "claude-3-5-haiku": p("Claude 3.5 Haiku", 0.80, 4, 0.08, 1),
        "claude-3-5-sonnet": p("Claude 3.5 Sonnet", 3, 15, 0.30, 3.75),

        // OpenAI
        "gpt-6-astra": p("GPT-6 Astra", 10, 50, 1, 12.5),
        "gpt-6.1-sol": p("GPT-6.1 Sol", 2, 10, 0.10, 2.50),
        "gpt-6-sol": p("GPT-6 Sol", 2, 10, 0.20, 2.50),
        "gpt-6-luna": p("GPT-6 Luna", 0.10, 0.50, 0.01, 0.125),
        "gpt-5.6-sol": p("GPT-5.6 Sol", 4, 20, 0.40, 5),
        "gpt-5.6-terra": p("GPT-5.6 Terra", 2, 12, 0.20, 2.50),
        "gpt-5.6-luna": p("GPT-5.6 Luna", 0.20, 1.20, 0.02, 0.25),
        "gpt-5.6-cyber": p("GPT-5.6 Cyber", 12.50, 75, 1.25, 15.625),
        "gpt-5.6": p("GPT-5.6 Sol", 4, 20, 0.40, 5),
        "gpt-5.5": p("GPT-5.5", 5, 30, 0.50, 0),
        "gpt-5.4": p("GPT-5.4", 2.50, 15, 0.25, 0),
        "gpt-5.4-mini": p("GPT-5.4 Mini", 0.75, 4.50, 0.075, 0),
        "gpt-5.4-nano": p("GPT-5.4 Nano", 0.20, 1.25, 0.02, 0),
        "gpt-5.3-codex-spark": p("GPT-5.3 Codex Spark", 1.75, 14, 0.175, 0),
        "gpt-5.3-codex": p("GPT-5.3 Codex", 1.75, 14, 0.175, 0),
        "gpt-5.2-codex": p("GPT-5.2 Codex", 1.75, 14, 0.175, 0),
        "gpt-5.2": p("GPT-5.2", 1.75, 14, 0.175, 0),
        "gpt-5.1-codex": p("GPT-5.1 Codex", 1.25, 10, 0.125, 0),
        "gpt-5-codex": p("GPT-5 Codex", 1.25, 10, 0.125, 0),
        "gpt-5": p("GPT-5", 1.25, 10, 0.125, 0),
        "gpt-5-mini": p("GPT-5 Mini", 0.25, 2, 0.025, 0),
        "gpt-5-nano": p("GPT-5 Nano", 0.05, 0.40, 0.005, 0),
        "codex-mini": p("Codex Mini", 0.75, 3, 0.025, 0),
        "o3-pro": p("OpenAI o3-pro", 20, 80, 0, 0),
        "o3-mini": p("OpenAI o3-mini", 1.10, 4.40, 0.55, 0),
        "o1": p("OpenAI o1", 15, 60, 7.50, 0),
        "o1-mini": p("OpenAI o1-mini", 0.55, 2.20, 0.55, 0),

        // DeepSeek. V4 models use peak-hour list prices; off-peak is half.
        "deepseek-v4.1-flash": p("DeepSeek V4.1 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-v4-flash": p("DeepSeek V4 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-flash": p("DeepSeek V4.1 Flash", 0.3, 1.2, 0.006, 0),
        "deepseek-v4-pro": p("DeepSeek V4 Pro", 1.32, 3.96, 0.044, 0),
        "deepseek-v3.2": p("DeepSeek V3.2", 0.28, 0.42, 0.028, 0),
        "deepseek-v3.1": p("DeepSeek V3.1", 0.55, 1.67, 0.055, 0),
        "deepseek-v3": p("DeepSeek V3", 0.28, 1.11, 0.028, 0),
        "deepseek-chat": p("DeepSeek Chat", 0.44, 1.32, 0.014, 0),
        "deepseek-reasoner": p("DeepSeek Reasoner", 0.44, 1.32, 0.014, 0),
        "deepseek-v4-flash-free": p("DeepSeek V4 Flash Free", 0, 0, 0, 0),

        // Moonshot / Kimi
        "kimi-k3": p("Kimi K3", 3, 15, 0.30, 3),
        "k3": p("Kimi K3", 3, 15, 0.30, 3),
        "kimi-k2.7-code-highspeed": p("Kimi K2.7 Code HighSpeed", 1.90, 8, 0.38, 0),
        "kimi-k2.7-code": p("Kimi K2.7 Code", 0.95, 4, 0.19, 0),
        "kimi-k2.7": p("Kimi K2.7", 0.95, 4, 0.19, 0),
        "kimi-k2.6": p("Kimi K2.6", 0.95, 4, 0.16, 0),
        "kimi-k2.5": p("Kimi K2.5", 0.60, 3, 0.10, 0),
        "kimi-k2-thinking": p("Kimi K2 Thinking", 0.55, 2.20, 0.10, 0),
        "kimi-k2-turbo": p("Kimi K2 Turbo", 1.11, 8.06, 0.14, 0),
        "kimi-k2-0905": p("Kimi K2", 0.55, 2.20, 0.10, 0),

        // Tencent Hunyuan
        "hunyuan-hy3": p("Hunyuan Hy3", 0.14, 0.56, 0.035, 0),
        "hy3": p("Hunyuan Hy3", 0.14, 0.56, 0.035, 0),
        "hy4-preview": p("Hunyuan Hy4 Preview", 0.84, 2.52, 0.042, 0),

        // Zhipu GLM
        "glm-5.3-flashx": p("GLM-5.3-FlashX", 0.37, 1.25, 0.075, 0),
        "glm-5.3-flash": p("GLM-5.3-Flash", 0.15, 0.50, 0.03, 0),
        "glm-5.3": p("GLM-5.3", 1.4, 4.4, 0.26, 0),
        "glm-5.2": p("GLM-5.2", 1.4, 4.4, 0.26, 0),
        "glm-5.1": p("GLM-5.1", 1.4, 4.4, 0.26, 0),
        "glm-5": p("GLM-5", 1, 3.2, 0.2, 0),
        "glm-5-turbo": p("GLM-5-Turbo", 1.2, 4, 0.24, 0),
        "glm-5v-turbo": p("GLM-5V-Turbo", 1.2, 4, 0.24, 0),
        "glm-4.7": p("GLM-4.7", 0.6, 2.2, 0.11, 0),
        "glm-4.6": p("GLM-4.6", 0.6, 2.2, 0.11, 0),

        // Xiaomi MiMo
        "mimo-v2.6-pro-ultraspeed": p("MiMo V2.6 Pro UltraSpeed", 4.35, 8.7, 0.036, 0),
        "mimo-v2.6-pro": p("MiMo V2.6 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2.6-flash": p("MiMo V2.6 Flash", 0.14, 0.28, 0.0028, 0),
        "mimo-v2.5-pro": p("MiMo V2.5 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2.5": p("MiMo V2.5", 0.14, 0.28, 0.0028, 0),
        "mimo-v2.5-free": p("MiMo V2.5 Free", 0, 0, 0, 0),
        "mimo-v2-pro": p("MiMo V2 Pro", 0.435, 0.87, 0.0036, 0),
        "mimo-v2-flash": p("MiMo V2 Flash", 0.09, 0.29, 0.009, 0),

        // Alibaba Qwen
        "qwen3.8-max": p("Qwen3.8 Max", 2, 6, 0.25, 2.50),
        "qwen3.8-flash": p("Qwen3.8 Flash", 0.15, 0.47, 0.016, 0.20),
        "qwen3.8-2.4t-a95b": p("Qwen3.8 2.4T A95B", 2, 6, 0.25, 2.50),
        "qwen3.8-27b": p("Qwen3.8 27B", 0.50, 3, 0.10, 0.625),
        "qwen3.7-max": p("Qwen3.7 Max", 2.50, 7.50, 0.25, 0),
        "qwen3.7-plus": p("Qwen3.7 Plus", 0.40, 1.60, 0.08, 0),
        "qwen3.7-flash": p("Qwen3.7 Flash", 0.03, 0.13, 0.006, 0.0375),
        "qwen3.6-27b": p("Qwen3.6 27B", 0.60, 3.60, 0, 0),

        // MiniMax
        "minimax-m3.1-flash": p("MiniMax M3.1 Flash", 0.15, 0.60, 0.015, 0),
        "minimax-m2.1": p("MiniMax M2.1", 0.30, 1.20, 0.03, 0.375),

        // StepFun
        "step-5-preview": p("Step 5 Preview", 0.98, 2.80, 0.10, 0),
        "step-3.7-flash": p("Step 3.7 Flash", 0.19, 1.13, 0.04, 0),
        "step-3.5-flash": p("Step 3.5 Flash", 0.10, 0.30, 0.02, 0),

        // xAI Grok. Build variants share the base model's list price.
        "grok-4.7-build": p("Grok 4.7 Build", 2, 6, 0.50, 0),
        "grok-4.6-build": p("Grok 4.6 Build", 2, 6, 0.50, 0),
        "grok-4.5-build": p("Grok 4.5 Build", 2, 6, 0.30, 0),
        "grok-4.7": p("Grok 4.7", 2, 6, 0.50, 0),
        "grok-4.6": p("Grok 4.6", 2, 6, 0.50, 0),
        "grok-4.5": p("Grok 4.5", 2, 6, 0.30, 0),
        "grok-4": p("Grok 4", 3, 15, 0.75, 0),
        "grok-3": p("Grok 3", 3, 15, 0.75, 0),
        "grok-3-mini": p("Grok 3 Mini", 0.25, 0.50, 0.075, 0),

        // Google
        "gemini-3.8-flash": p("Gemini 3.8 Flash", 0.75, 3.75, 0.075, 0),
        "gemini-3.5-flash": p("Gemini 3.5 Flash", 1.50, 9.00, 0.15, 0),

        // ByteDance Doubao (Seed 2.1 list prices, USD converted)
        "doubao-seed-2-1-pro": p("Doubao Seed 2.1 Pro", 0.84, 4.20, 0.17, 0),
        "doubao-seed-2-1-turbo": p("Doubao Seed 2.1 Turbo", 0.42, 2.10, 0.08, 0),
        "doubao-seed-2-0-pro": p("Doubao Seed 2.0 Pro", 0.47, 2.37, 0.09, 0),
        "doubao-seed-code": p("Doubao Seed Code", 0.17, 1.11, 0.02, 0),

        // OpenCode Zen free/stealth models
        "space-bunny": p("Space Bunny", 0, 0, 0, 0),
        "big-pickle": p("Big Pickle", 0, 0, 0, 0),
    ]

    private static func p(_ name: String, _ input: Double, _ output: Double,
                          _ read: Double, _ creation: Double) -> ModelPrice {
        ModelPrice(displayName: name, input: input, output: output,
                   cacheRead: read, cacheCreation: creation)
    }

    static func displayName(for model: String?) -> String {
        guard let model, !model.isEmpty else { return "未知模型" }
        return price(for: model)?.displayName ?? model
    }

    static func price(for model: String?) -> ModelPrice? {
        guard let key = canonicalKey(for: model) else { return nil }
        return prices[key]
    }

    /// The table key a logged model id resolves to. Used both for pricing and for
    /// merging provider variants (`stepfun/step-5-preview` and `step-5-preview`)
    /// into one row. Unknown ids fall back to their cleaned spelling.
    static func canonicalKey(for model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let candidates = candidates(for: model)
        for candidate in candidates {
            if prices[candidate] != nil { return candidate }
        }

        // Longest table key that is a token-boundary prefix of a candidate.
        // Covers variants like hy4-preview-x, glm-5.2-x, kimi-k3-1 and
        // deepseek-v4-flash-0731 without inventing exact rows for each.
        var bestKey: String?
        for candidate in candidates {
            for key in prices.keys where tokenPrefix(key, of: candidate) {
                if key.count > (bestKey?.count ?? 0) { bestKey = key }
            }
        }
        return bestKey ?? candidates.first
    }

    /// Estimated USD for one bucket. Cache creation is split into 5-minute and
    /// 1-hour writes; the 1-hour TTL is billed at 2× input, i.e. 1.6× the
    /// 5-minute column (same rule as CC-Switch's cost calculator).
    static func estimate(totals: TokenTotals, model: String?) -> CostEstimate {
        guard let price = price(for: model) else {
            return CostEstimate(usd: 0, pricedTokens: 0, unpricedTokens: totals.total)
        }
        let million = 1_000_000.0
        let write1h = max(0, min(totals.cacheWrite1h, totals.cacheWrite))
        let write5m = max(0, totals.cacheWrite - write1h)
        let cost =
            Double(totals.uncachedInput) * price.input / million
            + Double(totals.output) * price.output / million
            + Double(totals.cacheRead) * price.cacheRead / million
            + Double(write5m) * price.cacheCreation / million
            + Double(write1h) * price.cacheCreation * 1.6 / million
        return CostEstimate(usd: cost, pricedTokens: totals.total, unpricedTokens: 0)
    }

    // MARK: Model id normalization

    /// All plausible table keys for a logged model id, most specific first.
    /// Mirrors CC-Switch's candidate walk: strip provider namespace, dates,
    /// versions and reasoning-effort suffixes before falling back to prefixes.
    static func candidates(for model: String) -> [String] {
        var cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = cleaned.lastIndex(of: "/") {
            cleaned = String(cleaned[cleaned.index(after: slash)...])
        }
        if let colon = cleaned.firstIndex(of: ":") {
            cleaned = String(cleaned[..<colon])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: "(1m)", with: "")
            .replacingOccurrences(of: "[1m]", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))

        var queue = [cleaned]
        var out: [String] = []
        var seen = Set<String>()
        while let candidate = queue.popLast() {
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
            out.append(candidate)

            if let clause = candidate.range(of: "claude-", options: .backwards),
               clause.lowerBound != candidate.startIndex {
                queue.append(String(candidate[clause.lowerBound...]))
            }
            for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.",
                           "bedrock.", "global.", "stepfun."] where candidate.hasPrefix(marker) {
                queue.append(String(candidate.dropFirst(marker.count)))
            }
            if let stripped = stripVersion(candidate) { queue.append(stripped) }
            if let stripped = stripDate(candidate) { queue.append(stripped) }
            if let stripped = stripEffort(candidate) { queue.append(stripped) }
            if let stripped = stripLatest(candidate) { queue.append(stripped) }
            if candidate.hasPrefix("claude-"), candidate.contains(".") {
                queue.append(candidate.replacingOccurrences(of: ".", with: "-"))
            }
        }
        return out
    }

    private static func stripVersion(_ s: String) -> String? {
        guard let r = s.range(of: "-v", options: .backwards) else { return nil }
        let suffix = s[r.upperBound...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        let base = String(s[..<r.lowerBound])
        return base.isEmpty ? nil : base
    }

    private static func stripDate(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        if bytes.count > 11 {
            let start = bytes.count - 11
            let suffix = Array(bytes[start...])
            if suffix[0] == UInt8(ascii: "-"),
               suffix[1...4].allSatisfy({ $0 >= 48 && $0 <= 57 }),
               suffix[5] == UInt8(ascii: "-"),
               suffix[6...7].allSatisfy({ $0 >= 48 && $0 <= 57 }),
               suffix[8] == UInt8(ascii: "-"),
               suffix[9...10].allSatisfy({ $0 >= 48 && $0 <= 57 }) {
                return String(s.prefix(start))
            }
        }
        guard let dash = s.lastIndex(of: "-") else { return nil }
        let suffix = s[s.index(after: dash)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        if suffix.count == 8 { return String(s[..<dash]) }
        if suffix.count == 6 {
            let digits = Array(suffix)
            let month = Int(String(digits[2...3])) ?? 0
            let day = Int(String(digits[4...5])) ?? 0
            if (1...12).contains(month), (1...31).contains(day) { return String(s[..<dash]) }
        }
        return nil
    }

    private static func stripEffort(_ s: String) -> String? {
        for suffix in ["-minimal", "-low", "-medium", "-high", "-xhigh"] where s.hasSuffix(suffix) {
            let base = String(s.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return nil
    }

    private static func stripLatest(_ s: String) -> String? {
        for suffix in ["-latest", "-preview"] where s.hasSuffix(suffix) {
            let base = String(s.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return nil
    }

    private static func tokenPrefix(_ key: String, of candidate: String) -> Bool {
        guard candidate.count > key.count, candidate.hasPrefix(key) else { return false }
        let next = candidate[candidate.index(candidate.startIndex, offsetBy: key.count)]
        return next == "-" || next == "."
    }
}
