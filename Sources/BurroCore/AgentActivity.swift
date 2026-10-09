// Fast, read-only agent snapshots and presentation ordering, independent of expensive Git scans.
import Foundation

public enum AgentAttention: Sendable { case none, done, waiting }

public struct AgentActivitySnapshot: Sendable {
    public var sessions: [AgentSession]
    public var warnings: [String]
    public var sampledAt: Date
    public var readState: ProviderReadState = .empty
    public init(sessions: [AgentSession], warnings: [String], sampledAt: Date) {
        self.sessions = sessions; self.warnings = warnings; self.sampledAt = sampledAt
    }
    public static var empty: Self { .init(sessions: [], warnings: [], sampledAt: .distantPast) }
    private var uniqueSessions: [AgentSession] {
        var seen: Set<String> = []
        return sessions.filter { seen.insert($0.id).inserted }
    }
    public var unverifiedSessions: [AgentSession] { uniqueSessions.filter { $0.state == .unknown }.sorted { $0.id < $1.id } }
    public var attention: AgentAttention { waitingCount > 0 ? .waiting : (doneCount > 0 ? .done : .none) }
    public var attentionCount: Int { waitingCount + doneCount }
    public var workingCount: Int { uniqueSessions.filter { $0.state == .working }.count }
    public var scheduledCount: Int { uniqueSessions.filter { $0.state == .scheduled }.count }
    public var waitingCount: Int { uniqueSessions.filter { $0.state == .waiting && $0.remote?.stale != true }.count }
    public var idleCount: Int { uniqueSessions.filter { $0.state == .idle && !$0.isDone }.count }
    public var doneCount: Int { uniqueSessions.filter(\.isDone).count }
    public func visibleSessions(includeIdle: Bool) -> [AgentSession] {
        var seen: Set<String> = []
        return sessions.filter {
            ($0.isDone || ($0.state != .inactive && (includeIdle || $0.state != .idle))) && seen.insert($0.id).inserted
        }.sorted {
            let a = $0.isDone ? 1 : Self.priority($0.state), b = $1.isDone ? 1 : Self.priority($1.state)
            if a != b { return a < b }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
    private static func priority(_ state: AgentState) -> Int {
        switch state {
        case .waiting: 0
        case .working: 2
        case .unknown: 3
        case .scheduled: 4
        case .recent: 5
        case .idle: 6
        case .inactive: 7
        }
    }
}
public struct AgentMonitor: Sendable {
    public init() {}
    public func sample(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> AgentActivitySnapshot {
        autoreleasepool { sampleScoped(home: home) }
    }
    private func sampleScoped(home: String) -> AgentActivitySnapshot {
        let now = Date(), processes = ProcessReader.snapshot()
        let readState = ProviderReadState.read(home: home)
        let inventory = AgentReader().read(home: home, processes: processes, now: now, readState: readState)
        var result = AgentActivitySnapshot(sessions: inventory.sessions,
            warnings: Array(Set(processes.warnings + inventory.warnings + readState.warnings)).sorted(), sampledAt: Date())
        result.readState = readState
        return result
    }
}
