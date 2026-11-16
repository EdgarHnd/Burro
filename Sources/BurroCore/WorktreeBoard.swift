// The Worktrees page's decisions, kept pure so they can be tested: what state each row shows,
// which rows can be ticked, the filter chips (including Protected) and their counts, the
// per-repository groups, and the bulk set.
// The bulk set is the only list the page ever hands to the cleanup confirmation, and it holds
// nothing but rows whose cleanup eligibility (WorktreeCleanup.eligibility, the same decision the
// confirmation and the removal itself recheck) is allowed. Ticking a row never makes it removable.
import Foundation

/// What a row's state chip says, in the order the page explains them.
public enum WorktreeRowKind: String, Sendable, Equatable {
    /// A chat that keeps the worktree, or a local process, is using the folder.
    case inUse
    /// Cleanup eligibility says the folder can move to Trash (its commits stay on a branch).
    case safe
    /// Modified, staged or untracked files block removal.
    case uncommitted
    /// Anything else that blocks removal: protected, managed by Codex, Git busy, cannot verify, needs a branch.
    case blocked
}

/// One row on the page: the scanned worktree, its cleanup eligibility and, once measured, its size.
public struct WorktreeBoardRow: Identifiable, Sendable {
    public var tree: Worktree
    public var eligibility: CleanupEligibility
    /// Bytes on disk, or nil until measured (or when measuring failed).
    public var size: Int64?
    public init(tree: Worktree, eligibility: CleanupEligibility, size: Int64? = nil) {
        self.tree = tree; self.eligibility = eligibility; self.size = size
    }
    public var id: String { tree.path }
    public var uncommitted: Int { tree.facts.changed + tree.facts.untracked }
    public var hasUncommittedWork: Bool { uncommitted > 0 }
    public var isInUse: Bool { tree.isInUse || eligibility.status == .inUse }
    public var kind: WorktreeRowKind {
        if isInUse { return .inUse }
        if eligibility.allowed { return .safe }
        if hasUncommittedWork { return .uncommitted }
        return .blocked
    }
    /// The state chip's words.
    public var stateTitle: String {
        switch kind {
        case .inUse: "In use"
        case .safe: "Safe to clean"
        case .uncommitted: "Uncommitted work"
        case .blocked: eligibility.status.rawValue
        }
    }
    /// Why the checkbox is disabled, or nil when the row can be ticked. Rows a chat or process uses
    /// and the main checkout can never be ticked; other blocked rows can, so their blockers can be
    /// reviewed, but they never enter the bulk set.
    public var selectionBlocker: String? {
        if isInUse { return "A chat or process is using this worktree" }
        if tree.isPrimary { return "The main checkout of a repository is never removed" }
        return nil
    }
    public var selectable: Bool { selectionBlocker == nil }
    /// The chat to show for the row: an open one first, otherwise the most recently active.
    public var linkedChat: AgentSession? {
        let open = tree.agents.filter { $0.state.keepsWorktree }
        return (open.isEmpty ? tree.agents : open).max { $0.updatedAt < $1.updatedAt }
    }
    public var lastActivity: Date? { tree.lastActivity }
    /// The Changes column: uncommitted and unpushed work first (attention), otherwise integration.
    public var changes: (text: String, attention: Bool) {
        let unpushed = tree.facts.unpushed ?? 0
        if hasUncommittedWork {
            return ([uncommitted > 0 ? "\(uncommitted) uncommitted" : nil, unpushed > 0 ? "\(unpushed) unpushed" : nil]
                .compactMap { $0 }.joined(separator: " · "), true)
        }
        if unpushed > 0 { return ("\(unpushed) unpushed", false) }
        let facts = tree.facts
        if let refs = facts.includedIn, !refs.isEmpty {
            return ("Merged in " + (facts.base.flatMap { refs.contains($0) ? $0 : nil } ?? refs[0]), false)
        }
        if let ref = facts.equivalentPatchIn { return ("Same changes in " + ref, false) }
        if facts.merged == true { return ("Merged in " + (facts.base ?? "the comparison branch"), false) }
        return ("Merge not confirmed", false)
    }
}

/// The page's filter chips.
public enum WorktreeBoardFilter: String, CaseIterable, Sendable {
    case all, inUse, safe, uncommitted, untouched, protected
    /// "Untouched" means no chat activity and no commit for this many days.
    public static let untouchedDays = 14
    public var title: String {
        switch self {
        case .all: "All"
        case .inUse: "In use"
        case .safe: "Safe to clean"
        case .uncommitted: "Uncommitted work"
        case .untouched: "Untouched \(Self.untouchedDays) days+"
        case .protected: "Protected"
        }
    }
    public func matches(_ row: WorktreeBoardRow, now: Date) -> Bool {
        switch self {
        case .all: true
        case .inUse: row.kind == .inUse
        case .safe: row.kind == .safe
        case .uncommitted: row.hasUncommittedWork
        case .untouched:
            // Unknown activity is not evidence of being untouched.
            row.lastActivity.map { now.timeIntervalSince($0) >= Double(Self.untouchedDays) * 86_400 } ?? false
        case .protected:
            // Protected by you, or what cleanup reports as Protected (a main checkout, a locked
            // worktree, a protected path): the old sidebar's Protected list.
            row.tree.protectedByUser || row.eligibility.status == .protected
        }
    }
}

