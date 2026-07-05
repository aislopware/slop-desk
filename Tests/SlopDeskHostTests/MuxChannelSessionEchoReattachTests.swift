import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// E17 / ES-E17-4 — AUTO Secure Keyboard Entry must survive a reconnect/reattach while a no-echo password
/// prompt is up. The host's ``EchoModeDetector`` is edge-triggered, and the client resets `hostNoEcho = false`
/// on reconnect, so without a forced re-emit a prompt that spans the reattach would leave the client's
/// `EnableSecureEventInput` DISENGAGED (keystrokes unprotected). ``MuxChannelSession/reestablishEchoOnReattach``
/// (called from ``rebindRelay``) re-anchors the detector and re-emits the CURRENT echo truth.
///
/// Driven WITHOUT a PTY or running relay via the echo seams (`PTYEchoProbe` is compiled-only per the
/// hang-safety rule; the injected `echoOn` stands in for its `tcgetattr`).
///
/// REVERT-TO-FAIL: removing the re-anchor (`echoDetector = EchoModeDetector(initialEcho: true)`) inside
/// `reestablishEchoOnReattach` collapses it to a no-op re-fold of the unchanged no-echo state →
/// `testReattachReemitsNoEchoTruthAcrossControlQueueClear` gets `nil` and fails.
final class MuxChannelSessionEchoReattachTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; echo driven via injected seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    func testReattachReemitsNoEchoTruthAcrossControlQueueClear() {
        let session = makeSession()

        // C3 warm-up: the shell is at a normal echo-on prompt first. The connect-time path honors a
        // no-echo edge only AFTER a confirmed echo-ON sample, so establish that baseline before the
        // sudo/ssh prompt appears (echo-on folds to nothing — the steady state is silent).
        session.foldEchoSampleForTesting(echoOn: true)
        XCTAssertNil(session.takeControlBatchForTesting(), "a confirmed echo-on baseline emits nothing")

        // A sudo/ssh password prompt appears: ECHO clears → exactly one type-31 inputEcho(false) is queued.
        session.foldEchoSampleForTesting(echoOn: false)
        XCTAssertEqual(
            session.takeControlBatchForTesting(), [.inputEcho(enabled: false)],
            "a no-echo prompt emits one inputEcho(false)",
        )
        // Steady state while the password is still being typed — the edge-triggered detector dedupes.
        session.foldEchoSampleForTesting(echoOn: false)
        XCTAssertNil(session.takeControlBatchForTesting(), "an unchanged no-echo state is not re-emitted")

        // ── A reconnect/reattach happens WHILE the prompt is still up. `rebindRelay` cleared `controlOut`
        //    and the client reset `hostNoEcho = false`. The raw edge-triggered detector would stay silent here
        //    (proven by the dedupe assertion above) — the bug. The reattach re-establishment must re-emit. ──
        session.reestablishEchoOnReattachForTesting(echoOn: false)
        XCTAssertEqual(
            session.takeControlBatchForTesting(), [.inputEcho(enabled: false)],
            "reattach re-anchors + re-emits the current no-echo truth so the client re-engages secure input",
        )
    }

    /// When echo is ON across a reattach (the common case — no password prompt), the re-establishment must
    /// stay SILENT: re-anchoring to the echo-on baseline then folding echo-on is a no-op, so the CONTROL
    /// stream gains no chatter on an ordinary reconnect.
    func testReattachWithEchoOnEmitsNothing() {
        let session = makeSession()
        session.reestablishEchoOnReattachForTesting(echoOn: true)
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "an echo-on reattach re-anchors to the baseline and emits nothing (no chatter)",
        )
    }

    // MARK: C3 — a transient startup no-echo must not latch the Secure-Input pill

    /// C3 (Phase-C GUI audit). The reported bug: the "SECURE INPUT" pill shows at launch on a NORMAL
    /// echo-on shell prompt and stays on. ROOT CAUSE is host-side — a freshly connected PTY master can
    /// read `ECHO`-cleared for a sample or two before the shell's termios settles to echo-on, and the
    /// edge-triggered ``EchoModeDetector`` (anchored echo-on) would fold that transient as a real edge,
    /// emitting a spurious `inputEcho(false)` that latches the client's `hostNoEcho = true`.
    ///
    /// The connect/keystroke/poll path must HONOR a no-echo edge only after a confirmed echo-ON sample.
    ///
    /// REVERT-TO-FAIL: removing the `echoWarmedUp` gate in ``MuxChannelSession/foldEchoSample(echoOn:)``
    /// makes the leading `false` fold immediately → an `inputEcho(false)` is emitted → this fails.
    func testStartupTransientNoEchoDoesNotLatchSecureInput() {
        let session = makeSession()
        var emitted: [WireMessage] = []

        // A realistic NORMAL echo-on connect: the PTY master reads ECHO-cleared for a sample right after
        // attach (termios not yet settled), then echo-on steady at the prompt (poll backstop + the
        // post-keystroke re-probes). NONE of this is a genuine password prompt.
        for echoOn in [false, true, true, true] {
            session.foldEchoSampleForTesting(echoOn: echoOn)
            while let batch = session.takeControlBatchForTesting() { emitted.append(contentsOf: batch) }
        }

        XCTAssertFalse(
            emitted.contains(.inputEcho(enabled: false)),
            "a transient startup no-echo on a NORMAL echo-on PTY must NOT emit inputEcho(false) (it would latch the Secure-Input pill)",
        )
        XCTAssertTrue(
            emitted.isEmpty,
            "a steady echo-on connect keeps the CONTROL stream silent (no echo chatter at all)",
        )
    }

    /// A GENUINE password prompt that follows a confirmed echo-on baseline still emits — the warm-up
    /// gate only suppresses a pre-baseline transient, never the real echo→no-echo transition. (Confirms
    /// the C3 fix does not disable the feature.)
    func testGenuineNoEchoAfterWarmupStillEmits() {
        let session = makeSession()
        var emitted: [WireMessage] = []

        for echoOn in [true, true, false, false, true] { // prompt → sudo password → restore
            session.foldEchoSampleForTesting(echoOn: echoOn)
            while let batch = session.takeControlBatchForTesting() { emitted.append(contentsOf: batch) }
        }

        XCTAssertEqual(
            emitted, [.inputEcho(enabled: false), .inputEcho(enabled: true)],
            "after an echo-on baseline, the password prompt's no-echo edge and its restore both emit",
        )
    }
}
