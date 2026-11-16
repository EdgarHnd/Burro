// Pending launches: a row per started chat, matched to the feed's session by thread or session id
// (case-insensitive, provider-prefixed), failure keeping the request for Retry, the overdue notice,
// and the row text. Also the chat list's place tags and previews, the notch/menu-bar open target,
// and the palette's "Start chat: …" row.
import XCTest
@testable import BurroCore

final class PendingLaunchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let request = LaunchRequest(provider: .claude, prompt: "\n  Fix the login bug\nand add a test", folder: "/p/a", access: .edit)

    func testMatchesTheStartedSessionAndHandsOverItsRow() {
        var launches = PendingLaunches()
        let claude = launches.begin(request, follow: true, now: now)
        let codex = launches.begin(LaunchRequest(provider: .codex, prompt: "Go", folder: "/p/b"), follow: false, now: now)
        XCTAssertEqual(launches.items.map(\.id), [codex.id, claude.id], "newest first")
        XCTAssertFalse(launches.awaitingFeed)

        // Nothing matches before the provider answers.
        XCTAssertTrue(launches.reconcile(feedIDs: ["claude:abc"]).isEmpty)

        launches.succeed(claude.id, with: LaunchResult(provider: .claude, sessionID: "8E0C2A1B-0000-4000-8000-000000000001", handle: "8e0c2a1b", folder: "/p/a"))
        launches.succeed(codex.id, with: LaunchResult(provider: .codex, sessionID: "019a-thread", handle: nil, folder: "/p/b"))
        XCTAssertTrue(launches.awaitingFeed)
        XCTAssertEqual(launches.launch(claude.id)?.sessionID, "claude:8e0c2a1b-0000-4000-8000-000000000001")

        let matched = launches.reconcile(feedIDs: ["codex:other", "claude:8e0c2a1b-0000-4000-8000-000000000001"])
        XCTAssertEqual(matched.map(\.rowID), [claude.rowID])
        XCTAssertEqual(matched.map(\.sessionID), ["claude:8e0c2a1b-0000-4000-8000-000000000001"])
        XCTAssertNil(launches.launch(claude.id))
        XCTAssertNotNil(launches.launch(codex.id))

        XCTAssertEqual(launches.reconcile(feedIDs: ["codex:019a-thread"]).map(\.rowID), [codex.rowID])
        XCTAssertTrue(launches.isEmpty)
    }

    func testFailureKeepsTheRequestAndNeverMatches() {
        var launches = PendingLaunches()
        let launch = launches.begin(request, follow: true, now: now)
        launches.fail(launch.id, message: "The chat did not start. Claude Code stopped at a prompt.\nMore detail")
        let failed = launches.launch(launch.id)!
        XCTAssertTrue(failed.isFailed)
        XCTAssertEqual(failed.request, request)
        XCTAssertEqual(failed.status(now: now), "The chat did not start. Claude Code stopped at a prompt.")
        XCTAssertTrue(launches.reconcile(feedIDs: ["claude:x"]).isEmpty)
        XCTAssertFalse(launches.awaitingFeed)
        XCTAssertEqual(LaunchForm(draft: LaunchDraft(retrying: failed.request), fallbackFolder: "", defaults: LaunchDefaults(),
                                  models: { $0 == .claude ? LaunchModel.claude : [] }).request, request)
        launches.remove(launch.id)
        XCTAssertTrue(launches.isEmpty)
    }

    func testRowIDsLookupAndText() {
        var launches = PendingLaunches()
        let launch = launches.begin(request, follow: true, now: now)
        XCTAssertTrue(launch.rowID.hasPrefix(PendingLaunch.rowPrefix))
        XCTAssertEqual(launches.launch(rowID: launch.rowID)?.id, launch.id)
        XCTAssertNil(launches.launch(rowID: "claude:\(launch.id.uuidString)"))
        XCTAssertNil(launches.launch(rowID: nil))
        XCTAssertEqual(launch.title, "Fix the login bug")
        XCTAssertEqual(PendingLaunch(request: LaunchRequest(provider: .codex, prompt: "  ", folder: "/p"), startedAt: now, follow: true).title, "New chat")
        XCTAssertEqual(PendingLaunch(request: LaunchRequest(provider: .codex, prompt: String(repeating: "x", count: 200), folder: "/p"),
                                     startedAt: now, follow: true).title.count, 80)
        XCTAssertEqual(launch.status(now: now), "Starting… checking it got going")
        XCTAssertEqual(PendingLaunch(request: LaunchRequest(provider: .codex, prompt: "Go", folder: "/p"), startedAt: now, follow: true).status(now: now), "Starting…")
    }

    func testAStartedChatThatDoesntAppearSaysSo() {
        var launches = PendingLaunches()
        let launch = launches.begin(request, follow: true, now: now)
        XCTAssertFalse(launches.launch(launch.id)!.isOverdue(now: now.addingTimeInterval(600)), "still starting is never overdue")
        launches.succeed(launch.id, with: LaunchResult(provider: .claude, sessionID: "s", handle: nil, folder: "/p/a"))
        let started = launches.launch(launch.id)!
        XCTAssertFalse(started.isOverdue(now: now.addingTimeInterval(10)))
        XCTAssertEqual(started.status(now: now.addingTimeInterval(10)), "Started · opening…")
        XCTAssertTrue(started.isOverdue(now: now.addingTimeInterval(PendingLaunch.listingGrace + 1)))
        XCTAssertEqual(started.status(now: now.addingTimeInterval(PendingLaunch.listingGrace + 1)), "Started · not in the list yet")
    }

    // MARK: Chat list, open target, palette

    func testPreviewIsPlainText() {
        XCTAssertEqual(ChatListPresentation.preview("The [redesign session](#local_4f35f387-59ab) is merged."), "The redesign session is merged.")
        XCTAssertEqual(ChatListPresentation.preview("The [redesign session](#local_4f35f387-59…"), "The redesign session",
                       "A link the scan cut off keeps its text")
        XCTAssertEqual(ChatListPresentation.preview("**Done**: `swift test` passes __now__."), "Done: swift test passes now.")
        XCTAssertEqual(ChatListPresentation.preview("## Summary\nmore"), "Summary")
        XCTAssertEqual(ChatListPresentation.preview("> - Merged *both* PRs"), "Merged both PRs")
        XCTAssertEqual(ChatListPresentation.preview("1. Ran the tests"), "Ran the tests")
        XCTAssertEqual(ChatListPresentation.preview("- [x] Shipped 2.2.24"), "Shipped 2.2.24")
        XCTAssertEqual(ChatListPresentation.preview("![shot](/tmp/a.png) attached"), "shot attached")
        XCTAssertEqual(ChatListPresentation.preview("snake_case_name and 3 * 4 = 12"), "snake_case_name and 3 * 4 = 12", "Underscores and maths inside text stay")
        XCTAssertNil(ChatListPresentation.preview("**  **\n`` "))
    }

    func testPreviewIsTheFirstLineCollapsedAndShortened() {
        XCTAssertNil(ChatListPresentation.preview(nil))
        XCTAssertNil(ChatListPresentation.preview(" \n  \n"))
        XCTAssertEqual(ChatListPresentation.preview("\n  Done:   tests   pass.\nSecond line"), "Done: tests pass.")
        let long = ChatListPresentation.preview(String(repeating: "word ", count: 100))!
        XCTAssertEqual(long.count, 140)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testOpenTarget() {
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: true, optionKey: false, hasProviderLink: true), .burro)
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: true, optionKey: true, hasProviderLink: true), .provider)
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: false, optionKey: false, hasProviderLink: true), .provider)
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: false, optionKey: true, hasProviderLink: true), .burro)
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: false, optionKey: false, hasProviderLink: false), .burro)
        XCTAssertEqual(ChatOpenTarget.decide(openInBurro: true, optionKey: true, hasProviderLink: false), .burro)
    }

    func testPaletteStartChatIsAloneWhenNothingMatchesAndLastOtherwise() {
        let index = CommandPaletteIndex([
            CommandPaletteItem(id: "page:home", kind: .page, title: "Home"),
            CommandPaletteItem(id: "chat:1", kind: .chat, title: "Fix the login flow", status: .needsYou),
            CommandPaletteItem(id: "action:new-chat", kind: .action, title: "New chat…"),
        ])
        let none = CommandPaletteStartChat.results(index.results(for: "refactor the parser"), query: "refactor the parser", projectName: "Burro")
        XCTAssertEqual(none.map(\.id), [CommandPaletteStartChat.itemID])
        XCTAssertEqual(none.first?.title, "Start chat: “refactor the parser”")
        XCTAssertEqual(none.first?.subtitle, "in Burro · opens the New chat sheet")

        let some = CommandPaletteStartChat.results(index.results(for: "login"), query: "login", projectName: nil)
        XCTAssertEqual(some.map(\.id), ["chat:1", CommandPaletteStartChat.itemID])
        XCTAssertEqual(some.last?.subtitle, "opens the New chat sheet")

        // A full result list still ends with the row, and it is never doubled.
        let capped = index.results(for: "h", limit: 1)
        let withRow = CommandPaletteStartChat.results(capped, query: "h", projectName: nil)
        XCTAssertEqual(withRow.count, capped.count + 1)
        XCTAssertEqual(CommandPaletteStartChat.results(withRow, query: "h", projectName: nil).filter { $0.id == CommandPaletteStartChat.itemID }.count, 1)

        XCTAssertEqual(CommandPaletteStartChat.results(index.results(for: ""), query: "   ", projectName: "Burro").map(\.id),
                       index.results(for: "").map(\.id), "an empty query adds nothing")
        let long = CommandPaletteStartChat.item(query: String(repeating: "a", count: 100), projectName: nil)!
        XCTAssertEqual(long.title, "Start chat: “" + String(repeating: "a", count: 59) + "…”")
    }
}
