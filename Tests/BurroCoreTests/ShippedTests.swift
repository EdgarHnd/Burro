import XCTest
@testable import BurroCore

final class ShippedTests: XCTestCase {
    // A day in UTC so the fixtures' timestamps read plainly.
    private let start = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z")!
    private var end: Date { start.addingTimeInterval(86_400) }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func pull(_ number: Int, _ title: String, author: String, base: String = "staging", head: String,
                      merged: String? = "2026-11-09T10:00:00Z", state: String = "MERGED", commit: String? = nil,
                      bot: Bool = false, name: String? = nil) -> String {
        """
        {"number": \(number), "title": "\(title)", "url": "https://github.com/acme/app/pull/\(number)", "state": "\(state)",
         "mergedAt": \(merged.map { "\"\($0)\"" } ?? "null"), "baseRefName": "\(base)", "headRefName": "\(head)",
         "additions": 10, "deletions": 2, "mergeCommit": \(commit.map { "{\"oid\": \"\($0)\"}" } ?? "null"),
         "author": {"__typename": "\(bot ? "Bot" : "User")", "login": "\(author)", "avatarUrl": "https://avatars.example.com/\(author)"\(name.map { ", \"name\": \"\($0)\"" } ?? "")}}
        """
    }

    private func activity(_ type: String, _ login: String, _ ref: String, _ at: String, after: String = "1111111", bot: Bool = false) -> String {
        """
        {"activity_type": "\(type)", "actor": {"login": "\(login)", "type": "\(bot ? "Bot" : "User")", "avatar_url": "https://avatars.example.com/\(login)"},
         "ref": "refs/heads/\(ref)", "before": "0000000", "after": "\(after)", "timestamp": "\(at)"}
        """
    }

    private func fixture() throws -> ShippedDay {
        let (graph, deployments, items, runs) = try parts()
        return ShippedDay.build(day: start, end: end, repository: "acme/app", graph: [graph], deployments: deployments,
                                activity: items, runs: runs, partial: false, now: end)
    }

    private func parts() throws -> (ShippedGraph, ShippedGraph, [ShippedActivity], ShippedRuns) {
        let merged = [
            pull(11, "Store: fitted previews bar", author: "dante", head: "claude/store-bar", name: "Dante Kim"),
            pull(12, "fix(insights): pie charts drew as a dot", author: "dante", head: "claude/pie", merged: "2026-11-09T12:00:00Z", name: "Dante Kim"),
            pull(13, "My Home: the postcard fits again", author: "edgar", head: "codex/postcard", merged: "2026-11-09T14:00:00Z"),
            pull(14, "Promote staging to main: web sign-up fixes", author: "edgar", base: "main", head: "staging",
                 merged: "2026-11-09T15:00:00Z", commit: "abc123456789"),
            pull(15, "Merged yesterday by mistake of the search", author: "edgar", head: "codex/old", merged: "2026-11-08T23:00:00Z"),
            pull(16, "Bump dependencies", author: "dependabot", head: "deps/bump", merged: "2026-11-09T09:00:00Z", bot: true),
        ].joined(separator: ",")
        let touched = [
            pull(20, "Vendor the Godot bridge", author: "edgar", head: "codex/bridge", merged: nil, state: "OPEN"),
            pull(5, "An old pull request on a reused branch", author: "dante", head: "claude/reused", merged: "2026-10-01T00:00:00Z"),
            pull(6, "Closed and abandoned", author: "dante", head: "claude/closed", merged: nil, state: "CLOSED"),
        ].joined(separator: ",")
        let graph = try decode(ShippedGraph.self, """
        {"data": {"viewer": {"login": "edgar"},
          "repository": {"defaultBranchRef": {"name": "staging"}, "environments": {"nodes": [{"name": "Preview"}, {"name": "Production"}]}},
          "merged": {"issueCount": 6, "pageInfo": {"hasNextPage": false}, "nodes": [\(merged), {}]},
          "touched": {"nodes": [\(touched)]}}}
        """)
        let deployments = try decode(ShippedGraph.self, """
        {"data": {"repository": {"deployments": {"nodes": [
          {"createdAt": "2026-11-09T15:01:00Z", "commitOid": "abc123456789", "environment": "Production", "state": "ACTIVE",
           "latestStatus": {"state": "SUCCESS", "environmentUrl": "https://app.example.com"}},
          {"createdAt": "2026-11-09T16:00:00Z", "commitOid": "def987654321", "environment": "Production", "state": "FAILURE",
           "latestStatus": {"state": "FAILURE"}},
          {"createdAt": "2026-11-07T16:00:00Z", "commitOid": "0ld000000000", "environment": "Production", "state": "INACTIVE"}
        ]}}}}
        """)
        let items = try decode([ShippedActivity].self, "[" + [
            activity("branch_creation", "edgar", "codex/bridge", "2026-11-09T08:00:00Z"),
            activity("push", "edgar", "codex/bridge", "2026-11-09T09:00:00Z"),
            activity("force_push", "edgar", "codex/bridge", "2026-11-09T09:30:00Z"),
            activity("push", "edgar", "codex/postcard", "2026-11-09T13:00:00Z"),
            activity("push", "dante", "staging", "2026-11-09T11:00:00Z"),
            activity("push", "dante", "claude/reused", "2026-11-09T11:30:00Z"),
            activity("push", "dante", "claude/closed", "2026-11-09T11:40:00Z"),
            activity("push", "edgar", "main", "2026-11-09T18:00:00Z", after: "fed000000000"),
            activity("pr_merge", "edgar", "staging", "2026-11-09T14:00:00Z"),
            activity("branch_deletion", "edgar", "codex/postcard", "2026-11-09T14:00:01Z"),
            activity("push", "github-actions[bot]", "ota/cut", "2026-11-09T10:00:00Z", bot: true),
            activity("push", "edgar", "codex/bridge", "2026-11-08T23:59:59Z"),
            activity("push", "edgar", "codex/bridge", "2026-11-10T00:00:00Z"),
        ].joined(separator: ",") + "]")
        let runs = try decode(ShippedRuns.self, """
        {"workflow_runs": [
          {"id": 1, "name": "Production OTA", "display_title": "Production OTA", "html_url": "https://github.com/acme/app/actions/runs/1",
           "status": "waiting", "conclusion": null, "created_at": "2026-11-09T17:00:00Z", "actor": {"login": "edgar"}, "triggering_actor": {"login": "edgar"}},
          {"id": 2, "name": "Insights export", "display_title": "Insights export", "status": "completed", "conclusion": "success",
           "created_at": "2026-11-09T17:00:00Z", "actor": {"login": "edgar"}},
          {"id": 3, "name": "Production Firebase deploy", "display_title": "Firebase: rules", "status": "completed", "conclusion": "failure",
           "created_at": "2026-11-09T19:00:00Z", "actor": {"login": "dante"}}
        ]}
        """)
        return (graph, deployments, items, runs)
    }

