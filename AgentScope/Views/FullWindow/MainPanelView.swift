import SwiftUI
import Charts

struct MainPanelView: View {
    let rail: RailItem
    @Environment(SessionStore.self) private var store

    // Config
    let selectedMcpName: String?
    @Binding var selectedMemoryId: String?

    // Config Health
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    let selectedHealthItem: String?
    let selectedWorkspaceId: String?

    // Settings
    @Binding var selectedSettingsSection: String?

    // Session navigation from config health (workspaceId, sessionId)
    var onNavigateToSession: ((String, String) -> Void)?

    var body: some View {
        Group {
            switch rail {
            case .analytics:
                AnalyticsDetailView()
            case .sessions:
                if let session = store.selectedSession {
                    SessionDetailTabView(session: session)
                } else {
                    EmptyStateView(
                        icon: "text.line.first.and.arrowtriangle.forward",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to view its conversation."
                    )
                }
            case .tools:
                if let session = store.selectedSession {
                    ToolsMainPanelView(session: session)
                        .id(session.id)
                } else {
                    EmptyStateView(
                        icon: "wrench.and.screwdriver",
                        title: "Select a session",
                        message: "Choose a session from the sidebar to audit its tool usage."
                    )
                }
            case .agents:
                if store.agents.isEmpty {
                    EmptyStateView(
                        icon: "person.2",
                        title: "No agents found",
                        message: "No .agent.md or AGENTS.md files were detected in your VS Code workspace."
                    )
                } else {
                    AgentsSplitView(agents: store.agents)
                }
            case .timeline:
                TimelineMainPanelView(
                    entries: store.timelineEntries,
                    isLoading: store.timelineLoading,
                    onNavigateToSession: onNavigateToSession
                )
            case .instructions:
                InstructionsSplitView(instructions: store.instructions)
            case .prompts:
                PromptsSplitView(prompts: store.prompts)
            case .mcps:
                McpsMainPanelView(
                    mcpServers: store.mcpServers,
                    selectedMcpName: selectedMcpName
                )
            case .memory:
                MemoryMainPanelView(
                    memoryFiles: store.memoryFiles,
                    selectedMemoryId: $selectedMemoryId
                )
            case .configHealth:
                ConfigHealthMainPanelView(
                    lintResults: store.lintResults,
                    lintSummary: store.lintSummary,
                    isLoading: store.lintLoading,
                    isSecretScanLoading: store.secretScanLoading,
                    selectedResultId: $selectedLintResultId,
                    hiddenSeverities: $hiddenLintSeverities,
                    selectedItem: selectedHealthItem,
                    onRescan: {
                        Task {
                            await store.runConfigLint()
                        }
                    },
                    onNavigateToSession: onNavigateToSession
                )
            case .settings:
                SettingsMainPanelView(selectedSection: $selectedSettingsSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionDetailTabView: View {
    let session: ParsedSession
    @Environment(SessionStore.self) private var store
    @State private var selectedTab: SessionTab = .chat

    enum SessionTab: String, CaseIterable {
        case chat = "Chat"
        case agentTree = "Agent Tree"
    }

    private var showAgentTreeTab: Bool {
        store.agentTree != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if showAgentTreeTab {
                Picker("", selection: $selectedTab) {
                    ForEach(SessionTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            switch selectedTab {
            case .chat:
                ChatView(session: session)
            case .agentTree:
                AgentTreeView(session: session)
                    .id(session.id)
            }
        }
    }
}
