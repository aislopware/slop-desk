//! Five grammars over a stream of events — the motion run, the key vocabulary, the styled VT pass,
//! the paste guard and the copy-mode clustering.
//!
//! Ported from the deleted `check-supervisor.sh`. Each is a walk Swift can re-type in twenty lines
//! and get ALMOST right: a cursor a cell off, a chord that cannot be typed, a warning that names
//! the wrong danger, scrolled distance dropped where it should have summed. None of them crashes,
//! and none of them fails a test that only ever exercised one side — which is why what is pinned
//! here is the call, not the behaviour.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// One motion run rule, and it names events rather than carrying them
///
/// The coalescer decided a run twice: `InputMotionCoalescer` in Swift and `coalesce_motion` in Rust
/// that nothing reached. The two halves that can drift are the run KEY (a move and a drag never
/// merge; a scroll is keyed by its phase signature so a gesture boundary never joins the bulk run)
/// and the merge (keep the latest, but SUM a scroll's deltas — keeping the latest silently drops
/// scrolled distance). Both live in `slopdesk-video` now, and the answer is a PLAN: a slot names
/// the input it is built from, so the `.text` arm's string never has to cross a flat record.
#[must_use]
pub fn one_motion_run_rule_answers(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            needle: "slopdesk_input_coalesce_plan",
            message: "Sources/SlopDeskVideoHost/VideoSessionLogic.swift no longer takes its coalescing plan \
                      from slopdesk_input_coalesce_plan",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskVideoHost/VideoSessionLogic.swift"],
            pattern: r"enum RunKey|func runKey|func mergeRun",
            view: View::Code,
            message: "{files} decides a motion run again — the rule is input_routing.rs's coalesce_plan",
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
#[must_use]
pub fn one_key_vocabulary_whichever_grammar(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "Sources/SlopDeskHost/ControlKeyMap.swift",
            needle: "slopdesk_ws_key_token",
            message: "Sources/SlopDeskHost/ControlKeyMap.swift answers a key name again — the vocabulary is \
                      send_keys.rs's",
        },
        Claim::NoneOf {
            paths: &["Sources/SlopDeskHost/ControlKeyMap.swift"],
            pattern: r#"0x1B, 0x5B|case "enter"|case "pageup"|& 0x1F"#,
            view: View::Code,
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
                "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
                "slopdesk_input_coalesce_plan\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-video/src/input_routing.rs",
                "fn coalesce_plan\nfn run_key\nRunKey::Scroll\nkept so the ban has a haystack\n",
            );
    }

    #[test]
    fn one_motion_run_rule_answers_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-motion-run-rule-answers");
        write_one_motion_run_rule_answers(&fixture);
        assert!(super::one_motion_run_rule_answers(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskVideoHost/VideoSessionLogic.swift", "");
        assert!(!super::one_motion_run_rule_answers(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_motion_run_rule_answers(&fixture);
        fixture.append(
            "Sources/SlopDeskVideoHost/VideoSessionLogic.swift",
            "enum RunKey\n",
        );
        assert!(!super::one_motion_run_rule_answers(&fixture.tree()).is_clean());
    }

    fn write_one_key_vocabulary_whichever_grammar(fixture: &Fixture) {
        fixture
            .write(
                "Sources/SlopDeskHost/ControlKeyMap.swift",
                "slopdesk_ws_key_token\nkept so the ban has a haystack\n",
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

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskHost/ControlKeyMap.swift", "");
        assert!(!super::one_key_vocabulary_whichever_grammar(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_one_key_vocabulary_whichever_grammar(&fixture);
        fixture.append("Sources/SlopDeskHost/ControlKeyMap.swift", "0x1B, 0x5B\n");
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
