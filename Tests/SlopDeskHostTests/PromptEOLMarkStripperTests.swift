import XCTest
@testable import SlopDeskHost

/// ``PromptEOLMarkStripper`` — the zsh PROMPT_SP cluster (`%B%S%#%s%b` mark + a COLUMNS-wide
/// space fill + PROMPT_CR) is width-dependent: replayed into a grid narrower than the recording
/// width the space fill wraps for real and the `%` mark surfaces as a stray line (the reconnect
/// stray-`%`-character bug). These pins use the EXACT byte shape captured from a live journal
/// (`\e[1m\e[7m%\e[27m\e[1m\e[0m` + SP×N + `\r \r` immediately before the shim's `133;D`/`133;A`).
final class PromptEOLMarkStripperTests: XCTestCase {
    /// The captured mark bytes: bold+standout `%`, standout-off, bold, reset.
    private let mark = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
    /// The captured tail: PROMPT_CR + the anti-xenl ` \r` tick.
    private let tail = "\r \r"
    private let dMark = "\u{1B}]133;D;0\u{07}"
    private let aMark = "\u{1B}]133;A\u{07}"

    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func strip(_ s: String) -> String {
        String(bytes: PromptEOLMarkStripper.strip(data(s)), encoding: .utf8) ?? "<invalid utf8>"
    }

    private func cluster(spaces: Int = 121) -> String {
        mark + String(repeating: " ", count: spaces) + tail
    }

    /// Every replacement re-asserts the SGR reset the swallowed cluster ended with.
    private let reset = "\u{1B}[0m"

    // MARK: Column-0 clusters (output ended with a newline) — become a bare SGR reset

    func testColumnZeroClusterBeforeDMarkIsExcised() {
        let input = "ls output\r\n" + cluster() + dMark + aMark + "prompt"
        XCTAssertEqual(
            strip(input), "ls output\r\n" + reset + dMark + aMark + "prompt",
            "a cluster at column 0 renders invisibly live — replay carries only the state reset",
        )
    }

    func testColumnZeroClusterBeforeAMarkIsExcised() {
        // Post-distill shape: the distiller consumes 133;D, so the cluster abuts 133;A.
        let input = "ls output\r\n" + cluster() + aMark + "prompt"
        XCTAssertEqual(strip(input), "ls output\r\n" + reset + aMark + "prompt")
    }

    func testClusterAtStreamStartIsExcised() {
        // First prompt of a session — preprompt fires before anything else was written.
        let input = cluster() + aMark + "prompt"
        XCTAssertEqual(strip(input), reset + aMark + "prompt")
    }

    func testColumnZeroReachedAcrossZeroWidthSequencesIsExcised() {
        // Captured `cd ~` shape: CRLF, then DECSCUSR (`\e[0 q`, zero-width), then the cluster.
        let input = "cd ~\r\n\u{1B}[0 q" + cluster() + dMark + aMark
        XCTAssertEqual(strip(input), "cd ~\r\n\u{1B}[0 q" + reset + dMark + aMark)
    }

    func testColumnZeroReachedAcrossPrivateModeSetResetIsExcised() {
        // Captured claude-exit shape: CRLF, SGR pair, then cursor-show (`\e[?25h`) — a DECSET
        // never moves the cursor, so the walk must look through it to the newline.
        let input = "done\r\n\u{1B}[2m\u{1B}[22m\u{1B}[?25h" + cluster() + aMark
        XCTAssertEqual(strip(input), "done\r\n\u{1B}[2m\u{1B}[22m\u{1B}[?25h" + reset + aMark)
    }

    func testColumnZeroReachedAcrossSyncEndAndAutowrapIsExcised() {
        // Captured inline-TUI epilogue: CRLF, DECSCUSR, sync-frame end (`\e[?2026l`), autowrap
        // re-enable (`\e[?7h`) — all zero-width, all looked through.
        let input = "ok.\r\n\u{1B}[0 q\u{1B}[?2026l\u{1B}[?7h" + cluster() + dMark + aMark
        XCTAssertEqual(strip(input), "ok.\r\n\u{1B}[0 q\u{1B}[?2026l\u{1B}[?7h" + reset + dMark + aMark)
    }

