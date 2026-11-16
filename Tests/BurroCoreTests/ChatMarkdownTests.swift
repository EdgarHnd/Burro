import XCTest
@testable import BurroCore

/// Tables and Codex directives in chat replies (`ChatMarkdown`, `ChatDirectives`), the previews
/// that read the same text, the chat list's provider and filter, and token counts.
final class ChatMarkdownTests: XCTestCase {
    private func table(_ blocks: [ChatMarkdown.Block], _ index: Int = 0) -> ChatTable? {
        let tables = blocks.compactMap { block -> ChatTable? in if case .table(let table) = block { table } else { nil } }
        return index < tables.count ? tables[index] : nil
    }

    // MARK: Tables

    func testTheOwnersTableIsATable() throws {
        let blocks = ChatMarkdown.blocks("| | Draw calls |\n|---|---|\n| Floor off | 160 |")
        XCTAssertEqual(blocks, [.table(ChatTable(header: ["", "Draw calls"], alignments: [.leading, .leading], rows: [["Floor off", "160"]]))])
    }

    func testAlignmentColonsAndOptionalOuterPipes() throws {
        let blocks = ChatMarkdown.blocks("Name | Left | Middle | Right\n--- | :--- | :---: | ---:\na | b | c | 1\nd | e | f | 22")
        let value = try XCTUnwrap(table(blocks))
        XCTAssertEqual(value.header, ["Name", "Left", "Middle", "Right"])
        XCTAssertEqual(value.alignments, [.leading, .leading, .center, .trailing])
        XCTAssertEqual(value.rows, [["a", "b", "c", "1"], ["d", "e", "f", "22"]])
        XCTAssertEqual(blocks.count, 1)
    }

    func testShortRowsArePaddedAndExtraCellsKept() throws {
        let value = try XCTUnwrap(table(ChatMarkdown.blocks("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")))
        XCTAssertEqual(value.columns, 4)
        XCTAssertEqual(value.header, ["a", "b", "c", ""])
        XCTAssertEqual(value.alignments.count, 4)
        XCTAssertEqual(value.rows, [["1", "", "", ""], ["1", "2", "3", "4"]])
    }

    func testEscapedPipesStayInTheCellAndInlineMarkdownIsKept() throws {
        let value = try XCTUnwrap(table(ChatMarkdown.blocks("| Expr | Note |\n|---|---|\n| `a \\| b` | **bold** and [link](https://x.y) |\n| C:\\path | x |")))
        XCTAssertEqual(value.rows[0], ["`a | b`", "**bold** and [link](https://x.y)"])
        XCTAssertEqual(value.rows[1], ["C:\\path", "x"], "other backslashes stay as written")
    }

    func testATableRightAfterAParagraphLineAndBeforeText() {
        let blocks = ChatMarkdown.blocks("Here is what I measured:\n| Case | ms |\n|---|--:|\n| cold | 812 |\n| warm | 95 |\nSo warm is fine.")
        XCTAssertEqual(blocks, [
            .paragraph("Here is what I measured:"),
            .table(ChatTable(header: ["Case", "ms"], alignments: [.leading, .trailing], rows: [["cold", "812"], ["warm", "95"]])),
            .paragraph("So warm is fine."),
        ])
    }

    func testTablesNextToListsAndHeadings() {
        let blocks = ChatMarkdown.blocks("""
        ### Results
        - first point
        | A | B |
        |---|---|
        | 1 | 2 |
        - after the table
          | nested | table |
          | --- | --- |
          | x | y |

        1. step
        """)
        XCTAssertEqual(blocks, [
            .heading("Results", 3),
            .item("•", "first point", 0),
            .table(ChatTable(header: ["A", "B"], alignments: [.leading, .leading], rows: [["1", "2"]])),
            .item("•", "after the table", 0),
            .table(ChatTable(header: ["nested", "table"], alignments: [.leading, .leading], rows: [["x", "y"]])),
            .item("1.", "step", 0),
        ])
    }

    func testAHeaderStillStreamingStaysAParagraph() {
        XCTAssertEqual(ChatMarkdown.blocks("Numbers:\n| Case | ms |"), [.paragraph("Numbers:\n| Case | ms |")])
        XCTAssertEqual(ChatMarkdown.blocks("| Case | ms |\n"), [.paragraph("| Case | ms |")])
        // A separator arriving makes it a table with no rows yet.
        XCTAssertEqual(ChatMarkdown.blocks("| Case | ms |\n|---|---|"),
                       [.table(ChatTable(header: ["Case", "ms"], alignments: [.leading, .leading], rows: []))])
    }

