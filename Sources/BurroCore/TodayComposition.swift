// The Today page's words and numbers, worked out once per render from values Burro already holds
// (the day's agent scan, the tracked day, Home's board, the Brief, Shipped). Pure, so it is tested.
// - `TextRun`: a sentence in pieces with a tone (needs you is amber, stuck is grey), for the page
//   header and the lanes panel. Tones, not colours, so this stays out of SwiftUI.
// - `TodayAgentTime`: the agents' wall-clock time that day, all chats' stretches merged (two chats
//   working at once count once); nil when no chat's stretches are known, "about" when the scan was
//   partial or some chats' stretches are unknown.
// - `TodayHeadline`: the header's one sentence of facts ("First message 08:12, last 17:40. 9 chats
//   worked 6h 10m; 2h 40m of it while you were away.").
// - `TodayStats`: the four KPI cells (Focused or With agents, Agents worked, Waiting on you or
//   Questions asked, Shipped).
// - `TodayLanes`: one lane per chat for the lanes panel: its stretches (nil = unknown, never idle),
//   amber marks where it asked you (waiting now, or a Brief needs-you item), a grey mark where the
//   Brief found it stuck, and two outcome lines; plus the panel's summary sentence.
// - `TodayProjects`: chats and merged active time per project for the bottom panel.
// Clock times are read from calendar components, never locale formatting.
import Foundation

/// A piece of a sentence and how it is shown.
public struct TextRun: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case plain, strong, needsYou, stuck }
    public var text: String
    public var tone: Tone
    public init(_ text: String, _ tone: Tone = .plain) { self.text = text; self.tone = tone }
}

extension Array where Element == TextRun {
    public var plainText: String { map(\.text).joined() }
}

