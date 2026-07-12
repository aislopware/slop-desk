import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// The tab-row activity indicators must survive a client restart/reattach. `sleep 300`
/// shows the busy dot + "sleep" label live, but after quitting and reopening the client (the command
/// still running on the host) the returning client showed NOTHING: the busy bit (type-23), the
/// foreground-process name (type-26), the agent status (type-27), and the OSC 9;4 progress (type-32)
/// are ALL edge-triggered control truths that are never in the replayed output byte stream, the client
/// resets its mirrors on reconnect, and `rebindRelay` wipes `controlOut` — so no edge ever re-tells
/// the new client what is still live. ``MuxChannelSession/reestablishActivityOnReattach`` (called from
/// `rebindRelay`, right after the echo/blocks re-asserts) re-emits the CURRENT truths.
///
/// Driven WITHOUT a PTY or running relay: the REAL chunk handler (`ingestPTYChunkForTesting` → the
/// live ``HostOutputSniffer``) supplies the OSC 133/9;4 truths, and the injected-name detector fold
/// (`foldForegroundSampleForTesting`) stands in for the `tcgetpgrp` probe (hang-safety rule).
///
/// REVERT-TO-FAIL: removing the `reestablishActivityOnReattach()` call from `rebindRelay` (or any of
/// its four sources) turns the corresponding re-assert batch into `nil`/missing and these fail.
final class MuxChannelSessionActivityReattachTests: XCTestCase {
    private func makeSession() -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; truths driven via the seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
        )
    }

    /// A BEL-terminated OSC sequence as raw PTY bytes (`ESC ] <body> BEL`).
    private func osc(_ body: String) -> Data { Data("\u{1B}]\(body)\u{07}".utf8) }

    /// Drains control-out of the LIVE-emission side-products of ingesting a chunk (the Blocks
    /// segmenter's type-28 metadata goes straight to control-out) — the returning client received
    /// none of these; the re-assert must stand on its own after the `rebindRelay` wipe.
    private func drainControlOut(_ session: MuxChannelSession) {
        while session.takeControlBatchForTesting() != nil {}
    }

    // MARK: - type-23: the busy bit (OSC 133;C with no matching ;D yet)

    func testReattachReemitsRunningBusyBit() {
        let session = makeSession()
        // `sleep 300` began: the shell integration emitted 133;C. The sniffed type-23 rides the
        // output FIFO with its chunk (only the Blocks segmenter's type-28 lands on control-out) —
        // exactly why a reattach (which wiped control-out and reset the client) sees nothing
        // without the re-assert. Drain the live-emission side-products first.
        session.ingestPTYChunkForTesting(osc("133;C"))
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(), [.commandStatus(.running)],
            "a command that spans the reattach re-tells the returning client it is still running",
        )
    }

    func testReattachAfterCommandFinishedStaysQuiet() {
        let session = makeSession()
        session.ingestPTYChunkForTesting(osc("133;C"))
        session.ingestPTYChunkForTesting(osc("133;D;0"))
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "idle IS the client's reconnect reset state — a synthetic .idle would fabricate a lastCommand/completion edge",
        )
    }

    // MARK: - type-32: a live OSC 9;4 progress spinner/bar

    func testReattachReemitsLiveProgress() {
        let session = makeSession()
        session.ingestPTYChunkForTesting(osc("9;4;3")) // indeterminate spinner up
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.progress(state: ProgressState.indeterminate.rawValue, percent: 0)],
            "a progress indicator that spans the reattach is re-told (the client cleared its mirror on disconnect)",
        )
    }

    func testReattachAfterProgressClearedStaysQuiet() {
        let session = makeSession()
        session.ingestPTYChunkForTesting(osc("9;4;1;40"))
        session.ingestPTYChunkForTesting(osc("9;4;0")) // the program cleared its indicator
        drainControlOut(session)

        session.reestablishActivityOnReattachForTesting()
        XCTAssertNil(session.takeControlBatchForTesting(), "a cleared progress truth contributes nothing on reattach")
    }

    // MARK: - type-26/27: the foreground-process name + agent status

    func testReattachReemitsForegroundNameAndAgentStatus() {
        let session = makeSession()
        // The ~1 Hz poll saw `sleep` in the foreground: type-26 edge (+ the first-fold type-27)
        // went to the OLD client. Drain them — the returning client never received these.
        session.foldForegroundSampleForTesting(name: "sleep", at: 100)
        XCTAssertNotNil(session.takeControlBatchForTesting(), "the live fold emitted its edge to the old client")

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(),
            [.foregroundProcess(name: "sleep"), .claudeStatus(state: 0, kind: 0, label: "")],
            "the CURRENT foreground name (the tab-row command label) is re-told to the returning client",
        )
    }

    func testReattachReemitsWorkingAgentStatusVerbatim() {
        let session = makeSession()
        session.reportAgentStatusForControl(state: "working", message: nil)
        let live = session.takeControlBatchForTesting()
        guard let announced = live?.last, case .claudeStatus = announced else {
            XCTFail("the report fold should have emitted a type-27, got \(String(describing: live))")
            return
        }

        session.reestablishActivityOnReattachForTesting()
        XCTAssertEqual(
            session.takeControlBatchForTesting(), [announced],
            "a working agent that spans the reattach re-tells the returning client its status verbatim",
        )
    }

    // MARK: - the common case: an ordinary idle reconnect adds no control chatter

    func testReattachQuietOnFreshIdleSession() {
        let session = makeSession()
        session.reestablishActivityOnReattachForTesting()
        XCTAssertNil(
            session.takeControlBatchForTesting(),
            "an idle shell with no agent/progress truth emits nothing — no chatter on an ordinary reconnect",
        )
    }
}
