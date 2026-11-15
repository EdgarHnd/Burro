// Burro's copy of remote chats' transcripts, so a chat on another machine opens at once, stays
// readable while that machine is asleep, and a live one costs only its new bytes per refresh.
// Per chat, the host's cache folder (~/Library/Caches/Burro/Remote/<host>/transcripts/) holds
// "<stem>.jsonl", raw bytes of a slice of the remote transcript file that starts at a line start,
// and "<stem>.state", where that slice sits in the remote file. A refresh runs the fixed read-only
// script remote_tail.py over SSH with what the copy covers: the reply is either the bytes after it
// (appended in place, so the Rust worker's incremental parser reads only those), nothing when the
// file didn't grow (a header of about 150 bytes), earlier bytes for "Show earlier messages", or a
// fresh tail when the file was replaced (written to a new file renamed over the old one). The copy
// is parsed by the same worker as chats on this Mac (`ChatTranscripts.read(file:)`), so both look
// the same. When the machine can't be reached the copy is shown as it was, with when it was last
// brought up to date. Without the worker or the script, the chat is fetched in full as before
// (remote_transcript.py). Files are 0600 in 0700 folders, written under the cache lock together with
// the cache index (last opened, size), and evicted by `RemoteCache.sweep(.transcripts)` — never a
// chat open on screen (`Hold`). Bytes are never logged. `burro-mcp` never reads this folder: its
// `read_chat` uses `ChatTranscripts.load(chatID:)`, which fetches remote chats in full.
import CryptoKit
import Darwin
import Foundation

public struct RemoteTranscriptMirror: Sendable {
    /// Runs remote_tail.py on `host` with `request` (sent as base64 JSON) and returns its stdout.
    public typealias Transport = @Sendable (_ host: RemoteHost, _ request: [String: Any]) throws -> Data
    /// Parses a copy: `ChatTranscripts.read(file:provider:root:limit:after:)` in the app.
    public typealias Parser = @Sendable (_ path: String, _ provider: AgentProvider, _ root: String, _ limit: Int,
                                         _ after: UInt64?) throws -> ChatTranscriptRead
    /// The full fetch used when the copy can't be used: `remote_transcript.py`.
    public typealias Fallback = @Sendable (_ host: RemoteHost, _ provider: String, _ id: String, _ limit: Int) throws -> ChatTranscript

    public static let window = 4 << 20
    /// "Show earlier messages" never grows a copy beyond this.
    public static let maxEarlier = 16 << 20
    /// A copy that grew past this by appends starts over from a fresh tail.
    public static let maxCopy: Int64 = 48 << 20
    static let head = 4096
    /// A refresh that brought nothing new still records the time this often (for "As of").
    static let stampEvery: TimeInterval = 60

    public static let shared = RemoteTranscriptMirror()

    let cache: RemoteCache
    let transport: Transport?
    let parser: Parser?
    let fallback: Fallback

    public init(cache: RemoteCache = .shared, transport: Transport? = RemoteTranscriptMirror.defaultTransport,
                parser: Parser? = RemoteTranscriptMirror.defaultParser,
                fallback: Fallback? = nil) {
        self.cache = cache; self.transport = transport; self.parser = parser
        self.fallback = fallback ?? { try ChatTranscripts.remote(provider: $1, id: $2, host: $0, limit: $3) }
    }

    /// remote_tail.py over SSH, or nil when this build lacks the script.
    public static var defaultTransport: Transport? {
        guard RemoteScript.url("remote_tail") != nil else { return nil }
        return { host, request in try RemoteScript.run("remote_tail", request: request, host: host, timeout: 25) }
    }
    /// The Rust worker, or nil when this build lacks it.
    public static var defaultParser: Parser? {
        guard let worker = ChatTranscripts.worker else { return nil }
        return { path, provider, root, limit, after in
            try ChatTranscripts.read(file: path, provider: provider, root: root, limit: limit, after: after, worker: worker)
        }
    }

