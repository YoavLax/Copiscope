import SwiftUI

// MARK: - Duration Badge

struct TurnDurationBadge: View {
    let durationMs: Double

    private var color: Color {
        if durationMs < 5000 { return .green }
        if durationMs < 30000 { return .yellow }
        return .red
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9))
            Text(formatDuration(durationMs))
                .font(Typography.codeSmall)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Vendor Badge

struct VendorBadge: View {
    let vendor: String

    private var color: Color {
        switch vendor.lowercased() {
        case "anthropic": return .orange
        case "openai": return .green
        case "google": return .blue
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu")
                .font(.system(size: 9))
            Text(vendor)
                .font(Typography.codeSmall)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Parallel Tool Badge

struct ParallelToolBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
            Text("\(count) parallel")
                .font(Typography.codeSmall)
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.purple.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Duration Formatter

private func formatDuration(_ ms: Double) -> String {
    if ms < 1000 { return String(format: "%.0fms", ms) }
    if ms < 60000 { return String(format: "%.1fs", ms / 1000) }
    let minutes = Int(ms / 60000)
    let seconds = Int((ms.truncatingRemainder(dividingBy: 60000)) / 1000)
    return "\(minutes)m \(seconds)s"
}
