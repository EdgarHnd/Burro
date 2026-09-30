// Shared snapshots keep UI, command-line inspection, and cleanup rules consistent.
import Foundation

public enum AgentProvider: String, Codable, Sendable { case codex = "Codex", claude = "Claude Code" }
public enum AgentState: String, Codable, Sendable {
    case working = "Working", waiting = "Needs input", scheduled = "Scheduled", idle = "Open · idle"
    case recent = "Recent activity", inactive = "Inactive", unknown = "Unknown"
    public var keepsWorktree: Bool { self != .inactive }
}
public enum DeliveryStatus: String, Codable, Sendable {
    case uncommitted = "Uncommitted changes", needsPush = "Needs push", needsMerge = "Needs to merge"
    case behind = "Needs pull", inProgress = "Git operation", merged = "Merged", synced = "Done"
    public var needsAction: Bool { self != .merged && self != .synced }
    public static func evaluate(_ facts: GitFacts) -> Self? {
        if facts.operationInProgress { return .inProgress }
        if facts.changed > 0 || facts.untracked > 0 { return .uncommitted }
        if (facts.upstreamAhead ?? facts.unpushed ?? 0) > 0 { return .needsPush }
        guard facts.errors.isEmpty else { return nil }
        // A shared integration branch is synchronized with its own upstream, not merged into main.
        if let branch = facts.branch,
           ["main", "master", "staging", "develop", "development"].contains(branch) || facts.base == facts.upstream {
            guard facts.upstream != nil, facts.upstreamAhead == 0, let behind = facts.upstreamBehind else { return nil }
            return behind > 0 ? .behind : .synced
        }
        if facts.branch != nil && facts.upstream == nil { return .needsPush }
        if (facts.upstreamBehind ?? 0) > 0 { return .behind }
        guard facts.upstreamAhead == 0 || (facts.upstream == nil && facts.unpushed == 0) else { return nil }
        if facts.merged == false { return .needsMerge }
        return facts.merged == true ? .merged : nil
    }
}

public struct AgentSession: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var provider: AgentProvider
    public var title: String
    public var cwd: String
    public var attachedPaths: [String] = []
    public var state: AgentState
    public var updatedAt: Date
    public var pid: Int?
    public var pinned = false
    public var evidence: String
    public var remote: RemoteOrigin? = nil
    public var claudeDesktopSessionID: String? = nil
    public var claudeBridgeSessionID: String? = nil
    public var turnCompleted: Bool? = nil
    public var hasUnreadResult: Bool? = nil
    public var isSubagent: Bool? = nil
    public var parentSessionID: String? = nil
    public var repositoryPath: String? = nil
    public var checkoutPath: String? = nil
    public var checkoutIsLinked: Bool? = nil
    public var checkoutBranch: String? = nil
    public var upstreamBehind: Int? = nil
    public var deliveryStatus: DeliveryStatus? = nil
    public var edits: ChatEdits? = nil
    public var workspaceDiff: ChatEdits? = nil
    public var isDone: Bool {
        hasUnreadResult == true && isSubagent != true && remote?.stale != true && (state == .idle || state == .inactive)
    }
    // Chat completion is provider activity evidence, independent of shared checkout dirt.
    public var showsCompletion: Bool {
        isDone || (turnCompleted == true && isSubagent != true
            && remote?.stale != true && state == .idle)
    }
    public var statusLabel: String { showsCompletion ? "Finished" : state.rawValue }
    public var chatDeliveryLabel: String {
        guard let commit = edits?.commit else { return "Delivery unverified" }
        return commit.onRemote ? "Reported commit on remote" : "Reported commit verified"
    }
}
public struct LocalProcess: Codable, Sendable {
    public var pid: Int
    public var name: String
    public var cwd: String
    public var started: Date
    public var parentPID: Int? = nil
}
public enum SafetyLevel: String, Codable, Sendable {
    case keep = "Keep", review = "Review", candidate = "Safe candidate"
}
public struct Assessment: Codable, Sendable {
    public var level: SafetyLevel
    public var reasons: [String]
    public init(level: SafetyLevel, reasons: [String]) { self.level = level; self.reasons = reasons }
}
public struct GitFacts: Codable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var upstreamAhead: Int?
    public var upstreamBehind: Int?
    public var changed = 0
    public var untracked = 0
    public var ignored: [String] = []
    public var ignoredCount = 0
    public var workspaceDiff: ChatEdits? = nil
    public var merged: Bool?
    public var unpushed: Int?
    public var base: String?
    public var lastCommit: Date?
    public var operationInProgress = false
    public var errors: [String] = []
    public init() {}
}
public struct Worktree: Identifiable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var repository: String
    public var repositoryPath: String
    public var branch: String
    public var head: String
    public var isPrimary: Bool
    public var isLocked: Bool
    public var isMissing: Bool
    public var isPrunable: Bool
    public var facts: GitFacts
    public var agents: [AgentSession]
    public var processes: [LocalProcess]
    public var protectedByUser: Bool
    public var assessment: Assessment
    public var isInUse: Bool { agents.contains { $0.state.keepsWorktree } || !processes.isEmpty }
    public var isWorking: Bool { agents.contains { $0.state == .working } }
    public var activity: String {
        if isWorking { return "Working" }
        if agents.contains(where: { $0.state == .waiting }) { return "Needs input" }
        if agents.contains(where: { $0.state == .scheduled }) { return "Scheduled" }
        if isInUse { return "In use" }
        return "Inactive"
    }
    public var lastActivity: Date? { agents.map(\.updatedAt).max() ?? facts.lastCommit }
}
public struct ScanSnapshot: Codable, Sendable {
    public var worktrees: [Worktree]
    public var agents: [AgentSession]
    public var warnings: [String]
    public var scannedAt: Date
    public var duration: Double
    public static var empty: Self { .init(worktrees: [], agents: [], warnings: [], scannedAt: .distantPast, duration: 0) }
}
public struct ScanConfiguration: Sendable {
    public var home: String
    public var repositories: [String]
    public var discover: Bool
    public var protectedPaths: Set<String>
    public var baseOverrides: [String: String]
    public var onlyWorktree: String? = nil
    public var inspectionDeadline: Date? = nil
    public var refreshReferences: Bool
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                repositories: [String] = [], discover: Bool = true,
                protectedPaths: Set<String> = [], baseOverrides: [String: String] = [:], refreshReferences: Bool = false) {
        self.home = home; self.repositories = repositories; self.discover = discover
        self.protectedPaths = protectedPaths; self.baseOverrides = baseOverrides; self.refreshReferences = refreshReferences
    }
}
public enum Paths {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public static func contains(_ root: String, _ child: String) -> Bool {
        child == root || child.hasPrefix(root == "/" ? root : root + "/")
    }
    public static func owner(of path: String, in roots: [String]) -> String? {
        roots.filter { contains($0, path) }.max { $0.count < $1.count }
    }
}
