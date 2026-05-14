import XCTest
import SQLite3
@testable import Copiscope

/// Tests for today-only token tracking, cross-day session cost accuracy,
/// multi-dir VS Code Insiders support, and analytics time-range filtering.
final class AnalyticsTimeFilterTests: XCTestCase {

    private var tempDir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopIscopeTFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("agent-traces.db").path
        createSpansDB(at: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Creates the minimal spans table schema used by OtelSpanReader.
    private func createSpansDB(at path: String) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE spans (
                span_id TEXT PRIMARY KEY, trace_id TEXT NOT NULL, parent_span_id TEXT,
                name TEXT NOT NULL, start_time_ms INTEGER NOT NULL, end_time_ms INTEGER NOT NULL,
                status_code INTEGER NOT NULL DEFAULT 0, status_message TEXT,
                operation_name TEXT, provider_name TEXT, agent_name TEXT, conversation_id TEXT,
                request_model TEXT, response_model TEXT,
                input_tokens INTEGER, output_tokens INTEGER, cached_tokens INTEGER, reasoning_tokens INTEGER,
                tool_name TEXT, tool_call_id TEXT, tool_type TEXT,
                chat_session_id TEXT, turn_index INTEGER, ttft_ms REAL
            );
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Inserts a chat span into the temp DB.
    private func insertSpan(
        sessionId: String,
        startTimeMs: Int64,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int = 0,
        model: String = "claude-sonnet-4.6",
        provider: String = "github"
    ) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO spans
            (span_id, trace_id, name, start_time_ms, end_time_ms, status_code,
             operation_name, provider_name, conversation_id,
             response_model, input_tokens, output_tokens, cached_tokens)
            VALUES (?, ?, 'chat', ?, ?, 0, 'chat', ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let spanId = UUID().uuidString
        sqlite3_bind_text(stmt, 1, spanId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, "trace-\(spanId)", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, startTimeMs)
        sqlite3_bind_int64(stmt, 4, startTimeMs + 1000)
        sqlite3_bind_text(stmt, 5, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 8, Int32(inputTokens))
        sqlite3_bind_int(stmt, 9, Int32(outputTokens))
        sqlite3_bind_int(stmt, 10, Int32(cachedTokens))
        sqlite3_step(stmt)
    }

    // MARK: - Timestamp helpers

    private func msForDate(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func todayStartMs() -> Int64 {
        msForDate(Calendar.current.startOfDay(for: Date()))
    }

    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: Date())!
    }

    private func isoString(_ date: Date) -> String {
        ISO8601.withFractional.string(from: date)
    }

    // MARK: - OtelSpanReader today sub-total tests

    /// A session entirely from today: todayTokens == totalTokens.
    func testTodaySubtotalsEqualsTotal_WhenAllSpansAreToday() {
        let sessionId = "session-all-today"
        // Three spans, all today
        insertSpan(sessionId: sessionId, startTimeMs: todayStartMs() + 1000, inputTokens: 1000, outputTokens: 200)
        insertSpan(sessionId: sessionId, startTimeMs: todayStartMs() + 5000, inputTokens: 2000, outputTokens: 400)
        insertSpan(sessionId: sessionId, startTimeMs: todayStartMs() + 9000, inputTokens: 3000, outputTokens: 600)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        XCTAssertEqual(td.totalInputTokens, 6000)
        XCTAssertEqual(td.totalOutputTokens, 1200)
        XCTAssertEqual(td.todayInputTokens, 6000, "All spans today → today input == total input")
        XCTAssertEqual(td.todayOutputTokens, 1200, "All spans today → today output == total output")
        XCTAssertEqual(td.todayCachedTokens, 0)
    }

