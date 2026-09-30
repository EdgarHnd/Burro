// Synthetic native provider payloads verify quota meaning, errors, credentials, and bounded RPC cleanup.
import XCTest
@testable import BurroCore

final class ProviderUsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testCodexUsesCurrentBucketsNotLegacyDuplicate() throws {
        let value = try UsageDecoding.codex(data([
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 35, "windowDurationMins": 10080, "resetsAt": 1_800_086_400]],
                                   "review": ["limitName": "Review", "secondary": ["usedPercent": 20, "windowDurationMins": 300]]]
        ]), now: now)
        XCTAssertEqual(value.windows.count, 2)
        XCTAssertEqual(value.windows[0].title, "Weekly")
        XCTAssertEqual(value.windows[0].remainingPercent, 65)
        XCTAssertEqual(value.windows[1].title, "Review · 5 hours")
        XCTAssertEqual(value.windows[0].resetsAt, now.addingTimeInterval(86400))
    }
    func testEmptyCurrentBucketsDoNotReviveLegacy() throws {
        let value = try UsageDecoding.codex(data(["rateLimitsByLimitId": [:], "rateLimits": ["primary": ["usedPercent": 30]]]))
        XCTAssertTrue(value.windows.isEmpty); XCTAssertEqual(value.issue, .unsupported)
    }
    func testLegacyCodexAndUnknownValues() throws {
        for used: Any in [NSNull(), true, -1, 101, "30"] {
            let value = try UsageDecoding.codex(data(["rateLimits": ["primary": ["usedPercent": used]]]))
            XCTAssertNil(value.windows.first?.remainingPercent)
            XCTAssertNil(value.windows.first?.resetsAt)
        }
        let value = try UsageDecoding.codex(data(["rateLimits": ["secondary": ["usedPercent": 100, "windowDurationMins": 10080]]]))
        XCTAssertEqual(value.windows.first?.remainingPercent, 0)
    }
    func testClaudeWindowsIgnoreSpendAndMissingWindows() throws {
        let value = try UsageDecoding.claude(data([
            "five_hour": ["utilization": 22, "resets_at": "2027-01-15T12:00:00.000Z"],
            "seven_day": NSNull(), "seven_day_opus": ["utilization": 0],
            "extra_usage": ["used_credits": 123456], "account": "PRIVATE"
        ]), now: now)
        XCTAssertEqual(value.windows.map(\.title), ["Session", "Opus weekly"])
        XCTAssertEqual(value.windows.map(\.remainingPercent), [78,100])
        XCTAssertNotNil(value.windows[0].resetsAt)
    }
    func testMalformedAndOversizedPayloads() throws {
        XCTAssertThrowsError(try UsageDecoding.codex(Data("nope".utf8)))
        XCTAssertThrowsError(try UsageDecoding.claude(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try UsageDecoding.codex(data(["rateLimitsByLimitId": ["bad": "bad"]])))
        XCTAssertEqual(try UsageDecoding.claude(data([:])).issue, .unsupported)
    }
    func testCountdownAndStalenessDoNotInventRefills() {
        let window = UsageWindow(id: "a", title: "Weekly", remainingPercent: 2, resetsAt: now)
        XCTAssertTrue(window.isExpired(now: now)); XCTAssertEqual(window.resetLabel(now: now), "Awaiting reset update")
        let value = ProviderUsage(id: .codex, updatedAt: now.addingTimeInterval(-601), windows: [window])
        XCTAssertTrue(value.isStale(now: now)); XCTAssertEqual(value.windows[0].remainingPercent, 2)
        XCTAssertEqual(UsageWindow(id: "b", title: "Session", resetsAt: now.addingTimeInterval(61)).resetLabel(now: now), "Resets in 2m")
    }
    func credential(token: String = "synthetic-token", expiry: Double? = nil, scopes: [String] = ["user:profile"]) throws -> Data {
        try data(["claudeAiOauth": ["accessToken": token, "expiresAt": expiry ?? (now.timeIntervalSince1970 + 3600) * 1000,
                                   "scopes": scopes, "refreshToken": "NEVER-USED"]])
    }
    func testCredentialRequiresUsageScopeAndValidExpiry() throws {
        XCTAssertEqual(try ClaudeUsageCredential.decode(credential(), now: now).accessToken, "synthetic-token")
        XCTAssertThrowsError(try ClaudeUsageCredential.decode(credential(scopes: ["user:inference"]), now: now))
        XCTAssertThrowsError(try ClaudeUsageCredential.decode(credential(expiry: 0), now: now))
        XCTAssertThrowsError(try ClaudeUsageCredential.decode(credential(token: "bad\nheader"), now: now))
        XCTAssertThrowsError(try ClaudeUsageCredential.decode(data(["mcpOAuth": [:]]), now: now))
    }
    func testClaudeRequestIsOnlyFixedHTTPSUsageEndpoint() {
        let request = ClaudeUsageReader.request(token: "synthetic")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }
    func testHTTPErrorsAreSanitized() {
        for (status, expected): (Int, UsageIssue) in [(401,.expired),(403,.signInRequired),(429,.rateLimited),(302,.unavailable),(500,.unavailable)] {
            XCTAssertThrowsError(try ClaudeUsageReader.validate(status: status)) { XCTAssertEqual($0 as? UsageIssue, expected) }
        }
        XCTAssertNoThrow(try ClaudeUsageReader.validate(status: 200))
    }
    func testCodexMissingExecutable() {
        XCTAssertEqual(CodexUsageReader.read(executable: nil).issue, .notInstalled)
        XCTAssertEqual(CodexUsageReader.read(executable: "/not/a/program").issue, .unavailable)
    }
    func fixture(_ script: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("burro-rpc-test-\(UUID().uuidString)")
        try ("#!/usr/bin/python3\n" + script).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    func testRPCHandshakeReadsOnlyAccountAndLimits() throws {
        let path = try fixture("""
        import sys,json
        methods=[]
        for line in sys.stdin:
            req=json.loads(line);methods.append(req['method'])
            if req['method']=='initialized':continue
            expected={1:'initialize',2:'account/read',3:'account/rateLimits/read'}
            assert expected[req['id']]==req['method']
            if req['id']==1:result={}
            elif req['id']==2:result={'account':{'type':'chatgpt'}}
            else:
                assert methods==['initialize','initialized','account/read','account/rateLimits/read']
                result={'rateLimits':{'primary':{'usedPercent':35,'windowDurationMins':10080}}}
            print(json.dumps({'method':'ignored/notification'}),flush=True)
            print(json.dumps({'id':req['id'],'result':result}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path) }
        let value = CodexUsageReader.read(executable: path.path, timeout: 5)
        XCTAssertNil(value.issue); XCTAssertEqual(value.windows.first?.remainingPercent, 65)
    }
    func testCodexDelegatesRecoveryAndUsesRefreshedIdentity() throws {
        let path = try fixture("""
        import sys,json
        for line in sys.stdin:
            req=json.loads(line)
            if req['method']=='initialized':continue
            n=req['id']
            if n==1:result={}
            elif n==2:
                assert req['params']['refreshToken']==False
                result={'account':{'type':'chatgpt','email':'old@example.invalid'}}
            elif n==3:
                print(json.dumps({'id':n,'error':{'message':'private rejection'}}),flush=True)
                continue
            elif n==4:
                assert req['method']=='account/read' and req['params']['refreshToken']==True
                result={'account':{'type':'chatgpt','email':'new@example.invalid'}}
            else:
                assert n==5 and req['method']=='account/rateLimits/read'
                result={'rateLimits':{'primary':{'usedPercent':20}}}
            print(json.dumps({'id':n,'result':result}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path) }
        let value = CodexUsageReader.read(executable: path.path, timeout: 5)
        XCTAssertNil(value.issue); XCTAssertEqual(value.identity?.account, "new@example.invalid")
        XCTAssertEqual(value.windows.first?.remainingPercent, 80)
    }
    func testRPCDoesNotLeakErrorMessages() throws {
        let path = try fixture("""
        import sys,json
        for line in sys.stdin:
            req=json.loads(line)
            print(json.dumps({'id':req['id'],'error':{'message':'PRIVATE TOKEN'}}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertEqual(CodexUsageReader.read(executable: path.path).issue, .unavailable)
    }
    func testRPCTimeoutKillsUnresponsiveChild() throws {
        let path = try fixture("""
        import signal,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        time.sleep(60)
        """)
        defer { try? FileManager.default.removeItem(at: path) }
        let start = Date()
        XCTAssertEqual(CodexUsageReader.read(executable: path.path, timeout: 0.2).issue, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
