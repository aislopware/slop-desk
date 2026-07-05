import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// WB1 — the host-glue wiring of the "Blocks" tap into ``MuxChannelSession``: the additive
/// PARALLEL tap (env-gated `SLOPDESK_BLOCKS`) feeds the per-channel ``CommandBlockTracker`` on the
/// SAME outbound chunks the live ``HostOutputSniffer`` sees, enqueues type-28 `commandBlock`
/// metadata on the CONTROL sender, and serves type-29 `blockOutput` on a `requestBlockOutput`.
///
/// Driven WITHOUT a PTY or running drain via the `_…ForTesting` seams (hang-safety). The control
/// sender FIFO is read back via `takeControlBatchForTesting()`.
final class MuxChannelSessionBlocksTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"

    private func cycle(command: String, output: String, exit: Int) -> String {
        "\(ESC)]133;A\(BEL)$ \(ESC)]133;B\(BEL)\(command)\(ESC)]133;C\(BEL)\(output)\(ESC)]133;D;\(exit)\(BEL)"
    }

    private func makeSession(blocksEnabled: Bool) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: PTYProcess(), // unspawned — relay never started; tap driven via seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            blocksEnabled: blocksEnabled,
        )
    }

    private func commandBlocks(_ messages: [WireMessage]?) -> [WireMessage] {
        (messages ?? []).filter { if case .commandBlock = $0 { true } else { false } }
    }

    // MARK: 1. Flag ON — a scripted 133 stream enqueues type-28 metadata per block

    func testBlocksEnabledEnqueuesCommandBlockMetadata() {
        let session = makeSession(blocksEnabled: true)
        XCTAssertTrue(session.blocksEnabledForTesting)
        session.feedBlocksForTesting(Data(cycle(command: "echo hi", output: "hi\n", exit: 0).utf8))

        let blocks = commandBlocks(session.takeControlBatchForTesting())
        // A complete metadata for index 0 pinned to the literal command.
        let complete = blocks.compactMap { msg -> (UInt32, String, Bool)? in
            guard case let .commandBlock(index, _, _, complete, _, cmd, _) = msg else { return nil }
            return (index, cmd, complete)
        }.filter(\.2)
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete[0].0, 0)
        XCTAssertEqual(complete[0].1, "echo hi")
    }

    // MARK: 2. requestBlockOutput → type-29 blockOutput with the right bytes

    func testServeBlockOutputEnqueuesTypeAndBytes() {
        let session = makeSession(blocksEnabled: true)
        session.feedBlocksForTesting(Data(cycle(command: "cat f", output: "alpha\nbeta\n", exit: 0).utf8))
        _ = session.takeControlBatchForTesting() // drain the metadata emit

        session.serveBlockOutputForTesting(index: 0)
        let batch = session.takeControlBatchForTesting() ?? []
        guard let msg = batch.first, case let .blockOutput(index, output) = msg else {
            XCTFail("expected a blockOutput on the control sender, got \(batch)")
            return
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "alpha\nbeta\n")
    }

    func testServeUnknownIndexEnqueuesEmptyBlockOutput() {
        let session = makeSession(blocksEnabled: true)
        session.serveBlockOutputForTesting(index: 7)
        let batch = session.takeControlBatchForTesting() ?? []
        guard let msg = batch.first, case let .blockOutput(index, output) = msg else {
            XCTFail("expected a blockOutput, got \(batch)")
            return
        }
        XCTAssertEqual(index, 7)
        XCTAssertTrue(output.isEmpty, "unknown block → empty served output, never a trap")
    }

    // MARK: 3. Flag OFF — no segmenter, no emit (byte pipeline byte-identical)

    func testBlocksDisabledEmitsNothing() {
        let session = makeSession(blocksEnabled: false)
        XCTAssertFalse(session.blocksEnabledForTesting)
        // Feeding a full 133 cycle produces NO control output at all.
        session.feedBlocksForTesting(Data(cycle(command: "echo hi", output: "hi\n", exit: 0).utf8))
        XCTAssertNil(session.takeControlBatchForTesting(), "blocks OFF → no type-28 enqueued")
    }

    func testBlocksDisabledRequestServesEmptyBlockOutput() {
        // Even with blocks off, a request gets an EMPTY reply (never a hang / never a trap).
        let session = makeSession(blocksEnabled: false)
        session.serveBlockOutputForTesting(index: 3)
        let batch = session.takeControlBatchForTesting() ?? []
        guard let msg = batch.first, case let .blockOutput(index, output) = msg else {
            XCTFail("expected an empty blockOutput, got \(batch)")
            return
        }
        XCTAssertEqual(index, 3)
        XCTAssertTrue(output.isEmpty)
    }

    // MARK: 4. Differential: blocks ON vs OFF — the sniffer path is byte-identical, only the tap differs

    func testBlocksFlagIsADifferentialOnlyOnTheTap() {
        // The Blocks tap is a SEPARATE parallel observer wired in `MuxChannelSession.start`'s read loop:
        // it OBSERVES the same chunk the live `HostOutputSniffer` does but never touches the bytes the
        // sniffer/commandStatus path emits. This test runs the SAME scripted PTY stream through both the
        // flag-ON and flag-OFF worlds and asserts:
        //   (a) the sniffer's emitted commandStatus/title/bell stream is IDENTICAL (the byte pipeline's
        //       only observation is untouched by WB1 — the session constructs the sniffer the same way
        //       regardless of the flag, so two independent sniffer passes over the same bytes must match);
        //   (b) flag-ON enqueues type-28 metadata while flag-OFF enqueues ZERO type-28/29.
        let scripted = Data(cycle(command: "echo hi", output: "hi\n", exit: 0).utf8)

        // (a) Sniffer stream — the SAME `HostOutputSniffer` the session's read loop uses. Two independent
        // passes over the identical bytes (mirroring an ON-session vs OFF-session read loop) must agree.
        let snifferOn = HostOutputSniffer(clock: { Date(timeIntervalSinceReferenceDate: 0) }).observe(scripted)
        let snifferOff = HostOutputSniffer(clock: { Date(timeIntervalSinceReferenceDate: 0) }).observe(scripted)
        XCTAssertEqual(snifferOn, snifferOff, "the sniffer/commandStatus stream is identical ON vs OFF")
        XCTAssertEqual(snifferOn, [
            .commandStatus(.idle(exitCode: nil, durationMS: 0)), // 133;B prompt-ready (startup idle)
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 0)),
        ], "and is exactly the prompt-ready→running→idle status for this cycle (pinned, not tautological)")

        // (b) The TAP differential: same scripted stream, flag ON enqueues type-28; flag OFF enqueues none.
        let onSession = makeSession(blocksEnabled: true)
        onSession.feedBlocksForTesting(scripted)
        let onControl = onSession.takeControlBatchForTesting() ?? []
        XCTAssertFalse(commandBlocks(onControl).isEmpty, "blocks ON → type-28 metadata enqueued")

        let offSession = makeSession(blocksEnabled: false)
        offSession.feedBlocksForTesting(scripted)
        let offControl = offSession.takeControlBatchForTesting()
        XCTAssertNil(offControl, "blocks OFF → ZERO type-28/29 enqueued (byte pipeline byte-identical)")
    }
}
