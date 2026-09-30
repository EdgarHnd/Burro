// Regression coverage for account boundaries, model quotas, pace and deduplicated local token estimates.
import XCTest
@testable import BurroCore

final class UsageDashboardTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testClaudeNativeWindowsKeepUnusedFableWithoutDuplicatingLegacy() throws {
        let value = try UsageDecoding.claude(data([
            "limits": [
                ["kind": "session", "percent": 24, "is_active": true],
                ["kind": "weekly_all", "percent": 51],
                ["kind": "weekly_scoped", "percent": 0, "is_active": false,
                 "scope": ["model": ["display_name": "Fable", "id": NSNull()]]]],
            "five_hour": ["utilization": 99], "seven_day": ["utilization": 99]
        ]))
        XCTAssertEqual(value.windows.map(\.title), ["Session", "Weekly", "Fable weekly"])
        XCTAssertEqual(value.windows.map(\.remainingPercent), [76,49,100])
        XCTAssertEqual(value.windows[2].model, "Fable")
    }
    func testNativeEmptyListDoesNotReviveLegacyValues() throws {
        XCTAssertEqual(try UsageDecoding.claude(data(["limits": [], "five_hour": ["utilization": 99]])).issue, .unsupported)
    }
    func testVerifiedAccountScopesAreSeparateAndHistoryContainsNoEmail() throws {
        let a = try XCTUnwrap(UsageDecoding.claudeIdentity(data(["account": ["uuid": "a", "email": "a@example.test", "has_claude_max": true], "organization": ["uuid": "team-a"]])))
        let b = try XCTUnwrap(UsageDecoding.claudeIdentity(data(["account": ["uuid": "b", "email": "b@example.test"], "organization": ["uuid": "team-b"]])))
        XCTAssertEqual(a.account, "a@example.test"); XCTAssertEqual(a.plan, "Max"); XCTAssertNotEqual(a.scope, b.scope)
        let usage = ProviderUsage(id: .claude, updatedAt: now, windows: [], identity: a)
        let sample = try XCTUnwrap(UsageHistorySample(usage: usage))
        let encoded = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        XCTAssertFalse(encoded.contains("example.test")); XCTAssertFalse(encoded.contains("team-a"))
        XCTAssertNil(UsageHistorySample(usage: .failure(.claude, .expired)))
        XCTAssertNil(UsageHistorySample(usage: .loading(.claude)))
        XCTAssertNil(UsageHistorySample(usage: ProviderUsage(id: .claude, updatedAt: now, windows: [])))
    }
    func testHistoryExpiresOldAndFutureSamples() throws {
        let identity = UsageIdentity(account: "test", owner: "test")
        func sample(_ date: Date) -> UsageHistorySample { UsageHistorySample(usage: ProviderUsage(id: .codex, updatedAt: date, windows: [], identity: identity))! }
        XCTAssertEqual(UsageHistorySample.retaining([sample(now), sample(now.addingTimeInterval(-31 * 86400)), sample(now.addingTimeInterval(3600))], now: now).count, 1)
    }
    func testPaceDoesNotPredictExpiredOrUnknownWindows() throws {
        let window = UsageWindow(id: "weekly", title: "Weekly", remainingPercent: 60, resetsAt: now.addingTimeInterval(500), duration: 1000)
        let pace = try XCTUnwrap(UsagePace(window: window, now: now))
        XCTAssertEqual(pace.expectedRemaining, 50); XCTAssertEqual(pace.reserve, 10)
        XCTAssertEqual(pace.exhaustion, now.addingTimeInterval(750))
        XCTAssertNil(UsagePace(window: window, now: now.addingTimeInterval(500)))
        XCTAssertNil(UsagePace(window: UsageWindow(id: "x", title: "x", remainingPercent: 50), now: now))
    }
    func testCustomClaudeProfileNeverFallsBackToDefaultAccount() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertThrowsError(try ClaudeUsageCredential.load(allowPrompt: false, profile: missing)) { XCTAssertEqual($0 as? UsageIssue, .signInRequired) }
    }
    func testAsynchronousCredentialLoadPreservesProfileAndErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await ClaudeUsageCredential.loadAsync(allowPrompt: false, profile: folder.path)
            XCTFail("An empty profile must not read another account's Keychain entry")
        } catch { XCTAssertEqual(error as? UsageIssue, .signInRequired) }
        let credential = try data(["claudeAiOauth": ["accessToken": "synthetic-token", "scopes": ["user:profile"],
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]])
        try credential.write(to: folder.appendingPathComponent(".credentials.json"))
        let loaded = try await ClaudeUsageCredential.loadAsync(allowPrompt: false, profile: folder.path)
        XCTAssertEqual(loaded.accessToken, "synthetic-token")
    }
    func testGrokCreditsAndUnknownValues() throws {
        let result = try GrokUsageReader.decode(data(["config": ["creditUsagePercent": 20,
            "currentPeriod": ["start": "2027-01-01T00:00:00Z", "end": "2027-02-01T00:00:00Z"],
            "productUsage": [["product": "Coding", "usagePercent": 20]],
            "onDemandCap": ["val": 1000], "onDemandUsed": ["val": 250]]]))
        XCTAssertEqual(result.windows.map(\.remainingPercent), [80]); XCTAssertEqual(result.products.first?.usedPercent, 20); XCTAssertEqual(result.windows[0].title, "Monthly credits")
        XCTAssertEqual(result.balance?.used, 2.5); XCTAssertEqual(result.balance?.limit, 10)
        XCTAssertEqual(try GrokUsageReader.decode(data(["config": [:]])).issue, .unsupported)
        XCTAssertNil(try GrokUsageReader.decode(data(["config": ["creditUsagePercent": true]])).windows.first?.remainingPercent)
    }
    func testGrokRejectsExpiredAmbiguousAndHeaderInjectionCredentials() throws {
        let entry: [String: Any] = ["key": "test", "expires_at": "2028-01-01T00:00:00Z", "user_id": "a", "email": "a@example.test"]
        XCTAssertEqual(try GrokUsageReader.credential(data(["https://auth.x.ai::one": entry]), now: now).email, "a@example.test")
        XCTAssertThrowsError(try GrokUsageReader.credential(data(["https://auth.x.ai::one": entry, "https://auth.x.ai::two": entry]), now: now))
        XCTAssertThrowsError(try GrokUsageReader.credential(data(["https://auth.x.ai::one": entry]), now: Date(timeIntervalSince1970: 2_000_000_000)))
        var bad = entry; bad["key"] = "bad\nheader"
        XCTAssertThrowsError(try GrokUsageReader.credential(data(["https://auth.x.ai::one": bad]), now: now))
    }
    func testClaudeTokenCategoriesAndCachePricing() throws {
        let value: [String: Any] = ["type": "assistant", "timestamp": "2027-01-15T08:00:00Z", "requestId": "req", "message": [
            "id": "msg", "model": "claude-opus-5-5", "usage": ["input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 1000,
                "cache_creation_input_tokens": 200, "cache_creation": ["ephemeral_1h_input_tokens": 50]]]]
        let record = try XCTUnwrap(LocalUsageScanner.claudeRecord(value))
        XCTAssertEqual(record.total, 1350); XCTAssertEqual(record.cacheWrite, 150); XCTAssertEqual(record.cacheWriteHour, 50)
        XCTAssertEqual(record.apiValue!, (400 + 1000 + 200 + 750 + 400) / 1_000_000.0, accuracy: 0.000001)
    }
    func testClaudeIgnoresIncompleteStreamEnvelope() {
        let value: [String: Any] = ["type": "assistant", "timestamp": "2027-01-15T08:00:00Z", "message": ["id": "msg", "model": "claude-opus-5-5", "usage": ["input_tokens": 100, "output_tokens": 0]]]
        XCTAssertNil(LocalUsageScanner.claudeRecord(value))
    }
    func testCodexUsesLastCallNotCumulativeAndDedupsRepeatedEvents() throws {
        var model = "gpt-6-sol", total: Double?
        let value: [String: Any] = ["type": "event_msg", "timestamp": "2027-01-15T08:00:00Z", "payload": ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 1000000], "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 20]]]]
        let first = try XCTUnwrap(LocalUsageScanner.codexRecord(value, model: &model, previousTotal: &total))
        XCTAssertEqual(first.total, 120); XCTAssertEqual(first.input, 60)
        XCTAssertNil(LocalUsageScanner.codexRecord(value, model: &model, previousTotal: &total))
        total = nil
        XCTAssertEqual(LocalUsageScanner.codexRecord(value, model: &model, previousTotal: &total)?.key, first.key)
    }
    func testUnknownModelsAreNotPricedAtZero() {
        let record = LocalUsageRecord(key: "x", date: now, model: "future-model", input: 100, cached: 0, cacheWrite: 0, cacheWriteHour: 0, output: 20)
        XCTAssertNil(record.apiValue)
        let summary = LocalUsageScanner.aggregate([record], partial: true, now: now)
        XCTAssertEqual(summary.tokens, 120); XCTAssertEqual(summary.pricedCount, 0); XCTAssertTrue(summary.partial)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { let low = UInt8(value & 127); value >>= 7; bytes.append(low | (value > 0 ? 128 : 0)) } while value > 0
        return bytes
    }
    private func message(_ field: UInt8, _ value: [UInt8]) -> [UInt8] { [field << 3 | 2] + varint(UInt64(value.count)) + value }
    private func framed(_ value: [UInt8], trailer: String = "grpc-status: 0\r\n") -> Data {
        func frame(_ bytes: [UInt8], flag: UInt8) -> [UInt8] { [flag, UInt8((bytes.count >> 24) & 255), UInt8((bytes.count >> 16) & 255), UInt8((bytes.count >> 8) & 255), UInt8(bytes.count & 255)] + bytes }
        return Data(frame(value, flag: 0) + frame(Array(trailer.utf8), flag: 128))
    }
    func testGrokNativeZeroRequiresValidatedActivePeriod() throws {
        let start = message(2, [8] + varint(UInt64(now.timeIntervalSince1970 - 86400)))
        let end = message(3, [8] + varint(UInt64(now.timeIntervalSince1970 + 6 * 86400)))
        let period = message(8, [8, 1] + start + end)
        let valid = try GrokWebUsage.decode(framed(message(1, period)), now: now)
        XCTAssertEqual(valid.windows.first?.remainingPercent, 100)
        XCTAssertEqual(valid.windows.first?.title, "Weekly credits")
        XCTAssertThrowsError(try GrokWebUsage.decode(framed(message(1, [])), now: now))
        XCTAssertThrowsError(try GrokWebUsage.decode(framed(message(1, period)), now: now.addingTimeInterval(7 * 86400)))
    }
    func testGrokNativePercentAndFailureFraming() throws {
        let bits = Float(24).bitPattern
        let percent = [UInt8(13)] + (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
        let payload = framed(message(1, percent))
        XCTAssertEqual(try GrokWebUsage.decode(payload, now: now).windows.first?.remainingPercent, 76)
        XCTAssertThrowsError(try GrokWebUsage.decode(Data(payload.dropLast()), now: now))
        XCTAssertThrowsError(try GrokWebUsage.decode(framed(message(1, percent), trailer: "grpc-status: 16\r\ngrpc-message: PRIVATE"), now: now))
        XCTAssertThrowsError(try GrokWebUsage.decode(framed([255,255,255,255,255,255,255,255,255,255]), now: now))
    }
}
