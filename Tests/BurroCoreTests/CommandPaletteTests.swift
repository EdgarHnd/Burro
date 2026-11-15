// The ⌘K palette's ranking: match tiers, word starts, chat status, ignoring case and accents,
// stable ties, the empty-query list, the result cap, and the cost of indexing a few hundred chats.
import XCTest
@testable import BurroCore

final class CommandPaletteTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ id: String, _ title: String, status: CommandPaletteItem.Status = .recent,
                      minutesAgo: Double = 10, keywords: [String] = []) -> CommandPaletteItem {
        CommandPaletteItem(id: id, kind: .chat, title: title, keywords: keywords, status: status,
                           updatedAt: now.addingTimeInterval(-minutesAgo * 60))
    }
    private func ids(_ items: [CommandPaletteItem]) -> [String] { items.map(\.id) }

    func testPrefixBeatsSubstringBeatsSubsequence() {
        let index = CommandPaletteIndex([
            CommandPaletteItem(id: "subsequence", kind: .project, title: "Brt ultra"),
            CommandPaletteItem(id: "substring", kind: .project, title: "Mybrutal"),
            CommandPaletteItem(id: "prefix", kind: .project, title: "Brutalist"),
        ])
        XCTAssertEqual(ids(index.results(for: "bru")), ["prefix", "substring", "subsequence"])
        let mixed = CommandPaletteIndex([
            CommandPaletteItem(id: "subsequence", kind: .project, title: "b-r-u-t"),
            CommandPaletteItem(id: "substring", kind: .project, title: "xbrut"),
            CommandPaletteItem(id: "prefix", kind: .project, title: "brut"),
        ])
        XCTAssertEqual(ids(mixed.results(for: "brut")), ["prefix", "substring", "subsequence"])
    }

    func testWordStartsScoreHigher() {
        let index = CommandPaletteIndex([
            CommandPaletteItem(id: "inside", kind: .project, title: "Debugger notes"),
            CommandPaletteItem(id: "word", kind: .project, title: "Fix bug report"),
        ])
        XCTAssertEqual(ids(index.results(for: "bug")), ["word", "inside"])
        let initials = CommandPaletteIndex([
            CommandPaletteItem(id: "scattered", kind: .action, title: "Unicorn"),
            CommandPaletteItem(id: "initials", kind: .action, title: "New chat"),
        ])
        XCTAssertEqual(ids(initials.results(for: "nc")), ["initials", "scattered"])
    }

    func testChatsThatNeedYouRankAboveWorkingAboveRecent() {
        let index = CommandPaletteIndex([
            chat("recent", "Deploy script", status: .recent, minutesAgo: 1),
            chat("working", "Deploy docs", status: .working, minutesAgo: 5),
            chat("needs", "Deploy fix", status: .needsYou, minutesAgo: 30),
        ])
        XCTAssertEqual(ids(index.results(for: "deploy")), ["needs", "working", "recent"])
        // Status never lifts a weaker kind of match over a stronger one.
        let tiers = CommandPaletteIndex([
            chat("needs-subsequence", "d-e-p-l-o-y", status: .needsYou),
            chat("recent-substring", "Redeploy", status: .recent),
        ])
        XCTAssertEqual(ids(tiers.results(for: "deploy")), ["recent-substring", "needs-subsequence"])
    }

    func testCaseAndAccentsAreIgnored() {
        let index = CommandPaletteIndex([chat("cafe", "Café Résumé"), chat("other", "Unrelated")])
        XCTAssertEqual(ids(index.results(for: "cafe resume")), ["cafe"])
        XCTAssertEqual(ids(index.results(for: "CAFÉ")), ["cafe"])
        XCTAssertEqual(CommandPaletteIndex.fold("  Ünïcode   Tëxt "), "unicode text")
    }

    func testKeywordsAndSeparateWordsMatch() {
        let index = CommandPaletteIndex([
            chat("a", "Refactor login", keywords: ["Studio Mac", "focustown", "Codex"]),
            chat("b", "Refactor login", keywords: ["This Mac", "burro", "Claude Code"]),
        ])
        XCTAssertEqual(ids(index.results(for: "studio")), ["a"])
        XCTAssertEqual(ids(index.results(for: "login burro")), ["b"], "Every word must match somewhere")
        XCTAssertEqual(ids(index.results(for: "claude")), ["b"])
        XCTAssertTrue(index.results(for: "login nowhere").isEmpty)
        // Keywords only match as text, never as scattered letters.
        XCTAssertTrue(index.results(for: "smc").isEmpty)
    }

    func testTiesKeepRecencyThenGivenOrder() {
        let index = CommandPaletteIndex([
            CommandPaletteItem(id: "first", kind: .project, title: "Alpha"),
            CommandPaletteItem(id: "second", kind: .project, title: "Alpha"),
            chat("older", "Alpha", minutesAgo: 60),
            chat("newer", "Alpha", minutesAgo: 1),
        ])
        XCTAssertEqual(ids(index.results(for: "alpha")), ["newer", "older", "first", "second"])
        XCTAssertEqual(ids(index.results(for: "alpha")), ids(index.results(for: "alpha")))
    }

    func testEmptyQueryListsPagesThenChatsThatNeedYouThenRecentChats() {
        let index = CommandPaletteIndex([
            chat("idle-new", "Idle new", status: .recent, minutesAgo: 1),
            CommandPaletteItem(id: "page:home", kind: .page, title: "Home"),
            chat("needs-old", "Needs old", status: .needsYou, minutesAgo: 90),
            CommandPaletteItem(id: "action", kind: .action, title: "Refresh"),
            chat("working", "Working", status: .working, minutesAgo: 40),
            CommandPaletteItem(id: "page:chats", kind: .page, title: "Chats"),
            chat("needs-new", "Needs new", status: .needsYou, minutesAgo: 5),
            CommandPaletteItem(id: "project", kind: .project, title: "Burro"),
        ])
        XCTAssertEqual(ids(index.results(for: "   ")),
                       ["page:home", "page:chats", "needs-new", "needs-old", "working", "idle-new"])
    }

    func testResultsAreCapped() {
        let index = CommandPaletteIndex((0..<200).map { chat("c\($0)", "Chat number \($0)") })
        XCTAssertEqual(index.results(for: "chat").count, CommandPaletteIndex.defaultLimit)
        XCTAssertEqual(index.results(for: "chat", limit: 7).count, 7)
        XCTAssertEqual(index.results(for: "", limit: 3).count, 3)
    }

    func testWeightKeepsSecondaryItemsBelowTheirSubject() {
        let index = CommandPaletteIndex([
            CommandPaletteItem(id: "ask", kind: .action, title: "Ask the Orchestrator about “Ship release”", weight: -40),
            chat("chat", "Ship release"),
        ])
        XCTAssertEqual(ids(index.results(for: "ship release")), ["chat", "ask"])
    }

    /// Building happens once per opening; filtering runs per keystroke. Both stay well under a frame.
    func testIndexingAndFilteringHundredsOfChatsIsCheap() {
        let words = ["refactor", "login", "deploy", "notch", "palette", "fix", "crash", "worker", "rust", "swift", "today", "usage"]
        var items: [CommandPaletteItem] = []
        for i in 0..<600 {
            let title = words[i % words.count].capitalized + " " + words[(i * 7) % words.count] + " task \(i)"
            let status: CommandPaletteItem.Status = i % 17 == 0 ? .needsYou : (i % 5 == 0 ? .working : .recent)
            let provider = i % 2 == 0 ? "Codex" : "Claude Code"
            items.append(chat("chat-\(i)", title, status: status, minutesAgo: Double(i),
                              keywords: ["Machine \(i % 4)", "project-\(i % 9)", provider]))
        }
        let clock = ContinuousClock()
        var index = CommandPaletteIndex([])
        let build = clock.measure { index = CommandPaletteIndex(items) }
        var count = 0
        let filter = clock.measure {
            for query in ["r", "re", "ref", "refa", "refac", "rft", "machine 2", "codex fix"] { count += index.results(for: query).count }
        }
        print("CommandPalette: built 600 items in \(build), 8 queries in \(filter)")
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(build, Duration.seconds(1))
        XCTAssertLessThan(filter, Duration.seconds(1))
    }
}
