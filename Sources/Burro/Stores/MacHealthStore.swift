// Samples Mac resources and leftovers only while a Mac view is visible; stopping anything needs explicit confirmation.
import AppKit
import Foundation
import Observation
import BurroCore

@MainActor @Observable final class MacHealthStore {
    var snapshot: MacHealthSnapshot?
    var report = LeftoverReport.empty
    var sampling = false
    var message: String?
    var pending: Leftover?
    var acting: Set<String> = []
    /// Processes that ignored a normal quit request; the next action offers Force Quit.
    var stubborn: Set<String> = []
    var ignored: Set<String> { didSet { defaults.set(Array(ignored).sorted(), forKey: "macHealthIgnored") } }
    @ObservationIgnored private var ticks: CPUTicks?
    @ObservationIgnored private var inventory: ProcessInventory?
    @ObservationIgnored private var observers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignored = Set(defaults.stringArray(forKey: "macHealthIgnored") ?? [])
    }
    var level: HealthLevel { max(snapshot?.level ?? .normal, report.leftovers.isEmpty ? .normal : .elevated) }

    /// Keeps sampling while at least one caller's task is alive; cancelling the task (view disappears) releases it.
    func observe() async {
        observers += 1
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        observers -= 1
        if observers == 0 { loop?.cancel(); loop = nil; inventory = nil; ticks = nil }
    }
    func refresh() async {
        guard !sampling else { return }
        sampling = true
        let previousTicks = ticks, previousInventory = inventory, ignored = ignored, home = home
        let result = await Task.detached(priority: .utility) {
            let (snapshot, ticks) = MacHealthSampler.sample(previous: previousTicks)
            let inventory = ProcessInventory.read()
            let report = LeftoverPolicy.report(inventory, cpu: inventory.cpuPercent(since: previousInventory), home: home,
                ignored: ignored, deviceName: { LeftoverPolicy.simulatorName(udid: $0, home: home) })
            return (snapshot, ticks, inventory, report)
        }.value
        snapshot = result.0; ticks = result.1; inventory = result.2
        // The first pass has no CPU deltas; keep the previous list until busy processes can be judged.
        if previousInventory != nil || report.leftovers.isEmpty { report = result.3 }
        stubborn.formIntersection(Set(report.leftovers.map(\.id)))
        sampling = false
    }
    func review(_ leftover: Leftover) { pending = leftover }
    func confirm(_ leftover: Leftover) {
        pending = nil
        guard !acting.contains(leftover.id) else { return }
        acting.insert(leftover.id)
        let force = stubborn.contains(leftover.id)
        Task {
            let target = leftover.target
            let outcome: LeftoverActionResult = await Task.detached(priority: .userInitiated) {
                switch target {
                case .process(let pid, let started, let executable):
                    let result = LeftoverActions.stop(pid: pid, started: started, executable: executable, force: force)
                    guard result == .done else { return result }
                    // Give a normal quit a moment before deciding it was ignored.
                    for _ in 0..<20 {
                        guard LeftoverActions.isRunning(pid: pid, started: started, executable: executable) else { return .done }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    return .stillRunning
                case .simulator(let udid):
                    return LeftoverActions.shutdownSimulator(udid)
                }
            }.value
            acting.remove(leftover.id)
            switch outcome {
            case .done:
                stubborn.remove(leftover.id)
                report.leftovers.removeAll { $0.id == leftover.id }
            case .changed:
                message = "\(leftover.name) changed or already exited, so Burro left it alone."
            case .stillRunning:
                stubborn.insert(leftover.id)
                message = force ? "\(leftover.name) is still running after Force Quit."
                    : "\(leftover.name) ignored the quit request. Use Force Quit to stop it immediately."
            case .failed(let reason):
                message = "Couldn't stop \(leftover.name): \(reason)"
            }
            await refresh()
        }
    }
    func ignore(_ leftover: Leftover) {
        ignored.insert(leftover.signature)
        report.leftovers.removeAll { $0.signature == leftover.signature }
    }
    func resetIgnored() { ignored = []; Task { await refresh() } }
    func reveal(_ leftover: Leftover) {
        let path = leftover.folder.hasPrefix("~") ? home + leftover.folder.dropFirst() : leftover.folder
        guard path.hasPrefix("/") else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
    func copyPID(_ leftover: Leftover) {
        guard let pid = leftover.pid else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(pid)", forType: .string)
    }
}
