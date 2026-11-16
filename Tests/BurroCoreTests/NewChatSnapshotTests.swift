import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the New chat sheet with invented sample data to PNGs for a visual check. Skipped unless
/// BURRO_NEWCHAT_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR. Uses a
/// throwaway preferences suite, a throwaway git repository in a temporary folder and sample usage;
/// never starts a chat and never creates a worktree.
@MainActor final class NewChatSnapshotTests: XCTestCase {
    func testRenderNewChatSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_NEWCHAT_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_NEWCHAT_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("burro-newchat-snapshot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let repo = temp.appendingPathComponent("focustown").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertTrue(CommandRunner().run("/usr/bin/git", ["-C", repo, "init", "-q"]).succeeded)
        let plain = temp.appendingPathComponent("notes").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)

        let prompt = "The streak freeze tile in the shop shows the old price after a purchase until you reopen the shop. Find where the shop caches prices, make it refresh after a purchase completes, and add a test. Don't touch the season pass code."
        var memory = LaunchPromptMemory()
        for sample in ["Draft the support reply for the refund spike", "Check why the Android build is 6 MB bigger",
                       "Bump the build number", "Look into the flaky login test", "Check why the Android build is 6 MB bigger"] {
            memory.recordStart(sample, folder: repo)
        }
        memory.saveTemplate("Triage last night's crash reports\nGroup by signature.", id: "mine")

        let now = Date()
        let usage = ProviderUsageSnapshot(availability: .available, providers: [
            ProviderUsage(id: .claude, updatedAt: now, windows: [
                UsageWindow(id: "session", title: "Session", remainingPercent: 38, resetsAt: now.addingTimeInterval(2 * 3600), duration: 5 * 3600),
                UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 64, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ]),
        ])
        let claude = LaunchChoice(provider: .claude, model: "claude-opus-5-5", effort: "high", access: .ask)

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            let filled = try store(usage: usage)
            filled.newChatDraft = LaunchDraft(prompt: prompt, folder: repo, choice: claude, newWorktree: true)
            try render(NewChatSheet(store: filled, prompts: memory), dark: dark, to: out.appendingPathComponent("newchat-\(suffix).png"))

            let empty = try store(usage: .disabled)
            empty.newChatDraft = LaunchDraft(prompt: "", folder: plain, choice: LaunchChoice(provider: .codex, model: "gpt-5.5", access: .edit))
            try render(NewChatSheet(store: empty, prompts: LaunchPromptMemory()), dark: dark, to: out.appendingPathComponent("newchat-empty-\(suffix).png"))
        }
    }

    private func store(usage: ProviderUsageSnapshot) throws -> AppStore {
        let suite = "burro.newchat.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.usage.snapshot = usage
        store.codexModels = [LaunchModel(id: "gpt-5.5", title: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium", isDefault: true)]
        return store
    }

    private func render<V: View>(_ view: V, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppAppearance.hairline))
            .padding(40).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
