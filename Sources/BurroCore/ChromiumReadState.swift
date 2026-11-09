// Read one allowlisted Chromium preference without opening, locking, or modifying its LevelDB.
import Foundation

enum ChromiumReadState {
    enum Failure: Error { case unsupported, corrupt, changed }
    static let limit = 64 * 1024 * 1024
    struct Cursor {
        var bytes: [UInt8]; var position = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position <= bytes.count, count <= bytes.count - position else { throw Failure.corrupt }
            defer { position += count }; return Array(bytes[position..<position + count])
        }
        mutating func fixed(_ count: Int) throws -> UInt64 {
            guard (0...8).contains(count), position <= bytes.count, count <= bytes.count - position else { throw Failure.corrupt }
            var value: UInt64 = 0
            for offset in 0..<count { value |= UInt64(bytes[position + offset]) << (offset * 8) }
            position += count
            return value
        }
        mutating func varint() throws -> Int {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let byte = try fixed(1)
                guard shift < 63 || byte <= 1 else { throw Failure.corrupt }
                value |= (byte & 127) << shift
                if byte < 128 { guard value <= Int.max else { throw Failure.corrupt }; return Int(value) }
            }
            throw Failure.corrupt
        }
        mutating func string() throws -> [UInt8] { try take(varint()) }
    }
    static func read(_ url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.unsupported }
        return Array(data)
    }
    private static let crcTable: [UInt32] = (0..<256).map { input in
        var value = UInt32(input)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0x82f63b78 : 0) }
        return value
    }
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = .max
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        crc = ~crc
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }
    static func records(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var c = Cursor(bytes: bytes), fragment: [UInt8] = [], result: [[UInt8]] = []
        while c.position < bytes.count {
            let remaining = 32768 - c.position % 32768
            if remaining < 7 { _ = try c.take(min(remaining, bytes.count - c.position)); continue }
            guard bytes.count - c.position >= 7 else { throw Failure.changed }
            let crc = try c.fixed(4), length = Int(try c.fixed(2)), kind = try c.fixed(1)
            if kind == 0 && length == 0 {
                _ = try c.take(min(remaining - 7, bytes.count - c.position)); continue
            }
            guard length <= remaining - 7 else { throw Failure.corrupt }
            let payload = try c.take(length)
            guard checksum([UInt8(kind)] + payload) == crc else { throw Failure.corrupt }
            switch kind {
            case 1: guard fragment.isEmpty else { throw Failure.corrupt }; result.append(payload)
            case 2: guard fragment.isEmpty else { throw Failure.corrupt }; fragment = payload
            case 3: guard !fragment.isEmpty else { throw Failure.corrupt }; fragment += payload
            case 4: guard !fragment.isEmpty else { throw Failure.corrupt }; result.append(fragment + payload); fragment = []
            default: throw Failure.unsupported
            }
        }
        guard fragment.isEmpty else { throw Failure.changed }
        return result
    }
    static func snappy(_ input: [UInt8]) throws -> [UInt8] {
        var c = Cursor(bytes: input), output: [UInt8] = []
        let expected = try c.varint()
        guard expected <= limit else { throw Failure.unsupported }
        output.reserveCapacity(expected)
        while c.position < input.count {
            let tag = Int(try c.fixed(1)), kind = tag & 3
            if kind == 0 {
                let n = tag >> 2
                let length = n < 60 ? n + 1 : Int(try c.fixed(n - 59)) + 1
                guard length <= expected - output.count else { throw Failure.corrupt }
                output += try c.take(length)
            } else {
                let length = kind == 1 ? 4 + ((tag >> 2) & 7) : 1 + (tag >> 2)
                let offset = kind == 1 ? ((tag & 224) << 3) + Int(try c.fixed(1)) : Int(try c.fixed(kind == 2 ? 2 : 4))
                guard offset > 0, offset <= output.count, length <= expected - output.count else { throw Failure.corrupt }
                for _ in 0..<length { output.append(output[output.count - offset]) }
            }
        }
        guard output.count == expected else { throw Failure.corrupt }; return output
    }
    static func entries(_ bytes: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard bytes.count >= 4 else { throw Failure.corrupt }
        var footer = Cursor(bytes: Array(bytes.suffix(4)))
        let count = Int(try footer.fixed(4))
        guard count > 0, count <= (bytes.count - 4) / 4 else { throw Failure.corrupt }
        let end = bytes.count - 4 - 4 * count
        var c = Cursor(bytes: Array(bytes.prefix(end))), last: [UInt8] = [], result: [([UInt8], [UInt8])] = []
        while c.position < end {
            let shared = try c.varint(), size = try c.varint(), valueSize = try c.varint()
            guard shared <= last.count else { throw Failure.corrupt }
            let key = Array(last.prefix(shared)) + (try c.take(size))
            result.append((key, try c.take(valueSize))); last = key
        }
        return result
    }
    static func block(_ file: [UInt8], handle: inout Cursor) throws -> [UInt8] {
        let offset = try handle.varint(), size = try handle.varint()
        guard offset <= file.count, size <= file.count - offset - 5 else { throw Failure.corrupt }
        let bytes = Array(file[offset..<offset + size]), kind = file[offset + size]
        var crc = Cursor(bytes: Array(file[offset + size + 1..<offset + size + 5]))
        guard checksum(bytes + [kind]) == (try crc.fixed(4)) else { throw Failure.corrupt }
        switch kind { case 0: return bytes; case 1: return try snappy(bytes); default: throw Failure.unsupported }
    }
    // Follow CURRENT + MANIFEST; obsolete tables must never resurrect deleted unread markers.
    private static let cache = ChromiumReadStateCache()
    static func value(directory: URL, key: String) throws -> Data? {
        try cache.value(directory: directory, key: key) { try readValue(directory: directory, key: key) }
    }
    static func readValue(directory: URL, key: String) throws -> Data? {
        let current = try read(directory.appendingPathComponent("CURRENT"))
        let manifestName = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard manifestName.hasPrefix("MANIFEST-"), Int(manifestName.dropFirst(9)) != nil else { throw Failure.corrupt }
        let manifestURL = directory.appendingPathComponent(manifestName), manifest = try read(manifestURL)
        var tables = Set<Int>(), logNumber = 0, previousLog = 0
        for record in try records(manifest) {
            var c = Cursor(bytes: record)
            while c.position < record.count {
                switch try c.varint() {
                case 1: _ = try c.string()
                case 2: logNumber = try c.varint()
                case 3, 4: _ = try c.varint()
                case 5: _ = try c.varint(); _ = try c.string()
                case 6: _ = try c.varint(); tables.remove(try c.varint())
                case 7:
                    _ = try c.varint(); tables.insert(try c.varint()); _ = try c.varint()
                    _ = try c.string(); _ = try c.string()
                case 9: previousLog = try c.varint()
                default: throw Failure.unsupported
                }
            }
        }
        guard tables.count <= 256 else { throw Failure.unsupported }
        let wanted = Array(("_https://claude.ai\0\u{1}" + key).utf8)
        var best: (UInt64, [UInt8]?)?
        func accept(_ k: [UInt8], _ value: [UInt8]?, _ sequence: UInt64) {
            if k == wanted, best == nil || sequence > best!.0 { best = (sequence, value) }
        }
        for number in tables {
            let url = directory.appendingPathComponent(String(format: "%06d.ldb", number)), file = try read(url)
            guard file.count >= 48 else { throw Failure.corrupt }
            var magic = Cursor(bytes: Array(file.suffix(8)))
            guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw Failure.unsupported }
            var footer = Cursor(bytes: Array(file.suffix(48)))
            _ = try footer.varint(); _ = try footer.varint()
            var previous: [UInt8]?
            for (upperKey, dataHandle) in try entries(block(file, handle: &footer)) {
                guard upperKey.count >= 8 else { throw Failure.corrupt }
                let upper = Array(upperKey.dropLast(8))
                if let previous, wanted.lexicographicallyPrecedes(previous) { break }
                previous = upper
                if upper.lexicographicallyPrecedes(wanted) { continue }
                // The table index isolates the preference's block. Unrelated values are
                // neither decompressed nor parsed; duplicate versions may cross a boundary.
                var h = Cursor(bytes: dataHandle)
                for (k, v) in try entries(block(file, handle: &h)) {
                    guard k.count >= 8 else { throw Failure.corrupt }
                    var tagCursor = Cursor(bytes: Array(k.suffix(8))); let tag = try tagCursor.fixed(8)
                    guard tag & 255 <= 1 else { throw Failure.unsupported }
                    accept(Array(k.dropLast(8)), tag & 255 == 1 ? v : nil, tag >> 8)
                }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let logs = files.filter { $0.pathExtension == "log" && Int($0.deletingPathExtension().lastPathComponent).map { $0 >= logNumber || $0 == previousLog } == true }
        guard logs.count <= 64 else { throw Failure.unsupported }
        for file in logs {
            for record in try records(read(file)) {
                var c = Cursor(bytes: record); let sequence = try c.fixed(8), count = Int(try c.fixed(4))
                guard count <= record.count, sequence <= (1 << 56) - 1 - UInt64(count) else { throw Failure.corrupt }
                for index in 0..<count {
                    let kind = try c.fixed(1), k = try c.string()
                    guard kind <= 1 else { throw Failure.unsupported }
                    accept(k, kind == 1 ? try c.string() : nil, sequence + UInt64(index))
                }
                guard c.position == record.count else { throw Failure.corrupt }
            }
        }
        guard try read(directory.appendingPathComponent("CURRENT")) == current, try read(manifestURL) == manifest else { throw Failure.changed }
        guard let bytes = best?.1, let encoding = bytes.first else { return nil }
        switch encoding {
        case 1: return String(bytes: bytes.dropFirst(), encoding: .isoLatin1)?.data(using: .utf8)
        case 0: return String(bytes: bytes.dropFirst(), encoding: .utf16LittleEndian)?.data(using: .utf8)
        default: throw Failure.unsupported
        }
    }
}
