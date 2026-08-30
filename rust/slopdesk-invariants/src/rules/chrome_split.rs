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
/// RE-AIMED 2026-08-28 at the `UIKit` twins `3f11c6e6` demolished and docs/62 stage D rebuilt:
/// `Columns/NavigatorColumn.swift` → `Shell/NavigatorColumnViewController.swift`,
/// `Panel/PhonePanelSheet.swift` → `Shell/PhonePanelViewController.swift`.
///
/// ⚠️ AND THE `CodePanelSurfaces` NEEDLE IS GONE ENTIRELY, which is the end of a two-step lesson
/// worth keeping whole. It began as `CodePanelSurfaces(` — with the paren, pinning a `SwiftUI`
/// CONSTRUCTOR CALL, so it was green only while the type kept both its name and its initialiser.
/// The 2026-08-28 pass dropped the paren, on the sound reasoning that the law is what the panel
/// READS and not how it spells the read. But the type had already died with its framework, and what
/// the bare needle then matched was the SUBSTRING inside `MacCodePanelSurfaces` — a class name.
/// Each step was right about the step before it and both missed that the subject no longer existed.
/// What the two panels genuinely share is `CodePanelPresentation`, pinned at its call sites below.
const PHONE_NAVIGATOR: &str = "Sources/SlopDeskPhoneUI/Shell/NavigatorColumnViewController.swift";

