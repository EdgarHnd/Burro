import XCTest
@testable import BurroCore

final class MachinesTests: XCTestCase {
    func testVersionParsingAndComparison() {
        XCTAssertEqual(Harness.parseVersion("2.1.317 (Claude Code)"), "2.1.317")
        XCTAssertEqual(Harness.parseVersion("codex-cli 0.166.0"), "0.166.0")
        XCTAssertEqual(Harness.parseVersion("grok 1.0.46 (2765805b9442) [stable]"), "1.0.46")
        XCTAssertEqual(Harness.parseVersion("2026.10.01-e373342"), "2026.10.01-e373342")
        XCTAssertNil(Harness.parseVersion("command not found"))
        XCTAssertTrue(Harness.isOlder("2.1.287", than: "2.1.299"))
        XCTAssertFalse(Harness.isOlder("2.1.317", than: "2.1.299"))
        XCTAssertFalse(Harness.isOlder("0.166.0", than: "0.166.0"))
        XCTAssertTrue(Harness.isOlder("0.62", than: "0.64.0"))
        XCTAssertTrue(Harness.isOlder("1.2.0-beta.1", than: "1.2.0"))
        XCTAssertTrue(Harness.isOlder("2026.10.01-14929f9", than: "2026.10.14-0f9edde"))
    }

    func testProbeOutputParsing() {
        let output = """
        os=macOS 27.2
        claude=2.1.317 (Claude Code)
        codex=codex-cli 0.166.0
        cursor-agent=2026.10.01-e373342
        gemini=
        unknown=1.0.0
        """
        let facts = MachineProbe.parse(output)
        XCTAssertEqual(facts.os, "macOS 27.2")
        XCTAssertEqual(facts.versions, [.claude: "2.1.317", .codex: "0.166.0", .cursor: "2026.10.01-e373342"])
        XCTAssertFalse(MachineProbe.script.contains("$1"), "the probe takes no arguments")
    }

    func testSSHArgumentsKeepHardenedOptionsWithAFixedCommand() {
        let host = RemoteHost(name: "Studio", destination: "me@studio", port: 2222)
        let args = MachineProbe.sshArguments(for: host, command: "sh -s")
        XCTAssertEqual(args.suffix(3), ["--", "me@studio", "sh -s"])
        XCTAssertTrue(args.contains("BatchMode=yes") && args.contains("StrictHostKeyChecking=yes") && args.contains("ForwardAgent=no"))
        XCTAssertTrue(args.contains("2222"))
    }

    func testTailscaleParsingKeepsNamesAndPresenceOnly() throws {
        let json = Data(#"""
        {"Self":{"ID":"n1","HostName":"MacBook-Pro","DNSName":"macbook-pro.tail1234.ts.net.","OS":"macOS","Online":true,"TailscaleIPs":["100.1.2.3"]},
         "Peer":{"k1":{"ID":"n2","HostName":"Mac-Studio","DNSName":"mac-studio.tail1234.ts.net.","OS":"macOS","Online":true,"LastSeen":"0001-01-01T00:00:00Z"},
                 "k2":{"ID":"n3","HostName":"Pixel","DNSName":"pixel.tail1234.ts.net.","OS":"android","Online":false,"LastSeen":"2026-11-08T21:15:04.123Z"}}}
        """#.utf8)
        let peers = try XCTUnwrap(Tailscale.parse(json))
        XCTAssertEqual(peers.map(\.hostName), ["MacBook-Pro", "Mac-Studio", "Pixel"], "self, then online, then offline")
        XCTAssertEqual(peers[1].dnsName, "mac-studio.tail1234.ts.net")
        XCTAssertNil(peers[1].lastSeen, "Tailscale's zero date means unknown")
        XCTAssertNotNil(peers[2].lastSeen)
        XCTAssertFalse(peers[2].online)
    }

    /// BURRO_LIVE_MACHINES=1: probe this Mac, read Tailscale and npm (read-only; prints counts and versions only).
    func testLiveMachineInventory() async throws {
        guard ProcessInfo.processInfo.environment["BURRO_LIVE_MACHINES"] == "1" else { throw XCTSkip("set BURRO_LIVE_MACHINES=1") }
        let started = Date()
        let local = try XCTUnwrap(MachineProbe.local())
        print("local: \(local.os ?? "?") \(local.versions.map { "\($0.key.rawValue)=\($0.value)" }.sorted()) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        XCTAssertNotNil(local.versions[.claude])
        let latest = await HarnessReleases.latest()
        print("latest: \(latest.map { "\($0.key.rawValue)=\($0.value)" }.sorted())")
        XCTAssertNotNil(latest[.claude])
        if let peers = Tailscale.peers() { print("tailscale: \(peers.count) devices, \(peers.filter(\.online).count) online, OS \(Set(peers.map(\.os)).sorted())") }
    }
}
