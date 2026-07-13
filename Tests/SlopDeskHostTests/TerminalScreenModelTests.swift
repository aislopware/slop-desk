import XCTest
@testable import SlopDeskHost

/// ``TerminalScreenModel`` — the `screen` verb's on-demand VT grid reconstruction.
///
/// Pure model tests: bytes in → grid out. No PTY, no socket, no session (hang-safety).
final class TerminalScreenModelTests: XCTestCase {
    private let ESC = "\u{1B}"

    private func render(
        _ input: String, rows: Int = 5, cols: Int = 10,
    ) -> TerminalScreenModel.Snapshot {
        var model = TerminalScreenModel(rows: rows, cols: cols)
        model.feed(Data(input.utf8))
        return model.snapshot()
    }

    // MARK: Plain text / control chars

    func testPlainTextWithCRLF() {
        let snap = render("hello\r\nworld")
        XCTAssertEqual(snap.lines[0], "hello")
        XCTAssertEqual(snap.lines[1], "world")
        XCTAssertEqual(snap.cursorRow, 1)
        XCTAssertEqual(snap.cursorCol, 5)
    }

    func testBareLFKeepsColumn() {
        // LF without CR moves down but keeps the column (raw VT semantics — a shell in
        // canonical mode translates, but the model must reproduce what actually arrived).
        let snap = render("ab\ncd")
        XCTAssertEqual(snap.lines[0], "ab")
        XCTAssertEqual(snap.lines[1], "  cd")
    }

    func testCarriageReturnOverwrites() {
        let snap = render("aaaa\rbb")
        XCTAssertEqual(snap.lines[0], "bbaa")
    }

    func testBackspaceMovesWithoutErase() {
        let snap = render("ab\u{08}c")
        XCTAssertEqual(snap.lines[0], "ac")
    }

    func testTabAdvancesToNext8Stop() {
        let snap = render("a\tb", cols: 20)
        XCTAssertEqual(snap.lines[0], "a       b")
    }

    // MARK: Wrap (DECAWM + deferred wrap)

    func testAutowrapAtRightEdge() {
        let snap = render("0123456789AB", rows: 3, cols: 10)
        XCTAssertEqual(snap.lines[0], "0123456789")
        XCTAssertEqual(snap.lines[1], "AB")
    }

    func testDeferredWrapPending() {
        // Writing exactly the last column must NOT wrap yet: a CR right after stays on the
        // same row (the classic vt100 pending-wrap trick every full-width status bar relies on).
        let snap = render("0123456789\rX", rows: 3, cols: 10)
        XCTAssertEqual(snap.lines[0], "X123456789")
        XCTAssertEqual(snap.lines[1], "")
    }

    func testAutowrapDisabledPinsAtLastColumn() {
        let snap = render("\(ESC)[?7l0123456789ABC", rows: 3, cols: 10)
        XCTAssertEqual(snap.lines[0], "012345678C")
        XCTAssertEqual(snap.lines[1], "")
    }

    // MARK: Cursor movement

    func testCUPAndOverwrite() {
        let snap = render("aaaa\r\nbbbb\(ESC)[1;2Hxy")
        XCTAssertEqual(snap.lines[0], "axya")
        XCTAssertEqual(snap.lines[1], "bbbb")
    }

    func testCursorRelativeMoves() {
        // CUP to 3;3, up 1, forward 2, write.
        let snap = render("\(ESC)[3;3H\(ESC)[1A\(ESC)[2CZ")
        XCTAssertEqual(snap.lines[1], "    Z")
    }

    func testCHAAndVPA() {
        let snap = render("\(ESC)[4dX\(ESC)[8GY", rows: 5, cols: 10)
        XCTAssertEqual(snap.lines[3], "X      Y")
    }

    // MARK: Erase

    func testEraseInLineVariants() {
        // Fill a row, then EL 0 from middle.
        let snap0 = render("abcdefghij\(ESC)[1;5H\(ESC)[K", rows: 2, cols: 10)
        XCTAssertEqual(snap0.lines[0], "abcd")
        // EL 1: start → cursor inclusive.
        let snap1 = render("abcdefghij\(ESC)[1;5H\(ESC)[1K", rows: 2, cols: 10)
        XCTAssertEqual(snap1.lines[0], "     fghij")
        // EL 2: whole line.
        let snap2 = render("abcdefghij\(ESC)[2K", rows: 2, cols: 10)
        XCTAssertEqual(snap2.lines[0], "")
    }

