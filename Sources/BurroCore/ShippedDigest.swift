// A shipped day boiled down to what the written summaries need: who took part, what went to
// production, each merged pull request's title, area and size, and (for people who merged
// nothing) what they're still working on. Small enough to keep on disk for every day, so weekly
// and monthly reports are built from it without reading GitHub again.
import Foundation

public struct ShippedDigest: Codable, Sendable, Equatable {
    public struct Person: Codable, Sendable, Equatable {
        /// "You", a first name, or the login: what summaries and reports call them.
        public var name: String
        public var login: String
        public var avatar: String?
        public var pushes: Int
    }
    public struct Release: Codable, Sendable, Equatable {
        public var title: String
        /// "promoted staging to main", "production workflow", "deployment", or nil.
        public var how: String?
        public var actor: String?
        /// "live", "failed", "waiting for approval"…
        public var status: String
    }
    public struct Pull: Codable, Sendable, Equatable {
        public var number: Int
        public var author: String
        public var area: String?
        public var title: String
        /// Set when it merged into a branch other than the default one.
        public var base: String?
        public var additions: Int
        public var deletions: Int
    }
    public struct Work: Codable, Sendable, Equatable {
        public var person: String
        public var direct: Bool
        public var items: [String]
    }

    /// "2026-11-09".
    public var date: String
    /// "Monday 2026-11-09".
    public var stamp: String
    public var repository: String
    public var defaultBranch: String
    public var people: [Person]
    public var production: [Release]
    public var merged: [Pull]
    public var inProgress: [Work]

    public var isEmpty: Bool { production.isEmpty && merged.isEmpty && inProgress.isEmpty }
    public var shippedCount: Int { production.filter { $0.status != "failed" && $0.status != "cancelled" }.count }
    public var failedCount: Int { production.filter { $0.status == "failed" }.count }

    public init(_ day: ShippedDay, calendar: Calendar = .current) {
        let people = day.contributors
        let mergers = Set(day.merged.map(\.author))
        date = ShippedSummary.stamp(day.day, "yyyy-MM-dd", calendar: calendar)
        stamp = ShippedSummary.stamp(day.day, "EEEE yyyy-MM-dd", calendar: calendar)
        repository = day.repository
        defaultBranch = day.defaultBranch
        self.people = people.map { person in
            Person(name: person.displayName, login: person.login, avatar: person.avatar?.absoluteString,
                   pushes: day.branches(by: person.login).reduce(0) { $0 + $1.pushes })
        }
        production = day.production.sorted { $0.id < $1.id }.map { release in
            let promotion = release.kind == .promotion ? ShippedDay.promotion(release.title) : nil
            let how: String? = switch release.kind {
            case .promotion: promotion.map { "promoted \($0.from) to \($0.to)" } ?? release.detail
            case .push: nil // "Pushed straight to main" says it
            case .workflow: "production workflow"
            case .deployment: "deployment"
            }
            return Release(title: promotion?.text ?? release.title, how: how, actor: release.actor.map { day.person($0).displayName },
                           status: ShippedSummary.statusWords(release.status))
        }
        merged = people.flatMap { person in
            day.merged(by: person.login).sorted { $0.number < $1.number }.map { pull in
                let parts = ShippedDay.area(of: pull.title)
                return Pull(number: pull.number, author: person.displayName, area: parts.area, title: parts.text,
                            base: pull.base == day.defaultBranch ? nil : pull.base, additions: pull.additions, deletions: pull.deletions)
            }
        }
        inProgress = people.filter { !mergers.contains($0.login) }.compactMap { person in
            let branches = day.branches(by: person.login)
            let direct = branches.contains { $0.name == day.defaultBranch }
            let items = branches.filter { $0.name != day.defaultBranch }.sorted { $0.name < $1.name }.map { branch in
                if let pull = branch.pullRequest {
                    let parts = ShippedDay.area(of: pull.title)
                    return "\(parts.area.map { "[\($0)] " } ?? "")\(parts.text) (\(pull.state == "MERGED" ? "pull request since merged" : "open pull request"))"
                }
                return "branch \(branch.name) (no pull request yet)"
            }
            return items.isEmpty && !direct ? nil : Work(person: person.displayName, direct: direct, items: items)
        }
    }

    /// What the model reads for this day, or nil when there's nothing to summarise.
    public var input: String? {
        guard !isEmpty else { return nil }
        var lines = ["Day: \(stamp)",
                     "Repository: \(repository) (pull requests merge into \(defaultBranch); production is separate)",
                     "People, in this order: " + people.map(\.name).joined(separator: ", ")]
        lines += ["", "Production:"]
        if production.isEmpty { lines.append("- nothing went to production") }
        lines += Self.counted(production.map(\.line)).map { "- " + $0 }
        lines += ["", "Merged into \(defaultBranch):"]
        if merged.isEmpty { lines.append("- nothing merged") }
        lines += pullLines(merged)
        if !inProgress.isEmpty {
            lines += ["", "Still in progress (pushed today, nothing merged yet):"]
            for work in inProgress {
                lines.append("\(work.person):")
                if work.direct { lines.append("- pushed commits straight to \(defaultBranch)") }
                lines += work.items.map { "- " + $0 }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Name:" then one line per pull request, grouped in the order the pulls come.
    func pullLines(_ pulls: [Pull]) -> [String] {
        var lines: [String] = []
        var current: String?
        for pull in pulls {
            if pull.author != current { lines.append("\(pull.author):"); current = pull.author }
            lines.append("- \(pull.line)")
        }
        return lines
    }

    /// Merged pull requests per person, in the order people appear.
    public func merged(by name: String) -> [Pull] { merged.filter { $0.author == name } }
}

extension ShippedDigest {
    /// Identical lines once each, in first-seen order, with "(×3)" when repeated.
    static func counted(_ lines: [String]) -> [String] {
        var order: [String] = [], counts: [String: Int] = [:]
        for line in lines {
            if counts[line] == nil { order.append(line) }
            counts[line, default: 0] += 1
        }
        return order.map { counts[$0, default: 1] > 1 ? "\($0) (×\(counts[$0, default: 1]))" : $0 }
    }

    /// The same day with people renamed (old name → new name), so one person reads the same
    /// across days ("sam-dev" on a push-only day, "Sam" on a day they merged).
    public func renamed(_ names: [String: String]) -> ShippedDigest {
        guard !names.isEmpty else { return self }
        func name(_ value: String) -> String { names[value] ?? value }
        var copy = self
        copy.people = people.map { var person = $0; person.name = name(person.name); return person }
        copy.merged = merged.map { var pull = $0; pull.author = name(pull.author); return pull }
        copy.production = production.map { var release = $0; release.actor = release.actor.map(name); return release }
        copy.inProgress = inProgress.map { var work = $0; work.person = name(work.person); return work }
        return copy
    }
}

extension ShippedDigest.Release {
    var line: String { ([title, how, actor.map { "by \($0)" }, status].compactMap { $0 }).joined(separator: " · ") }
}

extension ShippedDigest.Pull {
    var line: String {
        "\(area.map { "[\($0)] " } ?? "")\(title)\(base.map { " (into \($0))" } ?? "") · +\(additions) −\(deletions) lines"
    }
}
