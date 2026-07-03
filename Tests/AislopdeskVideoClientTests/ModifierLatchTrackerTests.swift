import XCTest
@testable import AislopdeskVideoClient

/// PURE modifier-latch tracking. Regression: a modifier forwarded to the host as "down" whose release
/// `flagsChanged` is swallowed by a focus change stays latched in the host's shared event source, so a
/// later plain scroll rides ⌘ (zoom). The tracker lets the view synthesize the missing key-ups on blur.
final class ModifierLatchTrackerTests: XCTestCase {
    func testStartsEmpty() {
        let t = ModifierLatchTracker()
        XCTAssertTrue(t.isEmpty)
        XCTAssertFalse(t.isDown(55))
    }

    func testNoteDownThenUpClears() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 55, down: true) // ⌘ left down
        XCTAssertTrue(t.isDown(55))
        XCTAssertFalse(t.isEmpty)
        t.note(keyCode: 55, down: false) // ⌘ left up
        XCTAssertFalse(t.isDown(55))
        XCTAssertTrue(t.isEmpty)
    }

    // The core fix: a ⌘ that went down but whose release was never seen (focus moved) must be drained so
    // the caller can emit a host key-up — otherwise the host latches ⌘ and scroll becomes zoom.
    func testDrainReturnsLatchedAndClears() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 55, down: true) // ⌘
        t.note(keyCode: 58, down: true) // ⌥
        let released = t.drainForRelease()
        XCTAssertEqual(released, [55, 58], "ascending, deterministic order")
        XCTAssertTrue(t.isEmpty, "draining clears the tracker so a re-forward doesn't double-count")
        XCTAssertTrue(t.drainForRelease().isEmpty, "a second drain finds nothing latched")
    }

    func testDrainIgnoresAlreadyReleasedModifiers() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 56, down: true) // ⇧ down
        t.note(keyCode: 56, down: false) // ⇧ up (release seen normally)
        t.note(keyCode: 59, down: true) // ⌃ down, no release
        XCTAssertEqual(t.drainForRelease(), [59], "only the still-held ⌃ needs a synthesized release")
    }

    /// C5 BUG A: Caps Lock (keyCode 57) is a TOGGLE, not a held key — latching it makes the blur-time
    /// synthesized "release" (a bare key-up CGEvent on virtualKey 57) TOGGLE the host's Caps state, so
    /// every focus/blur cycle of a GUI pane with local Caps on flipped remote Caps. The tracker must
    /// never latch it (its genuine `flagsChanged` edges still forward 1:1 while focused).
    func testCapsLockEdgesAreNeverLatched() {
        var t = ModifierLatchTracker()
        t.note(keyCode: 57, down: true) // ⇪ ON edge — must NOT latch
        XCTAssertFalse(t.isDown(57), "Caps Lock is a toggle — never tracked as held")
        XCTAssertTrue(t.isEmpty)
        t.note(keyCode: 55, down: true) // ⌘ down (a real held modifier)
        t.note(keyCode: 57, down: true) // ⇪ again, mixed in
        XCTAssertEqual(t.drainForRelease(), [55], "a blur release list never contains keyCode 57")
    }
}
