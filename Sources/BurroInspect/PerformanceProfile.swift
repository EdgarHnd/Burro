// Local, opt-in timings emit counts only, never session names, paths, or transcript data.
import Foundation
import Darwin
import BurroCore

enum PerformanceProfile {
    struct Sample: Encodable {
        var operation: String
        var wallMS: Double
        var cpuMS: Double
        var peakResidentMB: Double
        var count: Int
        var partial: Bool
        var tokens: Double?
    }
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func measure(_ name: String, work: () -> (Int, Bool, Double?)) -> Sample {
        let start = ProcessInfo.processInfo.systemUptime, before = cpu()
        let (count, partial, tokens) = autoreleasepool(invoking: work)
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Sample(operation: name, wallMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                      cpuMS: (cpu() - before) * 1000, peakResidentMB: Double(value.ru_maxrss) / 1_048_576,
                      count: count, partial: partial, tokens: tokens)
    }
    static func run(includeUsage: Bool) throws {
        var samples: [Sample] = []
        for _ in 0..<3 {
            samples.append(measure("processes") { let value = ProcessReader.snapshot(); return (value.processes.count, !value.warnings.isEmpty, nil) })
            samples.append(measure("read-state") { let value = ProviderReadState.read(home: FileManager.default.homeDirectoryForCurrentUser.path); return (value.codexUnread.count + value.claudeUnread.count, !value.warnings.isEmpty, nil) })
            samples.append(measure("agents") { let value = AgentMonitor().sample(); return (value.sessions.count, !value.warnings.isEmpty, nil) })
        }
        for provider in includeUsage ? UsageProvider.allCases : [] {
            for index in 0..<2 {
                samples.append(measure("usage-\(provider.rawValue)-\(index == 0 ? "cold" : "warm")") {
                    let value = LocalUsageScanner.scan(provider: provider)
                    return (value.recordCount, value.partial, value.tokens)
                })
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(samples))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
