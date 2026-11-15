// The Brief: what the Orchestrator keeps current for you between questions. Items come from
// triage results (OrchestratorTriage.swift) and from one rule with no model call: a chat that has
// been working with no sign of life is "stuck" (45 minutes with no new output; three hours when
// one tool call is still running or only a status time can be seen: `StuckWatch`). One open item per chat; a newer result for
// the same chat replaces it; it resolves on its own when the chat moves on (it starts working again,
// shows new activity, or stops waiting and has nothing left to read), and items leave after seven
// days. A drafted reply is never sent: it becomes an ordinary proposal in `actions.json`, shown with
// Send / Edit / Discard, and the item keeps its id. Below the confidence threshold there is no
// draft, just the headline.
//
// `brief.json` lives in the Orchestrator's folder: owner-only, written by Burro with a locked
// read-modify-write like the proposals file, read by `burro-mcp`'s `brief` tool. Reads are
// tolerant (a damaged file is an empty brief; items that don't decode are skipped).
import Foundation

public struct BriefItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case decision, blocked, failed, looping, stuck, done, shipped, suggestion
        /// Shown under "Needs you" (amber).
        public var needsYou: Bool { self == .decision || self == .blocked || self == .failed || self == .looping }
    }
    public var id: String
    public var chatID: String?
    public var chatTitle: String?
    public var machine: String?
    public var kind: Kind
    public var headline: String
    public var detail: String?
    public var question: String?
    public var options: [String]?
    /// The drafted reply's proposal in `actions.json`, when triage drafted one.
    public var proposalID: String?
    public var sourceHash: String
    public var confidence: Double?
    /// The chat's last update when the item was written; newer activity resolves it.
    public var chatUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), chatID: String?, chatTitle: String? = nil, machine: String? = nil, kind: Kind,
                headline: String, detail: String? = nil, question: String? = nil, options: [String]? = nil, proposalID: String? = nil,
                sourceHash: String, confidence: Double? = nil, chatUpdatedAt: Date? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id; self.chatID = chatID; self.chatTitle = chatTitle; self.machine = machine; self.kind = kind; self.headline = headline
        self.detail = detail; self.question = question; self.options = options; self.proposalID = proposalID; self.sourceHash = sourceHash
        self.confidence = confidence; self.chatUpdatedAt = chatUpdatedAt; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
    public var isOpen: Bool { resolvedAt == nil }
}

/// The whole brief file: items, and the last message hash triaged per chat (so a chat that stopped
/// again without anything new isn't triaged twice, even when triage found nothing to say).
public struct BriefFile: Sendable, Equatable {
    public var items: [BriefItem] = []
    public var triaged: [String: String] = [:]
    public init(items: [BriefItem] = [], triaged: [String: String] = [:]) { self.items = items; self.triaged = triaged }
    public var open: [BriefItem] { items.filter(\.isOpen) }
}

/// A chat's state as the reducer needs it, from one agent sample.
public struct BriefChatState: Sendable, Equatable {
    public var id: String
    public var waiting: Bool
    public var working: Bool
    /// Finished with a result you haven't read.
    public var unread: Bool
    public var updatedAt: Date
    /// Whether `updatedAt` moves as the transcript grows (Codex's thread time follows its log;
    /// Claude Code's session record changes only when its status does).
    public var updatesWhileWorking: Bool
    /// On this Mac, where its transcript can be looked at without SSH.
    public var local: Bool
    /// The latest sign of life Burro has seen: `updatedAt`, or a newer transcript change
    /// (filled in from `StuckWatch`).
    public var lastSignal: Date
    public init(id: String, waiting: Bool = false, working: Bool = false, unread: Bool = false, updatedAt: Date,
                updatesWhileWorking: Bool = true, local: Bool = true, lastSignal: Date? = nil) {
        self.id = id; self.waiting = waiting; self.working = working; self.unread = unread; self.updatedAt = updatedAt
        self.updatesWhileWorking = updatesWhileWorking; self.local = local; self.lastSignal = max(updatedAt, lastSignal ?? updatedAt)
    }
    public init(_ session: AgentSession) {
        self.init(id: session.id, waiting: session.state == .waiting, working: session.state == .working, unread: session.isDone,
                  updatedAt: session.updatedAt, updatesWhileWorking: session.provider == .codex, local: session.remote == nil)
    }
}

