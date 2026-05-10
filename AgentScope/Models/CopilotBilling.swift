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
    static let byModel: [String: TokenPricing] = [
        // Anthropic (Copilot proxied)
        "claude-opus-4.6":   TokenPricing(input: 15,   output: 75,    cacheRead: 1.50,  cacheWrite: 18.75),
        "claude-sonnet-4.6": TokenPricing(input: 3,    output: 15,    cacheRead: 0.30,  cacheWrite: 3.75),
        "claude-haiku-4.5":  TokenPricing(input: 1,    output: 5,     cacheRead: 0.10,  cacheWrite: 1.25),
        // OpenAI
        "gpt-4o":            TokenPricing(input: 2.50, output: 10,    cacheRead: 1.25,  cacheWrite: 0),
        "gpt-4o-mini":       TokenPricing(input: 0.15, output: 0.60,  cacheRead: 0.075, cacheWrite: 0),
        // Google
        "gemini-2.5-pro":    TokenPricing(input: 1.25, output: 10,    cacheRead: 0.315, cacheWrite: 0),
    ]

    static func pricing(for model: String?) -> TokenPricing {
        guard let m = model?.lowercased() else { return .unknown }
        // Exact match
        if let p = byModel[m] { return p }
        // Prefix match (e.g. "gpt-4o-mini-2024-07-18" → "gpt-4o-mini")
        for (key, p) in byModel {
            if m.hasPrefix(key) { return p }
        }
        // Family match
        if m.contains("opus") { return byModel["claude-opus-4.6"] ?? .unknown }
        if m.contains("sonnet") { return byModel["claude-sonnet-4.6"] ?? .unknown }
        if m.contains("haiku") { return byModel["claude-haiku-4.5"] ?? .unknown }
        if m.contains("4o-mini") { return byModel["gpt-4o-mini"] ?? .unknown }
        if m.contains("4o") { return byModel["gpt-4o"] ?? .unknown }
        if m.contains("gemini") { return byModel["gemini-2.5-pro"] ?? .unknown }
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
