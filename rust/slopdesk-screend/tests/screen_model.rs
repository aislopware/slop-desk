//! `ScreenModel` — the `screen` verb's on-demand VT grid reconstruction.
//!
//! Pure model tests: bytes in → grid out. No PTY, no socket, no session.

#![expect(
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::format_push_string,
    reason = "these tests BUILD terminal streams: `push_str(&format!(..))` is how a fixture reads, and an \
              integer percentage is the arithmetic a progress reporter actually does"
)]

use slopdesk_screend::{ScreenModel, Snapshot};

const ESC: &str = "\u{1B}";

fn render_at(input: &str, rows: usize, cols: usize) -> Snapshot {
    let mut model = ScreenModel::new(rows, cols);
    model.feed(input.as_bytes());
    model.snapshot()
}

fn render(input: &str) -> Snapshot {
    render_at(input, 5, 10)
}

// MARK: Plain text / control chars

#[test]
fn plain_text_with_crlf() {
    let snap = render("hello\r\nworld");
    assert_eq!(snap.lines[0], "hello");
    assert_eq!(snap.lines[1], "world");
    assert_eq!(snap.cursor_row, 1);
    assert_eq!(snap.cursor_col, 5);
}

#[test]
fn bare_lf_keeps_column() {
    // LF without CR moves down but keeps the column (raw VT semantics — a shell in canonical mode
    // translates, but the model must reproduce what actually arrived).
    let snap = render("ab\ncd");
    assert_eq!(snap.lines[0], "ab");
    assert_eq!(snap.lines[1], "  cd");
}

#[test]
fn carriage_return_overwrites() {
    assert_eq!(render("aaaa\rbb").lines[0], "bbaa");
}

#[test]
fn backspace_moves_without_erase() {
    assert_eq!(render("ab\u{08}c").lines[0], "ac");
}

#[test]
fn tab_advances_to_the_next_eight_stop() {
    assert_eq!(render_at("a\tb", 5, 20).lines[0], "a       b");
}

// MARK: Wrap (DECAWM + deferred wrap)

#[test]
fn autowrap_at_the_right_edge() {
    let snap = render_at("0123456789AB", 3, 10);
    assert_eq!(snap.lines[0], "0123456789");
    assert_eq!(snap.lines[1], "AB");
}

#[test]
fn deferred_wrap_stays_pending() {
    // Writing exactly the last column must NOT wrap yet: a CR right after stays on the same row
    // (the classic vt100 pending-wrap trick every full-width status bar relies on).
    let snap = render_at("0123456789\rX", 3, 10);
    assert_eq!(snap.lines[0], "X123456789");
    assert_eq!(snap.lines[1], "");
}

#[test]
fn autowrap_disabled_pins_at_the_last_column() {
    let snap = render_at(&format!("{ESC}[?7l0123456789ABC"), 3, 10);
    assert_eq!(snap.lines[0], "012345678C");
    assert_eq!(snap.lines[1], "");
}

// MARK: Cursor movement

#[test]
fn cup_then_overwrite() {
    let snap = render(&format!("aaaa\r\nbbbb{ESC}[1;2Hxy"));
    assert_eq!(snap.lines[0], "axya");
    assert_eq!(snap.lines[1], "bbbb");
}

#[test]
fn relative_cursor_moves() {
    // CUP to 3;3, up 1, forward 2, write.
    let snap = render(&format!("{ESC}[3;3H{ESC}[1A{ESC}[2CZ"));
    assert_eq!(snap.lines[1], "    Z");
}

#[test]
fn cha_and_vpa() {
    let snap = render_at(&format!("{ESC}[4dX{ESC}[8GY"), 5, 10);
    assert_eq!(snap.lines[3], "X      Y");
}

// MARK: Erase

#[test]
fn erase_in_line_variants() {
    // Fill a row, then EL 0 from middle.
    assert_eq!(
        render_at(&format!("abcdefghij{ESC}[1;5H{ESC}[K"), 2, 10).lines[0],
        "abcd"
    );
    // EL 1: start → cursor inclusive.
    assert_eq!(
        render_at(&format!("abcdefghij{ESC}[1;5H{ESC}[1K"), 2, 10).lines[0],
        "     fghij"
    );
    // EL 2: whole line.
    assert_eq!(render_at(&format!("abcdefghij{ESC}[2K"), 2, 10).lines[0], "");
}

