//! `docs/56` stage D's three ALWAYS-MOUNTED surfaces: the navigator, the titlebar band and the
//! panel chrome.
//!
//! Ported from the deleted `check-supervisor.sh`. These are the columns whose halves could disagree
//! in the most ways, so everything two frameworks could argue about was lifted to
//! `SlopDeskClientCore` FIRST and what is left in either half is drawing and events. Each rule here
//! pairs a BAN (the shared `SwiftUI` original stays deleted, no sigil is respelt) with a READER —
//! because a ban alone cannot tell a half that PORTED a reading from one that DELETED it, and a
//! navigator that simply stopped drawing git passes every ban in the file while the parity rule the
//! whole split rests on quietly stops holding.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const MAC_HEADER: &str = "Sources/SlopDeskMacUI/Columns/MacSidebarHeader.swift";
const MAC_ROW: &str = "Sources/SlopDeskMacUI/Columns/MacSidebarRow.swift";
const PHONE_NAVIGATOR: &str = "Sources/SlopDeskPhoneUI/Columns/NavigatorColumn.swift";
const PHONE_PANEL: &str = "Sources/SlopDeskPhoneUI/Panel/PhonePanelSheet.swift";

/// One navigator, one row reading, one git dialect
///
/// The NAVIGATOR is the column stage D names as Mac-shaped, and the one whose halves could disagree
/// in the most ways: forty rows, each with a hover swap, a drop ring, a context menu, an inline
/// field and a mark that ticks at display rate. The row's whole appearance (`SidebarRowReading`),
/// the git dialect (`SidebarGitLine`), the sectioning (`SidebarSections`), the menu's verb table
/// (`SidebarRowMenu`) and the select path (`SidebarSelection`) all went to `SlopDeskClientCore`
/// first. This gate is what keeps that true.
///
/// `SlateTabRow.swift` must stay DELETED. It was the shared `SwiftUI` row both platforms drew; the
/// Mac's row is `MacSidebarRowView` and the phone's is `IOSSidebarLiveRow`, and a third would be
/// the cross-language mirror `CLAUDE.md`'s one-implementation rule bans.
///
/// THE PHONE IS ASSERTED THE SAME WAY, and it is not symmetry for its own sake: the sigil ban
/// cannot tell a half that ported the git line from one that deleted it. A navigator that simply
/// stopped drawing git passes every ban here — no second dialect, no respelt sigil, nothing to
/// catch — while "the phone differs in LAYOUT only" quietly stops holding.
#[must_use]
pub fn one_navigator_per_platform(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Chrome/SlateTabRow.swift",
            message: "SlateTabRow.swift is back — the navigator row is MacSidebarRowView (AppKit) or \
                      IOSSidebarLiveRow (phone)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(struct|final class) SlateTabRow\b",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "SlateTabRow is back under another path ({files}) — one row per platform, both reading \
                      SidebarRowReading",
        },
        // The SwiftUI navigator is the PHONE's now. Without the platform gate the Mac would build two.
        Claim::Names {
            path: PHONE_NAVIGATOR,
            needle: "#if os(iOS)",
            message: "NavigatorColumn stopped being iOS-only — the Mac's navigator is MacNavigatorColumn",
        },
        Claim::Mentions {
            path: PHONE_NAVIGATOR,
            names: &["SidebarRowPresentation", "SidebarRowMenu", "SidebarGitLine"],
            message: "the phone's navigator stopped reading {entry} — two rows, and the drift would be \
                      silent",
        },
        Claim::MentionsUnder {
            root: "Sources/SlopDeskMacUI/Columns",
            names: &["SidebarRowPresentation", "SidebarRowMenu", "SidebarSections"],
            message: "the Mac's navigator stopped reading {entry} — two rows, and the drift would be silent",
        },
        // The GIT DIALECT is cut once. A half that spells a sigil itself is a second dialect: the
        // sigils are a language a git prompt already taught the eye, and two spellings of it read as
        // two repos.
        Claim::Mentions {
            path: MAC_HEADER,
            names: &["SidebarGitLine"],
            message: "MacSidebarHeader stopped reading {entry} — the git dialect is ClientCore's, cut once",
        },
        // Comments stripped first — the headers NAME the sigils they no longer spell.
        Claim::NoneOf {
            paths: &[MAC_HEADER, MAC_ROW, PHONE_NAVIGATOR],
            pattern: r#""↑\\\(|"↓\\\(|"\+\\\(|"!\\\(|"\?\\\(|"~\\\(|"\$\\\("#,
            view: View::Code,
            message: "{files} spells a git sigil — every one of them is SidebarGitLine.segments's",
        },
        // THE MULTICLIENT LINES ARE CUT ONCE TOO — `SidebarRowReading.presence` mints "Also open on
        // <device>" and "Held by <device>", and nothing else may. This is the sentence a reader
        // trusts to know whether somebody else is typing into the pane they are about to take, so a
        // half that composes its own is not a wording drift: it is a second answer to a question with
        // one true answer, and the wrong one looks exactly as authoritative as the right one.
        Claim::NoneOf {
            paths: &[MAC_ROW, PHONE_NAVIGATOR],
            pattern: r#""Also open on|"Held by"#,
            view: View::Code,
            message: "{files} mints a multiclient line — \"Also open on\" and \"Held by\" are \
                      SidebarRowReading.presence's",
        },
        // The ATTENTION ROLES are ranked once (`TabBadgeReading.rollup`), because a collapsed group's
        // count has to pick a loudest hidden state and both halves must pick the same one.
        Claim::Mentions {
            path: "Sources/SlopDeskSlate/StatusPresentation.swift",
            names: &["TabBadgeReading"],
            message: "StatusPresentation stopped delegating to {entry} — the attention ranking is cut once",
        },
    ];
    check_all(tree, &claims)
}

