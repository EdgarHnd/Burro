// Read-only Mac resource sampling from the kernel: CPU ticks, memory categories, swap, pressure, storage and thermal state.
import Foundation
import CSystem
import Darwin

public enum HealthLevel: Int, Comparable, Sendable {
    case normal, elevated, critical
    public static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct CPUTicks: Sendable, Equatable {
    public var busy: UInt64
    public var total: UInt64
    public init(busy: UInt64, total: UInt64) { self.busy = busy; self.total = total }
}

public struct MacHealthSnapshot: Sendable, Equatable {
    public enum Pressure: String, Sendable { case normal = "Normal", warning = "Warning", critical = "Critical", unknown = "Unknown" }
    public enum Thermal: String, Sendable { case nominal = "Nominal", fair = "Fair", serious = "Serious", critical = "Critical" }
    public struct Memory: Sendable, Equatable {
        public var total, app, wired, compressed, cached, free: UInt64
        public var swapTotal, swapUsed: UInt64
        public var pressure: Pressure
        /// Activity Monitor's "Memory Used": app memory, wired memory and the compressor.
        public var used: UInt64 { app + wired + compressed }
        public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64,
                    swapTotal: UInt64, swapUsed: UInt64, pressure: Pressure) {
            self.total = total; self.app = app; self.wired = wired; self.compressed = compressed; self.cached = cached
            self.free = free; self.swapTotal = swapTotal; self.swapUsed = swapUsed; self.pressure = pressure
        }
    }
    public struct Storage: Sendable, Equatable {
        public var total: UInt64
        public var available: UInt64
        public init(total: UInt64, available: UInt64) { self.total = total; self.available = available }
    }
    public var sampledAt: Date
    public var cores: Int
    public var load: [Double]       // 1, 5 and 15 minute averages; empty when unavailable
    public var cpuBusy: Double?     // fraction of all cores since the previous sample
    public var memory: Memory?
    public var storage: Storage?
    public var thermal: Thermal
    public var bootedAt: Date?

    public init(sampledAt: Date, cores: Int, load: [Double], cpuBusy: Double?, memory: Memory?, storage: Storage?,
                thermal: Thermal, bootedAt: Date?) {
        self.sampledAt = sampledAt; self.cores = cores; self.load = load; self.cpuBusy = cpuBusy
        self.memory = memory; self.storage = storage; self.thermal = thermal; self.bootedAt = bootedAt
    }

    public var cpuLevel: HealthLevel {
        guard let current = load.first, cores > 0 else { return .normal }
        let ratio = current / Double(cores)
        return ratio >= 1.5 ? .critical : (ratio >= 0.9 ? .elevated : .normal)
    }
    public var memoryLevel: HealthLevel {
        guard let memory else { return .normal }
        switch memory.pressure {
        case .critical: return .critical
        case .warning: return .elevated
        case .normal, .unknown: return swapLevel
        }
    }
    /// Swap files that are nearly full mean sustained pressure even when the kernel reports normal right now.
    public var swapLevel: HealthLevel {
        guard let memory, memory.swapTotal > 0 else { return .normal }
        let nearlyFull = Double(memory.swapUsed) / Double(memory.swapTotal) >= 0.85
        return nearlyFull && memory.swapUsed >= 4 << 30 ? .elevated : .normal
    }
    public var storageLevel: HealthLevel {
        guard let storage, storage.total > 0 else { return .normal }
        let fraction = Double(storage.available) / Double(storage.total)
        if storage.available < 10 << 30 || fraction < 0.05 { return .critical }
        return fraction < 0.15 ? .elevated : .normal
    }
    public var thermalLevel: HealthLevel {
        switch thermal { case .nominal: .normal; case .fair: .elevated; case .serious, .critical: .critical }
    }
    public var level: HealthLevel { [cpuLevel, memoryLevel, storageLevel, thermalLevel].max() ?? .normal }
    /// A long uptime with heavy swap is usually cleared fastest by a restart.
    public func restartSuggested(now: Date) -> Bool {
        guard let bootedAt, let memory else { return false }
        return now.timeIntervalSince(bootedAt) >= 14 * 86400 && memory.swapUsed >= 4 << 30
    }
}

public enum MacHealthSampler {
    public static func ticks() -> CPUTicks? {
        var raw = BurroCPUTicks()
        guard burro_cpu_ticks(&raw) == 1 else { return nil }
        let busy = raw.user + raw.system + raw.nice
        return CPUTicks(busy: busy, total: busy + raw.idle)
    }
    public static func busy(from previous: CPUTicks?, to current: CPUTicks?) -> Double? {
        guard let previous, let current, current.total > previous.total, current.busy >= previous.busy else { return nil }
        return min(1, Double(current.busy - previous.busy) / Double(current.total - previous.total))
    }
    /// Returns the snapshot and the CPU ticks to pass as `previous` next time.
    public static func sample(previous: CPUTicks?, now: Date = Date()) -> (MacHealthSnapshot, CPUTicks?) {
        let current = ticks()
        var averages = [Double](repeating: 0, count: 3)
        let load = getloadavg(&averages, 3) == 3 ? averages : []
        var raw = BurroMemory()
        let memory = burro_memory(&raw) == 1 ? MacHealthSnapshot.Memory(total: raw.total, app: raw.app, wired: raw.wired,
            compressed: raw.compressed, cached: raw.cached, free: raw.free, swapTotal: raw.swap_total, swapUsed: raw.swap_used,
            pressure: pressure(raw.pressure)) : nil
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        var storage: MacHealthSnapshot.Storage?
        if let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage, total > 0 {
            storage = .init(total: UInt64(total), available: UInt64(max(0, available)))
        }
        let snapshot = MacHealthSnapshot(sampledAt: now, cores: ProcessInfo.processInfo.activeProcessorCount, load: load,
            cpuBusy: busy(from: previous, to: current), memory: memory, storage: storage,
            thermal: thermal(ProcessInfo.processInfo.thermalState),
            bootedAt: raw.booted > 0 ? Date(timeIntervalSince1970: Double(raw.booted)) : nil)
        return (snapshot, current)
    }
    static func pressure(_ level: Int32) -> MacHealthSnapshot.Pressure {
        switch level { case 1: .normal; case 2: .warning; case 4: .critical; default: .unknown }
    }
    static func thermal(_ state: ProcessInfo.ThermalState) -> MacHealthSnapshot.Thermal {
        switch state { case .fair: .fair; case .serious: .serious; case .critical: .critical; default: .nominal }
    }
}
