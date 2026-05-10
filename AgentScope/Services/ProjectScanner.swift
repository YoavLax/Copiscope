import Foundation

/// Scans VS Code workspaceStorage directories to discover Copilot chat transcripts.
///
/// Directory structure:
///   ~/Library/Application Support/Code/User/workspaceStorage/<hash>/
///     workspace.json                          — contains original workspace folder path
///     GitHub.copilot-chat/transcripts/<id>.jsonl  — session transcripts
///     GitHub.copilot-chat/debug-logs/<id>/    — debug logs (models.json, main.jsonl)
struct WorkspaceScanner {
    let vscodeUserDir: URL
    let parser: SessionParser
    let otelReader: OtelSpanReader?

    private static let maxConcurrentParses = 8

    /// Scan all workspaces and collect session metadata.
    func scan(onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil) async -> (workspaces: [Workspace], sessionsByWorkspace: [String: [SessionSummary]]) {
        let workspaceStorageDir = vscodeUserDir.appendingPathComponent("workspaceStorage")
        var workspaces: [Workspace] = []
        var sessionsByWorkspace: [String: [SessionSummary]] = [:]

        let fm = FileManager.default
        guard let hashDirs = try? fm.contentsOfDirectory(atPath: workspaceStorageDir.path) else {
            return (workspaces, sessionsByWorkspace)
        }

        // Collect all JSONL entries across all workspace hashes
        var allEntries: [(workspaceId: String, url: URL, sessionId: String, isChatSession: Bool)] = []
        var workspaceInfos: [String: (name: String, path: String, workspacePath: String?)] = [:]

        for hashDir in hashDirs {
            let hashPath = workspaceStorageDir.appendingPathComponent(hashDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: hashPath.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check both known session directory layouts:
            //   - GitHub.copilot-chat/transcripts/  (older VS Code / Copilot versions)
            //   - chatSessions/                      (newer VS Code versions)
            // Prefer transcripts when both exist for the same session ID (richer format).
            let transcriptsDir = hashPath.appendingPathComponent("GitHub.copilot-chat").appendingPathComponent("transcripts")
            let chatSessionsDir = hashPath.appendingPathComponent("chatSessions")

            var seenSessionIds = Set<String>()
            var jsonlFiles: [(url: URL, sessionId: String, isChatSession: Bool)] = []

            // Transcripts first (preferred format)
            if let files = try? fm.contentsOfDirectory(atPath: transcriptsDir.path) {
                for file in files where file.hasSuffix(".jsonl") {
                    let sessionId = String(file.dropLast(6))
                    seenSessionIds.insert(sessionId)
                    jsonlFiles.append((transcriptsDir.appendingPathComponent(file), sessionId, false))
                }
            }
            // chatSessions second — skip any IDs already found in transcripts
            if let files = try? fm.contentsOfDirectory(atPath: chatSessionsDir.path) {
                for file in files where file.hasSuffix(".jsonl") {
                    let sessionId = String(file.dropLast(6))
                    guard !seenSessionIds.contains(sessionId) else { continue }
                    jsonlFiles.append((chatSessionsDir.appendingPathComponent(file), sessionId, true))
                }
            }
            guard !jsonlFiles.isEmpty else { continue }

            // Resolve workspace name from workspace.json
            let workspaceName = resolveWorkspaceName(at: hashPath, fm: fm) ?? hashDir
            let workspacePath = resolveWorkspacePath(at: hashPath, fm: fm)

            workspaceInfos[hashDir] = (name: workspaceName, path: hashPath.path, workspacePath: workspacePath)

            for entry in jsonlFiles {
                allEntries.append((hashDir, entry.url, entry.sessionId, entry.isChatSession))
            }
        }

        // Parse all sessions with throttled concurrency
        let total = allEntries.count
        var processed = 0
        var summariesByWorkspace: [String: [SessionSummary]] = [:]

        await withTaskGroup(of: (String, SessionSummary?).self) { group in
            var running = 0

            for entry in allEntries {
                if running >= Self.maxConcurrentParses {
                    if let result = await group.next() {
                        processed += 1
                        if let summary = result.1 {
                            summariesByWorkspace[result.0, default: []].append(summary)
                        }
                        running -= 1
                        await onProgress?(processed, total)
                    }
                }

                group.addTask {
                    let summary: SessionSummary?
                    if entry.isChatSession {
                        summary = try? await self.parser.parseMetadataChatSession(
                            url: entry.url,
                            sessionId: entry.sessionId,
                            workspaceId: entry.workspaceId
                        )
                    } else {
                        summary = try? await self.parser.parseMetadata(
                            url: entry.url,
                            sessionId: entry.sessionId,
                            workspaceId: entry.workspaceId
                        )
                    }
                    return (entry.workspaceId, summary)
                }
                running += 1
            }

            for await result in group {
                processed += 1
                if let summary = result.1 {
                    summariesByWorkspace[result.0, default: []].append(summary)
                }
                await onProgress?(processed, total)
            }
        }

        // Enrich with OTEL token data
        if let reader = otelReader {
            for (wsId, summaries) in summariesByWorkspace {
                summariesByWorkspace[wsId] = enrichSummaries(summaries, reader: reader)
            }
        }

        // Build workspace list
        for (wsId, info) in workspaceInfos {
            let count = summariesByWorkspace[wsId]?.count ?? 0
            guard count > 0 else { continue }
            workspaces.append(Workspace(
                id: wsId,
                name: info.name,
                path: info.path,
                workspacePath: info.workspacePath,
                sessionCount: count
            ))
        }

        // Sort workspaces by name
        workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sessionsByWorkspace = summariesByWorkspace

        return (workspaces, sessionsByWorkspace)
    }

    // MARK: - Helpers

    private func resolveWorkspaceName(at hashPath: URL, fm: FileManager) -> String? {
        let workspaceJsonPath = hashPath.appendingPathComponent("workspace.json")
        guard let data = fm.contents(atPath: workspaceJsonPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = json["folder"] as? String else {
            return nil
        }
        // folder is a URI like "file:///Users/name/project"
        if let url = URL(string: folder) {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    private func resolveWorkspacePath(at hashPath: URL, fm: FileManager) -> String? {
        let workspaceJsonPath = hashPath.appendingPathComponent("workspace.json")
        guard let data = fm.contents(atPath: workspaceJsonPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = json["folder"] as? String else {
            return nil
        }
        if let url = URL(string: folder) {
            return url.path
        }
        return folder
    }

    private func enrichSummaries(_ summaries: [SessionSummary], reader: OtelSpanReader) -> [SessionSummary] {
        summaries.map { summary in
            let tokenData = reader.tokenData(forSession: summary.id)
            guard tokenData.chatSpanCount > 0 else { return summary }

            let breakdown = tokenData.spanBreakdown.map { b in
                ModelUsageBreakdown(
                    model: b.model,
                    vendor: b.vendor,
                    inputTokens: b.inputTokens,
                    outputTokens: b.outputTokens,
                    cachedTokens: b.cachedTokens,
                    reasoningTokens: b.reasoningTokens,
                    estimatedCost: estimateCostFromTokens(
                        model: b.model,
                        inputTokens: b.inputTokens,
                        outputTokens: b.outputTokens,
                        cachedTokens: b.cachedTokens
                    ),
                    requestCount: b.spanCount,
                    multiplierCost: 0,
                    turnCount: b.spanCount
                )
            }

            let totalCost = breakdown.reduce(0) { $0 + $1.estimatedCost }
            let primaryModel = tokenData.spanBreakdown.max(by: { $0.spanCount < $1.spanCount })?.model

            return SessionSummary(
                id: summary.id,
                workspaceId: summary.workspaceId,
                title: summary.title,
                firstTimestamp: summary.firstTimestamp,
                lastTimestamp: summary.lastTimestamp,
                messageCount: summary.messageCount,
                primaryModel: primaryModel ?? summary.primaryModel,
                vendor: tokenData.providers.first,
                turnCount: summary.turnCount,
                toolCallCount: summary.toolCallCount,
                hasError: summary.hasError,
                observability: summary.observability,
                totalInputTokens: tokenData.totalInputTokens,
                totalOutputTokens: tokenData.totalOutputTokens,
                totalCachedTokens: tokenData.totalCachedTokens,
                totalReasoningTokens: tokenData.totalReasoningTokens,
                estimatedCost: totalCost,
                premiumRequestCount: tokenData.chatSpanCount,
                totalMultiplierCost: 0,
                modelBreakdown: breakdown
            )
        }
    }
}
