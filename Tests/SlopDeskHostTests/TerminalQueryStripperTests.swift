import Foundation
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// Replay hygiene: replayed history must never make the client terminal ANSWER a prior life's
/// queries (the answers ride back as PTY input and spill onto the command line — the user-hit
/// `sleep 300` → close → reopen → `^[]11;rgb:…^G^[[?62;22;52c^[P>|ghostty…` garbage), and stale
/// color/clipboard state must not repaint a fresh terminal.
final class TerminalQueryStripperTests: XCTestCase {
    private func strip(_ s: String) -> String {
        String(bytes: TerminalQueryStripper.strip(Data(s.utf8)), encoding: .utf8) ?? "<non-utf8>"
    }

    // MARK: - The user repro: ghostty/prompt startup queries vanish from replay

    /// The exact query set whose ANSWERS made up the reported garbage: OSC 11 background probe,
    /// DA1, XTVERSION, DECRQM 2026. Interleaved with real output — only the output survives.
    func testStripsThePromptStartupQuerySet() {
        let replay = "PROMPT>\u{1B}]11;?\u{07}\u{1B}[c\u{1B}[>0q\u{1B}[?2026$p\u{1B}[6n$ sleep 300\r\n"
        XCTAssertEqual(strip(replay), "PROMPT>$ sleep 300\r\n")
    }

    /// Echoed RESPONSES already recorded into a poisoned transcript (the garbage itself) are
    /// stripped too, so an already-polluted journal renders clean on its next restore.
    func testStripsEchoedResponses() {
        let poisoned = "ok\u{1B}]11;rgb:2d2d/2a2a/2e2e\u{07}\u{1B}[?62;22;52c"
            + "\u{1B}P>|ghostty 1.3.1-merge\u{1B}\\\u{1B}[?2026;2$y\u{1B}[24;80Rdone"
        XCTAssertEqual(strip(poisoned), "okdone")
    }

    func testStripsRemainingQueryForms() {
        XCTAssertEqual(strip("a\u{1B}[5nb"), "ab", "DSR status query")
        XCTAssertEqual(strip("a\u{1B}[=0cb"), "ab", "DA3")
        XCTAssertEqual(strip("a\u{1B}[?ub"), "ab", "kitty keyboard-flags query")
        XCTAssertEqual(strip("a\u{1B}[14tb"), "ab", "window pixel-size report request")
        XCTAssertEqual(strip("a\u{1B}[18tb"), "ab", "text-area size report request")
        XCTAssertEqual(strip("a\u{1B}[21tb"), "ab", "title report request")
        XCTAssertEqual(strip("a\u{1B}Zb"), "ab", "DECID")
        XCTAssertEqual(strip("a\u{1B}P+q544e\u{1B}\\b"), "ab", "XTGETTCAP")
        XCTAssertEqual(strip("a\u{1B}P$qm\u{1B}\\b"), "ab", "DECRQSS")
        XCTAssertEqual(strip("a\u{1B}]52;c;?\u{07}b"), "ab", "OSC 52 clipboard query")
        XCTAssertEqual(strip("a\u{1B}]4;1;?\u{07}b"), "ab", "OSC 4 palette query")
    }

    /// Stale color STATE (set form, not just query form) must not repaint a fresh terminal.
    func testStripsColorStateSetForms() {
        XCTAssertEqual(strip("a\u{1B}]11;rgb:1111/2222/3333\u{1B}\\b"), "ab", "OSC 11 set (ST)")
        XCTAssertEqual(strip("a\u{1B}]10;#ffffff\u{07}b"), "ab", "OSC 10 set")
        XCTAssertEqual(strip("a\u{1B}]104\u{07}b"), "ab", "palette reset")
    }

