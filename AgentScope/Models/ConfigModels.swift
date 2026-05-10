import Foundation

// MARK: - Instruction Models

enum InstructionSource: Sendable, Hashable {
    case user          // copilot-instructions.md in user settings
    case workspace     // .github/copilot-instructions.md
    case vscode        // .vscode/settings.json → github.copilot.chat.codeGeneration.instructions
    case file(name: String) // .instructions.md files

    var label: String {
        switch self {
        case .user: return "user"
        case .workspace: return "workspace"
        case .vscode: return "vscode"
        case .file(let name): return "file: \(name)"
        }
    }
}

struct InstructionEntry: Identifiable, Sendable {
    var id: String { path ?? label }
    let label: String
    let source: InstructionSource
    let path: String?
    let content: String?
    let sizeBytes: Int?
    let applyTo: String?   // glob pattern from frontmatter
}

// MARK: - Agent Models

struct AgentEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let path: String
    let content: String?
    let sizeBytes: Int
    let tools: [String]?
}

// MARK: - Prompt Models

struct PromptEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let path: String
    let content: String?
    let sizeBytes: Int
    let mode: String?  // "ask", "edit", "agent"
}

// MARK: - MCP Models

struct McpServerEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let command: String?
    let args: [String]
    let url: String?
    let env: [String: String]
    let source: String?    // "user", "workspace"
}

// MARK: - Memory Models

struct MemoryFile: Identifiable, Sendable {
    let id: String
    let label: String
    let sublabel: String
    let path: String
    let content: String?
    let sizeBytes: Int?
}

// MARK: - VS Code Settings Model

struct VSCodeSettings: Sendable {
    // Environment
    var vscodeVersion: String?
    var copilotVersion: String?

    // Model
    var selectedCompletionModel: String?
    var enabledLanguages: [String: Bool] = [:]  // github.copilot.enable

    // Chat
    var maxRequests: Int?
    var memoryEnabled: Bool?
    var nestedAgentsMd: Bool?
    var showOrgAgents: Bool?
    var viewSessionsOrientation: String?
    var codeGenerationInstructions: [String] = []

    // Completions
    var nextEditSuggestionsEnabled: Bool?

    // Observability
    var otelEnabled: Bool?
    var otelExporterType: String?
    var otelEndpoint: String?
    var otelCaptureContent: Bool?
    var otelDbExporterEnabled: Bool?
    var agentDebugLogEnabled: Bool?

    // Marketplaces / plugins
    var pluginMarketplaces: [String] = []
    var mcpGalleryEnabled: Bool?

    // Hooks
    var hookFileLocations: [String: Bool] = [:]

    // MCP sampling
    var mcpServerSampling: [String: Bool] = [:]  // server name → allowedDuringChat

    static let empty = VSCodeSettings()
}
