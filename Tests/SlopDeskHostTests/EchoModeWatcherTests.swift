import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The PURE ``EchoModeDetector`` core (no real PTY / `tcgetattr`; the `PTYEchoProbe` OS
/// shim is compiled + code-reviewed only). Drives the detector with INJECTED `echoOn` bools and
/// asserts the type-31 ``WireMessage/inputEcho`` emit decisions: edge-only emission, the echo-on
/// anchor (silent steady state), dedupe, and the no-echo → restore cycle.
///
/// REVERT-TO-FAIL: a detector that emitted on every sample (no edge anchor) would fail
/// `testSteadyEchoOnEmitsNothing` / `testRepeatedSameStateIsDeduped`.
final class EchoModeWatcherTests: XCTestCase {
    // MARK: echo-on anchor (silent steady state)

    func testSteadyEchoOnEmitsNothing() {
        var d = EchoModeDetector()
        // The canonical default is echo-on; a stream of echo-on samples must emit NOTHING (no
        // redundant initial `inputEcho(true)`) — the CONTROL stream stays byte-identical when no
        // no-echo prompt ever appears.
        XCTAssertNil(d.sample(echoOn: true))
        XCTAssertNil(d.sample(echoOn: true))
        XCTAssertNil(d.sample(echoOn: true))
        XCTAssertEqual(d.currentEcho, true)
    }

    // MARK: the no-echo edge

    func testEchoClearedEmitsDisabled() {
        var d = EchoModeDetector()
        let e = d.sample(echoOn: false)
        XCTAssertEqual(e, .inputEcho(enabled: false), "clearing ECHO (a password prompt) emits inputEcho(false)")
        XCTAssertEqual(d.currentEcho, false)
    }

    func testEchoClearedFromTheVeryFirstSample() {
        // A no-echo prompt that appears before any echo-on sample still emits (anchor is echo-on,
        // first sample is false → an edge).
        var d = EchoModeDetector()
        XCTAssertEqual(d.sample(echoOn: false), .inputEcho(enabled: false))
    }

    // MARK: dedupe — an unchanged state is not re-emitted

    func testRepeatedSameStateIsDeduped() {
        var d = EchoModeDetector()
        _ = d.sample(echoOn: false) // emits disabled
        XCTAssertNil(d.sample(echoOn: false), "an unchanged no-echo state must not re-emit (dedupe)")
        XCTAssertNil(d.sample(echoOn: false))
    }

    // MARK: the restore edge

    func testEchoRestoredEmitsEnabled() {
        var d = EchoModeDetector()
        _ = d.sample(echoOn: false) // → disabled
        let e = d.sample(echoOn: true)
        XCTAssertEqual(e, .inputEcho(enabled: true), "restoring ECHO (prompt done) emits inputEcho(true)")
        XCTAssertEqual(d.currentEcho, true)
    }

    // MARK: the full password-prompt cycle

    func testPasswordPromptCycleEmitsExactlyTwoEdges() {
        var d = EchoModeDetector()
        var emitted: [WireMessage] = []
        // echo-on … echo-on (typing the command), then sudo clears ECHO, the user types the password
        // (still no-echo), then ECHO restores after Enter.
        for echoOn in [true, true, false, false, false, true, true] {
            if let m = d.sample(echoOn: echoOn) { emitted.append(m) }
        }
        XCTAssertEqual(
            emitted,
            [.inputEcho(enabled: false), .inputEcho(enabled: true)],
            "exactly one disabled edge and one restore edge over a whole prompt cycle",
        )
    }

    // MARK: PTYEchoProbe.echoOn — ECHO-vs-line-editor discrimination (the live "pill on a normal

    // prompt" fix). REVERT-TO-FAIL: an ECHO-only probe (`return echoBitSet`) fails
    // `testLineEditorRawPromptReadsEchoOn` — at a zsh/starship `zle` prompt ECHO is cleared, so the
    // old probe reported no-echo and latched the Secure-Input pill on an ordinary prompt.

    func testLineEditorRawPromptReadsEchoOn() {
        // zsh `zle` / bash readline / a full-screen TUI: ECHO cleared AND ICANON cleared (raw editing,
        // the editor does its own echo). This is the NORMAL interactive steady state — it must read
        // echo-ON so the pill does NOT light on a plain prompt.
        XCTAssertTrue(PTYEchoProbe.echoOn(echoBitSet: false, canonicalBitSet: false))
    }

    func testHiddenPasswordPromptReadsNoEcho() {
        // sudo / ssh / getpass / `read -s`: ECHO cleared but the line stays CANONICAL (ICANON set) —
        // a genuine hidden-password prompt. This is the ONLY case that reports no-echo (→ pill on).
        XCTAssertFalse(PTYEchoProbe.echoOn(echoBitSet: false, canonicalBitSet: true))
    }

    func testCookedChildReadsEchoOn() {
        // A normal cooked foreground child (`cat`): ECHO set, canonical — plainly echo-on, no pill.
        XCTAssertTrue(PTYEchoProbe.echoOn(echoBitSet: true, canonicalBitSet: true))
    }

    func testRawEchoSetReadsEchoOn() {
        // ECHO set but raw (ICANON cleared) — not a hidden-password prompt; echo-on, no pill.
        XCTAssertTrue(PTYEchoProbe.echoOn(echoBitSet: true, canonicalBitSet: false))
    }

    // MARK: explicit initial anchor

    func testInitialEchoOffAnchorIsSilentOnEchoOff() {
        // If the PTY starts in raw/no-echo mode, an injected anchor keeps the detector silent until
        // ECHO is RESTORED (so a raw-mode pane does not spuriously emit on its first sample).
        var d = EchoModeDetector(initialEcho: false)
        XCTAssertNil(d.sample(echoOn: false))
        XCTAssertEqual(d.sample(echoOn: true), .inputEcho(enabled: true))
    }
}
