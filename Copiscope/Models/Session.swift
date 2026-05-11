import Foundation

// MARK: - Parsed Session (full detail)

struct ParsedSession: Sendable {
    let id: String
    let workspaceId: String
    let records: [CopilotRecord]
    let toolResultMap: [String: ToolResultEntry]
    let metadata: SessionMetadata
    let tokenData: SessionTokenData?
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
