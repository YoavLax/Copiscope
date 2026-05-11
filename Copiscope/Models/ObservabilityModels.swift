import Foundation

// MARK: - Turn Duration

struct TurnDuration: Identifiable, Sendable {
    var id: Int { turnIndex }
    let turnIndex: Int
    let userTimestamp: String?
    let assistantTimestamp: String?
    let durationMs: Double
    let inputTokens: Int
    let model: String?
    let ttftMs: Double?
}

// MARK: - Error Classification

enum ErrorClassification: String, CaseIterable, Sendable {
    case rateLimit
    case authFailure
    case proxyError
    case maxTokensTruncation
    case toolError
    case abruptEnding
    case unknown

    var label: String {
        switch self {
        case .rateLimit: return "Rate Limit"
        case .authFailure: return "Auth Failure"
        case .proxyError: return "Proxy Error"
        case .maxTokensTruncation: return "Max Tokens Truncation"
        case .toolError: return "Tool Error"
        case .abruptEnding: return "Abrupt Ending"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Session Error Detail

struct SessionErrorDetail: Sendable {
    let classification: ErrorClassification
    let turnIndex: Int
    let timestamp: String?
    let message: String
}

// MARK: - Parallel Tool Group

struct ParallelToolGroup: Identifiable, Sendable {
    var id: String { "\(turnIndex)-\(toolCount)" }
    let turnIndex: Int
    let timestamp: String?
    let toolNames: [String]
    let toolCount: Int
}

// MARK: - Agent Tree Node (replaces SubagentNode)

struct AgentTreeNode: Identifiable, Sendable {
    let id: String
    let agentName: String
    let model: String?
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let estimatedCost: Double
    let toolCallCount: Int
    let durationMs: Double
    let children: [AgentTreeNode]
}

// MARK: - Session Observability

struct SessionObservability: Sendable {
    let medianTurnDurationMs: Double?
    let maxTurnDurationMs: Double?
    let medianTtftMs: Double?
    let errorClassifications: [ErrorClassification]
    let parallelToolCallCount: Int
    let maxParallelDegree: Int
    let agentInvocationCount: Int
    let vendorDistribution: [String: Int]

    static let empty = SessionObservability(
        medianTurnDurationMs: nil,
        maxTurnDurationMs: nil,
        medianTtftMs: nil,
        errorClassifications: [],
        parallelToolCallCount: 0,
        maxParallelDegree: 0,
        agentInvocationCount: 0,
        vendorDistribution: [:]
    )
}

// MARK: - Session Badge Data

struct SessionBadgeData: Sendable {
    let hasErrors: Bool
    let errorTypes: [ErrorClassification]

    static let none = SessionBadgeData(hasErrors: false, errorTypes: [])
}
