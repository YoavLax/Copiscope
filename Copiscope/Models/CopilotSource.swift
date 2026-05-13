import Foundation

/// Identifies which Copilot client produced a session.
enum CopilotSource: String, Sendable, Codable {
    /// VS Code extension (workspaceStorage / chatSessions format)
    case vscode
    /// GitHub Copilot CLI (~/.copilot/session-state format)
    case cli
}
