// Machines in the dashboard layout, kept pure so it can be tested: the header's toned sentence (the
// same parts as `MachinesOverview.headline`, with "2 need you" in amber) and the strip's four cells:
// Reachable ("2 of 3"; the sub-line names what isn't answering), Working, Waiting on you (an amber
// dot only above zero) and Tools out of date (the machines' names, "all up to date" only once
// versions were read, "—" while they are being checked). One fact per sub-line.
import Foundation

public enum MachinesComposition {
    /// One machine as the strip sees it.
    public struct Machine: Sendable, Equatable {
        public enum Reach: Sendable, Equatable { case reachable, checking, unreachable, paused }
        public var name: String
        public var reach: Reach
        public var counts: MachinesOverview.Counts
        /// Titles of the agent tools that have a newer release.
        public var outdated: [String]
        /// Its tool versions have been read.
        public var versionsKnown: Bool
        public var probing: Bool
        public init(name: String, reach: Reach, counts: MachinesOverview.Counts = .init(), outdated: [String] = [],
                    versionsKnown: Bool = false, probing: Bool = false) {
            self.name = name; self.reach = reach; self.counts = counts; self.outdated = outdated
            self.versionsKnown = versionsKnown; self.probing = probing
        }
    }

    /// Reachable machines (this Mac counts) and the total without paused ones, as the headline counts them.
    public static func reach(_ machines: [Machine]) -> (reachable: Int, total: Int) {
        (machines.filter { $0.reach == .reachable }.count, machines.filter { $0.reach != .paused }.count)
    }

    /// The headline's parts as runs: "2 of 3 reachable · 3 chats working · 2 need you."
    public static func sentence(reachable: Int, total: Int, counts: MachinesOverview.Counts) -> [TextRun] {
        let parts = MachinesOverview.headline(reachable: reachable, total: total, counts: counts).components(separatedBy: " · ")
        var runs: [TextRun] = []
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            let text = part + (last ? "." : " · ")
            if index == 0 { runs.append(TextRun(text, .strong)) }
            else if counts.needYou > 0 && last { runs.append(TextRun(text, .needsYou)) }
            else { runs.append(TextRun(text)) }
        }
        return runs
    }

    /// "This Mac and Studio", "This Mac, Studio and Mini", or "4 machines" past three names.
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return "\(names.count) machines"
        }
    }

    public static func stats(_ machines: [Machine]) -> [DashboardStat] {
        let (reachable, total) = reach(machines)
        let away = machines.filter { $0.reach == .unreachable }.map(\.name)
        let checking = machines.filter { $0.reach == .checking }.count
        let paused = machines.filter { $0.reach == .paused }.count
        let reachSub: TextRun
        if !away.isEmpty { reachSub = TextRun(away.count == 1 ? "\(away[0]) unreachable" : "\(away.count) unreachable", .stuck) }
        else if checking > 0 { reachSub = TextRun("\(checking) checking…") }
        else if total <= 1 { reachSub = TextRun(paused > 0 ? "\(paused) paused" : "this Mac only") }
        else { reachSub = TextRun(paused > 0 ? "\(paused) paused" : "all answering") }
        let reachStat = DashboardStat(id: "reachable", label: "Reachable", value: total <= 1 ? "\(reachable)" : "\(reachable) of \(total)",
                                      sub: [reachSub], help: "Machines answering Burro's checks; this Mac always counts. Paused machines are left out.")

        let working = machines.reduce(0) { $0 + $1.counts.working }
        let busy = machines.filter { $0.counts.working > 0 }.map(\.name)
        let workingStat = DashboardStat(id: "working", label: "Working", value: "\(working)",
                                        sub: [TextRun(busy.isEmpty ? "nothing running" : "on " + names(busy))],
                                        help: "Chats working now on your machines (sub-agents left out).")

        let waiting = machines.reduce(0) { $0 + $1.counts.needYou }
        let waitingOn = machines.filter { $0.counts.needYou > 0 }.map(\.name)
        let waitingStat = DashboardStat(id: "waiting", label: "Waiting on you", value: "\(waiting)",
                                        sub: [TextRun(waitingOn.isEmpty ? "nothing waiting" : "on " + names(waitingOn))],
                                        help: "Chats that stopped and wait for your answer.", dot: waiting > 0)

        let outdated = machines.filter { !$0.outdated.isEmpty }
        let count = outdated.reduce(0) { $0 + $1.outdated.count }
        let known = machines.contains(where: \.versionsKnown)
        let toolsStat: DashboardStat
        if count > 0 {
            toolsStat = DashboardStat(id: "tools", label: "Tools out of date", value: "\(count)", sub: [TextRun("on " + names(outdated.map(\.name)))],
                                      help: outdated.map { "\($0.name): \($0.outdated.joined(separator: ", "))" }.joined(separator: "\n"))
        } else if known {
            toolsStat = DashboardStat(id: "tools", label: "Tools out of date", value: "0", sub: [TextRun("all up to date")],
                                      help: "Every agent tool Burro found is on its latest release (from npm).")
        } else {
            let probing = machines.contains(where: \.probing)
            toolsStat = DashboardStat(id: "tools", label: "Tools out of date", value: "—",
                                      sub: [TextRun(probing ? "checking versions…" : "versions not read yet")],
                                      help: "Versions are read on each machine with the tool's own --version.")
        }
        return [reachStat, workingStat, waitingStat, toolsStat]
    }
}
