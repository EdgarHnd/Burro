import XCTest
@testable import BurroCore

final class SharedStatusPolicyTests: XCTestCase {
    func testSharedRemoteLocalFixtures() throws {
        struct Fixtures: Decodable {
            struct Codex: Decodable { let tail: String; let held: Int32; let age: Double; let state: String; let completed: Bool }
            struct Claude: Decodable { let status: String; let live: Bool; let state: String }
            let codex: [Codex]; let claude: [Claude]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("policy/status-fixtures.json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: data), now = Date()
        for item in fixtures.codex {
            XCTAssertEqual(AgentParsing.codexState(tail: item.tail, held: item.held, modified: now.addingTimeInterval(-item.age), now: now).rawValue, item.state)
            XCTAssertEqual(AgentParsing.codexCompleted(tail: item.tail), item.completed)
        }
        for item in fixtures.claude {
            XCTAssertEqual(AgentParsing.claudeState(item.status, live: item.live).rawValue, item.state)
        }
    }
}
