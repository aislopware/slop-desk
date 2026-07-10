import Foundation
import XCTest
@testable import SlopDeskHost

/// Test suite for ``CommandBlockSegmenter`` — proves the host can segment the raw
/// OUTBOUND PTY byte stream into per-command Blocks from the OSC 133 A/B/C/D marks alone.
///
/// Non-tautological by construction: the fixtures are built from STRING literals (the
/// command text + the output text are written by hand), and the asserts pin the EXTRACTED
/// spans back to those literals — never to a recomputation of the segmenter's own output.
final class CommandBlockSegmenterTests: XCTestCase {
    private let ESC = "\u{1B}"
    private let BEL = "\u{07}"
    private let ST = "\u{1B}\\" // ESC \

    // MARK: Fixture builders (OSC 133 marks around literal text)

    private func a() -> String { "\(ESC)]133;A\(BEL)" }
    private func b() -> String { "\(ESC)]133;B\(BEL)" }
    private func c() -> String { "\(ESC)]133;C\(BEL)" }
    private func d(_ exit: Int? = nil) -> String {
        exit.map { "\(ESC)]133;D;\($0)\(BEL)" } ?? "\(ESC)]133;D\(BEL)"
    }

    /// The EXPLICIT command-line mark `133;E;<escaped>` (the slopdesk extension the shim's `preexec`
    /// emits before `C`). `escaped` must already be the wire form (`;`, `\`, ESC, BEL, CR, LF as `\xNN`).
    private func e(_ escaped: String) -> String { "\(ESC)]133;E;\(escaped)\(BEL)" }