    func testColumnZeroReachedAcrossEraseInDisplayIsExcised() {
        // Captured prompt-redraw shape: CR, erase-below (`\e[J` — never moves the cursor),
        // cursor-show. The CR alone proves column 0.
        let input = "tail\r\u{1B}[J\u{1B}[?25h" + cluster() + aMark
        XCTAssertEqual(strip(input), "tail\r\u{1B}[J\u{1B}[?25h" + reset + aMark)
    }

    func testColumnOneCHAIsDirectColumnZeroProof() {
        // Captured inline-TUI redraw epilogue: `\e[13A\e[G` — CUU preserves the column and a
        // bare CHA (`\e[G`) sets column 1, so the cluster provably overprints at column 0.
        let input = "row\n\u{1B}[G\n\u{1B}[G\u{1B}[13A\u{1B}[G" + cluster() + dMark + aMark
        XCTAssertEqual(strip(input), "row\n\u{1B}[G\n\u{1B}[G\u{1B}[13A\u{1B}[G" + reset + dMark + aMark)
    }

    func testCursorUpPreservesColumnAcrossTheWalk() {
        // CUU/CUD move rows, never columns — looked through to the newline behind them.
        let input = "x\r\n\u{1B}[3A" + cluster() + aMark
        XCTAssertEqual(strip(input), "x\r\n\u{1B}[3A" + reset + aMark)
    }

    func testCHAToAnotherColumnEndsTheWalkAsUnknown() {
        // `\e[5G` parks the cursor at column 5 — not column 0, keep the safe CRLF.
        let input = "x\r\n\u{1B}[5G" + cluster() + aMark
        XCTAssertEqual(strip(input), "x\r\n\u{1B}[5G" + reset + "\r\n" + aMark)
    }

    func testCursorBackEndsTheWalkAsUnknown() {
        // CUB changes the column by a relative amount — unknowable, keep the safe CRLF.
        let input = "x\r\n\u{1B}[24D" + cluster() + aMark
        XCTAssertEqual(strip(input), "x\r\n\u{1B}[24D" + reset + "\r\n" + aMark)
    }

    func testAltScreenSwitchEndsTheWalkAsUnknown() {
        // `\e[?1049l` restores a SAVED cursor — the column is unknowable across it, so the safe
        // mid-line CRLF replacement must be kept even though a newline sits further back.
        let input = "x\r\n\u{1B}[?1049l" + cluster() + aMark
        XCTAssertEqual(strip(input), "x\r\n\u{1B}[?1049l" + reset + "\r\n" + aMark)
    }

    func testNonPrivateSetModeEndsTheWalkAsUnknown() {
        // ANSI SM (no `?` — e.g. IRM `\e[4h`) is not in the looked-through set: stay safe.
        let input = "x\r\n\u{1B}[4h" + cluster() + aMark
        XCTAssertEqual(strip(input), "x\r\n\u{1B}[4h" + reset + "\r\n" + aMark)
    }

    // MARK: Mid-line clusters (partial line / empty-Enter / Ctrl-C at prompt) — become reset+CRLF

    func testMidLineClusterBecomesCRLF() {
        let input = "partial" + cluster() + dMark + aMark + "prompt"
        XCTAssertEqual(
            strip(input), "partial" + reset + "\r\n" + dMark + aMark + "prompt",
            "the partial line is preserved on its own line; the prompt starts at column 0; no mark",
        )
    }

    func testEmptyEnterAtPromptShape() {
        // Captured shape: prompt tail + 133;B + EL, then the cluster (no newline in between).
        let promptTail = "\u{2AB}\u{1B}[0m \u{1B}]133;B\u{07}\u{1B}[K"
        let input = promptTail + cluster() + dMark + aMark
        XCTAssertEqual(strip(input), promptTail + reset + "\r\n" + dMark + aMark)
    }

    func testHashMarkForRootShellsIsHandled() {
        let rootMark = "\u{1B}[1m\u{1B}[7m#\u{1B}[27m\u{1B}[1m\u{1B}[0m"
        let input = "out\r\n" + rootMark + String(repeating: " ", count: 79) + tail + aMark
        XCTAssertEqual(strip(input), "out\r\n" + reset + aMark)
    }

    // MARK: Adversarial-review regressions