    func testMergedPullRequestsStayInTheDayAndSkipPromotions() throws {
        let day = try fixture()
        XCTAssertEqual(day.defaultBranch, "staging")
        XCTAssertEqual(day.you, "edgar")
        XCTAssertEqual(day.merged.map(\.number), [13, 12, 11, 16], "newest first, yesterday's and the promotion left out")
        XCTAssertEqual(day.merged(by: "dante").map(\.number), [12, 11])
        XCTAssertEqual(day.person("dante").displayName, "Dante")
        XCTAssertEqual(day.person("edgar").displayName, "You")
        XCTAssertEqual(day.person("dependabot").isBot, true)
    }

    func testProductionHoldsPromotionsDirectPushesRunsAndOtherDeployments() throws {
        let day = try fixture()
        let byID = Dictionary(uniqueKeysWithValues: day.production.map { ($0.id, $0) })
        XCTAssertEqual(day.production.map(\.id), ["run-3", "push-fed000000000", "run-1", "deploy-def987654321-Production", "pr-14"])
        XCTAssertEqual(byID["pr-14"]?.kind, .promotion)
        XCTAssertEqual(byID["pr-14"]?.status, .live, "its merge commit's Production deployment succeeded")
        XCTAssertEqual(byID["pr-14"]?.target, "Production\nhttps://app.example.com")
        XCTAssertEqual(byID["push-fed000000000"]?.title, "Pushed straight to main")
        XCTAssertNil(byID["push-fed000000000"]?.status)
        XCTAssertEqual(byID["run-1"]?.status, .waiting)
        XCTAssertEqual(byID["run-1"]?.title, "Production OTA")
        XCTAssertEqual(byID["run-3"]?.title, "Firebase: rules")
        XCTAssertEqual(byID["run-3"]?.detail, "Production Firebase deploy")
        XCTAssertEqual(byID["run-3"]?.status, .failed)
        XCTAssertEqual(byID["deploy-def987654321-Production"]?.status, .failed)
        XCTAssertNil(byID["run-2"], "only production workflows count")
    }

    func testPushesGroupByPersonAndBranchAndNameTheirPullRequest() throws {
        let day = try fixture()
        let bridge = try XCTUnwrap(day.branches.first { $0.name == "codex/bridge" })
        XCTAssertEqual(bridge.pushes, 3, "creation, push and force push, inside the day only")
        XCTAssertEqual(bridge.forced, 1)
        XCTAssertTrue(bridge.created)
        XCTAssertEqual(bridge.pullRequest?.number, 20)
        XCTAssertEqual(bridge.pullRequest?.state, "OPEN")
        XCTAssertEqual(day.branches.first { $0.name == "codex/postcard" }?.pullRequest?.number, 13, "merged after its pushes")
        XCTAssertNil(day.branches.first { $0.name == "claude/reused" }?.pullRequest, "an old merge on a reused branch name")
        XCTAssertNil(day.branches.first { $0.name == "claude/closed" }?.pullRequest)
        XCTAssertNil(day.branches.first { $0.name.hasPrefix("ota/") }, "bots' pushes are left out")
        XCTAssertNil(day.branches.first { $0.name == "main" }, "production pushes are releases")
        XCTAssertEqual(day.branches(by: "dante").first?.name, "staging", "straight pushes to staging come first")
        XCTAssertEqual(day.pushCount, 7)
    }

    func testContributorsPutYouFirstAndLeaveOutBotsWithoutPullRequests() throws {
        let day = try fixture()
        XCTAssertEqual(day.contributors.map(\.login), ["edgar", "dante", "dependabot"])
    }

    func testHeadlineSaysWhoMergedWhatAndWhatReachedProduction() throws {
        let day = try fixture()
        XCTAssertEqual(day.headline, "You merged 1 pull request into staging, Dante 2 and dependabot 1. Shipped to production 3 times. 2 production runs failed.")
        var quiet = day
        quiet.production = []; quiet.merged = []
        XCTAssertEqual(quiet.headline, "No pull requests merged into staging. Nothing went to production.")
        var two = day
        two.merged.removeAll { $0.author == "dependabot" }
        two.production = Array(day.production.filter { $0.id == "pr-14" })
        XCTAssertEqual(two.headline, "You merged 1 pull request into staging and Dante merged 2. Shipped to production once.")
        two.production += day.production.filter { $0.id == "run-1" }
        XCTAssertTrue(two.headline.hasSuffix("Shipped to production twice."))
    }