    /// A cross-midnight session: only today's spans count in today sub-totals.
    func testTodaySubtotals_CrossDaySession() {
        let sessionId = "session-cross-day"
        let yesterdayMs = msForDate(daysAgo(1))
        let todayMs = todayStartMs() + 3_600_000  // 1h into today

        // Yesterday: 10_000 input, 500 output
        insertSpan(sessionId: sessionId, startTimeMs: yesterdayMs + 1000, inputTokens: 10_000, outputTokens: 500)
        // Today: 4_000 input, 200 output
        insertSpan(sessionId: sessionId, startTimeMs: todayMs, inputTokens: 4_000, outputTokens: 200)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        XCTAssertEqual(td.totalInputTokens, 14_000, "Total spans = both days")
        XCTAssertEqual(td.totalOutputTokens, 700)
        XCTAssertEqual(td.todayInputTokens, 4_000, "Only today's span")
        XCTAssertEqual(td.todayOutputTokens, 200, "Only today's span")
    }

    /// A session entirely from yesterday: today sub-totals should be zero.
    func testTodaySubtotalsAreZero_WhenSessionIsYesterday() {
        let sessionId = "session-yesterday-only"
        let yesterdayMs = msForDate(daysAgo(1))

        insertSpan(sessionId: sessionId, startTimeMs: yesterdayMs + 500, inputTokens: 5_000, outputTokens: 300)
        insertSpan(sessionId: sessionId, startTimeMs: yesterdayMs + 1500, inputTokens: 3_000, outputTokens: 150)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        XCTAssertEqual(td.totalInputTokens, 8_000)
        XCTAssertEqual(td.todayInputTokens, 0, "No spans today → today input must be 0")
        XCTAssertEqual(td.todayOutputTokens, 0, "No spans today → today output must be 0")
    }

    /// A session from 7 days ago: today sub-totals should be zero.
    func testTodaySubtotalsAreZero_WhenSessionIsOneWeekOld() {
        let sessionId = "session-week-old"
        let weekAgoMs = msForDate(daysAgo(7))

        insertSpan(sessionId: sessionId, startTimeMs: weekAgoMs + 1000, inputTokens: 20_000, outputTokens: 1_000)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        XCTAssertEqual(td.totalInputTokens, 20_000)
        XCTAssertEqual(td.todayInputTokens, 0)
        XCTAssertEqual(td.todayOutputTokens, 0)
    }

    /// Cached tokens are included correctly in today sub-total.
    func testTodaySubtotals_IncludesCachedTokens() {
        let sessionId = "session-cached"
        let todayMs = todayStartMs() + 2_000

        insertSpan(sessionId: sessionId, startTimeMs: todayMs, inputTokens: 10_000, outputTokens: 500, cachedTokens: 8_000)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        XCTAssertEqual(td.todayInputTokens, 10_000)
        XCTAssertEqual(td.todayCachedTokens, 8_000, "Cached tokens must be tracked in today sub-total")
    }

    // MARK: - Analytics time-range filtering

    /// "Today" range includes sessions active today (lastTimestamp >= todayStart),
    /// even if firstTimestamp is yesterday.
    func testTodayRangeIncludesCrossDaySessions() {
        let yesterday = daysAgo(1)
        let now = Date()

        let crossDaySession = SessionSummary(
            id: "cross", workspaceId: "ws", title: "cross",
            firstTimestamp: isoString(yesterday),
            lastTimestamp: isoString(now),
            messageCount: 10, primaryModel: "claude-sonnet-4.6", vendor: "github",
            turnCount: 10, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 5_000, totalOutputTokens: 1_000, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 0.9,
            premiumRequestCount: 10, totalMultiplierCost: 0, modelBreakdown: []
        )
        let todayStart = Calendar.current.startOfDay(for: now)
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        // "Today" uses lastTimestamp for inclusion
        let lastDate = isoFull.date(from: crossDaySession.lastTimestamp)
            ?? isoBasic.date(from: crossDaySession.lastTimestamp)
        let includedInToday = (lastDate ?? .distantPast) >= todayStart

        XCTAssertTrue(includedInToday, "Cross-day session with lastTimestamp=now must appear in Today")
    }

