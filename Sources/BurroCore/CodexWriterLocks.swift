// Index filenames for one scan; existing locks are still probed live on every pass.
import Foundation
import Darwin
import CSystem

struct CodexWriterLocks {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int
    }
    private let directory: String
    private let names: Set<String>?
    private let stamp: Stamp?

    init(directory: URL, indexed: Bool = true) {
        self.directory = directory.path
        if indexed, let before = Self.identity(directory.path),
           let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           names.count <= 20_000, Self.identity(directory.path) == before {
            self.names = Set(names); stamp = before
        } else {
            names = nil; stamp = nil
        }
    }
    func held(_ id: String, probe: (String) -> Int32 = { burro_lock_held($0) }) -> Int32 {
        let name = id + ".lock"
        if let names, !names.contains(name) { return 0 }
        return probe(directory + "/" + name)
    }
    var isCurrent: Bool { stamp.map { Self.identity(directory) == $0 } ?? true }
    var threadIDs: [String]? { names.map { $0.filter { $0.hasSuffix(".lock") }.map { String($0.dropLast(5)) } } }

    private static func identity(_ path: String) -> Stamp? {
        var info = stat()
        // A symlinked/unreadable directory uses the original per-file reader.
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Stamp(device: info.st_dev, inode: info.st_ino,
                     modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                     changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}
