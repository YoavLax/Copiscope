import Foundation

// MARK: - Model Vendor

enum ModelVendor: String, CaseIterable, Sendable {
    case anthropic
    case openai
    case google

    static func from(model: String?) -> ModelVendor {
        guard let m = model?.lowercased() else { return .openai }
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet") || m.contains("haiku") {
            return .anthropic
        }
        if m.contains("gemini") {
            return .google
        }
        return .openai
    }

    static func from(provider: String?) -> ModelVendor {
        guard let p = provider?.lowercased() else { return .openai }
        if p.contains("anthropic") { return .anthropic }
        if p.contains("google") || p.contains("gemini") || p.contains("gcp") { return .google }
        return .openai
    }
}

// MARK: - Model Billing (from models.json)

struct ModelBilling: Sendable {
    let id: String
    let name: String
    let vendor: String
    let multiplier: Double
    let isPremium: Bool
    let category: String  // "powerful", "versatile", "lightweight"
    let maxContextTokens: Int?
    let maxOutputTokens: Int?

    static let unknown = ModelBilling(
        id: "unknown", name: "Unknown", vendor: "unknown",
        multiplier: 1.0, isPremium: true, category: "versatile",
        maxContextTokens: nil, maxOutputTokens: nil
    )
}

// MARK: - Model Catalog (loaded from models.json)

struct ModelCatalog: Sendable {
    let models: [String: ModelBilling]

    func billing(for modelId: String?) -> ModelBilling {
        guard let id = modelId else { return .unknown }
        // Try exact match, then prefix match
        if let b = models[id] { return b }
        for (key, b) in models {
            if id.hasPrefix(key) || key.hasPrefix(id) { return b }
        }
        return .unknown
    }

    static let empty = ModelCatalog(models: [:])
}

// MARK: - Token Pricing (per-vendor rates, per MTok)

struct TokenPricing: Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    static let unknown = TokenPricing(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
}

