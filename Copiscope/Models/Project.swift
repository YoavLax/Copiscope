import Foundation

/// A VS Code workspace that contains Copilot sessions.
/// The `id` is the workspaceStorage hash (e.g. "9be8da72f79087d3328cb193a2a2975a").
/// The `name` is resolved from workspace.json or the folder name.
struct Workspace: Identifiable, Sendable {
    let id: String           // workspaceStorage hash (VS Code) or "cli::<cwd>" (CLI)
    let name: String         // human-readable workspace name
    let path: String         // full path to the workspaceStorage/<hash> directory
    let workspacePath: String? // original workspace folder path (from workspace.json)
    let sessionCount: Int
    let source: CopilotSource

    init(id: String, name: String, path: String, workspacePath: String?,
         sessionCount: Int, source: CopilotSource = .vscode) {
        self.id = id
        self.name = name
        self.path = path
        self.workspacePath = workspacePath
        self.sessionCount = sessionCount
        self.source = source
    }
}

/// Lightweight reference to associate a session with its workspace
struct WorkspaceRef: Sendable {
    let id: String
    let name: String
}
