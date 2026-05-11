import Foundation

// MARK: - Configuration Token Estimate Checks

extension ConfigLinterService {

    // MARK: - Environment Checks

    func environmentChecks(_ settings: VSCodeSettings) -> [LintResult] {
        var results: [LintResult] = []

        // ENV001: OTEL not fully enabled — per-model token data is unavailable
        let otelOn = settings.otelEnabled == true
        let dbExporterOn = settings.otelDbExporterEnabled == true
        if !otelOn || !dbExporterOn {
            let missing: String
            if !otelOn && !dbExporterOn {
                missing = "`github.copilot.chat.otel.enabled` and `github.copilot.chat.otel.dbSpanExporter.enabled` are both disabled"
            } else if !otelOn {
                missing = "`github.copilot.chat.otel.enabled` is disabled"
            } else {
                missing = "`github.copilot.chat.otel.dbSpanExporter.enabled` is disabled"
            }
            results.append(LintResult(
                severity: .warning,
                checkId: .ENV001,
                filePath: "settings.json",
                message: "OTEL not fully enabled — \(missing). Per-model token counts and cost breakdowns will be missing or estimated.",
                fix: "Open Settings > Observability and click \"Enable\", or add the keys manually to your VS Code settings.json.",
                displayPath: "Configuration"
            ))
        }

        return results
    }

    // Very rough approximation: 1 token ≈ 4 chars
    private func estimateTokens(_ text: String?) -> Int {
        guard let text else { return 0 }
        return max(1, text.count / 4)
    }

    func tokenEstimateChecks(
        instructions: [InstructionEntry],
        agents: [AgentEntry]
    ) -> [LintResult] {
        var results: [LintResult] = []

        // XCT001/XCT002: Total instruction token estimate
        let instrTotal = instructions.reduce(0) { $0 + estimateTokens($1.content) }
        let agentTotal = agents.reduce(0) { $0 + estimateTokens($1.content) }
        let grandTotal = instrTotal + agentTotal

        if grandTotal > 0 {
            let formatted = grandTotal >= 1000 ? "\(grandTotal / 1000)K" : "\(grandTotal)"
            let checkId: LintCheckId = grandTotal > 5000 ? .XCT002 : .XCT001
            let severity: LintSeverity = grandTotal > 5000 ? .warning : .info
            let pct = min(100, grandTotal * 100 / 16000)  // rough 16K system prompt budget

            results.append(LintResult(
                severity: severity,
                checkId: checkId,
                filePath: ".github/copilot-instructions.md",
                message: "Configuration uses ~\(formatted) tokens (~\(pct)% of typical system prompt budget). \(grandTotal > 5000 ? "Consider trimming." : "Within healthy range.")",
                fix: grandTotal > 5000 ? "Trim instructions or split into scoped .instructions.md files with applyTo glob patterns." : nil,
                displayPath: "Configuration"
            ))
        }

        return results
    }
}

