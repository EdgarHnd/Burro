// Regression coverage for rotated Keychain grants without copied credentials or model calls.
import XCTest
@testable import BurroCore

final class ClaudeCLIUsageTests: XCTestCase {
    private func report(quota: [String: Any]? = nil, command: String = "usage", turns: Int = 0) throws -> Data {
        let limits = quota ?? ["limits": [
            ["kind": "session", "percent": 25, "resets_at": "2026-10-08T05:50:00Z"],
            ["kind": "weekly_all", "percent": 56, "resets_at": "2026-10-11T03:00:00Z"],
            ["kind": "weekly_scoped", "percent": 0, "scope": ["model": ["id": "fable", "display_name": "Fable"]]]
        ]]
        let events: [[String: Any]] = [
            ["type": "system", "subtype": "init"],
            ["type": "assistant", "usage_report": ["rate_limits": limits],
             "message": ["content": "Insights only: 99% of local tokens from PRIVATE TOOL"]],
            ["type": "result", "subtype": "success", "is_error": false, "local_command": command,
             "num_turns": turns, "total_cost_usd": 0, "duration_api_ms": 0]
        ]
        return try events.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
    }
    func testStructuredLiveQuotasIncludingModelLimitsAndResets() throws {
        let result = try ClaudeCLIUsageReader.decode(report())
        XCTAssertNil(result.issue); XCTAssertTrue(result.usesClaudeCLI)
        XCTAssertEqual(result.windows.map(\.title), ["Session", "Weekly", "Fable weekly"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [75, 44, 100])
        XCTAssertEqual(result.windows.first?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-08T05:50:00Z"))
        XCTAssertNil(result.identity); XCTAssertNil(UsageHistorySample(usage: result))
    }
    func testMissingQuotasNeverUsesInsightPercentages() throws {
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(report(quota: [:])))
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(report(quota: ["limits": [["kind": "session", "percent": NSNull()]]])))
    }
    func testRequiresSuccessfulZeroTurnLocalUsageCompletion() throws {
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(report(command: "status")))
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(report(turns: 1)))
        var lines = try report().split(separator: 10)
        lines.removeLast()
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(Data(lines.joined(separator: [10]))))
        XCTAssertThrowsError(try ClaudeCLIUsageReader.decode(Data(repeating: 32, count: UsageDecoding.maxBytes + 1)))
    }
    func testRecoveryForRevokedGrantOrExpiredCredential() async {
        let payload = try! report()
        for issue in [UsageIssue.permissionRequired, .renewalRequired] {
            let result = await ClaudeUsageReader.recover(.failure(.claude, issue), allowPrompt: false) {
                try! ClaudeCLIUsageReader.decode(payload)
            }
            XCTAssertNil(result.issue); XCTAssertTrue(result.usesClaudeCLI)
        }
    }
    func testRecoveryDoesNotOverrideLockDenialRateLimitOrActualMissingLogin() async {
        for issue in [UsageIssue.keychainLocked, .rateLimited, .signInRequired, .unavailable] {
            let result = await ClaudeUsageReader.recover(.failure(.claude, issue), allowPrompt: false) {
                XCTFail("Must not run another authentication path"); return .failure(.claude, .unsupported)
            }
            XCTAssertEqual(result.issue, issue)
        }
        let result = await ClaudeUsageReader.recover(.failure(.claude, .permissionRequired), allowPrompt: true) {
            XCTFail("A declined permission prompt must not trigger CLI fallback"); return .failure(.claude, .unsupported)
        }
        XCTAssertEqual(result.issue, .permissionRequired)
    }
    func testFailedFallbackPreservesActionableCause() async {
        let result = await ClaudeUsageReader.recover(.failure(.claude, .permissionRequired), allowPrompt: false) {
            .failure(.claude, .unsupported)
        }
        XCTAssertEqual(result.issue, .permissionRequired)
        let limited = await ClaudeUsageReader.recover(.failure(.claude, .permissionRequired), allowPrompt: false) {
            .failure(.claude, .rateLimited)
        }
        XCTAssertEqual(limited.issue, .rateLimited)
    }
    func testEnvironmentRetainsSelectedAccountAndTrafficPolicyOnly() {
        let env = ClaudeCLIUsageReader.environment(profile: "/chosen profile", base: [
            "HOME": "/home", "PATH": "/bin", "CLAUDE_CONFIG_DIR": "/other", "ANTHROPIC_API_KEY": "NEVER",
            "ANTHROPIC_BASE_URL": "https://wrong.invalid", "CLAUDE_CODE_OAUTH_TOKEN": "NEVER", "NODE_OPTIONS": "injected",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "GIT_DIR": "/other-repo"
        ])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/chosen profile")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "NODE_OPTIONS", "GIT_DIR"] { XCTAssertNil(env[key]) }
        XCTAssertEqual(ClaudeCLIUsageReader.environment(profile: nil, base: ["CLAUDE_CONFIG_DIR": "/ambient"])["CLAUDE_CONFIG_DIR"], "/ambient")
    }
    func testBoundedCommandHasNoToolsHooksMCPOrSessionPersistence() throws {
        let payload = try String(data: report(), encoding: .utf8)!
        let quoted = try String(data: JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed), encoding: .utf8)!
        let fake = try ProviderUsageTests().fixture("""
        import sys,os,json
        a=sys.argv[1:]
        assert a[:2]==['-p','/usage']
        assert a[a.index('--max-turns')+1]=='0'
        assert a[a.index('--tools')+1]==''
        assert a[a.index('--setting-sources')+1]==''
        assert json.loads(a[a.index('--settings')+1])=={'disableAllHooks':True,'remoteControlAtStartup':False}
        assert '--strict-mcp-config' in a and '--no-session-persistence' in a
        assert json.loads(a[a.index('--mcp-config')+1])=={'mcpServers':{}}
        assert os.environ['CLAUDE_CONFIG_DIR']=='/chosen'
        assert os.path.basename(os.getcwd()).startswith('burro-usage-')
        sys.stdout.write(\(quoted))
        """)
        defer { try? FileManager.default.removeItem(at: fake) }
        let result = try ClaudeCLIUsageReader.decode(ClaudeCLIUsageReader.run(executable: fake.path, profile: "/chosen", timeout: 5))
        XCTAssertEqual(result.windows.count, 3)
    }
    func testHungCommandTerminatesWithinBound() throws {
        let fake = try ProviderUsageTests().fixture("import time\ntime.sleep(30)")
        defer { try? FileManager.default.removeItem(at: fake) }
        let start = Date()
        XCTAssertThrowsError(try ClaudeCLIUsageReader.run(executable: fake.path, profile: nil, timeout: 0.1)) {
            XCTAssertEqual($0 as? UsageIssue, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testOversizedOutputIsRejected() throws {
        let fake = try ProviderUsageTests().fixture("import sys\nsys.stdout.write('x'*3000000)")
        defer { try? FileManager.default.removeItem(at: fake) }
        XCTAssertThrowsError(try ClaudeCLIUsageReader.run(executable: fake.path, profile: nil, timeout: 5)) {
            XCTAssertEqual($0 as? UsageIssue, .unsupported)
        }
    }
}
