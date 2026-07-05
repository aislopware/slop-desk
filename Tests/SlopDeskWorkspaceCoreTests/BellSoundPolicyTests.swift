import Foundation
import SlopDeskClient
import XCTest
@testable import SlopDeskWorkspaceCore

/// E14/K10: the PURE bell + error-exit sound decisions. `UN`-free + AppKit-free, asserted against an
/// independent expectation (never the output's derivation). Mirrors `CommandNotificationPolicyTests`.
final class BellSoundPolicyTests: XCTestCase {
    /// A `BEL` rings iff "Sound — Shell Controlled" is on — the toggle IS the decision.
    func testBellGatedBySoundShellControlled() {
        XCTAssertTrue(BellPolicy.shouldBeep(soundShellControlled: true))
        XCTAssertFalse(BellPolicy.shouldBeep(soundShellControlled: false))
    }

    /// "Sound on Error Exit" beeps only when the toggle is ON AND the exit is non-zero.
    func testErrorSoundGatedByToggleAndNonZeroExit() {
        // Toggle OFF → never beeps, even on a failure.
        XCTAssertFalse(ErrorSoundPolicy.shouldBeep(exit: 1, soundOnErrorEnabled: false))
        XCTAssertFalse(ErrorSoundPolicy.shouldBeep(exit: 0, soundOnErrorEnabled: false))
        // Toggle ON → beeps on a non-zero exit, silent on a clean exit.
        XCTAssertTrue(ErrorSoundPolicy.shouldBeep(exit: 1, soundOnErrorEnabled: true))
        XCTAssertTrue(ErrorSoundPolicy.shouldBeep(exit: 130, soundOnErrorEnabled: true))
        XCTAssertTrue(ErrorSoundPolicy.shouldBeep(exit: -1, soundOnErrorEnabled: true))
        XCTAssertFalse(ErrorSoundPolicy.shouldBeep(exit: 0, soundOnErrorEnabled: true))
    }

    /// `exit == nil` (a completion carrying no code) is a clean exit → no error beep, even with the toggle on.
    func testErrorSoundNilExitTreatedAsClean() {
        XCTAssertFalse(ErrorSoundPolicy.shouldBeep(exit: nil, soundOnErrorEnabled: true))
    }
}

/// E14/K10 WIRING: the bell + error-exit beeps actuate through ``TerminalViewModel``'s existing injected
/// `beep` seam, gated by the pure policies. Revert-to-confirm-fail: before the wiring the `.bell` /
/// `.commandStatus(.idle)` arms never rang the seam, so these counts would all be 0.
@MainActor
final class BellSoundWiringTests: XCTestCase {
    private let touched = [SettingsKey.soundShellControlled, SettingsKey.soundOnErrorExit]
    override func setUp() { touched.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { touched.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    /// A `.bell` rings the beep seam when Sound — Shell Controlled is on (the default).
    func testBellBeepsWhenSoundShellControlledOn() {
        let model = TerminalViewModel()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.handle(.bell)
        XCTAssertEqual(beeps, 1, "a BEL rings once with Sound — Shell Controlled ON (default)")
        XCTAssertTrue(model.bellPending, "the bell-pending flag is still set (audio is additive to it)")
    }

    /// With Sound — Shell Controlled OFF, a `.bell` does NOT ring (the toggle gates the beep).
    func testBellSilentWhenSoundShellControlledOff() {
        UserDefaults.standard.set(false, forKey: SettingsKey.soundShellControlled)
        let model = TerminalViewModel()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.handle(.bell)
        XCTAssertEqual(beeps, 0, "a BEL is silent with Sound — Shell Controlled OFF")
    }

    /// A non-zero `.commandStatus(.idle)` rings the beep seam ONLY when Sound on Error Exit is on.
    func testErrorExitBeepsOnlyWhenEnabled() {
        // Default OFF → a failing command does not beep.
        let off = TerminalViewModel()
        var offBeeps = 0
        off.beep = { offBeeps += 1 }
        off.handle(.commandStatus(.idle(exitCode: 1, durationMS: 0)))
        XCTAssertEqual(offBeeps, 0, "Sound on Error Exit is OFF by default → no beep")

        // Toggle ON → a non-zero exit beeps; a clean exit stays silent.
        UserDefaults.standard.set(true, forKey: SettingsKey.soundOnErrorExit)
        let on = TerminalViewModel()
        var onBeeps = 0
        on.beep = { onBeeps += 1 }
        on.handle(.commandStatus(.idle(exitCode: 2, durationMS: 0)))
        XCTAssertEqual(onBeeps, 1, "a non-zero exit beeps with Sound on Error Exit ON")
        on.handle(.commandStatus(.idle(exitCode: 0, durationMS: 0)))
        XCTAssertEqual(onBeeps, 1, "a clean exit never beeps (still 1)")
    }
}
