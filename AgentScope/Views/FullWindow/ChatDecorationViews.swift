import SwiftUI

// MARK: - Turn Separator

struct TurnSeparator: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
