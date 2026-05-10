import SwiftUI

// MARK: - Rule & Category Metadata

struct RuleMetadata {
    let displayName: String
    let hint: String
}

let ruleMetadata: [LintCheckId: RuleMetadata] = [
    // Instruction checks
    .INS001: RuleMetadata(
        displayName: "Instruction file exceeds 200 lines",
        hint: "Instruction file is very long. Consider splitting into smaller, focused files."
    ),
    .INS002: RuleMetadata(
        displayName: "applyTo glob matches no files",
        hint: "The applyTo glob pattern in this instruction doesn't match any files. Verify the pattern targets existing paths."
    ),
    .INS003: RuleMetadata(
        displayName: "Malformed YAML frontmatter",
        hint: "Instruction file has invalid YAML frontmatter. Check for syntax errors and fix the YAML."
    ),
    .INS004: RuleMetadata(
        displayName: "copilot-instructions.md missing",
        hint: "No copilot-instructions.md found. Create .github/copilot-instructions.md to configure Copilot for this workspace."
    ),

    // Agent checks
    .AGT001: RuleMetadata(
        displayName: "Agent missing description",
        hint: "Agent definition is missing a description. Add a description to help identify the agent's purpose."
    ),
    .AGT002: RuleMetadata(
        displayName: "Agent references unknown tools",
        hint: "Agent references tools that are not defined. Verify tool names match available tools."
    ),
    .AGT003: RuleMetadata(
        displayName: "Agent file exceeds 500 lines",
        hint: "Agent file is very long. Consider splitting into smaller, focused agent definitions."
    ),

    // Prompt checks
    .PRM001: RuleMetadata(
        displayName: "Prompt missing mode",
        hint: "Prompt file is missing the mode field. Add a mode to specify when this prompt applies."
    ),
    .PRM002: RuleMetadata(
        displayName: "Prompt exceeds 200 lines",
        hint: "Prompt file is very long. Consider breaking into smaller, focused prompts."
    ),

    // MCP checks
    .MCP001: RuleMetadata(
        displayName: "MCP server unreachable",
        hint: "MCP server could not be reached. Verify the server is running and the configuration is correct."
    ),
    .MCP002: RuleMetadata(
        displayName: "MCP server missing command and url",
        hint: "MCP server configuration is missing both command and url. At least one must be specified."
    ),

    // Session checks
    .SES001: RuleMetadata(
        displayName: "High cost session",
        hint: "Session estimated cost exceeds threshold. Consider breaking expensive tasks into smaller sessions."
    ),
    .SES002: RuleMetadata(
        displayName: "Very long conversation",
        hint: "Session has over 200 messages. Long conversations may degrade context quality."
    ),
    .SES003: RuleMetadata(
        displayName: "High token consumption",
        hint: "Session exceeded 2M tokens. Consider breaking expensive tasks into smaller sessions."
    ),
    .SES004: RuleMetadata(
        displayName: "Session with error patterns",
        hint: "Session contains repeated error patterns. Review errors and fix underlying issues."
    ),

    // Secret detection
    .SEC001: RuleMetadata(
        displayName: "Private key detected",
        hint: "Private key material found in session output. Never paste private keys into prompts."
    ),
    .SEC002: RuleMetadata(
        displayName: "AWS access key detected",
        hint: "Found AWS access key pattern (AKIA...) in session output. Use environment variables instead."
    ),
    .SEC003: RuleMetadata(
        displayName: "Authorization header detected",
        hint: "Bearer token found in session content. Ensure auth headers are sourced from env vars."
    ),
    .SEC004: RuleMetadata(
        displayName: "API key or token detected",
        hint: "Generic API key pattern matched. Rotate the key and move it to a secrets vault."
    ),
    .SEC005: RuleMetadata(
        displayName: "Password or secret literal detected",
        hint: "Plaintext password or secret found in session content. Use a secrets manager."
    ),
    .SEC006: RuleMetadata(
        displayName: "Connection string with credentials",
        hint: "Database connection string with embedded credentials detected. Move credentials to environment variables."
    ),
    .SEC007: RuleMetadata(
        displayName: "Platform token detected",
        hint: "Platform-specific token (GitHub, Slack, npm, etc.) found. Rotate and store securely."
    ),

    // Cross-cutting
    .XCT001: RuleMetadata(
        displayName: "Instruction token estimate",
        hint: "Your instructions and settings consume an estimated portion of the context window."
    ),
    .XCT002: RuleMetadata(
        displayName: "Instructions exceed 5000 tokens",
        hint: "Configuration exceeds 5,000 tokens. This significantly reduces available context. Trim or split."
    ),
]

struct CategoryDef: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let prefixes: [String]
    let sortOrder: Int
}

let healthCategories: [CategoryDef] = [
    CategoryDef(id: "security", label: "Security", icon: "!", color: Color(red: 0.886, green: 0.294, blue: 0.290), prefixes: ["SEC"], sortOrder: 1),
    CategoryDef(id: "performance", label: "Session performance", icon: "~", color: Color(red: 0.937, green: 0.624, blue: 0.153), prefixes: ["SES"], sortOrder: 2),
    CategoryDef(id: "agents", label: "Agents & prompts", icon: "A", color: Color(red: 0.498, green: 0.467, blue: 0.867), prefixes: ["AGT", "PRM"], sortOrder: 3),
    CategoryDef(id: "config", label: "Configuration", icon: "i", color: Color(red: 0.216, green: 0.541, blue: 0.867), prefixes: ["XCT", "INS", "MCP"], sortOrder: 4),
]

let otherCategory = CategoryDef(id: "other", label: "Other", icon: "?", color: .gray, prefixes: [], sortOrder: 99)

func categoryFor(_ checkId: LintCheckId) -> CategoryDef {
    let raw = checkId.rawValue
    for cat in healthCategories {
        for prefix in cat.prefixes {
            if raw.hasPrefix(prefix) { return cat }
        }
    }
    return otherCategory
}

func displayNameFor(_ checkId: LintCheckId) -> String {
    ruleMetadata[checkId]?.displayName ?? checkId.rawValue
}

func hintFor(_ checkId: LintCheckId) -> String? {
    ruleMetadata[checkId]?.hint
}

// MARK: - Auto-Fix Support

let autoFixableRules: Set<LintCheckId> = []

struct ConfigAutoFixer {
    static func canFix(_ checkId: LintCheckId) -> Bool {
        autoFixableRules.contains(checkId)
    }

    static func apply(checkId: LintCheckId, settingsPath: String) -> Bool {
        // No auto-fixable rules for Copilot config yet
        return false
    }
}
