//! `render` / `render_transcript` — the cold-reattach state-transfer path: render the model's STATE
//! once instead of replaying byte history.
//!
//! The proof discipline is differential + idempotent (the overprint-collapser habit):
//! - **Round trip**: feeding `render(A)` to a FRESH model must reproduce A's visible state (grid
//!   text + styles, scrollback text, cursor, modes).
//! - **Canonicalization**: `render(feed(render(A))) == render(A)` byte-exact — over curated cases
//!   AND seeded fuzz streams spanning the VT vocabulary.
//!
//! Pure model tests: bytes in → bytes out. No PTY, no socket, no session.

#![expect(
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::format_push_string,
    clippy::integer_division,
    reason = "these tests BUILD terminal streams: `push_str(&format!(..))` is how a fixture reads, and an \
              integer percentage is the arithmetic a progress reporter actually does"
)]

use slopdesk_screend::cell::SgrColor;
use slopdesk_screend::{ScreenModel, render, render_transcript};

const ESC: &str = "\u{1B}";
/// The composer's scrollback budget, mirrored so the tests exercise the production geometry.
const SCROLLBACK_BUDGET: usize = 10_000;

fn model_from(input: &[u8], rows: usize, cols: usize) -> ScreenModel {
    let mut model = ScreenModel::with_scrollback(rows, cols, 1000);
    model.feed(input);
    model
}

/// The `Verb::Transcript` pipeline, as the server runs it.
fn compose_transcript(raw: &[u8], rows: usize, cols: usize) -> Vec<u8> {
    let mut model = ScreenModel::with_scrollback(rows, cols, SCROLLBACK_BUDGET);
    model.feed(raw);
    render_transcript(&model.replay_snapshot())
}

/// Round-trips `input` through render → fresh model and asserts the VISIBLE state matches: cell
/// text
/// + styles for both screens, scrollback cells, cursor, wrap, modes.
///
/// (Soft-wrap FLAGS are excluded: a full-width line printed with an explicit CRLF is visually
/// identical to a wrapped one but carries no flag — both render the same bytes, which the
/// idempotence assertion pins.)
#[track_caller]
fn assert_round_trip(input: &[u8], rows: usize, cols: usize) {
    let a = model_from(input, rows, cols);
    let sa = a.replay_snapshot();
    let rendered_a = render(&sa, &[]);
    let b = model_from(&rendered_a, rows, cols);
    let sb = b.replay_snapshot();

    assert_eq!(sa.main_cells, sb.main_cells, "main grid diverged");
    assert_eq!(sa.using_alt, sb.using_alt);
    // The INACTIVE alt grid is invisible state the renderer deliberately does not transfer
    // (`?1049h` clears on re-entry); compare it only while active.
    if sa.using_alt {
        assert_eq!(sa.alt_cells, sb.alt_cells, "alt grid diverged");
    }
    let cells_a: Vec<_> = sa.scrollback.iter().map(|line| &line.cells).collect();
    let cells_b: Vec<_> = sb.scrollback.iter().map(|line| &line.cells).collect();
    assert_eq!(cells_a, cells_b, "scrollback diverged");
    // OSC 133 `A` prompt marks are visible state for `jump_to_prompt` even though they paint
    // nothing — a re-feed of the render must land them on the SAME rows, or a state-transferred
    // pane's command-ladder jumps go to the wrong command (or nowhere).
    assert_eq!(sa.main_prompt, sb.main_prompt, "main prompt marks diverged");
    let prompts_a: Vec<_> = sa.scrollback.iter().map(|line| line.is_prompt).collect();
    let prompts_b: Vec<_> = sb.scrollback.iter().map(|line| line.is_prompt).collect();
    assert_eq!(prompts_a, prompts_b, "scrollback prompt marks diverged");
    assert_eq!(sa.cursor_row, sb.cursor_row, "cursor_row");
    assert_eq!(sa.cursor_col, sb.cursor_col, "cursor_col");
    assert_eq!(sa.wrap_pending, sb.wrap_pending, "wrap_pending");
    assert_eq!(sa.cursor_visible, sb.cursor_visible);
    assert_eq!(sa.autowrap, sb.autowrap);
    assert_eq!(sa.origin_mode, sb.origin_mode);
    assert_eq!(sa.scroll_top, sb.scroll_top);
    assert_eq!(sa.scroll_bottom, sb.scroll_bottom);
    assert_eq!(sa.g0_graphics, sb.g0_graphics);
    assert_eq!(sa.g1_graphics, sb.g1_graphics);
    assert_eq!(sa.using_g1, sb.using_g1);
    assert_eq!(sa.application_keypad, sb.application_keypad);
    assert_eq!(sa.cursor_shape, sb.cursor_shape, "DECSCUSR shape");
    assert_eq!(sa.style, sb.style, "live SGR");
    // Canonicalization: rendering the round-tripped model reproduces the SAME bytes.
    assert_eq!(rendered_a, render(&sb, &[]), "render is not idempotent");
}

