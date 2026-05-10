import SwiftUI

// MARK: - Settings Main Panel View

struct SettingsMainPanelView: View {
    @Environment(SessionStore.self) var store
    @Binding var selectedSection: String?
    @State var expandedSections: Set<String> = [
        "appearance", "pricing", "updates"
    ]

    func shouldShow(_ sectionId: String) -> Bool {
        guard let sel = selectedSection else { return true }
        return sel == sectionId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("AgentScope preferences")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShow("appearance") { appearanceSection() }
                    if shouldShow("pricing") { pricingSection() }
                    if shouldShow("updates") { updatesSection() }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
