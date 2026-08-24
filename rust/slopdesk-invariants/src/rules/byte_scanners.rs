//! The scanners that walk untrusted bytes — the plain-text VT pass, the escape grammar, the width
//! table, the shell word, the find scan, the base64 codec and the `\xNN`/`%NN` reading.
//!
//! Ported from the deleted `check-supervisor.sh`. Every one of these was written more than once,
//! and the counts are the point: six escape scanners, eight shell quoters, fourteen narrowing
//! casts, three base64 codecs, four `hex_nibble`s. None of the copies was wrong on its own; what
//! made them a defect was that they answered the same bytes differently, and the bytes came off a
//! socket or a clipboard rather than out of a test.

use crate::claim::{Claim, GATE_RULES, View, check_all};
use crate::report::Report;
use crate::tree::Tree;

const SWIFT_STRIPPER: &str = "Sources/SlopDeskHost/ANSIStripper.swift";
const SWIFT_WAIT: &str = "Sources/SlopDeskHost/AgentControlListener.swift";
const SWIFT_QUOTING: &str = "Sources/SlopDeskWorkspaceModel/Domain/ShellQuoting.swift";
const SWIFT_SYNC_INPUT: &str = "Sources/SlopDeskWorkspaceCore/Workspace/Store/SyncInputByteFilter.swift";
const SWIFT_FIND: &str = "Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift";

/// One VT grammar for plain text, read two ways
///
/// `vtscan` exists because the replay passes each hand-rolled the same skimmer. Two MORE machines
/// were still spelled in Swift: the stripper that renders a pane's output for a regex, and the
/// holdback scan that decides where a chunk was cut mid-sequence — whose doc comments promised each
/// other they matched, which is the drift risk stated as a promise. Both are `plaintext` now, and
/// the terminator policy that genuinely differs between a replay pass and a render is NAMED
/// (`Terminators`) rather than duplicated.
#[must_use]
pub fn one_vt_grammar_for_plain_text(tree: &Tree) -> Report {
    let claims = [
        Claim::Mentions {
            path: SWIFT_STRIPPER,
            names: &["slopdesk_plaintext_strip", "slopdesk_plaintext_holdback"],
            message: "ANSIStripper.swift no longer asks {entry} — the VT grammar is plaintext.rs's",
        },
        Claim::Lacks {
            path: SWIFT_STRIPPER,
            pattern: "skipCSI|skipStringCommand|0x9B|0xE000|utf8Tail",
            view: View::Code,
            message: "ANSIStripper.swift walks the grammar again — one scanner answers both the strip and \
                      the holdback",
        },
        Claim::Lacks {
            path: SWIFT_WAIT,
            pattern: "private static func csiEnd|private static func stringCommandEnd",
            view: View::Code,
            message: "AgentControlListener.swift is a second VT machine — its own comments used to say it \
                      matched the stripper's",
        },
        Claim::Names {
            path: "rust/slopdesk-sanitize/src/plaintext.rs",
            needle: "pub fn holdback_start",
            message: "rust/slopdesk-sanitize/src/plaintext.rs lost holdback_start — the cut point is read \
                      off the same grammar",
        },
        Claim::Names {
            path: "rust/slopdesk-sanitize/src/vtscan.rs",
            needle: "pub const fn lenient",
            message: "rust/slopdesk-sanitize/src/vtscan.rs lost the lenient terminator policy — a render \
                      cannot wait for a continuation the way a replay pass can",
        },
    ];
    check_all(tree, &claims)
}

