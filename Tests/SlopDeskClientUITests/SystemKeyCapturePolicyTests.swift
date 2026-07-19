// SystemKeyCapturePolicyTests — the PURE immersive-mode capture decision table, exercised headlessly on
// destructured (keyCode, flags, type) values. NEVER instantiates `SystemKeyCaptureController`: a live event
// tap needs Accessibility trust and would swallow the TEST RUNNER's keyboard (the hang-safety rule). Each
// test pins a safety invariant the controller relies on: the always-reachable escape chord, the never-trapped
// Force Quit chord, the everything-else-forwards default (⌘Q included — quitting the remote app is a
// first-class immersive verb), and the flagsChanged isDown mapping.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskClientUI

final class SystemKeyCapturePolicyTests: XCTestCase {
    // Virtual key codes used by the pins (Carbon kVK_* values, mirrored as literals like the policy itself).
    private let keyE: UInt16 = 14
    private let keyQ: UInt16 = 12
    private let keyEscape: UInt16 = 53
    private let keyTab: UInt16 = 48
    private let keySpace: UInt16 = 49
    private let keyF5: UInt16 = 96

    /// ⌃⌥⌘E keyDown disengages — the mandatory escape hatch. The chord itself is `.disengage`, never
    /// `.forwardAndSwallow`: it is a client-side control, typed into neither machine.
    func testEscapeChordDisengages() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyE, flags: [.maskControl, .maskAlternate, .maskCommand], type: .keyDown,
            ),
            .disengage,
        )
    }

    /// Extra flag bits (caps lock, shift, the device-specific left-control bit) never dead-lock the escape
    /// hatch — the chord check is `contains`, not equality. Weakening this traps the user.
    func testEscapeChordSurvivesStrayFlagBits() {
        var flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        flags.insert(.maskAlphaShift)
        flags.insert(.maskShift)
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyE, flags: flags, type: .keyDown),
            .disengage,
        )
    }

    /// An INCOMPLETE escape chord is just a key: ⌃⌘E (no option) and plain E forward like everything else,
    /// and the chord only fires on keyDown (an E keyUp with the modifiers held still forwards).
    func testIncompleteOrKeyUpEscapeChordForwards() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyE, flags: [.maskControl, .maskCommand], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyE, flags: [], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyE, flags: [.maskControl, .maskAlternate, .maskCommand], type: .keyUp,
            ),
            .forwardAndSwallow,
        )
    }

    /// ⌘Q FORWARDS to the host — quitting the remote frontmost app is a first-class immersive verb, and the
    /// local bail-outs stay ⌘⌥Esc (Force Quit) + ⌃⌥⌘E (escape chord). Down and up both forward (the remote
    /// needs the release edge), and the ⌘⇧Q / ⌘⌥Q variants forward too — no Q carve-out survives.
    func testCommandQForwards() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyQ, flags: [.maskCommand], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyQ, flags: [.maskCommand], type: .keyUp),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyQ, flags: [.maskCommand, .maskShift], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyQ, flags: [.maskCommand, .maskAlternate], type: .keyDown),
            .forwardAndSwallow,
        )
    }

    /// SAFETY INVARIANT: ⌘⌥Esc (Force Quit) passes through — the user's recovery path when the app itself
    /// wedges. ⌘⌥⇧Esc (force-quit frontmost) is covered by the same rule; a BARE Esc forwards (the remote
    /// terminal needs it constantly).
    func testCommandOptionEscapePassesThrough() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyEscape, flags: [.maskCommand, .maskAlternate], type: .keyDown,
            ),
            .passThrough,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(
                keyCode: keyEscape, flags: [.maskCommand, .maskAlternate, .maskShift], type: .keyDown,
            ),
            .passThrough,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyEscape, flags: [], type: .keyDown),
            .forwardAndSwallow,
        )
    }

    /// The chords immersive mode EXISTS for all forward-and-swallow: ⌘Tab (app switcher), ⌘Space (Spotlight),
    /// an F-key (F5 — a media key arriving as a standard function key), and a plain letter.
    func testReservedSystemChordsAndPlainKeysForward() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyTab, flags: [.maskCommand], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keySpace, flags: [.maskCommand], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyF5, flags: [.maskSecondaryFn], type: .keyDown),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 0 /* A */, flags: [], type: .keyDown),
            .forwardAndSwallow,
        )
        // keyUps forward too — the remote host needs the release edge or every key sticks.
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: keyTab, flags: [], type: .keyUp),
            .forwardAndSwallow,
        )
    }

    /// flagsChanged for a KNOWN modifier keyCode forwards (the remote mirrors modifier state); an unmapped
    /// keyCode passes through — no mask means no derivable isDown, and forwarding a guess would desync the
    /// remote modifier state.
    func testFlagsChangedDecision() {
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 55 /* ⌘ */, flags: [.maskCommand], type: .flagsChanged),
            .forwardAndSwallow,
        )
        XCTAssertEqual(
            SystemKeyCapturePolicy.decision(keyCode: 0 /* not a modifier */, flags: [], type: .flagsChanged),
            .passThrough,
        )
    }

    /// The flagsChanged isDown mapping: isDown = the changed key's flag bit is NOW SET. Down when the bit
    /// appears, up when it clears — for every mapped modifier key, left and right variants included.
    func testFlagsChangedIsDownMapping() {
        let cases: [(keyCode: UInt16, mask: CGEventFlags)] = [
            (55, .maskCommand), (54, .maskCommand), // ⌘ left/right
            (56, .maskShift), (60, .maskShift), // ⇧ left/right
            (58, .maskAlternate), (61, .maskAlternate), // ⌥ left/right
            (59, .maskControl), (62, .maskControl), // ⌃ left/right
            (57, .maskAlphaShift), // caps lock
            (63, .maskSecondaryFn), // fn
        ]
        for c in cases {
            XCTAssertTrue(
                SystemKeyCapturePolicy.isDown(keyCode: c.keyCode, flags: c.mask, type: .flagsChanged),
                "keyCode \(c.keyCode): bit set means the key went DOWN",
            )
            XCTAssertFalse(
                SystemKeyCapturePolicy.isDown(keyCode: c.keyCode, flags: [], type: .flagsChanged),
                "keyCode \(c.keyCode): bit cleared means the key went UP",
            )
        }
        // Other modifiers still held do not confuse the changed key's own bit derivation.
        XCTAssertTrue(SystemKeyCapturePolicy.isDown(
            keyCode: 55, flags: [.maskCommand, .maskShift], type: .flagsChanged,
        ))
        XCTAssertFalse(SystemKeyCapturePolicy.isDown(
            keyCode: 55, flags: [.maskShift], type: .flagsChanged,
        ))
    }

    /// keyDown/keyUp isDown is the event type itself; an unmapped flagsChanged keyCode reports `false`
    /// (harmless — its decision is `.passThrough`, so it is never forwarded anyway).
    func testKeyEventIsDownMapping() {
        XCTAssertTrue(SystemKeyCapturePolicy.isDown(keyCode: 0, flags: [], type: .keyDown))
        XCTAssertFalse(SystemKeyCapturePolicy.isDown(keyCode: 0, flags: [], type: .keyUp))
        XCTAssertFalse(SystemKeyCapturePolicy.isDown(keyCode: 0, flags: [], type: .flagsChanged))
    }

    /// Event types the policy does not understand (the tap-disabled wake events reach the controller first,
    /// but defensively) are NEVER swallowed — unknown input keeps flowing to macOS.
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
