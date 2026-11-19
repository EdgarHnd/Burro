import XCTest
@testable import Burro
@testable import BurroCore

/// The sidebar's pure rules: groups in ⌘1–⌘8 order, the row a page lights up, the narrow-window
/// rail and the toggle that never overwrites the saved choice while the window is narrow.
@MainActor final class SidebarLayoutTests: XCTestCase {
    func testGroupsReadTopToBottomInShortcutOrder() {
        XCTAssertEqual(SidebarLayout.groups.flatMap(\.pages), AppPage.navigable)
        XCTAssertEqual(SidebarLayout.groups.map(\.label), ["Overview", "Workspace", "System"])
    }

    func testTimelineLightsTodayAndOtherPagesTheirOwnRow() {
        XCTAssertEqual(SidebarLayout.row(for: .timeline), .today)
        for page in AppPage.navigable { XCTAssertEqual(SidebarLayout.row(for: page), page) }
    }

    func testNarrowBelowSidebarPlusAComfortablePage() {
        XCTAssertTrue(SidebarLayout.isNarrow(windowWidth: 1000))
        XCTAssertTrue(SidebarLayout.isNarrow(windowWidth: 1124))
        XCTAssertFalse(SidebarLayout.isNarrow(windowWidth: 1125))
        XCTAssertFalse(SidebarLayout.isNarrow(windowWidth: 1240)) // the default window
    }

    func testCollapsedFollowsSavedChoiceUnlessNarrow() {
        XCTAssertFalse(SidebarLayout.collapsed(saved: false, narrow: false, expandedWhileNarrow: false))
        XCTAssertTrue(SidebarLayout.collapsed(saved: true, narrow: false, expandedWhileNarrow: false))
        XCTAssertTrue(SidebarLayout.collapsed(saved: false, narrow: true, expandedWhileNarrow: false))
        XCTAssertFalse(SidebarLayout.collapsed(saved: true, narrow: true, expandedWhileNarrow: true))
    }

    func testToggleWhileNarrowLeavesTheSavedChoiceAlone() {
        XCTAssertEqual(SidebarLayout.toggled(saved: false, narrow: true, expandedWhileNarrow: false).saved, false)
        XCTAssertEqual(SidebarLayout.toggled(saved: false, narrow: true, expandedWhileNarrow: false).expandedWhileNarrow, true)
        XCTAssertEqual(SidebarLayout.toggled(saved: false, narrow: false, expandedWhileNarrow: false).saved, true)
    }

    func testSidebarChatClickIsADirectPickWithNoBackPill() throws {
        let store = try makeStore()
        let session = AgentSession(id: "codex:crew", provider: .codex, title: "Crew chat", cwd: "/tmp", state: .waiting,
                                   updatedAt: Date(), evidence: "fixture")
        store.openChatFromSidebar(session)
        XCTAssertEqual(store.page, .remote)
        XCTAssertEqual(store.remoteSelection, "codex:crew")
        XCTAssertNil(store.backPillTarget)
        store.go(to: .home)
        store.showChat(session) // Home's cards: a jump, with a way back
        XCTAssertEqual(store.backPillTarget, .home)
    }

    private func makeStore() throws -> AppStore {
        let suite = "burro.sidebar.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "notchEnabled"); defaults.set(false, forKey: "usageEnabled"); defaults.set(false, forKey: "discover")
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return AppStore(defaults: defaults)
    }

    func testStoreSavesTheChoiceAndForgetsANarrowOpenWhenWidened() throws {
        let suite = "burro.sidebar.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "notchEnabled"); defaults.set(false, forKey: "usageEnabled"); defaults.set(false, forKey: "discover")
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        XCTAssertFalse(store.sidebarIsCollapsed)
        store.toggleSidebar()
        XCTAssertTrue(store.sidebarIsCollapsed)
        XCTAssertTrue(defaults.bool(forKey: SidebarLayout.collapsedKey))
        XCTAssertTrue(AppStore(defaults: defaults).sidebarCollapsed)
        store.toggleSidebar()

        store.windowNarrowChanged(true)
        XCTAssertTrue(store.sidebarIsCollapsed)
        store.toggleSidebar() // opens it for now
        XCTAssertFalse(store.sidebarIsCollapsed)
        XCTAssertFalse(defaults.bool(forKey: SidebarLayout.collapsedKey))
        store.windowNarrowChanged(false)
        store.windowNarrowChanged(true)
        XCTAssertTrue(store.sidebarIsCollapsed, "widening forgets the temporary open")
    }
}
