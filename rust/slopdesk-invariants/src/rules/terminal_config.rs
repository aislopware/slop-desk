//! The terminal's configuration surface — the keybind grammar, the config emitter, the named-key
//! table, the reset backstop, the pane directory, and the two tables a search crosses.
//!
//! Ported from the deleted `check-supervisor.sh`. A second speller here does not crash: it produces
//! a chord that cannot be typed, a config the far side drops a line of, or a search that ranks the
//! same table two ways depending on which field asked.

use crate::claim::{Claim, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// One keybind grammar, and the CLI no longer asks Swift for it
///
/// `config validate` used to hand the crate a C function pointer BACK into Swift, once per line, so
/// the validator's verdict would track the grammar the app honours. The grammar is Rust now, so
/// both ends of that round trip are the same side of the door — and the callback must not come
/// back, or the two would be free to disagree again. The escape vocabulary and the base-key
/// vocabulary stay out of Swift for the same reason: a `\xNN` that decodes differently on either
/// side puts bytes on a pane the user never wrote.
#[must_use]
pub fn one_keybind_grammar_no_callback(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift",
            names: &["slopdesk_keybind_parse_line", "slopdesk_keybind_is_valid"],
            message: "Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift no longer parses through \
                      {entry} — that grammar is rust/slopdesk-terminal's keybind",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift"],
            pattern: r#"func literalBytes|func isValidBaseKey|func hexNibble|"pageup"|case "cmd""#,
            view: View::Code,
            message: "{files} re-derives the keybind grammar — keybind.rs owns the escapes and the \
                      vocabularies",
        },
        Claim::NoneOf {
            paths: &[
                "rust/slopdesk-cli/src/shell/config.rs",
                "rust/slopdesk-ffi/include/slopdesk_ffi.h",
            ],
            pattern: r"SlopDeskKeybindValidFn|isValidKeybindValue",
            view: View::Code,
            message: "{files} asks Swift whether a keybind parses — the crate holds that grammar itself now",
        },
    ];
    check_all(tree, &claims)
}

/// One terminal config emitter, and Swift keeps only the enums it persists
///
/// The libghostty config text is a stable ORDER of `key = value` lines, and the order is
/// load-bearing: `background` after `theme` is what makes the explicit colour win, the palette
/// after `foreground` is what makes the theme's sixteen entries win over both, and `font-feature`
/// rides EVERY build because a font that ships ligatures turns them on itself. A second emitter
/// would not fail a test — it would quietly hand libghostty a different terminal. So the tokens,
/// the validation and the number formatting stay in `rust/slopdesk-terminal`'s `config`, and this
/// side crosses the RAW VALUES it persists.
#[must_use]
pub fn one_terminal_config_emitter_swift(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift",
            needle: "slopdesk_terminal_config_string",
            message: "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift no longer builds \
                      through slopdesk_terminal_config_string — that emitter is rust/slopdesk-terminal's \
                      config",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift",
                "Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift",
            ],
            pattern: r"font-family = |font-feature = |scrollback-limit = |selection-foreground|window-padding-balance",
            view: View::Code,
            message: "{files} spells a libghostty config line in Swift — config.rs decides which key a \
                      preference actuates",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift"],
            pattern: r"func isValidHex|func formatSize|func fallbackFamilies|bytesPerScrollbackLine|clampCellHeightPercent",
            view: View::Code,
            message: "{files} re-derives a config rule the crate owns — hex validity, number spelling and \
                      the clamp are config.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift"],
            pattern: r"baseFeatures|syntheticTokens|disablesFace|var thickens",
            view: View::Code,
            message: "{files} maps a font preference to a libghostty token in Swift — the enum crosses as \
                      its RAW value",
        },
    ];
    check_all(tree, &claims)
}

