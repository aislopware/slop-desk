//! Cold-reattach state transfer: render the MODEL, not the history.
//!
//! Turns a [`ReplaySnapshot`] into the minimal VT byte stream that reproduces its visible state on
//! a fresh terminal.
//!
//! It replaces replaying (however well distilled) the raw byte HISTORY.
//!
//! ## Shape of the output
//! 1. An explicit reset preamble (main screen, plain SGR, full scroll region, wrap on, origin off,
//!    `ED 3` + `ED 2`, home). On a fresh surface every step is a no-op; on a warm surface (the
//!    warm-overflow snapshot) it IS the wipe that makes the re-render correct.
//! 2. Scrollback, one LOGICAL line per line: soft-wrapped rows are re-joined so the client re-wraps
//!    them at its own width (a join is trusted only when the leading row is full to its last column
//!    — see [`ScrollbackLine::soft_wrapped`]).
//! 3. The main grid painted SEQUENTIALLY (every row, blank rows included): after `scrollback +
//!    rows` printed lines the viewport holds exactly the grid with row 0 at the top, and the
//!    scrollback sits above it — the same adjacency the real history produced.
//! 4. If the alt screen is active: position the main saved cursor, `?1049h`, then paint the alt
//!    grid with ABSOLUTE per-row positioning (no scroll risk, blank rows skipped).
//! 5. State re-establishment: DECSTBM, DECOM, DECAWM, DECTCEM, charsets (G0/G1 + SO), the live SGR,
//!    the cursor (re-arming DECAWM deferred wrap by re-printing the last column when the model
//!    ended wrap-pending), keypad, DECSCUSR cursor shape, then the caller's input-mode reassert
//!    bytes.
//!
//! ## What this guarantees
//! Feeding the output to a FRESH [`ScreenModel`](crate::ScreenModel) reproduces the source model's
//! visible state, and rendering is a CANONICALIZATION: `render(feed(render(A))) == render(A)`
//! byte-exact — the differential + idempotence pins the tests enforce over the VT vocabulary.
//!
//! The one OSC that IS modeled is `133;A` — see [`PROMPT_MARK`]: it paints nothing, but it is the
//! only thing that makes a row a prompt row, and prompt rows are what every jump counts.
//!
//! Accepted gaps (`docs/DECISIONS.md` 2026-07-25): OSC 8 hyperlinks and app-set palette colours are
//! not modeled; `REP` across the snapshot boundary repeats nothing; the saved-cursor slot restores
//! position, not its saved SGR/charset.

// A terminal grid IS an indexed structure: every coordinate reaching a `cells[r][c]` here has
// already been clamped against `rows`/`cols` on the way in. Rewriting the grid touches as
// `get_mut(..)` + `else { return }` would replace one panic that cannot fire with silent no-ops
// that hide the bug if it ever could — the clamp is the check. Per file, so a module that does no
// grid work does not inherit the exemption.
#![expect(
    clippy::indexing_slicing,
    reason = "grid coordinates are clamped before they get here"
)]

use std::fmt::Write as _;

use crate::cell::{Cell, CellStyle, SgrColor};
use crate::model::{ReplaySnapshot, ScrollbackLine, row_reaches_last_column};

const CRLF: &[u8] = b"\r\n";

/// OSC 133 `A` — the shell-integration PROMPT-START mark, BEL-terminated.
///
/// Re-emitted for every row the source model saw one on, because the marks are the only thing that
/// makes a row a `.prompt` row in libghostty's `PageList` — and prompt rows are what
/// `jump_to_prompt` counts. Without this a state-transferred pane arrives with a complete-looking
/// scrollback and ZERO prompt rows, so every command-ladder / navigator jump silently lands nowhere
/// (user-reported 2026-08-09: "after the client reconnects, clicking the command ladder no longer
/// jumps").
///
/// Deliberately NOT emitted by [`render_transcript`]: that path fronts a BRAND-NEW shell whose
/// segmenter restarts its prompt ordinals at 1, so marks left by the dead life would make ordinal
/// #1 an old prompt and every jump would land on the wrong command.
const PROMPT_MARK: &[u8] = b"\x1b]133;A\x07";

/// `?1049l` main screen · `SGR 0` · `?25h` visible · `r` full region · `?6l` origin off · `?7h`
/// wrap on · G0/G1 ASCII + SI · `ESC >` keypad normal · `0 SP q` cursor shape default · `3J` erase
/// saved lines · `2J` erase screen · `H` home.
const PREAMBLE: &[u8] =
    b"\x1b[?1049l\x1b[0m\x1b[?25h\x1b[r\x1b[?6l\x1b[?7h\x1b(B\x1b)B\x0f\x1b>\x1b[0 q\x1b[3J\x1b[2J\x1b[H";