    /// The ECHOED RESPONSES of DECRQSS (`DCS {0|1} $ r … ST`, ghostty's
    /// `stream_handler` reply format) and XTGETTCAP (`DCS {0|1} + r … ST`, ghostty's terminfo
    /// reply format) must be stripped like their query halves — a poisoned transcript carrying
    /// them re-emits raw DCS garbage on the fresh command line at cold reattach (the exact bug
    /// class this type exists to fix, already covered for the XTVERSION `>|` response).
    func testStripsDCSEchoedResponses() {
        XCTAssertEqual(strip("a\u{1B}P1$rm\u{1B}\\b"), "ab", "DECRQSS hit response")
        XCTAssertEqual(strip("a\u{1B}P0$r\u{1B}\\b"), "ab", "DECRQSS miss response")
        XCTAssertEqual(strip("a\u{1B}P1+r524742=3838\u{1B}\\b"), "ab", "XTGETTCAP hit response")
        XCTAssertEqual(strip("a\u{1B}P0+r\u{1B}\\b"), "ab", "XTGETTCAP miss response")
    }

    /// OSC 21 (kitty color protocol) is a live query/response OSC in
    /// ghostty — same shape and delivery mechanism as the already-guarded OSC 10/11/12. Both
    /// forms must be stripped so a recorded probe is never re-answered into the shell's stdin.
    func testStripsOSC21KittyColorProtocol() {
        XCTAssertEqual(strip("a\u{1B}]21;foreground=?\u{07}b"), "ab", "OSC 21 query (BEL)")
        XCTAssertEqual(
            strip("a\u{1B}]21;foreground=rgb:aa/bb/cc\u{1B}\\b"), "ab",
            "OSC 21 echoed response / set (ST)",
        )
    }

    // MARK: - What must SURVIVE replay verbatim

    func testKeepsRenderingSequences() {
        let kept = [
            "plain text với tiếng Việt ✓",
            "\u{1B}[31mred\u{1B}[0m", // SGR
            "\u{1B}[?2004h\u{1B}[?2004l", // bracketed paste set/reset (h/l finals)
            "\u{1B}[?1049h\u{1B}[?1049l", // alt screen
            "\u{1B}[2 q", // DECSCUSR (SP intermediate — NOT XTVERSION)
            "\u{1B}[!p", // DECSTR soft reset (no $)
            "\u{1B}[22;0t\u{1B}[23;0t", // title push/pop (t final but not a report request)
            "\u{1B}]0;title\u{07}", // title set
            "\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}", // OSC 133 command marks
            "\u{1B}]7;file://host/tmp\u{1B}\\", // OSC 7 cwd
            "\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\", // hyperlink
            "\u{1B}[1;5H\u{1B}[2J", // cursor move / clear
            "\u{1B}(B\u{1B}=", // charset + keypad ESC pairs
        ]
        for s in kept {
            XCTAssertEqual(strip(s), s, "must pass through verbatim: \(s.debugDescription)")
        }
    }

    /// A truncated trailing sequence (ring head-cut artifact) passes through unchanged rather
    /// than being dropped or crashing the scanner.
    func testTruncatedTrailingSequencePassesThrough() {
        XCTAssertEqual(strip("abc\u{1B}["), "abc\u{1B}[")
        XCTAssertEqual(strip("abc\u{1B}]11;rgb:11"), "abc\u{1B}]11;rgb:11")
        XCTAssertEqual(strip("abc\u{1B}"), "abc\u{1B}")
    }

    /// An `ESC[` embedded in a DCS body must not be parsed as a CSI (string-sequence swallow —
    /// mirrors the distiller's rule). Sixel-style DCS is kept whole.
    func testDCSBodySwallowsEmbeddedCSI() {
        let sixel = "a\u{1B}Pq#0;2;0;0;0\u{1B}[c-not-a-query\u{1B}\\b"
        XCTAssertEqual(strip(sixel), sixel)
    }

    // MARK: - The composed replay transform (ring + journal share it)

