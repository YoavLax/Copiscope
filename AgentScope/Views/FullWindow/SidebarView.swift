import SwiftUI

struct SidebarView: View {
    let rail: RailItem
    let width: CGFloat
    @Environment(SessionStore.self) private var store
    @Binding var selectedWorkspaceId: String?
    @Binding var selectedSessionId: String?
    @Binding var selectedMcpName: String?
    @Binding var selectedMemoryId: String?
    @Binding var selectedMemoryWorkspaceId: String?
    @Binding var selectedSettingsSection: String?
    @Binding var selectedLintResultId: String?
    @Binding var hiddenLintSeverities: Set<LintSeverity>
    @Binding var selectedHealthItem: String?
    @Binding var selectedTimelineDay: String?
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Filter \(rail.label.lowercased())...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                switch rail {
                case .sessions:
                    SessionsSidebarContent(
                        workspaces: store.workspaces,
                        sessionsByWorkspace: store.sessionsByWorkspace,
                        filterText: filterText,
                        selectedSessionId: $selectedSessionId,
                        selectedWorkspaceId: $selectedWorkspaceId
                    )
                case .tools:
                    ToolsSidebarContent(
                        workspaces: store.workspaces,
                        sessionsByWorkspace: store.sessionsByWorkspace,
                        filterText: filterText,
                        selectedSessionId: $selectedSessionId,
                        selectedWorkspaceId: $selectedWorkspaceId
                    )
                case .analytics:
                    AnalyticsSidebarContent(
                        workspaceCosts: store.analyticsData.workspaceCosts,
                        totalCost: store.analyticsData.totalCost,
                        filterText: filterText,
                        timeRangeLabel: store.analyticsTimeRange.rawValue,
                        selectedWorkspaceId: Binding(
                            get: { store.selectedWorkspaceId },
                            set: { newValue in
                                store.selectedWorkspaceId = newValue
                                store.recomputeAnalytics()
                            }
                        )
                    )
                case .agents:
                    AgentsSidebarContent(
                        filterText: filterText,
                        agents: store.agents
                    )
                case .timeline:
                    TimelineSidebarContent(
                        filterText: filterText,
                        entries: store.timelineEntries,
                        selectedDay: $selectedTimelineDay
                    )
                case .instructions:
                    InstructionsSidebarContent(
                        filterText: filterText,
                        instructions: store.instructions
                    )
                case .prompts:
                    PromptsSidebarContent(
                        filterText: filterText,
                        prompts: store.prompts
                    )
                case .mcps:
                    McpsSidebarContent(
                        filterText: filterText,
                        mcpServers: store.mcpServers,
                        selectedMcpName: $selectedMcpName
                    )
                case .memory:
                    MemorySidebarContent(
                        filterText: filterText,
                        workspaces: store.workspaces,
                        memoryFiles: store.memoryFiles,
                        selectedMemoryId: $selectedMemoryId,
                        selectedWorkspaceId: $selectedMemoryWorkspaceId
                    )
                case .configHealth:
                    ConfigHealthSidebarContent(
                        filterText: filterText,
                        lintResults: store.lintResults,
                        lintSummary: store.lintSummary,
                        isLoading: store.lintLoading,
                        selectedItem: $selectedHealthItem,
                        hiddenSeverities: $hiddenLintSeverities
                    )
                case .settings:
                    SettingsSidebarContent(
                        filterText: filterText,
                        selectedSection: $selectedSettingsSection
                    )
                }
            }
        }
        .onChange(of: rail) { _, _ in filterText = "" }
        .frame(width: width)
        .background(.bar.opacity(0.5))
    }
}

// MARK: - Sessions Sidebar

private struct SessionsSidebarContent: View {
    let workspaces: [Workspace]
    let sessionsByWorkspace: [String: [SessionSummary]]
    let filterText: String
    @Binding var selectedSessionId: String?
    @Binding var selectedWorkspaceId: String?

