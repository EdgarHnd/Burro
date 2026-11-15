// Check the orchestrator's proposed-actions file: round trips, tolerant reads, expiry, pruning,
// dedupe of an identical proposal, and owner-only permissions. Everything runs in a temporary
// folder; nothing is ever sent.
import XCTest
@testable import BurroCore

final class OrchestratorActionsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> OrchestratorActionStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-actions-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return OrchestratorActionStore(url: folder.appendingPathComponent("Orchestrator/actions.json"))
    }
    private func reply(_ text: String = "Go with B", at date: Date? = nil) -> OrchestratorAction {
        OrchestratorAction(kind: .reply, createdAt: date ?? start, text: text, chatID: "claude:11111111-2222-4333-8444-555555555555",
                           chatTitle: "Fix login", machine: "devbox")
    }

    func testProposalsRoundTripThroughDisk() throws {
        let store = try store()
        var launch = OrchestratorAction(kind: .start, createdAt: start, text: "Fix it", agent: "codex", folder: "/Dev/focustown",
                                        model: "gpt-6", effort: "high", access: "edit")
        launch.status = .sent; launch.result = "Started Codex in focustown."; launch.startedChatID = "codex:abc"; launch.sentAt = start
        _ = try store.propose(reply(), now: start)
        _ = try store.propose(launch, now: start)
        let loaded = store.load()
        XCTAssertEqual(loaded, [reply().withID(loaded[0].id), launch])
        XCTAssertEqual(loaded[1].provider, .codex)
        XCTAssertEqual(loaded[1].launchAccess, .edit)
        XCTAssertEqual(loaded[1].headline, "Start a Codex chat in focustown")
        XCTAssertEqual(loaded[0].headline, "Reply to “Fix login” on devbox")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    func testReadsAreTolerant() throws {
        let store = try store()
        XCTAssertEqual(store.load(), [], "no file reads as none")
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), [], "a damaged file reads as none")
        let good = try OrchestratorActionStore.encode([reply()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var rows = try XCTUnwrap(object["actions"] as? [[String: Any]])
        rows.insert(["id": "x", "kind": "teleport", "createdAt": 1, "text": "?", "status": "pending"], at: 0)
        rows.append(["kind": "reply"])
        rows[1]["somethingNew"] = "from a later Burro"
        object["actions"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        XCTAssertEqual(store.load().map(\.text), ["Go with B"], "entries that don't decode are skipped; unknown keys are ignored")
    }

    func testProposalsExpireAfterADayAndLeaveAfterAWeek() throws {
        var action = reply()
        XCTAssertTrue(action.isWaiting(now: start.addingTimeInterval(86_399)))
        XCTAssertTrue(action.isExpired(now: start.addingTimeInterval(86_400)))
        XCTAssertFalse(action.isWaiting(now: start.addingTimeInterval(86_400)))
        action.status = .sent
        XCTAssertFalse(action.isExpired(now: start.addingTimeInterval(90_000)), "a sent action is never expired")

        let store = try store()
        _ = try store.propose(reply("old"), now: start)
        _ = try store.propose(reply("new", at: start.addingTimeInterval(3 * 86_400)), now: start.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(store.load().map(\.text), ["old", "new"], "an expired proposal stays to be shown as expired")
        try store.update(now: start.addingTimeInterval(7 * 86_400)) { _ in }
        XCTAssertEqual(store.load().map(\.text), ["new"], "after a week it leaves the file")
    }

    func testAnIdenticalProposalIsNotAddedTwice() throws {
        let store = try store()
        let first = try store.propose(reply(), now: start)
        XCTAssertFalse(first.duplicate)
        let again = try store.propose(reply("  Go with B\n"), now: start.addingTimeInterval(60))
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(again.action.id, first.action.id)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertFalse(try store.propose(reply("Go with A"), now: start).duplicate, "different text is a different proposal")
        var elsewhere = reply(); elsewhere.chatID = "claude:22222222-3333-4444-8555-666666666666"
        XCTAssertFalse(try store.propose(elsewhere, now: start).duplicate, "a different chat is a different proposal")
        // Once the first one is sent or expired, the same text can be proposed again.
        try store.modify(first.action.id) { $0.status = .sent }
        XCTAssertFalse(try store.propose(reply(), now: start.addingTimeInterval(120)).duplicate)
        XCTAssertFalse(try store.propose(reply("Go with A"), now: start.addingTimeInterval(2 * 86_400)).duplicate)
    }

    func testModifyAndDiscard() throws {
        let store = try store()
        let id = try store.propose(reply(), now: start).action.id
        XCTAssertTrue(try store.modify(id) { $0.error = "This chat is open in Claude Code." })
        XCTAssertEqual(store.load().first?.error, "This chat is open in Claude Code.")
        XCTAssertEqual(store.load().first?.status, .pending, "a failed send stays pending")
        try store.discard(id)
        XCTAssertEqual(store.load(), [])
        XCTAssertFalse(try store.modify(id) { $0.text = "gone" })
    }

    func testFileIsOwnerOnly() throws {
        let store = try store()
        _ = try store.propose(reply(), now: start)
        func mode(_ path: String) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777
        }
        XCTAssertEqual(try mode(store.url.path), 0o600)
        XCTAssertEqual(try mode(store.url.path + ".lock"), 0o600)
        XCTAssertEqual(try mode(store.url.deletingLastPathComponent().path), 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual(Set(leftovers), ["actions.json", "actions.json.lock"], "no temporary files are left behind")
    }

    func testModelsKeepTheDefaultSelectable() {
        let models = Orchestrator.models
        XCTAssertEqual(models.first?.id, Orchestrator.model, "the default comes first")
        XCTAssertEqual(models.filter { $0.id == Orchestrator.model }.count, 1)
        for model in LaunchModel.claude { XCTAssertTrue(models.contains(model), "\(model.id) is offered") }
        XCTAssertEqual(Orchestrator.modelTitle(Orchestrator.model), Orchestrator.modelTitle)
        XCTAssertEqual(Orchestrator.modelTitle("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(Orchestrator.validModel(nil), Orchestrator.model)
    }
}

private extension OrchestratorAction {
    func withID(_ id: String) -> OrchestratorAction { var copy = self; copy.id = id; return copy }
}
