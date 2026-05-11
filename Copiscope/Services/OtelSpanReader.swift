import Foundation
import SQLite3

/// Reads spans from the Copilot agent-traces.db SQLite database.
/// Uses the SQLite3 C API directly (no third-party dependency).
final class OtelSpanReader: Sendable {

    private let dbPath: String

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    // MARK: - Public API

    /// Fetch all chat spans for a given conversation/session ID
    func chatSpans(forSession sessionId: String) -> [OtelSpan] {
        // Try direct column match first (old format)
        let sqlDirect = """
            SELECT * FROM spans
            WHERE (conversation_id = ?1 OR chat_session_id = ?1)
              AND operation_name = 'chat'
            ORDER BY start_time_ms ASC
            """
        let direct = querySpans(sql: sqlDirect, bindings: [sessionId])
        if !direct.isEmpty { return direct }

        // Fall back: session ID stored as span attribute 'copilot_chat.parent_chat_session_id'
        let sqlAttr = """
            SELECT s.* FROM spans s
            JOIN span_attributes sa ON sa.span_id = s.span_id
            WHERE sa.key = 'copilot_chat.parent_chat_session_id'
              AND sa.value = ?1
              AND s.operation_name = 'chat'
            ORDER BY s.start_time_ms ASC
            """
        return querySpans(sql: sqlAttr, bindings: [sessionId])
    }

    /// Fetch all spans (any operation) for a given conversation/session ID
    func allSpans(forSession sessionId: String) -> [OtelSpan] {
        let sqlDirect = """
            SELECT * FROM spans
            WHERE conversation_id = ?1 OR chat_session_id = ?1
            ORDER BY start_time_ms ASC
            """
        let direct = querySpans(sql: sqlDirect, bindings: [sessionId])
        if !direct.isEmpty { return direct }

        let sqlAttr = """
            SELECT s.* FROM spans s
            JOIN span_attributes sa ON sa.span_id = s.span_id
            WHERE sa.key = 'copilot_chat.parent_chat_session_id'
              AND sa.value = ?1
            ORDER BY s.start_time_ms ASC
            """
        return querySpans(sql: sqlAttr, bindings: [sessionId])
    }

    /// Fetch tool spans for a given session
    func toolSpans(forSession sessionId: String) -> [OtelSpan] {
        let sql = """
            SELECT * FROM spans
            WHERE (conversation_id = ?1 OR chat_session_id = ?1)
              AND operation_name = 'execute_tool'
            ORDER BY start_time_ms ASC
            """
        return querySpans(sql: sql, bindings: [sessionId])
    }

    /// Fetch agent invocation spans for a given session
    func agentSpans(forSession sessionId: String) -> [OtelSpan] {
        let sql = """
            SELECT * FROM spans
            WHERE (conversation_id = ?1 OR chat_session_id = ?1)
              AND operation_name = 'invoke_agent'
            ORDER BY start_time_ms ASC
            """
        return querySpans(sql: sql, bindings: [sessionId])
    }

    /// Get aggregated token data for a session
    func tokenData(forSession sessionId: String) -> SessionTokenData {
        let spans = chatSpans(forSession: sessionId)
        guard !spans.isEmpty else { return .empty(sessionId: sessionId) }

        var totalInput = 0, totalOutput = 0, totalCached = 0, totalReasoning = 0
        var models = Set<String>()
        var providers = Set<String>()
        var ttfts: [Double] = []
        var modelBreakdowns: [String: (vendor: String, input: Int, output: Int, cached: Int, reasoning: Int, count: Int, ttfts: [Double])] = [:]

        for span in spans {
            let input = span.inputTokens ?? 0
            let output = span.outputTokens ?? 0
            let cached = span.cachedTokens ?? 0
            let reasoning = span.reasoningTokens ?? 0

            totalInput += input
            totalOutput += output
            totalCached += cached
            totalReasoning += reasoning

            if let m = span.effectiveModel { models.insert(m) }
            if let p = span.providerName { providers.insert(p) }
            if let t = span.ttftMs { ttfts.append(t) }

            let key = span.effectiveModel ?? "unknown"
            var existing = modelBreakdowns[key] ?? (vendor: span.providerName ?? "unknown", input: 0, output: 0, cached: 0, reasoning: 0, count: 0, ttfts: [])
            existing.input += input
            existing.output += output
            existing.cached += cached
            existing.reasoning += reasoning
            existing.count += 1
            if let t = span.ttftMs { existing.ttfts.append(t) }
            modelBreakdowns[key] = existing
        }

        let breakdown = modelBreakdowns.map { key, val in
            ModelSpanBreakdown(
                model: key,
                vendor: val.vendor,
                inputTokens: val.input,
                outputTokens: val.output,
                cachedTokens: val.cached,
                reasoningTokens: val.reasoning,
                spanCount: val.count,
                avgTtftMs: val.ttfts.isEmpty ? nil : val.ttfts.reduce(0, +) / Double(val.ttfts.count)
            )
        }

        return SessionTokenData(
            sessionId: sessionId,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCachedTokens: totalCached,
            totalReasoningTokens: totalReasoning,
            chatSpanCount: spans.count,
            models: Array(models),
            providers: Array(providers),
            medianTtftMs: median(ttfts),
            spanBreakdown: breakdown
        )
    }