    /// A session from yesterday should NOT appear in today's range.
    func testTodayRangeExcludesPurelyYesterdaySessions() {
        let yesterday = daysAgo(1)
        let endOfYesterday = Calendar.current.date(byAdding: .hour, value: 23, to: Calendar.current.startOfDay(for: yesterday))!

        let yesterdaySession = SessionSummary(
            id: "past", workspaceId: "ws", title: "past",
            firstTimestamp: isoString(yesterday),
            lastTimestamp: isoString(endOfYesterday),
            messageCount: 5, primaryModel: nil, vendor: nil,
            turnCount: 5, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 3_000, totalOutputTokens: 500, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 0.3,
            premiumRequestCount: 0, totalMultiplierCost: 0, modelBreakdown: []
        )

        let todayStart = Calendar.current.startOfDay(for: Date())
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lastDate = isoFull.date(from: yesterdaySession.lastTimestamp)
        let includedInToday = (lastDate ?? .distantPast) >= todayStart

        XCTAssertFalse(includedInToday, "Pure yesterday session must NOT appear in Today")
    }

    /// 7-day range uses firstTimestamp: session started 8 days ago is excluded.
    func testSevenDayRangeExcludesSessionsOlderThanSevenDays() {
        let eightDaysAgo = daysAgo(8)
        let (from, _) = AnalyticsTimeRange.sevenDays.dateRange(customFrom: Date(), customTo: Date())

        let sessionDate = eightDaysAgo
        // firstTimestamp-based filter
        let included = from.map { sessionDate >= $0 } ?? true

        XCTAssertFalse(included, "Session started 8 days ago must be EXCLUDED from 7-day range")
    }

    /// 7-day range includes session started 6 days ago.
    func testSevenDayRangeIncludesSessionFromSixDaysAgo() {
        let sixDaysAgo = daysAgo(6)
        let (from, _) = AnalyticsTimeRange.sevenDays.dateRange(customFrom: Date(), customTo: Date())

        let included = from.map { sixDaysAgo >= $0 } ?? true
        XCTAssertTrue(included, "Session started 6 days ago must be INCLUDED in 7-day range")
    }

    /// 30-day range includes session started 8 days ago (outside 7-day but inside 30-day).
    func testThirtyDayRangeIncludesSessionFromEightDaysAgo() {
        let eightDaysAgo = daysAgo(8)
        let (from, _) = AnalyticsTimeRange.thirtyDays.dateRange(customFrom: Date(), customTo: Date())

        let included = from.map { eightDaysAgo >= $0 } ?? true
        XCTAssertTrue(included, "Session started 8 days ago must be INCLUDED in 30-day range")
    }

    /// 30-day range excludes session started 31 days ago.
    func testThirtyDayRangeExcludesSessionOlderThanThirtyDays() {
        let thirtyOneDaysAgo = daysAgo(31)
        let (from, _) = AnalyticsTimeRange.thirtyDays.dateRange(customFrom: Date(), customTo: Date())

        let included = from.map { thirtyOneDaysAgo >= $0 } ?? true
        XCTAssertFalse(included, "Session started 31 days ago must be EXCLUDED from 30-day range")
    }

    // MARK: - Cross-day session cost accuracy

    /// When today sub-totals are available, today cost must be < full session cost.
    func testTodayCostIsLowerThanFullCostForCrossDaySession() {
        let sessionId = "cross-cost"
        let yesterdayMs = msForDate(daysAgo(1))
        let todayMs = todayStartMs() + 1_000

        // Yesterday: 50_000 input, 2_000 output (expensive)
        insertSpan(sessionId: sessionId, startTimeMs: yesterdayMs + 1000, inputTokens: 50_000, outputTokens: 2_000)
        // Today: 5_000 input, 300 output (cheap)
        insertSpan(sessionId: sessionId, startTimeMs: todayMs, inputTokens: 5_000, outputTokens: 300)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        let fullCost = estimateCostFromTokens(
            model: "claude-sonnet-4.6",
            inputTokens: td.totalInputTokens,
            outputTokens: td.totalOutputTokens,
            cachedTokens: td.totalCachedTokens
        )
        let todayCost = estimateCostFromTokens(
            model: "claude-sonnet-4.6",
            inputTokens: td.todayInputTokens,
            outputTokens: td.todayOutputTokens,
            cachedTokens: td.todayCachedTokens
        )

        XCTAssertGreaterThan(fullCost, 0, "Full session cost must be positive")
        XCTAssertGreaterThan(todayCost, 0, "Today cost must be positive")
        XCTAssertLessThan(todayCost, fullCost,
            "Today cost must be less than full session cost for a cross-day session")
    }

