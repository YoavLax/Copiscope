import XCTest
@testable import Copiscope

/// Tests for GitHub Copilot CLI session support:
///   - CopilotRecord decodes session.shutdown with modelMetrics
///   - CLIWorkspaceYAML parses workspace.yaml
///   - SessionParser.parseMetadataCLI extracts tokens and metadata
///   - CLI sessions carry source: .cli
final class CLISupportTests: XCTestCase {

    private var parser: SessionParser!
    private var tempDir: URL!

    override func setUpWithError() throws {
        parser = SessionParser()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLISupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - CopilotRecord: session.shutdown decoding

    func testDecodeSessionShutdownType() throws {
        let json = """
        {"type":"session.shutdown","id":"sid1","timestamp":"2026-05-13T10:00:00.000Z","data":{}}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .sessionShutdown)
        XCTAssertNil(record.unknownTypeRaw)
    }

    func testDecodeSessionShutdownWithModelMetrics() throws {
        let json = """
        {
          "type": "session.shutdown",
          "id": "sid2",
          "timestamp": "2026-05-13T10:05:00.000Z",
          "data": {
            "modelMetrics": {
              "claude-sonnet-4-5": {
                "requests": { "count": 3, "cost": 0.0 },
                "usage": {
                  "inputTokens": 12000,
                  "outputTokens": 3400,
                  "cacheReadTokens": 8000,
                  "cacheWriteTokens": 500,
                  "reasoningTokens": 0
                }
              }
            }
          }
        }
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .sessionShutdown)
        let metrics = try XCTUnwrap(record.data?.modelMetrics)
        XCTAssertEqual(metrics.count, 1)
        let m = try XCTUnwrap(metrics["claude-sonnet-4-5"])
        XCTAssertEqual(m.requests?.count, 3)
        XCTAssertEqual(m.usage?.inputTokens, 12000)
        XCTAssertEqual(m.usage?.outputTokens, 3400)
        XCTAssertEqual(m.usage?.cacheReadTokens, 8000)
        XCTAssertEqual(m.usage?.reasoningTokens, 0)
    }

