import XCTest
@testable import Claudoscope

/// Regression: streaming intermediate records normally lack `stop_reason` — the
/// final record carries cumulative usage, and the parser used to drop every
/// non-stop_reason record on that assumption. But aborted streams (Ctrl+C,
/// network drops, truncated transcripts) leave behind orphan msg.ids whose
/// stream never produced a stop_reason record. Anthropic still bills those
/// calls, so the parser now counts one record per orphan msg.id (first
/// occurrence; msg.id dedup keeps it to one). Improvement contributed by Igor
/// during v0.6.2 verification.
final class OrphanRecordTests: XCTestCase {

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-orphan-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Helper: assistant record with optional stop_reason and configurable token amounts.
    private func record(uuid: String, msgId: String, stopReason: String?, input: Int = 100, output: Int = 200, timestamp: String = "2026-04-26T10:00:00.000Z") -> String {
        let stopReasonField = stopReason.map { "\"stop_reason\":\"\($0)\"," } ?? "\"stop_reason\":null,"
        return """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"sess-1","timestamp":"\(timestamp)","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120",\(stopReasonField)"usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    // MARK: - Orphan billed once

    func testOrphanMessageIdIsBilledOnce() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Two records sharing the same msg.id, neither has stop_reason.
        // Without the orphan fix: dropped (zero tokens).
        // With the orphan fix: one record billed (msg.id dedup keeps it to one).
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_orphan", stopReason: nil),
            record(uuid: "u2", msgId: "msg_orphan", stopReason: nil),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "orphan msg.id should be billed once")
        XCTAssertEqual(summary.totalOutputTokens, 200)
    }

    // MARK: - Normal stream: only stop_reason record counted

    func testNormalStreamWithStopReasonOnlyCountsFinalRecord() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Three records sharing msg.id: two intermediates with stop_reason=null,
        // one final with stop_reason set. Only the final should be billed.
        // The orphan fix MUST NOT change this behavior — intermediates whose
        // msg.id has a stop_reason record elsewhere in the file are still dropped.
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_normal", stopReason: nil, input: 10, output: 20),
            record(uuid: "u2", msgId: "msg_normal", stopReason: nil, input: 50, output: 100),
            record(uuid: "u3", msgId: "msg_normal", stopReason: "end_turn", input: 100, output: 200),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100, "only the final stop_reason record should bill")
        XCTAssertEqual(summary.totalOutputTokens, 200)
    }

    // MARK: - Mixed: orphan + normal in same file

    func testMixedOrphanAndNormalRecordsInSameFile() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // msg_normal: stream completed (intermediate + final). Bill final only.
        // msg_orphan: stream aborted (intermediate only, no final). Bill the orphan.
        // Expected: 100 (normal final) + 50 (orphan) = 150 input.
        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_normal", stopReason: nil, input: 10, output: 20),
            record(uuid: "u2", msgId: "msg_normal", stopReason: "end_turn", input: 100, output: 200),
            record(uuid: "u3", msgId: "msg_orphan", stopReason: nil, input: 50, output: 75),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 150, "100 from normal final + 50 from orphan")
        XCTAssertEqual(summary.totalOutputTokens, 275, "200 from normal final + 75 from orphan")
    }

    // MARK: - parse() also includes orphans

    func testFullParseIncludesOrphans() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            record(uuid: "u1", msgId: "msg_orphan_a", stopReason: nil, input: 100, output: 200),
            record(uuid: "u2", msgId: "msg_orphan_b", stopReason: nil, input: 50, output: 75),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try await parser.parse(url: url, sessionId: "sess-1")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 150, "two distinct orphans, each billed once")
        XCTAssertEqual(parsed.metadata.totalOutputTokens, 275)
    }

    // MARK: - Record without msg.id — counted as orphan

    func testRecordWithoutMessageIdCountsAsOrphan() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Record has no message.id at all. There's no way to tell if it's
        // related to another record, so the orphan rule treats it as billable.
        // (Matches the bash diagnostic's `$has_stop[.message.id // ""] // false`
        // behavior — empty msg.id is never in the has_stop set.)
        let noIdRecord = """
        {"type":"assistant","uuid":"u1","sessionId":"sess-1","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","model":"claude-opus-4-5","usage":{"input_tokens":50,"output_tokens":75}}}
        """
        let url = try writeTempFile([noIdRecord])
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50)
        XCTAssertEqual(summary.totalOutputTokens, 75)
    }
}
