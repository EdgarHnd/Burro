// Read-only measurements for the Worktrees page (object counts from `git count-objects -v`, folder
// sizes from `du`) and the one explicit maintenance action, `git gc`, which runs only when the
// user confirms it. The gc is the conservative kind: it repacks objects but never prunes
// unreachable objects, never expires reflogs or rerere records and never prunes worktree
// registrations, so nothing that could be recovered before is lost after it. All calls block
// their caller; run them off the main thread.
import Foundation

/// The fields of `git count-objects -v`.
public struct RepositoryObjectStats: Equatable, Sendable {
    /// Loose objects.
    public var loose: Int
    /// Packfiles.
    public var packs: Int
    /// KiB in loose objects and in packs.
    public var looseKiB: Int
    public var packKiB: Int
    /// Loose objects that are also in a pack, and files Git does not recognise.
    public var prunePackable: Int
    public var garbage: Int

    /// Git's own `gc --auto` thresholds (`gc.auto` loose objects and `gc.autoPackLimit` packs). Past
    /// either, status, diff and log slow down in every worktree that shares the object store.
    public static let looseLimit = 6_700
    public static let packLimit = 50
    public var needsAttention: Bool { loose > Self.looseLimit || packs > Self.packLimit }
    /// "267 packs, 104k loose objects".
    public var summary: String {
        "\(packs) pack\(packs == 1 ? "" : "s"), \(WorktreeBoardFormat.compact(loose)) loose object\(loose == 1 ? "" : "s")"
    }

    public init(loose: Int, packs: Int, looseKiB: Int = 0, packKiB: Int = 0, prunePackable: Int = 0, garbage: Int = 0) {
        self.loose = loose; self.packs = packs; self.looseKiB = looseKiB; self.packKiB = packKiB
        self.prunePackable = prunePackable; self.garbage = garbage
    }

    /// Parses `git count-objects -v`; nil unless both `count` and `packs` are present.
    public static func parse(_ output: String) -> RepositoryObjectStats? {
        var values: [String: Int] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = value
        }
        guard let loose = values["count"], let packs = values["packs"] else { return nil }
        return RepositoryObjectStats(loose: loose, packs: packs, looseKiB: values["size"] ?? 0, packKiB: values["size-pack"] ?? 0,
                                     prunePackable: values["prune-packable"] ?? 0, garbage: values["garbage"] ?? 0)
    }
}

public enum RepositoryMaintenance {
    /// Arguments after `git -C <repository>` for the conservative gc described above.
    public static let gcArguments = [
        "-c", "gc.reflogExpire=never", "-c", "gc.reflogExpireUnreachable=never",
        "-c", "gc.worktreePruneExpire=never", "-c", "gc.pruneExpire=never",
        "-c", "gc.rerereResolved=36500", "-c", "gc.rerereUnresolved=36500",
        "gc", "--no-prune", "--quiet",
    ]
    /// A large repository can take many minutes; the child is stopped after this.
    public static let gcTimeout: Double = 45 * 60

    /// Object counts for one repository, or nil when Git cannot answer.
    public static func objectStats(_ repository: String) -> RepositoryObjectStats? {
        let result = CommandRunner().git(repository, ["count-objects", "-v"], timeout: 15)
        return result.succeeded ? RepositoryObjectStats.parse(result.output) : nil
    }

    /// Runs the conservative gc. Only ever called after the user confirms it.
    public static func collectGarbage(_ repository: String, timeout: Double = gcTimeout) async -> CommandResult {
        await CommandRunner().run("/usr/bin/git", ["-C", repository] + gcArguments, timeout: timeout)
    }

    /// Bytes a folder takes on disk (allocated blocks, not crossing into other volumes), or nil
    /// when `du` fails, times out or cannot read part of the folder.
    public static func diskUsage(_ path: String, timeout: Double = 30) async -> Int64? {
        let result = await CommandRunner().run("/usr/bin/du", ["-skx", path], timeout: timeout)
        return result.succeeded ? parseDiskUsage(result.output) : nil
    }

    /// Parses `du -sk` ("123456\t/path") into bytes.
    public static func parseDiskUsage(_ output: String) -> Int64? {
        guard let field = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0.isNewline }).first,
              let kib = Int64(field) else { return nil }
        return kib * 1_024
    }
}
