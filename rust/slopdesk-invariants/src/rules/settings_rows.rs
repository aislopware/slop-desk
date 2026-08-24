//! What a setting IS: one row table, one alphabet per key, one page shape, one chord editor.
//!
//! Ported from the deleted `check-supervisor.sh`. Where `settings_catalog` covers what a control
//! OFFERS, this covers the row itself — its label, its key, the page it sits on and the recorder
//! that edits its chord. Every one of them is `slopdesk-settings`' table and a Swift marshaller
//! over it, and every one of them has a way of drifting that compiles, runs, renders and fails no
//! test.

use crate::claim::{Claim, Extract, SWIFT, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const ROWS_SWIFT: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift";
const SETTINGS_KEY: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift";
const CONFIG_BRIDGE: &str =
    "Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore+ConfigBridge.swift";
const ROWS_RUST: &str = "rust/slopdesk-settings/src/settings_rows.rs";
const LAYOUT_RUST: &str = "rust/slopdesk-settings/src/settings_layout.rs";
const LAYOUT_SWIFT: &str = "Sources/SlopDeskClientCore/Settings/SettingsLayout.swift";
const LAYOUT_FFI: &str = "rust/slopdesk-ffi/src/settings_layout.rs";
const HEADER: &str = "rust/slopdesk-ffi/include/slopdesk_ffi.h";
const MAC_CHORDS: &str = "Sources/SlopDeskMacUI/Settings/MacKeybindingsEditor.swift";
const PHONE_CHORDS: &str = "Sources/SlopDeskPhoneUI/Settings/KeybindingsEditorView.swift";

/// The two halves that draw a settings page, and the floor under every ban that reads them.
const SETTINGS_VIEWS: &[&str] = &["Sources/SlopDeskPhoneUI/Settings", "Sources/SlopDeskMacUI"];

/// The seven row doors. The per-FIELD doors are deliberately not here: they still exist and three
/// callers that want exactly one string still ask them, but reading a whole row through them cost
/// eight crossings per row on every settings-search keystroke, so `entry(at:)` asks
/// `slopdesk_settings_row_fields` and gets the row tagged and length-prefixed in one.
const ROW_DOORS: &[&str] = &[
    "slopdesk_settings_row_count",
    "slopdesk_settings_row_key",
    "slopdesk_settings_row_fields",
    "slopdesk_settings_row_is_inline_editable",
    "slopdesk_settings_row_persistence",
    "slopdesk_settings_row_index",
    "slopdesk_settings_row_matches",
];

/// Every row key, both notations. The comparison target for the two one-directional subsets below.
const fn row_keys() -> Extract {
    Extract::code(ROWS_RUST, r#"^        key: "(.*)",$"#)
}

/// A setting is NAMED once
///
/// The row table — every key with its label, its one-line description, its default and where it is
/// edited — is `slopdesk_workspace::settings_rows`. `AllSettingsCatalog.swift` is the near side and
/// must stay a MARSHALLER: a Swift array of rows would pass every test that reads it, because the
/// tests read the catalog rather than the boundary.
///
/// And no view may TYPE a row's label. A setting is named on the page where it is set and again in
/// the searchable list, and those are the same words for the same job — they were two strings, and
/// two was already one too many ("Hide Mouse While Typing" vs "…When Typing", "Long-Command
/// Notification" vs "…Completion"). The labels are read out of the Rust table and looked for
/// verbatim, so a re-typed one fails by its own text.
///
/// The DESCRIPTION is deliberately not covered: an index blurb and an in-context subtitle are two
/// registers, and `docs/56` §18 says so.
#[must_use]
pub fn a_setting_is_named_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: ROWS_SWIFT,
            message: "nothing would advertise a setting to the all-settings list (docs/56)",
        },
        Claim::Mentions {
            path: ROWS_SWIFT,
            names: ROW_DOORS,
            message: "AllSettingsCatalog.swift stopped calling {entry} — a row it describes itself is a \
                      table written twice",
        },
        Claim::Mentions {
            path: HEADER,
            names: ROW_DOORS,
            message: "{entry} is missing from slopdesk_ffi.h — Swift cannot reach a door the header does \
                      not name",
        },
        // The floor under both quotation bans. This gate has died quietly three times by resolving to
        // an empty file list, and a ban over nothing passes.
        Claim::Populated {
            roots: SETTINGS_VIEWS,
            extensions: SWIFT,
            minimum: 20,
            message: "the settings renderer corpus read as {found} files — the label and header bans below \
                      have gone vacuous and are checking nothing",
        },
        Claim::NoneQuoting {
            roots: SETTINGS_VIEWS,
            extensions: SWIFT,
            needles: Extract::code(ROWS_RUST, r#"^        label: "(.*)",$"#),
            template: "\"{needle}\"",
            view: View::Code,
            exempt: &[],
            message: "{files} TYPED a row's label — ask settingLabel(key); the words are settings_rows'",
        },
    ];
    check_all(tree, &claims)
}

