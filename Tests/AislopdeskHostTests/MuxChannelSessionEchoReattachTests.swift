import AislopdeskProtocol
import AislopdeskTransport
import XCTest
@testable import AislopdeskHost

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
}
