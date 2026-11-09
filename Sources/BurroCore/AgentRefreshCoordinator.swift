// File changes wake quiet monitors; process checks remain a bounded fallback.
import Foundation
import CoreServices

public final class AgentFileWatcher: @unchecked Sendable {
    private final class Callback: @unchecked Sendable {
        let changed: @Sendable ([String], Bool) -> Void
        init(_ changed: @escaping @Sendable ([String], Bool) -> Void) { self.changed = changed }
    }
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.burro.agent-file-events", qos: .utility)
    public var isRunning: Bool { stream != nil }

    public convenience init(paths: [String], changed: @escaping @Sendable () -> Void) {
        self.init(paths: paths, events: { _, _ in changed() })
    }
    public init(paths: [String], events: @escaping @Sendable ([String], Bool) -> Void) {
        let callback = Callback(events)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let uncertain = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            let all = (0..<count).contains { flags[$0] & uncertain != 0 }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed((0..<count).map { String(cString: strings[$0]) }, all)
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { stop() }
        }
    }
    // Call start/stop on the owner's actor. The callback owns no watcher/app state.
    public func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    }
    deinit { stop() }

    public static func paths(home: String) -> [String] {
        let root = URL(fileURLWithPath: home)
        return [
            ".codex", ".claude/sessions", ".claude/projects",
            "Library/Application Support/Claude/claude-code-sessions",
            "Library/Application Support/Claude/Local Storage/leveldb"
        ].map { root.appendingPathComponent($0).path }
    }
    public static func affectsAgents(_ paths: [String], uncertain: Bool, home: String) -> Bool {
        if uncertain { return true }
        let codex = home + "/.codex"
        return paths.contains { path in
            guard Paths.contains(codex, path), path != codex else { return true }
            let relative = String(path.dropFirst(codex.count + 1))
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            return first.hasPrefix("state_") || first.hasPrefix(".codex-global-state.json")
                || ["sessions", "archived_sessions", "thread-writer-locks"].contains(first)
        }
    }
}

@MainActor public final class AgentRefreshCoordinator {
    private let refresh: @MainActor @Sendable () async -> TimeInterval
    private let minimumInterval: TimeInterval
    private var scheduled: Task<Void, Never>?
    private var generation: UUID?
    private var inFlight = false
    private var dirty = false
    private var lastStarted: TimeInterval = -.infinity
    private var scheduledAt: TimeInterval?

    public init(minimumInterval: TimeInterval = 3,
                refresh: @escaping @MainActor @Sendable () async -> TimeInterval) {
        self.minimumInterval = minimumInterval; self.refresh = refresh
    }
    public func start() {
        guard generation == nil else { return }
        generation = UUID()
        if !inFlight { schedule(after: 0) }
    }
    public func changed() {
        guard generation != nil else { return }
        dirty = true
        if !inFlight { schedule(after: earliestDelay) }
    }
    public func stop() {
        generation = nil; scheduled?.cancel(); scheduled = nil
        scheduledAt = nil
        dirty = false
    }
    private var earliestDelay: TimeInterval {
        max(0, minimumInterval - (ProcessInfo.processInfo.systemUptime - lastStarted))
    }
    private func schedule(after delay: TimeInterval) {
        guard let generation else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        // A burst must not repeatedly cancel an already earlier wakeup.
        if let scheduledAt, scheduledAt <= deadline { return }
        scheduled?.cancel()
        scheduledAt = deadline
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.scheduled = nil
            self.scheduledAt = nil
            self.inFlight = true; self.dirty = false
            self.lastStarted = ProcessInfo.processInfo.systemUptime
            let interval = await self.refresh()
            self.inFlight = false
            guard self.generation == generation else {
                if self.generation != nil { self.schedule(after: self.earliestDelay) }
                return
            }
            self.schedule(after: self.dirty ? self.earliestDelay : max(self.minimumInterval, interval))
        }
    }
    public static func interval(states: [AgentState], warnings: Bool, watching: Bool) -> TimeInterval {
        // A live session or uncertain evidence still gets frequent PID/lock checks.
        guard watching, !warnings, !states.contains(where: { [.working, .waiting, .unknown].contains($0) }) else { return 3 }
        return 15
    }
}
