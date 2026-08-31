//! Tables the crate owns, and the Swift faces that must keep asking for them.
//!
//! Ported from the deleted `check-supervisor.sh`. Every rule here guards the same regression: a
//! value the crate produces, spelled out again on the Swift side. Nothing fails when the two agree,
//! and nothing fails when they stop — the host encodes at the old operating point, the fresh pane
//! is born with a name the crate no longer mints, and the test that "checks" it compares against
//! the literal rather than the answer. So the pin is on the CALL, and on the literal not growing
//! back.

use crate::claim::{Claim, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// Where the three seeded names are minted.
const TREE_WORKSPACE: &str = "Sources/SlopDeskWorkspaceModel/Domain/Tree/TreeWorkspace.swift";
/// The GUI video host, which asks for its tuned defaults rather than seeding them.
///
/// A DIRECTORY rather than a file, the way [`crate::rules::video_host`] argues for: the daemon's
/// modules are still being split, and this rule is about the host asking, not about which of its
/// files does the asking.
const DAEMON: &str = "rust/slopdesk-videohostd";
/// The builder whose relabelling is quadratic if asked per row.
const RAIL: &str = "Sources/SlopDeskClientCore/Rail/RailRowsBuilder.swift";
/// The host performer that used to hold a second `:line[:col]` splitter.
/// The two host call sites that split an open target: the code action performer and the bridge
/// server, which routes the same target to a code-server window.
const CODE_OPENERS: [&str; 2] = [
    "rust/slopdesk-hostserver/src/codeaction.rs",
    "rust/slopdesk-hostserver/src/bridge.rs",
];

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
        "Sources/SlopDeskWorkspaceModel/Domain/SessionTemplateEngine.swift",
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
            message: "TreeWorkspaceDefaults lost one of its three faces — the seeded names would go back to \
                      being literals",
        });
    }
    check_all(tree, &claims)
}

/// The tuned encoder defaults are the crate's, and the host asks for them
///
/// Eleven numbers — four quantiser knobs, seven recovery-keyframe ones — used to be spelled in both
/// `qp_control.rs`/`recovery_idr.rs` and their Swift faces. Nothing failed when they agreed and
/// nothing would have failed when they stopped: the host would simply encode at the old operating
/// point, or grant keyframes on the old bucket, with no build error and no failing test.
///
/// `docs/61` deleted both faces and the two `*_config_default` doors they crossed, and neither the
/// regression nor its invisibility went with them. `rust/slopdesk-videohostd` runs the encoder now,
/// and it can seed an operating point of its own exactly as easily as `QPController` could — more
/// easily, because a plain struct literal in the same language reads as configuration rather than
/// as a second answer. So the rule is re-aimed rather than dropped: the daemon must still ASK
/// `qp_control` and `recovery_idr`, and the eleven numbers may not be spelled where it asks.
///
/// Two bans, each the exact shape the regrowth takes now. The IDR side's is by FIELD NAME —
/// `grace_fraction`, the bucket's capacity and refill, the ring's capacity and the rest — because
/// those seven names are `RecoveryIdrConfig`'s and a daemon that spells one is a daemon holding its
/// own copy of the struct. The quantiser side's is by field-and-literal, `sharp: 26`, which is the
/// same drift the Swift `envInt("SLOPDESK_QP_…", 38)` fallback was: a tuned number typed in beside
/// the door instead of read out of it.
///
/// Both are scoped to the daemon. `rust/slopdesk-video` spells all eleven, because it is what owns
/// them, and banning them there would ban the answer along with the copy.
#[must_use]
pub fn the_encoder_defaults_are_the_crates(tree: &Tree) -> Report {
    check_all(tree, &[
        Claim::MentionsUnder {
            root: DAEMON,
            names: &["qp_control", "recovery_idr"],
            message: "the daemon stopped asking {entry} — the tuned defaults are the crate's, and a host \
                      that stopped asking is a host encoding at an operating point nothing else knows about \
                      (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(grace_fraction|grace_floor_seconds|grace_ceil_seconds|bucket_capacity|refill_tokens_per_second|grant_pending_timeout|keyframe_ring_capacity)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon spells a recovery-keyframe field in {files} — those seven belong to \
                      recovery_idr.rs's RecoveryIdrConfig, and a second copy grants keyframes on a bucket \
                      the policy never sees refill (docs/61 §3)",
        },
        Claim::NoneUnder {
            roots: &[DAEMON],
            extensions: RUST,
            pattern: r"\b(sharp|coarse|up_step|down_interval) *: *[0-9]",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a quantiser default is typed back in in {files} — the four ladder numbers are \
                      qp_control.rs's QpConfig, and one seeded here wins over the door the same way a \
                      literal on a Swift field used to (docs/61 §3)",
        },
    ])
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
            message: "the rail builder stopped calling slopdesk_ws_rail_disambiguated_labels — the \
                      relabelling is quadratic again",
        },
    ])
}

