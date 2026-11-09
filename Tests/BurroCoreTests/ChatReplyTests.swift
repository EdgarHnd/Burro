// Check reply options map onto each agent's own controls, media links and file checks, the
// fixed remote scripts' refusals, and (opt-in) a real reply and remote media copy.
import XCTest
@testable import Burro
@testable import BurroCore

final class ChatReplyTests: XCTestCase {
    private let id = "11111111-2222-4333-8444-555555555555"
    private func session(_ provider: AgentProvider, state: AgentState = .idle, remote: Bool = false) -> AgentSession {
        var value = AgentSession(id: "\(provider == .codex ? "codex" : "claude"):\(id)", provider: provider, title: "x", cwd: "/tmp",
                                 state: state, updatedAt: Date(), evidence: "fixture")
        if remote {
            let host = UUID()
            value.remote = RemoteOrigin(hostID: host, hostName: "devbox", sampledAt: Date(), stale: false)
            value.id = "remote:\(host.uuidString):\(value.id)"
        }
        return value
    }

    func testCodexTurnsCarryOnlyTheChosenOverrides() {
        let keep = ChatReply.codexTurnParams(threadID: id, ReplyRequest(text: "  go on  "))
        XCTAssertEqual(keep["threadId"] as? String, id)
        XCTAssertEqual((keep["input"] as? [[String: Any]])?.first?["text"] as? String, "go on")
        XCTAssertNil(keep["approvalPolicy"]); XCTAssertNil(keep["model"]); XCTAssertNil(keep["sandboxPolicy"])
        let auto = ChatReply.codexTurnParams(threadID: id, ReplyRequest(text: "x", model: "gpt-6.1-sol", effort: "xhigh", access: .approveForMe))
        XCTAssertEqual(auto["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(auto["effort"] as? String, "xhigh")
        XCTAssertEqual(auto["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(auto["approvalsReviewer"] as? String, "auto_review")
        let readOnly = ChatReply.codexTurnParams(threadID: id, ReplyRequest(text: "x", access: .readOnly))
        XCTAssertEqual((readOnly["sandboxPolicy"] as? [String: String])?["type"], "readOnly")
        XCTAssertEqual(ChatReply.codexTurnParams(threadID: id, ReplyRequest(text: "x", access: .edit))["approvalPolicy"] as? String, "never")
    }

    func testClaudeResumesInTheBackgroundWithTheMessageAfterDashes() {
        XCTAssertEqual(ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "--help me")), ["--bg", "--resume", id, "--", "--help me"])
        XCTAssertEqual(ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "x", model: "claude-opus-5-5", effort: "max", access: .edit)),
                       ["--bg", "--resume", id, "--permission-mode", "acceptEdits", "--model", "claude-opus-5-5", "--effort", "max", "--", "x"])
        XCTAssertEqual(ChatReply.claudeArguments(sessionID: id, ReplyRequest(text: "x", model: "opus; rm -rf ~", access: .readOnly)),
                       ["--bg", "--resume", id, "--permission-mode", "plan", "--", "x"], "Odd model names are dropped")
        XCTAssertFalse(ReplyAccess.options(for: .claude).contains(.approveForMe))
    }

    func testRepliesAreRefusedWhenTheyCantReachTheChat() {
        XCTAssertNil(ChatReply.unavailable(session(.codex, state: .working), host: nil), "Codex steers a running turn")
        XCTAssertNotNil(ChatReply.unavailable(session(.claude, state: .working), host: nil), "Claude would fork a busy session")
        XCTAssertNotNil(ChatReply.unavailable(session(.codex, remote: true), host: nil), "A remote chat needs its machine")
        var odd = session(.codex); odd.id = "codex:not-a-uuid"
        XCTAssertNotNil(ChatReply.unavailable(odd, host: nil))
        XCTAssertThrowsError(try ChatReply.send(ReplyRequest(text: "   "), to: session(.codex), host: nil))
    }

    func testClaudeRepliesOnlyContinueSessionsNothingHasOpen() {
        let rows = Data("""
        [{"id":"c0d2240d","sessionId":"\(id)","kind":"background","status":"idle"},
         {"sessionId":"22222222-3333-4444-8555-666666666666","kind":"interactive","status":"idle"},
         {"id":"aaaa1111","sessionId":"33333333-4444-4555-8666-777777777777","kind":"background","status":"busy"},
         {"id":"$(rm -rf)","sessionId":"44444444-5555-4666-8777-888888888888","kind":"background","status":"idle"}]
        """.utf8)
        func plan(_ session: String) -> ChatReply.ClaudeCheck { ChatReply.claudePlan(ChatReply.claudeLive(session, rows: rows)) }
        XCTAssertNotNil(plan(id).problem, "An open background session would fork; Burro never stops it")
        XCTAssertEqual(plan(id).attach, "c0d2240d")
        XCTAssertNotNil(plan("22222222-3333-4444-8555-666666666666").problem)
        XCTAssertNil(plan("22222222-3333-4444-8555-666666666666").attach)
        XCTAssertNotNil(plan("33333333-4444-4555-8666-777777777777").problem)
        XCTAssertNil(plan("44444444-5555-4666-8777-888888888888").attach, "Odd handles are never passed on")
        XCTAssertEqual(plan("55555555-6666-4777-8888-999999999999"), ChatReply.ClaudeCheck(), "Not open anywhere: resume directly")
    }

