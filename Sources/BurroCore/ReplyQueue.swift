// Replies you queued for a chat that is still working: "Queue for when it's done". Queuing is
// your explicit action for that message; the app sends it once the chat has been idle for a few
// seconds, through the normal reply path and its checks, and drops it with a notice (text kept,
// so you can edit it back) when the chat is gone, is open elsewhere, or is still busy a day later.
// A Claude chat whose background session stays open after its turn is continued the way the
// composer's Send does it (the idle session is stopped, confirmed stopped, then resumed). A
// message is marked as going before it is sent; one found marked after a relaunch (Burro quit
// mid-send) is never sent again: it is dropped with a notice to check the chat. When the provider
// refuses at that moment because the chat is working or waiting for an answer although Burro's
// sample said idle (`ReplyRefusal`), nothing went: the message stays queued, no longer marked as
// going, and is tried again once the chat looks idle again, no sooner than `retryDelay`.
// Never more than one queued message per chat. Visible and cancellable until it goes.
//
// Saved as JSON in `reply-queue.json` (owner-only: 0600 file in a 0700 folder, written through a
// temporary file, read without following links, 1 MiB cap; a damaged file reads as empty).
import Foundation

public struct QueuedReply: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chatID: String
    public var text: String
    public var model: String?
    public var effort: String?
    public var access: String
    public var attachments: [String]
    public var queuedAt: Date
    /// Set just before it is sent; still set later means the send may have happened.
    public var dispatchedAt: Date?
    /// Set when the provider said the chat was busy at dispatch: not tried again before this.
    public var retryAfter: Date?
    public init(id: UUID = UUID(), chatID: String, request: ReplyRequest, queuedAt: Date) {
        self.id = id; self.chatID = chatID; self.text = request.text; self.model = request.model; self.effort = request.effort
        self.access = request.access.rawValue; self.attachments = request.attachments; self.queuedAt = queuedAt
    }
    public var request: ReplyRequest {
        ReplyRequest(text: text, model: model, effort: effort, access: ReplyAccess(rawValue: access) ?? .keep, attachments: attachments)
    }
}

/// What happened to a queued message: sent, or dropped and why (with its text, to edit back).
public struct ReplyQueueNotice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chatID: String
    public var text: String
    public var sent: Bool
    public var message: String
    public var at: Date
    public init(id: UUID = UUID(), chatID: String, text: String, sent: Bool, message: String, at: Date) {
        self.id = id; self.chatID = chatID; self.text = text; self.sent = sent; self.message = message; self.at = at
    }
}

public struct ReplyQueue: Codable, Sendable, Equatable {
    public var items: [QueuedReply] = []
    public var notices: [ReplyQueueNotice] = []
    public init(items: [QueuedReply] = [], notices: [ReplyQueueNotice] = []) { self.items = items; self.notices = notices }

    /// How long a chat must look idle before a queued message goes.
    public static let settle: TimeInterval = 3
    /// How long a chat may be missing from the feed before its message is dropped.
    public static let goneAfter: TimeInterval = 60
    /// A message still waiting after this long is dropped.
    public static let expiresAfter: TimeInterval = 86_400
    /// After a busy refusal, the least wait before the next try.
    public static let retryDelay: TimeInterval = 30
    static let noticeLimit = 20, noticeKeep: TimeInterval = 86_400

    public enum Decision: Equatable, Sendable { case wait, dispatch, drop(String) }

    public func item(for chatID: String) -> QueuedReply? { items.first { $0.chatID == chatID } }

