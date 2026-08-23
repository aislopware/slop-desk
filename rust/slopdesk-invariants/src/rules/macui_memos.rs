//! Nine held values on the paths `AppKit` drives at the display's rate.
//!
//! Ported from `scripts/check-supervisor.sh`. Every rule here pins a HELD value — a cache, a guard,
//! a stored list — whose absence changes nothing a test can see. The view draws the same pixels,
//! the same rows come back, the same seam moves; only the clock moves, and only on the paths
//! `AppKit` drives at the display's rate (a divider drag, a live window resize, a `CADisplayLink`
//! tick, a keystroke in an overlay). That is the shape `docs/55` §8 catalogues: a fact re-derived
//! because re-deriving it looked free at the call site. A green suite is exactly what a regression
//! here looks like, so the pin has to be textual.
//!
//! The numbers below were measured on the author's machine against the shipped xcframework under
//! `swiftc -O`, two agreeing runs each, with the FFI door floor (1.7 ns) as the unit of "free".

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The sidebar header, which holds the git line's measured ladder.
const HEADER: &str = "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift";
/// The overlay whose corpus is one DFS per session, tab and pane.
const OPEN_QUICKLY: &str = "Sources/SlopDeskMacUI/Overlays/MacOpenQuickly.swift";
/// The canvas that re-solves every seam in the tab at the display's rate.
const CANVAS: &str = "Sources/SlopDeskMacUI/Pane/MacSplitCanvasView.swift";
/// The leaf whose drag update used to walk the split tree.
const GUI_LEAF: &str = "Sources/SlopDeskMacUI/Pane/MacGuiLeafView.swift";
/// The container that re-runs its pane count on every ⌃⇥ tap.
const CONTAINER: &str = "Sources/SlopDeskMacUI/Pane/MacPaneContainer.swift";
/// The one path in this directory where the user watches the latency directly.
const DISPATCH: &str = "Sources/SlopDeskMacUI/Input/WorkspaceKeyDispatcher.swift";
/// The GUI control bar's button, re-assigned about twice a second forever.
const PLATE: &str = "Sources/SlopDeskMacUI/Panel/MacPlateIconButton.swift";
/// The two spinners, both driven by a `CADisplayLink`.
const SPINNERS: &[&str] = &[
    "Sources/SlopDeskMacUI/Overlays/MacAgentGlyph.swift",
    "Sources/SlopDeskMacUI/Columns/MacStatusMark.swift",
];
/// The divider, whose readout reaches an un-memoized CoreText build.
const DIVIDER: &str = "Sources/SlopDeskMacUI/Pane/MacPaneDivider.swift";

/// M1. The sidebar's git line stays MEASURED, not re-measured
///
/// `MacGitLineView` picks between an inline spelling and a four-rung ladder by asking each
/// candidate how wide it is, and `AppKit` asks for `intrinsicContentSize` and `draw(_:)` on every
/// layout pass of the sidebar — a window resize, a sidebar drag, a row insertion.
///
/// The shedding `draw` was 59–65 µs and `intrinsicContentSize` 16.8–17.5 µs, both of them
/// `NSAttributedString.size()` (2.0–2.3 µs each, full CoreText typesetting) over five to nine
/// candidates. Building the ladder ONCE costs 50–52 µs; every read after it is 5 ns.
///
/// Three arms, because three separate things can go: the ladder being deleted, `measured()` being
/// inlined back into its two callers, and — the one that is not a speed rule at all — the
/// invalidation. The ladder is `segments` measured, so it must die with them and with nothing else;
/// a `didSet` that rebuilds the segments without dropping the ladder serves the OLD branch name
/// forever, which is worse than the 62 µs it saves.
///
/// Break-tested: `ladder` renamed to `ladderCache` in the real file → all three arms fired.
#[must_use]
pub fn the_git_line_stays_measured(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: HEADER,
            pattern: r"private var ladder: Ladder\?",
            view: View::Raw,
            message: "the sidebar header no longer holds its measured ladder — the git line would \
                      re-typeset five to nine candidate strings on every AppKit layout pass (59–65 µs) to \
                      pick the one it already picked",
        },
        Claim::Matches {
            path: HEADER,
            pattern: r"private func measured\(\) -> Ladder\?",
            view: View::Raw,
            message: "the sidebar header lost measured() — intrinsicContentSize and draw(_:) must share ONE \
                      build of the ladder, or the guard above buys nothing",
        },
        Claim::Matches {
            path: HEADER,
            pattern: r"ladder = nil",
            view: View::Raw,
            message: "the sidebar header never invalidates the ladder — a memo with no kill is a stale git \
                      line, which is worse than the 62 µs it saves",
        },
    ])
}

