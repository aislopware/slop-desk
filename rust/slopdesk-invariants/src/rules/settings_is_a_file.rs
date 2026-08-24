//! Settings are a FILE, and the app is good on first launch without being asked anything.
//!
//! On 2026-08-24 the whole settings GUI and the whole first-launch flow were deleted — nineteen
//! `Settings/` views on the Mac, seventeen on the phone, six onboarding step cards, the row
//! catalogue that fed them and the four FFI door families under it. What replaced them is
//! `config.toml`, `docs/config.schema.json` and a set of defaults chosen once (`docs/58`).
//!
//! This is a ratchet rather than a comment because the deleted shape is the one that GROWS BACK BY
//! ITSELF. Every new setting arrives wanting a row, every row wants a page, and a page wants an
//! index to be found from — the pressure that built thirty-six view files in the first place has
//! not gone anywhere. Nothing here fails a test when it comes back: a `MacSettingsWindow` that
//! writes `UserDefaults` compiles, renders, and is internally consistent. It is only wrong against
//! a DECISION, which is exactly what this crate holds.
//!
//! The onboarding half is the same argument pointed at the other risk. A first-launch gate does not
//! merely add a screen: it makes every good default CONDITIONAL on somebody having clicked
//! through, so the install that skipped the flow is a different product from the one that did not.
//! The hook, the CLI symlink and the terminal integration are installed because they are right, not
//! because a sheet asked.
//!
//! Read `View::Code` like every other ban here — the prose above a ban names what it forbids.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// The directories the GUI occupied. They are BANNED as directories rather than as a list of files
/// because the list is the part that rots: a rule naming thirty-six paths goes green the moment
/// somebody reintroduces the thirty-seventh under a new name, while a rule naming the directory
/// cannot be routed around without moving the views somewhere they look even more out of place.
///
/// `Sources/SlopDeskVideoProtocol/Settings/` is deliberately NOT here. It survived the teardown and
/// should: it holds the config file's grammar and the preference VALUES the loader decodes into,
/// which is the file half, not the GUI half.
/// The one Swift surface that still reads a setting, now that the rows and pages are gone.
const SETTINGS_KEY: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift";

/// The key table every path is declared in, defaults and all.
const KEY_TABLE: &str = "rust/slopdesk-settings/src/config/table.rs";

const GUI_DIRECTORIES: &[&str] = &[
    "Sources/SlopDeskMacUI/Settings",
    "Sources/SlopDeskMacUI/FirstLaunch",
    "Sources/SlopDeskPhoneUI/Settings",
    "Sources/SlopDeskPhoneUI/FirstLaunch",
    "Sources/SlopDeskClientCore/Settings",
    "Sources/SlopDeskClientCore/FirstLaunch",
    "Sources/SlopDeskWorkspaceCore/FirstLaunch",
];

