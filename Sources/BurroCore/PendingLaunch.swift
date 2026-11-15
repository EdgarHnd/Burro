// A chat you just started, from the moment the New chat sheet closes until the real session shows
// up in Burro's feed. It starts as "Starting…" (for Claude this covers the start check, which can
// take up to 20 seconds), becomes "started" once the provider answers with a thread or session id,
// and goes away when a feed session with that id appears; the Chats page then selects the real
// chat if the pending row was selected. A failed start keeps its error and the exact request, so
// Retry can reopen the sheet prefilled. A started chat that hasn't appeared after a while says so
// instead of spinning forever.
// A chat started on another machine says "Starting on <Machine>…". Once that machine answers, the
// row hands over at once: a placeholder for the chat (`remote:<host>:<provider>:<id>`) is put in
// that machine's list, so the Chats page can open the conversation before the next check lists it,
// and the hidden row keeps re-adding it until a check made after the start lists the real chat (or
// two minutes pass). Pure state; the app drives it.
import Foundation

public struct PendingLaunch: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case starting
        case started(LaunchResult)
        case failed(String)
    }
    public let id: UUID
    public var request: LaunchRequest
    public var startedAt: Date
    /// Whether the owner asked to follow the chat (⌘↩) rather than stay where he was (⇧⌘↩).
    public var follow: Bool
    public var phase: Phase
    /// The machine it starts on (a remote host id), nil for this Mac, and that machine's name.
    public var machine: UUID?
    public var machineName: String?
    /// When the provider answered with the chat's id.
    public var confirmedAt: Date?
    /// A remote chat whose placeholder took over the row: hidden from the list, kept until a check lists it.
    public var handedOver = false

    /// How long a started chat may take to appear in the feed before the row says so.
    public static let listingGrace: TimeInterval = 45
    /// The same for another machine, whose list is refreshed less often.
    public static let remoteListingGrace: TimeInterval = 90
    /// How long a remote placeholder is kept while no check lists the real chat.
    public static let placeholderLifetime: TimeInterval = 120
    /// The evidence a placeholder carries, so a check's real row is never mistaken for it.
    public static let placeholderEvidence = "Just started from Burro; waiting for the next check."
    /// The selection id used on the Chats page for this row (never a real session id).
    public static let rowPrefix = "launch:"
    public var rowID: String { Self.rowPrefix + id.uuidString }

    public init(id: UUID = UUID(), request: LaunchRequest, startedAt: Date, follow: Bool, phase: Phase = .starting,
                machine: UUID? = nil, machineName: String? = nil) {
        self.id = id; self.request = request; self.startedAt = startedAt; self.follow = follow; self.phase = phase
        self.machine = machine; self.machineName = machineName
    }

    public var isRemote: Bool { machine != nil }
    /// "This Mac" or the machine's name.
    public var place: String { machine == nil ? "This Mac" : (machineName ?? "another machine") }

    /// The Chats page's id for the started chat, once known: "codex:<thread>" / "claude:<session>"
    /// on this Mac, "remote:<host id>:<provider>:<id>" on another machine.
    public var chatID: String? {
        guard case .started(let result) = phase else { return nil }
        let session = result.sessionID.lowercased()
        if let machine { return RemoteLaunch.chatID(hostID: machine, provider: result.provider, sessionID: session) }
        return "\(result.provider.rawValue):\(session)"
    }
    /// `chatID` lowercased, for matching.
    public var sessionID: String? { chatID?.lowercased() }
    public func matches(_ feedID: String) -> Bool { sessionID.map { $0 == feedID.lowercased() } ?? false }

    public var failure: String? { if case .failed(let message) = phase { message } else { nil } }
    public var isFailed: Bool { failure != nil }

    /// Started, but not in the feed after the grace period.
    public func isOverdue(now: Date) -> Bool {
        guard case .started = phase else { return false }
        return now.timeIntervalSince(startedAt) > (isRemote ? Self.remoteListingGrace : Self.listingGrace)
    }

    /// What the Chats page shows for a remote chat that started but isn't in its machine's list yet.
    public func placeholderSession(now: Date) -> AgentSession? {
        guard let machine, case .started(let result) = phase, let chatID else { return nil }
        let at = confirmedAt ?? now
        return AgentSession(id: chatID, provider: result.provider == .codex ? .codex : .claude, title: title, cwd: result.folder,
                            state: .working, updatedAt: at, pid: nil, evidence: Self.placeholderEvidence,
                            remote: RemoteOrigin(hostID: machine, hostName: place, sampledAt: at, stale: false),
                            model: request.model, effort: request.effort, startedAt: startedAt)
    }

    /// The row's title: the prompt's first non-empty line, shortened.
    public var title: String {
        let line = request.trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New chat" }
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    /// One short line for the row.
    public func status(now: Date) -> String {
        let starting = isRemote ? "Starting on \(place)…" : "Starting…"
        switch phase {
        case .starting: return request.provider == .claude ? "\(starting) checking it got going" : starting
        case .started:
            if isOverdue(now: now) { return isRemote ? "Started · appears at the next check" : "Started · not in the list yet" }
            return "Started · opening…"
        case .failed(let message): return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Didn't start"
        }
    }
}

