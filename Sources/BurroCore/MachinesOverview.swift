// The Machines page's decisions, kept pure so they can be tested: the headline ("2 of 3 reachable ·
// 3 chats working · 2 need you"), each machine's chat list (chats working or waiting for you on
// that machine, needs-you first, newest first; subagents and expired remote samples left out), what
// a machine's local transcript copies add up to ("6 chats readable from the local copy"), a name
// suggested for a typed SSH address, and the argument list of "Open SSH" — remote monitoring's
// strict SSH options with an interactive terminal, where only the validated destination (and the
// configured port) varies and no remote command is sent.
import Foundation

public enum MachinesOverview {
    /// Whether a chat belongs in a machine's list: working or waiting for you, not a subagent, and
    /// not an expired sample of a machine that stopped answering.
    public static func isActive(_ session: AgentSession) -> Bool {
        guard session.isSubagent != true, session.remote?.stale != true else { return false }
        return session.state == .working || session.state == .waiting
    }

    /// The chats on one machine (`machine` nil for this Mac) that are working or need you: needs-you
    /// first, then newest first. At most `limit` rows; `more` counts the rest.
    public static func chats(machine: UUID?, sessions: [AgentSession], limit: Int = 5) -> (rows: [AgentSession], more: Int) {
        var seen = Set<String>()
        let mine = sessions.filter { $0.remote?.hostID == machine && isActive($0) && seen.insert($0.id).inserted }
            .sorted { a, b in
                let left = a.state == .waiting ? 0 : 1, right = b.state == .waiting ? 0 : 1
                if left != right { return left < right }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id < b.id
            }
        let limit = max(0, limit)
        return (Array(mine.prefix(limit)), max(0, mine.count - limit))
    }

    /// How many chats are working and how many need you, on the same rules as the chat lists.
    public struct Counts: Equatable, Sendable {
        public var working = 0
        public var needYou = 0
        public init(working: Int = 0, needYou: Int = 0) { self.working = working; self.needYou = needYou }
        /// Counts over `sessions`, on the same rules as the chat lists (duplicates counted once).
        public static func of(_ sessions: [AgentSession]) -> Counts {
            var counts = Counts(), seen = Set<String>()
            for session in sessions where isActive(session) && seen.insert(session.id).inserted {
                if session.state == .working { counts.working += 1 } else { counts.needYou += 1 }
            }
            return counts
        }
    }

    /// "2 of 3 reachable · 3 chats working · 2 need you". This Mac counts as one reachable machine;
    /// paused machines are left out of the total. Nothing needing you leaves that part out.
    public static func headline(reachable: Int, total: Int, counts: Counts) -> String {
        var parts: [String] = []
        parts.append(total <= 1 ? "This Mac only" : "\(min(reachable, total)) of \(total) reachable")
        switch counts.working {
        case 0: parts.append("no chats working")
        case 1: parts.append("1 chat working")
        default: parts.append("\(counts.working) chats working")
        }
        if counts.needYou > 0 { parts.append("\(counts.needYou) need\(counts.needYou == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    /// The muted text of a chat row: what state it is in and where ("Needs your input · burro").
    public static func detail(_ session: AgentSession) -> String {
        let state = session.state == .waiting ? "Needs your input" : "Working"
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        return folder.isEmpty || folder == "/" ? state : "\(state) · \(folder)"
    }

    /// What a machine's transcript copies add up to: how many chats can be read here while it is
    /// away, and when the newest copy was brought up to date.
    public struct LocalCopy: Equatable, Sendable {
        public var chats: Int
        public var lastSynced: Date?
        public init(chats: Int, lastSynced: Date?) { self.chats = chats; self.lastSynced = lastSynced }
        public init(entries: [RemoteCacheEntry]) {
            self.init(chats: Set(entries.map(\.key)).count, lastSynced: entries.map(\.fetchedAt).max())
        }
        /// "6 chats readable from the local copy", or that nothing was copied yet.
        public var text: String {
            switch chats {
            case 0: "No chats copied to this Mac yet"
            case 1: "1 chat readable from the local copy"
            default: "\(chats) chats readable from the local copy"
            }
        }
    }

    /// A name for a machine typed as an SSH address: "edgar@build-mini.tail4e2a.ts.net" → "build-mini".
    public static func suggestedName(for destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmed.split(separator: "@").last.map(String.init) ?? trimmed
        if host.hasPrefix("[") || host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

/// "Open SSH": a Terminal `.command` file that runs `ssh -t` to the machine with remote
/// monitoring's security options (keys only, verified host key, no forwarding, no local commands).
/// The background probe's timing and connection-sharing options (`ConnectTimeout`,
/// `ServerAliveInterval`/`CountMax`, `ControlMaster`/`ControlPersist`/`ControlPath`) are left out:
/// an interactive shell shouldn't drop after a few quiet seconds or ride Burro's shared probe
/// connection. Only the validated destination and the configured port vary; no remote command is
/// sent, so the machine opens its own login shell.
public enum RemoteShell {
    /// The probe's `-o` options an interactive shell doesn't take.
    static let probeOnlyOptions: Set<String> = ["ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax",
                                                "ControlMaster", "ControlPersist", "ControlPath"]
    public static func arguments(host: RemoteHost) -> [String]? {
        guard host.validationError == nil else { return nil }
        let probe = RemoteAgentMonitor.arguments(for: host)
        guard probe.first == "-T", probe.last == "python3 -", probe.dropLast().last == host.destination,
              let separator = probe.lastIndex(of: "--") else { return nil }
        var args = ["-t"]
        var index = 1
        while index < separator {
            if probe[index] == "-o", index + 1 < separator {
                let key = String(probe[index + 1].split(separator: "=", maxSplits: 1).first ?? "")
                if !probeOnlyOptions.contains(key) { args += ["-o", probe[index + 1]] }
                index += 2
            } else { args.append(probe[index]); index += 1 }
        }
        return args + ["--", host.destination]
    }
    /// The `.command` file's text: every argument single-quoted for zsh.
    public static func script(host: RemoteHost) -> String? {
        guard let args = arguments(host: host) else { return nil }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        return "#!/bin/zsh\nexec /usr/bin/ssh " + args.map(quoted).joined(separator: " ") + "\n"
    }
}
