// On-disk activity: one JSON-lines file per local day in ~/Library/Application Support/Burro/
// Activity (folder 0700, files 0600), appended a few lines at a time. Reads skip symlinks,
// non-regular files and bad or truncated lines; files are capped at 4 MiB and kept 30 days.
// Nothing here touches the network, logs, or the orchestrator's snapshot.
import Foundation

/// One stretch of time in one app/window. Only built from an `ActivityKey`, so it has already
/// been through the privacy rules.
public struct ActivitySpan: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var bundleID: String
    public var app: String
    public var title: String?
    public var host: String?
    public var isPrivate: Bool
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(_ key: ActivityKey, start: Date, end: Date) {
        self.start = start; self.end = end
        bundleID = key.bundleID; app = key.app; title = key.title; host = key.host; isPrivate = key.isPrivate
    }
    var key: ActivityKey { ActivityKey(bundleID: bundleID, app: app, title: title, host: host, isPrivate: isPrivate) }
    /// This span as if `host` had been private when it was recorded.
    public func redacted(host: String) -> ActivitySpan { ActivitySpan(ActivityPrivacy.redacted(key, host: host), start: start, end: end) }

    enum CodingKeys: String, CodingKey { case start, end, bundle, app, title, host, `private` }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode((start.timeIntervalSince1970 * 10).rounded() / 10, forKey: .start)
        try c.encode((end.timeIntervalSince1970 * 10).rounded() / 10, forKey: .end)
        try c.encode(bundleID, forKey: .bundle)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(host, forKey: .host)
        if isPrivate { try c.encode(true, forKey: .private) }
    }
    /// Rejects anything the writer could not have produced.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .start))
        end = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .end))
        bundleID = try c.decode(String.self, forKey: .bundle)
        app = try c.decode(String.self, forKey: .app)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .private) ?? false
        guard end >= start, duration <= 86_400, bundleID.count <= 200, app.count <= 80,
              (title?.count ?? 0) <= ActivityPrivacy.titleLimit, (host?.count ?? 0) <= 253,
              !isPrivate || title == nil else { throw DecodingError.dataCorruptedError(forKey: .start, in: c, debugDescription: "invalid span") }
    }
}

public struct ActivityLog: Sendable {
    public static let fileLimit = 4 * 1024 * 1024
    public static let retentionDays = 30
    public let folder: URL

    public init(folder: URL = ActivityLog.defaultFolder) { self.folder = folder }
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burro/Activity", isDirectory: true)
    }
    public var rulesURL: URL { folder.appendingPathComponent("rules.json") }

    public func url(for day: Date, calendar: Calendar = .current) -> URL {
        folder.appendingPathComponent(TodoDay.key(day, calendar: calendar) + ".jsonl")
    }

    /// Appends spans to their days' files, splitting any that cross midnight.
    public func append(_ spans: [ActivitySpan], calendar: Calendar = .current) throws {
        var byDay: [URL: Data] = [:]
        let encoder = JSONEncoder()
        for span in spans {
            var piece = span
            while piece.end > piece.start {
                let dayStart = calendar.startOfDay(for: piece.start)
                let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? piece.end
                var part = piece
                part.end = min(piece.end, next)
                byDay[url(for: dayStart, calendar: calendar), default: Data()].append(try encoder.encode(part) + Data("\n".utf8))
                piece.start = part.end
            }
        }
        guard !byDay.isEmpty else { return }
        try Self.ensurePrivateFolder(folder)
        for (url, data) in byDay { try Self.appendPrivate(url, data: data) }
    }

    /// The day's spans in file order. Missing, unsafe or unreadable files read as empty.
    public func read(day: Date, calendar: Calendar = .current) -> [ActivitySpan] {
        guard let data = Self.readRegularFile(url(for: day, calendar: calendar), limit: Self.fileLimit + 64 * 1024) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).prefix(100_000).compactMap { line in
            line.count <= 4096 ? try? decoder.decode(ActivitySpan.self, from: Data(line)) : nil
        }
    }

    /// Day files older than the retention window. Only `yyyy-MM-dd.jsonl` names are touched.
    public func prune(now: Date = Date(), keepDays: Int = ActivityLog.retentionDays, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(keepDays - 1), to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = TodoDay.key(cutoff, calendar: calendar)
        for name in dayFiles() where String(name.prefix(10)) < cutoffKey { unlink(folder.appendingPathComponent(name).path) }
    }

    public func deleteDay(_ day: Date, calendar: Calendar = .current) { unlink(url(for: day, calendar: calendar).path) }
    /// Every day file; your category rules stay.
    public func deleteAll() { for name in dayFiles() { unlink(folder.appendingPathComponent(name).path) } }

    /// Rewrites stored days so a host marked private keeps no title and reads as "Private".
    public func scrub(host: String) {
        for name in dayFiles() {
            let url = folder.appendingPathComponent(name)
            guard let data = Self.readRegularFile(url, limit: Self.fileLimit + 64 * 1024) else { continue }
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            let spans = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(ActivitySpan.self, from: Data($0)) }
            let redacted = spans.map { $0.redacted(host: host) }
            guard redacted != spans else { continue }
            let out = redacted.reduce(into: Data()) { data, span in
                if let line = try? encoder.encode(span) { data.append(line); data.append(UInt8(ascii: "\n")) }
            }
            try? Self.writePrivateFile(url, data: out)
        }
    }

    func dayFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            name.count == 16 && name.hasSuffix(".jsonl") && name.prefix(10).enumerated().allSatisfy { index, ch in
                [4, 7].contains(index) ? ch == "-" : ch.isASCII && ch.isNumber
            }
        }
    }

    // MARK: Private files

    /// Creates the folder owner-only, or tightens it; refuses a symlink or non-directory.
    static func ensurePrivateFolder(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileWriteInvalidFileName) }
        if info.st_mode & 0o777 != 0o700 { chmod(url.path, 0o700) }
    }

    /// Opens without following symlinks, requires a regular file, keeps it 0600 and under the size cap,
    /// and starts on a fresh line if a crash left the last one unfinished.
    static func appendPrivate(_ url: URL, data: Data) throws {
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteInvalidFileName) }
        if info.st_mode & 0o777 != 0o600 { fchmod(fd, 0o600) }
        guard Int(info.st_size) + data.count <= fileLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        var payload = data
        if info.st_size > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, info.st_size - 1) == 1, last != UInt8(ascii: "\n") { payload.insert(UInt8(ascii: "\n"), at: 0) }
        }
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes a whole small file owner-only through a temporary file and rename.
    static func writePrivateFile(_ url: URL, data: Data) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw CocoaError(.fileWriteInvalidFileName) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else { unlink(temp.path); throw CocoaError(.fileWriteUnknown) }
    }

    /// Reads at most `limit` bytes of a regular file; nil for symlinks, folders, devices or errors.
    static func readRegularFile(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.read(upToCount: limit) ?? Data()
    }
}
