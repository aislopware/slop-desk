import XCTest
@testable import SlopDeskAgentDetect

/// The BLOCK LEDGER (2026-08-11): a hook block is a set of outstanding calls keyed by
/// `tool_use_id`, not one flag. Claude Code emits tool calls in BATCHES, so "a tool finished"
/// and "the human answered the question" stopped being the same fact.
final class ClaudeStatusMachineBlockLedgerTests: XCTestCase {
    private func ask(_ id: String?, _ text: String = "which one?") -> ClaudeSignal {
        .hook(.notification(kind: .waitingForInput, label: text, toolUseID: id))
    }

    private func permission(_ id: String?) -> ClaudeSignal {
        .hook(.notification(kind: .permission, label: "Permission needed: Bash", toolUseID: id))
    }

    private func pre(_ tool: String, _ id: String?) -> ClaudeSignal {
        .hook(.preToolUse(sessionID: nil, tool: tool, toolUseID: id))
    }

    private func post(_ tool: String, _ id: String?) -> ClaudeSignal {
        .hook(.postToolUse(sessionID: nil, tool: tool, toolUseID: id))
    }

    // MARK: The gap the ledger closes

    /// The batch case: `[AskUserQuestion, Bash]` in one assistant turn. Bash finishing is not an
    /// answer, and it used to hand the pane back to a human who was still being asked something.
    func testASiblingCallFinishingDoesNotAnswerTheQuestion() {
        var m = ClaudeStatusMachine()
        m.reduce(ask("ask-1"), at: 0)
        XCTAssertEqual(m.status, .needsPermission)

        XCTAssertEqual(m.reduce(pre("Bash", "bash-1"), at: 0.1), .needsPermission, "a sibling STARTING")
        XCTAssertEqual(m.reduce(post("Bash", "bash-1"), at: 0.5), .needsPermission, "…and FINISHING")
        XCTAssertEqual(m.outstandingBlockCount, 1)

        // Only the question's own result resolves it.
        XCTAssertEqual(m.reduce(post("AskUserQuestion", "ask-1"), at: 1), .working)
        XCTAssertEqual(m.outstandingBlockCount, 0)
    }

    /// The same shape for a permission raised on one call of a batch while a pre-approved sibling
    /// runs to completion.
    func testASiblingResultDoesNotGrantAPermission() {
        var m = ClaudeStatusMachine()
        m.reduce(permission("write-1"), at: 0)
        XCTAssertEqual(m.reduce(post("Bash", "bash-1"), at: 0.4), .needsPermission)
        XCTAssertEqual(m.reduce(pre("Write", "write-1"), at: 1), .working, "approved → it runs")
    }

    /// Two questions outstanding at once: the pane stays blocked until BOTH are answered.
    func testTheLedgerHoldsUntilTheLastCallResolves() {
        var m = ClaudeStatusMachine()
        m.reduce(ask("a"), at: 0)
        m.reduce(ask("b"), at: 0.1)
        XCTAssertEqual(m.outstandingBlockCount, 2)
        XCTAssertEqual(m.reduce(post("AskUserQuestion", "a"), at: 1), .needsPermission)
        XCTAssertEqual(m.reduce(post("AskUserQuestion", "b"), at: 2), .working)
    }

    func testRepeatingTheSameBlockDoesNotStackTheLedger() {
        var m = ClaudeStatusMachine()
        m.reduce(ask("a"), at: 0)
        m.reduce(ask("a"), at: 0.3)
        m.reduce(ask("a"), at: 0.6)
        XCTAssertEqual(m.outstandingBlockCount, 1)
        XCTAssertEqual(m.reduce(post("AskUserQuestion", "a"), at: 1), .working)
    }

    // MARK: Nothing may be un-lowerable

    /// ⚠️ A permission entry used to be dropped by ANY tool starting, on the reasoning that the
    /// dialog is modal. A BATCH breaks that: `[Read(a), Bash(gated)]` raises the prompt on `Bash`
    /// and `Read`'s own `PreToolUse` then fires while the human is still looking at it — the exact
    /// failure the ledger exists to prevent, left open in one direction. It resolves by identity
    /// now, like every other kind.
    func testASiblingCallStartingIsNotAnAnswerToAPermissionPrompt() {
        var m = ClaudeStatusMachine()
        m.reduce(permission("write-1"), at: 0)
        XCTAssertEqual(m.reduce(pre("Read", "read-9"), at: 2), .needsPermission)
        XCTAssertEqual(m.outstandingBlockCount, 1)
        // Granting it is what runs it, and running it is what lowers the hand.
        XCTAssertEqual(m.reduce(pre("Write", "write-1"), at: 3), .working)
        XCTAssertEqual(m.outstandingBlockCount, 0)
    }

