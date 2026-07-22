#if os(macOS)
import XCTest
@testable import SlopDeskVideoHost

/// ``HostPrivacyBlank`` engage/idempotence/teardown logic + the pure input-swallow policy — driven
/// entirely on FAKE seams (no real CGDisplayGammaTable / CGEventTap side effects), honouring the
/// hang-safety rule.
final class HostPrivacyBlankTests: XCTestCase {
    /// A recording fake for the four seams.
    private final class Fakes: @unchecked Sendable {
        var blanks: [UInt32] = []
        var restores: [UInt32] = []
        var tapInstalls = 0
        var tapRemoves = 0
        var blankSucceeds = true
        var tapSucceeds = true
    }

    private func make(displayID: UInt32 = 7, _ f: Fakes) -> HostPrivacyBlank {
        HostPrivacyBlank(
            displayID: displayID,
            blank: { id in f.blanks.append(id)
                return f.blankSucceeds
            },
            restore: { id in f.restores.append(id) },
            installTap: { f.tapInstalls += 1
                return f.tapSucceeds
            },
            removeTap: { f.tapRemoves += 1 },
        )
    }

    func testEnableBlanksTheTargetDisplayAndInstallsTheTap() {
        let f = Fakes()
        let p = make(displayID: 42, f)
        XCTAssertTrue(p.setEnabled(true))
        XCTAssertTrue(p.isEngaged)
        XCTAssertEqual(f.blanks, [42], "the SESSION's display is blacked")
        XCTAssertEqual(f.tapInstalls, 1)
    }

    func testEnableIsIdempotent() {
        let f = Fakes()
        let p = make(f)
        p.setEnabled(true)
        p.setEnabled(true) // the per-session re-assert after a re-hello
        XCTAssertEqual(f.blanks.count, 1, "a re-sent ON does not re-blank")
        XCTAssertEqual(f.tapInstalls, 1)
    }

    func testDisableRestoresGammaAndRemovesTap() {
        let f = Fakes()
        let p = make(displayID: 9, f)
        p.setEnabled(true)
        XCTAssertFalse(p.setEnabled(false))
        XCTAssertFalse(p.isEngaged)
        XCTAssertEqual(f.restores, [9])
        XCTAssertEqual(f.tapRemoves, 1)
        p.setEnabled(false) // idempotent OFF
        XCTAssertEqual(f.restores.count, 1)
    }

    /// A gamma-blank failure leaves the controller DISENGAGED (the client re-sends and retries) and
    /// never installs the tap — no half-engaged "input dead but screen visible" state.
    func testGammaFailureStaysDisengaged() {
        let f = Fakes()
        f.blankSucceeds = false
        let p = make(f)
        XCTAssertFalse(p.setEnabled(true))
        XCTAssertFalse(p.isEngaged)
        XCTAssertEqual(f.tapInstalls, 0, "no tap when the screen never went dark")
    }

    /// An absent tap (no Accessibility grant) still leaves the SCREEN dark — the blank stands even
    /// though local input is not swallowed.
    func testAbsentTapStillEngagesTheBlank() {
        let f = Fakes()
        f.tapSucceeds = false
        let p = make(f)
        XCTAssertTrue(p.setEnabled(true))
        XCTAssertTrue(p.isEngaged, "the dark screen is the primary effect")
    }

    /// `disengage()` (session end / deinit) restores unconditionally — a dropped remote must never
    /// strand the host dark.
    func testDisengageRestoresFromEngaged() {
        let f = Fakes()
        let p = make(displayID: 3, f)
        p.setEnabled(true)
        p.disengage()
        XCTAssertFalse(p.isEngaged)
        XCTAssertEqual(f.restores, [3])
        XCTAssertEqual(f.tapRemoves, 1)
    }

    // MARK: The pure input-swallow policy

    func testLocalInputSwallowPolicy() {
        // Disengaged: everything passes.
        XCTAssertTrue(HostPrivacyBlank.localInputShouldPass(engaged: false, isInjectedByRemote: false))
        // Engaged: physical local input is swallowed…
        XCTAssertFalse(HostPrivacyBlank.localInputShouldPass(engaged: true, isInjectedByRemote: false))
        // …but the remote operator's own injected input passes.
        XCTAssertTrue(HostPrivacyBlank.localInputShouldPass(engaged: true, isInjectedByRemote: true))
    }
}
#endif