    // MARK: Results

    /// Why the copy shown is not current.
    public enum Offline: Sendable, Equatable {
        /// The machine didn't answer (the reason, for a tooltip).
        case unreachable(String)
        /// The machine answered but no longer has this chat's transcript.
        case missing
        /// Whether the chat's follow timer asks again: only for a machine that didn't answer. A
        /// chat the machine no longer has is asked again only on Refresh or when its row changes.
        public var retriesOnTimer: Bool {
            if case .unreachable = self { return true }
            return false
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var read: ChatTranscriptRead
        /// When the copy was last brought up to date; nil for a full fetch.
        public var syncedAt: Date?
        /// Set when this refresh couldn't update the copy and it is shown as of `syncedAt`.
        public var offline: Offline?
        /// The copy doesn't start at the beginning of the remote file and may still grow backwards.
        public var canShowEarlier: Bool
        /// False when the chat was fetched in full instead (no worker or script, or a reply Burro refused).
        public var mirrored: Bool
        public init(read: ChatTranscriptRead, syncedAt: Date?, offline: Offline? = nil, canShowEarlier: Bool = false, mirrored: Bool = true) {
            self.read = read; self.syncedAt = syncedAt; self.offline = offline; self.canShowEarlier = canShowEarlier; self.mirrored = mirrored
        }
    }

