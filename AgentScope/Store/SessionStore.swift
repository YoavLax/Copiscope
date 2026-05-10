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
    var selectedWorkspaceId: String?
    var analyticsTimeRange: AnalyticsTimeRange = .thirtyDays
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

    // Appearance
    var appearance: AppAppearance = .system

    private let vscodeUserDir: URL
    private let parser = SessionParser()
    private let cache = SessionCache()
    private let otelReader: OtelSpanReader?
    private let watcher: CopilotFileWatcher
    private let linterService = ConfigLinterService()
    private var cancellables = Set<AnyCancellable>()

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

    /// Today's sessions
    var todaySessions: [SessionSummary] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return allSessionsWithWorkspaces
            .map(\.session)
            .filter { session in
                guard let date = ISO8601.parse(session.lastTimestamp) else { return false }
                return date >= startOfToday
            }
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

    /// Today's stats
    var todayTokens: Int {
        todaySessions.reduce(0) { $0 + $1.totalInputTokens + $1.totalOutputTokens }
    }

    var todayCost: Double {
        todaySessions.reduce(0.0) { $0 + $1.estimatedCost }
    }

    func clearAlertedSecrets() {
        alertedSecrets.removeAll()
    }

    /// Cached analytics for the sidebar
    var sidebarAnalyticsData: AnalyticsData = .empty

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vscodeUserDir = home
            .appendingPathComponent("Library/Application Support/Code/User")

        // OTEL DB path
        let otelDbPath = vscodeUserDir
            .appendingPathComponent("globalStorage/github.copilot-chat/agent-traces.db")
            .path
        if FileManager.default.fileExists(atPath: otelDbPath) {
            self.otelReader = OtelSpanReader(dbPath: otelDbPath)
        } else {
            self.otelReader = nil
        }

        self.watcher = CopilotFileWatcher(
            vscodeUserDir: vscodeUserDir,
            otelDbPath: otelDbPath
        )

        self.alertedSecrets = Self.loadAlertedSecrets()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.realtimeSecretScanKey) == nil {
            self.realtimeSecretScanEnabled = true
            defaults.set(true, forKey: Self.realtimeSecretScanKey)
        } else {
            self.realtimeSecretScanEnabled = defaults.bool(forKey: Self.realtimeSecretScanKey)
        }

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
            NSLog("[AgentScope] File watcher failed to start.")
        }
    }

    private func performInitialScan() {
        Task {
            let scanner = WorkspaceScanner(
                vscodeUserDir: vscodeUserDir,
                parser: parser,
                otelReader: otelReader
            )
            let (scannedWorkspaces, scannedSessions) = await scanner.scan { [weak self] processed, total in
                self?.scanSessionsProcessed = processed
                self?.scanSessionsTotal = total
            }

            self.workspaces = scannedWorkspaces
            self.sessionsByWorkspace = scannedSessions
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
                var summary = try await parser.parseMetadata(
                    url: url,
                    sessionId: sessionId,
                    workspaceId: workspaceId
                )

                // Enrich with OTEL data
                if let reader = otelReader {
                    let tokenData = reader.tokenData(forSession: sessionId)
                    if tokenData.chatSpanCount > 0 {
                        summary = SessionSummary(
                            id: summary.id,
                            workspaceId: summary.workspaceId,
                            title: summary.title,
                            firstTimestamp: summary.firstTimestamp,
                            lastTimestamp: summary.lastTimestamp,
                            messageCount: summary.messageCount,
                            primaryModel: tokenData.models.first ?? summary.primaryModel,
                            vendor: tokenData.providers.first,
                            turnCount: summary.turnCount,
                            toolCallCount: summary.toolCallCount,
                            hasError: summary.hasError,
                            observability: summary.observability,
                            totalInputTokens: tokenData.totalInputTokens,
                            totalOutputTokens: tokenData.totalOutputTokens,
                            totalCachedTokens: tokenData.totalCachedTokens,
                            totalReasoningTokens: tokenData.totalReasoningTokens,
                            estimatedCost: 0,
                            premiumRequestCount: tokenData.chatSpanCount,
                            totalMultiplierCost: 0,
                            modelBreakdown: []
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
                    let workspace = Workspace(
                        id: workspaceId,
                        name: workspaceId,
                        path: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
                        workspacePath: nil,
                        sessionCount: sessions.count
                    )
                    self.workspaces.append(workspace)
                    self.workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }

                self.checkActiveSession()
                self.recomputeAnalytics()
            } catch {
                NSLog("[AgentScope] Watcher: failed to parse session %@: %@",
                      sessionId, error.localizedDescription)
            }

            self.lintResultsValid = false

        case .configChanged:
            break

        case .otelDbChanged:
            // OTEL DB updated — could re-enrich recent sessions
            break

        case .mustRescan:
            rescanAllSessions()
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
            let scanner = WorkspaceScanner(
                vscodeUserDir: vscodeUserDir,
                parser: parser,
                otelReader: otelReader
            )
            let (scannedWorkspaces, scannedSessions) = await scanner.scan()
            self.workspaces = scannedWorkspaces
            self.sessionsByWorkspace = scannedSessions
            self.recomputeAnalytics()
        }
    }

    func recomputeAnalytics() {
        // TODO: Implement analytics computation for Copilot sessions
        // This requires adapting AnalyticsEngine to work with the new models
    }

    func loadSession(id: String, workspaceId: String) async {
        if let cached = await cache.get(id) {
            self.selectedSession = cached
            return
        }

        let fileURL = vscodeUserDir
            .appendingPathComponent("workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("GitHub.copilot-chat")
            .appendingPathComponent("transcripts")
            .appendingPathComponent("\(id).jsonl")

        do {
            var parsed = try await parser.parse(url: fileURL, sessionId: id, workspaceId: workspaceId)

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
            NSLog("[AgentScope] Failed to load session %@: %@", id, error.localizedDescription)
        }
    }

    // MARK: - Timeline

    func loadTimeline() async {
        // TODO: Implement timeline from OTEL spans or transcript timestamps
        timelineLoading = true
        timelineLoading = false
    }

    // MARK: - Config

    func loadConfig() async {
        configLoading = true
        // TODO: Load instructions, agents, prompts, MCPs from workspace
        configLoading = false
    }

    func loadMemoryFiles() async {
        // TODO: Load Copilot memory files
    }

    // MARK: - Config Lint

    func runConfigLintIfNeeded() async {
        guard !lintResultsValid else { return }
        await runConfigLint()
    }

    func runConfigLint() async {
        lintLoading = true
        // TODO: Implement config linting for Copilot configuration
        lintLoading = false
        lintResultsValid = true
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
