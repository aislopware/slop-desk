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
    /// mirrors the distiller's R9 #4 rule). Sixel-style DCS is kept whole.
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

    /// Env gates: `STRIP_QUERIES=0` disables only the stripper; both off → nil transform.
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
        ]))
        let bothOn = ScrollbackReplayTransform.make(environment: [:])
        XCTAssertEqual(bothOn?(Data("a\u{1B}[cb".utf8)), Data("ab".utf8))
    }
}
