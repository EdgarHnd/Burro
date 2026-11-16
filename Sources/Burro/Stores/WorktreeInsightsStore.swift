// Folder sizes and repository health for the Worktrees page, measured off the main thread one at a
// time, only while the page is on screen (its .task drives `measure` and cancels it when the page
// leaves), and cached: a size for an hour, a repository's object counts for half an hour. Unknown
// stays unknown ("—"). It also runs `git gc` for a repository, and only when the user confirms it:
// one at a time, in the background, with its progress and result kept here so they survive leaving
// the page. Nothing here starts on its own.
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class WorktreeInsightsStore {
    enum GCState: Equatable {
        case running(started: Date)
        case finished(before: RepositoryObjectStats?, after: RepositoryObjectStats?)
        case failed(String)
    }
    typealias Size = @Sendable (String) async -> Int64?
    typealias Stats = @Sendable (String) async -> RepositoryObjectStats?
    typealias Collect = @Sendable (String) async -> CommandResult

    /// Bytes per worktree path.
    private(set) var sizes: [String: Int64] = [:]
    /// Object counts per repository path.
    private(set) var health: [String: RepositoryObjectStats] = [:]
    /// The last gc per repository path, until dismissed.
    private(set) var gc: [String: GCState] = [:]
    var gcRunning: Bool { gc.values.contains { if case .running = $0 { true } else { false } } }

    static let sizeLifetime: TimeInterval = 3_600
    static let healthLifetime: TimeInterval = 1_800
    @ObservationIgnored private var sizeCheckedAt: [String: Date] = [:]
    @ObservationIgnored private var healthCheckedAt: [String: Date] = [:]
    @ObservationIgnored private let size: Size
    @ObservationIgnored private let stats: Stats
    @ObservationIgnored private let collect: Collect

    init(size: Size? = nil, stats: Stats? = nil, collect: Collect? = nil) {
        self.size = size ?? { await RepositoryMaintenance.diskUsage($0) }
        self.stats = stats ?? { path in await Task.detached(priority: .utility) { RepositoryMaintenance.objectStats(path) }.value }
        self.collect = collect ?? { await RepositoryMaintenance.collectGarbage($0) }
    }

    /// Measures what is missing or stale: repository health first (cheap), then sizes in the given
    /// order (the page puts safe rows first so the reclaimable total appears soonest). Stops between
    /// items when the calling task is cancelled.
    func measure(repositories: [String], paths: [String], now: Date = Date()) async {
        for repository in repositories where Self.due(healthCheckedAt[repository], now: now, lifetime: Self.healthLifetime) {
            guard !Task.isCancelled else { return }
            if case .running = gc[repository] { continue }
            healthCheckedAt[repository] = now
            let value = await stats(repository)
            guard !Task.isCancelled else { healthCheckedAt[repository] = nil; return }
            health[repository] = value
        }
        for path in paths where Self.due(sizeCheckedAt[path], now: now, lifetime: Self.sizeLifetime) {
            guard !Task.isCancelled else { return }
            sizeCheckedAt[path] = now
            let value = await size(path)
            guard !Task.isCancelled else { sizeCheckedAt[path] = nil; return }
            sizes[path] = value
        }
    }

    /// Starts the conservative gc for one repository. The caller has already asked the user.
    @discardableResult func runGC(repository: String, now: Date = Date()) -> Task<Void, Never>? {
        guard !gcRunning else { return nil }
        let before = health[repository]
        gc[repository] = .running(started: now)
        let collect = collect, stats = stats
        return Task {
            let result = await collect(repository)
            let after = await stats(repository)
            healthCheckedAt[repository] = Date()
            if let after { health[repository] = after }
            if result.succeeded {
                gc[repository] = .finished(before: before, after: after)
            } else {
                let message = result.timedOut ? "Git gc took too long and was stopped. The repository is unchanged or partly repacked; both are safe."
                    : (result.error.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Git gc failed.")
                gc[repository] = .failed(message)
            }
        }
    }

    func dismissGC(_ repository: String) {
        if case .running = gc[repository] { return }
        gc[repository] = nil
    }

    /// Forgets a size so it is measured again (a moved folder, for example).
    func forget(paths: [String]) {
        for path in paths { sizes[path] = nil; sizeCheckedAt[path] = nil }
    }

    private static func due(_ checked: Date?, now: Date, lifetime: TimeInterval) -> Bool {
        guard let checked else { return true }
        return now.timeIntervalSince(checked) >= lifetime
    }
}
