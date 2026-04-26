import XCTest
@testable import Claudoscope

/// Regression: Claude Code re-persists the same Anthropic API response across
/// tool-use turn boundaries. Each copy carries identical usage but a new uuid
/// and timestamp, so uuid-only dedup couldn't catch them and totals inflated.
/// On Igor's machine the inflation was ~80% ($1616 vs $898 actual bill).
/// Dedup now keys off message.id, which is the same across every copy.
final class MessageIdDedupTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-msgid-dedup-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func usageRecord(uuid: String, msgId: String, timestamp: String) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"sess-1","timestamp":"\(timestamp)","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120","stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_5m_input_tokens":500,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    func testParseMetadataDedupsByMessageId() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Three records with identical msgId but different uuids/timestamps —
        // mimics Claude Code's tool-use turn re-persistence pattern.
        let url = try writeTempFile([
            usageRecord(uuid: "u1", msgId: "msg_abc", timestamp: "2026-04-26T10:00:00.000Z"),
            usageRecord(uuid: "u2", msgId: "msg_abc", timestamp: "2026-04-26T10:00:00.500Z"),
            usageRecord(uuid: "u3", msgId: "msg_abc", timestamp: "2026-04-26T10:00:01.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "should count msg_abc once, not three times")
        XCTAssertEqual(summary.totalOutputTokens, 200)
        XCTAssertEqual(summary.totalCacheReadTokens, 1000)
        XCTAssertEqual(summary.totalCacheCreationTokens, 500)
    }

    func testParseMetadataKeepsDifferentMessageIds() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let url = try writeTempFile([
            usageRecord(uuid: "u1", msgId: "msg_abc", timestamp: "2026-04-26T10:00:00.000Z"),
            usageRecord(uuid: "u2", msgId: "msg_def", timestamp: "2026-04-26T10:00:01.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 200, "two distinct msg ids = both counted")
        XCTAssertEqual(summary.totalOutputTokens, 400)
    }

    func testFullParseDedupsByMessageId() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            usageRecord(uuid: "u1", msgId: "msg_abc", timestamp: "2026-04-26T10:00:00.000Z"),
            usageRecord(uuid: "u2", msgId: "msg_abc", timestamp: "2026-04-26T10:00:00.500Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try await parser.parse(url: url, sessionId: "sess-1")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 100)
        XCTAssertEqual(parsed.metadata.totalOutputTokens, 200)
    }

    // Records without a message.id should still be counted (no dedup key available).
    func testRecordsWithoutMessageIdAreNotDropped() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let noIdRecord = """
        {"type":"assistant","uuid":"u1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","model":"claude-opus-4-5","stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":75}}}
        """
        let url = try writeTempFile([noIdRecord, noIdRecord])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        // UUID-based dedup catches identical uuids; tokens count once.
        XCTAssertEqual(summary.totalInputTokens, 50)
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }
}
