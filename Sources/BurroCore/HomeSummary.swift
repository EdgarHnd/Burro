// Burro Home's rollups: live attention by project and machine, plus a plain-language summary.
// These are in-memory counts over snapshots Burro already holds, so they run in-process in
// microseconds; a worker round trip would cost more than the work. Log scanning stays in Rust.
import Foundation

public struct HomeCounts: Sendable, Equatable {
    public var running = 0, waiting = 0, done = 0, scheduled = 0
    public init() {}
    public var isQuiet: Bool { running + waiting + done + scheduled == 0 }
    /// Same rules as the notch: stale remote input requests don't count as waiting.
    mutating func add(_ session: AgentSession) {
        if session.state == .working { running += 1 }
        if session.state == .scheduled { scheduled += 1 }
        if session.state == .waiting && session.remote?.stale != true { waiting += 1 }
        if session.isDone { done += 1 }
    }
}

public struct HomeProject: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// False for an active chat in a folder outside any scanned repository.
    public var isRepository: Bool
    public var counts = HomeCounts()
    public var worktrees = 0
    public var readyToRemove = 0
    public var tokensToday: Double = 0
    public var apiValueToday: Double = 0
    public var lastActive: Date?
}

public struct HomeMachine: Identifiable, Sendable, Equatable {
    public enum Connection: Sendable, Equatable { case local, online, stale, offline, connecting, paused }
    public var id: String
    public var name: String
    public var connection: Connection
    public var counts = HomeCounts()
    public var lastSeen: Date?
}

public struct HomeHost: Sendable {
    public var id: UUID
    public var name: String
    public var connection: HomeMachine.Connection
    public var lastSeen: Date?
    public init(id: UUID, name: String, connection: HomeMachine.Connection, lastSeen: Date?) {
        self.id = id; self.name = name; self.connection = connection; self.lastSeen = lastSeen
    }
}

public struct HomeSummary: Sendable, Equatable {
    public var counts: HomeCounts
    public var projects: [HomeProject]
    public var machines: [HomeMachine]
    public var needsYou: [AgentSession]
    public var unread: [AgentSession]
    public var running: [AgentSession]
    public var sentence: String
    /// Chats waiting on a timer or schedule.
    public var scheduled: [AgentSession] = []

    public static let empty = HomeSummary(counts: HomeCounts(), projects: [], machines: [], needsYou: [], unread: [],
                                          running: [], sentence: "")

