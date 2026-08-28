//! Five grammars over a stream of events — the motion run, the key vocabulary, the styled VT pass,
//! the paste guard and the copy-mode clustering.
//!
//! Ported from the deleted `check-supervisor.sh`. Each is a walk Swift can re-type in twenty lines
//! and get ALMOST right: a cursor a cell off, a chord that cannot be typed, a warning that names
//! the wrong danger, scrolled distance dropped where it should have summed. None of them crashes,
//! and none of them fails a test that only ever exercised one side — which is why what is pinned
//! here is the call, not the behaviour.

use crate::claim::{Claim, RUST, View, check_all};
use crate::paths::HOSTD_CRATES;
use crate::report::Report;
use crate::tree::Tree;

/// One motion run rule, and it names events rather than carrying them
///
/// The coalescer decided a run twice: `InputMotionCoalescer` in Swift and `coalesce_motion` in Rust
/// that nothing reached. The two halves that can drift are the run KEY (a move and a drag never
/// merge; a scroll is keyed by its phase signature so a gesture boundary never joins the bulk run)
/// and the merge (keep the latest, but SUM a scroll's deltas — keeping the latest silently drops
/// scrolled distance). Both live in `slopdesk-video`, and the answer is a PLAN: a slot names the
/// input it is built from, so the `.text` arm's string never has to cross a flat record.
///
/// `docs/61` deleted the Swift face and its `slopdesk_input_coalesce_plan` door;
/// `rust/slopdesk-videohostd` collapses a run by calling the crate directly. So the ban is re-aimed
/// at the daemon: the run key and the merge are the two things a drain loop is tempted to re-type,
/// because both look like three lines at the point where the batch is in hand. A daemon copy that
/// kept the LATEST scroll rather than summing drops scrolled distance with nothing red anywhere —
/// the page just moves less than the finger did.
///
/// The "no Swift brings this back" half is stated tree-wide in
/// [`crate::rules::deleted_video_swift`], which bans declaring any video-host type in any Swift
/// target rather than in the one file that used to hold this one.
#[must_use]
pub fn one_motion_run_rule_answers(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["rust/slopdesk-videohostd"],
            extensions: RUST,
            pattern: r"\b(enum|struct) RunKey\b|\bfn (run_key|merge_run|coalesce_plan|coalesce_motion)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "the daemon decides a motion run for itself in {files} — the rule is \
                      input_routing.rs's coalesce_plan, and a copy that keeps the latest scroll rather than \
                      summing drops scrolled distance with nothing red anywhere (docs/61 §3)",
        },
        Claim::Mentions {
            path: "rust/slopdesk-video/src/input_routing.rs",
            names: &["fn coalesce_plan", "fn run_key", "RunKey::Scroll"],
            message: "rust/slopdesk-video/src/input_routing.rs lost {entry} — the run rule is written there \
                      once",
        },
    ];
    check_all(tree, &claims)
}

