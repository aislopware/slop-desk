//! `collapse` — the progress-bar churn pass of the replay transform.

#![expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::format_push_string,
    clippy::integer_division,
    reason = "these tests BUILD terminal streams: `push_str(&format!(..))` is how a fixture reads, and an \
              integer percentage is the arithmetic a progress reporter actually does"
)]

use slopdesk_screend::{ScreenModel, collapse};

const ESC: &str = "\u{1B}";

fn collapse_str(input: &str) -> String {
    String::from_utf8(collapse(input.as_bytes())).expect("collapsed output is still utf-8")
}

/// A scrollback ring opens at an arbitrary byte offset, so the column its first line starts in is
/// unknown and that line is never collapsed. A leading `CRLF` — what the PTY's `ONLCR` puts at the
/// end of every real line anyway — anchors column 0; this returns what the pass did to everything
/// AFTER it.
#[track_caller]
fn collapse_anchored(input: &str) -> String {
    let result = collapse_str(&format!("\r\n{input}"));
    assert!(result.starts_with("\r\n"), "anchor must survive");
    result[2..].to_owned()
}

// MARK: Nothing to collapse

#[test]
fn empty_input_passes_through() {
    assert_eq!(collapse(b""), b"");
}

#[test]
fn a_plain_transcript_is_byte_identical() {
    let transcript = format!("first line\nsecond line\r\nthird\twith tab\n{ESC}[31mred{ESC}[0m\n");
    assert_eq!(collapse_str(&transcript), transcript);
}

#[test]
fn crlf_line_endings_survive() {
    assert_eq!(collapse_str("alpha\r\nbeta\r\n"), "alpha\r\nbeta\r\n");
}

// MARK: The point of the pass

#[test]
fn progress_churn_collapses_to_the_last_revision() {
    let mut churn = String::new();
    for percent in 0..=100 {
        churn.push_str(&format!("Writing objects: {percent}% (37/3700)\r"));
    }
    churn.push_str("Writing objects: 100% (3700/3700), done.\n");
    assert_eq!(
        collapse_anchored(&churn),
        "\rWriting objects: 100% (3700/3700), done.\n"
    );
}

/// An erase-and-repaint loop collapses to its LAST erase plus the final text: that erase blanks
/// columns no successor touches, so it is what put them in their final state.
#[test]
fn erase_in_line_churn_collapses_to_the_last_revision() {
    let mut churn = String::new();
    for percent in 0..=50 {
        churn.push_str(&format!("{ESC}[2K\r[{percent}/50] Compiling Foo.swift"));
    }
    churn.push_str(&format!("{ESC}[2K\rBuild complete!\n"));
    assert_eq!(
        collapse_anchored(&churn),
        format!("\r[50/50] Compiling Foo.swift{ESC}[2K\rBuild complete!\n")
    );
}

/// A revision that only ERASES is never dropped for showing nothing — its blanking decides those
/// columns, and dropping it would resurrect what it wiped.
#[test]
fn an_erase_only_revision_is_not_dropped_as_invisible() {
    let input = format!("aaa{ESC}[1Gbbbbb{ESC}[1G{ESC}[1K\r\n");
    assert_eq!(
        collapse_anchored(&input),
        format!("{ESC}[1Gbbbbb{ESC}[1G{ESC}[1K\r\n")
    );
}

/// `CSI 1 K` erases only to the LEFT of the cursor, so it cannot hide a wider predecessor.
#[test]
fn erase_to_cursor_does_not_cover_a_wider_predecessor() {
    assert_eq!(
        collapse_anchored(&format!("aaaaaa\rbb{ESC}[1K\n")),
        format!("aaaaaa\rbb{ESC}[1K\n")
    );
}

/// `CSI 0 K` clears through the line's end, so everything before it is gone — but its own paint to
/// the LEFT of the cursor survives.
#[test]
fn erase_to_end_covers_predecessors_but_keeps_its_own_paint() {
    assert_eq!(
        collapse_anchored(&format!("aaaaaa\rbb{ESC}[K\n")),
        format!("\rbb{ESC}[K\n")
    );
    assert_eq!(
        collapse_anchored(&format!("aaaaaa\rbb{ESC}[K\rc\n")),
        format!("\rbb{ESC}[K\rc\n")
    );
}

