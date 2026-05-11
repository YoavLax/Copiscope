import Foundation

// MARK: - Secret Detection

extension ConfigLinterService {

    struct SecretPattern {
        let checkId: LintCheckId
        let severity: LintSeverity
        let regex: NSRegularExpression
        let name: String
        let redactGroup: Int  // capture group to mask in message
    }

    static let secretPatterns: [SecretPattern] = buildPatterns()

    private static func buildPatterns() -> [SecretPattern] {
        func re(_ pattern: String) -> NSRegularExpression {
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) ?? NSRegularExpression()
        }
        return [
            SecretPattern(checkId: .SEC001, severity: .error,
                regex: re(#"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#),
                name: "Private key", redactGroup: 0),
            SecretPattern(checkId: .SEC002, severity: .error,
                regex: re(#"(?:^|[^A-Z0-9])(AKIA[0-9A-Z]{16})(?:[^A-Z0-9]|$)"#),
                name: "AWS access key", redactGroup: 1),
            SecretPattern(checkId: .SEC007, severity: .error,
                regex: re(#"(ghp_[A-Za-z0-9_]{36}|gho_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{82})"#),
                name: "GitHub token", redactGroup: 1),
            SecretPattern(checkId: .SEC007, severity: .error,
                regex: re(#"(npm_[A-Za-z0-9]{36})"#),
                name: "npm token", redactGroup: 1),
            SecretPattern(checkId: .SEC007, severity: .error,
                regex: re(#"(xox[baprs]-[0-9A-Za-z\-]{10,48})"#),
                name: "Slack token", redactGroup: 1),
            SecretPattern(checkId: .SEC003, severity: .warning,
                regex: re(#"(?:^|\s)Authorization:\s*Bearer\s+([A-Za-z0-9\-._~+/]+=*)"#),
                name: "Authorization header", redactGroup: 1),
            SecretPattern(checkId: .SEC006, severity: .warning,
                regex: re(#"(?:mongodb|postgres|mysql|redis|amqp|mssql)://[^:@\s]+:[^@\s]+@"#),
                name: "Connection string with credentials", redactGroup: 0),
            SecretPattern(checkId: .SEC005, severity: .warning,
                regex: re(#"(?:password|passwd|secret|token)\s*[:=]\s*['"]?([A-Za-z0-9!@#$%^&*\-_.]{8,})"#),
                name: "Password/secret literal", redactGroup: 1),
            SecretPattern(checkId: .SEC004, severity: .warning,
                regex: re(#"(?:api[_-]?key|apikey)\s*[:=]\s*['"]?([A-Za-z0-9\-_.]{20,})"#),
                name: "API key", redactGroup: 1),
        ]
    }

    func secretChecks(content: String, filePath: String, displayPath: String, detectedAt: Date) -> [LintResult] {
        var results: [LintResult] = []
        var seenPatterns = Set<LintCheckId>()

        let lines = content.components(separatedBy: "\n")

        for (lineIdx, line) in lines.enumerated() {
            // Skip JSONL metadata lines that are obviously not user content
            // (lines that are pure JSON structure without user text)
            for pattern in Self.secretPatterns {
                guard !seenPatterns.contains(pattern.checkId) else { continue }

                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                guard let match = pattern.regex.firstMatch(in: line, range: range) else { continue }

                // Build masked display value
                let masked: String
                if pattern.redactGroup > 0 && match.numberOfRanges > pattern.redactGroup {
                    let gr = match.range(at: pattern.redactGroup)
                    if gr.location != NSNotFound {
                        let raw = nsLine.substring(with: gr)
                        let keep = min(4, raw.count)
                        masked = String(raw.prefix(keep)) + String(repeating: "•", count: min(raw.count - keep, 12))
                    } else {
                        masked = "•••"
                    }
                } else {
                    masked = "•••"
                }

                seenPatterns.insert(pattern.checkId)
                results.append(LintResult(
                    severity: pattern.severity,
                    checkId: pattern.checkId,
                    filePath: filePath,
                    line: lineIdx + 1,
                    message: "\(pattern.name) detected (\(masked)). Rotate and move to a secrets manager.",
                    fix: "Revoke the credential immediately and store secrets in environment variables or a vault.",
                    displayPath: displayPath,
                    contextLines: contextLines(from: lines, around: lineIdx),
                    detectedAt: detectedAt
                ))
            }
        }
        return results
    }

    private func contextLines(from lines: [String], around idx: Int) -> [String] {
        let start = max(0, idx - 1)
        let end = min(lines.count - 1, idx + 1)
        return Array(lines[start...end])
    }
}