    var filteredWorkspaces: [Workspace] {
        if filterText.isEmpty { return workspaces }
        return workspaces.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(filterText) ||
            (sessionsByWorkspace[workspace.id] ?? []).contains { session in
                session.title.localizedCaseInsensitiveContains(filterText)
            }
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filteredWorkspaces) { workspace in
                WorkspaceGroup(
                    workspace: workspace,
                    sessions: filteredSessions(for: workspace),
                    selectedSessionId: $selectedSessionId,
                    selectedWorkspaceId: $selectedWorkspaceId
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func filteredSessions(for workspace: Workspace) -> [SessionSummary] {
        let sessions = sessionsByWorkspace[workspace.id] ?? []
        if filterText.isEmpty { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
    }
}

private struct WorkspaceGroup: View {
    let workspace: Workspace
    let sessions: [SessionSummary]
    @Binding var selectedSessionId: String?
    @Binding var selectedWorkspaceId: String?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    Text(workspace.name)
                        .font(Typography.bodyMedium)
                        .lineLimit(1)
                        .help(workspace.name)

                    Spacer()

                    Text("\(sessions.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: selectedSessionId == session.id
                    ) {
                        selectedSessionId = session.id
                        selectedWorkspaceId = workspace.id
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(Typography.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    Text(formatRelativeTime(session.lastTimestamp))
                        .font(.system(size: 11))

                    Text("\u{00B7}")
                        .font(.system(size: 11))

                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 11))

                    if !session.observability.errorClassifications.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }

                    if let model = session.primaryModel {
                        let family = getModelFamily(model)
                        Spacer()
                        Text(family)
                            .font(Typography.micro)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.leading, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.04) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Sidebar Stubs for New Items

private struct AgentsSidebarContent: View {
    let filterText: String
    let agents: [AgentEntry]

    var filtered: [AgentEntry] {
        guard !filterText.isEmpty else { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filtered) { agent in
                HStack {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(agent.name)
                        .font(Typography.body)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InstructionsSidebarContent: View {
    let filterText: String
    let instructions: [InstructionEntry]

    var filtered: [InstructionEntry] {
        guard !filterText.isEmpty else { return instructions }
        return instructions.filter { $0.source.label.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filtered) { entry in
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(entry.source.label)
                        .font(Typography.body)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PromptsSidebarContent: View {
    let filterText: String
    let prompts: [PromptEntry]

    var filtered: [PromptEntry] {
        guard !filterText.isEmpty else { return prompts }
        return prompts.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filtered) { entry in
                HStack {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(entry.name)
                        .font(Typography.body)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Analytics Sidebar

private struct AnalyticsSidebarContent: View {
    let workspaceCosts: [WorkspaceCost]
    let totalCost: Double
    let filterText: String
    let timeRangeLabel: String
    @Binding var selectedWorkspaceId: String?

    var filtered: [WorkspaceCost] {
        if filterText.isEmpty { return workspaceCosts }
        return workspaceCosts.filter { $0.workspaceName.localizedCaseInsensitiveContains(filterText) }
    }

    var maxCost: Double {
        filtered.map(\.totalCost).max() ?? 1
    }

    private let barColors: [Color] = [
        .blue, .green, .orange, .red, .purple, .cyan, .yellow, .pink, .mint, .teal
    ]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("COST BY WORKSPACE (\(timeRangeLabel.uppercased()))")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            AnalyticsWorkspaceRow(
                name: "All workspaces",
                cost: totalCost,
                barWidth: 1.0,
                barColor: .accentColor,
                isSelected: selectedWorkspaceId == nil
            ) {
                selectedWorkspaceId = nil
            }

            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, cost in
                AnalyticsWorkspaceRow(
                    name: cost.workspaceName,
                    cost: cost.totalCost,
                    barWidth: cost.totalCost / maxCost,
                    barColor: barColors[index % barColors.count],
                    isSelected: selectedWorkspaceId == cost.workspaceId
                ) {
                    selectedWorkspaceId = cost.workspaceId
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AnalyticsWorkspaceRow: View {
    let name: String
    let cost: Double
    let barWidth: Double
    let barColor: Color
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .help(name)
                    Spacer()
                    Text(formatCost(cost))
                        .font(Typography.code)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }

                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor.opacity(0.6))
                        .frame(width: max(4, geo.size.width * barWidth))
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
