// Decisions behind the Orchestrator page's Brief tab, kept pure so they can be tested: the line under
// its title ("2 need you, 3 finished, 1 stuck · last triage 3 min ago"), the Budget card's numbers
// (triage runs today of the daily cap, today's cost from the runs log, Claude's session and weekly
// windows with the floors triage pauses below, and when each resets), which chats "Run triage now"
// queues and what it says back, the first memory notes the side card shows, and how many columns
// the page uses at a given width (two from 760 points, one below). Nothing here reads files or starts anything.
import Foundation

public enum OrchestratorPageSummary {
    /// The counts that aren't zero, then when triage last ran (or that it is reading chats now).
    public static func line(needs: Int, finished: Int, stuck: Int, lastTriage: Date?, triaging: Int, now: Date) -> String {
        var counts: [String] = []
        if needs > 0 { counts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if finished > 0 { counts.append("\(finished) finished") }
        if stuck > 0 { counts.append("\(stuck) stuck") }
        var parts = [counts.isEmpty ? "Nothing waiting on you" : counts.joined(separator: ", ")]
        if triaging > 0 {
            parts.append("reading \(triaging) chat\(triaging == 1 ? "" : "s")…")
        } else if let lastTriage {
            parts.append("last triage " + ago(lastTriage, now: now))
        }
        return parts.joined(separator: " · ")
    }

    /// "just now", "3 min ago", "2 h ago", "3 d ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

/// The Budget card: what triage has used today and how close Claude's windows are to pausing it.
public struct OrchestratorBudget: Sendable, Equatable {
    public struct Meter: Sendable, Equatable {
        public var title: String
        /// Percent left, 0–100.
        public var remaining: Double
        /// Triage pauses below this percent left.
        public var floor: Double
        public var resetsAt: Date?
        public init(title: String, remaining: Double, floor: Double, resetsAt: Date?) {
            self.title = title; self.remaining = max(0, min(100, remaining)); self.floor = floor; self.resetsAt = resetsAt
        }
        public var paused: Bool { remaining < floor }
        /// "62% left".
        public var left: String { "\(Int(remaining.rounded()))% left" }

        /// "Resets 23:00" today, "Resets tomorrow 09:00", "Resets Thursday" within the week, else
        /// "Resets 21 Nov"; nil when unknown or already past.
        public func resetText(now: Date, calendar: Calendar) -> String? {
            guard let resetsAt, resetsAt > now else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: resetsAt)
            let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if calendar.isDate(resetsAt, inSameDayAs: now) { return "Resets \(clock)" }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: resetsAt)).day ?? 0
            if days == 1 { return "Resets tomorrow \(clock)" }
            if days < 7 {
                let weekday = calendar.component(.weekday, from: resetsAt)
                return "Resets " + calendar.weekdaySymbols[(weekday - 1 + 7) % 7]
            }
            let month = calendar.shortMonthSymbols[calendar.component(.month, from: resetsAt) - 1]
            return "Resets \(calendar.component(.day, from: resetsAt)) \(month)"
        }
    }

    public var runsToday: Int
    public var cap: Int
    public var costToday: Double
    public var session: Meter?
    public var weekly: Meter?
    /// Automatic triage is switched on.
    public var enabled: Bool
    /// Why triage can't run now (off, a cap, a window below its floor), nil when it can.
    public var pausedReason: String?
    public var sessionFloor: Double
    public var weeklyFloor: Double

    public init(runsToday: Int, cap: Int, costToday: Double, session: Meter?, weekly: Meter?, enabled: Bool, pausedReason: String?,
                sessionFloor: Double = TriageBudget().sessionFloor, weeklyFloor: Double = TriageBudget().weeklyFloor) {
        self.runsToday = runsToday; self.cap = cap; self.costToday = costToday; self.session = session; self.weekly = weekly
        self.enabled = enabled; self.pausedReason = pausedReason; self.sessionFloor = sessionFloor; self.weeklyFloor = weeklyFloor
    }

    /// From what the stores hold: the Brief's run count, cap and gate, today's runs (both the
    /// Orchestrator's own and triage's, from the runs log) and Claude's windows (nil when unknown).
    public init(runsToday: Int, cap: Int, runs: [OrchestratorRun], claude windows: [UsageWindow]?, enabled: Bool, gate: TriageGate,
                budget: TriageBudget = TriageBudget()) {
        let usage = windows.map { TriageUsage(claude: $0) }
        let session = windows?.first { $0.id == "session" || $0.id == "five_hour" }
        let weekly = windows?.first { $0.id == "weekly" || $0.id == "seven_day" }
        self.init(runsToday: runsToday, cap: cap, costToday: runs.reduce(0) { $0 + $1.costUSD },
                  session: usage?.session.map { Meter(title: "Claude session limit", remaining: $0, floor: budget.sessionFloor, resetsAt: session?.resetsAt) },
                  weekly: usage?.weekly.map { Meter(title: "Weekly limit", remaining: $0, floor: budget.weeklyFloor, resetsAt: weekly?.resetsAt) },
                  enabled: enabled, pausedReason: gate == .off ? nil : gate.reason,
                  sessionFloor: budget.sessionFloor, weeklyFloor: budget.weeklyFloor)
    }

    /// "$0.42".
    public var cost: String { String(format: "$%.2f", costToday) }
    /// The rule, in the card's words.
    public var floorsLine: String {
        "Triage pauses below \(Int(sessionFloor))% session or \(Int(weeklyFloor))% weekly left."
    }
}

