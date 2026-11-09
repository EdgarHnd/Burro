// Today's local token activity per working folder. The Rust history worker does the log
// scanning (and keeps older files cached); Swift only merges providers and prices models.
import Foundation

public struct ProjectActivity: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var path: String
        public var tokens: Double
        public var apiValue: Double
        public var records: Int
        public var last: Date
        public init(path: String, tokens: Double = 0, apiValue: Double = 0, records: Int = 0, last: Date = .distantPast) {
            self.path = path; self.tokens = tokens; self.apiValue = apiValue; self.records = records; self.last = last
        }
        mutating func add(_ other: Folder) {
            tokens += other.tokens; apiValue += other.apiValue; records += other.records; last = max(last, other.last)
        }
    }
    public var folders: [Folder]
    public var partial: Bool
    public var since: Date
    public var scannedAt: Date
    public init(folders: [Folder], partial: Bool, since: Date, scannedAt: Date) {
        self.folders = folders; self.partial = partial; self.since = since; self.scannedAt = scannedAt
    }
    public var tokens: Double { folders.reduce(0) { $0 + $1.tokens } }
    public var apiValue: Double { folders.reduce(0) { $0 + $1.apiValue } }

    /// Folds folders into their owning root (a worktree or project folder); the longest root wins.
    public func totals(roots: [String]) -> [String: Folder] {
        var result: [String: Folder] = [:]
        for folder in folders {
            guard let owner = Paths.owner(of: folder.path, in: roots) else { continue }
            result[owner, default: Folder(path: owner)].add(folder)
        }
        return result
    }
}

public enum ProjectActivityScanner {
    /// Scans Codex and Claude logs touched since the start of today. Returns nil when the
    /// worker is unavailable; Home then omits token figures rather than parsing in-process.
    public static func today(profiles: [UsageProvider: String] = [:], now: Date = Date(),
                             calendar: Calendar = .current) -> ProjectActivity? {
        let since = calendar.startOfDay(for: now)
        let roots = [UsageProvider.codex, .claude].map { ($0, LocalUsageScanner.roots(provider: $0, profile: profiles[$0])) }
        return scan(roots: roots, since: since, now: now, worker: .usage)
    }

    static func scan(roots: [(UsageProvider, [URL])], since: Date, now: Date, worker: AgentLogWorker?) -> ProjectActivity? {
        guard let worker else { return nil }
        var folders: [String: ProjectActivity.Folder] = [:]
        var partial = false, answered = false
        for (provider, providerRoots) in roots {
            let request = UsageLogRequest(provider: provider, roots: providerRoots, now: now, projectsSince: since)
            guard let batch = worker.exchange([], usage: request)?.usage, let projects = batch.projects else {
                partial = true; continue
            }
            answered = true
            partial = partial || batch.partial
            for bucket in projects {
                let record = bucket.record
                let folder = ProjectActivity.Folder(path: bucket.cwd, tokens: record.total, apiValue: record.apiValue ?? 0,
                                                    records: bucket.recordCount, last: record.date)
                folders[bucket.cwd, default: ProjectActivity.Folder(path: bucket.cwd)].add(folder)
            }
        }
        guard answered else { return nil }
        return ProjectActivity(folders: folders.values.sorted { $0.tokens > $1.tokens }, partial: partial,
                               since: since, scannedAt: now)
    }
}
