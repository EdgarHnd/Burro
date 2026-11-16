// Links into the Claude app for chats the Brief names but Burro's list no longer holds (a Claude app
// chat that finished its turn and closed). `refresh(_:)` looks the ids up off the main thread with
// `ClosedChatLink.links` (one bounded walk of the Claude app's session records), remembers each hit
// and re-checks a miss no more often than every five minutes. It runs from an on-screen `.task` keyed
// on the set of unlisted ids (Home's needs-you cards, the Brief queue, the Chats page) and from
// `AppStore.openChat(id:)` at click time; never from a view's body, never on a timer.
// `AppStore.openChat(id:)` is what every "open this chat by id" click uses (Home's needs-you cards,
// the Brief queue, a notification): a listed chat is shown in Burro, an unlisted one with a link
// opens in the Claude app, anything else goes to Chats, which explains why it isn't listed
// (`ClosedChatLink.openTarget` decides). `ClosedChatState` is how Home and the Brief queue draw such
// an item ("Closed" / "Not listed", and "Open in Claude" or a line saying Burro can't open it).
// Navigation only: it never sends, starts or stops anything.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class ClosedChatLinks {
    static let shared = ClosedChatLinks()

    private var hits: [String: URL] = [:]
    /// When each id was last looked up without a hit.
    private var misses: [String: Date] = [:]
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored var root = ClosedChatLink.root()
    static let recheckAfter: TimeInterval = 5 * 60

    /// The known link for a chat id, if any.
    func link(for id: String) -> URL? { hits[id] }

    /// Looks up the ids that are local Claude chats, not yet known and not missed recently.
    func refresh(_ ids: some Sequence<String>) async {
        let now = Date()
        let due = Set(ids.filter { id in
            ClosedChatLink.localClaudeUUID(id) != nil && hits[id] == nil && !running.contains(id)
                && misses[id].map { now.timeIntervalSince($0) >= Self.recheckAfter } != false
        })
        guard !due.isEmpty else { return }
        running.formUnion(due)
        defer { running.subtract(due) }
        let root = self.root
        let found = await Task.detached(priority: .utility) { ClosedChatLink.links(for: due, root: root) }.value
        let checked = Date()
        for id in due {
            if let url = found[id] { hits[id] = url; misses[id] = nil } else { misses[id] = checked }
        }
    }
}

/// A Brief item whose chat Burro's list doesn't hold, as Home's needs-you cards and the Brief queue draw it. `openInClaude`: a chat on this Mac that
/// has closed but the Claude app still has (its one button opens it there); `closed`: one on this
/// Mac with no link (no open button, a line says why); `notListed`: another machine's chat Burro
/// can't see right now (the same, worded for that).
enum ClosedChatState: Equatable {
    case openInClaude, closed, notListed
    var tag: String { self == .notListed ? "Not listed" : "Closed" }
    var canOpen: Bool { self == .openInClaude }
    var openTitle: String { self == .openInClaude ? "Open in Claude" : "Open" }
    var line: String? {
        switch self {
        case .openInClaude: return nil
        case .closed: return "This chat has closed, so Burro can't open it."
        case .notListed: return "Burro can't see this chat right now, so it can't open it."
        }
    }
}

extension AppStore {
    /// The listed chat with this id (ids compared without case, as HomeBoard does).
    func listedChat(id: String) -> AgentSession? {
        let key = id.lowercased()
        return notchChatSessions.first { $0.id.lowercased() == key }
    }

    /// What Open does for this chat id now, from the cached link only (for drawing a button).
    func openTarget(forChat id: String) -> ClosedChatLink.OpenTarget {
        ClosedChatLink.openTarget(chatID: id, listed: listedChat(id: id) != nil, listLoaded: didCheckAgents,
                                  link: ClosedChatLinks.shared.link(for: id))
    }

    /// For a Brief item's chat that isn't listed (after the first agent check): whether the Claude
    /// app can still open it, else why Burro can't. Nil when Open shows it in Burro.
    func closedState(chatID: String?) -> ClosedChatState? {
        guard didCheckAgents else { return nil }
        guard let chatID else { return .notListed }
        switch openTarget(forChat: chatID) {
        case .showInBurro: return nil
        case .openInClaude: return .openInClaude
        case .explain: return chatID.lowercased().hasPrefix("remote:") ? .notListed : .closed
        }
    }

    /// Of these chat ids, the ones Burro's list doesn't hold (empty until the first agent check).
    func unlistedChatIDs(_ ids: some Sequence<String>) -> [String] {
        guard didCheckAgents else { return [] }
        let listed = Set(notchChatSessions.map { $0.id.lowercased() })
        return Array(Set(ids.filter { !listed.contains($0.lowercased()) })).sorted()
    }

    /// Opens a chat by id: in Burro when listed, else in the Claude app when it still has the chat
    /// (looked up now when not known yet), else on the Chats page, which explains. Returns what it did.
    @discardableResult func openChat(id: String) async -> ClosedChatLink.OpenTarget {
        if let session = listedChat(id: id) { showChat(session); return .showInBurro }
        if didCheckAgents && ClosedChatLinks.shared.link(for: id) == nil { await ClosedChatLinks.shared.refresh([id]) }
        let target = openTarget(forChat: id)
        switch target {
        case .showInBurro:
            if let session = listedChat(id: id) { showChat(session) } else { search = ""; page = .remote; remoteSelection = id }
        case .openInClaude(let url):
            NSWorkspace.shared.open(url)
        case .explain:
            search = ""; page = .remote; remoteSelection = id
        }
        return target
    }
}
