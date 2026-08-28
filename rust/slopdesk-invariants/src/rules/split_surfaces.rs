//! The five surfaces the macOS/iOS split draws TWICE — the drop zone, the cheat sheet, the
//! notification card, the palette, and the bespoke settings pages.
//!
//! Ported from the deleted `check-supervisor.sh`. `docs/56` stage D gave each of these two
//! renderers on purpose: an `NSPanel` sized to a Mac window and a native card sized to a phone.
//! What none of them may own is what the surface SAYS — the rows, the headline, the proportions,
//! the option lists. A half that spells its own does not fail either half's tests, because each
//! stays internally consistent; it fails the person who reads one label on the Mac and a different
//! one on the phone.
//!
//! The gate is therefore always the same two-sided shape: the shared content type must keep asking
//! its Rust door, and each renderer must keep reading the shared content type. A third claim recurs
//! where a half could plausibly reach PAST the shared type to the source it was built from — the
//! registry, the `(source, flavour)` pair, the ranked-row index — because that reach is a second
//! implementation that still compiles.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The drop overlay draws and hit-tests ONE shape
///
/// The overlay DRAWS the five blobs and the receiver HIT-TESTS against them. A second copy of the
/// proportions anywhere lets the hit region slide off the blob, and the drop lands in a zone the
/// user was not pointing at — silently, because both halves still look right on screen. So
/// `PaneDropZoneLayout` may only forward, and the fractions live once in
/// `slopdesk_workspace::drop_zone`.
///
/// The same reach holds for what the blobs SAY and how they are inked. The five labels, the label's
/// inset for the two clipped edge ellipses, the terminal-half / pane-half partition and the
/// three-way wash branch are each small enough that a second renderer re-derives them slightly
/// differently — a Mac's "Open In-Place" against a phone's "Open in place", an edge label that
/// drifts off-pane — and none of it is red on screen. `DropZonePresentation` may only forward.
#[must_use]
pub fn the_drop_overlay_draws_one_shape(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Drop/PaneDropZoneLayout.swift",
            names: &["slopdesk_drop_zone_shape", "slopdesk_drop_zone_at"],
            message: "PaneDropZoneLayout stopped calling {entry} — a drop lands where it is not drawn",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
            names: &[
                "slopdesk_drop_zone_label",
                "slopdesk_drop_zone_marks",
                "slopdesk_drop_zone_wash",
            ],
            message: "DropZonePresentation stopped calling {entry} — the two renderers would word or ink \
                      the same blob differently",
        },
        // ⚠️ THE FLOOR BEFORE THE BAN. `3f11c6e6` emptied `Sources/SlopDeskPhoneUI/Pane` entirely
        // and the ban below did not go red — a `NoneUnder` over a directory with no files in it
        // passes while checking nothing. 6 against a live 16 is a tripwire against an empty tree,
        // not a ratchet on the rebuild (docs/62 stage E.0).
        Claim::Populated {
            roots: &["Sources/SlopDeskPhoneUI/Pane"],
            extensions: &["swift"],
            minimum: 6,
            message: "only {found} Swift files under Sources/SlopDeskPhoneUI/Pane — the drop-zone \
                      proportion ban below reads an empty tree and passes (docs/56 stage D)",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI/Pane"],
            extensions: &["swift"],
            pattern: r"0\.46|0\.72|0\.26",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a drop-zone proportion grew back in the overlay ({files}) — \
                      rust/slopdesk-workspace/src/drop_zone.rs owns them",
        },
    ];
    check_all(tree, &claims)
}

