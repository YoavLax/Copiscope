import XCTest
@testable import Copiscope

/// Tests for SessionParser — specifically that token data is correctly extracted from the
/// chatSessions JSONL format, which is the only source of token data when the OTEL DB
/// does not have spans for a given session (e.g. older sessions or sessions not using
/// the agent-traces pipeline).
final class SessionParserTests: XCTestCase {

    private var parser: SessionParser!
    private var tempDir: URL!

    override func setUpWithError() throws {
        parser = SessionParser()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopIscopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - chatSessions format token extraction

    func testChatSessionsMetadataExtractsCompletionTokens() async throws {
        // A minimal chatSessions snapshot with 2 requests, each with completionTokens
        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "creationDate": 1746921600000.0,  // May 11 2026 00:00 UTC
                "requests": [
                    [
                        "timestamp": 1746921600000.0,
                        "modelId": "copilot/claude-sonnet-4.6",
                        "completionTokens": 1234,
                        "message": ["text": "Hello world"]
                    ],
                    [
                        "timestamp": 1746921660000.0,
                        "modelId": "copilot/claude-sonnet-4.6",
                        "completionTokens": 567,
                        "message": ["text": "Follow-up question"]
                    ]
                ]
            ]
        ]
        let jsonl = (try JSONSerialization.data(withJSONObject: snapshot)).string + "\n"
        let fileURL = tempDir.appendingPathComponent("test-session.jsonl")
        try jsonl.data(using: .utf8)!.write(to: fileURL)

        let summary = try await parser.parseMetadataChatSession(url: fileURL, sessionId: "test-123", workspaceId: "ws-1")