#[test]
fn a_column_zero_cha_is_a_revision_boundary_like_cr() {
    assert_eq!(
        collapse_anchored(&format!("aaaa{ESC}[Gbbbb{ESC}[1Gcccc\n")),
        format!("{ESC}[1Gcccc\n")
    );
}

/// A shorter successor does NOT cover a longer predecessor — a real terminal leaves the tail on
/// screen, and so must the replay.
#[test]
fn a_wider_predecessor_survives_a_shorter_successor() {
    assert_eq!(collapse_anchored("aaaaaa\rbb\n"), "aaaaaa\rbb\n");
}

#[test]
fn an_equal_width_successor_covers_its_predecessor() {
    assert_eq!(collapse_anchored("aaa\rbbb\n"), "\rbbb\n");
}

/// Coverage is DISPLAY width: two wide scalars cover four ASCII columns.
#[test]
fn wide_scalars_count_as_two_columns() {
    assert_eq!(collapse_anchored("abcd\r日本\n"), "\r日本\n");
    assert_eq!(collapse_anchored("abcde\r日本\n"), "abcde\r日本\n");
}

#[test]
fn churn_across_separate_lines_collapses_independently() {
    assert_eq!(
        collapse_anchored("a\rbb\r\nccc\rd\r\nee\rff\r\n"),
        "\rbb\r\nccc\rd\r\n\rff\r\n"
    );
}

// MARK: Where the line starts

/// The ring opens at an arbitrary byte offset, so the first line's column is unknown and its
/// opening revision may extend past anything a successor covers — it is never dropped.
#[test]
fn the_opening_line_of_the_buffer_is_never_dropped() {
    assert_eq!(collapse_str("aaa\rbbb\n"), "aaa\rbbb\n");
}

/// A bare `LF` moves DOWN without returning to column 0 (the PTY's `ONLCR` is what normally makes
/// it `CRLF`), so the next line's opening revision paints from that column — and its tail survives
/// a shorter successor.
#[test]
fn a_bare_lf_carries_the_column_to_the_next_line() {
    assert_eq!(collapse_anchored("a\rbb\nccc\rd\n"), "\rbb\nccc\rd\n");
}

/// After an unmodelled (verbatim) line the cursor column is a guess, so the next line's opening
/// revision is kept too — the guess is never allowed to drop visible content. The line after THAT
/// ends in `CRLF`, which re-anchors column 0, and collapsing resumes.
#[test]
fn the_column_is_unknown_after_a_verbatim_line_then_recovers() {
    assert_eq!(
        collapse_anchored(&format!("aaa{ESC}[1Abbb\nccc\rccc\r\nddd\reee\r\n")),
        format!("aaa{ESC}[1Abbb\nccc\rccc\r\n\reee\r\n")
    );
}

// MARK: Carried state

#[test]
fn sgr_from_a_dropped_revision_is_carried_to_the_survivor() {
    // The colour is set in the dropped first revision; the survivor never re-states it.
    assert_eq!(
        collapse_anchored(&format!("{ESC}[31mred\rgrn\n")),
        format!("\r{ESC}[31mgrn\n")
    );
}

#[test]
fn neutral_private_modes_are_carried() {
    assert_eq!(
        collapse_anchored(&format!("{ESC}[?25lwork\rdone\n")),
        format!("\r{ESC}[?25ldone\n")
    );
}

#[test]
fn carried_state_is_ordered_oldest_first() {
    assert_eq!(
        collapse_anchored(&format!("{ESC}[31ma\r{ESC}[1mb\rc\n")),
        format!("\r{ESC}[31m{ESC}[1mc\n")
    );
}

/// A full SGR reset kills every carried attribute before it — only state set after the reset
/// remains load-bearing.
#[test]
fn an_sgr_reset_collapses_the_carried_attributes() {
    assert_eq!(
        collapse_anchored(&format!("{ESC}[31m{ESC}[1ma\r{ESC}[0m{ESC}[32mb\rc\n")),
        format!("\r{ESC}[0m{ESC}[32mc\n")
    );
}