    /// Get all distinct session IDs from the database
    func allSessionIds() -> [String] {
        var ids: [String] = []
        withDB { db in
            let sql = """
                SELECT DISTINCT conversation_id FROM spans
                WHERE conversation_id IS NOT NULL
                UNION
                SELECT DISTINCT chat_session_id FROM spans
                WHERE chat_session_id IS NOT NULL
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: cStr))
                }
            }
        }
        return Array(Set(ids))
    }

    /// Get span events for a specific span
    func spanEvents(forSpan spanId: String) -> [OtelSpanEvent] {
        var events: [OtelSpanEvent] = []
        withDB { db in
            let sql = "SELECT id, span_id, name, timestamp_ms, attributes FROM span_events WHERE span_id = ?1 ORDER BY timestamp_ms ASC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, spanId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            while sqlite3_step(stmt) == SQLITE_ROW {
                events.append(OtelSpanEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    spanId: textColumn(stmt, 1) ?? "",
                    name: textColumn(stmt, 2) ?? "",
                    timestampMs: sqlite3_column_int64(stmt, 3),
                    attributes: textColumn(stmt, 4)
                ))
            }
        }
        return events
    }

    // MARK: - Private helpers

    private func withDB<T>(_ body: (OpaquePointer) -> T) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db!)
    }

    private func querySpans(sql: String, bindings: [String] = []) -> [OtelSpan] {
        var spans: [OtelSpan] = []
        withDB { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, binding) in bindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), binding, -1, SQLITE_TRANSIENT)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                spans.append(spanFromRow(stmt))
            }
        }
        return spans
    }

    private func spanFromRow(_ stmt: OpaquePointer?) -> OtelSpan {
        OtelSpan(
            spanId: textColumn(stmt, 0) ?? "",
            traceId: textColumn(stmt, 1) ?? "",
            parentSpanId: textColumn(stmt, 2),
            name: textColumn(stmt, 3) ?? "",
            startTimeMs: sqlite3_column_int64(stmt, 4),
            endTimeMs: Double(sqlite3_column_int64(stmt, 5)),
            statusCode: Int(sqlite3_column_int(stmt, 6)),
            statusMessage: textColumn(stmt, 7),
            operationName: textColumn(stmt, 8),
            providerName: textColumn(stmt, 9),
            agentName: textColumn(stmt, 10),
            conversationId: textColumn(stmt, 11),
            requestModel: textColumn(stmt, 12),
            responseModel: textColumn(stmt, 13),
            inputTokens: nullableInt(stmt, 14),
            outputTokens: nullableInt(stmt, 15),
            cachedTokens: nullableInt(stmt, 16),
            reasoningTokens: nullableInt(stmt, 17),
            toolName: textColumn(stmt, 18),
            toolCallId: textColumn(stmt, 19),
            toolType: textColumn(stmt, 20),
            chatSessionId: textColumn(stmt, 21),
            turnIndex: nullableInt(stmt, 22),
            ttftMs: nullableDouble(stmt, 23)
        )
    }

    private func textColumn(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private func nullableInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }

    private func nullableDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, col)
    }
}

// MARK: - Utility

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
    return sorted[mid]
}
