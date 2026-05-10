import Foundation

enum LintSeverity: String, Sendable, CaseIterable, Comparable {
    case error
    case warning
    case info

    static func < (lhs: LintSeverity, rhs: LintSeverity) -> Bool {
        let order: [LintSeverity] = [.error, .warning, .info]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

enum LintCheckId: String, Sendable, CaseIterable {
    // Instruction checks
    case INS001  // instruction file >200 lines
    case INS002  // applyTo glob matches no files
    case INS003  // malformed YAML frontmatter
    case INS004  // copilot-instructions.md missing

    // Agent checks
    case AGT001  // agent missing description
    case AGT002  // agent references unknown tools
    case AGT003  // agent file >500 lines

    // Prompt checks
    case PRM001  // prompt missing mode
    case PRM002  // prompt >200 lines

    // MCP checks
    case MCP001  // MCP server unreachable
    case MCP002  // MCP server missing command and url

    // Session checks
    case SES001  // high cost session (>$25)
    case SES002  // very long conversation (>200 messages)
    case SES003  // high token consumption (>2M tokens)
    case SES004  // session with error patterns

    // Secret detection checks
    case SEC001  // private key
    case SEC002  // AWS access key
    case SEC003  // authorization header
    case SEC004  // API key/token
    case SEC005  // password/secret literal
    case SEC006  // connection string with credentials
    case SEC007  // platform token (GitHub, Slack, npm, etc.)

    // Cross-cutting
    case XCT001  // total instruction token estimate
    case XCT002  // instructions >5000 tokens
}

struct LintResult: Identifiable, Sendable {
    let id: String
    let severity: LintSeverity
    let checkId: LintCheckId
    let filePath: String
    let line: Int?
    let message: String
    let fix: String?
    let displayPath: String?
    let contextLines: [String]?
    let unmaskedSecret: String?
    let detectedAt: Date?

    init(severity: LintSeverity, checkId: LintCheckId, filePath: String, line: Int? = nil, message: String, fix: String? = nil, displayPath: String? = nil, contextLines: [String]? = nil, unmaskedSecret: String? = nil, detectedAt: Date? = nil) {
        self.id = "\(checkId.rawValue)-\(filePath)-\(line ?? 0)-\(message.hash)"
        self.severity = severity
        self.checkId = checkId
        self.filePath = filePath
        self.line = line
        self.message = message
        self.fix = fix
        self.displayPath = displayPath
        self.contextLines = contextLines
        self.unmaskedSecret = unmaskedSecret
        self.detectedAt = detectedAt
    }
}

struct LintSummary: Sendable {
    let errorCount: Int
    let warningCount: Int
    let infoCount: Int
    let healthScore: Double

    static let empty = LintSummary(errorCount: 0, warningCount: 0, infoCount: 0, healthScore: 1.0)

    static func from(results: [LintResult]) -> LintSummary {
        let errors = results.filter { $0.severity == .error }.count
        let warnings = results.filter { $0.severity == .warning }.count
        let infos = results.filter { $0.severity == .info }.count
        let total = results.count
        let demerits = Double(errors * 3 + warnings)
        let maxDemerits = Double(total * 3)
        let score = maxDemerits > 0 ? max(0, 1.0 - demerits / maxDemerits) : 1.0
        return LintSummary(errorCount: errors, warningCount: warnings, infoCount: infos, healthScore: score)
    }
}

struct SecretAlert: Sendable {
    let checkId: LintCheckId
    let patternName: String
    let maskedValue: String
    let sessionTitle: String
    let workspaceId: String
    let sessionId: String
}
