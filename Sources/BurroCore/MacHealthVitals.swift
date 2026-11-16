// Mac Health's judgements, kept pure so they can be tested: a one-word verdict for each vital (CPU, memory
// pressure, swap, disk), the page's headline sentence, and a short bounded history of samples the store keeps in
// memory only while Mac Health, Home or the notch Mac tab is on screen (it records the samples those views already
// take; it never samples on its own). Nothing here reads the system.
import Foundation

public enum MacVital: String, CaseIterable, Sendable { case cpu, memory, swap, disk }

/// How a vital is doing, in increasing severity.
public enum VitalVerdict: Int, Comparable, Sendable {
    case fine, moderate, high, critical
    public static func < (a: VitalVerdict, b: VitalVerdict) -> Bool { a.rawValue < b.rawValue }

    /// The one word the vital's card shows.
    public func word(for vital: MacVital) -> String {
        switch (vital, self) {
        case (_, .fine): "Fine"
        case (.cpu, .moderate): "Busy"
        case (.cpu, _): "High"
        case (.disk, .moderate): "Filling up"
        case (.disk, .high): "Low"
        case (_, .moderate): "Moderate"
        case (_, .high): "High"
        case (_, .critical): "Critical"
        }
    }
}

public enum MacHealthVerdicts {
    static let gigabyte: UInt64 = 1 << 30

    /// CPU from the busy fraction since the last sample and the one-minute load per core (the steadier signal).
    public static func cpu(busy: Double?, load: Double?, cores: Int) -> VitalVerdict? {
        guard busy != nil || load != nil else { return nil }
        let ratio = (load ?? 0) / Double(max(1, cores))
        let busy = busy ?? 0
        if busy >= 0.9 || ratio >= 1.5 { return .high }
        if busy >= 0.6 || ratio >= 0.9 { return .moderate }
        return .fine
    }
    /// The kernel's pressure level decides; a normal level with most memory in use reads as moderate.
    public static func memory(_ memory: MacHealthSnapshot.Memory?) -> VitalVerdict? {
        guard let memory else { return nil }
        switch memory.pressure {
        case .critical: return .critical
        case .warning: return .high
        case .normal, .unknown:
            guard memory.total > 0 else { return .fine }
            return Double(memory.used) / Double(memory.total) >= 0.8 ? .moderate : .fine
        }
    }
    /// Swap in use: under 1 GB is fine, under 4 GB moderate, more is high.
    public static func swap(_ memory: MacHealthSnapshot.Memory?) -> VitalVerdict? {
        guard let memory else { return nil }
        if memory.swapUsed >= 4 * gigabyte { return .high }
        return memory.swapUsed >= gigabyte ? .moderate : .fine
    }
    /// Free space on the startup disk: critical under 10 GB or 5%, low under 15%, filling up under 25%.
    public static func disk(_ storage: MacHealthSnapshot.Storage?) -> VitalVerdict? {
        guard let storage, storage.total > 0 else { return nil }
        let fraction = Double(storage.available) / Double(storage.total)
        if storage.available < 10 * gigabyte || fraction < 0.05 { return .critical }
        if fraction < 0.15 { return .high }
        return fraction < 0.25 ? .moderate : .fine
    }
    public static func thermal(_ thermal: MacHealthSnapshot.Thermal) -> VitalVerdict {
        switch thermal { case .nominal: .fine; case .fair: .moderate; case .serious: .high; case .critical: .critical }
    }
}

extension MacHealthSnapshot {
    public func verdict(_ vital: MacVital) -> VitalVerdict? {
        switch vital {
        case .cpu: MacHealthVerdicts.cpu(busy: cpuBusy, load: load.first, cores: cores)
        case .memory: MacHealthVerdicts.memory(memory)
        case .swap: MacHealthVerdicts.swap(memory)
        case .disk: MacHealthVerdicts.disk(storage)
        }
    }
}

/// The page title and the sentence under it.
public struct MacHealthHeadline: Equatable, Sendable {
    public var title: String
    public var detail: String

