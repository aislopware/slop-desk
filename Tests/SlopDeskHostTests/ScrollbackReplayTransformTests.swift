import Foundation
import SlopDeskTransport
import XCTest
@testable import SlopDeskHost

/// ``ScrollbackReplayTransform`` — the WIRING, not the passes.
///
/// The seven byte passes are `rust/slopdesk-sanitize`, and their behaviour is pinned there: every
/// rule one at a time beside each module, and the captured field shapes plus two exact-byte corpus
/// pins in `rust/slopdesk-sanitize/tests/replay_passes.rs` (where the deleted Swift suites went).
/// Re-asserting any of that here would be the cross-language mirror this tree forbids.
///
/// What is left is the set of claims that are genuinely about the SWIFT side: that both replay
/// paths reach the transform, that the ring path re-asserts input modes and the journal path does
/// not, that a trailing split escape is held back and the reassert lands ahead of it, and that no
/// environment variable can turn the cleanup off.
final class ScrollbackReplayTransformTests: XCTestCase {
    /// Ring cold replay (the user-visible reattach path): a transcript whose TUI exited replays with
    /// NO mode churn at all; one still inside a TUI replays stripped, with the net state re-asserted
    /// as the replay's LAST bytes.
    func testRingReplayStripsModesAndReassertsLiveTUIState() {
        let transform = ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true)
        let exited = transform(
            Data("\u{1B}[?1002h\u{1B}[?2048h\u{1B}[>1uvim\u{1B}[<u\u{1B}[?2048l\u{1B}[?1002lbye\r\n".utf8),
        )
        XCTAssertEqual(exited, Data("vimbye\r\n".utf8))