    public static func build(sessions: [AgentSession], worktrees: [Worktree], readyPaths: Set<String> = [],
                             hosts: [HomeHost] = [], activity: ProjectActivity? = nil, usage: [ProviderUsage] = [],
                             leftovers: Int = 0, now: Date = Date()) -> HomeSummary {
        var unique: [AgentSession] = [], seen: Set<String> = []
        for session in sessions where seen.insert(session.id).inserted { unique.append(session) }

        // Projects: every scanned repository, plus folders that hold an active local chat.
        let roots = worktrees.map(\.path)
        let repositoryOf = Dictionary(worktrees.map { ($0.path, $0.repositoryPath) }, uniquingKeysWith: { first, _ in first })
        var projects: [String: HomeProject] = [:]
        for tree in worktrees {
            var project = projects[tree.repositoryPath]
                ?? HomeProject(id: tree.repositoryPath, name: tree.repository, isRepository: true)
            project.worktrees += 1
            if readyPaths.contains(tree.path) { project.readyToRemove += 1 }
            project.lastActive = latest(project.lastActive, tree.lastActivity)
            projects[tree.repositoryPath] = project
        }
        var counts = HomeCounts()
        var local = HomeMachine(id: "local", name: "This Mac", connection: .local)
        var remote: [UUID: HomeCounts] = [:]
        for session in unique {
            counts.add(session)
            if let origin = session.remote {
                remote[origin.hostID, default: HomeCounts()].add(session)
                continue
            }
            local.counts.add(session)
            let owner = session.attachedPaths.lazy.compactMap { Paths.owner(of: $0, in: roots) }.first
                ?? Paths.owner(of: session.cwd, in: roots)
            let id: String
            if let owner, let repository = repositoryOf[owner] { id = repository }
            else {
                var probe = HomeCounts(); probe.add(session)
                guard !probe.isQuiet, session.cwd.hasPrefix("/") else { continue }
                id = session.cwd
            }
            var project = projects[id] ?? HomeProject(id: id, name: URL(fileURLWithPath: id).lastPathComponent, isRepository: false)
            project.counts.add(session)
            project.lastActive = latest(project.lastActive, session.updatedAt)
            projects[id] = project
        }
        if let activity {
            let owners = roots + projects.values.filter { !$0.isRepository }.map(\.id)
            for (owner, folder) in activity.totals(roots: owners) {
                let id = repositoryOf[owner] ?? owner
                guard var project = projects[id] else { continue }
                project.tokensToday += folder.tokens
                project.apiValueToday += folder.apiValue
                project.lastActive = latest(project.lastActive, folder.last)
                projects[id] = project
            }
        }
        let sortedProjects = projects.values.sorted { a, b in
            let left = (a.counts.waiting, a.counts.running, a.counts.done, a.tokensToday)
            let right = (b.counts.waiting, b.counts.running, b.counts.done, b.tokensToday)
            if left != right { return left > right }
            if a.lastActive != b.lastActive { return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let machines = [local] + hosts.map {
            HomeMachine(id: $0.id.uuidString, name: $0.name, connection: $0.connection, counts: remote[$0.id] ?? HomeCounts(),
                        lastSeen: $0.lastSeen)
        }
        let newest: (AgentSession, AgentSession) -> Bool = { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
        let needsYou = unique.filter { $0.state == .waiting && $0.remote?.stale != true }.sorted(by: newest)
        let unread = unique.filter(\.isDone).sorted(by: newest)
        let running = unique.filter { $0.state == .working }.sorted(by: newest)
        let scheduled = unique.filter { $0.state == .scheduled }.sorted(by: newest)
        // Remote chats have no local project, so their machine names stand in as places.
        let places = sortedProjects.filter { $0.counts.running > 0 }.map(\.name)
            + machines.filter { $0.connection != .local && $0.counts.running > 0 }.map(\.name)
        let sentence = HomeSentence.make(counts: counts, places: places, needsYou: needsYou,
                                         usage: usage, leftovers: leftovers, now: now)
        return HomeSummary(counts: counts, projects: sortedProjects, machines: machines, needsYou: needsYou,
                           unread: unread, running: running, sentence: sentence, scheduled: scheduled)
    }
    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) { case let (a?, b?): max(a, b); case let (a?, nil): a; case let (nil, b): b }
    }
}

/// A short, deterministic status line. No model call: everything comes from local state.
enum HomeSentence {
    static func make(counts: HomeCounts, places: [String], needsYou: [AgentSession],
                     usage: [ProviderUsage], leftovers: Int, now: Date) -> String {
        var parts: [String] = []
        if counts.running > 0 {
            parts.append("\(plural(counts.running, "agent")) \(counts.running == 1 ? "is" : "are") working\(location(places)).")
        } else if counts.scheduled > 0 {
            parts.append("Nothing is running; \(plural(counts.scheduled, "task")) \(counts.scheduled == 1 ? "is" : "are") scheduled.")
        }
        if let first = needsYou.first {
            let short = shorten(first.title)
            // A title that already ends a sentence ("…cut?") doesn't get a second full stop.
            let stop = short.last.map { "?!.…".contains($0) } == true ? "" : "."
            let title = "“\(short)”"
            parts.append(needsYou.count == 1 ? "1 chat needs you: \(title)\(stop)" : "\(needsYou.count) chats need you, starting with \(title)\(stop)")
        }
        if counts.done > 0 { parts.append("\(plural(counts.done, "result")) \(counts.done == 1 ? "is" : "are") ready to read.") }
        if let line = usageLine(usage, now: now) { parts.append(line) }
        if leftovers > 0 { parts.append("This Mac has \(plural(leftovers, "leftover process", "leftover processes")).") }
        if parts.isEmpty { return "All quiet. No agents are running and nothing needs you." }
        if counts.running == 0 && counts.scheduled == 0 { parts.insert("No agents are running.", at: 0) }
        return parts.joined(separator: " ")
    }
    /// Mentions the tightest current limit only when it is getting low.
    static func usageLine(_ providers: [ProviderUsage], now: Date) -> String? {
        let windows = providers.filter { !$0.isStale(now: now) && $0.issue == nil }.flatMap { provider in
            provider.windows.compactMap { window in window.remainingPercent.map { (provider, window, $0) } }
        }
        guard let (provider, window, remaining) = windows.min(by: { $0.2 < $1.2 }), remaining <= 25 else { return nil }
        var line = "\(provider.title) \(window.title.lowercased()) has \(Int(remaining.rounded()))% left"
        if let reset = window.resetsAt, reset > now {
            let style: Date.FormatStyle = reset.timeIntervalSince(now) < 20 * 3600
                ? .dateTime.hour().minute() : .dateTime.weekday(.wide)
            line += ", resetting \(reset.timeIntervalSince(now) < 20 * 3600 ? "at " : "")\(reset.formatted(style))"
        }
        return line + "."
    }
    static func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (pluralForm ?? singular + "s"))"
    }
    static func location(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: " in \(names[0])"
        case 2: " in \(names[0]) and \(names[1])"
        default: " in \(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
    static func shorten(_ title: String, limit: Int = 48) -> String {
        let clean = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return clean.count <= limit ? clean : String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
