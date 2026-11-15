// remote_tail.py run locally under a temporary HOME (the way Burro sends it over SSH), and
// RemoteTranscriptMirror with that script as its transport: appends, no growth, truncation,
// rotation, same-size rewrites, path-hint escapes, framing, a copy that equals one full read, offline
// reads, eviction that spares open chats, and the full-fetch fallback.
import CryptoKit
import XCTest
@testable import BurroCore

final class RemoteTranscriptMirrorTests: XCTestCase {
    let id = "0b6c1f0e-4a8e-4f4e-9d55-3f1f4c2a9e01"
    let host = RemoteHost(name: "Studio", destination: "me@studio")

    // MARK: Fixtures

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rtail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-Users-me-app"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func transcriptURL(_ home: URL) -> URL { home.appendingPathComponent(".claude/projects/-Users-me-app/\(id).jsonl") }

    private func line(_ text: String, role: String = "user") -> String {
        role == "user" ? #"{"type":"user","message":{"content":"\#(text)"}}"# + "\n"
            : #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
    }
    private func lines(_ range: Range<Int>) -> String {
        range.map { line("message \($0) " + String(repeating: "x", count: $0 % 40), role: $0.isMultiple(of: 2) ? "user" : "assistant") }.joined()
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    /// Runs a bundled remote script locally the way Burro sends it over SSH; returns stdout and the stdin size.
    private static func run(_ name: String, input prefix: String, home: URL) throws -> (status: Int32, out: Data, sent: Int) {
        let body = try Data(contentsOf: try XCTUnwrap(RemoteScript.url(name)))
        var input = Data(prefix.utf8)
        input.append(body)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out, input.count)
    }
    private static func tail(_ request: [String: Any], home: URL) throws -> (status: Int32, out: Data, sent: Int) {
        try run("remote_tail", input: "REQUEST_B64 = \"\(try JSONSerialization.data(withJSONObject: request).base64EncodedString())\"\n", home: home)
    }
    private func tail(_ request: [String: Any], home: URL) throws -> (header: [String: Any], body: Data) {
        let result = try Self.tail(request, home: home)
        XCTAssertEqual(result.status, 0)
        let newline = try XCTUnwrap(result.out.firstIndex(of: 0x0A))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: result.out[..<newline]) as? [String: Any])
        let body = Data(result.out[result.out.index(after: newline)...])
        XCTAssertEqual(header["count"] as? Int, body.count, "the header counts exactly the bytes that follow")
        return (header, body)
    }
    private func request(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["provider": "claude", "id": id, "initial": 4 << 20, "cap": 4 << 20].merging(extra) { $1 }
    }
    /// `have` for a copy holding `copy`, as reported by `header`.
    private func have(_ header: [String: Any], copy: Data) -> [String: Any] {
        ["dev": header["dev"]!, "ino": header["ino"]!, "start": header["start"]!, "end": header["end"]!,
         "headHash": SHA256.hash(data: copy.prefix(4096)).map { String(format: "%02x", $0) }.joined()]
    }

    // MARK: remote_tail.py

    func testTheFirstTailStartsAtALineAndThenOnlyNewLinesTravel() throws {
        let home = try makeHome(), url = transcriptURL(home)
        let text = lines(0..<40)
        try Data(text.utf8).write(to: url)
        let first = try tail(request(["initial": 700]), home: home)
        XCTAssertEqual(first.header["mode"] as? String, "reset")
        XCTAssertLessThanOrEqual(first.body.count, 700)
        XCTAssertEqual(Data(text.utf8).suffix(first.body.count), first.body)
        let startIndex = text.utf8.count - first.body.count
        XCTAssertEqual(first.header["start"] as? Int, startIndex)
        XCTAssertEqual(Array(text.utf8)[startIndex - 1], 0x0A, "starts right after a line end")
        XCTAssertEqual(first.header["end"] as? Int, text.utf8.count)

        // Nothing new: an empty append, a tiny reply.
        let have = have(first.header, copy: first.body)
        let idle = try Self.tail(request(["have": have, "pathHint": first.header["path"]!]), home: home)
        XCTAssertEqual(idle.status, 0)
        XCTAssertLessThan(idle.out.count, 300)
        let none = try tail(request(["have": have]), home: home)
        XCTAssertEqual(none.header["mode"] as? String, "append"); XCTAssertEqual(none.body.count, 0)

        // New lines arrive; a line still being written waits for its end.
        try append(line("next", role: "assistant") + #"{"type":"user","mess"#, to: url)
        let grown = try tail(request(["have": have]), home: home)
        XCTAssertEqual(grown.header["mode"] as? String, "append")
        XCTAssertEqual(String(decoding: grown.body, as: UTF8.self), line("next", role: "assistant"))
        XCTAssertEqual(grown.header["end"] as? Int, text.utf8.count + grown.body.count)

        // A small cap sends the whole lines that fit; a single line longer than the window goes in pieces.
        let capped = try tail(request(["have": have, "cap": 200]), home: home)
        XCTAssertEqual(capped.body, grown.body)
        let piece = try tail(request(["have": have, "cap": 10]), home: home)
        XCTAssertEqual(piece.body, grown.body.prefix(10))
    }

    func testTruncatedRotatedAndRewrittenFilesStartOver() throws {
        let home = try makeHome(), url = transcriptURL(home)
        try Data(lines(0..<20).utf8).write(to: url)
        let first = try tail(request(), home: home)
        let have = have(first.header, copy: first.body)

        // Truncated: shorter than the copy.
        try Data(lines(0..<5).utf8).write(to: url)
        XCTAssertEqual(try tail(request(["have": have]), home: home).header["mode"] as? String, "reset")

        // Rotated: a new file renamed over it (another inode), even if longer.
        try Data(lines(0..<20).utf8).write(to: url)
        let again = try tail(request(), home: home)
        let replacement = url.deletingLastPathComponent().appendingPathComponent("new.tmp")
        try Data((lines(0..<20) + lines(20..<22)).utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let rotated = try tail(request(["have": self.have(again.header, copy: again.body)]), home: home)
        XCTAssertEqual(rotated.header["mode"] as? String, "reset")
        XCTAssertNotEqual(rotated.header["ino"] as? Int, again.header["ino"] as? Int)

        // Rewritten in place at the same size: the head hash notices.
        let current = try tail(request(), home: home)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 30); try handle.write(contentsOf: Data("Z".utf8)); try handle.close()
        let rewritten = try tail(request(["have": self.have(current.header, copy: current.body)]), home: home)
        XCTAssertEqual(rewritten.header["ino"] as? Int, current.header["ino"] as? Int)
        XCTAssertEqual(rewritten.header["size"] as? Int, current.header["size"] as? Int)
        XCTAssertEqual(rewritten.header["mode"] as? String, "reset")
    }

    func testEarlierBytesStartAtALineAndStopAtTheCopy() throws {
        let home = try makeHome(), url = transcriptURL(home)
        let text = lines(0..<60)
        try Data(text.utf8).write(to: url)
        let first = try tail(request(["initial": 500]), home: home)
        let earlier = try tail(request(["have": have(first.header, copy: first.body), "earlier": 800]), home: home)
        XCTAssertEqual(earlier.header["mode"] as? String, "prepend")
        XCTAssertEqual(earlier.header["end"] as? Int, first.header["end"] as? Int)
        let start = try XCTUnwrap(earlier.header["start"] as? Int)
        XCTAssertEqual(start + earlier.body.count, first.header["start"] as? Int)
        XCTAssertEqual(Array(text.utf8)[start - 1], 0x0A)
        XCTAssertEqual(earlier.body + first.body, Data(text.utf8).suffix(text.utf8.count - start))
    }

    func testPathHintsCannotLeaveTheProviderFolders() throws {
        let home = try makeHome(), url = transcriptURL(home)
        try Data(lines(0..<3).utf8).write(to: url)
        let outside = home.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("\(id).jsonl")
        try Data(#"{"type":"user","message":{"content":"secret"}}"#.utf8 + [0x0A]).write(to: secret)
        let real = try tail(request(), home: home).header["path"] as? String
        XCTAssertNotNil(real)
        XCTAssertNil(try tail(request(["pathHint": real!]), home: home).header["path"], "a path equal to the hint isn't repeated")

        // Outside the roots, through "..", or another chat's file: ignored, the real file is found instead.
        for hint in [secret.path, home.path + "/.claude/projects/../elsewhere/\(id).jsonl",
                     home.path + "/.claude/projects/-Users-me-app/11111111-2222-4333-8444-555555555555.jsonl"] {
            let reply = try tail(request(["pathHint": hint]), home: home)
            XCTAssertEqual(reply.header["path"] as? String, real, hint)
            XCTAssertFalse(String(decoding: reply.body, as: UTF8.self).contains("secret"))
        }
        // A link inside the roots pointing out is refused, whether hinted or found.
        try FileManager.default.removeItem(at: url)
        let link = url
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertEqual(try tail(request(["pathHint": link.path]), home: home).header["mode"] as? String, "missing")
        XCTAssertEqual(try tail(request(), home: home).header["mode"] as? String, "missing")
        // A linked folder inside the roots is not followed either.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude/projects/linked"), withDestinationURL: outside)
        XCTAssertEqual(try tail(request(["pathHint": home.path + "/.claude/projects/linked/\(id).jsonl"]), home: home).header["mode"] as? String, "missing")
        XCTAssertEqual(try tail(request(), home: home).header["mode"] as? String, "missing")
    }

    func testBadRequestsAreRefusedAndCodexFilesAreFound() throws {
        let home = try makeHome()
        for bad: [String: Any] in [["id": "../../etc/passwd"], ["provider": "shell"], ["initial": 5 << 20], ["cap": true], ["earlier": -1],
                                   ["pathHint": "relative/\(id).jsonl"],
                                   ["have": ["dev": 1, "ino": 2, "start": 5, "end": 4, "headHash": String(repeating: "a", count: 64)]],
                                   ["have": ["dev": 1, "ino": 2, "start": 0, "end": 4, "headHash": "nothex"]]] {
            XCTAssertEqual(try tail(request(bad), home: home).header["mode"] as? String, "error", "\(bad)")
        }
        XCTAssertEqual(try tail(request(), home: home).header["mode"] as? String, "missing")
        let day = home.appendingPathComponent(".codex/sessions/2026/11/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-11-15T10-00-00-\(id).jsonl")
        try Data(#"{"type":"session_meta","payload":{"cwd":"/w"}}"#.utf8 + [0x0A]).write(to: rollout)
        let codex = try tail(request(["provider": "codex"]), home: home)
        XCTAssertEqual(codex.header["mode"] as? String, "reset")
        XCTAssertEqual((codex.header["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, rollout.lastPathComponent)
    }

    // MARK: Mirror

    private func cacheRoot() -> RemoteCache {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rmirror-\(UUID().uuidString)/Remote")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return RemoteCache(root: root)
    }
    private func scriptTransport(home: URL, calls: LockedValue<[Int]>? = nil) -> RemoteTranscriptMirror.Transport {
        { _, request in
            let result = try Self.tail(request, home: home)
            calls?.withLock { $0.append(result.out.count) }
            guard result.status == 0 else { throw ChatTranscripts.LoadError.unavailable("failed") }
            return result.out
        }
    }
    private func workerURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/rust/release/burro-log-worker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("Run script/build_rust_worker.sh for Rust integration tests") }
        return url
    }
    /// A stand-in parser that shows each line of the copy as one message.
    private static let lineParser: RemoteTranscriptMirror.Parser = { path, _, _, _, _ in
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let messages = text.split(separator: "\n").enumerated().map { ChatMessage(id: $0.offset, kind: .user, text: String($0.element)) }
        return .loaded(ChatTranscript(messages: messages), revision: nil)
    }
    private var chatID: String { "remote:\(host.id.uuidString):claude:\(id)" }

    func testAMirrorFollowingAppendsReadsTheSameAsOneFullRead() throws {
        let workerURL = try workerURL()
        let worker = AgentLogWorker(executable: workerURL, retryDelay: 0); defer { worker.stop() }
        let parser: RemoteTranscriptMirror.Parser = { path, provider, root, limit, after in
            try ChatTranscripts.read(file: path, provider: provider, root: root, limit: limit, after: after, worker: worker)
        }
        let home = try makeHome(), url = transcriptURL(home)
        let calls = LockedValue<[Int]>([])
        let mirror = RemoteTranscriptMirror(cache: cacheRoot(), transport: scriptTransport(home: home, calls: calls), parser: parser,
                                            fallback: { _, _, _, _ in XCTFail("no fallback"); throw ChatTranscripts.LoadError.notFound })
        let full = { try ChatTranscripts.read(file: url.path, provider: .claude, root: home.appendingPathComponent(".claude/projects").path,
                                              limit: 300, after: nil, worker: worker).transcript?.messages }
        try Data(lines(0..<10).utf8).write(to: url)
        var outcome = try mirror.refresh(chatID: chatID, host: host)
        XCTAssertEqual(outcome.read.transcript?.messages, try full())
        var revision: UInt64? = { if case .loaded(_, let r) = outcome.read { return r }; return nil }()

        // Nothing new: unchanged, and the reply was only a header.
        outcome = try mirror.refresh(chatID: chatID, host: host, after: revision)
        XCTAssertEqual(outcome.read, .unchanged)
        XCTAssertLessThan(calls.withLock { $0.last ?? 0 }, 300)

        for step in [lines(10..<13), line("half") + #"{"type":"assistant","mes"#, #"sage":{"content":[{"type":"text","text":"done"}]}}"# + "\n", lines(13..<40)] {
            try append(step, to: url)
            outcome = try mirror.refresh(chatID: chatID, host: host, after: revision)
            if case .loaded(_, let r) = outcome.read { revision = r }
            let shown = try XCTUnwrap(mirror.cached(chatID: chatID, host: host)?.read.transcript?.messages)
            XCTAssertEqual(shown, try full())
        }
        // Rotated to a new file: the copy starts over and still matches.
        let replacement = url.deletingLastPathComponent().appendingPathComponent("r.tmp")
        try Data(lines(100..<120).utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        outcome = try mirror.refresh(chatID: chatID, host: host, after: revision)
        XCTAssertEqual(outcome.read.transcript?.messages, try full())
        XCTAssertFalse(outcome.canShowEarlier)
    }

    func testOfflineChatsStayReadableAsOfTheirLastUpdate() throws {
        let home = try makeHome(), url = transcriptURL(home)
        try Data(lines(0..<5).utf8).write(to: url)
        let cache = cacheRoot(), synced = Date(timeIntervalSince1970: 1_800_000_000)
        let online = RemoteTranscriptMirror(cache: cache, transport: scriptTransport(home: home), parser: Self.lineParser)
        _ = try online.refresh(chatID: chatID, host: host, now: synced)
        let unreachable = RemoteTranscriptMirror(cache: cache, transport: { _, _ in throw ChatTranscripts.LoadError.unavailable("Couldn't reach Studio over SSH.") },
                                                 parser: Self.lineParser, fallback: { _, _, _, _ in XCTFail("no fallback"); throw ChatTranscripts.LoadError.notFound })
        let offline = try unreachable.refresh(chatID: chatID, host: host, now: synced.addingTimeInterval(600))
        XCTAssertEqual(offline.read.transcript?.messages.count, 5)
        XCTAssertEqual(offline.offline, .unreachable("Couldn't reach Studio over SSH."))
        XCTAssertEqual(offline.syncedAt, synced)
        // Opening it shows the copy without asking the machine.
        XCTAssertEqual(unreachable.cached(chatID: chatID, host: host)?.read.transcript?.messages.count, 5)
        // A chat never copied keeps today's error.
        let other = "remote:\(host.id.uuidString):claude:11111111-2222-4333-8444-555555555555"
        XCTAssertNil(unreachable.cached(chatID: other, host: host))
        XCTAssertThrowsError(try unreachable.refresh(chatID: other, host: host)) {
            XCTAssertEqual($0 as? ChatTranscripts.LoadError, .unavailable("Couldn't reach Studio over SSH."))
        }
        // Deleted on the machine: still readable, said so.
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try online.refresh(chatID: chatID, host: host).offline, .missing)

        let poll = RemotePollStatus(failures: 2, nextDue: synced.addingTimeInterval(630), failingSince: synced)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RemoteTranscriptMirror.asOfLine(syncedAt: synced, machine: "Studio", offline: .unreachable("x"), poll: poll,
                                                       now: synced.addingTimeInterval(600), timeZone: utc),
                       "As of 08:00 · Studio unreachable · retrying in 30 s")
        XCTAssertEqual(RemoteTranscriptMirror.asOfLine(syncedAt: synced, machine: "Studio", offline: .missing, poll: nil,
                                                       now: synced.addingTimeInterval(60), timeZone: utc), "As of 08:00 · no longer on Studio")
    }

    func testEarlierHistoryGrowsTheCopyBackwards() throws {
        let home = try makeHome(), url = transcriptURL(home)
        // More than one 4 MiB window, so the first copy starts mid-file.
        let big = String(repeating: "y", count: 3000)
        let text = (0..<2000).map { line("m\($0) " + big) }.joined()
        try Data(text.utf8).write(to: url)
        let mirror = RemoteTranscriptMirror(cache: cacheRoot(), transport: scriptTransport(home: home), parser: Self.lineParser)
        let first = try mirror.refresh(chatID: chatID, host: host)
        XCTAssertTrue(first.canShowEarlier)
        let count = try XCTUnwrap(first.read.transcript?.messages.count)
        let more = try mirror.refresh(chatID: chatID, host: host, earlier: true)
        XCTAssertEqual(more.read.transcript?.messages.count, 2000, "the remaining ~1.8 MB fit in one 4 MiB step")
        XCTAssertLessThan(count, 2000)
        XCTAssertFalse(more.canShowEarlier)
        XCTAssertEqual(more.read.transcript?.messages.last?.text, String(line("m1999 " + big).dropLast()))
    }

    func testEvictionNeverRemovesAChatOpenOnScreen() throws {
        let home = try makeHome(), url = transcriptURL(home)
        try Data(lines(0..<5).utf8).write(to: url)
        let otherID = "11111111-2222-4333-8444-555555555555"
        try Data(lines(0..<5).utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("\(otherID).jsonl"))
        let cache = cacheRoot()
        let mirror = RemoteTranscriptMirror(cache: cache, transport: scriptTransport(home: home), parser: Self.lineParser)
        let other = "remote:\(host.id.uuidString):claude:\(otherID)"
        _ = try mirror.refresh(chatID: chatID, host: host)
        _ = try mirror.refresh(chatID: other, host: host)
        var hold: RemoteTranscriptMirror.Hold? = RemoteTranscriptMirror.Hold(chatID: chatID)
        XCTAssertEqual(mirror.sweep(cap: 0), 1)
        XCTAssertNotNil(mirror.cached(chatID: chatID, host: host), "the open chat and its state file stay")
        XCTAssertNil(mirror.cached(chatID: other, host: host))
        XCTAssertEqual(Set(cache.entries(.transcripts, hostID: host.id).map(\.key)), [chatID])
        hold = nil
        XCTAssertNil(hold)
        XCTAssertFalse(RemoteTranscriptMirror.openChats.contains(chatID))
        XCTAssertEqual(mirror.sweep(cap: 0), 1)
        XCTAssertNil(mirror.cached(chatID: chatID, host: host))
        // Files are owner-only.
        _ = try mirror.refresh(chatID: chatID, host: host)
        let folder = cache.root.appendingPathComponent(host.id.uuidString).appendingPathComponent("transcripts")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
    }

    func testWithoutTheScriptOrWorkerOrWithABadReplyTheChatIsFetchedInFull() throws {
        let home = try makeHome()
        try Data(lines(0..<3).utf8).write(to: transcriptURL(home))
        let fetched = LockedValue(0), expected = self.id
        let fallback: RemoteTranscriptMirror.Fallback = { _, provider, id, limit in
            fetched.withLock { $0 += 1 }
            XCTAssertEqual(provider, "claude"); XCTAssertEqual(id, expected); XCTAssertEqual(limit, 300)
            return ChatTranscript(messages: [ChatMessage(id: 0, kind: .user, text: "full")])
        }
        let variants: [RemoteTranscriptMirror] = [
            RemoteTranscriptMirror(cache: cacheRoot(), transport: nil, parser: Self.lineParser, fallback: fallback),
            RemoteTranscriptMirror(cache: cacheRoot(), transport: scriptTransport(home: home), parser: nil, fallback: fallback),
            RemoteTranscriptMirror(cache: cacheRoot(), transport: { _, _ in Data("not a header".utf8) }, parser: Self.lineParser, fallback: fallback),
            RemoteTranscriptMirror(cache: cacheRoot(), transport: { _, _ in Data(#"{"mode":"reset","path":"/x","dev":1,"ino":2,"start":0,"end":3,"size":3,"mtime":1,"count":5}"#.utf8 + [0x0A, 0x61]) },
                                   parser: Self.lineParser, fallback: fallback),
            RemoteTranscriptMirror(cache: cacheRoot(), transport: { _, _ in Data(#"{"mode":"error","count":0}"#.utf8 + [0x0A]) }, parser: Self.lineParser, fallback: fallback),
        ]
        for mirror in variants {
            let outcome = try mirror.refresh(chatID: chatID, host: host)
            XCTAssertFalse(outcome.mirrored)
            XCTAssertEqual(outcome.read.transcript?.messages.first?.text, "full")
        }
        XCTAssertEqual(fetched.withLock { $0 }, variants.count)
        XCTAssertThrowsError(try variants[0].refresh(chatID: "claude:\(id)", host: host))
    }

    func testAppendHeadersMustContinueTheCopy() {
        let state = RemoteTranscriptMirror.State(path: "/h/a.jsonl", dev: 1, ino: 2, start: 10, end: 20, size: 20, mtime: 1,
                                                 headHash: String(repeating: "0", count: 64), syncedAt: Date())
        func header(_ mode: RemoteTranscriptMirror.Header.Mode, start: Int64, end: Int64, ino: UInt64 = 2) -> RemoteTranscriptMirror.Header {
            .init(mode: mode, path: "/h/a.jsonl", dev: 1, ino: ino, start: start, end: end, size: end, mtime: 2, count: 0)
        }
        let three = Data("ab\n".utf8)
        XCTAssertEqual(RemoteTranscriptMirror.change(header(.append, start: 10, end: 23), body: three, have: state), .append(three))
        XCTAssertNil(RemoteTranscriptMirror.change(header(.append, start: 10, end: 24), body: three, have: state))
        XCTAssertNil(RemoteTranscriptMirror.change(header(.append, start: 10, end: 23, ino: 9), body: three, have: state))
        XCTAssertNil(RemoteTranscriptMirror.change(header(.append, start: 10, end: 23), body: three, have: nil))
        XCTAssertEqual(RemoteTranscriptMirror.change(header(.prepend, start: 7, end: 20), body: three, have: state), .prepend(three))
        XCTAssertEqual(RemoteTranscriptMirror.change(header(.reset, start: 0, end: 3), body: three, have: nil), .replace(three))
        XCTAssertNil(RemoteTranscriptMirror.change(header(.reset, start: 0, end: 2), body: Data("ab".utf8), have: nil), "a reset ends at a line end")
        // Requests carry only validated values and stop asking for appends to an oversized copy.
        let request = RemoteTranscriptMirror.request(provider: "claude", id: id, state: state, earlier: true)
        XCTAssertEqual(request["pathHint"] as? String, "/h/a.jsonl"); XCTAssertNotNil(request["have"]); XCTAssertEqual(request["earlier"] as? Int, 4 << 20)
        var huge = state; huge.end = huge.start + RemoteTranscriptMirror.maxCopy + 1
        XCTAssertNil(RemoteTranscriptMirror.request(provider: "claude", id: id, state: huge, earlier: false)["have"])
    }

    /// Bytes on the wire for one refresh of a live chat that didn't change, against the full fetch it replaces.
    func testANothingNewPollIsTinyNextToAFullFetch() throws {
        let home = try makeHome(), url = transcriptURL(home)
        let text = lines(0..<400)
        try Data(text.utf8).write(to: url)
        let first = try tail(request(), home: home)
        let idle = try Self.tail(request(["have": have(first.header, copy: first.body), "pathHint": first.header["path"]!]), home: home)
        let full = try Self.run("remote_transcript", input: "REQUEST = {\"provider\": \"claude\", \"id\": \"\(id)\", \"limit\": 300}\n", home: home)
        XCTAssertEqual(full.status, 0)
        print("wire: tail no-growth sent \(idle.sent) B, received \(idle.out.count) B; full fetch sent \(full.sent) B, received \(full.out.count) B (fixture \(text.utf8.count) B, 400 messages)")
        XCTAssertLessThan(idle.out.count, 300)
        XCTAssertLessThan(idle.out.count * 50, full.out.count)
    }
}
