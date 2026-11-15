// Synthetic LevelDB snapshots cover fragmentation, checksums, tombstones and stale tables.
import XCTest
@testable import BurroCore

final class ChromiumReadStateTests: XCTestCase {
    func testCacheInvalidatesOnOverwriteReplacementDeletionAndFailedRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MANIFEST-000001\n".utf8).write(to: root.appendingPathComponent("CURRENT"))
        try Data(record([2, 3])).write(to: root.appendingPathComponent("MANIFEST-000001"))
        let log = root.appendingPathComponent("000003.log"), cache = ChromiumReadStateCache()
        var loads = 0
        func read() throws -> Data? {
            try cache.value(directory: root, key: "epitaxy-unread-v1") {
                loads += 1; return try ChromiumReadState.readValue(directory: root, key: "epitaxy-unread-v1")
            }
        }
        try Data(record(batch(1, value: "first"))).write(to: log)
        XCTAssertEqual(try read(), Data("first".utf8))
        XCTAssertEqual(try read(), Data("first".utf8)); XCTAssertEqual(loads, 1)
        // Same size and restored mtime still invalidate through ctime.
        let date = try FileManager.default.attributesOfItem(atPath: log.path)[.modificationDate]!
        try Data(record(batch(2, value: "other"))).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: log.path)
        XCTAssertEqual(try read(), Data("other".utf8)); XCTAssertEqual(loads, 2)
        try Data(record(batch(3, value: nil))).write(to: log, options: .atomic)
        XCTAssertNil(try read()); XCTAssertNil(try read()); XCTAssertEqual(loads, 3)
        var corrupt = record(batch(4, value: "bad")); corrupt[0] ^= 1
        try Data(corrupt).write(to: log)
        XCTAssertThrowsError(try read()); XCTAssertEqual(loads, 4)
        // An unchanged failing database reports the failure again without being parsed again.
        XCTAssertThrowsError(try read()); XCTAssertEqual(loads, 4)
        try FileManager.default.removeItem(at: log)
        XCTAssertNil(try read()); XCTAssertEqual(loads, 5)
        try Data(record(batch(5, value: "again"))).write(to: log)
        XCTAssertEqual(try read(), Data("again".utf8)); XCTAssertEqual(loads, 6)
    }
    func testCacheRejectsChangesDuringDecodeAndMissingCurrent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("CURRENT"), cache = ChromiumReadStateCache()
        try Data("first".utf8).write(to: current)
        XCTAssertThrowsError(try cache.value(directory: root, key: "test") {
            try Data("changed".utf8).write(to: current); return Data("stale".utf8)
        })
        XCTAssertEqual(try cache.value(directory: root, key: "test") { Data("fresh".utf8) }, Data("fresh".utf8))
        try FileManager.default.removeItem(at: current)
        XCTAssertThrowsError(try cache.value(directory: root, key: "test") { Data("stale".utf8) })
    }
    func fixed(_ n: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    func vi(_ n: Int) -> [UInt8] {
        var n = n, bytes: [UInt8] = []
        while n >= 128 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }; return bytes + [UInt8(n)]
    }
    func record(_ payload: [UInt8], kind: UInt8 = 1) -> [UInt8] {
        fixed(UInt64(ChromiumReadState.checksum([kind] + payload)), 4) + fixed(UInt64(payload.count), 2) + [kind] + payload
    }
    func string(_ value: [UInt8]) -> [UInt8] { vi(value.count) + value }
    var key: [UInt8] { Array("_https://claude.ai\0\u{1}epitaxy-unread-v1".utf8) }
    func batch(_ sequence: Int, value: String?) -> [UInt8] {
        fixed(UInt64(sequence), 8) + fixed(1, 4) + [value == nil ? 0 : 1] + string(key) + (value.map { string([1] + Array($0.utf8)) } ?? [])
    }
    func testCurrentManifestAndNewestLogWinThenTombstoneClears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MANIFEST-000001\n".utf8).write(to: root.appendingPathComponent("CURRENT"))
        try Data(record([2, 3])).write(to: root.appendingPathComponent("MANIFEST-000001"))
        // An obsolete table is ignored even if unreadable; it must not resurrect an old marker.
        try Data([255]).write(to: root.appendingPathComponent("000002.ldb"))
        let log = root.appendingPathComponent("000003.log")
        try Data(record(batch(10, value: "unread")) + record(batch(11, value: "read"))).write(to: log)
        XCTAssertEqual(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"), Data("read".utf8))
        try Data(record(batch(10, value: "unread")) + record(batch(12, value: nil))).write(to: log)
        XCTAssertNil(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"))
        // A half-written tail of a live log ends it; a bad checksum before the end does not.
        try Data(record(batch(10, value: "unread")) + [1, 2, 3]).write(to: log)
        XCTAssertEqual(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"), Data("unread".utf8))
        var corrupt = record(batch(10, value: "unread")); corrupt[0] ^= 1
        try Data(corrupt + record(batch(11, value: "read"))).write(to: log)
        XCTAssertThrowsError(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"))
    }
    func testFragmentationChecksumAndSnappyCopies() throws {
        let first = Array(repeating: UInt8(65), count: 32761), second: [UInt8] = [66, 67]
        XCTAssertEqual(try ChromiumReadState.records(record(first, kind: 2) + record(second, kind: 4)), [first + second])
        var bad = record([1, 2, 3]); bad[0] ^= 1
        XCTAssertThrowsError(try ChromiumReadState.records(bad))
        XCTAssertEqual(try ChromiumReadState.snappy([8, 4, 65, 66, 22, 2, 0]), Array("ABABABAB".utf8))
        XCTAssertThrowsError(try ChromiumReadState.snappy([8, 22, 0, 0]))
        XCTAssertThrowsError(try ChromiumReadState.snappy([1, 4, 65, 66]))
    }
    func testTableRestartKeyCompressionAndBounds() throws {
        let block = [UInt8](arrayLiteral: 0, 3, 1, 97, 98, 99, 49, 2, 1, 1, 100, 50) + fixed(0, 4) + fixed(1, 4)
        let rows = try ChromiumReadState.entries(block)
        XCTAssertEqual(rows.map { String(decoding: $0.0, as: UTF8.self) }, ["abc", "abd"])
        XCTAssertEqual(rows.map { $0.1 }, [[49], [50]])
        XCTAssertThrowsError(try ChromiumReadState.entries([255, 255, 255, 255]))
    }
    func testManifestSelectedTableAndIndexedPreferenceBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func block(_ entries: [([UInt8], [UInt8])]) -> [UInt8] {
            var result: [UInt8] = []
            for (k, v) in entries { result += [0] + vi(k.count) + vi(v.count) + k + v }
            return result + fixed(0, 4) + fixed(1, 4)
        }
        func wrapped(_ b: [UInt8]) -> [UInt8] { b + [0] + fixed(UInt64(ChromiumReadState.checksum(b + [0])), 4) }
        let internalKey = key + fixed((55 << 8) | 1, 8)
        let beforeKey = Array("_https://claude.ai\0\u{1}aaa".utf8) + fixed((50 << 8) | 1, 8)
        let before = block([(beforeKey, [1] + Array("unrelated".utf8))])
        let data = block([(internalKey, [1] + Array("unread".utf8))])
        let index = block([(beforeKey, vi(0) + vi(before.count)), (internalKey, vi(before.count + 5) + vi(data.count))])
        let offset = before.count + data.count + 10
        var footer = vi(0) + vi(0) + vi(offset) + vi(index.count)
        footer += Array(repeating: 0, count: 40 - footer.count); footer += fixed(0xdb4775248b80fb57, 8)
        let file = wrapped(before) + wrapped(data) + wrapped(index) + footer
        try Data(file).write(to: root.appendingPathComponent("000002.ldb"))
        let edit = [2, 3, 7, 0, 2] + vi(file.count) + string(beforeKey) + string(internalKey)
        try Data(record(edit)).write(to: root.appendingPathComponent("MANIFEST-000001"))
        try Data("MANIFEST-000001\n".utf8).write(to: root.appendingPathComponent("CURRENT"))
        XCTAssertEqual(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"), Data("unread".utf8))
        try Data(record(batch(56, value: nil))).write(to: root.appendingPathComponent("000003.log"))
        XCTAssertNil(try ChromiumReadState.value(directory: root, key: "epitaxy-unread-v1"))
    }

    /// Frames payloads the way LevelDB's log writer does: records split at 32 KiB block
    /// boundaries, a tail shorter than a header zero-padded, and a FIRST record with no payload
    /// when exactly one header fits before the block end.
    func log(_ payloads: [[UInt8]], startingAt start: Int = 0) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: start)
        for payload in payloads {
            var rest = payload[...], begin = true
            repeat {
                let left = 32768 - out.count % 32768
                if left < 7 { out += [UInt8](repeating: 0, count: left); continue }
                let take = min(rest.count, left - 7), end = take == rest.count
                let kind: UInt8 = begin && end ? 1 : begin ? 2 : end ? 4 : 3
                out += record(Array(rest.prefix(take)), kind: kind); rest = rest.dropFirst(take); begin = false
                if end { break }
            } while true
        }
        return Array(out.dropFirst(start))
    }
    func payload(_ count: Int, _ seed: UInt8) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed } }
    func testLogRecordsSpanBlocksAndSkipPadding() throws {
        // A record spanning three blocks, then one ending 3 bytes before a block end (padding).
        let big = payload(70_000, 1), padded = payload(32768 * 3 - 3 - (70_000 + 3 * 7) - 7, 2), next = payload(10, 3)
        var bytes = log([big, padded])
        XCTAssertEqual(32768 - bytes.count % 32768, 3)
        bytes = log([big, padded, next])
        XCTAssertEqual(try ChromiumReadState.records(bytes), [big, padded, next])
    }
    func testFirstRecordWithNoPayloadAtBlockEnd() throws {
        // Exactly one header fits before the block end: LevelDB writes an empty FIRST there.
        let filler = payload(32768 - 7 - 7, 4), spanning = payload(100, 5)
        let bytes = log([filler, spanning])
        XCTAssertEqual(Array(bytes[32761..<32768]), record([], kind: 2))
        XCTAssertEqual(try ChromiumReadState.records(bytes), [filler, spanning])
    }
    func testTruncatedOrZeroFilledTailEndsTheLog() throws {
        let first = payload(500, 6), second = payload(900, 7), bytes = log([first, second])
        // The last record cut inside its payload, and inside its header.
        XCTAssertEqual(try ChromiumReadState.records(Array(bytes.dropLast(100))), [first])
        XCTAssertEqual(try ChromiumReadState.records(Array(bytes.prefix(507 + 4))), [first])
        // A preallocated, zero-filled tail running across a block boundary.
        XCTAssertEqual(try ChromiumReadState.records(bytes + [UInt8](repeating: 0, count: 40_000)), [first, second])
        // A fragmented record whose later pieces were not written yet.
        let spanning = log([first, payload(40_000, 8)])
        XCTAssertEqual(try ChromiumReadState.records(Array(spanning.prefix(32768))), [first])
    }
    func testCorruptChecksumMidLogIsReported() throws {
        var bytes = log([payload(500, 9), payload(40_000, 10), payload(20, 11)])
        bytes[600] ^= 0x40
        XCTAssertThrowsError(try ChromiumReadState.records(bytes)) { XCTAssertEqual($0 as? ChromiumReadState.Failure, .corrupt) }
        // A length running past its block is corruption, not a short file.
        var long = record(payload(10, 12)); long[4] = 0xff; long[5] = 0x7f
        XCTAssertThrowsError(try ChromiumReadState.records(long + [UInt8](repeating: 1, count: 40_000)))
        // A LAST or MIDDLE without a FIRST is a broken sequence.
        XCTAssertThrowsError(try ChromiumReadState.records(record([1], kind: 4)))
    }
    func testCodexReadStateIsReusedUntilItsFilesChange() throws {
        let codex = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codex) }
        let state = codex.appendingPathComponent(".codex-global-state.json"), wal = codex.appendingPathComponent("state_5.sqlite-wal")
        try Data("{}".utf8).write(to: state); try Data("db".utf8).write(to: codex.appendingPathComponent("state_5.sqlite"))
        let cache = CodexReadStateCache()
        var result: Result<Set<String>, Error> = .success(["a"])
        func read() throws -> Set<String> { try cache.value(codex: codex) { try result.get() } }
        XCTAssertEqual(try read(), ["a"]); XCTAssertEqual(try read(), ["a"]); XCTAssertEqual(cache.loads, 1)
        // A new WAL file, then a write to it, invalidate the cached set.
        result = .success(["b"]); try Data("w".utf8).write(to: wal)
        XCTAssertEqual(try read(), ["b"]); XCTAssertEqual(cache.loads, 2)
        result = .success(["c"]); try Data("ww".utf8).write(to: wal)
        XCTAssertEqual(try read(), ["c"]); XCTAssertEqual(cache.loads, 3)
        // A failure is reported again, unparsed, until the state file changes.
        result = .failure(CocoaError(.coderReadCorrupt)); try Data("{ }".utf8).write(to: state)
        XCTAssertThrowsError(try read()); XCTAssertThrowsError(try read()); XCTAssertEqual(cache.loads, 4)
        result = .success(["d"]); try Data("{  }".utf8).write(to: state, options: .atomic)
        XCTAssertEqual(try read(), ["d"]); XCTAssertEqual(cache.loads, 5)
        // A newer database file is picked up too.
        result = .success(["e"]); try Data("db".utf8).write(to: codex.appendingPathComponent("state_6.sqlite"))
        XCTAssertEqual(try read(), ["e"]); XCTAssertEqual(cache.loads, 6)
    }
}
