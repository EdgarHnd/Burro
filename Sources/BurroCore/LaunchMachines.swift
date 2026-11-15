// Choosing the machine a new chat starts on, and what the app shows around a start there.
// The New chat sheet's machine chip lists This Mac, then every configured machine with its status
// line; a paused machine, one with an invalid address and one currently unreachable are listed but
// can't be picked, with the reason. A remote start's failure becomes one clear message for its row
// (unreachable with when it was last seen, Claude not installed there, not the standalone Codex,
// folder not trusted by Claude, blocked at a prompt, started but not confirmed). The ⌘K palette's
// "New chat on <Machine>…" and "New chat in <folder> on <Machine>…" rows (ranked below this Mac's)
// come from here too; they only open the sheet. Pure: the app passes snapshots, folders and the clock.
import Foundation

/// One entry of the machine chip.
public struct LaunchMachine: Identifiable, Equatable, Sendable {
    /// nil is this Mac.
    public var id: UUID?
    public var name: String
    /// The status line ("Connected · checked 12 s ago"), empty for this Mac.
    public var detail: String
    /// Why it can't be picked now, nil when it can.
    public var unavailable: String?
    public var available: Bool { unavailable == nil }
    public init(id: UUID?, name: String, detail: String, unavailable: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.unavailable = unavailable
    }
}

public enum LaunchMachines {
    public static let thisMac = LaunchMachine(id: nil, name: "This Mac", detail: "")

    /// Why a machine can't take a new chat right now, nil when it can. Paused (or with an invalid
    /// address) and unreachable machines can't; one not checked yet can (the start itself will tell).
    public static func unavailability(_ snapshot: RemoteHostSnapshot, status: String) -> String? {
        if !snapshot.host.enabled || snapshot.state == .disabled { return "Paused" }
        if let problem = snapshot.host.validationError { return problem }
        if snapshot.state == .offline { return status.isEmpty ? "Unreachable" : status }
        return nil
    }

    /// This Mac, then every configured machine in its order, each with its status line.
    public static func options(hosts: [RemoteHost], snapshot: (RemoteHost) -> RemoteHostSnapshot,
                               status: (RemoteHost) -> String) -> [LaunchMachine] {
        [thisMac] + hosts.map { host in
            let line = status(host)
            return LaunchMachine(id: host.id, name: host.name, detail: line, unavailable: unavailability(snapshot(host), status: line))
        }
    }

    /// The chip's row text: "Studio · Connected · checked 12 s ago".
    public static func rowTitle(_ machine: LaunchMachine) -> String {
        machine.detail.isEmpty ? machine.name : "\(machine.name) · \(machine.detail)"
    }

    /// A folder row in the project chip: "app · repo on main", plus "not trusted by Claude yet" for
    /// an untrusted folder when the chat is Claude's.
    public static func folderTitle(_ folder: RemoteFolder, provider: LaunchProvider) -> String {
        var parts = [URL(fileURLWithPath: folder.path).lastPathComponent]
        if let git = folder.git {
            let repo = URL(fileURLWithPath: git.root).lastPathComponent
            let branch = git.branch.map { " on \($0)" } ?? ""
            if repo != parts[0] || !branch.isEmpty { parts.append(repo + branch) }
        }
        if provider == .claude, !folder.trusted { parts.append("not trusted by Claude yet") }
        return parts.joined(separator: " · ")
    }
}

/// A remote start's failure as the one message its row shows.
public enum RemoteLaunchFailure {
    /// `machine` is the machine's name, `lastSeen` its last successful check.
    public static func message(_ error: Error, machine: String, lastSeen: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let error = error as? RemoteLaunchError else {
            return (error as? LocalizedError)?.errorDescription ?? "The chat didn't start on \(machine)."
        }
        switch error {
        case .unreachable:
            let seen = lastSeen.map { "Last seen \(RemoteStatusLine.clock($0, now: now, timeZone: timeZone))." } ?? "Burro hasn't reached it yet."
            return "Couldn't reach \(machine) over SSH. \(seen) Check that it's awake and online, then Retry."
        case .claudeNotInstalled:
            return "Claude Code isn't installed on \(machine). Install it there, or start the chat with Codex."
        case .codexNotInstalled:
            return "Codex isn't installed on \(machine). Install it there, or start the chat with Claude Code."
        case .codexNotStandalone(_, let detail):
            return detail
        case .untrusted(_, let folder):
            let name = URL(fileURLWithPath: folder).lastPathComponent
            return "Claude hasn't been trusted in \(name) on \(machine) yet. Open Terminal on \(machine), run `claude` in that folder once and accept, then Retry."
        case .timedOut:
            return "\(machine) didn't answer in time. Retry when it's reachable."
        case .folder, .blocked, .unconfirmed, .notConfirmed, .failed:
            return error.errorDescription ?? "The chat didn't start on \(machine)."
        }
    }
}

extension RemoteHostSnapshot {
    /// The snapshot with a just-started chat's placeholder added, unless a row with its id is already there.
    public func addingPlaceholder(_ session: AgentSession) -> RemoteHostSnapshot {
        let key = session.id.lowercased()
        guard !sessions.contains(where: { $0.id.lowercased() == key }) else { return self }
        var copy = self
        copy.sessions.append(session)
        return copy
    }
    /// The ids of the rows a check reported (placeholders left out).
    public var checkedSessionIDs: [String] {
        sessions.filter { $0.evidence != PendingLaunch.placeholderEvidence }.map(\.id)
    }
}

/// The ⌘K palette's rows for starting on another machine. Each opens the New chat sheet prefilled
/// with that machine (and folder); nothing starts without the sheet's Start.
public enum CommandPaletteRemoteLaunch {
    public struct Entry: Equatable, Sendable {
        public var item: CommandPaletteItem
        public var machine: UUID
        public var folder: String?
    }
    /// Folders offered per machine.
    public static let folderLimit = 40
    /// Below this Mac's "New chat in …" rows with the same name.
    public static let folderWeight = -25

    /// "New chat on <Machine>…" for every enabled machine, then "New chat in <folder> on <Machine>…"
    /// for its remembered folders (existing ones, as listed).
    public static func entries(hosts: [RemoteHost], folders: (RemoteHost) -> [RemoteFolder]) -> [Entry] {
        let enabled = hosts.filter { $0.enabled && $0.validationError == nil }
        var result = enabled.map { host in
            Entry(item: CommandPaletteItem(id: "action:new-chat-on:\(host.id.uuidString)", kind: .action, title: "New chat on \(host.name)…",
                                           subtitle: "Opens the New chat sheet", keywords: ["start", "launch", "remote", "Codex", "Claude"],
                                           weight: -5),
                  machine: host.id, folder: nil)
        }
        for host in enabled {
            var seen = Set<String>()
            for folder in folders(host).filter(\.exists) where seen.insert(folder.path).inserted {
                guard seen.count <= folderLimit else { break }
                let name = URL(fileURLWithPath: folder.path).lastPathComponent
                result.append(Entry(item: CommandPaletteItem(id: "action:new-chat-in:\(host.id.uuidString):\(folder.path)", kind: .action,
                                                             title: "New chat in \(name) on \(host.name)…",
                                                             subtitle: "\(folder.path) · opens the New chat sheet",
                                                             keywords: ["start", "launch", host.name, folder.git?.branch ?? ""],
                                                             weight: folderWeight),
                                    machine: host.id, folder: folder.path))
            }
        }
        return result
    }
}
