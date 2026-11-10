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
        return ShippedDay.build(day: start, end: end, repository: "acme/app", graph: [graph], deployments: deployments,
                                activity: items, runs: runs, partial: false, now: end)
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
}
