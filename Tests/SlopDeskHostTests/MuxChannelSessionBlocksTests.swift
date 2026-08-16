import SlopDeskProtocol
import SlopDeskSupervisor
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// WB1 — the host-glue wiring of the "Blocks" tap into ``MuxChannelSession``.
///
/// What this file asserts changed shape with the port, and the difference is worth stating. hostd
/// used to OWN the segmentation: these tests fed a scripted OSC 133 stream and checked that a Swift
/// state machine found the block in it. It owns none of that now — superd's pump segments the bytes
/// it already read and hands over `[BlockEvent]` (`rust/slopdesk-superd/src/blocks.rs`, `docs/51`
/// §6.14). So the fixture is the EVENT, not the stream, and what is under test is the only thing
/// hostd still does with one: fold it into a type-28 `commandBlock`, and serve type 29 from superd's
/// ring. The 133 truth table went with the segmenter, to `blocks.rs`'s own tests.
///
/// Driven WITHOUT a PTY or running drain via the `_…ForTesting` seams (hang-safety). The control
/// sender FIFO is read back via `takeControlBatchForTesting()`. An unspawned PTY has no pane
/// identity, so every read-through verb answers empty here — which is exactly the "never a trap"
/// contract sections 2 and 3 are about.
final class MuxChannelSessionBlocksTests: XCTestCase {
    private func closed(index: UInt32, command: String, outputLen: UInt32, exit: Int32) -> BlockEvent {
        .block(BlockMetadata(
            index: index,
            exitCode: exit,
            durationMS: 12,
            complete: true,
            outputLen: outputLen,
            commandText: command,
        ))
    }

    private func makeSession(blocksEnabled: Bool) -> MuxChannelSession {
        MuxChannelSession(
            channelID: 1,
            pty: unattachedPTY(), // unspawned — relay never started; tap driven via seams
            data: MuxSubChannel(channelID: 1, channel: .data) { _, _ in },
            control: MuxSubChannel(channelID: 1, channel: .control) { _, _ in },
            blocksEnabled: blocksEnabled,
        )
    }

    private func commandBlocks(_ messages: [WireMessage]?) -> [WireMessage] {
        (messages ?? []).filter { if case .commandBlock = $0 { true } else { false } }
    }

    // MARK: 1. Flag ON — a superd block event enqueues type-28 metadata

    func testBlocksEnabledEnqueuesCommandBlockMetadata() {
        let session = makeSession(blocksEnabled: true)
        XCTAssertTrue(session.blocksEnabledForTesting)
        session.foldBlocksForTesting([closed(index: 0, command: "echo hi", outputLen: 3, exit: 0)])

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

    /// Every field of the event reaches the wire message. The translation is the whole of hostd's
    /// remaining job here, so a dropped exit code would otherwise be invisible until a client showed
    /// a green tick on a failed command.
    func testEveryFieldOfTheEventReachesTheWireMessage() {
        let session = makeSession(blocksEnabled: true)
        session.foldBlocksForTesting([.block(BlockMetadata(
            index: 4,
            exitCode: 130,
            durationMS: 9871,
            complete: true,
            outputLen: 4096,
            commandText: "cargo test",
            promptOrdinal: 11,
        ))])

        guard case let .commandBlock(index, exit, duration, complete, outputLen, command, ordinal)
            = commandBlocks(session.takeControlBatchForTesting()).first
        else {
            XCTFail("expected one type-28")
            return
        }
        XCTAssertEqual(index, 4)
        XCTAssertEqual(exit, 130)
        XCTAssertEqual(duration, 9871)
        XCTAssertTrue(complete)
        XCTAssertEqual(outputLen, 4096)
        XCTAssertEqual(command, "cargo test")
        XCTAssertEqual(ordinal, 11)
    }

    /// A synthetic progress badge is superd's decision about a slow command; the type-32 that
    /// carries it is hostd's, because superd does not know the protocol.
    func testASyntheticProgressEventBecomesATypeThirtyTwo() {
        let session = makeSession(blocksEnabled: true)
        session.foldBlocksForTesting([.progress(.indeterminate), .progress(.clear)])

        let progress = (session.takeControlBatchForTesting() ?? []).compactMap { msg -> UInt8? in
            guard case let .progress(state, _) = msg else { return nil }
            return state
        }
        XCTAssertEqual(progress, [3, 0], "indeterminate then clear, in the order superd reported them")
    }

    /// A kind a NEWER superd knows must cost nothing but itself.
    func testAnUnknownKindIsSkippedRatherThanTakingTheBatch() {
        let session = makeSession(blocksEnabled: true)
        session.foldBlocksForTesting([
            .unknown(kind: "somethingLater"),
            closed(index: 0, command: "echo hi", outputLen: 3, exit: 0),
        ])
        XCTAssertEqual(commandBlocks(session.takeControlBatchForTesting()).count, 1)
    }

    // MARK: 2. requestBlockOutput → type-29 blockOutput, always answered

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

    // MARK: 3. Flag OFF — no tap asked for, no emit

    func testBlocksDisabledEmitsNothing() {
        let session = makeSession(blocksEnabled: false)
        XCTAssertFalse(session.blocksEnabledForTesting)
        // The pane was spawned untapped, so superd sends nothing; the fold is gated anyway, which is
        // what makes a stale event from a pane whose flag changed cost nothing.
        session.foldBlocksForTesting([closed(index: 0, command: "echo hi", outputLen: 3, exit: 0)])
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

    // MARK: 4. Differential: blocks ON vs OFF — only the tap differs

    func testBlocksFlagIsADifferentialOnlyOnTheTap() {
        // The same events through both worlds: flag-ON enqueues type-28, flag-OFF enqueues ZERO
        // type-28/29 and the byte pipeline is byte-identical either way.
        //
        // The other half of the old differential — that the sniffed command-status stream is
        // identical either way — is not assertable from here any more and no longer needs to be:
        // the sniffer is superd's, it never sees this flag, and its own suite pins the
        // prompt-ready → running → idle sequence for this exact cycle.
        let events = [closed(index: 0, command: "echo hi", outputLen: 3, exit: 0)]

        let onSession = makeSession(blocksEnabled: true)
        onSession.foldBlocksForTesting(events)
        let onControl = onSession.takeControlBatchForTesting() ?? []
        XCTAssertFalse(commandBlocks(onControl).isEmpty, "blocks ON → type-28 metadata enqueued")

        let offSession = makeSession(blocksEnabled: false)
        offSession.foldBlocksForTesting(events)
        let offControl = offSession.takeControlBatchForTesting()
        XCTAssertNil(offControl, "blocks OFF → ZERO type-28/29 enqueued (byte pipeline byte-identical)")
    }
}