#[test]
fn erase_in_display_from_the_cursor() {
    let snap = render_at(&format!("aaaa\r\nbbbb\r\ncccc{ESC}[2;3H{ESC}[J"), 4, 10);
    assert_eq!(snap.lines[0], "aaaa");
    assert_eq!(snap.lines[1], "bb");
    assert_eq!(snap.lines[2], "");
}

#[test]
fn erase_all_clears_without_homing() {
    let snap = render(&format!("aaaa\r\nbbbb{ESC}[2J"));
    assert_eq!(snap.lines[0], "");
    assert_eq!(snap.lines[1], "");
    // ED 2 clears but does NOT home the cursor (xterm keeps position).
    assert_eq!(snap.cursor_row, 1);
}

#[test]
fn erase_chars() {
    assert_eq!(
        render_at(&format!("abcdefghij{ESC}[1;3H{ESC}[4X"), 2, 10).lines[0],
        "ab    ghij"
    );
}

// MARK: Insert / delete chars + lines

#[test]
fn insert_and_delete_chars() {
    assert_eq!(
        render_at(&format!("abcdef{ESC}[1;3H{ESC}[2@"), 2, 10).lines[0],
        "ab  cdef"
    );
    assert_eq!(
        render_at(&format!("abcdef{ESC}[1;3H{ESC}[2P"), 2, 10).lines[0],
        "abef"
    );
}

#[test]
fn insert_and_delete_lines() {
    let base = "aaaa\r\nbbbb\r\ncccc\r\ndddd";
    let ins = render_at(&format!("{base}{ESC}[2;1H{ESC}[1L"), 4, 10);
    assert_eq!(ins.lines, ["aaaa", "", "bbbb", "cccc"]);
    let del = render_at(&format!("{base}{ESC}[2;1H{ESC}[1M"), 4, 10);
    assert_eq!(del.lines, ["aaaa", "cccc", "dddd", ""]);
}

// MARK: Scrolling / regions

#[test]
fn a_line_feed_at_the_bottom_scrolls() {
    assert_eq!(render_at("1\r\n2\r\n3\r\n4", 3, 10).lines, ["2", "3", "4"]);
}

#[test]
fn a_scroll_region_confines_the_scroll() {
    // Rows 2–3 are the region; LF at region bottom scrolls ONLY rows 2–3.
    let snap = render_at(
        &format!("top\r\nAAA\r\nBBB\r\nbot{ESC}[2;3r{ESC}[3;1H\nNEW"),
        4,
        10,
    );
    assert_eq!(snap.lines[0], "top");
    assert_eq!(snap.lines[1], "BBB");
    assert_eq!(snap.lines[2], "NEW");
    assert_eq!(snap.lines[3], "bot");
}

#[test]
fn reverse_index_at_the_top_scrolls_down() {
    assert_eq!(render_at(&format!("1\r\n2{ESC}[1;1H{ESC}MX"), 3, 10).lines, [
        "X", "1", "2"
    ]);
}

// MARK: Alt screen

#[test]
fn alt_screen_enter_draw_exit_restores_main() {
    let snap = render(&format!("main{ESC}[?1049hALT SCREEN{ESC}[?1049l"));
    assert!(!snap.alt_screen);
    assert_eq!(snap.lines[0], "main");
    // 1049 restores the saved cursor on exit.
    assert_eq!(snap.cursor_row, 0);
    assert_eq!(snap.cursor_col, 4);
}

#[test]
fn an_open_alt_screen_is_the_snapshot() {
    let snap = render_at(&format!("main{ESC}[?1049h{ESC}[2;3HTUI"), 4, 10);
    assert!(snap.alt_screen);
    assert_eq!(snap.lines[0], "");
    assert_eq!(snap.lines[1], "  TUI");
}