/// Renders `snapshot` into the cold-reattach byte stream.
///
/// `input_mode_reassert` (the Swift caller's `TerminalInputModeStripper.finalState` net state) is
/// appended as the FINAL bytes — the same trailing position the stripped-replay path gives it.
#[must_use]
pub fn render(snapshot: &ReplaySnapshot, input_mode_reassert: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(snapshot.rows * snapshot.cols * 2);
    let mut sgr = SgrTracker::default();

    // 1. Explicit reset preamble (deterministic — no reliance on DECSTR semantics).
    out.extend_from_slice(PREAMBLE);

    // 2. Scrollback as logical lines.
    append_scrollback(&snapshot.scrollback, &mut out, &mut sgr);

    // 3. Main grid, sequentially — EVERY row, so the viewport lands exactly on the grid.
    append_main_grid(snapshot, &mut out, &mut sgr);

    // 4. Alt screen (active only): seed the main saved-cursor slot via `?1049h`'s own save, then paint
    //    absolutely.
    if snapshot.using_alt {
        append_cup(snapshot.saved_main_row, snapshot.saved_main_col, &mut out);
        sgr.reset(&mut out); // the alt clear-on-enter must fill with the DEFAULT bg
        out.extend_from_slice(b"\x1b[?1049h");
        for (r, row) in snapshot.alt_cells.iter().enumerate() {
            if is_blank_row(row) {
                continue;
            }
            append_cup(r, 0, &mut out);
            append_cells(row, &mut out, &mut sgr);
        }
    } else {
        // Seed the active (main) saved-cursor slot: position + DECSC. Saved SGR/charset fidelity is
        // an accepted gap — DECSC here captures the renderer's current state.
        append_cup(snapshot.saved_cursor_row, snapshot.saved_cursor_col, &mut out);
        out.extend_from_slice(b"\x1b7");
    }

    // 5. State re-establishment.
    if snapshot.using_alt {
        // The alt slot: position + DECSC on the active (alt) screen.
        append_cup(snapshot.saved_cursor_row, snapshot.saved_cursor_col, &mut out);
        out.extend_from_slice(b"\x1b7");
    }
    append_modes(snapshot, &mut out);

    // Cursor + deferred wrap — the LAST cursor-affecting emission. Coordinates are ORIGIN-relative
    // when DECOM is on (the CUP is interpreted inside the region above). The charset
    // re-establishment must come AFTER this: the wrap re-arm re-prints a cell that was painted under
    // the default (preamble) charset, and switching G0/G1 first would remap its ASCII through DEC
    // graphics.
    let cup_row = if snapshot.origin_mode {
        snapshot.cursor_row.saturating_sub(snapshot.scroll_top)
    } else {
        snapshot.cursor_row
    };
    if snapshot.wrap_pending {
        // Re-arm DECAWM deferred wrap: re-print the last column's occupant (the wide lead when the
        // last cell is a continuation), which leaves the terminal exactly one printable away from
        // wrapping — the state the model ended in.
        let grid = if snapshot.using_alt {
            &snapshot.alt_cells
        } else {
            &snapshot.main_cells
        };
        let row = &grid[snapshot.cursor_row];
        let last_col = snapshot.cols - 1;
        let mut print_col = last_col;
        let mut cell = &row[last_col];
        if cell.is_continuation && last_col > 0 {
            print_col = last_col - 1;
            cell = &row[print_col];
        }
        append_cup(cup_row, print_col, &mut out);
        sgr.transition(&cell.style, &mut out);
        out.extend_from_slice(cell.text.or_space().as_bytes());
    } else {
        append_cup(cup_row, snapshot.cursor_col, &mut out);
    }

    // Charsets (no cursor / deferred-wrap side effects), then the live SGR.
    if snapshot.g0_graphics {
        out.extend_from_slice(b"\x1b(0");
    }
    if snapshot.g1_graphics {
        out.extend_from_slice(b"\x1b)0");
    }
    if snapshot.using_g1 {
        out.push(0x0E); // SO
    }
    sgr.transition(&snapshot.style, &mut out);

    out.extend_from_slice(input_mode_reassert);
    out
}

