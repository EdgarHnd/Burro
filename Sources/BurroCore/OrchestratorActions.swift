// Proposed actions: a reply to a chat, or a new chat, that the orchestrator wants sent. The tool
// server only records them; nothing is sent until the user clicks Send on the action's card in
// Burro, which runs the ordinary reply or launch path from the app. They live in `actions.json`
// (owner-only, next to the snapshot in the orchestrator's folder), survive a relaunch, and expire
// a day after they were proposed: an expired proposal stays on screen, marked expired, until it is
// discarded or a week has passed. Reads skip entries they can't decode instead of failing.
import Foundation

public struct OrchestratorAction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case reply, start }
    public enum Status: String, Codable, Sendable { case pending, sent }

    public var id: String
    public var kind: Kind
    public var createdAt: Date
    /// The reply, or the new chat's prompt. Editable on the card before sending.
    public var text: String
    /// Reply: the chat (full Burro id), with its title and machine when the snapshot knew them.
    public var chatID: String?
    public var chatTitle: String?
    public var machine: String?
    /// Start: `claude` or `codex`, the folder, and optional model, effort and access.
    public var agent: String?
    public var folder: String?
    public var model: String?
    public var effort: String?
    public var access: String?
    /// The orchestrator conversation that proposed it.
    public var conversation: String?
    public var status: Status
    /// What happened on Send: the confirmation, or why it didn't go (it stays pending then).
    public var result: String?
    public var error: String?
    public var sentAt: Date?
    /// A started chat's Burro id.
    public var startedChatID: String?

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, createdAt: Date, text: String, chatID: String? = nil,
                chatTitle: String? = nil, machine: String? = nil, agent: String? = nil, folder: String? = nil, model: String? = nil,
                effort: String? = nil, access: String? = nil, conversation: String? = nil, status: Status = .pending) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.text = text; self.chatID = chatID; self.chatTitle = chatTitle
        self.machine = machine; self.agent = agent; self.folder = folder; self.model = model; self.effort = effort; self.access = access
        self.conversation = conversation; self.status = status
    }

    /// Proposals are good for a day.
    public static let lifetime: TimeInterval = 86_400
    public func isExpired(now: Date = Date()) -> Bool {
        status == .pending && now.timeIntervalSince(createdAt) >= Self.lifetime
    }
    public func isWaiting(now: Date = Date()) -> Bool { status == .pending && !isExpired(now: now) }

    public var provider: LaunchProvider? { agent.flatMap(LaunchProvider.init(rawValue:)) }
    public var launchAccess: LaunchAccess { access.flatMap(LaunchAccess.init(rawValue:)) ?? .ask }

    /// What will happen, in one line.
    public var headline: String {
        switch kind {
        case .reply:
            let title = chatTitle.map { "“\($0)”" } ?? "a chat"
            return "Reply to \(title) on \(machine ?? "This Mac")"
        case .start:
            let name = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a folder"
            return "Start a \(provider?.title ?? "Claude Code") chat in \(name)"
        }
    }

    /// Two proposals are the same when they'd do the same thing to the same target.
    func sameProposal(as other: OrchestratorAction) -> Bool {
        kind == other.kind && chatID == other.chatID && agent == other.agent && folder == other.folder
            && model == other.model && effort == other.effort && launchAccess == other.launchAccess
            && text.trimmingCharacters(in: .whitespacesAndNewlines) == other.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The proposals file. Every change is a locked read-modify-write, because Burro and the tool
/// server both write it.
public struct OrchestratorActionStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }
    public static var standard: OrchestratorActionStore { OrchestratorActionStore(url: Orchestrator.actionsURL) }
    /// Anything older than this leaves the file, whatever its state.
    public static let keep: TimeInterval = 7 * 86_400
    static let limit = 200

    public func load() -> [OrchestratorAction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data)
    }

    /// Records a proposal, or returns the identical one already waiting.
    public func propose(_ action: OrchestratorAction, now: Date = Date()) throws -> (action: OrchestratorAction, duplicate: Bool) {
        try update(now: now) { actions in
            if let existing = actions.first(where: { $0.isWaiting(now: now) && $0.sameProposal(as: action) }) { return (existing, true) }
            actions.append(action)
            return (action, false)
        }
    }

    public func discard(_ id: String) throws {
        try update { $0.removeAll { $0.id == id } }
    }

    /// Changes one action in place; false when it's gone.
    @discardableResult
    public func modify(_ id: String, _ change: (inout OrchestratorAction) -> Void) throws -> Bool {
        try update { actions in
            guard let index = actions.firstIndex(where: { $0.id == id }) else { return false }
            change(&actions[index])
            return true
        }
    }

    @discardableResult
    public func update<T>(now: Date = Date(), _ body: (inout [OrchestratorAction]) throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var actions = load()
        let value = try body(&actions)
        try write(Self.prune(actions, now: now))
        return value
    }

    private func write(_ actions: [OrchestratorAction]) throws {
        let data = try Self.encode(actions)
        // Created owner-only, then moved into place, so the file is never readable by others.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func prune(_ actions: [OrchestratorAction], now: Date) -> [OrchestratorAction] {
        Array(actions.filter { now.timeIntervalSince($0.createdAt) < keep }.suffix(limit))
    }

    static func encode(_ actions: [OrchestratorAction]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(version: 1, actions: actions))
    }

    /// Tolerant: a damaged file reads as empty, and entries that don't decode are skipped.
    static func decode(_ data: Data) -> [OrchestratorAction] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["actions"] as? [Any] else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return rows.compactMap { row in
            guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(OrchestratorAction.self, from: data)
        }
    }

    private struct File: Encodable {
        var version: Int
        var actions: [OrchestratorAction]
    }
}