/// One titlebar band, one connection reading
///
/// The window runs `.hiddenTitleBar`, so the BAND is the chrome — and being the chrome, it is
/// always mounted, which is the same recurring cost that moved the navigator. Both its halves
/// crossed: `MacTabStrip` for the tabs and `MacConnectionIsland` for the status.
///
/// The two `SwiftUI` originals must stay DELETED. `SlateTitlebar` was a full-bleed overlay that had
/// to be handed `allowsHitTesting` back a layer at a time to stop claiming the terminal's clicks —
/// the exact hazard an `NSView` sibling does not have — and `WorkspaceTabStrip` was the tab list it
/// carried. Neither has a phone mount to come back for: the phone has no titlebar at all.
///
/// What the two connection halves could disagree about is not the palette — it is which readings
/// may CLIMB at all (the link on its round trip, memory on the kernel's pressure verdict, disk on
/// an absolute byte floor; CPU never), and a second answer to that is an instrument that cries wolf
/// on one platform and stays silent on the other.
#[must_use]
pub fn one_titlebar_band_one_connection_reading(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Chrome/SlateTitlebar.swift",
            message: "SlateTitlebar.swift is back — the Mac's titlebar chrome is MacTitlebarBand + \
                      MacTabStrip (AppKit)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Chrome/WorkspaceTabStrip.swift",
            message: "WorkspaceTabStrip.swift is back — the Mac's titlebar chrome is MacTitlebarBand + \
                      MacTabStrip (AppKit)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(struct|final class) (SlateTitlebar|WorkspaceTabStrip|TabStripChip)\b",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a SwiftUI titlebar/tab-strip type is back ({files}) — the band is MacTitlebarBand, \
                      the strip MacTabStrip",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Chrome/MacConnectionIsland.swift",
            names: &["ConnectionReading"],
            message: "MacConnectionIsland stopped reading {entry} — the alarm ladder is ClientCore's, cut \
                      once",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Chrome/ConnectionPill.swift",
            names: &["ConnectionReading"],
            message: "ConnectionPill stopped reading {entry} — the alarm ladder is ClientCore's, cut once",
        },
        // The strip's chip is the navigator row's reading, NOT a second one. Its inputs are a strict
        // subset, and only one of the strip and the column is ever mounted, so there is nothing to buy
        // by cutting a `TabChipReading` and one more place for "what is this pane called" to drift.
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Chrome/MacTabStrip.swift",
            names: &["SidebarRowPresentation"],
            message: "MacTabStrip stopped reading {entry} — the chip is the row's reading, cut once",
        },
        // The band is a PASS-THROUGH: it spans the column so its ends can anchor to the window's, and
        // every click in its empty middle belongs to the terminal under it. Without the refusal it is
        // the full-bleed hit-claimer the port removed.
        Claim::Names {
            path: "Sources/SlopDeskMacUI/Chrome/MacTitlebarBand.swift",
            needle: "override func hitTest",
            message: "MacTitlebarBand stopped refusing hits — its empty centre is the terminal island's moat",
        },
    ];
    check_all(tree, &claims)
}

