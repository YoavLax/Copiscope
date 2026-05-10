import SwiftUI

// MARK: - Settings Sections

extension SettingsMainPanelView {

    // MARK: - Section Builder

    @ViewBuilder
    func settingsSection<Content: View>(
        id: String,
        icon: String,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedSections.contains(id) },
            set: { newValue in
                if newValue {
                    expandedSections.insert(id)
                } else {
                    expandedSections.remove(id)
                }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(12)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Empty Hint

    @ViewBuilder
    func settingsEmptyHint(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundStyle(.tertiary)
        .padding(12)
    }

    // MARK: - Appearance Section

    @ViewBuilder
    func appearanceSection() -> some View {
        settingsSection(id: "appearance", icon: "paintbrush", title: "Appearance") {
            HStack(spacing: 8) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { option in
                    Button {
                        store.appearance = option
                        MainWindowController.shared.applyAppearance(option)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(previewFill(for: option))
                                .frame(width: 64, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            store.appearance == option ? Color.accentColor : Color.secondary.opacity(0.3),
                                            lineWidth: store.appearance == option ? 2 : 1
                                        )
                                )

                            Text(option.label)
                                .font(.system(size: 12, weight: store.appearance == option ? .medium : .regular))
                                .foregroundStyle(store.appearance == option ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private func previewFill(for option: AppAppearance) -> some ShapeStyle {
        switch option {
        case .system: return AnyShapeStyle(LinearGradient(colors: [.white, .black], startPoint: .leading, endPoint: .trailing))
        case .light: return AnyShapeStyle(Color.white)
        case .dark: return AnyShapeStyle(Color(white: 0.15))
        }
    }

    // MARK: - Pricing Section

    @ViewBuilder
    func pricingSection() -> some View {
        settingsSection(id: "pricing", icon: "dollarsign.circle", title: "Pricing") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Token costs are estimated from GitHub Copilot model pricing.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rates (per 1M tokens)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Model")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Input")
                                .frame(width: 70, alignment: .trailing)
                            Text("Output")
                                .frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AnyShapeStyle(.quaternary))

                        ForEach(pricingRows(), id: \.model) { row in
                            Divider().padding(.horizontal, 12)
                            HStack {
                                Text(row.model)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.input)
                                    .frame(width: 70, alignment: .trailing)
                                Text(row.output)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(Typography.code)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                    }
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    struct PricingRow {
        let model: String
        let input: String
        let output: String
    }

    func pricingRows() -> [PricingRow] {
        let models: [(String, String, Double, Double)] = [
            ("Claude Opus 4", "claude-opus-4", 15.0, 75.0),
            ("Claude Sonnet 4", "claude-sonnet-4-20250514", 3.0, 15.0),
            ("GPT-4o", "gpt-4o", 2.50, 10.0),
            ("GPT-4o mini", "gpt-4o-mini", 0.15, 0.60),
            ("Claude Haiku", "claude-haiku-3.5", 0.80, 4.0),
        ]
        return models.map { label, _, input, output in
            PricingRow(
                model: label,
                input: String(format: "$%.2f", input),
                output: String(format: "$%.2f", output)
            )
        }
    }

    // MARK: - Updates Section

    @ViewBuilder
    func updatesSection() -> some View {
        settingsSection(id: "updates", icon: "arrow.triangle.2.circlepath", title: "Updates") {
            UpdatesSectionContent()
        }
    }
}

// MARK: - Updates Section Content

struct UpdatesSectionContent: View {
    @Environment(UpdateService.self) private var updateService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Current version")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(updateService.currentVersion)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 12)

            Divider()

            HStack {
                @Bindable var service = updateService
                Toggle("Check for updates automatically", isOn: $service.autoCheckEnabled)
                    .font(Typography.body)
                    .toggleStyle(.checkbox)
                    .disabled(updateService.isAutoCheckManaged)
            }
            .padding(.horizontal, 12)

            if updateService.isAutoCheckManaged {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                    Text("Managed by your organization")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let update = updateService.updateAvailable {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                        Text("Version \(update.version) available")
                            .font(Typography.bodyMedium)

                        Spacer()

                        if updateService.isDownloading {
                            ProgressView(value: updateService.downloadProgress)
                                .frame(width: 80)
                            Text("\(Int(updateService.downloadProgress * 100))%")
                                .font(Typography.codeSmall)
                                .foregroundStyle(.secondary)
                            Button("Cancel") {
                                updateService.cancelDownload()
                            }
                            .font(.system(size: 12))
                        } else {
                            Button("Download and Install") {
                                updateService.downloadAndInstall()
                            }
                            .font(Typography.body)
                        }
                    }

                    if let notes = update.releaseNotes, !notes.isEmpty {
                        ScrollView {
                            MarkdownNotesView(markdown: notes)
                                .padding(10)
                        }
                        .frame(maxHeight: 160)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AnyShapeStyle(.quaternary))
                        )
                    }
                } else {
                    HStack {
                        Text(updateService.isChecking ? "" : "You're up to date")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("What's New") {
                            updateService.whatsNewInfo = .init(
                                version: updateService.currentVersion,
                                releaseNotes: nil
                            )
                            updateService.onOpenWhatsNew?()
                        }
                        .font(Typography.body)

                        Button {
                            Task {
                                updateService.clearSkippedVersion()
                                await updateService.checkForUpdates()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if updateService.isChecking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Check Now")
                            }
                        }
                        .font(Typography.body)
                        .disabled(updateService.isChecking)
                    }
                }
            }
            .padding(.horizontal, 12)

            if let error = updateService.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                    Spacer()
                    Button("Retry") {
                        Task { await updateService.checkForUpdates() }
                    }
                    .font(.system(size: 12))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }
}