/// One cheat sheet, two layouts
///
/// `docs/56` stage D's first surface: the Mac's ⌘/ sheet is an `NSPanel` and the phone's is a
/// native `.sheet`, and neither is allowed to know the other exists. What they may not do is each
/// spell out the table — so the rows, the glyph gating and the column deal are `CheatSheetContent`,
/// over `slopdesk_cheat_sheet_columns`. Two ways this decays, and the gate catches both: a half
/// that stops reading the shared source (a second table, drifting from the dispatcher's chords),
/// and the shared `SwiftUI` host mounting the card again (the Mac would then show it twice, over
/// its own panel).
#[must_use]
pub fn one_cheat_sheet_two_layouts(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift",
            needle: "slopdesk_cheat_sheet_columns",
            message: "CheatSheetContent stopped calling slopdesk_cheat_sheet_columns — the column deal has \
                      two answers",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift",
            names: &["CheatSheetContent"],
            message: "MacCheatSheetPanel.swift stopped rendering {entry} — the cheat sheet has two tables",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Shell/KeyboardCheatSheetViewController.swift",
            names: &["CheatSheetContent"],
            message: "KeyboardCheatSheetViewController.swift stopped rendering {entry} — the cheat sheet \
                      has two tables",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift",
                "Sources/SlopDeskPhoneUI/Shell/KeyboardCheatSheetViewController.swift",
            ],
            pattern: "WorkspaceBindingRegistry",
            view: View::Code,
            message: "{files} reached past CheatSheetContent to the registry — the glyph gating lives in \
                      ONE place",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
            pattern: "KeyboardCheatSheetView",
            view: View::Code,
            message: "the shared overlay host mounts the cheat sheet again — the Mac would draw it over its \
                      own panel",
        },
    ];
    check_all(tree, &claims)
}

/// One notification card, two corners
///
/// `docs/56` stage D's second surface, and the one that took the last ALWAYS-MOUNTED `SwiftUI`
/// layer off the macOS window root. The Mac's corner is an `NSPanel` sized to the column, the
/// phone's is an overlay on its own root, and what a card SAYS belongs to neither: the headline
/// (over `slopdesk_ws_notify_toast_headline`), the spine budget, the mark's rung/glyph and the
/// dwell are `ToastPresentation`.
///
/// The third claim is the fusion bug `TabBadgeResolver` had, pinned before it can happen twice: a
/// half that re-derives the phrase from the pair keys on flavour alone sooner or later, and
/// announces a finished `just` as an agent turn.
///
/// ## ⚠️ THE LAST CLAUSE PINS A `SwiftUI` SPELLING, AND ONLY THE PATH WAS RE-AIMED
///
/// The mount ban reads `PhoneOverlayLayerView.swift`, which is live `UIKit`, but `ToastStackView\(`
/// is a `SwiftUI` initializer call — a view controller mounts a child with `addChild` and
/// `addSubview`, and that needle cannot see it. So the ban is permanently green until stage F
/// re-spells it, and it is recorded here rather than re-spelled from this seat because the toast
/// column itself has not landed: the phone rows above are WRITTEN AHEAD (`docs/62` §4.8) and red
/// today for that reason, which is the honest state. The law — no always-mounted toast column on
/// the shared host — is unchanged.
#[must_use]
pub fn one_notification_card_two_corners(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Overlays/ToastPresentation.swift",
            needle: "slopdesk_ws_notify_toast_headline",
            message: "ToastPresentation stopped calling slopdesk_ws_notify_toast_headline — the headline \
                      has two answers",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Overlays/MacToastStack.swift",
            names: &["ToastPresentation"],
            message: "MacToastStack.swift stopped reading {entry} — a notification says two different things",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Overlays/PhoneToastStackView.swift",
            names: &["ToastPresentation"],
            message: "ToastStackView.swift stopped reading {entry} — a notification says two different \
                      things",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacToastStack.swift",
                "Sources/SlopDeskPhoneUI/Overlays/PhoneToastStackView.swift",
            ],
            pattern: "toast.source, toast.flavor",
            view: View::Code,
            message: "{files} re-derives the headline from (source, flavour) — that pair is resolved ONCE, \
                      in Rust",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
            pattern: r"ToastStackView\(",
            view: View::Code,
            message: "the shared overlay host mounts the toast column again — that mount claims every hit \
                      over the split",
        },
    ];
    check_all(tree, &claims)
}

