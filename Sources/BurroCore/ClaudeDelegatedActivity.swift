// Keep idle Claude parents visible while verified background commands or in-process workers remain.
import Foundation
import CoreFoundation
import CSystem
import Darwin

struct ClaudeDelegatedActivity {
    var state: AgentState
    var evidence: String

    enum InspectionError: Error { case incomplete }
    typealias OutputPath = (Int, Int) throws -> String?

    static func outputPath(pid: Int, fd: Int) throws -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        let status = burro_process_output_path(Int32(pid), Int32(fd), &path, Int32(path.count))
        guard status >= 0 else { throw InspectionError.incomplete }
        return status == 1 ? String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    static func descendants(of parent: Int, processes: [LocalProcess]) throws -> [LocalProcess] {
        var found: Set<Int> = [], frontier: Set<Int> = [parent]
        for _ in 0..<32 {
            let children = processes.filter { $0.pid != parent && !found.contains($0.pid) && frontier.contains($0.parentPID ?? -1) }
            if children.isEmpty { return processes.filter { found.contains($0.pid) } }
            frontier = Set(children.map(\.pid)); found.formUnion(frontier)
            if found.count > 256 { throw InspectionError.incomplete }
        }
        throw InspectionError.incomplete
    }

    static func taskID(path: String, sessionID: String, uid: UInt32 = getuid()) -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let prefix = path.hasPrefix("/private/tmp/") ? ["", "private", "tmp"] : ["", "tmp"]
        guard parts.count == prefix.count + 5, Array(parts.prefix(prefix.count)) == prefix,
              parts[prefix.count] == "claude-\(uid)", !["", ".", ".."].contains(parts[prefix.count + 1]),
              parts[prefix.count + 2] == sessionID, parts[prefix.count + 3] == "tasks",
              parts.last?.hasSuffix(".output") == true else { return nil }
        let id = String(parts.last!.dropLast(7))
        return validID(id) ? id : nil
    }

    // A sleeping OS process alone is insufficient. Require an owned task whose entire branch
    // consists of shell wrappers waiting for explicit sleep executables. Mixed work stays Running.
    static func taskIsScheduled(owners: Set<Int>, processes: [LocalProcess]) throws -> Bool {
        var branch = owners
        for pid in owners { branch.formUnion(try descendants(of: pid, processes: processes).map(\.pid)) }
        let members = processes.filter { branch.contains($0.pid) }
        guard members.contains(where: { $0.name == "sleep" }) else { return false }
        let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
        return members.allSatisfy { process in
            if process.name == "sleep" { return true }
            return wrappers.contains(process.name) && members.contains { $0.parentPID == process.pid }
        }
    }

    static func inspect(home: String, sessionID: String, parent: LocalProcess, incarnation: Date?,
                        processes: [LocalProcess], now: Date, deadline: TimeInterval,
                        identity: (LocalProcess) -> Bool = ProcessReader.isCurrent,
                        descriptor: OutputPath = outputPath) -> Self? {
        var workers: [AgentState] = []
        if let incarnation, incarnation.timeIntervalSince1970.isFinite, incarnation.timeIntervalSince1970 > 0 {
            workers = workerStates(home: home, sessionID: sessionID, started: incarnation, now: now, deadline: deadline)
        }
        var tasks: [String: Set<Int>] = [:], complete = true
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw InspectionError.incomplete }
            let children = try descendants(of: parent.pid, processes: processes)
            for child in children {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw InspectionError.incomplete }
                guard identity(child) else { continue }
                var owned: Set<String> = []
                for fd in [1, 2] {
                    if let path = try descriptor(child.pid, fd), let task = taskID(path: path, sessionID: sessionID) { owned.insert(task) }
                }
                guard identity(child) else { continue }
                for task in owned { tasks[task, default: []].insert(child.pid) }
            }
        } catch { complete = false }
        guard identity(parent) else { return unknown }
        let scheduled = tasks.values.allSatisfy { (try? taskIsScheduled(owners: $0, processes: processes)) == true }
        if workers.contains(.working) || (!tasks.isEmpty && !scheduled) {
            return Self(state: .working, evidence: "Verified Claude process with active delegated work; parent reports idle")
        }
        if !complete || workers.contains(.unknown) { return unknown }
        if !tasks.isEmpty {
            return Self(state: .scheduled, evidence: "Verified Claude background task waiting in a live sleep delay; resumes automatically")
        }
        return nil
    }

    private static var unknown: Self {
        Self(state: .unknown, evidence: "Claude reports idle; delegated work could not be confirmed complete")
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func workerTailState(_ tail: String, sessionID: String, agentID: String, started: Date, now: Date, modified: Date) -> AgentState? {
        let formatter = ISO8601DateFormatter()
        var identified = false
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if event["sessionId"] is String && event["agentId"] is String { identified = true }
            guard event["sessionId"] as? String == sessionID, event["agentId"] as? String == agentID,
                  event["isSidechain"] as? Bool == true, let type = event["type"] as? String,
                  ["assistant", "user"].contains(type), let stamp = event["timestamp"] as? String,
                  let message = event["message"] as? [String: Any] else { continue }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var time = formatter.date(from: stamp)
            if time == nil { formatter.formatOptions = [.withInternetDateTime]; time = formatter.date(from: stamp) }
            guard let time, time >= started.addingTimeInterval(-2), time <= now.addingTimeInterval(5) else { continue }
            if type == "assistant", ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") { return nil }
            // New Claude workers finish via SubagentHandback: the final tool-result
            // envelope ends the turn, without a following assistant stop_reason.
            if type == "user", let endsTurn = event["toolEndsTurn"] as? NSNumber,
               CFGetTypeID(endsTurn) == CFBooleanGetTypeID(), endsTurn.boolValue,
               let content = message["content"] as? [Any],
               content.contains(where: { ($0 as? [String: Any])?["type"] as? String == "tool_result" }) { return nil }
            return (-5...120).contains(now.timeIntervalSince(time)) && (-5...120).contains(now.timeIntervalSince(modified)) ? .working : .unknown
        }
        return !identified && !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unknown : nil
    }

    static func workerStates(home: String, sessionID: String, started: Date, now: Date, deadline: TimeInterval) -> [AgentState] {
        guard UUID(uuidString: sessionID) != nil else { return [] }
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var states: [AgentState] = []
        var enumerationFailed = false
        func directory(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            return values.isSymbolicLink != true && values.isDirectory == true
        }
        do {
            // The enumerator is shallow, with explicit bounds instead of an unbounded recursive crawl.
            guard let projects = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else { return [.unknown] }
            var count = 0
            for case let project as URL in projects {
                count += 1
                guard count <= 256, ProcessInfo.processInfo.systemUptime < deadline else { return states + [.unknown] }
                guard try directory(project) else { continue }
                let session = project.appendingPathComponent(sessionID), folder = session.appendingPathComponent("subagents")
                guard fm.fileExists(atPath: folder.path) else { continue }
                guard try directory(session), try directory(folder) else { states.append(.unknown); continue }
                guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else { states.append(.unknown); continue }
                var workers = 0
                for case let file as URL in files where file.lastPathComponent.hasPrefix("agent-") && file.pathExtension == "jsonl" {
                    workers += 1
                    guard workers <= 64, ProcessInfo.processInfo.systemUptime < deadline else { return states + [.unknown] }
                    let agentID = String(file.deletingPathExtension().lastPathComponent.dropFirst(6))
                    guard validID(agentID) else { continue }
                    let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
                    guard values.isSymbolicLink != true else { states.append(.unknown); continue }
                    guard let modified = values.contentModificationDate, modified >= started.addingTimeInterval(-2) else { continue }
                    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard fd >= 0 else { states.append(.unknown); continue }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    let size = try handle.seekToEnd(), limit: UInt64 = 512 * 1024
                    try handle.seek(toOffset: size > limit ? size - limit : 0)
                    let tail = String(decoding: try handle.read(upToCount: Int(limit)) ?? Data(), as: UTF8.self)
                    if let state = workerTailState(tail, sessionID: sessionID, agentID: agentID, started: started, now: now, modified: modified) { states.append(state) }
                }
            }
        } catch { states.append(.unknown) }
        if enumerationFailed { states.append(.unknown) }
        return states
    }
}
