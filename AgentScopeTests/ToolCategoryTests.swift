import XCTest
@testable import AgentScope

final class ToolCategoryTests: XCTestCase {

    func testReadTools() {
        XCTAssertEqual(toolCategory(for: "read_file"), .read)
        XCTAssertEqual(toolCategory(for: "list_dir"), .read)
        XCTAssertEqual(toolCategory(for: "view_image"), .read)
        XCTAssertEqual(toolCategory(for: "get_errors"), .read)
        XCTAssertEqual(toolCategory(for: "memory"), .read)
    }

    func testWriteTools() {
        XCTAssertEqual(toolCategory(for: "create_file"), .write)
        XCTAssertEqual(toolCategory(for: "replace_string_in_file"), .write)
        XCTAssertEqual(toolCategory(for: "multi_replace_string_in_file"), .write)
        XCTAssertEqual(toolCategory(for: "vscode_renameSymbol"), .write)
    }

    func testExecTools() {
        XCTAssertEqual(toolCategory(for: "run_in_terminal"), .exec)
        XCTAssertEqual(toolCategory(for: "send_to_terminal"), .exec)
        XCTAssertEqual(toolCategory(for: "kill_terminal"), .exec)
        XCTAssertEqual(toolCategory(for: "manage_todo_list"), .exec)
    }

    func testSearchTools() {
        XCTAssertEqual(toolCategory(for: "grep_search"), .search)
        XCTAssertEqual(toolCategory(for: "file_search"), .search)
        XCTAssertEqual(toolCategory(for: "semantic_search"), .search)
        XCTAssertEqual(toolCategory(for: "vscode_listCodeUsages"), .search)
        XCTAssertEqual(toolCategory(for: "search_subagent"), .search)
    }

    func testAgentTools() {
        XCTAssertEqual(toolCategory(for: "runSubagent"), .agent)
        XCTAssertEqual(toolCategory(for: "fetch_webpage"), .agent)
        XCTAssertEqual(toolCategory(for: "vscode_askQuestions"), .agent)
    }

    func testUnknownTool() {
        XCTAssertEqual(toolCategory(for: "some_future_tool"), .other)
    }

    func testPrimaryArguments() {
        let readInput: [String: AnyCodableValue] = ["filePath": .string("/src/main.swift")]
        XCTAssertEqual(primaryArgument(from: readInput, toolName: "read_file"), "/src/main.swift")

        let termInput: [String: AnyCodableValue] = ["command": .string("npm install")]
        XCTAssertEqual(primaryArgument(from: termInput, toolName: "run_in_terminal"), "npm install")

        let searchInput: [String: AnyCodableValue] = ["query": .string("function definition")]
        XCTAssertEqual(primaryArgument(from: searchInput, toolName: "grep_search"), "function definition")
    }
}