/// One shell word, wherever a path is typed into a live shell
///
/// The POSIX `'…'` quoting was written EIGHT times: seven Swift copies and one private to the Rust
/// template emitter. One of the seven called itself the single source of truth while four sat
/// beside it; another kept its copy rather than widen a daemon's dependency graph for four lines.
/// The graph never had to widen — the face lives in the value-model leaf every one of them already
/// links.
///
/// The half that bans a second copy lives in [`repo_invariants`](super::repo_invariants)
/// (`shell_quoting_has_one_owner`), because the shell's version here could not fail: it piped 742
/// paths into `xargs grep -ln`, which prints the offender and still exits non-zero when the last
/// batch is clean.
#[must_use]
pub fn one_shell_word_wherever_a_path_is_typed(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: SWIFT_QUOTING,
            needle: "slopdesk_ws_shell_quote",
            message: "ShellQuoting.swift stopped asking the door — it is a face, not a second rule",
        },
        Claim::Lacks {
            path: "Sources/SlopDeskWorkspaceCore/Terminal/PasteTransform.swift",
            pattern: "private static func isShellSafe|allSatisfy",
            view: View::Code,
            message: "PasteTransform.swift spells the shlex safe set again — bare-if-safe is a reading of \
                      the same door",
        },
        Claim::Names {
            path: "rust/slopdesk-ids/src/shell_quoting.rs",
            needle: "pub fn shlex_quoted",
            message: "rust/slopdesk-ids/src/shell_quoting.rs lost shlex_quoted — the paste's bare reading \
                      is the same rule",
        },
        Claim::Lacks {
            path: "rust/slopdesk-workspace/src/templates.rs",
            pattern: "fn shell_quoted",
            view: View::Code,
            message: "templates.rs is the emitter's private copy again — it asks shell_quoting like \
                      everyone else",
        },
    ];
    check_all(tree, &claims)
}

/// And ONE width table under that clustering
///
/// One clustering was not enough, because there were still two tables saying how wide a cluster IS.
/// `slopdesk-sanitize` knew the Arabic, Hebrew and Thai combining marks; the link scan's copy knew
/// the `Default_Ignorable` set and painted U+1F300..U+1FAFF wide over three ranges of narrow
/// pictographs. A screen model measuring a Thai line one way while the cursor, the underline and
/// the hint badge measure it another is the same drift one layer down. The CJK sentinel is the
/// cheapest tell that a third table has appeared: nothing measures East Asian width without it.
#[must_use]
pub fn one_width_table_under_that_clustering(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "rust/slopdesk-sanitize/src/width.rs",
            needle: "pub const fn scalar_width",
            message: "rust/slopdesk-sanitize/src/width.rs lost scalar_width — it is the one width table",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/src/link.rs",
            needle: "use slopdesk_sanitize::width::scalar_width",
            message: "rust/slopdesk-terminal/src/link.rs stopped reading the one width table — a second one \
                      drifts",
        },
        Claim::NoneUnder {
            roots: &["rust", "Sources"],
            extensions: &["rs", "swift"],
            pattern: "0x4E00|0x4e00",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-sanitize/src/width.rs", GATE_RULES],
            message: "{files} carries its own East Asian width table — slopdesk-sanitize::width is the one",
        },
    ];
    check_all(tree, &claims)
}

/// And ONE grammar for where an escape ENDS
///
/// `vtscan` exists because the Swift originals hand-rolled the CSI/string-sequence walk four times
/// and a bug in the parameter ranges was fixable in four places. `slopdesk-altscreen` then made a
/// FIFTH copy — in the crate that decides, from evicted bytes, whether tens of MiB of alt-screen
/// churn replays into a user's scrollback. Two scanners disagreeing about where one sequence ends
/// is how that crate and the replay passes reach different answers about the same bytes.
///
/// The ban is on the two function NAMES rather than on the ranges: `0x40..=0x7E` is the ECMA-48
/// final byte and appears in the shared scanner itself, but nothing walks a sequence without
/// defining where it stops. The SIXTH copy was in Swift and on the INPUT path —
/// `SyncInputByteFilter` hand-rolled both walks under a "mirror, don't share" comment, deciding
/// which client→host bytes get mirrored into a sibling pane. A disagreement there does not merely
/// render wrong: the bytes it lets through are typed into another shell, and the next mirrored `↵`
/// runs them.
#[must_use]
pub fn one_grammar_for_where_an_escape_ends(tree: &Tree) -> Report {
    let claims = [
        Claim::Names {
            path: "rust/slopdesk-sanitize/src/vtscan.rs",
            needle: "pub fn parse_csi",
            message: "rust/slopdesk-sanitize/src/vtscan.rs lost parse_csi — it is the one escape grammar",
        },
        Claim::Names {
            path: "rust/slopdesk-altscreen/src/lib.rs",
            needle: "use slopdesk_sanitize::vtscan",
            message: "rust/slopdesk-altscreen stopped reading the one escape grammar — a fifth copy drifts",
        },
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: "fn (parse_csi|string_sequence_end)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-sanitize/src/vtscan.rs", GATE_RULES],
            message: "{files} defines its own escape scanner — slopdesk-sanitize::vtscan is the one",
        },
        Claim::Lacks {
            path: SWIFT_SYNC_INPUT,
            pattern: r"func (parseCSI|stringSequenceEnd)|struct CSISequence|0x3F\)\.contains",
            view: View::Code,
            message: "SyncInputByteFilter.swift walks escapes in Swift again — slopdesk-sanitize::syncinput \
                      owns the input filter",
        },
        Claim::Names {
            path: SWIFT_SYNC_INPUT,
            needle: "slopdesk_sync_input_keyboard_only",
            message: "SyncInputByteFilter.swift no longer asks the door — the sync-input filter is one \
                      implementation",
        },
    ];
    check_all(tree, &claims)
}