    /// …and "no" is announced on its own event now (`PermissionDenied` → a post for that call),
    /// so a denial never needs the modal inference to stand in for it.
    func testADenialResolvesItsOwnCall() {
        var m = ClaudeStatusMachine()
        m.reduce(permission("write-1"), at: 0)
        XCTAssertEqual(m.reduce(post("Write", "write-1"), at: 2), .working)
        XCTAssertEqual(m.outstandingBlockCount, 0)
    }

    /// A notification that names no call (`agent_needs_input`, a ctl `report blocked`) keeps the
    /// old any-tool-clears-it rule — it has no better handle, and the alternative is a stuck hand.
    func testAnIdlessBlockIsStillClearedByAnyToolTraffic() {
        var m = ClaudeStatusMachine()
        m.reduce(ask(nil), at: 0)
        XCTAssertEqual(m.reduce(post("Bash", "bash-1"), at: 0.5), .working)

        var other = ClaudeStatusMachine()
        other.reduce(ask(nil), at: 0)
        XCTAssertEqual(other.reduce(pre("Bash", "bash-1"), at: 0.5), .working)
    }

    /// ⚠️ A body that omits `tool_use_id` arrives with none. Minting one would be a DIFFERENT
    /// string on the pre and the post hook, so the ledger entry it opened could never be resolved
    /// and the question would block the pane forever. A nil id degrades to the id-less rule.
    func testASynthesisedIdWouldNeverMatchSoNilIsTheSafeDegradation() {
        var m = ClaudeStatusMachine()
        m.reduce(ask(nil), at: 0)
        XCTAssertEqual(m.reduce(post("AskUserQuestion", nil), at: 1), .working)
    }

    /// Every turn boundary retires the whole ledger — nothing from the old turn is still being asked.
    func testTurnBoundariesRetireTheWholeLedger() {
        for (name, boundary) in [
            ("stop", ClaudeSignal.hook(.stop(sessionID: nil, label: "done"))),
            ("prompt", .hook(.userPromptSubmit(sessionID: nil))),
            ("sessionStart", .hook(.sessionStart(sessionID: nil))),
            ("cancel", .userInput),
        ] {
            var m = ClaudeStatusMachine()
            m.reduce(ask("a"), at: 0)
            m.reduce(ask("b"), at: 0.1)
            m.reduce(boundary, at: 1)
            XCTAssertEqual(m.outstandingBlockCount, 0, name)
            XCTAssertNotEqual(m.status, .needsPermission, name)
        }
    }

    func testSessionEndAndPresenceAbsenceBothEmptyTheLedger() {
        var ended = ClaudeStatusMachine()
        ended.reduce(ask("a"), at: 0)
        ended.reduce(.hook(.sessionEnd(sessionID: nil)), at: 1)
        XCTAssertEqual(ended.outstandingBlockCount, 0)
        XCTAssertFalse(ended.hasAuthoritativeFeed, "coverage belongs to a session")

        var gone = ClaudeStatusMachine()
        gone.reduce(ask("a"), at: 0)
        gone.reduce(.processPresent(false), at: 1)
        XCTAssertEqual(gone.outstandingBlockCount, 0)
        XCTAssertFalse(gone.hasAuthoritativeFeed)
    }

    /// A screen-raised block carries no call identity, so it must not touch the ledger — its
    /// provenance flag governs it exactly as before.
    func testAScreenBlockKeepsTheLedgerEmpty() {
        var m = ClaudeStatusMachine()
        m.reduce(.processPresent(true), at: 0)
        m.reduce(.screen(AgentScreenDetection(state: .blocked, visibleBlocker: true)), at: 1)
        XCTAssertEqual(m.status, .needsPermission)
        XCTAssertEqual(m.outstandingBlockCount, 0)
        // …and an authoritative hook still beats it on contact.
        XCTAssertEqual(m.reduce(post("Bash", "b"), at: 2), .working)
    }

    /// Ordering is not guaranteed on a socket: a result for a call we never saw open must not trap
    /// or wedge anything (validate-then-drop).
    func testUnknownAndOutOfOrderResolutionsAreHarmless() {
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(post("Bash", "never-opened"), at: 0), .working)
        m.reduce(ask("a"), at: 1)
        XCTAssertEqual(m.reduce(post("Bash", "never-opened"), at: 2), .needsPermission)
        XCTAssertEqual(m.reduce(post("AskUserQuestion", "a"), at: 3), .working)
    }
}
