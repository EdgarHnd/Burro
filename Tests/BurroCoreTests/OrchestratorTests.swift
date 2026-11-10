// Check the orchestrator's stream parsing, its tool server, chat ids, and that the local (Rust)
// and remote (Python over SSH) transcript readers agree.
import XCTest
@testable import BurroCore

final class OrchestratorTests: XCTestCase {
    private let chatID = "11111111-2222-4333-8444-555555555555"
    private let otherID = "22222222-3333-4444-8555-666666666666"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-orchestrator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func session(_ id: String, _ title: String, state: AgentState, cwd: String = "/Dev/focustown", minutesAgo: Double = 1,
                         remote: (UUID, String)? = nil) -> AgentSession {
        var value = AgentSession(id: id, provider: id.contains("codex:") ? .codex : .claude, title: title, cwd: cwd, state: state,
                                 updatedAt: Date().addingTimeInterval(-minutesAgo * 60), evidence: "fixture")
        if let remote {
            value.remote = RemoteOrigin(hostID: remote.0, hostName: remote.1, sampledAt: Date(), stale: false)
            value.id = "remote:\(remote.0.uuidString):\(id)"
        }
        return value
    }
    private func state(chats: [AgentSession], hosts: [RemoteHost] = []) -> OrchestratorState {
        OrchestratorState(
            mainProject: "/Dev/focustown",
            machines: [.init(id: "local", name: "This Mac", connection: "this Mac", lastSeen: Date(), os: "macOS 27", versions: ["claude": "2.1.317"])],
            projects: [.init(name: "focustown", path: "/Dev/focustown", isRepository: true, worktrees: 3, readyToRemove: 1, tokensToday: 2_400_000, lastActive: Date()),
                       .init(name: "Burro", path: "/Dev/Burro", isRepository: true, worktrees: 1, readyToRemove: 0, tokensToday: 0, lastActive: nil)],
            chats: chats,
            worktrees: [.init(path: "/Dev/focustown", repository: "focustown", repositoryPath: "/Dev/focustown", branch: "main", isPrimary: true,
                              changed: 2, untracked: 1, unpushed: 3, lastCommit: Date(), activity: "Working", readyToRemove: false),
                        .init(path: "/Dev/focustown-wt/login", repository: "focustown", repositoryPath: "/Dev/focustown", branch: "fix-login", isPrimary: false,
                              changed: 0, untracked: 0, unpushed: 0, lastCommit: Date(), activity: "Idle", readyToRemove: true)],
            todos: [.init(text: "Ship the season pass", done: false, day: TodoDay.key(), project: nil)],
            hosts: hosts, profiles: [:])
    }
    private func tools(_ state: OrchestratorState) throws -> OrchestratorTools {
        let url = try folder().appendingPathComponent("state.json")
        try JSONEncoder.orchestrator.encode(state).write(to: url)
        return OrchestratorTools(stateURL: url)
    }

    // MARK: Stream

