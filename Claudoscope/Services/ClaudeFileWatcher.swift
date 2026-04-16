import Foundation
import Combine

enum FileChange: Sendable {
    case sessionUpdated(URL)
    case sessionCreated(URL)
    case configChanged(URL)
    case mustRescan
}

/// Watches ~/.claude/projects/ for file changes using FSEvents.
/// Port of server/services/file-watcher.ts
final class ClaudeFileWatcher: @unchecked Sendable {
    private let claudeDir: URL
    private var stream: FSEventStreamRef?
    private let subject = PassthroughSubject<FileChange, Never>()
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.claudoscope.filewatcher")

    /// Weak-reference box passed to FSEvents callback to avoid use-after-free.
    /// The stored property keeps it alive; the callback checks watcher != nil.
    private final class StreamBox {
        weak var watcher: ClaudeFileWatcher?
        init(_ watcher: ClaudeFileWatcher) { self.watcher = watcher }
    }
    private var streamBox: StreamBox?

    private static let debounceMS: Int = 300

    var changes: AnyPublisher<FileChange, Never> {
        subject.eraseToAnyPublisher()
    }

    init(claudeDir: URL) {
        self.claudeDir = claudeDir
    }

    @discardableResult
    func start() -> Bool {
        let projectsDir = claudeDir.appendingPathComponent("projects").path

        let box = StreamBox(self)
        self.streamBox = box

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let paths = [projectsDir] as CFArray
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

                    // Handle event overflow: OS dropped events, full rescan needed
                    let mustRescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                        | UInt32(kFSEventStreamEventFlagKernelDropped)
                        | UInt32(kFSEventStreamEventFlagUserDropped)
                    if flags & mustRescanFlags != 0 {
                        watcher.subject.send(.mustRescan)
                        continue
                    }

                    // Skip directory events
                    if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

                    watcher.handleFileEvent(path: path, flags: flags)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // latency in seconds
            flags
        ) else {
            NSLog("[ClaudeFileWatcher] FSEventStreamCreate returned nil for %@", projectsDir)
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
        // Clean up timers on the queue where they are created/accessed
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

        guard isCreated || isModified else { return }

        if path.hasSuffix(".jsonl") {
            debounceEmit(key: path) {
                if isCreated {
                    return .sessionCreated(url)
                } else {
                    return .sessionUpdated(url)
                }
            }
        } else if path.hasSuffix("settings.json") ||
                  path.hasSuffix("mcp.json") ||
                  path.hasSuffix(".mcp.json") ||
                  path.contains("/commands/") ||
                  path.contains("/skills/") {
            debounceEmit(key: path) {
                return .configChanged(url)
            }
        }
    }

    private func debounceEmit(key: String, event: @escaping () -> FileChange) {
        debounceTimers[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.debounceTimers.removeValue(forKey: key)
            self?.subject.send(event())
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