/// ⌘F is the second untrusted pattern, and it runs on the same engine
///
/// Find-in-terminal took a pattern the user retypes on every keystroke and ran it, backtracking,
/// over the whole scrollback. Same hazard as Hint Mode, reached far more often. The scan is
/// `slopdesk-rowscan::find` now, and the columns it answers in are UTF-16 units because that is
/// what the highlighting surface indexes — the door does not convert, so neither may this face.
#[must_use]
pub fn the_find_bar_asks_the_same_engine(tree: &Tree) -> Report {
    let claims = [
        Claim::Lacks {
            path: SWIFT_FIND,
            pattern: "NSRegularExpression|NSString|NSRange|NSNotFound|CharacterSet",
            view: View::Code,
            message: "TerminalSearchController.swift scans for matches in Swift again — \
                      slopdesk-rowscan::find owns the scan",
        },
        Claim::Names {
            path: SWIFT_FIND,
            needle: "slopdesk_find_matches",
            message: "TerminalSearchController.swift no longer asks slopdesk_find_matches — the find scan \
                      is one implementation",
        },
        Claim::Names {
            path: "rust/slopdesk-rowscan/src/find.rs",
            needle: "pub fn matches",
            message: "rust/slopdesk-rowscan/src/find.rs lost matches() — ⌘F has nowhere to ask",
        },
    ];
    check_all(tree, &claims)
}

/// One base64, and one secret notation
///
/// Three hand-written base64 codecs lived in this tree — an encoder and a decoder inside superd
/// agreeing with each other by inspection, and a third pair in the wire's state file — each
/// carrying a copy of the standard alphabet and its own reading of what padding is legal. A codec
/// that is "small enough to read" is still one implementation per copy. The `base64` crate is the
/// one implementation now, and the alphabet is what gives a fourth copy away.
///
/// The secret shapes are regular expressions in the notation the world publishes them in, not a
/// byte loop with its own reading of `\b`. The scanner they replaced was wrong twice during its own
/// port.
#[must_use]
pub fn one_base64_and_one_secret_notation(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &[GATE_RULES],
            message: "a hand-written base64 alphabet is back ({files}) — the base64 crate is the codec \
                      (docs/DECISIONS.md, 2026-08-15)",
        },
        Claim::Names {
            path: "rust/slopdesk-wire/Cargo.toml",
            needle: "\nbase64 = ",
            message: "rust/slopdesk-wire dropped the base64 crate — it encodes or decodes base64 and must \
                      not spell one",
        },
        Claim::Names {
            path: "rust/slopdesk-superd/Cargo.toml",
            needle: "\nbase64 = ",
            message: "rust/slopdesk-superd dropped the base64 crate — it encodes or decodes base64 and must \
                      not spell one",
        },
        Claim::Names {
            path: "rust/slopdesk-workspace/Cargo.toml",
            needle: "\nregex = ",
            message: "rust/slopdesk-workspace dropped the regex crate — secrets.rs must not hand-roll the \
                      shapes again",
        },
        Claim::Pinned {
            label: "the secret shapes secrets.rs carries",
            from: crate::claim::Extract::code(
                "rust/slopdesk-workspace/src/secrets.rs",
                r"const PATTERNS: \[\(&str, Action\); ([0-9]+)\]",
            ),
            expect: "11",
        },
    ];
    check_all(tree, &claims)
}