public enum BriefReducer {
    public static let keep: TimeInterval = 7 * 86_400
    /// New activity this much after an item was written means the chat moved on (a little slack,
    /// because a chat keeps writing its title and cost for a moment after it stops).
    public static let activitySlack: TimeInterval = 120
    public static let stuckAfter: TimeInterval = 45 * 60
    static let limit = 300

    /// What applying a result asks the caller to do with proposals.
    public struct Change: Sendable, Equatable {
        /// The item that should carry a drafted reply, and the draft (confidence above the threshold).
        public var draft: (itemID: String, text: String)?
        /// Proposals of replaced or resolved items, to discard if still waiting.
        public var discard: [String] = []
        public static func == (a: Change, b: Change) -> Bool {
            a.draft?.itemID == b.draft?.itemID && a.draft?.text == b.draft?.text && a.discard == b.discard
        }
    }

    /// Applies one triage result: replaces the chat's open item (keeping its id and creation time
    /// when the kind is unchanged), or resolves it when triage found nothing.
    public static func apply(_ result: TriageResult, title: String, machine: String?, sourceHash: String, chatUpdatedAt: Date?,
                             to file: inout BriefFile, now: Date) -> Change {
        var change = Change()
        file.triaged[result.chatID] = sourceHash
        let existing = file.items.firstIndex { $0.chatID == result.chatID && $0.isOpen }
        guard let kind = itemKind(result.kind) else {
            if let index = existing {
                file.items[index].resolvedAt = now
                if let proposal = file.items[index].proposalID { change.discard.append(proposal) }
            }
            return change
        }
        var item: BriefItem
        if let index = existing {
            item = file.items[index]
            if let proposal = item.proposalID { change.discard.append(proposal) }
            if item.kind != kind { item.createdAt = now }
            file.items.remove(at: index)
        } else {
            item = BriefItem(chatID: result.chatID, kind: kind, headline: result.headline, sourceHash: sourceHash, createdAt: now)
        }
        item.kind = kind; item.headline = result.headline; item.chatTitle = title; item.machine = machine
        item.question = result.question; item.options = result.options.isEmpty ? nil : result.options
        item.proposalID = nil; item.sourceHash = sourceHash; item.confidence = result.confidence
        item.chatUpdatedAt = chatUpdatedAt; item.updatedAt = now; item.resolvedAt = nil
        item.detail = result.confidence < OrchestratorTriage.draftConfidence && kind.needsYou ? "Worth a look" : nil
        file.items.append(item)
        if kind.needsYou, let draft = result.draftReply, result.confidence >= OrchestratorTriage.draftConfidence {
            change.draft = (item.id, draft)
        }
        return change
    }

    static func itemKind(_ kind: TriageKind) -> BriefItem.Kind? {
        switch kind {
        case .decision: .decision
        case .blocked: .blocked
        case .failed: .failed
        case .looping: .looping
        case .done: .done
        case .nothing: nil
        }
    }

    /// Records the proposal made for an item's draft.
    public static func attach(proposal: String, to itemID: String, in file: inout BriefFile) {
        guard let index = file.items.firstIndex(where: { $0.id == itemID }) else { return }
        file.items[index].proposalID = proposal
    }

    /// A rule-based "stuck" item for a chat working with no sign of life (see `StuckWatch`);
    /// nothing when the chat already has an open item. `longStep` says one tool call has been
    /// running the whole time.
    @discardableResult
    public static func stuck(chatID: String, title: String, machine: String?, since: Date, chatUpdatedAt: Date, longStep: Bool = false,
                             in file: inout BriefFile, now: Date) -> Bool {
        guard !file.items.contains(where: { $0.chatID == chatID && $0.isOpen }) else { return false }
        file.items.append(BriefItem(chatID: chatID, chatTitle: title, machine: machine, kind: .stuck,
                                    headline: stuckHeadline(quietFor: now.timeIntervalSince(since), longStep: longStep),
                                    sourceHash: "stuck:\(Int(chatUpdatedAt.timeIntervalSince1970))",
                                    chatUpdatedAt: chatUpdatedAt, createdAt: now))
        return true
    }

    static func stuckHeadline(quietFor seconds: TimeInterval, longStep: Bool) -> String {
        let minutes = max(0, Int(seconds / 60))
        let span = minutes < 120 ? "\(minutes) min" : "\(minutes / 60) h"
        return longStep ? "One step running for \(span) with no output" : "Working with no new output for \(span)"
    }

