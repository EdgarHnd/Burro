// The Orchestrator page in the dashboard layout, kept pure so it can be tested: the header's toned
// sentence (`OrchestratorPageSummary.line`, with "2 need you" in amber) and the strip's four cells
// from what the page already shows: Needs you (an amber dot above zero; how long the oldest has
// waited), Finished, Stuck, and Triage today (runs today of the daily cap; what today's runs cost,
// then Claude's session quota as a quieter line; why triage is paused, in the Budget card's amber,
// or that it is off). One fact per sub-line.
import Foundation

public enum OrchestratorComposition {
    /// "2 need you, 3 finished · last triage 3 min ago." with the needs-you count in amber.
    public static func sentence(needs: Int, finished: Int, stuck: Int, lastTriage: Date?, triaging: Int, now: Date) -> [TextRun] {
        let line = OrchestratorPageSummary.line(needs: needs, finished: finished, stuck: stuck, lastTriage: lastTriage, triaging: triaging, now: now)
        guard needs > 0 else { return [TextRun(line + ".")] }
        let head = "\(needs) need\(needs == 1 ? "s" : "") you"
        return [TextRun(head, .needsYou), TextRun(String(line.dropFirst(head.count)) + ".")]
    }

    /// "now", "4 min", "2 h", "3 d".
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// The gate's reason, short enough for a strip cell.
    static func paused(_ gate: TriageGate) -> String? {
        switch gate {
        case .open, .off: nil
        case .dailyCap: "paused at the daily cap"
        case .hourlyCap: "paused at the hourly cap"
        case .session: "paused: session limit low"
        case .weekly: "paused: weekly limit low"
        }
    }

    /// `oldestNeed`: when the oldest needs-you item last changed.
    public static func stats(needs: Int, oldestNeed: Date?, finished: Int, stuck: Int, budget: OrchestratorBudget, gate: TriageGate,
                             now: Date) -> [DashboardStat] {
        let needsSub = needs == 0 ? "nothing waiting" : oldestNeed.map { age($0, now: now) == "now" ? "oldest just now" : "oldest \(age($0, now: now)) ago" } ?? "waiting on you"
        let needsStat = DashboardStat(id: "needs", label: "Needs you", value: "\(needs)", sub: [TextRun(needsSub)],
                                      help: "Chats triage found waiting on a decision, blocked, failing or looping.", dot: needs > 0)
        let finishedStat = DashboardStat(id: "finished", label: "Finished", value: "\(finished)",
                                         sub: [TextRun(finished == 0 ? "nothing new" : "results to read")],
                                         help: "Chats that finished with a result you haven't read in Burro.")
        let stuckStat = DashboardStat(id: "stuck", label: "Stuck", value: "\(stuck)",
                                      sub: [TextRun(stuck == 0 ? "none stuck" : "no new output", stuck == 0 ? .plain : .stuck)],
                                      help: "Chats that went quiet mid-turn. Nothing here messages an agent.")
        var triage = DashboardStat(id: "triage", label: "Triage today", value: "\(budget.runsToday) of \(budget.cap)", sub: [],
                                   help: "Automatic triage runs today of the daily cap. " + budget.floorsLine)
        let cost = "\(budget.cost) today"
        if gate == .off || !budget.enabled {
            triage.sub = [TextRun("automatic triage off", .stuck)]
            triage.footnote = cost
        } else if let reason = paused(gate) {
            triage.sub = [TextRun(reason, .needsYou)]
            triage.footnote = cost
            if let full = gate.reason { triage.help = full + ". " + triage.help }
        } else {
            triage.sub = [TextRun(cost)]
            triage.footnote = budget.session.map { "session \($0.left)" }
        }
        triage.help += " Cost is what Claude Code reports for today's Orchestrator and triage runs, at API prices."
        return [needsStat, finishedStat, stuckStat, triage]
    }
}
