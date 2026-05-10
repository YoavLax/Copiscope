import Foundation

/// A VS Code workspace that contains Copilot sessions.
/// The `id` is the workspaceStorage hash (e.g. "9be8da72f79087d3328cb193a2a2975a").
/// The `name` is resolved from workspace.json or the folder name.
struct Workspace: Identifiable, Sendable {
    let id: String           // workspaceStorage hash
    let name: String         // human-readable workspace name
    let path: String         // full path to the workspaceStorage/<hash> directory
    let workspacePath: String? // original workspace folder path (from workspace.json)
    let sessionCount: Int
}

/// Lightweight reference to associate a session with its workspace
struct WorkspaceRef: Sendable {
    let id: String
    let name: String
}