    /// "As of 14:02 · Mac mini unreachable · retrying in 30 s" / "As of 14:02 · no longer on Mac mini".
    public static func asOfLine(syncedAt: Date, machine: String, offline: Offline, poll: RemotePollStatus?, now: Date,
                                timeZone: TimeZone = .current) -> String {
        var parts = ["As of \(RemoteStatusLine.clock(syncedAt, now: now, timeZone: timeZone))"]
        switch offline {
        case .missing:
            parts.append("no longer on \(machine)")
        case .unreachable:
            parts.append("\(machine) unreachable")
            if let poll {
                let wait = poll.nextDue.timeIntervalSince(now)
                parts.append(wait <= 0.5 ? "retrying now" : "retrying in \(RemoteStatusLine.duration(wait))")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Reading

    /// The copy as it is, without asking the machine: for showing a chat the moment it opens.
    /// Marks the chat as opened (eviction goes by that). Nil when there is no usable copy.
    public func cached(chatID: String, host: RemoteHost, limit: Int = 300, now: Date = Date()) -> Outcome? {
        guard let parser, let chat = Chat(chatID: chatID, host: host, cache: cache), let state = chat.state(),
              let read = try? parser(chat.dataPath, chat.provider, chat.root, limit, nil) else { return nil }
        cache.touch(.transcripts, hostID: host.id, key: chatID, now: now)
        return Outcome(read: read, syncedAt: state.syncedAt, canShowEarlier: state.canShowEarlier)
    }

    /// Brings the copy up to date (or, with `earlier`, extends it backwards) and reads it. Pass the
    /// revision of what you show and an unchanged copy answers `.unchanged`. When the machine can't
    /// be reached and a copy exists, that copy is returned with `offline` set; without a copy the
    /// error is thrown as before.
    public func refresh(chatID: String, host: RemoteHost, limit: Int = 300, after revision: UInt64? = nil,
                        earlier: Bool = false, now: Date = Date()) throws -> Outcome {
        guard let (hostID, provider, id) = ChatTranscripts.identity(chatID: chatID), hostID == host.id else {
            throw ChatTranscripts.LoadError.unsupported
        }
        guard let transport, let parser, let chat = Chat(chatID: chatID, host: host, cache: cache) else {
            return try full(host: host, provider: provider, id: id, limit: limit)
        }
        let before = chat.state()
        let request = Self.request(provider: provider, id: id, state: before, earlier: earlier)
        let reply: Data
        do { reply = try transport(host, request) } catch {
            guard let before, let read = try? parser(chat.dataPath, chat.provider, chat.root, limit, revision) else { throw Self.unavailable(error, host: host) }
            return Outcome(read: read, syncedAt: before.syncedAt, offline: .unreachable(Self.message(error, host: host)),
                           canShowEarlier: before.canShowEarlier)
        }
        guard var (header, body) = try? Self.frame(reply) else {
            return try full(host: host, provider: provider, id: id, limit: limit)
        }
        // The script leaves out a path equal to the hint, which came from the state.
        if header.path == nil, request["pathHint"] != nil { header.path = before?.path }
        switch header.mode {
        case .missing:
            guard let before, let read = try? parser(chat.dataPath, chat.provider, chat.root, limit, revision) else { throw ChatTranscripts.LoadError.notFound }
            return Outcome(read: read, syncedAt: before.syncedAt, offline: .missing, canShowEarlier: before.canShowEarlier)
        case .error:
            return try full(host: host, provider: provider, id: id, limit: limit)
        case .append, .reset, .prepend:
            guard let change = Self.change(header, body: body, have: request["have"] == nil ? nil : before) else {
                return try full(host: host, provider: provider, id: id, limit: limit)
            }
            let state: State
            do { state = try chat.apply(change, header: header, expected: before, chatID: chatID, now: now) } catch {
                return try full(host: host, provider: provider, id: id, limit: limit)
            }
            do {
                let read = try parser(chat.dataPath, chat.provider, chat.root, limit, revision)
                return Outcome(read: read, syncedAt: state.syncedAt, canShowEarlier: state.canShowEarlier)
            } catch ChatTranscripts.LoadError.unavailable {
                return try full(host: host, provider: provider, id: id, limit: limit)
            }
        }
    }

    private func full(host: RemoteHost, provider: String, id: String, limit: Int) throws -> Outcome {
        Outcome(read: .loaded(try fallback(host, provider, id, limit), revision: nil), syncedAt: nil, mirrored: false)
    }

    static func message(_ error: Error, host: RemoteHost) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn't reach \(host.name) over SSH."
    }
    static func unavailable(_ error: Error, host: RemoteHost) -> Error {
        ChatTranscripts.LoadError.unavailable(message(error, host: host))
    }

    // MARK: Protocol

    /// What the copy covers, as remote_tail.py's `have`.
    public struct State: Codable, Sendable, Equatable {
        public static let currentVersion = 1
        public var version = State.currentVersion
        public var path: String
        public var dev: UInt64
        public var ino: UInt64
        /// The slice of the remote file the copy holds: bytes `start..<end`.
        public var start: Int64
        public var end: Int64
        public var size: Int64
        public var mtime: Double
        /// SHA-256 of the copy's first 4 KB, hex.
        public var headHash: String
        public var syncedAt: Date

        public var canShowEarlier: Bool { start > 0 && end - start < Int64(RemoteTranscriptMirror.maxEarlier) }
    }

    /// The request for a refresh: the copy's position (unless there is none or it grew too large),
    /// windows of 4 MiB, and 4 MiB of earlier bytes when asked. Only validated values go in.
    static func request(provider: String, id: String, state: State?, earlier: Bool) -> [String: Any] {
        var request: [String: Any] = ["provider": provider, "id": id, "initial": window, "cap": window]
        if let state, state.end - state.start <= maxCopy {
            if state.path.hasPrefix("/"), state.path.utf8.count <= 4096, !state.path.contains("\0") { request["pathHint"] = state.path }
            request["have"] = ["dev": state.dev, "ino": state.ino, "start": state.start, "end": state.end, "headHash": state.headHash]
            if earlier && state.canShowEarlier { request["earlier"] = window }
        }
        return request
    }

    public struct Header: Decodable, Sendable, Equatable {
        public enum Mode: String, Decodable, Sendable { case append, reset, prepend, missing, error }
        public var mode: Mode
        public var path: String?
        public var dev: UInt64?
        public var ino: UInt64?
        public var start: Int64?
        public var end: Int64?
        public var size: Int64?
        public var mtime: Double?
        public var count: Int
    }

    /// Splits a reply into its header line and exactly `count` bytes; anything else is refused.
    static func frame(_ data: Data) throws -> (Header, Data) {
        guard let newline = data.prefix(8192).firstIndex(of: 0x0A) else { throw CocoaError(.coderReadCorrupt) }
        let header = try JSONDecoder().decode(Header.self, from: data[data.startIndex..<newline])
        let body = data[data.index(after: newline)...]
        guard header.count >= 0, body.count == header.count, header.count <= maxEarlier + window else { throw CocoaError(.coderReadCorrupt) }
        if header.mode == .missing || header.mode == .error { guard header.count == 0 else { throw CocoaError(.coderReadCorrupt) } }
        return (header, Data(body))
    }

    enum Change: Equatable {
        case append(Data), replace(Data), prepend(Data)
    }

    /// What a header asks the copy to do, checked against what was requested; nil when it doesn't add up.
    static func change(_ header: Header, body: Data, have: State?) -> Change? {
        guard let path = header.path, path.hasPrefix("/"), path.utf8.count <= 4096, let start = header.start, let end = header.end,
              let size = header.size, header.dev != nil, header.ino != nil, header.mtime?.isFinite == true,
              0 <= start, start <= end, end <= size, end - start == Int64(body.count) || header.mode != .reset else { return nil }
        switch header.mode {
        case .reset:
            guard body.isEmpty || body.last == 0x0A else { return nil }
            return .replace(body)
        case .append:
            guard let have, header.dev == have.dev, header.ino == have.ino, start == have.start,
                  end - have.end == Int64(body.count) else { return nil }
            return .append(body)
        case .prepend:
            guard let have, header.dev == have.dev, header.ino == have.ino, end == have.end,
                  have.start - start == Int64(body.count), end - start <= Int64(maxEarlier) else { return nil }
            return .prepend(body)
        case .missing, .error:
            return nil
        }
    }

    // MARK: Files

    /// One chat's files in its host's transcripts folder.
    struct Chat {
        let chatID: String
        let hostID: UUID
        let provider: AgentProvider
        let cache: RemoteCache
        let root: String
        let stem: String
        var dataPath: String { root + "/" + stem + ".jsonl" }
        var statePath: String { root + "/" + stem + ".state" }

        init?(chatID: String, host: RemoteHost, cache: RemoteCache) {
            guard let (hostID, provider, _) = ChatTranscripts.identity(chatID: chatID), hostID == host.id else { return nil }
            self.chatID = chatID; self.hostID = host.id; self.cache = cache
            self.provider = provider == "codex" ? .codex : .claude
            root = cache.root.appendingPathComponent(host.id.uuidString).appendingPathComponent(RemoteCacheKind.transcripts.rawValue).path
            stem = SHA256.hash(data: Data(chatID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        }

        /// The recorded state when the copy on disk still matches it.
        func state() -> State? {
            guard cache.hostFolderIsPrivate(hostID), PrivateFiles.isPrivateDirectory(root),
                  let data = PrivateFiles.read(URL(fileURLWithPath: statePath), limit: 64 * 1024),
                  let state = try? RemoteCache.decoder.decode(State.self, from: data), state.version == State.currentVersion,
                  state.start >= 0, state.start <= state.end, let size = Self.size(dataPath), size == state.end - state.start else { return nil }
            return state
        }

        static func size(_ path: String) -> Int64? {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
            return Int64(info.st_size)
        }

        /// Writes a change and the new state, and records the entry, under the cache lock. Refused
        /// (throws) when the copy changed since `expected` was read.
        func apply(_ change: Change, header: Header, expected: State?, chatID: String, now: Date) throws -> State {
            var result: State?
            try cache.writing(.transcripts, hostID: hostID) { folder in
                guard folder.path == root else { throw POSIXError(.EPERM) }
                let current = state()
                switch change {
                case .append(let bytes):
                    guard let expected, current == expected else { throw POSIXError(.ESTALE) }
                    if !bytes.isEmpty { try Self.append(bytes, to: dataPath, expectedSize: expected.end - expected.start) }
                case .replace(let bytes):
                    try Self.replace(with: bytes, at: dataPath, temp: root + "/" + stem + ".part")
                case .prepend(let bytes):
                    guard let expected, current == expected,
                          let existing = PrivateFiles.read(URL(fileURLWithPath: dataPath), limit: RemoteTranscriptMirror.maxEarlier) else {
                        throw POSIXError(.ESTALE)
                    }
                    try Self.replace(with: bytes + existing, at: dataPath, temp: root + "/" + stem + ".part")
                }
                let headHash = SHA256.hash(data: try Self.head(dataPath)).map { String(format: "%02x", $0) }.joined()
                let grew: Bool = { if case .append(let bytes) = change { return !bytes.isEmpty }; return true }()
                var state = State(path: header.path!, dev: header.dev!, ino: header.ino!, start: header.start!, end: header.end!,
                                  size: header.size!, mtime: header.mtime!, headHash: headHash, syncedAt: now)
                if !grew, let current, now.timeIntervalSince(current.syncedAt) < RemoteTranscriptMirror.stampEvery {
                    state.syncedAt = current.syncedAt
                }
                if state != current { try PrivateFiles.write(try RemoteCache.encoder.encode(state), to: URL(fileURLWithPath: statePath)) }
                result = state
                return RemoteCacheEntry(key: chatID, file: stem + ".jsonl", remotePath: state.path, size: state.end - state.start,
                                        remoteMTime: state.mtime, fetchedAt: now, openedAt: now)
            }
            return result!
        }

        static func append(_ bytes: Data, to path: String, expectedSize: Int64) throws {
            let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), Int64(info.st_size) == expectedSize else {
                throw POSIXError(.ESTALE)
            }
            try writeAll(fd, bytes)
        }

        static func replace(with bytes: Data, at path: String, temp: String) throws {
            unlink(temp)
            let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do { try writeAll(fd, bytes) } catch { close(fd); unlink(temp); throw error }
            close(fd)
            guard rename(temp, path) == 0 else { unlink(temp); throw POSIXError(.EIO) }
        }

        static func writeAll(_ fd: Int32, _ bytes: Data) throws {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
        }

        static func head(_ path: String) throws -> Data {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: RemoteTranscriptMirror.head)
            var total = 0
            while total < buffer.count {
                let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + total, $0.count - total, off_t(total)) }
                if got <= 0 { break }
                total += got
            }
            return Data(buffer.prefix(total))
        }
    }

    // MARK: Open chats and eviction

    /// Keeps a chat's copy from eviction while it lives (a chat open on screen holds one).
    public final class Hold: Sendable {
        public let chatID: String
        public init(chatID: String) {
            self.chatID = chatID
            RemoteTranscriptMirror.opened.withLock { $0[chatID, default: 0] += 1 }
        }
        deinit {
            let key = chatID
            RemoteTranscriptMirror.opened.withLock { counts in
                let left = (counts[key] ?? 1) - 1
                counts[key] = left > 0 ? left : nil
            }
        }
    }
    static let opened = LockedValue<[String: Int]>([:])
    /// Chats held open now.
    public static var openChats: Set<String> { opened.withLock { Set($0.keys) } }

    /// Evicts copies not opened for 30 days, then the least recently opened beyond 512 MB, never a held chat.
    @discardableResult
    public func sweep(now: Date = Date(), cap: Int64? = nil) -> Int {
        cache.sweep(.transcripts, now: now, protected: Self.openChats, cap: cap)
    }
}
