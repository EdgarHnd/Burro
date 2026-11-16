// Check the closed-chat lookup in a temporary Claude app session folder (match, archived, id shapes,
// oversized and symlinked records, no record) and the one decision every Open by id uses.
import XCTest
@testable import BurroCore

final class ClosedChatLinkTests: XCTestCase {
    private let uuid = "1ddf8b09-2222-4333-8444-555555555555"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("closed-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var org: URL { root.appendingPathComponent("account/org", isDirectory: true) }

    @discardableResult
    private func record(_ name: String, cli: String, session: String? = nil, archived: Bool = false, in folder: URL? = nil,
                        padding: Int = 0) throws -> URL {
        let folder = folder ?? org
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var object: [String: Any] = ["sessionId": session ?? name, "cliSessionId": cli, "isArchived": archived, "title": "Weekly Mac leftovers check"]
        if padding > 0 { object["padding"] = String(repeating: "x", count: padding) }
        let url = folder.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testAMatchingRecordGivesTheSameLinkAListedChatWould() throws {
        try record("local_other", cli: "99999999-2222-4333-8444-555555555555")
        try record("local_abc-123", cli: uuid)
        let expected = AgentSession.claudeDesktopURL("local_abc-123")
        XCTAssertEqual(expected?.absoluteString, "claude://code/continue?session=local_abc-123")
        XCTAssertEqual(ClosedChatLink.link(for: "claude:\(uuid)", root: root), expected)
        XCTAssertEqual(ClosedChatLink.link(for: "claude:\(uuid.uppercased())", root: root), expected, "ids compare without case")
    }

    func testArchivedRecordsAndMissingRecordsGiveNoLink() throws {
        try record("local_archived", cli: uuid, archived: true)
        XCTAssertNil(ClosedChatLink.link(for: "claude:\(uuid)", root: root))
        XCTAssertNil(ClosedChatLink.link(for: "claude:aaaaaaaa-2222-4333-8444-555555555555", root: root))
        XCTAssertNil(ClosedChatLink.link(for: "claude:\(uuid)", root: root.appendingPathComponent("missing")))
    }

    func testOnlyLocalClaudeIDsAreLookedUp() throws {
        try record("local_abc", cli: uuid)
        for id in ["codex:\(uuid)", "remote:\(UUID().uuidString):claude:\(uuid)", "claude:not-a-uuid", "claude:\(uuid)x", uuid, "claude:"] {
            XCTAssertNil(ClosedChatLink.link(for: id, root: root), id)
        }
    }

    func testARecordWhoseSessionIDIsNotADesktopIDGivesNoLink() throws {
        try record("local_bad", cli: uuid, session: "local_bad&evil=1")
        XCTAssertNil(ClosedChatLink.link(for: "claude:\(uuid)", root: root))
    }

    func testOversizedRecordsOtherFilesAndWrongDepthsAreSkipped() throws {
        try record("local_big", cli: uuid, padding: 1024 * 1024)
        try record("other_name", cli: uuid)
        try record("local_shallow", cli: uuid, in: root.appendingPathComponent("account", isDirectory: true))
        try record("local_deep", cli: uuid, in: org.appendingPathComponent("nested", isDirectory: true))
        XCTAssertNil(ClosedChatLink.link(for: "claude:\(uuid)", root: root))
    }

    func testSymlinksAreNeverFollowed() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("closed-chat-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = try record("local_outside", cli: uuid, in: outside.appendingPathComponent("org", isDirectory: true))
        // A linked record file, and a linked account folder.
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: org.appendingPathComponent("local_link.json"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertNil(ClosedChatLink.link(for: "claude:\(uuid)", root: root))
    }

    func testOneWalkAnswersManyIDs() throws {
        let second = "bbbbbbbb-2222-4333-8444-555555555555"
        try record("local_one", cli: uuid)
        try record("local_two", cli: second, in: root.appendingPathComponent("account2/org2", isDirectory: true))
        let links = ClosedChatLink.links(for: ["claude:\(uuid)", "claude:\(second)", "codex:\(uuid)"], root: root)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links["claude:\(second)"]?.absoluteString, "claude://code/continue?session=local_two")
    }

    // MARK: What Open does

    func testOpenShowsListedChatsInBurroOpensClosedOnesInClaudeAndOtherwiseExplains() {
        let id = "claude:\(uuid)"
        let link = AgentSession.claudeDesktopURL("local_abc")
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: id, listed: true, listLoaded: true, link: link), .showInBurro)
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: id, listed: false, listLoaded: true, link: link), .openInClaude(link!))
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: id, listed: false, listLoaded: true, link: nil), .explain)
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: id, listed: false, listLoaded: false, link: link), .showInBurro,
                       "before the first agent check every chat looks unlisted")
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: "codex:\(uuid)", listed: false, listLoaded: true, link: link), .explain)
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: "remote:\(UUID().uuidString):claude:\(uuid)", listed: false, listLoaded: true, link: link),
                       .explain)
        XCTAssertEqual(ClosedChatLink.openTarget(chatID: id, listed: false, listLoaded: true, link: URL(string: "https://example.com")), .explain)
    }
}
