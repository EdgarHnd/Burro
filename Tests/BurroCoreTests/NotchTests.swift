// Notch regression coverage tests activity priority, screen placement, and rename preference migration.
import XCTest
import CoreGraphics
@testable import BurroCore

final class NotchTests: XCTestCase {
    private func session(_ id: String, _ state: AgentState, seconds: Double = 0) -> AgentSession {
        AgentSession(id: id, provider: .codex, title: id, cwd: "/repo", state: state,
                     updatedAt: Date(timeIntervalSince1970: seconds), evidence: "fixture")
    }
    func testActiveFeedKeepsAttentionFirstAndExcludesIdleHistory() {
        let feed = AgentActivitySnapshot(sessions: [session("idle", .idle, seconds: 900),
            session("busy", .working, seconds: 100), session("wait", .waiting, seconds: 1),
            session("old", .inactive), session("recent", .recent), session("unknown", .unknown)], warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.visibleSessions(includeIdle: false).map(\.id), ["wait", "busy", "unknown", "recent"])
        XCTAssertEqual(feed.visibleSessions(includeIdle: true).last?.id, "idle")
        XCTAssertEqual(feed.workingCount, 1); XCTAssertEqual(feed.waitingCount, 1); XCTAssertEqual(feed.idleCount, 1)
    }
    func testAttentionPrioritizesInputAndClearsAfterProviderRead() {
        var done = session("done", .idle)
        done.hasUnreadResult = true
        var feed = AgentActivitySnapshot(sessions: [done], warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.attention, .done)
        feed.sessions.append(session("waiting-worker", .waiting))
        feed.sessions[1].isSubagent = true
        XCTAssertEqual(feed.attention, .waiting)
        feed.sessions.removeLast()
        feed.sessions[0].hasUnreadResult = false
        XCTAssertEqual(feed.attention, .none)
        feed.sessions = [session("working", .working), session("scheduled", .scheduled), session("unknown", .unknown)]
        XCTAssertEqual(feed.attention, .none)
    }
    func testStaleRemoteAndCompletedWorkersDoNotLightAttention() {
        var done = session("done", .inactive); done.hasUnreadResult = true
        var wait = session("wait", .waiting)
        let origin = RemoteOrigin(hostID: UUID(), hostName: "Fixture", sampledAt: Date(), stale: true)
        done.remote = origin; wait.remote = origin
        var worker = session("worker", .idle); worker.hasUnreadResult = true; worker.isSubagent = true
        var feed = AgentActivitySnapshot(sessions: [done, wait, worker], warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.attention, .none)
        XCTAssertEqual(feed.attentionCount, 0)
        feed.sessions[1].remote?.stale = false
        XCTAssertEqual(feed.attention, .waiting)
    }
    func testDuplicateSessionIsNotShownTwice() {
        let feed = AgentActivitySnapshot(sessions: [session("same", .working), session("same", .working)], warnings: [], sampledAt: Date())
        XCTAssertEqual(feed.visibleSessions(includeIdle: false).count, 1)
    }
    func testNotchedDisplayUsesTopEdgeAndReservesTheCamera() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 60, width: 1512, height: 890)
        let compact = NotchGeometry.layout(screen: screen, visibleFrame: visible, safeTop: 32, hardwareWidth: 210, expanded: false)
        let expanded = NotchGeometry.layout(screen: screen, visibleFrame: visible, safeTop: 32, hardwareWidth: 210, expanded: true)
        XCTAssertEqual(compact.frame.maxY, screen.maxY)
        XCTAssertEqual(expanded.frame.maxY, screen.maxY)
        XCTAssertEqual(compact.frame.midX, screen.midX)
        XCTAssertGreaterThan(compact.hardwareGap, 210)
        XCTAssertGreaterThan(expanded.frame.height, compact.frame.height)
        XCTAssertTrue(compact.hasHardwareNotch)
    }
    func testExternalDisplayUsesItsOwnCoordinatesAndAttachesToPhysicalTop() {
        let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 170, width: 1920, height: 1025)
        let value = NotchGeometry.layout(screen: screen, visibleFrame: visible, safeTop: 0, hardwareWidth: 0, expanded: true)
        XCTAssertEqual(value.frame.midX, screen.midX)
        XCTAssertEqual(value.frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(value.frame.minY, visible.minY)
        XCTAssertEqual(value.hardwareGap, 0); XCTAssertFalse(value.hasHardwareNotch)
    }
    func testCameraClearanceSurvivesMissingAuxiliaryScreenRectangles() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let value = NotchGeometry.layout(screen: screen, visibleFrame: screen.insetBy(dx: 0, dy: 32),
                                        safeTop: 32, hardwareWidth: 0, expanded: false)
        XCTAssertTrue(value.hasHardwareNotch)
        XCTAssertGreaterThanOrEqual(value.hardwareGap, 210)
        XCTAssertEqual(value.frame.maxY, screen.maxY)
    }
    func testPanelIsClampedToSmallDisplays() {
        let screen = CGRect(x: 0, y: 0, width: 320, height: 240)
        let value = NotchGeometry.layout(screen: screen, visibleFrame: screen, safeTop: 0, hardwareWidth: 0, expanded: true)
        XCTAssertTrue(screen.contains(value.frame))
        XCTAssertLessThan(value.frame.width, screen.width)
    }
    func testOneAgentPanelShrinksButKeepsItsTopEdgeFixed() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let one = NotchGeometry.layout(screen: screen, visibleFrame: screen, safeTop: 32, hardwareWidth: 200, expanded: true, visibleAgents: 1)
        let many = NotchGeometry.layout(screen: screen, visibleFrame: screen, safeTop: 32, hardwareWidth: 200, expanded: true, visibleAgents: 20)
        XCTAssertLessThan(one.frame.height, many.frame.height)
        XCTAssertEqual(one.frame.maxY, many.frame.maxY)
    }
    func testRenameMigratesExplicitPreferencesOnlyOnceWithoutOverwritingBurro() {
        let name = "burro-test-\(UUID().uuidString)"
        // Use a unique suite so this regression cannot touch the actual app's preferences.
        let isolated = UserDefaults(suiteName: name)!
        defer { isolated.removePersistentDomain(forName: name) }
        isolated.set(["/already-configured"], forKey: "repositories")
        PreferencesMigration.migrate(into: isolated, legacy: ["repositories": ["/legacy"],
            "protectedPaths": ["/keep"], "discover": false, "unrelated": "do not migrate"])
        XCTAssertEqual(isolated.stringArray(forKey: "repositories"), ["/already-configured"])
        XCTAssertEqual(isolated.stringArray(forKey: "protectedPaths"), ["/keep"])
        XCTAssertFalse(isolated.bool(forKey: "discover")); XCTAssertNil(isolated.object(forKey: "unrelated"))
        isolated.removeObject(forKey: "protectedPaths")
        PreferencesMigration.migrate(into: isolated, legacy: ["protectedPaths": ["/keep"]])
        XCTAssertNil(isolated.object(forKey: "protectedPaths"))
    }
}
