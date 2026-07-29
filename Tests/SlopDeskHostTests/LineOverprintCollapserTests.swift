import XCTest
@testable import SlopDeskHost

/// ``LineOverprintCollapser`` — the progress-bar churn pass of the replay transform.
final class LineOverprintCollapserTests: XCTestCase {
    private func collapse(_ string: String) -> String {
        let collapsed = LineOverprintCollapser.collapse(Data(string.utf8))
        return String(bytes: collapsed, encoding: .utf8) ?? "<not UTF-8>"
    }

    /// A scrollback ring opens at an arbitrary byte offset, so the column its first line starts in
    /// is unknown and that line is never collapsed. A leading `CRLF` — what the PTY's `ONLCR`
    /// puts at the end of every real line anyway — anchors column 0; this returns what the pass
    /// did to everything AFTER it.
    private func collapseAnchored(_ string: String, line: UInt = #line) -> String {
        let anchor = "\r\n"
        let result = collapse(anchor + string)
        XCTAssertTrue(result.hasPrefix(anchor), "anchor must survive", line: line)
        return String(result.dropFirst(anchor.count))
    }

    // MARK: Nothing to collapse

    func testEmptyInputPassesThrough() {
        XCTAssertEqual(LineOverprintCollapser.collapse(Data()), Data())
    }

    func testPlainTranscriptIsByteIdentical() {
        let transcript = "first line\nsecond line\r\nthird\twith tab\n\u{1B}[31mred\u{1B}[0m\n"
        XCTAssertEqual(collapse(transcript), transcript)
    }

    func testCRLFLineEndingsSurvive() {
        XCTAssertEqual(collapse("alpha\r\nbeta\r\n"), "alpha\r\nbeta\r\n")
    }

    // MARK: The point of the pass

    func testProgressChurnCollapsesToTheLastRevision() {
        var churn = ""
        for percent in 0...100 { churn += "Writing objects: \(percent)% (37/3700)\r" }
        churn += "Writing objects: 100% (3700/3700), done.\n"
        XCTAssertEqual(collapseAnchored(churn), "\rWriting objects: 100% (3700/3700), done.\n")
    }

    /// An erase-and-repaint loop collapses to its LAST erase plus the final text: that erase blanks
    /// columns no successor touches, so it is what put them in their final state.
    func testEraseInLineChurnCollapsesToTheLastRevision() {
        var churn = ""
        for percent in 0...50 { churn += "\u{1B}[2K\r[\(percent)/50] Compiling Foo.swift" }
        churn += "\u{1B}[2K\rBuild complete!\n"
        XCTAssertEqual(
            collapseAnchored(churn),
            "\r[50/50] Compiling Foo.swift\u{1B}[2K\rBuild complete!\n",
        )
    }

    /// A revision that only ERASES is never dropped for showing nothing — its blanking decides
    /// those columns, and dropping it would resurrect what it wiped.
    func testEraseOnlyRevisionIsNotDroppedAsInvisible() {
        let input = "aaa\u{1B}[1Gbbbbb\u{1B}[1G\u{1B}[1K\r\n"
        XCTAssertEqual(collapseAnchored(input), "\u{1B}[1Gbbbbb\u{1B}[1G\u{1B}[1K\r\n")
    }

    /// `CSI 1 K` erases only to the LEFT of the cursor, so it cannot hide a wider predecessor.
    func testEraseToCursorDoesNotCoverAWiderPredecessor() {
        XCTAssertEqual(collapseAnchored("aaaaaa\rbb\u{1B}[1K\n"), "aaaaaa\rbb\u{1B}[1K\n")
    }

    /// `CSI 0 K` clears through the line's end, so everything before it is gone — but its own
    /// paint to the LEFT of the cursor survives.
    func testEraseToEndCoversPredecessorsButKeepsItsOwnPaint() {
        XCTAssertEqual(collapseAnchored("aaaaaa\rbb\u{1B}[K\n"), "\rbb\u{1B}[K\n")
        XCTAssertEqual(collapseAnchored("aaaaaa\rbb\u{1B}[K\rc\n"), "\rbb\u{1B}[K\rc\n")
    }

    func testColumnZeroCHAIsARevisionBoundaryLikeCR() {
        XCTAssertEqual(collapseAnchored("aaaa\u{1B}[Gbbbb\u{1B}[1Gcccc\n"), "\u{1B}[1Gcccc\n")
    }