    /// A session with no today spans: today cost is 0.
    func testTodayCostIsZero_WhenNoSpansToday() {
        let sessionId = "no-today-spans"
        let yesterdayMs = msForDate(daysAgo(1))
        insertSpan(sessionId: sessionId, startTimeMs: yesterdayMs + 500, inputTokens: 8_000, outputTokens: 400)

        let reader = OtelSpanReader(dbPath: dbPath)
        let td = reader.tokenData(forSession: sessionId)

        let todayCost = estimateCostFromTokens(
            model: "claude-sonnet-4.6",
            inputTokens: td.todayInputTokens,
            outputTokens: td.todayOutputTokens,
            cachedTokens: td.todayCachedTokens
        )
        XCTAssertEqual(todayCost, 0.0, accuracy: 1e-10, "No spans today → zero today cost")
    }

    // MARK: - VS Code Insiders multi-dir detection

    /// WorkspaceStorage detection should find both stable and Insiders dirs when both have workspaceStorage.
    func testInsidersDetection_BothDirsPresent() throws {
        let appSupport = tempDir!
        let stableDir = appSupport.appendingPathComponent("Code/User")
        let insidersDir = appSupport.appendingPathComponent("Code - Insiders/User")

        // Create workspaceStorage in both dirs to simulate real VS Code layout
        try FileManager.default.createDirectory(
            at: stableDir.appendingPathComponent("workspaceStorage"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: insidersDir.appendingPathComponent("workspaceStorage"),
            withIntermediateDirectories: true
        )

        let detected = detectVSCodeDirs(appSupport: appSupport)
        XCTAssertEqual(detected.count, 2, "Both stable and Insiders dirs should be detected")
        XCTAssertTrue(detected.contains(where: { $0.path.contains("Code/User") && !$0.path.contains("Insiders") }),
                      "Stable Code/User must be in detected dirs")
        XCTAssertTrue(detected.contains(where: { $0.path.contains("Code - Insiders") }),
                      "Code - Insiders/User must be in detected dirs")
    }

    /// When only stable VS Code is installed, only one dir is detected.
    func testInsidersDetection_OnlyStablePresent() throws {
        let appSupport = tempDir!
        let stableDir = appSupport.appendingPathComponent("Code/User")
        try FileManager.default.createDirectory(
            at: stableDir.appendingPathComponent("workspaceStorage"),
            withIntermediateDirectories: true
        )
        // Insiders dir does NOT exist

        let detected = detectVSCodeDirs(appSupport: appSupport)
        XCTAssertEqual(detected.count, 1, "Only stable VS Code dir should be detected")
        XCTAssertTrue(detected[0].path.contains("Code/User"),
                      "The single detected dir should be stable Code/User")
    }

    /// When neither VS Code dir exists, falls back to stable Code/User.
    func testInsidersDetection_FallbackWhenNeitherPresent() {
        let appSupport = tempDir!  // nothing created inside
        let detected = detectVSCodeDirs(appSupport: appSupport)
        XCTAssertEqual(detected.count, 1, "Should fall back to exactly one dir")
        XCTAssertTrue(detected[0].path.contains("Code/User"),
                      "Fallback must be stable Code/User")
        XCTAssertFalse(detected[0].path.contains("Insiders"),
                       "Fallback must NOT be Insiders")
    }

    /// When only Insiders is installed (stable workspaceStorage missing), only Insiders is detected.
    func testInsidersDetection_OnlyInsidersPresent() throws {
        let appSupport = tempDir!
        let insidersDir = appSupport.appendingPathComponent("Code - Insiders/User")
        try FileManager.default.createDirectory(
            at: insidersDir.appendingPathComponent("workspaceStorage"),
            withIntermediateDirectories: true
        )
        // stable Code/User does NOT have workspaceStorage

        let detected = detectVSCodeDirs(appSupport: appSupport)
        XCTAssertEqual(detected.count, 1, "Only Insiders dir should be detected")
        XCTAssertTrue(detected[0].path.contains("Code - Insiders"),
                      "Detected dir should be Insiders")
    }

    /// Stable dir is always first when both are present (preference order).
    func testInsidersDetection_StableIsFirst() throws {
        let appSupport = tempDir!
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("Code/User/workspaceStorage"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("Code - Insiders/User/workspaceStorage"),
            withIntermediateDirectories: true
        )

        let detected = detectVSCodeDirs(appSupport: appSupport)
        XCTAssertGreaterThanOrEqual(detected.count, 2)
        XCTAssertFalse(detected[0].path.contains("Insiders"),
                       "Stable Code/User must come before Insiders (index 0)")
        XCTAssertTrue(detected[1].path.contains("Insiders"),
                      "Insiders must be second (index 1)")
    }

    // MARK: - Regression: tokens differ across time ranges

    /// Regression: a cross-day session must not inflate the 7-day range to match 30-day.
    func testTokensDifferBetweenSevenAndThirtyDayRanges_CrossDaySession() {
        let now = Date()
        let eightDaysAgoStr = isoString(daysAgo(8))
        let todayStr = isoString(now)

        let sessionA = SessionSummary(
            id: "A", workspaceId: "ws", title: "A",
            firstTimestamp: isoString(daysAgo(2)), lastTimestamp: todayStr,
            messageCount: 5, primaryModel: "claude-sonnet-4.6", vendor: "github",
            turnCount: 5, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 0, totalOutputTokens: 10_000, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 1.0,
            premiumRequestCount: 5, totalMultiplierCost: 0, modelBreakdown: []
        )
        let sessionB = SessionSummary(
            id: "B", workspaceId: "ws", title: "B",
            firstTimestamp: eightDaysAgoStr, lastTimestamp: eightDaysAgoStr,
            messageCount: 3, primaryModel: "claude-sonnet-4.6", vendor: "github",
            turnCount: 3, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 0, totalOutputTokens: 5_000, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 0.5,
            premiumRequestCount: 3, totalMultiplierCost: 0, modelBreakdown: []
        )

        func tokenSumForRange(_ range: AnalyticsTimeRange) -> Int {
            let (from, to) = range.dateRange(customFrom: now, customTo: now)
            let isoFull = ISO8601DateFormatter()
            isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [sessionA, sessionB].reduce(0) { acc, s in
                let filterDate = isoFull.date(from: s.firstTimestamp)
                if let f = from, let d = filterDate, d < f { return acc }
                if let t = to,   let d = filterDate, d >= t { return acc }
                return acc + s.totalOutputTokens
            }
        }

        let sevenDay  = tokenSumForRange(.sevenDays)
        let thirtyDay = tokenSumForRange(.thirtyDays)
        XCTAssertEqual(sevenDay, 10_000, "7-day: only session A (started 2 days ago)")
        XCTAssertEqual(thirtyDay, 15_000, "30-day: both sessions")
        XCTAssertNotEqual(sevenDay, thirtyDay, "Token totals must differ between 7-day and 30-day")
    }
}

// MARK: - Extracted detection logic (mirrors SessionStore.init)

/// Mirrors the VS Code dir detection logic from SessionStore.init so tests
/// can validate it independently without instantiating the full store.
private func detectVSCodeDirs(appSupport: URL) -> [URL] {
    let fm = FileManager.default
    let variants = ["Code/User", "Code - Insiders/User"]
    var detected: [URL] = variants.compactMap { rel in
        let url = appSupport.appendingPathComponent(rel)
        return fm.fileExists(atPath: url.appendingPathComponent("workspaceStorage").path) ? url : nil
    }
    if detected.isEmpty {
        detected = [appSupport.appendingPathComponent("Code/User")]
    }
    return detected
}
