// Fast, read-only agent snapshots and presentation ordering, independent of expensive Git scans.
import Foundation

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
    public var attentionCount: Int { waitingCount + doneCount }
    public var workingCount: Int { uniqueSessions.filter { $0.state == .working }.count }
    public var scheduledCount: Int { uniqueSessions.filter { $0.state == .scheduled }.count }
    public var waitingCount: Int { uniqueSessions.filter { $0.state == .waiting }.count }
    public var idleCount: Int { uniqueSessions.filter { $0.state == .idle && !$0.showsCompletion }.count }
    public var needsMergeCount: Int { uniqueSessions.filter { $0.showsCompletion && $0.deliveryStatus == .needsMerge }.count }
    public var mergedCount: Int { uniqueSessions.filter { $0.showsCompletion && $0.deliveryStatus == .merged }.count }
    public var unknownDeliveryCount: Int { uniqueSessions.filter { $0.showsCompletion && $0.deliveryStatus == nil }.count }
    public var doneCount: Int { uniqueSessions.filter(\.showsCompletion).count }
    public func visibleSessions(includeIdle: Bool) -> [AgentSession] {
        var seen: Set<String> = []
        return sessions.filter {
            ($0.showsCompletion || ($0.state != .inactive && (includeIdle || $0.state != .idle))) && seen.insert($0.id).inserted
        }.sorted {
            let a = $0.showsCompletion ? 1 : Self.priority($0.state), b = $1.showsCompletion ? 1 : Self.priority($1.state)
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
        let now = Date(), processes = ProcessReader.snapshot()
        let readState = ProviderReadState.read(home: home)
        let inventory = AgentReader().read(home: home, processes: processes, now: now, readState: readState)
        var result = AgentActivitySnapshot(sessions: inventory.sessions,
            warnings: Array(Set(processes.warnings + inventory.warnings + readState.warnings)).sorted(), sampledAt: Date())
        result.readState = readState
        return result
    }
}
