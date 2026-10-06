// Synthetic renewal races, stale credentials, profile isolation, retries, and subprocess boundaries.
import XCTest
@testable import BurroCore

private final class PromptFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    var requests: [Bool] { lock.withLock { values } }
    func record(_ allowed: Bool) { lock.withLock { values.append(allowed) } }
}
private final class RenewalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data
    private var count = 0
    init(_ value: Data) { self.value = value }
    func read() -> Data { lock.withLock { value } }
    func replace(_ data: Data) { lock.withLock { value = data; count += 1 } }
    func increment() { lock.withLock { count += 1 } }
    var calls: Int { lock.withLock { count } }
}
final class UsageCredentialRenewalTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func grok(_ token: String = "old", expiry: TimeInterval = -1, refresh: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["https://auth.x.ai::test": [
            "key": token, "user_id": "fixture-user", "oidc_issuer": "https://auth.x.ai",
            "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(expiry)),
            "refresh_token": refresh ? "synthetic-refresh" : ""
        ]])
    }
    func testExpiredGrokRenewsSilentlyAndRereadsOwnerStore() async throws {
        let fixture = RenewalFixture(try grok()), fresh = try grok("new", expiry: 3600)
        let value = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now,
            coordinator: UsageCredentialRenewal(), read: { fixture.read() }, renew: { fixture.replace(fresh) })
        XCTAssertEqual(value.token, "new"); XCTAssertEqual(fixture.calls, 1)
    }
    func testConcurrentReadersShareOneRenewal() async throws {
        let fixture = RenewalFixture(try grok()), fresh = try grok("new", expiry: 3600)
        let coordinator = UsageCredentialRenewal(), date = now
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await GrokUsageReader.loadCredential(folder: "/fixture", now: date,
                        coordinator: coordinator, read: { fixture.read() }, renew: {
                            try await Task.sleep(for: .milliseconds(50)); fixture.replace(fresh)
                        }).token
                }
            }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(values, Array(repeating: "new", count: 5)); XCTAssertEqual(fixture.calls, 1)
    }
    func testValidGrokDoesNotSpawnOrRefresh() async throws {
        let fixture = RenewalFixture(try grok(expiry: 3600))
        _ = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now, coordinator: UsageCredentialRenewal(),
            read: { fixture.read() }, renew: { fixture.increment() })
        XCTAssertEqual(fixture.calls, 0)
    }
    func testFailedProactiveRenewalStillUsesUnexpiredToken() async throws {
        let fixture = RenewalFixture(try grok(expiry: 120))
        let value = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now, coordinator: UsageCredentialRenewal(),
            read: { fixture.read() }, renew: { throw UsageIssue.unavailable })
        XCTAssertEqual(value.token, "old")
    }
    func testMissingRefreshDoesNotInvokeLogin() async throws {
        let fixture = RenewalFixture(try grok(refresh: false))
        do {
            _ = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now, coordinator: UsageCredentialRenewal(),
                read: { fixture.read() }, renew: { fixture.increment() })
            XCTFail("Expired credential accepted")
        } catch { XCTAssertEqual(error as? UsageIssue, .renewalRequired) }
        XCTAssertEqual(fixture.calls, 0)
    }
    func testSuccessfulCLIWithoutChangedCredentialsIsNotSuccess() async throws {
        let fixture = RenewalFixture(try grok())
        do {
            _ = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now, coordinator: UsageCredentialRenewal(),
                read: { fixture.read() }, renew: {})
            XCTFail("Expired credential accepted")
        } catch { XCTAssertEqual(error as? UsageIssue, .renewalRequired) }
    }
    func testRenewalFailureBackoffAndProfileIsolation() async throws {
        let fixture = RenewalFixture(Data()), coordinator = UsageCredentialRenewal()
        for (profile, token) in [("a", "old"), ("a", "old"), ("b", "old"), ("a", "new")] {
            do {
                try await coordinator.renew(profile: profile, fingerprint: token, now: now) {
                    fixture.increment(); throw UsageIssue.unavailable
                }
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? UsageIssue, .unavailable) }
        }
        XCTAssertEqual(fixture.calls, 3)
    }
    func testOwnerRotationWinsEvenIfRenewingCommandTimesOut() async throws {
        let fixture = RenewalFixture(try grok()), fresh = try grok("owner-renewed", expiry: 3600)
        let value = try await GrokUsageReader.loadCredential(folder: "/fixture", now: now, coordinator: UsageCredentialRenewal(),
            read: { fixture.read() }, renew: { fixture.replace(fresh); throw UsageIssue.timedOut })
        XCTAssertEqual(value.token, "owner-renewed")
    }
    func testClaudeRetriesChangedTokenAfter401() async {
        let fixture = RenewalFixture(Data())
        let result = await ClaudeUsageReader.read(load: { _ in
            ClaudeUsageCredential(accessToken: fixture.calls == 0 ? "old" : "new")
        }, fetch: { token in
            if token.accessToken == "old" { fixture.increment(); throw UsageIssue.expired }
            return ProviderUsage(id: .claude, windows: [])
        })
        XCTAssertNil(result.issue); XCTAssertEqual(fixture.calls, 1)
    }
    func testClaudeDoesNotRetryRejectedUnchangedToken() async {
        let fixture = RenewalFixture(Data())
        let result = await ClaudeUsageReader.read(load: { _ in ClaudeUsageCredential(accessToken: "same") }, fetch: { _ in
            fixture.increment(); throw UsageIssue.expired
        })
        XCTAssertEqual(result.issue, .renewalRequired); XCTAssertEqual(fixture.calls, 1)
    }
    func testClaudeConnectionAllowsOnlyInitialReadToPrompt() async {
        let fixture = PromptFixture()
        let result = await ClaudeUsageReader.read(allowKeychainPrompt: true, load: { allowed in
            fixture.record(allowed)
            return ClaudeUsageCredential(accessToken: fixture.requests.count == 1 ? "old" : "new")
        }, fetch: { token in
            if token.accessToken == "old" { throw UsageIssue.expired }
            return ProviderUsage(id: .claude, windows: [])
        })
        XCTAssertNil(result.issue)
        XCTAssertEqual(fixture.requests, [true, false])
    }
    func testBackgroundRotationNeverEnablesPromptAndDenialDoesNotLoop() async {
        let fixture = PromptFixture()
        let result = await ClaudeUsageReader.read(load: { allowed in
            fixture.record(allowed)
            if fixture.requests.count > 1 { throw UsageIssue.permissionRequired }
            return ClaudeUsageCredential(accessToken: "old")
        }, fetch: { _ in throw UsageIssue.expired })
        XCTAssertEqual(result.issue, .permissionRequired)
        XCTAssertEqual(fixture.requests, [false, false])
    }
    func testClaudeExpiredTokenDoesNotAskForPasswordOrMakeRequest() async {
        let fixture = RenewalFixture(Data())
        let result = await ClaudeUsageReader.read(load: { _ in throw UsageIssue.expired }, fetch: { _ in
            fixture.increment(); return .failure(.claude, .unavailable)
        })
        XCTAssertEqual(result.issue, .renewalRequired); XCTAssertEqual(fixture.calls, 0)
    }
    func testOnlyExplicitClaudeConnectionAllowsKeychainUI() {
        XCTAssertTrue(ClaudeUsageCredential.authenticationContext(allowPrompt: false).interactionNotAllowed)
        XCTAssertFalse(ClaudeUsageCredential.authenticationContext(allowPrompt: true).interactionNotAllowed)
    }
    func testTemporaryProviderErrorsDoNotOfferSignIn() {
        for issue: UsageIssue in [.unavailable, .timedOut, .rateLimited, .renewalRequired, .permissionRequired, .unsupported, .notInstalled] {
            XCTAssertFalse(issue.requiresSignIn)
        }
        XCTAssertTrue(UsageIssue.signInRequired.requiresSignIn)
        XCTAssertTrue(UsageIssue.expired.requiresSignIn)
        XCTAssertEqual(UsageIssue.renewalRequired.accountLabel, "Session renewal needed")
    }
    func testRetryPolicySeparatesTemporaryFailureFromLogin() {
        XCTAssertEqual(UsageRetryPolicy.delay(issue: .unavailable, failures: 1, interval: 900), 30)
        XCTAssertEqual(UsageRetryPolicy.delay(issue: .timedOut, failures: 10, interval: 60), 300)
        XCTAssertEqual(UsageRetryPolicy.delay(issue: .rateLimited, failures: 1, interval: 60), 300)
        XCTAssertEqual(UsageRetryPolicy.delay(issue: .renewalRequired, failures: 5, interval: 900), 60)
        XCTAssertEqual(UsageRetryPolicy.delay(issue: nil, failures: 0, interval: 900), 900)
    }
    func testGrokCommandEnvironmentKeepsSelectedProfileAndNoAPIOverride() {
        let environment = GrokCredentialCommand.environment(profile: "/selected profile", base: [
            "GROK_HOME": "/wrong", "XAI_API_KEY": "secret", "GROK_API_KEY": "secret", "GIT_DIR": "/repo", "HOME": "/user"])
        XCTAssertEqual(environment, ["GROK_HOME": "/selected profile", "HOME": "/user", "NO_COLOR": "1"])
    }
    func testGrokCommandIsBoundedAndOnlyListsModels() throws {
        let path = try ProviderUsageTests().fixture("""
        import os,sys
        assert sys.argv[1:]==['models']
        assert os.getcwd()=='/'
        assert os.environ['GROK_HOME']=='/fixture profile'
        assert sys.stdin.read()==''
        """)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertNoThrow(try GrokCredentialCommand.run(executable: path.path, profile: "/fixture profile", timeout: 5))
        let hung = try ProviderUsageTests().fixture("""
        import signal,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        time.sleep(60)
        """)
        defer { try? FileManager.default.removeItem(at: hung) }
        let start = Date()
        XCTAssertThrowsError(try GrokCredentialCommand.run(executable: hung.path, profile: "/fixture", timeout: 0.1)) {
            XCTAssertEqual($0 as? UsageIssue, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
