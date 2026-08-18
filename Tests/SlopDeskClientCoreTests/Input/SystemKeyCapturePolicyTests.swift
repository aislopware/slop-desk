// SystemKeyCapturePolicyTests — the CROSSING behind immersive-mode capture, exercised headlessly on
// destructured (keyCode, flags, type) values. NEVER instantiates `SystemKeyCaptureController`: a live event
// tap needs Accessibility trust and would swallow the TEST RUNNER's keyboard (the hang-safety rule).
//
// What is pinned here is the translation `slopdesk_video::key_capture` cannot see: `CGEventFlags` into the
// wire's six-bit mask and back, and `CGEventType` into its case index. That translation is the one way this
// side can break a rule the crate gets right — a mask bit wired to the wrong flag would make the escape
// chord unreachable while every Rust test still passed — so the two safety chords are pinned end to end
// through it, and the rest of the table (which chords forward, how a modifier edge derives its direction)
// is tested once, in the crate that owns it.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskClientCore

final class SystemKeyCapturePolicyTests: XCTestCase {
    private let keyE: UInt16 = 14
    private let keyEscape: UInt16 = 53

    /// SAFETY INVARIANT: ⌃⌥⌘E disengages, and no stray bit can dead-lock the hatch. Reaching this through
    /// the flag translation is the point — three flags mapped to the wrong bits would land somewhere else.
    func testTheEscapeChordSurvivesTheTranslationAndAnyStrayBit() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyE, flags: [.maskControl, .maskAlternate, .maskCommand], type: .keyDown,
            ),
            .disengage,
        )
        var stuck: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        stuck.insert(.maskAlphaShift)
        stuck.insert(.maskShift)
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyE, flags: stuck, type: .keyDown),
            .disengage,
        )
    }

    /// SAFETY INVARIANT: ⌘⌥Esc reaches macOS — the recovery path when the app itself wedges — while a bare
    /// Esc goes to the remote terminal that needs it constantly.
    func testForceQuitPassesThroughAndABareEscapeDoesNot() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyEscape, flags: [.maskCommand, .maskAlternate], type: .keyDown,
            ),
            .passThrough,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyEscape, flags: [], type: .keyDown),
            .forwardAndSwallow,
        )
    }

    /// Every flag the rules read survives the round trip: each modifier keyCode's own flag reads as a press
    /// and its absence as a release, which only holds if that flag mapped to the bit the crate names. A
    /// swapped pair would still answer `true` for one key and silently invert the other.
    func testEachFlagMapsToTheBitItsOwnKeycodeDrives() {
        let modifiers: [(keyCode: UInt16, mask: CGEventFlags)] = [
            (55, .maskCommand), (54, .maskCommand),
            (56, .maskShift), (60, .maskShift),
            (58, .maskAlternate), (61, .maskAlternate),
            (59, .maskControl), (62, .maskControl),
            (57, .maskAlphaShift),
            (63, .maskSecondaryFn),
        ]
        for modifier in modifiers {
            XCTAssertEqual(
                SystemKeyCapturePolicy.modifierMask(for: modifier.keyCode), modifier.mask,
                "keyCode \(modifier.keyCode) drives its own flag, back in Apple's constant",
            )
            XCTAssertTrue(
                SystemKeyCapturePolicy.isDown(
                    keyCode: modifier.keyCode, flags: modifier.mask, type: .flagsChanged,
                ),
                "keyCode \(modifier.keyCode): its bit set means the key went DOWN",
            )
            XCTAssertFalse(
                SystemKeyCapturePolicy.isDown(keyCode: modifier.keyCode, flags: [], type: .flagsChanged),
                "keyCode \(modifier.keyCode): its bit cleared means the key went UP",
            )
        }
        XCTAssertNil(SystemKeyCapturePolicy.modifierMask(for: keyE), "a letter drives no flag")
    }

    /// The three event types the policy has rules for reach their own case index — a `keyUp` read as a
    /// `keyDown` would report every release as a press and stick every key on the remote machine.
    func testEachEventTypeReachesItsOwnCaseIndex() {
        XCTAssertTrue(SystemKeyCapturePolicy.isDown(keyCode: 0, flags: [], type: .keyDown))
        XCTAssertFalse(SystemKeyCapturePolicy.isDown(keyCode: 0, flags: [], type: .keyUp))
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 55, flags: [.maskCommand], type: .flagsChanged),
            .forwardAndSwallow,
        )
    }

    /// Event types with no rule — the tap-disabled wakes the controller handles first, and anything else —
    /// are NEVER swallowed. Swallowing the unknown is what turns an engaged pane into a keyboard trap.
    func testUnknownEventTypesPassThrough() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 0, flags: [], type: .tapDisabledByTimeout),
            .passThrough,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 0, flags: [], type: .null),
            .passThrough,
        )
    }
}
#endif
