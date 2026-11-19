// Home's words and numbers in the dashboard layout, worked out once per render from values Burro
// already holds (Home's board, the turn clock, today's agent scan, the tracked day, project
// activity, usage). Pure, so it is tested; Today's rules are reused, never copied.
// - `HomeBoard.sentenceRuns`: the greeting's sentence (`HomeBoard.sentence`) with its needs-you
//   clause toned amber.
// - `HomeStats`: the four KPI cells: Working (longest turn, else where they run), Waiting on you
//   (Today's own cell), Ready to read (stuck, else the newest), and Focused today (tracking on) or
//   API value today (tracking off; "—" while unknown, never "Spent").
// - `HomeLanes`: one lane input per live chat on Home's board (needs you, working, ready to read;
//   sub-agents never), for `TodayLanes.build`; cap 6 then "Show all N in Chats".
// - `HomeQueueTabs`: the queue's three tabs and which one opens first.
// - `HomeBottomRow`: Machines, Limits, To-dos; or Machines, To-dos, Notes when there are no limits to show.
// - `HomeLimits`: each shown provider's windows, % left and reset.
// Clock times are read from calendar components, never locale formatting.
import Foundation

extension HomeBoard {
    /// `sentence(...)` in toned pieces: "2 chats need you" amber, the rest plain.
    public static func sentenceRuns(needsYou: Int, working: Int, toRead: Int, shipped: Int? = nil, usageLine: String? = nil) -> [TextRun] {
        let text = sentence(needsYou: needsYou, working: working, toRead: toRead, shipped: shipped, usageLine: usageLine)
        guard needsYou > 0 else { return [TextRun(text)] }
        let clause = "\(needsYou) chat\(needsYou == 1 ? "" : "s") need\(needsYou == 1 ? "s" : "") you"
        guard text.hasPrefix(clause) else { return [TextRun(text)] }
        return [TextRun(clause, .needsYou), TextRun(String(text.dropFirst(clause.count)))]
    }
}

// MARK: KPI cells

public enum HomeStats {
    /// The fourth cell's inputs.
    public enum Day: Sendable, Equatable {
        /// Activity tracking on: today's tracked day (nil while unread) and the agents' time while you were away.
        case tracked(ActivityDay?, away: TimeInterval?, awayPartial: Bool)
        /// Tracking off: API value and tokens today on this Mac (nil while project activity hasn't been read).
        case value(dollars: Double?, tokens: Double?)
    }

    /// Working, Waiting on you, Ready to read, and Focused today or API value today.
    /// `longestTurn`: the longest current turn Burro saw begin (TurnClock), nil when none is known.
    /// `machines`: the machine of each working chat. `oldestWaiting`: Home's oldest Needs-you `since`.
    public static func cells(working: Int, longestTurn: TimeInterval?, machines: [String], waiting: Int, oldestWaiting: Date?,
                             activity: DailyActivity?, toRead: Int, stuck: Int, newestToRead: Date?, day: Day,
                             calendar: Calendar) -> [TodayStat] {
        [workingCell(working, longestTurn: longestTurn, machines: machines),
         TodayStats.waitingCell(activity: activity, waiting: waiting, oldest: oldestWaiting, calendar: calendar),
         toReadCell(toRead, stuck: stuck, newest: newestToRead, calendar: calendar),
         dayCell(day)]
    }

    static func workingCell(_ working: Int, longestTurn: TimeInterval?, machines: [String]) -> TodayStat {
        let sub: String
        if working == 0 {
            sub = "nothing running"
        } else if let longestTurn, longestTurn >= 60 {
            // Turns are timed from when Burro saw them begin, so seconds after a launch say nothing.
            sub = "longest turn \(TurnClock.text(longestTurn))"
        } else {
            let places = Array(Set(machines))
            sub = places.count == 1 ? "on \(places[0])" : "on \(places.count) machines"
        }
        return TodayStat(key: .working, label: "Working", value: "\(working)", sub: [TextRun(sub)],
                         help: "Chats working now (sub-agents count with their parent). The longest turn is timed from when Burro saw it begin.")
    }

    static func toReadCell(_ toRead: Int, stuck: Int, newest: Date?, calendar: Calendar) -> TodayStat {
        let sub: TextRun
        if stuck > 0 { sub = TextRun("\(stuck) look\(stuck == 1 ? "s" : "") stuck", .stuck) }
        else if toRead > 0, let newest { sub = TextRun("newest \(TodayClock.hm(newest, calendar: calendar))") }
        else { sub = TextRun("nothing to read") }
        return TodayStat(key: .toRead, label: "Ready to read", value: "\(toRead)", sub: [sub],
                         help: "Finished results you haven't opened in Burro. Stuck: working chats the Brief found quiet for a long time.")
    }

    static func dayCell(_ day: Day) -> TodayStat {
        switch day {
        case .tracked(let tracked, let away, let partial):
            let known = tracked.flatMap { $0.total > 0 ? $0 : nil }
            var sub = known.map { "of \(TodaySummary.duration($0.total)) tracked" } ?? (tracked == nil ? "reading…" : "nothing tracked yet")
            // One fact per line so it never cuts off: the away figure when there is one (the tracked total is in the help).
            if let away, away >= 60 { sub = "agents \(AgentAwayTime.phrase(away, partial: partial)) while away" }
            return TodayStat(key: .focus, label: "Focused today", value: known.map { TodaySummary.duration($0.focused) } ?? "—",
                             sub: [TextRun(sub)],
                             help: (known.map { "Tracked today: \(TodaySummary.duration($0.total)). " } ?? "") + "Focused: tracked time outside Break on this Mac. Agents' time while you were away: wall-clock time any agent was active while Burro was recording and you weren't at the Mac.")
        case .value(let dollars, let tokens):
            let value = dollars.map(money) ?? "—"
            let sub = tokens.map { $0 > 0 ? "\(TokenCount.compact($0)) tokens on this Mac" : "no tokens yet today" } ?? "reading…"
            return TodayStat(key: .value, label: "API value today", value: value, sub: [TextRun(sub)],
                             help: "What today's tokens on this Mac would cost at API prices. Subscriptions aren't billed this way.")
        }
    }

