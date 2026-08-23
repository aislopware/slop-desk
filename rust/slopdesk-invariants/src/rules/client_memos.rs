//! Two client memos that must keep asking rather than re-deriving — the palette ranking and the
//! rail's title rung.
//!
//! Ported from `scripts/check-supervisor.sh`. A memo is exactly where a second implementation hides
//! best: it is called once per keystroke, it is easy to write badly, and a ranking that disagrees
//! with the one the row title used reads as the list being jumpy, never as two rules.

use crate::claim::{Claim, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

/// One fuzzy ranking, for every search field
///
/// fzf's `FuzzyMatchV2` — a Smith-Waterman DP, a structural-bonus table and a backtrace — was 300
/// lines of Swift beside the Rust that owns it now. This one carries IDENTITY: the order a palette
/// shows IS the product, so a second scorer does not fail a test, it just starts ranking
/// differently and nobody can say which copy the person is looking at. Every search field asks the
/// same door.
#[must_use]
pub fn one_fuzzy_ranking_for_every(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["Sources"],
            extensions: &["swift"],
            pattern: r"(let|var|func|case) *(bonusBoundary|bonusCamel123|bonusConsecutive|scoreGapStart|scoreGapExtension|bonusMatrix|bonusFor|backtrace)\b",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[],
            message: "a Swift fuzzy scorer is back in Sources/ — rust/slopdesk-fuzzy owns FuzzyMatchV2",
        },
        Claim::Names {
            path: "Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift",
            needle: "slopdesk_fuzzy_score",
            message: "Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift stopped asking the door — it is \
                      a marshaller over the matcher, not a second one",
        },
        Claim::Mentions {
            path: "rust/slopdesk-fuzzy/src/lib.rs",
            names: &[
                "pub fn score",
                "pub fn rank",
                "pub fn match_pattern",
                "fn bonus_for",
            ],
            message: "rust/slopdesk-fuzzy/src/lib.rs lost {entry} — the ranking is one module",
        },
    ];
    check_all(tree, &claims)
}

/// The rail's title RUNG is asked for, never transcribed
///
/// `titledByProcess` is `slopdesk_workspace::rail_title::title_rung` asked without composing the
/// string. It used to be transcribed into Swift, and its own doc comment said "Mirrors
/// RailRowsBuilder.rowTitle's escape order" — docs/55 §8's named anti-pattern, a comment describing
/// another language's behaviour as the only thing holding two implementations together. The
/// transcription is deleted. The two helpers banned below are the pieces the Swift copy was built
/// from, so their reappearance in the memo IS the transcription growing back; the two doors are
/// pinned because an unreached port is worse than an unported one. BREAK-TESTED 2026-08-22:
/// restoring `if RailRowsBuilder.cwdFolderName(cwd) == nil` in RailRowsMemo.swift failed rule 1;
/// deleting either door call failed its own rule. All three pass.
#[must_use]
pub fn rail_fingerprint_asks_for_its(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneOf {
            paths: &["Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift"],
            pattern: r"cwdFolderName|normalizedProjectKey",
            view: View::Code,
            message: "{files} re-derives the rail's title rung in Swift — the rung lives in \
                      slopdesk_workspace::rail_title::title_rung and row_title composes its string from the \
                      SAME function, so the two cannot drift",
        },
        Claim::Mentions {
            path: "Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift",
            names: &[
                "slopdesk_ws_rail_titles_by_process",
                "slopdesk_ws_rail_structure_keys",
            ],
            message: "Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift no longer asks {entry} — docs/55 \
                      §8: an unreached port is worse than an unported one, and the Swift answering it would \
                      be a second implementation",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    fn write_one_fuzzy_ranking_for_every(fixture: &Fixture) {
        fixture
            .write("Sources/Generated.swift", "kept so the ban has a haystack\n")
            .write(
                "Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift",
                "slopdesk_fuzzy_score\nkept so the ban has a haystack\n",
            )
            .write(
                "rust/slopdesk-fuzzy/src/lib.rs",
                "pub fn score\npub fn rank\npub fn match_pattern\nfn bonus_for\nkept so the ban has a \
                 haystack\n",
            );
    }

    #[test]
    fn one_fuzzy_ranking_for_every_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("one-fuzzy-ranking-for-every");
        write_one_fuzzy_ranking_for_every(&fixture);
        assert!(super::one_fuzzy_ranking_for_every(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskClientCore/Palette/FuzzyMatcher.swift", "");
        assert!(!super::one_fuzzy_ranking_for_every(&fixture.tree()).is_clean());

        // And the scorer itself, retyped anywhere under Sources/ — not just in the face.
        write_one_fuzzy_ranking_for_every(&fixture);
        fixture.append("Sources/Generated.swift", "let bonusBoundary = 8\n");
        assert!(!super::one_fuzzy_ranking_for_every(&fixture.tree()).is_clean());
    }

    fn write_rail_fingerprint_asks_for_its(fixture: &Fixture) {
        fixture.write(
            "Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift",
            "slopdesk_ws_rail_titles_by_process\nslopdesk_ws_rail_structure_keys\nkept so the ban has a \
             haystack\n",
        );
    }

    #[test]
    fn rail_fingerprint_asks_for_its_holds_its_faces_to_their_doors() {
        let fixture = Fixture::new("rail-fingerprint-asks-for-its");
        write_rail_fingerprint_asks_for_its(&fixture);
        assert!(super::rail_fingerprint_asks_for_its(&fixture.tree()).is_clean());

        // The face stopped asking — an implementation grew back where the call used to be.
        fixture.write("Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift", "");
        assert!(!super::rail_fingerprint_asks_for_its(&fixture.tree()).is_clean());

        // And the law it was banned from respelling, respelled.
        write_rail_fingerprint_asks_for_its(&fixture);
        fixture.append(
            "Sources/SlopDeskClientCore/Rail/RailRowsMemo.swift",
            "cwdFolderName\n",
        );
        assert!(!super::rail_fingerprint_asks_for_its(&fixture.tree()).is_clean());
    }
}
