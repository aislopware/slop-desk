import SwiftUI
import XCTest
@testable import SlopDeskPhoneUI

/// Pins the floating cards' auto-repeat policy (``OverlayKeyRepeat``): a held ARROW walks the list, and a
/// held chord does NOT re-fire. The second half is what makes the whitelist necessary — the pickers route
/// their whole keyboard through one `.onKeyPress` handler, so subscribing to `.repeat` wholesale would let a
/// held ⌘3 open the third row every 30ms.
final class OverlayKeyRepeatTests: XCTestCase {
    // MARK: - Movement keys walk while held

    func testArrowsRepeatWhileHeld() {
        XCTAssertTrue(OverlayKeyRepeat.repeatsWhileHeld(.upArrow))
        XCTAssertTrue(OverlayKeyRepeat.repeatsWhileHeld(.downArrow))
        XCTAssertTrue(OverlayKeyRepeat.repeatsWhileHeld(.pageUp))
        XCTAssertTrue(OverlayKeyRepeat.repeatsWhileHeld(.pageDown))
    }

    func testHeldDownArrowIsAdmittedOnEveryRepeat() {
        XCTAssertTrue(OverlayKeyRepeat.admits(key: .downArrow, isRepeat: false))
        XCTAssertTrue(OverlayKeyRepeat.admits(key: .downArrow, isRepeat: true))
    }

    // MARK: - Everything else acts once per press

    func testChordsAndOneShotsDoNotRepeat() {
        for key: KeyEquivalent in [KeyEquivalent("k"), KeyEquivalent("3"), .tab, .return, .escape, .home, .end] {
            XCTAssertFalse(
                OverlayKeyRepeat.repeatsWhileHeld(key),
                "\(key.character) must act once per press, not on every auto-repeat",
            )
            // The FIRST press still acts — the whitelist gates the repeats only.
            XCTAssertTrue(OverlayKeyRepeat.admits(key: key, isRepeat: false))
            XCTAssertFalse(OverlayKeyRepeat.admits(key: key, isRepeat: true))
        }
    }

    // MARK: - The subscription itself

    func testPhasesIncludeBothDownAndRepeat() {
        // A handler that subscribed to `.down` alone is exactly the bug: one move per physical press.
        XCTAssertTrue(OverlayKeyRepeat.phases.contains(.down))
        XCTAssertTrue(OverlayKeyRepeat.phases.contains(.repeat))
        XCTAssertFalse(OverlayKeyRepeat.phases.contains(.up))
    }
}
