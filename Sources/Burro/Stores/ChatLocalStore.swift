// Burro's own per-chat state: which results you've seen here (`ChatSeen`) and Burro-only titles,
// pins and hidden chats (`ChatManage`), kept in Burro's preferences. `applying` turns the sampled
// sessions into Burro's copy (seen results no longer unread, Burro-only titles); AppStore calls it
// where it publishes chats, so the Chats list, its badge, Home and the notch agree; notifications
// and triage get the copy without "seen" (`copies`). Provider unread markers are never written.
import Foundation
import Observation
import BurroCore

@MainActor @Observable
final class ChatLocalStore {
    static let shared = ChatLocalStore()
    private(set) var seen: ChatSeen
    private(set) var manage: ChatManage
    @ObservationIgnored private let defaults: UserDefaults
    static let seenKey = "chats.seen", manageKey = "chats.manage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = ChatSeen.decode(defaults.data(forKey: Self.seenKey))
        manage = ChatManage.decode(defaults.data(forKey: Self.manageKey))
    }

    /// Burro's copy of sampled chats: seen results no longer unread, Burro-only titles applied.
    func applying(_ sessions: [AgentSession]) -> [AgentSession] { manage.applyingTitles(seen.applying(sessions)) }
    /// The display copy, and the copy for notifications and triage ("seen" left out of it).
    func copies(_ sessions: [AgentSession]) -> (display: [AgentSession], attention: [AgentSession]) { seen.copies(sessions, manage: manage) }

    /// Marks the chat seen at its current activity time; true when that changed anything.
    @discardableResult
    func markSeen(_ session: AgentSession) -> Bool {
        guard seen.mark(session) else { return false }
        defaults.set(seen.encoded(), forKey: Self.seenKey)
        return true
    }

    func rename(_ id: String, to title: String) { change { $0.rename(id, to: title) } }
    func setPinned(_ id: String, _ value: Bool) { change { $0.setPinned(id, value, now: Date()) } }
    func hide(_ session: AgentSession) { change { $0.hide(session) } }
    func unhide(_ id: String) { change { $0.unhide(id) } }

    private func change(_ body: (inout ChatManage) -> Void) {
        body(&manage)
        defaults.set(manage.encoded(), forKey: Self.manageKey)
    }
}