/// One named-key table: what a chord may be SPELLED, and what it is STORED as
///
/// The grammar decides which spellings a `keybind` line may use; the near side decides which one
/// each folds to. Those are two halves of one table, and they were kept in step by hand in three
/// places — so `space`, which the dispatcher produces (⌃⇧Space enters Vi mode) and `mapKey`
/// resolves, was refused by the grammar outright: a chord the app can deliver that no config file
/// could ask for. The rows live in `NAMED_KEYS` now, `is_valid_base_key` and `canonical_base_key`
/// are both read off them, and the near side folds through the door rather than restating the
/// aliases.
#[must_use]
pub fn one_named_key_table_what(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            names: &[
                "slopdesk_keybind_canonical_key",
                "slopdesk_keybind_canonical_chord",
            ],
            message: "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift no longer folds \
                      through {entry} — that table is keybind.rs's NAMED_KEYS",
        },
        Claim::NoneOf {
            paths: &[
                "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift",
            ],
            pattern: r"pgup|pgdn|leftarrow|rightarrow|uparrow|downarrow",
            view: View::Code,
            message: "{files} spells an alias key in Swift — a chord arrives already folded, so a second \
                      table can only drift",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/keybind.rs",
            needle: "const NAMED_KEYS",
            message: "rust/slopdesk-terminal/src/keybind.rs lost NAMED_KEYS — the accepted spellings and \
                      the stored one are one table",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/keybind.rs",
            needle: "(\"space\", \"space\")",
            message: "rust/slopdesk-terminal/src/keybind.rs stopped accepting space — the dispatcher \
                      produces it, so no config line could ask for a chord the app delivers",
        },
    ];
    check_all(tree, &claims)
}

/// The reset backstop is built from the set the strip pass reads
///
/// The suffix is appended by a restore the passes did NOT run on, which is exactly when a mode
/// they track must still be turned off. All fourteen were spelled out on the near side, with
/// nothing connecting that literal to `TRACKED_MODES` — so a mode added to the pass would have gone
/// missing from the backstop that exists to catch what the pass missed.
///
/// The near side is `rust/slopdesk-hostd`'s transcript restore since `docs/60` F.9, and it now
/// CALLS `reset_suffix`, so the fourteen-row equality is the compiler's. What is left is the pair
/// no import can state: that the call is still made, and that nobody re-acquires a mode by typing
/// its escape.
#[must_use]
pub fn reset_backstop_built_from_set(tree: &Tree) -> Report {
    /// hostd's transcript restore, the one caller that appends the suffix.
    const TRANSCRIPTS: &str = "rust/slopdesk-hostd/src/transcripts.rs";

    let claims = [
        Claim::Matches {
            path: TRANSCRIPTS,
            pattern: r"slopdesk_sanitize::inputmode::reset_suffix\(",
            view: View::Code,
            message: "rust/slopdesk-hostd/src/transcripts.rs no longer builds the reset from inputmode.rs's \
                      TRACKED_MODES — a restore that skips it leaves a mode the passes never saw turned on",
        },
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r"\?1000l|\?2004l|\?2048l",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} names a tracked mode by its escape — the backstop and the pass read one \
                      array, and a hand-typed mode is one the pass will never turn off",
        },
        Claim::Names {
            path: "rust/slopdesk-sanitize/src/inputmode.rs",
            needle: "pub fn reset_suffix",
            message: "rust/slopdesk-sanitize/src/inputmode.rs lost reset_suffix — the backstop is built, \
                      not written",
        },
    ];
    check_all(tree, &claims)
}

/// One rule for what a pane's DIRECTORY is, and what it is called
///
/// `looksLikeTransientPluginCwd` guards fourteen Swift call sites — every sink that can poison the
/// directory a split or a relaunch inherits — and `looks_like_transient_plugin_cwd` guards the Rust
/// `tab_ordering` that sorts the same panes into project sections. Both were live, in both
/// languages, neither reading the other: the sinks and the ordering could disagree about which
/// directory is poison, and a sidebar row could disagree with its own section header about a
/// folder's name.
#[must_use]
pub fn one_rule_for_pane_directory(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift"],
            pattern: r#"contains\("---"\)|hasSuffix\("/"\)|split\(separator: "/"\)\.last"#,
            view: View::Code,
            message: "{files} classifies a cwd in Swift again — slopdesk-workspace::PaneSpec owns both rules",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift",
            names: &["slopdesk_ws_transient_plugin_cwd", "slopdesk_ws_cwd_display_name"],
            message: "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift no longer asks {entry} — the cwd \
                      rules are one implementation",
        },
    ];
    check_all(tree, &claims)
}