public enum WorktreeBoardSort: String, CaseIterable, Sendable {
    case lastActivity, branch, size
    public var title: String {
        switch self { case .lastActivity: "Last activity"; case .branch: "Branch"; case .size: "Size" }
    }
}

/// The numbers in the summary strip.
public struct WorktreeBoardSummary: Equatable, Sendable {
    public var total: Int
    public var inUse: Int
    public var safe: Int
    public var uncommitted: Int
    /// Bytes the safe rows take, or nil until every safe row has been measured.
    public var reclaimable: Int64?
}

/// One repository's rows after filtering and sorting.
public struct WorktreeBoardGroup: Identifiable, Sendable {
    public var repositoryPath: String
    public var name: String
    /// Rows that pass the filter, sorted.
    public var rows: [WorktreeBoardRow]
    /// Every row of this repository on the page, whatever the filter.
    public var total: Int
    public var safe: Int
    public var reclaimable: Int64?
    public var id: String { repositoryPath }
}

public enum WorktreeBoard {
    public static func counts(_ rows: [WorktreeBoardRow], now: Date) -> [WorktreeBoardFilter: Int] {
        Dictionary(uniqueKeysWithValues: WorktreeBoardFilter.allCases.map { filter in
            (filter, rows.filter { filter.matches($0, now: now) }.count)
        })
    }

    public static func summary(_ rows: [WorktreeBoardRow]) -> WorktreeBoardSummary {
        let safe = rows.filter { $0.kind == .safe }
        return WorktreeBoardSummary(total: rows.count, inUse: rows.filter { $0.kind == .inUse }.count, safe: safe.count,
                                    uncommitted: rows.filter(\.hasUncommittedWork).count, reclaimable: total(safe))
    }

    /// The sum of the rows' sizes, or nil while any is unknown.
    public static func total(_ rows: [WorktreeBoardRow]) -> Int64? {
        var sum: Int64 = 0
        for row in rows { guard let size = row.size else { return nil }; sum += size }
        return sum
    }

    /// Groups by repository (largest first, then by name); empty groups are dropped unless the filter is All.
    public static func groups(_ rows: [WorktreeBoardRow], filter: WorktreeBoardFilter, sort: WorktreeBoardSort,
                              now: Date) -> [WorktreeBoardGroup] {
        Dictionary(grouping: rows, by: \.tree.repositoryPath).map { path, all in
            let safe = all.filter { $0.kind == .safe }
            return WorktreeBoardGroup(repositoryPath: path, name: all.first?.tree.repository ?? path,
                rows: sorted(all.filter { filter.matches($0, now: now) }, by: sort),
                total: all.count, safe: safe.count, reclaimable: total(safe))
        }
        .filter { !$0.rows.isEmpty }
        .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func sorted(_ rows: [WorktreeBoardRow], by sort: WorktreeBoardSort) -> [WorktreeBoardRow] {
        rows.sorted { a, b in
            switch sort {
            case .lastActivity:
                let left = a.lastActivity ?? .distantPast, right = b.lastActivity ?? .distantPast
                if left != right { return left > right }
            case .size:
                let left = a.size ?? -1, right = b.size ?? -1
                if left != right { return left > right }
            case .branch:
                let order = a.tree.branch.localizedStandardCompare(b.tree.branch)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.tree.path.localizedStandardCompare(b.tree.path) == .orderedAscending
        }
    }

    /// Ticked ids that still name a row that can be ticked; everything else drops out.
    public static func prune(_ selection: Set<String>, rows: [WorktreeBoardRow]) -> Set<String> {
        selection.intersection(rows.filter(\.selectable).map(\.id))
    }

    /// The ids "Select safe ones" ticks: safe rows only.
    public static func safeIDs(_ rows: [WorktreeBoardRow]) -> Set<String> {
        Set(rows.filter { $0.kind == .safe && $0.selectable }.map(\.id))
    }

    /// The worktrees "Move to Trash…" may hand to the confirmation: ticked, tickable, and allowed
    /// by cleanup eligibility. Order follows `rows`.
    public static func bulkSet(_ selection: Set<String>, rows: [WorktreeBoardRow]) -> [Worktree] {
        rows.filter { selection.contains($0.id) && $0.selectable && $0.eligibility.allowed }.map(\.tree)
    }
}

/// Plain-language numbers for the page, independent of the user's locale so CI and tests agree.
public enum WorktreeBoardFormat {
    /// "now", "4 min ago", "3 h ago", "yesterday", "9 days ago", "2 months ago"; "—" when unknown.
    public static func ago(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return "\(Int(seconds / 3_600)) h ago" }
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        return "\(days / 30) months ago"
    }

    /// Decimal units, as Finder shows them: "820 KB", "412 MB", "1.1 GB"; "—" when unknown.
    public static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let v = Double(value)
        if v < 1_000_000 { return "\(Int((v / 1_000).rounded())) KB" }
        if v < 1_000_000_000 { return "\(Int((v / 1_000_000).rounded())) MB" }
        return String(format: "%.1f GB", v / 1_000_000_000)
    }

    /// "940", "6.7k", "104k", "1.2M".
    public static func compact(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 10_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        if value < 1_000_000 { return "\(value / 1_000)k" }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
}