public enum TodayClock {
    /// "08:12" in `calendar`'s time zone.
    public static func hm(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    /// "08:12–17:40".
    public static func range(_ start: Date, _ end: Date, calendar: Calendar) -> String { hm(start, calendar: calendar) + "–" + hm(end, calendar: calendar) }
    /// "now", "6 min", "1h 05m".
    public static func elapsed(_ since: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}

// MARK: Agent time

public struct TodayAgentTime: Sendable, Equatable {
    /// Wall-clock seconds any agent on this Mac was active; nil when no chat's stretches are known.
    public var total: TimeInterval?
    /// The scan was partial or some chats' stretches are unknown.
    public var approximate: Bool
    /// Chats with any activity that day.
    public var chats: Int

    /// Nil while the day hasn't been scanned.
    public static func make(_ activity: DailyActivity?) -> TodayAgentTime? {
        guard let activity else { return nil }
        let known = activity.chats.compactMap(\.active)
        let total = known.isEmpty ? nil : ActivityCoverage.mergedDuration(known.flatMap { $0 })
        return TodayAgentTime(total: total, approximate: total != nil && (activity.partial || known.count < activity.chats.count),
                              chats: activity.chats.count)
    }

    /// "6h 10m", "about 6h 10m", or nil when unknown.
    public var text: String? { total.map { AgentAwayTime.phrase($0, partial: approximate) } }
}

// MARK: Header sentence

public enum TodayHeadline {
    /// One sentence of facts for the header; nothing invented, empty facts left out.
    public static func sentence(activity: DailyActivity?, agentTime: TodayAgentTime?, away: AgentAwayTime.Summary?, isToday: Bool,
                                todos: (done: Int, total: Int)? = nil, calendar: Calendar) -> [TextRun] {
        guard let activity else { return [TextRun("Reading your agent logs…")] }
        var text: String
        if let first = activity.firstTurn, let last = activity.lastTurn {
            let a = TodayClock.hm(first, calendar: calendar), b = TodayClock.hm(last, calendar: calendar)
            text = a == b ? "One message at \(a)." : "First message \(a), last \(b)."
        } else {
            text = isToday ? "No messages to an agent yet today." : "No messages to an agent that day."
        }
        let chats = agentTime?.chats ?? activity.chats.count
        if chats > 0 {
            let subject = "\(chats) chat\(chats == 1 ? "" : "s")"
            if let worked = agentTime?.text {
                text += " \(subject) worked \(worked)"
                if let away, away.total >= 60 { text += "; \(away.totalText) of it while you were away" }
                text += "."
            } else {
                text += " \(subject); Burro can't tell for how long."
            }
        }
        if let todos, todos.total > 0 { text += " \(todos.done) of \(todos.total) to-dos done." }
        return [TextRun(text)]
    }
}

// MARK: KPI cells

public struct TodayStat: Sendable, Equatable, Identifiable {
    /// Today's four, plus Home's `working`, `toRead` and `value` (HomeComposition.swift).
    public enum Key: String, Sendable { case focus, agents, waiting, shipped, working, toRead, value }
    public var key: Key
    public var label: String
    /// The amber dot before the label (Waiting on you, today).
    public var dot = false
    public var value: String
    /// A small word before the number ("about").
    public var valuePrefix: String? = nil
    public var sub: [TextRun]
    public var help: String
    public var id: String { key.rawValue }
    /// No number to show.
    public var unknown: Bool { value == "—" }
}

public enum TodayStats {
    public enum Shipped: Sendable, Equatable {
        case loading, noProject, failed
        case loaded(merged: Int, deploys: Int, dayBefore: Int?)
    }

    public static func cells(activity: DailyActivity?, tracked: ActivityDay?, tracking: Bool, isToday: Bool, agentTime: TodayAgentTime?,
                             waiting: Int, oldestWaiting: Date?, shipped: Shipped, calendar: Calendar) -> [TodayStat] {
        [focus(activity: activity, tracked: tracked, tracking: tracking, isToday: isToday, calendar: calendar),
         agents(activity: activity, agentTime: agentTime, isToday: isToday),
         isToday ? waitingCell(activity: activity, waiting: waiting, oldest: oldestWaiting, calendar: calendar) : asked(activity: activity),
         shippedCell(shipped, isToday: isToday)]
    }

    static func focus(activity: DailyActivity?, tracked: ActivityDay?, tracking: Bool, isToday: Bool, calendar: Calendar) -> TodayStat {
        if tracking {
            let day = tracked.flatMap { $0.total > 0 ? $0 : nil }
            return TodayStat(key: .focus, label: "Focused", value: day.map { TodaySummary.duration($0.focused) } ?? "—",
                             sub: [TextRun(day.map { "of \(TodaySummary.duration($0.total)) tracked" }
                                           ?? (tracked == nil ? "reading…" : "nothing tracked\(isToday ? " yet" : "")"))],
                             help: "Focused: tracked time outside Break on this Mac. Tracked: everything Burro recorded; idle time and the lock screen don't count.")
        }
        let range = activity?.firstTurn.flatMap { first in activity?.lastTurn.map { TodayClock.range(first, $0, calendar: calendar) } }
        return TodayStat(key: .focus, label: "With agents", value: activity?.span.map(TodaySummary.duration) ?? "—",
                         sub: [TextRun(range ?? (activity == nil ? "reading your logs…" : "no messages\(isToday ? " yet" : "")"))],
                         help: "From your first to your last message to an agent.")
    }

    static func agents(activity: DailyActivity?, agentTime: TodayAgentTime?, isToday: Bool) -> TodayStat {
        let help = "Wall-clock time any agent on this Mac was active (Codex and Claude); chats working at once count once."
        guard let activity else { return TodayStat(key: .agents, label: "Agents worked", value: "—", sub: [TextRun("reading your logs…")], help: help) }
        var parts: [String] = []
        let chats = activity.chats.count
        parts.append(chats == 0 ? "no chats\(isToday ? " yet" : "")" : "\(chats) chat\(chats == 1 ? "" : "s")")
        if activity.turns > 0 { parts.append("\(activity.turns) sent") }
        if activity.replies > 0 { parts.append("\(activity.replies) repl\(activity.replies == 1 ? "y" : "ies")") }
        if chats > 0 && agentTime?.total == nil { parts.insert("time unknown", at: 0) }
        let total = agentTime?.total
        return TodayStat(key: .agents, label: "Agents worked", value: total.map(TodaySummary.duration) ?? (chats == 0 ? "0m" : "—"),
                         valuePrefix: agentTime?.approximate == true ? "about" : nil, sub: [TextRun(parts.joined(separator: " · "))],
                         help: help + (agentTime?.approximate == true ? " Some chats couldn't be read, so this is approximate." : ""))
    }

    static func waitingCell(activity: DailyActivity?, waiting: Int, oldest: Date?, calendar: Calendar) -> TodayStat {
        let answered = TodaySummary.decisions(asked: activity?.questions ?? 0, waitingNow: waiting).answered
        var parts: [String] = []
        // One fact per cell, so the line never cuts off: how long the oldest has waited, else what was answered.
        if waiting > 0, let oldest { parts.append("oldest since \(TodayClock.hm(oldest, calendar: calendar))") }
        else if answered > 0 { parts.append("\(answered) question\(answered == 1 ? "" : "s") answered today") }
        if parts.isEmpty { parts.append("nothing waiting") }
        return TodayStat(key: .waiting, label: "Waiting on you", dot: true, value: "\(waiting)", sub: [TextRun(parts.joined(separator: " · "))],
                         help: "Home's Needs you: chats waiting on an input request, and chats triage found ending a turn on a question. Answered: explicit questions agents asked today that no longer wait.")
    }

    static func asked(activity: DailyActivity?) -> TodayStat {
        TodayStat(key: .waiting, label: "Questions asked", value: activity.map { "\($0.questions)" } ?? "—",
                  sub: [TextRun(activity == nil ? "reading your logs…" : "by agents that day")],
                  help: "Explicit questions agents asked (Codex request_user_input, Claude AskUserQuestion). Approval prompts aren't logged by the tools.")
    }

    static func shippedCell(_ shipped: Shipped, isToday: Bool) -> TodayStat {
        let help = "Pull requests merged and production deploys in the main project's GitHub repository."
        switch shipped {
        case .loading: return TodayStat(key: .shipped, label: "Shipped", value: "—", sub: [TextRun("reading GitHub…")], help: help)
        case .noProject: return TodayStat(key: .shipped, label: "Shipped", value: "—", sub: [TextRun("no main project")], help: help)
        case .failed: return TodayStat(key: .shipped, label: "Shipped", value: "—", sub: [TextRun("couldn't read GitHub")], help: help)
        case .loaded(let merged, let deploys, let dayBefore):
            let sub = deploys > 0 ? "merged · \(deploys) production deploy\(deploys == 1 ? "" : "s")"
                : dayBefore.map { "merged · day before: \($0)" } ?? "pull requests merged"
            return TodayStat(key: .shipped, label: "Shipped", value: "\(merged)", sub: [TextRun(sub)], help: help)
        }
    }
}

// MARK: Lanes

/// What the lanes need to know about one of the day's chats (the page's row for it).
public struct TodayLaneInput: Sendable, Equatable {
    public enum State: Int, Sendable, Comparable {
        case needsYou, working, toRead, idle
        public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var title: String
    public var provider: AgentProvider
    public var state: State
    /// "machine / project / worktree".
    public var place: String
    public var lastAt: Date
    /// When its current turn began, as far as Burro saw it.
    public var turnStart: Date?
    public var remote: Bool
    public var canOpen: Bool
    public init(id: String, title: String, provider: AgentProvider, state: State, place: String, lastAt: Date, turnStart: Date? = nil,
                remote: Bool = false, canOpen: Bool = true) {
        self.id = id; self.title = title; self.provider = provider; self.state = state; self.place = place; self.lastAt = lastAt
        self.turnStart = turnStart; self.remote = remote; self.canOpen = canOpen
    }
}

public struct AgentLane: Sendable, Equatable, Identifiable {
    /// `asked`: waiting on you right now (amber). `askedEarlier`: a question the Brief saw that no
    /// longer waits (a grey ring). `stuck`: the Brief found it stuck (a grey diamond).
    public enum MarkKind: Sendable, Equatable { case asked, askedEarlier, stuck }
    public struct Mark: Sendable, Equatable {
        public var at: Date
        public var kind: MarkKind
        public var text: String
    }
    public var id: String
    public var provider: AgentProvider
    public var title: String
    public var subtitle: String
    public var state: TodayLaneInput.State
    /// When the agent was active, sorted and apart; nil when unknown (another machine, an older helper).
    public var intervals: [DateInterval]?
    public var marks: [Mark]
    /// "Waiting · 6 min", "Working · turn 18 min", "Ready to read", "Done · 17:40", "Stuck · quiet 52 min".
    public var outcome: String
    /// "active 2h 05m · 14 sent", or the Brief's Finished headline.
    public var detail: String?
    public var stuck: Bool
    public var remote: Bool
    public var canOpen: Bool
    public var lastAt: Date
    public var activeSeconds: TimeInterval? { intervals.map { ActivityCoverage.mergedDuration($0) } }
}

public enum TodayLanes {
    /// Lanes shown before "Show all N".
    public static let cap = 8

    /// One lane per chat: needs you, working and ready to read first (newest first), then the rest by
    /// active time (longest first, unknown last, then newest).
    /// `needsSince` is when each chat waiting now started waiting (Home's board); `brief` the Brief's items.
    public static func build(_ inputs: [TodayLaneInput], activity: DailyActivity?, needsSince: [String: Date], brief: [BriefItem],
                             window: DateInterval, isToday: Bool, now: Date, calendar: Calendar) -> [AgentLane] {
        let chats = Dictionary((activity?.chats ?? []).map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var briefByChat: [String: [BriefItem]] = [:]
        for item in brief { if let chat = item.chatID?.lowercased() { briefByChat[chat, default: []].append(item) } }
        let since = Dictionary(needsSince.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        return inputs.map { input in
            let key = input.id.lowercased(), chat = chats[key], items = briefByChat[key] ?? []
            let stuckItem = items.filter { $0.kind == .stuck && $0.isOpen }.max { $0.createdAt < $1.createdAt }
            let finished = items.filter { $0.kind == .done && $0.isOpen }.max { $0.createdAt < $1.createdAt }
            var marks: [AgentLane.Mark] = []
            func add(_ at: Date, _ kind: AgentLane.MarkKind, _ text: String) {
                guard window.contains(at), !marks.contains(where: { $0.kind == kind && abs($0.at.timeIntervalSince(at)) < 60 }) else { return }
                marks.append(AgentLane.Mark(at: at, kind: kind, text: text))
            }
            // Amber only for what waits on you now; earlier questions are grey rings.
            var waitingSince: Date?
            if isToday, input.state == .needsYou {
                let at = since[key] ?? input.lastAt
                waitingSince = at
                add(at, .asked, "Waiting on you since \(TodayClock.hm(at, calendar: calendar))")
            }
            for item in items where item.kind.needsYou {
                // Triage's reading of the current wait is the amber dot already.
                if let waitingSince, item.createdAt >= waitingSince.addingTimeInterval(-60) { continue }
                add(item.createdAt, .askedEarlier, "Asked you earlier: \(item.question ?? item.headline)")
            }
            for item in items where item.kind == .stuck { add(item.createdAt, .stuck, item.headline) }
            marks.sort { $0.at < $1.at }

            let stuck = isToday && input.state == .working && stuckItem != nil
            let outcome: String
            switch input.state {
            case .needsYou where isToday: outcome = "Waiting · \(TodayClock.elapsed(since[key] ?? input.lastAt, now: now))"
            case .working where stuck: outcome = "Stuck · quiet \(TodayClock.elapsed(stuckItem?.chatUpdatedAt ?? input.lastAt, now: now))"
            case .working: outcome = input.turnStart.map { "Working · turn \(TodayClock.elapsed($0, now: now))" } ?? "Working"
            case .toRead where isToday: outcome = "Ready to read"
            default: outcome = "Done · \(TodayClock.hm(input.lastAt, calendar: calendar))"
            }
            let sent = chat.map(\.turns) ?? 0
            let active = chat?.active.map { ActivityCoverage.mergedDuration($0) }
            var detail: String?
            if input.state == .toRead, isToday, let headline = finished?.headline { detail = headline }
            else if let active, active >= 60 { detail = "active \(TodaySummary.duration(active))" + (sent > 0 ? " · \(sent) sent" : "") }
            else if let headline = finished?.headline { detail = headline }
            else if sent > 0 { detail = "\(sent) sent" }
            return AgentLane(id: input.id, provider: input.provider, title: input.title, subtitle: input.place, state: input.state,
                             intervals: chat?.active, marks: marks, outcome: outcome, detail: detail, stuck: stuck, remote: input.remote,
                             canOpen: input.canOpen, lastAt: input.lastAt)
        }
        .sorted { a, b in
            if a.state != b.state { return a.state < b.state }
            // The rest (done, idle, a past day): the day's substantial chats first, so the cap shows them.
            if a.state == .idle || !isToday {
                let (ta, tb) = (a.activeSeconds ?? -1, b.activeSeconds ?? -1)
                if ta != tb { return ta > tb }
            }
            return a.lastAt != b.lastAt ? a.lastAt > b.lastAt : a.id < b.id
        }
    }

    /// The lanes panel's one sentence, problem counts toned: "2 chats wait on you and 1 looks stuck. 3 still working, the rest done."
    public static func summary(_ lanes: [AgentLane], isToday: Bool) -> [TextRun] {
        guard !lanes.isEmpty else { return [TextRun(isToday ? "No chats yet today." : "No chats that day.")] }
        guard isToday else {
            var runs = [TextRun("\(lanes.count) chat\(lanes.count == 1 ? "" : "s") that day.")]
            if let longest = lanes.compactMap({ lane in lane.activeSeconds.map { (lane, $0) } }).max(by: { $0.1 < $1.1 }), longest.1 >= 60 {
                runs.append(TextRun(" The longest, \(longest.0.title), was active \(TodaySummary.duration(longest.1))."))
            }
            return runs
        }
        let needs = lanes.filter { $0.state == .needsYou }.count
        let stuck = lanes.filter(\.stuck).count
        let working = lanes.filter { $0.state == .working && !$0.stuck }.count
        let toRead = lanes.filter { $0.state == .toRead }.count
        let rest = lanes.count - needs - stuck - working - toRead
        var runs: [TextRun] = []
        var named = false
        func subject(_ count: Int) -> String {
            defer { named = true }
            return named ? "\(count)" : "\(count) chat\(count == 1 ? "" : "s")"
        }
        if needs > 0 { runs.append(TextRun("\(subject(needs)) wait\(needs == 1 ? "s" : "") on you", .needsYou)) }
        if stuck > 0 {
            if !runs.isEmpty { runs.append(TextRun(" and ")) }
            runs.append(TextRun("\(subject(stuck)) look\(stuck == 1 ? "s" : "") stuck", .stuck))
        }
        if runs.isEmpty { runs.append(TextRun("Nothing waits on you")) }
        runs.append(TextRun("."))
        var others: [String] = []
        if working > 0 { others.append("\(working) still working") }
        if toRead > 0 { others.append("\(toRead) ready to read") }
        if rest > 0 { others.append(others.isEmpty && needs + stuck == 0 ? "all \(rest) done" : "the rest done") }
        if !others.isEmpty {
            let text = others.count == 1 ? others[0] : others.dropLast().joined(separator: ", ") + " and " + others[others.count - 1]
            runs.append(TextRun(" " + text.prefix(1).uppercased() + text.dropFirst() + "."))
        }
        return runs
    }

    /// The earliest moment anything on the lanes starts, for the axis.
    public static func earliest(_ lanes: [AgentLane], also: [Date?] = []) -> Date? {
        (lanes.compactMap { $0.intervals?.first?.start } + lanes.compactMap { $0.marks.first?.at } + also.compactMap { $0 }).min()
    }
}

// MARK: Projects

public struct TodayProjectRow: Sendable, Equatable, Identifiable {
    public var name: String
    public var chats: Int
    /// Merged active time of its chats; nil when none of them is known.
    public var active: TimeInterval?
    /// Some of its chats' stretches are unknown.
    public var approximate: Bool
    public var id: String { name }
}

public enum TodayProjects {
    /// Chats and merged active time per project, most active first.
    public static func rows(_ chats: [(project: String, active: [DateInterval]?)]) -> [TodayProjectRow] {
        Dictionary(grouping: chats, by: \.project).map { name, chats in
            let known = chats.compactMap(\.active)
            return TodayProjectRow(name: name, chats: chats.count,
                                   active: known.isEmpty ? nil : ActivityCoverage.mergedDuration(known.flatMap { $0 }),
                                   approximate: !known.isEmpty && known.count < chats.count)
        }
        .sorted { a, b in
            if (a.active ?? -1) != (b.active ?? -1) { return (a.active ?? -1) > (b.active ?? -1) }
            if a.chats != b.chats { return a.chats > b.chats }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