#[test]
fn alt_screen_reentry_is_cleared() {
    // 1049 clears the alt grid on every enter — no stale TUI pixels from a prior visit.
    let snap = render(&format!("{ESC}[?1049hOLD{ESC}[?1049l{ESC}[?1049h{ESC}[2;1HNEW"));
    assert!(snap.alt_screen);
    assert_eq!(snap.lines[0], "");
    assert_eq!(snap.lines[1], "NEW");
}

// MARK: Charset / wide / combining

#[test]
fn dec_graphics_box_drawing() {
    assert_eq!(
        render_at(&format!("{ESC}(0lqqk{ESC}(B x"), 2, 10).lines[0],
        "┌──┐ x"
    );
}

#[test]
fn shift_out_uses_g1() {
    assert_eq!(
        render_at(&format!("{ESC})0a\u{0E}q\u{0F}b"), 2, 10).lines[0],
        "a─b"
    );
}

#[test]
fn a_wide_char_occupies_two_columns() {
    let snap = render_at("字x", 2, 10);
    assert_eq!(snap.lines[0], "字x");
    assert_eq!(snap.cursor_col, 3);
}

#[test]
fn overwriting_half_a_wide_pair_blanks_the_partner() {
    // Write 字 at cols 0–1, then overwrite col 0 → the continuation must not orphan.
    assert_eq!(render_at(&format!("字{ESC}[1;1HZ"), 2, 10).lines[0], "Z");
}

/// An ERASE that lands on half a wide pair must blank the other half too, exactly as overwriting it
/// does — a surviving lone half renders at the wrong width.
#[test]
fn erasing_half_a_wide_pair_blanks_the_partner() {
    // EL 1 (start → cursor) over the LEAD cell of 字 at cols 0–1.
    assert_eq!(
        render_at(&format!("字x{ESC}[1;1H{ESC}[1K"), 2, 10).lines[0],
        "  x"
    );
    // EL 0 (cursor → end) starting on the CONTINUATION cell.
    assert_eq!(render_at(&format!("字x{ESC}[1;2H{ESC}[0K"), 2, 10).lines[0], "");
    // ECH over the lead cell.
    assert_eq!(
        render_at(&format!("字x{ESC}[1;1H{ESC}[1X"), 2, 10).lines[0],
        "  x"
    );
}

/// ICH's shift can split a wide pair at either seam — the insertion point and the right edge where
/// cells are pushed off. Both halves blank, exactly as erasing and overwriting do.
#[test]
fn insert_chars_splitting_a_wide_pair_blanks_both_halves() {
    // Cursor on the CONTINUATION cell of 字 → the inserted blank lands between the halves.
    assert_eq!(
        render_at(&format!("字x{ESC}[1;2H{ESC}[1@"), 2, 10).lines[0],
        "   x"
    );
    // The right-edge seam: the pair pushed off the end must not leave its lead behind.
    assert_eq!(
        render_at(&format!("ab字{ESC}[1;1H{ESC}[1@"), 2, 4).lines[0],
        " ab"
    );
}

/// DCH's shift can split a wide pair at either seam — the deleted range's start and its end.
#[test]
fn delete_chars_splitting_a_wide_pair_blanks_both_halves() {
    // Cursor on the CONTINUATION cell → deleting it leaves the lead half, which must blank.
    assert_eq!(render_at(&format!("字x{ESC}[1;2H{ESC}[1P"), 2, 10).lines[0], " x");
    // Cursor on the LEAD cell → the continuation shifts left as an orphan, which must blank.
    assert_eq!(render_at(&format!("字x{ESC}[1;1H{ESC}[1P"), 2, 10).lines[0], " x");
}

#[test]
fn a_combining_mark_attaches_to_the_previous_cell() {
    let snap = render_at("e\u{0301}x", 2, 10);
    // The mark is APPENDED, not normalised: the cell holds `e` + U+0301 exactly as it arrived.
    // (The Swift original asserted against the precomposed "éx" and passed only because Swift's
    // `String` equality folds canonical equivalence — Rust compares bytes, which is what the
    // client's terminal and the detection manifests actually see.)
    assert_eq!(snap.lines[0], "e\u{0301}x");
    assert_eq!(snap.cursor_col, 2);
}

