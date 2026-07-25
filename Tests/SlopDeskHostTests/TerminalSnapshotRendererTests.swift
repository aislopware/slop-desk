import XCTest
@testable import SlopDeskHost

/// ``TerminalSnapshotRenderer`` / ``TerminalReplaySnapshot`` — the cold-reattach
/// state-transfer path: render the model's STATE once instead of replaying byte history.
///
/// The proof discipline is differential + idempotent (the LineOverprintCollapser habit):
/// - **Round trip**: feeding `render(A)` to a FRESH model must reproduce A's visible state
///   (grid text + styles, scrollback text, cursor, modes).
/// - **Canonicalization**: `render(feed(render(A))) == render(A)` byte-exact — over curated
///   cases AND seeded fuzz streams spanning the VT vocabulary.
///
/// Pure model tests: bytes in → bytes out. No PTY, no socket, no session (hang-safety).
final class TerminalSnapshotRendererTests: XCTestCase {
    private let ESC = "\u{1B}"

    // MARK: Harness

    private func makeModel(_ input: Data, rows: Int = 6, cols: Int = 12) -> TerminalScreenModel {
        var model = TerminalScreenModel(rows: rows, cols: cols, scrollbackLimit: 1000)
        model.feed(input)
        return model
    }

    /// Round-trips `input` through render → fresh model and asserts the VISIBLE state
    /// matches: cell text + styles for both screens, scrollback cells, cursor, wrap, modes.
    /// (Soft-wrap FLAGS are excluded: a full-width line printed with an explicit CRLF is
    /// visually identical to a wrapped one but carries no flag — both render the same bytes,
    /// which the idempotence assertion pins.)
    private func assertRoundTrip(
        _ input: String, rows: Int = 6, cols: Int = 12,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        assertRoundTrip(Data(input.utf8), rows: rows, cols: cols, file: file, line: line)
    }

    private func assertRoundTrip(
        _ input: Data, rows: Int = 6, cols: Int = 12,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        let a = makeModel(input, rows: rows, cols: cols)
        let renderedA = TerminalSnapshotRenderer.render(a.replaySnapshot())
        let b = makeModel(renderedA, rows: rows, cols: cols)
        let sa = a.replaySnapshot()
        let sb = b.replaySnapshot()
        XCTAssertEqual(sa.mainCells, sb.mainCells, "main grid diverged", file: file, line: line)
        XCTAssertEqual(sa.usingAlt, sb.usingAlt, file: file, line: line)
        // The INACTIVE alt grid is invisible state the renderer deliberately does not
        // transfer (`?1049h` clears on re-entry); compare it only while active.
        if sa.usingAlt {
            XCTAssertEqual(sa.altCells, sb.altCells, "alt grid diverged", file: file, line: line)
        }
        XCTAssertEqual(
            sa.scrollback.map(\.cells), sb.scrollback.map(\.cells),
            "scrollback diverged", file: file, line: line,
        )
        XCTAssertEqual(sa.cursorRow, sb.cursorRow, "cursorRow", file: file, line: line)
        XCTAssertEqual(sa.cursorCol, sb.cursorCol, "cursorCol", file: file, line: line)
        XCTAssertEqual(sa.wrapPending, sb.wrapPending, "wrapPending", file: file, line: line)
        XCTAssertEqual(sa.cursorVisible, sb.cursorVisible, file: file, line: line)
        XCTAssertEqual(sa.autowrap, sb.autowrap, file: file, line: line)
        XCTAssertEqual(sa.originMode, sb.originMode, file: file, line: line)
        XCTAssertEqual(sa.scrollTop, sb.scrollTop, file: file, line: line)
        XCTAssertEqual(sa.scrollBottom, sb.scrollBottom, file: file, line: line)
        XCTAssertEqual(sa.g0Graphics, sb.g0Graphics, file: file, line: line)
        XCTAssertEqual(sa.g1Graphics, sb.g1Graphics, file: file, line: line)
        XCTAssertEqual(sa.usingG1, sb.usingG1, file: file, line: line)
        XCTAssertEqual(sa.applicationKeypad, sb.applicationKeypad, file: file, line: line)
        XCTAssertEqual(sa.cursorShape, sb.cursorShape, "DECSCUSR shape", file: file, line: line)
        XCTAssertEqual(sa.style, sb.style, "live SGR", file: file, line: line)
        // Canonicalization: rendering the round-tripped model reproduces the SAME bytes.
        let renderedB = TerminalSnapshotRenderer.render(sb)
        XCTAssertEqual(renderedA, renderedB, "render is not idempotent", file: file, line: line)
    }

