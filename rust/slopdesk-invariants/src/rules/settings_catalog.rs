//! What Settings OFFERS: one Rust table, one memoised reader, and no view that spells a choice.
//!
//! Ported from `scripts/check-supervisor.sh`. The choices, their labels, their honest captions, the
//! taxonomy and the ladders' stops and readouts are `slopdesk_workspace::settings_catalog`. They had
//! already been lifted once, out of view bodies into a Swift catalog, and the argument for lifting
//! them did not stop at the view boundary: the table has no framework in it, and the two halves of
//! the UI split were about to read it from two.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const CATALOG: &str = "Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift";
const CHEAT_SHEET: &str = "Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift";
const MENU_COMMANDS: &str = "Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift";

/// The thirteen doors the catalog is a face over, and the header both sides must name.
const CATALOG_DOORS: &[&str] = &[
    "slopdesk_settings_option_group",
    "slopdesk_settings_density_token",
    "slopdesk_settings_section_count",
    "slopdesk_settings_section_id",
    "slopdesk_settings_section_title",
    "slopdesk_settings_section_symbol",
    "slopdesk_settings_timing_label",
    "slopdesk_settings_timing_symbol",
    "slopdesk_settings_ladder",
    "slopdesk_settings_ladder_preset_count",
    "slopdesk_settings_ladder_preset_value",
    "slopdesk_settings_ladder_preset_label",
    "slopdesk_settings_ladder_readout",
];

/// The option groups cross WHOLE, and they cross ONCE
///
/// The two Swift files that held the table must stay gone. A card grid has no "…", so a group that
/// drifted between the two languages would render a DIFFERENT set of choices per platform with
/// nothing on screen saying so, and both halves would keep passing their own tests.
///
/// `SettingsCatalog.tokens(_:)` is what `options(_:as:)`, `stringOptions(_:)` and `label(_:for:)`
/// all forward to, so naming one token used to rebuild the whole group: `1 + 4n` doors, each
/// answering a STRING, which on the near side is a 64-byte `[UInt8]` and a `String` per field.
/// Measured at 51.3 µs for the twenty-three groups, and every reader above it sits in a `SwiftUI`
/// `body` or an `NSView` rebuild — the phone's all-settings list paid it per keystroke.
///
/// TWO properties, and the second is the one a future edit is likely to lose. The group must cross
/// in one delivery, AND the delivery must be read into a `static let`: a `tokens(_:)` that went back
/// to calling the door per read would still be one crossing and still be 10 µs of allocation on
/// every render pass, with nothing on either side saying so.
///
/// And no settings RENDERER may open the option-group door itself. The catalog face is the one
/// reader, the same way neither settings renderer opens the layout-page door: a second reader is a
/// second memo that is not one, and it would cross per render for a table that cannot change.
#[must_use]
pub fn the_option_groups_cross_whole_and_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Absent {
            path: "Sources/SlopDeskClientCore/Settings/SettingsOption.swift",
            message: "SettingsOption.swift is back — the settings catalog is Rust (docs/56)",
        },
        Claim::Absent {
            path: "Sources/SlopDeskClientCore/Settings/SettingsOptionCatalog.swift",
            message: "SettingsOptionCatalog.swift is back — the settings catalog is Rust (docs/56)",
        },
        Claim::Exists {
            path: CATALOG,
            message: "SettingsCatalog.swift is gone — without it no settings control has any choices to \
                      offer (docs/56)",
        },
        // The marshaller must actually call the doors. A `SettingsCatalog` that answered from a Swift
        // array again would pass every test above, because the tests read it rather than the boundary.
        Claim::Mentions {
            path: CATALOG,
            names: CATALOG_DOORS,
            message: "SettingsCatalog.swift stopped calling {entry} — an answer it holds itself is a table \
                      written twice",
        },
        Claim::Mentions {
            path: "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            names: CATALOG_DOORS,
            message: "{entry} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does \
                      not name",
        },
        Claim::Names {
            path: CATALOG,
            needle: "private static let groupRows",
            message: "SettingsCatalog.swift stopped memoising the option groups — tokens(_:) is what every \
                      settings face forwards to, and a per-read crossing there is 51 µs of marshalling per \
                      render pass (docs/55 §4)",
        },
        Claim::Names {
            path: CATALOG,
            needle: "groupRows[Int(group.rawValue)]",
            message: "SettingsCatalog.swift's tokens(_:) no longer reads groupRows — a face that asks the \
                      door again is the loop this port deleted",
        },
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI", "Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: "slopdesk_settings_option_group",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} opens the option-group door itself — the choices are SettingsCatalog's to read \
                      once, not a renderer's to re-read per body",
        },
    ];
    check_all(tree, &claims)
}