        let midTUI = transform(Data("\u{1B}[?1002h\u{1B}[?1006hvim".utf8))
        XCTAssertEqual(midTUI, Data("vim\u{1B}[?1002h\u{1B}[?1006h".utf8))
    }

    /// The transcript restore path must NOT re-assert (its bytes front a fresh shell): a transcript
    /// cut mid-TUI restores mode-free, and the sanitize suffix follows as before.
    ///
    /// The file is superd's since stage 27, so the restore goes through it — `journalInfo` for a
    /// session with no live pane is exactly the shape a returning cold client produces. Written
    /// here rather than through a pane because the subject is the TRANSFORM, not the writer.
    func testJournalRestoreNeverReasserts() throws {
        let superd = try SuperdFixture()
        defer { withExtendedLifetime(superd) {} }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-transform-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcripts = ScrollbackTranscripts(
            directory: dir.path,
            byteCap: 1 << 20,
            distiller: ScrollbackReplayTransform.make(environment: [:]),
        )
        let sessionID = UUID()
        try Data("$ vi\u{1B}[?1002h\u{1B}[?2048hEDIT".utf8)
            .write(to: dir.appendingPathComponent("\(sessionID.uuidString).scrollback"))

        XCTAssertEqual(
            transcripts.restored(sessionID: sessionID, supervisor: superd.client)?.bytes,
            Data("$ viEDIT".utf8) + ScrollbackTranscripts.sanitizeSuffix,
        )
    }

    /// COLD replay (`after: 0` — a fresh client) through ``ReplayBuffer``: ring AND un-acked tail are
    /// transformed as ONE stream, because the client has rendered nothing and even the tail's
    /// queries must not re-arm the terminal. A WARM reconnect keeps the tail byte-exact (its issuer
    /// may still be awaiting the answer).
    func testColdReplayTransformsRingAndTailWarmKeepsTailRaw() {
        let buffer = ReplayBuffer(scrollbackBytes: 1 << 20)
        let history = Data("old\u{1B}[c\u{1B}]11;?\u{07}output\n".utf8)
        let tail = Data("pending\u{1B}[c".utf8)
        let s1 = buffer.append(bytes: history)
        buffer.ack(upTo: s1) // moves history into the scrollback ring
        let s2 = buffer.append(bytes: tail) // un-acked live tail

        var coldBytes = Data()
        var coldSeqs: [Int64] = []
        for case let .output(seq, bytes) in buffer.replay(after: 0) {
            coldBytes.append(bytes)
            coldSeqs.append(seq)
        }
        XCTAssertEqual(
            coldBytes, Data("oldoutput\npending".utf8),
            "cold replay must be query-free end to end (ring AND tail)",
        )
        XCTAssertEqual(coldSeqs.last, s2, "last chunk carries the top tail seq (ack release)")

        XCTAssertEqual(
            buffer.replay(after: s1), [.output(seq: s2, bytes: tail)],
            "warm tail stays byte-exact",
        )
    }

    /// PTY chunking can split ONE escape sequence across the scrollback-ring / un-acked-tail
    /// boundary. The reassert must land BEFORE the dangling half, never between it and the raw
    /// tail's continuation bytes — interposing there aborts the split sequence and prints the tail's
    /// continuation as literal text.
    ///
    /// The ordering is screend's to keep now (stage 26): this pins the guarantee hostd depends on,
    /// while the split rules themselves are tested in `slopdesk-sanitize`'s `boundary` module.
    func testReassertLandsBeforeTrailingSplitEscape() {
        let transform = ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true)
        XCTAssertEqual(
            transform(Data("\u{1B}[?1002hvim\u{1B}[?2004".utf8)),
            Data("vim\u{1B}[?1002h\u{1B}[?2004".utf8),
            "reassert BEFORE the dangling half-CSI — the live tail completes it adjacently",
        )
    }

    /// The cleanup passes have no env gates left — six `STRIP_*`/`COLLAPSE_*` opt-outs were deleted,
    /// so the transform always exists and always cleans. Only `SLOPDESK_SCROLLBACK_DISTILL` survives,
    /// over the B→C line-editor collapse, and turning it off does not turn the rest off with it.
    func testTheCleanupPassesHaveNoOptOut() {
        let retired = [
            "SLOPDESK_SCROLLBACK_STRIP_QUERIES": "0",
            "SLOPDESK_SCROLLBACK_STRIP_INPUT_MODES": "0",
            "SLOPDESK_SCROLLBACK_STRIP_ALT_SCREEN": "0",
            "SLOPDESK_SCROLLBACK_COLLAPSE_SYNC": "0",
            "SLOPDESK_SCROLLBACK_COLLAPSE_OVERPRINT": "0",
            "SLOPDESK_SCROLLBACK_STRIP_EOL_MARKS": "0",
        ]
        for environment in [retired, retired.merging(["SLOPDESK_SCROLLBACK_DISTILL": "0"]) { _, new in new }, [:]] {
            let transform = ScrollbackReplayTransform.make(environment: environment)
            XCTAssertEqual(
                transform(Data("a\u{1B}[c\u{1B}[?2048hb".utf8)), Data("ab".utf8),
                "the query and the mode enable go however the environment is set",
            )
        }
    }

    /// The one surviving gate really does gate: with the distiller off, the B→C editing bytes come
    /// back verbatim instead of collapsing to the committed command.
    func testTheDistillGateIsTheOnlyOneLeftAndItWorks() throws {
        let cycle = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}gi-junk\u{1B}]133;E;git status\u{07}"
            + "\u{1B}]133;C\u{07}On branch main\n\u{1B}]133;D;0\u{07}"
        let on = ScrollbackReplayTransform.make(environment: [:])
        XCTAssertEqual(
            on(Data(cycle.utf8)),
            Data("\u{1B}]133;A\u{07}$ git status\r\nOn branch main\n".utf8),
            "the B→C churn collapses to the committed command",
        )
        let off = ScrollbackReplayTransform.make(environment: ["SLOPDESK_SCROLLBACK_DISTILL": "0"])
        let text = try XCTUnwrap(String(bytes: off(Data(cycle.utf8)), encoding: .utf8))
        XCTAssertTrue(text.contains("gi-junk"), "with the gate off the raw editing bytes survive")
    }

    /// End-to-end over a full captured-shape prompt cycle: an exited TUI leaves no drawing, a live
    /// one keeps its open segment, and the zsh `PROMPT_SP` cluster leaves no stray mark — the three
    /// passes whose ORDER this type owns, observed through the one call site that composes them.
    func testTheComposedTransformCleansACapturedPromptCycle() throws {
        let transform = ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true)
        let exited = transform(
            Data("$ vi\r\n\u{1B}[?1049h\u{1B}[?1002hDRAW\u{1B}[?1002l\u{1B}[?1049l$ ok\r\n".utf8),
        )
        XCTAssertEqual(exited, Data("$ vi\r\n$ ok\r\n".utf8))

        let live = transform(Data("$ vi\r\n\u{1B}[?1002h\u{1B}[?1049hFRAME".utf8))
        XCTAssertEqual(live, Data("$ vi\r\n\u{1B}[?1049hFRAME\u{1B}[?1002h".utf8))

        let cluster = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
            + String(repeating: " ", count: 121) + "\r \r"
        let aMark = "\u{1B}]133;A\u{07}"
        let cycle = "ls output\r\n" + cluster + "\u{1B}]133;D;0\u{07}" + aMark + "PS1 "
        let out = try XCTUnwrap(String(bytes: transform(Data(cycle.utf8)), encoding: .utf8))
        XCTAssertFalse(out.contains("       "), "the COLUMNS-wide space fill must not survive replay")
        XCTAssertFalse(out.contains("\u{1B}[7m%"), "the standout mark must not survive replay")
        XCTAssertTrue(out.contains(aMark), "the 133;A prompt anchor must survive (block-jump counts)")
    }
}
