// Worktrees in the dashboard layout, kept pure so it can be tested: the header's sentence (the
// safety promise, then where the list comes from and when it was read, folded in from the old
// "This Mac · scanned now" line) and the strip's four cells from `WorktreeBoardSummary`:
// Worktrees, Safe to clean, Reclaimable ("—" until every safe folder is measured) and Uncommitted
// work (its number amber above zero, as before). One fact per sub-line.
import Foundation

public enum WorktreeComposition {
    public static let promise = "Nothing is removed while a chat uses it or while it holds uncommitted work. Branches are always kept."

    /// Where the rows come from and when: "This Mac · scanned 2 min ago", "This Mac · scanning…", "This Mac".
    public static func scanned(didScan: Bool, scanning: Bool, scannedAt: Date, now: Date, calendar: Calendar) -> String {
        if scanning { return "This Mac · scanning…" }
        guard didScan else { return "This Mac" }
        let ago = WorktreeBoardFormat.ago(scannedAt, now: now, calendar: calendar)
        return "This Mac · scanned " + (ago == "now" ? "just now" : ago)
    }

    /// The promise, then "This Mac · scanned 2 min ago." in the quieter tone.
    public static func sentence(scanned: String) -> [TextRun] {
        [TextRun(promise + " "), TextRun(scanned + ".", .stuck)]
    }

    public static func stats(_ summary: WorktreeBoardSummary, idleUncommitted: Int) -> [DashboardStat] {
        let total = DashboardStat(id: "total", label: "Worktrees", value: "\(summary.total)",
                                  sub: [TextRun(summary.inUse == 0 ? "none in use" : "\(summary.inUse) in use")],
                                  help: "Worktrees on this Mac in the current scope. In use: a chat keeps it or a process runs in it.")
        let safe = DashboardStat(id: "safe", label: "Safe to clean", value: "\(summary.safe)",
                                 sub: [TextRun(summary.safe == 0 ? "nothing to clean" : "branches are kept")],
                                 help: "Folders cleanup allows to move to Trash: not in use, no uncommitted work, every commit kept on a branch.")
        let measured = summary.reclaimable != nil
        let reclaimable = DashboardStat(id: "reclaimable", label: "Reclaimable", value: WorktreeBoardFormat.bytes(summary.reclaimable),
                                        sub: [TextRun(summary.safe == 0 ? "nothing safe to clean"
                                                      : measured ? "freed by emptying the Trash" : "measuring the safe folders…")],
                                        help: measured ? "Disk space the safe folders take. It is freed when you empty the Trash." : "Measuring the safe folders…")
        let uncommitted = DashboardStat(id: "uncommitted", label: "Uncommitted work", value: "\(summary.uncommitted)",
                                        sub: [TextRun(summary.uncommitted == 0 ? "everything committed"
                                                      : idleUncommitted == 0 ? "all in use" : "\(idleUncommitted) not in use")],
                                        help: "Worktrees with modified, staged or untracked files; they are never removed.",
                                        warning: summary.uncommitted > 0)
        return [total, safe, reclaimable, uncommitted]
    }
}