/// M2. Open Quickly builds its corpus ONCE per draw
///
/// `sections(filter:)` walks every session, tab and pane, spends a `TreeWorkspace.spec` DFS per
/// pane, re-ranks the whole folder frecency history and runs five fuzzy passes. The shipped
/// `draw()` ran it twice — once for the display entries, once through a `selectableRows(filter:)`
/// METHOD — and `move`, `moveToEnd`, `setActions`, `actSelected` and every ⌘-digit ran a third.
///
/// The ban catches the method growing back, and it is also the CORRECT shape rather than merely the
/// cheap one: a clamp or a ⌘-digit resolved against a freshly-derived corpus answers about rows the
/// user is not looking at, because the corpus can have moved under the selection since the draw
/// that showed it.
///
/// The ban reads CODE and the pin reads RAW, which is the split the shell had and it is
/// load-bearing: the doc comment above the stored property names `selectableRows(filter:)` to
/// record what it replaced, so a ban that could not tell the explanation from the thing explained
/// would have to be deleted the first time anyone read it.
///
/// Break-tested: the stored property replaced with a `private func selectableRows(filter:)`
/// forwarding to `OpenQuicklyModel.selectable(sections(filter:))` → both arms fired.
#[must_use]
pub fn open_quickly_builds_its_corpus_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Lacks {
            path: OPEN_QUICKLY,
            pattern: r"func selectableRows\(",
            view: View::Code,
            message: "Open Quickly derives its selectable rows again — they are the HELD result of the draw \
                      that put them on screen; a keystroke must clamp against the list the user can see, \
                      not a new one",
        },
        Claim::Matches {
            path: OPEN_QUICKLY,
            pattern: r"private var selectableRows: \[OpenQuicklyItem\]",
            view: View::Raw,
            message: "Open Quickly no longer holds selectableRows — see the ban above for why the held list \
                      is the correct one and not merely the fast one",
        },
    ])
}

/// M3. The canvas remembers which leaves are unthemed
///
/// `applyHandles` asked `store.tree.spec(for: leaf.id)?.kind == .desktop` per leaf, and it runs per
/// divider-drag frame, per live-resize frame and per pointer move of a pane drag. `spec` is a full
/// DFS of the split tree, so the cost is O(panes²) per frame for an answer that is FIXED for the
/// life of a pane id.
///
/// Two arms, and the second is the reason they are two: the cache never being PRUNED would keep a
/// closed pane's answer alive against a reused id, which is a wrong drawing rather than a slow one.
///
/// Break-tested: the pruning line deleted → the second arm fired alone, which is the point of
/// splitting it from the first.
#[must_use]
pub fn the_canvas_remembers_unthemed_leaves(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: CANVAS,
            pattern: r"handleIsUnthemed",
            view: View::Raw,
            message: "the canvas asks the tree for each leaf's kind again — that is a DFS per leaf per drag \
                      frame for an answer fixed for the life of the pane id",
        },
        Claim::Matches {
            path: CANVAS,
            pattern: r"handleIsUnthemed\[id\] = nil",
            view: View::Raw,
            message: "the canvas keeps unthemed answers for panes it has removed — the cache must be pruned \
                      in the same loop that tears the handle down",
        },
    ])
}

