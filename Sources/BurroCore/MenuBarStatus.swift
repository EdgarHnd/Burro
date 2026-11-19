// What Burro's menu-bar item says at a glance, and the chats its menu lists. Idle shows the icon
// alone; while agents run it shows how many; while a chat is waiting on you it switches to a
// "needs you" glyph with the number waiting (no colour: menu-bar items are monochrome). The menu
// lists the newest chats waiting on you, skipping remote ones whose machine has gone quiet. The
// window sidebar shows the same state as a line under its name (`summary`).
import Foundation

public enum MenuBarStatus: Equatable, Sendable {
    case idle
    case running(Int)
    case needsYou(waiting: Int, running: Int)

    /// The menu-bar item: chats waiting on an input request and chats working, on Home's rules
    /// (HomeSummary.chatLists): a sub-agent is neither, it belongs to its parent chat. The raw
    /// `AgentActivitySnapshot` counts include sub-agents, which made the sidebar read "7 working"
    /// while Home said "5 chats are working".
    public init(_ activity: AgentActivitySnapshot) {
        let lists = HomeSummary.chatLists(activity.sessions)
        self.init(needsYou: lists.needsYou.count, working: lists.running.filter { $0.isSubagent != true }.count)
    }

    /// Home's own numbers: the board's Needs you (waiting chats plus chats triage found ending a
    /// turn on a question) and Working sections. The window sidebar's line uses this so it says
    /// exactly what Home's sentence says.
    public init(_ board: HomeBoard) {
        self.init(needsYou: board.needsYou.count, working: board.working.count)
    }

    public init(needsYou: Int, working: Int) {
        if needsYou > 0 { self = .needsYou(waiting: needsYou, running: working) }
        else if working > 0 { self = .running(working) }
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

    /// The same state in one short line, for the window sidebar's subtitle under "Burro".
    public var summary: String {
        switch self {
        case .idle: return "All quiet"
        case .running(let running): return "\(running) working"
        case .needsYou(let waiting, let running):
            return "\(waiting) need\(waiting == 1 ? "s" : "") you" + (running > 0 ? " · \(running) working" : "")
        }
    }

    /// Chats waiting on you, newest first, at most `limit`, each once.
    public static func needsYou(_ sessions: [AgentSession], limit: Int = 5) -> [AgentSession] {
        var seen: Set<String> = []
        let waiting = sessions.filter { $0.state == .waiting && $0.remote?.stale != true && $0.isSubagent != true && seen.insert($0.id).inserted }
        return Array(waiting.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }.prefix(max(0, limit)))
    }
}