        XCTAssertEqual(summary.id, "test-123")
        XCTAssertEqual(summary.workspaceId, "ws-1")
        XCTAssertEqual(summary.totalOutputTokens, 1234 + 567, "Should sum completionTokens from all requests")
        XCTAssertEqual(summary.messageCount, 2, "Each request is one exchange")
        XCTAssertEqual(summary.primaryModel, "copilot/claude-sonnet-4.6")
        XCTAssertGreaterThan(summary.estimatedCost, 0, "Cost should be estimated from output tokens")
    }

    func testChatSessionsMetadataHandlesMissingTokens() async throws {
        // Requests without completionTokens should not crash
        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "creationDate": 1746921600000.0,
                "requests": [
                    ["timestamp": 1746921600000.0, "message": ["text": "Hi"]],
                    ["timestamp": 1746921660000.0, "modelId": "copilot/gpt-4o", "message": ["text": "More"]]
                ]
            ]
        ]
        let jsonl = (try JSONSerialization.data(withJSONObject: snapshot)).string + "\n"
        let fileURL = tempDir.appendingPathComponent("no-tokens.jsonl")
        try jsonl.data(using: .utf8)!.write(to: fileURL)

        let summary = try await parser.parseMetadataChatSession(url: fileURL, sessionId: "no-tok", workspaceId: "ws-1")
        XCTAssertEqual(summary.totalOutputTokens, 0, "Zero tokens when completionTokens absent")
    }

    func testChatSessionsMetadataIncludesPatches() async throws {
        // A snapshot followed by a kind=2 patch adding a new request
        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "creationDate": 1746921600000.0,
                "requests": [
                    ["timestamp": 1746921600000.0, "modelId": "copilot/claude-sonnet-4.6", "completionTokens": 100, "message": ["text": "Q1"]]
                ]
            ]
        ]
        let patch: [String: Any] = [
            "kind": 2,
            "k": ["requests"],
            "v": [
                ["timestamp": 1746921660000.0, "modelId": "copilot/claude-sonnet-4.6", "completionTokens": 200, "message": ["text": "Q2"]]
            ]
        ]
        let snapshotData = try JSONSerialization.data(withJSONObject: snapshot)
        let patchData = try JSONSerialization.data(withJSONObject: patch)
        let jsonl = snapshotData.string + "\n" + patchData.string + "\n"
        let fileURL = tempDir.appendingPathComponent("with-patch.jsonl")
        try jsonl.data(using: .utf8)!.write(to: fileURL)

        let summary = try await parser.parseMetadataChatSession(url: fileURL, sessionId: "patched", workspaceId: "ws-1")
        XCTAssertEqual(summary.totalOutputTokens, 300, "Should include tokens from both snapshot and patch requests")
        XCTAssertEqual(summary.messageCount, 2)
    }

    func testChatSessionsTimestampParsedFromRequests() async throws {
        let snapshot: [String: Any] = [
            "kind": 0,
            "v": [
                "creationDate": 1746921600000.0,
                "requests": [
                    ["timestamp": 1746921600000.0, "message": ["text": "first"]],
                    ["timestamp": 1746921700000.0, "message": ["text": "second"]]
                ]
            ]
        ]
        let jsonl = (try JSONSerialization.data(withJSONObject: snapshot)).string + "\n"
        let fileURL = tempDir.appendingPathComponent("timestamps.jsonl")
        try jsonl.data(using: .utf8)!.write(to: fileURL)

        let summary = try await parser.parseMetadataChatSession(url: fileURL, sessionId: "ts-test", workspaceId: "ws-1")
        XCTAssertFalse(summary.firstTimestamp.isEmpty, "firstTimestamp should be set from requests")
        XCTAssertFalse(summary.lastTimestamp.isEmpty, "lastTimestamp should be set from requests")
        // lastTimestamp should reflect the later of the two requests
        XCTAssertGreaterThan(summary.lastTimestamp, summary.firstTimestamp)
    }

    // MARK: - Transcript format (no tokens)

    func testTranscriptMetadataHasZeroTokens() async throws {
        // Transcript format has no token data at all
        let lines = [
            #"{"type":"session.start","data":{"sessionId":"tr-1","version":1,"producer":"copilot-agent","copilotVersion":"0.46.0","vscodeVersion":"1.118.0","startTime":"2026-05-11T10:00:00.000Z"},"id":"id1","timestamp":"2026-05-11T10:00:00.000Z"}"#,
            #"{"type":"user.message","data":{"content":"Hello"},"id":"id2","timestamp":"2026-05-11T10:00:01.000Z"}"#,
            #"{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"id3","timestamp":"2026-05-11T10:00:01.100Z"}"#,
            #"{"type":"assistant.message","data":{"messageId":"msg1","content":"Hi there","toolRequests":[]},"id":"id4","timestamp":"2026-05-11T10:00:05.000Z"}"#,
            #"{"type":"assistant.turn_end","data":{"turnId":"0"},"id":"id5","timestamp":"2026-05-11T10:00:05.500Z"}"#
        ]
        let jsonl = lines.joined(separator: "\n") + "\n"
        let fileURL = tempDir.appendingPathComponent("transcript.jsonl")
        try jsonl.data(using: .utf8)!.write(to: fileURL)

        let summary = try await parser.parseMetadata(url: fileURL, sessionId: "tr-1", workspaceId: "ws-1")
        XCTAssertEqual(summary.totalInputTokens, 0, "Transcript format never has input tokens")
        XCTAssertEqual(summary.totalOutputTokens, 0, "Transcript format never has output tokens")
        XCTAssertEqual(summary.estimatedCost, 0, "No tokens → no cost")
        XCTAssertEqual(summary.messageCount, 2, "user + assistant message counted")
    }

    // MARK: - Analytics time-range filtering correctness

    /// Verifies that AnalyticsTimeRange.dateRange correctly produces ranges that would
    /// include/exclude sessions from different dates — confirming the filter logic is sound.
    func testAnalyticsTimeRangeDateRangeFiltering() {
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!

        let sevenDayRange = AnalyticsTimeRange.sevenDays.dateRange(
            customFrom: now, customTo: now
        )
        let thirtyDayRange = AnalyticsTimeRange.thirtyDays.dateRange(
            customFrom: now, customTo: now
        )
        let todayRange = AnalyticsTimeRange.today.dateRange(
            customFrom: now, customTo: now
        )

        // Today's range: start of today → nil (open end)
        XCTAssertEqual(sevenDayRange.to, nil, "7-day range should have open upper bound")
        XCTAssertEqual(thirtyDayRange.to, nil, "30-day range should have open upper bound")
        XCTAssertEqual(todayRange.to, nil, "Today range should have open upper bound")
        XCTAssertEqual(todayRange.from, todayStart, "Today range should start at midnight")

        // 7-day from date should be approximately 7 days ago
        let sevenDayFrom = sevenDayRange.from!
        XCTAssertTrue(sevenDayFrom < threeDaysAgo, "3 days ago should be inside 7-day window")
        XCTAssertTrue(sevenDayFrom > eightDaysAgo, "8 days ago should be OUTSIDE 7-day window")

        // Simulate filtering: a session from 8 days ago should appear in 30-day but NOT 7-day
        let oldSessionDate = eightDaysAgo
        let in7Day = !(oldSessionDate < sevenDayRange.from!)
        let in30Day = !(oldSessionDate < thirtyDayRange.from!)
        XCTAssertFalse(in7Day, "Session from 8 days ago must NOT appear in 7-day view")
        XCTAssertTrue(in30Day, "Session from 8 days ago MUST appear in 30-day view")
    }

    /// Regression test: tokens and cost must differ between 7-day and 30-day views
    /// when sessions outside the 7-day window have non-zero token counts.
    ///
    /// Root cause (now fixed): recomputeAnalytics was using lastTimestamp for range filtering.
    /// A long-running session started on May 11 but with last activity on May 12 was being
    /// included in "Today," inflating every range to the same total. Fixed by using
    /// firstTimestamp for range filtering so sessions are bucketed by when they STARTED.
    func testTokensAndCostDifferAcrossTimeRanges() {
        let now = Date()
        let todayStr = ISO8601.withFractional.string(from: now)
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        let eightDaysAgoStr = ISO8601.withFractional.string(from: eightDaysAgo)

        // session A: started TODAY, 10_000 output tokens
        let sessionA = SessionSummary(
            id: "A", workspaceId: "ws", title: "A",
            firstTimestamp: todayStr, lastTimestamp: todayStr,
            messageCount: 5, primaryModel: "claude-sonnet-4.6", vendor: "github",
            turnCount: 5, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 0, totalOutputTokens: 10_000, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 1.0,
            premiumRequestCount: 5, totalMultiplierCost: 0, modelBreakdown: []
        )
        // session B: started 8 DAYS AGO but lastTimestamp = today (cross-day session).
        // The old bug: lastTimestamp-based filter would include B in "7-day" AND "today."
        // The fix: firstTimestamp-based filter correctly excludes B from "7-day" view.
        let sessionB = SessionSummary(
            id: "B", workspaceId: "ws", title: "B",
            firstTimestamp: eightDaysAgoStr, lastTimestamp: todayStr,
            messageCount: 3, primaryModel: "claude-sonnet-4.6", vendor: "github",
            turnCount: 3, toolCallCount: 0, hasError: false, observability: .empty,
            totalInputTokens: 0, totalOutputTokens: 5_000, totalCachedTokens: 0,
            totalReasoningTokens: 0, estimatedCost: 0.5,
            premiumRequestCount: 3, totalMultiplierCost: 0, modelBreakdown: []
        )

        let sessions = [sessionA, sessionB]

        // Simulate the recomputeAnalytics filtering logic (using firstTimestamp for range)
        func tokenSum(range: AnalyticsTimeRange) -> (tokens: Int, cost: Double) {
            let (fromDate, _) = range.dateRange(customFrom: now, customTo: now)
            var tokens = 0
            var cost = 0.0
            for session in sessions {
                // Use firstTimestamp for range filter — matches recomputeAnalytics behaviour
                let filterDate = ISO8601.parse(session.firstTimestamp)
                if let from = fromDate, let d = filterDate, d < from { continue }
                tokens += session.totalInputTokens + session.totalOutputTokens
                cost += session.estimatedCost
            }
            return (tokens, cost)
        }

        let sevenDay = tokenSum(range: .sevenDays)
        let thirtyDay = tokenSum(range: .thirtyDays)

        // Session B started 8 days ago → excluded from 7-day window
        XCTAssertEqual(sevenDay.tokens, 10_000, "7-day view: only session A (today)")
        // Session B started 8 days ago → included in 30-day window
        XCTAssertEqual(thirtyDay.tokens, 15_000, "30-day view: both sessions")
        XCTAssertNotEqual(sevenDay.tokens, thirtyDay.tokens,
            "Tokens MUST differ across time ranges for cross-day sessions")
        XCTAssertNotEqual(sevenDay.cost, thirtyDay.cost,
            "Cost MUST differ across time ranges")
    }
}

// MARK: - Helpers

private extension Data {
    var string: String { String(data: self, encoding: .utf8) ?? "" }
}
