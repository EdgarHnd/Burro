// What Settings tells you leaves this Mac, one line per channel, worked out from the real toggles
// (triage, Shipped summaries, usage limits, to-do sync, notes access, machines you added), plus the
// one-sentence summary under the Orchestrator pane's title. Pure, so the wording for every
// combination is tested; the Settings window only draws it.
import Foundation

public enum SettingsDisclosure {
    /// One line of "What leaves this Mac". `sends` lines get a bright dot; the rest stay grey.
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: String
        public var text: String
        public var sends: Bool
        public init(id: String, text: String, sends: Bool) { self.id = id; self.text = text; self.sends = sends }
    }

    /// The toggles the summary depends on, read from the stores by the caller.
    public struct State: Sendable, Equatable {
        public var triage: Bool
        public var shippedSummaries: Bool
        public var usageLimits: Bool
        public var notesAccess: Bool
        /// The Convex host to-dos sync with, or nil when sync isn't connected.
        public var todoSyncHost: String?
        /// Names of the machines you added and left on.
        public var machines: [String]
        /// The small model triage and Shipped use, e.g. "Haiku 5.5".
        public var smallModel: String
        public init(triage: Bool, shippedSummaries: Bool, usageLimits: Bool, notesAccess: Bool, todoSyncHost: String?,
                    machines: [String], smallModel: String) {
            self.triage = triage; self.shippedSummaries = shippedSummaries; self.usageLimits = usageLimits
            self.notesAccess = notesAccess; self.todoSyncHost = todoSyncHost; self.machines = machines; self.smallModel = smallModel
        }
    }

    public static func lines(_ state: State) -> [Line] {
        var lines = [
            state.triage
                ? Line(id: "triage", text: "Chat endings go to Claude \(state.smallModel) for triage", sends: true)
                : Line(id: "triage", text: "Triage is off, so no chat endings are sent", sends: false),
            state.shippedSummaries
                ? Line(id: "shipped", text: "Pull-request titles go to Claude \(state.smallModel) for Shipped summaries", sends: true)
                : Line(id: "shipped", text: "Shipped summaries are off, so no pull-request titles are sent", sends: false),
            Line(id: "ask", text: "When you ask the Orchestrator something, it goes to Claude with your chat list and its memory"
                 + (state.notesAccess ? ", and your notes when it needs them" : ""), sends: true),
        ]
        if state.usageLimits {
            lines.append(Line(id: "usage", text: "Usage limits ask Codex, Claude and Grok for your quotas with your own sign-ins", sends: true))
        }
        if let host = state.todoSyncHost {
            lines.append(Line(id: "todos", text: "To-dos sync with your Convex backend (\(host))", sends: true))
        }
        lines.append(Line(id: "activity", text: "Nothing from tracked activity is sent anywhere", sends: false))
        lines.append(Line(id: "ssh", text: sshLine(state.machines), sends: false))
        return lines
    }

    static func sshLine(_ machines: [String]) -> String {
        switch machines.count {
        case 0: "No SSH connections: you haven't added another machine"
        case 1: "SSH connects only to your own machine, \(machines[0])"
        case 2: "SSH connects only to your own machines, \(machines[0]) and \(machines[1])"
        default: "SSH connects only to the \(machines.count) machines you added"
        }
    }

    /// "Triage is on, the morning brief is on, and it can't read your notes."
    public static func orchestratorSummary(triage: Bool, morningBrief: Bool, notesAccess: Bool) -> String {
        let notes = notesAccess ? "it can read your notes" : "it can't read your notes"
        guard triage else { return "Triage is off, so chats aren't read as they end, and \(notes)." }
        return "Triage is on, the morning brief is \(morningBrief ? "on" : "off"), and \(notes)."
    }

    /// "9 of 150 used today".
    public static func capUsage(runsToday: Int, cap: Int) -> String {
        "\(runsToday) of \(cap) used today"
    }
}
