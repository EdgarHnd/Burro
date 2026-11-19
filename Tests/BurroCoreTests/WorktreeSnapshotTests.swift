import AppKit
import SwiftUI
import XCTest
@testable import Burro
@testable import BurroCore

/// Renders the Worktrees page from invented sample worktrees to PNGs for a visual check. Skipped
/// unless BURRO_WORKTREE_SNAPSHOTS=1; writes to dist/screenshots (gitignored) or BURRO_SNAPSHOT_DIR.
/// Rows carry the real cleanup decision for their invented facts; nothing reads a real repository.
@MainActor final class WorktreeSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func tree(_ repo: String, _ branch: String, chat: String? = nil, chatState: AgentState = .inactive, changed: Int = 0,
                      unpushed: Int = 0, merged: Bool = true, ago: Double, primary: Bool = false) -> Worktree {
        let path = "/sample/\(repo)/\(branch.replacingOccurrences(of: "/", with: "-"))"
        var facts = GitFacts()
        facts.base = "origin/main"; facts.changed = changed; facts.unpushed = unpushed
        facts.merged = merged; facts.includedIn = merged ? ["origin/main"] : nil
        facts.retentionChecked = true; facts.retainedBranch = "refs/heads/" + branch
        facts.lastCommit = now.addingTimeInterval(-ago - 600)
        let agents = chat.map { [AgentSession(id: UUID().uuidString, provider: .claude, title: $0, cwd: path, state: chatState,
                                              updatedAt: now.addingTimeInterval(-ago), evidence: "sample")] } ?? []
        return Worktree(path: path, repository: repo, repositoryPath: "/sample/\(repo)/main", branch: branch,
                        head: String(repeating: "b", count: 40), isPrimary: primary, isLocked: false, isMissing: false,
                        isPrunable: false, facts: facts, agents: agents, processes: [], protectedByUser: false,
                        assessment: Assessment(level: .keep, reasons: []))
    }

    private var sample: [Worktree] {
        let h = 3_600.0, d = 86_400.0
        var trees = [
            tree("lighthouse", "feat/tide-tables", chat: "Tide tables from the harbour feed", chatState: .working, changed: 6, ago: 20),
            tree("lighthouse", "fix/lamp-flicker-on-resume", chat: "Lamp flicker on resume", chatState: .idle, changed: 2, ago: 120),
            tree("lighthouse", "release/2.4-notes", chat: "Release notes for 2.4", chatState: .waiting, ago: 180),
            tree("lighthouse", "feat/fog-signal-settings", chat: "Fog signal settings", ago: 2 * h),
            tree("lighthouse", "spike/keeper-rota-layout", chat: "Keeper rota layout", changed: 3, unpushed: 1, merged: false, ago: 3 * h),
            tree("lighthouse", "chore/audit-dependencies", chat: "Audit dependencies", ago: 5 * h),
            tree("lighthouse", "fix/beacon-receipt-retry", chat: "Beacon receipt retry", unpushed: 2, merged: false, ago: 9 * d),
            tree("lighthouse", "exp/renderer-upgrade", chat: "Upgrade the renderer", changed: 14, merged: false, ago: 17 * d),
            tree("lighthouse", "wip/onboarding-copy", ago: 21 * d),
            tree("lighthouse", "main", chat: "Daily triage", ago: 30 * d, primary: true),
        ]
        for index in 0..<6 { trees.append(tree("lighthouse", "feat/old-idea-\(index + 1)", ago: Double(25 + index) * d)) }
        trees += [
            tree("ledger", "feat/csv-import", chat: "CSV import", ago: 4 * d),
            tree("ledger", "fix/rounding", chat: "Rounding in totals", changed: 1, ago: 6 * d),
            tree("burro", "feat/chat-steering", chat: "Start, follow and steer chats", ago: 26 * h),
            tree("burro", "perf/aquarium-layout", chat: "Aquarium layout cost", changed: 2, merged: false, ago: 4 * d),
            tree("burro", "fix/ci-locale-dates", chat: "CI date text in UTC", ago: 6 * d),
        ]
        return trees
    }

    private func model(filter: WorktreeBoardFilter = .all, selectSafe: Bool = true, measured: Bool = true,
                       gc: [String: WorktreeInsightsStore.GCState] = [:]) -> WorktreeBoardModel {
        let rows = sample.enumerated().map { index, tree in
            WorktreeBoardRow(tree: tree, eligibility: WorktreeCleanup.eligibility(tree, home: "/sample-home", warnings: []),
                             size: measured || index % 3 == 0 ? Int64(180_000_000 + index * 23_000_000) : nil)
        }
        let groups = WorktreeBoard.groups(rows, filter: filter, sort: .lastActivity, now: now)
        let selection = selectSafe ? WorktreeBoard.safeIDs(rows.filter { $0.tree.repository != "ledger" }) : []
        return WorktreeBoardModel(rows: rows, groups: groups, summary: WorktreeBoard.summary(rows),
            counts: WorktreeBoard.counts(rows, now: now), filter: filter, selection: selection,
            collapsed: ["/sample/ledger/main"], health: ["/sample/lighthouse/main": RepositoryObjectStats(loose: 104_212, packs: 267)],
            gc: gc, now: now, calendar: calendar,
            scopeBenches: [(id: UUID(), name: "Games")],
            scopeRepositories: [("/sample/burro/main", "burro"), ("/sample/ledger/main", "ledger"), ("/sample/lighthouse/main", "lighthouse")])
    }

    /// The page as WorktreeListView lays it out at a content width (padding 36), with the bulk bar
    /// that its safe-area inset shows while rows are ticked.
    private func page(_ model: WorktreeBoardModel, width: CGFloat, phase: WorktreePageData.Phase = .board,
                      scanned: String = "This Mac · scanned 2 min ago", scope: String? = nil) -> some View {
        let data = WorktreePageData(phase: phase, title: scope ?? "Worktrees", scopeName: scope, scanned: scanned, model: model,
                                    compact: WorktreePageData.compact(tableWidth: width - 72),
                                    warnings: phase == .board ? ["2 repositories could not be read: permission denied"] : [])
        return VStack(alignment: .leading, spacing: 14) {
            WorktreePage(data: data, actions: WorktreeBoardActions()) { EmptyView() }
            if !model.selection.isEmpty { WorktreeBulkBar(model: model, actions: WorktreeBoardActions()) }
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .modifier(AppTheme())
    }

    func testRenderWorktreeSnapshots() throws {
        guard ProcessInfo.processInfo.environment["BURRO_WORKTREE_SNAPSHOTS"] == "1" else { throw XCTSkip("set BURRO_WORKTREE_SNAPSHOTS=1") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = ProcessInfo.processInfo.environment["BURRO_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("dist/screenshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ticked = model()
        XCTAssertFalse(ticked.bulk.isEmpty)
        XCTAssertTrue(ticked.bulk.allSatisfy { tree in ticked.rows.first { $0.id == tree.path }?.eligibility.allowed == true })
        let mixed = model(selectSafe: false)
        var noMatch = model(filter: .protected, selectSafe: false)
        noMatch.groups = []
        let scanning = model(selectSafe: false)
        // Content widths of a 1000, 1240 and 1440 pt window beside the sidebar.
        for width in [935, 1015, 1215] {
            for dark in [true, false] {
                let suffix = "\(width)-\(dark ? "dark" : "light")"
                try render(page(mixed, width: CGFloat(width)), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("worktrees-mixed-\(suffix).png"))
                try render(page(ticked, width: CGFloat(width)), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("worktrees-ticked-\(suffix).png"))
                try render(page(noMatch, width: CGFloat(width)), width: CGFloat(width), dark: dark, to: out.appendingPathComponent("worktrees-nomatch-\(suffix).png"))
                try render(page(scanning, width: CGFloat(width), phase: .scanning, scanned: "This Mac · scanning…"), width: CGFloat(width), dark: dark,
                           to: out.appendingPathComponent("worktrees-scanning-\(suffix).png"))
            }
        }
        var scoped = model(filter: .protected, selectSafe: false)
        scoped.scope = .repository("/sample/lighthouse/main"); scoped.scopeTitle = "lighthouse"
        try render(page(scoped, width: 1015, scope: "lighthouse"), width: 1015, dark: true, to: out.appendingPathComponent("worktrees-scoped-1015-dark.png"))
        try render(page(model(filter: .uncommitted, selectSafe: false, measured: false,
                              gc: ["/sample/lighthouse/main": .running(started: now.addingTimeInterval(-90))]), width: 1215),
                   width: 1215, dark: true, to: out.appendingPathComponent("worktrees-filtered-gc-1215-dark.png"))
        try render(page(model(selectSafe: false, gc: ["/sample/lighthouse/main": .finished(
                        before: RepositoryObjectStats(loose: 104_212, packs: 267), after: RepositoryObjectStats(loose: 12, packs: 2))]), width: 1015),
                   width: 1015, dark: false, to: out.appendingPathComponent("worktrees-gc-done-1015-light.png"))
        try render(page(mixed, width: 1015, phase: .empty), width: 1015, dark: true, to: out.appendingPathComponent("worktrees-empty-1015-dark.png"))
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width).background(AppAppearance.background))
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
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
