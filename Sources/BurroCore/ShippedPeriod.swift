// Weekly and monthly reports for the Shipped section, built only from the days' cached digests
// (no GitHub reads): one counting sentence, a few written lines per person on what the work was
// (one Claude call per week or month, cached like the days and rewritten only while the period is
// still open and its days change), and each day's or week's line underneath.
import CryptoKit
import Foundation

public struct ShippedPeriod: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case week, month }
    public var kind: Kind
    /// The first day, and the day after the last.
    public var start: Date
    public var end: Date

    public static func containing(_ day: Date, _ kind: Kind, calendar: Calendar = .current) -> ShippedPeriod {
        let interval = calendar.dateInterval(of: kind == .week ? .weekOfYear : .month, for: calendar.startOfDay(for: day))
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
        return ShippedPeriod(kind: kind, start: interval.start, end: interval.end)
    }

    public func previous(calendar: Calendar = .current) -> ShippedPeriod {
        Self.containing(start.addingTimeInterval(-3600), kind, calendar: calendar)
    }

    /// Every day of the period, oldest first.
    public func days(calendar: Calendar = .current) -> [Date] {
        var days: [Date] = []
        var day = start
        while day < end {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return days
    }

    /// The weeks a month's days fall in (the first and last may reach into the next months).
    public func weeks(calendar: Calendar = .current) -> [ShippedPeriod] {
        var weeks: [ShippedPeriod] = []
        for day in days(calendar: calendar) {
            let week = Self.containing(day, .week, calendar: calendar)
            if weeks.last != week { weeks.append(week) }
        }
        return weeks
    }

    public func cacheID(repository: String, calendar: Calendar = .current) -> String {
        "\(repository) \(kind.rawValue) " + ShippedSummary.stamp(start, kind == .week ? "yyyy-MM-dd" : "yyyy-MM", calendar: calendar)
    }

    /// Over for good: half an hour after its last midnight.
    public func isClosed(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        ShippedSummary.isClosed(end.addingTimeInterval(-3600), now: now, calendar: calendar)
    }

    public func contains(_ day: Date) -> Bool { day >= start && day < end }
}

