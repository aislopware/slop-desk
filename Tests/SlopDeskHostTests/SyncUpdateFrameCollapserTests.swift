import Foundation
import XCTest
@testable import SlopDeskHost

/// ``SyncUpdateFrameCollapser`` — static synchronized-output repaints (`?2026h…?2026l` with no
/// scroll effect) are dropped from replay; frames that move content into history, change screen
/// state a later frame depends on, or are the stream-final frame survive verbatim.
final class SyncUpdateFrameCollapserTests: XCTestCase {
    private func collapse(_ s: String) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: SyncUpdateFrameCollapser.collapse(Data(s.utf8)), as: UTF8.self)
    }

    private let begin = "\u{1B}[?2026h"
    private let end = "\u{1B}[?2026l"

    /// The Claude Code shape: absolute-anchored spinner repaints with no LF. All but the LAST
    /// frame drop; surrounding plain output is untouched.
    func testDropsStaticRepaintFramesKeepsLast() {
        let f1 = begin + "\u{1B}[?25l\u{1B}[H\r\u{1B}[40B\u{1B}[38;2;1;2;3mA\u{1B}[46;1H\u{1B}[?25h" + end
        let f2 = begin + "\u{1B}[?25l\u{1B}[H\r\u{1B}[40B\u{1B}[38;2;1;2;3mB\u{1B}[46;1H\u{1B}[?25h" + end
        let f3 = begin + "\u{1B}[?25l\u{1B}[H\r\u{1B}[40B\u{1B}[38;2;1;2;3mC\u{1B}[46;1H\u{1B}[?25h" + end
        let input = "before\r\n" + f1 + f2 + f3 + "after"
        XCTAssertEqual(collapse(input), "before\r\n" + f3 + "after")
    }

    /// A frame that scrolls content into history (LF) survives even mid-stream.
    func testKeepsScrollBearingFrame() {
        let quiet = begin + "\u{1B}[H\u{1B}[2Kspin" + end
        let scrolls = begin + "\u{1B}[Hline one\r\nline two\r\n" + end
        let last = begin + "\u{1B}[H\u{1B}[2Ktick" + end
        XCTAssertEqual(collapse(quiet + scrolls + last), scrolls + last)
    }

    /// IND / NEL / RI / RIS two-byte escapes force a keep (scroll / global reset effects).
    func testKeepsIndexAndResetEscapes() {
        for escape in ["\u{1B}D", "\u{1B}E", "\u{1B}M", "\u{1B}c"] {
            let special = begin + "x" + escape + "y" + end
            let last = begin + "z" + end
            XCTAssertEqual(
                collapse(special + last), special + last,
                "frame containing \(escape.debugDescription) must survive",
            )
        }
    }

    /// CSI S / CSI T (scroll), ED 2/3, and DECSTBM force a keep; plain in-frame erases don't.
    func testKeepsScrollRegionAndFullClearCSIs() {
        for kept in ["\u{1B}[2S", "\u{1B}[T", "\u{1B}[2J", "\u{1B}[3J", "\u{1B}[1;20r"] {
            let special = begin + "x" + kept + "y" + end
            let last = begin + "z" + end
            XCTAssertEqual(
                collapse(special + last), special + last,
                "frame containing \(kept.debugDescription) must survive",
            )
        }
        // The churn's own erases (EL, ED-to-end) do NOT protect a frame.
        let churn = begin + "\u{1B}[2K\u{1B}[J\u{1B}[0J\u{1B}[1J" + end
        let last = begin + "z" + end
        XCTAssertEqual(collapse(churn + last), last)
    }

    /// An alt-screen transition inside a frame must survive (AltScreenSegmentStripper
    /// segmentation + the live TUI's screen switch depend on it).
    func testKeepsAltScreenTransitionFrames() {
        for mode in ["\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?47h", "\u{1B}[?1047l"] {
            let special = begin + mode + "draw" + end
            let last = begin + "z" + end
            XCTAssertEqual(
                collapse(special + last), special + last,
                "frame containing \(mode.debugDescription) must survive",
            )
        }
    }

    /// An OSC `133;` prompt mark inside a frame anchors the distiller — keep. Other OSCs
    /// (title churn) don't protect a frame.
    func testKeepsPromptMarkFramesDropsTitleOnlyFrames() {
        let marked = begin + "\u{1B}]133;A\u{07}prompt" + end
        let titled = begin + "\u{1B}]0;spinner tick\u{07}\u{1B}[H." + end
        let last = begin + "z" + end
        XCTAssertEqual(collapse(marked + titled + last), marked + last)
    }

    /// Inter-frame bytes (title updates, charset selects) survive even when both neighbours drop.
    func testPreservesInterFrameBytes() {
        let f1 = begin + "\u{1B}[Ha" + end
        let f2 = begin + "\u{1B}[Hb" + end
        let last = begin + "\u{1B}[Hc" + end
        let title = "\u{1B}]0;⠐ working\u{07}"
        XCTAssertEqual(collapse(f1 + title + f2 + last), title + last)
    }

    /// An UNTERMINATED trailing frame (the cut fell mid-repaint) passes through verbatim.
    func testUnterminatedTrailingFramePassesThrough() {
        let f1 = begin + "\u{1B}[Ha" + end
        let open = begin + "\u{1B}[H\u{1B}[2Khalf-drawn"
        XCTAssertEqual(collapse(f1 + open), open)
    }

    /// A `?2026h` inside an OSC/DCS body is data, not a frame opener.
    func testIgnoresSyncMarkersInsideStringSequences() {
        let osc = "\u{1B}]0;fake \u{1B}[?2026h title\u{07}"
        // No real frames → untouched (including the embedded pseudo-marker).
        XCTAssertEqual(collapse(osc + "plain"), osc + "plain")
    }

    /// Piggybacked params on the opener/closer (`?2026;25h`) forbid dropping the frame.
    func testMixedParamMarkersForceKeep() {
        let mixed = "\u{1B}[?2026;25h" + "\u{1B}[Hx" + end
        let last = begin + "y" + end
        XCTAssertEqual(collapse(mixed + last), mixed + last)
    }

    /// No droppable frames → byte-identical input (the steady-state fast path).
    func testNoFramesIsIdentity() {
        let plain = "ls -la\r\ntotal 42\r\n\u{1B}[1;31mred\u{1B}[0m\r\n"
        XCTAssertEqual(collapse(plain), plain)
        // A single frame is always the last frame — kept.
        let one = begin + "\u{1B}[Hx" + end
        XCTAssertEqual(collapse(one), one)
    }

    /// A truncated trailing CSI (chunk cut mid-sequence) passes through unchanged.
    func testTruncatedTrailingCSIPassesThrough() {
        let f1 = begin + "\u{1B}[Ha" + end
        let cut = "tail\u{1B}[38;5"
        XCTAssertEqual(collapse(f1 + cut), f1 + cut)
    }

    /// Real-shape volume guard: thousands of spinner frames collapse to just the last one.
    func testCollapsesSpinnerChurnBulk() {
        var input = "prompt$ claude\r\n"
        for i in 0..<2000 {
            input += begin + "\u{1B}[?25l\u{1B}[H\r\u{1B}[40B tick \(i % 10)\u{1B}[46;1H\u{1B}[?25h" + end
        }
        let out = collapse(input)
        XCTAssertTrue(out.hasPrefix("prompt$ claude\r\n"))
        XCTAssertTrue(out.contains("tick 9"), "last frame kept")
        XCTAssertLessThan(out.count, 200, "churn collapsed to the final frame")
    }
}
