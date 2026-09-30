// Optional, bounded patch equivalence improves integration labels; it never authorizes cleanup.
import Foundation

struct GitIntegrationEvidence {
    var runner: CommandRunner
    func equivalentRef(_ path: String, base: String) -> String? {
        let started = Date()
        // Ignore complex/diverged histories here, including unique merge resolutions.
        let commits = runner.git(path, ["log", "--format=%H%x09%s", "--max-count=13", base + "..HEAD"], timeout: 2)
        let lines = commits.output.split(separator: "\n").map(String.init)
        guard commits.succeeded, !lines.isEmpty, lines.count <= 12 else { return nil }
        let merges = runner.git(path, ["rev-list", "--count", "--merges", base + "..HEAD"], timeout: 2)
        guard merges.succeeded, merges.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { return nil }
        let cherry = runner.git(path, ["cherry", base, "HEAD"], timeout: 2)
        let patches = cherry.output.split(separator: "\n")
        if cherry.succeeded, patches.count == lines.count, patches.allSatisfy({ $0.hasPrefix("- ") }) { return base }
        // A squash combines the branch's commits. Subjects only shortlist candidates;
        // require the combined patch ID to match before claiming equivalence.
        let subjects = lines.compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }.filter { !$0.isEmpty }
        guard Date().timeIntervalSince(started) < 4, !subjects.isEmpty else { return nil }
        let candidates = runner.git(path, ["log", "--no-merges", "--fixed-strings", "--max-count=8", "--format=%H"]
            + subjects.map { "--grep=" + $0 } + [base, "--"], timeout: 2)
        guard candidates.succeeded, !candidates.output.isEmpty else { return nil }
        let common = runner.git(path, ["merge-base", "HEAD", base], timeout: 2)
        guard common.succeeded else { return nil }
        let ancestor = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = runner.git(path, ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", ancestor, "HEAD", "--"], timeout: 2)
        guard diff.succeeded, let expected = patchID(diff.output) else { return nil }
        for commit in candidates.output.split(separator: "\n") {
            guard Date().timeIntervalSince(started) < 6 else { return nil }
            let patch = runner.git(path, ["show", "--format=medium", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", String(commit), "--"], timeout: 2)
            if patch.succeeded, patchID(patch.output) == expected { return base }
        }
        return nil
    }
    private func patchID(_ patch: String) -> String? {
        guard !patch.isEmpty else { return nil }
        let result = runner.run("/usr/bin/git", ["patch-id", "--stable"], timeout: 2, input: Data(patch.utf8))
        return result.succeeded ? result.output.split(whereSeparator: \.isWhitespace).first.map(String.init) : nil
    }
}
