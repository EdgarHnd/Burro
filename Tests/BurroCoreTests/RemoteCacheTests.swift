// The remote cache: owner-only folders and files, host.json round trips and address checks,
// last-seen rows that never count as live, saving only on change, size and eviction, the per-machine
// status line and the poll facts it reads, and media copies re-checked against the remote file.
import Darwin
import XCTest
@testable import BurroCore

final class RemoteCacheTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

    private func makeCache() throws -> RemoteCache {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return RemoteCache(root: base.appendingPathComponent("Remote"))
    }
    private func row(_ host: RemoteHost, _ id: String = "codex:11111111-2222-4333-8444-555555555555", state: AgentState = .working) -> AgentSession {
        var value = AgentSession(id: "remote:\(host.id.uuidString):\(id)", provider: .codex, title: "Fix", cwd: "/Users/me/app",
                                 state: state, updatedAt: t0, evidence: "fixture")
        value.remote = RemoteOrigin(hostID: host.id, hostName: host.name, sampledAt: t0, stale: false)
        return value
    }
    private func mode(_ path: String) -> mode_t {
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0, path); return info.st_mode & 0o777
    }

    // MARK: host.json

    func testSnapshotRoundTripsOwnerOnlyAndStaysOutOfBackups() throws {
        let cache = try makeCache()
        let host = RemoteHost(name: "Studio", destination: "me@studio", port: 2222)
        let probe = RemoteHostSnapshot(host: host, sessions: [row(host)], warnings: ["w"], sampledAt: t0, attemptedAt: t0, state: .online)
        XCTAssertTrue(cache.saveProbe(probe, now: t0))
        let loaded = try XCTUnwrap(cache.load(host))
        XCTAssertEqual(loaded.sessions.map(\.id), probe.sessions.map(\.id))
        XCTAssertEqual(loaded.warnings, ["w"])
        XCTAssertEqual(loaded.sampledAt, t0)
        XCTAssertEqual(loaded.destination, "me@studio"); XCTAssertEqual(loaded.port, 2222)
        XCTAssertEqual(mode(cache.root.path), 0o700)
        XCTAssertEqual(mode(cache.root.appendingPathComponent(host.id.uuidString).path), 0o700)
        XCTAssertEqual(mode(cache.snapshotURL(host.id).path), 0o600)
        XCTAssertEqual(try cache.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testAnotherAddressWipesThatHostsFolder() throws {
        let cache = try makeCache()
        var host = RemoteHost(name: "Studio", destination: "me@studio")
        try cache.update(host, now: t0) { $0.warnings = ["old"] }
        host.destination = "me@other"
        XCTAssertNil(cache.load(host), "data for one address never shows for another")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.root.appendingPathComponent(host.id.uuidString).path))
    }

    func testLoadedChatsShowAsLastSeenNeverLiveUntilAProbe() throws {
        let cache = try makeCache()
        let host = RemoteHost(name: "Studio", destination: "me@studio")
        let foreign = AgentSession(id: "remote:\(UUID().uuidString):codex:x", provider: .codex, title: "x", cwd: "/", state: .working, updatedAt: t0, evidence: "")
        try cache.update(host, now: t0) { $0.sessions = [self.row(host), foreign]; $0.sampledAt = self.t0 }
        let snapshot = try XCTUnwrap(cache.loadAll([host])[host.id]).snapshot(for: host)
        XCTAssertEqual(snapshot.state, .notChecked)
        XCTAssertEqual(snapshot.sessions.count, 1, "rows filed under another host id are dropped")
        let shown = snapshot.displaySessions(now: t0)
        XCTAssertEqual(shown.first?.state, .unknown)
        XCTAssertEqual(shown.first?.remote?.stale, true)
        XCTAssertTrue(shown.first?.evidence.contains("Last observed: Working") == true)
        // A failed first probe keeps showing them, still stale.
        let failed = RemoteHostSnapshot.mergeFailure(host: host, error: "Connection timed out.", previous: snapshot, now: t0)
        XCTAssertEqual(failed.sessions.count, 1)
        XCTAssertEqual(failed.displaySessions(now: t0).first?.remote?.stale, true)
        // Paused hosts aren't loaded.
        var paused = host; paused.enabled = false
        XCTAssertNil(cache.loadAll([paused])[host.id])
    }

    func testProbeIsSavedOnlyWhenSomethingChanged() throws {
        let cache = try makeCache()
        let host = RemoteHost(name: "Studio", destination: "me@studio")
        let probe = RemoteHostSnapshot(host: host, sessions: [row(host)], sampledAt: t0, attemptedAt: t0, state: .online)
        XCTAssertTrue(cache.saveProbe(probe, now: t0))
        var later = probe; later.sampledAt = t0.addingTimeInterval(10)
        later.sessions[0].remote?.sampledAt = t0.addingTimeInterval(10)
        XCTAssertFalse(cache.saveProbe(later, now: t0.addingTimeInterval(10)), "only the sample time moved")
        var changed = later; changed.sessions[0].state = .idle
        XCTAssertTrue(cache.saveProbe(changed, now: t0.addingTimeInterval(20)))
        XCTAssertTrue(cache.saveProbe(changed, now: t0.addingTimeInterval(20 + RemoteCache.unchangedRefresh)), "last seen is refreshed now and then")
        var offline = changed; offline.state = .offline
        XCTAssertFalse(cache.saveProbe(offline, now: t0.addingTimeInterval(9999)))
        // Saving keeps what else host.json remembers.
        try cache.update(host, now: t0) { $0.codexModels = [RemoteCodexModel(LaunchModel(id: "gpt", title: "GPT", efforts: ["low"]))] }
        changed.sessions[0].title = "Renamed"
        XCTAssertTrue(cache.saveProbe(changed, now: t0.addingTimeInterval(30_000)))
        XCTAssertEqual(cache.load(host)?.codexModels?.first?.id, "gpt")
        XCTAssertEqual(cache.load(host)?.sessions.first?.title, "Renamed")
    }

    func testSymlinksAreNeverFollowed() throws {
        let cache = try makeCache()
        let host = RemoteHost(name: "Studio", destination: "me@studio")
        try cache.prepareRoot()
        let elsewhere = cache.root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache.root.appendingPathComponent(host.id.uuidString), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try cache.folder(for: host.id))
        XCTAssertThrowsError(try cache.update(host) { $0.warnings = ["x"] })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        // A host.json that is itself a link isn't read.
        try FileManager.default.removeItem(at: cache.root.appendingPathComponent(host.id.uuidString))
        try cache.update(host, now: t0) { $0.warnings = ["real"] }
        let real = cache.snapshotURL(host.id)
        let copy = elsewhere.appendingPathComponent("host.json")
        try FileManager.default.moveItem(at: real, to: copy)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: copy)
        XCTAssertNil(cache.load(host))
    }

    func testUsageClearAndPrune() throws {
        let cache = try makeCache()
        let a = RemoteHost(name: "A", destination: "a"), b = RemoteHost(name: "B", destination: "b")
        try cache.update(a, now: t0) { $0.warnings = ["x"] }
        try cache.update(b, now: t0) { $0.warnings = ["y"] }
        let media = try cache.directory(.media, hostID: a.id)
        try Data(repeating: 1, count: 5000).write(to: media.appendingPathComponent("0123456789abcdef0123456789abcdef.png"))
        XCTAssertGreaterThan(cache.usage(hostID: a.id), 5000)
        XCTAssertEqual(cache.totalUsage(), cache.usage(hostID: a.id) + cache.usage(hostID: b.id))
        cache.prune(keeping: [a.id])
        XCTAssertEqual(cache.hostIDs(), [a.id])
        cache.clear(hostID: a.id)
        XCTAssertEqual(cache.usage(hostID: a.id), 0)
        try cache.update(b, now: t0) { $0.warnings = ["y"] }
        cache.clearAll()
        XCTAssertEqual(cache.totalUsage(), 0)
    }

    // MARK: Eviction

    private func entry(_ key: String, size: Int64, opened: TimeInterval) -> RemoteCacheEntry {
        RemoteCacheEntry(key: key, file: "\(key).png", remotePath: "/x/\(key).png", size: size, remoteMTime: 1,
                         fetchedAt: t0.addingTimeInterval(opened), openedAt: t0.addingTimeInterval(opened))
    }
    func testEvictionDropsOldThenLeastRecentlyOpenedButNeverAnOpenChat() {
        let now = t0.addingTimeInterval(40 * 86_400)
        let entries = [entry("old", size: 10, opened: 0), entry("a", size: 60, opened: 35 * 86_400),
                       entry("b", size: 60, opened: 36 * 86_400), entry("c", size: 60, opened: 37 * 86_400),
                       entry("open", size: 60, opened: 1)]
        let drop = RemoteCache.evictions(entries, cap: 130, maxAge: 30 * 86_400, now: now, protected: ["open"])
        XCTAssertEqual(Set(drop.map { entries[$0].key }), ["old", "a", "b"])
        XCTAssertTrue(RemoteCache.evictions(entries, cap: 1 << 30, maxAge: 1e9, now: now).isEmpty)
    }
    func testSweepDeletesEvictedFilesAcrossMachines() throws {
        let cache = try makeCache()
        let a = RemoteHost(name: "A", destination: "a"), b = RemoteHost(name: "B", destination: "b")
        for (host, key, opened) in [(a, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0.0), (b, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 100.0)] {
            let dir = try cache.directory(.media, hostID: host.id)
            try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("\(key).png"))
            try cache.record(entry(key, size: 100, opened: opened), .media, hostID: host.id)
        }
        let stray = try cache.directory(.media, hostID: a.id).appendingPathComponent("stray.bin")
        try Data([1]).write(to: stray)
        XCTAssertEqual(cache.sweep(.media, now: t0.addingTimeInterval(200), cap: 150), 1)
        XCTAssertTrue(cache.entries(.media, hostID: a.id).isEmpty, "the least recently opened copy goes first")
        XCTAssertEqual(cache.entries(.media, hostID: b.id).count, 1)
        XCTAssertNotNil(cache.entry(.media, hostID: b.id, key: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertThrowsError(try cache.record(RemoteCacheEntry(key: "k", file: "../../escape", remotePath: "/", size: 1, remoteMTime: 0,
                                                               fetchedAt: t0, openedAt: t0), .media, hostID: a.id))
    }

    // MARK: Media

    func testMediaPlanReusesCurrentCopiesAndAsksBeforeLargeOnes() {
        let cached = entry("k", size: 100, opened: 0)
        XCTAssertEqual(ChatMedia.plan(cached: cached, remote: .init(size: 100, mtime: 1), kind: .image, automatic: true), .useCached)
        XCTAssertEqual(ChatMedia.plan(cached: cached, remote: .init(size: 100, mtime: 2), kind: .image, automatic: true), .fetch, "changed since copied")
        XCTAssertEqual(ChatMedia.plan(cached: cached, remote: nil, kind: .image, automatic: true), .useCached, "unreachable: show the last copy")
        XCTAssertEqual(ChatMedia.plan(cached: nil, remote: nil, kind: .image, automatic: true), .unavailable)
        let big = Int64(ChatMedia.automaticImageLimit + 1)
        XCTAssertEqual(ChatMedia.plan(cached: nil, remote: .init(size: big, mtime: 1), kind: .image, automatic: true), .needsClick(Int(big)))
        XCTAssertEqual(ChatMedia.plan(cached: nil, remote: .init(size: big, mtime: 1), kind: .image, automatic: false), .fetch)
        XCTAssertEqual(ChatMedia.plan(cached: nil, remote: .init(size: 10, mtime: 1), kind: .video, automatic: true), .needsClick(10))
        XCTAssertEqual(ChatMedia.plan(cached: nil, remote: .init(size: 10, mtime: 1), kind: .image, automatic: true), .fetch)
    }

    // MARK: Status line

    func testStatusLine() {
        let host = RemoteHost(name: "Studio", destination: "me@studio")
        let now = t0.addingTimeInterval(6 * 3600 + 12) // 14:00:12 UTC
        let online = RemoteHostSnapshot(host: host, sampledAt: now.addingTimeInterval(-12), attemptedAt: now, state: .online)
        XCTAssertEqual(RemoteStatusLine.text(snapshot: online, poll: .init(), now: now, timeZone: utc), "Connected · checked 12 s ago")
        let since = t0.addingTimeInterval(6 * 3600 - 98) // 13:58:22
        let offline = RemoteHostSnapshot(host: host, attemptedAt: now, state: .offline)
        XCTAssertEqual(RemoteStatusLine.text(snapshot: offline, poll: .init(failures: 2, nextDue: now.addingTimeInterval(30), failingSince: since),
                                             now: now, timeZone: utc), "Unreachable since 13:58 · retrying in 30 s")
        XCTAssertEqual(RemoteStatusLine.text(snapshot: offline, poll: .init(failures: 4, nextDue: now.addingTimeInterval(110), failingSince: since),
                                             now: now, timeZone: utc), "Unreachable since 13:58 · retrying in 2 min")
        XCTAssertEqual(RemoteStatusLine.text(snapshot: offline, poll: .init(failures: 1, nextDue: now, failingSince: since), now: now, timeZone: utc),
                       "Unreachable since 13:58 · retrying now")
        var paused = host; paused.enabled = false
        XCTAssertEqual(RemoteStatusLine.text(snapshot: RemoteHostSnapshot(host: paused), poll: .init(), now: now, timeZone: utc), "Paused")
        let remembered = RemoteHostSnapshot(host: host, sampledAt: t0.addingTimeInterval(-86_400), state: .notChecked)
        XCTAssertEqual(RemoteStatusLine.text(snapshot: remembered, poll: .init(), now: now, timeZone: utc), "Last seen Jan 14, 08:00 · connecting…")
        XCTAssertEqual(RemoteStatusLine.text(snapshot: RemoteHostSnapshot(host: host), poll: .init(), now: now, timeZone: utc), "Connecting…")
        let peer = TailscalePeer(id: "1", hostName: "studio", dnsName: "studio.tail1234.ts.net", os: "macOS", online: true, lastSeen: nil, isSelf: false)
        XCTAssertEqual(TailscalePeer.matching("me@studio", in: [peer]), peer)
        XCTAssertNil(TailscalePeer.matching("me@laptop", in: [peer]))
        XCTAssertEqual(RemoteStatusLine.text(snapshot: offline, poll: .init(failures: 1, nextDue: now.addingTimeInterval(15), failingSince: since),
                                             peer: peer, now: now, timeZone: utc), "Unreachable since 13:58 · retrying in 15 s · Tailscale sees it online")
        var away = peer; away.online = false; away.lastSeen = since
        XCTAssertEqual(RemoteStatusLine.text(snapshot: online, poll: .init(), peer: away, now: now, timeZone: utc), "Connected · checked 12 s ago",
                       "the hint only explains a machine Burro can't reach")
        XCTAssertTrue(RemoteStatusLine.text(snapshot: offline, poll: .init(nextDue: now.addingTimeInterval(15), failingSince: since), peer: away,
                                            now: now, timeZone: utc).hasSuffix("offline on Tailscale since 13:58"))
    }

    func testPollStatusReportsWhenFailingStartedWithoutChangingTheSchedule() {
        let id = UUID()
        var schedule = RemotePollSchedule()
        schedule.recordFailure(id, at: t0)
        schedule.recordFailure(id, at: t0.addingTimeInterval(15))
        XCTAssertEqual(schedule.status(id, fast: true), RemotePollStatus(failures: 2, nextDue: t0.addingTimeInterval(45), failingSince: t0))
        schedule.requestNow([id])
        XCTAssertEqual(schedule.status(id, fast: true).failingSince, t0, "a manual retry isn't a success")
        XCTAssertEqual(schedule.status(id, fast: true).nextDue, .distantPast)
        schedule.recordFailure(id, at: t0.addingTimeInterval(60))
        XCTAssertEqual(schedule.status(id, fast: false).nextDue, t0.addingTimeInterval(120))
        schedule.recordSuccess(id, at: t0.addingTimeInterval(70))
        XCTAssertEqual(schedule.status(id, fast: false), RemotePollStatus(failures: 0, nextDue: t0.addingTimeInterval(130), failingSince: nil))
    }
}
