import SwiftUI

// MARK: - Prompts List

struct PromptsListView: View {
    let prompts: [PromptEntry]
    @State private var searchText = ""

    var filtered: [PromptEntry] {
        guard !searchText.isEmpty else { return prompts }
        return prompts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConfigSearchBar(text: $searchText, placeholder: "Filter prompts...")
            if filtered.isEmpty {
                ConfigEmptyState(
                    icon: "text.bubble",
                    title: "No Prompts Found",
                    subtitle: prompts.isEmpty
                        ? "No .prompt.md files detected"
                        : "No prompts match your filter"
                )
            } else {
                List(filtered) { entry in
                    PromptRow(entry: entry)
                }
            }
        }
    }
}

struct PromptRow: View {
    let entry: PromptEntry

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

// MARK: - Prompts Split View

struct PromptsSplitView: View {
    let prompts: [PromptEntry]
    @State private var searchText = ""
    @State private var selectedPrompt: PromptEntry?

    var filtered: [PromptEntry] {
        guard !searchText.isEmpty else { return prompts }
        return prompts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ConfigSearchBar(text: $searchText, placeholder: "Filter prompts...")
                List(filtered, selection: Binding(
                    get: { selectedPrompt?.id },
                    set: { id in selectedPrompt = filtered.first { $0.id == id } }
                )) { entry in
                    PromptRow(entry: entry)
                        .tag(entry.id)
                }
            }
            .frame(minWidth: 250)

            if let selected = selectedPrompt {
                promptDetail(selected)
            } else {
                ConfigEmptyState(
                    icon: "text.bubble",
                    title: "Select a Prompt",
                    subtitle: "Choose a prompt file to view details"
                )
            }
        }
    }

    @ViewBuilder
    func promptDetail(_ entry: PromptEntry) -> some View {
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
