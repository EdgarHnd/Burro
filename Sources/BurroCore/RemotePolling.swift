// When each remote Mac is next checked: every 10 seconds while you are looking at remote chats or one
// is working or waiting on you, otherwise once a minute. A host that fails is retried after 15, 30, 60,
// then 120 seconds (never sooner than the current cadence); the first success, a manual refresh, or
// adding/editing the host resets that and checks it straight away.
import Foundation

public struct RemotePollSchedule: Sendable, Equatable {
    public static let fastInterval: TimeInterval = 10
    public static let slowInterval: TimeInterval = 60
    public static let backoff: [TimeInterval] = [15, 30, 60, 120]

    private struct HostState: Sendable, Equatable {
        var finishedAt: Date?
        var failures = 0
        var requested = false
    }
    private var hosts: [UUID: HostState] = [:]

    public init() {}

    /// Fast while a surface showing remote chats is on screen, or a remote chat is working or waiting on you.
    public static func wantsFast(surfaceVisible: Bool, remoteStates: [AgentState]) -> Bool {
        surfaceVisible || remoteStates.contains { $0 == .working || $0 == .waiting }
    }
    public func failures(_ id: UUID) -> Int { hosts[id]?.failures ?? 0 }

    /// When the host should next be probed. A host never checked, or asked for, is due at once.
    public func nextDue(_ id: UUID, fast: Bool) -> Date {
        guard let state = hosts[id], !state.requested, let finished = state.finishedAt else { return .distantPast }
        let cadence = fast ? Self.fastInterval : Self.slowInterval
        guard state.failures > 0 else { return finished.addingTimeInterval(cadence) }
        let step = Self.backoff[min(state.failures, Self.backoff.count) - 1]
        return finished.addingTimeInterval(max(cadence, step))
    }
    public func isDue(_ id: UUID, now: Date, fast: Bool) -> Bool { nextDue(id, fast: fast) <= now }
    public func due(_ ids: [UUID], now: Date, fast: Bool) -> [UUID] { ids.filter { isDue($0, now: now, fast: fast) } }

    /// How long the loop may sleep before something becomes due, capped so a change in what's on screen
    /// (which can switch to the fast cadence) is noticed within `tick`.
    public func sleepInterval(_ ids: [UUID], now: Date, fast: Bool, tick: TimeInterval) -> TimeInterval {
        let soonest = ids.map { nextDue($0, fast: fast).timeIntervalSince(now) }.min() ?? tick
        return min(tick, max(0.5, soonest))
    }

    public mutating func recordSuccess(_ id: UUID, at date: Date) {
        hosts[id] = HostState(finishedAt: date, failures: 0, requested: false)
    }
    public mutating func recordFailure(_ id: UUID, at date: Date) {
        var state = hosts[id] ?? HostState()
        state.finishedAt = date; state.failures += 1; state.requested = false
        hosts[id] = state
    }
    /// A manual refresh, or a host added or edited: probe now and forget any backoff.
    public mutating func requestNow(_ ids: [UUID]) {
        for id in ids { hosts[id] = HostState(finishedAt: hosts[id]?.finishedAt, failures: 0, requested: true) }
    }
    /// Drops hosts that were removed.
    public mutating func keep(only ids: Set<UUID>) { hosts = hosts.filter { ids.contains($0.key) } }
}
