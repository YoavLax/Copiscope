import Foundation

// MARK: - ConfigLinterService
// Runs all health checks across sessions, config files, and secrets.

final class ConfigLinterService: Sendable {

    struct Input: Sendable {
        let sessions: [(workspaceId: String, summary: SessionSummary)]
        let instructions: [InstructionEntry]
        let agents: [AgentEntry]
        let prompts: [PromptEntry]
        let mcpServers: [McpServerEntry]
        let chatSessionDirs: [(workspaceId: String, url: URL)]  // for secret scanning
    }

    func lint(_ input: Input) async -> [LintResult] {
        var results: [LintResult] = []

        // Session performance
        results += sessionChecks(input.sessions)

        // Config file quality
        results += configFileChecks(
            instructions: input.instructions,
            agents: input.agents,
            prompts: input.prompts,
            mcpServers: input.mcpServers
        )

        // Cross-cutting token estimate
        results += tokenEstimateChecks(
            instructions: input.instructions,
            agents: input.agents
        )

        return results
    }

    /// Scan session content for secrets (heavy — call separately/background).
    func secretScan(dirs: [(workspaceId: String, url: URL)],
                    sessions: [(workspaceId: String, summary: SessionSummary)]) async -> [LintResult] {
        var results: [LintResult] = []
        let sessionMap = Dictionary(uniqueKeysWithValues: sessions.map { ($0.summary.id, $0) })

        for (workspaceId, dirURL) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let sessionId = file.deletingPathExtension().lastPathComponent
                let title = sessionMap[sessionId]?.summary.title ?? sessionId
                let displayPath = title
                let filePath = "sessions/\(workspaceId)/\(sessionId)"

                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                results += secretChecks(
                    content: content,
                    filePath: filePath,
                    displayPath: displayPath,
                    detectedAt: Date()
                )
            }
        }
        return results
    }
}

