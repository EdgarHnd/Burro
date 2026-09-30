// Shared snapshots keep UI, command-line inspection, and cleanup rules consistent.
import Foundation

public enum AgentProvider: String, Codable, Sendable { case codex = "Codex", claude = "Claude Code" }
public enum AgentState: String, Codable, Sendable {
    case working = "Working", waiting = "Needs input", scheduled = "Scheduled", idle = "Open · idle"
    case recent = "Recent activity", inactive = "Inactive", unknown = "Unknown"
    public var keepsWorktree: Bool { self != .inactive }
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
    public var isDone: Bool {
        hasUnreadResult == true && isSubagent != true && remote?.stale != true && (state == .idle || state == .inactive)
    }
    public var statusLabel: String { isDone ? "Done" : state.rawValue }
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
    public var changed = 0
    public var untracked = 0
    public var ignored: [String] = []
    public var ignoredCount = 0
    public var merged: Bool?
    public var unpushed: Int?
    public var base: String?
    public var lastCommit: Date?
    public var retainedBranch: String?
    public var retentionChecked: Bool?
    public var includedIn: [String]?
    public var equivalentPatchIn: String?
    public var changedPaths: [String]?
    public var untrackedPaths: [String]?
    public var integrationSummary: String {
        if let refs = includedIn, !refs.isEmpty {
            let ref = base.flatMap { refs.contains($0) ? $0 : nil } ?? refs[0]
            return "Included in " + ref
        }
        if let ref = equivalentPatchIn { return "Equivalent changes in " + ref }
        if merged == true { return "Included in " + (base ?? "comparison branch") }
        return "Integration not confirmed" + (base.map { " in " + $0 } ?? "")
    }
    public var retainedBranchName: String? {
        guard let retainedBranch, retainedBranch.hasPrefix("refs/heads/"), retainedBranch.count > "refs/heads/".count else { return nil }
        return String(retainedBranch.dropFirst("refs/heads/".count))
    }
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
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                repositories: [String] = [], discover: Bool = true,
                protectedPaths: Set<String> = [], baseOverrides: [String: String] = [:]) {
        self.home = home; self.repositories = repositories; self.discover = discover
        self.protectedPaths = protectedPaths; self.baseOverrides = baseOverrides
    }
}
public enum Paths {
    public static func canonical(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        // Foundation leaves /private aliases unresolved for missing paths. Resolve the
        // nearest existing parent so a moved worktree keeps its registration identity.
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) {
            missing.append(url.lastPathComponent); url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for component in missing.reversed() { url.appendPathComponent(component) }
        return url.path
    }
    public static func contains(_ root: String, _ child: String) -> Bool {
        child == root || child.hasPrefix(root == "/" ? root : root + "/")
    }
    public static func owner(of path: String, in roots: [String]) -> String? {
        roots.filter { contains($0, path) }.max { $0.count < $1.count }
    }
}