/// A key is spelled once, in whichever half of the alphabet it belongs to
///
/// `settings_rows.rs` names its keys in TWO notations and the gate that came first only ever read
/// one. The config-style names (`font-family`, `video-fec-k`) are `AllSettingsCatalog.RenderKey`'s.
/// The dotted `UserDefaults` keys (`controls.copyOnSelect`, `notifications.longCommand`) are each
/// ALSO a `static let` in `SettingsKey.swift`, character for character, because a `Defaults.Key`
/// name cannot leave Swift and the Rust row has to quote it to advertise it.
///
/// Sixty-eight strings written twice, and until this gate nothing compared them. A typo on either
/// side compiles, passes every test, and ships a settings row bound to a key nothing reads: the
/// toggle moves, the plist gains an orphan entry, and the feature it was supposed to control never
/// changes. There is no error anywhere in that story.
///
/// `RenderKey` cannot become a door — a Swift `switch` case needs a compile-time constant, which is
/// the wall `PaneLivenessState` hit — so the answer is the one that worked there: compare the two
/// halves as TEXT, before either is compiled.
///
/// The third speller is `PreferencesStore+ConfigBridge`: three `switch` statements over the same
/// five names, none of which goes through `RenderKey`. A `switch` over a `String` has a `default:`
/// arm, so `case "font-siz":` neither fails to compile nor fails to run — it stops matching, and
/// the row goes on rendering its current value while the write that was supposed to follow it lands
/// nowhere.
///
/// The dot/dash split is the classifier for the `SettingsKey` half, and it is CHECKED rather than
/// assumed: a key carrying both notations or neither means the two alphabets have started to blur
/// and that comparison is reading the wrong half of the set.
#[must_use]
pub fn a_settings_key_is_spelled_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Exists {
            path: SETTINGS_KEY,
            message: "the settings keys settings_rows.rs quotes have no near side (docs/56)",
        },
        Claim::Exists {
            path: CONFIG_BRIDGE,
            message: "the typed prefs models have no bridge to the row keys (docs/56)",
        },
        Claim::EachMatches {
            label: "the settings row keys",
            from: row_keys(),
            pattern: r"^([^-]*\.[^-]*|[^.]*-[^.]*)$",
            message: "{members} is neither a dotted UserDefaults key nor a dashed config name — this gate \
                      can no longer tell the two alphabets apart",
        },
        Claim::Subset {
            label: "render key ⊆ row key",
            subject: Extract::code(ROWS_SWIFT, r#"^        public static let [A-Za-z]* = "(.*)"$"#)
                .within(r"public enum RenderKey \{", r"^    \}$"),
            universe: row_keys(),
            message: "the RenderKey {orphans} names no row in settings_rows.rs — the two spellings of that \
                      key have drifted, and a view asking for a row that does not exist renders as nothing",
        },
        // ONE DIRECTION, deliberately. Eleven `SettingsKey` constants are internal state rather than
        // settings (`window.savedFrame`, `firstLaunch.completed`, `shell.openedCodeProjects`) and have
        // no row by design, so the reverse gate would need an allowlist of those eleven.
        Claim::Subset {
            label: "dotted row key ⊆ SettingsKey",
            subject: Extract::code(ROWS_RUST, r#"^        key: "([^-"]*\.[^-"]*)",$"#),
            universe: Extract::code(
                SETTINGS_KEY,
                r#"^    public static let [A-Za-z0-9]+(?:: String)? = "([^"]*)""#,
            ),
            message: "the settings_rows key {orphans} is not a SettingsKey constant — that row edits a \
                      UserDefaults key nothing reads (docs/56)",
        },
        // Also one direction: the bridge covers the terminal config keys and not the video or
        // font-fallback ones, so a key it does not mention is not a finding. A name it DOES mention
        // that no row advertises is.
        Claim::Subset {
            label: "config-bridge arm ⊆ row key",
            subject: Extract::code(CONFIG_BRIDGE, r#"^[[:space:]]*case "([^"]*)""#),
            universe: row_keys(),
            message: "PreferencesStore+ConfigBridge switches on {orphans}, which no settings_rows key \
                      spells — that arm can never match",
        },
    ];
    check_all(tree, &claims)
}

/// A platform gate on a settings page is DATA, and a PAGE crosses whole
///
/// Which groups a page shows, in what order, and which platform each belongs to is
/// `slopdesk_workspace::settings_layout`. `SettingsLayout.swift` is the near side and
/// `rust/slopdesk-ffi/src/settings_layout.rs` is the marshalling.
///
/// ONE door, on both sides. It used to be TEN, addressed positionally — a group count, then a
/// title, a timing and a row count per group, then six more per row — which is `1 + 3G + 6R`
/// crossings to answer one question, asked from inside a body both renderers re-evaluate whenever a
/// `@Default` on the page changes. Each of those doors RE-DERIVED the whole page to reach one
/// member, so laying out Appearance made ~166 crossings doing ~166 filters and ~330 allocations to
/// read 23 `&'static` rows. Nothing failed while it did, because every answer was RIGHT; the only
/// trace was the frame rate under a slider drag on that page. A door is born in the header and in
/// the shim, so the ban on its return is in both — either can be edited on its own.
///
/// The door is matched with a word boundary rather than as a substring, because a plain substring
/// passes on a door RENAMED to `…_pagev2`, which is exactly the shape a "just one more door" change
/// takes.
///
/// The point of the table is that a gate became a VALUE, so the gate must not grow back.
/// `Half.current` was its last hiding place: a `#if os(macOS)` inside an otherwise shared file,
/// answering "which half am I" at COMPILE time in a target that compiled for both. The halves are
/// split now, so it answers `.phone` outright.
#[must_use]
pub fn a_settings_page_is_shaped_once(tree: &Tree) -> Report {
    // The nine doors the port deleted, spelled once so the header ban and the shim ban cannot come to
    // disagree about what a positional door is.
    const POSITIONAL: &str = concat!(
        "slopdesk_settings_layout_(group_count|group_title|group_timing|row_count|row_key",
        "|row_subtitle|row_glyph|row_bespoke_id|row_control)"
    );

    let claims = [
        Claim::Exists {
            path: LAYOUT_SWIFT,
            message: "a settings page would have to spell its own shape again (docs/56)",
        },
        Claim::Exists {
            path: LAYOUT_FFI,
            message: "the settings page shape has no marshalling left (docs/55 §2)",
        },
        Claim::Matches {
            path: LAYOUT_SWIFT,
            pattern: r"slopdesk_settings_layout_page\b",
            view: View::Code,
            message: "SettingsLayout.swift stopped calling slopdesk_settings_layout_page — a page shape it \
                      holds itself is a table written twice (docs/56)",
        },
        // Matched WITH its opening parenthesis, which is what `slopdesk-gate ffi` greps the header for when
        // it builds the symbol list every slice must carry — so this gate and that one cannot disagree
        // about what counts as a declaration.
        Claim::Matches {
            path: HEADER,
            pattern: r"slopdesk_settings_layout_page\(",
            view: View::Raw,
            message: "slopdesk_settings_layout_page is missing from slopdesk_ffi.h — Swift cannot reach a \
                      door the header does not name (docs/55 §2)",
        },
        Claim::Lacks {
            path: HEADER,
            pattern: POSITIONAL,
            view: View::Code,
            message: "slopdesk_ffi.h declares a per-index settings-layout door again — a page crosses \
                      WHOLE, and a positional door rebuilds the page once per member (docs/55 §4)",
        },
        // Anchored to the export, not the name: the shim's own prose says which doors are gone, and a
        // bare name ban would fire on the note explaining the deletion.
        //
        // Assembled with `concat!` for the reason `one_home_per_operation` assembles its own: the C
        // ABI marker spelled as a literal here is a match THAT ban finds in this file, and the honest
        // answer is to stop spelling it rather than to exempt the gate from a rule that has to be
        // universal to mean anything.
        Claim::Lacks {
            path: LAYOUT_FFI,
            pattern: concat!(
                "extern ",
                r#""C""#,
                " fn slopdesk_settings_layout_(group_count|group_title|group_timing|row_count|row_key",
                "|row_subtitle|row_glyph|row_bespoke_id|row_control)"
            ),
            view: View::CodeBeforeTests,
            message: "the FFI shim exported a per-index settings-layout door again — a page crosses WHOLE \
                      (docs/55 §4)",
        },
        // The page crosses ONCE, and it crosses through `SettingsLayout.swift`. A renderer that opens
        // the door itself is a second delivery per body evaluation, and the two settings faces are
        // exactly where that is convenient, because both already hold a `SettingsLayout.Group`.
        Claim::NoneUnder {
            roots: &["Sources/SlopDeskMacUI", "Sources/SlopDeskPhoneUI"],
            extensions: SWIFT,
            pattern: "slopdesk_settings_layout",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} opens the settings-layout door itself — the page crosses once, through \
                      SettingsLayout.swift, and a renderer that asks again pays a delivery per body \
                      evaluation (docs/55 §4)",
        },
        // The near side's first guess at a page's size, and the Rust constant the test measures every
        // page against. One number, two spellings. A page that stopped fitting would still be CORRECT
        // — §4's retry fetches it — and would silently cost every settings render TWO crossings
        // instead of the one this port exists to deliver, with nothing on either side saying so.
        Claim::SameValue {
            label: "the settings page first-guess buffer",
            swift: Extract::code(LAYOUT_SWIFT, r"^ *private static let inlineCapacity = ([0-9]+)$"),
            rust: Extract::raw(LAYOUT_FFI, r"^ *const SWIFT_FIRST_GUESS: usize = ([0-9]+);$"),
        },
        // The two tests that make the delivery checkable at all: one walks EVERY row of EVERY page on
        // BOTH halves against the table the deleted index doors read, the other measures every page
        // against the buffer above. Delete either and the suite stays green over a layout nothing pins.
        Claim::Mentions {
            path: LAYOUT_FFI,
            names: &[
                "every_row_of_every_page_matches_the_table_the_index_doors_read",
                "every_page_fits_the_near_sides_first_guess",
            ],
            message: "the FFI shim dropped {entry} — the page delivery is then pinned by nothing (docs/55 \
                      §4)",
        },
        Claim::LacksWithin {
            path: "Sources/SlopDeskPhoneUI/Settings/SettingsControls.swift",
            start: "static var current",
            end: r"^\}",
            pattern: "#if",
            view: View::Code,
            message: "SettingsLayout.Half.current forked on a platform again — it is one half's constant \
                      now (docs/56)",
        },
        // The floor under both bans that read the two settings faces, stated here as well as in
        // `a_setting_is_named_once` because the two rules run independently and a drained corpus must
        // not be able to silence one of them.
        Claim::Populated {
            roots: SETTINGS_VIEWS,
            extensions: SWIFT,
            minimum: 20,
            message: "the settings renderer corpus read as {found} files — the door and header bans above \
                      have gone vacuous and are checking nothing",
        },
        // A ported page renders from the table, so it may not name a group header it draws.
        Claim::NoneQuoting {
            roots: SETTINGS_VIEWS,
            extensions: SWIFT,
            needles: Extract::code(LAYOUT_RUST, r#"^        title: "(.*)",$"#),
            template: "slateFormSection(\"{needle}\")",
            view: View::Code,
            exempt: &[],
            message: "{files} TYPED a group header the layout table already holds — render it from the table",
        },
    ];
    check_all(tree, &claims)
}

/// One chord editor, drawn twice
///
/// Key Bindings is `Platform::Both`, so it is the one BESPOKE group the Mac draws itself rather
/// than hosting: its recorder is an `NSEvent` monitor scoped to the Settings window, and a monitor
/// is not a view. Two drawings over one registry is fine; two answers to "what did the user just
/// press" or "does this row match the search" is not, and neither fails loudly — a second capture
/// table just quietly records a chord the dispatcher will never fire.
///
/// The Mac reads an `NSEvent` and asks `KeybindingCapture` (`slopdesk_video::key_naming`, off a
/// macOS virtual key code); the phone reads a `UIKey` and asks `PhoneKey.captureOutcome`
/// (`slopdesk_workspace::phone_key`, off its HID usage). The two tables live in crates that cannot
/// see each other, so their agreement is a test in `slopdesk-ffi`, which can — and that test is
/// what stops a phone rebind from being written under a spelling the Mac's lookup never builds.
///
/// The two override writers must PRESERVE `textBindings` / `unbinds`. Rebuilding the model as
/// `KeybindingPreferences(overrides:)` defaults both to empty, so a single rebind in Settings
/// silently wipes every `config.toml` literal-byte binding — the audit bug, and it looks like
/// nothing at all. (`KeybindingPreferences()` with no arguments is the GLOBAL reset and is meant to
/// clear everything.)
#[must_use]
pub fn one_chord_editor_drawn_twice(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: MAC_CHORDS,
            names: &["WorkspaceBindingRegistry", "KeybindingsEditorModel"],
            message: "the Mac's chord editor stopped reading {entry} — two chord editors, and the drift \
                      would be silent",
        },
        Claim::Mentions {
            path: PHONE_CHORDS,
            names: &["WorkspaceBindingRegistry", "KeybindingsEditorModel"],
            message: "the phone's chord editor stopped reading {entry} — two chord editors, and the drift \
                      would be silent",
        },
        Claim::Names {
            path: PHONE_CHORDS,
            needle: "PhoneKey.captureOutcome",
            message: "the phone's chord editor stopped asking PhoneKey.captureOutcome — a second capture \
                      table is silent",
        },
        Claim::Names {
            path: MAC_CHORDS,
            needle: "KeybindingCapture.outcome",
            message: "the Mac's chord editor stopped asking KeybindingCapture — a chord it records may \
                      never fire",
        },
        Claim::Names {
            path: "rust/slopdesk-ffi/src/phone_key.rs",
            needle: "the_two_recorders_agree_on_every_key_both_can_name",
            message: "the recorders' agreement test is gone — the two capture tables can now drift silently",
        },
        Claim::NoneOf {
            paths: &[MAC_CHORDS, PHONE_CHORDS],
            pattern: r"KeybindingPreferences\(overrides:",
            view: View::Code,
            message: "{files} rebuilt KeybindingPreferences — that wipes the config.toml literal-byte \
                      bindings",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// Twenty-odd settings views, none of which types a label or a header.
    fn views(fixture: &Fixture) {
        for index in 0..24 {
            fixture.write(
                &format!("Sources/SlopDeskMacUI/Settings/Page{index}.swift"),
                "Text(settingLabel(key))\n",
            );
        }
    }

    fn rows(fixture: &Fixture) -> &Fixture {
        let doors = super::ROW_DOORS.join("\n");
        fixture
            .write(super::ROWS_SWIFT, &doors)
            .write("rust/slopdesk-ffi/include/slopdesk_ffi.h", &doors)
            .write(
                super::ROWS_RUST,
                "        key: \"controls.copyOnSelect\",\n        label: \"Copy on Select\",\n\x20       \
                 key: \"font-family\",\n        label: \"Font\",\n",
            );
        views(fixture);
        fixture
    }

    #[test]
    fn a_label_belongs_to_the_table_and_a_view_may_not_retype_it() {
        let fixture = Fixture::new("settings-rows-named");
        rows(&fixture);
        assert!(super::a_setting_is_named_once(&fixture.tree()).is_clean());

        // The drift this exists for: the same setting, named twice, differently.
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/Page3.swift",
            "Toggle(\"Copy on Select\", isOn: $flag)\n",
        );
        assert!(!super::a_setting_is_named_once(&fixture.tree()).is_clean());

        // A comment naming the label is not a finding.
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/Page3.swift",
            "// the row reads \"Copy on Select\"\nText(settingLabel(key))\n",
        );
        assert!(super::a_setting_is_named_once(&fixture.tree()).is_clean());

        // A door the header stopped naming.
        fixture.write(
            "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            "slopdesk_settings_row_count\n",
        );
        assert!(!super::a_setting_is_named_once(&fixture.tree()).is_clean());
    }

    /// The corpus draining is the failure mode the shell had three times: a ban over no files
    /// passes.
    #[test]
    fn a_drained_renderer_corpus_fails_rather_than_passing() {
        let fixture = Fixture::new("settings-rows-drained");
        let doors = super::ROW_DOORS.join("\n");
        fixture
            .write(super::ROWS_SWIFT, &doors)
            .write("rust/slopdesk-ffi/include/slopdesk_ffi.h", &doors)
            .write(super::ROWS_RUST, "        label: \"Copy on Select\",\n");
        assert!(!super::a_setting_is_named_once(&fixture.tree()).is_clean());
    }

    fn keys(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::ROWS_RUST,
                "        key: \"controls.copyOnSelect\",\n        key: \"font-family\",\n",
            )
            .write(
                super::ROWS_SWIFT,
                "public enum RenderKey {\n        public static let fontFamily = \"font-family\"\n    }\n",
            )
            .write(
                super::SETTINGS_KEY,
                "    public static let copyOnSelect = \"controls.copyOnSelect\"\n",
            )
            .write(super::CONFIG_BRIDGE, "        case \"font-family\":\n")
    }

    #[test]
    fn a_key_is_spelled_once_across_three_files() {
        let fixture = Fixture::new("settings-rows-keys");
        keys(&fixture);
        assert!(super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());

        // A row bound to a UserDefaults key nothing reads.
        fixture.write(
            super::SETTINGS_KEY,
            "    public static let copyOnSelect = \"controls.copyOnSelekt\"\n",
        );
        assert!(!super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());

        // A bridge arm that can never match.
        keys(&fixture);
        fixture.write(super::CONFIG_BRIDGE, "        case \"font-siz\":\n");
        assert!(!super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());

        // A key in neither alphabet — the classifier under the subset, without which that key would
        // simply drop out of the comparison.
        keys(&fixture);
        fixture.write(
            super::ROWS_RUST,
            "        key: \"controls.copyOnSelect\",\n        key: \"font-family\",\n\x20       key: \
             \"plainname\",\n",
        );
        assert!(!super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_render_key_names_a_row_that_exists() {
        let fixture = Fixture::new("settings-rows-render");
        keys(&fixture);
        fixture.write(
            super::ROWS_SWIFT,
            "public enum RenderKey {\n        public static let fontFamily = \"font-family\"\n    }\n",
        );
        assert!(super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());

        fixture.write(
            super::ROWS_SWIFT,
            "public enum RenderKey {\n        public static let fontFamily = \"font-fam\"\n    }\n",
        );
        assert!(!super::a_settings_key_is_spelled_once(&fixture.tree()).is_clean());
    }

    fn page(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::LAYOUT_SWIFT,
                "slopdesk_settings_layout_page(0, true, &out, 4096)\n    private static let inlineCapacity \
                 = 4096\n",
            )
            .write(
                super::LAYOUT_FFI,
                "const SWIFT_FIRST_GUESS: usize = 4096;\nfn \
                 every_row_of_every_page_matches_the_table_the_index_doors_read() {}\nfn \
                 every_page_fits_the_near_sides_first_guess() {}\n",
            )
            .write(
                super::HEADER,
                "size_t slopdesk_settings_layout_page(uint8_t i, bool mac, uint8_t *out, size_t cap);\n",
            )
            .write(
                "Sources/SlopDeskPhoneUI/Settings/SettingsControls.swift",
                "enum Half {\n    static var current: Self { .phone }\n}\n",
            )
            .write(super::LAYOUT_RUST, "        title: \"Appearance\",\n");
        views(fixture);
        fixture
    }

    #[test]
    fn a_page_crosses_whole_and_its_gate_stays_a_value() {
        let fixture = Fixture::new("settings-page");
        page(&fixture);
        assert!(super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());

        // A positional door back in the header.
        fixture.write(
            super::HEADER,
            "size_t slopdesk_settings_layout_page(uint8_t i, bool mac, uint8_t *out, size_t cap);\nsize_t \
             slopdesk_settings_layout_row_key(uint8_t g, uint8_t r);\n",
        );
        assert!(!super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());

        // The buffer drifting on one side.
        page(&fixture);
        fixture.write(
            super::LAYOUT_FFI,
            "const SWIFT_FIRST_GUESS: usize = 2048;\nfn \
             every_row_of_every_page_matches_the_table_the_index_doors_read() {}\nfn \
             every_page_fits_the_near_sides_first_guess() {}\n",
        );
        assert!(!super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());

        // The compile-time gate growing back inside `current`.
        page(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Settings/SettingsControls.swift",
            "enum Half {\n    static var current: Self {\n        #if os(macOS)\n        .mac\n\x20       \
             #else\n        .phone\n        #endif\n    }\n}\n",
        );
        assert!(!super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());

        // And a group header typed into a view.
        page(&fixture);
        fixture.write(
            "Sources/SlopDeskMacUI/Settings/MacAppearancePage.swift",
            "slateFormSection(\"Appearance\") {\n}\n",
        );
        assert!(!super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());
    }

    /// A renamed `current` leaves the `#if` ban with nothing to read. It must say so.
    #[test]
    fn a_ban_over_a_renamed_declaration_fails_rather_than_passing() {
        let fixture = Fixture::new("settings-page-renamed");
        page(&fixture);
        fixture.write(
            "Sources/SlopDeskPhoneUI/Settings/SettingsControls.swift",
            "enum Half {\n    static var whichHalf: Self { .phone }\n}\n",
        );
        assert!(!super::a_settings_page_is_shaped_once(&fixture.tree()).is_clean());
    }

    fn chords(fixture: &Fixture) -> &Fixture {
        fixture
            .write(
                super::MAC_CHORDS,
                "WorkspaceBindingRegistry KeybindingsEditorModel KeybindingCapture.outcome\n",
            )
            .write(
                super::PHONE_CHORDS,
                "WorkspaceBindingRegistry KeybindingsEditorModel PhoneKey.captureOutcome\n",
            )
            .write(
                "rust/slopdesk-ffi/src/phone_key.rs",
                "fn the_two_recorders_agree_on_every_key_both_can_name() {}\n",
            )
    }

    #[test]
    fn both_halves_record_from_one_table_and_neither_wipes_the_config() {
        let fixture = Fixture::new("settings-chords");
        chords(&fixture);
        assert!(super::one_chord_editor_drawn_twice(&fixture.tree()).is_clean());

        // The audit bug: a rebind that clears every literal-byte binding.
        fixture.write(
            super::PHONE_CHORDS,
            "WorkspaceBindingRegistry KeybindingsEditorModel PhoneKey.captureOutcome\nstore.keybindings = \
             KeybindingPreferences(overrides: next)\n",
        );
        assert!(!super::one_chord_editor_drawn_twice(&fixture.tree()).is_clean());

        // A half deciding a verdict itself.
        chords(&fixture);
        fixture.write(
            super::PHONE_CHORDS,
            "WorkspaceBindingRegistry KeybindingsEditorModel\n",
        );
        assert!(!super::one_chord_editor_drawn_twice(&fixture.tree()).is_clean());
    }
}
