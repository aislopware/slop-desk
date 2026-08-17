// CommandReceiptTests — pins the trailing slot's COMMAND RECEIPT (docs/DECISIONS.md round 24): the
// reading that replaced the outcome MARKS, where a finished command names itself in the slot rather
// than miming its exit with a disc or a triangle. Three rules ride here: WHICH badge earns a receipt
// (the mark column keeps the agent's, so a finish only lands here when it is not the agent's), WHICH
// block names it (the attributed failure for a red one, the newest closed block for a clean one —
// and the foreground process when no block can), and HOW the name is trimmed down to one slot-wide
// word. Headless VALUE assertions over the pure resolver — no view, no store.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

final class CommandReceiptTests: XCTestCase {
    private func block(
        _ index: UInt32, _ text: String, exit: Int32?, duration: UInt32? = 40, complete: Bool = true,
    ) -> CommandBlock {
        CommandBlock(
            index: index, commandText: text, exitCode: exit, durationMS: duration, complete: complete,
        )
    }

    /// A clean exit names the NEWEST CLOSED block — what just finished — in the succeeded reading.
    func testACleanExitNamesTheCommandThatJustFinished() {
        let blocks = [
            block(0, "npm install", exit: 0),
            block(1, "make check", exit: 0),
            block(2, "vim README.md", exit: nil, duration: nil, complete: false),
        ]
        let receipt = RailRowsBuilder.commandReceipt(
            badge: .finished, agentFinish: false, blocks: blocks, failedBlock: nil,
            processLabel: "vim",
        )
        XCTAssertEqual(receipt, .init(name: "make", outcome: .succeeded))
    }

    /// A failure names the ATTRIBUTED failed block — never the newest closed one, which after a
    /// failure is usually whatever the shell ran next.
    func testAFailureNamesTheBlockItIsBlamedOn() {
        let failed = block(1, "make check", exit: 137)
        let blocks = [block(0, "git pull", exit: 0), failed, block(2, "ls", exit: 0)]
        let receipt = RailRowsBuilder.commandReceipt(
            badge: .error, agentFinish: false, blocks: blocks, failedBlock: failed,
            processLabel: "zsh",
        )
        XCTAssertEqual(receipt, .init(name: "make", outcome: .failed))
    }

    /// ⚠️ An UNATTRIBUTED failure (a live `OSC 9;4;2` inside a still-open block — the caller passes
    /// no failed block, see ``RailRowsBuilder/failedBlock(for:badge:store:)``) must NOT borrow an
    /// older closed command's name. It falls back to the pane's foreground process, so the row still
    /// reads red without inventing a culprit.
    func testAnUnattributedFailureNamesTheProcessNotAnOlderCommand() {
        let receipt = RailRowsBuilder.commandReceipt(
            badge: .error, agentFinish: false, blocks: [block(0, "npm test", exit: 1)],
            failedBlock: nil, processLabel: "cargo",
        )
        XCTAssertEqual(receipt, .init(name: "cargo", outcome: .failed))
    }

    /// Nothing can name it ⇒ NO receipt. A nameless "something finished" is exactly what the disc
    /// used to say, and saying it in a different medium was not the point of dropping the disc.
    func testANamelessOutcomeMountsNothing() {
        XCTAssertNil(RailRowsBuilder.commandReceipt(
            badge: .finished, agentFinish: false, blocks: [], failedBlock: nil, processLabel: nil,
        ))
        XCTAssertNil(RailRowsBuilder.commandReceipt(
            badge: .finished, agentFinish: false, blocks: [block(0, "   ", exit: 0)],
            failedBlock: nil, processLabel: "  ",
        ))
    }

    /// The AGENT's finish is the mark column's check — it never takes the slot as well, whatever
    /// blocks the pane happens to hold.
    func testTheAgentsFinishTakesNoReceipt() {
        for kind: TabBadgeKind in [.completed, .finished] {
            XCTAssertNil(RailRowsBuilder.commandReceipt(
                badge: kind, agentFinish: true, blocks: [block(0, "claude", exit: 0)],
                failedBlock: nil, processLabel: "claude",
            ))
        }
    }

    /// Everything still LIVE keeps the resting process label: an outcome is a finished fact, so a
    /// busy shell never dresses its own name up as a verdict.
    func testLiveTiersTakeNoReceipt() {
        for kind: TabBadgeKind? in [
            .commandBusy,
            .commandRunning,
            .running,
            .awaitingInput,
            .sudo,
            .caffeinate,
            nil,
        ] {
            XCTAssertNil(RailRowsBuilder.commandReceipt(
                badge: kind, agentFinish: false, blocks: [block(0, "make", exit: 0)],
                failedBlock: nil, processLabel: "make",
            ))
        }
    }

    /// The name is ONE word, basenamed: the slot is a narrow column beside a title that must
    /// truncate last, and the full command line stays one hover away in the tooltip.
    func testTheNameIsTheCommandsOwnFirstWord() {
        XCTAssertEqual(RailRowsBuilder.slotCommandName("make -j8 check"), "make")
        XCTAssertEqual(RailRowsBuilder.slotCommandName("/usr/bin/make -j8"), "make")
        XCTAssertEqual(RailRowsBuilder.slotCommandName("  ./scripts/check-ios.sh  "), "check-ios.sh")
        XCTAssertEqual(RailRowsBuilder.slotCommandName("npm run build"), "npm")
        XCTAssertNil(RailRowsBuilder.slotCommandName("   "))
        XCTAssertNil(RailRowsBuilder.slotCommandName(nil))
    }

    /// A leading env assignment or `sudo` is not what RAN — and `sudo` in the slot would also
    /// restate the privilege badge two glyphs away.
    func testTheNameSkipsEnvAssignmentsAndSudo() {
        XCTAssertEqual(RailRowsBuilder.slotCommandName("RUST_LOG=debug cargo test"), "cargo")
        XCTAssertEqual(RailRowsBuilder.slotCommandName("sudo make install"), "make")
        XCTAssertEqual(RailRowsBuilder.slotCommandName("FOO=1 BAR=2 sudo ./deploy.sh"), "deploy.sh")
        // An ASSIGNMENT further along is an ARGUMENT, not a prefix — the command still wins.
        XCTAssertEqual(RailRowsBuilder.slotCommandName("make PREFIX=/usr/local"), "make")
    }
}
