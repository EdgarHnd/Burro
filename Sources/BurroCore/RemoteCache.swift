// Burro's private cache for other machines: ~/Library/Caches/Burro/Remote/<host id>/, not backed up.
// Each host folder holds host.json (the last successful probe's chats and warnings, the machine's
// facts, the folders a chat can start in there and its Codex models), so after a relaunch with that
// machine asleep its chats still show, as last seen, until a probe replaces them. It also holds copied
// media and transcript copies (`RemoteTranscriptMirror`), each kind with an index of what was copied
// and when it was last opened; old or excess copies are evicted by last-opened time, never one marked
// open. Folders are 0700 and files 0600 and must be yours; nothing is read or written through a
// symlink. A host's folder is deleted when you remove the host or change its address, and a
// host.json written for another address is discarded on load.
import CryptoKit
import Darwin
import Foundation

/// What Burro remembers about one machine between runs.
public struct RemoteHostCache: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var hostID: UUID
    public var destination: String
    public var port: Int?
    public var sessions: [AgentSession]
    public var warnings: [String]
    public var sampledAt: Date?
    public var facts: RemoteMachineFacts?
    public var folders: RemoteFolderList?
    public var codexModels: [RemoteCodexModel]?
    public var savedAt: Date

    public init(host: RemoteHost, sessions: [AgentSession] = [], warnings: [String] = [], sampledAt: Date? = nil,
                facts: RemoteMachineFacts? = nil, folders: RemoteFolderList? = nil, codexModels: [RemoteCodexModel]? = nil,
                savedAt: Date = Date()) {
        version = Self.currentVersion; hostID = host.id; destination = host.destination; port = host.port
        self.sessions = sessions; self.warnings = warnings; self.sampledAt = sampledAt
        self.facts = facts; self.folders = folders; self.codexModels = codexModels; self.savedAt = savedAt
    }

    /// Written for this host at its current address.
    public func matches(_ host: RemoteHost) -> Bool {
        hostID == host.id && destination == host.destination && port == host.port
    }

    /// The remembered chats as a not-yet-checked snapshot: every row shows as last seen (stale), never
    /// live, exactly like rows that went stale during a run, until the first probe replaces them.
    public func snapshot(for host: RemoteHost) -> RemoteHostSnapshot {
        let prefix = "remote:\(host.id.uuidString):"
        let rows = sessions.filter { $0.id.hasPrefix(prefix) }.prefix(2000).map { original in
            var session = original
            session.remote = RemoteOrigin(hostID: host.id, hostName: host.name, sampledAt: sampledAt ?? .distantPast, stale: true)
            return session
        }
        return RemoteHostSnapshot(host: host, sessions: Array(rows), warnings: Array(warnings.prefix(50)), sampledAt: sampledAt,
                                  attemptedAt: .distantPast, state: .notChecked)
    }
}

/// `MachineFacts` in a form that survives a relaunch.
public struct RemoteMachineFacts: Codable, Sendable, Equatable {
    public var os: String?
    public var versions: [String: String]
    public var checkedAt: Date
    public init(_ facts: MachineFacts) {
        os = facts.os; versions = Dictionary(uniqueKeysWithValues: facts.versions.map { ($0.key.rawValue, $0.value) }); checkedAt = facts.checkedAt
    }
    public var machineFacts: MachineFacts {
        MachineFacts(os: os, versions: Dictionary(uniqueKeysWithValues: versions.compactMap { key, value in Harness(rawValue: key).map { ($0, value) } }),
                     checkedAt: checkedAt)
    }
}

/// `LaunchModel` in a form that survives a relaunch.
public struct RemoteCodexModel: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var isDefault: Bool
    public init(_ model: LaunchModel) {
        id = model.id; title = model.title; efforts = model.efforts; defaultEffort = model.defaultEffort; isDefault = model.isDefault
    }
    public var launchModel: LaunchModel { LaunchModel(id: id, title: title, efforts: efforts, defaultEffort: defaultEffort, isDefault: isDefault) }
}

