// SettingsEscapePolicyTests — pins the Esc-closes-Settings CROSSING.
//
// The rule is `slopdesk_video::escape_monitor`: which key, which modifiers disqualify it, and that a chord
// recorder outranks the dismiss. What only this side can get wrong is the translation — the AppKit modifier
// flags folded into the wire's six-bit mask, and the door's `Bool` turned back into the two-case decision the
// monitor acts on. (The AppKit half — first-responder probing, `performClose`, monitor scoping — is
// code-reviewed, not unit-tested: an `NSWindow` in a unit test is exactly the GUI-in-tests hazard CLAUDE.md
// bans.)
//
// TEXT FIELDS DELIBERATELY DO NOT VETO, and that is the HW-verified part: two earlier designs let a focused
// field keep Esc (pass-through, then resign-first-responder-then-close) and BOTH dead-ended on hardware —
// SwiftUI's `.searchable` pill neither consumes Esc nor gives up first responder, so Esc never closed the
// window at all. `testEscapeClosesEvenWhileTypingInAField` pins the fix against a well-meaning revert.

#if canImport(SwiftUI)
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskClientUI

final class SettingsEscapePolicyTests: XCTestCase {
    /// The whole point, and the keycode the monitor reads off an `NSEvent`: a bare Esc closes the window.
    func testBareEscapeClosesTheWindow() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, modifierMask: 0, isCapturingChord: false),
            .closeWindow,
        )
    }

    /// Esc closes even while a text field has focus. This is the HW-verified decision, not an oversight: both
    /// designs that let a focused field keep Esc dead-ended on hardware, because SwiftUI's `.searchable` pill
    /// neither consumes Esc nor releases first responder — so Esc never closed the window at all. Nothing is
    /// lost: every Settings field commits continuously (on change / via `DraftCommitDebouncer`), and the AppKit
    /// side ends field editing before closing. A revert to field-vetoes-Esc fails here.
    func testEscapeClosesEvenWhileTypingInAField() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, modifierMask: 0, isCapturingChord: false),
            .closeWindow,
            "a focused field must not be able to make Esc inert — that WAS the reported bug",
        )
    }

    /// While a Key Bindings row is recording, Esc means "cancel the capture" — the one surface that outranks
    /// the dismiss. Pinned so the outcome does not depend on which local key monitor AppKit happens to call
    /// first (an order it does not document).
    func testEscapeWhileRecordingAChordPassesThroughToTheRecorder() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, modifierMask: 0, isCapturingChord: true),
            .passThrough,
        )
    }

    /// The mask crosses in the wire's own bits: each chord modifier disqualifies the dismiss, and caps
    /// lock — a state the user is in rather than a chord they typed — does not. A mistranslated flag would
    /// show here as a window that either never closes or closes on somebody else's binding.
    func testTheModifierMaskCrossesInTheWiresOwnBits() {
        for modifier: InputModifiers in [.command, .option, .control, .shift] {
            XCTAssertEqual(
                SettingsEscapePolicy.decide(keyCode: 53, modifierMask: modifier.rawValue, isCapturingChord: false),
                .passThrough,
                "a modified Esc is another binding's chord",
            )
        }
        XCTAssertEqual(
            SettingsEscapePolicy.decide(
                keyCode: 53,
                modifierMask: InputModifiers([.capsLock, .function]).rawValue,
                isCapturingChord: false,
            ),
            .closeWindow,
            "a stuck caps lock must not make the window unclosable",
        )
    }

    /// Every non-Esc key is untouched — the monitor must not swallow typing. Spot-checked across the
    /// letter / arrow / Return / Tab keyCodes a Settings window actually receives.
    func testNonEscapeKeysPassThrough() {
        for keyCode: UInt16 in [0, 12, 36, 48, 49, 51, 123, 125] {
            XCTAssertEqual(
                SettingsEscapePolicy.decide(keyCode: keyCode, modifierMask: 0, isCapturingChord: false),
                .passThrough,
                "keyCode \(keyCode) must not close the Settings window",
            )
        }
    }

    /// The recorder's claim starts DISARMED — a fresh process must not have Esc disowned by a flag nobody set.
    @MainActor
    func testChordCaptureStartsDisarmed() {
        XCTAssertFalse(SettingsChordCapture.shared.isCapturing)
    }
}
#endif