    func testThingsThatAreNotTablesKeepTheirText() {
        // A rule under a line with a pipe is not a separator; neither is a row of words.
        XCTAssertEqual(ChatMarkdown.blocks("a | b\n---"), [.paragraph("a | b\n---")])
        XCTAssertEqual(ChatMarkdown.blocks("a | b\n| c | d |"), [.paragraph("a | b\n| c | d |")])
        XCTAssertEqual(ChatMarkdown.blocks("|x|\n|-a-|"), [.paragraph("|x|\n|-a-|")])
        XCTAssertEqual(ChatMarkdown.blocks("use `a || b` here"), [.paragraph("use `a || b` here")])
        // Inside a code fence a table is code.
        XCTAssertEqual(ChatMarkdown.blocks("```\n| a |\n|---|\n```"), [.code("| a |\n|---|")])
    }

    func testMalformedInputNeverCrashesOrLosesText() {
        let inputs = ["|", "||", "|\n|", "|-|\n|", "| a |\n| :: |", "\\", "| \\", "| a | b |\n|---|---|\n|", "|:-:|\n|:-:|\n|:-:|", ":::", "::", "::{}", "|---|\n|---|"]
        for input in inputs {
            let blocks = ChatMarkdown.blocks(input)
            let text = blocks.map { block -> String in
                switch block {
                case .paragraph(let value), .code(let value): value
                case .table(let table): (table.header + table.rows.flatMap { $0 }).joined()
                default: "x"
                }
            }.joined()
            let letters = input.filter { $0.isLetter }
            XCTAssertTrue(letters.allSatisfy { text.contains($0) }, "kept the words of \(input.debugDescription)")
        }
        XCTAssertNotNil(table(ChatMarkdown.blocks("|---|\n|---|")), "a separator under a separator is a one-column table")
    }

    // MARK: Directives

