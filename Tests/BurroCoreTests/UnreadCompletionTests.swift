// Provider unread markers control Done independently of lifecycle and cleanup evidence.
import XCTest
@testable import BurroCore

final class UnreadCompletionTests: XCTestCase {
    let id = "11111111-2222-4333-8444-555555555555"
    func agent(_ state: AgentState = .idle) -> AgentSession {
        AgentSession(id: "codex:\(id)", provider: .codex, title: "Fixture", cwd: "/tmp/fixture", state: state,
                     updatedAt: Date(), evidence: "fixture", turnCompleted: true)
    }
    func testDonePersistsUntilProviderClearsUnreadAndDoesNotChangeSafety() {
        var read = ProviderReadState.empty; read.codexUnread = [id]
        let done = read.applying(to: agent())
        XCTAssertTrue(done.isDone); XCTAssertEqual(done.state, .idle); XCTAssertTrue(done.state.keepsWorktree)
        let snapshot = AgentActivitySnapshot(sessions: [done], warnings: [], sampledAt: Date())
        XCTAssertEqual(snapshot.doneCount, 1); XCTAssertEqual(snapshot.idleCount, 0)
        XCTAssertEqual(snapshot.visibleSessions(includeIdle: false).count, 1)
        read.codexUnread = []
        let seen = read.applying(to: done)
        XCTAssertFalse(seen.isDone)
        XCTAssertEqual(AgentActivitySnapshot(sessions: [seen], warnings: [], sampledAt: Date()).visibleSessions(includeIdle: false).count, 1, "Reading clears unread, not a live chat’s verified finished state")
        read.codexUnread = [id]
        XCTAssertTrue(read.applying(to: seen).isDone, "A later unread completion can reappear")
    }
    func testClosedUnreadStaysVisibleAndRunningOrWaitingAlwaysWin() {
        var read = ProviderReadState.empty; read.codexUnread = [id]
        let closed = read.applying(to: agent(.inactive))
        XCTAssertTrue(closed.isDone); XCTAssertFalse(closed.state.keepsWorktree)
        for state in [AgentState.working, .waiting, .scheduled, .unknown, .recent] { XCTAssertFalse(read.applying(to: agent(state)).isDone) }
        var noResult = agent(); noResult.turnCompleted = false
        XCTAssertFalse(read.applying(to: noResult).isDone)
    }
    func testAbortsAndNewTurnsDoNotBecomeDone() {
        func event(_ name: String) -> String { "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(name)\"}}" }
        let complete = event("task_complete")
        XCTAssertTrue(AgentParsing.codexCompleted(tail: event("task_started") + "\n" + complete))
        for name in ["turn_aborted", "task_aborted", "task_started", "request_user_input", "approval_required"] {
            XCTAssertFalse(AgentParsing.codexCompleted(tail: complete + "\n" + event(name)))
        }
        XCTAssertFalse(AgentParsing.codexCompleted(tail: "{\"type\":\"response_item\",\"payload\":{\"type\":\"task_complete\"}}"))
    }
    func testCodexAccountsAndLegacySnapshotsAreNotUnioned() throws {
        let other = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": [
            "version": 1, "unreadByIdentity": ["current": ["local:host": [id]], "old": ["local:host": [other]]],
            "legacyMigration": ["unreadThreadIdsByHostId": ["local": [other]]]]])
        XCTAssertEqual(try ProviderReadState.codexIDs(data: data, identity: "current"), [id])
        XCTAssertThrowsError(try ProviderReadState.codexIDs(data: data, identity: nil))
        XCTAssertThrowsError(try ProviderReadState.codexIDs(data: data, identity: "missing"))
    }
    func testClaudeUsesExplicitUnreadAndBridgeIdentityOnRemote() throws {
        let data = Data(#"{"version":0,"state":{"unreadIds":["local_here"],"explicitUnreadIds":["session_bridge"]}}"#.utf8)
        var read = ProviderReadState.empty; read.claudeUnread = try ProviderReadState.claudeIDs(data: data)
        var session = agent(); session.provider = .claude; session.claudeDesktopSessionID = "local_here"
        XCTAssertTrue(read.applying(to: session).isDone)
        session.remote = RemoteOrigin(hostID: UUID(), hostName: "Other", sampledAt: Date(), stale: false)
        XCTAssertFalse(read.applying(to: session).isDone)
        session.claudeBridgeSessionID = "session_bridge"
        XCTAssertTrue(read.applying(to: session).isDone)
        session.remote?.stale = true
        XCTAssertFalse(read.applying(to: session).isDone)
    }
    func testOldRemotePayloadStillDecodesAndCompletedClosedPayloadCanBeProjected() throws {
        let host = RemoteHost(name: "Other", destination: "other")
        let json = #"{"version":1,"sessions":[{"id":"codex:ID","provider":"Codex","title":"Fixture","cwd":"/repo","attachedPaths":[],"state":"Inactive","updatedAt":0,"pinned":false,"evidence":"fixture","turnCompleted":true}],"warnings":[]}"#.replacingOccurrences(of: "ID", with: id)
        let result = try RemoteAgentMonitor.decode(Data(json.utf8), host: host, receivedAt: Date())
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertFalse(result.sessions[0].isDone)
        var read = ProviderReadState.empty; read.codexUnread = [id]
        XCTAssertTrue(read.applying(to: result.sessions[0]).isDone)
        let stale = result.displaySessions(now: Date().addingTimeInterval(60))[0]
        XCTAssertFalse(read.applying(to: stale).isDone)
    }
}