/// One reading of `\xNN` and `%NN`, wherever the bytes came from
///
/// The shim's `133;E` escaping was inverted in `slopdesk-sanitize::distill` AND in superd's
/// segmenter, one spelling it `(high << 4) | low` and the other `high * 16 + low`; percent-decoding
/// was byte-for-byte duplicated between superd's OSC 7 reader and the client's link scanner; and
/// `hex_nibble` had four copies, three of them re-deriving what `char::to_digit(16)` already knows.
/// `slopdesk-sanitize::escape` is the one reading now — the crate that already declares itself the
/// home of the shared byte scanners.
#[must_use]
pub fn one_reading_of_an_escape(tree: &Tree) -> Report {
    let claims = [
        Claim::NoneUnder {
            roots: &["rust"],
            extensions: &["rs"],
            pattern: "fn (hex_nibble|hex_value|unescape_command|remove_percent_encoding)",
            all: &[],
            unless: &[],
            view: View::Code,
            exempt: &["rust/slopdesk-sanitize/src/escape.rs", GATE_RULES],
            message: "an escape decoder grew back outside slopdesk-sanitize::escape ({files}) — one \
                      reading, whoever wrote the bytes",
        },
        Claim::Names {
            path: "rust/slopdesk-superd/Cargo.toml",
            needle: "\nslopdesk-sanitize = ",
            message: r"rust/slopdesk-superd dropped slopdesk-sanitize — it decodes \xNN or %NN and must not \
                       spell one",
        },
        Claim::Names {
            path: "rust/slopdesk-terminal/Cargo.toml",
            needle: "\nslopdesk-sanitize = ",
            message: r"rust/slopdesk-terminal dropped slopdesk-sanitize — it decodes \xNN or %NN and must \
                       not spell one",
        },
    ];
    check_all(tree, &claims)
}

#[cfg(test)]
mod tests {
    use crate::tests::Fixture;

