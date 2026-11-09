import XCTest
@testable import BurroCore

/// Opt-in checks against real services. They clean up after themselves.
final class LiveIntegrationTests: XCTestCase {
    /// BURRO_LIVE_CONVEX=1: add, tick and remove a to-do through Maurice's Convex backend.
    func testLiveConvexTodoRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_CONVEX"] == "1" else { throw XCTSkip("set BURRO_LIVE_CONVEX=1") }
        let secrets = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dev/maurice-app/Config/Secrets.xcconfig")
        let config = try XCTUnwrap(ConvexConfig.parseXcconfig(try String(contentsOf: secrets, encoding: .utf8)))
        let remote = TodoRemote(client: ConvexClient(config: config))
        let day = TodoDay.key(), since = TodoDay.startMillis()
        let clientId = "burro-live-\(UUID().uuidString.prefix(8))"
        let added = try await remote.perform(.add(clientId: clientId, text: "Burro live test", day: day, project: nil))
        let id = try XCTUnwrap(added)
        defer { Task { try? await remote.perform(.remove(id: id)) } }
        let again = try await remote.perform(.add(clientId: clientId, text: "Burro live test", day: day, project: nil))
        XCTAssertEqual(again, id, "a retried add returns the same row")
        let listed = try await remote.today(day: day, doneSince: since)
        XCTAssertTrue(listed.contains { $0.id == id && !$0.done })
        try await remote.perform(.setDone(id: id, done: true))
        let ticked = try await remote.today(day: day, doneSince: since)
        XCTAssertEqual(ticked.first { $0.id == id }?.done, true)
        do { try await remote.perform(.edit(id: id, text: "   ")); XCTFail("blank text must be refused") }
        catch let error as ConvexClientError { XCTAssertEqual(error, .refused("Write the to-do first.")) }
        try await remote.perform(.remove(id: id))
        let after = try await remote.today(day: day, doneSince: since)
        XCTAssertFalse(after.contains { $0.id == id })
        let bad = TodoRemote(client: ConvexClient(config: ConvexConfig(url: config.url, token: String(repeating: "x", count: 40))))
        do { _ = try await bad.today(day: day, doneSince: since); XCTFail("a wrong token must fail") }
        catch let error as ConvexClientError { XCTAssertEqual(error, .unauthorized) }
    }

    /// BURRO_LIVE_LAUNCH=1: start one tiny Codex chat and one Claude background session, then remove them.
    func testLiveLaunchBothAgents() throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_LAUNCH"] == "1" else { throw XCTSkip("set BURRO_LIVE_LAUNCH=1") }
        let prompt = "Reply with just the word OK. Do not use any tools or run any commands."
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("burro-launch-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let codex = try CodexLaunch.start(LaunchRequest(provider: .codex, prompt: prompt, folder: scratch.path,
                                                        model: "gpt-6-luna", effort: "low", access: .readOnly))
        XCTAssertNotNil(UUID(uuidString: codex.sessionID))
        XCTAssertEqual(codex.chatURL?.absoluteString, "codex://threads/\(codex.sessionID)")
        let executable = try XCTUnwrap(CodexUsageReader.executable())
        let server = try CodexAppServer.connect(executable: executable)
        defer { _ = try? server.request("thread/archive", ["threadId": codex.sessionID]); server.close() }
        var status = ""
        for _ in 0..<30 {
            let thread = try server.request("thread/read", ["threadId": codex.sessionID, "includeTurns": true])
            let turns = (thread["thread"] as? [String: Any])?["turns"] as? [[String: Any]] ?? []
            status = turns.last?["status"] as? String ?? ""
            if status == "completed" { break }
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertEqual(status, "completed", "the Codex turn keeps running after Burro disconnects")

        let burro = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let claude = try ClaudeLaunch.start(LaunchRequest(provider: .claude, prompt: prompt, folder: burro.path,
                                                          model: "claude-haiku-5-5", effort: "low", access: .readOnly))
        let handle = try XCTUnwrap(claude.handle)
        defer { _ = try? LaunchShell.run(ClaudeLaunch.executable()!, ["rm", handle], folder: burro.path, timeout: 30) }
        XCTAssertTrue(claude.sessionID.hasPrefix(handle))
        XCTAssertNotEqual(claude.sessionID, handle, "the full session id resolves from claude agents")
    }
}