    func testBareMarkWithoutSGRIsADeliberateMiss() {
        // The two-sided SGR requirement: a plain `%` + fill + CR abutting the anchor is REAL
        // command output whenever the session `unsetopt PROMPT_SP` (the pad-to-clear progress
        // idiom) — it must never be treated as a mark. The dumb-TERM bare mark is the price.
        let input = "Build: 100%" + String(repeating: " ", count: 20) + "\r" + dMark + aMark + "PS1 "
        XCTAssertEqual(strip(input), input, "plain-text %/# before the anchor is user output, not a mark")
    }

    func testOneSidedSGRIsNotACluster() {
        // A coloured progress line's own reset (`…100%\e[0m` + pad + CR) satisfies only the
        // suffix side — still user output, still untouched.
        let input = "\u{1B}[32mBuild: 100%\u{1B}[0m" + String(repeating: " ", count: 20) + "\r" + dMark
        XCTAssertEqual(strip(input), input)
    }

    func testCommandTrailingSGRResetCannotBleedColour() {
        // The prefix walk swallows a reset the COMMAND wrote right before the cluster; the
        // emitted replacement reset re-establishes the exact post-cluster live state, so the
        // command's colour can never bleed into the replayed prompt.
        let input = "\u{1B}[31mred\u{1B}[0m" + cluster() + dMark + aMark + "PS1 "
        let out = strip(input)
        XCTAssertEqual(
            out, "\u{1B}[31mred" + reset + "\r\n" + dMark + aMark + "PS1 ",
            "swallowed user SGRs are replaced by an equivalent reset before the anchor",
        )
    }

    // MARK: Non-clusters — pass through untouched

    func testShortSpaceRunIsNotACluster() {
        let input = "x%   \r" + aMark
        XCTAssertEqual(strip(input), input, "a <8-space run is regular content, not PROMPT_SP fill")
    }

    func testClusterWithoutFollowing133AnchorIsUntouched() {
        let input = "x\r\n" + cluster() + "plain text, no mark"
        XCTAssertEqual(strip(input), input, "only clusters abutting 133;D/133;A are zsh preprompt output")
    }

    func testNonMarkCharacterIsUntouched() {
        let input = "x\r\nZ" + String(repeating: " ", count: 79) + "\r" + aMark
        XCTAssertEqual(strip(input), input)
    }

    func testSpacesWithoutTrailingCRAreUntouched() {
        let input = "x\r\n%" + String(repeating: " ", count: 79) + aMark
        XCTAssertEqual(strip(input), input)
    }

    func testOtherOSC133SubcommandsAreNotAnchors() {
        let input = "x\r\n" + cluster() + "\u{1B}]133;C\u{07}"
        XCTAssertEqual(strip(input), input)
    }

    func testPlainTextAndEmptyInputPassThrough() {
        XCTAssertEqual(strip("hello world"), "hello world")
        XCTAssertEqual(PromptEOLMarkStripper.strip(Data()), Data())
    }

    // MARK: Composition properties

    func testEveryPromptCycleInATranscriptIsCleaned() {
        let block = "output line\r\n" + cluster() + dMark + aMark + "PS1 \u{2AB} "
        let input = String(repeating: block, count: 3)
        let expected = String(
            repeating: "output line\r\n" + reset + dMark + aMark + "PS1 \u{2AB} ", count: 3,
        )
        XCTAssertEqual(strip(input), expected)
    }

    func testIdempotent() {
        let input = "a\r\n" + cluster() + dMark + "mid" + cluster() + aMark + "p"
        let once = PromptEOLMarkStripper.strip(data(input))
        XCTAssertEqual(PromptEOLMarkStripper.strip(once), once)
    }

    func testReplayTransformPipelineRemovesClusters() throws {
        // End-to-end through the production composition (distill → query-strip → mark-strip):
        // a full captured-shape prompt cycle must come out with no fill run and no stray mark.
        let transform = try XCTUnwrap(ScrollbackReplayTransform.make(environment: [:]))
        let input = "ls output\r\n" + cluster() + dMark + aMark + "PS1 "
        let out = try XCTUnwrap(String(bytes: transform(data(input)), encoding: .utf8))
        XCTAssertFalse(out.contains("       "), "the COLUMNS-wide space fill must not survive replay")
        XCTAssertFalse(out.contains("\u{1B}[7m%"), "the standout mark must not survive replay")
        XCTAssertTrue(out.contains(aMark), "the 133;A prompt anchor must survive (block-jump counts)")
    }
}
