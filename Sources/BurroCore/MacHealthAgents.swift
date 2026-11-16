// Ties Mac Health's process scan to agent chats on this Mac, using only what Burro already has: the process tree from
// the scan Mac Health runs anyway, and the chats' verified agent process IDs. A process belongs to a chat when the
// chat's agent process is its ancestor; a leftover also belongs to a Claude chat when it runs in that chat's temporary
// folder (/tmp/claude-<uid>/<project>/<session id>/). Nothing here reads the system, and nothing is guessed from names.
import Foundation

/// The little Mac Health needs to know about a chat on this Mac.
public struct AgentChatRef: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    /// The chat's agent process when Burro has verified it is live; nil for finished chats or providers without one.
    public var pid: Int?
    public init(id: String, title: String, pid: Int?) { self.id = id; self.title = title; self.pid = pid }
}

public struct AgentProcessLine: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var chat: AgentChatRef
    /// Percent of one core since the previous scan; nil on the first scan.
    public var cpuPercent: Double?
    public var memory: UInt64?
}

public struct AgentProcessSummary: Sendable, Equatable {
    /// The busiest processes, highest CPU first, then memory.
    public var top: [AgentProcessLine]
    public var processes: Int
    public var cpuPercent: Double
    public var memory: UInt64
    public static let empty = AgentProcessSummary(top: [], processes: 0, cpuPercent: 0, memory: 0)
}

public enum AgentProcessAttribution {
    /// Every process under a chat's verified agent process, attributed to the nearest chat above it.
    public static func summarize(_ inventory: ProcessInventory, cpu: [String: Double], chats: [AgentChatRef], limit: Int = 5) -> AgentProcessSummary {
        let byPID = Dictionary(inventory.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // Only a pid that is still an agent CLI counts, so a reused pid is never blamed on a chat.
        var owners: [Int: AgentChatRef] = [:]
        for chat in chats {
            guard let pid = chat.pid, let process = byPID[pid], LeftoverPolicy.isAgentCLI(process.executable) else { continue }
            owners[pid] = chat
        }
        guard !owners.isEmpty else { return .empty }
        var lines: [AgentProcessLine] = []
        for process in inventory.processes {
            guard let chat = owner(of: process.pid, byPID: byPID, owners: owners) else { continue }
            lines.append(AgentProcessLine(id: process.id, name: LeftoverPolicy.label(executable: process.executable, arguments: process.arguments),
                                          chat: chat, cpuPercent: cpu[process.id], memory: process.memory))
        }
        lines.sort { a, b in
            let left = a.cpuPercent ?? -1, right = b.cpuPercent ?? -1
            if left != right { return left > right }
            if (a.memory ?? 0) != (b.memory ?? 0) { return (a.memory ?? 0) > (b.memory ?? 0) }
            return a.id < b.id
        }
        return AgentProcessSummary(top: Array(lines.prefix(limit)), processes: lines.count,
                                   cpuPercent: lines.compactMap(\.cpuPercent).reduce(0, +), memory: lines.compactMap(\.memory).reduce(0, +))
    }

    /// The chat a leftover belongs to, if any: an agent process above it, or a Claude chat's temporary folder it runs in.
    public static func chat(for leftover: Leftover, inventory: ProcessInventory, chats: [AgentChatRef]) -> AgentChatRef? {
        guard let pid = leftover.pid else { return nil }
        let byPID = Dictionary(inventory.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var owners: [Int: AgentChatRef] = [:]
        for chat in chats {
            guard let pid = chat.pid, let process = byPID[pid], LeftoverPolicy.isAgentCLI(process.executable) else { continue }
            owners[pid] = chat
        }
        if let chat = owner(of: pid, byPID: byPID, owners: owners) { return chat }
        guard let process = byPID[pid] else { return nil }
        for path in [process.cwd] + process.arguments.dropFirst() {
            guard let session = claudeTemporarySession(path) else { continue }
            if let chat = chats.first(where: { $0.id.lowercased() == "claude:\(session)" }) { return chat }
        }
        return nil
    }

    /// The session ID in a Claude Code temporary path such as /private/tmp/claude-501/-Users-me-Dev-app/<uuid>/scratchpad.
    public static func claudeTemporarySession(_ path: String) -> String? {
        guard let range = path.range(of: "/tmp/claude-") else { return nil }
        let components = path[range.upperBound...].split(separator: "/").prefix(4)
        // claude-<uid>, then the project folder, then the session; the first UUID after the uid wins.
        for component in components.dropFirst() where component.count == 36 {
            if let uuid = UUID(uuidString: String(component)) { return uuid.uuidString.lowercased() }
        }
        return nil
    }

    private static func owner(of pid: Int, byPID: [Int: ProcessSample], owners: [Int: AgentChatRef]) -> AgentChatRef? {
        var current: Int? = pid, hops = 0
        while let next = current, next > 1, hops < 64 {
            if let chat = owners[next] { return chat }
            current = byPID[next]?.parentPID; hops += 1
        }
        return nil
    }
}

/// The Keep awake card's segmented control: one choice per segment, and which one is on now.
public enum KeepAwakeChoice: Hashable, Sendable {
    case duration(TimeInterval)
    case untilStopped
    case agents

    public static let all: [KeepAwakeChoice] = KeepAwakePolicy.durations.map { $0.seconds.map(KeepAwakeChoice.duration) ?? .untilStopped } + [.agents]

    public var title: String {
        switch self {
        case .duration(let seconds): KeepAwakePolicy.durations.first(where: { $0.seconds == seconds })?.title ?? "\(Int(seconds / 3600)) hours"
        case .untilStopped: "Until I stop"
        case .agents: "While agents work"
        }
    }
    public var seconds: TimeInterval? { if case .duration(let seconds) = self { seconds } else { nil } }

    /// A timed request is shown as the segment that started it only when it still ends when that pick said it would
    /// (`pickedAt` + its length), so a duration chosen from the menu bar is never mislabelled. A timed request
    /// that can't be matched leaves no segment on; the headline still says until when.
    public static func selected(manualUntil: Date?, agentsMode: Bool, picked: TimeInterval?, pickedAt: Date?, now: Date) -> KeepAwakeChoice? {
        if let until = manualUntil, until > now {
            if until == .distantFuture { return .untilStopped }
            if let picked, let pickedAt, abs(pickedAt.addingTimeInterval(picked).timeIntervalSince(until)) < 5 { return .duration(picked) }
            return nil
        }
        return agentsMode ? .agents : nil
    }
}
