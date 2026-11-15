// What Burro's menu-bar item says at a glance, and the chats its menu lists. Idle shows the icon
// alone; while agents run it shows how many; while a chat is waiting on you it switches to a
// "needs you" glyph with the number waiting (no colour: menu-bar items are monochrome). The menu
// lists the newest chats waiting on you, skipping remote ones whose machine has gone quiet.
import Foundation

public enum MenuBarStatus: Equatable, Sendable {
    case idle
    case running(Int)
    case needsYou(waiting: Int, running: Int)

    public init(_ activity: AgentActivitySnapshot) {
        if activity.waitingCount > 0 { self = .needsYou(waiting: activity.waitingCount, running: activity.workingCount) }
        else if activity.workingCount > 0 { self = .running(activity.workingCount) }
        else { self = .idle }
    }

    /// The number beside the icon, or nil for the icon alone.
    public var count: Int? {
        switch self {
        case .idle: nil
        case .running(let running): running
        case .needsYou(let waiting, _): waiting
        }
    }

    /// What VoiceOver reads for the item.
    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Burro"
        case .running(let running): return "Burro: \(running) running"
        case .needsYou(let waiting, let running):
            return "Burro: \(waiting) need\(waiting == 1 ? "s" : "") you" + (running > 0 ? ", \(running) running" : "")
        }
    }

    /// Chats waiting on you, newest first, at most `limit`, each once.
    public static func needsYou(_ sessions: [AgentSession], limit: Int = 5) -> [AgentSession] {
        var seen: Set<String> = []
        let waiting = sessions.filter { $0.state == .waiting && $0.remote?.stale != true && $0.isSubagent != true && seen.insert($0.id).inserted }
        return Array(waiting.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }.prefix(max(0, limit)))
    }
}