    /// Resolves open items whose chat moved on, and drops anything older than a week. Returns the
    /// proposals of resolved items, to discard if still waiting. Chats missing from the sample (a
    /// machine offline) keep their items.
    public static func reconcile(_ file: inout BriefFile, chats: [BriefChatState], now: Date) -> [String] {
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var discard: [String] = []
        for index in file.items.indices where file.items[index].isOpen {
            let item = file.items[index]
            guard let id = item.chatID, let chat = byID[id] else { continue }
            if movedOn(item, chat) {
                file.items[index].resolvedAt = now
                if let proposal = item.proposalID { discard.append(proposal) }
            }
        }
        prune(&file, now: now)
        return discard
    }

    static func movedOn(_ item: BriefItem, _ chat: BriefChatState) -> Bool {
        let newer = item.chatUpdatedAt.map { chat.updatedAt.timeIntervalSince($0) > activitySlack } ?? false
        if item.kind == .stuck { return !chat.working || chat.lastSignal > (item.chatUpdatedAt ?? .distantPast) }
        return chat.working || newer || (!chat.waiting && !chat.unread)
    }

    public static func prune(_ file: inout BriefFile, now: Date) {
        file.items = Array(file.items.filter { now.timeIntervalSince($0.createdAt) < keep && now.timeIntervalSince($0.updatedAt) < keep }.suffix(limit))
        let chats = Set(file.items.compactMap(\.chatID))
        if file.triaged.count > limit { file.triaged = file.triaged.filter { chats.contains($0.key) } }
    }

    /// Sections as Home shows them, newest first.
    public static func needsYou(_ file: BriefFile) -> [BriefItem] { file.open.filter(\.kind.needsYou).sorted { $0.updatedAt > $1.updatedAt } }
    public static func finished(_ file: BriefFile) -> [BriefItem] { file.open.filter { $0.kind == .done }.sorted { $0.updatedAt > $1.updatedAt } }
    public static func stuck(_ file: BriefFile) -> [BriefItem] { file.open.filter { $0.kind == .stuck }.sorted { $0.updatedAt > $1.updatedAt } }
}

/// Notices chats working with no sign of life, using the best signal there is for each:
/// - Codex (any machine): its thread time, which follows every line its log gets.
/// - Claude Code on this Mac: its session record only changes with its status, so the transcript
///   is looked at (`dueChecks`, then `record`) once the record has been quiet for 45 minutes, and
///   again every 5 minutes while it stays quiet; a transcript change counts as life.
/// - Claude Code on another machine: only its status time is visible without opening SSH for
///   this, so the bar is three hours.
/// A chat whose transcript ends on a tool call still running (a long build, a sub-agent) is a
/// long quiet step, not a stall: it is flagged only after three hours.
public struct StuckWatch: Sendable, Equatable {
    public static let checkEvery: TimeInterval = 300
    public static let longStepAfter: TimeInterval = 3 * 3600
    public static let statusOnlyAfter: TimeInterval = 3 * 3600

    /// What one look at a transcript found.
    public struct Glance: Sendable, Equatable {
        public var modified: Date?
        public var toolRunning: Bool
        public var revision: UInt64?
        public init(modified: Date?, toolRunning: Bool, revision: UInt64? = nil) {
            self.modified = modified; self.toolRunning = toolRunning; self.revision = revision
        }
        /// From a transcript read: the file's change time (else its last message's), and whether
        /// it ends on a tool call that has no output yet.
        public init(_ transcript: ChatTranscript, revision: UInt64?) {
            let last = transcript.messages.last
            self.init(modified: transcript.modified ?? transcript.messages.compactMap(\.at).max(),
                      toolRunning: last?.kind == .tool && last?.output == nil, revision: revision)
        }
    }

    private struct Progress: Sendable, Equatable {
        var modified: Date?
        var toolRunning = false
        var revision: UInt64?
        var checkedAt: Date
        var looked = false
        /// Its transcript couldn't be read: judged like a chat on another machine.
        var blind = false
    }
    private var progress: [String: Progress] = [:]
    public init() {}

    /// The latest sign of life for a chat: its own time or a newer transcript change.
    public func lastSignal(_ chat: BriefChatState) -> Date {
        max(chat.updatedAt, progress[chat.id]?.modified ?? .distantPast)
    }
    /// The revision of the transcript last looked at, to pass back to the reader.
    public func revision(_ id: String) -> UInt64? { progress[id]?.revision }
    /// Whether the last look found one tool call still running.
    public func longStep(_ id: String) -> Bool { progress[id]?.toolRunning == true }