    func testEraseInDisplayFromCursor() {
        let snap = render("aaaa\r\nbbbb\r\ncccc\(ESC)[2;3H\(ESC)[J", rows: 4, cols: 10)
        XCTAssertEqual(snap.lines[0], "aaaa")
        XCTAssertEqual(snap.lines[1], "bb")
        XCTAssertEqual(snap.lines[2], "")
    }

    func testEraseAllHomesNothingButClears() {
        let snap = render("aaaa\r\nbbbb\(ESC)[2J")
        XCTAssertEqual(snap.lines[0], "")
        XCTAssertEqual(snap.lines[1], "")
        // ED 2 clears but does NOT home the cursor (xterm keeps position).
        XCTAssertEqual(snap.cursorRow, 1)
    }

    func testEraseChars() {
        let snap = render("abcdefghij\(ESC)[1;3H\(ESC)[4X", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "ab    ghij")
    }

    // MARK: Insert / delete chars + lines

    func testInsertAndDeleteChars() {
        let ins = render("abcdef\(ESC)[1;3H\(ESC)[2@", rows: 2, cols: 10)
        XCTAssertEqual(ins.lines[0], "ab  cdef")
        let del = render("abcdef\(ESC)[1;3H\(ESC)[2P", rows: 2, cols: 10)
        XCTAssertEqual(del.lines[0], "abef")
    }

    func testInsertAndDeleteLines() {
        let base = "aaaa\r\nbbbb\r\ncccc\r\ndddd"
        let ins = render("\(base)\(ESC)[2;1H\(ESC)[1L", rows: 4, cols: 10)
        XCTAssertEqual(ins.lines, ["aaaa", "", "bbbb", "cccc"])
        let del = render("\(base)\(ESC)[2;1H\(ESC)[1M", rows: 4, cols: 10)
        XCTAssertEqual(del.lines, ["aaaa", "cccc", "dddd", ""])
    }

    // MARK: Scrolling / regions

    func testLineFeedAtBottomScrolls() {
        let snap = render("1\r\n2\r\n3\r\n4", rows: 3, cols: 10)
        XCTAssertEqual(snap.lines, ["2", "3", "4"])
    }

    func testScrollRegionConfinesScroll() {
        // Rows 2–3 are the region; LF at region bottom scrolls ONLY rows 2–3.
        let snap = render(
            "top\r\nAAA\r\nBBB\r\nbot\(ESC)[2;3r\(ESC)[3;1H\nNEW",
            rows: 4, cols: 10,
        )
        XCTAssertEqual(snap.lines[0], "top")
        XCTAssertEqual(snap.lines[1], "BBB")
        XCTAssertEqual(snap.lines[2], "NEW")
        XCTAssertEqual(snap.lines[3], "bot")
    }

    func testReverseIndexAtTopScrollsDown() {
        let snap = render("1\r\n2\(ESC)[1;1H\(ESC)MX", rows: 3, cols: 10)
        XCTAssertEqual(snap.lines, ["X", "1", "2"])
    }

    // MARK: Alt screen

    func testAltScreenEnterDrawExitRestoresMain() {
        let snap = render("main\(ESC)[?1049hALT SCREEN\(ESC)[?1049l")
        XCTAssertFalse(snap.altScreen)
        XCTAssertEqual(snap.lines[0], "main")
        // 1049 restores the saved cursor on exit.
        XCTAssertEqual(snap.cursorRow, 0)
        XCTAssertEqual(snap.cursorCol, 4)
    }

    func testOpenAltScreenIsTheSnapshot() {
        let snap = render("main\(ESC)[?1049h\(ESC)[2;3HTUI", rows: 4, cols: 10)
        XCTAssertTrue(snap.altScreen)
        XCTAssertEqual(snap.lines[0], "")
        XCTAssertEqual(snap.lines[1], "  TUI")
    }

    func testAltScreenReentryIsCleared() {
        // 1049 clears the alt grid on every enter — no stale TUI pixels from a prior visit.
        let snap = render("\(ESC)[?1049hOLD\(ESC)[?1049l\(ESC)[?1049h\(ESC)[2;1HNEW")
        XCTAssertTrue(snap.altScreen)
        XCTAssertEqual(snap.lines[0], "")
        XCTAssertEqual(snap.lines[1], "NEW")
    }

    // MARK: Charset / wide / combining

    func testDECGraphicsBoxDrawing() {
        let snap = render("\(ESC)(0lqqk\(ESC)(B x", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "┌──┐ x")
    }

