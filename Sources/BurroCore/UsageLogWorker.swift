// Bounded aggregate-only protocol for a separate Rust usage worker.
import Foundation

struct UsageLogRequest: Encodable, Sendable {
    let provider: String
    let roots: [String]
    let now: Double
    let dayBoundaries: [Double]
    /// Asks the worker for per-folder totals since this time and limits reads to files touched since then.
    let projectsSince: Double?
    init(provider: UsageProvider, roots: [URL], now: Date, calendar: Calendar = .current, projectsSince: Date? = nil) {
        self.provider = provider.rawValue; self.roots = roots.map(\.path); self.now = now.timeIntervalSince1970
        let start = calendar.startOfDay(for: now.addingTimeInterval(-30 * 86400))
        dayBoundaries = (0..<33).compactMap { calendar.date(byAdding: .day, value: $0, to: start)?.timeIntervalSince1970 }
        self.projectsSince = projectsSince?.timeIntervalSince1970
    }
}
struct UsageLogProjectBucket: Decodable, Sendable {
    let cwd: String
    let model: String
    let input, cached, cacheWrite, cacheWriteHour, output: Double
    let recordCount: Int
    let last: Double
    var record: LocalUsageRecord {
        .init(key: cwd, date: Date(timeIntervalSince1970: last), model: model, input: input,
              cached: cached, cacheWrite: cacheWrite, cacheWriteHour: cacheWriteHour, output: output)
    }
    /// Matches the worker's folder rule: absolute, bounded, no control characters.
    static func validFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
struct UsageLogBucket: Decodable, Sendable {
    let date: Double
    let model: String
    let input, cached, cacheWrite, cacheWriteHour, output: Double
    let recordCount: Int
    var record: LocalUsageRecord {
        .init(key: "aggregate", date: Date(timeIntervalSince1970: date), model: model, input: input,
              cached: cached, cacheWrite: cacheWrite, cacheWriteHour: cacheWriteHour, output: output)
    }
}
struct UsageLogBatch: Decodable, Sendable {
    let buckets: [UsageLogBucket]
    let partial: Bool
    let reads, cacheHits, bytesRead, visited: Int
    var projects: [UsageLogProjectBucket]? = nil
    func valid(for request: UsageLogRequest) -> Bool {
        guard buckets.count <= 512, (0...20000).contains(visited), (0...visited).contains(reads),
              (0...visited).contains(cacheHits), reads + cacheHits <= visited,
              (0...(288 * 1024 * 1024)).contains(bytesRead) else { return false }
        var count = 0, keys = Set<String>()
        for bucket in buckets {
            guard request.dayBoundaries.contains(bucket.date), bucket.date <= request.now + 60,
                  UsageDecoding.label(bucket.model, fallback: "") == bucket.model, !bucket.model.isEmpty,
                  (1...200000).contains(bucket.recordCount),
                  [bucket.input, bucket.cached, bucket.cacheWrite, bucket.cacheWriteHour, bucket.output]
                    .allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(bucket.recordCount) * 2e13 }),
                  keys.insert("\(bucket.date):\(bucket.model)").inserted else { return false }
            count += bucket.recordCount
        }
        return count <= 200000 && validProjects(for: request)
    }
    private func validProjects(for request: UsageLogRequest) -> Bool {
        guard let since = request.projectsSince else { return projects == nil }
        guard let projects, projects.count <= 512 else { return false }
        var count = 0, keys = Set<String>()
        for project in projects {
            guard UsageLogProjectBucket.validFolder(project.cwd),
                  UsageDecoding.label(project.model, fallback: "") == project.model, !project.model.isEmpty,
                  (1...200000).contains(project.recordCount), project.last >= since, project.last <= request.now + 60,
                  [project.input, project.cached, project.cacheWrite, project.cacheWriteHour, project.output]
                    .allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(project.recordCount) * 2e13 }),
                  keys.insert(project.cwd + "\u{0}" + project.model).inserted else { return false }
            count += project.recordCount
        }
        return count <= 200000
    }
    func result(now: Date) -> LocalUsageCost {
        var days: [Date: LocalUsageDay] = [:], models: [String: Double] = [:]
        var count = 0, priced = 0
        for bucket in buckets {
            let record = bucket.record
            var day = days[record.date] ?? LocalUsageDay(date: record.date, tokens: 0, apiValue: 0, pricedRecords: 0)
            day.tokens += record.total; count += bucket.recordCount
            if let value = record.apiValue {
                day.apiValue += value; day.pricedRecords += bucket.recordCount; priced += bucket.recordCount
            }
            days[record.date] = day; models[record.model, default: 0] += record.total
        }
        return LocalUsageCost(days: days.values.sorted { $0.date < $1.date }, models: models,
                              recordCount: count, pricedCount: priced, partial: partial, scannedAt: now)
    }
}