/// Renders `snapshot` as a plain TRANSCRIPT — the fresh-spawn journal restore (PATH B).
///
/// The restored history fronts a NEW shell, so nothing about the dead life's terminal STATE may
/// survive into the pane. Emits only content: scrollback logical lines, then the main grid's rows
/// (soft-wrapped rows re-joined, trailing blank rows dropped), each line SGR-styled and reset
/// before its line feed, ending on a fresh line for the new shell's first prompt. No preamble (the
/// receiving surface is cold by the restore gate), no alt screen (a TUI that died with the daemon
/// cannot resume — the main screen beneath it is what the raw-replay path's `?1049l` sanitize
/// revealed too), no modes, no cursor or cursor-shape restoration.
#[must_use]
pub fn render_transcript(snapshot: &ReplaySnapshot) -> Vec<u8> {
    // Scrollback and grid form ONE uniform run of rows so a soft-wrapped logical line that STRADDLES
    // the boundary (first half scrolled into history, second half still on screen) re-joins like any
    // other. Splitting at the boundary would also break the fixed point (transcript-of-transcript):
    // the re-feed's scroll phase shifts the boundary, so the split would land in a different place
    // each pass. Grid rows apply the same full-to-the-last-column join guard the scrollback capture
    // bakes into `ScrollbackLine::soft_wrapped`; trailing blank grid rows are dropped so the new
    // shell's prompt lands right under the content.
    let mut rows: Vec<(&[Cell], bool)> = snapshot
        .scrollback
        .iter()
        .map(|line| (line.cells.as_slice(), line.soft_wrapped))
        .collect();
    for (r, row) in snapshot.main_cells.iter().enumerate() {
        let continues_next =
            snapshot.main_wrapped.get(r).copied().unwrap_or(false) && row_reaches_last_column(row);
        rows.push((row.as_slice(), continues_next));
    }
    // Blank EDGES are noise, not content: trailing blanks are the empty region under the dead
    // prompt, and leading blanks are scroll artifacts with nothing above them (a content-free
    // `ESC[S` capture). Both would also break the fixed point — a re-feed reproduces interior blank
    // lines exactly, but grows/loses edge blanks with the scroll phase. Interior blank lines
    // (paragraph separators) are kept verbatim.
    while rows.last().is_some_and(|last| is_blank_row(last.0)) {
        rows.pop();
    }
    let leading = rows.iter().take_while(|row| is_blank_row(row.0)).count();
    rows.drain(..leading);

    let mut out = Vec::new();
    let mut sgr = SgrTracker::default();
    let mut i = 0;
    while i < rows.len() {
        let mut logical = rows[i].0.to_vec();
        while rows[i].1 && i + 1 < rows.len() {
            i += 1;
            logical.extend_from_slice(rows[i].0);
        }
        i += 1;
        append_cells(&logical, &mut out, &mut sgr);
        sgr.reset(&mut out); // the BCE discipline from `render` — see the note there
        out.extend_from_slice(CRLF);
    }
    out
}

// MARK: Pieces

/// Scrollback, re-joined into logical lines: a soft-wrapped run prints as ONE line so the receiving
/// client re-wraps it at its own width.
fn append_scrollback(scrollback: &[ScrollbackLine], out: &mut Vec<u8>, sgr: &mut SgrTracker) {
    let mut i = 0;
    while i < scrollback.len() {
        let mut logical = scrollback[i].cells.clone();
        let is_prompt = scrollback[i].is_prompt;
        while scrollback[i].soft_wrapped && i + 1 < scrollback.len() {
            i += 1;
            logical.extend_from_slice(&scrollback[i].cells);
        }
        i += 1;
        // The prompt mark belongs to the logical line's FIRST row — emitted before its content so
        // the receiving terminal stamps the row the content lands on.
        if is_prompt {
            out.extend_from_slice(PROMPT_MARK);
        }
        append_cells(&logical, out, sgr);
        // Reset BEFORE the line feed: the scroll this feed causes in the receiving terminal
        // BCE-fills the new bottom row with the LIVE background — a lingering coloured bg would
        // paint rows the source model never coloured.
        sgr.reset(out);
        out.extend_from_slice(CRLF);
    }
}

/// The main grid, every row including blank ones, so the viewport ends up exactly on it.
fn append_main_grid(snapshot: &ReplaySnapshot, out: &mut Vec<u8>, sgr: &mut SgrTracker) {
    let last_row = snapshot.main_cells.len().saturating_sub(1);
    for (index, row) in snapshot.main_cells.iter().enumerate() {
        if snapshot.main_prompt.get(index).copied().unwrap_or(false) {
            out.extend_from_slice(PROMPT_MARK);
        }
        append_cells(row, out, sgr);
        if index < last_row {
            sgr.reset(out); // same BCE discipline as the scrollback feed above
            out.extend_from_slice(CRLF);
        }
    }
}