    /// How long a chat may stay quiet before it counts as stuck; nil while it can't be judged yet
    /// (Claude Code on this Mac before its transcript was looked at).
    public func threshold(_ chat: BriefChatState) -> TimeInterval? {
        if progress[chat.id]?.toolRunning == true { return Self.longStepAfter }
        if chat.updatesWhileWorking { return BriefReducer.stuckAfter }
        if chat.local, let entry = progress[chat.id] {
            return entry.blind ? Self.statusOnlyAfter : (entry.looked ? BriefReducer.stuckAfter : nil)
        }
        if chat.local { return nil }
        return Self.statusOnlyAfter
    }

    /// Chats on this Mac quiet for 45 minutes whose transcript should be looked at now. Marks them
    /// as being looked at, so a slow read isn't asked for twice.
    public mutating func dueChecks(_ chats: [BriefChatState], now: Date) -> [String] {
        var due: [String] = []
        for chat in chats where chat.working && chat.local && now.timeIntervalSince(lastSignal(chat)) >= BriefReducer.stuckAfter {
            if let checked = progress[chat.id]?.checkedAt, now.timeIntervalSince(checked) < Self.checkEvery { continue }
            progress[chat.id, default: Progress(checkedAt: now)].checkedAt = now
            due.append(chat.id)
        }
        return due
    }

    /// Records a look at a chat's transcript: what it found, nil when it was unchanged since the
    /// last look, or `unreadable` when it couldn't be read (then the three-hour bar applies).
    public mutating func record(_ id: String, glance: Glance?, unreadable: Bool = false, now: Date) {
        var entry = progress[id] ?? Progress(checkedAt: now)
        entry.checkedAt = now
        entry.looked = true
        if unreadable {
            entry.blind = entry.revision == nil
        } else if let glance {
            entry.blind = false
            if let modified = glance.modified { entry.modified = max(entry.modified ?? .distantPast, modified) }
            entry.toolRunning = glance.toolRunning
            entry.revision = glance.revision ?? entry.revision
        }
        progress[id] = entry
    }

    /// Returns the chats stuck now, with the sign of life their quiet is counted from. Only working
    /// chats count; anything known about the others is forgotten.
    public mutating func update(_ chats: [BriefChatState], now: Date) -> [(id: String, since: Date, updatedAt: Date)] {
        let working = Set(chats.filter(\.working).map(\.id))
        progress = progress.filter { working.contains($0.key) }
        return chats.compactMap { chat in
            guard chat.working, let threshold = threshold(chat) else { return nil }
            let since = lastSignal(chat)
            return now.timeIntervalSince(since) >= threshold ? (chat.id, since, since) : nil
        }
    }
}

// MARK: File

/// `brief.json`: every change is a locked read-modify-write.
public struct BriefStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }
    public static var standard: BriefStore { BriefStore(url: Orchestrator.briefURL) }
    static let maxBytes = 4 << 20

    public func load() -> BriefFile {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? 0) <= Self.maxBytes,
              let data = try? Data(contentsOf: url) else { return BriefFile() }
        return Self.decode(data)
    }

    @discardableResult
    public func update<T>(now: Date = Date(), _ body: (inout BriefFile) throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var file = load()
        let before = file
        let value = try body(&file)
        BriefReducer.prune(&file, now: now)
        if file != before { try write(file) }
        return value
    }

    private func write(_ file: BriefFile) throws {
        let data = try Self.encode(file)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func encode(_ file: BriefFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(version: 1, items: file.items, triaged: file.triaged))
    }

    static func decode(_ data: Data) -> BriefFile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return BriefFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let items = (object["items"] as? [Any] ?? []).compactMap { row -> BriefItem? in
            guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(BriefItem.self, from: data)
        }
        let triaged = (object["triaged"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return BriefFile(items: items, triaged: triaged)
    }

    private struct Wire: Encodable {
        var version: Int
        var items: [BriefItem]
        var triaged: [String: String]
    }
}

// MARK: Tool