    /// A shorter successor does NOT cover a longer predecessor — a real terminal leaves the tail
    /// on screen, and so must the replay.
    func testWiderPredecessorSurvivesAShorterSuccessor() {
        XCTAssertEqual(collapseAnchored("aaaaaa\rbb\n"), "aaaaaa\rbb\n")
    }

    func testEqualWidthSuccessorCoversItsPredecessor() {
        XCTAssertEqual(collapseAnchored("aaa\rbbb\n"), "\rbbb\n")
    }

    /// Coverage is DISPLAY width: two wide scalars cover four ASCII columns.
    func testWideScalarsCountAsTwoColumns() {
        XCTAssertEqual(collapseAnchored("abcd\r日本\n"), "\r日本\n")
        XCTAssertEqual(collapseAnchored("abcde\r日本\n"), "abcde\r日本\n")
    }

    func testChurnAcrossSeparateLinesCollapsesIndependently() {
        let input = "a\rbb\r\nccc\rd\r\nee\rff\r\n"
        XCTAssertEqual(collapseAnchored(input), "\rbb\r\nccc\rd\r\n\rff\r\n")
    }

    // MARK: Where the line starts

    /// The ring opens at an arbitrary byte offset, so the first line's column is unknown and its
    /// opening revision may extend past anything a successor covers — it is never dropped.
    func testOpeningLineOfTheBufferIsNeverDropped() {
        XCTAssertEqual(collapse("aaa\rbbb\n"), "aaa\rbbb\n")
    }

    /// A bare `LF` moves DOWN without returning to column 0 (the PTY's `ONLCR` is what normally
    /// makes it `CRLF`), so the next line's opening revision paints from that column — and its
    /// tail survives a shorter successor.
    func testBareLFCarriesTheColumnToTheNextLine() {
        XCTAssertEqual(collapseAnchored("a\rbb\nccc\rd\n"), "\rbb\nccc\rd\n")
    }

    /// After an unmodelled (verbatim) line the cursor column is a guess, so the next line's
    /// opening revision is kept too — the guess is never allowed to drop visible content. The
    /// line after THAT ends in `CRLF`, which re-anchors column 0, and collapsing resumes.
    func testColumnIsUnknownAfterAVerbatimLineThenRecovers() {
        XCTAssertEqual(
            collapseAnchored("aaa\u{1B}[1Abbb\nccc\rccc\r\nddd\reee\r\n"),
            "aaa\u{1B}[1Abbb\nccc\rccc\r\n\reee\r\n",
        )
    }

    // MARK: Carried state

    func testSGRFromADroppedRevisionIsCarriedToTheSurvivor() {
        // The colour is set in the dropped first revision; the survivor never re-states it.
        XCTAssertEqual(collapseAnchored("\u{1B}[31mred\rgrn\n"), "\r\u{1B}[31mgrn\n")
    }

    func testNeutralPrivateModesAreCarried() {
        XCTAssertEqual(collapseAnchored("\u{1B}[?25lwork\rdone\n"), "\r\u{1B}[?25ldone\n")
    }

    func testCarriedStateIsOrderedOldestFirst() {
        XCTAssertEqual(collapseAnchored("\u{1B}[31ma\r\u{1B}[1mb\rc\n"), "\r\u{1B}[31m\u{1B}[1mc\n")
    }

    /// A full SGR reset kills every carried attribute before it — only state set after the reset
    /// remains load-bearing.
    func testSGRResetCollapsesTheCarriedAttributes() {
        XCTAssertEqual(
            collapseAnchored("\u{1B}[31m\u{1B}[1ma\r\u{1B}[0m\u{1B}[32mb\rc\n"),
            "\r\u{1B}[0m\u{1B}[32mc\n",
        )
    }

    /// A toggle is STATE, not a byte stream: only its last setting is carried.
    func testCarriedTogglesKeepTheirLastSettingOnly() {
        XCTAssertEqual(
            collapseAnchored("\u{1B}[?25la\r\u{1B}[?25hb\rc\n"),
            "\r\u{1B}[?25hc\n",
        )
    }