/// Every pending launch, newest first.
public struct PendingLaunches: Equatable, Sendable {
    public private(set) var items: [PendingLaunch] = []
    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    /// The rows the list shows: everything but remote chats already handed over to their placeholder.
    public var visible: [PendingLaunch] { items.filter { !$0.handedOver } }
    public func launch(_ id: UUID) -> PendingLaunch? { items.first { $0.id == id } }
    /// The pending launch a Chats-page selection points at, if any.
    public func launch(rowID: String?) -> PendingLaunch? {
        guard let rowID, rowID.hasPrefix(PendingLaunch.rowPrefix) else { return nil }
        return items.first { $0.rowID == rowID }
    }

    @discardableResult
    public mutating func begin(_ request: LaunchRequest, follow: Bool, now: Date, id: UUID = UUID(),
                               machine: UUID? = nil, machineName: String? = nil) -> PendingLaunch {
        let launch = PendingLaunch(id: id, request: request, startedAt: now, follow: follow, machine: machine, machineName: machineName)
        items.insert(launch, at: 0)
        return launch
    }
    public mutating func succeed(_ id: UUID, with result: LaunchResult, now: Date = Date()) {
        update(id) { $0.phase = .started(result); $0.confirmedAt = now }
    }
    public mutating func fail(_ id: UUID, message: String) { update(id) { $0.phase = .failed(message) } }
    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Hands every started launch whose chat is now in the feed over to it and returns the pairs
    /// (pending row id → feed chat id), so a selected pending row can select the real chat. A chat on
    /// this Mac removes its row; a remote one (its placeholder is in the feed) only hides it until
    /// `settle` sees a check list the chat.
    public mutating func reconcile(feedIDs: [String]) -> [(rowID: String, sessionID: String)] {
        let byKey = Dictionary(feedIDs.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var matched: [(rowID: String, sessionID: String)] = []
        for index in items.indices {
            guard let key = items[index].sessionID, let feedID = byKey[key] else { continue }
            if !items[index].handedOver { matched.append((items[index].rowID, feedID)) }
            items[index].handedOver = true
        }
        items.removeAll { $0.handedOver && !$0.isRemote }
        return matched
    }

    /// Remote chats that need their placeholder in their machine's list: started and not yet settled.
    public func placeholders(now: Date) -> [(hostID: UUID, session: AgentSession)] {
        items.compactMap { launch in
            guard let machine = launch.machine, let session = launch.placeholderSession(now: now) else { return nil }
            return (machine, session)
        }
    }

    /// Drops remote launches a check has listed: the machine's sample was taken at or after the start
    /// was confirmed and contains the chat (pass the ids of real rows only, never placeholders). Also
    /// drops handed-over remote launches whose placeholder outlived `placeholderLifetime`. `samples` holds each
    /// machine's sample time and chat ids.
    public mutating func settle(samples: [UUID: (sampledAt: Date?, ids: [String])], now: Date) {
        items.removeAll { launch in
            guard let machine = launch.machine, let key = launch.sessionID, let confirmed = launch.confirmedAt else { return false }
            if launch.handedOver, now.timeIntervalSince(confirmed) > PendingLaunch.placeholderLifetime { return true }
            guard let sample = samples[machine], let at = sample.sampledAt, at >= confirmed else { return false }
            return sample.ids.contains { $0.lowercased() == key }
        }
    }

    /// Whether any launch is still waiting for its session to appear.
    public var awaitingFeed: Bool { items.contains { if case .started = $0.phase { true } else { false } } }

    private mutating func update(_ id: UUID, _ change: (inout PendingLaunch) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
