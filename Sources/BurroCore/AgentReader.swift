// Adapt local Codex metadata and Claude session files without modifying either provider.
import Foundation
import CSystem

public struct AgentInventory: Sendable {
    public var sessions: [AgentSession] = []
    public var roots: [String] = []
    public var warnings: [String] = []
}
public enum AgentParsing {
    public static func codexIsSubagent(source: String?) -> Bool {
        guard let source else { return false }
        if source == "subagent" || source == "\"subagent\"" { return true }
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["subagent"] != nil
    }
    public static func codexParentID(source: String?) -> String? {
        guard let source, let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let child = object["subagent"] as? [String: Any],
              let spawn = child["thread_spawn"] as? [String: Any],
              let id = spawn["parent_thread_id"] as? String, UUID(uuidString: id) != nil else { return nil }
        return "codex:" + id
    }
    public static func codexDisplayName(name: String?, title: String?, isSubagent: Bool) -> String {
        for value in [name, title].compactMap({ $0 }) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return isSubagent ? "Codex sub-agent" : "Untitled chat"
    }
    static func codexEvent(tail: String) -> (CodexEventState, Bool)? {
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "event_msg", let payload = event["payload"] as? [String: Any],
                  let kind = payload["type"] as? String, let result = SessionStatusPolicy.codexEvents[kind] else { continue }
            return result
        }
        return nil
    }
    public static func codexCompleted(tail: String) -> Bool { codexEvent(tail: tail)?.1 ?? false }
    public static func matchesClaudeStart(_ text: String, started: Date) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // Claude records may come from a UTC subprocess on a Mac using local time.
        for zone in [TimeZone(secondsFromGMT: 0)!, TimeZone.current] {
            formatter.timeZone = zone
            if let expected = formatter.date(from: text), abs(started.timeIntervalSince(expected)) < 2 { return true }
        }
        return false
    }
    public static func claudeState(_ status: String, live: Bool) -> AgentState {
        guard live else { return .inactive }
        return SessionStatusPolicy.claudeAliases[status.lowercased()] ?? .unknown
    }
    public static func codexState(tail: String, held: Int32, modified: Date?, now: Date) -> AgentState {
        let event = codexEvent(tail: tail)
        return CodexLogEvidence(readable: true, modified: modified?.timeIntervalSince1970,
                                last: event?.0, completed: event?.1 ?? false).state(held: held, now: now)
    }
}
public struct AgentReader: Sendable {
    private let logWorker: AgentLogWorker
    public init() { logWorker = .shared }
    init(logWorker: AgentLogWorker) { self.logWorker = logWorker }
    public func read(home: String, processes: ProcessSnapshot, now: Date, readState: ProviderReadState = .empty) -> AgentInventory {
        var result = codex(home: home, now: now, unread: readState.codexUnread)
        let claude = claude(home: home, processes: processes, now: now)
        result.sessions += claude.sessions; result.roots += claude.roots; result.warnings += claude.warnings
        result.sessions = result.sessions.map { readState.applying(to: $0) }
        return result
    }
    private func codex(home: String, now: Date, unread: Set<String>) -> AgentInventory {
        var result = AgentInventory()
        let directory = URL(fileURLWithPath: home).appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: directory.path) else { return result }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let databases = files.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }
            guard let path = databases.first else { result.warnings.append("Codex is present but its session database is unavailable"); return result }
            let db = try SQLiteReader(path: path.path)
            let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
            let pinned = columns.contains("is_pinned") ? "is_pinned" : "0 AS is_pinned"
            let name = columns.contains("name") ? "name" : "NULL AS name"
            let source = columns.contains("source") ? "source" : "NULL AS source"
            let threads = try db.rows("SELECT id,cwd,title,updated_at,rollout_path,\(pinned),\(name),\(source) FROM threads WHERE archived=0 ORDER BY updated_at DESC")
            let tables = Set(try db.rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
            if tables.contains("project_roots") { result.roots += try db.rows("SELECT path FROM project_roots").compactMap { $0["path"] } }
            var attachments: [String: [String]] = [:]
            if tables.contains("thread_attachments") {
                for row in try db.rows("SELECT thread_id,identity_key,payload FROM thread_attachments WHERE attachment_type='worktree'") {
                    guard let thread = row["thread_id"], let raw = row["payload"], let data = raw.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        result.warnings.append("A Codex worktree attachment could not be read"); continue
                    }
                    if object["archivedAt"] != nil || object["archived"] as? Bool == true { continue }
                    if let root = object["workspaceRoot"] as? String ?? object["root"] as? String ?? row["identity_key"] {
                        attachments[thread, default: []].append(Paths.canonical(root)); result.roots.append(root)
                    }
                }
            }
            // Batch only the logs this snapshot needs. The worker caches parsed
            // events; live lock checks and age-dependent state stay in Swift.
            let paths = Array(Set(threads.compactMap { row -> String? in
                guard let id = row["id"], let path = row["rollout_path"] else { return nil }
                let held = burro_lock_held(directory.appendingPathComponent("thread-writer-locks/\(id).lock").path)
                let recent = now.timeIntervalSince1970 - (Double(row["updated_at"] ?? "0") ?? 0) < 600
                let unreadParent = unread.contains(id) && !AgentParsing.codexIsSubagent(source: row["source"])
                return held != 0 || recent || unreadParent ? path : nil
            })).sorted()
            let logs = Dictionary(uniqueKeysWithValues: zip(paths, logWorker.read(paths)))
            for row in threads {
                guard let id = row["id"], let cwd = row["cwd"] else { result.warnings.append("A Codex session is missing its workspace"); continue }
                let lock = directory.appendingPathComponent("thread-writer-locks/\(id).lock").path
                let held = burro_lock_held(lock)
                let updated = Date(timeIntervalSince1970: Double(row["updated_at"] ?? "0") ?? 0)
                let recent = now.timeIntervalSince(updated) < 600
                let isSubagent = AgentParsing.codexIsSubagent(source: row["source"])
                var state: AgentState = .inactive
                var completed = false
                var evidence = "No held writer lock or recent unfinished turn"
                if held != 0 || recent || (unread.contains(id) && !isSubagent) {
                    let rollout = row["rollout_path"] ?? ""
                    // A lock acquired during the batch can introduce a new log.
                    let log = logs[rollout] ?? CodexLogEvidence.swiftRead(rollout)
                    completed = log.completed
                    if !log.readable {
                        state = .unknown
                        evidence = held == 1 ? "Open writer lock; session log unavailable" : "Session log unavailable; activity is uncertain"
                    }
                    else {
                        state = log.state(held: held, now: now)
                        evidence = held == 1 ? "Live Codex writer lock + local turn events" : (held < 0 ? "Writer lock could not be inspected" : "Local turn events; no live writer lock")
                        if held == 1 && state == .unknown && log.last == nil {
                            evidence = "This open Codex chat has no turn activity in its local log."
                        }
                    }
                }
                result.sessions.append(AgentSession(id: "codex:\(id)", provider: .codex,
                    title: AgentParsing.codexDisplayName(name: row["name"], title: row["title"], isSubagent: isSubagent), cwd: Paths.canonical(cwd),
                    attachedPaths: attachments[id] ?? [], state: state, updatedAt: updated,
                    pinned: row["is_pinned"] == "1", evidence: evidence, turnCompleted: completed, isSubagent: isSubagent,
                    parentSessionID: AgentParsing.codexParentID(source: row["source"])))
                if held != 0 { result.roots.append(cwd) }
            }
        } catch { result.warnings.append(error.localizedDescription) }
        return result
    }
    private func claude(home: String, processes: ProcessSnapshot, now: Date) -> AgentInventory {
        var result = AgentInventory()
        let directory = URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            if processes.processes.contains(where: { $0.name.lowercased() == "claude" }) { result.warnings.append("Claude is running but session metadata is unavailable") }
            return result
        }
        do {
            let completed = ProviderReadState.claudeCompletedSessions(home: home)
            var records: [[String: Any]] = []
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["sessionId"] is String, object["cwd"] is String, object["pid"] is Int else {
                    result.warnings.append("A Claude session record could not be read"); continue
                }
                records.append(object)
            }
            // One Rust batch discovers Claude projects once and caches each worker's lifecycle.
            // Only verified idle sessions can be overridden by delegated-work evidence.
            let candidates = records.compactMap { object -> ClaudeLogSession? in
                guard object["status"] as? String == "idle", let id = object["sessionId"] as? String,
                      UUID(uuidString: id) != nil, let started = object["startedAt"] as? Double,
                      started.isFinite, started > 0, let pid = object["pid"] as? Int,
                      let expected = object["procStart"] as? String,
                      let process = processes.processes.first(where: { $0.pid == pid && $0.name.lowercased() == "claude" }),
                      AgentParsing.matchesClaudeStart(expected, started: process.started) else { return nil }
                return ClaudeLogSession(sessionID: id, started: started / 1000)
            }
            let parsed = logWorker.readClaude(root: URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").path,
                                             sessions: candidates, now: now)
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            var delegatedStates: [String: [AgentState]] = [:]
            if let parsed {
                for (session, state) in zip(candidates, parsed) { delegatedStates[session.sessionID] = state.map { [$0] } ?? [] }
            }
            for object in records {
                guard let id = object["sessionId"] as? String, let cwd = object["cwd"] as? String, let pid = object["pid"] as? Int else { continue }
                let process = processes.processes.first { $0.pid == pid && $0.name.lowercased() == "claude" }
                // procStart is the kernel start time. Verify it to avoid stale files matching reused PIDs.
                let expected = object["procStart"] as? String
                let live = process.map { p in expected.map { AgentParsing.matchesClaudeStart($0, started: p.started) } ?? false } ?? false
                var state = AgentParsing.claudeState(object["status"] as? String ?? "", live: live)
                if process != nil && !live { state = .unknown }
                let updated = Date(timeIntervalSince1970: (object["updatedAt"] as? Double ?? object["startedAt"] as? Double ?? 0) / 1000)
                if !processes.warnings.isEmpty && process == nil { state = .unknown }
                var evidence = live ? "Live Claude PID and verified process start + reported session status" : "No matching live Claude process, or process identity is uncertain"
                if state == .idle, let process,
                   let delegated = ClaudeDelegatedActivity.inspect(home: home, sessionID: id, parent: process,
                       incarnation: (object["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                       processes: processes.processes, now: now, deadline: deadline, workerEvidence: delegatedStates[id]) {
                    state = delegated.state; evidence = delegated.evidence
                }
                result.sessions.append(AgentSession(id: "claude:\(id)", provider: .claude,
                    title: object["name"] as? String ?? "Claude Code session", cwd: Paths.canonical(cwd),
                    state: state, updatedAt: updated, pid: live ? pid : nil,
                    evidence: evidence,
                    claudeDesktopSessionID: object["hostSessionId"] as? String,
                    claudeBridgeSessionID: object["bridgeSessionId"] as? String,
                    turnCompleted: completed.contains(object["hostSessionId"] as? String ?? "") && object["status"] as? String == "idle" && (state == .idle || state == .inactive)))
                result.roots.append(cwd)
            }
        } catch { result.warnings.append("Claude session directory could not be read") }
        return result
    }
}