    /// The title comes from CPU, memory pressure, disk and heat. Swap is left out of it on purpose: it is the
    /// after-effect of pressure, often harmless while the kernel reports normal pressure, so the sentence names it instead.
    public static func make(snapshot: MacHealthSnapshot?, leftovers: Int, leftoverMemory: UInt64, leftoversKnown: Bool,
                            bytes: (UInt64) -> String) -> MacHealthHeadline {
        guard let snapshot else { return MacHealthHeadline(title: "Checking this Mac…", detail: "") }
        let cpu = snapshot.verdict(.cpu), memory = snapshot.verdict(.memory), swap = snapshot.verdict(.swap), disk = snapshot.verdict(.disk)
        let heat = MacHealthVerdicts.thermal(snapshot.thermal)
        let overall = [cpu, memory, disk, heat].compactMap { $0 }.max() ?? .fine
        var title: String
        switch overall {
        case .fine, .moderate: title = "Healthy"
        case .high: title = "Under pressure"
        case .critical: title = "Needs attention"
        }
        if leftovers > 0 { title += ", with \(leftovers) thing\(leftovers == 1 ? "" : "s") left running" }

        var problems: [String] = []
        if let memory, memory >= .high { problems.append("memory pressure is \(memory == .critical ? "critical" : "high")") }
        if let swap, swap >= .high, let used = snapshot.memory?.swapUsed { problems.append("swap is high at \(bytes(used))") }
        if let cpu, cpu >= .high { problems.append("the CPU is flat out") }
        if let disk, disk >= .high, let free = snapshot.storage?.available { problems.append("the startup disk has only \(bytes(free)) free") }
        if heat >= .moderate { problems.append("it is running hot, so macOS may slow it down") }

        let leftoverClause: String?
        if leftovers > 0 {
            let them = leftovers == 1 ? "it" : "them"
            leftoverClause = leftoverMemory > 0 ? "stopping \(them) frees about \(bytes(leftoverMemory))" : nil
        } else {
            leftoverClause = leftoversKnown ? "nothing is left running" : nil
        }
        var sentence: String
        if problems.isEmpty {
            let watched = [cpu, memory, swap, disk].compactMap { $0 }
            let calm = watched.allSatisfy { $0 == .fine } ? "CPU, memory and disk are fine" : "nothing is under strain"
            sentence = [calm, leftoverClause].compactMap { $0 }.joined(separator: "; ")
        } else {
            sentence = ([problems.prefix(2).joined(separator: " and ")] + [leftoverClause].compactMap { $0 }).joined(separator: "; ")
        }
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
        if snapshot.restartSuggested(now: snapshot.sampledAt), let booted = snapshot.bootedAt {
            let days = Int(snapshot.sampledAt.timeIntervalSince(booted) / 86400)
            sentence += " Up \(days) days; a restart clears swap and stale memory."
        }
        return MacHealthHeadline(title: title, detail: sentence)
    }
}

/// One recorded sample, reduced to what the sparklines need.
public struct MacHealthPoint: Sendable, Equatable {
    public var at: Date
    public var cpu: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var swapUsed: UInt64?
    public var diskFree: UInt64?
    public var diskTotal: UInt64?
    public init(at: Date, cpu: Double? = nil, memoryUsed: UInt64? = nil, memoryTotal: UInt64? = nil, swapUsed: UInt64? = nil,
                diskFree: UInt64? = nil, diskTotal: UInt64? = nil) {
        self.at = at; self.cpu = cpu; self.memoryUsed = memoryUsed; self.memoryTotal = memoryTotal; self.swapUsed = swapUsed
        self.diskFree = diskFree; self.diskTotal = diskTotal
    }
    public init(_ snapshot: MacHealthSnapshot) {
        self.init(at: snapshot.sampledAt, cpu: snapshot.cpuBusy, memoryUsed: snapshot.memory?.used, memoryTotal: snapshot.memory?.total,
                  swapUsed: snapshot.memory?.swapUsed, diskFree: snapshot.storage?.available, diskTotal: snapshot.storage?.total)
    }
    /// The value a vital's sparkline draws, as a fraction of its scale (swap is scaled by the caller).
    public func value(_ vital: MacVital) -> Double? {
        switch vital {
        case .cpu: return cpu
        case .memory:
            guard let memoryUsed, let memoryTotal, memoryTotal > 0 else { return nil }
            return Double(memoryUsed) / Double(memoryTotal)
        case .swap: return swapUsed.map { Double($0) }
        case .disk:
            guard let diskFree, let diskTotal, diskTotal > 0 else { return nil }
            return Double(diskTotal - min(diskTotal, diskFree)) / Double(diskTotal)
        }
    }
}