    #[test]
    fn the_plain_text_pass_stays_one_grammar() {
        let fixture = Fixture::new("byte-scanners-plaintext");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    super::SWIFT_STRIPPER,
                    "slopdesk_plaintext_strip\nslopdesk_plaintext_holdback\n",
                )
                .write(super::SWIFT_WAIT, "kept so the ban has a haystack\n")
                .write(
                    "rust/slopdesk-sanitize/src/plaintext.rs",
                    "pub fn holdback_start\n",
                )
                .write("rust/slopdesk-sanitize/src/vtscan.rs", "pub const fn lenient\n");
        };
        seed(&fixture);
        assert!(super::one_vt_grammar_for_plain_text(&fixture.tree()).is_clean());

        fixture.write("rust/slopdesk-sanitize/src/plaintext.rs", "");
        assert!(!super::one_vt_grammar_for_plain_text(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.append(super::SWIFT_STRIPPER, "func skipCSI() {}\n");
        assert!(!super::one_vt_grammar_for_plain_text(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_shell_word_has_one_quoter() {
        let fixture = Fixture::new("byte-scanners-shell-word");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::SWIFT_QUOTING, "slopdesk_ws_shell_quote\n")
                .write(
                    "Sources/SlopDeskWorkspaceCore/Terminal/PasteTransform.swift",
                    "kept so the ban has a haystack\n",
                )
                .write("rust/slopdesk-ids/src/shell_quoting.rs", "pub fn shlex_quoted\n")
                .write(
                    "rust/slopdesk-workspace/src/templates.rs",
                    "kept so the ban has a haystack\n",
                );
        };
        seed(&fixture);
        assert!(super::one_shell_word_wherever_a_path_is_typed(&fixture.tree()).is_clean());

        fixture.write(super::SWIFT_QUOTING, "");
        assert!(!super::one_shell_word_wherever_a_path_is_typed(&fixture.tree()).is_clean());

        // The emitter's private copy, back.
        seed(&fixture);
        fixture.append(
            "rust/slopdesk-workspace/src/templates.rs",
            "fn shell_quoted(path: &str)\n",
        );
        assert!(!super::one_shell_word_wherever_a_path_is_typed(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_width_table_stays_the_only_one() {
        let fixture = Fixture::new("byte-scanners-width");
        let seed = |fixture: &Fixture| {
            fixture
                .write(
                    "rust/slopdesk-sanitize/src/width.rs",
                    "pub const fn scalar_width\n0x4E00\n",
                )
                .write(
                    "rust/slopdesk-terminal/src/link.rs",
                    "use slopdesk_sanitize::width::scalar_width\n",
                );
        };
        seed(&fixture);
        assert!(super::one_width_table_under_that_clustering(&fixture.tree()).is_clean());

        // The exempt file may spell the sentinel; anyone else spelling it has a second table.
        fixture.append("rust/slopdesk-terminal/src/link.rs", "const CJK: u32 = 0x4E00;\n");
        assert!(!super::one_width_table_under_that_clustering(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write("rust/slopdesk-terminal/src/link.rs", "");
        assert!(!super::one_width_table_under_that_clustering(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_escape_grammar_stays_the_only_one() {
        let fixture = Fixture::new("byte-scanners-escape-end");
        let seed = |fixture: &Fixture| {
            fixture
                .write("rust/slopdesk-sanitize/src/vtscan.rs", "pub fn parse_csi\n")
                .write(
                    "rust/slopdesk-altscreen/src/lib.rs",
                    "use slopdesk_sanitize::vtscan\n",
                )
                .write(super::SWIFT_SYNC_INPUT, "slopdesk_sync_input_keyboard_only\n");
        };
        seed(&fixture);
        assert!(super::one_grammar_for_where_an_escape_ends(&fixture.tree()).is_clean());

        // A fifth copy in Rust.
        fixture.append(
            "rust/slopdesk-altscreen/src/lib.rs",
            "fn parse_csi(bytes: &[u8])\n",
        );
        assert!(!super::one_grammar_for_where_an_escape_ends(&fixture.tree()).is_clean());

        // And the sixth, in Swift, on the input path.
        seed(&fixture);
        fixture.append(super::SWIFT_SYNC_INPUT, "func parseCSI() {}\n");
        assert!(!super::one_grammar_for_where_an_escape_ends(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_find_bar_keeps_asking_the_engine() {
        let fixture = Fixture::new("byte-scanners-find");
        let seed = |fixture: &Fixture| {
            fixture
                .write(super::SWIFT_FIND, "slopdesk_find_matches\n")
                .write("rust/slopdesk-rowscan/src/find.rs", "pub fn matches\n");
        };
        seed(&fixture);
        assert!(super::the_find_bar_asks_the_same_engine(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.append(super::SWIFT_FIND, "NSRegularExpression(pattern:)\n");
        assert!(!super::the_find_bar_asks_the_same_engine(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_base64_alphabet_and_the_shape_count_stay_where_they_are() {
        let fixture = Fixture::new("byte-scanners-base64");
        let seed = |fixture: &Fixture| {
            fixture
                .write("rust/slopdesk-wire/Cargo.toml", "\nbase64 = \"0.22\"\n")
                .write("rust/slopdesk-superd/Cargo.toml", "\nbase64 = \"0.22\"\n")
                .write("rust/slopdesk-workspace/Cargo.toml", "\nregex = \"1\"\n")
                .write(
                    "rust/slopdesk-workspace/src/secrets.rs",
                    "const PATTERNS: [(&str, Action); 11] = [];\n",
                );
        };
        seed(&fixture);
        assert!(super::one_base64_and_one_secret_notation(&fixture.tree()).is_clean());

        // A twelfth shape means the redactor and the crate no longer agree on what a secret is.
        fixture.write(
            "rust/slopdesk-workspace/src/secrets.rs",
            "const PATTERNS: [(&str, Action); 12] = [];\n",
        );
        assert!(!super::one_base64_and_one_secret_notation(&fixture.tree()).is_clean());

        // And a fourth codec, given away by its alphabet.
        seed(&fixture);
        fixture.write(
            "rust/slopdesk-superd/src/b64.rs",
            "const A: &str = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";\n",
        );
        assert!(!super::one_base64_and_one_secret_notation(&fixture.tree()).is_clean());
    }

    #[test]
    fn the_escape_decoder_has_one_home() {
        let fixture = Fixture::new("byte-scanners-hex");
        let seed = |fixture: &Fixture| {
            fixture
                .write("rust/slopdesk-sanitize/src/escape.rs", "fn hex_nibble(b: u8)\n")
                .write(
                    "rust/slopdesk-superd/Cargo.toml",
                    "\nslopdesk-sanitize = { path = \"..\" }\n",
                )
                .write(
                    "rust/slopdesk-terminal/Cargo.toml",
                    "\nslopdesk-sanitize = { path = \"..\" }\n",
                );
        };
        seed(&fixture);
        assert!(super::one_reading_of_an_escape(&fixture.tree()).is_clean());

        fixture.write(
            "rust/slopdesk-superd/src/seg.rs",
            "fn hex_value(b: u8) -> u8 { 0 }\n",
        );
        assert!(!super::one_reading_of_an_escape(&fixture.tree()).is_clean());

        seed(&fixture);
        fixture.write("rust/slopdesk-terminal/Cargo.toml", "");
        assert!(!super::one_reading_of_an_escape(&fixture.tree()).is_clean());
    }
}
