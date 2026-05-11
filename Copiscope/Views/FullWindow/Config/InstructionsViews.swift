import SwiftUI

// MARK: - Instructions List

struct InstructionsListView: View {
    let instructions: [InstructionEntry]
    @State private var searchText = ""

    var filtered: [InstructionEntry] {
        guard !searchText.isEmpty else { return instructions }
        return instructions.filter {
            $0.source.label.localizedCaseInsensitiveContains(searchText) ||
            ($0.applyTo?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConfigSearchBar(text: $searchText, placeholder: "Filter instructions...")
            if filtered.isEmpty {
                ConfigEmptyState(
                    icon: "doc.text",
                    title: "No Instructions Found",
                    subtitle: instructions.isEmpty
                        ? "No .instructions.md files detected"
                        : "No instructions match your filter"
                )
            } else {
                List(filtered) { entry in
                    InstructionRow(entry: entry)
                }
            }
        }
    }
}

struct InstructionRow: View {
    let entry: InstructionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.source.label)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            if let applyTo = entry.applyTo {
                Text("Applies to: \(applyTo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Instructions Split View

struct InstructionsSplitView: View {
    let instructions: [InstructionEntry]
    @State private var selectedInstruction: InstructionEntry?

    var body: some View {
        HSplitView {
            List(instructions, selection: Binding(
                get: { selectedInstruction?.id },
                set: { id in selectedInstruction = instructions.first { $0.id == id } }
            )) { entry in
                InstructionRow(entry: entry)
                    .tag(entry.id)
            }
            .frame(minWidth: 220)

            if let selected = selectedInstruction {
                instructionDetail(selected)
            } else {
                ConfigEmptyState(
                    icon: "doc.text",
                    title: "Select an Instruction",
                    subtitle: "Choose an instruction file to view details"
                )
            }
        }
    }

    @ViewBuilder
    func instructionDetail(_ entry: InstructionEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.source.label)
                    .font(.headline)
                if let applyTo = entry.applyTo {
                    LabeledContent("Applies To", value: applyTo)
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