/// One key vocabulary, whichever grammar names it
///
/// `send_keys` reads the table for the `<Token>` grammar a preset, a template, a re-run and a text
/// drop carry; the agent-control `write` verb names the SAME keys in a comma-separated `--key`
/// list, and used to carry a second table for it. They had drifted: `C-?` was DEL on the Swift side
/// and `C-_`'s byte in Rust, `C-Space` was NUL there and refused here, and the function and paging
/// keys had no Rust spelling at all. One table answers both now.
///
/// The `write` verb is `rust/slopdesk-hostserver`'s control dispatch since `docs/60` F.9, so the
/// resolve is a call the compiler checks. The ban is what survives: a second table is still one
/// `match` away, and the two spellings that drifted are the ones cheapest to re-type.
#[must_use]
pub fn one_key_vocabulary_whichever_grammar(tree: &Tree) -> Report {
    /// hostd's control dispatch, the one caller that resolves a `--key` token.
    const CONTROL: &str = "rust/slopdesk-hostserver/src/control.rs";

    let claims = [
        Claim::Matches {
            path: CONTROL,
            pattern: r"slopdesk_workspace::send_keys::key_token\(",
            view: View::Code,
            message: "rust/slopdesk-hostserver/src/control.rs answers a key name itself again — the \
                      vocabulary is send_keys.rs's",
        },
        // The escape a paging key sends, not the CSI introducer: a test emitting `\x1b[32m` into a
        // pane is colouring output, and banning the introducer would ban every one of them.
        Claim::NoneUnder {
            roots: HOSTD_CRATES,
            extensions: RUST,
            pattern: r#"& 0x1[Ff]|"pageup"|"pagedown"|\\x1b\[5~|\\x1b\[6~|\\x1bO[PQRS]"#,
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "{files} spells a key sequence again — a second table is how C-? and C-Space drifted",
        },
        Claim::Names {
            path: "rust/slopdesk-workspace/src/send_keys.rs",
            needle: "pub fn key_token",
            message: "rust/slopdesk-workspace/src/send_keys.rs lost key_token — the bare-name grammar reads \
                      the table through it",
        },
        Claim::Mentions {
            path: "rust/slopdesk-workspace/src/send_keys.rs",
            names: &[r#""f12""#, r#""pagedown""#, r#""insert""#],
            message: "rust/slopdesk-workspace/src/send_keys.rs dropped {entry} — the union is the \
                      vocabulary, so a preset can say it too",
        },
    ];
    check_all(tree, &claims)
}

/// One VT grammar for STYLED text, and the clipboard reads it destyled
///
/// `AnsiStyledParser` was a SECOND VT grammar: a hand-rolled escape skipper, a hand-rolled SGR
/// decoder and a hand-rolled string-sequence scan, sitting beside the `vtscan` module that already
/// owned all three for the replay passes. Two grammars over one byte stream is how a sequence one
/// side skips and the other prints becomes a bug nobody can localise. `slopdesk_sanitize::styled`
/// owns the pass now; the clipboard's plain text is that pass with the styles discarded, which is
/// what keeps the copied text and the coloured text from being two behaviours.
#[must_use]
pub fn one_vt_grammar_for_styled(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"func +(skipEscapeSequence|isEraseToLineEnd|applySGR|extendedColour)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift VT grammar is back in Sources/ — slopdesk-sanitize::styled owns the styled \
                      pass",
        },
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/AnsiStyledText.swift",
            needle: "slopdesk_styled_lines",
            message: "Sources/SlopDeskWorkspaceCore/Terminal/AnsiStyledText.swift stopped asking the door — \
                      it is a marshaller over the pass, not a second one",
        },
        Claim::Names {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/BlockOutputSanitizer.swift",
            needle: "AnsiStyledParser.lines",
            message: "Sources/SlopDeskWorkspaceCore/Terminal/BlockOutputSanitizer.swift skims on its own \
                      again — the clipboard's text IS the styled pass, destyled",
        },
        Claim::Mentions {
            path: "rust/slopdesk-sanitize/src/styled.rs",
            names: &[
                "pub fn lines",
                "fn escape_end",
                "fn apply_sgr",
                "fn is_erase_to_line_end",
            ],
            message: "rust/slopdesk-sanitize/src/styled.rs lost {entry} — one grammar, read two ways",
        },
    ];
    check_all(tree, &claims)
}

/// One paste guard, and the other one stays a different engine
///
/// Two guards ask two questions and must never merge: `paste` asks "would this run something
/// dangerous at a prompt?", `secrets` asks "would typing this leak a credential?". Both are Rust
/// now; what this pins is that neither Swift face grows rules of its own, and that the four dangers
/// keep the same bit numbering on both sides — the mask crosses as itself, so a renumbering here
/// would silently relabel every warning the sheet prints. The SENTENCES are pinned the same way,
/// and for the same reason. A line describing a danger is as much the guard as the bit that trips
/// it: a renderer that spelled its own would be a second guard saying something slightly different,
/// and a fifth danger would reach the user as a blank bullet.
#[must_use]
pub fn one_paste_guard_secret_one(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift"],
            pattern: r"containsElevationToken|isSeparator|unicodeScalars",
            view: View::Code,
            message: "{files} classifies a paste in Swift again — slopdesk-terminal::paste owns the four \
                      dangers",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift",
            names: &["slopdesk_paste_dangers", "slopdesk_paste_should_warn"],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift no longer asks \
                      {entry} — the guard is one implementation",
        },
        // The WORDS moved off the analyzer and into the presentation, and from six doors to one. The
        // face pinned here is the one that draws the dialog rather than the one that decides there
        // should be a dialog, and what it must not do is assemble that dialog itself.
        Claim::Mentions {
            path: "Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift",
            names: &["slopdesk_paste_confirmation"],
            message: "Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift no longer asks \
                      {entry} — the confirmation's words are one implementation",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift"],
            pattern: r#"previewLimit|messageText = "|Paste Anyway|OSC 52"#,
            view: View::Code,
            message: "{files} spells the confirmation's own words — slopdesk-terminal::paste owns every \
                      sentence",
        },
        Claim::Mentions {
            path: "rust/slopdesk-terminal/src/paste.rs",
            names: &[
                "pub fn descriptions",
                "pub fn preview",
                "pub fn confirmation",
                "pub enum Ask",
            ],
            message: "rust/slopdesk-terminal/src/paste.rs lost {entry} — the sheet's words live beside its \
                      rules",
        },
        Claim::Mentions {
            path: "rust/slopdesk-terminal/src/paste.rs",
            names: &[
                "MULTI_LINE: u32 = 1 << 0",
                "TRAILING_NEWLINE: u32 = 1 << 1",
                "SUDO_OR_SU: u32 = 1 << 2",
                "CONTROL_CHARS: u32 = 1 << 3",
            ],
            message: "rust/slopdesk-terminal/src/paste.rs renumbered a danger ({entry}) — the mask crosses \
                      as itself",
        },
    ];
    check_all(tree, &claims)
}