// MARK: REP / OSC skip / DECALN / RIS

#[test]
fn rep_repeats_the_last_graphic() {
    assert_eq!(render_at(&format!("a{ESC}[3b"), 2, 10).lines[0], "aaaa");
}

#[test]
fn osc_and_dcs_bodies_are_invisible() {
    let snap = render_at(&format!("{ESC}]0;my title\u{07}ok{ESC}P+q544e{ESC}\\!"), 2, 20);
    assert_eq!(snap.lines[0], "ok!");
}

#[test]
fn sgr_paints_no_text() {
    assert_eq!(
        render_at(&format!("{ESC}[1;31mred{ESC}[0m plain"), 2, 20).lines[0],
        "red plain"
    );
}

#[test]
fn decaln_fills_with_e() {
    assert_eq!(render_at(&format!("{ESC}#8"), 2, 3).lines, ["EEE", "EEE"]);
}

#[test]
fn ris_resets_everything() {
    let snap = render_at(&format!("junk{ESC}[?1049h{ESC}cX"), 3, 10);
    assert!(!snap.alt_screen);
    assert_eq!(snap.lines[0], "X");
    assert_eq!(snap.lines[1], "");
}

// MARK: Cursor visibility / split feeds

#[test]
fn cursor_hide_and_show() {
    assert!(!render(&format!("{ESC}[?25l")).cursor_visible);
    assert!(render(&format!("{ESC}[?25l{ESC}[?25h")).cursor_visible);
}

#[test]
fn a_sequence_split_across_feeds_still_parses() {
    let mut model = ScreenModel::new(3, 10);
    model.feed(format!("ab{ESC}[1").as_bytes());
    model.feed(b";1HZ");
    assert_eq!(model.snapshot().lines[0], "Zb");
}

#[test]
fn a_utf8_scalar_split_across_feeds_still_parses() {
    let mut model = ScreenModel::new(2, 10);
    let bytes = "é".as_bytes();
    model.feed(&bytes[0..1]);
    model.feed(&bytes[1..]);
    assert_eq!(model.snapshot().lines[0], "é");
}

// MARK: Robustness (validate-then-drop)

#[test]
fn hostile_params_never_trap() {
    // Huge params, degenerate region, moves off-grid, unknown finals — must not crash and must
    // clamp instead of trap.
    let snap = render_at(
        &format!("{ESC}[9999;9999H{ESC}[9999A{ESC}[9999X{ESC}[5;2r{ESC}[999b{ESC}[?9999hok"),
        3,
        10,
    );
    assert_eq!(snap.rows, 3);
    // The clamped cursor lands on (0, 9); "ok" wraps across the right edge.
    assert!(snap.lines[0].ends_with('o'));
    assert_eq!(snap.lines[1], "k");
}

#[test]
fn a_vim_like_paint_reads_like_the_editor_looks() {
    // A miniature vim paint: enter alt, clear, tildes down the left, a status line, cursor home.
    let mut paint = format!("{ESC}[?1049h{ESC}[2J{ESC}[H");
    for row in 2..=4 {
        paint.push_str(&format!("{ESC}[{row};1H~"));
    }
    paint.push_str(&format!("{ESC}[5;1H-- INSERT --{ESC}[1;1H"));
    let snap = render_at(&paint, 5, 20);
    assert!(snap.alt_screen);
    assert_eq!(snap.lines, ["", "~", "~", "~", "-- INSERT --"]);
    assert_eq!(snap.cursor_row, 0);
    assert_eq!(snap.cursor_col, 0);
}

// MARK: Rows

/// `lines` is one entry PER ROW, always — including the blank ones. Every consumer's trimming rule
/// (herdr's detection text, the `screen` verb's `text`) is derived from that, on the Swift side,
/// and a grid that quietly dropped its own blank rows would make both rules unstatable.
#[test]
fn every_row_is_present_including_the_blank_ones() {
    let snap = render_at("one\r\ntwo", 5, 10);
    assert_eq!(snap.lines, ["one", "two", "", "", ""]);
    assert_eq!(render_at("", 5, 10).lines, ["", "", "", "", ""]);
}
