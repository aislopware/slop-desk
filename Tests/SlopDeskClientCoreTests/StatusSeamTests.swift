// StatusSeamTests — the two pins that span the design floor and the rail's reading of it.
//
// Both tests below lived in `SlopDeskSlateTests/StatusDotTests.swift` until 2026-08-22, and moved for
// a reason worth recording rather than for tidiness. That suite's dependency list was narrowed to the
// three targets `SlopDeskSlate` itself names, which is correct — a floor's suite that can reach the
// whole tree can test anything, and stops being evidence about the floor. But these two assertions do
// not belong to the floor. Each pairs a ``StatusPresentation`` fact with the ``RailRowsBuilder``
// predicate that DECIDES which presentation applies, and the predicate is `package` in
// `SlopDeskClientCore`, one storey up. So the tests came up to meet it.
//
// The pairing is the whole point of them: `StatusPresentation` can only say what a finish LOOKS like,
// and `RailRowsBuilder` can only say WHOSE finish it is. Split them across two suites and each half
// keeps passing while the seam between them rots — the row that draws the agent's closed ring stops
// being the row that shows the agent's last words, and no single suite is wrong. Kept together, in
// the only target that can see both, one test fails.

import SlopDeskAgentDetect
import SlopDeskSlate
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class StatusSeamTests: XCTestCase {
    /// ⚠️ A clean exit is NOT a brightness step any more (round 25, user-directed). The running
    /// command already reads bold on the primary ink, so the succeeded receipt is byte-for-byte the
    /// same register — this is the pin that says so, and the reason ``outcomeSymbol`` has to exist:
    /// if these two ever diverge again, the tick has become decoration on a signal that is already
    /// being sent, and the round is undone. Since round 26 the succeeded receipt is the TICK, and
    /// this ink is what the tick reads in — the register is still inherited, not re-picked.
    @MainActor
    func testAFinishDoesNotRestyleTheCommandName() {
        XCTAssertEqual(
            StatusPresentation.outcomeInk(.succeeded),
            StatusPresentation.slotNameInk(isCommand: true),
            "a clean exit must read in the same ink the command wore while it ran",
        )
        // A bare login shell is the one slot label that stays quiet — bolding every idle `zsh` on
        // the rail spends exactly the step this round reserves for work.
        XCTAssertEqual(StatusPresentation.slotNameInk(isCommand: false), Slate.Native.Text.tertiary)
        XCTAssertNotEqual(
            StatusPresentation.slotNameInk(isCommand: true),
            StatusPresentation.slotNameInk(isCommand: false),
        )
        XCTAssertTrue(RailRowsBuilder.slotLabelIsCommand("make"))
        XCTAssertTrue(RailRowsBuilder.slotLabelIsCommand("/usr/bin/vim"))
        for shell in ["zsh", "-zsh", "bash", "fish"] {
            XCTAssertFalse(
                RailRowsBuilder.slotLabelIsCommand(shell), "\(shell) is the pane at rest, not work",
            )
        }
        XCTAssertFalse(RailRowsBuilder.slotLabelIsCommand(nil))
    }

    /// The finish's OWNER comes from one shared predicate: a live agent `.done` or the client's
    /// unread latch, and ONLY on a finish badge. The same call gates the row's agent FINAL LINE, so
    /// the row that shows the agent's last words is exactly the row that fills its check — a
    /// command's exit can neither borrow the agent's line nor its weight.
    @MainActor
    func testTheFinishOwnerIsOnePredicateForLineAndMark() {
        for status: ClaudeStatus in [.done, .idle] {
            for unseen in [true, false] {
                let agents = RailRowsBuilder.finishIsAgents(
                    badge: .finished, status: status, unseenDone: unseen,
                )
                XCTAssertEqual(
                    agents, status == .done || unseen,
                    "a live `.done` OR the unread latch owns the finish (\(status), unseen=\(unseen))",
                )
                // Whatever the predicate says, the VOICE must follow it — never diverge: the
                // agent's finish is the check, a command's is the slot's receipt.
                XCTAssertEqual(
                    StatusPresentation.statusDot(
                        working: false, badge: .finished, agentFinish: agents,
                    )?.mark,
                    agents ? .agentFinish : nil,
                )
                XCTAssertEqual(
                    StatusPresentation.commandOutcome(badge: .finished, agentFinish: agents),
                    agents ? nil : .succeeded,
                )
            }
        }
        // A NON-finish badge is never the agent's finish, however done the agent looks — an error or
        // a busy tier must not be read as a completed turn.
        for kind: TabBadgeKind? in [.error, .commandBusy, .awaitingInput, .running, nil] {
            XCTAssertFalse(
                RailRowsBuilder.finishIsAgents(badge: kind, status: .done, unseenDone: true),
                "\(String(describing: kind)) is not a finish badge",
            )
        }
    }
}
