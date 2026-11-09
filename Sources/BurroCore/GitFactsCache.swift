// Automatic dashboard scans reuse facts only while filesystem watches stay clean.
// Explicit refresh and every cleanup/preflight scan bypass this presentation cache.
import Foundation

final class GitFactsCache: @unchecked Sendable {
    static let shared = GitFactsCache()
    private struct Entry {
        let record: WorktreeRecord
        let base: String?
        let facts: GitFacts
        let time: TimeInterval
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var watches: [String: [String]] = [:]
    private var globalPaths: [String] = []
    private var watcher: AgentFileWatcher?
    private var reliable = false
    private var epoch: UInt64 = 0
    private let lifetime: TimeInterval
    private var hits = 0, misses = 0
    init(lifetime: TimeInterval = 900) { self.lifetime = lifetime }
    func statistics() -> (hits: Int, misses: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, misses)
    }

    func prepare(watches: [String: [String]], globals: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard self.watches != watches || globalPaths != globals || !reliable || watcher?.isRunning != true else { return }
        watcher?.stop(); watcher = nil
        reliable = false
        entries.removeAll(); epoch &+= 1
        self.watches = watches; globalPaths = globals
        guard !watches.isEmpty, watches.count <= 512 else { return }
        let paths = Array(Set(watches.values.flatMap { $0 } + globals)).sorted()
        watcher = AgentFileWatcher(paths: paths, events: { [weak self] paths, uncertain in
            self?.invalidate(paths: paths, uncertain: uncertain)
        })
        reliable = watcher?.isRunning == true
    }

    func invalidate(paths: [String] = [], uncertain: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        // A moved root or dropped event stream must be re-established before reuse.
        if uncertain { reliable = false }
        // Events during an in-flight scan still change the epoch, but there is
        // nothing to match once all cached entries are already dirty.
        guard !entries.isEmpty else { return }
        // FSEvents reports physical /private aliases. Match both spellings
        // without resolving/stat-ing every build output or deleted file.
        let paths = paths.flatMap { path -> [String] in
            var aliases = [path]
            if path.hasPrefix("/System/Volumes/Data/") { aliases.append(String(path.dropFirst("/System/Volumes/Data".count))) }
            for value in aliases {
                for root in ["/var", "/tmp", "/etc"] {
                    if Paths.contains("/private" + root, value) { aliases.append(String(value.dropFirst("/private".count))) }
                    else if Paths.contains(root, value) { aliases.append("/private" + value) }
                }
            }
            return aliases
        }
        func overlaps(_ lhs: String, _ rhs: String) -> Bool { Paths.contains(lhs, rhs) || Paths.contains(rhs, lhs) }
        if uncertain || paths.contains(where: { path in globalPaths.contains { overlaps(path, $0) } }) {
            entries.removeAll(); return
        }
        for worktree in Array(entries.keys) where paths.contains(where: { path in (watches[worktree] ?? []).contains { overlaps(path, $0) } }) {
            entries.removeValue(forKey: worktree)
        }
    }

    func facts(_ record: WorktreeRecord, base: String?, now: TimeInterval = Date.timeIntervalSinceReferenceDate,
               load: () -> GitFacts) -> GitFacts {
        lock.lock()
        let watching = reliable && watcher?.isRunning == true && watches[record.path] != nil
        let ticket = epoch
        if watching, let entry = entries[record.path], entry.record == record, entry.base == base,
           now >= entry.time, now - entry.time < lifetime {
            hits += 1
            lock.unlock(); return entry.facts
        }
        misses += 1
        lock.unlock()
        let facts = load()
        lock.lock(); defer { lock.unlock() }
        if watching, ticket == epoch, facts.errors.isEmpty, facts.unpushed != nil,
           facts.retentionChecked == true, facts.lastCommit != nil, !facts.operationInProgress,
           base == nil || facts.merged != nil {
            entries[record.path] = Entry(record: record, base: base, facts: facts, time: now)
        }
        return facts
    }
}
