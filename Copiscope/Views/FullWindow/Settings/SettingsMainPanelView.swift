import SwiftUI

// MARK: - Settings Main Panel View

struct SettingsMainPanelView: View {
    @Environment(SessionStore.self) var store
    @Binding var selectedSection: String?
    @State var expandedSections: Set<String> = [
        "appearance", "environment", "model", "chat", "pricing", "updates"
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
                if let path = settingsPath {
                    Text("Settings from \(path)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Copiscope preferences")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShow("appearance") { appearanceSection() }
                    if shouldShow("environment") { environmentSection() }
                    if shouldShow("model") { modelSection() }
                    if shouldShow("completions") { completionsSection() }
                    if shouldShow("chat") { chatSection() }
                    if shouldShow("observability") { observabilitySection() }
                    if shouldShow("marketplaces") { marketplacesSection() }
                    if shouldShow("hooks") { hooksSection() }
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

    private var settingsPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "~/Library/Application Support/Code/User/settings.json"
            .replacingOccurrences(of: home, with: "~")
    }
}
