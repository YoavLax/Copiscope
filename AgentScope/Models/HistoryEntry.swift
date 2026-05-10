import Foundation

struct HistoryEntry: Identifiable, Sendable {
    let id: String
    let type: String
    let sessionId: String?
    let workspace: String?
    let workspaceId: String?
    let timestamp: Date
    let display: String
}
