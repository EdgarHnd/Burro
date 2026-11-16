import XCTest
@testable import BurroCore

final class MachinesOverviewTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hostID = UUID()

    private func session(_ id: String, _ state: AgentState, minutesAgo: Double = 0, remote: UUID? = nil, stale: Bool = false,
                         subagent: Bool = false, cwd: String = "/Users/me/Dev/burro") -> AgentSession {
        var value = AgentSession(id: id, provider: .claude, title: id, cwd: cwd, state: state,
                                 updatedAt: t0.addingTimeInterval(-minutesAgo * 60), evidence: "")
        if let remote { value.remote = RemoteOrigin(hostID: remote, hostName: "Other Mac", sampledAt: t0, stale: stale) }
        if subagent { value.isSubagent = true }
        return value
    }

    func testChatsArePerMachineNeedsYouFirstThenNewest() {
        let sessions = [
            session("old-work", .working, minutesAgo: 9),
            session("new-work", .working, minutesAgo: 1),
            session("ask", .waiting, minutesAgo: 30),
            session("idle", .idle),
            session("sub", .working, subagent: true),
            session("remote-work", .working, remote: hostID),
            session("new-work", .working, minutesAgo: 1),
        ]
        let local = MachinesOverview.chats(machine: nil, sessions: sessions)
        XCTAssertEqual(local.rows.map(\.id), ["ask", "new-work", "old-work"])
        XCTAssertEqual(local.more, 0)
        XCTAssertEqual(MachinesOverview.chats(machine: hostID, sessions: sessions).rows.map(\.id), ["remote-work"])
    }

    func testChatsAreCappedAndCountTheRest() {
        let sessions = (0..<8).map { session("w\($0)", .working, minutesAgo: Double($0)) }
        let result = MachinesOverview.chats(machine: nil, sessions: sessions, limit: 5)
        XCTAssertEqual(result.rows.map(\.id), ["w0", "w1", "w2", "w3", "w4"])
        XCTAssertEqual(result.more, 3)
    }

    func testExpiredRemoteSamplesAreNotListedOrCounted() {
        let sessions = [session("stale-ask", .waiting, remote: hostID, stale: true), session("live", .working, remote: hostID)]
        XCTAssertEqual(MachinesOverview.chats(machine: hostID, sessions: sessions).rows.map(\.id), ["live"])
        XCTAssertEqual(MachinesOverview.Counts.of(sessions), MachinesOverview.Counts(working: 1, needYou: 0))
    }

    func testCountsMatchTheListsAcrossMachines() {
        let sessions = [
            session("a", .working), session("b", .waiting), session("b", .waiting),
            session("c", .working, remote: hostID), session("d", .waiting, remote: hostID), session("e", .recent),
            session("f", .working, subagent: true),
        ]
        XCTAssertEqual(MachinesOverview.Counts.of(sessions), MachinesOverview.Counts(working: 2, needYou: 2))
    }

    func testHeadline() {
        XCTAssertEqual(MachinesOverview.headline(reachable: 2, total: 3, counts: .init(working: 3, needYou: 2)),
                       "2 of 3 reachable · 3 chats working · 2 need you")
        XCTAssertEqual(MachinesOverview.headline(reachable: 1, total: 1, counts: .init(working: 1, needYou: 1)),
                       "This Mac only · 1 chat working · 1 needs you")
        XCTAssertEqual(MachinesOverview.headline(reachable: 3, total: 2, counts: .init()), "2 of 2 reachable · no chats working")
    }

    func testDetail() {
        XCTAssertEqual(MachinesOverview.detail(session("x", .waiting)), "Needs your input · burro")
        XCTAssertEqual(MachinesOverview.detail(session("x", .working, cwd: "/")), "Working")
    }

    func testLocalCopyCountsMirrorEntriesAndTheNewestSync() {
        func entry(_ key: String, _ minutesAgo: Double) -> RemoteCacheEntry {
            RemoteCacheEntry(key: key, file: "0123456789abcdef", remotePath: "/x", size: 10, remoteMTime: 0,
                             fetchedAt: t0.addingTimeInterval(-minutesAgo * 60), openedAt: t0)
        }
        let copy = MachinesOverview.LocalCopy(entries: [entry("a", 30), entry("b", 2), entry("c", 90), entry("b", 50)])
        XCTAssertEqual(copy.chats, 3)
        XCTAssertEqual(copy.lastSynced, t0.addingTimeInterval(-120))
        XCTAssertEqual(copy.text, "3 chats readable from the local copy")
        XCTAssertEqual(MachinesOverview.LocalCopy(entries: []).text, "No chats copied to this Mac yet")
        XCTAssertNil(MachinesOverview.LocalCopy(entries: []).lastSynced)
    }

    func testSuggestedName() {
        XCTAssertEqual(MachinesOverview.suggestedName(for: "me@build-mini.tail4e2a.ts.net"), "build-mini")
        XCTAssertEqual(MachinesOverview.suggestedName(for: " studio "), "studio")
        XCTAssertEqual(MachinesOverview.suggestedName(for: "10.0.0.7"), "10.0.0.7")
    }

    // MARK: Open SSH

    func testOpenSSHUsesTheStrictOptionsWithOnlyTheDestinationVarying() throws {
        let host = RemoteHost(name: "Other Mac", destination: "me@other-mac.tail4e2a.ts.net", port: 2222)
        let args = try XCTUnwrap(RemoteShell.arguments(host: host))
        let monitor = RemoteAgentMonitor.arguments(for: host)
        XCTAssertEqual(args.first, "-t")
        XCTAssertEqual(Array(args.suffix(2)), ["--", "me@other-mac.tail4e2a.ts.net"])
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes",
                       "PermitLocalCommand=no", "LogLevel=ERROR"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertEqual(Array(args.suffix(4)), ["-p", "2222", "--", "me@other-mac.tail4e2a.ts.net"])
        XCTAssertFalse(args.contains("python3 -"))
        // The interactive shell drops the probe's timeouts, keep-alives and shared connection.
        for key in ["ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax", "ControlMaster", "ControlPersist", "ControlPath"] {
            XCTAssertFalse(args.contains { $0.hasPrefix(key + "=") }, key)
        }
        // Every remaining option comes from the probe's own list, in its order, each after "-o".
        let kept = stride(from: 1, to: args.count - 4, by: 2).map { args[$0 + 1] }
        XCTAssertTrue(stride(from: 1, to: args.count - 4, by: 2).allSatisfy { args[$0] == "-o" })
        XCTAssertEqual(kept, monitor.enumerated().filter { $0.offset > 0 && monitor[$0.offset - 1] == "-o" }.map(\.element)
            .filter { !["ConnectTimeout", "ServerAliveInterval", "ServerAliveCountMax", "ControlMaster", "ControlPersist", "ControlPath"].contains(String($0.split(separator: "=").first!)) })

        // Two machines differ only in the destination.
        let other = RemoteHost(name: "Build Mini", destination: "build-mini", port: 2222)
        let otherArgs = try XCTUnwrap(RemoteShell.arguments(host: other))
        XCTAssertEqual(Array(otherArgs.dropLast()), Array(args.dropLast()))
    }

    func testOpenSSHRefusesAnInvalidDestination() {
        XCTAssertNil(RemoteShell.arguments(host: RemoteHost(name: "x", destination: "a; rm -rf ~")))
        XCTAssertNil(RemoteShell.arguments(host: RemoteHost(name: "x", destination: "-oProxyCommand=evil")))
        XCTAssertNil(RemoteShell.script(host: RemoteHost(name: "", destination: "fine")))
    }

    func testOpenSSHScriptQuotesEveryArgument() throws {
        let host = RemoteHost(name: "Other Mac", destination: "other-mac")
        let script = try XCTUnwrap(RemoteShell.script(host: host))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\nexec /usr/bin/ssh '-t' '-o' 'BatchMode=yes'"))
        XCTAssertTrue(script.hasSuffix("'--' 'other-mac'\n"))
        XCTAssertEqual(script.split(separator: "\n").count, 2)
    }
}
