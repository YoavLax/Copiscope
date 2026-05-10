import Foundation

// MARK: - OTEL Span (from agent-traces.db)

/// Represents a single span row from the `spans` table in agent-traces.db.
/// Columns are pre-extracted by Copilot's OTEL exporter — no JSON parsing needed.
struct OtelSpan: Sendable {
    let spanId: String
    let traceId: String
    let parentSpanId: String?
    let name: String
    let startTimeMs: Int64
    let endTimeMs: Double
    let statusCode: Int
    let statusMessage: String?
    let operationName: String?
    let providerName: String?
    let agentName: String?
    let conversationId: String?
    let requestModel: String?
    let responseModel: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedTokens: Int?
    let reasoningTokens: Int?
    let toolName: String?
    let toolCallId: String?
    let toolType: String?
    let chatSessionId: String?
    let turnIndex: Int?
    let ttftMs: Double?

    var durationMs: Double { endTimeMs - Double(startTimeMs) }

    var effectiveModel: String? { responseModel ?? requestModel }
}

// MARK: - Operation types

enum OtelOperationType: String, Sendable {
    case chat
    case embeddings
    case executeHook = "execute_hook"
    case executeTool = "execute_tool"
    case invokeAgent = "invoke_agent"
}

// MARK: - Aggregated token data for a session

struct SessionTokenData: Sendable {
    let sessionId: String
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCachedTokens: Int
    let totalReasoningTokens: Int
    let chatSpanCount: Int
    let models: [String]
    let providers: [String]
    let medianTtftMs: Double?
    let spanBreakdown: [ModelSpanBreakdown]

    static func empty(sessionId: String) -> SessionTokenData {
        SessionTokenData(
            sessionId: sessionId,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCachedTokens: 0, totalReasoningTokens: 0,
            chatSpanCount: 0, models: [], providers: [],
            medianTtftMs: nil, spanBreakdown: []
        )
    }
}

struct ModelSpanBreakdown: Sendable {
    let model: String
    let vendor: String
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let spanCount: Int
    let avgTtftMs: Double?
}

// MARK: - Span event (from span_events table)

struct OtelSpanEvent: Sendable {
    let id: Int64
    let spanId: String
    let name: String
    let timestampMs: Int64
    let attributes: String?
}
