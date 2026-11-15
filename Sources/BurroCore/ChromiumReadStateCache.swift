// Cache only the requested preference, never the surrounding Chromium database. A value or a
// failure is reused while every database file keeps the same stat stamp, so an unchanged
// database is parsed once; any write, compaction or replacement reads it again.
import Foundation
import Darwin

/// Identity and change stamp of one file: device, inode, size, mode, and modification and
/// status-change times. A missing file has no stamp.
struct FileStamp: Equatable, Sendable {
    var name: String
    var device: dev_t
    var inode: ino_t
    var size: off_t
    var mode: mode_t
    var modified: timespec
    var changed: timespec
    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.device == b.device && a.inode == b.inode && a.size == b.size && a.mode == b.mode
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
    static func of(_ path: String, name: String) throws -> FileStamp? {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileStamp(name: name, device: info.st_dev, inode: info.st_ino, size: info.st_size, mode: info.st_mode,
                         modified: info.st_mtimespec, changed: info.st_ctimespec)
    }
}

final class ChromiumReadStateCache: @unchecked Sendable {
    private struct Entry { var directory: String; var key: String; var stamps: [FileStamp]; var result: Result<Data?, Error> }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func value(directory: URL, key: String, load: () throws -> Data?) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let before: [FileStamp]
        do { before = try stamps(directory) } catch {
            entries.removeAll { $0.directory == directory.path && $0.key == key }
            throw error
        }
        if let entry = entries.first(where: { $0.directory == directory.path && $0.key == key && $0.stamps == before }) {
            return try entry.result.get()
        }
        entries.removeAll { $0.directory == directory.path && $0.key == key }
        let result = Result { try load() }
        // A concurrent write, compaction or replacement must not cache an inconsistent read;
        // a read that saw the files move is retried on the next sample.
        guard before == (try? stamps(directory)) else { throw ChromiumReadState.Failure.changed }
        if case .failure(let error) = result, error as? ChromiumReadState.Failure == .changed { throw error }
        entries.append(Entry(directory: directory.path, key: key, stamps: before, result: result))
        if entries.count > 4 { entries.removeFirst() }
        return try result.get()
    }

    private func stamps(_ directory: URL) throws -> [FileStamp] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0 == "CURRENT" || $0.hasPrefix("MANIFEST-") || $0.hasSuffix(".ldb") || $0.hasSuffix(".log")
        }.sorted()
        guard names.contains("CURRENT"), names.count <= 1024 else { throw ChromiumReadState.Failure.unsupported }
        return try names.map { name in
            guard let stamp = try FileStamp.of(directory.appendingPathComponent(name).path, name: name) else {
                throw ChromiumReadState.Failure.changed
            }
            return stamp
        }
    }
}
