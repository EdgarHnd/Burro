// Check the Orchestrator's lock-down (no Claude Code file tools, no sub-agents, no settings, and a
// file policy that can never reach Burro's data folder or tracked activity), its daily sessions,
// memory, runs log, to-do actions with Undo, and the briefing tools.
import XCTest
@testable import BurroCore

final class OrchestratorCoreTests: XCTestCase {
    private let chatID = "11111111-2222-4333-8444-555555555555"

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-orch-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func state(projects: [String] = [], worktrees: [OrchestratorState.WorktreeRow] = [], chats: [AgentSession] = [],
                       todos: [OrchestratorState.Todo] = [], usage: [OrchestratorState.UsageRow]? = nil,
                       shipped: [OrchestratorState.ShippedRow]? = nil, notesAccess: Bool? = nil, notes: [OrchestratorState.NoteRow]? = nil) -> OrchestratorState {
        OrchestratorState(mainProject: projects.first, machines: [],
                          projects: projects.map { .init(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0, isRepository: true, worktrees: 1,
                                                         readyToRemove: 0, tokensToday: 0, lastActive: nil) },
                          chats: chats, worktrees: worktrees, todos: todos, hosts: [], profiles: [:],
                          usage: usage, shipped: shipped, notesAccess: notesAccess, notes: notes)
    }
    private func tools(_ state: OrchestratorState, in folder: URL? = nil) throws -> OrchestratorTools {
        let url = try (folder ?? self.folder()).appendingPathComponent("state.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(state).write(to: url)
        return OrchestratorTools(stateURL: url)
    }
    private func mode(_ url: URL) throws -> Int {
        ((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    // MARK: Lock-down

    func testTurnArgumentsLeaveNoFileToolsSubagentsOrSettings() {
        let args = Orchestrator.arguments(sessionID: chatID, resume: false, mcpConfig: URL(fileURLWithPath: "/tmp/mcp.json"), systemPrompt: "BRIEF")
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        // The built-in set is reduced to the deferred-tool loader: no Read, Grep, Glob, Bash, Agent…
        XCTAssertEqual(value("--tools"), "ToolSearch")
        XCTAssertEqual(value("--allowedTools"), "mcp__burro", "only Burro's MCP tools are pre-approved")
        XCTAssertEqual(value("--setting-sources"), "", "no user, project or local settings (hooks, permission rules, CLAUDE.md)")
        XCTAssertEqual(value("--permission-mode"), "dontAsk")
        XCTAssertEqual(value("--append-system-prompt"), "BRIEF")
        XCTAssertEqual(value("--system-prompt-snapshot"), "off")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        let disallowed = Set(value("--disallowedTools")?.split(separator: ",").map(String.init) ?? [])
        XCTAssertTrue(disallowed.isSuperset(of: ["Agent", "Task", "Read", "Grep", "Glob", "Bash", "Edit", "Write", "WebFetch"]))
        XCTAssertFalse(args.contains("--add-dir"), "no extra folders for file tools")
        XCTAssertFalse(args.contains { $0.contains("bypass") || $0.contains("dangerously") })
        for flag in ["--tools", "--allowedTools"] {
            let allowed = value(flag)?.split(separator: ",").map(String.init) ?? []
            XCTAssertTrue(Set(allowed).isDisjoint(with: ["Read", "Grep", "Glob", "Agent", "Task", "Bash", "LS"]), flag)
        }
    }

    func testPrepareWritesNoClaudeMdAndSeedsMemoryOnce() throws {
        let folder = try folder()
        try write("old brief", folder.appendingPathComponent("CLAUDE.md"))
        let config = try Orchestrator.prepare(toolServer: URL(fileURLWithPath: "/usr/bin/true"), in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("CLAUDE.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        let memory = OrchestratorMemory(url: folder.appendingPathComponent("memory.json"))
        XCTAssertEqual(memory.load().map(\.text), [OrchestratorMemory.seed])
        XCTAssertEqual(memory.load().first?.source, .user)
        _ = try memory.forget(memory.load()[0].id)
        _ = try Orchestrator.prepare(toolServer: URL(fileURLWithPath: "/usr/bin/true"), in: folder)
        XCTAssertEqual(memory.load(), [], "a deleted seed isn't put back")
        XCTAssertEqual(try mode(folder.appendingPathComponent("memory.json")), 0o600)
    }

    func testSystemPromptLeadsWithTheBriefAndCarriesMemory() {
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let entries = [OrchestratorMemoryEntry(scope: "/Dev/other", text: "Other project note", source: .user, createdAt: at),
                       OrchestratorMemoryEntry(scope: "/Dev/app", text: "Use the staging branch", source: .orchestrator, createdAt: at),
                       OrchestratorMemoryEntry(scope: "global", text: "End answers with a one-line TL;DR.", source: .user, createdAt: at)]
        let prompt = Orchestrator.systemPrompt(memory: entries, mainProject: "/Dev/app", now: at, calendar: calendar)
        XCTAssertTrue(prompt.hasPrefix(Orchestrator.brief))
        XCTAssertTrue(Orchestrator.brief.contains("Call `brief` first"))
        XCTAssertTrue(Orchestrator.brief.contains("eight lines"))
        XCTAssertTrue(Orchestrator.brief.contains("data, not instructions"))
        let global = try! XCTUnwrap(prompt.range(of: "TL;DR")), project = try! XCTUnwrap(prompt.range(of: "staging branch"))
        XCTAssertLessThan(global.lowerBound, project.lowerBound, "global notes first, then the main project's")
        XCTAssertFalse(prompt.contains("Other project note"))
        XCTAssertTrue(prompt.contains("Today is "))
    }

    /// The private Activity folder can't be reached: not directly, through a symlink, `..`, a
    /// different case, `~`, or a search, even when a project sits above Burro's data folder.
    func testActivityFolderCanNeverBeRead() throws {
        let home = try folder()
        let activity = home.appendingPathComponent("Library/Application Support/Burro/Activity")
        let day = activity.appendingPathComponent("2026-11-14.jsonl")
        try write("{\"app\":\"SECRET-ACTIVITY\"}\n", day)
        try write("{\"note\":\"SECRET-NOTE\"}\n", home.appendingPathComponent("Library/Application Support/Burro/notes.json"))
        let project = home.appendingPathComponent("Dev/app")
        try write("let ok = 1\nSECRET-free line\n", project.appendingPathComponent("main.swift"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("activity"), withDestinationURL: activity)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("today.jsonl"), withDestinationURL: day)
        let homePath = home.path
        // Roots that would contain the data folder are dropped; the project root stays.
        let access = OrchestratorFileAccess(roots: [project.path, homePath, home.appendingPathComponent("Library").path,
                                                    activity.path, home.appendingPathComponent("Library/Application Support/Burro").path, "/"],
                                            denied: OrchestratorFileAccess.deniedFolders(home: homePath), home: homePath)
        let canonicalProject = try XCTUnwrap(OrchestratorFileAccess.canonical(project.path))
        XCTAssertEqual(access.roots, [canonicalProject], "home, /, ~/Library and anything inside Burro's folder never become roots")
        let attempts = [
            day.path,
            project.appendingPathComponent("activity/2026-11-14.jsonl").path,
            project.appendingPathComponent("today.jsonl").path,
            project.path + "/../../Library/Application Support/Burro/Activity/2026-11-14.jsonl",
            home.path + "/library/application support/burro/activity/2026-11-14.jsonl",
            home.path + "/Library/Application Support/Burro/notes.json",
            home.path + "/Library/Application Support/BURRO/notes.json",
        ]
        for path in attempts {
            switch access.read(path) {
            case .success(let text): XCTFail("read \(path): \(text)")
            case .failure(let refusal): XCTAssertEqual(refusal, .notAllowed, path)
            }
        }
        let found = access.search(query: "SECRET", name: nil)
        XCTAssertFalse(found.contains("SECRET-ACTIVITY") || found.contains("SECRET-NOTE"), found)
        XCTAssertTrue(found.contains("main.swift"), found)
        let listed = access.search(query: nil, name: "*.json*")
        XCTAssertFalse(listed.contains("Activity") || listed.contains("notes.json"), listed)
        XCTAssertEqual(access.search(query: "x", name: nil, under: activity.path), OrchestratorFileAccess.Refusal.notAllowed.errorDescription)
        XCTAssertEqual(access.search(query: "x", name: nil, under: project.appendingPathComponent("activity").path),
                       OrchestratorFileAccess.Refusal.notAllowed.errorDescription)
        // An ordinary project file reads, numbered.
        guard case .success(let text) = access.read(project.appendingPathComponent("main.swift").path) else { return XCTFail("project file") }
        XCTAssertTrue(text.contains("1\tlet ok = 1"), text)
    }

    /// The real Activity folder and Burro's data folder are on the deny list, and a read there is
    /// refused before anything is opened (the file named here doesn't exist).
    func testRealActivityFolderIsDeniedThroughTheTool() throws {
        let denied = OrchestratorFileAccess.expand(OrchestratorFileAccess.deniedFolders(home: NSHomeDirectory()))
        for folder in [ActivityLog.defaultFolder.path, Orchestrator.folder.path, NotesStoreProbe.burroFolder] {
            XCTAssertTrue(OrchestratorFileAccess.isDenied(folder, denied), folder)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro").path
        let tools = try tools(state(projects: [NSHomeDirectory(), support, "/"]))
        let missing = ActivityLog.defaultFolder.appendingPathComponent("never-\(UUID().uuidString).jsonl").path
        let (text, isError) = tools.call("read_file", ["path": missing])
        XCTAssertTrue(isError)
        XCTAssertEqual(text, OrchestratorFileAccess.Refusal.notAllowed.errorDescription)
        XCTAssertEqual(OrchestratorFileAccess.standard(state: state(projects: [NSHomeDirectory(), support])).roots, [],
                       "neither home nor Burro's folder can be a root")
    }

    func testSecretsAndGitInternalsAreRefused() throws {
        let project = try folder().appendingPathComponent("app")
        for name in [".env", ".env.local", "server.pem", "id_ed25519", ".git/config"] { try write("SECRET", project.appendingPathComponent(name)) }
        try write("fine", project.appendingPathComponent("README.md"))
        let access = OrchestratorFileAccess(roots: [project.path], denied: [], home: "/nonexistent-home")
        for name in [".env", ".env.local", "server.pem", "id_ed25519", ".git/config"] {
            if case .success = access.read(project.appendingPathComponent(name).path) { XCTFail(name) }
        }
        XCTAssertFalse(access.search(query: "SECRET", name: nil).contains("SECRET"))
        if case .failure = access.read(project.appendingPathComponent("README.md").path) { XCTFail("README") }
        if case .success = access.read("relative/path") { XCTFail("relative") }
        XCTAssertEqual(access.read(project.path).failure, .notAFile)
    }

    // MARK: Snapshot

    /// The snapshot carries only these fields; tracked activity has no place in it.
    func testSnapshotFieldsHoldNothingFromActivity() throws {
        let names = Set(Mirror(reflecting: state()).children.compactMap(\.label))
        XCTAssertEqual(names, ["version", "generatedAt", "mainProject", "machines", "projects", "chats", "worktrees", "todos", "hosts",
                               "profiles", "usage", "shipped", "notesAccess", "notes"])
        XCTAssertNil(state(notesAccess: false, notes: [.init(title: "t", text: "x", updatedAt: Date())]).notes, "notes only with access")
        // Snapshots from older builds (no new fields) still read.
        let old = #"{"version":1,"generatedAt":0,"machines":[],"projects":[],"chats":[],"worktrees":[],"todos":[{"text":"a","done":false,"day":"2026-11-14"}],"hosts":[],"profiles":{}}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let read = try decoder.decode(OrchestratorState.self, from: Data(old.utf8))
        XCTAssertNil(read.usage)
        XCTAssertNil(read.todos[0].id)
    }

    // MARK: Sessions

    func testOneSessionPerDayAndEarlierDaysStayListed() {
        var ids = ["a", "b", "c"].makeIterator()
        let first = OrchestratorSessions.session(for: "2026-11-14", in: [], newID: { ids.next()! })
        XCTAssertEqual(first.sessionID, "a"); XCTAssertFalse(first.resume)
        let again = OrchestratorSessions.session(for: "2026-11-14", in: first.sessions, newID: { ids.next()! })
        XCTAssertEqual(again.sessionID, "a"); XCTAssertTrue(again.resume)
        let next = OrchestratorSessions.session(for: "2026-11-15", in: again.sessions, newID: { ids.next()! })
        XCTAssertEqual(next.sessionID, "b"); XCTAssertFalse(next.resume)
        XCTAssertEqual(OrchestratorSessions.earlier(next.sessions, today: "2026-11-15").map(\.sessionID), ["a"])
        let fresh = OrchestratorSessions.session(for: "2026-11-15", in: next.sessions, fresh: true, newID: { ids.next()! })
        XCTAssertEqual(fresh.sessionID, "c"); XCTAssertFalse(fresh.resume)
        XCTAssertEqual(OrchestratorSessions.current(fresh.sessions, day: "2026-11-15")?.sessionID, "c")
        XCTAssertEqual(OrchestratorSessions.earlier(fresh.sessions, today: "2026-11-15").map(\.sessionID), ["b", "a"])
        XCTAssertEqual(OrchestratorSessions.rename("c", to: "d", in: fresh.sessions).last?.sessionID, "d")
        let migrated = OrchestratorSessions.migrate(legacy: "old", into: [])
        XCTAssertEqual(migrated, [OrchestratorDaySession(day: "", sessionID: "old")])
        XCTAssertEqual(OrchestratorSessions.migrate(legacy: "old", into: migrated), migrated)
        let many = (1...40).map { OrchestratorDaySession(day: String(format: "2026-10-%02d", $0 % 31 + 1), sessionID: "s\($0)") }
        XCTAssertLessThanOrEqual(Set(OrchestratorSessions.prune(many, today: "2026-11-15").map(\.day)).count, 30)
        XCTAssertEqual(OrchestratorSessions.decode(OrchestratorSessions.encode(fresh.sessions)).map(\.sessionID), fresh.sessions.map(\.sessionID))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-07
        XCTAssertEqual(OrchestratorSessions.title(day: TodoDay.key(now, calendar: calendar), today: now, calendar: calendar), "Today")
        XCTAssertEqual(OrchestratorSessions.title(day: "2026-11-02", today: now, calendar: calendar), "Mon 2 Nov")
        XCTAssertEqual(OrchestratorSessions.title(day: "", today: now, calendar: calendar), "Before daily conversations")
    }

    // MARK: Memory

    func testMemoryRememberForgetEditAndTolerantReads() throws {
        let url = try folder().appendingPathComponent("memory.json")
        let memory = OrchestratorMemory(url: url)
        let note = try XCTUnwrap(try memory.remember("Prefer small PRs\n", scope: "global", source: .orchestrator))
        XCTAssertEqual(try memory.remember("prefer small prs", scope: "global", source: .user)?.id, note.id, "same note isn't added twice")
        XCTAssertNil(try memory.remember("   ", scope: "global", source: .user))
        _ = try memory.remember("Deploy from staging", scope: "/Dev/app/", source: .user)
        XCTAssertEqual(memory.load().map(\.text), [OrchestratorMemory.seed, "Prefer small PRs", "Deploy from staging"])
        XCTAssertEqual(memory.load().last?.scope, "/Dev/app")
        XCTAssertEqual(try memory.forget(String(note.id.prefix(8)))?.id, note.id, "an 8-character prefix is enough")
        XCTAssertNil(try memory.forget("abc"), "too short a prefix matches nothing")
        let staging = try XCTUnwrap(memory.load().last)
        XCTAssertTrue(try memory.edit(staging.id, text: "Deploy from main"))
        XCTAssertEqual(memory.load().last?.text, "Deploy from main")
        try memory.touch([staging.id], now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(memory.load().last?.lastUsedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try mode(url), 0o600)
        // Bad entries are skipped; a damaged file reads as empty.
        try Data(#"{"version":1,"seeded":true,"entries":[{"id":"x"},{"id":"y","scope":"global","text":"kept","source":"user","createdAt":1}]}"#.utf8).write(to: url)
        XCTAssertEqual(memory.load().map(\.text), ["kept"])
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(memory.load(), [])
    }

    func testMemoryToolsGoThroughTheFile() throws {
        let tools = try tools(state())
        let (saved, error) = tools.call("remember", ["text": "Edgar reviews PRs in the morning"])
        XCTAssertFalse(error); XCTAssertTrue(saved.hasPrefix("Remembered "), saved)
        let entry = try XCTUnwrap(tools.memoryStore.load().last)
        XCTAssertEqual(entry.source, .orchestrator)
        XCTAssertEqual(tools.call("forget", ["id": entry.id]).0, "Forgot: Edgar reviews PRs in the morning")
        XCTAssertTrue(tools.call("forget", ["id": entry.id]).1)
    }

    // MARK: Runs

    func testRunsLogAppendsReadsTodayAndPrunes() throws {
        let url = try folder().appendingPathComponent("runs.jsonl")
        let runs = OrchestratorRuns(url: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let old = OrchestratorRun(at: now.addingTimeInterval(-40 * 86_400), trigger: "ask", model: "m", costUSD: 1)
        try runs.append(old, now: old.at)
        try runs.append(OrchestratorRun(at: now.addingTimeInterval(-86_400), trigger: "ask", model: "m", costUSD: 0.5), now: now)
        try runs.append(OrchestratorRun(at: now, trigger: "triage", model: "haiku", durationMs: 1200, inputTokens: 10, outputTokens: 5,
                                        cacheReadTokens: 900, costUSD: 0.01), now: now)
        XCTAssertEqual(runs.load().count, 2, "a 40-day-old run is dropped when the file is rewritten")
        XCTAssertEqual(runs.today(now: now, calendar: calendar).map(\.trigger), ["triage"])
        XCTAssertEqual(runs.recent(1).first?.cacheReadTokens, 900)
        XCTAssertEqual(try mode(url), 0o600)
        // Other writers' lines: ISO dates and missing numbers are fine; junk lines are skipped.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("not json\n{\"at\":\"2026-11-07T10:00:00Z\",\"trigger\":\"morning\",\"model\":\"haiku\",\"costUSD\":0.02}\n".utf8))
        try handle.close()
        XCTAssertEqual(runs.load().map(\.trigger), ["ask", "triage", "morning"])
        let line = String(decoding: try OrchestratorRuns.encode(runs.load()[1]), as: UTF8.self)
        for key in ["\"at\"", "\"trigger\"", "\"model\"", "\"durationMs\"", "\"inputTokens\"", "\"outputTokens\"", "\"cacheReadTokens\"", "\"costUSD\""] {
            XCTAssertTrue(line.contains(key), line)
        }
    }

    func testResultLineBecomesARun() throws {
        let line = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":61234,"total_cost_usd":0.734,"usage":{"input_tokens":12,"cache_creation_input_tokens":3000,"cache_read_input_tokens":140000,"output_tokens":800},"session_id":"s"}"#
        let events = OrchestratorEvent.parse(Data(line.utf8))
        guard case .run(let run) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(run.durationMs, 61234)
        XCTAssertEqual(run.inputTokens, 3012)
        XCTAssertEqual(run.cacheReadTokens, 140_000)
        XCTAssertEqual(run.outputTokens, 800)
        XCTAssertEqual(run.costUSD, 0.734, accuracy: 0.0001)
        XCTAssertEqual(events.last, .finished(isError: false, message: nil, sessionID: "s"))
    }

    // MARK: To-dos

    func testTodoToolsRecordLocalActionsTheAppAppliesOnceAndCanUndo() throws {
        let todo = OrchestratorState.Todo(text: "Ship it", done: false, day: "2026-11-14", project: nil, id: "abc")
        let tools = try tools(state(projects: ["/Dev/app"], todos: [todo]))
        let (added, error) = tools.call("add_todo", ["text": "Review  the login PR", "project": "app"])
        XCTAssertFalse(error, added)
        XCTAssertTrue(added.hasPrefix("To-do action "), added)
        XCTAssertTrue(tools.call("add_todo", ["text": "ship it"]).0.contains("already on the list"))
        XCTAssertTrue(tools.call("complete_todo", ["id": "nope"]).1)
        XCTAssertFalse(tools.call("complete_todo", ["id": "abc"]).1)
        let store = tools.actions
        XCTAssertTrue(store.load().allSatisfy { $0.isLocal && $0.status == .pending && !$0.isWaiting() }, "never a proposal waiting for Send")
        let claimed = try store.claimLocal(newID: { "client-1" })
        XCTAssertEqual(claimed.map(\.kind), [.addTodo, .completeTodo])
        XCTAssertEqual(claimed[0].text, "Review the login PR")
        XCTAssertEqual(claimed[0].project, "/Dev/app")
        XCTAssertEqual(claimed[0].todoID, "local:client-1")
        XCTAssertEqual(claimed[1].todoID, "abc")
        XCTAssertEqual(try store.claimLocal(), [], "applied once")
        XCTAssertEqual(store.load().first?.headline, "Added to-do “Review the login PR”")
        // The app records what applying did; Undo is offered only for a change that happened.
        try store.recordLocal(claimed[0].id, changed: true, todoID: "local:client-1")
        try store.recordLocal(claimed[1].id, changed: true, todoID: "abc")
        let undone = try XCTUnwrap(try store.undoLocal(claimed[0].id))
        XCTAssertEqual(undone.status, .applied)
        XCTAssertNil(try store.undoLocal(claimed[0].id), "undo happens once")
        XCTAssertEqual(store.load().first?.status, .undone)
        let later = Date().addingTimeInterval(2 * 86_400)
        XCTAssertFalse(store.load()[1].canUndo(now: later), "Undo lasts a day")
    }

    func testTodoAddCarriesItsSourceAndOldQueuesStillRead() throws {
        let items = TodoLedger.apply(.add(clientId: "c", text: "T", day: "2026-11-14", project: nil, source: "orchestrator"), to: [], now: 1)
        XCTAssertEqual(items.first?.source, "orchestrator")
        XCTAssertEqual(TodoLedger.apply(.add(clientId: "d", text: "T", day: "2026-11-14", project: nil), to: [], now: 1).first?.source, "burro")
        let old = #"[{"add":{"clientId":"c","text":"T","day":"2026-11-14"}}]"#
        let decoded = try JSONDecoder().decode([TodoOp].self, from: Data(old.utf8))
        XCTAssertEqual(decoded, [.add(clientId: "c", text: "T", day: "2026-11-14", project: nil)])
    }

    // MARK: Briefing tools

    func testReadChatSinceReturnsOnlyWhatIsNew() throws {
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        let messages = [ChatMessage(id: 0, kind: .user, text: "Fix login", at: at),
                        ChatMessage(id: 1, kind: .assistant, text: "Done. Should I merge?", at: at.addingTimeInterval(60)),
                        ChatMessage(id: 2, kind: .user, text: "Yes", at: at.addingTimeInterval(120))]
        let chat = AgentSession(id: "claude:\(chatID)", provider: .claude, title: "Login", cwd: "/Dev/app", state: .idle, updatedAt: at, evidence: "fixture")
        var tools = try tools(state(chats: [chat]))
        tools.readChat = { _, _, _, _ in ChatTranscript(messages: messages) }
        let first = tools.call("read_chat", ["id": chatID]).0
        let cursor = try XCTUnwrap(first.components(separatedBy: "cursor: ").last)
        XCTAssertEqual(cursor, OrchestratorTools.cursor(messages[2]))
        XCTAssertTrue(tools.call("read_chat", ["id": chatID, "since": cursor]).0.contains("Nothing new since then."))
        let middle = tools.call("read_chat", ["id": chatID, "since": OrchestratorTools.cursor(messages[0])]).0
        XCTAssertFalse(middle.contains("Fix login")); XCTAssertTrue(middle.contains("Should I merge?"))
        XCTAssertTrue(tools.call("read_chat", ["id": chatID, "since": "ffffffffff"]).0.contains("isn't among"))
        XCTAssertEqual(OrchestratorTools.messages(messages, since: "2026-11-07T10:41:00Z").messages.count,
                       messages.filter { $0.at! > ISO8601DateFormatter().date(from: "2026-11-07T10:41:00Z")! }.count)
    }

    func testChatDigestShowsTheAskTheAnswerTheQuestionAndTheWorktree() throws {
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        let chat = AgentSession(id: "claude:\(chatID)", provider: .claude, title: "Login", cwd: "/Dev/app-wt/login/Sources", state: .idle,
                                updatedAt: at, evidence: "fixture")
        let tree = OrchestratorState.WorktreeRow(path: "/Dev/app-wt/login", repository: "app", repositoryPath: "/Dev/app", branch: "fix-login",
                                                 isPrimary: false, changed: 3, untracked: 1, unpushed: 2, lastCommit: nil, activity: "Idle", readyToRemove: false)
        var tools = try tools(state(worktrees: [tree], chats: [chat]))
        tools.readChat = { _, _, _, limit in
            XCTAssertLessThanOrEqual(limit, 40)
            return ChatTranscript(messages: [ChatMessage(id: 0, kind: .user, text: "Fix the login bug", at: at),
                                             ChatMessage(id: 1, kind: .tool, text: "swift test", tool: "Bash", output: "ok"),
                                             ChatMessage(id: 2, kind: .assistant, text: "Fixed and tested.\n\nTests pass. Should I open a PR?", at: at)])
        }
        let (text, error) = tools.call("chat_digest", ["id": chatID])
        XCTAssertFalse(error)
        XCTAssertTrue(text.contains("Worktree: fix-login · 3 changed · 1 untracked · 2 unpushed"), text)
        XCTAssertTrue(text.contains("Last from the user"), text)
        XCTAssertTrue(text.contains("Ends on: Should I open a PR?"), text)
        XCTAssertFalse(text.contains("swift test"), "no tool bodies")
        XCTAssertNil(OrchestratorTools.pendingQuestion([ChatMessage(id: 0, kind: .assistant, text: "All done.")], waiting: false))
        XCTAssertEqual(OrchestratorTools.pendingQuestion([ChatMessage(id: 0, kind: .tool, text: "Pick one", tool: "AskUserQuestion")], waiting: true),
                       "asks the user: Pick one")
    }

    func testNotesUsageAndShippedComeOnlyFromTheSnapshot() throws {
        let now = Date()
        let closed = try tools(state(notesAccess: false, notes: [.init(title: "Plan", text: "secret plan", updatedAt: now)]))
        let (refused, isError) = closed.call("read_notes", [:])
        XCTAssertTrue(isError); XCTAssertFalse(refused.contains("secret plan"))
        let open = try tools(state(notesAccess: true, notes: [.init(title: "Plan", text: "ship friday", updatedAt: now),
                                                              .init(title: "Groceries", text: "eggs", updatedAt: now)]))
        let notes = open.call("read_notes", ["query": "ship"]).0
        XCTAssertTrue(notes.contains("ship friday")); XCTAssertFalse(notes.contains("eggs"))
        let usage = try tools(state(usage: [.init(provider: "Claude", window: "Session", remainingPercent: 12.4, resetsAt: now.addingTimeInterval(5430))]))
        XCTAssertTrue(usage.call("usage", [:]).0.contains("Claude Session: 12% left, resets in 1h 30m"), usage.call("usage", [:]).0)
        let shipped = try tools(state(shipped: [.init(period: "day", date: "2026-11-13", repository: "o/app", summary: "Login fixed.", merged: ["#12 Fix login (Edgar)"]),
                                                .init(period: "day", date: "2026-11-14", repository: "o/app", summary: nil)]))
        XCTAssertTrue(shipped.call("read_shipped", ["date": "2026-11-13"]).0.contains("#12 Fix login"))
        XCTAssertTrue(shipped.call("read_shipped", [:]).0.contains("2026-11-14"))
        XCTAssertTrue(shipped.call("read_shipped", ["period": "week"]).0.contains("no cached"))
    }

    func testEveryNewToolIsListed() {
        let names = Set(OrchestratorTools.definitions.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["chat_digest", "read_shipped", "usage", "read_notes", "read_file", "search_files",
                                            "add_todo", "complete_todo", "remember", "forget", "read_chat"]))
        XCTAssertFalse(names.contains("Read"))
    }
}

private enum NotesStoreProbe {
    /// Where the Notes store keeps notes.json (Burro's Application Support folder).
    static var burroFolder: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burro").path
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
