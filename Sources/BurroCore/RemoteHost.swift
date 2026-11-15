// Explicit SSH hosts and provenance keep remote sessions separate from local worktree evidence.
import Foundation

public struct RemoteHost: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var port: Int?
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, destination: String, port: Int? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.destination = destination; self.port = port; self.enabled = enabled
    }
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this machine." }
        let valid = destination.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.:@%\[\]-]{0,254}$"#, options: .regularExpression) != nil
        if !valid || destination.split(separator: "@", omittingEmptySubsequences: false).contains(where: \.isEmpty) || destination.filter({ $0 == "@" }).count > 1 { return "Enter an SSH alias, hostname, or user@host, without spaces or shell commands." }
        if let port, !(1...65535).contains(port) { return "The SSH port must be between 1 and 65535." }
        return nil
    }
}
public struct RemoteOrigin: Codable, Sendable, Equatable {
    public var hostID: UUID
    public var hostName: String
    public var sampledAt: Date
    public var stale: Bool
}
public enum RemoteConnectionState: String, Sendable { case notChecked = "Not connected", online = "Connected", offline = "Unreachable", disabled = "Paused" }
public struct RemoteHostSnapshot: Sendable {
    /// How long a successful sample stays live: the slow polling cadence plus a probe's timeout and some slack.
    /// A failed probe marks the host offline at once, so this only covers samples that simply aren't renewed.
    public static let freshFor: TimeInterval = RemotePollSchedule.slowInterval + 30
    public var host: RemoteHost
    public var sessions: [AgentSession]
    public var warnings: [String]
    public var sampledAt: Date?
    public var attemptedAt: Date
    public var state: RemoteConnectionState
    public var error: String?
    public init(host: RemoteHost, sessions: [AgentSession] = [], warnings: [String] = [], sampledAt: Date? = nil,
                attemptedAt: Date = .distantPast, state: RemoteConnectionState = .notChecked, error: String? = nil) {
        self.host = host; self.sessions = sessions; self.warnings = warnings; self.sampledAt = sampledAt
        self.attemptedAt = attemptedAt; self.state = state; self.error = error
    }
    public func displaySessions(now: Date = Date()) -> [AgentSession] {
        guard host.enabled else { return [] }
        let stale = state != .online || sampledAt.map { now.timeIntervalSince($0) > Self.freshFor } != false
        return sessions.map { original in
            var session = original
            session.remote = RemoteOrigin(hostID: host.id, hostName: host.name, sampledAt: sampledAt ?? .distantPast, stale: stale)
            if stale { session.state = .unknown; session.evidence = "Connection unavailable or sample expired. Last observed: \(original.state.rawValue)." }
            return session
        }
    }
    public static func mergeFailure(host: RemoteHost, error: String, previous: Self?, now: Date) -> Self {
        // Editing a destination must never carry another machine's data across to it.
        let sameEndpoint = previous?.host.id == host.id && previous?.host.destination == host.destination && previous?.host.port == host.port
        return Self(host: host, sessions: sameEndpoint ? previous?.sessions ?? [] : [],
                    sampledAt: sameEndpoint ? previous?.sampledAt : nil, attemptedAt: now, state: .offline, error: error)
    }
}
