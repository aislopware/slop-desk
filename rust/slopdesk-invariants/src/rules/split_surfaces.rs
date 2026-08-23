//! The five surfaces the macOS/iOS split draws TWICE — the drop zone, the cheat sheet, the
//! notification card, the palette, and the bespoke settings pages.
//!
//! Ported from `scripts/check-supervisor.sh`. `docs/56` stage D gave each of these two renderers on
//! purpose: an `NSPanel` sized to a Mac window and a native card sized to a phone. What none of
//! them may own is what the surface SAYS — the rows, the headline, the proportions, the option
//! lists. A half that spells its own does not fail either half's tests, because each stays
//! internally consistent; it fails the person who reads one label on the Mac and a different one on
//! the phone.
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
#[must_use]
pub fn the_drop_overlay_draws_one_shape(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/Drop/PaneDropZoneLayout.swift",
            names: &["slopdesk_drop_zone_shape", "slopdesk_drop_zone_at"],
            message: "PaneDropZoneLayout stopped calling {entry} — a drop lands where it is not drawn",
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
            path: "Sources/SlopDeskPhoneUI/Overlays/KeyboardCheatSheetView.swift",
            names: &["CheatSheetContent"],
            message: "KeyboardCheatSheetView.swift stopped rendering {entry} — the cheat sheet has two \
                      tables",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacCheatSheetPanel.swift",
                "Sources/SlopDeskPhoneUI/Overlays/KeyboardCheatSheetView.swift",
            ],
            pattern: "WorkspaceBindingRegistry",
            view: View::Code,
            message: "{files} reached past CheatSheetContent to the registry — the glyph gating lives in \
                      ONE place",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
/// announces a finished `make` as an agent turn.
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
            path: "Sources/SlopDeskPhoneUI/Overlays/ToastStackView.swift",
            names: &["ToastPresentation"],
            message: "ToastStackView.swift stopped reading {entry} — a notification says two different \
                      things",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacToastStack.swift",
                "Sources/SlopDeskPhoneUI/Overlays/ToastStackView.swift",
            ],
            pattern: "toast.source, toast.flavor",
            view: View::Code,
            message: "{files} re-derives the headline from (source, flavour) — that pair is resolved ONCE, \
                      in Rust",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
            path: "Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift",
            names: &["PalettePresentation"],
            message: "PaletteView.swift stopped reading {entry} — the two palettes would drift on the first \
                      section header",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskMacUI/Overlays/MacPalette.swift",
                "Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift",
            ],
            pattern: r"isSeparator \? nil",
            view: View::Code,
            message: "{files} re-pairs the ranked rows with the keyboard's index — that pairing is spelled \
                      ONCE",
        },
    ];
    check_all(tree, &claims)
}

