// Cache only the requested preference, never the surrounding Chromium database.
import Foundation
import Darwin

final class ChromiumReadStateCache: @unchecked Sendable {
    private struct Stamp: Equatable {
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
    }
    private struct Entry { var directory: String; var key: String; var stamps: [Stamp]; var value: Data? }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func value(directory: URL, key: String, load: () throws -> Data?) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        do {
            let before = try stamps(directory)
            if let entry = entries.first(where: { $0.directory == directory.path && $0.key == key && $0.stamps == before }) {
                return entry.value
            }
            let value = try load()
            // A concurrent write, compaction or replacement must not cache an inconsistent read.
            guard before == (try stamps(directory)) else { throw ChromiumReadState.Failure.changed }
            entries.removeAll { $0.directory == directory.path && $0.key == key }
            entries.append(Entry(directory: directory.path, key: key, stamps: before, value: value))
            if entries.count > 4 { entries.removeFirst() }
            return value
        } catch {
            entries.removeAll { $0.directory == directory.path && $0.key == key }
            throw error // Never reuse stale unread badges after a failed read.
        }
    }

    private func stamps(_ directory: URL) throws -> [Stamp] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0 == "CURRENT" || $0.hasPrefix("MANIFEST-") || $0.hasSuffix(".ldb") || $0.hasSuffix(".log")
        }.sorted()
        guard names.contains("CURRENT"), names.count <= 1024 else { throw ChromiumReadState.Failure.unsupported }
        return try names.map { name in
            var info = stat()
            guard fstatat(AT_FDCWD, directory.appendingPathComponent(name).path, &info, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Stamp(name: name, device: info.st_dev, inode: info.st_ino, size: info.st_size, mode: info.st_mode,
                         modified: info.st_mtimespec, changed: info.st_ctimespec)
        }
    }
}
