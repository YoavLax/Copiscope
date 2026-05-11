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

// MARK: - chatSessions format parser

extension SessionParser {
    /// Detect whether a JSONL file uses the chatSessions patch format (kind/k/v) vs the
    /// transcript format (type/timestamp/data).
    func isChatSessionsFormat(url: URL) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { fh.closeFile() }
        for line in StreamingLineReader(fileHandle: fh) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return obj["kind"] != nil  // chatSessions uses "kind"; transcripts use "type"
        }
        return false
    }

    /// Lightweight metadata parse for the chatSessions patch format.
    func parseMetadataChatSession(url: URL, sessionId: String, workspaceId: String) throws -> SessionSummary {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        defer { fh.closeFile() }

        // Reconstruct the session state from snapshot + patches
        var requests: [[String: Any]] = []
        var customTitle: String? = nil
        var creationDateMs: Double? = nil

        for line in StreamingLineReader(fileHandle: fh) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = obj["kind"] as? Int
            else { continue }

            switch kind {
            case 0:
                // Full snapshot
                if let v = obj["v"] as? [String: Any] {
                    requests = v["requests"] as? [[String: Any]] ?? []
                    if let d = v["creationDate"] as? Double { creationDateMs = d }
                    else if let i = v["creationDate"] as? Int { creationDateMs = Double(i) }
                    customTitle = v["customTitle"] as? String
                }
            case 1:
                // Partial set: k=[keyPath...], v=newValue
                guard let keys = obj["k"] as? [Any], let val = obj["v"] else { continue }
                if keys.count == 1, let k0 = keys[0] as? String {
                    if k0 == "customTitle" { customTitle = val as? String }
                } else if keys.count == 3,
                          let k0 = keys[0] as? String, k0 == "requests",
                          let idx = keys[1] as? Int, idx < requests.count,
                          let k2 = keys[2] as? String {
                    requests[idx][k2] = val
                }
            case 2:
                // Array patch: k=[keyPath...], v=array
                // k=["requests"] means APPEND new request(s) (each turn sends a 1-element array)
                // k=["requests", idx, "response"] means replace the response array for that request
                guard let keys = obj["k"] as? [Any] else { continue }
                if keys.count == 1, let k0 = keys[0] as? String, k0 == "requests",
                   let arr = obj["v"] as? [[String: Any]] {
                    requests.append(contentsOf: arr)
                } else if keys.count == 3,
                          let k0 = keys[0] as? String, k0 == "requests",
                          let idx = keys[1] as? Int, idx < requests.count,
                          let k2 = keys[2] as? String {
                    requests[idx][k2] = obj["v"] as Any
                }
            default:
                break
            }
        }

        // Extract metadata from reconstructed requests
        let messageCount = requests.count
        var turnCount = 0
        var toolCallCount = 0
        var title = customTitle ?? ""
        var firstTimestamp = ""
        var lastTimestamp = ""
        var primaryModel: String? = nil
        var hasError = false
        var totalOutputTokens = 0
        var modelTokenMap: [String: Int] = [:]  // modelId → sum of completionTokens

        for (i, req) in requests.enumerated() {
            // Timestamp (milliseconds epoch → ISO8601 string)
            let tsMs: Double?
            if let d = req["timestamp"] as? Double { tsMs = d }
            else if let i = req["timestamp"] as? Int { tsMs = Double(i) }
            else { tsMs = nil }
            if let tsMs {
                let date = Date(timeIntervalSince1970: tsMs / 1000)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let tsStr = iso.string(from: date)
                if firstTimestamp.isEmpty { firstTimestamp = tsStr }
                lastTimestamp = tsStr
            }

            // Title from first user message
            if title.isEmpty, i == 0,
               let msg = req["message"] as? [String: Any],
               let text = msg["text"] as? String, !text.isEmpty {
                title = String(text.prefix(120))
            }

            // Model
            if let m = req["modelId"] as? String {
                if primaryModel == nil { primaryModel = m }
                // completionTokens from chatSession = output tokens per request
                let ct = (req["completionTokens"] as? Int) ?? 0
                if ct > 0 {
                    totalOutputTokens += ct
                    modelTokenMap[m, default: 0] += ct
                }
            } else {
                // fallback for requests without modelId
                let ct = (req["completionTokens"] as? Int) ?? 0
                totalOutputTokens += ct
            }

            // Count as a turn (each request = one user+assistant exchange)
            turnCount += 1

            // Tool calls from response array
            if let response = req["response"] as? [[String: Any]] {
                for part in response {
                    if let k = part["kind"] as? String, k == "toolInvocationSerialized" {
                        toolCallCount += 1
                    }
                }
            }

            // Errors: modelState value 2 = error/cancelled
            if let modelState = req["modelState"] as? [String: Any],
               let stateVal = modelState["value"] as? Int, stateVal == 2 {
                hasError = true
            }
            _ = req["result"]  // accessed above for completeness
        }

        // Derive first/last timestamps from creationDate if not parsed from requests
        if firstTimestamp.isEmpty, let ms = creationDateMs {
            let date = Date(timeIntervalSince1970: ms / 1000)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            firstTimestamp = iso.string(from: date)
            lastTimestamp = firstTimestamp
        }

        if title.isEmpty { title = "Session \(sessionId.prefix(8))" }

        // Build per-model breakdown from completionTokens and estimate cost
        let modelBreakdown: [ModelUsageBreakdown] = modelTokenMap.map { model, outToks in
            let cost = estimateCostFromTokens(model: model, inputTokens: 0, outputTokens: outToks, cachedTokens: 0)
            return ModelUsageBreakdown(
                model: model, vendor: "github",
                inputTokens: 0, outputTokens: outToks,
                cachedTokens: 0, reasoningTokens: 0,
                estimatedCost: cost,
                requestCount: 0, multiplierCost: 0, turnCount: 0
            )
        }
        let estimatedCost = modelBreakdown.reduce(0) { $0 + $1.estimatedCost }

        return SessionSummary(
            id: sessionId,
            workspaceId: workspaceId,
            title: title,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: messageCount,
            primaryModel: primaryModel,
            vendor: nil,
            turnCount: turnCount,
            toolCallCount: toolCallCount,
            hasError: hasError,
            observability: .empty,
            totalInputTokens: 0,
            totalOutputTokens: totalOutputTokens,
            totalCachedTokens: 0,
            totalReasoningTokens: 0,
            estimatedCost: estimatedCost,
            premiumRequestCount: turnCount,
            totalMultiplierCost: 0,
            modelBreakdown: modelBreakdown
        )
    }

    /// Full parse of a chatSessions JSONL file → ParsedSession (synthesises CopilotRecord objects).
    func parseChatSession(url: URL, sessionId: String, workspaceId: String) throws -> ParsedSession {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw SessionParserError.fileNotFound
        }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)

        // Reconstruct requests array from snapshot + patches
        var requests: [[String: Any]] = []
        var customTitle: String?
        var creationDateMs: Double?

        for lineData in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let kind = obj["kind"] as? Int
            else { continue }
            switch kind {
            case 0:
                if let v = obj["v"] as? [String: Any] {
                    requests = v["requests"] as? [[String: Any]] ?? []
                    if let d = v["creationDate"] as? Double { creationDateMs = d }
                    else if let i = v["creationDate"] as? Int { creationDateMs = Double(i) }
                    customTitle = v["customTitle"] as? String
                }
            case 1:
                guard let keys = obj["k"] as? [Any], let val = obj["v"] else { continue }
                if keys.count == 1, let k0 = keys[0] as? String, k0 == "customTitle" {
                    customTitle = val as? String
                } else if keys.count == 3,
                          let k0 = keys[0] as? String, k0 == "requests",
                          let idx = keys[1] as? Int, idx < requests.count,
                          let k2 = keys[2] as? String {
                    requests[idx][k2] = val
                }
            case 2:
                guard let keys = obj["k"] as? [Any] else { continue }
                if keys.count == 1, let k0 = keys[0] as? String, k0 == "requests",
                   let arr = obj["v"] as? [[String: Any]] {
                    requests.append(contentsOf: arr)
                } else if keys.count == 3,
                          let k0 = keys[0] as? String, k0 == "requests",
                          let idx = keys[1] as? Int, idx < requests.count,
                          let k2 = keys[2] as? String {
                    requests[idx][k2] = obj["v"] as Any
                }
            default: break
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var records: [CopilotRecord] = []
        var toolResultMap: [String: ToolResultEntry] = [:]
        var toolCallCount = 0
        var firstTimestamp = ""
        var lastTimestamp = ""

        // If we have a creationDate, use it as the first record timestamp
        if let ms = creationDateMs {
            let ts = isoFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
            if firstTimestamp.isEmpty { firstTimestamp = ts }
        }

        for req in requests {
            // Derive ISO8601 timestamp for this request
            let tsMs: Double?
            if let d = req["timestamp"] as? Double { tsMs = d }
            else if let i = req["timestamp"] as? Int { tsMs = Double(i) }
            else { tsMs = nil }

            let ts: String? = tsMs.map { isoFormatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) }
            if let ts {
                if firstTimestamp.isEmpty { firstTimestamp = ts }
                lastTimestamp = ts
            }

            // User message record
            let userText = (req["message"] as? [String: Any])?["text"] as? String ?? ""
            let userData = CopilotRecordData(
                sessionId: nil, version: nil, producer: nil, copilotVersion: nil,
                vscodeVersion: nil, startTime: nil,
                content: userText, attachments: nil,
                messageId: nil, toolRequests: nil, reasoningText: nil,
                turnId: nil, toolCallId: nil, toolName: nil, arguments: nil, success: nil
            )
            records.append(CopilotRecord(syntheticType: .userMessage, data: userData, timestamp: ts))

            // Assistant turn start
            records.append(CopilotRecord(syntheticType: .assistantTurnStart, timestamp: ts))

            // Process response parts
            let responseParts = req["response"] as? [[String: Any]] ?? []
            var markdownParts: [String] = []
            var toolRequests: [CopilotToolRequest] = []

            for part in responseParts {
                let partKind = part["kind"] as? String ?? ""
                if partKind == "markdownContent" {
                    if let text = part["value"] as? String { markdownParts.append(text) }
                } else if partKind == "toolInvocationSerialized" {
                    let callId = part["toolCallId"] as? String ?? UUID().uuidString
                    let toolId = part["toolId"] as? String
                    let invMsg = part["invocationMessage"] as? String
                    toolRequests.append(CopilotToolRequest(toolCallId: callId, name: toolId, arguments: nil, type: "function"))
                    toolCallCount += 1
                    // Synthesise a tool result if available
                    let isComplete = part["isComplete"] as? Bool ?? false
                    if isComplete {
                        toolResultMap[callId] = ToolResultEntry(
                            content: invMsg ?? "", isError: false, timestamp: ts
                        )
                    }
                }
            }

            // Assistant message record
            let assistantContent = markdownParts.joined()
            let assistantData = CopilotRecordData(
                sessionId: nil, version: nil, producer: nil, copilotVersion: nil,
                vscodeVersion: nil, startTime: nil,
                content: assistantContent.isEmpty ? nil : assistantContent,
                attachments: nil,
                messageId: nil,
                toolRequests: toolRequests.isEmpty ? nil : toolRequests,
                reasoningText: nil,
                turnId: nil, toolCallId: nil, toolName: nil, arguments: nil, success: nil
            )
            records.append(CopilotRecord(syntheticType: .assistantMessage, data: assistantData, timestamp: ts))
            records.append(CopilotRecord(syntheticType: .assistantTurnEnd, timestamp: ts))
        }

        let title = customTitle ?? (requests.first.flatMap { ($0["message"] as? [String: Any])?["text"] as? String }.map { String($0.prefix(120)) } ?? sessionId)

        let metadata = SessionMetadata(
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp.isEmpty ? firstTimestamp : lastTimestamp,
            messageCount: requests.count * 2,
            userMessageCount: requests.count,
            assistantMessageCount: requests.count,
            turnCount: requests.count,
            toolCallCount: toolCallCount,
            models: [],
            turnDurations: [],
            errorDetails: [],
            parallelToolGroups: [],
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
            tokenData: nil
        )
    }
}

private func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
        ?? ISO8601DateFormatter().date(from: string)
}
