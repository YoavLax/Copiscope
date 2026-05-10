import Foundation

// MARK: - Copilot Transcript Record Types

enum CopilotRecordType: String, Codable, Sendable {
    case sessionStart = "session.start"
    case userMessage = "user.message"
    case assistantTurnStart = "assistant.turn_start"
    case assistantMessage = "assistant.message"
    case assistantTurnEnd = "assistant.turn_end"
    case toolExecutionStart = "tool.execution_start"
    case toolExecutionComplete = "tool.execution_complete"
}

// MARK: - Top-level transcript JSONL line

struct CopilotRecord: Decodable, Sendable {
    let type: CopilotRecordType?
    let data: CopilotRecordData?
    let id: String?
    let timestamp: String?
    let parentId: String?

    /// Raw type string for forward-compat when type is unrecognized
    let unknownTypeRaw: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try? container.decode(CopilotRecordType.self, forKey: .type)
        type = decoded
        unknownTypeRaw = decoded == nil ? (try? container.decode(String.self, forKey: .type)) : nil
        id = try container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)

        // Decode data based on type
        if let type = decoded {
            data = try container.decodeIfPresent(CopilotRecordData.self, forKey: .data)
        } else {
            data = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, data, id, timestamp, parentId
    }
}

// MARK: - Record Data (union of all possible data shapes)

struct CopilotRecordData: Decodable, Sendable {
    // session.start fields
    let sessionId: String?
    let version: Int?
    let producer: String?
    let copilotVersion: String?
    let vscodeVersion: String?
    let startTime: String?

    // user.message fields
    let content: String?
    let attachments: [CopilotAttachment]?

    // assistant.message fields
    let messageId: String?
    let toolRequests: [CopilotToolRequest]?
    let reasoningText: String?

    // assistant.turn_start / turn_end
    let turnId: String?

    // tool.execution_start / tool.execution_complete
    let toolCallId: String?
    let toolName: String?
    let arguments: AnyCodableValue?
    let success: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId, version, producer, copilotVersion, vscodeVersion, startTime
        case content, attachments
        case messageId, toolRequests, reasoningText
        case turnId
        case toolCallId, toolName, arguments, success
    }
}

// MARK: - Supporting types

struct CopilotAttachment: Decodable, Sendable {
    let type: String?
    let uri: String?
    let name: String?
}

struct CopilotToolRequest: Decodable, Sendable {
    let toolCallId: String?
    let name: String?
    let arguments: AnyCodableValue?
    let type: String?  // "function"
}