extension OrchestratorTools {
    static var briefDefinition: [String: Any] {
        ["name": "brief",
         "description": "Call this first. The standing Brief Burro keeps current between questions: open items with ids, kinds (decision, blocked, failed, looping, stuck, done), the chat they belong to, headlines, questions, whether a drafted reply waits for the user, and their age.",
         "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]]
    }

    /// `brief.json` beside the snapshot.
    var briefFile: BriefFile { BriefStore(url: stateURL.deletingLastPathComponent().appendingPathComponent("brief.json")).load() }

    /// What the Brief says about one chat, for `chat_digest`: nil when it has no open item for it.
    /// `current` is false when the chat changed after triage read it.
    func briefLines(for chat: AgentSession, file: BriefFile) -> (lines: [String], current: Bool)? {
        guard let item = file.open.filter({ $0.chatID?.lowercased() == chat.id.lowercased() }).max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        let now = now()
        let current = item.chatUpdatedAt.map { chat.updatedAt.timeIntervalSince($0) <= BriefReducer.activitySlack } ?? false
        var lines = ["Brief (\(item.kind == .stuck ? "rule" : "triage"), \(Self.age(item.updatedAt, now: now))): [\(item.kind.rawValue)] \(item.headline)"]
        if let question = item.question { lines.append("  Question: \(question)") }
        if let options = item.options, !options.isEmpty { lines.append("  Options: \(options.joined(separator: " | "))") }
        let draft = Self.draftLine(item, actions: actions.load(), now: now)
        if !draft.isEmpty { lines.append(String(draft.dropFirst())) }
        lines.append(current ? "  The brief is current for this chat; no need to re-read it unless asked."
                             : "  The chat changed after triage read it; what follows is newer.")
        return (lines, current)
    }

    /// The `brief` tool: open items from `brief.json` beside the snapshot, with their proposals' state.
    func brief() -> (String, Bool) {
        let file = briefFile
        let actions = actions.load()
        let now = now()
        let open = file.open.sorted { (rank($0.kind), $1.updatedAt) < (rank($1.kind), $0.updatedAt) }
        guard !open.isEmpty else { return ("The Brief is empty: triage has nothing open. Use overview for the full picture.", false) }
        var lines = ["Brief: \(open.count) open item\(open.count == 1 ? "" : "s"). Read a chat only when its update is newer than its item."]
        for item in open {
            var parts = ["- [\(item.kind.rawValue)] \(item.headline)"]
            if let title = item.chatTitle { parts.append("chat \"\(title)\"" + (item.machine.map { " on \($0)" } ?? "")) }
            if let chat = item.chatID { parts.append("chat id \(chat)") }
            parts.append("item \(item.id)")
            parts.append("updated \(Self.age(item.updatedAt, now: now))")
            if let updated = item.chatUpdatedAt { parts.append("chat as of \(Self.age(updated, now: now))") }
            var line = parts.joined(separator: " · ")
            if let question = item.question { line += "\n  Question: \(question)" }
            if let options = item.options, !options.isEmpty { line += "\n  Options: \(options.joined(separator: " | "))" }
            line += Self.draftLine(item, actions: actions, now: now)
            lines.append(line)
        }
        return (lines.joined(separator: "\n"), false)
    }

    /// An item's drafted reply and its state, the same in `brief` and `chat_digest`: triage's own
    /// draft, else a reply you proposed for that chat that still waits.
    static func draftLine(_ item: BriefItem, actions: [OrchestratorAction], now: Date) -> String {
        let linked = item.proposalID.flatMap { id in actions.first { $0.id == id } }
        if let id = item.proposalID, linked == nil, BriefDrafts.waitingReply(chatID: item.chatID, actions: actions, now: now) == nil {
            return "\n  Draft reply (proposal \(id)): discarded"
        }
        guard let action = linked ?? BriefDrafts.waitingReply(chatID: item.chatID, actions: actions, now: now) else {
            return item.kind.needsYou ? "\n  No draft: worth a look." : ""
        }
        let state: String
        if action.status == .sent { state = "sent" }
        else if action.isExpired(now: now) { state = "expired" }
        else { state = "waiting for the user's Send: \"\(OrchestratorEvent.clip(action.text, 200))\"" }
        return "\n  Draft reply (proposal \(action.id)\(action.conversation == BriefDrafts.triageConversation ? ", by triage" : "")): \(state)"
    }

    private func rank(_ kind: BriefItem.Kind) -> Int { kind.needsYou ? 0 : kind == .stuck ? 1 : 2 }
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