/// A week or month of digests, put together.
public struct ShippedPeriodReport: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        public var day: Date
        public var digest: ShippedDigest?
        public var summary: String?
    }
    public struct Tally: Sendable, Equatable, Identifiable {
        public var person: ShippedDigest.Person
        public var merged: Int
        public var pushes: Int
        public var releases: Int
        public var id: String { person.login }
    }

    public var period: ShippedPeriod
    public var repository: String
    /// The period's days up to the last one asked for (today, for an open period).
    public var days: [Day]
    /// Days in that span with no digest yet (never read). Days before the repository's first
    /// recorded day don't count.
    public var missing: Int
    public var defaultBranch: String
    public var tallies: [Tally]
    /// This period's cached summary, when it still holds (final, or written from these days).
    public var summary: String?

    /// `entries` is the summary cache; `live` overrides it for days the app has just read.
    public init(period: ShippedPeriod, repository: String, entries: [String: ShippedSummary.Entry], live: [Date: ShippedDigest] = [:],
                through last: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        self.repository = repository
        let prefix = repository + " "
        let first = entries.keys.filter { $0.hasPrefix(prefix) && $0.count == prefix.count + 10 }.min()
        let lastDay = calendar.startOfDay(for: last)
        days = period.days(calendar: calendar).filter { $0 <= lastDay }.map { day in
            let entry = entries[ShippedSummary.cacheID(repository: repository, day: day, calendar: calendar)]
            return Day(day: day, digest: live[day] ?? entry?.digest, summary: entry?.text.isEmpty == false ? entry?.text : nil)
        }
        missing = days.filter { day in
            guard day.digest == nil else { return false }
            let id = ShippedSummary.cacheID(repository: repository, day: day.day, calendar: calendar)
            return first.map { id >= $0 } ?? true
        }.count
        // One name per person across the period: the one GitHub gave over a bare login.
        var best: [String: String] = [:]
        for digest in days.compactMap(\.digest) {
            for person in digest.people where best[person.login] == nil || best[person.login] == person.login { best[person.login] = person.name }
        }
        days = days.map { day in
            var day = day
            day.digest = day.digest.map { digest in
                digest.renamed(Dictionary(digest.people.compactMap { person in
                    best[person.login].flatMap { $0 != person.name ? (person.name, $0) : nil }
                }, uniquingKeysWith: { first, _ in first }))
            }
            return day
        }
        let digests = days.compactMap(\.digest)
        defaultBranch = digests.last?.defaultBranch ?? "staging"
        var people: [String: ShippedDigest.Person] = [:]
        var merged: [String: Int] = [:], pushes: [String: Int] = [:], releases: [String: Int] = [:]
        for digest in digests {
            for person in digest.people {
                if people[person.name] == nil || people[person.name]?.avatar == nil { people[person.name] = person }
                pushes[person.name, default: 0] += person.pushes
            }
            for pull in digest.merged where pull.base == nil { merged[pull.author, default: 0] += 1 }
            for release in digest.production { if let actor = release.actor { releases[actor, default: 0] += 1 } }
        }
        tallies = people.values.map { person in
            Tally(person: person, merged: merged[person.name] ?? 0, pushes: pushes[person.name] ?? 0, releases: releases[person.name] ?? 0)
        }
        .filter { $0.merged + $0.pushes + $0.releases > 0 }
        .sorted {
            if ($0.person.name == "You") != ($1.person.name == "You") { return $0.person.name == "You" }
            let a = $0.merged * 10 + $0.pushes, b = $1.merged * 10 + $1.pushes
            return a != b ? a > b : $0.person.name < $1.person.name
        }
        summary = cached(entries, calendar: calendar).flatMap { $0.text.isEmpty ? nil : $0.text }
    }

    public var digests: [ShippedDigest] { days.compactMap(\.digest) }
    /// Who the written summary covers: people who merged or released something. Pushes alone
    /// show in the tallies; over a week or month they'd only get a filler line.
    var writers: [Tally] {
        let active = tallies.filter { $0.merged > 0 || $0.releases > 0 }
        return active.isEmpty ? tallies : active
    }
    public var isEmpty: Bool { digests.allSatisfy(\.isEmpty) }
    public var production: [(day: String, release: ShippedDigest.Release)] {
        digests.flatMap { digest in digest.production.map { (digest.date, $0) } }
    }
    public var mergedCount: Int { digests.reduce(0) { $0 + $1.merged.count } }

    /// "You merged 32 pull requests into staging and Dante merged 40. Shipped to production twice."
    public var headline: String {
        let counts = tallies.filter { $0.merged > 0 }.map { ($0.person.name, $0.merged) }
        var text: String
        if let first = counts.first {
            text = "\(first.0) merged \(ShippedDay.count(first.1, "pull request")) into \(defaultBranch)"
            let rest = counts.dropFirst()
            if rest.count == 1, let only = rest.first {
                text += " and \(only.0) merged \(only.1)"
            } else if rest.count > 1 {
                let items = rest.map { "\($0.0) \($0.1)" }
                text += ", " + items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
            }
            text += "."
        } else {
            text = "No pull requests merged into \(defaultBranch)."
        }
        let shipped = digests.reduce(0) { $0 + $1.shippedCount }, failed = digests.reduce(0) { $0 + $1.failedCount }
        switch shipped {
        case 0 where failed == 0: text += " Nothing went to production."
        case 0: break
        case 1: text += " Shipped to production once."
        case 2: text += " Shipped to production twice."
        default: text += " Shipped to production \(shipped) times."
        }
        if failed > 0 { text += failed == 1 ? " One production run failed." : " \(failed) production runs failed." }
        return text
    }

    /// What the model reads, or nil when nothing happened. Pull requests per person, grouped by
    /// area so a month reads as themes; production with its dates.
    public var input: String? {
        guard !isEmpty, let first = days.first?.day, let last = days.last?.day else { return nil }
        let calendar = Calendar.current
        let span = "\(ShippedSummary.stamp(first, "EEEE yyyy-MM-dd", calendar: calendar)) to \(ShippedSummary.stamp(last, "EEEE yyyy-MM-dd", calendar: calendar))"
        var lines = ["Period: \(period.kind == .week ? "one week" : "one month"), \(span)\(missing > 0 ? " (\(ShippedDay.count(missing, "day")) not read)" : "")",
                     "Repository: \(repository) (pull requests merge into \(defaultBranch); production is separate)",
                     "People, in this order: " + writers.map(\.person.name).joined(separator: ", ")]
        lines += ["", "Production:"]
        let releases = production
        if releases.isEmpty { lines.append("- nothing went to production") }
        lines += ShippedDigest.counted(releases.map { "\($0.day): \($0.release.line)" }).map { "- " + $0 }
        lines += ["", "Merged into \(defaultBranch):"]
        let pulls = digests.flatMap(\.merged)
        if pulls.isEmpty { lines.append("- nothing merged") }
        for tally in writers {
            let own = pulls.filter { $0.author == tally.person.name }
            guard !own.isEmpty else { continue }
            lines.append("\(tally.person.name) (\(own.count)):")
            let byArea = Dictionary(grouping: own) { $0.area ?? "" }
            for area in byArea.keys.sorted(by: { (byArea[$0]?.count ?? 0, $1) > (byArea[$1]?.count ?? 0, $0) }) {
                for pull in (byArea[area] ?? []).sorted(by: { $0.number < $1.number }) { lines.append("- \(pull.line)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func instructions(_ kind: ShippedPeriod.Kind) -> String { ShippedBrief.periodInstructions(kind) }

    public var key: String? {
        input.map { input in
            let material = "\(ShippedSummary.version)\n\(ShippedSummary.model)\n\(ShippedSummary.effort)\n\(Self.instructions(period.kind))\n\(input)"
            return SHA256.hash(data: Data(material.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Final once its last day is over and every day in it was read. A week so far (up to a past
    /// day) is final too: those days won't change.
    public func isFinal(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let last = days.last?.day else { return false }
        return ShippedSummary.isClosed(last, now: now, calendar: calendar) && missing == 0
    }

    /// Where this report's summary is cached: the period's own id, or, for part of a period (a
    /// week so far), that id with its last day ("… week 2026-11-09 to 2026-11-11").
    public var cacheID: String { Self.cacheID(period: period, repository: repository, through: days.last?.day ?? period.start) }

    /// Up to today (the period is still open) it's the period's own id, rewritten as days arrive.
    public static func cacheID(period: ShippedPeriod, repository: String, through: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.end
        let day = calendar.startOfDay(for: through)
        let id = period.cacheID(repository: repository, calendar: calendar)
        return day >= last || day >= calendar.startOfDay(for: now) ? id : id + " to " + ShippedSummary.stamp(day, "yyyy-MM-dd", calendar: calendar)
    }

    /// Asks Claude once. Blocks for a few seconds: call it from a detached task.
    public func generate(executable: String? = ClaudeLaunch.executable(), folder: URL = ShippedSummary.folder) -> (result: Result<String, ShippedSummary.Failure>, cost: Double?) {
        guard let input else { return (.failure(.failed("Nothing happened in this period.")), nil) }
        return ShippedSummary.ask(input: input, instructions: Self.instructions(period.kind), shape: .period, names: Set(writers.map(\.person.name)),
                                  production: !production.isEmpty, executable: executable, folder: folder)
    }

    /// The cached summary for this period when it's still good: final, or written from these exact days.
    public func cached(_ entries: [String: ShippedSummary.Entry], calendar: Calendar = .current) -> ShippedSummary.Entry? {
        guard let entry = entries[cacheID] else { return nil }
        return entry.isSettled || entry.key == key ? entry : nil
    }

    /// Plain text for Copy and `burro-inspect`.
    public func render(summary: String?, weeks: [ShippedPeriodReport] = [], calendar: Calendar = .current) -> String {
        var lines = ["Shipped \(title(calendar: calendar)) · \(repository)", headline]
        if let summary, !summary.isEmpty { lines += [""] + ShippedBrief.plain(summary).split(whereSeparator: \.isNewline).map(String.init) }
        if period.kind == .week {
            let active = days.filter { $0.digest.map { !$0.isEmpty } ?? false }
            if !active.isEmpty { lines += ["", "Days"] }
            for day in active {
                lines.append("\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(Self.counts(day.digest))")
                for line in ShippedBrief.plain(day.summary ?? "").split(whereSeparator: \.isNewline) where !(day.summary ?? "").isEmpty { lines.append("  " + line) }
            }
        } else if !weeks.isEmpty {
            lines += ["", "Weeks"]
            for week in weeks where !week.isEmpty {
                lines.append("\(week.title(calendar: calendar)): \(week.tallies.filter { $0.merged > 0 }.map { "\($0.person.name) \($0.merged)" }.joined(separator: " · "))")
            }
        }
        if missing > 0 { lines += ["", "\(ShippedDay.count(missing, "day")) not read yet."] }
        return lines.joined(separator: "\n")
    }

    /// "Week of 2 Nov" or "November 2026".
    public func title(calendar: Calendar = .current) -> String {
        period.kind == .week ? "week of " + period.start.formatted(.dateTime.day().month(.abbreviated))
            : period.start.formatted(.dateTime.month(.wide).year())
    }

    /// "You 6 · Dante 3 merged", or what else happened.
    public static func counts(_ digest: ShippedDigest?) -> String {
        guard let digest, !digest.isEmpty else { return "nothing" }
        var byPerson: [String: Int] = [:]
        for pull in digest.merged { byPerson[pull.author, default: 0] += 1 }
        let merged = digest.people.compactMap { person in byPerson[person.name].map { "\(person.name) \($0)" } }
        var parts = merged.isEmpty ? [] : [merged.joined(separator: " · ") + " merged"]
        if digest.shippedCount > 0 { parts.append("shipped to production") }
        if parts.isEmpty { parts.append("pushes only") }
        return parts.joined(separator: " · ")
    }
}
