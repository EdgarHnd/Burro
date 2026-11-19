// Mac Health in the dashboard layout, kept pure so it can be tested: the header's toned sentence
// (`MacHealthHeadline`'s title and detail; the title amber only when a vital is high or worse, the
// page's existing warning) and the strip's four cells (CPU, Memory pressure, Swap, Disk: the value,
// `VitalVerdict.word` as the sub-line, the unit as a footnote, the load, pressure and swap facts in
// help). Byte counts come in through closures, so tests don't depend on the Mac's locale.
import Foundation

public enum MacHealthComposition {
    /// A vital or the heat at high or worse: the headline reads "Under pressure" or "Needs attention".
    public static func strained(_ snapshot: MacHealthSnapshot?) -> Bool {
        guard let snapshot else { return false }
        let verdicts = [snapshot.verdict(.cpu), snapshot.verdict(.memory), snapshot.verdict(.disk)].compactMap { $0 }
            + [MacHealthVerdicts.thermal(snapshot.thermal)]
        return (verdicts.max() ?? .fine) >= .high
    }

    /// "Healthy, with 2 things left running. Stopping them frees about 1.4 GB."
    public static func sentence(_ headline: MacHealthHeadline, strained: Bool) -> [TextRun] {
        var runs = [TextRun(headline.title + (headline.detail.isEmpty ? "" : ". "), strained ? .needsYou : .strong)]
        if !headline.detail.isEmpty { runs.append(TextRun(headline.detail)) }
        return runs
    }

    /// The verdict word as a run: amber at high or critical (the page has no red), plain otherwise.
    static func word(_ verdict: VitalVerdict?, _ vital: MacVital) -> [TextRun] {
        guard let verdict else { return [TextRun("Measuring")] }
        return [TextRun(verdict.word(for: vital), verdict >= .high ? .needsYou : .plain)]
    }

    static func percent(_ fraction: Double?) -> String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// CPU, Memory pressure, Swap, Disk; "—" with "Measuring" for whatever hasn't been sampled yet.
    public static func stats(_ snapshot: MacHealthSnapshot?, bytes: (UInt64) -> String, fileBytes: (UInt64) -> String,
                             load: ([Double]) -> String = { $0.map { String(format: "%.1f", $0) }.joined(separator: " · ") }) -> [DashboardStat] {
        var cpu = DashboardStat(id: "cpu", label: "CPU", value: percent(snapshot?.cpuBusy), sub: word(snapshot?.verdict(.cpu), .cpu),
                                help: "Share of all cores busy since the last sample.")
        if let snapshot {
            cpu.footnote = "of \(snapshot.cores) cores"
            if !snapshot.load.isEmpty {
                cpu.help += " Load \(load(snapshot.load)) over 1, 5 and 15 minutes on \(snapshot.cores) cores."
            }
        }
        var memory = DashboardStat(id: "memory", label: "Memory pressure", value: "—", sub: word(snapshot?.verdict(.memory), .memory),
                                   help: "Memory in use; the verdict follows the kernel's pressure level.")
        var swap = DashboardStat(id: "swap", label: "Swap", value: "—", sub: word(snapshot?.verdict(.swap), .swap),
                                 help: "Swap files in use. Under 1 GB is fine, under 4 GB moderate.")
        if let used = snapshot?.memory {
            memory.value = bytes(used.used)
            memory.footnote = "of \(bytes(used.total)) used"
            memory.help = "Pressure \(used.pressure.rawValue.lowercased()) · \(bytes(used.compressed)) compressed · \(bytes(used.cached)) cached"
            swap.value = used.swapUsed == 0 ? "None" : bytes(used.swapUsed)
            swap.footnote = used.swapUsed == 0 ? "no swap in use" : "in use"
            swap.help = used.swapTotal == 0 ? "No swap files in use" : "\(bytes(used.swapTotal)) in swap files; macOS grows them as needed"
        }
        var disk = DashboardStat(id: "disk", label: "Disk", value: "—", sub: word(snapshot?.verdict(.disk), .disk),
                                 help: "Free space on the startup disk, including purgeable space; checked every minute")
        if let storage = snapshot?.storage {
            disk.value = fileBytes(storage.available)
            disk.footnote = "free of \(fileBytes(storage.total))"
        }
        return [cpu, memory, swap, disk]
    }
}