/// The open target splits once, and the crate owns where
///
/// The host's `splitLineColSuffix` used to be a second `:line[:col]` splitter beside
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
    let mut claims: Vec<Claim> = CODE_OPENERS
        .iter()
        .map(|opener| {
            Claim::Matches {
                path: opener,
                pattern: r"link_action::line_col_suffix\(|[^:]\bline_col_suffix\(",
                message: "the host splits a line:col suffix itself again — that rule is link_action.rs's, \
                          and the path the host stats and the path the extension opens can disagree by a \
                          colon",
            }
        })
        .collect();
    claims.push(Claim::NoneUnder {
        roots: HOSTD_CRATES,
        extensions: RUST,
        pattern: r"is_ascii_digit|run_start|saw_digit",
        all: &[],
        unless: &[],
        view: View::Code,
        exempt: &[],
        message: "{files} re-derives the suffix scan — the crate answers it, and the path is the remainder",
    });
    check_all(tree, &claims)
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
            "Sources/SlopDeskWorkspaceModel/Domain/SessionTemplateEngine.swift",
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
            "Sources/SlopDeskWorkspaceModel/Domain/SessionTemplateEngine.swift",
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

    /// The daemon asking both modules, spelling neither table.
    fn encoders(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/session_capture.rs",
                "use slopdesk_video::qp_control::{self, QpConfig};\nlet ladder = \
                 QpConfig::from_env(&overlay);\n",
            )
            .write(
                "rust/slopdesk-videohostd/src/session.rs",
                "use slopdesk_video::recovery_idr::RecoveryIdrConfig;\nlet idr = \
                 RecoveryIdrConfig::from_env(&overlay);\n",
            );
    }

    #[test]
    fn a_tuned_default_typed_back_in_is_red() {
        let fixture = Fixture::new("defaults-encoder");
        encoders(&fixture);
        assert!(super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // A field of the recovery config spelled where the daemon reads it is the daemon holding a
        // second copy of the table — it grants keyframes on a bucket the policy never refills.
        fixture.append(
            "rust/slopdesk-videohostd/src/session.rs",
            "let idr = RecoveryIdrConfig { bucket_capacity: 4, ..idr };\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // Same regression on the quantiser side, arriving as a tuned number typed in beside the
        // module that answers it — the Rust spelling of the old `envInt(…, 38)` fallback.
        encoders(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session_capture.rs",
            "let ladder = QpConfig { sharp: 26, coarse: 40, ..ladder };\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());

        // And the ask losing its only site: nothing is respelled, so the only claim left to fail is
        // the one that says the host still asks at all.
        encoders(&fixture);
        fixture.write(
            "rust/slopdesk-videohostd/src/session.rs",
            "let idr = self.tuned_recovery;\n",
        );
        assert!(!super::the_encoder_defaults_are_the_crates(&fixture.tree()).is_clean());
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
        let seed = |fixture: &Fixture| {
            for opener in super::CODE_OPENERS {
                fixture.write(
                    opener,
                    "use slopdesk_terminal::link_action::line_col_suffix;\nlet suffix = \
                     line_col_suffix(raw);\n",
                );
            }
        };
        seed(&fixture);
        assert!(super::the_open_target_splits_once(&fixture.tree()).is_clean());

        // One of the two going quiet is the whole rule: a bridge that splits its own target routes
        // a window at a path the performer never stats.
        seed(&fixture);
        fixture.write("rust/slopdesk-hostserver/src/bridge.rs", "");
        assert!(!super::the_open_target_splits_once(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write(
            "rust/slopdesk-hostd/src/open.rs",
            "let mut run_start = raw.len();\nwhile byte.is_ascii_digit() {}\n",
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