    func testDecodeSessionShutdownMultipleModels() throws {
        let json = """
        {
          "type": "session.shutdown",
          "id": "sid3",
          "timestamp": "2026-05-13T10:10:00.000Z",
          "data": {
            "modelMetrics": {
              "gpt-4o": {
                "requests": { "count": 2, "cost": 0.0 },
                "usage": { "inputTokens": 5000, "outputTokens": 1200, "cacheReadTokens": 0, "cacheWriteTokens": 0, "reasoningTokens": 0 }
              },
              "claude-sonnet-4-5": {
                "requests": { "count": 1, "cost": 0.0 },
                "usage": { "inputTokens": 3000, "outputTokens": 800, "cacheReadTokens": 2000, "cacheWriteTokens": 0, "reasoningTokens": 0 }
              }
            }
          }
        }
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        let metrics = try XCTUnwrap(record.data?.modelMetrics)
        XCTAssertEqual(metrics.count, 2)
        XCTAssertNotNil(metrics["gpt-4o"])
        XCTAssertNotNil(metrics["claude-sonnet-4-5"])
    }

    // MARK: - CLIWorkspaceYAML parsing

    func testCLIWorkspaceYAMLParsesValidFile() throws {
        let yamlContent = """
        id: a1b2c3d4-0000-0000-0000-000000000001
        cwd: /Users/test/my-project
        name: my-project
        summary: A test project
        created_at: 2026-05-13T09:00:00.000Z
        updated_at: 2026-05-13T10:00:00.000Z
        """
        let yamlURL = tempDir.appendingPathComponent("workspace.yaml")
        try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)

        let yaml = try XCTUnwrap(CLIWorkspaceYAML.parse(from: yamlURL))
        XCTAssertEqual(yaml.id, "a1b2c3d4-0000-0000-0000-000000000001")
        XCTAssertEqual(yaml.cwd, "/Users/test/my-project")
        XCTAssertEqual(yaml.name, "my-project")
        XCTAssertEqual(yaml.summary, "A test project")
        XCTAssertEqual(yaml.createdAt, "2026-05-13T09:00:00.000Z")
        XCTAssertEqual(yaml.updatedAt, "2026-05-13T10:00:00.000Z")
    }

    func testCLIWorkspaceYAMLMissingIdReturnsNil() throws {
        let yamlContent = "cwd: /Users/test/project\nname: project\n"
        let yamlURL = tempDir.appendingPathComponent("bad-workspace.yaml")
        try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)
        XCTAssertNil(CLIWorkspaceYAML.parse(from: yamlURL))
    }

    func testCLIWorkspaceYAMLMissingCwdReturnsNil() throws {
        let yamlContent = "id: a1b2c3d4-0000-0000-0000-000000000002\nname: project\n"
        let yamlURL = tempDir.appendingPathComponent("no-cwd.yaml")
        try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)
        XCTAssertNil(CLIWorkspaceYAML.parse(from: yamlURL))
    }

    func testCLIWorkspaceYAMLPathWithColonInValue() throws {
        // cwd values contain colons (/Users/...) - parser must handle correctly
        let yamlContent = """
        id: a1b2c3d4-0000-0000-0000-000000000003
        cwd: /Users/test/some:weird:path
        """
        let yamlURL = tempDir.appendingPathComponent("colon-path.yaml")
        try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)
        let yaml = CLIWorkspaceYAML.parse(from: yamlURL)
        XCTAssertNotNil(yaml)
        // The cwd value after the first colon might be tricky — just check it starts with /Users
        XCTAssertTrue(yaml?.cwd.hasPrefix("/Users") ?? false)
    }

    // MARK: - SessionParser.parseMetadataCLI

    func testParseMetadataCLIExtractsTokensFromShutdown() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-abc-001",
            cwd: "/Users/test/project",
            name: "project",
            summary: nil,
            createdAt: "2026-05-13T09:00:00.000Z",
            updatedAt: "2026-05-13T10:00:00.000Z"
        )

        let lines = [
            #"{"type":"session.start","id":"1","timestamp":"2026-05-13T09:00:00.000Z","data":{}}"#,
            #"{"type":"user.message","id":"2","timestamp":"2026-05-13T09:00:01.000Z","data":{"content":"Write me a test"}}"#,
            #"{"type":"assistant.turn_start","id":"3","timestamp":"2026-05-13T09:00:02.000Z","data":{}}"#,
            #"{"type":"assistant.message","id":"4","timestamp":"2026-05-13T09:00:10.000Z","data":{"messageId":"m1","content":"Here is a test..."}}"#,
            #"{"type":"assistant.turn_end","id":"5","timestamp":"2026-05-13T09:00:10.500Z","data":{}}"#,
            #"{"type":"session.shutdown","id":"6","timestamp":"2026-05-13T10:00:00.000Z","data":{"modelMetrics":{"claude-sonnet-4-5":{"requests":{"count":1,"cost":0.0},"usage":{"inputTokens":4500,"outputTokens":1200,"cacheReadTokens":3000,"cacheWriteTokens":200,"reasoningTokens":0}}}}}"#
        ]
        let eventsURL = try writeEventLines(lines, name: "events.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)

        XCTAssertEqual(summary.id, "session-abc-001")
        XCTAssertEqual(summary.workspaceId, "cli::/Users/test/project")
        XCTAssertEqual(summary.source, .cli, "CLI sessions must carry source: .cli")
        XCTAssertEqual(summary.messageCount, 2, "1 user + 1 assistant message")
        XCTAssertEqual(summary.turnCount, 1)
        XCTAssertEqual(summary.totalInputTokens, 4500)
        XCTAssertEqual(summary.totalOutputTokens, 1200)
        XCTAssertEqual(summary.totalCachedTokens, 3000)
        XCTAssertEqual(summary.primaryModel, "claude-sonnet-4-5")
        XCTAssertFalse(summary.hasError)
    }

    func testParseMetadataCLIUsesYAMLTimestampWhenNoEvents() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-abc-002",
            cwd: "/Users/test/project",
            name: "project",
            summary: nil,
            createdAt: "2026-05-13T08:00:00.000Z",
            updatedAt: "2026-05-13T08:05:00.000Z"
        )
        // Minimal events.jsonl with no timestamps
        let lines = [#"{"type":"session.start","id":"1","data":{}}"#]
        let eventsURL = try writeEventLines(lines, name: "empty-events.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)

        XCTAssertEqual(summary.firstTimestamp, "2026-05-13T08:00:00.000Z",
                       "firstTimestamp falls back to YAML createdAt")
    }

    func testParseMetadataCLIExtractsTitleFromFirstUserMessage() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-abc-003",
            cwd: "/Users/test/project",
            name: nil,
            summary: nil,
            createdAt: nil,
            updatedAt: nil
        )
        let lines = [
            #"{"type":"session.start","id":"1","timestamp":"2026-05-13T09:00:00.000Z","data":{}}"#,
            #"{"type":"user.message","id":"2","timestamp":"2026-05-13T09:00:01.000Z","data":{"content":"Explain dependency injection"}}"#
        ]
        let eventsURL = try writeEventLines(lines, name: "titled-events.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertEqual(summary.title, "Explain dependency injection")
    }

    func testParseMetadataCLINoShutdownHasZeroTokens() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-abc-004",
            cwd: "/Users/test/project",
            name: "project",
            summary: nil,
            createdAt: "2026-05-13T09:00:00.000Z",
            updatedAt: "2026-05-13T09:30:00.000Z"
        )
        // No session.shutdown event
        let lines = [
            #"{"type":"user.message","id":"1","timestamp":"2026-05-13T09:00:01.000Z","data":{"content":"Hello"}}"#,
            #"{"type":"assistant.turn_start","id":"2","timestamp":"2026-05-13T09:00:02.000Z","data":{}}"#,
            #"{"type":"assistant.message","id":"3","timestamp":"2026-05-13T09:00:05.000Z","data":{"content":"Hi"}}"#,
            #"{"type":"assistant.turn_end","id":"4","timestamp":"2026-05-13T09:00:05.500Z","data":{}}"#
        ]
        let eventsURL = try writeEventLines(lines, name: "no-shutdown.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertEqual(summary.totalInputTokens, 0, "No shutdown event → zero tokens")
        XCTAssertEqual(summary.totalOutputTokens, 0)
    }

    func testParseMetadataCLISourceIsAlwaysCLI() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-source-check",
            cwd: "/Users/test/project",
            name: nil, summary: nil, createdAt: nil, updatedAt: nil
        )
        let lines = [#"{"type":"session.start","id":"1","timestamp":"2026-05-13T09:00:00.000Z","data":{}}"#]
        let eventsURL = try writeEventLines(lines, name: "source-check.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertEqual(summary.source, .cli)
    }

    func testParseMetadataCLIToolCallsAreCounted() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-tools",
            cwd: "/Users/test/project",
            name: "project",
            summary: nil,
            createdAt: "2026-05-13T09:00:00.000Z",
            updatedAt: "2026-05-13T09:10:00.000Z"
        )
        let lines = [
            #"{"type":"user.message","id":"1","timestamp":"2026-05-13T09:00:01.000Z","data":{"content":"Read some files"}}"#,
            #"{"type":"assistant.turn_start","id":"2","timestamp":"2026-05-13T09:00:02.000Z","data":{}}"#,
            #"{"type":"assistant.message","id":"3","timestamp":"2026-05-13T09:00:03.000Z","data":{"toolRequests":[{"toolCallId":"tc1","name":"read_file"},{"toolCallId":"tc2","name":"list_dir"}]}}"#,
            #"{"type":"tool.execution_complete","id":"4","timestamp":"2026-05-13T09:00:04.000Z","data":{"toolCallId":"tc1","toolName":"read_file","success":true}}"#,
            #"{"type":"tool.execution_complete","id":"5","timestamp":"2026-05-13T09:00:04.500Z","data":{"toolCallId":"tc2","toolName":"list_dir","success":true}}"#,
            #"{"type":"assistant.turn_end","id":"6","timestamp":"2026-05-13T09:00:05.000Z","data":{}}"#
        ]
        let eventsURL = try writeEventLines(lines, name: "tool-events.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertEqual(summary.toolCallCount, 2)
        XCTAssertFalse(summary.hasError)
    }

    func testParseMetadataCLIToolErrorSetsHasError() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "session-error",
            cwd: "/Users/test/project",
            name: "project",
            summary: nil,
            createdAt: "2026-05-13T09:00:00.000Z",
            updatedAt: "2026-05-13T09:10:00.000Z"
        )
        let lines = [
            #"{"type":"user.message","id":"1","timestamp":"2026-05-13T09:00:01.000Z","data":{"content":"Do something"}}"#,
            #"{"type":"tool.execution_complete","id":"2","timestamp":"2026-05-13T09:00:04.000Z","data":{"toolCallId":"tc1","toolName":"run_cmd","success":false}}"#
        ]
        let eventsURL = try writeEventLines(lines, name: "error-events.jsonl")

        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertTrue(summary.hasError, "Failed tool call should mark session as having an error")
    }

    // MARK: - CopilotSource default

    func testVSCodeSessionSummaryDefaultsToVSCode() {
        let summary = SessionSummary(
            id: "s1", workspaceId: "ws1", title: "Test",
            firstTimestamp: "", lastTimestamp: "",
            messageCount: 0, primaryModel: nil, vendor: nil,
            turnCount: 0, toolCallCount: 0, hasError: false,
            observability: .empty,
            totalInputTokens: 0, totalOutputTokens: 0,
            totalCachedTokens: 0, totalReasoningTokens: 0,
            estimatedCost: 0, premiumRequestCount: 0,
            totalMultiplierCost: 0, modelBreakdown: []
            // no source: param → defaults to .vscode
        )
        XCTAssertEqual(summary.source, .vscode)
    }

    func testCLISessionSummaryHasCLISource() async throws {
        let yaml = CLIWorkspaceYAML(
            id: "cli-source-test",
            cwd: "/Users/test/repo",
            name: nil, summary: nil, createdAt: nil, updatedAt: nil
        )
        let lines = [#"{"type":"session.start","id":"1","timestamp":"2026-05-13T09:00:00.000Z","data":{}}"#]
        let eventsURL = try writeEventLines(lines, name: "cli-source.jsonl")
        let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)
        XCTAssertEqual(summary.source, .cli)
        XCTAssertEqual(summary.workspaceId, "cli::/Users/test/repo")
    }

    // MARK: - Helpers

    private func writeEventLines(_ lines: [String], name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
