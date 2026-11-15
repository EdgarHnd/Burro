// Starting chats on another machine, proven locally: the fixed scripts run under a temporary HOME
// with a fake `claude` on PATH (never a real one, never SSH). Covers the argument allow-list, folder
// checks, trust (untrusted launches nothing), a session blocked at a prompt (stop and rm for that
// handle only), a `claude` whose background child holds stdout (both scripts still return promptly),
// the Swift decision on the evidence, the folder lister, the Codex path, and the SSH call shape.
import Darwin
import XCTest
@testable import BurroCore

final class RemoteLaunchTests: XCTestCase {
    private let sid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let host = RemoteHost(name: "Studio", destination: "me@studio")

    // MARK: Fixtures

    /// A temporary HOME with a project folder and a fake `claude` in ~/.local/bin that logs every call
    /// and acts out `scenario`.
    private func makeHome(scenario: String, trusted: Bool = true) throws -> (home: URL, project: URL) {
        // The real path (/private/var/…), as the scripts' realpath sees it.
        let base = URL(fileURLWithPath: try XCTUnwrap(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) }))
        let home = base.appendingPathComponent("burro-rlaunch-\(UUID().uuidString.prefix(8))")
        let bin = home.appendingPathComponent(".local/bin"), project = home.appendingPathComponent("Dev/app")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try scenario.write(to: home.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
        let projects: [String: Any] = trusted ? [home.appendingPathComponent("Dev").path: ["hasTrustDialogAccepted": true]]
                                              : [project.path: ["hasTrustDialogAccepted": false]]
        try JSONSerialization.data(withJSONObject: ["projects": projects]).write(to: home.appendingPathComponent(".claude.json"))
        let fake = bin.appendingPathComponent("claude")
        try fakeClaude.write(to: fake, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fake.path, 0o755), 0)
        return (home, project)
    }
    private var fakeClaude: String {
        #"""
        #!/bin/sh
        printf '%s %s\n' "$#" "$*" >> "$HOME/calls.log"
        S=$(cat "$HOME/scenario")
        SID=\#(sid)
        case "$1" in
          --bg)
            pwd -P > "$HOME/launch_cwd"
            if [ "$S" = fork ]; then (sleep 15) & fi
            if [ "$S" = started ] || [ "$S" = fork ]; then
              dir="$HOME/.claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
              mkdir -p "$dir"; : > "$dir/$SID.jsonl"
            fi
            if [ "$S" = blocked ]; then
              mkdir -p "$HOME/.claude/jobs/abc12345"
              printf '{"state":"blocked","needs":"approve 1 new project MCP server (x) — attach to respond","sessionId":"%s"}' "$SID" > "$HOME/.claude/jobs/abc12345/state.json"
            fi
            echo "Started in the background. claude attach abc12345"
            ;;
          agents)
            case "$S" in
              started|fork) printf '[{"id":"ffff0000","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","state":"idle"},{"id":"abc12345","sessionId":"%s","cwd":"%s","state":"working","kind":"background"}]' "$SID" "$(cat "$HOME/launch_cwd")" ;;
              blocked) printf '[{"id":"abc12345","sessionId":"%s","state":"blocked"}]' "$SID" ;;
              *) echo '[]' ;;
            esac ;;
          logs) echo "New MCP server found in this project: foo" ;;
        esac
        exit 0
        """#
    }
    /// Every call to the fake `claude`, as "<argument count> <arguments joined by spaces>".
    private func calls(_ home: URL) -> [String] {
        ((try? String(contentsOf: home.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private func cleanup(_ home: URL) -> [String] {
        calls(home).filter { $0.hasPrefix("2 stop") || $0.hasPrefix("2 rm") || $0.contains(" stop ") || $0.contains(" rm ") }
    }

    /// Runs a bundled remote script locally the way Burro sends it over SSH, optionally with its
    /// verify wait shortened. Returns stdout and how long it took.
    private func script(_ name: String, _ request: [String: Any], home: URL, verify: Double? = nil) throws -> (out: Data, seconds: Double) {
        var body = try String(contentsOf: try XCTUnwrap(RemoteScript.url(name)), encoding: .utf8)
        if let verify { body = body.replacingOccurrences(of: "VERIFY_SECONDS = 20.0", with: "VERIFY_SECONDS = \(verify)") }
        let input = Data(("REQUEST_B64 = \"\(try JSONSerialization.data(withJSONObject: request).base64EncodedString())\"\n" + body).utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (out, Date().timeIntervalSince(start))
    }
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
    }
    private func request(_ folder: URL, prompt: String = "Fix the build") -> LaunchRequest {
        LaunchRequest(provider: .claude, prompt: prompt, folder: folder.path, model: "claude-opus-5-5", effort: "high", access: .edit)
    }
    private func runner(_ home: URL, verify: Double? = nil) -> RemoteLaunch.Runner {
        { name, request, _ in try self.script(name, request, home: home, verify: verify).out }
    }

    // MARK: remote_launch.py

    func testLaunchScriptAcceptsOnlyANewChatsArguments() throws {
        let (home, project) = try makeHome(scenario: "started")
        let bad: [[String]] = [
            ["--bg", "--resume", sid, "--", "x"],
            ["--bg", "--permission-mode", "bypassPermissions", "--", "x"],
            ["--bg", "--permission-mode", "manual", "--dangerously-skip-permissions", "--", "x"],
            ["--bg", "--permission-mode", "manual", "--model", "a b", "--", "x"],
            ["--bg", "--permission-mode", "manual", "--model", "a", "--model", "b", "--", "x"],
            ["--bg", "--permission-mode", "manual", "x"],
            ["--bg", "--permission-mode", "manual", "--", ""],
            ["--bg", "--permission-mode", "manual", "--", String(repeating: "x", count: 100_001)],
            ["--print", "--permission-mode", "manual", "--", "x"],
            ["--bg", "--permission-mode", "manual", "--", "x", "extra"],
        ]
        for args in bad {
            let object = try json(try script("remote_launch", ["op": "start", "folder": project.path, "args": args], home: home).out)
            XCTAssertEqual(object["ok"] as? Bool, false, "\(args.prefix(6))")
            XCTAssertEqual(object["code"] as? String, "invalid", "\(args.prefix(6))")
        }
        for extra in [["op": "start", "folder": project.path, "args": ["--bg"], "cwd": "/"], ["op": "launch", "folder": project.path, "args": []],
                      ["op": "check", "folder": project.path, "args": ["--bg"]]] as [[String: Any]] {
            XCTAssertEqual(try json(try script("remote_launch", extra, home: home).out)["code"] as? String, "invalid")
        }
        XCTAssertTrue(calls(home).isEmpty, "nothing ran")
    }

    func testLaunchScriptRefusesFoldersThatArentYoursOrReal() throws {
        let (home, _) = try makeHome(scenario: "started")
        let link = home.appendingPathComponent("Dev/usr-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr"))
        let file = home.appendingPathComponent("Dev/file.txt")
        try Data("x".utf8).write(to: file)
        let args = ClaudeLaunch.arguments(for: request(home))
        for folder in [link.path, "/usr", home.appendingPathComponent("Dev/missing").path, file.path, "relative/path", "/tmp/a\nb"] {
            let object = try json(try script("remote_launch", ["op": "start", "folder": folder, "args": args], home: home).out)
            XCTAssertEqual(object["ok"] as? Bool, false, folder)
            XCTAssertEqual(object["code"] as? String, "folder", folder)
        }
        XCTAssertTrue(calls(home).isEmpty)
    }

    func testUntrustedFolderLaunchesNothing() throws {
        let (home, project) = try makeHome(scenario: "started", trusted: false)
        let object = try json(try script("remote_launch", ["op": "start", "folder": project.path, "args": ClaudeLaunch.arguments(for: request(project))], home: home).out)
        XCTAssertEqual(object["code"] as? String, "untrusted")
        XCTAssertTrue(calls(home).isEmpty, "Burro never launches into (or trusts) an untrusted folder")
        XCTAssertThrowsError(try RemoteLaunch.startClaude(request(project), host: host, run: runner(home))) { error in
            XCTAssertEqual(error as? RemoteLaunchError, .untrusted(host: "Studio", folder: project.path))
        }
        let check = try json(try script("remote_launch", ["op": "check", "folder": project.path, "args": [String]()], home: home).out)
        XCTAssertEqual(check["code"] as? String, "untrusted")
        XCTAssertTrue(calls(home).isEmpty)
    }

    func testStartedChatIsDecidedByTheLocalStartCheck() throws {
        let (home, project) = try makeHome(scenario: "started")
        XCTAssertEqual(try RemoteLaunch.checkClaude(folder: project.path, host: host, run: runner(home)).path, project.path)
        let prompt = "Fix it; $(touch \(home.path)/pwned) `id` \"quoted\" -- --dangerously-skip-permissions"
        let result = try RemoteLaunch.startClaude(request(project, prompt: prompt), host: host, run: runner(home))
        XCTAssertEqual(result.launch.sessionID, sid)
        XCTAssertEqual(result.launch.handle, "abc12345")
        XCTAssertEqual(result.chatID, "remote:\(host.id.uuidString):claude:\(sid)")
        XCTAssertEqual(ChatTranscripts.identity(chatID: result.chatID)?.host, host.id)
        let log = calls(home)
        XCTAssertEqual(log.first, "9 --bg --permission-mode acceptEdits --model claude-opus-5-5 --effort high -- \(prompt)", "the prompt arrives as one argument")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path), "the prompt is never run by a shell")
        XCTAssertTrue(cleanup(home).isEmpty, "a started chat is left alone")
    }

    func testBlockedSessionIsStoppedAndRemovedByItsHandleOnly() throws {
        let (home, project) = try makeHome(scenario: "blocked")
        XCTAssertThrowsError(try RemoteLaunch.startClaude(request(project), host: host, run: runner(home))) { error in
            XCTAssertEqual(error as? RemoteLaunchError, .blocked(host: "Studio", folder: project.path, reason: "approve 1 new project MCP server (x)"))
        }
        let log = calls(home)
        XCTAssertEqual(cleanup(home), ["2 stop abc12345", "2 rm abc12345"])
        XCTAssertTrue(log.contains("2 logs abc12345"))
    }

    func testSilentSessionReadsItsScreenThenIsRemoved() throws {
        let (home, project) = try makeHome(scenario: "silent")
        XCTAssertThrowsError(try RemoteLaunch.startClaude(request(project), host: host, run: runner(home, verify: 1))) { error in
            XCTAssertEqual(error as? RemoteLaunchError, .blocked(host: "Studio", folder: project.path, reason: "approve the new project MCP server foo"))
        }
        XCTAssertEqual(cleanup(home), ["2 stop abc12345", "2 rm abc12345"])
    }

    func testAChildHoldingStdoutDoesNotStallEitherScript() throws {
        let (home, project) = try makeHome(scenario: "fork")
        let launch = try script("remote_launch", ["op": "start", "folder": project.path, "args": ClaudeLaunch.arguments(for: request(project))], home: home)
        XCTAssertLessThan(launch.seconds, 10, "the launch returns without waiting for the background child")
        XCTAssertEqual(try json(launch.out)["verdict"] as? String, "started")
        let args = ["--bg", "--resume", "11111111-2222-4333-8444-555555555555", "--permission-mode", "plan", "--", "go on"]
        let reply = try script("remote_reply", ["args": args, "cwd": project.path], home: home)
        XCTAssertLessThan(reply.seconds, 10, "the reply returns without waiting for the background child")
        XCTAssertEqual(try json(reply.out)["ok"] as? Bool, true)
    }

    func testEvidenceDecoding() throws {
        let request = request(URL(fileURLWithPath: "/w"))
        func evidence(_ fields: [String: Any]) -> [String: Any] {
            ["ok": true, "folder": "/w", "handle": "abc12345", "agents": "[]", "transcripts": [[String: Any]](), "logs": "", "discarded": true]
                .merging(fields) { $1 }
        }
        let started = evidence(["agents": #"[{"id":"abc12345","sessionId":"\#(sid.uppercased())","cwd":"/w","state":"working"}]"#,
                                "transcripts": [["cwd": "/w", "session": sid, "exists": true]], "discarded": false])
        XCTAssertEqual(try RemoteLaunch.decide(started, request: request, host: host).launch.sessionID, sid)
        XCTAssertThrowsError(try RemoteLaunch.decide(started.merging(["discarded": true]) { $1 }, request: request, host: host)) {
            XCTAssertEqual($0 as? RemoteLaunchError, .unconfirmed(host: "Studio", handle: "abc12345"), "never reported started once removed")
        }
        let ended = evidence(["job": #"{"state":"failed","detail":"bad model"}"#])
        XCTAssertThrowsError(try RemoteLaunch.decide(ended, request: request, host: host)) {
            XCTAssertTrue(($0 as? RemoteLaunchError)?.errorDescription?.contains("ended (failed: bad model)") == true)
        }
        XCTAssertThrowsError(try RemoteLaunch.decide(evidence([:]), request: request, host: host)) {
            XCTAssertEqual($0 as? RemoteLaunchError, .unconfirmed(host: "Studio", handle: "abc12345"))
        }
        XCTAssertThrowsError(try RemoteLaunch.decide(evidence(["handle": "../x"]), request: request, host: host)) {
            XCTAssertEqual($0 as? RemoteLaunchError, .unconfirmed(host: "Studio", handle: nil))
        }
        for (code, expected) in [("notInstalled", RemoteLaunchError.claudeNotInstalled(host: "Studio")),
                                 ("untrusted", .untrusted(host: "Studio", folder: "/real")),
                                 ("folder", .folder(host: "Studio", reason: "That path isn't a folder.")),
                                 ("invalid", .failed("Burro sent a request Studio won't run."))] {
            let refusal: [String: Any] = ["ok": false, "code": code, "error": "That path isn't a folder.", "folder": "/real"]
            XCTAssertThrowsError(try RemoteLaunch.decide(refusal, request: request, host: host)) { XCTAssertEqual($0 as? RemoteLaunchError, expected) }
        }
    }

    func testSwiftRefusesBadRequestsBeforeAnyCall() {
        var ran = false
        let run: RemoteLaunch.Runner = { _, _, _ in ran = true; return Data() }
        XCTAssertThrowsError(try RemoteLaunch.startClaude(LaunchRequest(provider: .claude, prompt: "  ", folder: "/w"), host: host, run: run))
        XCTAssertThrowsError(try RemoteLaunch.startClaude(LaunchRequest(provider: .claude, prompt: "x", folder: "w"), host: host, run: run))
        XCTAssertThrowsError(try RemoteLaunch.startClaude(LaunchRequest(provider: .claude, prompt: "x", folder: "/w", model: "a b"), host: host, run: run))
        XCTAssertThrowsError(try RemoteLaunch.startClaude(LaunchRequest(provider: .codex, prompt: "x", folder: "/w"), host: host, run: run))
        XCTAssertFalse(ran)
    }

    // MARK: remote_folders.py

    private func sqlite(_ path: String, _ statements: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.executescript(sys.argv[2]); db.commit()", path, statements]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testFolderListerReadsProjectsCodexAndRecentClaudeWithGitFacts() throws {
        let (home, project) = try makeHome(scenario: "none")
        let fm = FileManager.default
        // A repository with a branch, and a linked worktree of it.
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: project.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let worktree = home.appendingPathComponent("Dev/app-wt"), wtGit = project.appendingPathComponent(".git/worktrees/app-wt")
        try fm.createDirectory(at: worktree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try "gitdir: \(wtGit.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/x\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let plain = home.appendingPathComponent("Dev/plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        // ~/.claude.json projects: one trusted parent, one gone.
        let projects: [String: Any] = [home.appendingPathComponent("Dev").path: ["hasTrustDialogAccepted": true],
                                       "/nowhere/gone": ["hasTrustDialogAccepted": true]]
        try JSONSerialization.data(withJSONObject: ["projects": projects]).write(to: home.appendingPathComponent(".claude.json"))
        // Codex state database.
        try fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        try sqlite(home.appendingPathComponent(".codex/state_5.sqlite").path, """
            CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, updated_at INTEGER, archived INTEGER);
            INSERT INTO threads VALUES ('a', '\(worktree.path)/sub', 't', \(Int(now) - 60), 0);
            INSERT INTO threads VALUES ('b', '/archived/one', 't', \(Int(now)), 1);
            """)
        // A recent Claude transcript, and an old one.
        for (folder, cwd, age) in [("-recent", plain.path, 3600.0), ("-old", "/old/one", 40 * 86_400.0)] {
            let dir = home.appendingPathComponent(".claude/projects/\(folder)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(sid).jsonl")
            try (#"{"type":"summary"}"# + "\n" + String(decoding: try JSONSerialization.data(withJSONObject: ["cwd": cwd]), as: UTF8.self) + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - age)], ofItemAtPath: file.path)
        }
        let cache = RemoteCache(root: home.appendingPathComponent("cache"))
        let list = try RemoteLaunch.folders(host: host, cache: cache, now: Date(), run: runner(home))
        let byPath = Dictionary(uniqueKeysWithValues: list.folders.map { ($0.path, $0) })
        XCTAssertEqual(byPath["\(worktree.path)/sub"]?.git, RemoteFolder.Git(root: worktree.path, branch: "feature/x", worktree: true))
        XCTAssertEqual(byPath["\(worktree.path)/sub"]?.sources, ["codex"])
        XCTAssertEqual(byPath["\(worktree.path)/sub"]?.trusted, true, "trusted through a parent folder")
        XCTAssertEqual(byPath[plain.path]?.sources, ["claudeSession"])
        XCTAssertNil(byPath[plain.path]?.git)
        XCTAssertEqual(byPath["/nowhere/gone"]?.exists, false)
        XCTAssertNil(byPath["/archived/one"])
        XCTAssertNil(byPath["/old/one"], "only the last 30 days")
        XCTAssertEqual(list.folders.first?.path, "\(worktree.path)/sub", "most recently used first")
        XCTAssertEqual(list.folders.last?.lastUsed, nil, "folders only known from ~/.claude.json come last")
        XCTAssertEqual(RemoteLaunch.cachedFolders(host: host, cache: cache)?.folders.count, list.folders.count, "remembered in host.json")
        // Validation of a typed folder.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Dev/link"), withDestinationURL: project)
        let check = try RemoteLaunch.validate(host: host, path: home.appendingPathComponent("Dev/link").path, cache: cache, now: Date(), run: runner(home))
        XCTAssertEqual(check, RemoteFolderCheck(path: project.path, trusted: true, git: RemoteFolder.Git(root: project.path, branch: "main", worktree: false)))
        XCTAssertEqual(RemoteLaunch.cachedFolders(host: host, cache: cache)?.folders.first?.path, project.path)
        for (path, reason) in [("/usr", "another user"), (home.appendingPathComponent("nope").path, "doesn't exist"), ("rel", "absolute")] {
            XCTAssertThrowsError(try RemoteLaunch.validate(host: host, path: path, cache: cache, now: Date(), run: runner(home))) {
                XCTAssertTrue(($0 as? RemoteLaunchError)?.errorDescription?.contains(reason) == true, "\(path): \($0)")
            }
        }
        XCTAssertEqual(try json(try script("remote_folders", ["op": "list", "extra": 1], home: home).out)["code"] as? String, "invalid")
    }

    func testFolderListerRunsNoPrograms() throws {
        let text = try String(contentsOf: try XCTUnwrap(RemoteScript.url("remote_folders")), encoding: .utf8)
        for forbidden in ["subprocess", "os.system", "popen", "os.exec", "spawn"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testMediaStatReportsSizeAndTime() throws {
        let (home, _) = try makeHome(scenario: "none")
        let image = home.appendingPathComponent("a.png")
        try Data(repeating: 7, count: 3000).write(to: image)
        let object = try json(try script("remote_media", ["path": image.path, "max": 10_000, "op": "stat"], home: home).out)
        XCTAssertEqual(object["size"] as? Int, 3000)
        XCTAssertNotNil(object["mtime"] as? Double)
    }

    // MARK: Codex

    private final class FakeCodex: CodexRPC {
        var calls: [(String, [String: Any])] = []
        var closed = false
        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            calls.append((method, params))
            return method == "thread/start" ? ["thread": ["id": "019a0000-0000-7000-8000-000000000001"]] : [:]
        }
        func close() { closed = true }
    }

    func testCodexStartsInTheValidatedFolderOverItsDaemon() throws {
        let fake = FakeCodex()
        let request = LaunchRequest(provider: .codex, prompt: " Fix ", folder: "/Users/me/link", model: "gpt-5", effort: "high", access: .readOnly)
        let result = try RemoteLaunch.startCodex(request, host: host, validate: { _ in RemoteFolderCheck(path: "/Users/me/real", trusted: false, git: nil) },
                                                 connect: { _ in fake })
        XCTAssertEqual(fake.calls.map(\.0), ["thread/start", "turn/start"])
        XCTAssertEqual(fake.calls[0].1["cwd"] as? String, "/Users/me/real")
        XCTAssertEqual(fake.calls[0].1["sandbox"] as? String, "read-only")
        XCTAssertEqual(fake.calls[1].1["threadId"] as? String, "019a0000-0000-7000-8000-000000000001")
        XCTAssertEqual((fake.calls[1].1["input"] as? [[String: Any]])?.first?["text"] as? String, "Fix")
        XCTAssertTrue(fake.closed)
        XCTAssertEqual(result.chatID, "remote:\(host.id.uuidString):codex:019a0000-0000-7000-8000-000000000001")
        XCTAssertEqual(result.launch.folder, "/Users/me/real")

        var connected = false
        XCTAssertThrowsError(try RemoteLaunch.startCodex(request, host: host, validate: { _ in throw RemoteLaunchError.folder(host: "Studio", reason: "x") },
                                                         connect: { _ in connected = true; return fake }))
        XCTAssertFalse(connected, "nothing starts in a folder that didn't validate")
    }

    func testCodexConnectionProblemsBecomeClearErrors() {
        let cases: [(String, RemoteLaunchError)] = [
            ("Couldn't reach Studio over SSH.", .unreachable(host: "Studio")),
            ("Studio can't be reached from Burro.", .unreachable(host: "Studio")),
            ("Codex isn't installed on Studio.", .codexNotInstalled(host: "Studio")),
            ("Codex on Studio isn't the standalone install, which …", .codexNotStandalone(host: "Studio", detail: "Codex on Studio isn't the standalone install, which …")),
            ("Codex is running on Studio, but Burro couldn't talk to it: x", .failed("Codex is running on Studio, but Burro couldn't talk to it: x")),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(RemoteLaunch.codexProblem(LaunchError.failed(message), host: host), expected, message)
        }
    }

    // MARK: SSH

    func testEveryNewCallUsesTheStrictBuilderAndKeepsValuesOffTheCommandLine() throws {
        let host = RemoteHost(name: "Studio", destination: "me@studio", port: 2222)
        let hostile = "/tmp/x'; rm -rf ~; echo '"
        for (name, request) in [("remote_launch", ["op": "start", "folder": hostile, "args": ["--bg", "--permission-mode", "plan", "--", "$(id)"]]),
                                ("remote_folders", ["op": "validate", "path": hostile]),
                                ("remote_folders", ["op": "list"])] as [(String, [String: Any])] {
            let call = try RemoteLaunch.invocation(name, request: request, host: host)
            XCTAssertEqual(call.arguments, RemoteAgentMonitor.arguments(for: host), name)
            XCTAssertEqual(Array(call.arguments.suffix(3)), ["--", "me@studio", "python3 -"])
            for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ClearAllForwardings=yes", "ForwardAgent=no", "PermitLocalCommand=no"] {
                XCTAssertTrue(call.arguments.contains(option), option)
            }
            XCTAssertFalse(call.arguments.contains { $0.contains("rm -rf") || $0.contains("$(id)") })
            let first = try XCTUnwrap(String(decoding: call.input, as: UTF8.self).split(separator: "\n").first)
            XCTAssertTrue(first.hasPrefix("REQUEST_B64 = \""))
            let encoded = first.dropFirst("REQUEST_B64 = \"".count).dropLast()
            let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: String(encoded)))) as? [String: Any])
            XCTAssertEqual(decoded["op"] as? String, request["op"] as? String)
            XCTAssertFalse(String(decoding: call.input, as: UTF8.self).contains("rm -rf"), "values travel only inside the base64 line")
        }
    }
}