    // MARK: Round trip — text, styles, scrollback

    func testPlainPromptRoundTrip() {
        assertRoundTrip("$ ls\r\nREADME.md  Sources\r\n$ ")
    }

    func testScrollbackCaptureAndRoundTrip() {
        // 10 numbered lines through a 6-row grid: 5 lines scroll into history (the 6th line
        // is on screen when line 7 prints, etc.).
        let input = (1...10).map { "line \($0)" }.joined(separator: "\r\n")
        let a = makeModel(Data(input.utf8))
        XCTAssertEqual(a.replaySnapshot().scrollback.count, 4)
        assertRoundTrip(Data(input.utf8))
    }

    func testColors16And256AndTruecolorRoundTrip() {
        assertRoundTrip(
            "\(ESC)[31mred\(ESC)[0m \(ESC)[1;38;5;196mbright\(ESC)[0m\r\n"
                + "\(ESC)[48;2;10;20;30mrgb bg\(ESC)[0m plain \(ESC)[93;104mbright16\(ESC)[0m",
        )
    }

    func testColonFormSGRRoundTrip() {
        // 4:3 (undercurl → underline sub-param) must not misparse `3` as italic; colon-form
        // truecolor with a colorspace id decodes to the same color as the semicolon form.
        assertRoundTrip("\(ESC)[4:3mcurl\(ESC)[0m \(ESC)[38:2::7;8;9mmix\(ESC)[0m x")
        var model = TerminalScreenModel(rows: 2, cols: 20, scrollbackLimit: 0)
        model.feed(Data("\(ESC)[38:2:1:2:3mX".utf8))
        XCTAssertEqual(model.replaySnapshot().mainCells[0][0].style.fg, .rgb(1, 2, 3))
        model.feed(Data("\(ESC)[4:0mY".utf8))
        // 4:0 = underline-off — must NOT have reset the truecolor fg via a bare `0`.
        XCTAssertEqual(model.replaySnapshot().mainCells[0][1].style.fg, .rgb(1, 2, 3))
    }

    func testBCEEraseFillCarriesBackground() {
        var model = TerminalScreenModel(rows: 3, cols: 8, scrollbackLimit: 0)
        model.feed(Data("\(ESC)[44m\(ESC)[2Jx".utf8))
        let snap = model.replaySnapshot()
        XCTAssertEqual(snap.mainCells[1][3].style.bg, .indexed(4), "ED 2 must fill with the live bg")
        XCTAssertEqual(snap.mainCells[0][0].text, "x")
        assertRoundTrip(Data("\(ESC)[44m\(ESC)[2Jx".utf8))
    }

    func testWideCharsAndCombiningRoundTrip() {
        assertRoundTrip("日本語テスト wide\r\ne\u{0301}combined")
    }

    func testSoftWrappedScrollbackLineIsReJoined() {
        // A 30-char line through a 12-col grid wraps onto 3 rows; scroll it fully into
        // history and the renderer must emit ONE logical line (client re-wraps at its width).
        let long = String(repeating: "abcdefghij", count: 3)
        let input = long + "\r\n" + (1...8).map { "l\($0)" }.joined(separator: "\r\n")
        let a = makeModel(Data(input.utf8))
        let rendered = TerminalSnapshotRenderer.render(a.replaySnapshot())
        // The logical line survives as one contiguous run in the output.
        XCTAssertNotNil(String(data: rendered, encoding: .utf8)?.range(of: long))
        assertRoundTrip(Data(input.utf8))
    }

