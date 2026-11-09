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
        try Data([255]).write(to: log)
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
        try Data(record(batch(10, value: "unread")) + [1, 2, 3]).write(to: log)
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
}