/// M4. The GUI leaf remembers its pane KIND, and only that
///
/// `isDesktopUploadTarget` ran a full tree DFS inside `draggingUpdated(_:)`, which `AppKit` fires
/// on every pointer move of a drag over the pane.
///
/// The shape that matters is what is NOT held: only the KIND is, because it is fixed for the life
/// of a pane id. The liveness half (`model?.active != nil`) stays a fresh read on every call, and a
/// `nil` kind is deliberately not cached, so a leaf that asks before its spec lands is not stuck
/// answering no. One arm, because the name is the whole pin — the two exclusions above are
/// unpinnable as text and are recorded here instead.
///
/// Break-tested: `cachedPaneKind` renamed → fired.
#[must_use]
pub fn the_gui_leaf_remembers_its_kind(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Matches {
        path: GUI_LEAF,
        pattern: r"cachedPaneKind",
        view: View::Raw,
        message: "the GUI leaf walks the split tree inside a drag-update again — cache the KIND (fixed per \
                  pane id), never the liveness",
    }])
}

/// M5. The container counts its tab's panes without building T arrays
///
/// `tabPaneCount` is read inside the `withObservationTracking` arm that observes
/// `store.paneSwitcher`, so EVERY mounted container re-runs it on every ⌃⇥ tap. The shipped
/// spelling was `tabs.first { $0.allPaneIDs().contains(paneID) }`, which allocates one array per
/// tab per pane per keypress before it can even test membership; `Tab.contains` answers without the
/// array.
///
/// Break-tested: the old predicate restored verbatim → fired.
#[must_use]
pub fn the_container_counts_without_arrays(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Lacks {
        path: CONTAINER,
        pattern: r"allPaneIDs\(\)\.contains\(paneID\)",
        view: View::Code,
        message: "the pane container allocates a pane-id array per tab just to test membership — ask \
                  Tab.contains, which is the same question without the allocation, on a ⌃⇥ path that runs \
                  it per mounted pane per keypress",
    }])
}

/// M6. The terminal reach is a set, not a linear scan built per keystroke
///
/// The two-chord array is rebuilt on every key event otherwise, which is the one path in this
/// directory where the user is watching the latency directly. The pin is the TYPE rather than the
/// name, because `[KeyChord]` is what it regresses to and it reads identically at the call site.
///
/// Break-tested: `Set<KeyChord>` changed to `[KeyChord]` → fired.
#[must_use]
pub fn the_terminal_reach_is_a_set(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Matches {
        path: DISPATCH,
        pattern: r"private static let terminalReach: Set<KeyChord>",
        view: View::Raw,
        message: "the key dispatcher rebuilds its code-panel chord list per key event — it is a static Set",
    }])
}

/// M7. The plate button guards its glyph name like its other two states
///
/// The GUI control bar assigns all four of its glyph names unconditionally from `applyChrome`,
/// which re-fires whenever any of the stream's ten telemetry mirrors move — about twice a second
/// for the life of a stream. Ungated, that re-rendered four SF Symbol images per tick, every one
/// byte-identical to the one already on screen.
///
/// What this catches is the guard being dropped while `active` and `enabled` keep theirs, which is
/// exactly how it was missing in the first place: the two that looked like state got one and the
/// one that looked like a plain string did not.
///
/// Break-tested: the guard line deleted → fired.
#[must_use]
pub fn the_plate_guards_its_glyph_name(tree: &Tree) -> Report {
    check_all(tree, &[Claim::Matches {
        path: PLATE,
        pattern: r"guard symbolName != oldValue else \{ return \}",
        view: View::Raw,
        message: "the plate button re-renders its SF Symbol on every assignment — symbolName carries the \
                  same equality guard as active and enabled, for a caller that assigns it ~2 Hz forever",
    }])
}