    // MARK: Round trip — screen state

    func testAltScreenRoundTrip() {
        // vim-like: enter 1049, paint a status line at the bottom, cursor home.
        let input = "shell history\r\n\(ESC)[?1049h\(ESC)[6;1H\(ESC)[7m-- STATUS --\(ESC)[0m\(ESC)[H"
        assertRoundTrip(input)
    }

    func testAltScreenExitRestoresMain() {
        assertRoundTrip("before\r\n\(ESC)[?1049htui\(ESC)[?1049lafter")
    }

    func testScrollRegionAndOriginModeRoundTrip() {
        assertRoundTrip("\(ESC)[2;5r\(ESC)[?6hinside\r\nregion")
    }

    func testDeferredWrapPendingSurvives() {
        // Fill the last column exactly: wrapPending must survive the snapshot so the next
        // printable in the LIVE tail wraps (and a CR stays on the same row).
        assertRoundTrip("0123456789AB", rows: 3, cols: 12)
    }

    func testDeferredWrapPendingWithWideLead() {
        // The wide char occupies the last two columns; re-arming must re-print the LEAD.
        assertRoundTrip("0123456789日", rows: 3, cols: 12)
    }

    func testHiddenCursorAndNoAutowrapRoundTrip() {
        assertRoundTrip("\(ESC)[?25l\(ESC)[?7lhidden")
    }

    func testDECGraphicsCharsetRoundTrip() {
        assertRoundTrip("\(ESC)(0lqqk\r\nx x")
    }

    func testApplicationKeypadRoundTrip() {
        assertRoundTrip("\(ESC)=app keypad")
    }