    func testAnInboxItemBecomesANote() {
        let text = "Set up.\n::inbox-item{title=\"Morning Report runs locally\" summary=\"Keep the Mac awake and the desktop app running at 8 a.m.\"}\nDone."
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .paragraph("Set up."),
            .note(ChatNote(kind: .inbox, title: "Morning Report runs locally", detail: "Keep the Mac awake and the desktop app running at 8 a.m.")),
            .paragraph("Done."),
        ])
    }

    func testCodeCommentsBecomeNotesAndOtherDirectivesAreLeftOut() {
        let text = """
        Review done.
        ::code-comment{title="Missing nil check" body="parse() can return nil here." file="/Users/me/Dev/app/Sources/Parse.swift" start=12 end=14 priority=1}
        ::created-thread{threadId="019a-thread"}
        ::something-new{a="1"}
        That's all.
        """
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .paragraph("Review done."),
            .note(ChatNote(kind: .comment, title: "Missing nil check", detail: "parse() can return nil here. · Parse.swift:12–14")),
            .paragraph("That's all."),
        ])
    }

    func testAWritingBlockKeepsItsTextWithoutTheFences() {
        let text = "Here's the draft:\n:::writing{variant=\"email\" id=\"d1\" title=\"Reply\"}\nHi Sam,\n\nThanks!\n:::\nWant changes?"
        XCTAssertEqual(ChatMarkdown.blocks(text), [.paragraph("Here's the draft:"), .paragraph("Hi Sam,"), .paragraph("Thanks!"), .paragraph("Want changes?")])
        XCTAssertEqual(ChatMarkdown.blocks("a\n:::\nb"), [.paragraph("a\n:::\nb")], "a lone ::: outside a block is text")
    }

    func testOnlyWholeWellFormedLinesAreDirectives() {
        for text in ["Use ::inbox-item{title=\"x\"} like this", "::Inbox-Item{title=\"x\"}", "::inbox_item{title=\"x\"}",
                     "::selection{color:red}", "::inbox-item{title=\"x\"", "::-x{a=\"1\"}", "::x-{a=\"1\"}", "::a--b{a=\"1\"}",
                     "::::x{a=\"1\"}", "::x{a=\"1\" junk}", "::x{=\"1\"}", "a::x{a=\"1\"}"] {
            XCTAssertNil(ChatDirectives.parse(text), text)
            XCTAssertFalse(ChatMarkdown.blocks(text).contains { if case .note = $0 { true } else { false } }, text)
            XCTAssertFalse(ChatMarkdown.blocks(text).isEmpty, "\(text) is kept as text")
        }
        XCTAssertEqual(ChatDirectives.parse("  ::inbox-item{title=\"Say \\\"hi\\\"\" summary=\"a}b\"}  "),
                       ChatDirectives.Directive(name: "inbox-item", attributes: ["title": "Say \"hi\"", "summary": "a}b"]))
        XCTAssertEqual(ChatDirectives.parse("::thing{}"), ChatDirectives.Directive(name: "thing", attributes: [:]))
        XCTAssertEqual(ChatDirectives.parse(":::writing{variant=\"chat_message\"}")?.opensBlock, true)
    }

    func testAReplyOfOnlyDirectivesLeavesNoEmptyBlock() {
        XCTAssertEqual(ChatMarkdown.blocks("::created-thread{threadId=\"t\"}\n\n::x{}"), [])
        XCTAssertEqual(ChatMarkdown.blocks("::inbox-item{summary=\"Only a summary\"}"),
                       [.note(ChatNote(kind: .inbox, title: "Only a summary", detail: nil))])
        XCTAssertEqual(ChatMarkdown.blocks("::inbox-item{}"), [])
    }

    // MARK: Previews

    func testPreviewsSkipDirectives() {
        XCTAssertEqual(ChatListPresentation.preview("::created-thread{threadId=\"t\"}\nOpened the **new** thread."), "Opened the new thread.")
        XCTAssertEqual(ChatListPresentation.preview("::inbox-item{title=\"Morning Report runs locally\" summary=\"Keep it awake\"}"),
                       "Morning Report runs locally")
        XCTAssertEqual(ChatListPresentation.preview(":::writing{variant=\"email\" id=\"1\" title=\"T\"}\nHi Sam,"), "Hi Sam,")
        XCTAssertEqual(ChatListPresentation.preview(":::\nNext"), "Next")
        XCTAssertNil(ChatListPresentation.preview("::created-thread{threadId=\"t\"}"))
    }

    func testPreviewsDropADirectiveCutOffByTheScan() {
        // The activity scan keeps one line and cuts it at 160 characters.
        let cut = "::inbox-item{title=\"Morning Report runs locally\" summary=\"Keep the Mac awake and the desktop app running at 8 a.m. so the report can"
        XCTAssertEqual(ChatListPresentation.preview(cut), "Morning Report runs locally")
        XCTAssertNil(ChatListPresentation.preview("::code-comment{title=\"Missing nil check\" body=\"parse() can retu"))
        XCTAssertNil(ChatListPresentation.preview("::inbox-item{title=\"Morning Rep"))
        XCTAssertEqual(ChatListPresentation.preview("::not a directive {"), "::not a directive {")
        XCTAssertEqual(ChatListPresentation.preview("::selection{color:red"), "::selection{color:red")
    }

    // MARK: The chat list's provider

    func testRowsCarryTheirProviderAndSayIt() {
        var session = AgentSession(id: "codex:1", provider: .codex, title: "Release notes", cwd: "/tmp", state: .working, updatedAt: Date(), evidence: "t")
        let row = ChatListRow.make(session, in: .working, pinned: true, folder: "app", preview: nil, now: Date(), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(row.provider, .codex)
        XCTAssertEqual(row.agent, "Codex")
        XCTAssertTrue(row.accessibilityLabel.hasPrefix("Pinned, Release notes, Codex, Working, app · "), row.accessibilityLabel)
        session.provider = .claude
        XCTAssertEqual(ChatListRow.make(session, in: .working, pinned: false, folder: "app", preview: nil, now: Date(),
                                        calendar: Calendar(identifier: .gregorian)).agent, "Claude")
    }

    func testTheFilterMatchesTheAgentAndModel() {
        func match(_ query: String, _ provider: AgentProvider, model: String? = nil) -> Bool {
            ChatListRow.matches(query, title: "Fix the hang", place: "This Mac · app", provider: provider, model: model)
        }
        XCTAssertTrue(match("codex", .codex))
        XCTAssertFalse(match("codex", .claude))
        XCTAssertTrue(match("CLAUDE", .claude))
        XCTAssertFalse(match("claude", .codex))
        XCTAssertTrue(match("opus", .claude, model: "claude-opus-5-5"))
        XCTAssertTrue(match("opus 5.5", .claude, model: "claude-opus-5-5"))
        XCTAssertTrue(match("gpt-5", .codex, model: "gpt-5.5-codex"))
        XCTAssertFalse(match("opus", .claude))
        XCTAssertTrue(match("hang", .codex))
        XCTAssertTrue(match("this mac", .codex))
        XCTAssertTrue(match("", .codex))
        XCTAssertTrue(match("code", .codex) && match("code", .claude), "\"code\" matches Codex and Claude Code alike")
    }

    // MARK: Token counts

    func testTokenCountsReachBillionsAndIgnoreTheLanguage() {
        XCTAssertEqual(TokenCount.compact(999_400_000), "999M")
        XCTAssertEqual(TokenCount.compact(1_000_000_000), "1B")
        XCTAssertEqual(TokenCount.compact(3_420_000_000), "3.4B")
        XCTAssertEqual(TokenCount.compact(500_400), "500K")
        XCTAssertEqual(TokenCount.compact(104_212), "104K")
        XCTAssertEqual(TokenCount.compact(.nan), "0")
        XCTAssertEqual(TokenCount.compact(1_260), "1.3K")
    }
}
