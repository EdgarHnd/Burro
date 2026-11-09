import XCTest
@testable import Burro
@testable import BurroCore

final class ChatTranscriptLayoutTests: XCTestCase {
    private func tool(_ id: Int, _ name: String, _ text: String, output: String? = "ok", note: String? = nil, plan: [ChatPlanItem]? = nil) -> ChatMessage {
        ChatMessage(id: id, kind: .tool, text: text, tool: name, output: output, note: note, plan: plan)
    }

    func testRunsFoldDelegatesStandAloneAndOnePlanCardShowsTheLatestState() {
        let first = [ChatPlanItem(text: "Read", status: .inProgress), ChatPlanItem(text: "Fix", status: .pending)]
        let later = [ChatPlanItem(text: "Read", status: .completed), ChatPlanItem(text: "Fix", status: .inProgress)]
        let steps = [
            tool(1, "update_plan", "update_plan", plan: first),
            tool(2, "Bash", "ls"), tool(3, "Bash", "cat a"), tool(4, "Read", "/x/a.swift"),
            ChatMessage(id: 5, kind: .assistant, text: "Reading the code."),
            tool(6, "Agent", "Find assets", output: nil, note: "Find street asset packs"),
            tool(7, "Bash", "swift build"),
            tool(8, "update_plan", "update_plan", plan: later),
            tool(9, "Grep", "foo"),
        ]
        let items = StepItem.items(steps)
        let shape = items.map { item -> String in
            switch item {
            case .plan(let m): "plan:\(m.plan?.map(\.status.rawValue).joined(separator: ",") ?? "")"
            case .run(let run): "run:\(run.map(\.id))"
            case .single(let m): "single:\(m.id)"
            case .note(let m): "note:\(m.id)"
            }
        }
        XCTAssertEqual(shape, ["plan:completed,in_progress", "run:[2, 3, 4]", "note:5", "single:6", "run:[7, 9]"])
        XCTAssertEqual(StepItem.summary([steps[1], steps[2], steps[3]]), "Ran 2 commands, read a file")
        XCTAssertEqual(StepItem.summary([steps[6], steps[8]]), "Ran a command, searched once")
    }

    func testLiveActivityPrefersTheCallsOwnDescription() {
        XCTAssertEqual(LiveActivity.describe(tool(1, "Bash", "rg runner", output: nil, note: "Locating the split config")), "Locating the split config")
        XCTAssertEqual(LiveActivity.describe(tool(2, "Bash", "swift test", output: nil)), "Running swift test")
        XCTAssertEqual(LiveActivity.describe(tool(3, "Read", "/a/b/View.swift", output: nil)), "Reading View.swift")
        XCTAssertEqual(LiveActivity.describe(tool(4, "Agent", "long prompt", output: nil)), "Waiting on a subagent")
        XCTAssertEqual(LiveActivity.describe(tool(5, "app_batch", "mcp__computer-use__app_batch", output: nil)), "Using app batch")
    }

    func testShortstatParsing() {
        XCTAssertEqual(ChatInspector.parseShortstat(" 12 files changed, 420 insertions(+), 33 deletions(-)\n"),
                       ChatInspector.DiffStat(files: 12, added: 420, removed: 33))
        XCTAssertEqual(ChatInspector.parseShortstat(" 1 file changed, 2 deletions(-)"), ChatInspector.DiffStat(files: 1, added: 0, removed: 2))
        XCTAssertEqual(ChatInspector.parseShortstat(""), ChatInspector.DiffStat())
    }

    func testTranscriptBatchCarriesNotesPlansAndContext() throws {
        let json = #"{"found":true,"messages":[{"kind":"tool","text":"swift test","tool":"Bash","note":"Run the tests","plan":[{"text":"Ship","status":"in_progress"}]}],"contextTokens":46000,"contextWindow":272000}"#
        let batch = try JSONDecoder().decode(TranscriptBatch.self, from: Data(json.utf8))
        XCTAssertTrue(batch.valid(for: 10))
        let transcript = try XCTUnwrap(batch.transcript)
        XCTAssertEqual(transcript.messages[0].note, "Run the tests")
        XCTAssertEqual(transcript.messages[0].plan, [ChatPlanItem(text: "Ship", status: .inProgress)])
        XCTAssertEqual(transcript.contextTokens, 46000)
        XCTAssertEqual(transcript.contextWindow, 272000)
    }
}