    /// "$12", "<$1", "$0"; whole dollars, the same in every locale.
    public static func money(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0" }
        if value < 1 { return "<$1" }
        let whole = Int(value.rounded())
        var digits = String(whole), grouped = ""
        while digits.count > 3 { grouped = "," + digits.suffix(3) + grouped; digits = String(digits.dropLast(3)) }
        return "$" + digits + grouped
    }
}

// MARK: Lanes

public enum HomeLanes {
    /// Lanes shown before "Show all N in Chats".
    public static let cap = 6

    /// One input per live chat on the board: needs you (only those with a chat in the feed), working,
    /// ready to read; each chat once. A needs-you chat is `.needsYou` (Home's own "needs you now", so
    /// its amber mark sits at `needsSince`), whether it waits on an input request or triage found it
    /// ending a turn on a question. `place` names the machine and folder, `turnStart` comes from the
    /// turn clock.
    public static func inputs(_ board: HomeBoard, place: (AgentSession) -> String, turnStart: (String) -> Date?) -> [TodayLaneInput] {
        var seen: Set<String> = [], result: [TodayLaneInput] = []
        func add(_ session: AgentSession, _ state: TodayLaneInput.State) {
            guard session.isSubagent != true, seen.insert(session.id.lowercased()).inserted else { return }
            result.append(TodayLaneInput(id: session.id, title: session.title, provider: session.provider, state: state, place: place(session),
                                         lastAt: session.updatedAt, turnStart: state == .working ? turnStart(session.id) : nil,
                                         remote: session.remote != nil, canOpen: true))
        }
        for entry in board.needsYou { if let session = entry.session { add(session, .needsYou) } }
        for entry in board.working { add(entry.session, .working) }
        for entry in board.toRead { add(entry.session, .toRead) }
        return result
    }

    /// When each needs-you chat started waiting, by chat id (the lanes' amber marks).
    public static func needsSince(_ board: HomeBoard) -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in board.needsYou { if let session = entry.session, result[session.id] == nil { result[session.id] = entry.since } }
        return result
    }

    /// Everything the lanes draw (stretches and marks), for `DayRibbonLayout.laneWindow`.
    public static func pieces(_ lanes: [AgentLane]) -> [DateInterval] {
        lanes.flatMap { $0.intervals ?? [] } + lanes.flatMap { $0.marks.map { DateInterval(start: $0.at, duration: 0) } }
    }
}

// MARK: Queue tabs

public struct HomeQueueTab: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case waiting, working, toRead }
    public var kind: Kind
    public var title: String
    public var short: String
    public var count: Int
    public var id: String { kind.rawValue }
}

public enum HomeQueueTabs {
    public static func tabs(needsYou: Int, working: Int, toRead: Int) -> [HomeQueueTab] {
        [HomeQueueTab(kind: .waiting, title: "Waiting on you", short: "Waiting", count: needsYou),
         HomeQueueTab(kind: .working, title: "Working", short: "Working", count: working),
         HomeQueueTab(kind: .toRead, title: "Ready to read", short: "To read", count: toRead)]
    }

    /// The tab shown until you pick one: what needs you, else what is working, else what is ready.
    public static func initial(needsYou: Int, working: Int, toRead: Int) -> HomeQueueTab.Kind {
        needsYou > 0 ? .waiting : working > 0 ? .working : toRead > 0 ? .toRead : .waiting
    }
}

// MARK: Bottom row

public enum HomeBottomRow {
    public enum Slot: String, Sendable { case machines, limits, todos, notes }

    /// Machines, Limits, To-dos; with no limits to show (usage off, or every provider hidden) the
    /// to-dos move up and Notes takes the third panel (and leaves the section below).
    public static func slots(limitsShown: Bool) -> [Slot] {
        limitsShown ? [.machines, .limits, .todos] : [.machines, .todos, .notes]
    }
}

// MARK: Limits

public struct HomeLimitRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: String
    /// "5-hour", "Weekly"; nil for a provider-level note.
    public var window: String?
    /// Percent left, 0…100; nil with a note instead.
    public var remaining: Double?
    /// "Resets in 3h 12m", or the account's problem ("Sign-in needs attention").
    public var detail: String
    public var stale: Bool
}

public enum HomeLimits {
    /// Windows per provider shown on Home (the Usage page has the rest).
    public static let windowsPerProvider = 3

    /// Each shown provider's windows with a known percentage, in its own order; a provider with an
    /// account problem gets one row saying so. Hidden providers (not in `shown`) never appear.
    public static func rows(_ providers: [ProviderUsage], shown: Set<UsageProvider>, now: Date) -> [HomeLimitRow] {
        providers.filter { shown.contains($0.id) }.flatMap { provider -> [HomeLimitRow] in
            let stale = provider.isStale(now: now)
            if let issue = provider.issue {
                return [HomeLimitRow(id: provider.id.rawValue, provider: provider.title, window: nil, remaining: nil, detail: issue.accountLabel, stale: true)]
            }
            return provider.windows.filter { $0.remainingPercent != nil }.prefix(windowsPerProvider).map { window in
                HomeLimitRow(id: "\(provider.id.rawValue).\(window.id)", provider: provider.title, window: window.title,
                             remaining: min(100, max(0, window.remainingPercent ?? 0)), detail: window.resetLabel(now: now), stale: stale)
            }
        }
    }
}
