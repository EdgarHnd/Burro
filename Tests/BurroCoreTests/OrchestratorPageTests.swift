// Check how the Orchestrator page groups a conversation into turns, and the reply Markdown blocks.
import XCTest
@testable import Burro
@testable import BurroCore

final class OrchestratorPageTests: XCTestCase {
    private func message(_ id: Int, _ kind: ChatMessage.Kind, _ text: String, tool: String? = nil, output: String? = nil) -> ChatMessage {
        ChatMessage(id: id, kind: kind, text: text, tool: tool, output: output)
    }

    func testTurnsKeepTheLastReplyAsTheAnswerAndEarlierNotesAsSteps() {
        let turns = ConversationTurn.turns([
            message(0, .user, "What needs me?"),
            message(1, .tool, "", tool: "overview", output: "ok"),
            message(2, .assistant, "Reading the ready chat."),
            message(3, .tool, "claude:x", tool: "read_chat", output: "ok"),
            message(4, .assistant, "Nothing needs you."),
            message(5, .user, "Start the fix"),
            message(6, .tool, "Fix it", tool: "start_chat"),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].question?.text, "What needs me?")
        XCTAssertEqual(turns[0].steps.map(\.id), [1, 2, 3])
        XCTAssertEqual(turns[0].answer?.text, "Nothing needs you.")
        XCTAssertEqual(turns[1].steps.map(\.id), [6])
        XCTAssertNil(turns[1].answer, "A turn still running has no answer yet")
    }

    func testTurnsTolerateHistoryThatStartsMidConversation() {
        let turns = ConversationTurn.turns([message(0, .assistant, "Earlier reply"), message(1, .user, "Next")])
        XCTAssertEqual(turns.count, 2)
        XCTAssertNil(turns[0].question)
        XCTAssertEqual(turns[0].answer?.text, "Earlier reply")
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.blocks("""
        **Lead** line
        continues

        ### Worth your eyes
        - first
          - nested
        1. step one
        2) step two
        ```swift
        let x = 1
        ```
        after
        """)
        XCTAssertEqual(blocks, [
            .paragraph("**Lead** line\ncontinues"),
            .heading("Worth your eyes", 3),
            .item("•", "first", 0),
            .item("•", "nested", 1),
            .item("1.", "step one", 0),
            .item("2.", "step two", 0),
            .code("let x = 1"),
            .paragraph("after"),
        ])
    }
}