/// One panel chrome, one tab reading
///
/// The right panel's CHROME crossed whole: the strip over the surfaces, the rail the collapsed
/// panel leaves behind, and the four tabs both of them draw. The SURFACES stayed `SwiftUI` on
/// purpose (three of the four are already `AppKit` under a thin wrapper, and the phone will want
/// them on its own layout) — which is exactly why the chrome had to move: a strip that reloads a
/// surface must outlive the view that draws it.
///
/// The two `SwiftUI` originals must stay DELETED. `PanelRail` was the collapsed panel's stand-in
/// and `AndroidRobotMark` the one mark no icon set ships; the mark is a `CGPath` in `ClientCore`
/// now, so a `SwiftUI` copy would be a second drawing of the same head.
///
/// THE PHONE'S PANEL IS A LAYOUT, NOT A SECOND PANEL. Its bar is its own (a cover has no split item
/// to hide, so it closes instead), but everything under the bar is the Mac's: the same four
/// surfaces, the same shared `codeSidebarCollapsed` flag driving the presentation — which is what
/// makes `revealCodeSidebar()` reach the phone at all — and the same drawn robot.
#[must_use]
pub fn one_panel_chrome_one_tab_reading(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/Chrome/PanelRail.swift",
            message: "PanelRail.swift is back — the panel's chrome is MacPanelStrip + MacPanelRail (AppKit)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskPhoneUI/DesignSystem/AndroidRobotMark.swift",
            message: "AndroidRobotMark.swift is back — the panel's chrome is MacPanelStrip + MacPanelRail \
                      (AppKit)",
        },
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: SWIFT,
            pattern: r"(struct|final class) (PanelRail|PanelTabPlate|AndroidRobotMark)\b",
            all: &[],
            unless: &[],
            view: View::Raw,
            exempt: &[],
            message: "a SwiftUI panel-chrome type is back ({files}) — the tabs are MacPanelTabPlate, the \
                      mark AndroidMarkPath",
        },
        // The four TABS are one list, in ClientCore, because they were written twice — once across
        // the strip and once down the rail — and the two had to agree on the mark, the word AND the
        // help of every surface. The WIDTH LADDER lives with them as arithmetic rather than a
        // `ViewThatFits`, so a test can ask it what a width affords without mounting anything.
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Panel/MacPanelStrip.swift",
            names: &["PanelTabs"],
            message: "MacPanelStrip stopped reading {entry} — the panel's four tabs are ClientCore's, cut \
                      once",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Panel/MacPanelTabGroup.swift",
            names: &["PanelTabs"],
            message: "MacPanelTabGroup stopped reading {entry} — the panel's four tabs are ClientCore's, \
                      cut once",
        },
        Claim::Mentions {
            path: PHONE_PANEL,
            names: &["PanelTabs", "CodePanelSurfaces(", "AndroidMarkPath"],
            message: "PhonePanelSheet stopped reading {entry} — the phone's panel is a LAYOUT, not a second \
                      panel",
        },
        Claim::Names {
            path: "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift",
            needle: "codeSidebarCollapsed",
            message: "the phone's root stopped reading codeSidebarCollapsed — revealCodeSidebar() would not \
                      reach the phone at all",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift",
            names: &["AndroidMarkPath"],
            message: "MacPanelTabPlate stopped drawing {entry} — the head's proportions are cut once",
        },
        // NOTHING IN THE RAIL IS A TURNED VIEW. `frameCenterRotation` pivots a layer-backed view about
        // its layer's ANCHOR POINT — the frame's corner — which threw every rail tab out of the rail;
        // and a turned view's frame is still its unturned box, so its hit area would lie across both
        // neighbours. The tab stands in its footprint and turns its CONTENT. Comments stripped first —
        // the headers NAME the API they exist to warn about.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskMacUI/Panel"],
            extensions: SWIFT,
            pattern: "frameCenterRotation",
            all: &[],
            unless: &[],
            view: View::Code,
            // The two DEVICE panels turn a view on purpose and say so: a simulator bezel is a device
            // rotating, and its own header records why the turn is a CUT rather than an animation
            // (an `AVSampleBufferDisplayLayer` mid-turn cross-fades every arriving frame). The shell
            // never had to decide this — its `Panel/*.swift` glob did not descend — so the exemption
            // is the decision that glob was making silently.
            exempt: &[
                "Sources/SlopDeskMacUI/Panel/Simulator/",
                "Sources/SlopDeskMacUI/Panel/Android/",
            ],
            message: "a panel tab turns its VIEW again ({files}) — turn the content, or the rail's hit \
                      areas overlap",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn navigator(fixture: &Fixture) {
        fixture
            .write(
                super::PHONE_NAVIGATOR,
                "#if os(iOS)\nSidebarRowPresentation\nSidebarRowMenu\nSidebarGitLine\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Columns/MacNavigatorColumn.swift",
                "SidebarRowPresentation\nSidebarRowMenu\nSidebarSections\n",
            )
            .write(super::MAC_HEADER, "SidebarGitLine\n")
            .write(super::MAC_ROW, "MacSidebarRowView\n")
            .write(
                "Sources/SlopDeskSlate/StatusPresentation.swift",
                "TabBadgeReading\n",
            );
    }

    #[test]
    fn the_navigator_reads_one_row_and_one_git_dialect() {
        let fixture = Fixture::new("chrome-navigator");
        navigator(&fixture);
        assert!(super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // The shared row, back under any path.
        fixture.write("Sources/SlopDeskSlate/Row.swift", "struct SlateTabRow: View {}\n");
        assert!(!super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // A half that PORTED the git line and one that DELETED it look the same to the sigil ban —
        // which is why the reader is asserted beside it.
        navigator(&fixture);
        fixture.write(
            super::PHONE_NAVIGATOR,
            "#if os(iOS)\nSidebarRowPresentation\nSidebarRowMenu\n",
        );
        assert!(!super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // A sigil respelt in a half.
        navigator(&fixture);
        fixture.append(super::MAC_ROW, "Text(\"↑\\(ahead)\")\n");
        assert!(!super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // And a multiclient line minted outside the presence reading.
        navigator(&fixture);
        fixture.append(super::MAC_ROW, "Text(\"Held by \\(device)\")\n");
        assert!(!super::one_navigator_per_platform(&fixture.tree()).is_clean());
    }

    fn titlebar(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskMacUI/Chrome/MacConnectionIsland.swift",
                "ConnectionReading\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Chrome/ConnectionPill.swift",
                "ConnectionReading\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Chrome/MacTabStrip.swift",
                "SidebarRowPresentation\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Chrome/MacTitlebarBand.swift",
                "override func hitTest(_ point: NSPoint) -> NSView? { nil }\n",
            );
    }

    #[test]
    fn the_band_refuses_hits_and_both_halves_read_one_ladder() {
        let fixture = Fixture::new("chrome-titlebar");
        titlebar(&fixture);
        assert!(super::one_titlebar_band_one_connection_reading(&fixture.tree()).is_clean());

        // The band that stopped being a moat.
        fixture.write(
            "Sources/SlopDeskMacUI/Chrome/MacTitlebarBand.swift",
            "final class Band {}\n",
        );
        assert!(!super::one_titlebar_band_one_connection_reading(&fixture.tree()).is_clean());

        // The deleted SwiftUI strip, back.
        titlebar(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Chrome/SlateTitlebar.swift",
            "struct SlateTitlebar {}\n",
        );
        assert!(!super::one_titlebar_band_one_connection_reading(&fixture.tree()).is_clean());

        // And a half that stopped reading the alarm ladder.
        titlebar(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Chrome/ConnectionPill.swift",
            "Text(\"link\")\n",
        );
        assert!(!super::one_titlebar_band_one_connection_reading(&fixture.tree()).is_clean());
    }

    fn panel(fixture: &Fixture) {
        fixture
            .write("Sources/SlopDeskMacUI/Panel/MacPanelStrip.swift", "PanelTabs\n")
            .write(
                "Sources/SlopDeskMacUI/Panel/MacPanelTabGroup.swift",
                "PanelTabs\n",
            )
            .write(
                super::PHONE_PANEL,
                "PanelTabs\nCodePanelSurfaces(store: store)\nAndroidMarkPath\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/WorkspaceRootView.swift",
                "codeSidebarCollapsed\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift",
                "AndroidMarkPath\n",
            );
    }

    #[test]
    fn the_panel_chrome_reads_one_tab_list_and_turns_no_view() {
        let fixture = Fixture::new("chrome-panel");
        panel(&fixture);
        assert!(super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());

        // A turned VIEW — the failure the rail's headers warn about.
        fixture.append(
            "Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift",
            "layer?.frameCenterRotation = 90\n",
        );
        assert!(!super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());

        // The header may still NAME it.
        panel(&fixture);
        fixture.append(
            "Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift",
            "// never frameCenterRotation — see the rule\n",
        );
        assert!(super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());

        // And the phone's panel becoming a second panel.
        panel(&fixture);
        fixture.write(super::PHONE_PANEL, "PanelTabs\nAndroidMarkPath\n");
        assert!(!super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());
    }
}
