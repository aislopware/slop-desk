//! The two crates that dress the embedded workbench, and the Swift that may only marshal for them.
//!
//! Ported from the deleted `check-supervisor.sh`. The panel is dressed from BOTH sides — the host
//! seeds code-server's settings before it boots, the client injects a sheet and four scripts into
//! the page afterwards — and the two sides share no code on purpose. What is enforced here is the
//! one fact that makes that split safe, plus the boundary that keeps the client half from growing a
//! second implementation.

use crate::claim::{Claim, Extract, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The host seed's settings table.
const CODESEED: &str = "rust/slopdesk-codeseed/src/settings.rs";

/// The client's injected dressing.
const CODEPANEL: &str = "rust/slopdesk-codepanel/src/dressing.rs";

/// The Swift face over it.
const SWIFT_DRESSING: &str = "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift";

/// The two bundled font families agree across a boundary they deliberately do not cross.
///
/// `slopdesk-codepanel` injects `@font-face` declarations into the workbench and
/// `slopdesk-codeseed` seeds the `editor.fontFamily` that names them. If the two disagree the panel
/// falls through to the system mono — no error, no crash, just the wrong shapes beside a terminal
/// drawing the right ones. They cross no door on purpose: codeseed is a HOST crate carrying the
/// whole seed history, and linking it into the FFI artifact would drag those tables into the iOS
/// binary for two strings. So this gate does the job the door would have, and the empty-side arms
/// are what stop a renamed constant reading as agreement between two nothings.
///
/// The stack is also BUILT from the two rather than typed out a third time. The check that stops
/// the family being listed twice used to hold its own copy of the word, so renaming the face in the
/// stack alone would have made the stack repeat it while every `starts_with` assertion kept
/// passing.
#[must_use]
pub fn font_pair_agrees_across_the_seam(tree: &Tree) -> Report {
    let claims = [
        Claim::SameValue {
            label: "the injected mono family and the seeded one",
            swift: Extract::code(CODEPANEL, r#"^pub const MONO_FONT_FAMILY: &str = "(.*)";$"#),
            rust: Extract::code(CODESEED, r#"^pub const MONO_FONT_FAMILY: &str = "(.*)";$"#),
        },
        Claim::SameValue {
            label: "the injected nerd family and the seeded one",
            swift: Extract::code(CODEPANEL, r#"^pub const NERD_FONT_FAMILY: &str = "(.*)";$"#),
            rust: Extract::code(CODESEED, r#"^pub const NERD_FONT_FAMILY: &str = "(.*)";$"#),
        },
        Claim::NoneOf {
            paths: &[CODESEED],
            pattern: r#"const FALLBACK: &str = "'"#,
            view: View::Code,
            message: "{files} typed the font stack out again — build it from the two named families",
        },
    ];
    check_all(tree, &claims)
}

/// The client's dressing is ONE implementation, and the Swift beside it only marshals.
///
/// 1,354 lines of pure string building — the stylesheet, the four injected scripts, the 834-line
/// recommendation catalogue — lived in Swift because the panel arrived before the boundary did.
/// Every one of them was `import Foundation` and nothing else, and every one is now
/// `rust/slopdesk-codepanel`'s. What the ban catches is the shape that would put them back: a
/// literal `@font-face`, a `<svg`, a `(function () {`, or the catalogue's own keys spelled in Swift
/// again. A second copy here would not fail — it would DRESS THE PAGE, correctly, until the day the
/// two disagreed, which is exactly the failure the crate exists to make impossible.
#[must_use]
pub fn dressing_is_one_implementation(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: SWIFT_DRESSING,
            names: &["slopdesk_code_panel_text", "slopdesk_code_panel_dressing_script"],
            message: "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift no longer asks \
                      {entry} — the dressing is one implementation",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            all: &[],
            unless: &[],
            exempt: &[],
            pattern: r"@font-face|<svg |\(function \(\) \{|extensionRecommendations|keymapExtensionTips",
            view: View::Code,
            message: "{files} builds the workbench dressing in Swift again — rust/slopdesk-codepanel owns \
                      the sheet, the four scripts and the tips catalogue",
        },
        Claim::Absent {
            path: "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarRecommendationTips.swift",
            message: "{files} is back — the catalogue is a JSON resource in rust/slopdesk-codepanel, not an \
                      834-line Swift literal",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_tree(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-codeseed/src/settings.rs",
                "pub const MONO_FONT_FAMILY: &str = \"JetBrains Mono\";\npub const NERD_FONT_FAMILY: &str = \
                 \"Symbols Nerd Font\";\n",
            )
            .write(
                "rust/slopdesk-codepanel/src/dressing.rs",
                "pub const MONO_FONT_FAMILY: &str = \"JetBrains Mono\";\npub const NERD_FONT_FAMILY: &str = \
                 \"Symbols Nerd Font\";\n",
            )
            .write(
                "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift",
                "slopdesk_code_panel_text\nslopdesk_code_panel_dressing_script\n",
            );
    }

    #[test]
    fn a_renamed_face_on_either_side_is_caught() {
        let fixture = Fixture::new("code-panel-font-pair");
        write_tree(&fixture);
        assert!(super::font_pair_agrees_across_the_seam(&fixture.tree()).is_clean());

        // The seed renames its face and the injection does not — the panel falls silently through
        // to the system mono, which is the whole reason this gate exists.
        fixture.write(
            "rust/slopdesk-codeseed/src/settings.rs",
            "pub const MONO_FONT_FAMILY: &str = \"Menlo\";\npub const NERD_FONT_FAMILY: &str = \"Symbols \
             Nerd Font\";\n",
        );
        assert!(!super::font_pair_agrees_across_the_seam(&fixture.tree()).is_clean());

        // And a constant that went missing does not read as agreement between two nothings.
        write_tree(&fixture);
        fixture.write("rust/slopdesk-codepanel/src/dressing.rs", "");
        assert!(!super::font_pair_agrees_across_the_seam(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_sheet_rebuilt_in_swift_is_caught() {
        let fixture = Fixture::new("code-panel-one-implementation");
        write_tree(&fixture);
        assert!(super::dressing_is_one_implementation(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift",
            "nothing crosses here any more\n",
        );
        assert!(!super::dressing_is_one_implementation(&fixture.tree()).is_clean());

        // And the sheet respelled beside the marshaller.
        write_tree(&fixture);
        fixture.append(
            "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarPageDressing.swift",
            "let sheet = \"@font-face { font-family: x; }\"\n",
        );
        assert!(!super::dressing_is_one_implementation(&fixture.tree()).is_clean());

        // And the catalogue back as a Swift literal.
        write_tree(&fixture);
        fixture.write(
            "Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarRecommendationTips.swift",
            "package enum CodeSidebarRecommendationTips {}\n",
        );
        assert!(!super::dressing_is_one_implementation(&fixture.tree()).is_clean());
    }
}
