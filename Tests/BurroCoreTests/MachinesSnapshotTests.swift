import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Machines page with invented machines and chats to PNGs for a visual check. Skipped
/// unless BURRO_MACHINES_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Draws views offscreen; never reads real machines, chats or caches and never connects anywhere.
@MainActor final class MachinesSnapshotTests: XCTestCase {
    private let now = Date()
    private let studio = RemoteHost(name: "Studio", destination: "studio.tail4e2a.ts.net")
    private let mini = RemoteHost(name: "Build Mini", destination: "me@build-mini.tail4e2a.ts.net")

    private func chat(_ title: String, _ state: AgentState, _ provider: AgentProvider = .claude, model: String? = "claude-opus-5-5",
                      cwd: String, host: RemoteHost? = nil, minutesAgo: Double = 1) -> AgentSession {
        var session = AgentSession(id: UUID().uuidString, provider: provider, title: title, cwd: cwd, state: state,
                                   updatedAt: now.addingTimeInterval(-minutesAgo * 60), evidence: "")
        session.model = model
        if let host { session.remote = RemoteOrigin(hostID: host.id, hostName: host.name, sampledAt: now, stale: false) }
        return session
    }

    private func model(narrowChats: Bool = false) -> MachinesPageModel {
        let local = [
            chat("Streak ladder config", .waiting, cwd: "/Users/me/Dev/ladder", minutesAgo: 3),
            chat("iOS hang on resume", .working, cwd: "/Users/me/Dev/mobile"),
            chat("Android release notes", .working, model: "claude-fable-5-2", cwd: "/Users/me/Dev/mobile", minutesAgo: 4),
        ]
        let remote = [
            chat("Support dashboard alerts", .waiting, .codex, model: "gpt-5.5", cwd: "/home/me/support", host: studio, minutesAgo: 2),
            chat("Shader warm-up", .working, cwd: "/home/me/game", host: studio),
        ]
        let thisMac = MachineCardModel(
            id: MachinesStore.localID, name: "This Mac", reach: .local, os: "macOS 26.2", statusLine: "Online", host: nil,
            chats: local, moreChats: 0, counts: .init(working: 2, needYou: 1),
            harnesses: [
                MachineHarnessRow(harness: .claude, installed: "2.3.14", latest: "2.3.16", outdated: true, canUpdate: true, updating: false),
                MachineHarnessRow(harness: .codex, installed: "0.61.0", latest: "0.61.0", outdated: false, canUpdate: false, updating: false),
            ],
            probing: false, cacheBytes: nil, localCopy: nil, lastError: nil)
        let other = MachineCardModel(
            id: studio.id.uuidString, name: "Studio", reach: .online, os: "macOS 26.1", statusLine: "Connected · checked 8 s ago", host: studio,
            chats: narrowChats ? [] : remote, moreChats: 0, counts: narrowChats ? .init() : .init(working: 1, needYou: 1),
            harnesses: [
                MachineHarnessRow(harness: .claude, installed: "2.3.16", latest: "2.3.16", outdated: false, canUpdate: false, updating: false),
                MachineHarnessRow(harness: .codex, installed: "0.58.2", latest: "0.61.0", outdated: true, canUpdate: true, updating: false),
            ],
            probing: false, cacheBytes: 84_000_000, localCopy: nil, lastError: nil)
        let away = MachineCardModel(
            id: mini.id.uuidString, name: "Build Mini", reach: .unreachable, os: nil,
            statusLine: "Unreachable since 14:02 · retrying in 30 s · offline on Tailscale since 13:58", host: mini,
            chats: [], moreChats: 0, counts: .init(), harnesses: [], probing: false, cacheBytes: 12_000_000,
            localCopy: .init(chats: 6, lastSynced: now.addingTimeInterval(-3600)), lastError: "Connection timed out.")
        let peer = TailscalePeer(id: "p1", hostName: "pixel-tablet", dnsName: "pixel-tablet.tail4e2a.ts.net", os: "android",
                                 online: false, lastSeen: now.addingTimeInterval(-7200), isSelf: false)
        return MachinesPageModel(headline: "2 of 3 reachable · 3 chats working · 2 need you", cards: [thisMac, other, away],
                                 tailnet: [peer], tailscaleInstalled: true, message: nil, checking: false, attaching: [])
    }

    private func page(_ model: MachinesPageModel) -> some View {
        VStack(spacing: 0) {
            MachinesHeader(model: model, actions: MachinesActions())
            MachinesPage(model: model, actions: MachinesActions()).padding(.horizontal, 30).padding(.top, 6).padding(.bottom, 28)
        }
        .frame(maxWidth: 1340).frame(maxWidth: .infinity)
    }

    func testRenderMachinesSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_MACHINES_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_MACHINES_SNAPSHOTS=1") }
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try render(page(model()), width: 1440, dark: true, to: out.appendingPathComponent("machines-1440-dark.png"))
        try render(page(model()), width: 1440, dark: false, to: out.appendingPathComponent("machines-1440-light.png"))
        try render(page(model(narrowChats: true)), width: 1100, dark: true, to: out.appendingPathComponent("machines-1100-dark.png"))
        try render(page(model()), width: 760, dark: true, to: out.appendingPathComponent("machines-760-dark.png"))
        var single = model()
        single.cards = [single.cards[0]]
        single.tailnet = []
        single.headline = "This Mac only · 2 chats working · 1 needs you"
        single.message = "Claude Code updated: 2.3.16"
        try render(page(single), width: 1000, dark: true, to: out.appendingPathComponent("machines-single-dark.png"))
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame.size = host.fittingSize
        window.setContentSize(host.fittingSize)
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