/// A fixed-size ring of recent samples. Appending past `capacity` overwrites the oldest, and points older than
/// `window` before the newest are dropped, so it never grows and a long pause doesn't stretch the chart.
public struct MacHealthHistory: Sendable, Equatable {
    public let capacity: Int
    public let window: TimeInterval
    private var storage: [MacHealthPoint?]
    private var head = 0
    public private(set) var count = 0

    /// Five-second samples for an hour by default.
    public init(capacity: Int = 720, window: TimeInterval = 3600) {
        self.capacity = max(1, capacity); self.window = window
        storage = Array(repeating: nil, count: max(1, capacity))
    }
    public var isEmpty: Bool { count == 0 }
    /// Oldest first.
    public var points: [MacHealthPoint] { (0..<count).compactMap { storage[(head + $0) % capacity] } }
    public var last: MacHealthPoint? { count == 0 ? nil : storage[(head + count - 1) % capacity] }

    public mutating func append(_ point: MacHealthPoint) {
        // A sample older than the newest (a clock change) restarts the history rather than drawing out of order.
        if let last, point.at < last.at { removeAll() }
        if count == capacity { head = (head + 1) % capacity; count -= 1 }
        storage[(head + count) % capacity] = point
        count += 1
        while count > 1, let oldest = storage[head], point.at.timeIntervalSince(oldest.at) > window {
            storage[head] = nil; head = (head + 1) % capacity; count -= 1
        }
    }
    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity); head = 0; count = 0
    }
    /// Seconds between the oldest and newest point.
    public var span: TimeInterval {
        guard let first = points.first, let last else { return 0 }
        return last.at.timeIntervalSince(first.at)
    }
    /// Averages the points into at most `bars` consecutive groups, oldest first; a group with no value is nil.
    public func bars(_ vital: MacVital, count bars: Int) -> [Double?] {
        let values = points.map { $0.value(vital) }
        guard bars > 0, !values.isEmpty else { return [] }
        guard values.count > bars else { return values }
        return (0..<bars).map { index in
            let lower = index * values.count / bars, upper = (index + 1) * values.count / bars
            let group = values[lower..<upper].compactMap { $0 }
            return group.isEmpty ? nil : group.reduce(0, +) / Double(group.count)
        }
    }

    /// The caption under a sparkline: how far back it goes, then what changed ("peak 70%", "was 1.4 GB", "steady").
    public func caption(_ vital: MacVital, bytes: (UInt64) -> String) -> String {
        let points = points
        guard points.count >= 2, let first = points.first, let last = points.last else { return "Measuring" }
        let minutes = Int((span / 60).rounded())
        let period = span >= window - 30 ? "last hour" : (minutes < 1 ? "last minute" : "last \(minutes) min")
        var change: String?
        switch vital {
        case .cpu:
            let values = points.compactMap(\.cpu)
            if let peak = values.max(), let low = values.min(), let now = last.cpu {
                if peak - now >= 0.15 { change = "peak \(Int((peak * 100).rounded()))%" }
                else if peak - low < 0.1 { change = "steady" }
            }
        case .memory:
            change = Self.change(from: first.memoryUsed, to: last.memoryUsed, scale: last.memoryTotal, floor: 256 << 20, bytes: bytes, suffix: "")
        case .swap:
            change = Self.change(from: first.swapUsed, to: last.swapUsed, scale: nil, floor: 256 << 20, bytes: bytes, suffix: "")
        case .disk:
            change = Self.change(from: first.diskFree, to: last.diskFree, scale: nil, floor: 1 << 30, bytes: bytes, suffix: " free")
        }
        return [period, change].compactMap { $0 }.joined(separator: " · ")
    }
    private static func change(from: UInt64?, to: UInt64?, scale: UInt64?, floor: UInt64, bytes: (UInt64) -> String, suffix: String) -> String? {
        guard let from, let to else { return nil }
        let difference = from > to ? from - to : to - from
        let threshold = max(floor, (scale ?? 0) / 20)
        return difference >= threshold ? "was \(bytes(from))\(suffix)" : "steady"
    }
}
