import SwiftUI

struct FullWindowView: View {
    @Environment(SessionStore.self) private var store
    @State private var selectedRail: RailItem = .analytics
    @State private var selectedWorkspaceId: String?
    @State private var selectedSessionId: String?
    @State private var savedSelections: [RailItem: (workspaceId: String?, sessionId: String?)] = [:]

    // Config state
    @State private var selectedMcpName: String?
    @State private var selectedMemoryId: String?
    @State private var selectedMemoryWorkspaceId: String?

    // Config Health state
    @State private var selectedLintResultId: String?
    @State private var hiddenLintSeverities: Set<LintSeverity> = []
    @State private var selectedHealthItem: String?

    // Command palette
    @State private var showCommandPalette = false

    // Pending navigation (deferred until after rail change)
    @State private var pendingNavigation: (workspaceId: String, sessionId: String)?

    // Timeline state
    @State private var selectedTimelineDay: String?

    // Settings state
    @State private var selectedSettingsSection: String?

    // Sidebar resize
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 240
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            threeColumnLayout
            commandPaletteLayer
        }
        .overlay(alignment: .top) {
            if store.isLoading {
                ScanProgressBanner()
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: store.isLoading)
            }
        }
        .onChange(of: selectedRail) { oldRail, newRail in
            savedSelections[oldRail] = (selectedWorkspaceId, selectedSessionId)

            if let nav = pendingNavigation {
                selectedWorkspaceId = nav.workspaceId
                selectedSessionId = nav.sessionId
                pendingNavigation = nil
            } else if let saved = savedSelections[newRail] {
                selectedWorkspaceId = saved.workspaceId
                selectedSessionId = saved.sessionId
            } else {
                selectedWorkspaceId = nil
                selectedSessionId = nil
            }

            loadDataForRail(newRail)
        }
        .onChange(of: SessionSelection(workspaceId: selectedWorkspaceId, sessionId: selectedSessionId)) { _, selection in
            if let sessionId = selection.sessionId, let workspaceId = selection.workspaceId {
                Task {
                    await store.loadSession(id: sessionId, workspaceId: workspaceId)
                }
            }
        }
        .onChange(of: selectedMemoryWorkspaceId) { _, _ in
            Task {
                await store.loadMemoryFiles()
            }
        }
        .background {
            Button("") { showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var threeColumnLayout: some View {
        HStack(spacing: 0) {
            RailView(selected: $selectedRail)

            Divider()

            SidebarView(
                rail: selectedRail,
                width: sidebarWidth,
                selectedWorkspaceId: $selectedWorkspaceId,
                selectedSessionId: $selectedSessionId,
                selectedMcpName: $selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedMemoryWorkspaceId: $selectedMemoryWorkspaceId,
                selectedSettingsSection: $selectedSettingsSection,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: $selectedHealthItem,
                selectedTimelineDay: $selectedTimelineDay
            )

            SidebarResizeHandle(sidebarWidth: $sidebarWidth, dragStartWidth: $dragStartWidth)

            MainPanelView(
                rail: selectedRail,
                selectedMcpName: selectedMcpName,
                selectedMemoryId: $selectedMemoryId,
                selectedLintResultId: $selectedLintResultId,
                hiddenLintSeverities: $hiddenLintSeverities,
                selectedHealthItem: selectedHealthItem,
                selectedWorkspaceId: selectedWorkspaceId,
                selectedSettingsSection: $selectedSettingsSection,
                onNavigateToSession: { workspaceId, sessionId in
                    pendingNavigation = (workspaceId, sessionId)
                    selectedRail = .sessions
                }
            )
        }
    }

    @ViewBuilder
    private var commandPaletteLayer: some View {
        if showCommandPalette {
            CommandPaletteOverlay(
                isPresented: $showCommandPalette,
                selectedRail: $selectedRail,
                selectedWorkspaceId: $selectedWorkspaceId,
                selectedSessionId: $selectedSessionId
            )
        }
    }

    private func loadDataForRail(_ rail: RailItem) {
        Task {
            switch rail {
            case .timeline:
                await store.loadTimeline()
            case .memory:
                await store.loadMemoryFiles()
                await store.loadConfig()
            case .configHealth:
                await store.runConfigLintIfNeeded()
            case .instructions, .prompts, .agents, .mcps, .settings:
                await store.loadConfig()
            case .analytics, .sessions, .tools:
                break
            }
        }
    }
}

private struct SessionSelection: Equatable {
    let workspaceId: String?
    let sessionId: String?
}

// MARK: - Sidebar Resize Handle

private struct SidebarResizeHandle: View {
    @Binding var sidebarWidth: Double
    @Binding var dragStartWidth: CGFloat?
    @State private var isHovered = false

    private let minWidth: CGFloat = 180
    private let maxWidth: CGFloat = 400
    private let defaultWidth: CGFloat = 240

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.accentColor.opacity(0.3) : .clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = sidebarWidth
                        }
                        let newWidth = (dragStartWidth ?? sidebarWidth) + value.translation.width
                        sidebarWidth = min(maxWidth, max(minWidth, newWidth))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarWidth = defaultWidth
                }
            }
    }
}
