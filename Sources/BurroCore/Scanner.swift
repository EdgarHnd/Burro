// Join Git registrations, agent sessions, and live processes into a single local snapshot.
import Foundation

public struct Scanner: Sendable {
    public init() {}
    public func scan(_ configuration: ScanConfiguration) async -> ScanSnapshot {
        let start = Date(), runner = CommandRunner(deadline: configuration.inspectionDeadline), git = GitReader(deadline: configuration.inspectionDeadline)
        let processes = ProcessReader.snapshot()
        let agents = AgentReader().read(home: configuration.home, processes: processes, now: start)
        var candidates = configuration.repositories
        if configuration.discover {
            candidates += agents.roots
            candidates += discover(in: configuration.home + "/Dev", depth: 2)
            candidates += discover(in: configuration.home + "/.codex/worktrees", depth: 3)
        }
        var groups: [(path: String, records: [WorktreeRecord], base: String?)] = []
        var refreshErrors: [String: String] = [:]
        var seen: Set<String> = [], warnings = processes.warnings + agents.warnings
        for path in Set(candidates.map(Paths.canonical)).sorted() {
            guard FileManager.default.fileExists(atPath: path) else {
                if configuration.repositories.contains(path) { warnings.append("Repository is unavailable: \(path)") }
                continue
            }
            let common = runner.git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            guard common.succeeded else {
                if configuration.repositories.contains(path) { warnings.append("Cannot inspect repository: \(path)") }
                continue
            }
            let identity = Paths.canonical(common.output.trimmingCharacters(in: .whitespacesAndNewlines))
            guard seen.insert(identity).inserted else { continue }
            let listing = runner.git(path, ["worktree", "list", "--porcelain", "-z"])
            guard listing.succeeded else { warnings.append("Cannot list worktrees: \(path)"); continue }
            let records = GitParser.worktrees(listing.output)
            guard let first = records.first else { continue }
            let repository = first.path
            if configuration.refreshReferences,
               let error = await GitReferenceRefresh.shared.refresh(path, identity: identity) {
                refreshErrors[repository] = error
                warnings.append("\(repository): \(error)")
            }
            let base = git.comparisonBase(path, override: configuration.baseOverrides[repository])
            groups.append((repository, records, base))
        }
        let referenceErrors = refreshErrors
        let roots = groups.flatMap { $0.records.map(\.path) }
        let coverageWarnings = Array(Set(agents.warnings + processes.warnings)).sorted()
        let jobs = groups.flatMap { group in group.records.enumerated().filter { !$0.element.bare && (configuration.onlyWorktree == nil || configuration.onlyWorktree == $0.element.path) }.map { (group.path, group.base, $0.offset == 0, $0.element) } }
        var worktrees: [Worktree] = []
        // Four bounded Git lanes prevent one slow repository from freezing the interface.
        await withTaskGroup(of: Worktree.self) { tasks in
            var next = 0
            func enqueue(_ job: (String, String?, Bool, WorktreeRecord)) {
                tasks.addTask {
                    let (repository, base, primary, record) = job
                    let matched = agents.sessions.filter { session in
                        Paths.owner(of: session.cwd, in: roots) == record.path || session.attachedPaths.contains { Paths.owner(of: $0, in: roots) == record.path }
                    }.sorted { lhs, rhs in
                        if lhs.state.keepsWorktree != rhs.state.keepsWorktree { return lhs.state.keepsWorktree }
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    let local = processes.processes.filter { !$0.cwd.isEmpty && Paths.owner(of: $0.cwd, in: roots) == record.path }
                    var facts = git.facts(record, base: base, includeDiff: configuration.onlyWorktree == nil)
                    if let error = referenceErrors[repository] { facts.errors.append(error); facts.merged = nil }
                    let protected = configuration.protectedPaths.contains(record.path)
                    let missing = !FileManager.default.fileExists(atPath: record.path)
                    let assessment = SafetyPolicy.assess(primary: primary, locked: record.locked, missing: missing,
                        prunable: record.prunable, branch: record.branch, facts: facts, agents: matched,
                        processes: local, protected: protected, coverageWarnings: coverageWarnings)
                    return Worktree(path: record.path, repository: URL(fileURLWithPath: repository).lastPathComponent,
                        repositoryPath: repository, branch: record.branch, head: record.head, isPrimary: primary,
                        isLocked: record.locked, isMissing: missing, isPrunable: record.prunable,
                        facts: facts, agents: matched, processes: local, protectedByUser: protected, assessment: assessment)
                }
            }
            while next < min(4, jobs.count) { enqueue(jobs[next]); next += 1 }
            while let tree = await tasks.next() {
                worktrees.append(tree)
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
            }
        }
        worktrees.sort {
            if $0.isWorking != $1.isWorking { return $0.isWorking }
            if $0.isInUse != $1.isInUse { return $0.isInUse }
            if $0.repository != $1.repository { return $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
            return $0.branch.localizedStandardCompare($1.branch) == .orderedAscending
        }
        return ScanSnapshot(worktrees: worktrees, agents: agents.sessions, warnings: Array(Set(warnings)).sorted(), scannedAt: Date(), duration: Date().timeIntervalSince(start))
    }
    private func discover(in path: String, depth: Int) -> [String] {
        let fm = FileManager.default
        guard depth >= 0, fm.fileExists(atPath: path) else { return [] }
        if fm.fileExists(atPath: path + "/.git") { return [path] }
        guard depth > 0, let children = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return children.flatMap { child -> [String] in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true,
                  values.isSymbolicLink != true, !["node_modules", "Library", "dist", "build"].contains(child.lastPathComponent) else { return [] }
            return discover(in: child.path, depth: depth - 1)
        }
    }
}
