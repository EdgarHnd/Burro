// The Orchestrator's memory: short standing notes it is given at the start of every turn (global
// ones, then the main project's). The owner adds, edits and deletes them on the Orchestrator page;
// the Orchestrator adds them with `remember` and drops them with `forget`. They live in
// `memory.json` in the Orchestrator's folder ({"version", "seeded", "entries": [{id, scope, text,
// source, createdAt, lastUsedAt}]}, dates in seconds since 1970, scope "global" or a project path),
// owner-only, changed only by a locked read-modify-write because Burro and the tool server both
// write it. Reads are tolerant: a damaged file reads as empty and bad entries are skipped. The file
// is seeded once with the owner's standing preference for a one-line TL;DR.
import Foundation

public struct OrchestratorMemoryEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case user, orchestrator }
    public static let global = "global"

    public var id: String
    /// "global", or a project's path.
    public var scope: String
    public var text: String
    public var source: Source
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), scope: String, text: String, source: Source, createdAt: Date, lastUsedAt: Date? = nil) {
        self.id = id; self.scope = scope; self.text = text; self.source = source; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt
    }
    public var isGlobal: Bool { scope == Self.global }
}

public struct OrchestratorMemory: Sendable {
    public var url: URL
    public init(url: URL) { self.url = url }
    public static var standard: OrchestratorMemory { OrchestratorMemory(url: Orchestrator.memoryURL) }

    public static let seed = "End answers with a one-line TL;DR."
    public static let textLimit = 500
    public static let entryLimit = 100

    public func load() -> [OrchestratorMemoryEntry] {
        guard let data = Self.readCapped(url) else { return [] }
        return Self.decode(data).entries
    }

    /// Creates the file with the seed entry the first time; never again once it exists.
    public func seedIfNeeded(now: Date = Date()) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try update(now: now) { _ in }
    }

    /// Adds a note, or returns the same one already there for that scope.
    @discardableResult
    public func remember(_ text: String, scope: String, source: OrchestratorMemoryEntry.Source, now: Date = Date()) throws -> OrchestratorMemoryEntry? {
        guard let clean = Self.clean(text) else { return nil }
        let scope = Self.cleanScope(scope)
        return try update(now: now) { entries in
            if let same = entries.first(where: { $0.scope == scope && $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return same }
            let entry = OrchestratorMemoryEntry(scope: scope, text: clean, source: source, createdAt: now)
            entries.append(entry)
            return entry
        }
    }

    /// Removes an entry by id, or by an id prefix of six or more characters that names exactly one.
    /// Returns what was removed.
    @discardableResult
    public func forget(_ id: String) throws -> OrchestratorMemoryEntry? {
        let wanted = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return try update { entries in
            var matches = entries.filter { $0.id == wanted }
            if matches.isEmpty, wanted.count >= 6 { matches = entries.filter { $0.id.hasPrefix(wanted) } }
            guard matches.count == 1, let entry = matches.first else { return nil }
            entries.removeAll { $0.id == entry.id }
            return entry
        }
    }

    @discardableResult
    public func edit(_ id: String, text: String, scope: String? = nil) throws -> Bool {
        guard let clean = Self.clean(text) else { return try forget(id) != nil }
        return try update { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].text = clean
            if let scope { entries[index].scope = Self.cleanScope(scope) }
            return true
        }
    }

    /// Marks entries as given to the model.
    public func touch(_ ids: [String], now: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try update(now: now) { entries in
            for index in entries.indices where ids.contains(entries[index].id) { entries[index].lastUsedAt = now }
        }
    }

    /// The entries for a turn: global first, then the main project's, oldest first within each.
    public static func relevant(_ entries: [OrchestratorMemoryEntry], mainProject: String?) -> [OrchestratorMemoryEntry] {
        let global = entries.filter(\.isGlobal)
        let project = mainProject.map { main in entries.filter { $0.scope == main } } ?? []
        return (global + project)
    }

    /// The memory section of the system brief, or nil when there is nothing to say.
    public static func section(_ entries: [OrchestratorMemoryEntry], mainProject: String?) -> String? {
        let relevant = relevant(entries, mainProject: mainProject)
        guard !relevant.isEmpty else { return nil }
        var lines = ["## Memory", "Standing notes from the user and from you (ids for `forget`). Follow the user's; treat yours as reminders."]
        for entry in relevant {
            let scope = entry.isGlobal ? "" : " (\(URL(fileURLWithPath: entry.scope).lastPathComponent))"
            lines.append("- [\(entry.id.prefix(8))]\(scope) \(entry.text)" + (entry.source == .orchestrator ? " — noted by you" : ""))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: File

    @discardableResult
    public func update<T>(now: Date = Date(), _ body: (inout [OrchestratorMemoryEntry]) throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var file = Self.readCapped(url).map(Self.decode) ?? File(seeded: false, entries: [])
        if !file.seeded {
            file.entries.insert(OrchestratorMemoryEntry(scope: OrchestratorMemoryEntry.global, text: Self.seed, source: .user, createdAt: now), at: 0)
            file.seeded = true
        }
        let value = try body(&file.entries)
        file.entries = Array(file.entries.suffix(Self.entryLimit))
        try OrchestratorFileWriter.write(try Self.encode(file), to: url)
        return value
    }

    static func clean(_ text: String) -> String? {
        let clean = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : String(clean.prefix(textLimit))
    }
    static func cleanScope(_ scope: String) -> String {
        let trimmed = scope.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") ? (trimmed as NSString).standardizingPath : OrchestratorMemoryEntry.global
    }

    struct File: Codable {
        var version = 1
        var seeded: Bool
        var entries: [OrchestratorMemoryEntry]
    }

    static func encode(_ file: File) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) -> File {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return File(seeded: false, entries: []) }
        let rows = object["entries"] as? [Any] ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = rows.compactMap { row -> OrchestratorMemoryEntry? in
            guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(OrchestratorMemoryEntry.self, from: data)
        }
        // A file someone wrote without the flag still counts as seeded once it has entries.
        return File(seeded: object["seeded"] as? Bool ?? !entries.isEmpty, entries: entries)
    }

    static func readCapped(_ url: URL) -> Data? {
        OrchestratorFileWriter.read(url, limit: 1024 * 1024)
    }
}

/// Owner-only files in the Orchestrator's folder: written to a temporary file created 0600 and
/// renamed into place; read without following a symlink and only up to a size cap.
enum OrchestratorFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func read(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()
    }
}
