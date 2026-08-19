// PaneModeOverlayTests proves the two AppKit mode overlays (docs/56 wave R, batch R4) keep the
// promises their SwiftUI halves make and a compiler cannot check.
//
// 1. THE HINT OVERLAY IS FLIPPED. `TerminalCellMetrics` answers in the surface's TOP-LEFT-origin
//    space, which is the space SwiftUI's `.offset` already draws in — so the SwiftUI half never had
//    to say so, and a port that dropped `isFlipped` compiles, runs, and puts a two-letter label on
//    the word mirrored about the viewport's middle. Every badge is then present, legible, and
//    pointing at the wrong thing, which is worse than an empty overlay: pressing the letter opens
//    something the user did not aim at.
//
// 2. THE HINT OVERLAY IS TRANSPARENT TO THE POINTER WHILE THE MODE IS DOWN. It is mounted
//    unconditionally over every terminal pane (the leaf never branches on it — the libghostty-freeze
//    guardrail), so it spends nearly all of its life invisible ON TOP of a surface that must keep
//    every click. Armed, the dim plate is deliberately the opposite: it swallows stray clicks and
//    cancels the mode. One `Bool` decides both, and getting it backwards makes the terminal
//    unclickable in a way that looks like the renderer broke.
//
// 3. THE KEY-HINT CARD RE-FLOWS INSTEAD OF CLIPPING, AND ALL THREE RUNGS ARE REACHABLE. AppKit hands
//    a view its own bounds — the size it has ALREADY taken — so the proposal has to arrive from the
//    mounter, and a card that ignored it would silently hug its widest arrangement and hang off the
//    edge of a narrow split. The middle rung is the one a port drops: MOTION beside a stacked
//    SELECT+SEARCH looks like an optimisation until you notice a narrow pane goes from three columns
//    straight to one tall one and scrolls. The sweep below pins that exactly three distinct drawings
//    exist across every width.
//
// 4. BOTH CHIPS' WORDS COME FROM THE FLOOR. `ViKeyHintPresentation` owns the pill's a11y wording and
//    the card's honesty surface; a renderer that hand-wrote either would drift from the phone's the
//    first time a key was added.
//
// 5. THE PILL'S `×` IS THE STATUS CHIP'S `×`. Both float in the same corner of the same pane, and the
//    square they take is `Slate.Metric.glyphPlate` — minted (stage F batch P6) precisely because
//    three chips across two renderers each spelled `16`. A private copy here would be the fourth.
//
// Headless: `isFlipped`, `hitTest`, `fittingSize` and a view's own subtree all need no window (the
// hang-safety rule forbids an `NSWindow` in a test), and the model is built over a `nil` surface so no
// libghostty / Metal / socket is touched.
//
// ⚠️ The ARMED half of the hint overlay is not reachable here, and that is the honest ceiling rather
// than an omission: arming needs `cellMetrics()`, which only a libghostty-backed surface answers, and
// that surface hangs without a window server. What is testable is that the overlay is inert without
// one — which is the same "labels are ABSENT, never wrong" promise `HintPresentation.isArmed` exists
// to keep.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class PaneModeOverlayTests: XCTestCase {
    // MARK: The hint overlay

    func testTheHintOverlayDrawsInTheCellGridsTopLeftOriginSpace() {
        XCTAssertTrue(
            MacHintModeOverlay(model: TerminalViewModel()).isFlipped,
            "the hint overlay is y-UP — every badge it anchors from TerminalCellMetrics is "
                + "top-left-origin, so each label now stands on the wrong row and resolving it opens "
                + "something the user never aimed at",
        )
    }

    func testTheHintOverlayIsTransparentToThePointerWhileTheModeIsDown() {
        let overlay = MacHintModeOverlay(model: TerminalViewModel())
        overlay.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        XCTAssertNil(
            overlay.hitTest(NSPoint(x: 200, y: 120)),
            "a click in the middle of an UNARMED hint overlay must reach the terminal under it — the "
                + "overlay is mounted over every pane for its whole life and armed for seconds of it",
        )
    }

    func testTheHintOverlayDrawsNothingWithoutALiveSurface() {
        // The honest ceiling, as a fact rather than as prose: no snapshot ⇒ no metrics ⇒ no overlay.
        // A port that guessed a cell size to have something to show would fail here.
        let overlay = MacHintModeOverlay(model: TerminalViewModel())
        XCTAssertTrue(
            overlay.isHidden,
            "the hint overlay mounted VISIBLE over a surface that reports no cell geometry — a badge "
                + "drawn at a guessed cell size points at the wrong word",
        )
    }

    // MARK: The key-hint card

    func testTheCardReflowsRatherThanKeepingOneWidth() {
        let wide = MacViKeyHintBar()
        let narrow = MacViKeyHintBar()
        narrow.availableWidth = 1
        XCTAssertGreaterThan(
            measure(wide).width, measure(narrow).width,
            "the card is one width at every proposal — it is not reading `availableWidth` at all, so "
                + "a narrow split gets a card hanging off its edge",
        )
        XCTAssertLessThan(
            measure(wide).height, measure(narrow).height,
            "the card did not get TALLER as it got narrower — a re-flow trades width for height, and "
                + "one that does not is a clip",
        )
    }

    func testTheCardHasExactlyThreeDrawings() {
        // Sweep every proposal from nothing up to the widest arrangement and collect the distinct
        // sizes. THREE is the whole ladder (`ViKeyHintLayout`); two would mean the middle rung —
        // MOTION beside a stacked SELECT+SEARCH — was never built, which no end-to-end width check
        // would notice because both ends would still be right.
        let bar = MacViKeyHintBar()
        // The UN-PROPOSED card is seeded separately rather than left to the sweep to find. Its rung's
        // threshold is exactly the widest width, and a stride that steps past that boundary by a
        // point would miss the three-column drawing and fail on the arithmetic of the test.
        var drawings: Set<CGSize> = [measure(bar)]
        let widest = measure(bar).width
        for step in stride(from: CGFloat.zero, through: widest, by: 2) {
            bar.availableWidth = step
            drawings.insert(measure(bar))
        }
        XCTAssertEqual(
            drawings.count, Self.expectedRungs,
            "the card draws \(drawings.count) arrangements across every width, not \(Self.expectedRungs) — "
                + "`ViKeyHintPresentation.groups(for:)` names three slots and this renderer honours fewer",
        )
    }

    func testTheCardsHonestySurfaceIsTheFloors() {
        XCTAssertFalse(
            MacViKeyHintBar.advertisedKeys.isEmpty,
            "the card advertises no keys at all — the honesty surface a test reads to prove it lists "
                + "only WIRED keys has been disconnected",
        )
        XCTAssertEqual(
            MacViKeyHintBar.advertisedKeys, ViKeyHintPresentation.advertisedKeys,
            "the Mac card advertises a different key list than the tables — a renderer's own copy of "
                + "the honesty surface is a promise about keys nothing dispatches",
        )
    }

    // MARK: The pill

    func testThePillSpeaksTheFloorsWords() {
        let pill = MacViModePill(model: TerminalViewModel(), onExit: {})
        XCTAssertEqual(
            pill.accessibilityLabel(),
            ViKeyHintPresentation.accessibilityLabel(mode: .none, count: nil),
            "the pill announces itself in words of its own — VoiceOver then says one thing on the Mac "
                + "and another on the phone for the same mode",
        )
        XCTAssertEqual(
            pill.accessibilityHelp(), ViKeyHintPresentation.exitHelp,
            "the pill's exit help is hand-written — it and the `×`'s tooltip name ONE action",
        )
    }

    func testThePillWearsTheStatusChipsCloseMark() {
        let pill = MacViModePill(model: TerminalViewModel(), onExit: {})
        guard let close = descendant(of: pill, ofType: MacPaneStatusPillCloseView.self) else {
            XCTFail(
                "the vi pill grew its own `×` — the mark on a pane chip is one control, and a second "
                    + "spelling of it is a second chance to be a rung off the chip beside it",
            )
            return
        }
        XCTAssertEqual(
            close.fittingSize, CGSize(width: Slate.Metric.glyphPlate, height: Slate.Metric.glyphPlate),
            "the pane chip's `×` is no longer a `Slate.Metric.glyphPlate` square — that rung was minted "
                + "because three chips across two renderers each spelled the number themselves",
        )
    }

    // MARK: Helpers

    /// The three rungs of ``ViKeyHintLayout``, as a number the failure message can name. Spelled here
    /// rather than derived from the enum, because the point of the assertion is that the RENDERER
    /// draws all of them — counting the cases would only prove the enum still has three.
    private static let expectedRungs = 3

    /// The size the card settles at, after letting Auto Layout resolve the arrangement the proposal
    /// just chose — `fittingSize` is asked of a subtree that has re-parented its columns.
    private func measure(_ bar: MacViKeyHintBar) -> CGSize {
        bar.layoutSubtreeIfNeeded()
        return bar.fittingSize
    }

    private func descendant<T: NSView>(of view: NSView, ofType _: T.Type) -> T? {
        for child in view.subviews {
            if let hit = child as? T { return hit }
            if let hit = descendant(of: child, ofType: T.self) { return hit }
        }
        return nil
    }
}
#endif
