import Foundation
import SlopDeskSupervisor
import XCTest
@testable import SlopDeskHost

/// The command-block tap, end to end through a real `slopdesk-superd`.
///
/// hostd no longer segments the OSC 133 stream and no longer holds a block's output: superd's pump
/// does both, because it already has the bytes before anyone else sees one, and — the part that
/// decided WHERE the ring lives — a ring in hostd died on every rebuild, so a client reattaching
/// after `make host-restart` found an empty Commands panel for a shell that had never stopped
/// (`rust/slopdesk-superd/src/blocks.rs`, `docs/51` §6.14).
///
/// Everything below drives a real daemon and a real shell. What no unit test can cover, and what
/// these exist for, is the SEAM: that the events cross the socket on their own `0x05` tag, that the
/// three read verbs answer from superd's ring, and that a pane spawned without a tap answers none of
/// them.
///
/// Skips by name when superd is not built (`make superd`, or `make test`, which does).
final class SupervisedBlocksTests: XCTestCase {
    private var superd: SuperdFixture?
    /// One collector per pane, kept alive for the test — a `PaneOutput` unsubscribes on `deinit`.
    private var collectors: [PaneOutput] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        superd = try SuperdFixture()
    }

    override func tearDown() {
        collectors.removeAll()
        superd = nil
        super.tearDown()
    }

    /// One full OSC-133 A→D prompt cycle, written by the shell rather than scripted into a Swift
    /// fixture — the marks have to survive the PTY and superd's reader to prove anything.
    private func cycle(command: String, output: String, exit: Int) -> String {
        "printf '\\033]133;A\\007$ \\033]133;B\\007\(command)\\033]133;C\\007\(output)\\033]133;D;\(exit)\\007'; "
    }

    @discardableResult
    private func spawn(_ script: String, blocks: Bool = true) throws -> (PTYProcess, PaneOutput) {
        let pty = try PTYProcess(supervisor: XCTUnwrap(superd).client)
        var environment = HostEnvironment.curated()
        environment["TERM"] = "xterm-256color"
        try pty.spawnForTest(
            "/bin/sh",
            arguments: ["-c", script + "sleep 30"],
            environment: environment,
            shellIntegration: true,
            blocks: blocks,
        )
        let output = try PaneOutput(pty)
        collectors.append(output)
        return (pty, output)
    }

    private func closed(_ events: [BlockEvent]) -> [BlockMetadata] {
        events.compactMap { event in
            guard case let .block(meta) = event, meta.complete else { return nil }
            return meta
        }
    }

    // MARK: The 0x05 frame

    /// The whole path in one assertion: a shell writes the 133 marks, superd's pump segments the
    /// chunk it just read, frames the result on its own tag, and hostd decodes a finished block with
    /// the command line and the exit code the shell reported.
    func testAClosedBlockArrivesOnItsOwnFrame() throws {
        let (_, pane) = try spawn(cycle(command: "echo one", output: "one\\n", exit: 0))
        XCTAssertTrue(
            pane.waitForBlocks(timeout: 10) { events in
                self.closed(events).contains { $0.commandText == "echo one" && $0.exitCode == 0 }
            },
            "superd must report the block it segmented — got \(pane.blocks)",
        )
    }

    /// The tags are separate because they answer to different gates, and a pane with both on must
    /// get both: the sniffer's status and the tap's block describe the same command from different
    /// sides, and the Commands panel needs the block while the pane badge needs the status.
    func testTheSniffAndTheBlockBothArriveForTheSameCommand() throws {
        let (_, pane) = try spawn(cycle(command: "false", output: "", exit: 1))
        XCTAssertTrue(
            pane.waitForBlocks(timeout: 10) { self.closed($0).contains { $0.exitCode == 1 } },
            "the block must arrive — got \(pane.blocks)",
        )
        XCTAssertTrue(
            pane.waitForSniffed(timeout: 10) { events in
                events.contains { event in
                    if case let .commandIdle(exitCode, _) = event { return exitCode == 1 }
                    return false
                }
            },
            "and so must the status the sniffer read from the same bytes — got \(pane.sniffed)",
        )
    }

    /// The gate. A pane spawned without a tap is never segmented, so no `0x05` frame exists for it —
    /// and the bytes still flow, because the gate is on the segmentation, not on the stream.
    func testAnUntappedPaneReportsNoBlocks() throws {
        let (pty, pane) = try spawn(
            cycle(command: "echo hi", output: "hi\\n", exit: 0) + "printf 'seen'; ",
            blocks: false,
        )
        _ = pane.waitFor("seen", timeout: 10)
        XCTAssertEqual(pane.blocks, [], "an untapped pane reports nothing")
        XCTAssertNil(pty.blockSnapshot(), "and answers no read — absent, which is not the same as empty")
        XCTAssertNil(pty.blockControl(limit: 4))
        XCTAssertNil(pty.blockOutput(index: 0))
    }

    // MARK: The three read verbs

    /// `blockOutput` — the bytes superd retained for a finished command, fetched on demand. This is
    /// the fetch that used to read a hostd-side ring, and the reason a reattach after a rebuild now
    /// finds anything at all.
    func testTheRetainedOutputIsFetchableByIndex() throws {
        let (pty, pane) = try spawn(cycle(command: "echo one", output: "one\\n", exit: 0))
        XCTAssertTrue(pane.waitForBlocks(timeout: 10) { !self.closed($0).isEmpty })

        let index = try XCTUnwrap(closed(pane.blocks).first?.index)
        let bytes = try XCTUnwrap(pty.blockOutput(index: index), "a tapped pane must answer the read")
        // `\r\n`, not `\n`: these are the bytes as the PTY produced them (ONLCR), retained verbatim.
        // Anything tidier here would mean superd had edited a transcript, which it must never do.
        XCTAssertEqual(String(bytes: bytes, encoding: .utf8), "one\r\n")
    }

    /// An index the ring never had, or has evicted, answers EMPTY rather than absent: the pane has a
    /// tap, so the caller's question was answerable, and the answer is "nothing".
    func testAnUnknownIndexAnswersEmptyRatherThanAbsent() throws {
        let (pty, pane) = try spawn(cycle(command: "echo one", output: "one\\n", exit: 0))
        XCTAssertTrue(pane.waitForBlocks(timeout: 10) { !self.closed($0).isEmpty })
        XCTAssertEqual(pty.blockOutput(index: 9999), [], "known pane, unknown block → empty, never nil")
    }

    /// `blockSnapshot` — what a reattaching client's navigator is rebuilt from. It is a read of
    /// superd's ring, so it survives everything on the hostd side of the socket.
    func testTheSnapshotCarriesEveryBlockTheRingStillHolds() throws {
        let (pty, pane) = try spawn(
            cycle(command: "echo one", output: "one\\n", exit: 0)
                + cycle(command: "false", output: "", exit: 1),
        )
        XCTAssertTrue(pane.waitForBlocks(timeout: 10) { self.closed($0).count >= 2 })

        let snapshot = try XCTUnwrap(pty.blockSnapshot())
        XCTAssertEqual(
            snapshot.filter(\.complete).map(\.commandText).suffix(2),
            ["echo one", "false"],
            "ascending, oldest first — the order a navigator lists them in",
        )
        XCTAssertEqual(snapshot.first(where: { $0.commandText == "false" })?.exitCode, 1)
    }

    /// `blockControl` — the `last-output` / `run --wait` read, which is ONE round trip precisely
    /// because the recent blocks, the running command and the next index are only consistent with
    /// each other if superd read them together.
    func testTheControlReadAnswersRecentAndRunningAndNextIndexTogether() throws {
        let (pty, pane) = try spawn(
            cycle(command: "echo one", output: "one\\n", exit: 0)
                // …then leave a command OPEN: `C` with no `D`, which is a shell still working.
                + "printf '\\033]133;A\\007$ \\033]133;B\\007sleep 99\\033]133;C\\007tick'; ",
        )
        XCTAssertTrue(pane.waitFor("tick", timeout: 10).contains("tick"))
        XCTAssertTrue(pane.waitForBlocks(timeout: 10) { !self.closed($0).isEmpty })

        let reply = try XCTUnwrap(pty.blockControl(limit: 2))
        let recent = try XCTUnwrap(reply.recent)
        XCTAssertEqual(recent.last?.commandText, "echo one", "newest LAST")
        XCTAssertEqual(recent.last?.exitCode, 0)
        XCTAssertEqual(recent.last.map { String(bytes: $0.output, encoding: .utf8) }, "one\r\n")
        XCTAssertEqual(reply.open?.commandText, "sleep 99", "the running command, by name")
        XCTAssertEqual(
            reply.nextIndex, 2,
            "block 0 closed and block 1 is open, so the next command typed here closes as 2",
        )
    }
}
