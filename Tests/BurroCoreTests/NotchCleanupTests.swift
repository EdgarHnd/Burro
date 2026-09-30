import XCTest
@testable import BurroCore

final class NotchCleanupTests: XCTestCase {
    func testExistingMergedLinkedCheckoutWithoutChatsIsCounted() {
        var facts = GitFacts(); facts.merged = true; facts.unpushed = 0
        var tree = Worktree(path: "/linked", repository: "repo", repositoryPath: "/main", branch: "feature", head: "a",
            isPrimary: false, isLocked: false, isMissing: false, isPrunable: false, facts: facts, agents: [], processes: [],
            protectedByUser: false, assessment: Assessment(level: .review, reasons: []))
        func count() -> Int { NotchCleanup.inventory(worktrees: [tree], sessions: []).count }
        XCTAssertEqual(count(), 1)
        XCTAssertTrue(NotchCleanup.inventory(worktrees: [tree], sessions: [])[0].canDelete)
        tree.assessment = Assessment(level: .candidate, reasons: [])
        XCTAssertTrue(NotchCleanup.inventory(worktrees: [tree], sessions: [])[0].canDelete)
        tree.agents = [AgentSession(id: "idle", provider: .codex, title: "idle", cwd: tree.path, state: .idle, updatedAt: Date(), evidence: "fixture")]
        tree.facts.ignoredCount = 6
        tree.assessment = SafetyPolicy.assess(primary: false, locked: false, missing: false, prunable: false, branch: tree.branch, facts: tree.facts, agents: tree.agents, processes: [], protected: false, coverageWarnings: [])
        XCTAssertEqual(WorktreeRemoval.assessment(tree).level, .candidate)
        tree.agents[0].state = .working
        XCTAssertEqual(WorktreeRemoval.assessment(tree).level, .keep)
        tree.agents = []; tree.facts.ignoredCount = 0
        tree.isPrimary = true; XCTAssertEqual(count(), 0)
        tree.isPrimary = false; tree.isMissing = true; XCTAssertEqual(count(), 0)
        tree.isMissing = false; tree.facts.changed = 1; XCTAssertEqual(count(), 0)
        tree.facts.changed = 0; tree.facts.merged = nil; XCTAssertEqual(count(), 0)
    }
    func testRemoteCleanupDeduplicatesAndRequiresFreshLinkedMergedEvidence() {
        var chat = AgentSession(id: "one", provider: .codex, title: "one", cwd: "/linked", state: .idle, updatedAt: Date(), evidence: "test")
        chat.checkoutPath = "/linked"; chat.checkoutIsLinked = true; chat.deliveryStatus = .merged
        chat.remote = RemoteOrigin(hostID: UUID(), hostName: "Remote", sampledAt: Date(), stale: false)
        var second = chat; second.id = "two"
        XCTAssertEqual(NotchCleanup.inventory(worktrees: [], sessions: [chat, second]).count, 1)
        second.state = .working
        XCTAssertTrue(NotchCleanup.inventory(worktrees: [], sessions: [chat, second]).isEmpty)
        chat.remote?.stale = true
        XCTAssertTrue(NotchCleanup.inventory(worktrees: [], sessions: [chat]).isEmpty)
        chat.remote?.stale = false; chat.checkoutIsLinked = nil
        XCTAssertTrue(NotchCleanup.inventory(worktrees: [], sessions: [chat]).isEmpty)
    }
}
