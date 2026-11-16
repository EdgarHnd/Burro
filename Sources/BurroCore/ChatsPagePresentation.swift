// Small decisions for the Chats page's layout. The list's sections: chats you pinned that aren't
// asking for anything sit in an unlabelled group at the top; then Needs you, Working, Ready to read
// (a pinned chat in one of those stays there, on top), then Earlier, newest first, of which the 12
// most recent show until you ask for all (or filter, or the open chat is further down). Every row
// is built from its section, so a row never shows a different state from the header above it: a
// title; a second line with the place (the folder on this Mac, "Studio · folder" on another
// machine) and the time; and, only for Needs you and Ready to read, the chat's last reply when a
// scan already read it. Times read "now", "4 min", "21:17", "Yesterday", "Mon" or "3 Nov"; a working
// Claude chat says how long it has worked ("for 36 min", "since 13:09"), because its time is when
// its status last changed, not its latest output (a Codex chat's time follows its log). The
// header's turn clock runs from the latest message you sent while the chat works ("turn 18 min").
// When a chat waits on you the transcript ends with a hand-off card: Burro can't answer an
// approval, so the card names the one place that can (the composer's own action, else the
// provider's app). Each row carries its provider (Claude or Codex), and the filter matches
// "claude", "codex" and the chat's model as well as its title and place.
import Foundation

/// A chat's status as the Chats page shows it.
public enum ChatPageStatus: String, Sendable, Equatable {
    case needsYou, working, readyToRead, idle

    public static func of(_ session: AgentSession) -> ChatPageStatus {
        if session.state == .waiting && session.remote?.stale != true { return .needsYou }
        if session.state == .working || session.state == .scheduled { return .working }
        return session.isDone ? .readyToRead : .idle
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .readyToRead: "Ready to read"
        case .idle: "Idle"
        }
    }
}

/// One section of the chat list.
public struct ChatListSection: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable { case pinned, needsYou, working, readyToRead, earlier }
    public var kind: Kind
    public var sessions: [AgentSession]

    /// The header, or nil for the pinned group (its rows carry a pin instead).
    public var title: String? {
        switch kind {
        case .pinned: nil
        case .needsYou: "Needs you"
        case .working: "Working"
        case .readyToRead: "Ready to read"
        case .earlier: "Earlier"
        }
    }

    /// `sessions` in display priority (pinned first is fine: the order within a status is kept);
    /// `pinned` says which chats you pinned. Empty sections are left out; every chat appears once.
    public static func sections(_ sessions: [AgentSession], pinned: (String) -> Bool) -> [ChatListSection] {
        var needs: [AgentSession] = [], working: [AgentSession] = [], ready: [AgentSession] = []
        var pins: [AgentSession] = [], rest: [AgentSession] = []
        for session in sessions {
            switch ChatPageStatus.of(session) {
            case .needsYou: needs.append(session)
            case .working: working.append(session)
            case .readyToRead: ready.append(session)
            case .idle: if pinned(session.id) { pins.append(session) } else { rest.append(session) }
            }
        }
        rest.sort { $0.updatedAt > $1.updatedAt }
        return [ChatListSection(kind: .pinned, sessions: pins), ChatListSection(kind: .needsYou, sessions: needs),
                ChatListSection(kind: .working, sessions: working), ChatListSection(kind: .readyToRead, sessions: ready),
                ChatListSection(kind: .earlier, sessions: rest)].filter { !$0.sessions.isEmpty }
    }
}

