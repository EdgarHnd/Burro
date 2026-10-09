// Sidebar chats and internal workers share a database but must not share unread Done badges.
import XCTest
@testable import BurroCore

final class CodexChatIdentityTests: XCTestCase {
    func testAllSubagentOriginsAreClassifiedWithoutInspectingTitles() {
        for source in [#"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}"#,
                       #"{"subagent":{"other":"guardian"}}"#, #"{"subagent":"review"}"#, "subagent", #""subagent""#] {
            XCTAssertTrue(AgentParsing.codexIsSubagent(source: source))
        }
        for source in [nil, "vscode", "cli", "exec", #"{"other":"subagent"}"#, "invalid"] {
            XCTAssertFalse(AgentParsing.codexIsSubagent(source: source))
        }
    }
    func testDisplayNameUsesTheSameNameAsCodexBeforeOriginalPrompt() {
        XCTAssertEqual(AgentParsing.codexDisplayName(name: "Build worktree and agent tracker", title: "i need a minimalistic mac app...", isSubagent: false), "Build worktree and agent tracker")
        XCTAssertEqual(AgentParsing.codexDisplayName(name: "  ", title: "Original title", isSubagent: false), "Original title")
        XCTAssertEqual(AgentParsing.codexDisplayName(name: nil, title: "", isSubagent: false), "Untitled chat")
        XCTAssertEqual(AgentParsing.codexDisplayName(name: nil, title: nil, isSubagent: true), "Codex sub-agent")
    }
    func testInternalUnreadDoesNotCountAsDoneButLiveWorkersStillCount() {
        let id = UUID().uuidString
        var worker = AgentSession(id: "codex:\(id)", provider: .codex, title: "Named worker", cwd: "/repo", state: .idle,
            updatedAt: Date(), evidence: "fixture", turnCompleted: true, hasUnreadResult: true, isSubagent: true)
        var read = ProviderReadState.empty; read.codexUnread = [id]
        XCTAssertFalse(worker.isDone, "Defense at presentation boundary, including decoded remote data")
        XCTAssertFalse(read.applying(to: worker).hasUnreadResult == true)
        var feed = AgentActivitySnapshot(sessions: [worker], warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.doneCount, 0); XCTAssertTrue(feed.visibleSessions(includeIdle: false).isEmpty)
        XCTAssertTrue(worker.state.keepsWorktree)
        worker.state = .working
        feed.sessions = [read.applying(to: worker)]
        XCTAssertEqual(feed.workingCount, 1); XCTAssertEqual(feed.visibleSessions(includeIdle: false).count, 1)
        worker.remote = RemoteOrigin(hostID: UUID(), hostName: "Other", sampledAt: Date(), stale: false)
        worker.state = .inactive
        XCTAssertFalse(read.applying(to: worker).isDone)
    }
    func testReaderKeepsRealUnreadChatsAndRejectsBlankAndNamedChildRuns() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rollout = codex.appendingPathComponent("fixture.jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#.utf8).write(to: rollout)
        let ids = (0..<4).map { _ in UUID().uuidString }
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let child = #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}"#
        let records = [(ids[0], "Displayed chat name", "Original prompt", "vscode"),
                       (ids[1], "", "", "vscode"),
                       (ids[2], "", "", child), (ids[3], "Named worker", "Task instruction", child)]
        var sql = "CREATE TABLE threads (id TEXT,cwd TEXT,title TEXT,name TEXT,source TEXT,updated_at INTEGER,rollout_path TEXT,archived INTEGER);\n"
        for (id, name, title, source) in records {
            sql += "INSERT INTO threads VALUES (\(quoted(id)), '/repo', \(quoted(title)), \(quoted(name)), \(quoted(source)), 0, \(quoted(rollout.path)), 0);\n"
        }
        let create = CommandRunner().run("/usr/bin/sqlite3", [codex.appendingPathComponent("state_5.sqlite").path], input: Data(sql.utf8))
        XCTAssertTrue(create.succeeded, create.error)
        var read = ProviderReadState.empty; read.codexUnread = Set(ids)
        let inventory = AgentReader().read(home: home.path, processes: ProcessSnapshot(processes: [], warnings: []), now: Date(), readState: read)
        XCTAssertEqual(inventory.warnings, [])
        XCTAssertEqual(inventory.sessions.count, 4, "Internal activity stays in the inventory for worktree safety")
        let feed = AgentActivitySnapshot(sessions: inventory.sessions, warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.doneCount, 2)
        XCTAssertEqual(Set(feed.visibleSessions(includeIdle: false).map(\.title)), ["Displayed chat name", "Untitled chat"])
        XCTAssertEqual(inventory.sessions.filter { $0.isSubagent == true }.count, 2)
        let fallback = AgentReader(logWorker: AgentLogWorker(executable: nil)).read(
            home: home.path, processes: ProcessSnapshot(processes: [], warnings: []), now: Date(), readState: read)
        XCTAssertEqual(fallback.warnings, inventory.warnings)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(fallback.sessions), try encoder.encode(inventory.sessions),
                       "Swift recovery must preserve complete session metadata and unread state")
    }
}