    /// Cold ring replay through `ScrollbackReplayTransform`: queries are stripped from the RING
    /// portion while the un-acked tail stays byte-exact (its issuer may still await the answer).
    func testRingReplayStripsQueriesButTailStaysRaw() {
        var buffer = ReplayBuffer(
            scrollbackBytes: 1 << 20,
            scrollbackDistiller: ScrollbackReplayTransform.make(environment: [:]),
        )
        let history = Data("old\u{1B}[c\u{1B}]11;?\u{07}output\n".utf8)
        let tail = Data("pending\u{1B}[c".utf8)
        let s1 = buffer.append(bytes: history)
        buffer.ack(upTo: s1) // moves history into the scrollback ring
        _ = buffer.append(bytes: tail) // un-acked live tail

        let replayed = buffer.replay(after: 0)
        var ringBytes = Data()
        var tailBytes = Data()
        for case let .output(seq, bytes) in replayed {
            if seq <= s1 { ringBytes.append(bytes) } else { tailBytes.append(bytes) }
        }
        XCTAssertEqual(ringBytes, Data("oldoutput\n".utf8), "ring history must be query-free")
        XCTAssertEqual(tailBytes, tail, "the un-acked tail must stay byte-exact")
    }

    /// The disk journal's restore runs the same pipeline: a journal poisoned with queries
    /// restores clean (before the sanitize suffix).
    func testJournalRestoreStripsQueries() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("query-strip-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ScrollbackJournalStore(
            directory: dir,
            distiller: ScrollbackReplayTransform.make(environment: [:]),
        )
        let sessionID = UUID()
        store.journal(for: sessionID).append(Data("$ cc\u{1B}[c\u{1B}[>0q\u{1B}[?2026$pdone\n".utf8))
        store.journal(for: sessionID).synchronize()