/// One row of the chat list, ready to draw.
public struct ChatListRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The state of the section the row sits in (pinned rows are idle).
    public var status: ChatPageStatus
    public var pinned: Bool
    /// "focustown · 4 min", "Studio · focustown · since 13:09".
    public var meta: String
    /// Only for Needs you and Ready to read, and only when a scan already has the text.
    public var preview: String?
    /// Which agent the chat is: drawn as the row's avatar and read out first after the title.
    public var provider: AgentProvider

    public init(id: String, title: String, status: ChatPageStatus, pinned: Bool, meta: String, preview: String?,
                provider: AgentProvider = .claude) {
        self.id = id; self.title = title; self.status = status; self.pinned = pinned; self.meta = meta; self.preview = preview
        self.provider = provider
    }

    /// "Claude" or "Codex".
    public var agent: String { ChatListRow.agent(provider) }
    public static func agent(_ provider: AgentProvider) -> String { provider == .codex ? "Codex" : "Claude" }

    /// What VoiceOver reads: "Pinned, Weekly release train, Claude, Needs you, focustown · 4 min, <preview>".
    public var accessibilityLabel: String {
        [pinned ? "Pinned" : nil, title, agent, status.title, meta, preview].compactMap { $0 }.joined(separator: ", ")
    }

    /// Whether a chat matches the list's filter: its title, its place, its agent ("claude",
    /// "codex") or its model ("opus", "gpt-5.5"), ignoring case. An empty query matches everything.
    public static func matches(_ query: String, title: String, place: String, provider: AgentProvider, model: String?) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        var fields = [title, place, agent(provider)]
        if provider == .claude { fields.append("Claude Code") }
        if let model, !model.isEmpty { fields.append(model); if let name = modelName(model) { fields.append(name) } }
        return fields.contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// "claude-opus-5-5" as "Opus 5.5"; other model ids as they are.
    public static func modelName(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst(7).split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().filter { $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    /// Needs you, working and ready-to-read rows are drawn strong; idle rows recede.
    public var isActive: Bool { status != .idle }

    /// The status a section's rows carry.
    public static func status(of kind: ChatListSection.Kind) -> ChatPageStatus {
        switch kind {
        case .needsYou: .needsYou
        case .working: .working
        case .readyToRead: .readyToRead
        case .pinned, .earlier: .idle
        }
    }

    /// Whether rows in this state show what the chat last said.
    public static func showsPreview(_ status: ChatPageStatus) -> Bool { status == .needsYou || status == .readyToRead }

    /// The short place: the folder on this Mac, "Machine · folder" on another machine.
    public static func place(machine: String?, folder: String) -> String {
        guard let machine else { return folder.isEmpty ? "This Mac" : folder }
        return folder.isEmpty ? machine : "\(machine) · \(folder)"
    }

    /// The row for `session` in a section of `kind`. `folder` is the chat's folder name; `preview`
    /// the already-cleaned text a scan has for it, if any.
    public static func make(_ session: AgentSession, in kind: ChatListSection.Kind, pinned: Bool,
                            folder: String, preview: String?, now: Date, calendar: Calendar) -> ChatListRow {
        let status = status(of: kind)
        let time = ChatRowTime.meta(status: status, updatedAt: session.updatedAt, followsOutput: session.provider == .codex,
                                    now: now, calendar: calendar)
        return ChatListRow(id: session.id, title: session.title, status: status, pinned: pinned,
                           meta: place(machine: session.remote?.hostName, folder: folder) + " · " + time,
                           preview: showsPreview(status) ? preview : nil, provider: session.provider)
    }
}

/// How much of Earlier the list shows.
public enum ChatListEarlier {
    /// The most recent Earlier chats shown before "Show all".
    public static let limit = 12
    /// Hiding fewer than this many rows isn't worth a "Show all" row.
    static let minimumHidden = 4

    /// How many of `total` Earlier rows to show. All of them while filtering, once you asked, when
    /// the open chat is among the ones that would be hidden (`selectedIndex` is its place in
    /// Earlier), or when only a few would be hidden.
    public static func shown(total: Int, filtering: Bool, expanded: Bool, selectedIndex: Int?) -> Int {
        if filtering || expanded || total < limit + minimumHidden { return total }
        if let selectedIndex, selectedIndex >= limit { return total }
        return limit
    }
}

/// The time on a chat row's second line.
public enum ChatRowTime {
    public static func label(_ date: Date, now: Date, calendar: Calendar, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        if calendar.isDate(date, inSameDayAs: now) { formatter.dateFormat = "HH:mm"; return formatter.string(from: date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "Yesterday" }
        formatter.dateFormat = days < 7 && days > 0 ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }

    /// The row's time, saying what it means. `followsOutput`: whether `updatedAt` moves as the chat
    /// writes (Codex's thread time follows its log). A Claude chat's time is when its session
    /// record's status last changed, so while it works that is when it started working: "for 36
    /// min", "since 13:09", "since Mon", never a stale clock time that looks like its latest output.
    public static func meta(status: ChatPageStatus, updatedAt: Date, followsOutput: Bool, now: Date, calendar: Calendar,
                            locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        guard status == .working, !followsOutput else { return label(updatedAt, now: now, calendar: calendar, locale: locale) }
        let seconds = now.timeIntervalSince(updatedAt)
        if seconds < 60 { return "just started" }
        if seconds < 3600 { return "for \(Int(seconds / 60)) min" }
        return "since " + label(updatedAt, now: now, calendar: calendar, locale: locale)
    }
}

/// How long the chat's current turn has run, for the header.
public enum ChatTurnClock {
    /// When the turn on screen began: your latest message, while the chat works.
    public static func start(_ messages: [ChatMessage], working: Bool) -> Date? {
        guard working else { return nil }
        return messages.last { $0.kind == .user }?.at
    }

    /// "turn 40 s", "turn 18 min", "turn 1 h 05 min".
    public static func label(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "turn \(total) s" }
        if total < 3600 { return "turn \(total / 60) min" }
        return "turn \(total / 3600) h \(String(format: "%02d", total % 3600 / 60)) min"
    }

    /// "40 s", "4 min", "1 h 05 min", for how long something has waited.
    public static func short(_ seconds: TimeInterval) -> String {
        String(label(seconds).dropFirst(5))
    }
}

/// The card at the end of a waiting chat's transcript.
public struct ChatHandoff: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var action: ComposerPlan.Action?

    /// What the card says and offers, given the composer's plan for the chat.
    public static func card(plan: ComposerPlan, hasURL: Bool) -> ChatHandoff {
        let action: ComposerPlan.Action? = {
            if let action = plan.action, action != .queue { return action }
            return hasURL ? .openInProvider : nil
        }()
        let detail = plan.canSend
            ? "It may be asking a question, which you can answer below, or for an approval, which only the place it runs can give."
            : "It's asking a question or for an approval. Burro can't answer approvals; answer where the chat runs."
        return ChatHandoff(title: "Waiting for you", detail: detail, action: action)
    }
}