/// The GUI stays deleted and the app is good on first launch
///
/// Four claims, each closing a different way back.
///
/// **The directories.** A file under any of [`GUI_DIRECTORIES`] is the shape returning at its
/// original address.
///
/// **The types.** A view can come back anywhere, so the entry points are banned by NAME as well —
/// the two settings windows, the two chord editors, the two onboarding roots, and the three
/// catalogue types that indexed them. The taxonomy types are named for a reason of their own: a
/// settings PAGE is what makes a settings row necessary, and a section header with nothing under it
/// is the first file of the next GUI.
///
/// **The onboarding gate.** A `hasCompletedFirstLaunch`-shaped flag is the mechanism, not the
/// screen: it is what makes an install that has seen the sheet behave differently from one that has
/// not. Banned as a token so it cannot come back as a `Defaults` key with no view attached.
///
/// **The schema.** The file settings are read from is only usable if the editor can complete it, so
/// `docs/config.schema.json` must EXIST. Whether it is FRESH is a different question and a
/// different gate — `slopdesk-settings`' own `checked_in_schema` test, which can generate the
/// artifact and diff it, which this crate cannot.
#[must_use]
pub fn the_settings_gui_stays_deleted(tree: &Tree) -> Report {
    let claims = [
        Claim::NoFileUnder {
            roots: GUI_DIRECTORIES,
            extensions: SWIFT,
            pattern: r"\S",
            rescued_by: None,
            view: View::Raw,
            exempt: &[],
            message: "a settings or onboarding view is back in {files} — settings are config.toml and \
                      docs/config.schema.json, with no GUI (docs/58)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Apps"],
            extensions: SWIFT,
            pattern: r"(struct|final class|enum|actor|protocol) (MacSettingsWindow|MacSettingsPage|MacSettingsNavigator|MacAllSettingsIndex|MacKeybindingsEditor|SettingsSheet|SettingsPages|AllSettingsListView|KeybindingsEditorView|KeybindingsEditorModel|KeybindingCaptureHost|FirstLaunchView|FirstLaunchModel|MacFirstLaunchSheet|SettingsCatalog|AllSettingsCatalog|SettingsLayout|SettingsTaxonomy|SettingsSectionHeader)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a settings-GUI type is declared again in {files} — the row table, the pages and the \
                      chord recorder were deleted with the GUI (docs/58)",
        },
        Claim::NoneUnder {
            roots: &["Sources", "Apps"],
            extensions: SWIFT,
            pattern: r"hasCompletedFirstLaunch|didCompleteOnboarding|firstLaunchComplete|needsOnboarding",
            all: &[],
            unless: &[],
            view: View::Statements,
            exempt: &[],
            message: "a first-launch gate is back in {files} — every good default is enforced \
                      unconditionally, so there is no state that says the flow has been seen",
        },
        Claim::Subset {
            label: "settings-key-paths",
            subject: Extract::code(
                SETTINGS_KEY,
                r#"\.(?:choice|double|flag|int|list|text)\("([a-z0-9.-]+)""#,
            ),
            universe: Extract::code(KEY_TABLE, r#"^\s*path: "([a-z0-9.-]+)",$"#),
            message: "SettingsKey reads {orphans}, which the key table does not declare — an undeclared \
                      path answers with the accessor's fallback forever, and no config file can set it \
                      because the schema does not offer it",
        },
        Claim::Exists {
            path: "docs/config.schema.json",
            message: "the config schema is the only thing that makes a file-only settings system \
                      completable in an editor — regenerate it with `make config-schema`",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// A tree with the teardown done: the config file's own grammar survives, the GUI does not.
    fn torn_down(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/KeybindConfigLoader.swift",
                "public enum KeybindConfigLoader {}\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Overlays/MacConnectSheet.swift",
                "struct MacConnectSheet {}\n",
            )
            .write(
                super::SETTINGS_KEY,
                "static var density: String { AppConfig.current.text(\"appearance.density\") }\n\x20                    static var redact: Bool { AppConfig.current.flag(\"general.redact-secrets\") }\n",
            )
            .write(
                super::KEY_TABLE,
                "        path: \"appearance.density\",\n        path: \"general.redact-secrets\",\n",
            )
            .write("docs/config.schema.json", "{}\n")
    }

    #[test]
    fn a_settings_view_that_came_back_is_red() {
        let fixture = Fixture::new("settings-gui-deleted");
        torn_down(&fixture);
        assert!(super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());

        // At its original address, which is where it would actually reappear.
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/MacSettingsWindow.swift",
            "struct MacSettingsWindow {}\n",
        );
        assert!(!super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_settings_type_at_a_new_address_is_red() {
        // The directory ban alone would pass: the file is somewhere nobody thought to name.
        let fixture = Fixture::new("settings-gui-relocated");
        torn_down(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Overlays/Prefs.swift",
            "struct SettingsPages {\n    var body: some View { EmptyView() }\n}\n",
        );
        assert!(!super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_first_launch_gate_with_no_view_is_red() {
        // The flag is the mechanism; a tree with no onboarding SCREEN at all can still have one.
        let fixture = Fixture::new("settings-gui-gate");
        torn_down(&fixture);
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/Defaults.swift",
            "extension Defaults.Keys {\n    static let hasCompletedFirstLaunch = Key(false)\n}\n",
        );
        assert!(!super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_path_the_table_does_not_declare_is_red() {
        // The drift the ~90 deleted key-literal pins used to catch from the other side: an accessor
        // that reads a path nothing declares answers with its own fallback and never says so.
        let fixture = Fixture::new("settings-gui-undeclared");
        torn_down(&fixture);
        assert!(super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());

        fixture.write(
            super::SETTINGS_KEY,
            "static var density: String { AppConfig.current.text(\"appearance.density\") }\n\x20                static var ghost: Bool { AppConfig.current.flag(\"general.invented-key\") }\n",
        );
        assert!(!super::the_settings_gui_stays_deleted(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_missing_schema_is_red() {
        // Named rather than merely counted: this fixture is missing several files at once, so a
        // bare "not clean" would pass even if the schema claim had been dropped.
        let fixture = Fixture::new("settings-gui-schema");
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/KeybindConfigLoader.swift",
            "public enum KeybindConfigLoader {}\n",
        );
        let found = super::the_settings_gui_stays_deleted(&fixture.tree());
        assert!(
            found
                .violations()
                .iter()
                .any(|line| line.contains("make config-schema"))
        );
    }
}
