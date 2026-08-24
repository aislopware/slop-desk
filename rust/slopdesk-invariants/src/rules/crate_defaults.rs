//! Tables the crate owns, and the Swift faces that must keep asking for them.
//!
//! Ported from the deleted `check-supervisor.sh`. Every rule here guards the same regression: a
//! value the crate produces, spelled out again on the Swift side. Nothing fails when the two agree,
//! and nothing fails when they stop — the host encodes at the old operating point, the fresh pane
//! is born with a name the crate no longer mints, and the test that "checks" it compares against
//! the literal rather than the answer. So the pin is on the CALL, and on the literal not growing
//! back.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// Where the three seeded names are minted.
const TREE_WORKSPACE: &str = "Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift";
/// The target whose two encoder faces ask for their tuned defaults.
const VIDEO_HOST: &str = "Sources/SlopDeskVideoHost/";
/// The face whose `Config` fields are seeded from a door.
const IDR_FACE: &str = "Sources/SlopDeskVideoHost/RecoveryIDRPolicy.swift";
/// The face whose env fallbacks are the door's answer, never a digit.
const QP_FACE: &str = "Sources/SlopDeskVideoHost/QPController.swift";
/// The reader that turned one crossing back into eight.
const CATALOG: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift";
/// The builder whose relabelling is quadratic if asked per row.
const RAIL: &str = "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift";
/// The host performer that used to hold a second `:line[:col]` splitter.
const CODE_OPEN: &str = "Sources/SlopDeskHost/HostCodeServerPerformer.swift";

/// The three seeded names are the crate's, and Swift asks for them
///
/// `TreeWorkspaceDefaults` has existed for a while and its own doc names the failure: a copy of
/// either literal on the Swift side is a second answer to "what is a fresh pane called", and the
/// fresh-workspace SHAPE TEST comparing against a spelled-out `"Terminal"` would go on passing
/// against a default the crate had stopped producing. The face was built and the callers were never
/// moved; this is what stops them drifting back.
///
/// This is a BAN, so an empty result passes it — which is exactly what a renamed file would
/// produce. The corpus is therefore asserted to EXIST first, one `Exists` per member, the way every
/// ban list in this crate is floored.
///
/// Reads CODE, because the prose around these call sites quotes the words on purpose.
///
/// `PaneChooserRegistry` is deliberately NOT in the corpus. Its `"Terminal"`/`"Desktop"` are the
/// CHOOSER's labels for a pane kind — a vocabulary a Swift `switch` reads, which `docs/55` §6
/// leaves in Swift — not the title a minted pane is born with. They are the same word today for the
/// same reason a folder and its icon share a name, and nothing breaks if the seeded title is
/// renamed and the menu entry is not.
#[must_use]
pub fn the_seeded_names_are_the_crates(tree: &Tree) -> Report {
    /// The five files that mint or persist a fresh pane.
    const CORPUS: &[&str] = &[
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift",
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Desktop.swift",
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
        "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Templates.swift",
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift",
    ];
    /// The three names, each as the quoted literal a regrowth would spell.
    const SEEDED: &[&str] = &[r#""Terminal""#, r#""Desktop""#, r#""Local""#];
    /// The three faces that mint them.
    const FACES: &[&str] = &[
        r"static let paneTitle = wsString",
        r"static let sessionName = wsString",
        r"static let desktopPaneTitle = wsString",
    ];

    let mut claims: Vec<Claim> = CORPUS
        .iter()
        .map(|path| {
            Claim::Exists {
                path,
                message: "the seeded-name ban reads an empty corpus, which passes it (docs/55 §8)",
            }
        })
        .collect();
    for seeded in SEEDED {
        claims.push(Claim::NoneOf {
            paths: CORPUS,
            pattern: seeded,
            view: View::Code,
            message: "a seeded name is spelled in Swift again ({files}) — ask TreeWorkspaceDefaults \
                      (docs/55 §8)",
        });
    }
    for face in FACES {
        claims.push(Claim::Matches {
            path: TREE_WORKSPACE,
            pattern: face,
            view: View::Raw,
            message: "TreeWorkspaceDefaults lost one of its three faces — the seeded names would go back to \
                      being literals",
        });
    }
    check_all(tree, &claims)
}

/// The tuned encoder defaults are Rust's, and the host asks for them
///
/// Eleven numbers — four quantiser knobs, seven recovery-keyframe ones — used to be spelled in both
/// `qp_control.rs`/`recovery_idr.rs` and their Swift faces. Nothing failed when they agreed and
/// nothing would have failed when they stopped: the host would simply encode at the old operating
/// point, or grant keyframes on the old bucket, with no build error and no failing test. The two
/// `*_config_default` doors put the table on one side; this stops the literals growing back.
///
/// Two bans, each the exact shape the regrowth takes on its own side. A `var` in the IDR config
/// carrying its own literal wins silently, because the struct's fields are seeded from the door in
/// `init()` and a default on the declaration is applied first. On the quantiser side the same thing
/// arrives as an env fallback typed as a digit rather than read from the door's answer.
#[must_use]
pub fn the_encoder_defaults_are_the_crates(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::MentionsUnder {
            root: VIDEO_HOST,
            names: &["slopdesk_qp_config_default", "slopdesk_idr_config_default"],
            message: "{entry} lost its caller — the tuned defaults are spelled Swift-side again (docs/55 §8)",
        },
        Claim::Lacks {
            path: IDR_FACE,
            pattern: r"^ *public var [a-zA-Z]+: (Double|Int) = ",
            view: View::Raw,
            message: "RecoveryIDRPolicy put literal defaults back on Config's fields — they come from \
                      slopdesk_idr_config_default()",
        },
        Claim::Lacks {
            path: QP_FACE,
            pattern: r#"envInt\("SLOPDESK_QP_[A-Z_]+", [0-9]"#,
            view: View::Raw,
            message: "QPController typed a quantiser default back in — the fallback is \
                      slopdesk_qp_config_default()'s",
        },
    ])
}