/// M8. Both spinners fill their dots through CoreGraphics
///
/// Both draws are driven by a `CADisplayLink`, so the loop runs once per dot per mark per display
/// refresh — and the rail can hold a mark per session.
///
/// Eight dots cost 28.6 µs/frame through `NSBezierPath(ovalIn:).fill()` and 21.8–23.2 µs through
/// `context.fillEllipse(in:)` — one `NSBezierPath` allocation per dot per frame, gone.
/// `setFillColor(red:green:blue:alpha:)` measured faster still (16.1–16.9 µs) and is REFUSED on
/// purpose: it would resolve the ink in a different colour space than
/// `withAlphaComponent(_:).setFill()`, which is a pixel change, not an optimisation.
///
/// Reads CODE, not the raw bytes: both files NAME the rejected spelling in the comment that records
/// the measurement, and a ban that fires on its own rationale is a ban nobody can satisfy.
///
/// Break-tested: `context.fillEllipse(in: frame)` swapped back to `NSBezierPath(ovalIn: frame)
/// .fill()` in `MacStatusMark.swift` → fired for that file only.
#[must_use]
pub fn both_spinners_fill_through_coregraphics(tree: &Tree) -> Report {
    let claims: Vec<Claim> = SPINNERS
        .iter()
        .map(|spinner| {
            Claim::Lacks {
                path: spinner,
                pattern: r"NSBezierPath\(ovalIn:",
                view: View::Code,
                message: "a spinner allocates an NSBezierPath per dot per display-link frame (28.6 µs vs 22 \
                          µs for eight dots) — fill the ellipse on the context",
            }
        })
        .collect();
    check_all(tree, &claims)
}

