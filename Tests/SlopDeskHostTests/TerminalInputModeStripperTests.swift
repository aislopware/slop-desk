import XCTest
@testable import SlopDeskHost
@testable import SlopDeskTransport

/// ``TerminalInputModeStripper`` — replayed history must never arm the client's input reporting
/// (mouse / kitty keyboard / in-band resize), and the net final state must be re-assertable for a
/// TUI that is still alive across the reattach.
final class TerminalInputModeStripperTests: XCTestCase {
    private func strip(_ s: String) -> (out: String, state: InputModeFinalState) {
        let (data, state) = TerminalInputModeStripper.strip(Data(s.utf8))
        // Lossy decode is fine here: inputs are ASCII test fixtures, outputs are compared whole.
        // swiftlint:disable:next optional_data_string_conversion
        return (String(decoding: data, as: UTF8.self), state)
    }

    // MARK: - Stripping

    /// The reattach-garbage shape from the field: nvim enables mouse + in-band resize + kitty
    /// event reporting at its start and disables them megabytes later. BOTH ends are removed —
    /// the replay must not even TRANSIENTLY arm the modes (`?2048h` makes the client emit a size
    /// report the instant it is processed; mouse/kitty leak any mid-replay user input).
    func testBalancedTUIModeChurnVanishesEntirely() {
        let (out, state) = strip(
            "$ vi .\r\n\u{1B}[?1049h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2048h\u{1B}[>3u"
                + "EDITOR CONTENT"
                + "\u{1B}[<u\u{1B}[?2048l\u{1B}[?1006l\u{1B}[?1002l\u{1B}[?1049l$ done\r\n",
        )
        XCTAssertEqual(out, "$ vi .\r\n\u{1B}[?1049hEDITOR CONTENT\u{1B}[?1049l$ done\r\n")
        XCTAssertTrue(state.isNeutral, "everything nets to fresh-terminal defaults")
        XCTAssertEqual(state.reassertSequence, Data())
    }

    /// A session that ends INSIDE a TUI nets to that TUI's modes: the stream is stripped, and
    /// the re-assert sequence re-creates exactly the enabled set (+ the kitty stack) so a live
    /// `vim` keeps mouse reporting across a cold reattach.
    func testUnbalancedEnablesNetIntoReassertSequence() {
        let (out, state) = strip("\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2048h\u{1B}[>3uTUI")
        XCTAssertEqual(out, "TUI")
        XCTAssertFalse(state.isNeutral)
        XCTAssertEqual(
            state.reassertSequence,
            Data("\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2048h\u{1B}[>3u".utf8),
        )
    }

    /// Re-assert emits only modes that net ON — a trailing unmatched reset (`?1003l` with no
    /// prior set) is stripped and re-asserts nothing (a fresh terminal is already off).
    func testNetOffModesReassertNothing() {
        let (out, state) = strip("a\u{1B}[?1003l\u{1B}[?1000h\u{1B}[?1000lb")
        XCTAssertEqual(out, "ab")
        XCTAssertTrue(state.isNeutral)
    }

    /// A DECSET carrying tracked AND untracked params in one CSI (`?1049;2004h` — real, see
    /// ``TerminalModeTracker``) is REWRITTEN: the alt-screen param survives for the replay's
    /// rendering, the bracketed-paste param is tracked + removed.
    func testMixedParamDECSETIsRewritten() {
        let (out, state) = strip("\u{1B}[?1049;2004hX\u{1B}[?2004;1049lY")
        XCTAssertEqual(out, "\u{1B}[?1049hX\u{1B}[?1049lY")
        XCTAssertEqual(state.modes[2004], false)
        XCTAssertTrue(state.isNeutral)
    }