struct PricingTables {
    // All prices are per 1 million tokens in USD.
    // Source: https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
    // 1 AI credit = $0.01 USD; prices in the table are in AI credits per MTok = USD per MTok.
    static let byModel: [String: TokenPricing] = [
        // Anthropic — Copilot-proxied IDs (e.g. "copilot/claude-sonnet-4.6")
        "claude-opus-4.7":   TokenPricing(input: 5.00,  output: 25.00, cacheRead: 0.50,  cacheWrite: 6.25),
        "claude-opus-4.6":   TokenPricing(input: 5.00,  output: 25.00, cacheRead: 0.50,  cacheWrite: 6.25),
        "claude-opus-4.5":   TokenPricing(input: 5.00,  output: 25.00, cacheRead: 0.50,  cacheWrite: 6.25),
        "claude-sonnet-4.6": TokenPricing(input: 3.00,  output: 15.00, cacheRead: 0.30,  cacheWrite: 3.75),
        "claude-sonnet-4.5": TokenPricing(input: 3.00,  output: 15.00, cacheRead: 0.30,  cacheWrite: 3.75),
        "claude-sonnet-4":   TokenPricing(input: 3.00,  output: 15.00, cacheRead: 0.30,  cacheWrite: 3.75),
        "claude-haiku-4.5":  TokenPricing(input: 1.00,  output: 5.00,  cacheRead: 0.10,  cacheWrite: 1.25),
        // OpenAI
        "gpt-5.5":           TokenPricing(input: 5.00,  output: 30.00, cacheRead: 0.50,  cacheWrite: 0),
        "gpt-5.4":           TokenPricing(input: 2.50,  output: 15.00, cacheRead: 0.25,  cacheWrite: 0),
        "gpt-5.4-mini":      TokenPricing(input: 0.75,  output: 4.50,  cacheRead: 0.075, cacheWrite: 0),
        "gpt-5.4-nano":      TokenPricing(input: 0.20,  output: 1.25,  cacheRead: 0.02,  cacheWrite: 0),
        "gpt-5.3-codex":     TokenPricing(input: 1.75,  output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.2-codex":     TokenPricing(input: 1.75,  output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.2":           TokenPricing(input: 1.75,  output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5-mini":        TokenPricing(input: 0.25,  output: 2.00,  cacheRead: 0.025, cacheWrite: 0),
        "gpt-4.1":           TokenPricing(input: 2.00,  output: 8.00,  cacheRead: 0.50,  cacheWrite: 0),
        "gpt-4o":            TokenPricing(input: 2.50,  output: 10.00, cacheRead: 1.25,  cacheWrite: 0),
        "gpt-4o-mini":       TokenPricing(input: 0.15,  output: 0.60,  cacheRead: 0.075, cacheWrite: 0),
        // Google
        "gemini-3.1-pro":    TokenPricing(input: 2.00,  output: 12.00, cacheRead: 0.20,  cacheWrite: 0),
        "gemini-3-flash":    TokenPricing(input: 0.50,  output: 3.00,  cacheRead: 0.05,  cacheWrite: 0),
        "gemini-2.5-pro":    TokenPricing(input: 1.25,  output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        // xAI
        "grok-code-fast-1":  TokenPricing(input: 0.20,  output: 1.50,  cacheRead: 0.02,  cacheWrite: 0),
    ]

    static func pricing(for model: String?) -> TokenPricing {
        guard let m = model?.lowercased() else { return .unknown }
        // Strip "copilot/" prefix used in chatSessions modelId
        let stripped = m.hasPrefix("copilot/") ? String(m.dropFirst(8)) : m
        // Exact match
        if let p = byModel[stripped] { return p }
        // Prefix match (e.g. "claude-sonnet-4.6-20241022" → "claude-sonnet-4.6")
        // Use longest-match-wins to avoid gpt-4o matching gpt-4o-mini-* models.
        var bestKey: String? = nil
        var bestLength = 0
        for key in byModel.keys {
            if stripped.hasPrefix(key) || key.hasPrefix(stripped) {
                let matchLen = min(key.count, stripped.count)
                if matchLen > bestLength {
                    bestLength = matchLen
                    bestKey = key
                }
            }
        }
        if let k = bestKey, let p = byModel[k] { return p }
        // Family fallbacks
        if stripped.contains("opus")   { return byModel["claude-opus-4.6"] ?? .unknown }
        if stripped.contains("sonnet") { return byModel["claude-sonnet-4.6"] ?? .unknown }
        if stripped.contains("haiku")  { return byModel["claude-haiku-4.5"] ?? .unknown }
        if stripped.contains("gpt-4o-mini") { return byModel["gpt-4o-mini"] ?? .unknown }
        if stripped.contains("gpt-4o") { return byModel["gpt-4o"] ?? .unknown }
        if stripped.contains("gpt-4.1") { return byModel["gpt-4.1"] ?? .unknown }
        if stripped.contains("gemini-3.1") { return byModel["gemini-3.1-pro"] ?? .unknown }
        if stripped.contains("gemini-3") { return byModel["gemini-3-flash"] ?? .unknown }
        if stripped.contains("gemini") { return byModel["gemini-2.5-pro"] ?? .unknown }
        return .unknown
    }
}

// MARK: - Cost Estimation

func estimateCostFromTokens(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cachedTokens: Int,
    cacheCreationTokens: Int = 0
) -> Double {
    let p = PricingTables.pricing(for: model)
    // Input tokens include cached; separate out uncached input
    let uncachedInput = max(0, inputTokens - cachedTokens)
    return (Double(uncachedInput) / 1e6) * p.input
         + (Double(outputTokens) / 1e6) * p.output
         + (Double(cachedTokens) / 1e6) * p.cacheRead
         + (Double(cacheCreationTokens) / 1e6) * p.cacheWrite
}

// MARK: - Copilot Plans

enum CopilotPlan: String, CaseIterable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case proPlus = "Pro+"
    case business = "Business"
    case enterprise = "Enterprise"
}

// MARK: - models.json Loader

struct ModelsJsonEntry: Decodable, Sendable {
    let id: String
    let name: String?
    let vendor: String?
    let version: String?
    let billing: ModelsJsonBilling?
    let capabilities: ModelsJsonCapabilities?
    let modelPickerCategory: String?

    enum CodingKeys: String, CodingKey {
        case id, name, vendor, version, billing, capabilities
        case modelPickerCategory = "model_picker_category"
    }
}

struct ModelsJsonBilling: Decodable, Sendable {
    let isPremium: Bool?
    let multiplier: Double?
    let restrictedTo: [String]?

    enum CodingKeys: String, CodingKey {
        case isPremium = "is_premium"
        case multiplier
        case restrictedTo = "restricted_to"
    }
}

struct ModelsJsonCapabilities: Decodable, Sendable {
    let family: String?
    let limits: ModelsJsonLimits?
}

struct ModelsJsonLimits: Decodable, Sendable {
    let maxContextWindowTokens: Int?
    let maxOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case maxContextWindowTokens = "max_context_window_tokens"
        case maxOutputTokens = "max_output_tokens"
    }
}

func loadModelCatalog(from data: Data) -> ModelCatalog {
    guard let entries = try? JSONDecoder().decode([ModelsJsonEntry].self, from: data) else {
        return .empty
    }
    var models: [String: ModelBilling] = [:]
    for entry in entries {
        models[entry.id] = ModelBilling(
            id: entry.id,
            name: entry.name ?? entry.id,
            vendor: entry.vendor ?? "unknown",
            multiplier: entry.billing?.multiplier ?? 1.0,
            isPremium: entry.billing?.isPremium ?? true,
            category: entry.modelPickerCategory ?? "versatile",
            maxContextTokens: entry.capabilities?.limits?.maxContextWindowTokens,
            maxOutputTokens: entry.capabilities?.limits?.maxOutputTokens
        )
    }
    return ModelCatalog(models: models)
}
