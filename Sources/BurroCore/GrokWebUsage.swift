// Decode only the known Grok billing message fields, with bounded gRPC framing and protobuf reads.
// Wire layout reference: https://github.com/steipete/CodexBar (GrokWebBillingFetcher, MIT).
import Foundation

public enum GrokWebUsage {
    static func read(token: String, session: URLSession) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0, 0, 0, 0, 2, 8, 0]) // Read-only GetGrokCreditsConfig request.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("Burro/0.6.0", forHTTPHeaderField: "User-Agent")
        return try decode(await UsageHTTP.get(request, session: session))
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> ProviderUsage {
        guard data.count <= UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
        let bytes = Array(data)
        var offset = 0, frames: [[UInt8]] = []
        while offset < bytes.count {
            guard offset + 5 <= bytes.count else { throw UsageIssue.unsupported }
            let flag = bytes[offset]
            let length = (1...4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            offset += 5
            guard length <= bytes.count - offset, flag == 0 || flag == 128 else { throw UsageIssue.unsupported }
            let payload = Array(bytes[offset..<(offset + length)]); offset += length
            if flag == 128 {
                guard let text = String(bytes: payload, encoding: .utf8) else { throw UsageIssue.unsupported }
                for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("grpc-status:") {
                    guard Int(line.dropFirst(12).trimmingCharacters(in: .whitespaces)) == 0 else { throw UsageIssue.unavailable }
                }
            } else { frames.append(payload) }
            guard frames.count <= 1 else { throw UsageIssue.unsupported }
        }
        guard let frame = frames.first else { throw UsageIssue.unsupported }
        let root = try fields(frame)
        guard root.filter({ $0.number == 1 }).count == 1, let body = root.first(where: { $0.number == 1 })?.bytes else { throw UsageIssue.unsupported }
        let config = try fields(body)
        let published = config.filter { $0.number == 1 }
        guard published.count <= 1 else { throw UsageIssue.unsupported }
        let period = try config.first(where: { $0.number == 8 })?.bytes.map(fields) ?? []
        let kind = period.first(where: { $0.number == 1 })?.integer
        let start = try timestamp(period.first(where: { $0.number == 2 }))
        let end = try timestamp(period.first(where: { $0.number == 3 }))
        let explicitReset = try timestamp(config.first(where: { $0.number == 5 }))
        let activePeriod = (kind == 1 || kind == 2) && start.map { $0 <= now } == true && end.map { $0 > now } == true
        let used: Double
        if let field = published.first, let float = field.float, float.isFinite, (0...100).contains(float) { used = float }
        else if published.isEmpty && activePeriod { used = 0 } // Proto3's omitted scalar defaults to zero only in a validated active message.
        else { throw UsageIssue.unsupported }
        let reset = explicitReset ?? end
        let duration: Double? = start.flatMap { start in end.flatMap { end in
            end > start && reset == end ? end.timeIntervalSince(start) : nil
        } }
        let title = duration.map { $0 <= 8 * 86400 ? "Weekly credits" : "Monthly credits" } ?? "Subscription credits"
        var result = ProviderUsage(id: .grok, updatedAt: now, windows: [UsageWindow(id: "credits", title: title,
            remainingPercent: 100 - used, resetsAt: reset, duration: duration)])
        var shares: [UsageProductShare] = []
        for entry in config.filter({ $0.number == 7 }) {
            guard let bytes = entry.bytes else { continue }
            let value = try fields(bytes)
            guard let id = value.first(where: { $0.number == 1 })?.integer else { continue }
            let percent = value.first(where: { $0.number == 2 })?.float ?? 0
            let title = id == 2 ? "Grok Build" : (id == 4 ? "Grok Chat" : "Other product")
            guard percent.isFinite, (0...100).contains(percent) else { continue }
            shares.append(UsageProductShare(id: String(id), title: title, usedPercent: percent))
        }
        if abs(shares.reduce(0) { $0 + $1.usedPercent } - used) <= 0.1, Set(shares.map(\.id)).count == shares.count { result.products = shares }
        return result
    }
    private struct Field {
        var number: Int
        var integer: UInt64? = nil
        var float: Double? = nil
        var bytes: [UInt8]? = nil
    }
    private static func timestamp(_ field: Field?) throws -> Date? {
        guard let body = field?.bytes else { return nil }
        guard let seconds = try fields(body).first(where: { $0.number == 1 })?.integer,
              seconds <= 253402300799 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }
    private static func fields(_ data: [UInt8]) throws -> [Field] {
        var offset = 0, result: [Field] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<10 {
                guard offset < data.count else { throw UsageIssue.unsupported }
                let byte = data[offset]; offset += 1
                guard i < 9 || byte <= 1 else { throw UsageIssue.unsupported }
                value |= UInt64(byte & 127) << (i * 7)
                if byte < 128 { return value }
            }
            throw UsageIssue.unsupported
        }
        while offset < data.count {
            guard result.count < 10000 else { throw UsageIssue.unsupported }
            let tag = try varint(), number = Int(tag >> 3)
            guard number > 0 && number <= 536870911 else { throw UsageIssue.unsupported }
            var field = Field(number: number)
            switch tag & 7 {
            case 0: field.integer = try varint()
            case 1:
                guard offset + 8 <= data.count else { throw UsageIssue.unsupported }
                offset += 8 // Unknown fixed64 fields are never reinterpreted as quota floats.
            case 2:
                let size = try varint()
                guard size <= data.count - offset else { throw UsageIssue.unsupported }
                field.bytes = Array(data[offset..<(offset + Int(size))]); offset += Int(size)
            case 5:
                guard offset + 4 <= data.count else { throw UsageIssue.unsupported }
                let bits = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
                field.float = Double(Float(bitPattern: bits)); offset += 4
            default: throw UsageIssue.unsupported
            }
            result.append(field)
        }
        return result
    }
}
