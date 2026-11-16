import XCTest
@testable import BurroCore

final class SettingsDisclosureTests: XCTestCase {
    private func state(triage: Bool = true, shipped: Bool = true, usage: Bool = false, notes: Bool = false,
                       todos: String? = nil, machines: [String] = []) -> SettingsDisclosure.State {
        .init(triage: triage, shippedSummaries: shipped, usageLimits: usage, notesAccess: notes, todoSyncHost: todos,
              machines: machines, smallModel: "Haiku 5.5")
    }

    func testEverythingOnSendsEachChannelAndActivityNeverLeaves() {
        let lines = SettingsDisclosure.lines(state(usage: true, notes: true, todos: "acme.convex.cloud", machines: ["Studio"]))
        XCTAssertEqual(lines.map(\.id), ["triage", "shipped", "ask", "usage", "todos", "activity", "ssh"])
        XCTAssertEqual(lines[0].text, "Chat endings go to Claude Haiku 5.5 for triage")
        XCTAssertTrue(lines[0].sends)
        XCTAssertTrue(lines[2].text.hasSuffix("and your notes when it needs them"))
        XCTAssertEqual(lines[4].text, "To-dos sync with your Convex backend (acme.convex.cloud)")
        XCTAssertEqual(lines[5].text, "Nothing from tracked activity is sent anywhere")
        XCTAssertFalse(lines[5].sends)
        XCTAssertEqual(lines[6].text, "SSH connects only to your own machine, Studio")
    }

    func testTogglesOffSayNothingIsSent() {
        let lines = SettingsDisclosure.lines(state(triage: false, shipped: false))
        XCTAssertEqual(lines.map(\.id), ["triage", "shipped", "ask", "activity", "ssh"])
        XCTAssertEqual(lines[0].text, "Triage is off, so no chat endings are sent")
        XCTAssertFalse(lines[0].sends)
        XCTAssertFalse(lines[1].sends)
        XCTAssertFalse(lines[2].text.contains("notes"))
        XCTAssertEqual(lines.last?.text, "No SSH connections: you haven't added another machine")
    }

    func testSSHLineNamesTwoMachinesAndCountsMore() {
        XCTAssertEqual(SettingsDisclosure.sshLine(["A", "B"]), "SSH connects only to your own machines, A and B")
        XCTAssertEqual(SettingsDisclosure.sshLine(["A", "B", "C"]), "SSH connects only to the 3 machines you added")
    }

    func testOrchestratorSummary() {
        XCTAssertEqual(SettingsDisclosure.orchestratorSummary(triage: true, morningBrief: true, notesAccess: false),
                       "Triage is on, the morning brief is on, and it can't read your notes.")
        XCTAssertEqual(SettingsDisclosure.orchestratorSummary(triage: true, morningBrief: false, notesAccess: true),
                       "Triage is on, the morning brief is off, and it can read your notes.")
        XCTAssertEqual(SettingsDisclosure.orchestratorSummary(triage: false, morningBrief: true, notesAccess: false),
                       "Triage is off, so chats aren't read as they end, and it can't read your notes.")
        XCTAssertEqual(SettingsDisclosure.capUsage(runsToday: 9, cap: 150), "9 of 150 used today")
    }
}
