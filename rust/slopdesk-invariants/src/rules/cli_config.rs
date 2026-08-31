//! What the CLI and the settings surface READ — the folder ranking, the config file's one reader,
//! the spelling of a number, and the swipe-nav operating point.
//!
//! Ported from the deleted `check-supervisor.sh`. Three of these four failed the same way before
//! they were one implementation: a validator called a line good and the loader dropped it, an env
//! overlay spelled `60` and the config text spelled `60.0`, a committed chip promised a gesture the
//! host swallowed. None of them is a crash, and each is invisible from either side alone.

use crate::claim::{Claim, RUST, SWIFT_ROOTS, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_FRECENCY: &str = "Sources/SlopDeskWorkspaceCore/Folders/FolderFrecency.swift";
const SWIFT_JUMP: &str = "Sources/SlopDeskWorkspaceCore/Folders/JumpResolver.swift";
const SWIFT_LOADER: &str = "Sources/SlopDeskVideoProtocol/Settings/KeybindConfigLoader.swift";
/// `slopdesk config`, which prints a verdict about that same file.
const RUST_CLI_CONFIG: &str = "rust/slopdesk-cli/src/shell/config.rs";
const SWIFT_ENVBRIDGE: &str = "Sources/SlopDeskVideoProtocol/Settings/EnvBridge.swift";
/// Where the swipe-nav operating point is parsed, and every question about it answered.
const SWIPE_NAV_CONFIG: &str = "rust/slopdesk-video/src/swipe_nav_config.rs";

/// The folders rank once, and a jump reads that rank
///
/// The FRECENCY ranking and the JUMP it resolves — `rust/slopdesk-workspace`'s `frecency` and
/// `jump`. One scorer rather than three sorts, because the folder rail, the open-quickly overlay,
/// the store's own cap and `slopdesk jump` all order the same set and a second ordering would rank
/// them apart. The bucket thresholds, the weights and the tie-break are what a re-implementation
/// grows back, plus the toggle branch: `--no-cd` must resolve WITHOUT advancing the source, and a
/// second copy of that rule is a preview that perturbs the toggle it was supposed to leave alone.
#[must_use]
pub fn folders_rank_once_and_a_jump_reads_it(tree: &Tree) -> Report {
    let claims = [
        Claim::Doors {
            path: SWIFT_FRECENCY,
            entries: &[
                "slopdesk_folder_weight",
                "slopdesk_folder_recency_weight",
                "slopdesk_folder_score",
                "slopdesk_folder_ranked",
            ],
            message: "FolderFrecency.swift no longer calls {entry} — the folder ordering is \
                      rust/slopdesk-workspace's",
        },
        Claim::Doors {
            path: SWIFT_JUMP,
            entries: &["slopdesk_jump_resolve"],
            message: "JumpResolver.swift no longer calls {entry} — the folder ordering is \
                      rust/slopdesk-workspace's",
        },
        Claim::NoneOf {
            paths: &[SWIFT_FRECENCY, SWIFT_JUMP],
            pattern: r"3600|86400|604_800|2_592_000|= 16$|sorted \{|lowercased\(\)\.contains",
            view: View::Code,
            message: "{files} spells a frecency threshold, weight, sort or jump match again — those live in \
                      frecency.rs and jump.rs",
        },
    ];
    check_all(tree, &claims)
}

/// The config file has one reader, and nothing in Swift re-reads its dialect
///
/// `slopdesk config validate` exists to say which of the reader's lines the app will honour, so a
/// second reader is not a duplicate — it is a validator that can call a line good and a loader that
/// then drops it. The two once disagreed on exactly one byte: the crate trimmed a carriage return
/// and the loader did not, so every binding in a CRLF file was reported valid and silently ignored.
///
/// There is no line reader on either side any more. The file is TOML, `slopdesk-settings` parses
/// it, and `AppConfig` is the ONE resolved reading both the app and `slopdesk config` see — so the
/// CRLF question is the TOML parser's and cannot be answered twice. What this rule holds is the
/// shape that made that true: `KeybindConfigLoader` takes an already-parsed `[String: String]`
/// TABLE, never a path and never file text, and it does not classify a comment, a quote or a
/// section header of its own. A loader that opened a file again would be the second reader back,
/// with the same failure mode and a new byte to disagree about.
#[must_use]
pub fn the_config_file_has_one_reader(tree: &Tree) -> Report {
    let claims =
        [
            Claim::Names {
                path: SWIFT_LOADER,
                needle: "table: [String: String]",
                message: "KeybindConfigLoader.swift stopped taking the parsed TABLE — a loader that takes a \
                          path                       or file text is the second reader of a file \
                          slopdesk-settings already read",
            },
            Claim::Lacks {
                path: SWIFT_LOADER,
                pattern: r##"hasPrefix\("#"\)|hasPrefix\("\["\)|contentsOfFile|String\(contentsOf|whereSeparator|components\(separatedBy"##,
                view: View::Code,
                message: "KeybindConfigLoader.swift reads the config dialect in Swift again — the parse, \
                          the                       comments and the quoting are slopdesk-settings' TOML \
                          reading",
            },
            Claim::Mentions {
                path: RUST_CLI_CONFIG,
                names: &["settings_path::resolve_path", "settings_path::load"],
                message: "`slopdesk config` no longer reaches the file through {entry} — a CLI that \
                          resolves the path its own way prints a verdict on a file the app does not read",
            },
        ];
    check_all(tree, &claims)
}

/// A number is spelled once, and every text door is measured once
///
/// `SLOPDESK_PLAYOUT_MS=60` and `font-size = 13` are the same question — what a user types for this
/// number — and it had two answers, one per language, differing only in the limit at which an
/// integer stops being written as one. The rule lives in `rust/slopdesk-terminal`'s `config` now,
/// taking that limit as an argument, so the env overlay and the terminal engine's config text
/// cannot drift; the limit is not a number either Swift file spells. The measure-then-fill dance
/// around every text door is the same shape, and a measure that disagrees with its fill is a
/// truncated answer — written once in `lentText` so the two calls cannot drift either.
#[must_use]
pub fn a_number_is_spelled_once(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: SWIFT_ENVBRIDGE,
            needle: "slopdesk_settings_env_number_text",
            message: "EnvBridge.swift no longer spells its env numbers through \
                      slopdesk_settings_env_number_text — that rule is config.rs's number_text",
        },
        Claim::Lacks {
            path: SWIFT_ENVBRIDGE,
            pattern: r"v\.rounded\(\)|1e15",
            view: View::Code,
            message: "EnvBridge.swift re-derives the number spelling in Swift — the integrality test and \
                      its limit belong to config.rs",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/config.rs",
            needle: "fn number_text",
            message: "rust/slopdesk-terminal/src/config.rs lost number_text — the env overlay and the \
                      config text spell a number by it",
        },
        Claim::NoneOf {
            paths: &[SWIFT_LOADER, SWIFT_ENVBRIDGE],
            pattern: "repeating: 0, count: needed",
            view: View::Code,
            message: "{files} measures a text door by hand again — lentText asks and fills so the two \
                      cannot disagree",
        },
    ];
    check_all(tree, &claims)
}

