// What a chat's folder has changed, file by file, for the Chats page's details panel: a read-only
// `git diff --numstat` against where the branch left its base (the merge base with the scan's base,
// or with origin's HEAD, then origin/main, master, staging), committed or not. Untracked files
// aren't in a diff and so aren't listed (the Folder row counts them as uncommitted). Runs git
// without a shell and with timeouts; call off the main thread. This Mac only.
import Foundation

/// One file in a diff. `added`/`removed` are nil for a binary file.
public struct ChatFileChange: Equatable, Sendable, Identifiable {
    public var path: String
    public var added: Int?
    public var removed: Int?
    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public init(path: String, added: Int?, removed: Int?) { self.path = path; self.added = added; self.removed = removed }
}

public struct ChatChangeList: Equatable, Sendable {
    public var files: [ChatFileChange]
    public init(files: [ChatFileChange]) { self.files = files }
    public var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    public var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

public enum ChatChanges {
    /// At most this many files are kept (largest change first).
    static let fileLimit = 200

    /// The folder's changes since its branch left `base` (or the base git finds), or nil when the
    /// folder isn't in a Git work tree or git failed.
    public static func read(path: String, base: String?) -> ChatChangeList? {
        let git = CommandRunner()
        guard git.git(path, ["rev-parse", "--is-inside-work-tree"], timeout: 3).succeeded else { return nil }
        let base = (base?.isEmpty == false ? base : nil) ?? GitReader().comparisonBase(path, override: nil)
        var against = "HEAD"
        if let base, !base.isEmpty, !base.hasPrefix("-") {
            let merge = git.git(path, ["merge-base", base, "HEAD"], timeout: 5)
            let commit = merge.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if merge.succeeded, commit.allSatisfy(\.isHexDigit), commit.count >= 7 { against = commit }
        }
        let result = git.git(path, ["diff", "--numstat", "--no-color", "--no-ext-diff", against, "--"], timeout: 8)
        guard result.succeeded else { return nil }
        return ChatChangeList(files: parseNumstat(result.output))
    }

    /// "12\t3\tSources/App.swift", "-\t-\tlogo.png" (binary), and renames "a => b" or "dir/{a => b}.swift",
    /// listed by their new path; largest change first, then by path.
    public static func parseNumstat(_ text: String) -> [ChatFileChange] {
        var files: [ChatFileChange] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let added = Int(parts[0]), removed = Int(parts[1])
            guard (added != nil || parts[0] == "-"), (removed != nil || parts[1] == "-") else { continue }
            let path = destination(String(parts[2]))
            guard !path.isEmpty else { continue }
            files.append(ChatFileChange(path: path, added: added, removed: removed))
        }
        files.sort { a, b in
            let (x, y) = ((a.added ?? 0) + (a.removed ?? 0), (b.added ?? 0) + (b.removed ?? 0))
            return x != y ? x > y : a.path < b.path
        }
        return Array(files.prefix(fileLimit))
    }

    /// The path after a rename, without git's quoting.
    static func destination(_ raw: String) -> String {
        var path = raw
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        if let open = path.firstIndex(of: "{"), let close = path[open...].firstIndex(of: "}"),
           let arrow = path[open...close].range(of: " => ") {
            let new = path[arrow.upperBound..<close]
            path = String(path[..<open]) + new + String(path[path.index(after: close)...])
            return path.replacingOccurrences(of: "//", with: "/")
        }
        if let arrow = path.range(of: " => ") { return String(path[arrow.upperBound...]) }
        return path
    }
}
