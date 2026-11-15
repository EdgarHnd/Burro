// Decides when a chat deserves a notification: when it starts waiting on you (a question or an
// approval) and, optionally, when it finishes. It only reads the chat samples Burro already takes
// (about every 3 seconds) and never touches the chats themselves.
//
// A state counts once it has held for `settle` seconds, so a chat that flickers into "needs input"
// for one sample fires nothing, and a short dip out of it doesn't end the episode. Each episode
// posts once per chat; when the chat has been seen out of that state for `settle` seconds the
// episode ends and the delivered notification is withdrawn. A chat is taken as it is the first time
// Burro ever sees it, at any time (at launch, a machine connecting late, after a long sleep): one
// already waiting or already finished fires nothing until it is seen leaving that state and coming
// back. A finish counts only after the chat was seen working or waiting. A chat whose machine went
// stale (a failed probe, an expired sample) is reported as unavailable: it keeps its episodes and
// its banner, and coming back in the same state is the same episode, however long it was away. A
// chat simply missing from the samples (it ended, or its machine was removed) has its banner
// withdrawn after `absenceGrace` but keeps its episodes too. Chats unseen for `forgetAfter` (a day)
// are forgotten, withdrawing anything still delivered.
import Foundation

public enum ChatAlertKind: String, Sendable, CaseIterable {
    case needsYou, finished
}

/// What the tracker needs to know about one chat in one sample.
public struct ChatAlertSample: Sendable, Equatable {
    public var id: String
    public var waiting: Bool
    public var working: Bool
    public var done: Bool
    public init(id: String, waiting: Bool = false, working: Bool = false, done: Bool = false) {
        self.id = id; self.waiting = waiting; self.working = working; self.done = done
    }
    public init(_ session: AgentSession) {
        self.init(id: session.id, waiting: session.state == .waiting, working: session.state == .working, done: session.isDone)
    }
    /// Your own chats only: subagents and stale remote rows never notify.
    public static func counts(_ session: AgentSession) -> Bool {
        session.isSubagent != true && session.remote?.stale != true
    }
    /// Your own chats on a machine Burro can't currently see (stale remote rows): known, state unknown.
    public static func unavailable(_ session: AgentSession) -> Bool {
        session.isSubagent != true && session.remote?.stale == true
    }
}

public enum ChatAlertEvent: Equatable, Sendable {
    case post(ChatAlertKind, chat: String)
    case withdraw(ChatAlertKind, chat: String)

    /// The notification identifier for a chat's banner: "chat.<kind>.<chat id>".
    public static func identifier(_ kind: ChatAlertKind, chat: String) -> String { "chat.\(kind.rawValue).\(chat)" }
    /// Whether a notification identifier is one of these banners (from this run or an earlier one).
    public static func isChatAlert(_ identifier: String) -> Bool {
        ChatAlertKind.allCases.contains { identifier.hasPrefix("chat.\($0.rawValue).") && identifier.count > "chat.\($0.rawValue).".count }
    }
}

public struct ChatAlertTracker: Sendable {
    public var settle: TimeInterval
    public var absenceGrace: TimeInterval
    public var forgetAfter: TimeInterval

    private struct Episode: Sendable {
        var enteredSince: Date?
        var leftSince: Date?
        var active = false
        var posted = false
    }
    private struct Chat: Sendable {
        var id: String
        /// Last time the chat was in the samples with a known state.
        var lastSeen: Date
        /// Last time it was in the samples or reported unavailable.
        var lastKnown: Date
        var hasWorked = false
        var episodes: [ChatAlertKind: Episode] = [:]
    }
    private var chats: [String: Chat] = [:]

    public init(settle: TimeInterval = 5, absenceGrace: TimeInterval = 60, forgetAfter: TimeInterval = 86_400) {
        self.settle = settle; self.absenceGrace = absenceGrace; self.forgetAfter = forgetAfter
    }

    /// Feeds one sample of every chat Burro sees, plus the ids of chats it knows of but can't see
    /// right now (`unavailable`); returns what to post and withdraw, in order.
    public mutating func update(_ samples: [ChatAlertSample], unavailable: Set<String> = [], at now: Date) -> [ChatAlertEvent] {
        var events: [ChatAlertEvent] = []
        var seen: Set<String> = []
        for sample in samples where seen.insert(sample.id).inserted {
            var chat: Chat
            if let known = chats[sample.id] {
                chat = known
                chat.lastSeen = now; chat.lastKnown = now
                if sample.working || sample.waiting { chat.hasWorked = true }
            } else {
                // Already like this when Burro first saw it: no notification for this episode.
                chat = Chat(id: sample.id, lastSeen: now, lastKnown: now, hasWorked: sample.working || sample.waiting)
                if sample.waiting { chat.episodes[.needsYou] = Episode(enteredSince: now, active: true) }
                if sample.done { chat.episodes[.finished] = Episode(enteredSince: now, active: true) }
            }
            events += step(sample, chat: &chat, now: now)
            chats[sample.id] = chat
        }
        for id in unavailable where !seen.contains(id) { chats[id]?.lastKnown = now }
        for id in chats.keys.sorted() where !seen.contains(id) {
            guard var chat = chats[id] else { continue }
            if now.timeIntervalSince(chat.lastSeen) >= forgetAfter {
                events += withdrawPosted(&chat)
                chats[id] = nil
            } else if now.timeIntervalSince(chat.lastKnown) >= absenceGrace {
                events += withdrawPosted(&chat)
                chats[id] = chat
            }
        }
        return events
    }

    /// Withdraws delivered banners but keeps the episodes, so the chat coming back isn't new.
    private func withdrawPosted(_ chat: inout Chat) -> [ChatAlertEvent] {
        var events: [ChatAlertEvent] = []
        for kind in ChatAlertKind.allCases where chat.episodes[kind]?.posted == true {
            chat.episodes[kind]?.posted = false
            events.append(.withdraw(kind, chat: chat.id))
        }
        return events
    }

    private func step(_ sample: ChatAlertSample, chat: inout Chat, now: Date) -> [ChatAlertEvent] {
        var events: [ChatAlertEvent] = []
        if let event = advance(.needsYou, in: sample.waiting, chat: &chat, now: now) { events.append(event) }
        // A finish needs work seen first; an episode already open keeps going either way.
        let done = sample.done && (chat.hasWorked || chat.episodes[.finished]?.active == true)
        if let event = advance(.finished, in: done, chat: &chat, now: now) {
            if case .post = event { chat.hasWorked = false }
            events.append(event)
        }
        return events
    }

    private func advance(_ kind: ChatAlertKind, in state: Bool, chat: inout Chat, now: Date) -> ChatAlertEvent? {
        var episode = chat.episodes[kind] ?? Episode()
        defer { chat.episodes[kind] = episode }
        if state {
            episode.leftSince = nil
            let since = episode.enteredSince ?? now
            episode.enteredSince = since
            guard !episode.active, now.timeIntervalSince(since) >= settle else { return nil }
            episode.active = true; episode.posted = true
            return .post(kind, chat: chat.id)
        }
        episode.enteredSince = nil
        guard episode.active else { return nil }
        let left = episode.leftSince ?? now
        episode.leftSince = left
        guard now.timeIntervalSince(left) >= settle else { return nil }
        let posted = episode.posted
        episode = Episode()
        return posted ? .withdraw(kind, chat: chat.id) : nil
    }
}
