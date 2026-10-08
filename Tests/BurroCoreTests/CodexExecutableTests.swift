// Resolve modern and legacy desktop packages before shell-dependent CLI wrappers.
import XCTest
@testable import BurroCore

final class CodexExecutableTests: XCTestCase {
    private func find(_ available: Set<String>, app: String? = "/Apps/Codex.app", bundled: String? = nil) -> String? {
        CodexUsageReader.executable(home: "/fixture", bundled: bundled, appBundle: app, isExecutable: available.contains)
    }
    func testCurrentDesktopPackageWinsOverNpmShim() {
        let packaged = "/Apps/Codex.app/Contents/Resources/codex-cli/bin/codex"
        XCTAssertEqual(find([packaged, "/fixture/.local/bin/codex"]), packaged)
    }
    func testLegacyDesktopAndExplicitExecutableRemainSupported() {
        let legacy = "/Apps/Codex.app/Contents/Resources/codex"
        XCTAssertEqual(find([legacy, "/fixture/.local/bin/codex"]), legacy)
        XCTAssertEqual(find([legacy, "/explicit/codex"], bundled: "/explicit/codex"), "/explicit/codex")
    }
    func testKnownInstallLocationsAndStandaloneFallback() {
        let packaged = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        XCTAssertEqual(find([packaged], app: nil), packaged)
        XCTAssertEqual(find(["/fixture/.local/bin/codex"]), "/fixture/.local/bin/codex")
        XCTAssertNil(find([]))
    }
}