    /// The carry cap must not eat a one-shot toggle: `?25l` set once survives thousands of dropped
    /// SGR-bearing revisions, because the toggles are held as state OUTSIDE the byte cap.
    func testHiddenCursorSurvivesCarryCapOverflow() {
        var input = "\u{1B}[?25lstart"
        for i in 0..<1200 { input += "\r\u{1B}[3\(i % 8)mprogress" }
        input += "\rlast-one\n"
        let out = collapseAnchored(input)
        XCTAssertTrue(out.contains("\u{1B}[?25l"), "hidden-cursor toggle lost by the carry cap")
        XCTAssertTrue(out.hasSuffix("last-one\n"))
    }

    // MARK: Bail-outs — never cleaner than raw, never wrong

    func testCursorUpMakesTheLineVerbatim() {
        let input = "one\rtwo\u{1B}[1A\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testOSCMarkMakesTheLineVerbatimSoTheDistillerKeepsItsMarks() {
        let input = "\u{1B}]133;A\u{07}% \u{1B}]133;B\u{07}aaa\rbbb\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testCRInsideAnOSCBodyIsNotARevisionBoundary() {
        let input = "\u{1B}]0;a\rb\u{07}text\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testNonNeutralPrivateModeMakesTheLineVerbatim() {
        let input = "aaa\u{1B}[?1049h\rbbb\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testBackspaceMakesTheLineVerbatim() {
        let input = "aaa\u{08}\rbbb\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testTwoByteEscapeMakesTheLineVerbatim() {
        let input = "aaa\u{1B}M\rbbb\n"
        XCTAssertEqual(collapse(input), input)
    }

    func testVerticalTabFlushesTheLineVerbatim() {
        let input = "aaa\rbbb\u{0B}ccc\rddd\n"
        XCTAssertEqual(collapseAnchored(input), input)
    }

    func testMalformedUTF8MakesTheLineVerbatim() {
        let input = Data([0x61, 0xFF, 0x62, 0x0D, 0x63, 0x0A])
        XCTAssertEqual(LineOverprintCollapser.collapse(input), input)
    }

    /// Overlong UTF-8 (structurally complete, semantically invalid — `E0 80 80` is an overlong
    /// `U+0000`) gets NO width credit: a terminal rejects it and paints nothing, so crediting it
    /// coverage would let a successor bury a predecessor whose residue is still on screen.
    func testOverlongUTF8MakesTheLineVerbatim() {
        var input = Data("\r\nabcd\rxxx".utf8)
        input.append(contentsOf: [0xE0, 0x80, 0x80])
        input.append(UInt8(ascii: "\n"))
        XCTAssertEqual(LineOverprintCollapser.collapse(input), input)
    }

    /// A revision OPENED by a zero-width scalar (combining mark, ZWJ, variation selector) attaches
    /// that scalar to the last printed cell — a PREDECESSOR's cell. Dropping the predecessor would
    /// re-target the mark, so the line is verbatim.
    func testRevisionOpenedByACombiningMarkIsVerbatim() {
        let input = Data("\r\nQ\r\nab\r\u{0301}xy\n".utf8)
        XCTAssertEqual(LineOverprintCollapser.collapse(input), input)
    }

    /// A combining mark AFTER a painted glyph stays inside its own revision — no bail-out.
    func testCombiningMarkAfterPaintStillCollapses() {
        XCTAssertEqual(
            Array(collapseAnchored("abc\re\u{0301}xy\n").utf8),
            Array("\re\u{0301}xy\n".utf8),
        )
    }

    /// The opening revision survives even a successor that erases the WHOLE line: its start column
    /// is unknown (the ring opened mid-stream), so its paint may have wrapped onto an extra row at
    /// recording time that no same-line erase can be proven to bury.
    func testOpeningRevisionSurvivesAFullCoverageSuccessor() {
        let input = "aaa\rbbb\u{1B}[2K\n"
        XCTAssertEqual(collapse(input), input)
    }

    /// An UNSAFE line keeps its byte-for-byte guarantee past the compaction threshold: compaction
    /// must not fire once modelling has failed (its coverage numbers are garbage there), no matter
    /// how many `CR` revisions pile up afterwards.
    func testUnsafeLineSurvivesTheCompactionThresholdVerbatim() {
        var input = "start\u{1B}[1Aup"
        for i in 0..<70000 { input += "\rrev\(i % 10)" }
        input += "\n"
        XCTAssertEqual(collapseAnchored(input), input)
    }

    func testTruncatedTrailingEscapeIsPreserved() {
        let input = "aaa\rbbb\u{1B}["
        XCTAssertEqual(collapse(input), input)
    }