#[track_caller]
fn round_trip(input: &str) {
    assert_round_trip(input.as_bytes(), 6, 12);
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

// MARK: Round trip — text, styles, scrollback

#[test]
fn a_plain_prompt_round_trips() {
    round_trip("$ ls\r\nREADME.md  Sources\r\n$ ");
}

#[test]
fn scrollback_capture_round_trips() {
    // 10 numbered lines through a 6-row grid: 4 lines scroll into history.
    let input = (1..=10)
        .map(|n| format!("line {n}"))
        .collect::<Vec<_>>()
        .join("\r\n");
    let a = model_from(input.as_bytes(), 6, 12);
    assert_eq!(a.replay_snapshot().scrollback.len(), 4);
    assert_round_trip(input.as_bytes(), 6, 12);
}

#[test]
fn colours_16_256_and_truecolour_round_trip() {
    round_trip(&format!(
        "{ESC}[31mred{ESC}[0m {ESC}[1;38;5;196mbright{ESC}[0m\r\n{ESC}[48;2;10;20;30mrgb bg{ESC}[0m plain \
         {ESC}[93;104mbright16{ESC}[0m"
    ));
}

#[test]
fn the_colon_form_of_sgr_round_trips() {
    // 4:3 (undercurl → underline sub-param) must not misparse `3` as italic; colon-form truecolour
    // with a colourspace id decodes to the same colour as the semicolon form.
    round_trip(&format!("{ESC}[4:3mcurl{ESC}[0m {ESC}[38:2::7;8;9mmix{ESC}[0m x"));
    let mut model = ScreenModel::with_scrollback(2, 20, 0);
    model.feed(format!("{ESC}[38:2:1:2:3mX").as_bytes());
    assert_eq!(
        model.replay_snapshot().main_cells[0][0].style.fg,
        SgrColor::Rgb(1, 2, 3)
    );
    model.feed(format!("{ESC}[4:0mY").as_bytes());
    // 4:0 = underline-off — must NOT have reset the truecolour fg via a bare `0`.
    assert_eq!(
        model.replay_snapshot().main_cells[0][1].style.fg,
        SgrColor::Rgb(1, 2, 3)
    );
}

#[test]
fn a_bce_erase_fill_carries_the_background() {
    let raw = format!("{ESC}[44m{ESC}[2Jx");
    let mut model = ScreenModel::with_scrollback(3, 8, 0);
    model.feed(raw.as_bytes());
    let snap = model.replay_snapshot();
    assert_eq!(
        snap.main_cells[1][3].style.bg,
        SgrColor::Indexed(4),
        "ED 2 must fill with the live bg"
    );
    assert_eq!(snap.main_cells[0][0].text.or_space(), "x");
    assert_round_trip(raw.as_bytes(), 6, 12);
}

#[test]
fn wide_chars_and_combining_marks_round_trip() {
    round_trip("日本語テスト wide\r\ne\u{0301}combined");
}

#[test]
fn a_soft_wrapped_scrollback_line_is_re_joined() {
    // A 30-char line through a 12-col grid wraps onto 3 rows; scroll it fully into history and the
    // renderer must emit ONE logical line (client re-wraps at its width).
    let long = "abcdefghij".repeat(3);
    let tail = (1..=8).map(|n| format!("l{n}")).collect::<Vec<_>>().join("\r\n");
    let input = format!("{long}\r\n{tail}");
    let a = model_from(input.as_bytes(), 6, 12);
    let rendered = render(&a.replay_snapshot(), &[]);
    // The logical line survives as one contiguous run in the output.
    assert!(text(&rendered).contains(&long));
    assert_round_trip(input.as_bytes(), 6, 12);
}

// MARK: Round trip — screen state

#[test]
fn the_alt_screen_round_trips() {
    // vim-like: enter 1049, paint a status line at the bottom, cursor home.
    round_trip(&format!(
        "shell history\r\n{ESC}[?1049h{ESC}[6;1H{ESC}[7m-- STATUS --{ESC}[0m{ESC}[H"
    ));
}

#[test]
fn leaving_the_alt_screen_restores_main() {
    round_trip(&format!("before\r\n{ESC}[?1049htui{ESC}[?1049lafter"));
}

#[test]
fn a_scroll_region_with_origin_mode_round_trips() {
    round_trip(&format!("{ESC}[2;5r{ESC}[?6hinside\r\nregion"));
}

#[test]
fn deferred_wrap_survives_the_snapshot() {
    // Fill the last column exactly: wrap_pending must survive so the next printable in the LIVE tail
    // wraps (and a CR stays on the same row).
    assert_round_trip(b"0123456789AB", 3, 12);
}

#[test]
fn deferred_wrap_with_a_wide_lead_survives() {
    // The wide char occupies the last two columns; re-arming must re-print the LEAD.
    assert_round_trip("0123456789日".as_bytes(), 3, 12);
}

#[test]
fn a_hidden_cursor_and_disabled_autowrap_round_trip() {
    round_trip(&format!("{ESC}[?25l{ESC}[?7lhidden"));
}

#[test]
fn the_dec_graphics_charset_round_trips() {
    round_trip(&format!("{ESC}(0lqqk\r\nx x"));
}

#[test]
fn the_application_keypad_round_trips() {
    round_trip(&format!("{ESC}=app keypad"));
}

#[test]
fn the_cursor_shape_survives_the_snapshot() {
    // The zsh integration's bar-at-prompt (`ESC[5 q` from precmd) must survive a state-transfer
    // reattach — the raw history carried it, so the snapshot must too.
    round_trip(&format!("$ ls\r\n{ESC}[5 q$ "));
    let model = model_from(format!("{ESC}[5 qprompt").as_bytes(), 6, 12);
    assert_eq!(model.replay_snapshot().cursor_shape, 5);
    let rendered = render(&model.replay_snapshot(), &[]);
    assert!(
        text(&rendered).contains(&format!("{ESC}[5 q")),
        "rendered snapshot must re-emit DECSCUSR"
    );
}

#[test]
fn a_cursor_shape_reset_and_ris_both_drop_to_the_default() {
    // `0 q` (the preexec reset) and RIS both return to the terminal default — nothing re-emitted
    // beyond the preamble's own `0 q` wipe.
    let reset = model_from(format!("{ESC}[5 qx{ESC}[0 q").as_bytes(), 6, 12);
    assert_eq!(reset.replay_snapshot().cursor_shape, 0);
    let ris = model_from(format!("{ESC}[5 qx{ESC}c").as_bytes(), 6, 12);
    assert_eq!(ris.replay_snapshot().cursor_shape, 0);
}

#[test]
fn progress_overprint_collapses_to_the_final_revision() {
    // The motivating case: 200 CR-overprinted progress ticks render as ONE line.
    let mut input = String::new();
    for pct in 0..=200 {
        input.push_str(&format!("Progress {}%\r", pct / 2));
    }
    input.push_str("\r\nDone.\r\n$ ");
    let a = model_from(input.as_bytes(), 6, 40);
    let rendered = text(&render(&a.replay_snapshot(), &[]));
    assert_eq!(rendered.matches("Progress").count(), 1, "one revision survives");
    assert_round_trip(input.as_bytes(), 6, 40);
}

// MARK: ED 3 / scrollback cap

#[test]
fn ed_3_clears_the_captured_scrollback() {
    let input = (1..=10)
        .map(|n| format!("line {n}"))
        .collect::<Vec<_>>()
        .join("\r\n")
        + ESC
        + "[3J";
    assert!(
        model_from(input.as_bytes(), 6, 12)
            .replay_snapshot()
            .scrollback
            .is_empty()
    );
}

#[test]
fn the_scrollback_cap_evicts_the_oldest() {
    let mut model = ScreenModel::with_scrollback(3, 8, 5);
    let input = (1..=20).map(|n| format!("l{n}")).collect::<Vec<_>>().join("\r\n");
    model.feed(input.as_bytes());
    let scrollback = model.replay_snapshot().scrollback;
    assert_eq!(scrollback.len(), 5);
    assert_eq!(scrollback[scrollback.len() - 1].cells[0].text.or_space(), "l");
}

#[test]
fn the_alt_screen_never_accrues_scrollback() {
    let feed = (1..=10)
        .map(|n| format!("alt{n}"))
        .collect::<Vec<_>>()
        .join("\r\n");
    let mut model = ScreenModel::with_scrollback(3, 8, 100);
    model.feed(format!("{ESC}[?1049h{feed}").as_bytes());
    assert!(model.replay_snapshot().scrollback.is_empty());
}

#[test]
fn a_sub_region_scroll_never_accrues_scrollback() {
    let feed = (1..=10).map(|n| format!("r{n}")).collect::<Vec<_>>().join("\r\n");
    let mut model = ScreenModel::with_scrollback(6, 8, 100);
    model.feed(format!("{ESC}[2;5r{feed}").as_bytes());
    assert!(model.replay_snapshot().scrollback.is_empty());
}

// MARK: Seeded fuzz — canonicalization over the VT vocabulary

#[test]
fn fuzzed_streams_render_idempotently() {
    // Deterministic LCG (no clock, no entropy): 300 streams over the vocabulary the collapser fuzz
    // uses — text, wide scalars, erases, SGR, cursor motion, scroll regions, alt screen, wrap edges.
    // Every stream must round-trip visibly and render idempotently; a divergence prints its seed.
    let mut state: u64 = 0x5EED_50DE;
    let mut next = move |bound: usize| -> usize {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        usize::try_from((state >> 33) % bound as u64).unwrap_or(0)
    };
    let esc = ESC;
    let atoms: Vec<String> = [
        "hello ".to_owned(),
        "wide日".to_owned(),
        "e\u{0301}".to_owned(),
        "\r\n".to_owned(),
        "\r".to_owned(),
        "\n".to_owned(),
        "\t".to_owned(),
        "0123456789AB".to_owned(),
        "=".to_owned(),
    ]
    .into_iter()
    .chain(
        [
            "[31m",
            "[1;44m",
            "[38;5;100m",
            "[48;2;9;8;7m",
            "[0m",
            "[2J",
            "[K",
            "[1K",
            "[2K",
            "[3J",
            "[H",
            "[3;4H",
            "[2A",
            "[3B",
            "[4C",
            "[2D",
            "[2;5r",
            "[r",
            "[?6h",
            "[?6l",
            "[?1049h",
            "[?1049l",
            "[?25l",
            "[?25h",
            "[?7l",
            "[?7h",
            "7",
            "8",
            "(0",
            "(B",
            "[2L",
            "[1M",
            "[3P",
            "[2@",
            "[2X",
            "[1S",
            "[1T",
            "=",
            ">",
            "[5 q",
            "[2 q",
            "[0 q",
            "c",
        ]
        .into_iter()
        .map(|tail| format!("{esc}{tail}")),
    )
    .collect();

    for seed in 0..300 {
        let mut input = String::new();
        let atom_count = 4 + next(20);
        for _ in 0..atom_count {
            input.push_str(&atoms[next(atoms.len())]);
        }
        let rows = 3 + next(5);
        let cols = 6 + next(10);
        let a = model_from(input.as_bytes(), rows, cols);
        let sa = a.replay_snapshot();
        let rendered_a = render(&sa, &[]);
        let b = model_from(&rendered_a, rows, cols);
        let sb = b.replay_snapshot();
        let label = format!("seed {seed} rows {rows} cols {cols} input {input:?}");
        assert_eq!(rendered_a, render(&sb, &[]), "{label}");
        assert_eq!(sa.main_cells, sb.main_cells, "main grid — {label}");
        if sa.using_alt {
            assert_eq!(sa.alt_cells, sb.alt_cells, "alt grid — {label}");
        }
        let cells_a: Vec<_> = sa.scrollback.iter().map(|line| &line.cells).collect();
        let cells_b: Vec<_> = sb.scrollback.iter().map(|line| &line.cells).collect();
        assert_eq!(cells_a, cells_b, "scrollback — {label}");
        assert_eq!(sa.cursor_row, sb.cursor_row, "cursor_row — {label}");
        assert_eq!(sa.cursor_col, sb.cursor_col, "cursor_col — {label}");
        assert_eq!(sa.wrap_pending, sb.wrap_pending, "wrap_pending — {label}");
        // The PATH-B transcript must be a fixed point over the same vocabulary.
        let once = compose_transcript(input.as_bytes(), rows, cols);
        let twice = compose_transcript(&once, rows, cols);
        assert_eq!(once, twice, "transcript fixed point — {label}");
    }
}

// MARK: OSC 133 `A` prompt marks (what `jump_to_prompt` counts after a state transfer)

/// The regression this whole flag exists for: a state-transferred pane must arrive with its PROMPT
/// ROWS, not just its text. Without the re-emitted marks libghostty's `PageList` holds zero
/// `.prompt` rows, so `jump_to_prompt` — the command ladder's, the navigator's and jump-to-failed's
/// one jump primitive — walks nothing and the click does nothing (user-reported 2026-08-09).
#[test]
fn prompt_marks_survive_a_state_transfer() {
    // Four prompts through a 6-row grid, so the earliest ones scroll into history and the last one
    // is still on the grid — both carriers have to keep the mark.
    let mark = format!("{ESC}]133;A\u{07}");
    let mut input = String::new();
    for n in 1..=4 {
        input.push_str(&format!("{mark}$ cmd{n}\r\nout{n}\r\n"));
    }
    input.push_str(&format!("{mark}$ "));
    let a = model_from(input.as_bytes(), 6, 12);
    let sa = a.replay_snapshot();
    let marked = sa.scrollback.iter().filter(|line| line.is_prompt).count()
        + sa.main_prompt.iter().filter(|flag| **flag).count();
    assert_eq!(marked, 5, "every OSC 133 A must have stamped exactly one row");

    let rendered = text(&render(&sa, &[]));
    assert_eq!(
        rendered.matches(&mark).count(),
        5,
        "the render must re-emit one mark per marked row"
    );
    assert_round_trip(input.as_bytes(), 6, 12);
}

/// The mark lands on the row the shell put it on — the row that then carries the prompt text —
/// because that is the row libghostty stamps and therefore the row a jump lands on.
#[test]
fn a_prompt_mark_stamps_the_cursor_row() {
    let mut model = ScreenModel::with_scrollback(4, 20, 0);
    model.feed(format!("first\r\nsecond\r\n{ESC}]133;A\u{07}$ ").as_bytes());
    assert_eq!(model.replay_snapshot().main_prompt, [false, false, true, false]);
}

/// The ST-terminated spelling is the same mark, and parameters (`133;A;aid=…`, which real shell
/// integrations emit) do not stop it being one.
#[test]
fn a_prompt_mark_accepts_the_st_terminator_and_parameters() {
    let mut st = ScreenModel::with_scrollback(2, 10, 0);
    st.feed(format!("{ESC}]133;A{ESC}\\$ ").as_bytes());
    assert_eq!(st.replay_snapshot().main_prompt, [true, false]);

    let mut params = ScreenModel::with_scrollback(2, 10, 0);
    params.feed(format!("{ESC}]133;A;aid=7;cl=m\u{07}$ ").as_bytes());
    assert_eq!(params.replay_snapshot().main_prompt, [true, false]);
}

/// Only `133;A` is a prompt START. The other OSC-133 verbs (`B` command start, `C` output start,
/// `D` command end) and every unrelated OSC must leave the row unmarked — a mark on the wrong row
/// shifts every ordinal after it and mis-lands every later jump.
#[test]
fn a_prompt_mark_rejects_other_verbs_and_other_osc() {
    for body in [
        "133;B",
        "133;C",
        "133;D;0",
        "1337;A",
        "0;a title",
        "8;;https://x",
        "13",
    ] {
        let mut model = ScreenModel::with_scrollback(2, 10, 0);
        model.feed(format!("{ESC}]{body}\u{07}x").as_bytes());
        assert_eq!(
            model.replay_snapshot().main_prompt,
            [false, false],
            "OSC {body} must not stamp a row"
        );
    }
    // A DCS body that happens to spell the OSC verb is not an OSC.
    let mut dcs = ScreenModel::with_scrollback(2, 10, 0);
    dcs.feed(format!("{ESC}P133;A{ESC}\\x").as_bytes());
    assert_eq!(dcs.replay_snapshot().main_prompt, [false, false]);
}

/// `ED 3` (erase saved lines) and RIS clear the screen's marks with the rows they belong to, so a
/// cleared pane cannot re-emit prompts for content that is gone.
#[test]
fn prompt_marks_are_cleared_with_their_rows() {
    let mut cleared = ScreenModel::with_scrollback(3, 10, 100);
    cleared.feed(format!("{ESC}]133;A\u{07}$ one\r\n{ESC}[3J{ESC}[2J").as_bytes());
    let snap = cleared.replay_snapshot();
    assert_eq!(snap.main_prompt, [false, false, false]);
    assert!(snap.scrollback.is_empty());

    let mut reset = ScreenModel::with_scrollback(3, 10, 0);
    reset.feed(format!("{ESC}]133;A\u{07}$ one{ESC}c").as_bytes());
    assert_eq!(reset.replay_snapshot().main_prompt, [false, false, false]);
}

// MARK: Transcript (PATH B — fresh-spawn journal restore)

/// PATH B fronts a BRAND-NEW shell whose segmenter restarts its prompt ordinals at 1. A mark left
/// by the dead life would make ordinal #1 an old prompt, so every jump in the new session would
/// land on the wrong command — the transcript therefore carries no marks.
#[test]
fn the_transcript_emits_no_prompt_marks() {
    let raw = format!("{ESC}]133;A\u{07}$ old command\r\nold output\r\n");
    let out = text(&compose_transcript(raw.as_bytes(), 6, 30));
    assert!(
        !out.contains("133;A"),
        "the dead life's prompt marks must not front a new shell"
    );
    assert!(
        out.contains("$ old command"),
        "its CONTENT is still the transcript"
    );
}

/// The transcript is CONTENT-ONLY: no private modes (mouse/alt/cursor-visibility), no cursor
/// positioning, no DECSCUSR — everything about the DEAD life's terminal state must die with it,
/// because these bytes front a brand-new shell.
#[test]
fn the_transcript_emits_no_modes_no_alt_and_no_cursor_state() {
    let raw = format!(
        "{ESC}[?1000h{ESC}[?2004h{ESC}[5 qmain content\r\n{ESC}[2;5r{ESC}[?1049hTUI-ALT-CONTENT{ESC}[3;4H"
    );
    let out = text(&compose_transcript(raw.as_bytes(), 6, 30));
    assert!(
        !out.contains(&format!("{ESC}[?")),
        "no private modes may survive into a fresh shell"
    );
    assert!(
        !out.contains(" q"),
        "no DECSCUSR — the new shell owns its cursor shape"
    );
    assert!(
        !out.contains("TUI-ALT-CONTENT"),
        "the dead TUI's alt screen is dropped"
    );
    assert!(
        out.contains("main content"),
        "the main screen beneath the TUI is the transcript"
    );
    assert!(
        !out.contains(ESC),
        "no cursor positioning — transcript lines are sequential"
    );
}

/// Scrollback + grid arrive as plain sequential lines, trailing blank grid rows dropped, and the
/// output ends with a line feed so the fresh prompt starts on its own line.
#[test]
fn the_transcript_is_plain_lines_ending_in_a_newline() {
    let input = (1..=9)
        .map(|n| format!("line {n}"))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n";
    let out = compose_transcript(input.as_bytes(), 6, 12);
    assert_eq!(text(&out), input, "plain lines pass through verbatim");
    assert_eq!(&out[out.len() - 2..], b"\r\n");
}

/// A soft-wrapped line still ON the grid (not yet scrolled into history) must re-join into one
/// logical line — the client re-wraps it at its own width.
#[test]
fn the_transcript_joins_soft_wrapped_grid_rows() {
    let long = "abcdefghij".repeat(3); // 30 chars over 12 cols = 3 grid rows
    let out = compose_transcript(long.as_bytes(), 6, 12);
    assert!(text(&out).contains(&long), "one contiguous logical line");
}

/// The overprint guarantee holds on the transcript path too: a progress bar repainted hundreds of
/// times restores as its final revision alone.
#[test]
fn the_transcript_collapses_overprint_to_the_final_revision() {
    let mut input = String::new();
    for pct in 0..=200 {
        input.push_str(&format!("Progress {}%\r", pct / 2));
    }
    input.push_str("\r\nDone.\r\n$ ");
    let out = text(&compose_transcript(input.as_bytes(), 6, 40));
    assert_eq!(out.matches("Progress").count(), 1, "one revision survives");
    assert!(out.contains("Progress 100%"));
    assert!(out.contains("Done."));
}

/// Transcript canonicalization: composing a transcript OF a transcript reproduces it byte-exact —
/// over curated churn and the fuzz vocabulary's benign subset. This is what makes repeated daemon
/// restarts stable.
#[test]
fn the_transcript_is_a_fixed_point() {
    let mut samples = vec![
        "$ ls\r\nREADME.md  Sources\r\n$ ".to_owned(),
        format!(
            "{ESC}[31mred{ESC}[0m {ESC}[1;38;5;196mbright{ESC}[0m\r\n{ESC}[48;2;10;20;30mrgb bg{ESC}[0m \
             plain"
        ),
        "blank\r\n\r\nafter-blank\r\n".to_owned(),
        "abcdefghij".repeat(4) + "\r\ntail",
        (1..=30)
            .map(|n| format!("history line {n}"))
            .collect::<Vec<_>>()
            .join("\r\n"),
    ];
    let mut progress = String::new();
    for pct in 0..=50 {
        progress.push_str(&format!("tick {pct}\r"));
    }
    samples.push(progress + "\r\ndone");
    for (index, sample) in samples.iter().enumerate() {
        let once = compose_transcript(sample.as_bytes(), 6, 12);
        let twice = compose_transcript(&once, 6, 12);
        assert_eq!(once, twice, "sample {index} transcript must be a fixed point");
    }
}
