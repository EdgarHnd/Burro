// Verify transport boundaries, stale evidence, cross-host identity, and remote/local selection isolation.
import XCTest
@testable import BurroCore
@testable import Burro

final class RemoteSessionTests: XCTestCase {
    @MainActor func testClosedRemoteHistoryIsBrowsableWithoutAddingToActiveQueue() throws {
        let instant = Date()
        let host = RemoteHost(name: "Other Mac", destination: "fixture")
        let input = Data(String(decoding: payload(), as: UTF8.self)
            .replacingOccurrences(of: "Working", with: "Inactive")
            .replacingOccurrences(of: "Needs input", with: "Inactive")
            .replacingOccurrences(of: "1800000000", with: String(instant.timeIntervalSince1970 - 1)).utf8)
        let snapshot = try RemoteAgentMonitor.decode(input, host: host, receivedAt: instant)
        XCTAssertEqual(snapshot.sessions.count, 2)
        let suite = "burro-today-remote-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.remoteSnapshots[host.id] = snapshot
        store.remoteHosts = [host]
        XCTAssertTrue(store.agentActivity.sessions.isEmpty)
        XCTAssertTrue(store.remoteSessions.isEmpty)
        let feed = NotchFeed(sessions: store.notchChatSessions, includeIdle: false, scope: .today, now: instant)
        XCTAssertEqual(feed.groups.count, 2)
        XCTAssertEqual(feed.groups.first?.root?.remote?.hostName, "Other Mac")
        store.selectAgent(try XCTUnwrap(feed.groups.first?.root))
        XCTAssertEqual(store.selectedRemote?.id, feed.groups.first?.id)
        store.remoteHosts[0].enabled = false
        XCTAssertTrue(store.notchChatSessions.isEmpty)
        XCTAssertNil(store.selectedRemote)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func payload(version: Int = 1) -> Data {
        Data("""
        {"version":\(version),"warnings":[],"sessions":[
          {"id":"codex:same","provider":"Codex","title":"Remote task","cwd":"/same/path","attachedPaths":[],"state":"Working","updatedAt":1800000000,"pid":null,"pinned":false,"evidence":"fixture"},
          {"id":"claude:same","provider":"Claude Code","title":"Waiting task","cwd":"/same/path","attachedPaths":[],"state":"Needs input","updatedAt":1800000000,"pid":42,"pinned":false,"evidence":"fixture"}
        ]}
        """.utf8)
    }
    func testHostValidationRejectsShellAndOptionInjection() {
        for destination in ["-oProxyCommand=bad", "host;echo bad", "host\ncommand", "$(whoami)", "user@", "user@@host", "host name"] {
            XCTAssertNotNil(RemoteHost(name: "Remote", destination: destination).validationError, destination)
        }
        for destination in ["devbox", "user@laptop.local", "user@100.64.1.2", "user@[2001:db8::1]"] {
            XCTAssertNil(RemoteHost(name: "Remote", destination: destination).validationError, destination)
        }
        XCTAssertNotNil(RemoteHost(name: "Remote", destination: "devbox", port: 0).validationError)
    }
    func testSSHUsesExistingTrustAndNoForwardingOrShellInterpolation() {
        let host = RemoteHost(name: "Laptop", destination: "user@laptop", port: 2222)
        let args = RemoteAgentMonitor.arguments(for: host)
        XCTAssertEqual(Array(args.suffix(3)), ["--", "user@laptop", "python3 -"])
        for option in ["StrictHostKeyChecking=yes", "BatchMode=yes", "ClearAllForwardings=yes", "ForwardAgent=no", "PermitLocalCommand=no"] { XCTAssertTrue(args.contains(option)) }
        XCTAssertTrue(args.contains("2222"))
        XCTAssertFalse(args.contains("StrictHostKeyChecking=no"))
    }
    func testSameSessionIDsOnDifferentHostsRemainDistinctAndRemotePathsStayLiteral() throws {
        let a = RemoteHost(name: "A", destination: "a"), b = RemoteHost(name: "B", destination: "b")
        let first = try RemoteAgentMonitor.decode(payload(), host: a, receivedAt: now)
        let second = try RemoteAgentMonitor.decode(payload(), host: b, receivedAt: now)
        XCTAssertNotEqual(first.sessions[0].id, second.sessions[0].id)
        XCTAssertEqual(first.sessions[0].cwd, "/same/path")
        XCTAssertEqual(first.sessions[0].remote?.hostID, a.id)
        let feed = AgentActivitySnapshot(sessions: first.sessions + second.sessions, warnings: [], sampledAt: now)
        XCTAssertEqual(feed.visibleSessions(includeIdle: true).count, 4)
        XCTAssertEqual(feed.workingCount, 2)
        XCTAssertEqual(feed.waitingCount, 2)
    }
    func testDelegatedClaudeParentAppearsOnceAndCannotBecomeDoneWhileWorkRemains() throws {
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        let data = Data("""
        {"version":1,"warnings":[],"sessions":[
          {"id":"claude:parent","provider":"Claude Code","title":"Delegated work","cwd":"/repo",
           "attachedPaths":[],"state":"Working","updatedAt":1800000000,"pinned":false,
           "evidence":"Verified delegated work; parent reports idle","turnCompleted":false,
           "claudeBridgeSessionID":"session_fixture"}
        ]}
        """.utf8)
        let snapshot = try RemoteAgentMonitor.decode(data, host: host, receivedAt: now)
        var unread = ProviderReadState.empty
        unread.claudeUnread = ["session_fixture"]
        let sessions = snapshot.displaySessions(now: now).map { unread.applying(to: $0) }
        let activity = AgentActivitySnapshot(sessions: sessions, warnings: [], sampledAt: now)
        XCTAssertEqual(activity.workingCount, 1)
        XCTAssertEqual(activity.doneCount, 0)
        let feed = NotchFeed(sessions: sessions, includeIdle: false)
        XCTAssertEqual(feed.groups.count, 1)
        XCTAssertEqual(feed.groups.first?.root?.title, "Delegated work")
        let stale = snapshot.displaySessions(now: now.addingTimeInterval(31)).map { unread.applying(to: $0) }
        XCTAssertEqual(AgentActivitySnapshot(sessions: stale, warnings: [], sampledAt: now).workingCount, 0)
        XCTAssertFalse(stale[0].isDone)
    }

    func testRemoteScheduledStateHasSeparateCountAndExpiresToUnknown() throws {
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        let input = Data(String(decoding: payload(), as: UTF8.self).replacingOccurrences(of: "Working", with: "Scheduled").utf8)
        let snapshot = try RemoteAgentMonitor.decode(input, host: host, receivedAt: now)
        let live = AgentActivitySnapshot(sessions: snapshot.displaySessions(now: now), warnings: [], sampledAt: now)
        XCTAssertEqual(live.scheduledCount, 1); XCTAssertEqual(live.workingCount, 0)
        XCTAssertEqual(live.visibleSessions(includeIdle: false).count, 2)
        let stale = AgentActivitySnapshot(sessions: snapshot.displaySessions(now: now.addingTimeInterval(31)), warnings: [], sampledAt: now)
        XCTAssertEqual(stale.scheduledCount, 0)
    }

    func testOfflineSessionsBecomeLastSeenAndStopCountingAsWorking() throws {
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        let online = try RemoteAgentMonitor.decode(payload(), host: host, receivedAt: now)
        let offline = RemoteHostSnapshot.mergeFailure(host: host, error: "offline", previous: online, now: now.addingTimeInterval(10))
        let sessions = offline.displaySessions(now: now.addingTimeInterval(10))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.state == .unknown && $0.remote?.stale == true })
        XCTAssertEqual(sessions[0].remote?.sampledAt, now)
        XCTAssertEqual(AgentActivitySnapshot(sessions: sessions, warnings: [], sampledAt: now).workingCount, 0)
    }
    func testExpiredAndDisabledSamplesCannotLookLive() throws {
        var host = RemoteHost(name: "Laptop", destination: "laptop")
        var snapshot = try RemoteAgentMonitor.decode(payload(), host: host, receivedAt: now)
        XCTAssertEqual(snapshot.displaySessions(now: now)[0].state, .working)
        XCTAssertTrue(snapshot.displaySessions(now: now.addingTimeInterval(31)).allSatisfy { $0.state == .unknown })
        host.enabled = false; snapshot.host = host
        XCTAssertTrue(snapshot.displaySessions(now: now).isEmpty)
    }
    func testChangingDestinationDoesNotCarryOldSessionsAcross() throws {
        var host = RemoteHost(name: "Laptop", destination: "first")
        let previous = try RemoteAgentMonitor.decode(payload(), host: host, receivedAt: now)
        host.destination = "second"
        let result = RemoteHostSnapshot.mergeFailure(host: host, error: "offline", previous: previous, now: now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.sampledAt)
    }
    func testMalformedOrFutureProtocolDoesNotMasqueradeAsEmptySuccess() {
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        XCTAssertThrowsError(try RemoteAgentMonitor.decode(Data("login banner\n{}".utf8), host: host, receivedAt: now))
        XCTAssertThrowsError(try RemoteAgentMonitor.decode(payload(version: 9), host: host, receivedAt: now))
    }
    func testCommandStdinIsLiteralAndProbeIsBundled() throws {
        let input = Data("$(do-not-run) `literal` \"quoted\"\n".utf8)
        let result = CommandRunner().run("/bin/cat", [], input: input)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(Data(result.output.utf8), input)
        XCTAssertTrue(try String(contentsOf: RemoteAgentMonitor.probeURL, encoding: .utf8).contains("def collect(home)"))
    }
    func testCommandStopsExcessiveOutput() {
        let result = CommandRunner().run("/usr/bin/yes", ["bounded output"], timeout: 2)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.code, -2)
        XCTAssertTrue(result.output.isEmpty)
    }
    @MainActor func testRemoteSelectionCannotSelectAWorktreeOnThisMac() async throws {
        let suite = "burro-remote-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        let host = RemoteHost(name: "Laptop", destination: "laptop")
        let remote = try RemoteAgentMonitor.decode(payload(), host: host, receivedAt: now).sessions[0]
        store.selection = "/same/path"
        store.selectAgent(remote)
        XCTAssertEqual(store.filter, .remote)
        XCTAssertEqual(store.remoteSelection, remote.id)
        XCTAssertNil(store.selectedRemote) // Not present in the current host feed, never falls back to local data.
    }
}