/// M9. The divider hides the readout BEFORE it cuts the text, and guards the handle
///
/// The canvas re-assigns `handle` on every seam in the tab on every solve, and a divider drag or a
/// live window resize solves at the display's rate. `RatioReadout.percents` sets three instrument
/// runs, each of which reaches the un-memoized `Slate.Typeface.instrumentNative` (a
/// `fontDescriptor.withFamily` plus an `NSFont(descriptor:size:)` CoreText build).
///
/// Four arms, because three things have to hold together and the fourth is the one text cannot see:
///
/// * the handle's `didSet` is guarded on the VALUE — only the seam under the cursor actually moves,
///   so this turns "N handles updated per frame" into "one", on both sides of `handleUpdated()`
///   (the readout AND an `invalidateCursorRects(for:)` round trip to the window server);
/// * `percents` is guarded field-by-field — a labelled optional tuple has no synthesized `==`, so a
///   `!=` on the whole thing does not compile and its absence is silent;
/// * `applyReadout()` sets `isHidden` FIRST and returns, so the N−1 seams that are not being
///   dragged do not build three fonts for pixels that are hidden. The ordering is safe because
///   `mouseDragged` sets `startLead` before `onResizeBegin()`/`setDragging(true)`, and
///   `setDragging` calls `applyReadout()` first — the readout is populated at the moment it becomes
///   visible;
/// * the ORDER, which is the rule, so the order is what is checked: a file that spells both lines
///   but sets the text first is exactly the regression, and it passes all three pins above.
///
/// Break-tested four ways against the real file. The `handle != oldValue` guard deleted → arm one
/// fired, alone. The field-by-field guard replaced by `guard percents != nil else { return }` → arm
/// two. `guard shown else { return }` deleted → arm three, alone. The two statements SWAPPED, both
/// pins still matching → only the ordering arm fired, which is the case the three text pins cannot
/// see and the reason it is written separately.
#[must_use]
pub fn the_divider_hides_before_it_cuts(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: DIVIDER,
            pattern: r"guard handle != oldValue else \{ return \}",
            view: View::Raw,
            message: "the divider re-runs handleUpdated for every seam in the tab on every solve — only the \
                      dragged one changed; SplitDividerHandle is Equatable, so guard on the value",
        },
        Claim::Matches {
            path: DIVIDER,
            pattern: r"percents\?\.leading != oldValue\?\.leading",
            view: View::Raw,
            message: "the divider re-cuts three instrument runs per drag frame to print the same two \
                      numbers — the tuple has no synthesized ==, so the guard is field-by-field or it is \
                      not there",
        },
        Claim::Matches {
            path: DIVIDER,
            pattern: r"guard shown else \{ return \}",
            view: View::Raw,
            message: "the divider sets the readout's text before deciding whether it is on screen — three \
                      uncached CoreText font builds per hidden seam per frame",
        },
        Claim::Before {
            path: DIVIDER,
            first: r"readout\.isHidden = !shown",
            second: r"readout\.percents = percents",
            view: View::Raw,
            message: "the divider cuts the readout's text before hiding it — the hidden seams pay the fonts",
        },
    ])
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The header holding its ladder, building it once, and killing it with its segments.
    fn header(fixture: &Fixture) {
        fixture.write(
            super::HEADER,
            "private var ladder: Ladder?\nprivate func measured() -> Ladder? { ladder }\nvar segments: \
             [Segment] = [] { didSet { ladder = nil } }\n",
        );
    }

    #[test]
    fn a_git_line_that_re_measures_is_red() {
        let fixture = Fixture::new("macui-ladder");
        header(&fixture);
        assert!(super::the_git_line_stays_measured(&fixture.tree()).is_clean());

        // The memo with no kill: a ladder that outlives the segments it measured serves the OLD
        // branch name forever, which is the wrong drawing rather than the slow one.
        fixture.write(
            super::HEADER,
            "private var ladder: Ladder?\nprivate func measured() -> Ladder? { ladder }\nvar segments: \
             [Segment] = []\n",
        );
        assert!(!super::the_git_line_stays_measured(&fixture.tree()).is_clean());

        // And the build inlined back into its two callers.
        fixture.write(
            super::HEADER,
            "private var ladder: Ladder?\nvar segments: [Segment] = [] { didSet { ladder = nil } }\n",
        );
        assert!(!super::the_git_line_stays_measured(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_corpus_derived_twice_per_draw_is_red() {
        let fixture = Fixture::new("macui-openq");
        fixture.write(
            super::OPEN_QUICKLY,
            "/// Replaces the `selectableRows(filter:)` that threw the sections away.\nprivate var \
             selectableRows: [OpenQuicklyItem] = []\n",
        );
        assert!(super::open_quickly_builds_its_corpus_once(&fixture.tree()).is_clean());

        // The prose above the property NAMES the method it replaced, so the ban reads code: a gate
        // that fires on its own rationale is a gate nobody can satisfy.
        fixture.write(
            super::OPEN_QUICKLY,
            "private func selectableRows(filter: String) -> [OpenQuicklyItem] { [] }\n",
        );
        assert!(!super::open_quickly_builds_its_corpus_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_unpruned_leaf_cache_is_red() {
        let fixture = Fixture::new("macui-canvas");
        fixture.write(
            super::CANVAS,
            "var handleIsUnthemed: [PaneID: Bool] = [:]\nhandleIsUnthemed[id] = nil\n",
        );
        assert!(super::the_canvas_remembers_unthemed_leaves(&fixture.tree()).is_clean());

        // The cache without its kill answers for a pane that closed, against a reused id.
        fixture.write(super::CANVAS, "var handleIsUnthemed: [PaneID: Bool] = [:]\n");
        assert!(!super::the_canvas_remembers_unthemed_leaves(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_dfs_inside_a_drag_update_is_red() {
        let fixture = Fixture::new("macui-leaf");
        fixture.write(super::GUI_LEAF, "private var cachedPaneKind: PaneKind?\n");
        assert!(super::the_gui_leaf_remembers_its_kind(&fixture.tree()).is_clean());

        fixture.write(
            super::GUI_LEAF,
            "var isDesktopUploadTarget: Bool { store.tree.spec(for: id)?.kind == .desktop }\n",
        );
        assert!(!super::the_gui_leaf_remembers_its_kind(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_array_built_to_test_membership_is_red() {
        let fixture = Fixture::new("macui-container");
        fixture.write(
            super::CONTAINER,
            "/// Not `allPaneIDs().contains(paneID)`, which ALLOCATES.\nlet tab = tabs.first { \
             $0.contains(paneID) }\n",
        );
        assert!(super::the_container_counts_without_arrays(&fixture.tree()).is_clean());

        fixture.write(
            super::CONTAINER,
            "let tab = tabs.first { $0.allPaneIDs().contains(paneID) }\n",
        );
        assert!(!super::the_container_counts_without_arrays(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_chord_list_rebuilt_per_keystroke_is_red() {
        let fixture = Fixture::new("macui-dispatch");
        fixture.write(
            super::DISPATCH,
            "private static let terminalReach: Set<KeyChord> = [.a, .b]\n",
        );
        assert!(super::the_terminal_reach_is_a_set(&fixture.tree()).is_clean());

        fixture.write(
            super::DISPATCH,
            "private static let terminalReach: [KeyChord] = [.a, .b]\n",
        );
        assert!(!super::the_terminal_reach_is_a_set(&fixture.tree()).is_clean());
    }

    #[test]
    fn an_unguarded_glyph_name_is_red() {
        let fixture = Fixture::new("macui-plate");
        fixture.write(
            super::PLATE,
            "var symbolName: String = \"\" { didSet { guard symbolName != oldValue else { return \
             }\napplyGlyph() } }\n",
        );
        assert!(super::the_plate_guards_its_glyph_name(&fixture.tree()).is_clean());

        fixture.write(
            super::PLATE,
            "var symbolName: String = \"\" { didSet { applyGlyph() } }\n",
        );
        assert!(!super::the_plate_guards_its_glyph_name(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_bezier_path_per_dot_per_frame_is_red() {
        let fixture = Fixture::new("macui-spinner");
        for spinner in super::SPINNERS {
            fixture.write(
                spinner,
                "// `fillEllipse` rather than `NSBezierPath(ovalIn:).fill()` — see the \
                 measurement.\ncontext.fillEllipse(in: frame)\n",
            );
        }
        assert!(super::both_spinners_fill_through_coregraphics(&fixture.tree()).is_clean());

        fixture.write(super::SPINNERS[1], "NSBezierPath(ovalIn: frame).fill()\n");
        assert!(!super::both_spinners_fill_through_coregraphics(&fixture.tree()).is_clean());
    }

    /// The divider guarding both assignments and hiding before it cuts.
    fn divider(fixture: &Fixture) {
        fixture.write(
            super::DIVIDER,
            "var handle: SplitDividerHandle? { didSet { guard handle != oldValue else { return \
             }\nhandleUpdated() } }\nfunc applyReadout() {\nreadout.isHidden = !shown\nguard shown else { \
             return }\nreadout.percents = percents\n}\nvar percents: Percents? { didSet { guard \
             percents?.leading != oldValue?.leading else { return } } }\n",
        );
    }

    #[test]
    fn a_readout_cut_before_it_is_hidden_is_red() {
        let fixture = Fixture::new("macui-divider");
        divider(&fixture);
        assert!(super::the_divider_hides_before_it_cuts(&fixture.tree()).is_clean());

        // The case the three text pins cannot see: both statements still spelled, in the order that
        // makes every hidden seam pay three CoreText builds.
        fixture.write(
            super::DIVIDER,
            "var handle: SplitDividerHandle? { didSet { guard handle != oldValue else { return \
             }\nhandleUpdated() } }\nfunc applyReadout() {\nreadout.percents = percents\nreadout.isHidden = \
             !shown\nguard shown else { return }\n}\nvar percents: Percents? { didSet { guard \
             percents?.leading != oldValue?.leading else { return } } }\n",
        );
        assert!(!super::the_divider_hides_before_it_cuts(&fixture.tree()).is_clean());

        // And the field-by-field guard collapsed to one a labelled tuple cannot answer.
        divider(&fixture);
        fixture.write(
            super::DIVIDER,
            "var handle: SplitDividerHandle? { didSet { guard handle != oldValue else { return \
             }\nhandleUpdated() } }\nfunc applyReadout() {\nreadout.isHidden = !shown\nguard shown else { \
             return }\nreadout.percents = percents\n}\nvar percents: Percents? { didSet { guard percents != \
             nil else { return } } }\n",
        );
        assert!(!super::the_divider_hides_before_it_cuts(&fixture.tree()).is_clean());
    }
}
