import Foundation

/// Display-ready content block for rendering in chat view
enum ContentBlock: Identifiable, Sendable {
    case text(id: String, text: String)
    case reasoning(id: String, reasoning: String)
    case toolUse(id: String, toolName: String, input: [String: AnyCodableValue], resultContent: String?, isError: Bool)
    case toolResult(id: String, toolCallId: String, content: String, isError: Bool)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .reasoning(let id, _): return id
        case .toolUse(let id, _, _, _, _): return id
        case .toolResult(let id, _, _, _): return id
        }
    }
}

/// Display-ready message for rendering
struct DisplayMessage: Identifiable, Sendable {
    let id: String
    let role: DisplayMessageRole
    let timestamp: String?
    let turnId: String?
    let contentBlocks: [ContentBlock]
}

enum DisplayMessageRole: String, Sendable {
    case user
    case assistant
    case system
}

struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }
}
