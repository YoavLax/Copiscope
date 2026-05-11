import SwiftUI

// MARK: - Agents List

struct AgentsListView: View {
    let agents: [AgentEntry]
    @State private var searchText = ""

    var filtered: [AgentEntry] {
        guard !searchText.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConfigSearchBar(text: $searchText, placeholder: "Filter agents...")
            if filtered.isEmpty {
                ConfigEmptyState(
                    icon: "person.2",
                    title: "No Agents Found",
                    subtitle: agents.isEmpty
                        ? "No .agent.md or AGENTS.md files detected"
                        : "No agents match your filter"
                )
            } else {
                List(filtered) { entry in
                    AgentRow(entry: entry)
                }
            }
        }
    }
}

struct AgentRow: View {
    let entry: AgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            if let desc = entry.description {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Agents Split View

struct AgentsSplitView: View {
    let agents: [AgentEntry]
    @State private var selectedAgent: AgentEntry?

    var body: some View {
        HSplitView {
            List(agents, selection: Binding(
                get: { selectedAgent?.id },
                set: { id in selectedAgent = agents.first { $0.id == id } }
            )) { entry in
                AgentRow(entry: entry)
                    .tag(entry.id)
            }
            .frame(minWidth: 220)

            if let selected = selectedAgent {
                agentDetail(selected)
            } else {
                ConfigEmptyState(
                    icon: "person.2",
                    title: "Select an Agent",
                    subtitle: "Choose an agent to view details"
                )
            }
        }
    }

    @ViewBuilder
    func agentDetail(_ entry: AgentEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name)
                    .font(.headline)
                if let desc = entry.description {
                    Text(desc)
                        .foregroundStyle(.secondary)
                }
                if let content = entry.content {
                    Divider()
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
    }
}