/// A toggle is STATE, not a byte stream: only its last setting is carried.
#[test]
fn carried_toggles_keep_their_last_setting_only() {
    assert_eq!(
        collapse_anchored(&format!("{ESC}[?25la\r{ESC}[?25hb\rc\n")),
        format!("\r{ESC}[?25hc\n")
    );
}

/// The carry cap must not eat a one-shot toggle: `?25l` set once survives thousands of dropped
/// SGR-bearing revisions, because the toggles are held as state OUTSIDE the byte cap.
#[test]
fn a_hidden_cursor_survives_a_carry_cap_overflow() {
    let mut input = format!("{ESC}[?25lstart");
    for i in 0..1200 {
        input.push_str(&format!("\r{ESC}[3{}mprogress", i % 8));
    }
    input.push_str("\rlast-one\n");
    let out = collapse_anchored(&input);
    assert!(
        out.contains(&format!("{ESC}[?25l")),
        "hidden-cursor toggle lost by the carry cap"
    );
    assert!(out.ends_with("last-one\n"));
}

// MARK: Bail-outs — never cleaner than raw, never wrong

#[test]
fn a_cursor_up_makes_the_line_verbatim() {
    let input = format!("one\rtwo{ESC}[1A\n");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn an_osc_mark_makes_the_line_verbatim_so_the_distiller_keeps_its_marks() {
    let input = format!("{ESC}]133;A\u{07}% {ESC}]133;B\u{07}aaa\rbbb\n");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn a_cr_inside_an_osc_body_is_not_a_revision_boundary() {
    let input = format!("{ESC}]0;a\rb\u{07}text\n");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn a_non_neutral_private_mode_makes_the_line_verbatim() {
    let input = format!("aaa{ESC}[?1049h\rbbb\n");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn a_backspace_makes_the_line_verbatim() {
    let input = "aaa\u{08}\rbbb\n";
    assert_eq!(collapse_str(input), input);
}

#[test]
fn a_two_byte_escape_makes_the_line_verbatim() {
    let input = format!("aaa{ESC}M\rbbb\n");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn a_vertical_tab_flushes_the_line_verbatim() {
    let input = "aaa\rbbb\u{0B}ccc\rddd\n";
    assert_eq!(collapse_anchored(input), input);
}

#[test]
fn malformed_utf8_makes_the_line_verbatim() {
    let input: &[u8] = &[0x61, 0xFF, 0x62, 0x0D, 0x63, 0x0A];
    assert_eq!(collapse(input), input);
}

/// Overlong UTF-8 (structurally complete, semantically invalid — `E0 80 80` is an overlong
/// `U+0000`) gets NO width credit: a terminal rejects it and paints nothing, so crediting it
/// coverage would let a successor bury a predecessor whose residue is still on screen.
#[test]
fn overlong_utf8_makes_the_line_verbatim() {
    let mut input = b"\r\nabcd\rxxx".to_vec();
    input.extend_from_slice(&[0xE0, 0x80, 0x80, b'\n']);
    assert_eq!(collapse(&input), input);
}

/// A revision OPENED by a zero-width scalar (combining mark, ZWJ, variation selector) attaches that
/// scalar to the last printed cell — a PREDECESSOR's cell. Dropping the predecessor would re-target
/// the mark, so the line is verbatim.
#[test]
fn a_revision_opened_by_a_combining_mark_is_verbatim() {
    let input = "\r\nQ\r\nab\r\u{0301}xy\n";
    assert_eq!(collapse_str(input), input);
}

/// A combining mark AFTER a painted glyph stays inside its own revision — no bail-out.
#[test]
fn a_combining_mark_after_paint_still_collapses() {
    assert_eq!(collapse_anchored("abc\re\u{0301}xy\n"), "\re\u{0301}xy\n");
}

/// The opening revision survives even a successor that erases the WHOLE line: its start column is
/// unknown (the ring opened mid-stream), so its paint may have wrapped onto an extra row at
/// recording time that no same-line erase can be proven to bury.
#[test]
fn the_opening_revision_survives_a_full_coverage_successor() {
    let input = format!("aaa\rbbb{ESC}[2K\n");
    assert_eq!(collapse_str(&input), input);
}

/// An UNSAFE line keeps its byte-for-byte guarantee past the compaction threshold: compaction must
/// not fire once modelling has failed (its coverage numbers are garbage there), no matter how many
/// `CR` revisions pile up afterwards.
#[test]
fn an_unsafe_line_survives_the_compaction_threshold_verbatim() {
    let mut input = format!("start{ESC}[1Aup");
    for i in 0..70_000 {
        input.push_str(&format!("\rrev{}", i % 10));
    }
    input.push('\n');
    assert_eq!(collapse_anchored(&input), input);
}

#[test]
fn a_truncated_trailing_escape_is_preserved() {
    let input = format!("aaa\rbbb{ESC}[");
    assert_eq!(collapse_str(&input), input);
}

#[test]
fn an_unterminated_final_line_still_collapses() {
    assert_eq!(collapse_anchored("aaa\rbbb"), "\rbbb");
}

// MARK: Differential — the rendered screen must not change

/// The load-bearing claim of the pass: what a terminal DISPLAYS after the collapsed stream is what
/// it displays after the raw one. Rendered by [`ScreenModel`] at a grid every revision fits inside
/// (the documented autowrap gap lives outside this claim).
#[track_caller]
fn assert_renders_identically(stream: &str) {
    let raw = stream.as_bytes();
    let collapsed = collapse(raw);
    let mut raw_model = ScreenModel::new(24, 80);
    raw_model.feed(raw);
    let mut collapsed_model = ScreenModel::new(24, 80);
    collapsed_model.feed(&collapsed);
    assert_eq!(
        collapsed_model.snapshot().lines,
        raw_model.snapshot().lines,
        "collapsed replay renders differently"
    );
    assert!(collapsed.len() <= raw.len(), "never longer than raw");
}

#[test]
fn cr_progress_renders_identically() {
    let mut stream = String::new();
    for percent in 0..=100 {
        stream.push_str(&format!("Enumerating objects: {percent}% (37/3700)\r"));
    }
    stream.push_str("Enumerating objects: 100% (3700/3700), done.\n");
    assert_renders_identically(&stream);
}

#[test]
fn erase_line_progress_renders_identically() {
    let mut stream = String::new();
    for step in 0..=50 {
        stream.push_str(&format!("{ESC}[2K\r[{step}/50] Compiling Foo.swift"));
    }
    stream.push_str(&format!("{ESC}[2K\rBuild complete!\n"));
    assert_renders_identically(&stream);
}

#[test]
fn surviving_residue_renders_identically() {
    assert_renders_identically("a very long progress line\rshort\nnext\n");
}

#[test]
fn a_coloured_spinner_renders_identically() {
    let frames = ["|", "/", "-", "\\"];
    let mut stream = format!("{ESC}[?25l");
    for tick in 0..40 {
        stream.push_str(&format!(
            "{ESC}[3{}m{} building {tick}%{ESC}[K\r",
            tick % 8,
            frames[tick % 4]
        ));
    }
    stream.push_str(&format!("{ESC}[0m{ESC}[?25hdone\n"));
    assert_renders_identically(&stream);
}

#[test]
fn a_mixed_transcript_renders_identically() {
    let mut stream = "$ swift build\n".to_owned();
    for step in 0..=30 {
        stream.push_str(&format!("{ESC}[2K\r[{step}/30] Compiling{ESC}[1;32m X{ESC}[0m"));
    }
    stream.push_str(&format!("{ESC}[2K\rBuild complete! (12.3s)\n"));
    stream.push_str("$ git push\n");
    for percent in (0..=100).step_by(5) {
        stream.push_str(&format!("Writing objects: {percent}%\r"));
    }
    stream.push_str("Writing objects: 100%, done.\nTo github.com:x/y.git\n");
    assert_renders_identically(&stream);
}

/// Modelling failure AFTER the memory backstop compacted: the buffered survivors are emitted
/// verbatim (everything compaction dropped was dropped while the line was still modelled, so the
/// screen is unchanged), and the unmodelled bytes ride along untouched.
#[test]
fn an_unsafe_line_after_compaction_still_renders_identically() {
    let mut stream = String::new();
    for i in 0..66_000 {
        stream.push_str(&format!("progress {}\r", i % 100));
    }
    stream.push_str(&format!("tail{ESC}[1A{ESC}[1Bdone\n"));
    assert_renders_identically(&stream);
}

/// Seeded fuzz over the vocabulary this pass reasons about — text, the column-0 resets, all three
/// erases, carried state, and sequences that must force the verbatim fallback. Every generated
/// stream must render identically before and after collapsing. Deterministic (fixed seed) so a
/// failure is reproducible; the generator keeps every line inside the grid, since wrapping is the
/// documented gap rather than a claim under test.
#[test]
fn fuzzed_streams_render_identically() {
    let mut rng = SplitMix64 {
        state: 0x51_0BDE_5C15_10BD,
    };
    for iteration in 0..2000 {
        let stream = random_stream(&mut rng);
        let raw = stream.as_bytes();
        let collapsed = collapse(raw);
        let mut raw_model = ScreenModel::new(24, 80);
        raw_model.feed(raw);
        let mut collapsed_model = ScreenModel::new(24, 80);
        collapsed_model.feed(&collapsed);
        assert_eq!(
            collapsed_model.snapshot().lines,
            raw_model.snapshot().lines,
            "iteration {iteration} renders differently: {stream:?}"
        );
        assert!(collapsed.len() <= raw.len(), "iteration {iteration} grew");
    }
}

/// Splitmix64 — a two-line deterministic generator, so a fuzz failure reproduces exactly.
struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn next(&mut self, bound: usize) -> usize {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        usize::try_from(z % bound as u64).unwrap_or(0)
    }
}

fn random_stream(rng: &mut SplitMix64) -> String {
    // Widths are tracked so no line ever reaches the 80th column: autowrap is the pass's documented
    // gap, not a property under test.
    const WRAP_GUARD: usize = 60;
    let mut stream = String::new();
    let mut column = 0usize;
    let atoms = 20 + rng.next(60);
    for _ in 0..atoms {
        match rng.next(14) {
            0..=3 => {
                // printable run
                let width = 1 + rng.next(10);
                if column + width > WRAP_GUARD {
                    stream.push_str("\r\n");
                    column = 0;
                }
                for _ in 0..width {
                    stream.push(char::from(u8::try_from(97 + rng.next(26)).unwrap_or(b'a')));
                }
                column += width;
            },
            4 => {
                // wide scalars — two columns each
                if column + 4 > WRAP_GUARD {
                    stream.push_str("\r\n");
                    column = 0;
                }
                stream.push_str("日本");
                column += 4;
            },
            5 | 6 => {
                stream.push('\r');
                column = 0;
            },
            7 => {
                stream.push_str("\r\n");
                column = 0;
            },
            8 => stream.push('\n'), // bare LF — moves down, keeps the column
            9 => stream.push_str(&format!("{ESC}[{}K", rng.next(3))), // EL modes 0/1/2
            10 => stream.push_str(&format!("{ESC}[{}m", 30 + rng.next(8))),
            11 => {
                let toggle = if rng.next(2) == 0 {
                    "\u{1B}[?25l"
                } else {
                    "\u{1B}[?7h"
                };
                stream.push_str(toggle);
            },
            12 => {
                stream.push_str(&format!("{ESC}[1G"));
                column = 0;
            },
            // sequences that must force the verbatim fallback
            _ => {
                match rng.next(4) {
                    0 => stream.push_str(&format!("{ESC}[1A")),
                    1 => stream.push_str(&format!("{ESC}]0;title\u{07}")),
                    2 => {
                        stream.push('\t');
                        column = (column / 8 + 1) * 8;
                    },
                    _ => stream.push_str(&format!("{ESC}[?1049h{ESC}[?1049l")),
                }
            },
        }
    }
    stream
}
