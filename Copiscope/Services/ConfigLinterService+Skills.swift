import Foundation

// MARK: - Config File Quality Checks (Instructions, Agents, Prompts, MCPs)

extension ConfigLinterService {

    func configFileChecks(
        instructions: [InstructionEntry],
        agents: [AgentEntry],
        prompts: [PromptEntry],
        mcpServers: [McpServerEntry]
    ) -> [LintResult] {
        var results: [LintResult] = []

        // --- Instructions ---
        for instr in instructions {
            let path = instr.path ?? instr.label
            let display = (instr.path.flatMap { URL(fileURLWithPath: $0).lastPathComponent }) ?? instr.label

            if let content = instr.content {
                let lineCount = content.components(separatedBy: "\n").count

                // INS001: file > 200 lines
                if lineCount > 200 {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .INS001,
                        filePath: path,
                        message: "\(display) is \(lineCount) lines — very long instruction file.",
                        fix: "Split into smaller, focused instruction files.",
                        displayPath: display
                    ))
                }

                // INS003: malformed frontmatter
                if content.hasPrefix("---") {
                    let lines = content.components(separatedBy: "\n")
                    var closingFound = false
                    for line in lines.dropFirst() {
                        if line.trimmingCharacters(in: .whitespaces) == "---" { closingFound = true; break }
                    }
                    if !closingFound {
                        results.append(LintResult(
                            severity: .error,
                            checkId: .INS003,
                            filePath: path,
                            message: "\(display) has unclosed YAML frontmatter block.",
                            fix: "Add a closing '---' delimiter after the frontmatter section.",
                            displayPath: display
                        ))
                    }

                    // XML brackets in frontmatter (breaks system prompt parser)
                    if let fmEnd = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                        let frontmatter = lines[1...fmEnd].joined(separator: "\n")
                        if frontmatter.contains("<") && frontmatter.contains(">") {
                            results.append(LintResult(
                                severity: .error,
                                checkId: .INS003,
                                filePath: path,
                                message: "\(display) has XML/HTML angle brackets in YAML frontmatter. This can break the system prompt parser.",
                                fix: "Escape the brackets or move XML content to the body section.",
                                displayPath: display
                            ))
                        }
                    }
                }
            }
        }

        // INS004: Check that at least one workspace has a copilot-instructions.md
        let hasWorkspaceInstruction = instructions.contains { $0.source == .workspace }
        if !hasWorkspaceInstruction && !instructions.isEmpty {
            results.append(LintResult(
                severity: .info,
                checkId: .INS004,
                filePath: ".github/copilot-instructions.md",
                message: "No .github/copilot-instructions.md found. This file provides workspace-level context to Copilot.",
                fix: "Create .github/copilot-instructions.md to configure Copilot for your workspace.",
                displayPath: ".github/copilot-instructions.md"
            ))
        }

        // --- Agents ---
        for agent in agents {
            let display = URL(fileURLWithPath: agent.path).lastPathComponent

            // AGT001: missing description
            if agent.description == nil || agent.description?.isEmpty == true {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .AGT001,
                    filePath: agent.path,
                    message: "\(display) is missing a description in its frontmatter.",
                    fix: "Add a 'description:' field to the YAML frontmatter.",
                    displayPath: display
                ))
            }

            if let content = agent.content {
                let lineCount = content.components(separatedBy: "\n").count
                // AGT003: file > 500 lines
                if lineCount > 500 {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .AGT003,
                        filePath: agent.path,
                        message: "\(display) is \(lineCount) lines — very long agent definition.",
                        fix: "Split into smaller, focused agent files or extract repeated content into instructions.",
                        displayPath: display
                    ))
                }
            }
        }

        // --- Prompts ---
        for prompt in prompts {
            let display = URL(fileURLWithPath: prompt.path).lastPathComponent

            // PRM001: missing mode
            if prompt.mode == nil || prompt.mode?.isEmpty == true {
                results.append(LintResult(
                    severity: .info,
                    checkId: .PRM001,
                    filePath: prompt.path,
                    message: "\(display) is missing a 'mode:' in its frontmatter.",
                    fix: "Add mode: ask, edit, or agent to the frontmatter.",
                    displayPath: display
                ))
            }

            if let content = prompt.content {
                let lineCount = content.components(separatedBy: "\n").count
                // PRM002: prompt > 200 lines
                if lineCount > 200 {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .PRM002,
                        filePath: prompt.path,
                        message: "\(display) is \(lineCount) lines — very long prompt file.",
                        fix: "Break into smaller, focused prompts.",
                        displayPath: display
                    ))
                }
            }
        }

        // --- MCPs ---
        for mcp in mcpServers {
            if mcp.command == nil && mcp.url == nil {
                results.append(LintResult(
                    severity: .error,
                    checkId: .MCP002,
                    filePath: "mcp.json",
                    message: "MCP server '\(mcp.name)' has neither a command nor a url.",
                    fix: "Add a 'command' or 'url' field to the MCP server configuration.",
                    displayPath: "mcp.json"
                ))
            }
        }

        return results
    }
}