    func testUnterminatedFinalLineStillCollapses() {
        XCTAssertEqual(collapseAnchored("aaa\rbbb"), "\rbbb")
    }

    // MARK: Differential — the rendered screen must not change

    /// The load-bearing claim of the pass: what a terminal DISPLAYS after the collapsed stream is
    /// what it displays after the raw one. Rendered by ``TerminalScreenModel`` at a grid every
    /// revision fits inside (the documented autowrap gap lives outside this claim).
    private func assertRendersIdentically(
        _ stream: String, rows: Int = 24, cols: Int = 80, line: UInt = #line,
    ) {
        let raw = Data(stream.utf8)
        let collapsed = LineOverprintCollapser.collapse(raw)
        var rawModel = TerminalScreenModel(rows: rows, cols: cols)
        rawModel.feed(raw)
        var collapsedModel = TerminalScreenModel(rows: rows, cols: cols)
        collapsedModel.feed(collapsed)
        XCTAssertEqual(
            collapsedModel.snapshot().lines, rawModel.snapshot().lines,
            "collapsed replay renders differently", line: line,
        )
        XCTAssertLessThanOrEqual(collapsed.count, raw.count, "never longer than raw", line: line)
    }

    func testRendersIdenticallyForCRProgress() {
        var stream = ""
        for percent in 0...100 { stream += "Enumerating objects: \(percent)% (37/3700)\r" }
        stream += "Enumerating objects: 100% (3700/3700), done.\n"
        assertRendersIdentically(stream)
    }

    func testRendersIdenticallyForEraseLineProgress() {
        var stream = ""
        for step in 0...50 { stream += "\u{1B}[2K\r[\(step)/50] Compiling Foo.swift" }
        stream += "\u{1B}[2K\rBuild complete!\n"
        assertRendersIdentically(stream)
    }

    func testRendersIdenticallyWhenResidueSurvives() {
        assertRendersIdentically("a very long progress line\rshort\nnext\n")
    }

    func testRendersIdenticallyForColouredSpinner() {
        let frames = ["|", "/", "-", "\\"]
        var stream = "\u{1B}[?25l"
        for tick in 0..<40 {
            stream += "\u{1B}[3\(tick % 8)m\(frames[tick % 4]) building \(tick)%\u{1B}[K\r"
        }
        stream += "\u{1B}[0m\u{1B}[?25hdone\n"
        assertRendersIdentically(stream)
    }

    func testRendersIdenticallyForMixedTranscript() {
        var stream = "$ swift build\n"
        for step in 0...30 { stream += "\u{1B}[2K\r[\(step)/30] Compiling\u{1B}[1;32m X\u{1B}[0m" }
        stream += "\u{1B}[2K\rBuild complete! (12.3s)\n"
        stream += "$ git push\n"
        for percent in stride(from: 0, through: 100, by: 5) {
            stream += "Writing objects: \(percent)%\r"
        }
        stream += "Writing objects: 100%, done.\nTo github.com:x/y.git\n"
        assertRendersIdentically(stream)
    }

    /// Modelling failure AFTER the memory backstop compacted: the buffered survivors are emitted
    /// verbatim (everything compaction dropped was dropped while the line was still modelled, so
    /// the screen is unchanged), and the unmodelled bytes ride along untouched.
    func testUnsafeAfterCompactionStillRendersIdentically() {
        var stream = ""
        for i in 0..<66000 { stream += "progress \(i % 100)\r" }
        stream += "tail\u{1B}[1A\u{1B}[1Bdone\n"
        assertRendersIdentically(stream)
    }

    /// Seeded fuzz over the vocabulary this pass reasons about — text, the column-0 resets, all
    /// three erases, carried state, and sequences that must force the verbatim fallback. Every
    /// generated stream must render identically before and after collapsing. Deterministic (fixed
    /// seed) so a failure is reproducible; the generator keeps every line inside the grid, since
    /// wrapping is the documented gap rather than a claim under test. 2,000 streams ≈ 2 s — the
    /// original 120,000-stream sweep was a one-time development run, not this gate.
    func testFuzzedStreamsRenderIdentically() {
        var rng = SplitMix64(seed: 0x51_0BDE_5C15_10BD)
        for iteration in 0..<2000 {
            let stream = Self.randomStream(&rng)
            let raw = Data(stream.utf8)
            let collapsed = LineOverprintCollapser.collapse(raw)
            var rawModel = TerminalScreenModel(rows: 24, cols: 80)
            rawModel.feed(raw)
            var collapsedModel = TerminalScreenModel(rows: 24, cols: 80)
            collapsedModel.feed(collapsed)
            XCTAssertEqual(
                collapsedModel.snapshot().lines, rawModel.snapshot().lines,
                "iteration \(iteration) renders differently: \(Array(stream.utf8))",
            )
            XCTAssertLessThanOrEqual(collapsed.count, raw.count, "iteration \(iteration) grew")
        }
    }