    func testStreamEventsReduceToWhatTheChatShows() {
        func parse(_ json: String) -> [OrchestratorEvent] { OrchestratorEvent.parse(Data(json.utf8)) }
        XCTAssertEqual(parse(#"{"type":"system","subtype":"init","session_id":"abc"}"#), [.started(sessionID: "abc")])
        XCTAssertEqual(parse(#"{"type":"system","subtype":"hook_started"}"#), [])
        XCTAssertEqual(parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#), [.textDelta("Hel")])
        XCTAssertEqual(parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"x"}}}"#), [])
        XCTAssertEqual(parse(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello"},{"type":"tool_use","id":"t1","name":"mcp__burro__read_chat","input":{"id":"claude:x"}}]}}"#),
                       [.text("Hello"), .tool(id: "t1", name: "read_chat", summary: "claude:x")])
        XCTAssertEqual(parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"  ok  "}]}]}}"#),
                       [.toolResult(id: "t1", output: "ok")])
        XCTAssertEqual(parse(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"abc"}"#),
                       [.finished(isError: false, message: nil, sessionID: "abc")])
        XCTAssertEqual(parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#),
                       [.finished(isError: true, message: "boom", sessionID: nil)])
        XCTAssertEqual(parse("not json"), [])
    }

    func testTurnArgumentsAllowOnlyBurroAndReadOnlyTools() {
        let config = URL(fileURLWithPath: "/tmp/mcp.json")
        let first = Orchestrator.arguments(sessionID: chatID, resume: false, mcpConfig: config)
        XCTAssertEqual(first.suffix(2), ["--session-id", chatID])
        XCTAssertEqual(Orchestrator.arguments(sessionID: chatID, resume: true, mcpConfig: config).suffix(2), ["--resume", chatID])
        func value(_ flag: String) -> String? { first.firstIndex(of: flag).map { first[$0 + 1] } }
        XCTAssertEqual(value("--model"), "claude-fable-5-2")
        XCTAssertEqual(value("--effort"), "high", "High by default")
        func effort(_ level: String) -> String? {
            let args = Orchestrator.arguments(sessionID: chatID, resume: true, mcpConfig: config, effort: level)
            return args.firstIndex(of: "--effort").map { args[$0 + 1] }
        }
        XCTAssertEqual(effort("max"), "max")
        XCTAssertEqual(effort("ludicrous"), "high", "Unknown levels fall back to the default")
        XCTAssertEqual(value("--allowedTools"), "mcp__burro,Read,Grep,Glob")
        XCTAssertTrue(value("--disallowedTools")?.contains("Bash") == true)
        XCTAssertTrue(first.contains("--strict-mcp-config"))
        XCTAssertFalse(first.contains { $0.contains("bypass") || $0.contains("dangerously") })
    }

    func testOwnFolderIsRecognised() {
        let root = Orchestrator.folder.path
        XCTAssertTrue(Orchestrator.owns(folder: root))
        XCTAssertTrue(Orchestrator.owns(folder: root + "/sub"))
        XCTAssertFalse(Orchestrator.owns(folder: root + "-other"))
        XCTAssertFalse(Orchestrator.owns(folder: nil))
        var mine = session("claude:\(chatID)", "Orchestrator", state: .idle, cwd: root)
        XCTAssertTrue(Orchestrator.owns(mine))
        mine.remote = RemoteOrigin(hostID: UUID(), hostName: "Other", sampledAt: Date(), stale: false)
        XCTAssertFalse(Orchestrator.owns(mine), "A remote chat is never the orchestrator")
    }

    // MARK: Tool server

    func testServerSpeaksMCP() throws {
        let tools = try tools(state(chats: []))
        let initialize = tools.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        XCTAssertEqual((initialize?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(tools.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let list = tools.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["overview", "list_chats", "read_chat", "list_worktrees", "start_chat"])
        let unknown = tools.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let call = tools.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "overview", "arguments": [String: Any]()]])
        let content = (call?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertTrue((content?.first?["text"] as? String)?.contains("Main project: focustown") == true)
    }

    func testOverviewLeadsWithWhatNeedsYou() throws {
        let host = UUID()
        let chats = [
            session("claude:\(chatID)", "Fix login", state: .waiting),
            session("codex:\(otherID)", "Season pass", state: .working, cwd: "/home/edgar/focustown", remote: (host, "devbox")),
            session("claude:33333333-4444-4555-8666-777777777777", "Old idea", state: .idle, minutesAgo: 60 * 30),
        ]
        let text = try tools(state(chats: chats)).overview(state(chats: chats))
        let needs = try XCTUnwrap(text.range(of: "## Needs you (1)")), working = try XCTUnwrap(text.range(of: "## Working (1)"))
        XCTAssertLessThan(needs.lowerBound, working.lowerBound)
        XCTAssertTrue(text.contains("Fix login — Claude Code on This Mac, focustown · needs you"))
        XCTAssertTrue(text.contains("Season pass — Codex on devbox"))
        XCTAssertTrue(text.contains("id remote:\(host.uuidString):codex:\(otherID)"))
        XCTAssertFalse(text.contains("Old idea"), "Idle chats older than a day stay out of the overview")
        XCTAssertTrue(text.contains("claude 2.1.317"))
        XCTAssertTrue(text.contains("3 worktrees (1 safe to clean)"))
        XCTAssertTrue(text.contains("- [ ] Ship the season pass"))
    }

    func testListChatsFilters() throws {
        let host = UUID()
        var sub = session("claude:44444444-5555-4666-8777-888888888888", "Subagent", state: .working)
        sub.isSubagent = true; sub.parentSessionID = "claude:\(chatID)"
        let chats = [session("claude:\(chatID)", "Fix login", state: .waiting, cwd: "/Dev/focustown-wt/login"),
                     session("codex:\(otherID)", "Season pass", state: .working, cwd: "/home/edgar/focustown", remote: (host, "devbox")),
                     session("claude:55555555-6666-4777-8888-999999999999", "Burro polish", state: .idle, cwd: "/Dev/Burro"), sub]
        let value = state(chats: chats), tools = try tools(value)
        let waiting = tools.listChats(value, ["status": "needs_you"])
        XCTAssertTrue(waiting.contains("Fix login") && !waiting.contains("Season pass"))
        XCTAssertTrue(waiting.contains("1 subagents (1 working)"))
        let devbox = tools.listChats(value, ["machine": "DEVBOX"])
        XCTAssertTrue(devbox.contains("Season pass") && !devbox.contains("Fix login"))
        let focustown = tools.listChats(value, ["project": "focustown"])
        XCTAssertTrue(focustown.contains("Fix login") && focustown.contains("Season pass") && !focustown.contains("Burro polish"),
                      "Worktrees of the project and remote folders named like it both count")
        XCTAssertFalse(tools.listChats(value, [:]).contains("- Subagent"))
        XCTAssertTrue(tools.listChats(value, ["include_subagents": true]).contains("- Subagent"))
        XCTAssertTrue(tools.listChats(value, ["query": "nothing like this"]).contains("No chats match."))
    }

    func testReadChatResolvesIdsAndFormatsMessages() throws {
        let chats = [session("claude:\(chatID)", "Fix login", state: .waiting)]
        let value = state(chats: chats)
        var tools = try tools(value)
        var requested: String?
        tools.readChat = { id, _, _, limit in
            requested = id
            XCTAssertEqual(limit, 60)
            return ChatTranscript(messages: [
                ChatMessage(id: 0, kind: .user, text: "Fix the login bug"),
                ChatMessage(id: 1, kind: .tool, text: "npm test", tool: "Bash", output: "2 failing\nmore"),
                ChatMessage(id: 2, kind: .assistant, text: "Fixed; tests pass."),
            ], truncated: true, title: "Login fix")
        }
        let (text, isError) = tools.readChat(value, ["id": chatID])
        XCTAssertFalse(isError)
        XCTAssertEqual(requested, "claude:\(chatID)", "A bare UUID resolves to the full chat id")
        XCTAssertTrue(text.hasPrefix("# Login fix"))
        XCTAssertTrue(text.contains("[tool Bash] npm test → 2 failing more"))
        XCTAssertTrue(text.contains("Older messages not shown"))
        tools.readChat = { _, _, _, _ in throw ChatTranscripts.LoadError.notFound }
        XCTAssertTrue(tools.readChat(value, ["id": chatID]).1)
        XCTAssertTrue(tools.readChat(value, [:]).1)
    }

    func testStartChatResolvesProjectsAndRefusesUnknownFolders() throws {
        let root = try folder()
        let project = root.appendingPathComponent("focustown")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var value = state(chats: [])
        value.projects = [.init(name: "focustown", path: project.path, isRepository: true, worktrees: 1, readyToRemove: 0, tokensToday: 0, lastActive: nil)]
        var tools = try tools(value)
        var launched: LaunchRequest?
        tools.launch = { request in
            launched = request
            return LaunchResult(provider: request.provider, sessionID: self.chatID.uppercased(), handle: nil, folder: request.folder)
        }
        let (text, isError) = tools.startChat(["agent": "claude", "folder": "FocusTown", "prompt": "Fix the login bug"])
        XCTAssertFalse(isError, text)
        XCTAssertEqual(launched?.folder, project.path)
        XCTAssertEqual(launched?.access, .ask, "Started chats ask before acting unless told otherwise")
        XCTAssertTrue(text.contains("claude:\(chatID)"))
        launched = nil
        XCTAssertTrue(tools.startChat(["agent": "claude", "folder": "/definitely/not/here", "prompt": "x"]).1)
        XCTAssertTrue(tools.startChat(["agent": "grok", "folder": "focustown", "prompt": "x"]).1)
        XCTAssertTrue(tools.startChat(["agent": "codex", "folder": "focustown", "prompt": "  "]).1)
        XCTAssertNil(launched)
    }

    /// A launch that didn't really start reaches the orchestrator as an error, never as "Started".
    func testStartChatReportsALaunchThatDidNotStart() throws {
        let root = try folder()
        let project = root.appendingPathComponent("focustown-rn-godot")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var value = state(chats: [])
        value.projects = [.init(name: "focustown-rn-godot", path: project.path, isRepository: true, worktrees: 1, readyToRemove: 0, tokensToday: 0, lastActive: nil)]
        var tools = try tools(value)
        var launched: LaunchRequest?
        tools.launch = { request in
            launched = request
            throw LaunchError.blocked(folder: request.folder, reason: "approve 1 new project MCP server (focustown-insights)")
        }
        let (text, isError) = tools.startChat(["agent": "claude", "folder": "focustown-rn-godot", "prompt": "Fix it",
                                               "model": "claude-opus-5-5", "effort": "medium", "access": "edit"])
        XCTAssertTrue(isError)
        XCTAssertFalse(text.contains("Started"), text)
        XCTAssertTrue(text.contains("did not start") && text.contains("focustown-insights"), text)
        XCTAssertEqual(launched?.effort, "medium", "the effort the orchestrator asks for reaches the launch")
        XCTAssertEqual(launched?.model, "claude-opus-5-5")
        let reply = tools.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                  "params": ["name": "start_chat", "arguments": ["agent": "claude", "folder": project.path, "prompt": "Fix it"]]])
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testMissingSnapshotIsAnError() {
        let tools = OrchestratorTools(stateURL: URL(fileURLWithPath: "/nonexistent/state.json"))
        let (text, isError) = tools.call("overview", [:])
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("Open Burro"))
    }

    func testSnapshotRoundTripsThroughDisk() throws {
        let value = state(chats: [session("claude:\(chatID)", "Fix login", state: .waiting)])
        let url = try folder().appendingPathComponent("state.json")
        try JSONEncoder.orchestrator.encode(value).write(to: url)
        let read = try XCTUnwrap(Orchestrator.readState(from: url))
        XCTAssertEqual(read.chats.map(\.id), value.chats.map(\.id))
        XCTAssertEqual(read.mainProject, "/Dev/focustown")
    }

    /// One real Opus 5.5 turn against the real tool server, in a throwaway folder.
    func testLiveTurnCallsBurroTools() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_ORCHESTRATOR"] == "1" else { throw XCTSkip("set BURRO_LIVE_ORCHESTRATOR=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = root.appendingPathComponent(".build/debug/burro-mcp")
        let claude = try XCTUnwrap(ClaudeLaunch.executable())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-orchestrator-live-\(UUID().uuidString)").resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let config = try Orchestrator.prepare(toolServer: server, in: folder)
        try JSONEncoder.orchestrator.encode(state(chats: [session("claude:\(chatID)", "Fix login", state: .waiting)])).write(to: folder.appendingPathComponent("state.json"))
        let id = UUID().uuidString.lowercased()
        addTeardownBlock { [folder] in
            // Remove only this test's transcript folder.
            let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let unique = folder.lastPathComponent.replacingOccurrences(of: "burro-orchestrator-live-", with: "")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] where name.hasSuffix("burro-orchestrator-live-" + unique) {
                try? FileManager.default.removeItem(at: projects.appendingPathComponent(name))
            }
        }
        let turn = try OrchestratorTurn(executable: claude, arguments: Orchestrator.arguments(sessionID: id, resume: false, mcpConfig: config),
                                        prompt: "Call the overview tool, then reply with only the name of the main project and the title of the chat that needs me.",
                                        folder: folder)
        var tools: [String] = [], text = "", finished: OrchestratorEvent?
        for await event in turn.events {
            switch event {
            case .tool(_, let name, _): tools.append(name)
            case .text(let value): text += value
            case .finished: finished = event
            default: break
            }
        }
        turn.waitUntilExit()
        XCTAssertEqual(finished, .finished(isError: false, message: nil, sessionID: id), turn.errorOutput)
        XCTAssertTrue(tools.contains("overview"), "tools: \(tools)")
        // The app reloads history by this id, so the transcript must be saved under it.
        let saved = try ChatTranscripts.load(chatID: "claude:" + id, hosts: [])
        XCTAssertEqual(saved.messages.first?.kind, .user)
        XCTAssertTrue(saved.messages.contains { $0.kind == .tool && $0.tool == "overview" })
        XCTAssertTrue(text.localizedCaseInsensitiveContains("focustown"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Fix login"), text)
    }

    // MARK: Chat ids and transcripts

    func testChatIdentities() {
        let host = UUID()
        XCTAssertEqual(ChatTranscripts.identity(chatID: "claude:\(chatID.uppercased())")?.id, chatID)
        XCTAssertNil(ChatTranscripts.identity(chatID: "claude:\(chatID)")?.host)
        let remote = ChatTranscripts.identity(chatID: "remote:\(host.uuidString):codex:\(chatID)")
        XCTAssertEqual(remote?.host, host)
        XCTAssertEqual(remote?.provider, "codex")
        XCTAssertNil(ChatTranscripts.identity(chatID: "grok:\(chatID)"))
        XCTAssertNil(ChatTranscripts.identity(chatID: "claude:not-a-uuid"))
        XCTAssertNil(ChatTranscripts.identity(chatID: "remote:nope:claude:\(chatID)"))
        XCTAssertNil(ChatTranscripts.identity(chatID: "claude:\(chatID); rm -rf /"))
        var value = session("claude:\(chatID)", "x", state: .idle, remote: (host, "devbox"))
        XCTAssertEqual(ChatTranscripts.identity(of: value)?.id, chatID)
        value.remote?.hostID = UUID()
        XCTAssertNil(ChatTranscripts.identity(of: value), "The id's machine must match the session's")
    }

    func testRemoteBatchesAreBounded() throws {
        func batch(_ json: String) throws -> TranscriptBatch { try JSONDecoder().decode(TranscriptBatch.self, from: Data(json.utf8)) }
        XCTAssertTrue(try batch(#"{"found":true,"messages":[{"kind":"user","text":"hi"}]}"#).valid(for: 10))
        XCTAssertFalse(try batch(#"{"found":true,"messages":[{"kind":"user","text":"a"},{"kind":"user","text":"b"}]}"#).valid(for: 1))
        let long = String(repeating: "x", count: 13_000)
        XCTAssertFalse(try batch(#"{"found":true,"messages":[{"kind":"assistant","text":"\#(long)"}]}"#).valid(for: 10))
        XCTAssertThrowsError(try batch(#"{"found":true,"messages":[{"kind":"system","text":"x"}]}"#))
        XCTAssertNil(try batch(#"{"found":false}"#).transcript)
    }

    /// The Rust reader (this Mac) and the Python reader (other machines) must show the same messages.
    func testLocalAndRemoteReadersAgree() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            if ProcessInfo.processInfo.environment["BURRO_REQUIRE_RUST_WORKER"] == "1" { XCTFail("Required Rust helper missing") }
            throw XCTSkip("Build the Rust worker")
        }
        let home = try folder()
        let claude = home.appendingPathComponent(".claude/projects/-Dev-focustown")
        let codex = home.appendingPathComponent(".codex/sessions/2026/11/09")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let claudeLines = [
            #"{"type":"custom-title","customTitle":"Login fix"}"#,
            #"{"type":"user","cwd":"/Dev/focustown","timestamp":"2026-11-09T10:00:00Z","message":{"content":"Fix the login bug"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-09T10:00:05Z","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"2 failing"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"side"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed."}]}}"#,
        ]
        try claudeLines.joined(separator: "\n").write(to: claude.appendingPathComponent("\(chatID).jsonl"), atomically: true, encoding: .utf8)
        let codexLines = [
            #"{"type":"session_meta","payload":{"cwd":"/Dev/focustown"}}"#,
            ##"{"type":"response_item","timestamp":"2026-11-09T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Ship it"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"c1","arguments":"{\"cmd\":[\"git\",\"status\"]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"clean"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Shipped."}]}}"#,
        ]
        try codexLines.joined(separator: "\n").write(to: codex.appendingPathComponent("rollout-2026-11-09T10-00-00-\(otherID).jsonl"), atomically: true, encoding: .utf8)

        let worker = AgentLogWorker(executable: executable)
        addTeardownBlock { worker.stop() }
        let script = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "remote_transcript", withExtension: "py")), encoding: .utf8)
        for (provider, id, roots) in [("claude", chatID, [home.appendingPathComponent(".claude/projects").path]),
                                      ("codex", otherID, [home.appendingPathComponent(".codex/sessions").path])] {
            let local = try XCTUnwrap(worker.exchange([], transcript: TranscriptRequest(provider: provider, id: id, roots: roots, limit: 50))?.transcript?.transcript)
            let line = "REQUEST = {\"provider\": \"\(provider)\", \"id\": \"\(id)\", \"limit\": 50}\n"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-"]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data((line + script).utf8)); try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let batch = try JSONDecoder().decode(TranscriptBatch.self, from: data)
            XCTAssertTrue(batch.valid(for: 50))
            let remote = try XCTUnwrap(batch.transcript)
            func shape(_ t: ChatTranscript) -> [String] { t.messages.map { "\($0.kind.rawValue)|\($0.text)|\($0.tool ?? "")|\($0.output ?? "")" } }
            XCTAssertEqual(shape(local), shape(remote), provider)
            XCTAssertEqual(local.title, remote.title, provider)
            XCTAssertEqual(local.folder, "/Dev/focustown", provider)
            XCTAssertEqual(remote.folder, "/Dev/focustown", provider)
        }
        let claudeShape = try XCTUnwrap(worker.exchange([], transcript: TranscriptRequest(provider: "claude", id: chatID, roots: [home.appendingPathComponent(".claude/projects").path], limit: 50))?.transcript?.transcript)
        XCTAssertEqual(claudeShape.messages.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(claudeShape.messages[2].output, "2 failing")
        XCTAssertEqual(claudeShape.title, "Login fix")
    }
}

extension JSONEncoder {
    static var orchestrator: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}
