// Decides whether a freshly built activity snapshot is worth publishing to the views. Sample times move
// on every check, so they only count once the shown one is old enough that "Updated just now" would lie.
import Foundation

extension AgentActivitySnapshot {
    /// How old the published sample time may get while nothing else changes.
    public static let sampleTimeRefresh: TimeInterval = 30

    /// True when `next` differs in anything views show: sessions (ignoring each remote sample's time,
    /// which nothing displays), warnings, or a sample time more than `sampleTimeRefresh` newer.
    public func shouldPublish(_ next: AgentActivitySnapshot) -> Bool {
        if warnings != next.warnings || sessions.count != next.sessions.count { return true }
        if (sampledAt == .distantPast) != (next.sampledAt == .distantPast) { return true }
        if abs(next.sampledAt.timeIntervalSince(sampledAt)) >= Self.sampleTimeRefresh { return true }
        return zip(sessions, next.sessions).contains { Self.ignoringSampleTime($0) != Self.ignoringSampleTime($1) }
    }
    private static func ignoringSampleTime(_ session: AgentSession) -> AgentSession {
        guard session.remote != nil else { return session }
        var copy = session
        copy.remote?.sampledAt = .distantPast
        return copy
    }
}
