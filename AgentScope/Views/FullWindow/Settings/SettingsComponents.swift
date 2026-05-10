import SwiftUI

// MARK: - Key-Value Row

func settingsKeyDisplayName(_ key: String) -> String {
    switch key {
    case "model": return "Model"
    case "smallFastModel": return "Small/Fast Model"
    case "skipDangerousModePermissionPrompt": return "Skip Dangerous Mode Prompt"
    case "autoMemoryEnabled": return "Auto Memory"
    case "cleanupPeriodDays": return "Cleanup Period (Days)"
    case "includeCoAuthoredBy": return "Include Co-Authored-By"
    case "attributionStyle": return "Attribution Style"
    case "sandbox": return "Sandbox"
    default: return key
    }
}

struct SettingsKeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack {
            Text(settingsKeyDisplayName(key))
                .font(Typography.body)
                .foregroundStyle(.tertiary)

            Spacer()

            if mono {
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return LayoutResult(
            positions: positions,
            size: CGSize(width: totalWidth, height: currentY + lineHeight)
        )
    }
}

// MARK: - Colored Tag Flow View

struct FlowTagsView: View {
    let items: [(String, Color)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(item.1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(item.1.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(item.1.opacity(0.3), lineWidth: 1))
            }
        }
    }
}
