// Discover registered worktrees and collect read-only evidence for cleanup decisions.
import Foundation

public struct WorktreeRecord: Sendable {
    public var path: String
    public var head: String = ""
    public var branch: String = "Detached HEAD"
    public var locked = false
    public var prunable = false
    public var bare = false
}
public enum GitParser {
    public static func worktrees(_ output: String) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []; var current: WorktreeRecord?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if field.hasPrefix("worktree ") {
                if let current { records.append(current) }
                current = WorktreeRecord(path: Paths.canonical(String(field.dropFirst(9))))
            } else if field.hasPrefix("HEAD ") { current?.head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { current?.branch = String(field.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if field == "locked" || field.hasPrefix("locked ") { current?.locked = true }
            else if field == "prunable" || field.hasPrefix("prunable ") { current?.prunable = true }
            else if field == "bare" { current?.bare = true }
        }
        if let current { records.append(current) }
        return records
    }
    public static func changes(_ output: String) -> (tracked: Int, untracked: Int) {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true)
        var tracked = 0, untracked = 0, index = 0
        while index < entries.count {
            let code = String(entries[index].prefix(2))
            if code == "??" { untracked += 1 } else { tracked += 1 }
            index += code.contains("R") || code.contains("C") ? 2 : 1
        }
        return (tracked, untracked)
    }
}
public struct GitReader: Sendable {
    let runner: CommandRunner
    public init(deadline: Date? = nil) { runner = CommandRunner(deadline: deadline) }
    public func comparisonBase(_ path: String, override: String?) -> String? {
        if let override, !override.isEmpty {
            return runner.git(path, ["rev-parse", "--verify", "--end-of-options", override + "^{commit}"]).succeeded ? override : nil
        }
        let symbolic = runner.git(path, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        let choices = (symbolic.succeeded ? [symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines)] : []) + ["origin/main", "origin/master", "origin/staging"]
        return choices.first { runner.git(path, ["rev-parse", "--verify", "--end-of-options", $0 + "^{commit}"]).succeeded }
    }
    public func facts(_ record: WorktreeRecord, base: String?, includeDiff: Bool = true) -> GitFacts {
        var facts = GitFacts(); facts.base = base
        facts.branch = record.branch == "Detached HEAD" ? nil : record.branch
        guard FileManager.default.fileExists(atPath: record.path) else { facts.errors.append("Folder cannot be inspected"); return facts }
        if FileManager.default.fileExists(atPath: record.path + "/.gitmodules") {
            facts.errors.append("Repository declares submodules; inspect their local data separately")
        }
        let status = runner.git(record.path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"])
        if status.succeeded {
            let changes = GitParser.changes(status.output); facts.changed = changes.tracked; facts.untracked = changes.untracked
        } else { facts.errors.append(status.timedOut ? "Git status timed out" : "Git status failed") }
        let ignored = runner.git(record.path, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        if ignored.succeeded {
            let entries = ignored.output.split(separator: "\0").map(String.init)
            facts.ignored = Array(entries.prefix(12)); facts.ignoredCount = entries.count
        } else { facts.errors.append("Ignored files could not be checked") }
        if let base {
            let diff = includeDiff ? runner.git(record.path, ["diff", "--numstat", "--no-renames", "--merge-base", base, "--"]) : CommandResult(code: -1, output: "", error: "", timedOut: false)
            if diff.succeeded {
                var added = 0, removed = 0
                for line in diff.output.split(separator: "\n") {
                    let fields = line.split(separator: "\t")
                    if fields.count >= 2, let a = Int(fields[0]), let r = Int(fields[1]) { added += a; removed += r }
                }
                let untracked = runner.git(record.path, ["ls-files", "--others", "--exclude-standard", "-z"])
                if untracked.succeeded {
                    for name in untracked.output.split(separator: "\0") {
                        let url = URL(fileURLWithPath: record.path).appendingPathComponent(String(name))
                        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                        guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? Int.max) < 8 * 1024 * 1024,
                              let data = try? Data(contentsOf: url), !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
                        added += text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
                    }
                }
                facts.workspaceDiff = ChatEdits(hasEdits: added + removed > 0, added: added, removed: removed, exact: true)
            }
            let merged = runner.git(record.path, ["merge-base", "--is-ancestor", "HEAD", base])
            if !merged.timedOut && [0, 1].contains(merged.code) { facts.merged = merged.code == 0 }
        }
        let unpushed = runner.git(record.path, ["rev-list", "--count", "HEAD", "--not", "--remotes"])
        if unpushed.succeeded { facts.unpushed = Int(unpushed.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let upstream = runner.git(record.path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        if upstream.succeeded {
            facts.upstream = upstream.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let divergence = runner.git(record.path, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            let counts = divergence.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if divergence.succeeded && counts.count == 2 { facts.upstreamAhead = counts[0]; facts.upstreamBehind = counts[1] }
        }
        let timestamp = runner.git(record.path, ["log", "-1", "--format=%ct"])
        if let seconds = Double(timestamp.output.trimmingCharacters(in: .whitespacesAndNewlines)) { facts.lastCommit = Date(timeIntervalSince1970: seconds) }
        let gitDir = runner.git(record.path, ["rev-parse", "--absolute-git-dir"])
        if gitDir.succeeded {
            let path = gitDir.output.trimmingCharacters(in: .whitespacesAndNewlines)
            facts.operationInProgress = ["index.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "BISECT_LOG"].contains {
                FileManager.default.fileExists(atPath: path + "/" + $0)
            }
        } else { facts.errors.append("Git operation state could not be checked") }
        return facts
    }
}