/// One clustering answers the cursor and the badge that says where it is
///
/// The vi copy-mode motions used to walk the row in Swift, `Character` by `Character`, asking the
/// link detector for each glyph's width. The link and hint overlays walked the SAME row through
/// `slopdesk_terminal::link`'s clustering. Two clusterings over one row put a cursor half a glyph
/// away from the badge claiming to be on it, on exactly the CJK rows nobody checks by hand — so the
/// motions moved beside the clustering, and this pins that they stay there.
#[must_use]
pub fn one_clustering_answers_cursor_badge(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift"],
            pattern: r"CellChar|charClass|isWhitespace|isLetter|isNumber|runStartIndex|runEndIndex",
            view: View::Code,
            message: "{files} walks the row in Swift again — slopdesk-terminal::vimotion owns the motions",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift",
            names: &[
                "slopdesk_vi_next_word_start",
                "slopdesk_vi_column_step",
                "slopdesk_vi_cell_width",
            ],
            message: "Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift no longer asks {entry} — \
                      the motions are one implementation",
        },
        Claim::Mentions {
            path: "rust/slopdesk-terminal/src/vimotion.rs",
            names: &[
                "pub fn cells",
                "pub fn addressable_cells",
                "fn run_start_index",
                "fn run_end_index",
            ],
            message: "rust/slopdesk-terminal/src/vimotion.rs lost {entry} — the copy-mode motions live there",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/vimotion.rs",
            needle: "use crate::link::{clusters, scalar_cells}",
            message: "vimotion stopped reading link's clustering — the cursor and the hint badge would \
                      drift apart",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_motion_run_rule_answers(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-videohostd/src/session_inbound.rs",
                "use slopdesk_video::input_routing::{self, ScrollCoalescePlanner};\nlet planned = \
                 input.planner.plan(run, now);\n",
            )
            .write(
                "rust/slopdesk-video/src/input_routing.rs",
                "fn coalesce_plan\nfn run_key\nRunKey::Scroll\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_motion_run_rule_answers_holds_the_daemon_to_the_crate() {
        let fixture = Fixture::new("one-motion-run-rule-answers");
        write_one_motion_run_rule_answers(&fixture);
        assert!(super::one_motion_run_rule_answers(&fixture.tree()).is_clean());

        // The crate stopped writing the rule — there is no single answer left to ask for.
        fixture.write(
            "rust/slopdesk-video/src/input_routing.rs",
            "kept so the ban has a haystack\n",
        );
        assert!(!super::one_motion_run_rule_answers(&fixture.tree()).is_clean());

        // The run KEY, re-typed in the drain loop that has the batch in hand.
        write_one_motion_run_rule_answers(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session_inbound.rs",
            "enum RunKey { Move, Drag, Scroll }\n",
        );
        assert!(!super::one_motion_run_rule_answers(&fixture.tree()).is_clean());

        // And the MERGE, which is the half that silently drops scrolled distance.
        write_one_motion_run_rule_answers(&fixture);
        fixture.append(
            "rust/slopdesk-videohostd/src/session_inbound.rs",
            "fn merge_run(slot: &mut Slot, event: &InputEvent) { *slot = latest(event); }\n",
        );
        assert!(!super::one_motion_run_rule_answers(&fixture.tree()).is_clean());
    }

    fn write_one_key_vocabulary_whichever_grammar(fixture: &Fixture) {
        fixture
            .write(
                "rust/slopdesk-hostserver/src/control.rs",
                "let Some(resolved) = slopdesk_workspace::send_keys::key_token(token) else {\n    return \
                 Err(Rejected);\n};\n",
            )
            .write(
                "rust/slopdesk-workspace/src/send_keys.rs",
                "pub fn key_token\n\"f12\"\n\"pagedown\"\n\"insert\"\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_key_vocabulary_whichever_grammar_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-key-vocabulary-whichever-grammar");
        write_one_key_vocabulary_whichever_grammar(&fixture);
        assert!(super::one_key_vocabulary_whichever_grammar(&fixture.tree()).is_clean());

        // The caller stopped asking — an implementation grew back where the call used to be.
        fixture.write("rust/slopdesk-hostserver/src/control.rs", "");
        assert!(!super::one_key_vocabulary_whichever_grammar(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled. The table stays in the crate that
        // owns it — only the host copy is red, which is what the ban is about.
        write_one_key_vocabulary_whichever_grammar(&fixture);
        fixture.write(
            "rust/slopdesk-hostd/src/keys.rs",
            "\"pageup\" => ESC_BRACKET_5_TILDE,\n",
        );
        assert!(!super::one_key_vocabulary_whichever_grammar(&fixture.tree()).is_clean());
    }

    fn write_one_vt_grammar_for_styled(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/AnsiStyledText.swift",
                "slopdesk_styled_lines\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/BlockOutputSanitizer.swift",
                "AnsiStyledParser.lines\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-sanitize/src/styled.rs",
                "pub fn lines\nfn escape_end\nfn apply_sgr\nfn is_erase_to_line_end\nkept so the ban has a \
                 haystack\n",
            );
    }

    #[test]
    fn one_vt_grammar_for_styled_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-vt-grammar-for-styled");
        write_one_vt_grammar_for_styled(&fixture);
        assert!(super::one_vt_grammar_for_styled(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskWorkspaceCore/Terminal/AnsiStyledText.swift", "");
        assert!(!super::one_vt_grammar_for_styled(&fixture.tree()).is_clean());
    }

    fn write_one_paste_guard_secret_one(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift",
                "slopdesk_paste_dangers\nslopdesk_paste_should_warn\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift",
                "slopdesk_paste_confirmation\nkept so the ban has a haystack\n",
            )
            .write(
                "Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift",
                "kept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/src/paste.rs",
                "pub fn descriptions\npub fn preview\npub fn confirmation\npub enum Ask\nMULTI_LINE: u32 = \
                 1 << 0\nTRAILING_NEWLINE: u32 = 1 << 1\nSUDO_OR_SU: u32 = 1 << 2\nCONTROL_CHARS: u32 = 1 \
                 << 3\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_paste_guard_secret_one_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-paste-guard-secret-one");
        write_one_paste_guard_secret_one(&fixture);
        assert!(super::one_paste_guard_secret_one(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write(
            "Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift",
            "",
        );
        assert!(!super::one_paste_guard_secret_one(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_paste_guard_secret_one(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift",
            "containsElevationToken\n",
        );
        assert!(!super::one_paste_guard_secret_one(&fixture.tree()).is_clean());
    }

    fn write_one_clustering_answers_cursor_badge(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift",
                "slopdesk_vi_next_word_start\nslopdesk_vi_column_step\nslopdesk_vi_cell_width\nkept so the \
                 ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-terminal/src/vimotion.rs",
                "pub fn cells\npub fn addressable_cells\nfn run_start_index\nfn run_end_index\nuse \
                 crate::link::{clusters, scalar_cells}\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_clustering_answers_cursor_badge_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-clustering-answers-cursor-badge");
        write_one_clustering_answers_cursor_badge(&fixture);
        assert!(super::one_clustering_answers_cursor_badge(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift", "");
        assert!(!super::one_clustering_answers_cursor_badge(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_clustering_answers_cursor_badge(&fixture);
        fixture.append(
            "Sources/SlopDeskWorkspaceCore/Terminal/ViLineMotion.swift",
            "CellChar\n",
        );
        assert!(!super::one_clustering_answers_cursor_badge(&fixture.tree()).is_clean());
    }
}
