import XCTest
@testable import Claudoscope

/// Regression tests for the single-pass refactor of SessionParser. Each case
/// covers a subtle interaction the buffer-and-replay design must preserve
/// against the legacy two-pass implementation.
final class SinglePassParityTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-single-pass-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A no-usage record arriving before a real orphan with the same msg.id
    /// must not gate out the orphan. Today the no-usage record is filtered
    /// by `if isBillable, let usage = ...`, so it never enters dedup. The
    /// single-pass version must preserve that ordering: dedup is checked
    /// only after `usage != nil`.
    func testNoUsageRecordDoesNotPoisonLaterOrphan() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let noUsage = """
        {"type":"assistant","uuid":"u1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","id":"msg_x","model":"claude-opus-4-5"}}
        """
        let orphanWithUsage = """
        {"type":"assistant","uuid":"u2","sessionId":"sess-1","timestamp":"2026-04-26T10:00:01.000Z","message":{"role":"assistant","id":"msg_x","model":"claude-opus-4-5","usage":{"input_tokens":50,"output_tokens":75}}}
        """
        let url = try writeTempFile([noUsage, orphanWithUsage])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50, "orphan with usage must bill even when a no-usage record for the same msg.id arrived first")
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }

    /// Compaction interleave: user1 -> assistant1(no stop) -> compact_boundary
    /// -> user2 -> assistant2(stop_reason, same msg.id as assistant1).
    /// The intermediate assistant1 is dropped (its msg.id has stop_reason
    /// elsewhere), so the only billable turn is assistant2. That turn must
    /// reference user2's timestamp and carry isPostCompaction=true.
    func testCompactionInterleaveWithSharedMsgIdPreservesUserTimestamp() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let user1 = """
        {"type":"user","uuid":"uu1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"user","content":"hi"}}
        """
        let assistantIntermediate = """
        {"type":"assistant","uuid":"a1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:01.000Z","message":{"role":"assistant","id":"msg_dual","model":"claude-opus-4-5","usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let compactBoundary = """
        {"type":"system","uuid":"s1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:02.000Z","subtype":"compact_boundary","compactMetadata":{"preTokens":1234}}
        """
        let user2 = """
        {"type":"user","uuid":"uu2","sessionId":"sess-1","timestamp":"2026-04-26T10:00:10.000Z","message":{"role":"user","content":"continue"}}
        """
        let assistantFinal = """
        {"type":"assistant","uuid":"a2","sessionId":"sess-1","timestamp":"2026-04-26T10:00:12.000Z","message":{"role":"assistant","id":"msg_dual","model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200}}}
        """
        let url = try writeTempFile([user1, assistantIntermediate, compactBoundary, user2, assistantFinal])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "only assistantFinal should bill")
        XCTAssertEqual(summary.totalOutputTokens, 200)
        XCTAssertEqual(summary.compactionCount, 1)
        XCTAssertEqual(summary.observability.compactionTimestamps.count, 1)

        // SessionObservability rolls per-turn data into summary stats. With
        // exactly one billed turn, both median and max collapse to that turn's
        // duration. The key parity check: 2000ms means the snapshot used
        // user2's timestamp (10s -> 12s = 2000ms). If the refactor had reset
        // lastUserTimestamp prematurely, durationMs would be 0 (or 12000ms
        // if it had used user1).
        XCTAssertEqual(summary.observability.medianTurnDurationMs, 2000, "must reference user2, not user1")
        XCTAssertEqual(summary.observability.maxTurnDurationMs, 2000)

        // modelBreakdown.turnCount == 1 confirms exactly one billed turn for
        // the opus family.
        let opusBreakdown = summary.modelBreakdown.first { $0.model == "opus" }
        XCTAssertEqual(opusBreakdown?.turnCount, 1)
    }

    /// `parse()` exposes the raw record list to the chat view via
    /// `ParsedSession.records`. Its order must match the on-disk order, since
    /// the chat view renders them top-to-bottom. A buffer-and-replay refactor
    /// must not introduce reordering.
    func testParseRecordsArrayPreservesOnDiskOrder() async throws {
        let parser = SessionParser()

        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"user","content":"first"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:01.000Z","message":{"role":"assistant","id":"msg_1","model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":20}}}"#,
            #"{"type":"user","uuid":"u2","sessionId":"sess-1","timestamp":"2026-04-26T10:00:02.000Z","message":{"role":"user","content":"second"}}"#,
            #"{"type":"assistant","uuid":"a2","sessionId":"sess-1","timestamp":"2026-04-26T10:00:03.000Z","message":{"role":"assistant","id":"msg_2","model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":30,"output_tokens":40}}}"#,
        ]
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try await parser.parse(url: url, sessionId: "sess-1")

        XCTAssertEqual(parsed.records.count, 4)
        XCTAssertEqual(parsed.records[0].uuid, "u1")
        XCTAssertEqual(parsed.records[1].uuid, "a1")
        XCTAssertEqual(parsed.records[2].uuid, "u2")
        XCTAssertEqual(parsed.records[3].uuid, "a2")
    }
}
