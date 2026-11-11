// --activity-import-dayflow [--dry-run] [--database <path>] [--activity-dir <path>]: the one-time
// backfill of Burro's local activity log from Dayflow's database (DayflowImport in BurroCore).
// The only burro-inspect command allowed to touch activity data, and only to write the local log:
// it prints counts and hours, never a title, host or app name, and makes no network call.
import Foundation
import BurroCore

enum DayflowImportCommand {
    static func run(_ arguments: [String]) {
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let known: Set<String> = ["--dry-run", "--database", "--activity-dir"]
        for (index, argument) in arguments.enumerated() where !known.contains(argument) {
            guard index > 0, ["--database", "--activity-dir"].contains(arguments[index - 1]) else {
                print("Unknown argument. Usage: burro-inspect --activity-import-dayflow [--dry-run] [--database <path>] [--activity-dir <path>]")
                exit(2)
            }
        }
        // A flag without a path must not fall back to the real location.
        for flag in ["--database", "--activity-dir"] where arguments.contains(flag) && (value(flag) ?? "--").hasPrefix("--") {
            print("\(flag) needs a path.")
            exit(2)
        }
        let expand = { (path: String) in URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let database = value("--database").map(expand) ?? DayflowImport.defaultDatabase
        let folder = value("--activity-dir").map(expand) ?? DayflowImport.defaultActivityFolder
        let dryRun = arguments.contains("--dry-run")
        print(dryRun ? "Dry run: nothing will be written." : "Importing Dayflow into the activity log.")
        if DayflowImport.walPending(database: database) {
            print("Note: the database has an unmerged -wal file; its newest rows (if any) are not read in immutable mode.")
        }
        let report: DayflowImport.Report
        do { report = try DayflowImport.run(database: database, folder: folder, dryRun: dryRun) } catch {
            print("Import failed: \(error.localizedDescription)")
            exit(1)
        }
        print("""
        Cards read: \(report.cardsRead)
        Skipped: \(report.deleted) deleted, \(report.idle) idle, \(report.invalid) invalid, \(report.tooOld) older than \(DayflowImport.retentionDays) days
        Became Private: \(report.madePrivate)
        Trimmed at live tracking: \(report.trimmedForLive)
        Earlier imported spans replaced: \(report.replaced)
        Spans \(dryRun ? "to write" : "written"): \(report.spansWritten) over \(report.days) days
        Hours by category:
        """)
        for (category, seconds) in report.seconds.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }) {
            print("  \(category.rawValue.capitalized): \(String(format: "%.1f", seconds / 3600))")
        }
    }
}
