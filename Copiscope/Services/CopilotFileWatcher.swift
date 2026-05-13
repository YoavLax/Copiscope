import Foundation
import Combine

enum FileChange: Sendable {
    case sessionUpdated(URL)
    case sessionCreated(URL)
    case configChanged(URL)
    case otelDbChanged
    case mustRescan
    /// CLI `events.jsonl` was updated for the given session UUID
    case cliSessionUpdated(sessionId: String)
    /// A new CLI session directory (with events.jsonl) was created
    case cliSessionCreated(sessionId: String)
}

/// Watches VS Code workspaceStorage and the Copilot CLI session-state dir for changes.
final class CopilotFileWatcher: @unchecked Sendable {
    private let vscodeUserDir: URL
    private let otelDbPath: String?
    private let cliStateDir: URL?
    private var stream: FSEventStreamRef?
    private let subject = PassthroughSubject<FileChange, Never>()
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.copiscope.filewatcher")

    private final class StreamBox {
        weak var watcher: CopilotFileWatcher?
        init(_ watcher: CopilotFileWatcher) { self.watcher = watcher }
    }
    private var streamBox: StreamBox?

    private static let debounceMS: Int = 300

    var changes: AnyPublisher<FileChange, Never> {
        subject.eraseToAnyPublisher()
    }

    init(vscodeUserDir: URL, otelDbPath: String? = nil, cliStateDir: URL? = nil) {
        self.vscodeUserDir = vscodeUserDir
        self.otelDbPath = otelDbPath
        self.cliStateDir = cliStateDir
    }

    @discardableResult
    func start() -> Bool {
        var watchPaths = [vscodeUserDir.appendingPathComponent("workspaceStorage").path]

        // Also watch the OTEL DB directory for changes
        if let dbPath = otelDbPath {
            let dbDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
            watchPaths.append(dbDir)
        }

        // Watch CLI session-state directory if it exists
        if let cliDir = cliStateDir {
            watchPaths.append(cliDir.path)
        }

        let box = StreamBox(self)
        self.streamBox = box

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let paths = watchPaths as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
                guard let watcher = box.watcher else { return }
                let paths = unsafeBitCast(eventPaths, to: NSArray.self)

                for i in 0..<numEvents {
                    guard let path = paths[i] as? String else { continue }
                    let flags = eventFlags[i]

                    let mustRescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                        | UInt32(kFSEventStreamEventFlagKernelDropped)
                        | UInt32(kFSEventStreamEventFlagUserDropped)
                    if flags & mustRescanFlags != 0 {
                        watcher.subject.send(.mustRescan)
                        continue
                    }

                    if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

                    watcher.handleFileEvent(path: path, flags: flags)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            self.streamBox = nil
            return false
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return true
    }

    func stop() {
        streamBox?.watcher = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamBox = nil
        queue.async { [weak self] in
            guard let self else { return }
            for item in self.debounceTimers.values { item.cancel() }
            self.debounceTimers.removeAll()
        }
    }

    private func handleFileEvent(path: String, flags: UInt32) {
        let url = URL(fileURLWithPath: path)

        let isCreated = flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let isModified = flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        let isRenamed = flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isInodeMeta = flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0

        // Copilot transcript JSONL files (both old /transcripts/ and new /chatSessions/ paths)
        if path.hasSuffix(".jsonl") && (path.contains("/transcripts/") || path.contains("/chatSessions/")) {
            guard isCreated || isModified || isRenamed || isInodeMeta else { return }
            debounceEmit(key: path) {
                if isCreated {
                    return .sessionCreated(url)
                } else {
                    return .sessionUpdated(url)
                }
            }
        }
        // agent-traces.db
        else if path.hasSuffix("agent-traces.db") {
            guard isModified || isRenamed || isInodeMeta else { return }
            debounceEmit(key: path) {
                return .otelDbChanged
            }
        }
        // CLI events.jsonl under ~/.copilot/session-state/{uuid}/events.jsonl
        else if path.hasSuffix("/events.jsonl"),
                let cliDir = cliStateDir, path.hasPrefix(cliDir.path) {
            guard isCreated || isModified || isRenamed || isInodeMeta else { return }
            let sessionId = url.deletingLastPathComponent().lastPathComponent
            guard !sessionId.isEmpty else { return }
            debounceEmit(key: path) {
                if isCreated {
                    return .cliSessionCreated(sessionId: sessionId)
                } else {
                    return .cliSessionUpdated(sessionId: sessionId)
                }
            }
        }
        // Config files (.instructions.md, .agent.md, .prompt.md, settings.json)
        else if path.hasSuffix(".instructions.md") ||
                path.hasSuffix(".agent.md") ||
                path.hasSuffix(".prompt.md") ||
                path.hasSuffix("copilot-instructions.md") ||
                path.hasSuffix("settings.json") ||
                path.hasSuffix("mcp.json") {
            guard isCreated || isModified else { return }
            debounceEmit(key: path) {
                return .configChanged(url)
            }
        }
    }

    private func debounceEmit(key: String, event: @escaping () -> FileChange) {
        dispatchPrecondition(condition: .onQueue(queue))
        debounceTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceTimers.removeValue(forKey: key)
            self.subject.send(event())
        }

        debounceTimers[key] = workItem
        queue.asyncAfter(
            deadline: .now() + .milliseconds(Self.debounceMS),
            execute: workItem
        )
    }

    deinit {
        stop()
    }
}