    func testAreasComeFromTitlePrefixes() {
        XCTAssertEqual(ShippedDay.area(of: "Store: fitted previews bar").area, "Store")
        XCTAssertEqual(ShippedDay.area(of: "My Home: the postcard fits").text, "The postcard fits")
        XCTAssertEqual(ShippedDay.area(of: "fix(insights): pie charts").area, "Insights")
        XCTAssertEqual(ShippedDay.area(of: "fix(insights): pie charts").text, "Pie charts")
        XCTAssertEqual(ShippedDay.area(of: "docs(ops): cost register").area, "Docs")
        XCTAssertEqual(ShippedDay.area(of: "ci: faster checks").area, "CI")
        XCTAssertNil(ShippedDay.area(of: "feat: something").area)
        XCTAssertEqual(ShippedDay.area(of: "feat: something").text, "Something")
        XCTAssertNil(ShippedDay.area(of: "Promote staging to main: web fixes").area, "four words isn't an area")
        XCTAssertNil(ShippedDay.area(of: "Tap outside a modal dismisses it").area)
    }

    func testPromotionTitlesLoseTheirLead() {
        let promotion = ShippedDay.promotion("Promote staging to main: web sign-up + paywall fixes (#1160)")
        XCTAssertEqual(promotion?.text, "Web sign-up + paywall fixes (#1160)")
        XCTAssertEqual(promotion?.from, "staging")
        XCTAssertEqual(promotion?.to, "main")
        XCTAssertNil(ShippedDay.promotion("Store: fitted previews"))
    }

    func testRepositoryComesFromGitHubRemotesOnly() {
        XCTAssertEqual(ShippedReader.repository(fromRemote: "https://github.com/appwesh/focustown-rn-godot.git\n"), "appwesh/focustown-rn-godot")
        XCTAssertEqual(ShippedReader.repository(fromRemote: "git@github.com:EdgarHnd/Burro.git"), "EdgarHnd/Burro")
        XCTAssertEqual(ShippedReader.repository(fromRemote: "ssh://git@github.com/acme/app"), "acme/app")
        XCTAssertEqual(ShippedReader.repository(fromRemote: "https://user@github.com/acme/app/"), "acme/app")
        XCTAssertNil(ShippedReader.repository(fromRemote: "https://gitlab.com/acme/app.git"))
        XCTAssertNil(ShippedReader.repository(fromRemote: "https://github.com/acme"))
        XCTAssertNil(ShippedReader.repository(fromRemote: "https://github.com/acme/../app"))
    }

    func testPagingReadsTheNextLinkAndSplitsHeaders() {
        let output = "HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nLink: <https://api.github.com/repositories/1/activity?per_page=100&after=abc>; rel=\"next\"\r\n\r\n[]"
        let split = ShippedReader.split(output)
        XCTAssertEqual(split?.body, "[]")
        XCTAssertEqual(split.flatMap { ShippedReader.nextLink($0.headers) }, "repositories/1/activity?per_page=100&after=abc")
        XCTAssertNil(ShippedReader.nextLink("Link: <https://evil.example.com/x>; rel=\"next\""))
        XCTAssertNil(ShippedReader.nextLink("Link: <https://api.github.com/x?page=1>; rel=\"prev\""))
    }

    func testStatusesMapGitHubStates() {
        XCTAssertEqual(ShippedDay.runStatus("completed", "success"), .succeeded)
        XCTAssertEqual(ShippedDay.runStatus("completed", "cancelled"), .cancelled)
        XCTAssertEqual(ShippedDay.runStatus("completed", "timed_out"), .failed)
        XCTAssertEqual(ShippedDay.runStatus("in_progress", nil), .running)
        XCTAssertEqual(ShippedDay.runStatus("waiting", nil), .waiting)
        XCTAssertNil(ShippedDay.runStatus("completed", "skipped"))
        XCTAssertTrue(ShippedDay.isProductionWorkflow("Production OTA rollout"))
        XCTAssertFalse(ShippedDay.isProductionWorkflow("Godot Web bundle"))
    }

    func testTextSummaryReadsPlainly() throws {
        let text = ShippedText.render(try fixture())
        XCTAssertTrue(text.contains("Merged into staging"))
        XCTAssertTrue(text.contains("Dante (2)"))
        XCTAssertTrue(text.contains("You: 4 pushes to 2 branches"))
        XCTAssertTrue(text.contains("- Vendor the Godot bridge (#20, open) · 3 pushes"))
        XCTAssertEqual(ShippedDay.count(1, "branch"), "1 branch")
        XCTAssertEqual(ShippedDay.count(2, "push"), "2 pushes")
    }

    // MARK: Written summary