/// The swipe-nav operating point is parsed ONCE, and it is a handle
///
/// One parse of the `SLOPDESK_SWIPE_NAV*` family answers both the path that fires ⌘[/⌘] and the
/// status push that tells the client what the host will do; two parses drift, and then a committed
/// chip and its haptic promise a fire the host silently swallows. This one is a HANDLE where the
/// ledger and the accumulator are values because it carries an allowlist EXTENSION set — no fold of
/// scalars holds that — and because its owner is a process-lifetime namespace that never copies it
/// (`docs/55` §4b). Deleted with it: the Swift `SwipeNavPolicy` face and the four doors that
/// answered the allowlist, the extension list and the travel knob apart from an operating point.
///
/// ## What `docs/61` moved, and what the claim points at now
/// `SwipeNavHostConfig.swift` was the Swift half and went with the rest of the GUI host, so the
/// claim that it still asked its five doors has nothing left to name. The rule it stated survives
/// the file exactly, though, and it is a claim about `swipe_nav_config.rs`'s SHAPE rather than
/// about any caller: ONE parse of the family, and every question answered off the parsed value.
/// So the ask is re-aimed onto that module's own surface — `from_env` parses, `eligible` and
/// `eligible_window_target` answer the fire, `status` and `window_status` answer the push — and
/// each name is pinned as a `pub fn`, so an answer moved back out into a free function that reads
/// the environment for itself fails here rather than passing as a rename.
///
/// It is deliberately NOT re-aimed at `rust/slopdesk-videohostd`, and the reason is the one
/// [`crate::rules::video_host`]'s accumulators give for leaving `recovery_dedupe` out of its ask:
/// the daemon does not import this module yet — the injection half reaches it through
/// `injector_gates` — so a claim that it did would be a claim about a schedule rather than about a
/// law. The bans below hold either way.
#[must_use]
pub fn the_swipe_nav_operating_point_is_a_handle(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: SWIPE_NAV_CONFIG,
            names: &[
                "pub fn from_env",
                "pub fn eligible",
                "pub fn eligible_window_target",
                "pub fn status",
                "pub fn window_status",
            ],
            message: "swipe_nav_config.rs lost {entry} — the operating point is parsed once and every \
                      question is answered off it, so an answer that moved out of this module is a second \
                      parse of the SLOPDESK_SWIPE_NAV* family",
        },
        Claim::NoneUnder {
            roots: &["rust/slopdesk-videohostd"],
            extensions: RUST,
            pattern: r"SwipeNavStatusMessage *\{|\bfn [a-z_]*swipe_nav[a-z_]*\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon answers a swipe-nav question itself in {files} — the eligibility, the \
                      travel and the zeroing rule for an ineligible push are swipe_nav_config's, and a \
                      second answer is a committed chip promising a fire the host swallows (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: SWIFT_ROOTS,
            extensions: &["swift"],
            pattern: "SwipeNavPolicy",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} brings the Swift allowlist face back — it is swipe_nav_config's question now",
        },
        Claim::NoneUnder {
            // The FFI crate plus every Swift root: these are RETIRED door names, so a resurrection in a
            // test target or an app entry point is the same relapse as one in a shipping module. A
            // literal rather than [`crate::claim::SWIFT_ROOTS`] because the Rust half is one crate.
            roots: &["rust/slopdesk-ffi", "Sources", "Tests", "Apps"],
            extensions: &["rs", "h", "swift"],
            pattern:
                "slopdesk_swipe_is_navigable|slopdesk_swipe_extra_apps|slopdesk_swipe_fire_travel_from_env",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} answers the allowlist apart from an operating point again",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn folders(fixture: &Fixture) {
        fixture
            .write(
                super::SWIFT_FRECENCY,
                "slopdesk_folder_weight(\nslopdesk_folder_recency_weight(\nslopdesk_folder_score(\\
                 nslopdesk_folder_ranked(\n",
            )
            .write(super::SWIFT_JUMP, "slopdesk_jump_resolve(\n");
    }

    #[test]
    fn the_folder_ranking_stays_one_scorer() {
        let fixture = Fixture::new("cli-config-folders");
        folders(&fixture);
        assert!(super::folders_rank_once_and_a_jump_reads_it(&fixture.tree()).is_clean());

        fixture.write(super::SWIFT_JUMP, "");
        assert!(!super::folders_rank_once_and_a_jump_reads_it(&fixture.tree()).is_clean());

        folders(&fixture);
        fixture.append(super::SWIFT_FRECENCY, "let day = 86400\n");
        assert!(!super::folders_rank_once_and_a_jump_reads_it(&fixture.tree()).is_clean());
    }

    fn loader(fixture: &Fixture) {
        fixture
            .write(
                super::SWIFT_LOADER,
                "public static func apply(table: [String: String]) -> KeybindingPreferences {\n",
            )
            .write(
                super::RUST_CLI_CONFIG,
                "settings_path::resolve_path(explicit)\nsettings_path::load(path)\n",
            );
    }

    #[test]
    fn the_config_dialect_is_read_on_one_side() {
        let fixture = Fixture::new("cli-config-loader");
        loader(&fixture);
        assert!(super::the_config_file_has_one_reader(&fixture.tree()).is_clean());

        // The loader taking file text again instead of the parsed table.
        fixture.write(
            super::SWIFT_LOADER,
            "public static func apply(text: String) -> KeybindingPreferences {\n",
        );
        assert!(!super::the_config_file_has_one_reader(&fixture.tree()).is_clean());

        // And the dialect classified a second time, in the loader.
        loader(&fixture);
        fixture.append(super::SWIFT_LOADER, "if line.hasPrefix(\"#\") { continue }\n");
        assert!(!super::the_config_file_has_one_reader(&fixture.tree()).is_clean());

        // And the CLI resolving the path its own way.
        loader(&fixture);
        fixture.write(super::RUST_CLI_CONFIG, "");
        assert!(!super::the_config_file_has_one_reader(&fixture.tree()).is_clean());
    }

    fn numbers(fixture: &Fixture) {
        fixture
            .write(super::SWIFT_ENVBRIDGE, "slopdesk_settings_env_number_text\n")
            .write("rust/slopdesk-terminal/src/config.rs", "fn number_text\n")
            .write(super::SWIFT_LOADER, "kept so the ban has a haystack\n");
    }

    #[test]
    fn a_number_and_a_text_door_are_measured_once() {
        let fixture = Fixture::new("cli-config-numbers");
        numbers(&fixture);
        assert!(super::a_number_is_spelled_once(&fixture.tree()).is_clean());

        fixture.write("rust/slopdesk-terminal/src/config.rs", "");
        assert!(!super::a_number_is_spelled_once(&fixture.tree()).is_clean());

        // The measure-then-fill dance, re-typed at a call site.
        numbers(&fixture);
        fixture.append(
            super::SWIFT_LOADER,
            "var out = [UInt8](repeating: 0, count: needed)\n",
        );
        assert!(!super::a_number_is_spelled_once(&fixture.tree()).is_clean());
    }

    fn swipe(fixture: &Fixture) {
        fixture
            .write(
                super::SWIPE_NAV_CONFIG,
                "pub fn from_env\npub fn eligible\npub fn eligible_window_target\npub fn status\npub fn \
                 window_status\n",
            )
            .write("Tests/Placeholder.swift", "kept so the ban has a haystack\n")
            .write(
                "rust/slopdesk-videohostd/src/injection.rs",
                "kept so the ban has a haystack\n",
            )
            .write("rust/slopdesk-ffi/src/lib.rs", "kept so the ban has a haystack\n");
    }

    #[test]
    fn the_operating_point_is_parsed_in_one_place() {
        let fixture = Fixture::new("cli-config-swipe");
        swipe(&fixture);
        assert!(super::the_swipe_nav_operating_point_is_a_handle(&fixture.tree()).is_clean());

        // An answer moved out of the module that parses the operating point is a second parse of
        // the family, whatever it is renamed to on the way out.
        fixture.write(
            super::SWIPE_NAV_CONFIG,
            "pub fn from_env\npub fn eligible\npub fn eligible_window_target\npub fn status\n",
        );
        assert!(!super::the_swipe_nav_operating_point_is_a_handle(&fixture.tree()).is_clean());

        // The host answering the push for itself, in the language it is written in now: the zeroing
        // rule for an ineligible status is the module's, and a second one promises a fire.
        swipe(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/injection.rs",
            "let push = SwipeNavStatusMessage { eligible: true, travel: 0.0 };\n",
        );
        assert!(!super::the_swipe_nav_operating_point_is_a_handle(&fixture.tree()).is_clean());

        // The deleted Swift face, back under any path.
        swipe(&fixture);
        fixture.append("Tests/Placeholder.swift", "SwipeNavPolicy.shared\n");
        assert!(!super::the_swipe_nav_operating_point_is_a_handle(&fixture.tree()).is_clean());

        // And a door that answers the allowlist apart from an operating point.
        swipe(&fixture);
        fixture.append("rust/slopdesk-ffi/src/lib.rs", "slopdesk_swipe_extra_apps\n");
        assert!(!super::the_swipe_nav_operating_point_is_a_handle(&fixture.tree()).is_clean());
    }
}
