import Foundation

// MARK: - Parsed Session (full detail)

struct ParsedSession: Sendable {
    let id: String
    let workspaceId: String
    let records: [CopilotRecord]
    let toolResultMap: [String: ToolResultEntry]
    let metadata: SessionMetadata
    let tokenData: SessionTokenData?
    let source: CopilotSource

    init(id: String, workspaceId: String, records: [CopilotRecord],
         toolResultMap: [String: ToolResultEntry], metadata: SessionMetadata,
         tokenData: SessionTokenData?, source: CopilotSource = .vscode) {
        self.id = id
        self.workspaceId = workspaceId
        self.records = records
        self.toolResultMap = toolResultMap
        self.metadata = metadata
        self.tokenData = tokenData
        self.source = source
    }
}

struct ToolResultEntry: Sendable {
    let content: String
    let isError: Bool
    let timestamp: String?
}

// MARK: - Session Metadata

struct SessionMetadata: Sendable {
    let firstTimestamp: String
    let lastTimestamp: String
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let turnCount: Int
    let toolCallCount: Int
    let models: [String]
    let turnDurations: [TurnDuration]
    let errorDetails: [SessionErrorDetail]
    let parallelToolGroups: [ParallelToolGroup]

    // Token fields — populated from OTEL when available
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCachedTokens: Int
    let totalReasoningTokens: Int

    // Billing fields
    let premiumRequestCount: Int
    let totalMultiplierCost: Double
}

// MARK: - Session Summary (lightweight for sidebar)

struct SessionSummary: Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let title: String
    let firstTimestamp: String
    let lastTimestamp: String
    let messageCount: Int
    let primaryModel: String?
    let vendor: String?
    let turnCount: Int
    let toolCallCount: Int
    let hasError: Bool
    let observability: SessionObservability

    // Token data (from OTEL)
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCachedTokens: Int
    let totalReasoningTokens: Int
    let estimatedCost: Double

    // Billing
    let premiumRequestCount: Int
    let totalMultiplierCost: Double
    let modelBreakdown: [ModelUsageBreakdown]

    // Source
    let source: CopilotSource

    init(id: String, workspaceId: String, title: String, firstTimestamp: String,
         lastTimestamp: String, messageCount: Int, primaryModel: String?,
         vendor: String?, turnCount: Int, toolCallCount: Int, hasError: Bool,
         observability: SessionObservability, totalInputTokens: Int,
         totalOutputTokens: Int, totalCachedTokens: Int, totalReasoningTokens: Int,
         estimatedCost: Double, premiumRequestCount: Int, totalMultiplierCost: Double,
         modelBreakdown: [ModelUsageBreakdown], source: CopilotSource = .vscode) {
        self.id = id
        self.workspaceId = workspaceId
        self.title = title
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.messageCount = messageCount
        self.primaryModel = primaryModel
        self.vendor = vendor
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.hasError = hasError
        self.observability = observability
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCachedTokens = totalCachedTokens
        self.totalReasoningTokens = totalReasoningTokens
        self.estimatedCost = estimatedCost
        self.premiumRequestCount = premiumRequestCount
        self.totalMultiplierCost = totalMultiplierCost
        self.modelBreakdown = modelBreakdown
        self.source = source
    }
}

struct ModelUsageBreakdown: Sendable {
    let model: String
    let vendor: String
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let estimatedCost: Double
    let requestCount: Int
    let multiplierCost: Double
    let turnCount: Int
}
