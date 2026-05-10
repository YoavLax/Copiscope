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

        for workspace in workspaces {
            let sessions = sessionsByWorkspace[workspace.id] ?? []
            for session in sessions {
                let date = isoFull.date(from: session.firstTimestamp)
                    ?? isoBasic.date(from: session.firstTimestamp)

                // Time-range filter
                if let from = fromDate, let d = date, d < from { continue }
                if let to = toDate, let d = date, d >= to { continue }

                totalSessions += 1
                totalMessages += session.messageCount
                totalInputTokens += session.totalInputTokens
                totalOutputTokens += session.totalOutputTokens
                totalCachedTokens += session.totalCachedTokens
                totalCost += session.estimatedCost

                // Daily aggregation
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
                    }
                }
            }
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
            cacheAnalytics: .empty,
            modelEfficiency: [],
            dailyModelCost: [],
            latencyAnalytics: .empty,
            vendorAnalytics: .empty,
            parallelToolAnalytics: .empty,
            billingAnalytics: .empty
        )
    }

    func loadSession(id: String, workspaceId: String) async {
        if let cached = await cache.get(id) {
            self.selectedSession = cached
            return
        }

        let transcriptURL = vscodeUserDir
            .appendingPathComponent("workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("GitHub.copilot-chat/transcripts/\(id).jsonl")

        let chatSessionURL = vscodeUserDir
            .appendingPathComponent("workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("chatSessions/\(id).jsonl")

        let fm = FileManager.default
        let useTranscript = fm.fileExists(atPath: transcriptURL.path)
        let fileURL = useTranscript ? transcriptURL : chatSessionURL

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
            NSLog("[AgentScope] Failed to load session %@: %@", id, error.localizedDescription)
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

        // --- User-level prompts directory ---
        let userPromptsDir = vscodeUserDir.appendingPathComponent("prompts")
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
        let globalCopilotDir = vscodeUserDir
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
        let userMcpURL = vscodeUserDir.appendingPathComponent("mcp.json")
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
        let workspaceStorageDir = vscodeUserDir.appendingPathComponent("workspaceStorage")
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