    func testShiftOutUsesG1() {
        let snap = render("\(ESC))0a\u{0E}q\u{0F}b", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "a─b")
    }

    func testWideCharOccupiesTwoColumns() {
        let snap = render("字x", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "字x")
        XCTAssertEqual(snap.cursorCol, 3)
    }

    func testOverwritingHalfAWidePairBlanksPartner() {
        // Write 字 at cols 0–1, then overwrite col 0 → the continuation must not orphan.
        let snap = render("字\(ESC)[1;1HZ", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "Z")
    }

    func testCombiningMarkAttachesToPreviousCell() {
        let snap = render("e\u{0301}x", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "éx")
        XCTAssertEqual(snap.cursorCol, 2)
    }

    // MARK: REP / OSC skip / DECALN / RIS

    func testRepeatLastGraphic() {
        let snap = render("a\(ESC)[3b", rows: 2, cols: 10)
        XCTAssertEqual(snap.lines[0], "aaaa")
    }

    func testOSCAndDCSBodiesAreInvisible() {
        let snap = render("\(ESC)]0;my title\u{07}ok\(ESC)P+q544e\(ESC)\\!", rows: 2, cols: 20)
        XCTAssertEqual(snap.lines[0], "ok!")
    }

    func testSGRIsDiscarded() {
        let snap = render("\(ESC)[1;31mred\(ESC)[0m plain", rows: 2, cols: 20)
        XCTAssertEqual(snap.lines[0], "red plain")
    }

    func testDECALNFillsWithE() {
        let snap = render("\(ESC)#8", rows: 2, cols: 3)
        XCTAssertEqual(snap.lines, ["EEE", "EEE"])
    }

    func testRISResetsEverything() {
        let snap = render("junk\(ESC)[?1049h\(ESC)cX", rows: 3, cols: 10)
        XCTAssertFalse(snap.altScreen)
        XCTAssertEqual(snap.lines[0], "X")
        XCTAssertEqual(snap.lines[1], "")
    }

    // MARK: Cursor visibility / split feeds

    func testCursorHideShow() {
        XCTAssertFalse(render("\(ESC)[?25l").cursorVisible)
        XCTAssertTrue(render("\(ESC)[?25l\(ESC)[?25h").cursorVisible)
    }

    func testSequenceSplitAcrossFeeds() {
        var model = TerminalScreenModel(rows: 3, cols: 10)
        model.feed(Data("ab\(ESC)[1".utf8))
        model.feed(Data(";1HZ".utf8))
        XCTAssertEqual(model.snapshot().lines[0], "Zb")
    }

    func testUTF8ScalarSplitAcrossFeeds() {
        var model = TerminalScreenModel(rows: 2, cols: 10)
        let bytes = Array("é".utf8)
        model.feed(Data(bytes[0..<1]))
        model.feed(Data(bytes[1...]))
        XCTAssertEqual(model.snapshot().lines[0], "é")
    }

    // MARK: Robustness (validate-then-drop)

    func testHostileParamsNeverTrap() {
        // Huge params, degenerate region, moves off-grid, unknown finals — must not crash
        // and must clamp instead of trap.
        let snap = render(
            "\(ESC)[9999;9999H\(ESC)[9999A\(ESC)[9999X\(ESC)[5;2r\(ESC)[999b\(ESC)[?9999hok",
            rows: 3, cols: 10,
        )
        XCTAssertEqual(snap.rows, 3)
        // The clamped cursor lands on (0, 9); "ok" wraps across the right edge.
        XCTAssertTrue(snap.lines[0].hasSuffix("o"))
        XCTAssertEqual(snap.lines[1], "k")
    }

    func testVimLikeSmoke() {
        // A miniature vim paint: enter alt, clear, tildes down the left, a status line,
        // cursor home. The dump must read like the editor looks.
        var paint = "\(ESC)[?1049h\(ESC)[2J\(ESC)[H"
        for row in 2...4 { paint += "\(ESC)[\(row);1H~" }
        paint += "\(ESC)[5;1H-- INSERT --\(ESC)[1;1H"
        let snap = render(paint, rows: 5, cols: 20)
        XCTAssertTrue(snap.altScreen)
        XCTAssertEqual(snap.lines, ["", "~", "~", "~", "-- INSERT --"])
        XCTAssertEqual(snap.cursorRow, 0)
        XCTAssertEqual(snap.cursorCol, 0)
    }
}