    /// Adds a message; refuses a second one for the same chat or an empty one.
    public mutating func enqueue(_ item: QueuedReply) throws {
        guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.failed("Write a message first.") }
        guard item.text.count <= 100_000 else { throw LaunchError.failed("That message is too long.") }
        guard self.item(for: item.chatID) == nil else { throw LaunchError.failed("A message is already queued for this chat. Edit or cancel it first.") }
        items.append(item)
    }

    @discardableResult
    public mutating func cancel(chatID: String) -> QueuedReply? {
        guard let index = items.firstIndex(where: { $0.chatID == chatID }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func record(_ notice: ReplyQueueNotice, now: Date) {
        notices.removeAll { $0.chatID == notice.chatID }
        notices.append(notice)
        notices = Array(notices.filter { now.timeIntervalSince($0.at) < Self.noticeKeep }.suffix(Self.noticeLimit))
    }

    /// Marks the chat's message as going (before it is sent).
    public mutating func markDispatched(chatID: String, at date: Date) {
        guard let index = items.firstIndex(where: { $0.chatID == chatID }) else { return }
        items[index].dispatchedAt = date
    }

    /// Puts a message the provider refused as busy back to waiting: not marked as going, and not
    /// tried again before `retryDelay` has passed (and the chat has looked idle again).
    public mutating func requeue(chatID: String, now: Date) {
        guard let index = items.firstIndex(where: { $0.chatID == chatID }) else { return }
        items[index].dispatchedAt = nil
        items[index].retryAfter = now.addingTimeInterval(Self.retryDelay)
    }

    /// Whether a failed send keeps the message queued: only the provider's working or waiting refusal.
    public static func retries(after error: Error) -> Bool { error is ReplyRefusal }

    /// Whether the send may stop and continue an idle Claude background session: the message was
    /// queued by the owner for exactly this, so yes for Claude chats.
    public static func continuesIdleBackground(_ session: AgentSession) -> Bool { session.provider == .claude }

    public mutating func dismissNotice(chatID: String) { notices.removeAll { $0.chatID == chatID } }
    public func notice(for chatID: String) -> ReplyQueueNotice? { notices.last { $0.chatID == chatID } }

    /// Whether a queued message should go now. `missingSince`: when the chat was last seen absent
    /// from the feed (nil while present); `idleSince`: since when it has looked idle.
    public static func decision(_ item: QueuedReply, session: AgentSession?, missingSince: Date?, idleSince: Date?, now: Date) -> Decision {
        if item.dispatchedAt != nil { return .drop("Burro quit while sending this, so it may or may not have arrived. Check the chat before sending it again.") }
        if now.timeIntervalSince(item.queuedAt) >= expiresAfter { return .drop("Not sent: the chat was still busy a day later.") }
        guard let session else {
            if let missingSince, now.timeIntervalSince(missingSince) >= goneAfter { return .drop("Not sent: the chat is gone.") }
            return .wait
        }
        if session.remote?.stale == true { return .wait }
        if let retryAfter = item.retryAfter, now < retryAfter { return .wait }
        guard [.idle, .recent, .inactive].contains(session.state) else { return .wait }
        guard let idleSince, now.timeIntervalSince(idleSince) >= settle else { return .wait }
        return .dispatch
    }
}

/// The queue's file.
public struct ReplyQueueStore: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }
    public static var standard: ReplyQueueStore {
        ReplyQueueStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burro").appendingPathComponent("reply-queue.json"))
    }
    static let cap = 1024 * 1024

    public func load() -> ReplyQueue {
        guard let data = OwnerOnlyFile.read(url, cap: Self.cap) else { return ReplyQueue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ReplyQueue.self, from: data)) ?? ReplyQueue()
    }

    public func save(_ queue: ReplyQueue) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(queue)
        guard data.count <= Self.cap else { throw LaunchError.failed("The reply queue is too large to save.") }
        try OwnerOnlyFile.write(data, to: url)
    }
}

/// Owner-only files: read without following a final link (regular, owned by you, under a size
/// cap); written into a 0700 folder through a fresh 0600 temporary file renamed into place.
enum OwnerOnlyFile {
    static func read(_ url: URL, cap: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= cap else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > cap { return nil }
        }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        close(fd)
        guard written, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
