import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders every Settings pane with invented state to PNGs for a visual check. Skipped unless
/// BURRO_SETTINGS_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Uses a throwaway defaults suite; never touches real settings, login items or notifications.
@MainActor final class SettingsSnapshotTests: XCTestCase {
    private func tree(_ repo: String) -> Worktree {
        Worktree(path: "/Users/sample/Dev/\(repo)", repository: repo, repositoryPath: "/Users/sample/Dev/\(repo)",
                 branch: "main", head: String(repeating: "a", count: 40), isPrimary: true, isLocked: false, isMissing: false, isPrunable: false,
                 facts: GitFacts(), agents: [], processes: [], protectedByUser: false, assessment: Assessment(level: .keep, reasons: []))
    }

    private func store() -> AppStore {
        let defaults = UserDefaults(suiteName: "burro-settings-snapshot-" + UUID().uuidString)!
        defaults.set(false, forKey: "usageEnabled")
        let store = AppStore(defaults: defaults, scan: { _ in .empty })
        store.snapshot = ScanSnapshot(worktrees: ["focus-town", "support-console", "burro", "notes-site"].map(tree), agents: [], warnings: [],
                                      scannedAt: Date(), duration: 0)
        store.remoteHosts = [RemoteHost(name: "Studio", destination: "sample@studio.local"),
                             RemoteHost(name: "Build box", destination: "build-box", enabled: false)]
        store.repositories = ["/Volumes/Work/legacy-app"]
        return store
    }

    func testRenderSettingsSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_SETTINGS_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_SETTINGS_SNAPSHOTS=1") }
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = store()
        for pane in SettingsPane.allCases {
            try render(SettingsView(store: store, pane: pane, memoryCount: 4), size: CGSize(width: 1180, height: 1250), dark: true,
                       to: out.appendingPathComponent("settings-\(pane.rawValue)-dark.png"))
        }
        try render(SettingsView(store: store, pane: .orchestrator, memoryCount: 4), size: CGSize(width: 1440, height: 1100), dark: true,
                   to: out.appendingPathComponent("settings-orchestrator-1440-dark.png"))
        try render(SettingsView(store: store, pane: .orchestrator, memoryCount: 4), size: CGSize(width: 1440, height: 1100), dark: false,
                   to: out.appendingPathComponent("settings-orchestrator-1440-light.png"))
        try render(SettingsView(store: store, pane: .orchestrator, memoryCount: 4), size: CGSize(width: 780, height: 1700), dark: true,
                   to: out.appendingPathComponent("settings-orchestrator-780-dark.png"))
        try render(SettingsView(store: store, pane: .privacy, memoryCount: 4), size: CGSize(width: 980, height: 1100), dark: false,
                   to: out.appendingPathComponent("settings-privacy-light.png"))
        store.brief.autoTriage = false
        store.orchestrator.notesAccess = true
        try render(SettingsView(store: store, pane: .orchestrator, memoryCount: 1), size: CGSize(width: 1180, height: 1250), dark: true,
                   to: out.appendingPathComponent("settings-orchestrator-off-dark.png"))
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.modifier(AppTheme()).frame(width: size.width, height: size.height))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
