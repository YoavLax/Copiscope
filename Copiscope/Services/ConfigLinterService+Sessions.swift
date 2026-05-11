import Foundation

// MARK: - Session Performance Checks

extension ConfigLinterService {

    func sessionChecks(_ sessions: [(workspaceId: String, summary: SessionSummary)]) -> [LintResult] {
        var results: [LintResult] = []

        for (workspaceId, summary) in sessions {
            let filePath = "sessions/\(workspaceId)/\(summary.id)"
            let display = summary.title.isEmpty ? summary.id : summary.title

            // SES002: Very long conversation (>50 messages)
            if summary.messageCount > 50 {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES002,
                    filePath: filePath,
                    message: "Session has \(summary.messageCount) messages — unusually high. Long sessions increase context compaction frequency and degrade context quality.",
                    fix: "Break the conversation into smaller, focused sessions.",
                    displayPath: display
                ))
            }

            // SES003: High token consumption (>300k total)
            let totalTokens = summary.totalInputTokens + summary.totalOutputTokens
            if totalTokens > 300_000 {
                let formatted = formatTokenCount(totalTokens)
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES003,
                    filePath: filePath,
                    message: "Session used \(formatted) tokens — exceeds expected budget. Consider breaking the task into smaller sessions.",
                    fix: "Add a summary/compact checkpoint mid-flow and split into smaller sessions.",
                    displayPath: display
                ))
            }

            // SES001: High cost session (>$2)
            if summary.estimatedCost > 2.0 {
                let cost = String(format: "$%.2f", summary.estimatedCost)
                results.append(LintResult(
                    severity: .warning,
                    checkId: .SES001,
                    filePath: filePath,
                    message: "Session estimated cost is \(cost). Consider breaking expensive tasks into smaller sessions.",
                    fix: "Use /compact or summarize earlier to reduce context size.",
                    displayPath: display
                ))
            }

            // SES004: Session with error (modelState=error)
            if summary.hasError {
                results.append(LintResult(
                    severity: .info,
                    checkId: .SES004,
                    filePath: filePath,
                    message: "Session contains a request that ended in an error or was cancelled.",
                    fix: "Review the session for unresolved errors.",
                    displayPath: display
                ))
            }
        }

        return results
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