/// The cheat sheet's rows are a CONSTANT, and must stay declared as one
///
/// `CheatSheetContent.sections` reads two `static let` registry tables and renders each row's
/// DEFAULT chord, so its answer cannot change between two reads. As a computed `static var` it was
/// rebuilt on every one: 54 chord-bearing rows, each paying a `binding(for:)` that rebuilds the
/// 85-element `allBindings` array before scanning it (measured 1.43 µs) plus a glyph door and its
/// marshalling (254 ns) — ~86 µs, and the phone reads it from a `body`.
///
/// A `var` is the whole defect and it is one keyword, which is exactly the edit a pattern ban can
/// see. `WorkspaceCommands` is the same shape in the menu bar and gets the same treatment.
///
/// The shell asked its `titlesByID` claim only IF `WorkspaceCommands.swift` existed. That tolerance
/// did not come across: the file is the Mac's menu bar, its disappearance is a change worth a red,
/// and a claim that a missing file satisfies is one more way for this gate to check nothing.
#[must_use]
pub fn the_cheat_sheet_and_menu_bar_hold_their_constants(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: CHEAT_SHEET,
            message: "CheatSheetContent.swift is gone — the ⌘/ sheet's rows are the registry's, below both \
                      renderers",
        },
        Claim::Lacks {
            path: CHEAT_SHEET,
            pattern: r"^[[:space:]]*public static var sections",
            view: View::Raw,
            message: "CheatSheetContent.swift made sections a computed var again — it renders DEFAULT \
                      chords off two static tables, so every read rebuilt an 86 µs answer that cannot have \
                      changed",
        },
        Claim::Exists {
            path: MENU_COMMANDS,
            message: "WorkspaceCommands.swift is gone — the Mac's menu bar reads the same registry the \
                      cheat sheet does",
        },
        Claim::Names {
            path: MENU_COMMANDS,
            needle: "titlesByID",
            message: "WorkspaceCommands.swift stopped memoising its row titles — a Commands body \
                      re-evaluates on any observed store change, and the glyph lookup in front of each \
                      title is an 85-element array rebuild",
        },
        // And no settings VIEW may spell a choice's own words. A label typed into a card is the second
        // table: it renders, it looks right, and it is unreachable from the pin that would have caught
        // it.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskPhoneUI/Settings", "Sources/SlopDeskMacUI"],
            extensions: SWIFT,
            pattern: r#"SettingsOption\(\.|"Applies (now|on reconnect)"|"(Copy or paste|Left only|Right only)""#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spelled a CHOICE — the words are settings_catalog's, the view only draws them",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn catalog(fixture: &Fixture) {
        let doors = super::CATALOG_DOORS.join("\n");
        fixture
            .write(
                super::CATALOG,
                &format!("{doors}\nprivate static let groupRows = …\ngroupRows[Int(group.rawValue)]\n"),
            )
            .write("rust/slopdesk-ffi/include/slopdesk_ffi.h", &doors);
    }

    #[test]
    fn the_group_crosses_once_and_is_read_from_a_memo() {
        let fixture = Fixture::new("settings-catalog");
        catalog(&fixture);
        assert!(super::the_option_groups_cross_whole_and_once(&fixture.tree()).is_clean());

        // The memo dropped — one crossing still, and 10 µs of allocation per render pass.
        let doors = super::CATALOG_DOORS.join("\n");
        fixture.write(super::CATALOG, &format!("{doors}\nrows(of: group)\n"));
        assert!(!super::the_option_groups_cross_whole_and_once(&fixture.tree()).is_clean());

        // A renderer opening the door itself.
        catalog(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Settings/SettingsPages.swift",
            "slopdesk_settings_option_group(0, nil, 0)\n",
        );
        assert!(!super::the_option_groups_cross_whole_and_once(&fixture.tree()).is_clean());

        // And a door the header stopped naming.
        catalog(&fixture);
        fixture.write("rust/slopdesk-ffi/include/slopdesk_ffi.h", "slopdesk_settings_ladder\n");
        assert!(!super::the_option_groups_cross_whole_and_once(&fixture.tree()).is_clean());
    }

    fn constants(fixture: &Fixture) {
        fixture
            .write(super::CHEAT_SHEET, "    public static let sections: [Section] = build()\n")
            .write(super::MENU_COMMANDS, "private static let titlesByID: [ID: String] = [:]\n");
    }

    #[test]
    fn a_constant_answer_stays_declared_as_one() {
        let fixture = Fixture::new("settings-constants");
        constants(&fixture);
        assert!(super::the_cheat_sheet_and_menu_bar_hold_their_constants(&fixture.tree()).is_clean());

        // One keyword is the whole defect.
        fixture.write(super::CHEAT_SHEET, "    public static var sections: [Section] { build() }\n");
        assert!(!super::the_cheat_sheet_and_menu_bar_hold_their_constants(&fixture.tree()).is_clean());

        constants(&fixture);
        fixture.write(super::MENU_COMMANDS, "var body: some Commands { … }\n");
        assert!(!super::the_cheat_sheet_and_menu_bar_hold_their_constants(&fixture.tree()).is_clean());

        // And a choice's words typed into a card.
        constants(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/MacSettingsCard.swift",
            "Text(\"Applies on reconnect\")\n",
        );
        assert!(!super::the_cheat_sheet_and_menu_bar_hold_their_constants(&fixture.tree()).is_clean());
    }
}