    /// Splitmix64 — a two-line deterministic generator, so a fuzz failure reproduces exactly.
    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z % UInt64(bound))
        }
    }

    private static func randomStream(_ rng: inout SplitMix64) -> String {
        // Widths are tracked so no line ever reaches the 80th column: autowrap is the pass's
        // documented gap, not a property under test.
        let wrapGuard = 60
        var stream = ""
        var column = 0
        for _ in 0..<(20 + rng.next(60)) {
            switch rng.next(14) {
            case 0,
                 1,
                 2,
                 3: // printable run
                let width = 1 + rng.next(10)
                if column + width > wrapGuard {
                    stream += "\r\n"
                    column = 0
                }
                for _ in 0..<width { stream.append(Character(UnicodeScalar(97 + rng.next(26))!)) }
                column += width
            case 4: // wide scalars — two columns each
                if column + 4 > wrapGuard {
                    stream += "\r\n"
                    column = 0
                }
                stream += "日本"
                column += 4
            case 5,
                 6:
                stream += "\r"
                column = 0
            case 7:
                stream += "\r\n"
                column = 0
            case 8: stream += "\n" // bare LF — moves down, keeps the column
            case 9: stream += "\u{1B}[\(rng.next(3))K" // EL modes 0/1/2
            case 10: stream += "\u{1B}[\(30 + rng.next(8))m"
            case 11: stream += rng.next(2) == 0 ? "\u{1B}[?25l" : "\u{1B}[?7h"
            case 12:
                stream += "\u{1B}[1G"
                column = 0
            default: // sequences that must force the verbatim fallback
                switch rng.next(4) {
                case 0: stream += "\u{1B}[1A"
                case 1: stream += "\u{1B}]0;title\u{07}"
                case 2:
                    stream += "\t"
                    column = (column / 8 + 1) * 8
                default: stream += "\u{1B}[?1049h\u{1B}[?1049l"
                }
            }
        }
        return stream
    }

    // MARK: Pipeline composition

    func testTransformCollapsesCommandOutputChurnEndToEnd() throws {
        var stream = "\u{1B}]133;A\u{07}% \u{1B}]133;B\u{07}\u{1B}]133;E;git push\u{07}git push"
        stream += "\u{1B}]133;C\u{07}\r\n"
        for percent in 0...100 { stream += "Enumerating objects: \(percent)% (37/3700)\r" }
        stream += "Enumerating objects: 100% (3700/3700), done.\n"
        stream += "To github.com:x/y.git\n"
        stream += "\u{1B}]133;D;0\u{07}"

        let raw = Data(stream.utf8)
        let transform = ScrollbackReplayTransform.make(environment: [:], reassertInputModes: false)
        let collapsed = try XCTUnwrap(transform)(raw)
        XCTAssertLessThan(collapsed.count, raw.count / 20, "progress churn must not survive replay")
        let text = try XCTUnwrap(String(bytes: collapsed, encoding: .utf8))
        XCTAssertTrue(text.contains("Enumerating objects: 100% (3700/3700), done."))
        XCTAssertTrue(text.contains("To github.com:x/y.git"))
        XCTAssertFalse(text.contains("Enumerating objects: 50%"))
    }

    /// There is no kill switch. `SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT=0` used to hand the churn
    /// back verbatim; it is gone, because megabytes of superseded percentage ticks is not a mode.
    func testThereIsNoKillSwitchForTheChurn() throws {
        var stream = ""
        for percent in 0...100 { stream += "Writing objects: \(percent)%\r" }
        stream += "done.\n"
        let raw = Data(stream.utf8)
        let env = ["SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT": "0"] // ignored — no such gate
        let transform = try XCTUnwrap(
            ScrollbackReplayTransform.make(environment: env, reassertInputModes: false),
        )
        XCTAssertLessThan(transform(raw).count, raw.count / 20)
    }
}
