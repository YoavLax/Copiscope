import Foundation

/// Scans `~/.copilot/session-state/` for GitHub Copilot CLI sessions.
struct CLISessionScanner: Sendable {
    let cliStateDir: URL
    let parser: SessionParser

    func scan(
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> (workspaces: [Workspace], sessionsByWorkspace: [String: [SessionSummary]]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cliStateDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return ([], [:])
        }

        // Collect valid session directories (must have events.jsonl and workspace.yaml)
        var sessionEntries: [(eventsURL: URL, yamlURL: URL)] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let eventsURL = entry.appendingPathComponent("events.jsonl")
            let yamlURL = entry.appendingPathComponent("workspace.yaml")
            guard fm.fileExists(atPath: eventsURL.path) else { continue }
            sessionEntries.append((eventsURL, yamlURL))
        }

        let total = sessionEntries.count
        var summaries: [SessionSummary] = []

        // Parse with bounded concurrency (max 8 concurrent)
        await withTaskGroup(of: SessionSummary?.self) { group in
            var pending = sessionEntries.makeIterator()
            var inFlight = 0
            let maxConcurrent = 8

            func launchNext() {
                while inFlight < maxConcurrent, let next = pending.next() {
                    let (eventsURL, yamlURL) = next
                    inFlight += 1
                    group.addTask {
                        guard let yaml = CLIWorkspaceYAML.parse(from: yamlURL) else { return nil }
                        return try? await self.parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
                    }
                }
            }

            launchNext()

            var processed = 0
            for await result in group {
                inFlight -= 1
                processed += 1
                onProgress?(processed, total)
                if let summary = result {
                    summaries.append(summary)
                }
                launchNext()
            }
        }

        // Group by workspace ID (cwd-based key)
        var sessionsByWorkspace: [String: [SessionSummary]] = [:]
        for summary in summaries {
            sessionsByWorkspace[summary.workspaceId, default: []].append(summary)
        }

        // Sort sessions within each workspace newest-first
        for key in sessionsByWorkspace.keys {
            sessionsByWorkspace[key]?.sort { $0.lastTimestamp > $1.lastTimestamp }
        }

        // Build Workspace objects
        var workspaces: [Workspace] = []
        for (wsId, sessions) in sessionsByWorkspace {
            let cwd = String(wsId.dropFirst("cli::".count))
            let folderName = URL(fileURLWithPath: cwd).lastPathComponent
            workspaces.append(Workspace(
                id: wsId,
                name: folderName.isEmpty ? cwd : folderName,
                path: cwd,
                workspacePath: cwd,
                sessionCount: sessions.count,
                source: .cli
            ))
        }
        workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return (workspaces, sessionsByWorkspace)
    }
}
