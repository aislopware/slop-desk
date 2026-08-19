// ViKeyHintPresentationTests — the vi reference card's two invariants, both asked of the VALUE rather
// than of a view.
//
// THE HONESTY RULE: the card advertises ONLY keys slopdesk's copy-mode engine actually wires (a faithful
// subset of full vi), never a dead key. Pure data over ``ViKeyHintPresentation/advertisedKeys``, the same
// tables the renderers draw from.
//
// THE WIDTH LADDER: the card used to pick its arrangement with a `ViewThatFits`, which no test could ask
// a question of without mounting three candidate layouts. Said as arithmetic
// (``ViKeyHintPresentation/layout(forWidth:gap:columnWidth:)``) the RUNG BOUNDARIES are pinnable — and
// the boundaries are the part that drifts, because both renderers measure their own type and only the
// comparison is shared.

import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientCore

/// The visual-mode enum's address, spelled once so the cases below read as cases.
private typealias VisualMode = TerminalViewModel.VisualMode

final class ViKeyHintPresentationTests: XCTestCase {
    // MARK: - Honesty

    /// The deliberately-unwired screen-relative jumps (`H`/`M`/`L`) stay unadvertised — the one honesty
    /// omission left after the E17 ceiling lift wired the cursor motions (DECISIONS.md 2026-07-14).
    func testHintBarDoesNotAdvertiseUnwiredKeys() {
        for dead in ["H", "M", "L"] {
            XCTAssertFalse(
                ViKeyHintPresentation.advertisedKeys.contains(dead),
                "the hint bar must not advertise the unwired motion `\(dead)`",
            )
        }
    }

    /// Positive control (guards against the test passing by listing nothing): the wired keys are present —
    /// including the CURSOR motions + `o` (swap ends) + `Y` (yank line) that joined with the ceiling lift.
    /// `?` pins the wired backward-find; `f` pins the Hint Mode entry (its own `beginHint` seam).
    func testHintBarAdvertisesTheWiredKeys() {
        let keys = Set(ViKeyHintPresentation.advertisedKeys)
        let wiredKeys = [
            "h", "j", "k", "l", "w", "b", "e", "0", "^", "$", "o", "Y",
            "g", "G", "v", "V", "y", "/", "?", "n", "N", "f",
        ]
        for wired in wiredKeys {
            XCTAssertTrue(keys.contains(wired), "the hint bar advertises the wired key `\(wired)`")
        }
    }

    /// The RANGE token is not a key. It rides `1 … 9`'s `keys` array so the row reads as a range, and a
    /// renderer draws it plateless — but a test that counted it would be asserting the engine wires `…`.
    func testSeparatorIsNotAdvertisedAsAKey() {
        XCTAssertFalse(ViKeyHintPresentation.advertisedKeys.contains(ViKeyHintPresentation.separator))
        XCTAssertTrue(
            ViKeyHintPresentation.motion.contains { $0.keys.contains(ViKeyHintPresentation.separator) },
            "the separator is still IN a row — otherwise this test passes by its absence",
        )
    }

    // MARK: - The width ladder

    /// Three columns whose intrinsic widths differ, so `selectionWidth` vs `searchWidth` actually matters
    /// to the middle rung (a `VStack` is as wide as its widest child).
    private static let width: [ViKeyHintColumn: Double] = [.motion: 200, .selection: 160, .search: 140]
    private let gap: Double = 16

    private func rung(_ available: Double) -> ViKeyHintLayout {
        ViKeyHintPresentation.layout(
            forWidth: available, gap: gap, columnWidth: { Self.width[$0] ?? 0 },
        )
    }

    /// The three-column rung's boundary: 200 + 160 + 140 + two gaps = 532. Exactly 532 FITS (the ladder
    /// asks `<=`, so a card measured to the point does not drop a rung for a rounding).
    func testThreeColumnsBoundary() {
        XCTAssertEqual(rung(532), .threeColumns)
        XCTAssertEqual(rung(531.5), .motionBesideStack)
    }

    /// The middle rung's boundary: MOTION beside the WIDER of the two stacked columns, plus one gap —
    /// 200 + 160 + 16 = 376. One point under it and the card goes single-column.
    ///
    /// The `max` is the part worth pinning: measuring against SEARCH (140, the narrower) would claim the
    /// arrangement fits at 356, where SELECT would then overhang the card.
    func testMotionBesideStackBoundary() {
        XCTAssertEqual(rung(376), .motionBesideStack)
        XCTAssertEqual(rung(375), .oneColumn)
    }

    /// A card with no width proposed at all reports its widest arrangement — that is what makes a parent
    /// with room give it room.
    func testUnboundedWidthTakesTheWidestRung() {
        XCTAssertEqual(rung(.infinity), .threeColumns)
    }

    /// A pane narrower than one column still gets the WHOLE card, stacked — never a clipped one.
    func testNarrowPaneStillGetsEveryColumn() {
        XCTAssertEqual(rung(40), .oneColumn)
        XCTAssertEqual(
            ViKeyHintPresentation.groups(for: .oneColumn), [[.motion, .selection, .search]],
        )
    }

    /// Every rung draws every column exactly once — a slot list that dropped or repeated one would be a
    /// reference card missing a section, which no width test would catch.
    func testEveryRungDrawsEveryColumnOnce() {
        for layout in [ViKeyHintLayout.threeColumns, .motionBesideStack, .oneColumn] {
            let drawn = ViKeyHintPresentation.groups(for: layout).flatMap(\.self)
            XCTAssertEqual(
                drawn.count, ViKeyHintColumn.allCases.count,
                "\(layout) draws a column twice or not at all",
            )
            XCTAssertEqual(Set(drawn), Set(ViKeyHintColumn.allCases), "\(layout) drops a column")
        }
    }

    // MARK: - The pill's words

    /// The `?? "VI"` fallback: plain scrollback navigation has no visual-mode label of its own, and the
    /// bare `VI` is what stands in its place.
    func testPillLabelFallsBackToVI() {
        XCTAssertEqual(TerminalViewModel.VisualMode.none.pillLabelOrDefault, "VI")
        XCTAssertEqual(TerminalViewModel.VisualMode.char.pillLabelOrDefault, "VISUAL")
        XCTAssertEqual(TerminalViewModel.VisualMode.line.pillLabelOrDefault, "VISUAL LINE")
        XCTAssertEqual(TerminalViewModel.VisualMode.block.pillLabelOrDefault, "VISUAL BLOCK")
    }

    /// `.none` is the ONLY non-visual mode — the accent ring is the "I am selecting" cue, so a mode
    /// wrongly reading as non-visual would silently take it away.
    func testIsVisualIsEveryModeButNone() {
        XCTAssertFalse(TerminalViewModel.VisualMode.none.isVisual)
        for mode in [VisualMode.char, .line, .block] {
            XCTAssertTrue(mode.isVisual)
        }
    }

    /// VoiceOver reads the mode and then the pending count, and reads nothing extra when none is pending.
    func testAccessibilityLabelAppendsThePendingCount() {
        XCTAssertEqual(
            ViKeyHintPresentation.accessibilityLabel(mode: .char, count: 5), "Vi mode VISUAL 5",
        )
        XCTAssertEqual(ViKeyHintPresentation.accessibilityLabel(mode: .none, count: nil), "Vi mode VI")
    }
}
