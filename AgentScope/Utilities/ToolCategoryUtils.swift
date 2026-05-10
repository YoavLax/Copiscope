import SwiftUI

enum ToolCategory: String, CaseIterable, Sendable {
    case read
    case write
    case exec
    case search
    case agent
    case other

    var label: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .exec: return "Exec"
        case .search: return "Search"
        case .agent: return "Agent"
        case .other: return "Other"
        }
    }
}

func toolCategory(for toolName: String) -> ToolCategory {
    let readTools: Set = [
        "read_file", "list_dir", "view_image",
        "copilot_getNotebookSummary", "get_terminal_output",
        "get_errors", "get_changed_files", "terminal_last_command",
        "terminal_selection", "memory"
    ]
    let writeTools: Set = [
        "create_file", "replace_string_in_file", "multi_replace_string_in_file",
        "edit_notebook_file", "vscode_renameSymbol"
    ]
    let execTools: Set = [
        "run_in_terminal", "send_to_terminal", "kill_terminal",
        "run_notebook_cell", "restart_notebook_kernel",
        "manage_todo_list"
    ]
    let searchTools: Set = [
        "grep_search", "file_search", "semantic_search",
        "vscode_listCodeUsages", "search_subagent",
        "tool_search", "github_text_search"
    ]
    let agentTools: Set = [
        "runSubagent", "fetch_webpage", "vscode_askQuestions"
    ]

    if readTools.contains(toolName) { return .read }
    if writeTools.contains(toolName) { return .write }
    if execTools.contains(toolName) { return .exec }
    if searchTools.contains(toolName) { return .search }
    if agentTools.contains(toolName) { return .agent }
    return .other
}

func categoryColor(for toolName: String) -> Color {
    switch toolCategory(for: toolName) {
    case .read:   return Color(red: 0.52, green: 0.72, blue: 0.92) // #85B7EB
    case .write:  return Color(red: 0.36, green: 0.79, blue: 0.65) // #5DCAA5
    case .exec:   return Color(red: 0.83, green: 0.66, blue: 0.26) // #D4A843
    case .search: return Color(red: 0.68, green: 0.56, blue: 0.85) // #AE8FD9
    case .agent:  return Color(red: 0.90, green: 0.55, blue: 0.50) // #E68C80
    case .other:  return .secondary
    }
}

func toolIcon(for toolName: String) -> String {
    switch toolName {
    case "read_file": return "doc.text"
    case "create_file": return "doc.text.fill"
    case "replace_string_in_file", "multi_replace_string_in_file": return "pencil"
    case "run_in_terminal", "send_to_terminal": return "terminal"
    case "kill_terminal": return "xmark.circle"
    case "grep_search": return "magnifyingglass"
    case "file_search": return "doc.text.magnifyingglass"
    case "semantic_search": return "brain"
    case "list_dir": return "folder"
    case "view_image": return "photo"
    case "vscode_listCodeUsages": return "chevron.left.forwardslash.chevron.right"
    case "vscode_renameSymbol": return "textformat"
    case "runSubagent", "search_subagent": return "person.2"
    case "fetch_webpage": return "globe"
    case "get_errors": return "exclamationmark.triangle"
    case "manage_todo_list": return "checklist"
    case "memory": return "brain.head.profile"
    case "vscode_askQuestions": return "questionmark.bubble"
    case "get_changed_files": return "arrow.triangle.branch"
    case "get_terminal_output": return "text.alignleft"
    default: return "wrench"
    }
}

func primaryArgument(from input: [String: AnyCodableValue], toolName: String) -> String? {
    switch toolName {
    case "run_in_terminal", "send_to_terminal":
        return input["command"]?.stringValue
    case "read_file", "create_file", "replace_string_in_file":
        return input["filePath"]?.stringValue
    case "grep_search":
        return input["query"]?.stringValue
    case "file_search":
        return input["query"]?.stringValue
    case "semantic_search":
        return input["query"]?.stringValue
    case "list_dir":
        return input["path"]?.stringValue
    case "runSubagent":
        return input["description"]?.stringValue ?? input["agentName"]?.stringValue
    case "search_subagent":
        return input["query"]?.stringValue
    case "fetch_webpage":
        return input["urls"]?.stringValue
    case "vscode_listCodeUsages", "vscode_renameSymbol":
        return input["symbol"]?.stringValue
    default:
        return nil
    }
}