    func testRemoteCodexProblemsAreSpelledOut() {
        XCTAssertEqual(CodexAppServer.remoteProblem("devbox", output: "", reachable: false), "Couldn't reach devbox over SSH.")
        XCTAssertEqual(CodexAppServer.remoteProblem("devbox", output: "NO_CODEX\n", reachable: true), "Codex isn't installed on devbox.")
        XCTAssertTrue(CodexAppServer.remoteProblem("devbox", output: "Error: managed standalone Codex install not found", reachable: true).contains("install.sh"))
        XCTAssertEqual(CodexAppServer.remoteProblem("devbox", output: "boom\n", reachable: true), "Couldn't reach Codex on devbox: boom")
    }

    func testMediaLinksBecomeBlocks() {
        XCTAssertEqual(MarkdownBlock.blocks("Before\n![Front and side](/tmp/run/final.mp4)\nAfter"),
                       [.paragraph("Before"), .media("Front and side", "/tmp/run/final.mp4"), .paragraph("After")])
        XCTAssertEqual(MarkdownBlock.blocks("See ![a](/x/a.png) and ![b](file:///x/b%20c.jpg)"),
                       [.paragraph("See  and"), .media("a", "/x/a.png"), .media("b", "/x/b c.jpg")])
        XCTAssertEqual(MarkdownBlock.blocks("![remote](https://example.com/a.png) ![doc](/x/notes.pdf)"),
                       [.paragraph("![remote](https://example.com/a.png) ![doc](/x/notes.pdf)")], "Only local images and videos load")
    }