/// One palette, two frameworks
///
/// `docs/56` stage D's first MODAL surface: the Mac's ⌘⇧P is an `NSPanel` and the phone's is a
/// paper card, and what a palette IS belongs to neither. `PalettePresentation`/`PaletteMetrics`
/// carry the card's measurements, the pairing of ranked rows with the keyboard's index, the ✓
/// predicate and the WORKING DIRECTORY badge — the last over `slopdesk_ws_cwd_badge_path`, so a
/// home is collapsed by ONE rule and never against the client's own `$HOME` (the path came off the
/// remote host).
///
/// The pairing is the one every half gets one off by hand: a separator takes a LINE but not a
/// selection, so a view that counted rows itself would highlight the wrong one under any header.
///
/// The shell also carried a fourth claim, that `MacWorkspaceRootView` drop the palette from the
/// shared host's `draws:` set. It is not ported: the Mac root no longer mounts the shared host at
/// all, so `draws:` exists nowhere in the tree and the `grep -A4` had been matching nothing. A
/// claim whose subject is gone reads as a rule being kept; it was passing because there was nothing
/// to check.
#[must_use]
pub fn one_palette_two_frameworks(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift",
            needle: "slopdesk_ws_cwd_badge_path",
            message: "PaneSpec stopped calling slopdesk_ws_cwd_badge_path — the badge's home collapse has \
                      two answers",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Overlays/MacPalette.swift",
            names: &["PalettePresentation"],
            message: "MacPalette.swift stopped reading {entry} — the two palettes would drift on the first \
                      section header",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Overlays/PhonePaletteCardView.swift",
            names: &["PalettePresentation"],
            message: "PaletteView.swift stopped reading {entry} — the two palettes would drift on the first \
                      section header",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacPalette.swift",
                "Sources/SlopDeskPhoneUI/Overlays/PhonePaletteCardView.swift",
            ],
            pattern: r"isSeparator \? nil",
            view: View::Code,
            message: "{files} re-pairs the ranked rows with the keyboard's index — that pairing is spelled \
                      ONCE",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn drop_overlay(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Drop/PaneDropZoneLayout.swift",
                "slopdesk_drop_zone_shape\nslopdesk_drop_zone_at\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
                "slopdesk_drop_zone_label\nslopdesk_drop_zone_marks\nslopdesk_drop_zone_wash\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
                "kept so the ban has a haystack\n",
            );
        // Enough of a pane target to clear the vacuity floor, so the assertions below read the ban
        // rather than the floor.
        for index in 0..6 {
            fixture.write(
                &format!("Sources/SlopDeskPhoneUI/Pane/Filler{index}.swift"),
                "final class Filler: UIView {}\n",
            );
        }
    }

    /// A drained pane target fails the proportion ban rather than satisfying it.
    ///
    /// The break-test for `3f11c6e6`: with no files under the root, `NoneUnder` finds no offender
    /// and reports clean while checking nothing at all.
    #[test]
    fn a_drained_pane_target_fails_the_proportion_ban() {
        let fixture = Fixture::new("split-surfaces-drop-drained");
        drop_overlay(&fixture);
        assert!(super::the_drop_overlay_draws_one_shape(&fixture.tree()).is_clean());

        for index in 0..6 {
            fixture.remove(&format!("Sources/SlopDeskPhoneUI/Pane/Filler{index}.swift"));
        }
        fixture.remove("Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift");
        let report = super::the_drop_overlay_draws_one_shape(&fixture.tree());
        assert!(!report.is_clean());
        assert!(
            report
                .violations()
                .iter()
                .any(|violation| violation.contains("reads an empty tree and passes"))
        );
    }

    #[test]
    fn the_drop_overlay_holds_its_face_to_the_shape() {
        let fixture = Fixture::new("split-surfaces-drop-overlay");
        drop_overlay(&fixture);
        assert!(super::the_drop_overlay_draws_one_shape(&fixture.tree()).is_clean());

        // The forwarder stopped forwarding — the hit test grew a shape of its own.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Drop/PaneDropZoneLayout.swift",
            "slopdesk_drop_zone_shape\n",
        );
        assert!(!super::the_drop_overlay_draws_one_shape(&fixture.tree()).is_clean());

        // The presentation stopped forwarding — one renderer's word drifts from the other's.
        drop_overlay(&fixture);
        fixture.write(
            "Sources/SlopDeskClientCore/Pane/DropZonePresentation.swift",
            "slopdesk_drop_zone_marks\nslopdesk_drop_zone_wash\n",
        );
        assert!(!super::the_drop_overlay_draws_one_shape(&fixture.tree()).is_clean());

        // And a proportion typed back into the overlay, where it drifts off the blob silently.
        drop_overlay(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlayView.swift",
            "let edge = 0.26\n",
        );
        assert!(!super::the_drop_overlay_draws_one_shape(&fixture.tree()).is_clean());
    }

    fn cheat_sheet(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift",
                "slopdesk_cheat_sheet_columns\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift",
                "CheatSheetContent\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Shell/KeyboardCheatSheetViewController.swift",
                "CheatSheetContent\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_cheat_sheet_holds_both_layouts_to_the_shared_table() {
        let fixture = Fixture::new("split-surfaces-cheat-sheet");
        cheat_sheet(&fixture);
        assert!(super::one_cheat_sheet_two_layouts(&fixture.tree()).is_clean());

        // A half that stops reading the shared source is a second table.
        fixture.write(
            "Sources/SlopDeskPhoneUI/Shell/KeyboardCheatSheetViewController.swift",
            "",
        );
        assert!(!super::one_cheat_sheet_two_layouts(&fixture.tree()).is_clean());

        // A half reaching PAST the shared type to the registry is the glyph gating, twice.
        cheat_sheet(&fixture);
        fixture.append(
            "Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift",
            "WorkspaceBindingRegistry.all\n",
        );
        assert!(!super::one_cheat_sheet_two_layouts(&fixture.tree()).is_clean());

        // And the shared host mounting the card again, which the Mac would draw over its panel.
        cheat_sheet(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
            "KeyboardCheatSheetView()\n",
        );
        assert!(!super::one_cheat_sheet_two_layouts(&fixture.tree()).is_clean());
    }

    fn toast(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskClientCore/Overlays/ToastPresentation.swift",
                "slopdesk_ws_notify_toast_headline\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacToastStack.swift",
                "ToastPresentation\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Overlays/PhoneToastStackView.swift",
                "ToastPresentation\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_notification_card_holds_both_corners_to_one_headline() {
        let fixture = Fixture::new("split-surfaces-toast");
        toast(&fixture);
        assert!(super::one_notification_card_two_corners(&fixture.tree()).is_clean());

        // The shared type stopped asking its door — the headline has two answers again.
        fixture.write("Sources/SlopDeskClientCore/Overlays/ToastPresentation.swift", "");
        assert!(!super::one_notification_card_two_corners(&fixture.tree()).is_clean());

        // The fusion bug: a half re-deriving the phrase from the pair keys.
        toast(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Overlays/PhoneToastStackView.swift",
            "switch (toast.source, toast.flavor) {\n",
        );
        assert!(!super::one_notification_card_two_corners(&fixture.tree()).is_clean());

        // And the shared host mounting the column, which claims every hit over the split.
        toast(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Shell/PhoneOverlayLayerView.swift",
            "ToastStackView(store: store)\n",
        );
        assert!(!super::one_notification_card_two_corners(&fixture.tree()).is_clean());
    }

    fn palette(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift",
                "slopdesk_ws_cwd_badge_path\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacPalette.swift",
                "PalettePresentation\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Overlays/PhonePaletteCardView.swift",
                "PalettePresentation\n",
            );
    }

    #[test]
    fn one_palette_holds_both_frameworks_to_one_pairing() {
        let fixture = Fixture::new("split-surfaces-palette");
        palette(&fixture);
        assert!(super::one_palette_two_frameworks(&fixture.tree()).is_clean());

        // A half that stops reading the shared measurements drifts on the first section header.
        fixture.write("Sources/SlopDeskMacUI/Overlays/MacPalette.swift", "");
        assert!(!super::one_palette_two_frameworks(&fixture.tree()).is_clean());

        // The off-by-one every half gets by hand: a separator takes a line but not a selection.
        palette(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Overlays/PhonePaletteCardView.swift",
            "let index = row.isSeparator ? nil : counter\n",
        );
        assert!(!super::one_palette_two_frameworks(&fixture.tree()).is_clean());
    }
}
