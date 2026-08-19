// TerminalFindBarKeysTests proves the three promises the AppKit find bar (docs/56 wave R, batch R5)
// makes that a compiler cannot check.
//
// 1. ⇧↩ AND ↩ DO NOT DOUBLE-FIRE, AND ⇧↩ REACHES `previous`. Both arrive at an `NSTextField` delegate
//    through the SAME selector, distinguished only by a modifier the delegate has to go and ask the
//    current event for. The SwiftUI half spent a `.shift` guard on exactly this, and a port that
//    dropped it compiles, runs, and steps FORWARD on ⇧↩ — a find bar that can only walk one way, in
//    the direction it was already walking. The three return selectors are all routed because WHICH of
//    them a ⇧↩ arrives as belongs to the user's key-binding tables, not to this app.
//
// 2. THE MODE CHIPS ARE THE SHARED PILL, NOT A THIRD DRAWING. `MacGlobalSearch` already ships an
//    AppKit `Aa` / `.*` chip, and the locked invariant is that the find bar and the global-search
//    query bar render the pills IDENTICALLY. `check-supervisor.sh` pins the two halves that RESOLVE
//    `FindTogglePillAppearance`; nothing stops a third renderer from resolving it a fourth way, and a
//    hover plate one rung off in one of the two bars reads as correct in both until they are put side
//    by side. This pins that the find bar mounts `MacFindTogglePillView` itself — the same class, not
//    the same recipe.
//
// 3. THE BAR STANDS ON THE POINTER RUNG. `FindBarMetrics` names its two rungs by INPUT DEVICE
//    precisely so neither renderer picks by platform, and the touch rung is a plausible default for a
//    port that reached for the nearest number. A Mac plate is 24 and a finger's is 34; both lay out,
//    and only one of them is this bar.
//
// Headless: an `NSView`'s constraints and `fittingSize` need no window (the hang-safety rule forbids
// an `NSWindow` in a test), so nothing here mounts one — which also means the bar never takes first
// responder and never opens a field editor.

#if os(macOS)
import AppKit
import SlopDeskClientCore
import XCTest
@testable import SlopDeskMacUI

@MainActor
final class TerminalFindBarKeysTests: XCTestCase {
    // MARK: The keyboard

    func testShiftReturnStepsBackwardAndPlainReturnStepsForward() {
        for selector in Self.returnSelectors {
            XCTAssertEqual(
                MacFindBarKey.verb(for: selector, shift: false), .next,
                "↩ through \(selector) stopped meaning `next` — the find bar's primary step",
            )
            XCTAssertEqual(
                MacFindBarKey.verb(for: selector, shift: true), .previous,
                "⇧↩ through \(selector) fell through to `next` — the bar can only walk forwards now",
            )
        }
    }

    func testEscapeClosesRegardlessOfShift() {
        // Esc is the way out of the bar, and it is the only key here that does not care about the
        // modifier — a ⇧⎋ that passed through would leave the bar open with the highlights armed.
        for shift in [false, true] {
            XCTAssertEqual(
                MacFindBarKey.verb(for: #selector(NSResponder.cancelOperation(_:)), shift: shift),
                .close,
                "⎋ (shift: \(shift)) stopped closing the find bar",
            )
        }
    }

    func testEveryOtherKeyBelongsToTheFieldEditor() {
        // The delegate returns `false` for `.passThrough`, which is what leaves typing, ⌘A, the arrow
        // keys and every IME command to the field editor. A routing table that claimed one of them
        // would make the query field stop being a text field in a way no test of the bar's LOOK sees.
        for selector in [
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.insertParagraphSeparator(_:)),
        ] {
            XCTAssertEqual(
                MacFindBarKey.verb(for: selector, shift: false), .passThrough,
                "\(selector) was claimed by the find bar — it belongs to the field editor",
            )
        }
    }

    // MARK: The chips

    func testTheModeChipsAreTheSharedAppKitPill() {
        let bar = MacTerminalFindBar(model: TerminalFindBarModel())
        let chips = Self.descendants(of: bar).compactMap { $0 as? MacFindTogglePillView }
        XCTAssertEqual(
            chips.count, FindModePill.inPaneFindBar.count,
            """
            the find bar draws \(chips.count) `MacFindTogglePillView`s for \
            \(FindModePill.inPaneFindBar.count) modes — either a chip went missing or one of them is a \
            second AppKit spelling of the pill `MacGlobalSearch` already ships
            """,
        )
    }

    func testTheBarOffersWholeWordAndTheCrossTabSearchDoesNot() {
        // The two lists are ONE decision — "which engine can answer which question" — and the in-pane
        // bar is the half that has a word-boundary filter. A find bar that read `FindModePill.globalSearch`
        // would lose the `ab` chip silently, with three chips' worth of layout still looking right.
        XCTAssertTrue(
            FindModePill.inPaneFindBar.contains(.wholeWord),
            "the in-pane find bar stopped offering whole-word matching",
        )
        XCTAssertFalse(
            FindModePill.globalSearch.contains(.wholeWord),
            "the cross-tab search grew a whole-word chip it has no engine for",
        )
    }

    // MARK: The rung

    func testTheTrailingPlatesStandOnThePointerRung() {
        // Guard the guard: if the two rungs ever converge, the assertion below passes for both and
        // this test stops saying anything.
        XCTAssertNotEqual(
            FindBarMetrics.pointer.plate, FindBarMetrics.touch.plate,
            "the pointer and touch rungs have converged — nothing below can tell them apart",
        )

        let bar = MacTerminalFindBar(model: TerminalFindBarModel())
        // Measured through a real layout pass rather than off the constraint constants — the same
        // reason `PaneScrimVeilTests` reads its alphas off the layer: a rung asserted against the
        // token it came from passes while every plate draws the other one.
        bar.frame = NSRect(origin: .zero, size: bar.fittingSize)
        bar.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            bar.frame.width, 0, "the bar resolved to nothing — the measurements below say nothing",
        )

        let plates = Self.descendants(of: bar).compactMap { $0 as? MacPlateIconButton }
        // ∧ previous, ∨ next, ▣ search-all-tabs, × close — `find.png`'s four trailing verbs.
        XCTAssertEqual(plates.count, 4, "the find bar's trailing verbs changed in number")
        for plate in plates {
            XCTAssertEqual(
                plate.frame.width, CGFloat(FindBarMetrics.pointer.plate), accuracy: 0.001,
                "a trailing plate laid out \(plate.frame.width)pt wide — the Mac's rung is the POINTER's",
            )
            XCTAssertEqual(
                plate.frame.height, CGFloat(FindBarMetrics.pointer.plate), accuracy: 0.001,
                "a trailing plate laid out \(plate.frame.height)pt tall — the Mac's rung is the POINTER's",
            )
        }
    }

    // MARK: Fixtures

    /// The selectors a RETURN press can arrive as. Listed here rather than read off the routing table
    /// so the test names the keys the bar promises to handle instead of restating whatever it happens
    /// to handle.
    private static let returnSelectors: [Selector] = [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
    ]

    /// Every view under `root`, root excluded — the bar nests its parts inside stack views, so a
    /// one-level `subviews` scan would find neither the chips nor the plates.
    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
