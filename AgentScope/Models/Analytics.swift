import Foundation

enum AnalyticsTimeRange: String, CaseIterable, Sendable {
    case today = "today"
    case sevenDays = "7 days"
    case thirtyDays = "30 days"
    case all = "all"
    case custom = "custom"

    func dateRange(customFrom: Date, customTo: Date) -> (from: Date?, to: Date?) {
        switch self {
        case .today:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            return (startOfToday, nil)
        case .sevenDays:
            return (Calendar.current.date(byAdding: .day, value: -7, to: Date()), nil)
        case .thirtyDays:
            return (Calendar.current.date(byAdding: .day, value: -30, to: Date()), nil)
        case .all:
            return (nil, nil)
        case .custom:
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customTo))
            return (Calendar.current.startOfDay(for: customFrom), endOfDay)
        }
    }
}

struct AnalyticsData: Sendable {
    let totalSessions: Int
    let totalMessages: Int
    let totalTokens: Int
    let totalCacheTokens: Int
    let totalCost: Double
    let dailyUsage: [DailyUsage]
    let workspaceCosts: [WorkspaceCost]
    let modelUsage: [ModelUsage]
    let cacheAnalytics: CacheAnalytics
    let modelEfficiency: [ModelEfficiencyRow]
    let dailyModelCost: [DailyModelCost]
    let latencyAnalytics: LatencyAnalytics
    let vendorAnalytics: VendorAnalytics
    let parallelToolAnalytics: ParallelToolAnalytics
    let billingAnalytics: BillingAnalytics

    static let empty = AnalyticsData(
        totalSessions: 0, totalMessages: 0, totalTokens: 0, totalCacheTokens: 0, totalCost: 0,
        dailyUsage: [], workspaceCosts: [], modelUsage: [],
        cacheAnalytics: .empty, modelEfficiency: [], dailyModelCost: [],
        latencyAnalytics: .empty, vendorAnalytics: .empty,
        parallelToolAnalytics: .empty, billingAnalytics: .empty
    )
}

// MARK: - Cache Analytics

struct CacheTierCost: Sendable {
    let cost5m: Double
    let cost1h: Double

    static let empty = CacheTierCost(cost5m: 0, cost1h: 0)
}

struct CacheAnalytics: Sendable {
    let hitRatio: Double
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let costSavings: Double
    let hypotheticalUncachedCost: Double
    let actualCost: Double
    let averageReuseRate: Double
    let cacheBustingDays: [String]
    let totalCache5mTokens: Int
    let totalCache1hTokens: Int
    let tierCostBreakdown: CacheTierCost
    let dailyHitRatio: [(date: String, ratio: Double)]
    let sessionEfficiency: [SessionCacheEfficiency]
    let modelSavings: [ModelCacheSavings]

    static let empty = CacheAnalytics(
        hitRatio: 0, totalCacheReadTokens: 0, totalCacheWriteTokens: 0,
        costSavings: 0, hypotheticalUncachedCost: 0, actualCost: 0,
        averageReuseRate: 0, cacheBustingDays: [],
        totalCache5mTokens: 0, totalCache1hTokens: 0,
        tierCostBreakdown: .empty,
        dailyHitRatio: [], sessionEfficiency: [], modelSavings: []
    )
}

struct SessionCacheEfficiency: Identifiable, Sendable {
    var id: String { sessionId }
    let sessionId: String
    let sessionTitle: String
    let hitRatio: Double
    let cacheReadTokens: Int
    let savingsAmount: Double
    let primaryModel: String?
}

struct ModelCacheSavings: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let cacheReadTokens: Int
    let savingsPerMTok: Double
    let totalSavings: Double
}

// MARK: - Model Efficiency

struct ModelEfficiencyRow: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let vendor: String
    let turnCount: Int
    let totalOutputTokens: Int
    let avgOutputPerTurn: Int
    let totalCost: Double
    let costPerTurn: Double
    let percentOfTotalCost: Double
    let avgTtftMs: Double?
}

struct DailyModelCost: Identifiable, Sendable {
    var id: String { "\(date)-\(model)" }
    let date: String
    let model: String
    let cost: Double
}

