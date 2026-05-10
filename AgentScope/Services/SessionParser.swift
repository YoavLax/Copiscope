import Foundation

/// Parses Copilot transcript JSONL files into ParsedSession objects.
actor SessionParser {
    private let decoder = JSONDecoder()

    /// Full parse of a Copilot transcript JSONL file
    func parse(url: URL, sessionId: String, workspaceId: String) throws -> ParsedSession {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fileHandle.closeFile() }

        var records: [CopilotRecord] = []
        var toolResultMap: [String: ToolResultEntry] = [:]
        var modelsSet = Set<String>()

        var firstTimestamp = ""
        var lastTimestamp = ""
        var messageCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var turnCount = 0
        var toolCallCount = 0
        var turnDurations: [TurnDuration] = []
        var errorDetails: [SessionErrorDetail] = []
        var parallelToolGroups: [ParallelToolGroup] = []

        // Track tool calls per turn for parallel detection
        var currentTurnToolNames: [String] = []
        var currentTurnTimestamp: String?
        var lastUserTimestamp: String?
        var lastTurnStartTime: Date?

        for line in StreamingLineReader(fileHandle: fileHandle) {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let record = try? decoder.decode(CopilotRecord.self, from: lineData) else { continue }

            // Track timestamps
            if let ts = record.timestamp {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
            }

            switch record.type {
            case .sessionStart:
                break

            case .userMessage:
                messageCount += 1
                userMessageCount += 1
                lastUserTimestamp = record.timestamp

            case .assistantTurnStart:
                turnCount += 1
                lastTurnStartTime = record.timestamp.flatMap { parseISO8601($0) }
                currentTurnToolNames = []
                currentTurnTimestamp = record.timestamp

            case .assistantMessage:
                messageCount += 1
                assistantMessageCount += 1

                // Count tool requests
                if let reqs = record.data?.toolRequests {
                    toolCallCount += reqs.count
                    for req in reqs {
                        if let name = req.name {
                            currentTurnToolNames.append(name)
                        }
                    }
                }

            case .assistantTurnEnd:
                // Record turn duration
                if let startTime = lastTurnStartTime,
                   let endTs = record.timestamp,
                   let endTime = parseISO8601(endTs) {
                    let durationMs = endTime.timeIntervalSince(startTime) * 1000
                    turnDurations.append(TurnDuration(
                        turnIndex: turnCount,
                        userTimestamp: lastUserTimestamp,
                        assistantTimestamp: record.timestamp,
                        durationMs: durationMs,
                        inputTokens: 0,  // enriched from OTEL later
                        model: nil,      // enriched from OTEL later
                        ttftMs: nil      // enriched from OTEL later
                    ))
                }

                // Detect parallel tool calls
                if currentTurnToolNames.count > 1 {
                    parallelToolGroups.append(ParallelToolGroup(
                        turnIndex: turnCount,
                        timestamp: currentTurnTimestamp,
                        toolNames: currentTurnToolNames,
                        toolCount: currentTurnToolNames.count
                    ))
                }

            case .toolExecutionStart:
                break

            case .toolExecutionComplete:
                // Build tool result map
                if let callId = record.data?.toolCallId {
                    let content = record.data?.content ?? ""
                    let isError = record.data?.success == false
                    if toolResultMap[callId] == nil {
                        toolResultMap[callId] = ToolResultEntry(
                            content: content,
                            isError: isError,
                            timestamp: record.timestamp
                        )
                    }
                    if isError {
                        errorDetails.append(SessionErrorDetail(
                            classification: .toolError,
                            turnIndex: turnCount,
                            timestamp: record.timestamp,
                            message: "Tool error in \(record.data?.toolName ?? "unknown")"
                        ))
                    }
                }

            case nil:
                break  // Unknown record type, skip
            }

            records.append(record)
        }

        let metadata = SessionMetadata(
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            turnCount: turnCount,
            toolCallCount: toolCallCount,
            models: Array(modelsSet),
            turnDurations: turnDurations,
            errorDetails: errorDetails,
            parallelToolGroups: parallelToolGroups,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            totalReasoningTokens: 0,
            premiumRequestCount: 0,
            totalMultiplierCost: 0
        )

        return ParsedSession(
            id: sessionId,
            workspaceId: workspaceId,
            records: records,
            toolResultMap: toolResultMap,
            metadata: metadata,
            tokenData: nil  // enriched from OTEL separately
        )
    }

    /// Lightweight metadata-only parse (no records kept in memory)
    func parseMetadata(url: URL, sessionId: String, workspaceId: String) throws -> SessionSummary {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fileHandle.closeFile() }

        var firstTimestamp = ""
        var lastTimestamp = ""
        var messageCount = 0
        var userMessageCount = 0
        var turnCount = 0
        var toolCallCount = 0
        var title = ""
        var hasError = false

        for line in StreamingLineReader(fileHandle: fileHandle) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            guard let record = try? decoder.decode(CopilotRecord.self, from: lineData) else { continue }

            if let ts = record.timestamp {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
            }

            switch record.type {
            case .userMessage:
                messageCount += 1
                userMessageCount += 1
                // Use first user message as title
                if title.isEmpty, let content = record.data?.content {
                    title = String(content.prefix(120))
                }

            case .assistantTurnStart:
                turnCount += 1

            case .assistantMessage:
                messageCount += 1
                if let reqs = record.data?.toolRequests {
                    toolCallCount += reqs.count
                }

            case .toolExecutionComplete:
                if record.data?.success == false { hasError = true }

            default:
                break
            }
        }

        if title.isEmpty { title = "Session \(sessionId.prefix(8))" }

        return SessionSummary(
            id: sessionId,
            workspaceId: workspaceId,
            title: title,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount,
            primaryModel: nil,    // enriched from OTEL
            vendor: nil,
            turnCount: turnCount,
            toolCallCount: toolCallCount,
            hasError: hasError,
            observability: .empty,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            totalReasoningTokens: 0,
            estimatedCost: 0,
            premiumRequestCount: 0,
            totalMultiplierCost: 0,
            modelBreakdown: []
        )
    }
}

enum SessionParserError: Error {
    case fileNotFound
}

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
        ?? ISO8601DateFormatter().date(from: string)
}