    func testCursorShapeSurvivesSnapshot() {
        // The zsh integration's bar-at-prompt (`ESC[5 q` from precmd) must survive a
        // state-transfer reattach — the raw history carried it, so the snapshot must too.
        assertRoundTrip("$ ls\r\n\(ESC)[5 q$ ")
        let model = makeModel(Data("\(ESC)[5 qprompt".utf8))
        XCTAssertEqual(model.replaySnapshot().cursorShape, 5)
        let rendered = TerminalSnapshotRenderer.render(model.replaySnapshot())
        let text = String(bytes: rendered, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\(ESC)[5 q"), "rendered snapshot must re-emit DECSCUSR")
    }

    func testCursorShapeResetAndRISDropToDefault() {
        // `0 q` (the preexec reset) and RIS both return to the terminal default — nothing
        // re-emitted beyond the preamble's own `0 q` wipe.
        let reset = makeModel(Data("\(ESC)[5 qx\(ESC)[0 q".utf8))
        XCTAssertEqual(reset.replaySnapshot().cursorShape, 0)
        let ris = makeModel(Data("\(ESC)[5 qx\(ESC)c".utf8))
        XCTAssertEqual(ris.replaySnapshot().cursorShape, 0)
    }

    func testComposePreservesPromptCursorShape() {
        let raw = Data("churn\r\n\(ESC)[5 q❯ ".utf8)
        let out = TerminalReplaySnapshot.compose(raw: raw, rows: 6, cols: 12)
        let text = String(bytes: out, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\(ESC)[5 q"), "compose must carry the prompt cursor shape")
    }

    func testProgressOverprintCollapsesToFinalRevision() {
        // The motivating case: 200 CR-overprinted progress ticks render as ONE line.
        var input = ""
        for pct in 0...200 {
            input += "Progress \(pct / 2)%\r"
        }
        input += "\r\nDone.\r\n$ "
        let a = makeModel(Data(input.utf8), rows: 6, cols: 40)
        let rendered = TerminalSnapshotRenderer.render(a.replaySnapshot())
        let text = String(data: rendered, encoding: .utf8) ?? ""
        XCTAssertEqual(text.components(separatedBy: "Progress").count - 1, 1, "one revision survives")
        assertRoundTrip(Data(input.utf8), rows: 6, cols: 40)
    }

    // MARK: ED 3 / scrollback cap

    func testED3ClearsCapturedScrollback() {
        let input = (1...10).map { "line \($0)" }.joined(separator: "\r\n") + "\(ESC)[3J"
        let a = makeModel(Data(input.utf8))
        XCTAssertTrue(a.replaySnapshot().scrollback.isEmpty)
    }

    func testScrollbackCapEvictsOldest() {
        var model = TerminalScreenModel(rows: 3, cols: 8, scrollbackLimit: 5)
        model.feed(Data((1...20).map { "l\($0)" }.joined(separator: "\r\n").utf8))
        let scrollback = model.replaySnapshot().scrollback
        XCTAssertEqual(scrollback.count, 5)
        XCTAssertEqual(scrollback.last?.cells.first?.text, "l")
    }

    func testAltScreenNeverAccruesScrollback() {
        let feed = (1...10).map { "alt\($0)" }.joined(separator: "\r\n")
        var model = TerminalScreenModel(rows: 3, cols: 8, scrollbackLimit: 100)
        model.feed(Data("\(ESC)[?1049h\(feed)".utf8))
        XCTAssertTrue(model.replaySnapshot().scrollback.isEmpty)
    }

    func testSubRegionScrollNeverAccruesScrollback() {
        let feed = (1...10).map { "r\($0)" }.joined(separator: "\r\n")
        var model = TerminalScreenModel(rows: 6, cols: 8, scrollbackLimit: 100)
        model.feed(Data("\(ESC)[2;5r\(feed)".utf8))
        XCTAssertTrue(model.replaySnapshot().scrollback.isEmpty)
    }

    // MARK: Composer (trailing-fragment hold-back + input modes)

    func testComposerHoldsBackTrailingIncompleteEscape() {
        let raw = Data("hello\(ESC)[3".utf8)
        let composed = TerminalReplaySnapshot.compose(raw: raw, rows: 4, cols: 20)
        XCTAssertTrue(composed.suffix(3).elementsEqual(Data("\(ESC)[3".utf8)), "dangling CSI re-appended last")
    }

    func testComposerHoldsBackTrailingIncompleteUTF8() {
        var raw = Data("ok ".utf8)
        raw.append(contentsOf: [0xE6, 0x97]) // first 2 of 3 bytes of 日
        let composed = TerminalReplaySnapshot.compose(raw: raw, rows: 4, cols: 20)
        XCTAssertTrue(composed.suffix(2).elementsEqual([0xE6, 0x97]))
        // And the partial scalar did NOT render as garbage before the dangling bytes.
        XCTAssertFalse(composed.dropLast(2).contains(0xE6))
    }

    func testSplitTrailingIncompleteUTF8Complete() {
        let complete = Data("日本".utf8)
        let split = TerminalReplaySnapshot.splitTrailingIncompleteUTF8(complete)
        XCTAssertEqual(split.head, complete)
        XCTAssertTrue(split.dangling.isEmpty)
    }

    func testComposerReassertsLiveInputModes() {
        // A "live TUI" armed mouse + bracketed paste and never disarmed them: the snapshot
        // must re-assert both AFTER the rendered state (trailing bytes).
        let raw = Data("\(ESC)[?1000h\(ESC)[?2004htui running".utf8)
        let composed = TerminalReplaySnapshot.compose(raw: raw, rows: 4, cols: 20)
        let text = String(data: composed, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\(ESC)[?1000h"))
        XCTAssertTrue(text.contains("\(ESC)[?2004h"))
        // The reassert must TRAIL the rendered content (the stripped-replay discipline).
        if let content = text.range(of: "tui running"), let mode = text.range(of: "\(ESC)[?1000h") {
            XCTAssertTrue(content.upperBound <= mode.lowerBound, "input-mode reassert must come last")
        } else {
            XCTFail("rendered content or reassert missing")
        }
    }

    func testComposerNetsExitedTUIModesToNothing() {
        let raw = Data("\(ESC)[?1000hused mouse\(ESC)[?1000lprompt".utf8)
        let composed = TerminalReplaySnapshot.compose(raw: raw, rows: 4, cols: 20)
        XCTAssertFalse((String(data: composed, encoding: .utf8) ?? "").contains("?1000"))
    }

    // MARK: Seeded fuzz — canonicalization over the VT vocabulary

    func testFuzzRoundTripCanonicalization() {
        // Deterministic LCG (no Date/entropy in tests): 300 streams over the vocabulary the
        // collapser fuzz uses — text, wide scalars, erases, SGR, cursor motion, scroll
        // regions, alt screen, wrap edges. Every stream must round-trip visibly and render
        // idempotently; a divergence prints its seed for replay.
        var state: UInt64 = 0x5EED_50DE
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let atoms: [String] = [
            "hello ", "wide日", "e\u{0301}", "\r\n", "\r", "\n", "\t",
            "\(ESC)[31m", "\(ESC)[1;44m", "\(ESC)[38;5;100m", "\(ESC)[48;2;9;8;7m", "\(ESC)[0m",
            "\(ESC)[2J", "\(ESC)[K", "\(ESC)[1K", "\(ESC)[2K", "\(ESC)[3J",
            "\(ESC)[H", "\(ESC)[3;4H", "\(ESC)[2A", "\(ESC)[3B", "\(ESC)[4C", "\(ESC)[2D",
            "\(ESC)[2;5r", "\(ESC)[r", "\(ESC)[?6h", "\(ESC)[?6l",
            "\(ESC)[?1049h", "\(ESC)[?1049l", "\(ESC)[?25l", "\(ESC)[?25h",
            "\(ESC)[?7l", "\(ESC)[?7h", "\(ESC)7", "\(ESC)8", "\(ESC)(0", "\(ESC)(B",
            "\(ESC)[2L", "\(ESC)[1M", "\(ESC)[3P", "\(ESC)[2@", "\(ESC)[2X", "\(ESC)[1S", "\(ESC)[1T",
            "0123456789AB", "=", "\(ESC)=", "\(ESC)>",
            "\(ESC)[5 q", "\(ESC)[2 q", "\(ESC)[0 q", "\(ESC)c",
        ]
        for seed in 0..<300 {
            var input = ""
            for _ in 0..<(4 + next(20)) {
                input += atoms[next(atoms.count)]
            }
            let rows = 3 + next(5)
            let cols = 6 + next(10)
            let a = makeModel(Data(input.utf8), rows: rows, cols: cols)
            let renderedA = TerminalSnapshotRenderer.render(a.replaySnapshot())
            let b = makeModel(renderedA, rows: rows, cols: cols)
            let renderedB = TerminalSnapshotRenderer.render(b.replaySnapshot())
            XCTAssertEqual(
                renderedA, renderedB,
                "seed \(seed) rows \(rows) cols \(cols) input \(input.debugDescription)",
            )
            let sa = a.replaySnapshot()
            let sb = b.replaySnapshot()
            XCTAssertEqual(sa.mainCells, sb.mainCells, "seed \(seed) main grid \(input.debugDescription)")
            if sa.usingAlt {
                XCTAssertEqual(sa.altCells, sb.altCells, "seed \(seed) alt grid \(input.debugDescription)")
            }
            XCTAssertEqual(
                sa.scrollback.map(\.cells), sb.scrollback.map(\.cells),
                "seed \(seed) scrollback \(input.debugDescription)",
            )
            XCTAssertEqual(sa.cursorRow, sb.cursorRow, "seed \(seed) cursorRow \(input.debugDescription)")
            XCTAssertEqual(sa.cursorCol, sb.cursorCol, "seed \(seed) cursorCol \(input.debugDescription)")
            XCTAssertEqual(sa.wrapPending, sb.wrapPending, "seed \(seed) wrapPending \(input.debugDescription)")
        }
    }
}
