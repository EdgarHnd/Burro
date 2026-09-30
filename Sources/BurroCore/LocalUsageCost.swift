// Bounded, on-demand token accounting from local metadata; never uploads or retains conversation text.
import Foundation
import CryptoKit

public struct LocalUsageRecord: Sendable {
    public var key: String
    public var date: Date
    public var model: String
    public var input: Double
    public var cached: Double
    public var cacheWrite: Double
    public var cacheWriteHour: Double
    public var output: Double
    public var total: Double { input + cached + cacheWrite + cacheWriteHour + output }
    public var apiValue: Double? { ReferenceTokenPrices.value(self) }
}
public struct LocalUsageDay: Identifiable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var tokens: Double
    public var apiValue: Double
    public var pricedRecords: Int
}
public struct LocalUsageCost: Sendable {
    public var days: [LocalUsageDay]
    public var models: [String: Double]
    public var recordCount: Int
    public var pricedCount: Int
    public var partial: Bool
    public var scannedAt: Date
    public var tokens: Double { days.reduce(0) { $0 + $1.tokens } }
    public var apiValue: Double { days.reduce(0) { $0 + $1.apiValue } }
}
public enum LocalUsageScanner {
    public static func scan(provider: UsageProvider, profile: String? = nil, now: Date = Date()) -> LocalUsageCost {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = profile.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("." + provider.rawValue)
        let roots = provider == .claude ? [folder.appendingPathComponent("projects")] :
            (provider == .codex ? [folder.appendingPathComponent("sessions"), folder.appendingPathComponent("archived_sessions")] : [folder.appendingPathComponent("sessions")])
        let since = now.addingTimeInterval(-30 * 86400)
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var bytes = 0, visited = 0, partial = false
        var records: [String: LocalUsageRecord] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsPackageDescendants], errorHandler: { _, _ in false }) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= 20000, records.count < 200000, bytes < 256 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < deadline else { partial = true; break }
                guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]), attrs.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
                guard attrs.isRegularFile == true, (attrs.contentModificationDate ?? .distantPast) >= since,
                      provider == .grok ? url.lastPathComponent == "signals.json" : url.pathExtension == "jsonl" else { continue }
                // A huge transcript cannot monopolize the UI or leave a partial line interpreted as usage.
                guard (attrs.fileSize ?? Int.max) <= 32 * 1024 * 1024,
                      let data = try? UsageFile.read(url, limit: 32 * 1024 * 1024) else { partial = true; continue }
                bytes += data.count
                if provider == .grok {
                    guard let object = try? UsageDecoding.object(data) else { partial = true; continue }
                    let a = count(object["totalTokensBeforeCompaction"]) ?? 0, b = count(object["contextTokensUsed"]) ?? 0
                    guard a + b > 0 else { continue }
                    let key = url.deletingLastPathComponent().lastPathComponent
                    records[key] = LocalUsageRecord(key: key, date: attrs.contentModificationDate ?? now,
                        model: UsageDecoding.label(object["primaryModelId"], fallback: "Grok"), input: a + b, cached: 0, cacheWrite: 0, cacheWriteHour: 0, output: 0)
                    continue
                }
                var model = "Unknown model", previousTotal: Double?
                for line in data.split(separator: 10) {
                    if ProcessInfo.processInfo.systemUptime >= deadline { partial = true; break }
                    // Ignore non-usage records before parsing their contents.
                    let relevant = provider == .claude ? line.range(of: Data("\"usage\"".utf8)) != nil :
                        (line.range(of: Data("token_count".utf8)) != nil || line.range(of: Data("turn_context".utf8)) != nil)
                    guard relevant else { continue }
                    guard line.count <= UsageDecoding.maxBytes, let object = try? UsageDecoding.object(Data(line)) else { partial = true; continue }
                    let record: LocalUsageRecord?
                    if provider == .claude { record = claudeRecord(object) }
                    else { record = codexRecord(object, model: &model, previousTotal: &previousTotal) }
                    if let record, record.date >= since, record.date <= now.addingTimeInterval(60) {
                        if records[record.key].map({ $0.total <= record.total }) ?? true { records[record.key] = record }
                    }
                    if records.count >= 200000 { partial = true; break }
                }
            }
        }
        return aggregate(Array(records.values), partial: partial, now: now)
    }
    static func count(_ value: Any?) -> Double? {
        UsageDecoding.number(value).flatMap { $0 >= 0 && $0 <= 1e13 && $0.rounded() == $0 ? $0 : nil }
    }
    static func claudeRecord(_ object: [String: Any]) -> LocalUsageRecord? {
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any], let id = message["id"] as? String,
              let date = UsageDecoding.isoDate(object["timestamp"]), let input = count(usage["input_tokens"]),
              let output = count(usage["output_tokens"]), let cached = count(usage["cache_read_input_tokens"]),
              let writes = count(usage["cache_creation_input_tokens"]) else { return nil }
        // Initial streaming envelopes often contain incomplete counters.
        guard output > 0 || message["stop_reason"] as? String != nil else { return nil }
        let creation = usage["cache_creation"] as? [String: Any]
        let hour = count(creation?["ephemeral_1h_input_tokens"]) ?? 0
        guard hour <= writes else { return nil }
        let key = (object["requestId"] as? String ?? object["sessionId"] as? String ?? "") + ":" + id
        return LocalUsageRecord(key: key, date: date, model: UsageDecoding.label(message["model"], fallback: "Unknown model"),
            input: input, cached: cached, cacheWrite: writes - hour, cacheWriteHour: hour, output: output)
    }
    static func codexRecord(_ object: [String: Any], model: inout String, previousTotal: inout Double?) -> LocalUsageRecord? {
        let payload = object["payload"] as? [String: Any] ?? [:]
        if object["type"] as? String == "turn_context" { model = UsageDecoding.label(payload["model"], fallback: "Unknown model"); return nil }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any], let usage = info["last_token_usage"] as? [String: Any],
              let total = count((info["total_token_usage"] as? [String: Any])?["total_tokens"]),
              let date = UsageDecoding.isoDate(object["timestamp"]), let input = count(usage["input_tokens"]),
              let output = count(usage["output_tokens"]), let cached = count(usage["cached_input_tokens"]), cached <= input else { return nil }
        defer { previousTotal = total }
        guard previousTotal != total else { return nil } // Repeated status events are not new model calls.
        // Inherited fork events keep timestamps/counters. Dedup across transcripts, not just within one file.
        let fingerprint = "\(date.timeIntervalSince1970):\(total):\(input):\(cached):\(output)"
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return LocalUsageRecord(key: key, date: date, model: model, input: input - cached, cached: cached, cacheWrite: 0, cacheWriteHour: 0, output: output)
    }
    static func aggregate(_ records: [LocalUsageRecord], partial: Bool, now: Date) -> LocalUsageCost {
        var days: [Date: LocalUsageDay] = [:], models: [String: Double] = [:]
        var priced = 0
        for record in records {
            let date = Calendar.current.startOfDay(for: record.date)
            var day = days[date] ?? LocalUsageDay(date: date, tokens: 0, apiValue: 0, pricedRecords: 0)
            day.tokens += record.total
            if let value = record.apiValue { day.apiValue += value; day.pricedRecords += 1; priced += 1 }
            days[date] = day; models[record.model, default: 0] += record.total
        }
        return LocalUsageCost(days: days.values.sorted { $0.date < $1.date }, models: models,
            recordCount: records.count, pricedCount: priced, partial: partial, scannedAt: now)
    }
}
// Standard short-context reference rates checked 2026-09-29. These are token values, never subscription bills.
// Sources: platform.claude.com/docs/en/about-claude/pricing and developers.openai.com/api/docs/pricing.
public enum ReferenceTokenPrices {
    public static func value(_ record: LocalUsageRecord) -> Double? {
        let model = record.model.lowercased()
        let rate: (Double, Double, Double)?
        switch model {
        case "claude-fable-5-1", "claude-mythos-5-1": rate = (10, 50, 0.25)
        case "claude-fable-5", "claude-mythos-5": rate = (10, 50, 1)
        case "claude-opus-5-5": rate = (4, 20, 0.2)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-opus-4-5-20251101": rate = (5, 25, 0.5)
        case "claude-sonnet-5-5", "claude-sonnet-5": rate = (2, 10, 0.2)
        case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929": rate = (3, 15, 0.3)
        case "claude-haiku-4-5", "claude-haiku-4-5-20251001": rate = (1, 5, 0.1)
        case "gpt-6-astra": rate = (10, 50, 1)
        case "gpt-6-sol": rate = (2, 10, 0.2)
        case "gpt-6-luna": rate = (0.1, 0.5, 0.01)
        case "gpt-5.6-sol": rate = (4, 20, 0.4)
        case "gpt-5.3-codex": rate = (1.75, 14, 0.175)
        default: rate = nil
        }
        guard let rate else { return nil }
        return (record.input * rate.0 + record.output * rate.1 + record.cached * rate.2 + record.cacheWrite * rate.0 * 1.25 + record.cacheWriteHour * rate.0 * 2) / 1_000_000
    }
}