/// "Run triage now": which chats it triages and what it says back. Same gate as automatic runs.
/// It looks at the chats waiting on you or unread, newest first (at most `lookLimit` of them), and
/// picks up to one batch whose latest messages haven't been triaged yet, by the same skip rule a
/// run uses (`needsTriage`); those go at the front of the queue, due at once.
public enum TriageNow {
    /// How many of the newest candidates a click reads (each read is a transcript tail, maybe over SSH).
    public static let lookLimit = 30

    public enum Outcome: Sendable, Equatable {
        case queued(Int)
        /// Nothing waits on you or is unread.
        case nothing
        /// Every candidate looked at was already triaged as it stands; `more`: older ones weren't looked at.
        case nothingNew(more: Bool)
        case paused(String)
        public var message: String {
            switch self {
            case .queued(let count): "Triaging \(count) chat\(count == 1 ? "" : "s") now"
            case .nothing: "Nothing is waiting on you or unread"
            case .nothingNew(let more): more ? "Nothing new to triage in the \(TriageNow.lookLimit) newest chats" : "Nothing new to triage"
            case .paused(let reason): reason
            }
        }
    }

    /// Chats waiting on you or with a result to read, newest first.
    public static func candidates(_ chats: [BriefChatState], limit: Int = lookLimit) -> [String] {
        Array(chats.filter { $0.waiting || $0.unread }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }.prefix(max(0, limit)).map(\.id))
    }

    /// The gate first: nothing when triage is off or paused (with the reason), else the candidates to read.
    public static func plan(chats: [BriefChatState], gate: TriageGate, limit: Int = lookLimit) -> (outcome: Outcome?, chatIDs: [String]) {
        if gate == .off { return (.paused("Triage is off"), []) }
        if let reason = gate.reason { return (.paused(reason), []) }
        let ids = candidates(chats, limit: limit)
        return ids.isEmpty ? (.nothing, []) : (nil, ids)
    }

    /// The one skip rule: a chat is triaged only when its transcript could be read, has something
    /// to read, and its latest messages' hash isn't the one already triaged.
    public static func needsTriage(_ input: TriageInput?, triaged: [String: String]) -> Bool {
        guard let input else { return false }
        return triaged[input.chatID] != input.sourceHash && (input.lastAssistant != nil || input.lastUser != nil)
    }

    /// After reading the candidates (in order; nil: unreadable): up to one batch still needing
    /// triage, newest first, and what the click says. `total`: how many candidates there were in all.
    public static func pick(_ inputs: [(id: String, input: TriageInput?)], triaged: [String: String], total: Int,
                            limit: Int = TriageScheduler.batchSize) -> (outcome: Outcome, chatIDs: [String]) {
        let ids = Array(inputs.filter { needsTriage($0.input, triaged: triaged) }.prefix(max(0, limit)).map(\.id))
        return ids.isEmpty ? (.nothingNew(more: total > inputs.count), []) : (.queued(ids.count), ids)
    }
}

extension OrchestratorMemory {
    /// The notes the page's Memory card shows first: global ones, then the main project's (the
    /// order it reads them in), then any others.
    public static func preview(_ entries: [OrchestratorMemoryEntry], mainProject: String?, limit: Int = 4) -> [OrchestratorMemoryEntry] {
        let first = relevant(entries, mainProject: mainProject)
        let ids = Set(first.map(\.id))
        return Array((first + entries.filter { !ids.contains($0.id) }).prefix(max(0, limit)))
    }
}

/// How the Brief tab is laid out on one joined surface: the conversation in a tall left column with
/// the Brief queue and side panels in a right column beside it from 760 points of content width
/// (380 points wide from 1050, else 360); below that, one scrolling column with the conversation at
/// a fixed height first.
public enum OrchestratorPageColumns {
    public static func count(width: Double) -> Int { width >= 760 ? 2 : 1 }
    public static func sideWidth(width: Double) -> Double { width >= 1050 ? 380 : 360 }
}
