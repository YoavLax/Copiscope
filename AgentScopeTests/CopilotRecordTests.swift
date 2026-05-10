import XCTest
@testable import AgentScope

final class CopilotRecordTests: XCTestCase {

    func testDecodeSessionStart() throws {
        let json = """
        {"type":"session.start","data":{"sessionId":"abc-123","version":1,"producer":"copilot-chat","copilotVersion":"0.35.0","vscodeVersion":"1.100.0","startTime":"2025-01-01T00:00:00.000Z"},"id":"1","timestamp":"2025-01-01T00:00:00.000Z"}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .sessionStart)
        XCTAssertEqual(record.data?.sessionId, "abc-123")
        XCTAssertEqual(record.data?.version, 1)
        XCTAssertEqual(record.data?.producer, "copilot-chat")
    }

    func testDecodeUserMessage() throws {
        let json = """
        {"type":"user.message","data":{"content":"Hello world"},"id":"2","timestamp":"2025-01-01T00:00:01.000Z"}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .userMessage)
        XCTAssertEqual(record.data?.content, "Hello world")
    }

    func testDecodeAssistantMessage() throws {
        let json = """
        {"type":"assistant.message","data":{"messageId":"msg-1","content":"Hi there","toolRequests":[{"toolCallId":"tc-1","name":"read_file","type":"function"}],"reasoningText":"thinking..."},"id":"3","timestamp":"2025-01-01T00:00:02.000Z"}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .assistantMessage)
        XCTAssertEqual(record.data?.messageId, "msg-1")
        XCTAssertEqual(record.data?.content, "Hi there")
        XCTAssertEqual(record.data?.reasoningText, "thinking...")
        XCTAssertEqual(record.data?.toolRequests?.count, 1)
        XCTAssertEqual(record.data?.toolRequests?.first?.name, "read_file")
        XCTAssertEqual(record.data?.toolRequests?.first?.toolCallId, "tc-1")
    }

    func testDecodeToolExecutionComplete() throws {
        let json = """
        {"type":"tool.execution_complete","data":{"toolCallId":"tc-1","toolName":"read_file","content":"file contents here","success":true},"id":"4","timestamp":"2025-01-01T00:00:03.000Z"}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(record.type, .toolExecutionComplete)
        XCTAssertEqual(record.data?.toolCallId, "tc-1")
        XCTAssertEqual(record.data?.toolName, "read_file")
        XCTAssertEqual(record.data?.success, true)
    }

    func testDecodeUnknownType() throws {
        let json = """
        {"type":"future.unknown_event","data":{},"id":"5","timestamp":"2025-01-01T00:00:04.000Z"}
        """
        let record = try JSONDecoder().decode(CopilotRecord.self, from: json.data(using: .utf8)!)
        XCTAssertNil(record.type)
        XCTAssertEqual(record.unknownTypeRaw, "future.unknown_event")
    }

    func testDecodeTurnStartEnd() throws {
        let startJson = """
        {"type":"assistant.turn_start","data":{"turnId":"turn-1"},"id":"6","timestamp":"2025-01-01T00:00:05.000Z"}
        """
        let startRecord = try JSONDecoder().decode(CopilotRecord.self, from: startJson.data(using: .utf8)!)
        XCTAssertEqual(startRecord.type, .assistantTurnStart)
        XCTAssertEqual(startRecord.data?.turnId, "turn-1")

        let endJson = """
        {"type":"assistant.turn_end","data":{"turnId":"turn-1"},"id":"7","timestamp":"2025-01-01T00:00:10.000Z"}
        """
        let endRecord = try JSONDecoder().decode(CopilotRecord.self, from: endJson.data(using: .utf8)!)
        XCTAssertEqual(endRecord.type, .assistantTurnEnd)
    }
}
