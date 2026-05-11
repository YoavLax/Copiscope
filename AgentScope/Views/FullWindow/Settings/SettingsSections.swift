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
        // Source: https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing
        let models: [(String, Double, Double)] = [
            // Anthropic
            ("Claude Haiku 4.5",    1.00,  5.00),
            ("Claude Sonnet 4/4.5/4.6", 3.00, 15.00),
            ("Claude Opus 4.5/4.6/4.7", 5.00, 25.00),
            // OpenAI
            ("GPT-5 mini",          0.25,  2.00),
            ("GPT-4.1",             2.00,  8.00),
            ("GPT-5.2 / 5.2-Codex / 5.3-Codex", 1.75, 14.00),
            ("GPT-5.4",             2.50, 15.00),
            ("GPT-5.4 mini",        0.75,  4.50),
            ("GPT-5.4 nano",        0.20,  1.25),
            ("GPT-5.5",             5.00, 30.00),
            // Google
            ("Gemini 2.5 Pro",      1.25, 10.00),
            ("Gemini 3 Flash",      0.50,  3.00),
            ("Gemini 3.1 Pro",      2.00, 12.00),
            // xAI
            ("Grok Code Fast 1",   0.20,  1.50),
        ]
        return models.map { label, input, output in
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

    // MARK: - Environment Section

    @ViewBuilder
    func environmentSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "environment", icon: "info.circle", title: "Environment") {
            VStack(spacing: 0) {
                settingsRow("VS Code", value: s.vscodeVersion ?? "Unknown")
                Divider().padding(.horizontal, 12)
                settingsRow("Copilot Extension", value: s.copilotVersion ?? "Unknown")
            }
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Model Section

    @ViewBuilder
    func modelSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "model", icon: "cpu", title: "Model") {
            VStack(spacing: 0) {
                settingsRow("Completion Model", value: s.selectedCompletionModel ?? "Default")
                if !s.enabledLanguages.isEmpty {
                    Divider().padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enabled by Language")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        FlowTagsView(items: s.enabledLanguages.sorted { $0.key < $1.key }.map { (lang, enabled) in
                            ("\(lang): \(enabled ? "✓" : "✗")", enabled ? Color.green : Color.red)
                        })
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
            }
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Completions Section

    @ViewBuilder
    func completionsSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "completions", icon: "text.badge.checkmark", title: "Completions") {
            VStack(spacing: 0) {
                settingsBoolRow("Next Edit Suggestions", value: s.nextEditSuggestionsEnabled)
            }
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Chat Section

    @ViewBuilder
    func chatSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "chat", icon: "bubble.left.and.bubble.right", title: "Chat") {
            VStack(spacing: 0) {
                if let max = s.maxRequests {
                    settingsRow("Max Agent Requests", value: "\(max)")
                    Divider().padding(.horizontal, 12)
                }
                settingsBoolRow("Copilot Memory", value: s.memoryEnabled)
                Divider().padding(.horizontal, 12)
                settingsBoolRow("Nested Agents (*.md)", value: s.nestedAgentsMd)
                Divider().padding(.horizontal, 12)
                settingsBoolRow("Show Org & Enterprise Agents", value: s.showOrgAgents)
                if let orient = s.viewSessionsOrientation {
                    Divider().padding(.horizontal, 12)
                    settingsRow("Session View", value: orient)
                }
            }
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Observability Section

    @ViewBuilder
    func observabilitySection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "observability", icon: "waveform", title: "Observability") {
            VStack(spacing: 0) {
                settingsBoolRow("OTEL Enabled", value: s.otelEnabled)
                if let endpoint = s.otelEndpoint, !endpoint.isEmpty {
                    Divider().padding(.horizontal, 12)
                    settingsRow("OTEL Endpoint", value: endpoint)
                }
                if let type_ = s.otelExporterType {
                    Divider().padding(.horizontal, 12)
                    settingsRow("Exporter Type", value: type_)
                }
                Divider().padding(.horizontal, 12)
                settingsBoolRow("Capture Content", value: s.otelCaptureContent)
                Divider().padding(.horizontal, 12)
                settingsBoolRow("DB Span Exporter", value: s.otelDbExporterEnabled)
                Divider().padding(.horizontal, 12)
                settingsBoolRow("Agent Debug Log", value: s.agentDebugLogEnabled)
            }
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Marketplaces Section

    @ViewBuilder
    func marketplacesSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "marketplaces", icon: "storefront", title: "Marketplaces") {
            VStack(alignment: .leading, spacing: 8) {
                settingsBoolRow("MCP Gallery", value: s.mcpGalleryEnabled)
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))

                if !s.pluginMarketplaces.isEmpty {
                    Text("Plugin Marketplaces")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(s.pluginMarketplaces.enumerated()), id: \.offset) { i, mkt in
                            if i > 0 { Divider().padding(.horizontal, 12) }
                            HStack {
                                Image(systemName: "storefront")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(mkt)
                                    .font(Typography.code)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    }
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                }

                if !s.mcpServerSampling.isEmpty {
                    Text("MCP Server Sampling")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(s.mcpServerSampling.sorted { $0.key < $1.key }.enumerated()), id: \.offset) { i, pair in
                            if i > 0 { Divider().padding(.horizontal, 12) }
                            settingsBoolRow(pair.key, value: pair.value)
                        }
                    }
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Hooks Section

    @ViewBuilder
    func hooksSection() -> some View {
        let s = store.vscodeSettings
        settingsSection(id: "hooks", icon: "arrow.triangle.branch", title: "Hooks") {
            if s.hookFileLocations.isEmpty {
                settingsEmptyHint("No hook file locations configured.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(s.hookFileLocations.sorted { $0.key < $1.key }.enumerated()), id: \.offset) { i, pair in
                        if i > 0 { Divider().padding(.horizontal, 12) }
                        HStack {
                            Image(systemName: pair.value ? "checkmark.circle.fill" : "xmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(pair.value ? .green : .secondary)
                            Text(pair.key)
                                .font(Typography.code)
                            Spacer()
                            Text(pair.value ? "enabled" : "disabled")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Shared row helpers

    @ViewBuilder
    func settingsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    func settingsBoolRow(_ label: String, value: Bool?) -> some View {
        HStack {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                HStack(spacing: 4) {
                    Circle()
                        .fill(value ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(value ? "enabled" : "disabled")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(value ? .green : .secondary)
                }
            } else {
                Text("not set")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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
