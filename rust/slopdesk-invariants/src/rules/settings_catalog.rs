//! What Settings OFFERS: one Rust table, one memoised reader, and no view that spells a choice.
//!
//! Ported from the deleted `check-supervisor.sh`. The choices, their labels, their honest captions,
//! the taxonomy and the ladders' stops and readouts are `slopdesk_workspace::settings_catalog`.
//! They had already been lifted once, out of view bodies into a Swift catalog, and the argument for
//! lifting them did not stop at the view boundary: the table has no framework in it, and the two
//! halves of the UI split were about to read it from two.

use crate::claim::{Claim, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const CHEAT_SHEET: &str = "Sources/SlopDeskClientCore/Overlays/CheatSheetContent.swift";
const MENU_COMMANDS: &str = "Sources/SlopDeskMacUI/Commands/WorkspaceCommands.swift";

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

    fn constants(fixture: &Fixture) {
        fixture
            .write(
                super::CHEAT_SHEET,
                "    public static let sections: [Section] = build()\n",
            )
            .write(
                super::MENU_COMMANDS,
                "private static let titlesByID: [ID: String] = [:]\n",
            );
    }

    #[test]
    fn a_constant_answer_stays_declared_as_one() {
        let fixture = Fixture::new("settings-constants");
        constants(&fixture);
        assert!(super::the_cheat_sheet_and_menu_bar_hold_their_constants(&fixture.tree()).is_clean());

        // One keyword is the whole defect.
        fixture.write(
            super::CHEAT_SHEET,
            "    public static var sections: [Section] { build() }\n",
        );
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
