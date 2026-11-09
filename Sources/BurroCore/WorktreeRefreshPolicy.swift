// Agent activity has its own live monitor. Dashboard open/navigation events may
// refresh stale Git evidence; repeated events within 30 seconds reuse the snapshot.
import Foundation

public enum WorktreeRefreshPolicy {
    public static func isDue(lastScan: Date?, now: Date, visible: Bool) -> Bool {
        guard visible else { return false }
        guard let lastScan else { return true }
        let age = now.timeIntervalSince(lastScan)
        return age < 0 || age >= 30
    }
}