    func testSummaryInputHasTitlesPeopleAndProductionButNoPushCounts() throws {
        let day = try fixture()
        let input = try XCTUnwrap(ShippedSummary.input(day, calendar: utc))
        XCTAssertTrue(input.hasPrefix("Day: Monday 2026-11-09\nRepository: acme/app (pull requests merge into staging"))
        XCTAssertTrue(input.contains("People, in this order: You, Dante, dependabot"))
        XCTAssertTrue(input.contains("- Web sign-up fixes · promoted staging to main · by You · live"))
        XCTAssertTrue(input.contains("- Firebase: rules · production workflow · by Dante · failed"))
        XCTAssertTrue(input.contains("Dante:\n- [Store] Fitted previews bar · +10 −2 lines\n- [Insights] Pie charts drew as a dot · +10 −2 lines"),
                      "areas split off, oldest pull request first")
        XCTAssertTrue(input.contains("- Pushed straight to main · by You · status unknown"))
        XCTAssertFalse(input.contains(" push") || input.contains("pushes"), "no push counts: \(input)")
        XCTAssertFalse(input.contains("Still in progress"), "everyone here merged something")
        XCTAssertFalse(input.contains("#1"), "no pull request numbers")
    }

    func testSummaryInputListsWorkInProgressOnlyForPeopleWhoMergedNothing() throws {
        var day = try fixture()
        day.merged.removeAll { $0.author == "dante" }
        let input = try XCTUnwrap(ShippedSummary.input(day, calendar: utc))
        XCTAssertTrue(input.contains("Still in progress (pushed today, nothing merged yet):\nDante:\n- pushed commits straight to staging\n- branch claude/closed (no pull request yet)\n- branch claude/reused (no pull request yet)"))
        XCTAssertFalse(input.contains("Vendor the Godot bridge"), "you merged, so your open branches aren't listed")

        var quiet = day
        quiet.merged = []; quiet.production = []; quiet.branches = []
        XCTAssertNil(ShippedSummary.input(quiet, calendar: utc), "an empty day needs no summary and no call")
        quiet.production = day.production
        XCTAssertTrue(ShippedSummary.input(quiet, calendar: utc)?.contains("Merged into staging:\n- nothing merged") == true)
    }

    func testSummaryKeyChangesWithTheItemsNotWithRefreshes() throws {
        let day = try fixture()
        let key = ShippedSummary.key(input: try XCTUnwrap(ShippedSummary.input(day, calendar: utc)))
        func keyOf(_ change: (inout ShippedDay) -> Void) -> String {
            var copy = day
            change(&copy)
            return ShippedSummary.key(input: ShippedSummary.input(copy, calendar: utc) ?? "")
        }
        XCTAssertEqual(keyOf { $0.fetchedAt = $0.fetchedAt.addingTimeInterval(300) }, key, "a refresh that finds the same items")
        XCTAssertEqual(keyOf { $0.branches[0].pushes += 3; $0.branches[0].lastAt = $0.branches[0].lastAt.addingTimeInterval(60) }, key,
                       "more pushes to a known branch")
        XCTAssertEqual(keyOf { $0.merged.reverse(); $0.production.reverse() }, key, "order doesn't matter")
        XCTAssertEqual(keyOf {
            $0.branches.append(ShippedDay.Branch(actor: "edgar", name: "codex/new", pushes: 1, forced: 0, created: true, lastAt: $0.day, pullRequest: nil))
        }, key, "a new branch from someone who already merged")
        XCTAssertNotEqual(keyOf {
            var pull = $0.merged[0]; pull.number = 99; pull.title = "Store: a new thing"; $0.merged.append(pull)
        }, key, "a new merge")
        XCTAssertNotEqual(keyOf { $0.production[0].status = .succeeded }, key, "a production run finished")
        XCTAssertNotEqual(keyOf { $0.production = [] }, key)
        XCTAssertEqual(key.count, 32)
    }

    func testSummaryCacheIsPerRepositoryAndDayAndOnlyFreshForTheSameKey() throws {
        let day = try fixture()
        let id = ShippedSummary.cacheID(repository: "acme/app", day: day.day.addingTimeInterval(3600 * 20), calendar: utc)
        XCTAssertEqual(id, "acme/app 2026-11-09")
        XCTAssertNotEqual(ShippedSummary.cacheID(repository: "acme/web", day: day.day, calendar: utc), id)
        XCTAssertNotEqual(ShippedSummary.cacheID(repository: "acme/app", day: end, calendar: utc), id)

        var cache = ShippedSummaryCache()
        let now = end
        cache.store(ShippedSummary.Entry(key: "aaa", text: "You: old.", model: ShippedSummary.model, createdAt: now), for: id)
        XCTAssertEqual(cache.fresh(id, key: "aaa")?.text, "You: old.")
        XCTAssertNil(cache.fresh(id, key: "bbb"), "the day's items changed: write it again")
        cache.store(ShippedSummary.Entry(key: "bbb", text: "You: new.", model: ShippedSummary.model, createdAt: now), for: id)
        XCTAssertEqual(cache.entries.count, 1, "one entry per repository and day")
        XCTAssertFalse(cache.entries[id]!.isFinal)
        cache.store(ShippedSummary.Entry(key: "c", text: "You: ancient.", model: ShippedSummary.model, createdAt: now.addingTimeInterval(-300 * 86_400)),
                    for: "acme/app 2026-01-01")
        XCTAssertEqual(cache.entries["acme/app 2026-01-01"]?.text, "You: ancient.", "backfilled days are kept for good")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-summary-\(UUID().uuidString)/summaries.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try cache.write(to: url)
        XCTAssertEqual(ShippedSummaryCache.read(from: url), cache, "survives a relaunch")
        XCTAssertEqual(ShippedSummaryCache.read(from: url.appendingPathExtension("missing")), ShippedSummaryCache())
    }