/// A settings row crosses whole, not field by field
///
/// `slopdesk_ffi::settings_rows`' own header argues the principle for the MATCH — positions rather
/// than rows, so a filter is one crossing and not one per field per row — and the reader then
/// turned each position back into eight calls, on every settings-search keystroke.
/// `slopdesk_settings_row_fields` is that argument applied one level out, and this stops
/// `entry(at:)` sliding back to the field doors.
///
/// The seven doors banned below were DELETED on 2026-08-22, so the ban names symbols that do not
/// exist — deliberately. `ffi-doors-are-opened` is what found them exported and uncalled, and the
/// reason they could never acquire a caller was this ban; keeping it outliving them stops the next
/// reader from re-declaring one as the obvious fix for a one-field question.
///
/// THREE field doors stay, and only three, because three callers really do want one field: the key
/// lookup, the shown gate, and the reset walk over `persistence`. Each asks a question about a row
/// it is not otherwise reading, so routing it through the whole-row door would decode seven fields
/// to use one. The other seven had no such caller left, which is why they are gone rather than kept
/// "for symmetry" — `docs/55` §8: an unreached port is worse than an unported one.
///
/// Scoped to `entry(at:)` rather than the file, which is the whole point: the key door is spelled
/// in the same file, legitimately, by the caller that wants exactly one field.
#[must_use]
pub fn a_settings_row_crosses_whole(tree: &Tree) -> Report {
    /// The seven doors that a whole-row crossing replaced.
    const FIELD_DOORS: &[&str] = &[
        "slopdesk_settings_row_label",
        "slopdesk_settings_row_page_label",
        "slopdesk_settings_row_description",
        "slopdesk_settings_row_default_text",
        "slopdesk_settings_row_target_section",
        "slopdesk_settings_row_keywords",
        "slopdesk_settings_row_bucket",
    ];

    let mut claims: Vec<Claim> = FIELD_DOORS
        .iter()
        .map(|door| {
            Claim::LacksWithin {
                path: CATALOG,
                start: r"private static func entry\(at index: Int\)",
                end: r"^    \}",
                pattern: door,
                view: View::Raw,
                message: "entry(at:) went back to a field door — a row crosses whole \
                          (slopdesk_settings_row_fields)",
            }
        })
        .collect();
    claims.push(Claim::Matches {
        path: CATALOG,
        pattern: r"slopdesk_settings_row_fields",
        view: View::Raw,
        message: "the settings catalog stopped calling slopdesk_settings_row_fields — reading a row costs 8 \
                  crossings again",
    });
    claims.push(Claim::Matches {
        path: CATALOG,
        pattern: r"slopdesk_settings_row_key",
        view: View::Raw,
        message: "the settings catalog lost the single-field key door — a key lookup should not decode a \
                  whole row",
    });
    check_all(tree, &claims)
}

/// A rail relabelling crosses once, not once per row
///
/// The collision rule needs the WHOLE list in hand to answer for any one member, so asking per
/// index meant rebuilding the label array and every title's bytes `n` times to answer `n` questions
/// off one input — quadratic in marshalling, on a list rebuilt whenever anything in it ticks.
///
/// The per-index door was DELETED on 2026-08-22, so the first arm bans a symbol that does not exist
/// — deliberately, for the reason `entry(at:)`'s seven are still banned. The ban outliving the door
/// is what keeps the next reader from re-declaring it as the obvious fix for a one-row question.
#[must_use]
pub fn a_rail_relabelling_crosses_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Lacks {
            path: RAIL,
            pattern: r"slopdesk_ws_rail_disambiguated_label\(",
            view: View::Raw,
            message: "the rail builder asks for a per-index label door — there is none, and there is none \
                      because a collision is a fact about the whole list: ask \
                      slopdesk_ws_rail_disambiguated_labels and read the member you want",
        },
        Claim::Matches {
            path: RAIL,
            pattern: r"slopdesk_ws_rail_disambiguated_labels\(",
            view: View::Raw,
            message: "the rail builder stopped calling slopdesk_ws_rail_disambiguated_labels — the \
                      relabelling is quadratic again",
        },
    ])
}