/// The non-default modes: scroll region, DECOM, DECAWM, DECTCEM, keypad, cursor shape. Each is
/// emitted only when it differs from what the preamble already established.
fn append_modes(snapshot: &ReplaySnapshot, out: &mut Vec<u8>) {
    if snapshot.scroll_top != 0 || snapshot.scroll_bottom != snapshot.rows - 1 {
        append_fmt(
            out,
            format_args!("\x1b[{};{}r", snapshot.scroll_top + 1, snapshot.scroll_bottom + 1),
        );
    }
    if snapshot.origin_mode {
        out.extend_from_slice(b"\x1b[?6h");
    }
    if !snapshot.autowrap {
        out.extend_from_slice(b"\x1b[?7l");
    }
    if !snapshot.cursor_visible {
        out.extend_from_slice(b"\x1b[?25l");
    }
    if snapshot.application_keypad {
        out.extend_from_slice(b"\x1b=");
    }
    if snapshot.cursor_shape != 0 {
        // DECSCUSR — the shell integration's bar-at-prompt cursor (or a TUI's own shape) survives
        // the state transfer; the preamble already reset the shape to default.
        append_fmt(out, format_args!("\x1b[{} q", snapshot.cursor_shape));
    }
}

/// Emits a 1-based CUP from 0-based coordinates.
fn append_cup(row: usize, col: usize, out: &mut Vec<u8>) {
    append_fmt(out, format_args!("\x1b[{};{}H", row + 1, col + 1));
}

/// Formats straight into the byte buffer — no intermediate `String` per escape.
fn append_fmt(out: &mut Vec<u8>, args: std::fmt::Arguments<'_>) {
    let mut scratch = String::with_capacity(24);
    // Writing into a `String` cannot fail; on the impossible error the escape is simply omitted
    // rather than trapping a whole connection's render.
    if scratch.write_fmt(args).is_ok() {
        out.extend_from_slice(scratch.as_bytes());
    }
}

fn is_blank_row(row: &[Cell]) -> bool {
    row.iter().all(Cell::is_blank)
}

/// Appends a run of cells (continuation cells contribute nothing — the wide lead prints both
/// columns), dropping the FULLY-DEFAULT tail (styled blanks are content: a coloured or underlined
/// space is visible and must be printed).
fn append_cells(cells: &[Cell], out: &mut Vec<u8>, sgr: &mut SgrTracker) {
    let mut end = cells.len();
    while end > 0 && cells[end - 1].is_blank() {
        end -= 1;
    }
    for cell in &cells[..end] {
        if cell.is_continuation {
            continue;
        }
        sgr.transition(&cell.style, out);
        out.extend_from_slice(cell.text.or_space().as_bytes());
    }
}

/// The renderer's mirror of the client terminal's live SGR state — emits one full reset+set run per
/// style CHANGE, nothing for same-style runs.
#[derive(Debug, Default)]
struct SgrTracker {
    current: CellStyle,
}

impl SgrTracker {
    fn reset(&mut self, out: &mut Vec<u8>) {
        self.transition(&CellStyle::PLAIN, out);
    }

    fn transition(&mut self, style: &CellStyle, out: &mut Vec<u8>) {
        if *style == self.current {
            return;
        }
        self.current = *style;
        if *style == CellStyle::PLAIN {
            out.extend_from_slice(b"\x1b[0m");
            return;
        }
        let mut codes = String::from("0");
        for (enabled, code) in [
            (style.bold, "1"),
            (style.dim, "2"),
            (style.italic, "3"),
            (style.underline, "4"),
            (style.blink, "5"),
            (style.inverse, "7"),
            (style.hidden, "8"),
            (style.strikethrough, "9"),
        ] {
            if enabled {
                codes.push(';');
                codes.push_str(code);
            }
        }
        append_color(style.fg, 30, 38, &mut codes);
        append_color(style.bg, 40, 48, &mut codes);
        append_fmt(out, format_args!("\x1b[{codes}m"));
    }
}

fn append_color(color: SgrColor, base: u16, extended: u16, codes: &mut String) {
    let _ = match color {
        // The leading reset already established the default.
        SgrColor::Default => Ok(()),
        SgrColor::Indexed(index) if index < 8 => write!(codes, ";{}", base + u16::from(index)),
        SgrColor::Indexed(index) if index < 16 => write!(codes, ";{}", base + 60 + u16::from(index) - 8),
        SgrColor::Indexed(index) => write!(codes, ";{extended};5;{index}"),
        SgrColor::Rgb(r, g, b) => write!(codes, ";{extended};2;{r};{g};{b}"),
    };
}