/// One key vocabulary, on the CLIENT's send-keys too
///
/// The existing "One key vocabulary" block pins the HOST's face (`ControlKeyMap.swift`). The
/// client's `pane send-keys` had a second table of its own — nine names — and every other name the
/// vocabulary knows fell through it into a `nil` the caller dropped while still answering success,
/// so `--key f5` reported a keystroke delivered to a pane that received nothing. Same door, same
/// ban on spelling a sequence, plus the refusal being answerable: a `Bool` here cannot say "that is
/// not a key" without borrowing "pane not found".
#[must_use]
pub fn client_send_keys_asks_one(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift",
            needle: "slopdesk_ws_key_token",
            message: "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift answers a key name \
                      again — the vocabulary is send_keys.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift"],
            pattern: r#"0x1B, 0x5B|case "enter"|case "pageup"|& 0x1F"#,
            view: View::Code,
            message: "{files} spells a key sequence again — a second table is how the client lost f5 and \
                      pgup",
        },
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift",
            needle: "unknownKey",
            message: "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift swallowed the \
                      refusal again — an unrecognised key must fail the request",
        },
    ];
    check_all(tree, &claims)
}

/// A config action name resolves once, and `goto_tab` is bounded on BOTH halves of the line
///
/// The name table and the `goto_tab` bound were written in Swift and in Rust, and they disagreed:
/// the Swift bounded the argument to 1…9 (there are nine per-digit bindings), the grammar accepted
/// any integer, so `cmd+1:goto_tab:99` validated in the keybinding editor and then resolved to
/// nothing. Both halves hold the bound now — the grammar so the line does not validate, the
/// resolver so nothing unbindable reaches the registry — and the nine ids are the resolver's list,
/// so the bound and the table it guards cannot drift apart.
#[must_use]
pub fn one_config_name_table_goto(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift",
            needle: "slopdesk_ws_binding_id_for_config_name",
            message: "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift \
                      resolves a config name in Swift again — that table is keybind.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift"],
            pattern: r#""new_tab": "|"pane\.select\.\\\(|\(1\.\.\.9\)\.contains"#,
            view: View::Code,
            message: "{files} spells a config name, a binding id or the goto_tab bound again — all three \
                      are Rust's",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/keybind.rs",
            needle: "Ok(1..=9)",
            message: "rust/slopdesk-terminal/src/keybind.rs stopped bounding goto_tab — a line that cannot \
                      fire must not validate",
        },
        Claim::Names {
            path: "rust/slopdesk-workspace/src/keybind.rs",
            needle: "SELECT_PANE_BINDING_IDS: [&str; 9]",
            message: "rust/slopdesk-workspace/src/keybind.rs no longer bounds goto_tab by its own row list \
                      — the list IS the bound",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_keybind_grammar_no_callback(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift",
                "slopdesk_keybind_parse_line\nslopdesk_keybind_is_valid\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-cli/src/shell/config.rs",
                "kept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-ffi/include/slopdesk_ffi.h",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_keybind_grammar_no_callback_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-keybind-grammar-no-callback");
        write_one_keybind_grammar_no_callback(&fixture);
        assert!(super::one_keybind_grammar_no_callback(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift", "");
        assert!(!super::one_keybind_grammar_no_callback(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_keybind_grammar_no_callback(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoProtocol/Settings/KeybindGrammar.swift",
            "func literalBytes\n",
        );
        assert!(!super::one_keybind_grammar_no_callback(&fixture.tree()).is_clean());
    }

    fn write_one_terminal_config_emitter_swift(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift",
                "slopdesk_terminal_config_string\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/TerminalFontSettings.swift",
                "kept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_terminal_config_emitter_swift_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-terminal-config-emitter-swift");
        write_one_terminal_config_emitter_swift(&fixture);
        assert!(super::one_terminal_config_emitter_swift(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift",
            "",
        );
        assert!(!super::one_terminal_config_emitter_swift(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_terminal_config_emitter_swift(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift",
            "font-family = \n",
        );
        assert!(!super::one_terminal_config_emitter_swift(&fixture.tree()).is_clean());
    }

    fn write_one_named_key_table_what(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
                "slopdesk_keybind_canonical_key\nslopdesk_keybind_canonical_chord\nkept so the ban has a \
                 haystack\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceBindingOverrides.swift",
                "kept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/src/keybind.rs",
                "const NAMED_KEYS\n(\"space\", \"space\")\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_named_key_table_what_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-named-key-table-what");
        write_one_named_key_table_what(&fixture);
        assert!(super::one_named_key_table_what(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            "",
        );
        assert!(!super::one_named_key_table_what(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_named_key_table_what(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoProtocol/Settings/KeybindingPreferences.swift",
            "pgup\n",
        );
        assert!(!super::one_named_key_table_what(&fixture.tree()).is_clean());
    }

    fn write_reset_backstop_built_from_set(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-hostd/src/transcripts.rs",
                "bytes.extend_from_slice(&slopdesk_sanitize::inputmode::reset_suffix());\n",
            )
            .write(
                "rust/slopdesk-sanitize/src/inputmode.rs",
                "pub fn reset_suffix\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn reset_backstop_built_from_set_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("reset-backstop-built-from-set");
        write_reset_backstop_built_from_set(&fixture);
        assert!(super::reset_backstop_built_from_set(&fixture.tree()).is_clean());

        // The caller stopped asking — a restore that appends nothing leaves the modes on.
        fixture.write("rust/slopdesk-hostd/src/transcripts.rs", "");
        assert!(!super::reset_backstop_built_from_set(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled — in any host crate, not just the
        // one that holds the call.
        write_reset_backstop_built_from_set(&fixture);
        fixture.write(
            "rust/slopdesk-hostserver/src/restore.rs",
            "const SUFFIX: &[u8] = b\"\\x1b[?1000l\";\n",
        );
        assert!(!super::reset_backstop_built_from_set(&fixture.tree()).is_clean());
    }

    fn write_one_rule_for_pane_directory(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift",
            "slopdesk_ws_transient_plugin_cwd\nslopdesk_ws_cwd_display_name\nkept so the ban has a \
             haystack\n",
        );
    }

    #[test]
    fn one_rule_for_pane_directory_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-rule-for-pane-directory");
        write_one_rule_for_pane_directory(&fixture);
        assert!(super::one_rule_for_pane_directory(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift", "");
        assert!(!super::one_rule_for_pane_directory(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_rule_for_pane_directory(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift",
            "contains(\"---\")\n",
        );
        assert!(!super::one_rule_for_pane_directory(&fixture.tree()).is_clean());
    }

    fn write_client_send_keys_asks_one(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift",
            "slopdesk_ws_key_token\nunknownKey\nkept so the ban has a haystack\n",
        );
    }

    #[test]
    fn client_send_keys_asks_one_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("client-send-keys-asks-one");
        write_client_send_keys_asks_one(&fixture);
        assert!(super::client_send_keys_asks_one(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift",
            "",
        );
        assert!(!super::client_send_keys_asks_one(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_client_send_keys_asks_one(&fixture);
        fixture.append(
            "Sources/SlopDeskClientCore/Control/WorkspaceControlBackend.swift",
            "0x1B, 0x5B\n",
        );
        assert!(!super::client_send_keys_asks_one(&fixture.tree()).is_clean());
    }

    fn write_one_config_name_table_goto(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift",
                "slopdesk_ws_binding_id_for_config_name\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/src/keybind.rs",
                "Ok(1..=9)\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-workspace/src/keybind.rs",
                "SELECT_PANE_BINDING_IDS: [&str; 9]\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_config_name_table_goto_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-config-name-table-goto");
        write_one_config_name_table_goto(&fixture);
        assert!(super::one_config_name_table_goto(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift",
            "",
        );
        assert!(!super::one_config_name_table_goto(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_config_name_table_goto(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/WorkspaceActionConfigNames.swift",
            "\"new_tab\": \"\n",
        );
        assert!(!super::one_config_name_table_goto(&fixture.tree()).is_clean());
    }
}
