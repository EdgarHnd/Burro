// Inspect the same live snapshot as the app without launching a window.
import Foundation
import BurroCore

@main struct BurroInspect {
    static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        if paths == ["--profile-git"] {
            try await PerformanceProfile.git()
            return
        }
        if paths.first == "--profile" || paths.first == "--profile-agents" {
            try PerformanceProfile.run(includeUsage: paths.first == "--profile")
            return
        }
        // --shipped <owner/name> [days ago] [--summary] [--week|--month]: what shipped on GitHub that day (or
        // the week or month holding it, from the cache), as text,
        // with the app's cached written summary when it matches the day. --summary writes one
        // (one Claude call) when the cache has none, and keeps it for the app too.
        if paths.first == "--shipped", paths.count >= 2 {
            let write = paths.contains("--summary")
            let kind: ShippedPeriod.Kind? = paths.contains("--week") ? .week : paths.contains("--month") ? .month : nil
            let rest = paths.filter { !["--summary", "--week", "--month"].contains($0) }
            if let kind {
                // The week or month holding that day, from the cache only.
                let ago = rest.count > 2 ? Int(rest[2]) ?? 0 : 0
                let day = Calendar.current.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
                let period = ShippedPeriod.containing(day, kind)
                var cache = ShippedSummaryCache.read()
                let report = ShippedPeriodReport(period: period, repository: rest[1], entries: cache.entries)
                var summary = report.summary
                if summary == nil, write, let key = report.key {
                    switch report.generate().result {
                    case .success(let text):
                        summary = text
                        let entry = ShippedSummary.Entry(key: key, text: text, model: ShippedSummary.model, createdAt: Date(), final: report.isFinal())
                        cache.store(entry, for: period.cacheID(repository: rest[1]))
                        try? ShippedSummaryCache.save([period.cacheID(repository: rest[1]): entry])
                    case .failure(let failure): print("Summary: \(failure.short). \(failure.detail)\n")
                    }
                }
                let weeks = kind == .month ? period.weeks().map { ShippedPeriodReport(period: $0, repository: rest[1], entries: cache.entries) } : []
                print(report.render(summary: summary, weeks: weeks))
                return
            }
            let ago = rest.count > 2 ? Int(rest[2]) ?? 0 : 0
            let day = Calendar.current.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
            switch await ShippedReader.load(day: day, repository: rest[1]) {
            case .failure(let failure): print("\(failure.title): \(failure.detail)")
            case .success(let shipped):
                var summary: String?
                if let input = ShippedSummary.input(shipped) {
                    let id = ShippedSummary.cacheID(repository: shipped.repository, day: shipped.day), key = ShippedSummary.key(input: input)
                    var cache = ShippedSummaryCache.read()
                    summary = cache.fresh(id, key: key)?.text
                    if summary == nil, write {
                        switch ShippedSummary.generate(for: shipped, input: input) {
                        case .success(let text):
                            summary = text
                            let entry = ShippedSummary.Entry(key: key, text: text, model: ShippedSummary.model, createdAt: Date(),
                                                             digest: ShippedDigest(shipped), final: ShippedSummary.isClosed(shipped.day))
                            cache.store(entry, for: id)
                            try? ShippedSummaryCache.save([id: entry])
                        case .failure(let failure): print("Summary: \(failure.short). \(failure.detail)\n")
                        }
                    }
                }
                print(ShippedText.render(shipped, summary: summary))
            }
            return
        }
        // --shipped-backfill <owner/name> [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--dry-run] [--limit N] [--force] [--days-only|--periods-only]:
        // writes the daily summaries for every past day (default: from the repository's creation to
        // yesterday) into the app's cache, then every closed week and month from those days. Finished
        // ones are skipped, so it can be stopped and rerun.
        if paths.first == "--shipped-backfill", paths.count >= 2 {
            try await backfill(Array(paths.dropFirst()))
            return
        }
        if paths == ["--agents"] {
            let activity = AgentMonitor().sample()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            struct Output: Encodable { var sessions: [AgentSession]; var warnings: [String] }
            FileHandle.standardOutput.write(try encoder.encode(Output(sessions: activity.visibleSessions(includeIdle: true), warnings: activity.warnings)))
            return
        }
        let snapshot = await Scanner().scan(ScanConfiguration(repositories: paths, discover: paths.isEmpty))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(snapshot))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// A progress line, written straight away (print buffers when piped to a file).
    @Sendable static func progress(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func backfill(_ arguments: [String]) async throws {
        let repository = arguments[0]
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        guard let from = value("--from").flatMap(parse.date(from:)) ?? ShippedHistory.createdAt(repository) else {
            print("Couldn't tell when \(repository) started; pass --from YYYY-MM-DD."); return
        }
        let to = min(value("--to").flatMap(parse.date(from:)) ?? yesterday, yesterday)
        let dryRun = arguments.contains("--dry-run")
        let started = Date()
        if !arguments.contains("--periods-only") {
        let result = await ShippedBackfill.run(repository: repository, from: from, to: to, dryRun: dryRun, force: arguments.contains("--force"),
                                               limit: value("--limit").flatMap(Int.init)) { line in progress(line) }
        switch result {
        case .failure(let failure): print("\(failure.title): \(failure.detail)")
        case .success(let report):
            print("""

            \(report.days) days · \(report.alreadyDone) already done · \(report.empty) with nothing to summarise (no call) · \(report.toWrite) to write
            Input for those: about \(report.characters / 4) tokens in all (\(report.toWrite == 0 ? 0 : report.characters / 4 / report.toWrite) a day on average)
            """)
            if !dryRun {
                print("Written \(report.written) · failed \(report.failed.count) · Claude cost $\(String(format: "%.3f", report.cost)) · \(Int(Date().timeIntervalSince(started))) s")
                for failure in report.failed { print("  \(failure.day): \(failure.reason)") }
            }
        }
        }
        guard !arguments.contains("--days-only") else { return }
        let periods = await ShippedBackfill.periods(repository: repository, from: from, to: to, dryRun: dryRun, force: arguments.contains("--force")) { line in
            progress(line)
        }
        print("""

        Weeks and months: \(periods.days) closed · \(periods.alreadyDone) already done · \(periods.empty) empty (no call) · \(periods.toWrite) to write (about \(periods.characters / 4) tokens of input)
        """)
        if !dryRun { print("Written \(periods.written) · Claude cost $\(String(format: "%.3f", periods.cost))") }
        for failure in periods.failed { print("  \(failure.day): \(failure.reason)") }
    }
}