/// What a cache index records about one copied file.
public struct RemoteCacheEntry: Codable, Sendable, Equatable {
    /// Stable identity within its host and kind (a media path hash, or a chat id for transcripts).
    public var key: String
    /// File name inside the kind's folder.
    public var file: String
    public var remotePath: String
    public var size: Int64
    /// The remote file's modification time when copied, to tell whether the copy is current.
    public var remoteMTime: Double
    public var fetchedAt: Date
    public var openedAt: Date
    public init(key: String, file: String, remotePath: String, size: Int64, remoteMTime: Double, fetchedAt: Date, openedAt: Date) {
        self.key = key; self.file = file; self.remotePath = remotePath; self.size = size
        self.remoteMTime = remoteMTime; self.fetchedAt = fetchedAt; self.openedAt = openedAt
    }
}

public enum RemoteCacheKind: String, CaseIterable, Sendable {
    case media, transcripts
    /// Total across all machines.
    public var cap: Int64 { self == .media ? 1 << 30 : 512 << 20 }
    /// Copies not opened for this long are removed.
    public var maxAge: TimeInterval { 30 * 86_400 }
}

public struct RemoteCache: Sendable {
    public static let shared = RemoteCache()
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro/Remote", isDirectory: true)
    }
    /// host.json beyond this is ignored (2000 chats are well under it).
    static let maxSnapshotBytes = 16 * 1024 * 1024
    /// A probe that changed nothing still refreshes host.json this often, so "last seen" stays close.
    public static let unchangedRefresh: TimeInterval = 600

    public let root: URL
    public init(root: URL = RemoteCache.defaultRoot) { self.root = root }

    // MARK: Folders

    /// The cache root, created 0700 and excluded from backups.
    @discardableResult
    public func prepareRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFiles.directory(root)
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return root
    }
    /// A host's folder, created if needed.
    public func folder(for hostID: UUID) throws -> URL {
        let url = try prepareRoot().appendingPathComponent(hostID.uuidString, isDirectory: true)
        try PrivateFiles.directory(url)
        return url
    }
    func folder(_ kind: RemoteCacheKind, hostID: UUID) throws -> URL {
        let url = try folder(for: hostID).appendingPathComponent(kind.rawValue, isDirectory: true)
        try PrivateFiles.directory(url)
        return url
    }
    /// The root and the host's folder are real directories you own (reads never pass through a link).
    func hostFolderIsPrivate(_ hostID: UUID) -> Bool {
        PrivateFiles.isPrivateDirectory(root.path) && PrivateFiles.isPrivateDirectory(root.appendingPathComponent(hostID.uuidString).path)
    }
    func snapshotURL(_ hostID: UUID) -> URL { root.appendingPathComponent(hostID.uuidString).appendingPathComponent("host.json") }
    /// Host ids with a folder here.
    public func hostIDs() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(UUID.init(uuidString:))
    }

    // MARK: host.json

    /// The remembered state for `host`, or nil. One written for another address wipes that host's folder.
    public func load(_ host: RemoteHost) -> RemoteHostCache? {
        guard hostFolderIsPrivate(host.id), let data = PrivateFiles.read(snapshotURL(host.id), limit: Self.maxSnapshotBytes) else { return nil }
        guard let value = try? Self.decoder.decode(RemoteHostCache.self, from: data), value.version == RemoteHostCache.currentVersion else { return nil }
        guard value.matches(host) else { remove(hostID: host.id); return nil }
        return value
    }
    /// Snapshots for every enabled host; folders of hosts no longer configured are deleted.
    public func loadAll(_ hosts: [RemoteHost]) -> [UUID: RemoteHostCache] {
        prune(keeping: Set(hosts.map(\.id)))
        var result: [UUID: RemoteHostCache] = [:]
        for host in hosts where host.enabled { result[host.id] = load(host) }
        return result
    }
    /// Reads, changes and atomically rewrites host.json (starting fresh when absent or for another address).
    public func update(_ host: RemoteHost, now: Date = Date(), _ change: (inout RemoteHostCache) -> Void) throws {
        try Self.lock.withLock {
            var value = load(host) ?? RemoteHostCache(host: host, savedAt: now)
            change(&value)
            value.savedAt = now
            try write(value, host: host)
        }
    }
    /// Saves a successful probe's chats and warnings, keeping the rest of host.json. Skipped when they
    /// match the last save, unless that save is older than `unchangedRefresh`. Returns whether it wrote.
    @discardableResult
    public func saveProbe(_ snapshot: RemoteHostSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.state == .online, snapshot.host.enabled else { return false }
        let host = snapshot.host
        let print = Self.fingerprint(snapshot)
        let key = root.path + "|" + host.id.uuidString
        if let last = Self.saved.withLock({ $0[key] }), last.print == print, now.timeIntervalSince(last.at) < Self.unchangedRefresh { return false }
        do {
            try update(host, now: now) { value in
                value.sessions = snapshot.sessions; value.warnings = snapshot.warnings; value.sampledAt = snapshot.sampledAt
            }
            Self.saved.withLock { $0[key] = (print, now) }
            return true
        } catch { return false }
    }
    static func fingerprint(_ snapshot: RemoteHostSnapshot) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .secondsSince1970
        struct Shape: Encodable { var destination: String; var port: Int?; var sessions: [AgentSession]; var warnings: [String] }
        // The per-sample time inside each row's origin changes every probe; it isn't part of what changed.
        let rows = snapshot.sessions.map { row -> AgentSession in var value = row; value.remote = nil; return value }
        let data = (try? encoder.encode(Shape(destination: snapshot.host.destination, port: snapshot.host.port, sessions: rows, warnings: snapshot.warnings))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func write(_ value: RemoteHostCache, host: RemoteHost) throws {
        _ = try folder(for: host.id)
        try PrivateFiles.write(try Self.encoder.encode(value), to: snapshotURL(host.id))
    }

    // MARK: Removal and size

    /// Deletes a host's folder (host removed, address changed, or its cache cleared).
    public func remove(hostID: UUID) {
        Self.saved.withLock { $0[root.path + "|" + hostID.uuidString] = nil }
        let url = root.appendingPathComponent(hostID.uuidString)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        try? FileManager.default.removeItem(at: url)
    }
    /// Deletes the folders of hosts that are no longer configured.
    public func prune(keeping ids: Set<UUID>) {
        for id in hostIDs() where !ids.contains(id) { remove(hostID: id) }
    }
    /// Clear cache for one machine: its snapshot, media and transcripts.
    public func clear(hostID: UUID) { remove(hostID: hostID) }
    /// Clear cache for every machine.
    public func clearAll() {
        Self.saved.withLock { $0 = $0.filter { !$0.key.hasPrefix(root.path + "|") } }
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return }
        try? FileManager.default.removeItem(at: root)
    }
    /// Bytes used by one machine's folder (symlinks count as themselves, never followed).
    public func usage(hostID: UUID) -> Int64 { PrivateFiles.size(root.appendingPathComponent(hostID.uuidString).path) }
    /// Bytes used by the whole cache.
    public func totalUsage() -> Int64 { PrivateFiles.size(root.path) }

    // MARK: Indexes (media now; transcripts next)

    private struct Index: Codable { var version = 1; var entries: [RemoteCacheEntry] = [] }
    private func indexURL(_ kind: RemoteCacheKind, hostID: UUID) -> URL {
        root.appendingPathComponent(hostID.uuidString).appendingPathComponent(kind.rawValue).appendingPathComponent("index.json")
    }
    private func readIndex(_ kind: RemoteCacheKind, hostID: UUID) -> Index {
        guard hostFolderIsPrivate(hostID),
              PrivateFiles.isPrivateDirectory(root.appendingPathComponent(hostID.uuidString).appendingPathComponent(kind.rawValue).path),
              let data = PrivateFiles.read(indexURL(kind, hostID: hostID), limit: Self.maxSnapshotBytes),
              let index = try? Self.decoder.decode(Index.self, from: data) else { return Index() }
        return Index(entries: index.entries.filter { Self.validFile($0.file) })
    }
    private func writeIndex(_ index: Index, _ kind: RemoteCacheKind, hostID: UUID) throws {
        _ = try folder(kind, hostID: hostID)
        try PrivateFiles.write(try Self.encoder.encode(index), to: indexURL(kind, hostID: hostID))
    }
    /// File names Burro gives copies: a hex key and an optional short extension, so an edited index can't point elsewhere.
    static func validFile(_ name: String) -> Bool {
        name.range(of: #"^[0-9a-f]{16,64}(\.[a-z0-9]{1,8})?$"#, options: .regularExpression) != nil
    }

    public func entries(_ kind: RemoteCacheKind, hostID: UUID) -> [RemoteCacheEntry] {
        Self.lock.withLock { readIndex(kind, hostID: hostID).entries }
    }
    /// The entry for `key` when its file is still there at the recorded size.
    public func entry(_ kind: RemoteCacheKind, hostID: UUID, key: String) -> (entry: RemoteCacheEntry, url: URL)? {
        Self.lock.withLock {
            guard let entry = readIndex(kind, hostID: hostID).entries.first(where: { $0.key == key }) else { return nil }
            let url = root.appendingPathComponent(hostID.uuidString).appendingPathComponent(kind.rawValue).appendingPathComponent(entry.file)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), Int64(info.st_size) == entry.size else { return nil }
            return (entry, url)
        }
    }
    /// The folder a kind's files go in for this host (created).
    public func directory(_ kind: RemoteCacheKind, hostID: UUID) throws -> URL { try folder(kind, hostID: hostID) }
    /// Adds or replaces an entry.
    public func record(_ entry: RemoteCacheEntry, _ kind: RemoteCacheKind, hostID: UUID) throws {
        guard Self.validFile(entry.file) else { throw CocoaError(.fileWriteInvalidFileName) }
        try Self.lock.withLock {
            var index = readIndex(kind, hostID: hostID)
            index.entries.removeAll { $0.key == entry.key }
            index.entries.append(entry)
            try writeIndex(index, kind, hostID: hostID)
        }
    }
    /// Runs `body`, which writes a kind's files for one entry and returns that entry, and records it,
    /// all under the cache lock, so a sweep never sees the files without their entry.
    @discardableResult
    func writing(_ kind: RemoteCacheKind, hostID: UUID, _ body: (URL) throws -> RemoteCacheEntry) throws -> RemoteCacheEntry {
        try Self.lock.withLock {
            let entry = try body(try folder(kind, hostID: hostID))
            guard Self.validFile(entry.file) else { throw CocoaError(.fileWriteInvalidFileName) }
            var index = readIndex(kind, hostID: hostID)
            index.entries.removeAll { $0.key == entry.key }
            index.entries.append(entry)
            try writeIndex(index, kind, hostID: hostID)
            return entry
        }
    }
    /// The state file kept beside an entry's file: "<stem>.state".
    static func companion(_ entry: RemoteCacheEntry) -> String {
        (entry.file.split(separator: ".").first.map(String.init) ?? entry.file) + ".state"
    }
    /// Marks an entry as opened now (eviction goes by this).
    public func touch(_ kind: RemoteCacheKind, hostID: UUID, key: String, now: Date = Date()) {
        Self.lock.withLock {
            var index = readIndex(kind, hostID: hostID)
            guard let i = index.entries.firstIndex(where: { $0.key == key }) else { return }
            index.entries[i].openedAt = now
            try? writeIndex(index, kind, hostID: hostID)
        }
    }

    /// Which entries to drop: everything not opened within `maxAge`, then the least recently opened
    /// until the rest fit in `cap`. Entries whose key is in `protected` (a chat marked open) are kept.
    public static func evictions(_ entries: [RemoteCacheEntry], cap: Int64, maxAge: TimeInterval, now: Date,
                                 protected: Set<String> = []) -> Set<Int> {
        var drop = Set<Int>()
        var total: Int64 = 0
        for (i, entry) in entries.enumerated() {
            if !protected.contains(entry.key) && now.timeIntervalSince(entry.openedAt) > maxAge { drop.insert(i) } else { total += entry.size }
        }
        let candidates = entries.indices.filter { !drop.contains($0) && !protected.contains(entries[$0].key) }
            .sorted { entries[$0].openedAt < entries[$1].openedAt }
        for i in candidates where total > cap {
            drop.insert(i); total -= entries[i].size
        }
        return drop
    }

    /// Applies `evictions` across every machine for one kind, deleting the files and stray partial
    /// copies. Returns how many entries were removed.
    @discardableResult
    public func sweep(_ kind: RemoteCacheKind, now: Date = Date(), protected: Set<String> = [], cap: Int64? = nil) -> Int {
        Self.lock.withLock {
            let hosts = hostIDs()
            var all: [(host: UUID, entry: RemoteCacheEntry)] = []
            var indexes: [UUID: Index] = [:]
            for host in hosts {
                let index = readIndex(kind, hostID: host)
                indexes[host] = index
                all += index.entries.map { (host, $0) }
            }
            let drop = Self.evictions(all.map(\.entry), cap: cap ?? kind.cap, maxAge: kind.maxAge, now: now, protected: protected)
            for host in hosts {
                let dir = root.appendingPathComponent(host.uuidString).appendingPathComponent(kind.rawValue)
                var info = stat()
                guard lstat(dir.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                let kept = all.indices.filter { all[$0].host == host && !drop.contains($0) }.map { all[$0].entry }
                // A transcript copy's state file ("<stem>.state") goes with its entry.
                let keepFiles = Set(kept.map(\.file) + kept.map(Self.companion) + ["index.json"])
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !keepFiles.contains(name) {
                    let url = dir.appendingPathComponent(name)
                    // Copies still being written are left alone for a while.
                    if name.hasSuffix(".part"), let modified = PrivateFiles.modified(url.path), now.timeIntervalSince(modified) < 600 { continue }
                    try? FileManager.default.removeItem(at: url)
                }
                if kept.count != indexes[host]?.entries.count { try? writeIndex(Index(entries: kept), kind, hostID: host) }
            }
            return drop.count
        }
    }

    // MARK: Shared

    static let lock = NSLock()
    /// Last saved probe fingerprint per cache root and host.
    static let saved = LockedValue<[String: (print: String, at: Date)]>([:])
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

/// Owner-only files: folders 0700 that must be real directories you own, files written 0600 through
/// a fresh temp file and renamed into place, reads that refuse symlinks and oversized files.
enum PrivateFiles {
    static func directory(_ url: URL) throws {
        let path = url.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
        if info.st_mode & 0o077 != 0 && chmod(path, 0o700) != 0 { throw POSIXError(.EPERM) }
    }
    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = true
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { ok = false; break }
                offset += written
            }
        }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else { unlink(temp.path); throw POSIXError(.EIO) }
    }
    static func read(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= limit else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try? handle.read(upToCount: limit) ?? Data()
    }
    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
    /// Total bytes of regular files under `path`; links are never followed.
    static func size(_ path: String, depth: Int = 0) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return Int64(info.st_size)
        case S_IFDIR where depth < 8:
            return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).reduce(0) { $0 + size(path + "/" + $1, depth: depth + 1) }
        default: return 0
        }
    }
}
