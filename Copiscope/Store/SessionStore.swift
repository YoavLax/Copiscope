import AppKit
import Foundation
import Combine

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Central observable store for all session/workspace data.
@MainActor @Observable
final class SessionStore {
    var workspaces: [Workspace] = []
    var sessionsByWorkspace: [String: [SessionSummary]] = [:]
    var hasActiveSession: Bool = false
    var analyticsData: AnalyticsData = .empty
    // Today-only stats — always for the current calendar day, updated by recomputeAnalytics()
    var todaySessionCount: Int = 0
    var todayWorkspaceCount: Int = 0
    var todayTokens: Int = 0
    var todayCost: Double = 0.0
    var selectedWorkspaceId: String?
    var analyticsTimeRange: AnalyticsTimeRange = .today
    var analyticsCustomFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var analyticsCustomTo: Date = Date()
    var isLoading: Bool = true
    var scanSessionsProcessed: Int = 0
    var scanSessionsTotal: Int = 0
    var selectedSession: ParsedSession?

    // Timeline data
    var timelineEntries: [HistoryEntry] = []
    var timelineLoading: Bool = false

    // Config data
    var instructions: [InstructionEntry] = []
    var agents: [AgentEntry] = []
    var prompts: [PromptEntry] = []
    var mcpServers: [McpServerEntry] = []
    var memoryFiles: [MemoryFile] = []
    var vscodeSettings: VSCodeSettings = .empty
    var configLoading: Bool = false

    // Observability data
    var agentTree: AgentTreeNode? = nil
    var sessionBadges: [String: SessionBadgeData] = [:]

    // Lint data
    var lintResults: [LintResult] = []
    var lintSummary: LintSummary = .empty
    var lintLoading: Bool = false
    var secretScanLoading: Bool = false

    // Real-time secret alert
    var activeSecretAlert: SecretAlert?
    var onSecretAlert: ((SecretAlert) -> Void)?
    private var alertedSecrets: [String] = [] {
        didSet { Self.persistAlertedSecrets(alertedSecrets) }
    }

    private static let alertedSecretsKey = "alertedSecretValues"
    private static let alertedSecretsCap = 200

    private static func loadAlertedSecrets() -> [String] {
        let array = UserDefaults.standard.stringArray(forKey: alertedSecretsKey) ?? []
        return Array(array.suffix(alertedSecretsCap))
    }

    private static func persistAlertedSecrets(_ secrets: [String]) {
        UserDefaults.standard.set(secrets, forKey: alertedSecretsKey)
    }

    private var lintResultsValid: Bool = false