/// The open target splits once, and the crate owns where
///
/// `HostCodeServerPerformer.splitLineColSuffix` used to be a second `:line[:col]` splitter beside
/// `slopdesk-terminal`'s, and the two had already answered differently for a target that is ALL
/// suffix (`":12"`): Swift called it a suffix with an empty path, the crate calls it no suffix at
/// all. Three host call sites read that split — the existence check, the workbench CLI target, and
/// the code-server window routing — so a second splitter growing back here means the path the host
/// stats and the path the extension opens can disagree by a colon.
///
/// The ban is on the SCAN's three tells rather than on the function name, because the name is the
/// one thing a reimplementation is free to change.
#[must_use]
pub fn the_open_target_splits_once(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::Matches {
            path: CODE_OPEN,
            pattern: r"slopdesk_link_line_col_suffix",
            view: View::Code,
            message: "the host splits a line:col suffix in Swift again — that rule is link_action.rs's",
        },
        Claim::Lacks {
            path: CODE_OPEN,
            pattern: r"isNumber|runStart|sawDigit",
            view: View::Code,
            message: "the host re-derives the suffix scan — the crate answers it, and the path is the \
                      remainder",
        },
    ])
}

/// A ring wraps through the one ring rule
///
/// `(i ± 1 + n) % n` was hand-rolled in three places beside `slopdesk_list_wrapped_index`, which
/// the picker's filter pills already ask. Each copy is one `% 0` away from a trap on an empty list,
/// and the door is the only spelling that answers "there is nothing to step from" instead.
#[must_use]
pub fn a_ring_wraps_through_one_rule(tree: &Tree) -> Report {
    /// The two files that used to step their own ring.
    const RINGS: &[&str] = &[
        "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSwitcher.swift",
        "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift",
    ];

    let claims: Vec<Claim> = RINGS
        .iter()
        .map(|ring| {
            Claim::Lacks {
                path: ring,
                pattern: r"\+ count\) %|\+ matches\.count\) %|\+ candidates\.count\) %",
                view: View::Code,
                message: "a ring wrap is hand-rolled again — ListNavigation.wrappedIndex is the one ring \
                          step, and the only spelling that survives an empty list",
            }
        })
        .collect();
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    /// The five-file corpus, clean, beside the three faces that mint the names.
    fn seeded(fixture: &Fixture) {
        for path in [
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspacePersistence.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Desktop.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Templates.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift",
        ] {
            fixture.write(path, "let title = TreeWorkspaceDefaults.paneTitle\n");
        }
        fixture.write(
            super::TREE_WORKSPACE,
            "static let paneTitle = wsString(slopdesk_ws_default_pane_title)\nstatic let sessionName = \
             wsString(slopdesk_ws_default_session_name)\nstatic let desktopPaneTitle = \
             wsString(slopdesk_ws_default_desktop_title)\n",
        );
    }

    #[test]
    fn a_seeded_name_spelled_in_swift_is_red() {
        let fixture = Fixture::new("defaults-seeded");
        seeded(&fixture);
        assert!(super::the_seeded_names_are_the_crates(&fixture.tree()).is_clean());

        // The prose around these call sites quotes the words on purpose, so a comment is not a
        // second answer to "what is a fresh pane called".
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
            "// The seeded name is \"Terminal\", which the crate mints.\nlet title = \
             TreeWorkspaceDefaults.paneTitle\n",
        );
        assert!(super::the_seeded_names_are_the_crates(&fixture.tree()).is_clean());

        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
            "let title = \"Terminal\"\n",
        );
        assert!(!super::the_seeded_names_are_the_crates(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_renamed_corpus_member_is_red() {
        // A ban over four files where five were meant reads clean, which is how this gate dies
        // quietly — so the corpus is floored by name, in its own fixture because writes accumulate.
        let fixture = Fixture::new("defaults-seeded-gone");
        for path in [
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Desktop.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Bootstrap.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Templates.swift",
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/SessionTemplateEngine.swift",
        ] {
            fixture.write(path, "let title = TreeWorkspaceDefaults.paneTitle\n");
        }
        fixture.write(
            super::TREE_WORKSPACE,
            "static let paneTitle = wsString(slopdesk_ws_default_pane_title)\nstatic let sessionName = \
             wsString(slopdesk_ws_default_session_name)\nstatic let desktopPaneTitle = \
             wsString(slopdesk_ws_default_desktop_title)\n",
        );
        assert!(!super::the_seeded_names_are_the_crates(&fixture.tree()).is_clean());
    }

    /// Both faces asking their door, neither carrying a literal.
    fn encoders(fixture: &Fixture) {
        fixture
            .write(
                super::QP_FACE,
                "let d = slopdesk_qp_config_default()\nlet floor = envInt(\"SLOPDESK_QP_FLOOR\", d.floor)\n",
            )
            .write(
                super::IDR_FACE,
                "public struct Config {\n\x20   public var window: Double\n\x20   init() { self = \
                 slopdesk_idr_config_default() }\n}\n",
            );
    }

    #[test]
    fn a_tuned_default_typed_back_in_is_red() {
        let fixture = Fixture::new("defaults-encoder");
        encoders(&fixture);
        assert!(super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // A default on the declaration is applied before init() reads the door, so it wins silently.
        fixture.write(
            super::IDR_FACE,
            "public struct Config {\n\x20   public var window: Double = 2.5\n\x20   init() { self = \
             slopdesk_idr_config_default() }\n}\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // Same regression on the quantiser side, arriving as an env fallback typed as a digit.
        encoders(&fixture);
        fixture.write(
            super::QP_FACE,
            "let d = slopdesk_qp_config_default()\nlet floor = envInt(\"SLOPDESK_QP_FLOOR\", 38)\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // And the door losing its only caller in the target.
        encoders(&fixture);
        fixture.write(
            super::IDR_FACE,
            "public struct Config {\n\x20   public var window: Double\n}\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_row_read_field_by_field_is_red() {
        let fixture = Fixture::new("defaults-rowfields");
        fixture.write(
            super::CATALOG,
            "    private static func entry(at index: Int) -> SettingEntry {\n\x20       let fields = \
             slopdesk_settings_row_fields(index)\n\x20       return SettingEntry(fields)\n\x20   }\n\x20   \
             static func key(at index: Int) -> String { slopdesk_settings_row_key(index) }\n",
        );
        assert!(super::a_settings_row_crosses_whole(&fixture.tree()).is_clean());

        // The key door is spelled in the same file, legitimately, which is why the ban is scoped to
        // entry(at:) rather than the file.
        fixture.write(
            super::CATALOG,
            "    private static func entry(at index: Int) -> SettingEntry {\n\x20       let label = \
             slopdesk_settings_row_label(index)\n\x20       let fields = \
             slopdesk_settings_row_fields(index)\n\x20       return SettingEntry(label, fields)\n\x20   \
             }\n\x20   static func key(at index: Int) -> String { slopdesk_settings_row_key(index) }\n",
        );
        assert!(!super::a_settings_row_crosses_whole(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_per_index_rail_label_is_red() {
        let fixture = Fixture::new("defaults-rail");
        fixture.write(
            super::RAIL,
            "let labels = slopdesk_ws_rail_disambiguated_labels(titles)\n",
        );
        assert!(super::a_rail_relabelling_crosses_once(&fixture.tree()).is_clean());

        fixture.write(
            super::RAIL,
            "let label = slopdesk_ws_rail_disambiguated_label(index)\n",
        );
        assert!(!super::a_rail_relabelling_crosses_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_second_line_col_splitter_is_red() {
        let fixture = Fixture::new("defaults-linecol");
        fixture.write(
            super::CODE_OPEN,
            "let split = slopdesk_link_line_col_suffix(target)\n",
        );
        assert!(super::the_open_target_splits_once(&fixture.tree()).is_clean());

        fixture.write(
            super::CODE_OPEN,
            "var runStart = target.endIndex\nwhile c.isNumber { }\n",
        );
        assert!(!super::the_open_target_splits_once(&fixture.tree()).is_clean());
    }

    #[test]
    fn a_hand_rolled_ring_wrap_is_red() {
        let fixture = Fixture::new("defaults-ring");
        for ring in [
            "Sources/SlopDeskWorkspaceCore/Workspace/Domain/PaneSwitcher.swift",
            "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift",
        ] {
            fixture.write(
                ring,
                "let next = ListNavigation.wrappedIndex(i, by: 1, count: n)\n",
            );
        }
        assert!(super::a_ring_wraps_through_one_rule(&fixture.tree()).is_clean());

        // One `% 0` away from a trap on an empty list.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift",
            "let next = (i + 1 + matches.count) % matches.count\n",
        );
        assert!(!super::a_ring_wraps_through_one_rule(&fixture.tree()).is_clean());
    }
}
