// CwdDisplayTests (Batch-5b follow-up) — pins the pure home-abbreviation the command-palette WORKING
// DIRECTORY pill uses (`CwdDisplay.abbreviate`). `command-palette.png` renders the pill as `~/Workplace/myproject/`
// — a `/Users/<name>` home prefix collapsed to `~`, plus a trailing directory slash — while slopdesk
// receives the RAW remote-host path from the `cwd()` RPC. The helper is SwiftUI/AppKit-free so it runs
// headlessly on the macOS `swift test` host. Each case asserts against an INDEPENDENT expected literal (not
// the helper's own derivation), so dropping the abbreviation (or the trailing-slash marker) fails the build.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

final class CwdDisplayTests: XCTestCase {
    // MARK: Home-prefix collapse (the command-palette.png case)

    func testCollapsesMacOSHomePrefixToTildeWithTrailingSlash() {
        // The screenshot case: /Users/abner/Workplace/myproject -> ~/Workplace/myproject/
        XCTAssertEqual(CwdDisplay.abbreviate("/Users/abner/Workplace/myproject"), "~/Workplace/myproject/")
    }

    func testCollapsesLinuxHomePrefixToTilde() {
        XCTAssertEqual(CwdDisplay.abbreviate("/home/abner/src/proj"), "~/src/proj/")
    }

    func testExactHomeDirCollapsesToBareTilde() {
        // The cwd IS the home dir — no remainder, just `~` (then the directory slash).
        XCTAssertEqual(CwdDisplay.abbreviate("/Users/abner"), "~/")
        XCTAssertEqual(CwdDisplay.abbreviate("/home/abner"), "~/")
    }

    // MARK: Non-home paths keep their path, gain the directory slash

    func testNonHomePathKeepsPathAndGainsTrailingSlash() {
        XCTAssertEqual(CwdDisplay.abbreviate("/etc"), "/etc/")
        XCTAssertEqual(CwdDisplay.abbreviate("/var/log/system"), "/var/log/system/")
    }

    func testBareHomeRootWithoutNameSegmentIsNotAHome() {
        // `/Users` alone has no <name> segment, so it is NOT collapsed — just a normal dir.
        XCTAssertEqual(CwdDisplay.abbreviate("/Users"), "/Users/")
        XCTAssertEqual(CwdDisplay.abbreviate("/home"), "/home/")
    }

    // MARK: Edge cases handled sanely

    func testFilesystemRootStaysRoot() {
        XCTAssertEqual(CwdDisplay.abbreviate("/"), "/")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(CwdDisplay.abbreviate(""), "")
    }

    func testAlreadyTildeRootedKeepsTildeAndGainsSlash() {
        XCTAssertEqual(CwdDisplay.abbreviate("~"), "~/")
        XCTAssertEqual(CwdDisplay.abbreviate("~/Workplace/myproject"), "~/Workplace/myproject/")
    }

    func testTrailingSlashIsNotDoubled() {
        XCTAssertEqual(CwdDisplay.abbreviate("/Users/abner/Workplace/myproject/"), "~/Workplace/myproject/")
        XCTAssertEqual(CwdDisplay.abbreviate("/etc/"), "/etc/")
    }

    func testNameLikePrefixIsNotMistakenForHomeBoundary() {
        // Boundary discipline: `/Users/abner` is the home, so a sibling whose name shares a prefix still
        // collapses correctly at the segment boundary (no `/Users/abnerXYZ` over-match leaking the name).
        XCTAssertEqual(CwdDisplay.abbreviate("/Users/abnerson/code"), "~/code/")
    }
}
#endif
