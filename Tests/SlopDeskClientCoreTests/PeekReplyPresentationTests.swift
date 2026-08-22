// PeekReplyPresentationTests — pins what the Peek & Reply card SAYS, below both platforms, and the
// agent readout every compact surface shares with it.
//
// The card is drawn twice now (docs/56 stage D): an `NSPanel` on the Mac, a paper card on the phone.
// What is pinned here is everything the two halves must word identically — the header's caption and
// the order its parts truncate in, the queue counter's hard cut, the note a pane with no reported
// question gets — plus the status→reading→ink mapping the header's glyph and the sidebar's own mark
// both read.

import SlopDeskAgentDetect
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

final class PeekReplyPresentationTests: XCTestCase {
    // MARK: - The agent readout

    /// The one status with NO reading is the one with no agent — every other state draws something,
    /// because a pane that has an agent and shows nothing for it is indistinguishable from a pane
    /// that has none.
    func testOnlyTheAbsentAgentDrawsNothing() {
        XCTAssertNil(AgentReadout.reading(.none))
        XCTAssertEqual(AgentReadout.reading(.idle), .resting)
        XCTAssertEqual(AgentReadout.reading(.working), .working)
        XCTAssertEqual(AgentReadout.reading(.done), .done)
        XCTAssertEqual(AgentReadout.reading(.needsPermission), .awaiting)
    }

    /// The resting states spend NO colour — that is the whole hue budget's premise, and it is what
    /// leaves anything left to spend on the two states that need a person.
    func testTheRestingStatesSpendNoColour() {
        XCTAssertEqual(AgentReadout.ink(.none), .muted)
        XCTAssertEqual(AgentReadout.ink(.idle), .muted)
    }

    /// ⚠️ `thinking` and `awaiting` are separate INKS that land on the same warm rung, and they stay
    /// separate cases on purpose: what tells a thinking agent from a waiting question is the
    /// silhouette and the motion, never the hue. Fusing them here would make a future re-tune of one
    /// silently re-tune the other.
    func testThinkingAndAwaitingAreDistinctInksOnPurpose() {
        XCTAssertEqual(AgentReadout.ink(.working), .thinking)
        XCTAssertEqual(AgentReadout.ink(.needsPermission), .awaiting)
        XCTAssertNotEqual(AgentReadout.ink(.working), AgentReadout.ink(.needsPermission))
        XCTAssertEqual(AgentReadout.ink(.done), .done)
    }

    /// The glyph BOX is shared, not agreed: the four readings have different advance widths, so the
    /// box is what holds the header still while a pane's state changes under it — and a box that
    /// differed between platforms would shift the title beside it.
    func testTheGlyphBoxIsOneNumber() {
        XCTAssertGreaterThan(AgentReadout.glyphBox, 0)
    }

    // MARK: - The header's caption

    /// The scent goes LAST. The caption is tail-truncated on both platforms, so this order is what
    /// makes a squeeze eat the prose first, the `i/n` count second, and the status word never.
    func testTheStatusWordComesFirstSoASqueezeNeverEatsIt() {
        let caption = PeekReplyPresentation.caption(
            status: .needsPermission, scent: "2/5 · Wiring the panel",
        )
        XCTAssertTrue(caption.hasPrefix(AgentReadout.label(.needsPermission)))
        XCTAssertTrue(caption.hasSuffix("Wiring the panel"))
    }

    /// No scent ⇒ the caption is the status word ALONE, byte for byte. An idle, non-Claude or
    /// dead-feed pane must not gain a separator with nothing after it.
    func testAPaneWithNoScentGetsTheBareLabel() {
        XCTAssertEqual(
            PeekReplyPresentation.caption(status: .working, scent: nil),
            AgentReadout.label(.working),
        )
    }

    // MARK: - The queue counter

    /// A queue of one is not a queue: the counter is `nil` and the calm static caption stays. The
    /// cut is HARD — never both at once — which is why the counter answers `nil` rather than "1 of 1".
    func testAQueueOfOneKeepsTheCalmCaption() {
        XCTAssertNil(PeekReplyPresentation.counter(nil))
        XCTAssertEqual(PeekReplyPresentation.counter((position: 3, total: 7)), "3 of 7")
    }

    // MARK: - The question block

    /// A pane with no reported question still gets a card — the status said it was blocked — so the
    /// block prints the card's OWN note, and says so, because the note reads in the supporting ink
    /// while a real question reads in the reading one.
    func testAMissingQuestionBecomesTheCardsOwnNote() {
        let absent = PeekReplyPresentation.question(nil)
        XCTAssertTrue(absent.isPlaceholder)
        XCTAssertFalse(absent.text.isEmpty)

        let asked = PeekReplyPresentation.question("Run `rm -rf build`?")
        XCTAssertFalse(asked.isPlaceholder)
        XCTAssertEqual(asked.text, "Run `rm -rf build`?")
    }

    /// An EMPTY question is the host's own text and stays it — the placeholder is for a question that
    /// was never reported, not for one that came back short. Treating them alike would put the card's
    /// voice where the agent's belongs.
    func testAnEmptyQuestionIsStillTheAgentsOwn() {
        XCTAssertFalse(PeekReplyPresentation.question("").isPlaceholder)
    }
}
