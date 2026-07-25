// SettingsEscapePolicyTests — pins Esc-closes-Settings and the two cases that must NOT close it.
//
// The macOS Settings surface is a stock `Settings` scene `NSWindow`, which AppKit gives no Esc behaviour — ⌘,
// opened a window the keyboard could not close. `SettingsEscapeDismisser` fixes that with a window-scoped
// key monitor whose decision is the pure `SettingsEscapePolicy` pinned here (the AppKit half — first-responder
// probing, `performClose`, monitor scoping — is code-reviewed, not unit-tested: an `NSWindow` in a unit test is
// exactly the GUI-in-tests hazard CLAUDE.md bans).
//
// The two pass-through cases are the REGRESSION guards, not decoration:
//   * a MODIFIED Esc is somebody else's chord (⌥Esc is macOS Speak Selection) — never a plain dismiss.
//   * a Key Bindings row RECORDING a chord already owns Esc as "cancel the capture"
//     (`KeybindingCapture.cancel`), and two local `.keyDown` monitors racing for it would otherwise resolve in
//     AppKit's undocumented install order — so the dismiss stands down while the recorder is armed.
//
// TEXT FIELDS DELIBERATELY DO NOT VETO, and that is the HW-verified part: two earlier designs let a focused
// field keep Esc (pass-through, then resign-first-responder-then-close) and BOTH dead-ended on hardware —
// SwiftUI's `.searchable` pill neither consumes Esc nor gives up first responder, so Esc never closed the
// window at all. `testEscapeClosesEvenWhileTypingInAField` pins the fix against a well-meaning revert.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

final class SettingsEscapePolicyTests: XCTestCase {
    /// The Esc keyCode is the physical key AppKit reports, independently asserted (not read back off the
    /// constant) so a typo'd redefinition fails here rather than silently making Esc inert.
    func testEscapeKeyCodeIs53() {
        XCTAssertEqual(SettingsEscapePolicy.escapeKeyCode, 53)
    }

    /// The whole point: a bare Esc closes the Settings window.
    func testBareEscapeClosesTheWindow() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, hasModifiers: false, isCapturingChord: false),
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
            SettingsEscapePolicy.decide(keyCode: 53, hasModifiers: false, isCapturingChord: false),
            .closeWindow,
            "a focused field must not be able to make Esc inert — that WAS the reported bug",
        )
    }

    /// While a Key Bindings row is recording, Esc means "cancel the capture" — the one surface that outranks
    /// the dismiss. Pinned so the outcome does not depend on which local key monitor AppKit happens to call
    /// first (an order it does not document).
    func testEscapeWhileRecordingAChordPassesThroughToTheRecorder() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, hasModifiers: false, isCapturingChord: true),
            .passThrough,
        )
    }

    /// A modified Esc (⌥Esc / ⌘Esc / ⌃Esc / ⇧Esc) is another binding's chord, never a dismiss.
    func testModifiedEscapePassesThrough() {
        XCTAssertEqual(
            SettingsEscapePolicy.decide(keyCode: 53, hasModifiers: true, isCapturingChord: false),
            .passThrough,
        )
    }

    /// Every non-Esc key is untouched — the monitor must not swallow typing. Spot-checked across the
    /// letter / arrow / Return / Tab keyCodes a Settings window actually receives.
    func testNonEscapeKeysPassThrough() {
        for keyCode: UInt16 in [0, 12, 36, 48, 49, 51, 123, 125] {
            XCTAssertEqual(
                SettingsEscapePolicy.decide(keyCode: keyCode, hasModifiers: false, isCapturingChord: false),
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