    func testSummaryCleaningKeepsOnlyPeopleFromTheDayAndRealProduction() throws {
        let day = try fixture()
        let messy = """
        Here's the summary:
        - **You:** got the postcard fitting again
          and fixed a thing.
        * Dante: store previews and Insights pie charts.
        Carol: invented work.
        Production: web sign-up fixes went live.
        """
        XCTAssertEqual(ShippedSummary.clean(messy, day: day),
                       "You: got the postcard fitting again and fixed a thing.\nDante: store previews and Insights pie charts.\nProduction: web sign-up fixes went live.")
        var quiet = day
        quiet.production = []
        XCTAssertEqual(ShippedSummary.clean("You: postcard.\nProduction: nothing went out.", day: quiet), "You: postcard.",
                       "production only when it happened")
        XCTAssertNil(ShippedSummary.clean("I can't help with that.", day: day))
        let lines = ShippedSummary.lines("You: postcard fixes.\nDante: store previews.")
        XCTAssertEqual(lines.map(\.label), ["You", "Dante"])
        XCTAssertEqual(lines.map(\.text), ["postcard fixes.", "store previews."])
    }

    func testSummaryReadsClaudesAnswerAndItsFailures() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"You: postcard fixes."}"#
        XCTAssertEqual(try? ShippedSummary.parse("Warning: something on stderr\n" + ok, code: 0).get(), "You: postcard fixes.")
        let signedOut = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertEqual(ShippedSummary.parse(signedOut, code: 1), .failure(.signedOut))
        XCTAssertEqual(ShippedSummary.parse("Invalid API key · Fix external API key", code: 1), .failure(.signedOut))
        XCTAssertEqual(ShippedSummary.parse("error: unknown option '--effort'\n", code: 1), .failure(.failed("Claude: error: unknown option '--effort'")))
        XCTAssertEqual(ShippedSummary.parse("", code: 3), .failure(.failed("Claude exited with 3.")))
        let args = ShippedSummary.arguments(input: "--model opus")
        XCTAssertEqual(Array(args.suffix(2)), ["--", "--model opus"], "the input can never be read as a flag")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "", "no tools")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "claude-haiku-5-5")
    }

    func testSummaryFallsBackWithoutClaudeAndRunsAFakeOne() throws {
        let day = try fixture()
        let input = try XCTUnwrap(ShippedSummary.input(day, calendar: utc))
        XCTAssertEqual(ShippedSummary.generate(for: day, input: input, executable: nil), .failure(.noClaude))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fake(_ name: String, _ body: String) throws -> String {
            let url = folder.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        }
        // Claude's JSON line, with the brief as its result (in a code fence, as models sometimes do).
        let answer = "```json\n{\"headline\": \"Postcard and store polish.\", \"people\": [{\"name\": \"You\", \"themes\": [{\"area\": \"My Home\", \"text\": \"Postcard fits again\"}]}, {\"name\": \"Mallory\", \"themes\": [{\"area\": \"X\", \"text\": \"Nothing real\"}]}], \"production\": \"Web sign-up fixes went live\"}\n```"
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false, "result": answer]), as: UTF8.self)
        try line.write(to: folder.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
        let good = try fake("good", "cat '\(folder.appendingPathComponent("answer.json").path)'")
        let brief = try XCTUnwrap(ShippedBrief(json: try ShippedSummary.generate(for: day, input: input, executable: good, folder: folder).get()))
        XCTAssertEqual(brief.headline, "Postcard and store polish")
        XCTAssertEqual(brief.people.map(\.name), ["You"], "people not in the day are dropped")
        XCTAssertEqual(brief.production, "Web sign-up fixes went live", "the fixture day did ship")
        let out = try fake("out", #"echo '{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}'; exit 1"#)
        XCTAssertEqual(ShippedSummary.generate(for: day, input: input, executable: out, folder: folder), .failure(.signedOut))
        let odd = try fake("odd", #"echo '{"type":"result","is_error":false,"result":"Sure! Here is a summary."}'"#)
        if case .failure(.failed) = ShippedSummary.generate(for: day, input: input, executable: odd, folder: folder) {} else {
            XCTFail("an answer that isn't a brief is a failure, not a summary")
        }
    }

    func testCopiedTextCarriesTheSummaryAfterTheHeadline() throws {
        let day = try fixture()
        let text = ShippedText.render(day, summary: "You: postcard fixes.\nDante: store previews.")
        XCTAssertTrue(text.contains(day.headline + "\n\nYou: postcard fixes.\nDante: store previews.\n\nProduction"))
        XCTAssertFalse(ShippedText.render(day).contains("postcard fixes"))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Backfill and periods

    func testARangeBuildsTheSameDayAsTheTodayPage() throws {
        let (graph, deployments, items, runs) = try parts()
        let range = ShippedHistory.Range(head: graph, merged: graph.data?.merged?.nodes ?? [], touched: graph.data?.touched?.nodes ?? [],
                                         deployments: deployments.data?.repository?.deployments?.nodes ?? [], activity: items,
                                         runs: runs.workflow_runs ?? [], activityComplete: true, start: start, end: end.addingTimeInterval(86_400),
                                         repository: "acme/app", requests: 0)
        let days = ShippedHistory.days(range, calendar: utc, now: end)
        XCTAssertEqual(days.map(\.day), [start, end])
        XCTAssertEqual(ShippedDigest(days[0], calendar: utc), ShippedDigest(try fixture(), calendar: utc),
                       "same people, merges, production and branches: the app won't rewrite a backfilled day")
        XCTAssertEqual(ShippedSummary.input(days[0], calendar: utc), ShippedSummary.input(try fixture(), calendar: utc))
        XCTAssertEqual(days[1].branches.map(\.name), ["codex/bridge"], "the next day keeps only its own pushes")
        XCTAssertTrue(days[1].merged.isEmpty)
    }

    func testDigestsRoundTripAndCountPushes() throws {
        let digest = ShippedDigest(try fixture(), calendar: utc)
        XCTAssertEqual(digest.date, "2026-11-09")
        XCTAssertEqual(digest.people.map(\.name), ["You", "Dante", "dependabot"])
        XCTAssertEqual(digest.people.first?.pushes, 4)
        XCTAssertEqual(digest.shippedCount, 3)
        XCTAssertEqual(digest.failedCount, 2)
        let data = try JSONEncoder().encode(ShippedSummary.Entry(key: "k", text: "You: x.", model: "m", createdAt: end, digest: digest, final: true))
        let back = try JSONDecoder().decode(ShippedSummary.Entry.self, from: data)
        XCTAssertEqual(back.digest, digest)
        XCTAssertTrue(back.isFinal)
        let old = try JSONDecoder().decode(ShippedSummary.Entry.self, from: Data(#"{"key":"k","text":"t","model":"m","createdAt":0}"#.utf8))
        XCTAssertNil(old.digest, "entries written before digests still read")
        XCTAssertFalse(old.isFinal)
    }

    func testADayIsClosedHalfAnHourAfterMidnight() {
        XCTAssertFalse(ShippedSummary.isClosed(start, now: end.addingTimeInterval(1799), calendar: utc))
        XCTAssertTrue(ShippedSummary.isClosed(start, now: end.addingTimeInterval(1800), calendar: utc))
        XCTAssertFalse(ShippedSummary.isClosed(end, now: end.addingTimeInterval(1800), calendar: utc))
    }

    func testWeeksAndMonthsHaveStableBoundsAndIDs() {
        var calendar = utc
        calendar.firstWeekday = 2
        let week = ShippedPeriod.containing(start.addingTimeInterval(3600 * 30), .week, calendar: calendar)
        XCTAssertEqual(week.cacheID(repository: "acme/app", calendar: calendar), "acme/app week 2026-11-09", "Monday-first weeks")
        XCTAssertEqual(week.days(calendar: calendar).count, 7)
        XCTAssertEqual(week.previous(calendar: calendar).cacheID(repository: "acme/app", calendar: calendar), "acme/app week 2026-11-02")
        let month = ShippedPeriod.containing(start, .month, calendar: calendar)
        XCTAssertEqual(month.cacheID(repository: "acme/app", calendar: calendar), "acme/app month 2026-11")
        XCTAssertEqual(month.days(calendar: calendar).count, 30)
        XCTAssertEqual(month.weeks(calendar: calendar).first?.cacheID(repository: "acme/app", calendar: calendar), "acme/app week 2026-10-26",
                       "a month's first week can start in the month before")
        XCTAssertEqual(month.weeks(calendar: calendar).count, 6)
        XCTAssertFalse(week.isClosed(now: week.end, calendar: calendar))
        XCTAssertTrue(week.isClosed(now: week.end.addingTimeInterval(1800), calendar: calendar))
    }

    func testAWeekReportPutsItsDaysTogether() throws {
        var calendar = utc
        calendar.firstWeekday = 2
        let monday = ShippedDigest(try fixture(), calendar: utc)
        var tuesdayDay = try fixture()
        tuesdayDay.day = end
        tuesdayDay.production = []
        tuesdayDay.merged = tuesdayDay.merged.filter { $0.author == "dante" }.map { pull in
            var pull = pull; pull.number += 100; pull.title = "Insights: board legends"; return pull
        }
        let tuesday = ShippedDigest(tuesdayDay, calendar: utc)
        let week = ShippedPeriod.containing(start, .week, calendar: calendar)
        let entries: [String: ShippedSummary.Entry] = [
            "acme/app 2026-11-09": .init(key: "a", text: "You: postcard.", model: "m", createdAt: end, digest: monday, final: true),
            "acme/app 2026-11-10": .init(key: "b", text: "Dante: legends.", model: "m", createdAt: end, digest: tuesday, final: true),
        ]
        let report = ShippedPeriodReport(period: week, repository: "acme/app", entries: entries, through: end.addingTimeInterval(3600 * 30), calendar: calendar)
        XCTAssertEqual(report.days.count, 3, "through Wednesday")
        XCTAssertEqual(report.missing, 1, "Wednesday was never read")
        XCTAssertEqual(report.tallies.map(\.person.name), ["You", "Dante", "dependabot"])
        XCTAssertEqual(report.tallies.map(\.merged), [1, 4, 1])
        XCTAssertEqual(report.headline, "You merged 1 pull request into staging, Dante 4 and dependabot 1. Shipped to production 3 times. 2 production runs failed.")
        let input = try XCTUnwrap(report.input)
        XCTAssertTrue(input.hasPrefix("Period: one week, Monday 2026-11-09 to Wednesday 2026-11-11 (1 day not read)"))
        XCTAssertTrue(input.contains("Dante (4):\n- [Insights] Pie charts drew as a dot · +10 −2 lines\n- [Insights] Board legends · +10 −2 lines\n- [Insights] Board legends · +10 −2 lines\n- [Store] Fitted previews bar"),
                      "grouped by area, biggest area first: \(input)")
        XCTAssertTrue(input.contains("- 2026-11-09: Web sign-up fixes · promoted staging to main · by You · live"))
        XCTAssertFalse(report.isFinal(now: week.end.addingTimeInterval(7200), calendar: calendar), "a day is missing")
        XCTAssertNil(report.summary)

        let key = try XCTUnwrap(report.key)
        var cached = entries
        cached[week.cacheID(repository: "acme/app", calendar: calendar)] = .init(key: key, text: "You: the week.", model: "m", createdAt: end)
        XCTAssertEqual(ShippedPeriodReport(period: week, repository: "acme/app", entries: cached, through: end.addingTimeInterval(3600 * 30), calendar: calendar).summary,
                       "You: the week.", "written from these exact days")
        cached["acme/app 2026-11-11"] = .init(key: "", text: "", model: "m", createdAt: end, digest: tuesday, final: true)
        XCTAssertNil(ShippedPeriodReport(period: week, repository: "acme/app", entries: cached, through: end.addingTimeInterval(3600 * 30), calendar: calendar).summary,
                     "a new day changes the week: write it again")

        let text = report.render(summary: "You: the week.")
        // The day's label follows the reader's region ("Mon 9 Nov" or "Mon, Nov 9"), so check around it.
        XCTAssertTrue(text.contains("You: the week.\n\nDays\nMon"), text)
        XCTAssertTrue(text.contains(": You 1 · Dante 2 · dependabot 1 merged · shipped to production\n  You: postcard."), text)
        XCTAssertTrue(text.hasSuffix("1 day not read yet."))
        XCTAssertTrue(ShippedPeriodReport.instructions(.month).contains("never a day-by-day list"))
    }

    func testDaysBeforeTheRepositoryStartedDontCountAsMissing() throws {
        var calendar = utc
        calendar.firstWeekday = 2
        let digest = ShippedDigest(try fixture(), calendar: utc)
        let month = ShippedPeriod.containing(start, .month, calendar: calendar)
        let report = ShippedPeriodReport(period: month, repository: "acme/app",
                                         entries: ["acme/app 2026-11-09": .init(key: "", text: "", model: "m", createdAt: end, digest: digest, final: true)],
                                         through: month.end.addingTimeInterval(-3600), calendar: calendar)
        XCTAssertEqual(report.missing, 21, "1–8 November come before the first recorded day; 10–30 are missing")
    }

    func testClaudesCostIsRead() {
        XCTAssertEqual(ShippedSummary.cost(#"{"type":"result","total_cost_usd":0.0005674,"result":"You: x."}"#), 0.0005674)
        XCTAssertNil(ShippedSummary.cost("not json"))
    }

    func testRepeatedProductionPushesReadOnceWithACount() {
        XCTAssertEqual(ShippedDigest.counted(["Pushed straight to main · by You · live", "Hotfix · by You · live", "Pushed straight to main · by You · live"]),
                       ["Pushed straight to main · by You · live (×2)", "Hotfix · by You · live"])
    }

    func testAPeriodCallsEachPersonByOneName() throws {
        var calendar = utc
        calendar.firstWeekday = 2
        var pushOnly = try fixture()
        pushOnly.day = end
        pushOnly.merged = []; pushOnly.production = []
        pushOnly.people["dante"]?.name = nil
        let tuesday = ShippedDigest(pushOnly, calendar: utc)
        XCTAssertTrue(tuesday.people.contains { $0.name == "dante" }, "a push-only day knows only the login")
        XCTAssertTrue(tuesday.input?.contains("- branch claude/reused (no pull request yet)") == true)
        let week = ShippedPeriod.containing(start, .week, calendar: calendar)
        let report = ShippedPeriodReport(period: week, repository: "acme/app", entries: [
            "acme/app 2026-11-09": .init(key: "", text: "", model: "m", createdAt: end, digest: ShippedDigest(try fixture(), calendar: utc), final: true),
            "acme/app 2026-11-10": .init(key: "", text: "", model: "m", createdAt: end, digest: tuesday, final: true),
        ], through: end, calendar: calendar)
        XCTAssertEqual(report.tallies.map(\.person.name), ["You", "Dante", "dependabot"], "one Dante, not Dante and dante")
        XCTAssertEqual(report.tallies.first { $0.person.name == "Dante" }?.pushes, 6)
    }

    func testAProductionLineRunOntoAPersonsLineGoesBackOnItsOwn() throws {
        let text = "You: web fixes and checkout. Production: two promotions went live.\nDante: Insights."
        XCTAssertEqual(ShippedSummary.normalized(text), "You: web fixes and checkout.\nProduction: two promotions went live.\nDante: Insights.")
        XCTAssertEqual(ShippedSummary.lines(text).map(\.label), ["You", "Production", "Dante"])
        XCTAssertEqual(ShippedSummary.clean(text, day: try fixture()), "You: web fixes and checkout.\nProduction: two promotions went live.\nDante: Insights.")
    }

    func testSavingMergesWithWhatAnotherWriterPutInTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burro-merge-\(UUID().uuidString)/summaries.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let digest = ShippedDigest(try fixture(), calendar: utc)
        // A backfill wrote a day; the app, which loaded the file before, then saves today.
        let stale = ShippedSummaryCache()
        try ShippedSummaryCache(entries: ["acme/app 2026-11-09": .init(key: "a", text: "You: old day.", model: "m", createdAt: end, digest: digest, final: true)]).write(to: url)
        try ShippedSummaryCache.save(["acme/app 2026-11-10": .init(key: "b", text: "You: today.", model: "m", createdAt: end)], known: stale, to: url)
        let merged = ShippedSummaryCache.read(from: url)
        XCTAssertEqual(merged.entries.count, 2, "the backfilled day survives the app's save")
        XCTAssertEqual(merged.entries["acme/app 2026-11-09"]?.digest, digest)
        XCTAssertTrue(merged.entries["acme/app 2026-11-09"]?.isFinal == true)
    }

    func testAWeekSoFarHasItsOwnCacheEntryUntilTheWeekIsWhole() {
        var calendar = utc
        calendar.firstWeekday = 2
        let week = ShippedPeriod.containing(start, .week, calendar: calendar)
        let later = week.end.addingTimeInterval(86_400 * 3)
        XCTAssertEqual(ShippedPeriodReport.cacheID(period: week, repository: "acme/app", through: end, now: later, calendar: calendar),
                       "acme/app week 2026-11-09 to 2026-11-10", "Monday and Tuesday of a past week")
        XCTAssertEqual(ShippedPeriodReport.cacheID(period: week, repository: "acme/app", through: week.end.addingTimeInterval(-3600), now: later, calendar: calendar),
                       "acme/app week 2026-11-09", "the whole week")
        XCTAssertEqual(ShippedPeriodReport.cacheID(period: week, repository: "acme/app", through: end, now: end.addingTimeInterval(3600), calendar: calendar),
                       "acme/app week 2026-11-09", "this week so far is the current week's own entry")
    }

    func testCopiedTextCarriesTheRecap() throws {
        let text = ShippedText.render(try fixture(), summary: "You: postcard.", recap: [("Yesterday", "You: store.\nDante: pies."), ("Last week", "")])
        XCTAssertTrue(text.contains("You: postcard.\n\nYesterday\n  You: store.\n  Dante: pies.\n\nProduction"), text)
        XCTAssertFalse(text.contains("Last week"), "rows without text are left out")
    }

    // MARK: Briefs

    func testABriefIsHeldToTheDaysPeopleAndShortLines() {
        let answer = """
        Here you go: {"headline": "A very long headline that just keeps on going well past what fits in one quick look at it.",
         "people": [{"name": "You", "themes": [{"area": "Checkout", "text": "New checkout flow behind a flag."}, {"area": "", "text": "  "},
                    {"area": "Support", "text": "a"}, {"area": "B", "text": "b"}, {"area": "C", "text": "c"}]},
                    {"name": "You", "themes": [{"text": "duplicate"}]}, {"name": "Eve", "themes": [{"text": "invented"}]}],
         "production": "Nothing went out"}
        """
        let brief = ShippedBrief.parse(answer, shape: .day, names: ["You", "Dante"], production: false)
        XCTAssertEqual(brief?.headline.hasSuffix("…"), true, "capped at 16 words")
        XCTAssertEqual(brief?.people.map(\.name), ["You"], "once each, and only people from the day")
        XCTAssertEqual(brief?.people.first?.themes.map(\.text), ["New checkout flow behind a flag", "a", "b"], "three at most, empty ones dropped")
        XCTAssertEqual(brief?.people.first?.themes.map(\.area), ["Checkout", "Support", "B"])
        XCTAssertNil(brief?.production, "no production line when nothing went to production")
        XCTAssertNil(ShippedBrief.parse("Sorry, I can't.", shape: .day, names: ["You"], production: false))
        XCTAssertNil(ShippedBrief(json: "You: an older plain summary."), "older entries aren't briefs")
    }

    func testAPeriodBriefKeepsItsThemesAndWhoWorkedOnThem() throws {
        let answer = #"{"headline": "Insights grew up", "themes": [{"area": "Insights", "text": "Dashboards and retention", "people": ["Dante", "Zed"]}, {"area": "Web", "text": "Sign-up fixed", "people": ["You"]}], "production": "Two promotions live"}"#
        let brief = try XCTUnwrap(ShippedBrief.parse(answer, shape: .period, names: ["You", "Dante"], production: true))
        XCTAssertEqual(brief.themes.first?.people, ["Dante"])
        XCTAssertTrue(brief.people.isEmpty)
        XCTAssertEqual(ShippedBrief(json: brief.json), brief, "round-trips through the cache")
        XCTAssertEqual(brief.plainText, "Insights grew up\n- [Insights] Dashboards and retention (Dante)\n- [Web] Sign-up fixed (You)\nProduction: Two promotions live")
        XCTAssertEqual(ShippedBrief.plain(brief.json), brief.plainText)
        XCTAssertEqual(ShippedBrief.plain("You: old.\nDante: lines."), "You: old.\nDante: lines.")
    }

    func testCompactColumnsTakeEachPersonsBiggestThemeFirst() {
        let brief = ShippedBrief(headline: "h", people: [
            .init(name: "You", themes: [.init(area: "A", text: "you 1"), .init(area: "B", text: "you 2")]),
            .init(name: "Dante", themes: [.init(area: "C", text: "dante 1"), .init(area: "D", text: "dante 2")]),
        ])
        XCTAssertEqual(brief.bullets(3).map(\.text), ["you 1", "dante 1", "you 2"])
    }

    func testAreasComeFromTheDataWithUntaggedWorkLast() throws {
        let digest = ShippedDigest(try fixture(), calendar: utc)
        XCTAssertEqual(digest.areas(for: "Dante").map(\.area), ["Insights", "Store"])
        XCTAssertEqual(digest.areas().last?.area, "Other", "dependabot's untagged bump")
        XCTAssertEqual(digest.areas().reduce(0) { $0 + $1.count }, digest.merged.count)
    }
}
