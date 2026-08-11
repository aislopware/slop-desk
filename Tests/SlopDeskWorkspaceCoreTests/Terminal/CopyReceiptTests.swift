// CopyReceiptTests — pins the pure copy-receipt wording (`Copied · N characters` / `N lines`) and the
// counting rules behind the transient copy chip, so a formatting regression is a test failure, not a
// squint at the UI. Sentence case since 2026-08-11: the chip moved off the glass onto the floating
// family's paper capsule, and took that family's voice with it (see `SlatePaperCapsule`).

import XCTest
@testable import SlopDeskWorkspaceCore

final class CopyReceiptTests: XCTestCase {
    // MARK: Label wording (the chip's caps register)

    func testSingleLineSpeaksChars() {
        let receipt = CopyReceipt(text: "make check", epoch: 1)
        XCTAssertEqual(receipt.label, "Copied · 10 characters")
        XCTAssertEqual(receipt.lineCount, 1)
    }

    func testSingleCharIsSingular() {
        XCTAssertEqual(CopyReceipt(text: "x", epoch: 1).label, "Copied · 1 character")
    }

    func testMultiLineSpeaksLines() {
        let receipt = CopyReceipt(text: "one\ntwo\nthree", epoch: 1)
        XCTAssertEqual(receipt.label, "Copied · 3 lines", "a multi-line grab answers the whole-block doubt in lines")
        XCTAssertEqual(receipt.charCount, 13)
    }

    func testTrailingNewlineDoesNotInflateTheLineCount() {
        XCTAssertEqual(
            CopyReceipt(text: "foo\n", epoch: 1).label, "Copied · 4 characters",
            "a shell line copy `foo\\n` is ONE line (chars voice), not two lines",
        )
        XCTAssertEqual(CopyReceipt(text: "a\nb\n", epoch: 1).lineCount, 2)
    }

    func testCountsAreGroupedDeterministically() {
        let text = String(repeating: "x", count: 1204)
        XCTAssertEqual(
            CopyReceipt(text: text, epoch: 1).label, "Copied · 1,204 characters",
            "grouping is locale-independent — the instrument voice reads identically on every machine",
        )
        XCTAssertEqual(CopyReceipt.grouped(999), "999")
        XCTAssertEqual(CopyReceipt.grouped(1000), "1,000")
        XCTAssertEqual(CopyReceipt.grouped(2_654_321), "2,654,321")
    }

    func testCharCountIsGraphemes() {
        XCTAssertEqual(CopyReceipt(text: "é🇻🇳", epoch: 1).charCount, 2, "user-visible characters, not bytes")
    }

    // MARK: Model publication (the pane chip's source)

    @MainActor
    func testNoteClipboardCopyPublishesReceiptAndFiresLegacyHook() {
        let model = TerminalViewModel()
        var confirmations = 0
        model.onCopyConfirmation = { confirmations += 1 }

        model.noteClipboardCopy("hello world")
        XCTAssertEqual(model.copyReceipt?.label, "Copied · 11 characters")
        XCTAssertEqual(confirmations, 1, "the legacy confirmation hook fires alongside the receipt")

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
        var confirmations = 0
        model.onCopyConfirmation = { confirmations += 1 }
        model.noteClipboardCopy("")
        XCTAssertNil(model.copyReceipt, "nothing copied ⇒ nothing to confirm")
        XCTAssertEqual(confirmations, 0)
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