/// Every `(file, pattern, message)` that is a READING of the panel's shared vocabulary — one row
/// per file per symbol, on both shells, symmetrically.
///
/// ⚠️ THE PARK IS PAID HERE. A predecessor left the phone's half of this red on purpose in
/// 2026-08-28 rather than re-aim it, because its subject had been SPLIT rather than renamed — the
/// controller stopped reading these symbols not by regressing but by handing each surface to a
/// sibling — and deciding which file must read which symbol is the panel's architecture, not a
/// gate's. The architecture is now settled: a file that DRAWS a tab reads the shared list, a file
/// that draws the ANDROID mark reads the shared path, and each shell's workbench reads the shared
/// clipped-titlebar metric. Which is also why the Mac gained rows it never had.
///
/// `Matches`/`Code` throughout, never `Mentions`: the latter reads RAW, so the sentence you are
/// reading would have satisfied every row below had it been written in the file it guards. This
/// family has already shipped one rule a comment could turn green; it will not ship a second.
const PANEL_READERS: &[(&str, &str, &str)] = &[
    (
        "Sources/SlopDeskMacUI/Panel/MacPanelStrip.swift",
        r"\bPanelTabs\b",
        "MacPanelStrip stopped reading PanelTabs — the panel's four tabs are ClientCore's, cut once",
    ),
    (
        "Sources/SlopDeskMacUI/Panel/MacPanelTabGroup.swift",
        r"\bPanelTabs\b",
        "MacPanelTabGroup stopped reading PanelTabs — the panel's four tabs are ClientCore's, cut once",
    ),
    (
        "Sources/SlopDeskPhoneUI/Panel/PhonePanelBar.swift",
        r"\bPanelTabs\b",
        "PhonePanelBar stopped reading PanelTabs — the phone's panel is a LAYOUT of the same four tabs, not \
         a second panel",
    ),
    (
        "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabGroup.swift",
        r"\bPanelTabs\b",
        "PhonePanelTabGroup stopped reading PanelTabs — the phone's panel is a LAYOUT of the same four \
         tabs, not a second panel",
    ),
    (
        "Sources/SlopDeskMacUI/Panel/MacPanelTabPlate.swift",
        r"\bAndroidMarkPath\b",
        "MacPanelTabPlate stopped reading AndroidMarkPath — the robot is ONE path, or the two shells draw \
         two robots",
    ),
    (
        "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabPlate.swift",
        r"\bAndroidMarkPath\b",
        "PhonePanelTabPlate stopped reading AndroidMarkPath — the robot is ONE path, or the two shells draw \
         two robots",
    ),
    // ⚠️ AND NOT `CodePanelSurfaces` — see this module's header for why that needle was pinning a
    // class NAME rather than a reading. What the two panels genuinely share is the clipped-titlebar
    // metric, and the pin goes where it is CALLED rather than where a header names it.
    (
        "Sources/SlopDeskMacUI/Panel/MacCodeWorkbenchView.swift",
        r"CodePanelPresentation\.",
        "MacCodeWorkbenchView stopped reading CodePanelPresentation — how far the web view is lifted to \
         clip its title bar is one number, not one per shell",
    ),
    (
        "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
        r"CodePanelPresentation\.",
        "PhoneCodeWorkbenchView stopped reading CodePanelPresentation — how far the web view is lifted to \
         clip its title bar is one number, not one per shell",
    ),
];

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
        // The UIKit navigator is the PHONE's. Without the platform gate the Mac would build two.
        // (It read "the SwiftUI navigator" until the demolition; the claim below never depended on
        // which framework painted it, only on there being exactly one navigator per platform.)
        Claim::Names {
            path: PHONE_NAVIGATOR,
            needle: "#if os(iOS)",
            message: "NavigatorColumnViewController stopped being iOS-only — the Mac's navigator is \
                      MacNavigatorColumn",
        },
        // ⚠️ A DIRECTORY, NOT A FILE, AS OF 2026-08-28, and the Mac's claim below has read one for
        // longer. This was `Mentions` on the controller alone, from when the phone's navigator WAS
        // one SwiftUI file. docs/62 stage D split it into four — the controller in `Shell/`, plus
        // `NavigatorRowCell`, `NavigatorSectionHeaderCell` and `SidebarGitLineView` in `Columns/` —
        // and two of the three names went with the cells. The claim stayed green only because the
        // agent that split it listed all five ClientCore owners in the controller's HEADER PROSE:
        // every positive anchor read `source.text` raw back then, so a comment satisfied it. That is
        // a gate held green by a comment, which is the failure [`Claim::MentionsUnder`]'s own doc
        // says it exists to prevent — "would make an ordinary split of a big view look like a
        // regression". Reading the directory asks the question the law actually cares about: does
        // the phone's navigator read these, wherever its author put them.
        //
        // ⚠️ AND `Columns` WAS NOT WHEREVER — it was one of the two directories stage D split the
        // navigator ACROSS, so the root contradicted the sentence directly above it. `SidebarRowMenu`
        // is read from `Shell/NavigatorColumnViewController.swift`, in code, and the narrow root saw
        // none of it; only a doc comment down in `Columns/` kept the name answered. Both defects had
        // to go at once, and they are one defect: 2026-08-30 made the anchors read `statements()`
        // (see `Claim::Doors`), which turned the comment-shaped pass into the red it should have
        // been, and the red is what showed the root was the wrong half of the navigator. The root is
        // the TARGET now, because the claim is about the navigator, and the navigator is both
        // directories.
        Claim::MentionsUnder {
            root: "Sources/SlopDeskPhoneUI",
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
        // ⚠️ RE-AIMED 2026-08-28, with `phone_parity`'s island rows. The phone's half of this reading
        // was `Chrome/ConnectionPill.swift` and went with `3f11c6e6`; the `UIKit` rebuild is
        // `ConnectionIslandView.swift`, which takes the Mac's noun for the same surface. Red until it
        // lands, deliberately: this claim is the SECOND reader of a ladder cut once, and a list of one
        // reader has nothing left to compare.
        Claim::Mentions {
            path: "Sources/SlopDeskPhoneUI/Chrome/ConnectionIslandView.swift",
            names: &["ConnectionReading"],
            message: "the phone's connection island stopped reading {entry} — the alarm ladder is \
                      ClientCore's, cut once",
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
    let mut claims = vec![
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
        // The per-file readings are [`PANEL_READERS`], appended below.
        Claim::Names {
            path: "Sources/SlopDeskPhoneUI/Shell/WorkspaceRootViewController.swift",
            needle: "codeSidebarCollapsed",
            message: "the phone's root stopped reading codeSidebarCollapsed — revealCodeSidebar() would not \
                      reach the phone at all",
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
            // The SIMULATOR panel turns a view on purpose and says so: a simulator bezel is a device
            // rotating, and `MacSimulatorBezelView`'s own header records why the turn is a CUT rather
            // than an animation (an `AVSampleBufferDisplayLayer` mid-turn cross-fades every arriving
            // frame). The shell never had to decide this — its `Panel/*.swift` glob did not descend —
            // so the exemption is the decision that glob was making silently.
            //
            // `Panel/Android/` was exempt beside it and never used the API: an Android mirror has no
            // bezel to turn, so the carve-out described a device that does not rotate in this panel.
            // A carve-out over a directory that never types the banned spelling permits nothing and
            // reads as a second licence, so the licence is now the one file's law it actually is.
            exempt: &["Sources/SlopDeskMacUI/Panel/Simulator/"],
            message: "a panel tab turns its VIEW again ({files}) — turn the content, or the rail's hit \
                      areas overlap",
        },
    ];
    claims.extend(PANEL_READERS.iter().map(|&(path, pattern, message)| {
        Claim::Matches {
            path,
            pattern,
            view: View::Statements,
            message,
        }
    }));
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The phone's navigator is FOUR files now, and the fixture is four files for that reason: a
    /// seed that keeps all three readings in the controller would prove the claim against the shape
    /// docs/62 stage D took apart, and would pass identically under the old per-file `Mentions`.
    fn navigator(fixture: &Fixture) {
        fixture
            .write(
                super::PHONE_NAVIGATOR,
                "#if os(iOS)\nfinal class C: UIViewController {}\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Columns/NavigatorRowCell.swift",
                "SidebarRowPresentation\nSidebarRowMenu\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Columns/SidebarGitLineView.swift",
                "SidebarGitLine\n",
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

        // ⚠️ AN ORDINARY SPLIT IS NOT A REGRESSION, and it goes FIRST because it is the only case
        // here that asserts a clean tree — every later one seeds a violation that the next
        // `navigator()` does not undo. Moving a reading from one file of the column to another is
        // what the old per-file `Mentions` called a violation, and it is the whole reason this
        // claim reads the directory.
        fixture
            .write(
                "Sources/SlopDeskPhoneUI/Columns/NavigatorRowCell.swift",
                "SidebarRowMenu\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Columns/NavigatorSectionHeaderCell.swift",
                "SidebarRowPresentation\n",
            );
        assert!(super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // The shared row, back under any path.
        fixture.write("Sources/SlopDeskSlate/Row.swift", "struct SlateTabRow: View {}\n");
        assert!(!super::one_navigator_per_platform(&fixture.tree()).is_clean());

        // A half that PORTED the git line and one that DELETED it look the same to the sigil ban —
        // which is why the reader is asserted beside it. Deleting the CELL rather than editing the
        // controller is the point: the reading has to be missing from the whole column, not from
        // one file somebody split.
        navigator(&fixture);
        fixture.remove("Sources/SlopDeskPhoneUI/Columns/SidebarGitLineView.swift");
        let report = super::one_navigator_per_platform(&fixture.tree());
        assert!(
            report
                .violations()
                .iter()
                .any(|v| v.contains("the phone's navigator stopped reading SidebarGitLine")),
            "{report:?}"
        );

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
                "Sources/SlopDeskPhoneUI/Chrome/ConnectionIslandView.swift",
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

        // And a half that stopped reading the alarm ladder. `UIKit` now, and the drift the claim
        // exists for is the same one it always was: a shell wording the link itself.
        titlebar(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Chrome/ConnectionIslandView.swift",
            "label.text = \"link\"\n",
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
            .write("Sources/SlopDeskPhoneUI/Panel/PhonePanelBar.swift", "PanelTabs\n")
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabGroup.swift",
                "PanelTabs\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabPlate.swift",
                "AndroidMarkPath\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
                "constant: -CodePanelPresentation.clippedTitleBarHeight,\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Panel/MacCodeWorkbenchView.swift",
                "constant: -CodePanelPresentation.clippedTitleBarHeight,\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Shell/WorkspaceRootViewController.swift",
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

        // And the phone's panel becoming a second panel — a workbench that lifts its web view by a
        // number of its own instead of the one both shells clip to.
        panel(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhoneCodeWorkbenchView.swift",
            "constant: -28,\n",
        );
        assert!(!super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());

        // A phone tab surface cutting its own four — the half the parked claim never reached,
        // because it watched a controller that had already handed the tabs to its siblings.
        panel(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhonePanelTabGroup.swift",
            "let tabs: [PanelTab] = [.code, .simulator, .android, .web]\n",
        );
        assert!(!super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());

        // The PROSE does not count, on either shell — the whole reason these are `Matches`/`Code`.
        panel(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Panel/PhonePanelBar.swift",
            "// The four tabs are PanelTabs', cut once in ClientCore.\n",
        );
        assert!(!super::one_panel_chrome_one_tab_reading(&fixture.tree()).is_clean());
    }
}
