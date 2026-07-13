// CopyReceiptTests — pins the pure copy-receipt wording (`COPIED · N CHARS` / `N LINES`) and the
// counting rules behind both transient chips (pane + window-level), so the two mounts can never drift
// and a formatting regression is a test failure, not a squint at the UI.

import XCTest
@testable import SlopDeskWorkspaceCore

final class CopyReceiptTests: XCTestCase {
    // MARK: Label wording (the chip's caps register)

    func testSingleLineSpeaksChars() {
        let receipt = CopyReceipt(text: "make check", epoch: 1)
        XCTAssertEqual(receipt.label, "COPIED · 10 CHARS")
        XCTAssertEqual(receipt.lineCount, 1)
    }

    func testSingleCharIsSingular() {
        XCTAssertEqual(CopyReceipt(text: "x", epoch: 1).label, "COPIED · 1 CHAR")
    }

    func testMultiLineSpeaksLines() {
        let receipt = CopyReceipt(text: "one\ntwo\nthree", epoch: 1)
        XCTAssertEqual(receipt.label, "COPIED · 3 LINES", "a multi-line grab answers the whole-block doubt in lines")
        XCTAssertEqual(receipt.charCount, 13)
    }

    func testTrailingNewlineDoesNotInflateTheLineCount() {
        XCTAssertEqual(
            CopyReceipt(text: "foo\n", epoch: 1).label, "COPIED · 4 CHARS",
            "a shell line copy `foo\\n` is ONE line (chars voice), not two lines",
        )
        XCTAssertEqual(CopyReceipt(text: "a\nb\n", epoch: 1).lineCount, 2)
    }

    func testCountsAreGroupedDeterministically() {
        let text = String(repeating: "x", count: 1204)
        XCTAssertEqual(
            CopyReceipt(text: text, epoch: 1).label, "COPIED · 1,204 CHARS",
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
        XCTAssertEqual(model.copyReceipt?.label, "COPIED · 11 CHARS")
        XCTAssertEqual(confirmations, 1, "the legacy confirmation hook fires alongside the receipt")

        let firstEpoch = model.copyReceipt?.epoch
        model.noteClipboardCopy("a\nb")
        XCTAssertEqual(model.copyReceipt?.label, "COPIED · 2 LINES")
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
            model.copyReceipt?.label, "COPIED · 16 CHARS",
            "the copy-mode yank routes through noteClipboardCopy — the chip is its confirmation UI",
        )
    }
}