    var realtimeSecretScanEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(realtimeSecretScanEnabled, forKey: Self.realtimeSecretScanKey)
        }
    }

    private static let realtimeSecretScanKey = "realtimeSecretScanEnabled"

    // Dock icon preference
    var showInDock: Bool = false {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(self.showInDock ? .regular : .accessory)
            }
        }
    }
    private static let showInDockKey = "showInDock"

    // Appearance
    var appearance: AppAppearance = .system

    private let vscodeUserDirs: [URL]  // all active VS Code User dirs (stable, Insiders, …)
    private var vscodeUserDir: URL { vscodeUserDirs[0] }  // primary dir (for settings r/w, OTEL)
    private let parser = SessionParser()
    private let cache = SessionCache()
    private var otelReader: OtelSpanReader?
    private let otelDbPath: String
    private let watcher: CopilotFileWatcher
    private let linterService = ConfigLinterService()
    private var cancellables = Set<AnyCancellable>()
    private let cliStateDir: URL
    private let cliScanner: CLISessionScanner
    /// Persistent cache: session ID → token data loaded from disk.
    /// Used as fallback when OTEL DB has pruned old sessions.
    private var persistedTokenCache: [String: PersistedTokenData] = [:]
    /// Per-session today-only tokens from OTEL (spans with start_time_ms >= today midnight).
    /// Keyed by session ID. Used by recomputeAnalytics() for accurate same-day cost display.
    private var todayTokensBySession: [String: (input: Int, output: Int, cached: Int)] = [:]
    /// Session IDs touched by the file watcher since the last OTEL DB update.
    /// Used to re-enrich sessions after OTEL spans are written (which lags the JSONL write).
    private var pendingOtelEnrichment: Set<String> = []

    /// All sessions flattened with their workspace
    var allSessionsWithWorkspaces: [(session: SessionSummary, workspace: Workspace)] {
        var result: [(SessionSummary, Workspace)] = []
        for workspace in workspaces {
            if let sessions = sessionsByWorkspace[workspace.id] {
                for session in sessions {
                    result.append((session, workspace))
                }
            }
        }
        return result
    }

    /// Recent sessions (last 3, any date)
    var recentSessions: [SessionSummary] {
        Array(
            allSessionsWithWorkspaces
                .map(\.session)
                .sorted { $0.lastTimestamp > $1.lastTimestamp }
                .prefix(3)
        )
    }

    func clearAlertedSecrets() {
        alertedSecrets.removeAll()
    }

    /// Cached analytics for the sidebar
    var sidebarAnalyticsData: AnalyticsData = .empty

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        let appSupport = home.appendingPathComponent("Library/Application Support")

        // Detect all active VS Code User dirs (stable + Insiders), in preference order
        let vscodeVariants = ["Code/User", "Code - Insiders/User"]
        var detected: [URL] = vscodeVariants.compactMap { rel in
            let url = appSupport.appendingPathComponent(rel)
            return fm.fileExists(atPath: url.appendingPathComponent("workspaceStorage").path) ? url : nil
        }
        if detected.isEmpty {
            detected = [appSupport.appendingPathComponent("Code/User")]
        }
        self.vscodeUserDirs = detected

        // OTEL DB: use first dir that has the database
        var resolvedOtelDbPath = vscodeUserDirs[0]
            .appendingPathComponent("globalStorage/github.copilot-chat/agent-traces.db")
            .path
        for dir in vscodeUserDirs {
            let path = dir.appendingPathComponent("globalStorage/github.copilot-chat/agent-traces.db").path
            if fm.fileExists(atPath: path) { resolvedOtelDbPath = path; break }
        }
        self.otelDbPath = resolvedOtelDbPath
        if fm.fileExists(atPath: resolvedOtelDbPath) {
            self.otelReader = OtelSpanReader(dbPath: resolvedOtelDbPath)
        } else {
            self.otelReader = nil
        }

        // CLI session-state directory — create eagerly so the file watcher always has it
        let cliStateDir = home.appendingPathComponent(".copilot/session-state")
        try? fm.createDirectory(at: cliStateDir, withIntermediateDirectories: true)
        self.cliStateDir = cliStateDir
        self.cliScanner = CLISessionScanner(cliStateDir: cliStateDir, parser: SessionParser())

        self.watcher = CopilotFileWatcher(
            vscodeUserDirs: vscodeUserDirs,
            otelDbPath: resolvedOtelDbPath,
            cliStateDir: cliStateDir
        )

        self.alertedSecrets = Self.loadAlertedSecrets()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.realtimeSecretScanKey) == nil {
            self.realtimeSecretScanEnabled = true
            defaults.set(true, forKey: Self.realtimeSecretScanKey)
        } else {
            self.realtimeSecretScanEnabled = defaults.bool(forKey: Self.realtimeSecretScanKey)
        }

        self.showInDock = defaults.bool(forKey: Self.showInDockKey)

        self.persistedTokenCache = SessionTokenPersistence.shared.load()

        setupWatcher()
        performInitialScan()
    }

    private func setupWatcher() {
        watcher.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                Task {
                    await self.handleFileChange(change)
                }
            }
            .store(in: &cancellables)

        watcher.changes
            .compactMap { change -> Void? in
                if case .configChanged = change { return () }
                return nil
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.loadConfig() }
            }
            .store(in: &cancellables)

        if !watcher.start() {
            NSLog("[Copiscope] File watcher failed to start.")
        }
    }

    private func performInitialScan() {
        Task {
            var vsWorkspaces: [Workspace] = []
            var vsSessions: [String: [SessionSummary]] = [:]

            for (i, dir) in vscodeUserDirs.enumerated() {
                let sc = WorkspaceScanner(vscodeUserDir: dir, parser: parser, otelReader: otelReader)
                let (ws, ss): ([Workspace], [String: [SessionSummary]])
                if i == 0 {
                    (ws, ss) = await sc.scan { [weak self] processed, total in
                        self?.scanSessionsProcessed = processed
                        self?.scanSessionsTotal = total
                    }
                } else {
                    (ws, ss) = await sc.scan()
                }
                vsWorkspaces += ws
                vsSessions.merge(ss) { $0 + $1 }
            }

            let (cliWorkspaces, cliSessions) = await cliScanner.scan()

            self.workspaces = (vsWorkspaces + cliWorkspaces)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.sessionsByWorkspace = vsSessions.merging(cliSessions) { $0 + $1 }
            self.updatePersistedTokenCache()
            self.applyCachedTokenData()
            self.populateTodayTokens()
            self.isLoading = false
            self.checkActiveSession()
            self.recomputeAnalytics()
        }
    }

    private func handleFileChange(_ change: FileChange) async {
        switch change {
        case .sessionUpdated(let url), .sessionCreated(let url):
            let sessionId = url.deletingPathExtension().lastPathComponent

            // Derive workspaceId from path
            let components = url.pathComponents
            let workspaceId: String
            if let wsIdx = components.lastIndex(of: "workspaceStorage"),
               wsIdx + 1 < components.count {
                workspaceId = components[wsIdx + 1]
            } else {
                workspaceId = "unknown"
            }

            await cache.invalidate(sessionId)

            do {
                let isChatSession = url.pathComponents.contains("chatSessions")
                var summary: SessionSummary
                if isChatSession {
                    summary = try await parser.parseMetadataChatSession(
                        url: url,
                        sessionId: sessionId,
                        workspaceId: workspaceId
                    )
                } else {
                    summary = try await parser.parseMetadata(
                        url: url,
                        sessionId: sessionId,
                        workspaceId: workspaceId
                    )
                }

                // Enrich with OTEL data
                if let reader = otelReader {
                    let tokenData = reader.tokenData(forSession: sessionId)
                    if tokenData.todayInputTokens > 0 || tokenData.todayOutputTokens > 0 {
                        self.todayTokensBySession[sessionId] = (
                            tokenData.todayInputTokens,
                            tokenData.todayOutputTokens,
                            tokenData.todayCachedTokens
                        )
                    }
                    if tokenData.chatSpanCount > 0 {
                        let breakdown = tokenData.spanBreakdown.map { b in
                            ModelUsageBreakdown(
                                model: b.model,
                                vendor: b.vendor,
                                inputTokens: b.inputTokens,
                                outputTokens: b.outputTokens,
                                cachedTokens: b.cachedTokens,
                                reasoningTokens: b.reasoningTokens,
                                estimatedCost: estimateCostFromTokens(
                                    model: b.model,
                                    inputTokens: b.inputTokens,
                                    outputTokens: b.outputTokens,
                                    cachedTokens: b.cachedTokens
                                ),
                                requestCount: b.spanCount,
                                multiplierCost: 0,
                                turnCount: b.spanCount
                            )
                        }
                        let totalCost = breakdown.reduce(0) { $0 + $1.estimatedCost }
                        let primaryModel = tokenData.spanBreakdown.max(by: { $0.spanCount < $1.spanCount })?.model
                        summary = SessionSummary(
                            id: summary.id,
                            workspaceId: summary.workspaceId,
                            title: summary.title,
                            firstTimestamp: summary.firstTimestamp,
                            lastTimestamp: summary.lastTimestamp,
                            messageCount: summary.messageCount,
                            primaryModel: primaryModel ?? summary.primaryModel,
                            vendor: tokenData.providers.first,
                            turnCount: summary.turnCount,
                            toolCallCount: summary.toolCallCount,
                            hasError: summary.hasError,
                            observability: summary.observability,
                            totalInputTokens: tokenData.totalInputTokens,
                            totalOutputTokens: tokenData.totalOutputTokens,
                            totalCachedTokens: tokenData.totalCachedTokens,
                            totalReasoningTokens: tokenData.totalReasoningTokens,
                            estimatedCost: totalCost,
                            premiumRequestCount: tokenData.chatSpanCount,
                            totalMultiplierCost: 0,
                            modelBreakdown: breakdown
                        )
                    }
                }

                var sessions = self.sessionsByWorkspace[workspaceId] ?? []
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                    sessions[idx] = summary
                } else {
                    sessions.insert(summary, at: 0)
                }
                self.sessionsByWorkspace[workspaceId] = sessions

                if !self.workspaces.contains(where: { $0.id == workspaceId }) {
                    // Resolve workspace name from workspace.json (two levels up from chatSessions/transcripts dir)
                    let hashDir = url.deletingLastPathComponent().deletingLastPathComponent()
                    let fm2 = FileManager.default
                    var resolvedName = workspaceId
                    var resolvedWorkspacePath: String? = nil
                    if let wjData = fm2.contents(atPath: hashDir.appendingPathComponent("workspace.json").path),
                       let wjJson = try? JSONSerialization.jsonObject(with: wjData) as? [String: Any],
                       let folder = wjJson["folder"] as? String {
                        let folderURL = URL(string: folder) ?? URL(fileURLWithPath: folder)
                        resolvedName = folderURL.lastPathComponent
                        resolvedWorkspacePath = folderURL.path
                    }
                    let workspace = Workspace(
                        id: workspaceId,
                        name: resolvedName,
                        path: hashDir.deletingLastPathComponent().path,
                        workspacePath: resolvedWorkspacePath,
                        sessionCount: sessions.count
                    )
                    self.workspaces.append(workspace)
                    self.workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }

                self.checkActiveSession()
                self.recomputeAnalytics()
            } catch {
                NSLog("[Copiscope] Watcher: failed to parse session %@: %@",
                      sessionId, error.localizedDescription)
            }

            self.lintResultsValid = false
            // Mark this session as needing OTEL re-enrichment once the DB catches up
            pendingOtelEnrichment.insert(sessionId)

        case .configChanged:
            break

        case .otelDbChanged:
            // If the reader wasn't initialized (DB didn't exist at launch), try now
            if otelReader == nil, FileManager.default.fileExists(atPath: otelDbPath) {
                otelReader = OtelSpanReader(dbPath: otelDbPath)
                rescanAllSessions()
                return
            }
            // Re-enrich any sessions whose JSONL was updated since the last DB write.
            // This closes the race condition where the JSONL is written before the OTEL span.
            guard let reader = otelReader, !pendingOtelEnrichment.isEmpty else { return }
            let ids = pendingOtelEnrichment
            pendingOtelEnrichment.removeAll()
            for sessionId in ids {
                let tokenData = reader.tokenData(forSession: sessionId)
                if tokenData.todayInputTokens > 0 || tokenData.todayOutputTokens > 0 {
                    todayTokensBySession[sessionId] = (
                        tokenData.todayInputTokens,
                        tokenData.todayOutputTokens,
                        tokenData.todayCachedTokens
                    )
                }
                guard tokenData.chatSpanCount > 0 else { continue }
                for (wsId, var sessions) in sessionsByWorkspace {
                    guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { continue }
                    let existing = sessions[idx]
                    let breakdown = tokenData.spanBreakdown.map { b in
                        ModelUsageBreakdown(
                            model: b.model, vendor: b.vendor,
                            inputTokens: b.inputTokens, outputTokens: b.outputTokens,
                            cachedTokens: b.cachedTokens, reasoningTokens: b.reasoningTokens,
                            estimatedCost: estimateCostFromTokens(
                                model: b.model, inputTokens: b.inputTokens,
                                outputTokens: b.outputTokens, cachedTokens: b.cachedTokens
                            ),
                            requestCount: b.spanCount, multiplierCost: 0, turnCount: b.spanCount
                        )
                    }
                    let totalCost = breakdown.reduce(0) { $0 + $1.estimatedCost }
                    let primaryModel = tokenData.spanBreakdown.max(by: { $0.spanCount < $1.spanCount })?.model
                    sessions[idx] = SessionSummary(
                        id: existing.id, workspaceId: existing.workspaceId, title: existing.title,
                        firstTimestamp: existing.firstTimestamp, lastTimestamp: existing.lastTimestamp,
                        messageCount: existing.messageCount,
                        primaryModel: primaryModel ?? existing.primaryModel,
                        vendor: tokenData.providers.first,
                        turnCount: existing.turnCount, toolCallCount: existing.toolCallCount,
                        hasError: existing.hasError, observability: existing.observability,
                        totalInputTokens: tokenData.totalInputTokens,
                        totalOutputTokens: tokenData.totalOutputTokens,
                        totalCachedTokens: tokenData.totalCachedTokens,
                        totalReasoningTokens: tokenData.totalReasoningTokens,
                        estimatedCost: totalCost,
                        premiumRequestCount: tokenData.chatSpanCount,
                        totalMultiplierCost: 0,
                        modelBreakdown: breakdown
                    )
                    sessionsByWorkspace[wsId] = sessions
                    break
                }
            }
            updatePersistedTokenCache()
            populateTodayTokens()
            recomputeAnalytics()

        case .mustRescan:
            rescanAllSessions()

        case .cliSessionCreated(let sessionId), .cliSessionUpdated(let sessionId):
            let eventsURL = cliStateDir
                .appendingPathComponent(sessionId)
                .appendingPathComponent("events.jsonl")
            let yamlURL = cliStateDir
                .appendingPathComponent(sessionId)
                .appendingPathComponent("workspace.yaml")
            guard let yaml = CLIWorkspaceYAML.parse(from: yamlURL) else { return }
            let workspaceId = "cli::" + yaml.cwd

            await cache.invalidate(sessionId)

            do {
                let summary = try await parser.parseMetadataCLI(eventsURL: eventsURL, yaml: yaml)

                var sessions = self.sessionsByWorkspace[workspaceId] ?? []
                if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
                    sessions[idx] = summary
                } else {
                    sessions.insert(summary, at: 0)
                }
                self.sessionsByWorkspace[workspaceId] = sessions

                if !self.workspaces.contains(where: { $0.id == workspaceId }) {
                    let cwd = yaml.cwd
                    let folderName = URL(fileURLWithPath: cwd).lastPathComponent
                    self.workspaces.append(Workspace(
                        id: workspaceId,
                        name: folderName.isEmpty ? cwd : folderName,
                        path: cwd,
                        workspacePath: cwd,
                        sessionCount: sessions.count,
                        source: .cli
                    ))
                    self.workspaces.sort {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }

                self.checkActiveSession()
                self.recomputeAnalytics()
            } catch {
                NSLog("[Copiscope] Watcher: failed to parse CLI session %@: %@",
                      sessionId, error.localizedDescription)
            }

            self.lintResultsValid = false
        }
    }

    private func checkActiveSession() {
        let now = Date()
        hasActiveSession = allSessionsWithWorkspaces.contains { pair in
            guard let date = ISO8601.parse(pair.session.lastTimestamp) else { return false }
            return now.timeIntervalSince(date) < 60
        }
    }

    func rescanAllSessions() {
        Task {
            var vsWorkspaces: [Workspace] = []
            var vsSessions: [String: [SessionSummary]] = [:]

            for dir in vscodeUserDirs {
                let sc = WorkspaceScanner(vscodeUserDir: dir, parser: parser, otelReader: otelReader)
                let (ws, ss) = await sc.scan()
                vsWorkspaces += ws
                vsSessions.merge(ss) { $0 + $1 }
            }

            let (cliWorkspaces, cliSessions) = await cliScanner.scan()

            self.workspaces = (vsWorkspaces + cliWorkspaces)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.sessionsByWorkspace = vsSessions.merging(cliSessions) { $0 + $1 }
            self.updatePersistedTokenCache()
            self.applyCachedTokenData()
            self.recomputeAnalytics()
        }
    }

    // MARK: - Token data persistence

    /// Save any session with real token data to the on-disk cache.
    private func updatePersistedTokenCache() {
        var changed = false
        for (_, sessions) in sessionsByWorkspace {
            for session in sessions {
                guard session.totalInputTokens > 0 || session.totalOutputTokens > 0 else { continue }
                let entry = PersistedTokenData(
                    totalInputTokens: session.totalInputTokens,
                    totalOutputTokens: session.totalOutputTokens,
                    totalCachedTokens: session.totalCachedTokens,
                    totalReasoningTokens: session.totalReasoningTokens,
                    estimatedCost: session.estimatedCost,
                    premiumRequestCount: session.premiumRequestCount,
                    primaryModel: session.primaryModel,
                    vendor: session.vendor,
                    modelBreakdown: session.modelBreakdown.map { b in
                        PersistedModelBreakdown(
                            model: b.model, vendor: b.vendor,
                            inputTokens: b.inputTokens, outputTokens: b.outputTokens,
                            cachedTokens: b.cachedTokens, reasoningTokens: b.reasoningTokens,
                            estimatedCost: b.estimatedCost, spanCount: b.requestCount
                        )
                    }
                )
                if persistedTokenCache[session.id] != entry {
                    persistedTokenCache[session.id] = entry
                    changed = true
                }
            }
        }
        if changed {
            SessionTokenPersistence.shared.save(persistedTokenCache)
        }
    }

    /// Fill in token data from disk cache for sessions the OTEL DB no longer covers.
    /// Queries OTEL for today-only token sub-totals for sessions active today.
    /// Only runs against sessions whose lastTimestamp is today — typically 1–3 sessions.
    private func populateTodayTokens() {
        guard let reader = otelReader else { return }
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        let todayStart = Calendar.current.startOfDay(for: Date())

        for sessions in sessionsByWorkspace.values {
            for session in sessions {
                let lastDate = isoFull.date(from: session.lastTimestamp)
                    ?? isoBasic.date(from: session.lastTimestamp)
                guard let d = lastDate, d >= todayStart else { continue }
                let td = reader.tokenData(forSession: session.id)
                if td.todayInputTokens > 0 || td.todayOutputTokens > 0 {
                    todayTokensBySession[session.id] = (td.todayInputTokens, td.todayOutputTokens, td.todayCachedTokens)
                }
            }
        }
    }

    private func applyCachedTokenData() {
        for (wsId, var sessions) in sessionsByWorkspace {
            var changed = false
            for i in sessions.indices {
                let s = sessions[i]
                guard s.totalInputTokens == 0, s.totalOutputTokens == 0,
                      let cached = persistedTokenCache[s.id]
                else { continue }
                sessions[i] = SessionSummary(
                    id: s.id, workspaceId: s.workspaceId, title: s.title,
                    firstTimestamp: s.firstTimestamp, lastTimestamp: s.lastTimestamp,
                    messageCount: s.messageCount,
                    primaryModel: cached.primaryModel ?? s.primaryModel,
                    vendor: cached.vendor ?? s.vendor,
                    turnCount: s.turnCount, toolCallCount: s.toolCallCount,
                    hasError: s.hasError, observability: s.observability,
                    totalInputTokens: cached.totalInputTokens,
                    totalOutputTokens: cached.totalOutputTokens,
                    totalCachedTokens: cached.totalCachedTokens,
                    totalReasoningTokens: cached.totalReasoningTokens,
                    estimatedCost: cached.estimatedCost,
                    premiumRequestCount: cached.premiumRequestCount,
                    totalMultiplierCost: 0,
                    modelBreakdown: cached.modelBreakdown.map { b in
                        ModelUsageBreakdown(
                            model: b.model, vendor: b.vendor,
                            inputTokens: b.inputTokens, outputTokens: b.outputTokens,
                            cachedTokens: b.cachedTokens, reasoningTokens: b.reasoningTokens,
                            estimatedCost: b.estimatedCost, requestCount: b.spanCount,
                            multiplierCost: 0, turnCount: b.spanCount
                        )
                    }
                )
                changed = true
            }
            if changed { sessionsByWorkspace[wsId] = sessions }
        }
    }

    func recomputeAnalytics() {
        let (fromDate, toDate) = analyticsTimeRange.dateRange(
            customFrom: analyticsCustomFrom, customTo: analyticsCustomTo
        )

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var totalSessions = 0
        var totalMessages = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCachedTokens = 0
        var totalCost = 0.0
        var dailyMap: [String: DailyUsage] = [:]
        var workspaceCostMap: [String: WorkspaceCost] = [:]
        var modelMap: [String: ModelUsage] = [:]

        // Cache analytics accumulators
        var totalCacheReadTokens = 0
        var totalCacheSavings = 0.0
        var totalHypotheticalCost = 0.0
        var sessionCacheEfficiencies: [SessionCacheEfficiency] = []
        var modelCacheReadMap: [String: Int] = [:]
        var modelCacheSavingsMap: [String: Double] = [:]
        var dailyCacheReadMap: [String: Int] = [:]
        var dailyInputTokenMap: [String: Int] = [:]

        // Model cost / daily-model-cost accumulators
        var modelCostMap: [String: Double] = [:]
        var dailyModelCostAccum: [String: [String: Double]] = [:]

        // Latency accumulators (session-level medians used as proxy for turn distributions)
        var sessionMedianDurations: [Double] = []
        var sessionMaxDurations: [(sessionId: String, title: String, maxMs: Double, ttftMs: Double?, model: String?)] = []

        let todayStart = Calendar.current.startOfDay(for: Date())
        var todaySessionCountLocal = 0
        var todayTokensLocal = 0
        var todayCostLocal = 0.0
        var todayWorkspaceIdsLocal = Set<String>()

        for workspace in workspaces {
            let sessions = sessionsByWorkspace[workspace.id] ?? []
            for session in sessions {
                // lastTimestamp: used for daily bar-chart bucketing and "today" activity check.
                let date = isoFull.date(from: session.lastTimestamp)
                    ?? isoBasic.date(from: session.lastTimestamp)

                // Range filter uses firstTimestamp — a session belongs to the period it STARTED.
                // This prevents cross-day sessions from inflating shorter ranges.
                let filterDate = isoFull.date(from: session.firstTimestamp)
                    ?? isoBasic.date(from: session.firstTimestamp)
                    ?? date  // fallback to lastTimestamp if firstTimestamp is empty

                // "Today" stats: use per-span today sub-totals when available (accurate cost for
                // sessions that cross the calendar day boundary). Fall back to full session total.
                if let d = date, d >= todayStart {
                    todaySessionCountLocal += 1
                    if let todayToks = todayTokensBySession[session.id] {
                        todayTokensLocal += todayToks.input + todayToks.output
                        // Re-estimate cost from today's token split using the session's model breakdown
                        let todayCost = session.modelBreakdown.isEmpty
                            ? estimateCostFromTokens(
                                model: session.primaryModel ?? "unknown",
                                inputTokens: todayToks.input,
                                outputTokens: todayToks.output,
                                cachedTokens: todayToks.cached
                              )
                            : session.modelBreakdown.reduce(0.0) { acc, b in
                                // Apportion cost by output token ratio (best proxy available without per-span breakdown)
                                let sessionOut = session.totalOutputTokens > 0 ? session.totalOutputTokens : 1
                                let ratio = Double(b.outputTokens) / Double(sessionOut)
                                let todayModelOut = Int(Double(todayToks.output) * ratio)
                                let todayModelIn  = Int(Double(todayToks.input) * ratio)
                                let todayModelCached = Int(Double(todayToks.cached) * ratio)
                                return acc + estimateCostFromTokens(
                                    model: b.model,
                                    inputTokens: todayModelIn,
                                    outputTokens: todayModelOut,
                                    cachedTokens: todayModelCached
                                )
                              }
                        todayCostLocal += todayCost
                    } else {
                        todayTokensLocal += session.totalInputTokens + session.totalOutputTokens
                        todayCostLocal += session.estimatedCost
                    }
                    todayWorkspaceIdsLocal.insert(workspace.id)
                }

                // Workspace filter: if the user has selected a specific workspace,
                // skip sessions that don't belong to it. Today-stats above are
                // intentionally kept unfiltered (they power sidebar activity badges).
                if let selectedId = selectedWorkspaceId, workspace.id != selectedId { continue }

                if let from = fromDate, let to = toDate {
                    // Custom / multi-day ranges: use firstTimestamp (session belongs to period it started)
                    guard let d = filterDate, d >= from, d < to else { continue }
                } else if let from = fromDate {
                    // "Today" / "7d" / "30d": for today's range use lastTimestamp so
                    // sessions active today (even if started yesterday) are included.
                    // For multi-day ranges keep firstTimestamp to avoid double-counting.
                    let rangeDate = (analyticsTimeRange == .today) ? date : filterDate
                    guard let d = rangeDate, d >= from else { continue }
                }

                totalSessions += 1
                totalMessages += session.messageCount
                totalInputTokens += session.totalInputTokens
                totalOutputTokens += session.totalOutputTokens
                totalCachedTokens += session.totalCachedTokens
                totalCost += session.estimatedCost

                // Daily aggregation — bucket by lastTimestamp so the bar chart shows
                // when work actually happened, not just session creation date
                let dayKey = date.map { dayFormatter.string(from: $0) } ?? "Unknown"
                if dailyMap[dayKey] == nil {
                    dailyMap[dayKey] = DailyUsage(
                        date: dayKey, inputTokens: 0, outputTokens: 0,
                        cacheReadTokens: 0, cacheCreationTokens: 0,
                        sessionCount: 0, messageCount: 0, estimatedCost: 0,
                        premiumRequests: 0, multiplierCost: 0
                    )
                }
                dailyMap[dayKey]!.sessionCount += 1
                dailyMap[dayKey]!.messageCount += session.messageCount
                dailyMap[dayKey]!.inputTokens += session.totalInputTokens
                dailyMap[dayKey]!.outputTokens += session.totalOutputTokens
                dailyMap[dayKey]!.cacheReadTokens += session.totalCachedTokens
                dailyMap[dayKey]!.estimatedCost += session.estimatedCost
                dailyMap[dayKey]!.premiumRequests += session.premiumRequestCount
                dailyMap[dayKey]!.multiplierCost += session.totalMultiplierCost

                // Workspace aggregation
                if workspaceCostMap[workspace.id] == nil {
                    workspaceCostMap[workspace.id] = WorkspaceCost(
                        workspaceId: workspace.id, workspaceName: workspace.name,
                        totalCost: 0, totalTokens: 0, sessionCount: 0,
                        messageCount: 0, premiumRequests: 0
                    )
                }
                workspaceCostMap[workspace.id]!.totalCost += session.estimatedCost
                workspaceCostMap[workspace.id]!.totalTokens += session.totalInputTokens + session.totalOutputTokens
                workspaceCostMap[workspace.id]!.sessionCount += 1
                workspaceCostMap[workspace.id]!.messageCount += session.messageCount
                workspaceCostMap[workspace.id]!.premiumRequests += session.premiumRequestCount

                // Model aggregation — prefer breakdown, fall back to primaryModel
                if session.modelBreakdown.isEmpty, let model = session.primaryModel {
                    if modelMap[model] == nil {
                        modelMap[model] = ModelUsage(
                            model: model, vendor: session.vendor ?? "copilot",
                            turnCount: 0, totalInputTokens: 0, totalOutputTokens: 0, totalCachedTokens: 0
                        )
                    }
                    modelMap[model]!.turnCount += session.turnCount
                    modelMap[model]!.totalInputTokens += session.totalInputTokens
                    modelMap[model]!.totalOutputTokens += session.totalOutputTokens
                    modelMap[model]!.totalCachedTokens += session.totalCachedTokens
                    // Model cost
                    modelCostMap[model, default: 0] += session.estimatedCost
                    dailyModelCostAccum[dayKey, default: [:]][model, default: 0] += session.estimatedCost
                } else {
                    for b in session.modelBreakdown {
                        if modelMap[b.model] == nil {
                            modelMap[b.model] = ModelUsage(
                                model: b.model, vendor: b.vendor,
                                turnCount: 0, totalInputTokens: 0, totalOutputTokens: 0, totalCachedTokens: 0
                            )
                        }
                        modelMap[b.model]!.turnCount += b.turnCount
                        modelMap[b.model]!.totalInputTokens += b.inputTokens
                        modelMap[b.model]!.totalOutputTokens += b.outputTokens
                        modelMap[b.model]!.totalCachedTokens += b.cachedTokens
                        // Model cost
                        modelCostMap[b.model, default: 0] += b.estimatedCost
                        dailyModelCostAccum[dayKey, default: [:]][b.model, default: 0] += b.estimatedCost
                    }
                }

                // Cache analytics aggregation
                let cacheRead = session.totalCachedTokens
                totalCacheReadTokens += cacheRead
                dailyCacheReadMap[dayKey, default: 0] += cacheRead
                dailyInputTokenMap[dayKey, default: 0] += session.totalInputTokens

                // Cost savings: difference between paying full input price vs cached price
                let sessionSavings: Double
                if session.modelBreakdown.isEmpty {
                    let p = PricingTables.pricing(for: session.primaryModel)
                    sessionSavings = Double(cacheRead) / 1e6 * (p.input - p.cacheRead)
                    totalHypotheticalCost += Double(session.totalInputTokens) / 1e6 * p.input
                                          + Double(session.totalOutputTokens) / 1e6 * p.output
                    if cacheRead > 0 {
                        modelCacheReadMap[session.primaryModel ?? "unknown", default: 0] += cacheRead
                        modelCacheSavingsMap[session.primaryModel ?? "unknown", default: 0] += max(0, sessionSavings)
                    }
                } else {
                    var bSavingsTotal = 0.0
                    for b in session.modelBreakdown {
                        let bp = PricingTables.pricing(for: b.model)
                        let bSavings = Double(b.cachedTokens) / 1e6 * (bp.input - bp.cacheRead)
                        bSavingsTotal += bSavings
                        totalHypotheticalCost += Double(b.inputTokens) / 1e6 * bp.input
                                              + Double(b.outputTokens) / 1e6 * bp.output
                        if b.cachedTokens > 0 {
                            modelCacheReadMap[b.model, default: 0] += b.cachedTokens
                            modelCacheSavingsMap[b.model, default: 0] += max(0, bSavings)
                        }
                    }
                    sessionSavings = bSavingsTotal
                }
                totalCacheSavings += max(0, sessionSavings)

                if cacheRead > 0 {
                    let hitRatioForSession = session.totalInputTokens > 0
                        ? Double(cacheRead) / Double(session.totalInputTokens)
                        : 0
                    sessionCacheEfficiencies.append(SessionCacheEfficiency(
                        sessionId: session.id,
                        sessionTitle: session.title,
                        hitRatio: hitRatioForSession,
                        cacheReadTokens: cacheRead,
                        savingsAmount: max(0, sessionSavings),
                        primaryModel: session.primaryModel
                    ))
                }

                // Latency aggregation (session-level proxy — individual turns not in summaries)
                if let med = session.observability.medianTurnDurationMs {
                    sessionMedianDurations.append(med)
                }
                if let maxDur = session.observability.maxTurnDurationMs {
                    sessionMaxDurations.append((
                        sessionId: session.id,
                        title: session.title,
                        maxMs: maxDur,
                        ttftMs: session.observability.medianTtftMs,
                        model: session.primaryModel
                    ))
                }
            }
        }

        // MARK: Build derived analytics

        // --- Cache ---
        let overallHitRatio = totalInputTokens > 0
            ? Double(totalCacheReadTokens) / Double(totalInputTokens) : 0
        let avgReuseRate = totalSessions > 0
            ? Double(totalCacheReadTokens) / Double(totalSessions) / 1000.0 : 0
        let dailyHitRatios: [(date: String, ratio: Double)] = dailyCacheReadMap.keys.sorted().map { day in
            let input = max(1, dailyInputTokenMap[day] ?? 1)
            return (date: day, ratio: Double(dailyCacheReadMap[day] ?? 0) / Double(input))
        }
        let modelSavingsList: [ModelCacheSavings] = modelCacheReadMap.keys.sorted().compactMap { m in
            guard let reads = modelCacheReadMap[m], reads > 0 else { return nil }
            let bp = PricingTables.pricing(for: m)
            return ModelCacheSavings(
                model: m,
                cacheReadTokens: reads,
                savingsPerMTok: bp.input - bp.cacheRead,
                totalSavings: modelCacheSavingsMap[m] ?? 0
            )
        }
        let builtCacheAnalytics = CacheAnalytics(
            hitRatio: overallHitRatio,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheWriteTokens: 0,
            costSavings: totalCacheSavings,
            hypotheticalUncachedCost: totalHypotheticalCost,
            actualCost: totalCost,
            averageReuseRate: avgReuseRate,
            cacheBustingDays: [],
            totalCache5mTokens: 0,
            totalCache1hTokens: 0,
            tierCostBreakdown: .empty,
            dailyHitRatio: dailyHitRatios,
            sessionEfficiency: sessionCacheEfficiencies.sorted { $0.savingsAmount > $1.savingsAmount },
            modelSavings: modelSavingsList.sorted { $0.totalSavings > $1.totalSavings }
        )

        // --- Model Efficiency ---
        let builtModelEfficiency: [ModelEfficiencyRow] = modelMap.values.map { m in
            let cost = modelCostMap[m.model] ?? 0
            return ModelEfficiencyRow(
                model: m.model,
                vendor: m.vendor,
                turnCount: m.turnCount,
                totalOutputTokens: m.totalOutputTokens,
                avgOutputPerTurn: m.turnCount > 0 ? m.totalOutputTokens / m.turnCount : 0,
                totalCost: cost,
                costPerTurn: m.turnCount > 0 ? cost / Double(m.turnCount) : 0,
                percentOfTotalCost: totalCost > 0 ? cost / totalCost * 100 : 0,
                avgTtftMs: nil
            )
        }.sorted { $0.totalCost > $1.totalCost }

        var builtDailyModelCost: [DailyModelCost] = []
        for (day, modelCosts) in dailyModelCostAccum {
            for (model, cost) in modelCosts where cost > 0 {
                builtDailyModelCost.append(DailyModelCost(date: day, model: model, cost: cost))
            }
        }
        builtDailyModelCost.sort { $0.date < $1.date }

        // --- Latency ---
        let builtLatency: LatencyAnalytics
        if sessionMedianDurations.isEmpty {
            builtLatency = .empty
        } else {
            let sorted = sessionMedianDurations.sorted()
            let median = analyticsPercentile(sorted, 0.50)
            let p95    = analyticsPercentile(sorted, 0.95)
            let p99    = analyticsPercentile(sorted, 0.99)
            let histogram = analyticsLatencyHistogram(sorted)
            let slowest = sessionMaxDurations
                .sorted { $0.maxMs > $1.maxMs }
                .prefix(10)
                .map { e in
                    SlowTurnEntry(
                        id: e.sessionId,
                        sessionId: e.sessionId,
                        sessionTitle: e.title,
                        turnIndex: 0,
                        durationMs: e.maxMs,
                        ttftMs: e.ttftMs,
                        model: e.model
                    )
                }
            builtLatency = LatencyAnalytics(
                medianDurationMs: median,
                p95DurationMs: p95,
                p99DurationMs: p99,
                histogram: histogram,
                slowestTurns: Array(slowest),
                medianTtftMs: 0,
                p95TtftMs: 0,
                ttftByModel: []
            )
        }

        analyticsData = AnalyticsData(
            totalSessions: totalSessions,
            totalMessages: totalMessages,
            totalTokens: totalInputTokens + totalOutputTokens,
            totalCacheTokens: totalCachedTokens,
            totalCost: totalCost,
            dailyUsage: dailyMap.values.sorted { $0.date < $1.date },
            workspaceCosts: workspaceCostMap.values.sorted { $0.totalCost > $1.totalCost },
            modelUsage: modelMap.values.sorted { $0.turnCount > $1.turnCount },
            cacheAnalytics: builtCacheAnalytics,
            modelEfficiency: builtModelEfficiency,
            dailyModelCost: builtDailyModelCost,
            latencyAnalytics: builtLatency,
            vendorAnalytics: .empty,
            parallelToolAnalytics: .empty,
            billingAnalytics: .empty
        )

        todaySessionCount = todaySessionCountLocal
        todayTokens = todayTokensLocal
        todayCost = todayCostLocal
        todayWorkspaceCount = todayWorkspaceIdsLocal.count
    }

    func loadSession(id: String, workspaceId: String) async {
        if let cached = await cache.get(id) {
            self.selectedSession = cached
            return
        }

        // CLI session: load from ~/.copilot/session-state/{id}/events.jsonl
        if workspaceId.hasPrefix("cli::") {
            let eventsURL = cliStateDir
                .appendingPathComponent(id)
                .appendingPathComponent("events.jsonl")
            do {
                let base = try await parser.parse(url: eventsURL, sessionId: id, workspaceId: workspaceId)
                let parsed = ParsedSession(
                    id: base.id, workspaceId: base.workspaceId,
                    records: base.records, toolResultMap: base.toolResultMap,
                    metadata: base.metadata, tokenData: base.tokenData,
                    source: .cli
                )
                await cache.set(id, value: parsed)
                self.selectedSession = parsed
            } catch {
                NSLog("[Copiscope] Failed to load CLI session %@: %@", id, error.localizedDescription)
            }
            return
        }

        let fm = FileManager.default
        var useTranscript = false
        var fileURL: URL? = nil

        // Search across all VS Code dirs (stable, Insiders, etc.)
        for dir in vscodeUserDirs {
            let t = dir
                .appendingPathComponent("workspaceStorage")
                .appendingPathComponent(workspaceId)
                .appendingPathComponent("GitHub.copilot-chat/transcripts/\(id).jsonl")
            let c = dir
                .appendingPathComponent("workspaceStorage")
                .appendingPathComponent(workspaceId)
                .appendingPathComponent("chatSessions/\(id).jsonl")
            if fm.fileExists(atPath: t.path) {
                fileURL = t; useTranscript = true; break
            } else if fm.fileExists(atPath: c.path) {
                fileURL = c; useTranscript = false; break
            }
        }
        guard let fileURL else {
            NSLog("[Copiscope] Session file not found for %@ in any VS Code dir", id)
            return
        }

        do {
            var parsed: ParsedSession
            if useTranscript {
                parsed = try await parser.parse(url: fileURL, sessionId: id, workspaceId: workspaceId)
            } else {
                parsed = try await parser.parseChatSession(url: fileURL, sessionId: id, workspaceId: workspaceId)
            }

            // Enrich with OTEL token data
            if let reader = otelReader {
                let tokenData = reader.tokenData(forSession: id)
                parsed = ParsedSession(
                    id: parsed.id,
                    workspaceId: parsed.workspaceId,
                    records: parsed.records,
                    toolResultMap: parsed.toolResultMap,
                    metadata: parsed.metadata,
                    tokenData: tokenData
                )
            }

            await cache.set(id, value: parsed)
            self.selectedSession = parsed
        } catch {
            NSLog("[Copiscope] Failed to load session %@: %@", id, error.localizedDescription)
        }
    }

    // MARK: - Timeline

    func loadTimeline() async {
        timelineLoading = true
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        var entries: [HistoryEntry] = []
        for workspace in workspaces {
            let sessions = sessionsByWorkspace[workspace.id] ?? []
            for session in sessions {
                let date = isoFull.date(from: session.firstTimestamp)
                    ?? isoBasic.date(from: session.firstTimestamp)
                    ?? Date.distantPast
                entries.append(HistoryEntry(
                    id: session.id,
                    type: "session",
                    sessionId: session.id,
                    workspace: workspace.name,
                    workspaceId: workspace.id,
                    timestamp: date,
                    display: session.title
                ))
            }
        }

        entries.sort { $0.timestamp > $1.timestamp }
        timelineEntries = entries
        timelineLoading = false
    }

    // MARK: - Config

    func loadMemoryFiles(workspaceId: String? = nil) async {
        let fm = FileManager.default
        var files: [MemoryFile] = []

        // Resolve which workspace is selected
        let wsId = workspaceId

        // Global: files in VS Code User/globalStorage/github.copilot-chat/
        // (instructions, agent prompts used as "global" memory context)
        let globalDir = vscodeUserDir.appendingPathComponent("globalStorage/github.copilot-chat")

        func collectMd(in dir: URL, scope: String, label: String) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for item in items where item.hasSuffix(".md") {
                let url = dir.appendingPathComponent(item)
                let content = try? String(contentsOf: url, encoding: .utf8)
                let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                files.append(MemoryFile(
                    id: url.path,
                    label: item,
                    sublabel: "\(scope) · \(label)",
                    path: url.path,
                    content: content,
                    sizeBytes: bytes
                ))
            }
        }

        if wsId == nil {
            // Global scope — show agent.md files from globalStorage
            for subdir in ["ask-agent", "plan-agent", "explore-agent"] {
                let url = globalDir.appendingPathComponent(subdir)
                collectMd(in: url, scope: "global", label: subdir)
            }
        } else if let wsId, let workspace = workspaces.first(where: { $0.id == wsId }) {
            // Workspace scope — collect memory-related .md files
            let hashPath = vscodeUserDir
                .appendingPathComponent("workspaceStorage")
                .appendingPathComponent(wsId)
            guard let wsPath = resolveWorkspacePath(at: hashPath) else { return }
            let wsURL = URL(fileURLWithPath: wsPath)

            // Common memory dirs (memory-bank/, memories/, docs/memory/)
            let memoryDirs = ["memory-bank", "memories", "docs/memory", ".memory"]
            for dir in memoryDirs {
                let url = wsURL.appendingPathComponent(dir)
                if fm.fileExists(atPath: url.path) {
                    collectMd(in: url, scope: workspace.name, label: dir)
                }
            }

            // Instructions in .github/instructions/
            let instrDir = wsURL.appendingPathComponent(".github/instructions")
            if fm.fileExists(atPath: instrDir.path) {
                collectMd(in: instrDir, scope: workspace.name, label: ".github/instructions")
            }
        }

        memoryFiles = files
    }

    func loadConfig() async {
        configLoading = true
        let fm = FileManager.default
        var instructions: [InstructionEntry] = []
        var agents: [AgentEntry] = []
        var prompts: [PromptEntry] = []
        var mcpServers: [McpServerEntry] = []

        // --- Load VS Code settings ---
        vscodeSettings = loadVSCodeSettings()

        // --- CLI: ~/.copilot/copilot-instructions.md ---
        let cliInstrURL = cliStateDir.deletingLastPathComponent()
            .appendingPathComponent("copilot-instructions.md")
        if fm.fileExists(atPath: cliInstrURL.path) {
            let content = try? String(contentsOf: cliInstrURL, encoding: .utf8)
            let bytes = (try? fm.attributesOfItem(atPath: cliInstrURL.path)[.size] as? Int) ?? 0
            instructions.append(InstructionEntry(
                label: "copilot-instructions (CLI)",
                source: .user,
                path: cliInstrURL.path,
                content: content,
                sizeBytes: bytes,
                applyTo: nil
            ))
        }

        for vsDir in vscodeUserDirs {
        // --- User-level prompts directory ---
        let userPromptsDir = vsDir.appendingPathComponent("prompts")
        if let files = try? fm.contentsOfDirectory(atPath: userPromptsDir.path) {
            for file in files {
                let url = userPromptsDir.appendingPathComponent(file)
                let content = try? String(contentsOf: url, encoding: .utf8)
                let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if file.hasSuffix(".agent.md") || file.hasSuffix(".chatmode.md") {
                    let name = String(file.dropLast(file.hasSuffix(".chatmode.md") ? 11 : 9))
                    agents.append(AgentEntry(name: name, description: extractFrontmatterField("description", from: content), path: url.path, content: content, sizeBytes: bytes, tools: nil))
                } else if file.hasSuffix(".prompt.md") {
                    let name = String(file.dropLast(10))
                    prompts.append(PromptEntry(name: name, description: extractFrontmatterField("description", from: content), path: url.path, content: content, sizeBytes: bytes, mode: extractFrontmatterField("mode", from: content)))
                } else if file.hasSuffix(".instructions.md") {
                    let name = String(file.dropLast(16))
                    instructions.append(InstructionEntry(label: name, source: .file(name: file), path: url.path, content: content, sizeBytes: bytes, applyTo: extractFrontmatterField("applyTo", from: content)))
                }
            }
        }

        // --- Global Copilot storage agents (built-in and org agents) ---
        let globalCopilotDir = vsDir
            .appendingPathComponent("globalStorage/github.copilot-chat")
        for subdir in ["ask-agent", "plan-agent", "explore-agent"] {
            let url = globalCopilotDir.appendingPathComponent(subdir)
            if let files = try? fm.contentsOfDirectory(atPath: url.path) {
                for file in files where file.hasSuffix(".agent.md") {
                    let agentURL = url.appendingPathComponent(file)
                    let content = try? String(contentsOf: agentURL, encoding: .utf8)
                    let bytes = (try? fm.attributesOfItem(atPath: agentURL.path)[.size] as? Int) ?? 0
                    let name = String(file.dropLast(9))
                    agents.append(AgentEntry(name: name, description: extractFrontmatterField("description", from: content), path: agentURL.path, content: content, sizeBytes: bytes, tools: nil))
                }
            }
        }

        // --- User-level MCP config ---
        let userMcpURL = vsDir.appendingPathComponent("mcp.json")
        if let data = fm.contents(atPath: userMcpURL.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["servers"] as? [String: Any] {
            for (name, value) in servers {
                if let serverObj = value as? [String: Any] {
                    mcpServers.append(McpServerEntry(
                        name: name,
                        command: serverObj["command"] as? String,
                        args: serverObj["args"] as? [String] ?? [],
                        url: serverObj["url"] as? String,
                        env: serverObj["env"] as? [String: String] ?? [:],
                        source: "user"
                    ))
                }
            }
        }

        // --- Per-workspace scan (recursive walk) ---
        let workspaceStorageDir = vsDir.appendingPathComponent("workspaceStorage")
        if let hashDirs = try? fm.contentsOfDirectory(atPath: workspaceStorageDir.path) {
            for hashDir in hashDirs {
                let hashPath = workspaceStorageDir.appendingPathComponent(hashDir)
                guard let workspacePath = resolveWorkspacePath(at: hashPath) else { continue }
                guard fm.fileExists(atPath: workspacePath) else { continue }
                let workspaceURL = URL(fileURLWithPath: workspacePath)

                scanWorkspaceDirectory(workspaceURL, fm: fm,
                    instructions: &instructions, agents: &agents,
                    prompts: &prompts, mcpServers: &mcpServers)
            }
        }
        } // end for vsDir in vscodeUserDirs

        // Deduplicate by path
        self.instructions = dedupe(instructions, by: { $0.path ?? $0.label })
        self.agents = dedupe(agents, by: { $0.path })
        self.prompts = dedupe(prompts, by: { $0.path })
        self.mcpServers = dedupe(mcpServers, by: { $0.name })
        configLoading = false
    }

    private func extractFrontmatterField(_ field: String, from content: String?) -> String? {
        guard let content, content.hasPrefix("---") else { return nil }
        let lines = content.components(separatedBy: "\n")
        var inFrontmatter = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                if !inFrontmatter { inFrontmatter = true; continue }
                else { break }
            }
            if inFrontmatter, line.hasPrefix("\(field):") {
                return line.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private func dedupe<T>(_ items: [T], by key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    // MARK: - OTEL Setup

    /// Whether the two required OTEL settings are both enabled.
    var otelSetupComplete: Bool {
        vscodeSettings.otelEnabled == true && vscodeSettings.otelDbExporterEnabled == true
    }

    /// Writes `github.copilot.chat.otel.enabled` and
    /// `github.copilot.chat.otel.dbSpanExporter.enabled` into VS Code's settings.json.
    /// Returns true on success.
    @discardableResult
    func enableOtelSettings() -> Bool {
        let settingsURL = vscodeUserDir.appendingPathComponent("settings.json")
        let fm = FileManager.default

        // Read existing settings (or start empty)
        var json: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsURL.path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        json["github.copilot.chat.otel.enabled"] = true
        json["github.copilot.chat.otel.dbSpanExporter.enabled"] = true

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return false }

        do {
            try text.write(to: settingsURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Copiscope] Failed to write OTEL settings: %@", error.localizedDescription)
            return false
        }

        // Reload settings so the UI reflects the change immediately
        vscodeSettings = loadVSCodeSettings()
        return true
    }

    private func resolveWorkspacePath(at hashPath: URL) -> String? {
        let workspaceJsonPath = hashPath.appendingPathComponent("workspace.json")
        guard let data = FileManager.default.contents(atPath: workspaceJsonPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = json["folder"] as? String else { return nil }
        if folder.hasPrefix("file://") {
            return String(folder.dropFirst(7))
        }
        return URL(fileURLWithPath: folder).path
    }

    /// Load and parse the VS Code user settings.json into a structured model.
    private func loadVSCodeSettings() -> VSCodeSettings {
        var s = VSCodeSettings()

        // VS Code version from app bundle
        let productJson = "/Applications/Visual Studio Code.app/Contents/Resources/app/package.json"
        if let data = FileManager.default.contents(atPath: productJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            s.vscodeVersion = json["version"] as? String
        }
        // Copilot extension version
        let copilotPkg = "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/copilot/package.json"
        if let data = FileManager.default.contents(atPath: copilotPkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            s.copilotVersion = json["version"] as? String
        }

        // Parse settings.json
        let settingsPath = vscodeUserDir.appendingPathComponent("settings.json")
        guard let data = FileManager.default.contents(atPath: settingsPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }

        s.selectedCompletionModel = json["github.copilot.selectedCompletionModel"] as? String
        s.enabledLanguages = json["github.copilot.enable"] as? [String: Bool] ?? [:]
        s.nextEditSuggestionsEnabled = json["github.copilot.nextEditSuggestions.enabled"] as? Bool
        s.maxRequests = json["chat.agent.maxRequests"] as? Int
        s.memoryEnabled = json["github.copilot.chat.copilotMemory.enabled"] as? Bool
        s.nestedAgentsMd = json["chat.useNestedAgentsMdFiles"] as? Bool
        s.showOrgAgents = json["github.copilot.chat.customAgents.showOrganizationAndEnterpriseAgents"] as? Bool
        s.viewSessionsOrientation = json["chat.viewSessions.orientation"] as? String
        if let instrs = json["github.copilot.chat.codeGeneration.instructions"] as? [String] {
            s.codeGenerationInstructions = instrs
        }
        s.otelEnabled = json["github.copilot.chat.otel.enabled"] as? Bool
        s.otelExporterType = json["github.copilot.chat.otel.exporterType"] as? String
        s.otelEndpoint = json["github.copilot.chat.otel.otlpEndpoint"] as? String
        s.otelCaptureContent = json["github.copilot.chat.otel.captureContent"] as? Bool
        s.otelDbExporterEnabled = json["github.copilot.chat.otel.dbSpanExporter.enabled"] as? Bool
        s.agentDebugLogEnabled = json["github.copilot.chat.agentDebugLog.fileLogging.enabled"] as? Bool
        s.pluginMarketplaces = json["chat.plugins.marketplaces"] as? [String] ?? []
        s.mcpGalleryEnabled = json["chat.mcp.gallery.enabled"] as? Bool
        s.hookFileLocations = json["chat.hookFilesLocations"] as? [String: Bool] ?? [:]
        if let sampling = json["chat.mcp.serverSampling"] as? [String: Any] {
            s.mcpServerSampling = sampling.compactMapValues {
                ($0 as? [String: Any])?["allowedDuringChat"] as? Bool
            }
        }
        return s
    }

    /// Recursively walk a workspace directory and collect config files.
    /// Skips .git, node_modules, and other large unrelated dirs.
    private func scanWorkspaceDirectory(
        _ root: URL, fm: FileManager,
        instructions: inout [InstructionEntry],
        agents: inout [AgentEntry],
        prompts: inout [PromptEntry],
        mcpServers: inout [McpServerEntry]
    ) {
        let skipDirs: Set<String> = [".git", "node_modules", ".venv", "__pycache__", "vendor", "dist", "build", ".build"]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            // Skip large unrelated directories
            if let vals = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               vals.isDirectory == true,
               skipDirs.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            let file = url.lastPathComponent
            let content = try? String(contentsOf: url, encoding: .utf8)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            if file == "copilot-instructions.md" && url.pathComponents.contains(".github") {
                instructions.append(InstructionEntry(
                    label: "copilot-instructions", source: .workspace, path: url.path,
                    content: content, sizeBytes: bytes, applyTo: nil
                ))
            } else if file.hasSuffix(".instructions.md") {
                let name = String(file.dropLast(16))
                let src = InstructionSource.file(name: file)
                instructions.append(InstructionEntry(
                    label: name, source: src, path: url.path,
                    content: content, sizeBytes: bytes,
                    applyTo: extractFrontmatterField("applyTo", from: content)
                ))
            } else if file.hasSuffix(".agent.md") {
                let name = String(file.dropLast(9))
                agents.append(AgentEntry(
                    name: name,
                    description: extractFrontmatterField("description", from: content),
                    path: url.path, content: content, sizeBytes: bytes, tools: nil
                ))
            } else if file.hasSuffix(".chatmode.md") {
                let name = String(file.dropLast(12))
                agents.append(AgentEntry(
                    name: name,
                    description: extractFrontmatterField("description", from: content),
                    path: url.path, content: content, sizeBytes: bytes, tools: nil
                ))
            } else if file.hasSuffix(".prompt.md") {
                let name = String(file.dropLast(10))
                prompts.append(PromptEntry(
                    name: name,
                    description: extractFrontmatterField("description", from: content),
                    path: url.path, content: content, sizeBytes: bytes,
                    mode: extractFrontmatterField("mode", from: content)
                ))
            } else if file == "mcp.json" {
                if let data = fm.contents(atPath: url.path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let servers = json["servers"] as? [String: Any] {
                    for (name, value) in servers {
                        if let serverObj = value as? [String: Any] {
                            mcpServers.append(McpServerEntry(
                                name: name,
                                command: serverObj["command"] as? String,
                                args: serverObj["args"] as? [String] ?? [],
                                url: serverObj["url"] as? String,
                                env: serverObj["env"] as? [String: String] ?? [:],
                                source: "workspace"
                            ))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Config Lint

    func runConfigLintIfNeeded() async {
        guard !lintResultsValid else { return }
        await runConfigLint()
    }

    func runConfigLint() async {
        lintLoading = true
        lintResultsValid = false

        // Ensure config files are loaded
        if instructions.isEmpty && agents.isEmpty && prompts.isEmpty {
            await loadConfig()
        }

        // Build the flat session list
        let sessions: [(workspaceId: String, summary: SessionSummary)] = sessionsByWorkspace.flatMap { wsId, summaries in
            summaries.map { (workspaceId: wsId, summary: $0) }
        }

        // Collect chatSessions directories for secret scanning (all VS Code dirs)
        var chatSessionDirs: [(workspaceId: String, url: URL)] = []
        for vsDir in vscodeUserDirs {
        let wsStorageDir = vsDir.appendingPathComponent("workspaceStorage")
        if let hashDirs = try? FileManager.default.contentsOfDirectory(atPath: wsStorageDir.path) {
            for hashDir in hashDirs {
                let hashPath = wsStorageDir.appendingPathComponent(hashDir)
                let csDir = hashPath.appendingPathComponent("chatSessions")
                if FileManager.default.fileExists(atPath: csDir.path) {
                    chatSessionDirs.append((workspaceId: hashDir, url: csDir))
                }
            }
        }
        } // end for vsDir in vscodeUserDirs

        let input = ConfigLinterService.Input(
            sessions: sessions,
            instructions: instructions,
            agents: agents,
            prompts: prompts,
            mcpServers: mcpServers,
            chatSessionDirs: chatSessionDirs,
            vscodeSettings: vscodeSettings
        )

        // Run the main (fast) lint pass
        let fastResults = await linterService.lint(input)
        lintResults = fastResults.sorted { $0.severity < $1.severity }
        lintSummary = LintSummary.from(results: lintResults)
        lintLoading = false
        lintResultsValid = true

        // Run secret scan in background (slow — reads every JSONL file)
        secretScanLoading = true
        let sessionMap: [(workspaceId: String, summary: SessionSummary)] = sessions
        let secretResults = await linterService.secretScan(dirs: chatSessionDirs, sessions: sessionMap)
        if !secretResults.isEmpty {
            lintResults = (fastResults + secretResults).sorted { $0.severity < $1.severity }
            lintSummary = LintSummary.from(results: lintResults)
        }
        secretScanLoading = false
    }

    // MARK: - Agent Tree

    func loadAgentTree(sessionId: String) async {
        guard let reader = otelReader else {
            self.agentTree = nil
            return
        }

        let spans = reader.agentSpans(forSession: sessionId)
        guard !spans.isEmpty else {
            self.agentTree = nil
            return
        }

        // Build tree from agent invocation spans
        let rootChildren = spans.map { span in
            AgentTreeNode(
                id: span.spanId,
                agentName: span.agentName ?? span.name,
                model: span.effectiveModel,
                totalInputTokens: span.inputTokens ?? 0,
                totalOutputTokens: span.outputTokens ?? 0,
                estimatedCost: estimateCostFromTokens(
                    model: span.effectiveModel,
                    inputTokens: span.inputTokens ?? 0,
                    outputTokens: span.outputTokens ?? 0,
                    cachedTokens: span.cachedTokens ?? 0
                ),
                toolCallCount: 0,
                durationMs: span.durationMs,
                children: []
            )
        }

        self.agentTree = AgentTreeNode(
            id: sessionId,
            agentName: "GitHub Copilot Chat",
            model: nil,
            totalInputTokens: rootChildren.reduce(0) { $0 + $1.totalInputTokens },
            totalOutputTokens: rootChildren.reduce(0) { $0 + $1.totalOutputTokens },
            estimatedCost: rootChildren.reduce(0) { $0 + $1.estimatedCost },
            toolCallCount: 0,
            durationMs: rootChildren.reduce(0) { $0 + $1.durationMs },
            children: rootChildren
        )
    }
}

// MARK: - Analytics helpers (file-private)

/// Returns the value at the given fraction (0–1) in a pre-sorted array using linear interpolation.
private func analyticsPercentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let pos = fraction * Double(sorted.count - 1)
    let lo = Int(pos)
    let hi = min(lo + 1, sorted.count - 1)
    let t  = pos - Double(lo)
    return sorted[lo] * (1 - t) + sorted[hi] * t
}

/// Buckets an array of millisecond durations into human-readable histogram buckets.
private func analyticsLatencyHistogram(_ sorted: [Double]) -> [LatencyBucket] {
    let buckets: [(label: String, max: Double)] = [
        ("<1s",    1_000),
        ("1–3s",   3_000),
        ("3–10s",  10_000),
        ("10–30s", 30_000),
        ("30–60s", 60_000),
        (">60s",   .infinity),
    ]
    var counts = [String: Int]()
    for label in buckets.map(\.label) { counts[label] = 0 }
    for ms in sorted {
        let label = buckets.first(where: { ms < $0.max })?.label ?? buckets.last!.label
        counts[label, default: 0] += 1
    }
    return buckets.compactMap { b in
        let c = counts[b.label] ?? 0
        return c > 0 ? LatencyBucket(label: b.label, count: c) : nil
    }
}