struct DailyUsage: Identifiable, Sendable {
    var id: String { date }
    let date: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var sessionCount: Int
    var messageCount: Int
    var estimatedCost: Double
    var premiumRequests: Int
    var multiplierCost: Double
}

struct WorkspaceCost: Identifiable, Sendable {
    var id: String { workspaceId }
    let workspaceId: String
    let workspaceName: String
    var totalCost: Double
    var totalTokens: Int
    var sessionCount: Int
    var messageCount: Int
    var premiumRequests: Int
}

struct ModelUsage: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let vendor: String
    var turnCount: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var totalCachedTokens: Int
}

// MARK: - Latency Analytics

struct LatencyAnalytics: Sendable {
    let medianDurationMs: Double
    let p95DurationMs: Double
    let p99DurationMs: Double
    let histogram: [LatencyBucket]
    let slowestTurns: [SlowTurnEntry]
    let medianTtftMs: Double
    let p95TtftMs: Double
    let ttftByModel: [ModelTtft]

    static let empty = LatencyAnalytics(
        medianDurationMs: 0, p95DurationMs: 0, p99DurationMs: 0,
        histogram: [], slowestTurns: [],
        medianTtftMs: 0, p95TtftMs: 0, ttftByModel: []
    )
}

struct LatencyBucket: Identifiable, Sendable {
    var id: String { label }
    let label: String
    let count: Int
}

struct SlowTurnEntry: Identifiable, Sendable {
    let id: String
    let sessionId: String
    let sessionTitle: String
    let turnIndex: Int
    let durationMs: Double
    let ttftMs: Double?
    let model: String?
}

struct ModelTtft: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let medianMs: Double
    let p95Ms: Double
    let sampleCount: Int
}

// MARK: - Vendor Analytics (replaces EffortAnalytics)

struct VendorAnalytics: Sendable {
    let distribution: [VendorDistribution]
    let costByVendor: [VendorCostBreakdown]
    let vendorOverTime: [DailyVendor]

    static let empty = VendorAnalytics(distribution: [], costByVendor: [], vendorOverTime: [])
}

struct VendorDistribution: Identifiable, Sendable {
    var id: String { vendor }
    let vendor: String
    let requestCount: Int
    let tokenCount: Int
    let percentage: Double
}

struct VendorCostBreakdown: Identifiable, Sendable {
    var id: String { vendor }
    let vendor: String
    let totalCost: Double
    let avgCostPerRequest: Double
}

struct DailyVendor: Sendable, Identifiable {
    var id: String { date }
    let date: String
    let vendorCounts: [String: Int]
}

// MARK: - Parallel Tool Analytics

struct ParallelToolAnalytics: Sendable {
    let totalParallelGroups: Int
    let avgToolsPerGroup: Double
    let maxParallelDegree: Int
    let distribution: [ParallelToolBucket]

    static let empty = ParallelToolAnalytics(
        totalParallelGroups: 0, avgToolsPerGroup: 0, maxParallelDegree: 0, distribution: []
    )
}

struct ParallelToolBucket: Sendable, Identifiable {
    var id: Int { toolCount }
    let toolCount: Int
    let occurrences: Int
}

// MARK: - Billing Analytics (Copilot premium requests)

struct BillingAnalytics: Sendable {
    let totalPremiumRequests: Int
    let totalMultiplierCost: Double
    let requestsByModel: [ModelBillingRow]
    let dailyPremiumRequests: [DailyPremiumRequests]

    static let empty = BillingAnalytics(
        totalPremiumRequests: 0, totalMultiplierCost: 0,
        requestsByModel: [], dailyPremiumRequests: []
    )
}

struct ModelBillingRow: Identifiable, Sendable {
    var id: String { model }
    let model: String
    let requestCount: Int
    let multiplier: Double
    let weightedCost: Double
    let isPremium: Bool
}

struct DailyPremiumRequests: Identifiable, Sendable {
    var id: String { date }
    let date: String
    let premiumRequests: Int
    let multiplierCost: Double
}