        XCTAssertEqual(
            store.restoredScrollback(for: sessionID),
            Data("$ ccdone\n".utf8) + ScrollbackJournalStore.sanitizeSuffix,
        )
    }

    // MARK: - Nasty-corpus exact-byte pin (allocation-refactor guard)

    /// EXACT-BYTE pin over a representative nasty corpus: every piece is tagged kept/stripped at
    /// construction time and the expected output is the concatenation of the KEPT pieces — so any
    /// internal refactor (lazy String building, slice-based CSI parsing) that changes a single
    /// output byte or a single strip decision fails here. Covers SGR-heavy colored output, CSI
    /// with params + intermediates, the full query/response set including the DCS `$r`/`+r`
    /// responses and OSC 21, OSC/DCS/APC string bodies, raw multi-byte UTF-8, and a
    /// truncated trailing escape.
    func testNastyCorpusExactBytesPinned() {
        // (piece, keep) — keep == true ⇒ the piece must appear VERBATIM in the output.
        let pieces: [(String, Bool)] = [
            ("plain ASCII text 123\r\n", true),
            ("\u{1B}[c", false), // DA1 query
            ("tiếng Việt — ✓ 日本語\n", true), // raw multi-byte UTF-8
            ("\u{1B}[?62;22;52c", false), // echoed DA1 response
            ("\u{1B}[1;38;5;196mR\u{1B}[0m\u{1B}[38;2;10;20;30mT\u{1B}[m", true), // SGR heavy
            ("\u{1B}[>0c", false), // DA2 query
            ("\u{1B}[?2004h\u{1B}[?2004l\u{1B}[?1049h", true), // mode set/reset
            ("\u{1B}[5n", false), // DSR status query
            ("\u{1B}[6n", false), // CPR request
            ("\u{1B}[?6n", false), // DEC CPR request
            ("\u{1B}[0n", false), // DSR response
            ("\u{1B}[24;80R", false), // echoed CPR response
            ("\u{1B}[2 q", true), // DECSCUSR (SP intermediate)
            ("\u{1B}[x", false), // DECREQTPARM query
            ("\u{1B}[2;1;1;120;120;1;0x", false), // DECREQTPARM response
            ("\u{1B}[!p", true), // DECSTR (no $)
            ("\u{1B}[?2026$p", false), // DECRQM query
            ("\u{1B}[?2026;2$y", false), // echoed DECRPM response
            ("\u{1B}[1;1;10;10$z", true), // DECERA — params AND $ intermediate, kept final
            ("\u{1B}[>0q", false), // XTVERSION query
            ("\u{1B}[>1u", true), // kitty keyboard push
            ("\u{1B}[?u", false), // kitty keyboard-flags query
            ("\u{1B}[8;24;80t", true), // resize — op 8 is not a report
            ("\u{1B}[14t", false), // window pixel-size report request
            ("\u{1B}[18t", false), // text-area size report request
            ("\u{1B}[21;0t", false), // title report request (first param decides)
            ("\u{1B}[22;0t\u{1B}[23;0t", true), // title push/pop
            ("\u{1B}Z", false), // DECID
            ("\u{1B}]0;title — nasty ;; body\u{07}", true), // OSC title
            ("\u{1B}]11;?\u{07}", false), // OSC 11 query
            ("\u{1B}]10;#ffffff\u{07}", false), // OSC 10 set
            ("\u{1B}]4;1;?\u{07}", false), // palette query
            ("\u{1B}]52;c;?\u{07}", false), // clipboard query
            ("\u{1B}]104\u{07}", false), // palette reset
            ("\u{1B}]112\u{07}", false), // cursor-color reset
            ("\u{1B}]21;foreground=?\u{07}", false), // OSC 21 kitty color query
            ("\u{1B}]21;foreground=rgb:aa/bb/cc\u{1B}\\", false), // OSC 21 response/set (ST)
            ("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}", true), // OSC 133 marks
            ("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\", true), // hyperlink
            ("\u{1B}Pq#0;2;0;0;0~~\u{1B}[c~~\u{1B}\\", true), // sixel DCS, embedded CSI swallowed
            ("\u{1B}P+q544e\u{1B}\\", false), // XTGETTCAP query
            ("\u{1B}P$qm\u{1B}\\", false), // DECRQSS query
            ("\u{1B}P>|ghostty 1.3.1\u{1B}\\", false), // echoed XTVERSION response
            ("\u{1B}P1$rm\u{1B}\\", false), // DECRQSS hit response
            ("\u{1B}P0$r\u{1B}\\", false), // DECRQSS miss response
            ("\u{1B}P1+r524742=3838\u{1B}\\", false), // XTGETTCAP hit response
            ("\u{1B}P0+r\u{1B}\\", false), // XTGETTCAP miss response
            ("\u{1B}_Gf=100;payload\u{1B}\\", true), // APC kept whole
            ("\u{1B}(B\u{1B}=\u{1B}M", true), // 2-byte ESC pairs
            ("\u{1B}[1;5H\u{1B}[2J\u{1B}[0K", true), // cursor move / clears
            ("tail\u{1B}[38;5", true), // truncated trailing CSI — passthrough (must be LAST)
        ]
        let input = pieces.map(\.0).joined()
        let expected = pieces.filter(\.1).map(\.0).joined()
        XCTAssertEqual(TerminalQueryStripper.strip(Data(input.utf8)), Data(expected.utf8))
    }

    /// Env gates: `STRIP_QUERIES=0` disables only the stripper; ALL THREE off → nil transform.
    func testTransformEnvGates() throws {
        let stripOff = ScrollbackReplayTransform.make(
            environment: ["SLOPDESK_SCROLLBACK_STRIP_QUERIES": "0"],
        )
        XCTAssertNotNil(stripOff, "distill stays on")
        XCTAssertEqual(
            try XCTUnwrap(stripOff?(Data("a\u{1B}[cb".utf8))), Data("a\u{1B}[cb".utf8),
            "with the stripper off the DA query must survive",
        )
        XCTAssertNil(ScrollbackReplayTransform.make(environment: [
            "SLOPDESK_SCROLLBACK_STRIP_QUERIES": "0",
            "SLOPDESK_SCROLLBACK_DISTILL": "0",
            "SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS": "0",
        ]))
        XCTAssertNotNil(
            ScrollbackReplayTransform.make(environment: [
                "SLOPDESK_SCROLLBACK_STRIP_QUERIES": "0",
                "SLOPDESK_SCROLLBACK_DISTILL": "0",
            ]),
            "the PROMPT_SP mark stripper keeps the transform alive on its own",
        )
        let allOn = ScrollbackReplayTransform.make(environment: [:])
        XCTAssertEqual(allOn?(Data("a\u{1B}[cb".utf8)), Data("ab".utf8))
    }
}
