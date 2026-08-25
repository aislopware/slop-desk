// CopyReceiptTests — the CROSSING and the WIRING, not the wording. Which number answers the doubt,
// how it is grouped and the sentence it sits in are `slopdesk_terminal::copy_receipt`'s and pinned
// there; the counting table lives beside the rule rather than in a second copy here.
//
// What is pinned here is what only Swift owns: that the two counts and the two sentences come back
// from ONE crossing together, and that the pane model publishes a receipt on every copy path with a
// fresh epoch (the chip's dwell identity).

import XCTest
@testable import SlopDeskWorkspaceCore

final class CopyReceiptTests: XCTestCase {
    // MARK: The crossing

    /// The counts LEAD the delivery and the sentences follow it, so a receipt that read its head at
    /// the wrong offset would come back with a right sentence beside a zero count.
    func testTheCountsAndTheSentencesCrossTogether() {
        let receipt = CopyReceipt(text: "make check", epoch: 1)
        XCTAssertEqual(receipt.charCount, 10)
        XCTAssertEqual(receipt.lineCount, 1)
        XCTAssertEqual(receipt.detail, "10 characters")
        XCTAssertEqual(receipt.label, "Copied · 10 characters")
    }

    /// A multi-line grab speaks the other number, which is the branch the two runs have to agree on.
    func testAMultiLineGrabCrossesSpeakingLines() {
        let receipt = CopyReceipt(text: "one\ntwo\nthree", epoch: 1)
        XCTAssertEqual(receipt.lineCount, 3)
        XCTAssertEqual(receipt.charCount, 13)
        XCTAssertEqual(receipt.label, "Copied · 3 lines")
    }

    /// An empty copy still crosses with a sentence — the door never answers nothing here, because a
    /// silent chip would read as a copy that failed.
    func testAnEmptyCopyStillCrossesWithASentence() {
        let receipt = CopyReceipt(text: "", epoch: 1)
        XCTAssertEqual(receipt.charCount, 0)
        XCTAssertEqual(receipt.lineCount, 1)
        XCTAssertEqual(receipt.label, "Copied · 0 characters")
    }

    // MARK: Model publication (the pane chip's source)

    @MainActor
    func testNoteClipboardCopyPublishesReceipt() {
        let model = TerminalViewModel()

        model.noteClipboardCopy("hello world")
        XCTAssertEqual(model.copyReceipt?.label, "Copied · 11 characters")

        let firstEpoch = model.copyReceipt?.epoch
        model.noteClipboardCopy("a\nb")
        XCTAssertEqual(model.copyReceipt?.label, "Copied · 2 lines")
        XCTAssertNotEqual(
            model.copyReceipt?.epoch, firstEpoch,
            "a re-copy mints a FRESH epoch so the chip's dwell timer restarts (retarget, not expire-early)",
        )

        model.clearCopyReceipt()
        XCTAssertNil(model.copyReceipt, "expiry clears the receipt (the chip unmounts)")
    }

    @MainActor
    func testEmptyCopyPublishesNothing() {
        let model = TerminalViewModel()
        model.noteClipboardCopy("")
        XCTAssertNil(model.copyReceipt, "nothing copied ⇒ nothing to confirm")
    }

    @MainActor
    func testCopyModeYankPublishesReceipt() {
        let recorder = RecordingSurfaceActions()
        recorder.selectionText = "yanked selection"
        let model = TerminalViewModel(surface: recorder)
        model.copyToPasteboard = { _ in }
        model.handleCopyModeKey(.char("y", control: false, shift: false))
        XCTAssertEqual(
            model.copyReceipt?.label, "Copied · 16 characters",
            "the copy-mode yank routes through noteClipboardCopy — the chip is its confirmation UI",
        )
    }
}
