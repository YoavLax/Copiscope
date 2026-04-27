import XCTest
@testable import Claudoscope

/// Regression: subagent JSONL files (under `.../subagents/<id>.jsonl`) carry the
/// parent's sessionId on every record. The parser previously fired its
/// continuation-detection branch and skipped every billable turn — hiding ~14%
/// of cost on heavy-subagent setups. Detection is now per-record via
/// `isSidechain` (with a path-based fallback). Subagent summaries are stamped
/// with `isSubagent` so downstream UI/analytics can hide them from session
/// listings while still rolling their tokens/cost into project totals.
final class SubagentRecordTests: XCTestCase {

    private func writeTempFile(_ lines: [String], inSubagentsDir: Bool = false) throws -> URL {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-subagent-\(UUID().uuidString)")
        let dir = inSubagentsDir
            ? baseDir.appendingPathComponent("parent-uuid").appendingPathComponent("subagents")
            : baseDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sub-uuid.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sidechainAssistantRecord(uuid: String, msgId: String, sessionId: String = "parent-uuid", isSidechain: Bool? = true) -> String {
        let sidechainField = isSidechain.map { ",\"isSidechain\":\($0)" } ?? ""
        return """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"\(sessionId)"\(sidechainField),"timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200}}}
        """
    }

    // MARK: - parseMetadata: isSidechain field detection

    func testParseMetadataIncludesSubagentRecordsViaIsSidechainField() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // File is in plain temp dir (no /subagents/ in path); records carry
        // isSidechain:true and parent's sessionId. Without the fix, the parser
        // captures sessionId as parent and skips every record => totals = 0.
        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a"),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b"),
            sidechainAssistantRecord(uuid: "u3", msgId: "msg_c"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 300, "regression: subagent records were silently dropped (totals were 0)")
        XCTAssertEqual(summary.totalOutputTokens, 600)
        XCTAssertEqual(summary.messageCount, 3)
        // isSubagent reflects the file's path, not the per-record signal.
        XCTAssertFalse(summary.isSubagent, "file is not in /subagents/, isSubagent should be false")
    }

    // MARK: - parseMetadata: path-based fallback

    func testParseMetadataIncludesSubagentRecordsViaPathFallback() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // No isSidechain field on records; file lives inside .../subagents/
        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a", isSidechain: nil),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b", isSidechain: nil),
            sidechainAssistantRecord(uuid: "u3", msgId: "msg_c", isSidechain: nil),
        ], inSubagentsDir: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 300)
        XCTAssertEqual(summary.totalOutputTokens, 600)
        XCTAssertTrue(summary.isSubagent, "file is in /subagents/, isSubagent should be true")
    }

    // MARK: - parseMetadata: continuation behavior preserved

    func testParseMetadataPreservesContinuationFileBehavior() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // No /subagents/ in path, no isSidechain field. First record's sessionId
        // differs from the file's name => continuation mode. Parent records
        // (sessionId == "parent-uuid") must be skipped. Only the "self" record
        // (sessionId == "sess-self") should count.
        let parentRecord = """
        {"type":"assistant","uuid":"u1","sessionId":"parent-uuid","timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","id":"msg_a","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200}}}
        """
        let selfRecord = """
        {"type":"assistant","uuid":"u2","sessionId":"sess-self","timestamp":"2026-04-26T10:01:00.000Z","message":{"role":"assistant","id":"msg_b","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":50,"output_tokens":75}}}
        """
        let url = try writeTempFile([parentRecord, selfRecord])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sess-self", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 50, "parent record must still be skipped in true continuation files")
        XCTAssertEqual(summary.totalOutputTokens, 75)
        XCTAssertFalse(summary.isSubagent)
    }

    // MARK: - parse(): isSidechain field detection

    func testFullParseIncludesSubagentRecordsViaIsSidechain() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a"),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b"),
            sidechainAssistantRecord(uuid: "u3", msgId: "msg_c"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parsed = try await parser.parse(url: url, sessionId: "sub-uuid")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 300)
        XCTAssertEqual(parsed.records.count, 3)
        XCTAssertFalse(parsed.isSubagent)
    }

    // MARK: - parse(): path fallback + parentSessionId derived from path

    func testFullParseIncludesSubagentRecordsViaPathFallback() async throws {
        let parser = SessionParser()

        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a", isSidechain: nil),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b", isSidechain: nil),
            sidechainAssistantRecord(uuid: "u3", msgId: "msg_c", isSidechain: nil),
        ], inSubagentsDir: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let parsed = try await parser.parse(url: url, sessionId: "sub-uuid")

        XCTAssertEqual(parsed.metadata.totalInputTokens, 300)
        XCTAssertEqual(parsed.records.count, 3)
        XCTAssertTrue(parsed.isSubagent)
        XCTAssertEqual(parsed.parentSessionId, "parent-uuid", "parentSessionId for subagent files comes from the parent dir name")
    }

    // MARK: - Hoisted-flag invariant

    func testHoistedFirstRecordFlagSurvivesSidechainPrefix() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Invariant: `isFirstRecord` flips to false on the first non-skipped record
        // regardless of sidechain status. So a stray non-sidechain record after a
        // sidechain prefix can't re-trigger first-record detection (which would
        // capture parent-uuid and start skipping records).
        // If someone refactors to gate `isFirstRecord = false` inside the
        // sidechain branch, this test breaks: record 3 would be treated as the
        // "first" record, capture parent-uuid, and get skipped on the next pass.
        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a", isSidechain: true),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b", isSidechain: true),
            sidechainAssistantRecord(uuid: "u3", msgId: "msg_c", isSidechain: false),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 300, "all three records counted; no parent capture should have happened")
        XCTAssertEqual(summary.totalOutputTokens, 600)
    }

    // MARK: - Belt-and-suspenders

    func testBeltAndSuspendersBothSignalsPresent() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // File in /subagents/ AND records have isSidechain:true.
        // Both signals fire; behavior is identical to either alone.
        let url = try writeTempFile([
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a", isSidechain: true),
            sidechainAssistantRecord(uuid: "u2", msgId: "msg_b", isSidechain: true),
        ], inSubagentsDir: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 200)
        XCTAssertTrue(summary.isSubagent)
    }

    // MARK: - Nil sessionId

    func testSubagentRecordWithNilSessionIdPassesThrough() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // Record has isSidechain:true but no sessionId field at all.
        // nil sessionId can never match the parent-skip check.
        let recordNoSession = """
        {"type":"assistant","uuid":"u1","isSidechain":true,"timestamp":"2026-04-26T10:00:00.000Z","message":{"role":"assistant","id":"msg_a","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200}}}
        """
        let url = try writeTempFile([recordNoSession])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let summary = try await parser.parseMetadata(url: url, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertEqual(summary.totalInputTokens, 100)
    }

    // MARK: - isSubagent stamping by path

    func testSummaryIsSubagentReflectsPath() async throws {
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        let recordsLines = [
            sidechainAssistantRecord(uuid: "u1", msgId: "msg_a", isSidechain: true),
        ]

        let plainUrl = try writeTempFile(recordsLines)
        defer { try? FileManager.default.removeItem(at: plainUrl.deletingLastPathComponent()) }
        let subagentUrl = try writeTempFile(recordsLines, inSubagentsDir: true)
        defer { try? FileManager.default.removeItem(at: subagentUrl.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let plainSummary = try await parser.parseMetadata(url: plainUrl, sessionId: "sub-uuid", pricingTable: pricing)
        let subagentSummary = try await parser.parseMetadata(url: subagentUrl, sessionId: "sub-uuid", pricingTable: pricing)

        XCTAssertFalse(plainSummary.isSubagent)
        XCTAssertTrue(subagentSummary.isSubagent)
    }
}
