import XCTest
@testable import SlopDeskVideoClient

/// Pins the smart-zoom ⌘0 gate (doc 05 §8): known-unsafe apps (⌘0 ≠ zoom reset) skip the
/// translation; everything else — including the unknowable desktop pane — stays live.
final class PinchZeroPolicyTests: XCTestCase {
    func testXcodeIsUnsafeBrowsersAllowed() {
        XCTAssertFalse(PinchZeroPolicy.allowsReset(appName: "Xcode")) // ⌘0 = toggle Navigator
        XCTAssertTrue(PinchZeroPolicy.allowsReset(appName: "Google Chrome"))
        XCTAssertTrue(PinchZeroPolicy.allowsReset(appName: "Safari"))
    }

    func testEmptyAppNameFailsOpen() {
        // A desktop pane (or a legacy binding) records no app — the client cannot know the
        // frontmost remote app, so the translation stays available.
        XCTAssertTrue(PinchZeroPolicy.allowsReset(appName: ""))
    }

    func testExtraUnsafeParsesAndExtends() {
        let extras = PinchZeroPolicy.extraUnsafe(from: " Sketch , Final Cut Pro,,")
        XCTAssertEqual(extras, ["Sketch", "Final Cut Pro"])
        XCTAssertFalse(PinchZeroPolicy.allowsReset(appName: "Sketch", extraUnsafe: extras))
        XCTAssertTrue(PinchZeroPolicy.allowsReset(appName: "Figma", extraUnsafe: extras))
        XCTAssertEqual(PinchZeroPolicy.extraUnsafe(from: nil), [])
    }
}