    func testLocalMediaChecks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("shot.png"), secret = folder.appendingPathComponent("id_ed25519")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data("key".utf8).write(to: secret)
        let disguised = folder.appendingPathComponent("innocent.png")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: secret)
        XCTAssertEqual(try ChatMedia.local(image.path).lastPathComponent, "shot.png")
        XCTAssertThrowsError(try ChatMedia.local(secret.path))
        XCTAssertThrowsError(try ChatMedia.local(disguised.path), "Links are judged by what they point at")
        XCTAssertThrowsError(try ChatMedia.local("relative.png"))
        XCTAssertThrowsError(try ChatMedia.local(folder.appendingPathComponent("gone.png").path))
    }

    /// Runs a bundled remote script locally the way Burro sends it over SSH.
    private func script(_ name: String, _ request: [String: Any], home: URL) throws -> (status: Int32, out: Data, err: String) {
        let body = try Data(contentsOf: try XCTUnwrap(RemoteScript.url(name)))
        var input = Data("REQUEST_B64 = \"\(try JSONSerialization.data(withJSONObject: request).base64EncodedString())\"\n".utf8)
        input.append(body)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, out, err)
    }

    func testRemoteMediaScriptSendsOnlyMediaFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rmedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let image = home.appendingPathComponent("a.png"), key = home.appendingPathComponent("id_rsa"), link = home.appendingPathComponent("b.png")
        try Data(repeating: 7, count: 3000).write(to: image)
        try Data("secret".utf8).write(to: key)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        let ok = try script("remote_media", ["path": image.path, "max": 10_000], home: home)
        XCTAssertEqual(ok.status, 0); XCTAssertEqual(ok.out, try Data(contentsOf: image))
        XCTAssertEqual(try script("remote_media", ["path": key.path, "max": 10_000], home: home).status, 2)
        XCTAssertEqual(try script("remote_media", ["path": link.path, "max": 10_000], home: home).status, 2)
        XCTAssertEqual(try script("remote_media", ["path": image.path, "max": 100], home: home).status, 3)
        XCTAssertEqual(try script("remote_media", ["path": "a.png", "max": 100], home: home).status, 2)
    }

    func testRemoteReplyScriptRunsOnlyTheFixedCommand() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rreply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        for args in [["--bg", "--resume", "not-a-uuid", "--", "x"],
                     ["--bg", "--resume", id, "--dangerously-skip-permissions", "--", "x"],
                     ["--bg", "--resume", id, "--permission-mode", "bypassPermissions", "--", "x"],
                     ["--bg", "--resume", id, "--model", "a b", "--", "x"],
                     ["--bg", "--resume", id, "x"],
                     ["--print", "--resume", id, "--", "x"]] {
            let result = try script("remote_reply", ["args": args, "cwd": "/tmp"], home: home)
            let object = try JSONSerialization.jsonObject(with: result.out) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, false, "\(args)")
            XCTAssertTrue((object?["error"] as? String)?.contains("won't run") == true, "\(args)")
        }
    }

    // MARK: Live (opt-in)

    /// A throwaway plan-mode Claude conversation in this repository (Claude only runs in trusted
    /// folders): one headless turn, then a reply through Burro's path, which continues it in the
    /// background under the same id. Removed with its transcript afterwards.
    func testLiveClaudeReply() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_CLAUDE_REPLY"] == "1" else { throw XCTSkip("set BURRO_LIVE_CLAUDE_REPLY=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let claude = try XCTUnwrap(ClaudeLaunch.executable())
        let id = UUID().uuidString.lowercased()
        addTeardownBlock {
            // Only this test's own session, matched by its id.
            if let live = ChatReply.claudeLive(id, claude: claude), let handle = live.handle {
                _ = try? LaunchShell.run(claude, ["rm", handle], folder: root.path, timeout: 20)
            }
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
                try? FileManager.default.removeItem(at: projects.appendingPathComponent(folder).appendingPathComponent("\(id).jsonl"))
            }
        }
        let first = try LaunchShell.run(claude, ["-p", "--session-id", id, "--permission-mode", "plan", "--", "Reply with exactly the word: first. Use no tools."],
                                        folder: root.path, timeout: 180)
        XCTAssertEqual(first.code, 0, first.text)
        let chat = AgentSession(id: "claude:" + id, provider: .claude, title: "live", cwd: root.path, state: .idle, updatedAt: Date(), evidence: "live")
        func answers() -> [String] {
            ((try? ChatTranscripts.load(chatID: chat.id, hosts: [])).map { $0.messages.filter { $0.kind == .assistant }.map(\.text) }) ?? []
        }
        func wait(for word: String) async throws {
            for _ in 0..<60 {
                if answers().contains(where: { $0.localizedCaseInsensitiveContains(word) }) { return }
                try await Task.sleep(for: .seconds(2))
            }
            XCTFail("No \(word) in \(answers())")
        }
        try await wait(for: "first")
        XCTAssertNil(ChatReply.claudeCheck(chat, host: nil).problem, "A closed session can take a reply")
        let confirmation = try ChatReply.send(ReplyRequest(text: "Now reply with exactly the word: second. Use no tools.", access: .readOnly), to: chat, host: nil)
        XCTAssertTrue(confirmation.hasPrefix("Sent"), confirmation)
        XCTAssertFalse(confirmation.contains("copy"), "Continues the same session")
        try await wait(for: "second")
    }

    /// Starts a throwaway read-only Codex chat, replies to it through Burro's reply path, checks the
    /// answer lands, then archives the thread. Also lists Codex models and copies one media file
    /// from a remote chat when a machine is configured.
    func testLiveReplyAndRemoteMedia() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_REPLY"] == "1" else { throw XCTSkip("set BURRO_LIVE_REPLY=1") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-reply-live-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let started = try CodexLaunch.start(LaunchRequest(provider: .codex, prompt: "Reply with exactly the word: first", folder: folder.path, access: .readOnly))
        let chat = AgentSession(id: "codex:" + started.sessionID.lowercased(), provider: .codex, title: "live", cwd: folder.path, state: .idle,
                                updatedAt: Date(), evidence: "live")
        addTeardownBlock {
            if let executable = CodexUsageReader.executable(), let server = try? CodexAppServer.connect(executable: executable) {
                _ = try? server.request("thread/archive", ["threadId": started.sessionID]); server.close()
            }
        }
        func answers() -> [String] {
            ((try? ChatTranscripts.load(chatID: chat.id, hosts: [])).map { $0.messages.filter { $0.kind == .assistant }.map(\.text) }) ?? []
        }
        func wait(for word: String) async throws {
            for _ in 0..<60 {
                if answers().contains(where: { $0.localizedCaseInsensitiveContains(word) }) { return }
                try await Task.sleep(for: .seconds(2))
            }
            XCTFail("No \(word) in \(answers())")
        }
        try await wait(for: "first")
        let confirmation = try ChatReply.send(ReplyRequest(text: "Now reply with exactly the word: second", access: .readOnly), to: chat, host: nil)
        XCTAssertTrue(confirmation.hasPrefix("Sent"))
        try await wait(for: "second")

        guard let state = Orchestrator.readState(), let host = state.hosts.first(where: \.enabled) else { return }
        do {
            let models = try ChatReply.codexModels(host: host)
            XCTAssertFalse(models.isEmpty, "Codex models over SSH")
        } catch {
            // A machine without Codex's standalone install can't take replies; Burro must say why.
            let reason = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(reason.contains(host.name), reason)
            print("Remote Codex replies unavailable on \(host.name): \(reason)")
        }
        for remote in state.chats where remote.remote?.hostID == host.id && remote.provider == .codex {
            guard let transcript = try? ChatTranscripts.load(chatID: remote.id, hosts: state.hosts, limit: 120) else { continue }
            let links = transcript.messages.filter { $0.kind == .assistant }.flatMap { message in
                MarkdownBlock.blocks(message.text).compactMap { block -> String? in if case .media(_, let path) = block { path } else { nil } }
            }
            guard let path = links.first(where: { ChatMedia.kind(of: $0) == .image }) ?? links.first else { continue }
            let copy = try ChatMedia.remote(path, host: host)
            XCTAssertGreaterThan((try copy.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, 0)
            try? FileManager.default.removeItem(at: copy)
            return
        }
    }
}