    /// Display-state modes pass through untouched: alt screen, cursor visibility, autowrap,
    /// synchronized output. ANSI (non-`?`) SM/RM and CSIs with intermediates are never touched.
    func testDisplayModesAndForeignCSIsPassThrough() {
        let kept = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7h\u{1B}[?2026h\u{1B}[?2026l\u{1B}[4h\u{1B}[2 q\u{1B}[?1002$p"
        let (out, state) = strip(kept)
        XCTAssertEqual(out, kept)
        XCTAssertTrue(state.isNeutral)
    }

    /// Kitty pop on an empty stack is a no-op; a pop count covers multiple entries; `=` mutates
    /// the top entry (or the base with an empty stack) with set/or/clear semantics.
    func testKittyStackSimulation() {
        let (out, state) = strip("\u{1B}[<u\u{1B}[>1u\u{1B}[>8u\u{1B}[=3;2u\u{1B}[<2u\u{1B}[=2;1uZ")
        XCTAssertEqual(out, "Z")
        XCTAssertEqual(state.kittyStack, [])
        XCTAssertEqual(state.kittyBase, 2, "the final `=2;1u` lands on the emptied stack's base")
        XCTAssertEqual(state.reassertSequence, Data("\u{1B}[=2;1u".utf8))
    }

    /// The kitty-flags QUERY (`CSI ? u`) is the query stripper's business — this pass keeps it.
    func testKittyQueryIsNotOurs() {
        let (out, _) = strip("a\u{1B}[?ub")
        XCTAssertEqual(out, "a\u{1B}[?ub")
    }

    /// String-sequence bodies (OSC/DCS/APC) are opaque: an embedded mode-set inside them must be
    /// neither stripped nor tracked. Truncated trailing sequences pass through (ring head-cut).
    func testStringBodiesOpaqueAndTruncationPassesThrough() {
        let dcs = "\u{1B}Pq#0;\u{1B}[?1002h#\u{1B}\\"
        var (out, state) = strip(dcs)
        XCTAssertEqual(out, dcs)
        XCTAssertTrue(state.isNeutral)

        (out, state) = strip("tail\u{1B}[?100")
        XCTAssertEqual(out, "tail\u{1B}[?100")
        (out, _) = strip("tail\u{1B}")
        XCTAssertEqual(out, "tail\u{1B}")
    }

    // MARK: - Pipeline wiring

    /// Ring cold replay (the user-visible reattach path): a transcript whose TUI exited replays
    /// with NO mode churn at all; one that is still inside a TUI replays stripped, with the net
    /// state re-asserted as the replay's LAST bytes.
    func testRingReplayStripsModesAndReassertsLiveTUIState() throws {
        let transform = try XCTUnwrap(
            ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true),
        )
        let exited = transform(
            Data("\u{1B}[?1002h\u{1B}[?2048h\u{1B}[>1uvim\u{1B}[<u\u{1B}[?2048l\u{1B}[?1002lbye\r\n".utf8),
        )
        XCTAssertEqual(exited, Data("vimbye\r\n".utf8))

        let midTUI = transform(Data("\u{1B}[?1002h\u{1B}[?1006hvim".utf8))
        XCTAssertEqual(midTUI, Data("vim\u{1B}[?1002h\u{1B}[?1006h".utf8))
    }

    /// The journal restore path must NOT re-assert (fresh shell): a journal cut mid-TUI restores
    /// mode-free, and the sanitize suffix follows as before.
    func testJournalRestoreNeverReasserts() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-strip-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScrollbackJournalStore(
            directory: dir,
            distiller: ScrollbackReplayTransform.make(environment: [:]),
        )
        let sessionID = UUID()
        store.journal(for: sessionID).append(Data("$ vi\u{1B}[?1002h\u{1B}[?2048hEDIT".utf8))
        store.journal(for: sessionID).synchronize()

        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("$ viEDIT".utf8) + ScrollbackJournalStore.sanitizeSuffix,
        )
    }

    // MARK: - XTSAVE / XTRESTORE (`CSI ? Pm s|r` — the save/restore door into tracked modes)

    /// A raw `?1000s … ?1000r` pair replayed verbatim re-arms mouse reporting on the client
    /// (restore brings the saved ON back) — the exact garbage-input class the h/l stripping
    /// exists to prevent, just via the save/restore door. Both are stripped AND simulated, so
    /// the net state lands where a real terminal executing the raw stream would have.
    func testXTSaveRestoreDoorIsStrippedAndTracked() {
        let (out, state) = strip("\u{1B}[?1000h\u{1B}[?1000s\u{1B}[?1000l\u{1B}[?1000rTUI")
        XCTAssertEqual(out, "TUI", "save/restore must be stripped like set/reset")
        XCTAssertEqual(state.modes[1000], true, "restore re-applies the value saved while ON")
        XCTAssertEqual(state.reassertSequence, Data("\u{1B}[?1000h".utf8))
    }

    /// XTRESTORE with no prior save restores the initial (fresh-terminal) value — off.
    func testXTRestoreWithoutSaveNetsOff() {
        let (out, state) = strip("\u{1B}[?1000h\u{1B}[?1000rX")
        XCTAssertEqual(out, "X")
        XCTAssertTrue(state.isNeutral, "restore-without-save yields the initial value (off)")
    }

    /// Mixed tracked/untracked params rewrite (mirror of the h/l discipline), and the NON-`?`
    /// finals stay untouched: bare `r` is DECSTBM (scroll region), bare `s` is SCOSC/DECSLRM —
    /// display state the replay needs.
    func testMixedParamSaveRewrittenAndDECSTBMKept() {
        let (out, state) = strip("\u{1B}[?1049;1000sX\u{1B}[2;24rY\u{1B}[sZ")
        XCTAssertEqual(out, "\u{1B}[?1049sX\u{1B}[2;24rY\u{1B}[sZ")
        XCTAssertTrue(state.isNeutral)
    }

    // MARK: - Trailing split-escape hold-back (the ring/tail boundary)

    /// PTY chunking can split ONE escape sequence across the scrollback-ring / un-acked-tail
    /// boundary. The reassert must land BEFORE the dangling half, never between it and the raw
    /// tail's continuation bytes — interposing there aborts the split sequence and prints the
    /// tail's continuation as literal text.
    func testReassertLandsBeforeTrailingSplitEscape() throws {
        let transform = try XCTUnwrap(
            ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true),
        )
        let out = transform(Data("\u{1B}[?1002hvim\u{1B}[?2004".utf8))
        XCTAssertEqual(
            out, Data("vim\u{1B}[?1002h\u{1B}[?2004".utf8),
            "reassert BEFORE the dangling half-CSI — the live tail completes it adjacently",
        )
    }

    /// The splitter itself: complete endings split nothing; a lone ESC / mid-CSI / unterminated
    /// OSC tail is held back.
    func testSplitTrailingIncompleteEscape() {
        func dangling(_ s: String) -> Data {
            ScrollbackReplayTransform.splitTrailingIncompleteEscape(Data(s.utf8)).dangling
        }
        XCTAssertEqual(dangling("plain"), Data())
        XCTAssertEqual(dangling("a\u{1B}[0m"), Data())
        XCTAssertEqual(dangling("a\u{1B}"), Data("\u{1B}".utf8))
        XCTAssertEqual(dangling("a\u{1B}[?200"), Data("\u{1B}[?200".utf8))
        XCTAssertEqual(
            dangling("a\u{1B}]0;title"), Data("\u{1B}]0;title".utf8),
            "an unterminated OSC opener is held back whole",
        )
        XCTAssertEqual(dangling("a\u{1B}]0;t\u{07}b"), Data(), "a BEL-terminated OSC ends clean")
    }

    /// Env gate: `STRIP_INPUT_MODES=0` restores the pre-fix passthrough (the enables survive) —
    /// the regression this type exists to prevent.
    func testEnvGateOffLeavesModesArmed() throws {
        let gateOff = try XCTUnwrap(
            ScrollbackReplayTransform.make(
                environment: ["SLOPDESK_SCROLLBACK_STRIP_INPUT_MODES": "0"],
                reassertInputModes: true,
            ),
        )
        XCTAssertEqual(
            gateOff(Data("\u{1B}[?2048ha".utf8)), Data("\u{1B}[?2048ha".utf8),
            "with the pass off the enable must survive (pre-fix behaviour)",
        )
    }
}