    /// A full prompt→command→output→done cycle: `A` <prompt> `B` <cmd> `C` <output> `D;exit`.
    private func cycle(prompt: String, command: String, output: String, exit: Int) -> String {
        a() + prompt + b() + command + c() + output + d(exit)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func text(_ b: [UInt8]) -> String { String(bytes: b, encoding: .utf8) ?? "" }

    // A deterministic clock the segmenter reads on each `C`/`D`. `advance` moves it forward.
    private final class TestClock {
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    // MARK: 1. Single command — text, output, exit all extracted

    func testSingleCommandExtractsTextOutputExit() {
        let stream = cycle(prompt: "user@host $ ", command: "echo hi", output: "hi\n", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))

        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        XCTAssertEqual(block.index, 0)
        // Pinned to the literal "echo hi" (the prompt before B must NOT leak in).
        XCTAssertEqual(block.commandText, "echo hi")
        // Pinned to the literal "hi\n" (the prompt AND the command text must NOT leak in).
        XCTAssertEqual(text(block.output), "hi\n")
        XCTAssertEqual(block.exitCode, 0)
        XCTAssertTrue(block.complete)
        XCTAssertFalse(block.outputTruncated)
    }

    func testNonZeroExitCodeParsed() {
        let stream = cycle(prompt: "$ ", command: "false", output: "", exit: 1)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].exitCode, 1)
        XCTAssertEqual(blocks[0].commandText, "false")
        XCTAssertEqual(blocks[0].output, [])
    }

    func testExitCodeAbsentIsNil() {
        // `D` with no exit field → nil exit (not 0).
        let stream = a() + "$ " + b() + "ls" + c() + "a  b\n" + d(nil)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0].exitCode)
        XCTAssertEqual(blocks[0].commandText, "ls")
        XCTAssertEqual(text(blocks[0].output), "a  b\n")
    }

    // MARK: 2. C→D duration via injected clock

    func testDurationMeasuredFromClock() {
        let clock = TestClock()
        var seg = CommandBlockSegmenter(clock: clock.date)
        // Feed up to C, then advance the clock 1.25s, then feed the rest.
        seg.ingest(bytes(a() + "$ " + b() + "sleep 1" + c()))
        clock.advance(1.25)
        let completed = seg.ingest(bytes("output\n" + d(0)))

        XCTAssertEqual(completed.count, 1)
        // 1.25s → exactly 1250 ms (pinned to the injected advance, not a recomputation).
        XCTAssertEqual(completed[0].durationMS, 1250)
        XCTAssertEqual(completed[0].commandText, "sleep 1")
    }

    // MARK: 3. Multi-command session

    func testMultiCommandSession() {
        let stream =
            cycle(prompt: "$ ", command: "pwd", output: "/home/me\n", exit: 0)
                + cycle(prompt: "$ ", command: "grep x f", output: "no match\n", exit: 2)
                + cycle(prompt: "$ ", command: "true", output: "", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))

        XCTAssertEqual(blocks.count, 3)

        XCTAssertEqual(blocks[0].index, 0)
        XCTAssertEqual(blocks[0].commandText, "pwd")
        XCTAssertEqual(text(blocks[0].output), "/home/me\n")
        XCTAssertEqual(blocks[0].exitCode, 0)

        XCTAssertEqual(blocks[1].index, 1)
        XCTAssertEqual(blocks[1].commandText, "grep x f")
        XCTAssertEqual(text(blocks[1].output), "no match\n")
        XCTAssertEqual(blocks[1].exitCode, 2)

        XCTAssertEqual(blocks[2].index, 2)
        XCTAssertEqual(blocks[2].commandText, "true")
        XCTAssertEqual(blocks[2].output, [])
        XCTAssertEqual(blocks[2].exitCode, 0)
    }

    // MARK: 4. Running (incomplete) command — no D yet

    func testRunningCommandIsIncompleteWithPartialOutput() {
        // A→B→C→<partial output>, NO D. finish() flushes it as incomplete.
        var seg = CommandBlockSegmenter()
        let completed = seg.ingest(bytes(a() + "$ " + b() + "tail -f log" + c() + "line 1\nline 2\n"))
        // Nothing has completed yet (no D).
        XCTAssertTrue(completed.isEmpty)

        let flushed = seg.finish()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertFalse(flushed[0].complete)
        XCTAssertNil(flushed[0].exitCode)
        XCTAssertEqual(flushed[0].commandText, "tail -f log")
        // Partial output captured so far (pinned to the two literal lines fed before finish).
        XCTAssertEqual(text(flushed[0].output), "line 1\nline 2\n")
    }

    func testRunningCommandHasNilDuration() {
        var seg = CommandBlockSegmenter()
        seg.ingest(bytes(a() + "$ " + b() + "watch x" + c() + "tick\n"))
        let flushed = seg.finish()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertNil(flushed[0].durationMS)
    }

    // MARK: 5. No-133 stream → zero blocks (the unstructured case)

    func testNoMarksProducesZeroBlocks() {
        // Plain output with a title + a bell but no 133 marks → nothing to segment.
        let stream = "just some output\n\(ESC)]2;a title\(BEL)more\nstuff\n\(BEL)"
        var seg = CommandBlockSegmenter()
        let completed = seg.ingest(bytes(stream))
        XCTAssertTrue(completed.isEmpty)
        // And finish() flushes nothing because no block was ever opened.
        XCTAssertTrue(seg.finish().isEmpty)
    }

    // MARK: 6. Output cap — runaway command can't blow memory

    func testOutputCapTruncates() {
        let cap = 1024
        // 5000 bytes of output, cap at 1024.
        let big = String(repeating: "y", count: 5000)
        let stream = a() + "$ " + b() + "yes" + c() + big + d(130)
        let blocks = CommandBlockSegmenter.segment(bytes(stream), outputCap: cap)

        XCTAssertEqual(blocks.count, 1)
        // Exactly `cap` bytes captured (pinned), the rest dropped.
        XCTAssertEqual(blocks[0].output.count, cap)
        XCTAssertTrue(blocks[0].outputTruncated)
        // The block still CLOSED cleanly on D despite the truncation.
        XCTAssertTrue(blocks[0].complete)
        XCTAssertEqual(blocks[0].exitCode, 130)
        // And the captured prefix is the literal output prefix.
        XCTAssertEqual(text(blocks[0].output), String(repeating: "y", count: cap))
    }

    func testUnderCapNotTruncated() {
        let stream = a() + "$ " + b() + "echo" + c() + String(repeating: "z", count: 100) + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream), outputCap: 1024)
        XCTAssertEqual(blocks[0].output.count, 100)
        XCTAssertFalse(blocks[0].outputTruncated)
    }

    // MARK: 7. Robustness — embedded 133 byte, nested marks, control sequences preserved

    func testEmbeddedRawByteInOutputDoesNotSpoof() {
        // The literal bytes "133;D" appearing in OUTPUT (NOT inside an OSC) must be captured
        // as plain output, not parsed as a finish mark.
        let stream = a() + "$ " + b() + "cat f" + c() + "the marker 133;D appears here\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(text(blocks[0].output), "the marker 133;D appears here\n")
        XCTAssertTrue(blocks[0].complete)
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    func testSpoofedMarkInsideStringSequenceIsIgnored() {
        // A DCS string body that embeds `ESC]133;D;99 ST` must NOT close the block — the
        // string sequence swallows it (the live sniffer's security property, mirrored).
        let dcsSpoof = "\(ESC)P\(ESC)]133;D;99\(BEL)\(ST)" // DCS … ST, with a fake D inside
        let stream = a() + "$ " + b() + "run" + c() + "real out\n" + dcsSpoof + "more out\n" + d(7)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        // The block closed on the REAL D (exit 7), not the spoofed D;99.
        XCTAssertEqual(blocks[0].exitCode, 7)
        XCTAssertTrue(blocks[0].complete)
    }

    func testControlSequencesPreservedInOutput() {
        // Output with a real CSI color sequence — the raw bytes are preserved verbatim.
        let colored = "\(ESC)[31mRED\(ESC)[0m\n"
        let stream = a() + "$ " + b() + "ls --color" + c() + colored + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(text(blocks[0].output), colored)
        // And the CSI bytes really are present (ESC + '[' + '3' + '1' + 'm').
        XCTAssertTrue(blocks[0].output.contains(0x1B))
    }

    func testColorizedCommandLineIsEscapeStripped() {
        // A colorized command line (zsh-syntax-highlighting / fish / oh-my-zsh wrap the typed line in
        // CSI SGR runs as you type) emits CSI escapes in the B→C command-entry region. Those must be
        // STRIPPED from `commandText` (the doc pins it as OSC/escape-stripped) — only the typed text
        // survives. Contrast with `testControlSequencesPreservedInOutput`: escapes in OUTPUT are kept.
        let coloredCommand = "\(ESC)[32mecho hi\(ESC)[0m"
        let stream = a() + "$ " + b() + coloredCommand + c() + "hi\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        // The CSI SGR runs are gone; only the literal typed command remains.
        XCTAssertEqual(blocks[0].commandText, "echo hi")
        // No raw ESC leaked into the command text (the byte-level proof the strip happened).
        XCTAssertFalse(Array(blocks[0].commandText.utf8).contains(0x1B), "no ESC bytes in commandText")
        // Output still carries its own bytes faithfully (the strip is command-phase only).
        XCTAssertEqual(text(blocks[0].output), "hi\n")
    }

    func testCommandWithNoBStillCapturesOutput() {
        // First-prompt case: a C with no preceding B (joined mid-session). The block opens
        // at C with an empty commandText, output captured, closes on D.
        let stream = c() + "orphan output\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "")
        XCTAssertEqual(text(blocks[0].output), "orphan output\n")
    }

    func testPhantomDWithNoCommandDropped() {
        // The classic first-prompt phantom `D;0` with no open block → emits nothing.
        let stream = a() + "$ " + d(0) + b() + "ls" + c() + "x\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        // Only the real ls block — the phantom D produced no block.
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "ls")
    }

    func testPhantomDInCommandPhaseAfterEmptyEnterDropped() {
        // The zsh shim emits `D;$?` from precmd on EVERY prompt cycle (before A), so an empty Enter
        // at the prompt fires a `D` while the block is still in the `.command` phase — B fired (the
        // prompt) but preexec/`C` did NOT (no command executed). Before the fix the `D` arm gated
        // only on `hasOpenBlock` and minted a "completed" phantom block with empty commandText and
        // the PREVIOUS command's exit code, piling "(no command)" rows into the Commands / Outline.
        let stream =
            cycle(prompt: "$ ", command: "false", output: "", exit: 1) // one real failed command
                + a() + "$ " + b() // new prompt: block opens (.command phase)
                + d(1) // empty-Enter precmd D;1 — stale $? = 1, NO C this cycle
                + a() + "$ " + b() + "ls" + c() + "ok\n" + d(0) // a real command after the empty Enter
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 2, "the empty-Enter phantom D must not mint a completed block")
        XCTAssertEqual(blocks.map(\.commandText), ["false", "ls"])
        XCTAssertEqual(blocks.map(\.exitCode), [1, 0])
        XCTAssertTrue(blocks.allSatisfy(\.complete))
    }

    func testCtrlCLineAbortDropsPhantomBlock() {
        // A Ctrl-C at the prompt aborts the line: zsh echoes `^C`, runs precmd (`D;130`) but NOT
        // preexec — no `C`, so the open block stayed in the `.command` phase. Before the fix this
        // minted a phantom completed "foo^C" block shown as FAILED (exit 130) though nothing ran.
        let stream =
            a() + "$ " + b() + "foo" + "^C\n" // typed "foo", then Ctrl-C abort (no preexec / C)
            + d(130) // precmd D;130 — abort exit, no command executed
            + a() + "$ " + b() + "ls" + c() + "ok\n" + d(0) // a real command after the abort
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1, "a Ctrl-C line-abort (no C) must not mint a phantom completed block")
        XCTAssertEqual(blocks[0].commandText, "ls")
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    func testInterruptedOutputBlockCarriesDurationOnClose() {
        // A running command (reached `C` → `.output`) interrupted by a fresh prompt `A` with no `D`
        // (a nested shell / ssh whose inner shell emits its own OSC-133) is closed as INCOMPLETE. It
        // must carry a NON-nil durationMS so the close is distinguishable from the running peek —
        // otherwise the tracker's dedup (which compares only exit/duration/text for a running block)
        // suppresses the final emit and the client shows the row "running…" forever (Bug 3).
        let clock = TestClock()
        var seg = CommandBlockSegmenter(clock: clock.date)
        _ = seg.ingest(bytes(a() + "$ " + b() + "ssh host" + c())) // reaches .output, runningSince set
        clock.advance(2.0) // 2s of runtime before the interrupt
        let closed = seg.ingest(bytes(a())) // remote prompt A interrupts, no D
        XCTAssertEqual(closed.count, 1)
        XCTAssertFalse(closed[0].complete)
        XCTAssertNil(closed[0].exitCode)
        XCTAssertEqual(closed[0].commandText, "ssh host")
        XCTAssertEqual(closed[0].durationMS, 2000, "an interrupt-close stamps the C→interrupt duration")
    }

    func testRepromptWithoutDClosesPriorAsIncomplete() {
        // A new A (prompt) arrives while a block is still open (no D) — the prior block is
        // flushed as incomplete, the new cycle starts fresh.
        let stream =
            a() + "$ " + b() + "hang" + c() + "partial\n"
                + a() + "$ " + b() + "ls" + c() + "ok\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 2)
        XCTAssertFalse(blocks[0].complete)
        XCTAssertEqual(blocks[0].commandText, "hang")
        XCTAssertEqual(text(blocks[0].output), "partial\n")
        XCTAssertTrue(blocks[1].complete)
        XCTAssertEqual(blocks[1].commandText, "ls")
    }

    // MARK: 7b. Prompt REDRAW (reset-prompt on every resize) must not spawn phantom blocks

    func testIdlePromptRedrawDoesNotSpawnPhantomBlocks() {
        // The B mark lives INSIDE $PROMPT (a zero-width sequence), so zsh re-fires it on every
        // `zle reset-prompt` — the shim's own TRAPWINCH runs one per SIGWINCH, and a remote pane
        // resizes constantly. At an IDLE prompt (B fired, no command typed, no C yet) each redraw is
        // the SAME prompt, NOT a new command. Three redraws before a single real command must yield
        // exactly ONE block — not three phantom incomplete ("running" forever) blocks + the real one.
        let stream =
            a() + "$ " + b() // prompt shown, block opens
                + b() + b() + b() // three reset-prompt redraws at the idle prompt (re-fired B marks)
                + "ls" + c() + "hi\n" + d(0) // the user finally runs a command
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1, "prompt redraws must not create phantom blocks")
        XCTAssertEqual(blocks[0].commandText, "ls")
        XCTAssertTrue(blocks[0].complete)
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    func testRedrawReprintedPromptDoesNotLeakIntoCommandText() {
        // A `reset-prompt` reprints PROMPT (incl. the B mark) then the current input BUFFER. So a
        // partial command typed before a resize is re-echoed after the re-fired B. The re-fired B in
        // the command phase must RE-ARM the same block (discarding the pre-redraw partial + the
        // reprinted prompt bytes), so the final commandText is the clean typed line — never
        // "ec$ echo hi" with the reprinted prompt fused in.
        let stream =
            a() + "$ " + b() + "ec" // typed "ec"
            + "$ " + b() // resize → reset-prompt reprints "$ " then the B mark
            + "echo hi" + c() + "hi\n" + d(0) // buffer re-echoed as "echo hi", then run
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1, "a redraw mid-typing must not split the command into two blocks")
        XCTAssertEqual(blocks[0].commandText, "echo hi", "reprinted prompt must not leak into commandText")
        XCTAssertTrue(blocks[0].complete)
    }

    func testOpenBlockNotSurfacedUntilCommandExecutes() {
        // `peekOpenBlock` drives the live "running command" surfaced to the client. A block still at
        // the prompt (B fired, no C) is the CURRENT INPUT LINE, not a running command — surfacing it
        // would show a spurious "(no command) running…" entry that sits forever at the top of the
        // Commands/Outline panel. It must only surface once the command actually STARTS (its C mark).
        var seg = CommandBlockSegmenter()
        seg.ingest(bytes(a() + "$ " + b()))
        XCTAssertNil(seg.peekOpenBlock(), "an idle prompt (pre-C) must not surface as a running block")
        seg.ingest(bytes("echo hi"))
        XCTAssertNil(seg.peekOpenBlock(), "a half-typed command (pre-C) is not yet running")
        seg.ingest(bytes(c()))
        let running = seg.peekOpenBlock()
        XCTAssertNotNil(running, "a command that started executing (saw C) IS surfaced as running")
        XCTAssertEqual(running?.commandText, "echo hi")
        XCTAssertEqual(running?.complete, false)
    }

    // MARK: 7b. Explicit command-line mark (133;E) — immune to line-editor redraw pollution

    /// THE Bug-A regression. Under zsh-autosuggestions + zsh-syntax-highlighting + starship, the command
    /// region is repainted many times as the user types: ghost-suggestion text is printed, the line is
    /// re-colored, the cursor jumps back — so the raw ECHO between `B` and `C` is a soup of every glyph ever
    /// painted there (`ll ~/Library/Group\ Containers/... ll ll` etc.). The explicit `133;E` mark carries the
    /// EXACT typed command, so `commandText` must be the clean command, NOT the echo soup. FAILS on the
    /// pre-fix segmenter (which had no `E` arm and fell back to the polluted echo bytes).
    func testExplicitCommandMarkOverridesGarbledEcho() {
        // The echo between B and C is deliberate garbage (what a redraw-heavy line editor actually emits).
        let garbage = "l l ll  ll ~/Library/Group\\ Containers ll ll  ec  ho SHIPPED"
        let stream = a() + "$ " + b() + garbage + e("ll") + c() + "file listing\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "ll", "the explicit E mark wins over the polluted echo bytes")
        XCTAssertEqual(text(blocks[0].output), "file listing\n")
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    /// The `\xNN` escaping round-trips: a command with a semicolon, a backslash, spaces and a non-Latin path
    /// (all bytes the shim escapes or passes through) decodes back to the EXACT command. The escape covers
    /// `;` (field separator) and `\` (escape lead-in); everything else — incl. multi-byte UTF-8 — is literal.
    func testExplicitCommandUnescapesSpecialBytes() {
        // Wire form: `echo "a; b" \ ~/Проект` with `;`→\x3b and `\`→\x5c.
        let escaped = #"echo "a\x3b b" \x5c ~/Проект"#
        let stream = a() + "$ " + b() + "echo …" + e(escaped) + c() + "out\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, #"echo "a; b" \ ~/Проект"#)
    }

    /// A `133;E` command longer than the 256-byte 133 cap is NOT dropped — that cap is a sniffer-parity guard
    /// for the A/B/C/D marks; the explicit command legitimately runs long and is bounded only by the 4096-byte
    /// OSC cap. (A `133;C;<257 junk bytes>` would still be dropped — pinned by the parity tests.) FAILS if the
    /// cap were applied to `E`: the mark would vanish and `commandText` would fall back to the echo.
    func testExplicitCommandLongerThan256BytesSurvivesCap() {
        let long = String(repeating: "x", count: 400) // > cmdOscCap (256), < oscCap (4096)
        let stream = a() + "$ " + b() + "typed" + e(long) + c() + "out\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, long, "the explicit command is exempt from the 256-byte 133 cap")
    }

    /// A re-fired `B` (prompt redraw on resize) that RE-ARMS the open block does not discard an explicit
    /// command captured for THIS execution: E arrives after the FINAL B (at preexec), so the redraw B's
    /// come before E and the explicit text still wins. Composes the Bug-A fix with the redraw-dedup fix.
    func testExplicitCommandSurvivesPromptRedrawBeforeExecution() {
        // Two redraw B's (resize) at the idle prompt, THEN the real preexec E + C.
        let stream = a() + "$ " + b() + b() + "gar" + b() + e("git status") + c() + "clean\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1, "redraw B's don't spawn phantom blocks")
        XCTAssertEqual(blocks[0].commandText, "git status")
    }

    // MARK: 8. Chunk-boundary invariance — split anywhere = same blocks

    func testChunkingInvariance() {
        let stream =
            cycle(prompt: "$ ", command: "echo one", output: "one\n", exit: 0)
                + cycle(prompt: "$ ", command: "echo two", output: "two\n", exit: 0)
        let raw = bytes(stream)
        // PIN the clock: `durationMS` is C→D WALL-CLOCK time, so with the real clock a
        // byte-at-a-time ingest legitimately measures a few ms where the whole-buffer pass
        // measures 0 — a load-dependent flake, not a chunking difference. A frozen clock
        // makes the comparison purely about chunk boundaries.
        let frozen = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let whole = CommandBlockSegmenter.segment(raw, clock: { frozen })

        // Feed one byte at a time (bypasses any batching) — must produce identical blocks.
        var seg = CommandBlockSegmenter(clock: { frozen })
        var chunked: [CommandBlockSegmenter.CommandBlock] = []
        for byte in raw {
            chunked.append(contentsOf: seg.ingest([byte]))
        }
        chunked.append(contentsOf: seg.finish())
        XCTAssertEqual(whole, chunked)

        // Also split the marks themselves across a boundary (mid-OSC).
        let half = raw.count / 2
        var seg2 = CommandBlockSegmenter(clock: { frozen })
        var twoChunk = seg2.ingest(Array(raw[0..<half]))
        twoChunk.append(contentsOf: seg2.ingest(Array(raw[half...])))
        twoChunk.append(contentsOf: seg2.finish())
        XCTAssertEqual(whole, twoChunk)
    }

    // MARK: 9. ST-terminated marks (ESC \ instead of BEL)

    func testSTTerminatedMarks() {
        // Use ESC \ as the OSC terminator instead of BEL throughout.
        func aST() -> String { "\(ESC)]133;A\(ST)" }
        func bST() -> String { "\(ESC)]133;B\(ST)" }
        func cST() -> String { "\(ESC)]133;C\(ST)" }
        func dST(_ e: Int) -> String { "\(ESC)]133;D;\(e)\(ST)" }
        let stream = aST() + "$ " + bST() + "make" + cST() + "built\n" + dST(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].commandText, "make")
        XCTAssertEqual(text(blocks[0].output), "built\n")
        XCTAssertEqual(blocks[0].exitCode, 0)
    }

    // MARK: Prompt ordinals (the outline-jump anchor — count every `A` cycle exactly like ghostty rows)

    /// Sequential commands are stamped with ordinals 1, 2, 3 — the 1-based `A`-cycle count.
    func testPromptOrdinalIncrementsPerPromptCycle() {
        let stream = cycle(prompt: "$ ", command: "one", output: "1\n", exit: 0)
            + cycle(prompt: "$ ", command: "two", output: "2\n", exit: 0)
            + cycle(prompt: "$ ", command: "three", output: "3\n", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.map(\.promptOrdinal), [1, 2, 3])
    }

    /// An EMPTY-ENTER cycle (A → B → D with no C — precmd runs, preexec does not) produces NO block but
    /// still CONSUMES a prompt ordinal: ghostty gets a `.prompt` row for the empty prompt, so the next
    /// command's ordinal must skip past it (1 then 3, never 1 then 2). The load-bearing property for the
    /// outline jump — an ordinal that ignored blockless cycles would land one prompt too high.
    func testEmptyEnterCycleConsumesAnOrdinalWithoutABlock() {
        let stream = cycle(prompt: "$ ", command: "one", output: "1\n", exit: 0)
            + a() + "$ " + b() + d(0) // empty Enter: precmd D + A/B, no C — discarded, no block
            + cycle(prompt: "$ ", command: "two", output: "2\n", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.map(\.commandText), ["one", "two"], "the empty cycle mints no block")
        XCTAssertEqual(
            blocks.map(\.promptOrdinal), [1, 3],
            "the empty-Enter prompt consumed ordinal 2 — exactly the `.prompt` row ghostty counts",
        )
    }

    /// A `zle reset-prompt` redraw storm re-fires only the in-`$PROMPT` `B` mark (the shim emits `A`
    /// once per cycle from precmd) — re-fired `B`s must NOT consume ordinals.
    func testPromptRedrawBStormDoesNotConsumeOrdinals() {
        let stream = a() + "$ " + b() + b() + b() + "ls" + c() + "out\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].promptOrdinal, 1, "three redraw `B`s are the SAME prompt cycle")
    }

    /// A continuation/secondary/right-prompt `A` (`k=c` / `k=s` / `k=r`) does not start a new `.prompt`
    /// row group in ghostty — it must not consume an ordinal either. Only a bare/`k=i` `A` counts.
    func testNonPrimaryPromptKindsDoNotConsumeOrdinals() {
        let kc = "\(ESC)]133;A;k=c\(BEL)"
        let ks = "\(ESC)]133;A;k=s\(BEL)"
        let stream = a() + kc + ks + "$ " + b() + "ls" + c() + "out\n" + d(0)
            + cycle(prompt: "$ ", command: "two", output: "2\n", exit: 0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.map(\.promptOrdinal), [1, 2], "k=c/k=s marks never consume an ordinal")
    }

    /// A mid-stream join that opens a block at `C` with NO `A` ever seen stamps ordinal 0 (unknown) —
    /// the client then skips the jump instead of mis-landing.
    func testMidStreamJoinWithoutPromptStampsUnknownOrdinal() {
        let stream = c() + "orphan output\n" + d(0)
        let blocks = CommandBlockSegmenter.segment(bytes(stream))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].promptOrdinal, 0, "no `A` seen ⇒ unknown ordinal (0), never a guess")
    }

    // MARK: Nasty-corpus exact-byte pin across chunk splits (allocation-refactor guard)

    /// EXACT-BYTE pin of the captured output over a representative nasty corpus, ingested at chunk
    /// sizes that split mid-UTF-8 and mid-escape. Each output piece is tagged captured/consumed at
    /// construction: CSI runs, plain/multi-byte text and 2-byte escapes are captured RAW; OSC and
    /// DCS/SOS/PM/APC string sequences feed the mark-detection machine and are NOT content. Any
    /// ingest refactor (generic byte-sequence / Data pass-through) that changes one captured byte
    /// or breaks cross-chunk state fails here.
    func testNastyCorpusOutputBytesPinnedAcrossChunkSplits() {
        let outputPieces: [(String, Bool)] = [
            ("\u{1B}[1;38;5;196mRED\u{1B}[0m ", true), // SGR heavy — preserved verbatim
            ("\u{1B}]0;title with 133;C inside\u{07}", false), // OSC — consumed, never spoofs a mark
            ("tiếng Việt ✓ 日本語 — the marker 133;D appears here\n", true), // raw UTF-8 + fake mark text
            ("\u{1B}P+q544e\u{1B}\\", false), // DCS query — string body swallowed
            ("\u{1B}[38;2;10;20;30mtruecolor\u{1B}[m\u{1B}(B\u{1B}=", true), // CSI + 2-byte escapes
            ("\u{1B}[2J\u{1B}[1;5H", true), // clears / cursor motion
            ("done\r\n", true),
        ]
        let outputRaw = outputPieces.map(\.0).joined()
        let expectedOutput = outputPieces.filter(\.1).map(\.0).joined()
        let churn = "g\u{1B}[90mit statu\u{1B}[0m\rgit status\u{1B}[K" // B→C editor churn (E overrides)
        let stream = bytes(
            a() + "\u{1B}[1;32m~/proj\u{1B}[0m ❯ " + b() + churn + e("git st\\x3batus")
                + c() + outputRaw + d(0),
        )
        for chunkSize in [1, 2, 3, 7, stream.count] {
            var seg = CommandBlockSegmenter()
            var blocks: [CommandBlockSegmenter.CommandBlock] = []
            var i = 0
            while i < stream.count {
                let end = min(i + chunkSize, stream.count)
                blocks.append(contentsOf: seg.ingest(Array(stream[i..<end])))
                i = end
            }
            blocks.append(contentsOf: seg.finish())
            XCTAssertEqual(blocks.count, 1, "chunk \(chunkSize)")
            XCTAssertEqual(blocks[0].commandText, "git st;atus", "chunk \(chunkSize)")
            XCTAssertEqual(text(blocks[0].output), expectedOutput, "chunk \(chunkSize)")
            XCTAssertEqual(blocks[0].exitCode, 0, "chunk \(chunkSize)")
            XCTAssertTrue(blocks[0].complete, "chunk \(chunkSize)")
        }
    }
}
