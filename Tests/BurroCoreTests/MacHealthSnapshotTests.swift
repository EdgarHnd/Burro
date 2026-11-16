import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Mac Health page with invented sample data to PNGs for a visual check. Skipped unless
/// BURRO_HEALTH_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR. Draws views offscreen;
/// never samples this Mac, never reads its processes, and never touches the real sleep setting (a fake system).
@MainActor final class MacHealthSnapshotTests: XCTestCase {
    private let gigabyte: UInt64 = 1 << 30
    private let now = Date()

    func testRenderMacHealthSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_HEALTH_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_HEALTH_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let busy = try health(leftovers: true)
        let keepAwake = await awake(agents: 2)
        for (width, height) in [(1440, 1000), (1000, 1250), (700, 1900)] {
            try render(MacHealthPage(health: busy, keepAwake: keepAwake), width: width, height: height, dark: true,
                       to: out.appendingPathComponent("health-\(width)-dark.png"))
        }
        try render(MacHealthPage(health: busy, keepAwake: keepAwake), width: 1440, height: 1000, dark: false,
                   to: out.appendingPathComponent("health-1440-light.png"))

        let calm = try health(leftovers: false)
        let off = await awake(agents: nil)
        try render(MacHealthPage(health: calm, keepAwake: off), width: 1440, height: 900, dark: true, to: out.appendingPathComponent("health-calm-dark.png"))
        let loading = MacHealthStore(defaults: try defaults())
        try render(MacHealthPage(health: loading, keepAwake: off), width: 1440, height: 900, dark: true, to: out.appendingPathComponent("health-loading-dark.png"))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "burro.health.snapshot.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// A store filled by hand: an hour of invented samples, five leftovers (one tied to a chat) and agent processes.
    private func health(leftovers: Bool) throws -> MacHealthStore {
        let store = MacHealthStore(defaults: try defaults())
        let swapNow = leftovers ? 6.2 : 0.0
        let memory = MacHealthSnapshot.Memory(total: 36 * gigabyte, app: UInt64(22.4 * Double(gigabyte)), wired: 4 * gigabyte, compressed: 3 * gigabyte,
            cached: 4 * gigabyte, free: gigabyte, swapTotal: 7 * gigabyte, swapUsed: UInt64(swapNow * Double(gigabyte)), pressure: .normal)
        store.snapshot = MacHealthSnapshot(sampledAt: now, cores: 12, load: [4.1, 3.8, 3.5], cpuBusy: 0.38, memory: memory,
            storage: .init(total: 1_000_000_000_000, available: 212_000_000_000), thermal: .nominal, bootedAt: now.addingTimeInterval(-3 * 86400))
        var history = MacHealthHistory()
        let samples = 720
        for index in 0..<samples {
            let t = Double(index) / Double(samples - 1)
            let cpu = 0.33 + 0.08 * sin(t * 19) + (abs(t - 0.25) < 0.04 ? 0.32 : 0)
            history.append(MacHealthPoint(at: now.addingTimeInterval(Double(index - samples + 1) * 5), cpu: index == samples - 1 ? 0.38 : cpu,
                memoryUsed: UInt64((22.5 + 6.9 * t) * Double(gigabyte)), memoryTotal: 36 * gigabyte,
                swapUsed: UInt64((leftovers ? 1.4 + (swapNow - 1.4) * t : 0) * Double(gigabyte)),
                diskFree: UInt64(215_000_000_000 - 3_000_000_000 * t), diskTotal: 1_000_000_000_000))
        }
        store.history = history
        guard leftovers else {
            store.report = LeftoverReport(leftovers: [], busiest: [
                ProcessLine(id: "1", name: "Xcode", cpuPercent: 24, memory: 2_400_000_000),
                ProcessLine(id: "2", name: "Arc", cpuPercent: 9, memory: 1_100_000_000),
                ProcessLine(id: "3", name: "node · vite", cpuPercent: 3, memory: 400_000_000),
            ], agentProcesses: 0, agentMemory: 0, complete: true)
            return store
        }
        func item(_ kind: LeftoverKind, _ name: String, _ folder: String, _ reason: String, hours: Double, memory: UInt64, pid: Int) -> Leftover {
            let started = now.addingTimeInterval(-hours * 3600)
            return Leftover(kind: kind, name: name, folder: folder, reason: reason, started: started, memory: memory, children: 0,
                            target: .process(pid: pid, started: started, executable: "/opt/homebrew/bin/node"), signature: "\(kind)|\(name)")
        }
        let metro = item(.watcher, "node · expo", "~/Dev/focustown", "Running for 5 h. Test runners and watchers normally stop when the work is done.",
                         hours: 5, memory: 780_000_000, pid: 4103)
        var simulator = item(.simulator, "iPhone 17", "No apps running", "Booted 6 h ago with no Simulator window open.", hours: 6, memory: 1_600_000_000, pid: 0)
        simulator.target = .simulator(udid: "6C1E2B4A-0000-4000-8000-000000000000")
        store.report = LeftoverReport(leftovers: [
            item(.watcher, "node · jest", "~/Dev/support-console", "Running for 3 h. Test runners and watchers normally stop when the work is done.",
                 hours: 3, memory: 620_000_000, pid: 4102),
            metro,
            item(.devServer, "node · vite", "~/Dev/support-console", "Listening on :5173 with no open connections; up 14 h.", hours: 14, memory: 410_000_000, pid: 4101),
            item(.devServer, "Python · http.server", "~/Downloads", "Listening on :8000 with no open connections; up 2 days.", hours: 50, memory: 38_000_000, pid: 4104),
            simulator,
        ], busiest: [
            ProcessLine(id: "1", name: "xcodebuild", cpuPercent: 142, memory: 3_100_000_000),
            ProcessLine(id: "2", name: "Simulator", cpuPercent: 38, memory: 1_900_000_000),
            ProcessLine(id: "3", name: "Arc", cpuPercent: 9, memory: 1_100_000_000),
            ProcessLine(id: "4", name: "WindowServer", cpuPercent: 7, memory: 600_000_000),
        ], agentProcesses: 3, agentMemory: 900_000_000, complete: true)
        store.leftoverChats = [metro.id: AgentChatRef(id: "claude:study", title: "Study with friends layout", pid: nil)]
        store.ignored = ["devServer|ollama|~", "orphan|python|~/Dev"]
        let ios = AgentChatRef(id: "claude:ios", title: "iOS hang on resume", pid: 900)
        let android = AgentChatRef(id: "claude:android", title: "Android 2.2.24 release notes", pid: 901)
        let streak = AgentChatRef(id: "claude:streak", title: "Streak ladder config", pid: 902)
        store.agents = AgentProcessSummary(top: [
            AgentProcessLine(id: "a", name: "xcodebuild", chat: ios, cpuPercent: 142, memory: 3_100_000_000),
            AgentProcessLine(id: "b", name: "Simulator", chat: ios, cpuPercent: 38, memory: 1_900_000_000),
            AgentProcessLine(id: "c", name: "claude", chat: android, cpuPercent: 6, memory: 290_000_000),
            AgentProcessLine(id: "d", name: "claude", chat: streak, cpuPercent: 0, memory: 310_000_000),
            AgentProcessLine(id: "e", name: "gh", chat: android, cpuPercent: 2, memory: 24_000_000),
        ], processes: 9, cpuPercent: 188, memory: 5_600_000_000)
        return store
    }

    /// Keep awake on a fake system: agents mode with `agents` chats working, or off.
    private func awake(agents: Int?) async -> KeepAwakeStore {
        let store = KeepAwakeStore(defaults: (try? defaults()) ?? .standard, system: FakeKeepAwakeSystem(passwordless: true),
                                   folder: FileManager.default.temporaryDirectory.appendingPathComponent("burro-ka-\(UUID().uuidString)"), owner: 4321)
        await store.launch()
        if let agents {
            store.agentsMode = true
            store.agentsChanged(working: agents)
            await store.pending?.value
        }
        return store
    }

    private func render<V: View>(_ view: V, width: Int, height: Int, dark: Bool, to url: URL) throws {
        let size = CGSize(width: width, height: height)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