/// One bespoke settings surface, drawn twice and spelled once
///
/// `Control.bespoke(id)` is the layout table admitting a group is not a list of settings, so those
/// groups carry the settings words that the table cannot: an empty page stating its own emptiness,
/// a card writing `~/.claude/settings.json`, a caret preview, a font specimen, the searchable
/// index. They had ONE renderer until increment 49, which is how every word in them came to have a
/// single speller BY ACCIDENT. There are two now, and the accident does not survive a second
/// drawing.
///
/// The index's option lists are the CATALOG's. Thirteen were typed at the `SwiftUI` control as
/// `Text(…).tag(…)` before increment 49 and FOUR had drifted — "Context Menu" against the catalog's
/// "Context menu", "Home" against "Home Directory". Naming the group is what makes a fourteenth
/// list impossible to type. The on-launch pair is the drift increment 49 found rather than
/// prevented: the checklist spelled "Restore Last Session" while Settings → General read
/// `ON_LAUNCH` and said "Restore session".
#[must_use]
pub fn one_bespoke_settings_surface(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Settings/SettingsBespokeSurfaces.swift",
            names: &["SettingsBespokePresentation"],
            message: "SettingsBespokeSurfaces.swift stopped reading {entry} — a bespoke surface deciding \
                      for itself is the second speller (docs/56, increment 49)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Settings/MacSettingsBespokeSurfaces.swift",
            names: &["SettingsBespokePresentation"],
            message: "MacSettingsBespokeSurfaces.swift stopped reading {entry} — a bespoke surface deciding \
                      for itself is the second speller (docs/56, increment 49)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Settings/AllSettingsListView.swift",
            names: &[
                "SettingsIndexPresentation",
                "SettingsIndexPresentation.optionGroup",
            ],
            message: "AllSettingsListView.swift stopped reading {entry} — an option list typed at a control \
                      is how four labels drifted (docs/56, increment 49)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift",
            names: &[
                "SettingsIndexPresentation",
                "SettingsIndexPresentation.optionGroup",
            ],
            message: "MacAllSettingsIndex.swift stopped reading {entry} — an option list typed at a control \
                      is how four labels drifted (docs/56, increment 49)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift",
            names: &["CursorColorHex"],
            message: "CursorPreviewView.swift stopped reading {entry} — a bespoke surface deciding for \
                      itself is the second speller (docs/56, increment 49)",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift",
            names: &["CursorColorHex"],
            message: "MacCursorPreviewSurface.swift stopped reading {entry} — a bespoke surface deciding \
                      for itself is the second speller (docs/56, increment 49)",
        },
        Claim::Names {
            path: "Sources/SlopDeskClientCore/FirstLaunch/FirstLaunchStepPresentation.swift",
            needle: "SettingsCatalog.label(.onLaunch",
            message: "OnLaunchBehavior.title stopped reading ON_LAUNCH — the checklist and Settings named \
                      one choice twice before",
        },
        // A second hex parser keeps passing both halves' tests while rounding a channel differently,
        // and the value it writes is a libghostty `cursor-color` string.
        Claim::NoneUnder {
            roots: &[
                "Sources/SlopDeskPhoneUI/Settings",
                "Sources/SlopDeskMacUI/Settings",
            ],
            extensions: &["swift"],
            pattern: "radix: 16",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a settings surface parses or prints hex itself ({files}) — CursorColorHex is the \
                      bridge (docs/56, increment 49)",
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
                "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlay.swift",
                "kept so the ban has a haystack\n",
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

        // And a proportion typed back into the overlay, where it drifts off the blob silently.
        drop_overlay(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Pane/PaneDropOverlay.swift",
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
                "Sources/SlopDeskPhoneUI/Overlays/KeyboardCheatSheetView.swift",
                "CheatSheetContent\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
            "Sources/SlopDeskPhoneUI/Overlays/KeyboardCheatSheetView.swift",
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
            "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
                "Sources/SlopDeskPhoneUI/Overlays/ToastStackView.swift",
                "ToastPresentation\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
            "Sources/SlopDeskPhoneUI/Overlays/ToastStackView.swift",
            "switch (toast.source, toast.flavor) {\n",
        );
        assert!(!super::one_notification_card_two_corners(&fixture.tree()).is_clean());

        // And the shared host mounting the column, which claims every hit over the split.
        toast(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Overlays/OverlayHostView.swift",
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
                "Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift",
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
            "Sources/SlopDeskPhoneUI/Overlays/PaletteView.swift",
            "let index = row.isSeparator ? nil : counter\n",
        );
        assert!(!super::one_palette_two_frameworks(&fixture.tree()).is_clean());
    }

    fn bespoke(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Settings/SettingsBespokeSurfaces.swift",
                "SettingsBespokePresentation\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Settings/MacSettingsBespokeSurfaces.swift",
                "SettingsBespokePresentation\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Settings/AllSettingsListView.swift",
                "SettingsIndexPresentation.optionGroup\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift",
                "SettingsIndexPresentation.optionGroup\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift",
                "CursorColorHex\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift",
                "CursorColorHex\n",
            )
            .write(
                "Sources/SlopDeskClientCore/FirstLaunch/FirstLaunchStepPresentation.swift",
                "SettingsCatalog.label(.onLaunch)\n",
            );
    }

    #[test]
    fn one_bespoke_surface_holds_both_renderers_to_the_catalog() {
        let fixture = Fixture::new("split-surfaces-bespoke");
        bespoke(&fixture);
        assert!(super::one_bespoke_settings_surface(&fixture.tree()).is_clean());

        // A renderer that stopped asking for the group is where the four labels drifted.
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/MacAllSettingsIndex.swift",
            "SettingsIndexPresentation\n",
        );
        assert!(!super::one_bespoke_settings_surface(&fixture.tree()).is_clean());

        // And a second hex parser, which rounds a channel differently and still passes both suites.
        bespoke(&fixture);
        fixture.append(
            "Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift",
            "UInt8(component, radix: 16)\n",
        );
        assert!(!super::one_bespoke_settings_surface(&fixture.tree()).is_clean());
    }
}
