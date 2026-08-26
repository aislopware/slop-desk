//! A PURE in-memory VT100/xterm screen emulator — the engine behind the `screen` ctl verb, the
//! agent-detection grid and the cold-reattach snapshot.
//!
//! The host keeps no persistent screen buffer (rendering is the client's job), so the rendered
//! screen is reconstructed ON DEMAND: replay raw bytes through this model at the pane's live PTY
//! size and dump the resulting grid. That makes a TUI pane (vim, htop, claude) READABLE to an
//! agent — `read` returns the raw byte soup a full-screen app emits, `screen` returns what a human
//! actually sees.
//!
//! Scope: text placement + per-cell SGR. Implements the cursor/erase/scroll/alt-screen state
//! machine (CUP/CUU..CUB/CHA/VPA/ED/EL/ICH/DCH/ECH/IL/DL/SU/SD/REP, DECSTBM, DECOM, DECAWM with
//! deferred wrap, DECSC/DECRC, IND/RI/NEL/RIS/DECALN, alt screen 47/1047/1049, SO/SI + DEC
//! special-graphics G0/G1, UTF-8 with wide/combining width). SGR colours/attributes are tracked per
//! cell (16/256/truecolour + the flag set, BCE on erase/scroll fill) for the snapshot renderer; the
//! [`ScreenModel::snapshot`] dump stays plain text. With `scrollback_limit > 0` the model also
//! captures lines scrolled off the top of the full-screen main region (xterm semantics: partial
//! scroll regions and the alt screen never accrue scrollback; `ED 3` clears it; oldest-out over the
//! cap). Unknown sequences are consumed and ignored (validate-then-drop: PTY bytes are
//! semi-trusted; the model never traps, never allocates beyond the fixed grid + scrollback cap).
//!
//! Starting mid-stream is expected (the ring truncates oldest-first) — full-screen apps repaint, so
//! the grid converges to truth after one redraw cycle regardless of the entry point.

// A terminal grid IS an indexed structure: every coordinate reaching a `cells[r][c]` here has
// already been clamped against `rows`/`cols` on the way in. Rewriting the grid touches as
// `get_mut(..)` + `else { return }` would replace one panic that cannot fire with silent no-ops
// that hide the bug if it ever could — the clamp is the check. Per file, so a module that does no
// grid work does not inherit the exemption.
#![expect(
    clippy::indexing_slicing,
    reason = "grid coordinates are clamped before they get here"
)]

use crate::cell::{Cell, CellStyle, CellText, SgrColor};
use crate::width::{dec_graphic, scalar_width};

/// Max rows a model will build, whatever the caller asks for.
pub const MAX_ROWS: usize = 512;
/// Max columns a model will build, whatever the caller asks for.
pub const MAX_COLS: usize = 1024;
/// Max captured scrollback lines, whatever the caller asks for.
pub const MAX_SCROLLBACK: usize = 100_000;

/// One line captured off the top of the full-screen main region.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct ScrollbackLine {
    /// The line's cells, at the width it was captured at.
    pub cells: Vec<Cell>,
    /// The line continues into its successor (autowrap) — the renderer re-joins the pair so the
    /// client re-wraps at its own width. Only trusted when the line is full to the last column (a
    /// stale flag on a since-rewritten short row must not merge unrelated lines).
    pub soft_wrapped: bool,
    /// The line carried an OSC 133 `A` shell-prompt mark.
    pub is_prompt: bool,
}

/// One screen's cells plus the per-row flags that travel with them through every scroll.
#[derive(Clone, PartialEq, Eq, Debug)]
struct Grid {
    cells: Vec<Vec<Cell>>,
    /// `wrapped[r]` means row `r` overflowed INTO row `r+1` via DECAWM autowrap (the two are one
    /// logical line). Shifted with the rows by every scroll/insert/delete; a freshly-filled (blank)
    /// row is never wrapped.
    wrapped: Vec<bool>,
    /// `prompt[r]` means the shell emitted an OSC 133 `A` while the cursor stood on row `r`.
    /// Carried for exactly one reason — the renderer re-emits the mark so a cold-reattached
    /// client's terminal gets its prompt ROWS back, which is what `jump_to_prompt` counts.
    prompt: Vec<bool>,
}

impl Grid {
    fn new(rows: usize, cols: usize, fill: &Cell) -> Self {
        Self {
            cells: vec![vec![fill.clone(); cols]; rows],
            wrapped: vec![false; rows],
            prompt: vec![false; rows],
        }
    }
}

/// Saved-cursor state (DECSC/DECRC) — one slot per screen, xterm-style.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "DECSC saves exactly these independent modes"
)]
struct SavedCursor {
    row: usize,
    col: usize,
    origin_mode: bool,
    g0_graphics: bool,
    g1_graphics: bool,
    using_g1: bool,
    style: CellStyle,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ParseState {
    Ground,
    Escape,
    /// ESC + one intermediate collected (e.g. `(`, `)`, `#`) — the NEXT byte finishes it.
    EscapeIntermediate(u8),
    Csi,
    /// OSC/DCS/SOS/PM/APC body — skipped to ST (`ESC \`), BEL also terminates OSC.
    StringBody {
        bel_terminates: bool,
        saw_esc: bool,
    },
}

/// The rendered-screen dump. `lines` has exactly `rows` entries, each with trailing whitespace
/// trimmed (the cursor may sit past a line's trimmed end).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    /// Grid height.
    pub rows: usize,
    /// Grid width.
    pub cols: usize,
    /// Cursor row (0-based).
    pub cursor_row: usize,
    /// Cursor column (0-based).
    pub cursor_col: usize,
    /// DECTCEM.
    pub cursor_visible: bool,
    /// Whether the alt screen is active.
    pub alt_screen: bool,
    /// One trimmed string per row.
    pub lines: Vec<String>,
}

// There is deliberately no `detection_text()` here. herdr's detection text — trailing blank rows
// dropped, `\n`-joined, one trailing newline — is DERIVED from `lines`, and the manifest engine
// that consumes it lives in Swift (`SlopDeskAgentDetect`). Computing it on both sides of the socket
// would be one rule written twice in two languages, free to drift; it is written once, in
// `ScreenSnapshot.detectionText`.

/// Everything the snapshot renderer needs to reproduce this model's visible state on a fresh
/// terminal.
///
/// Attributed grids + scrollback, cursor, deferred wrap, scroll region, modes, charsets, keypad,
/// live SGR, and the active screen's saved cursor.
#[derive(Clone, PartialEq, Eq, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "a terminal's modes ARE independent booleans; a bitfield would only cost them their names"
)]
pub struct ReplaySnapshot {
    /// Grid height.
    pub rows: usize,
    /// Grid width.
    pub cols: usize,
    /// Captured history, oldest first.
    pub scrollback: Vec<ScrollbackLine>,
    /// The main screen's cells.
    pub main_cells: Vec<Vec<Cell>>,
    /// Per-main-row soft-wrap flags.
    pub main_wrapped: Vec<bool>,
    /// Per-main-row OSC 133 `A` prompt marks.
    pub main_prompt: Vec<bool>,
    /// The alt screen's cells.
    pub alt_cells: Vec<Vec<Cell>>,
    /// Whether the alt screen is active.
    pub using_alt: bool,
    /// Cursor row.
    pub cursor_row: usize,
    /// Cursor column.
    pub cursor_col: usize,
    /// DECTCEM.
    pub cursor_visible: bool,
    /// DECAWM deferred wrap is armed.
    pub wrap_pending: bool,
    /// DECAWM.
    pub autowrap: bool,
    /// DECOM.
    pub origin_mode: bool,
    /// DECSTBM top (0-based).
    pub scroll_top: usize,
    /// DECSTBM bottom (0-based).
    pub scroll_bottom: usize,
    /// G0 is DEC special graphics.
    pub g0_graphics: bool,
    /// G1 is DEC special graphics.
    pub g1_graphics: bool,
    /// SO (G1 selected).
    pub using_g1: bool,
    /// DECKPAM.
    pub application_keypad: bool,
    /// DECSCUSR shape (0 = terminal default — nothing re-emitted).
    pub cursor_shape: usize,
    /// The live SGR state.
    pub style: CellStyle,
    /// The ACTIVE screen's saved-cursor row.
    pub saved_cursor_row: usize,
    /// The ACTIVE screen's saved-cursor column.
    pub saved_cursor_col: usize,
    /// The MAIN screen's saved-cursor row (the slot `?1049h` will overwrite on entry) — only
    /// meaningful when `using_alt`.
    pub saved_main_row: usize,
    /// The MAIN screen's saved-cursor column.
    pub saved_main_col: usize,
}

/// `133;A` — the OSC-133 shell-integration prompt-start mark, the one OSC body this model INSPECTS.
const PROMPT_MARK_PATTERN: &[u8] = b"133;A";

/// The VT screen model. See the module docs.
#[derive(Clone, PartialEq, Eq, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "a terminal's modes ARE independent booleans; a bitfield would only cost them their names"
)]
pub struct ScreenModel {
    rows: usize,
    cols: usize,
    scrollback_limit: usize,

    main: Grid,
    alt: Grid,
    using_alt: bool,

    cursor_row: usize,
    cursor_col: usize,
    cursor_visible: bool,
    /// DECAWM deferred wrap: writing the last column arms this; the NEXT printable wraps first.
    wrap_pending: bool,
    autowrap: bool,
    origin_mode: bool,
    scroll_top: usize,
    scroll_bottom: usize,

    saved_main: SavedCursor,
    saved_alt: SavedCursor,

    g0_graphics: bool,
    g1_graphics: bool,
    using_g1: bool,

    /// The live SGR state — stamped onto every printed cell; BCE fill derives from its bg.
    style: CellStyle,

    /// DECKPAM/DECKPNM, re-asserted by the renderer so a live TUI keeps its keypad across a
    /// reattach.
    application_keypad: bool,

    /// DECSCUSR — the last cursor-shape request, 0 = terminal default. Last-wins GLOBAL (not
    /// per-screen), which is xterm's semantics: the shell integration's bar-at-prompt cursor must
    /// survive a state-transfer reattach.
    cursor_shape: usize,

    /// Captured scrollback (oldest-first), bounded by `scrollback_limit` (0 = capture off — the
    /// default, so the resident detection grid / `screen` verb pay nothing). Stored with a dead
    /// prefix (`scrollback_head`): per-line eviction at the cap is an index bump, not an O(cap)
    /// shift per scrolled line; the prefix is compacted in one move once it grows to the cap
    /// (amortised O(1), storage bounded at 2× the cap).
    scrollback_storage: Vec<ScrollbackLine>,
    scrollback_head: usize,

    /// The last printed grapheme (REP repeats it; combining marks attach to its cell).
    last_graphic: Option<(CellText, usize)>,
    last_cell_row: Option<usize>,
    last_cell_col: Option<usize>,

    state: ParseState,

    // CSI accumulation (bounded: params capped in count + magnitude — validate-then-drop).
    csi_private: u8,
    csi_params: Vec<i64>,
    /// Parallel to `csi_params`: true when the param was introduced by a COLON separator (an SGR
    /// sub-parameter, e.g. the `3` in `4:3`) — SGR must not read it as a top-level code, where
    /// `4:0` (underline-off) would misparse as underline + reset-all.
    csi_colon_flags: Vec<bool>,
    csi_current: Option<i64>,
    csi_next_param_colon: bool,
    csi_intermediate: u8,

    // UTF-8 accumulation.
    utf8_pending: Vec<u8>,
    utf8_expected: usize,

    /// How much of [`PROMPT_MARK_PATTERN`] the CURRENT string body has matched — `None` once the
    /// body can no longer be the mark (or when no body is open).
    prompt_mark_match: Option<usize>,
}

impl ScreenModel {
    /// A model at `rows`×`cols` with scrollback capture disabled.
    #[must_use]
    pub fn new(rows: usize, cols: usize) -> Self {
        Self::with_scrollback(rows, cols, 0)
    }

    /// A model at `rows`×`cols` capturing at most `scrollback_limit` scrolled-off lines (0 = off).
    #[must_use]
    pub fn with_scrollback(rows: usize, cols: usize, scrollback_limit: usize) -> Self {
        // Clamp to a sane grid — the callers validate, but the model itself never traps.
        let rows = rows.clamp(1, MAX_ROWS);
        let cols = cols.clamp(1, MAX_COLS);
        let blank = Cell::blank();
        Self {
            rows,
            cols,
            scrollback_limit: scrollback_limit.min(MAX_SCROLLBACK),
            main: Grid::new(rows, cols, &blank),
            alt: Grid::new(rows, cols, &blank),
            using_alt: false,
            cursor_row: 0,
            cursor_col: 0,
            cursor_visible: true,
            wrap_pending: false,
            autowrap: true,
            origin_mode: false,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            saved_main: SavedCursor::default(),
            saved_alt: SavedCursor::default(),
            g0_graphics: false,
            g1_graphics: false,
            using_g1: false,
            style: CellStyle::PLAIN,
            application_keypad: false,
            cursor_shape: 0,
            scrollback_storage: Vec::new(),
            scrollback_head: 0,
            last_graphic: None,
            last_cell_row: None,
            last_cell_col: None,
            state: ParseState::Ground,
            csi_private: 0,
            csi_params: Vec::new(),
            csi_colon_flags: Vec::new(),
            csi_current: None,
            csi_next_param_colon: false,
            csi_intermediate: 0,
            utf8_pending: Vec::new(),
            utf8_expected: 0,
            prompt_mark_match: None,
        }
    }

    /// Grid height.
    #[must_use]
    pub const fn rows(&self) -> usize {
        self.rows
    }

    /// Grid width.
    #[must_use]
    pub const fn cols(&self) -> usize {
        self.cols
    }

    /// Feeds raw PTY bytes through the state machine. Stateful across calls — a sequence split over
    /// two chunks parses identically to one contiguous buffer.
    pub fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            self.consume(byte);
        }
    }

    /// Dumps the current screen. Trailing whitespace is trimmed per line; continuation cells of
    /// wide characters contribute nothing.
    #[must_use]
    pub fn snapshot(&self) -> Snapshot {
        let grid = self.active_grid();
        let lines = grid
            .cells
            .iter()
            .map(|row| {
                let mut line = String::with_capacity(self.cols);
                for cell in row {
                    if !cell.is_continuation {
                        cell.text.push_to(&mut line);
                    }
                }
                while line.ends_with(' ') {
                    line.pop();
                }
                line
            })
            .collect();
        Snapshot {
            rows: self.rows,
            cols: self.cols,
            cursor_row: self.cursor_row,
            cursor_col: self.cursor_col,
            cursor_visible: self.cursor_visible,
            alt_screen: self.using_alt,
            lines,
        }
    }

    /// The full-state dump the renderer consumes.
    #[must_use]
    pub fn replay_snapshot(&self) -> ReplaySnapshot {
        let active = if self.using_alt {
            &self.saved_alt
        } else {
            &self.saved_main
        };
        ReplaySnapshot {
            rows: self.rows,
            cols: self.cols,
            scrollback: self.scrollback_storage[self.scrollback_head..].to_vec(),
            main_cells: self.main.cells.clone(),
            main_wrapped: self.main.wrapped.clone(),
            main_prompt: self.main.prompt.clone(),
            alt_cells: self.alt.cells.clone(),
            using_alt: self.using_alt,
            cursor_row: self.cursor_row,
            cursor_col: self.cursor_col,
            cursor_visible: self.cursor_visible,
            wrap_pending: self.wrap_pending,
            autowrap: self.autowrap,
            origin_mode: self.origin_mode,
            scroll_top: self.scroll_top,
            scroll_bottom: self.scroll_bottom,
            g0_graphics: self.g0_graphics,
            g1_graphics: self.g1_graphics,
            using_g1: self.using_g1,
            application_keypad: self.application_keypad,
            cursor_shape: self.cursor_shape,
            style: self.style,
            saved_cursor_row: active.row,
            saved_cursor_col: active.col,
            saved_main_row: self.saved_main.row,
            saved_main_col: self.saved_main.col,
        }
    }

    // MARK: Byte pump

    fn consume(&mut self, byte: u8) {
        match self.state {
            ParseState::Ground => self.consume_ground(byte),
            ParseState::Escape => self.consume_escape(byte),
            ParseState::EscapeIntermediate(intermediate) => {
                self.state = ParseState::Ground;
                self.esc_final(intermediate, byte);
            },
            ParseState::Csi => self.consume_csi(byte),
            ParseState::StringBody {
                bel_terminates,
                saw_esc,
            } => {
                self.consume_string_body(byte, bel_terminates, saw_esc);
            },
        }
    }

    fn consume_ground(&mut self, byte: u8) {
        if self.utf8_expected > 0 {
            // Mid multi-byte scalar: a continuation byte extends it; anything else aborts the
            // partial scalar (dropped) and re-dispatches the byte.
            if byte & 0xC0 == 0x80 {
                self.utf8_pending.push(byte);
                self.utf8_expected -= 1;
                if self.utf8_expected == 0 {
                    self.flush_utf8_scalar();
                }
                return;
            }
            self.utf8_pending.clear();
            self.utf8_expected = 0;
        }
        match byte {
            0x1B => self.state = ParseState::Escape,
            0x0D => {
                self.cursor_col = 0;
                self.wrap_pending = false;
            },
            0x0A..=0x0C => self.line_feed(),
            0x08 => {
                self.cursor_col = self.cursor_col.saturating_sub(1);
                self.wrap_pending = false;
            },
            0x09 => {
                self.cursor_col = next_tab_stop(self.cursor_col);
                self.cursor_col = self.cursor_col.min(self.cols - 1);
                self.wrap_pending = false;
            },
            0x0E => self.using_g1 = true,
            0x0F => self.using_g1 = false,
            0x00..=0x1F | 0x7F => {},
            0x20..=0x7E => self.print_scalar(char::from(byte)),
            _ => {
                // 0x80+ — a UTF-8 lead byte. Stray continuation / invalid lead → dropped.
                if byte & 0xE0 == 0xC0 {
                    self.utf8_pending = vec![byte];
                    self.utf8_expected = 1;
                } else if byte & 0xF0 == 0xE0 {
                    self.utf8_pending = vec![byte];
                    self.utf8_expected = 2;
                } else if byte & 0xF8 == 0xF0 {
                    self.utf8_pending = vec![byte];
                    self.utf8_expected = 3;
                }
            },
        }
    }

    fn flush_utf8_scalar(&mut self) {
        let scalar = std::str::from_utf8(&self.utf8_pending)
            .ok()
            .and_then(|text| text.chars().next());
        self.utf8_pending.clear();
        if let Some(scalar) = scalar {
            self.print_scalar(scalar);
        }
    }

    fn consume_escape(&mut self, byte: u8) {
        match byte {
            b'[' => {
                self.state = ParseState::Csi;
                self.csi_private = 0;
                self.csi_params.clear();
                self.csi_colon_flags.clear();
                self.csi_current = None;
                self.csi_next_param_colon = false;
                self.csi_intermediate = 0;
            },
            b']' => {
                self.state = ParseState::StringBody {
                    bel_terminates: true,
                    saw_esc: false,
                };
                self.prompt_mark_match = Some(0); // arm the OSC 133 `A` matcher for this body
            },
            b'P' | b'X' | b'^' | b'_' => {
                self.state = ParseState::StringBody {
                    bel_terminates: false,
                    saw_esc: false,
                };
                self.prompt_mark_match = None;
            },
            b'(' | b')' | b'#' | b'*' | b'+' | b'%' => {
                self.state = ParseState::EscapeIntermediate(byte);
            },
            b'7' => {
                self.state = ParseState::Ground;
                self.save_cursor();
            },
            b'8' => {
                self.state = ParseState::Ground;
                self.restore_cursor();
            },
            b'=' => {
                self.state = ParseState::Ground;
                self.application_keypad = true;
            },
            b'>' => {
                self.state = ParseState::Ground;
                self.application_keypad = false;
            },
            b'D' => {
                self.state = ParseState::Ground;
                self.line_feed();
            },
            b'E' => {
                self.state = ParseState::Ground;
                self.cursor_col = 0;
                self.line_feed();
            },
            b'M' => {
                self.state = ParseState::Ground;
                self.reverse_index();
            },
            b'c' => {
                self.state = ParseState::Ground;
                self.full_reset();
            },
            0x1B => self.state = ParseState::Escape,
            _ => self.state = ParseState::Ground,
        }
    }

    fn esc_final(&mut self, intermediate: u8, final_byte: u8) {
        match intermediate {
            b'(' => self.g0_graphics = final_byte == b'0',
            b')' => self.g1_graphics = final_byte == b'0',
            b'#' if final_byte == b'8' => self.dec_alignment_test(),
            _ => {},
        }
    }

    fn consume_csi(&mut self, byte: u8) {
        match byte {
            b'0'..=b'9' => {
                let digit = i64::from(byte - b'0');
                // Clamp magnitude — a hostile parameter can't force huge loops.
                self.csi_current = Some((self.csi_current.unwrap_or(0) * 10 + digit).min(9999));
            },
            b';' | b':' => {
                if self.csi_params.len() < 32 {
                    self.csi_params.push(self.csi_current.unwrap_or(0));
                    self.csi_colon_flags.push(self.csi_next_param_colon);
                }
                self.csi_current = None;
                self.csi_next_param_colon = byte == b':';
            },
            b'?' | b'>' | b'<' | b'=' => self.csi_private = byte,
            0x20..=0x2F => self.csi_intermediate = byte,
            0x40..=0x7E => {
                if let Some(current) = self.csi_current
                    && self.csi_params.len() < 32
                {
                    self.csi_params.push(current);
                    self.csi_colon_flags.push(self.csi_next_param_colon);
                }
                self.state = ParseState::Ground;
                // An intermediate marks a sequence family the model consumes unmodeled — except
                // DECSCUSR (`SP q`), whose last-wins shape the renderer must re-emit.
                if self.csi_intermediate == 0 {
                    self.csi_dispatch(byte);
                } else if self.csi_intermediate == 0x20 && byte == b'q' && self.csi_private == 0 {
                    self.cursor_shape = usize::try_from(self.raw_param(0, 0)).unwrap_or(0).min(6);
                }
            },
            0x1B => self.state = ParseState::Escape,
            0x0D => {
                self.cursor_col = 0;
                self.wrap_pending = false;
            },
            0x0A => self.line_feed(),
            0x08 => self.cursor_col = self.cursor_col.saturating_sub(1),
            _ => {},
        }
    }

    fn consume_string_body(&mut self, byte: u8, bel_terminates: bool, saw_esc: bool) {
        if saw_esc {
            // ESC \ = ST ends the body; ESC + anything else stays in the body (xterm eats it).
            if byte == b'\\' {
                self.state = ParseState::Ground;
                self.finish_string_body();
            } else {
                self.state = ParseState::StringBody {
                    bel_terminates,
                    saw_esc: false,
                };
                self.prompt_mark_match = None;
            }
            return;
        }
        if byte == 0x1B {
            self.state = ParseState::StringBody {
                bel_terminates,
                saw_esc: true,
            };
        } else if bel_terminates && byte == 0x07 {
            self.state = ParseState::Ground;
            self.finish_string_body();
        } else {
            self.advance_prompt_mark_match(byte);
        }
    }

    // MARK: OSC 133 `A` (shell-prompt mark)

    /// Folds one body byte into the prompt-mark matcher. Past the pattern the body may only
    /// continue with `;` + parameters (`133;A;aid=…`), which shells do emit — anything else (e.g.
    /// the `133;B` / `133;C` marks) is a different mark and fails.
    fn advance_prompt_mark_match(&mut self, byte: u8) {
        let Some(matched) = self.prompt_mark_match else {
            return;
        };
        if matched < PROMPT_MARK_PATTERN.len() {
            self.prompt_mark_match = (byte == PROMPT_MARK_PATTERN[matched]).then_some(matched + 1);
            return;
        }
        // Only the parameter separator may follow a complete `133;A`; once inside the parameter
        // tail every byte is accepted (it is the shell's own payload, not part of the verb).
        self.prompt_mark_match = if matched == PROMPT_MARK_PATTERN.len() && byte != b';' {
            None
        } else {
            Some(matched + 1)
        };
    }

    /// A string body just terminated: stamp the prompt mark if it was `133;A`, then re-arm.
    fn finish_string_body(&mut self) {
        if self
            .prompt_mark_match
            .is_some_and(|matched| matched >= PROMPT_MARK_PATTERN.len())
        {
            self.mark_prompt_row();
        }
        self.prompt_mark_match = None;
    }

    /// Records that the shell's prompt begins on the CURSOR's row — the same row libghostty stamps
    /// as a `.prompt` row, and therefore the row a re-emitted mark has to land on for
    /// `jump_to_prompt` to count it after a state-transfer reattach.
    fn mark_prompt_row(&mut self) {
        let row = self.cursor_row;
        if row >= self.rows {
            return;
        }
        self.active_grid_mut().prompt[row] = true;
    }

    // MARK: CSI dispatch

    fn param(&self, index: usize, default: i64) -> i64 {
        match self.csi_params.get(index) {
            None | Some(&0) => default,
            Some(&value) => value,
        }
    }

    fn raw_param(&self, index: usize, default: i64) -> i64 {
        self.csi_params.get(index).copied().unwrap_or(default)
    }

    /// A parameter used as a REPEAT COUNT: clamped into `usize` so a hostile 9999 cannot outrun the
    /// grid (every caller bounds it again against its own dimension).
    fn count_param(&self, index: usize, default: i64) -> usize {
        usize::try_from(self.param(index, default).max(1)).unwrap_or(1)
    }

    fn csi_dispatch(&mut self, final_byte: u8) {
        match final_byte {
            b'A' => self.move_cursor(-self.param(0, 1), 0),
            b'B' | b'e' => self.move_cursor(self.param(0, 1), 0),
            b'C' | b'a' => self.move_cursor(0, self.param(0, 1)),
            b'D' => self.move_cursor(0, -self.param(0, 1)),
            b'E' => {
                self.cursor_col = 0;
                self.move_cursor(self.param(0, 1), 0);
            },
            b'F' => {
                self.cursor_col = 0;
                self.move_cursor(-self.param(0, 1), 0);
            },
            b'G' | b'`' => {
                self.cursor_col = self.clamp_col(self.param(0, 1) - 1);
                self.wrap_pending = false;
            },
            b'H' | b'f' => self.set_cursor_position(self.param(0, 1) - 1, self.param(1, 1) - 1),
            b'I' => {
                for _ in 0..self.count_param(0, 1) {
                    self.cursor_col = next_tab_stop(self.cursor_col).min(self.cols - 1);
                }
                self.wrap_pending = false;
            },
            b'Z' => {
                for _ in 0..self.count_param(0, 1) {
                    self.cursor_col = previous_tab_stop(self.cursor_col);
                }
                self.wrap_pending = false;
            },
            b'd' => {
                let target = if self.origin_mode {
                    signed(self.scroll_top) + self.param(0, 1) - 1
                } else {
                    self.param(0, 1) - 1
                };
                self.cursor_row = self.clamp_row(target);
                self.wrap_pending = false;
            },
            b'J' => self.erase_in_display(self.raw_param(0, 0)),
            b'K' => self.erase_in_line(self.raw_param(0, 0)),
            b'L' => self.insert_lines(self.count_param(0, 1)),
            b'M' => self.delete_lines(self.count_param(0, 1)),
            b'P' => self.delete_chars(self.count_param(0, 1)),
            b'@' => self.insert_chars(self.count_param(0, 1)),
            b'X' => self.erase_chars(self.count_param(0, 1)),
            b'S' => self.scroll_up(self.count_param(0, 1)),
            b'T' => self.scroll_down(self.count_param(0, 1)),
            b'b' => {
                if let Some((text, width)) = self.last_graphic.clone() {
                    for _ in 0..self.count_param(0, 1).min(self.cols * 2) {
                        self.put(text.clone(), width);
                    }
                }
            },
            b'r' => {
                let bottom = self.param(1, signed(self.rows)) - 1;
                self.set_scroll_region(self.param(0, 1) - 1, bottom);
            },
            b'h' => self.set_modes(true),
            b'l' => self.set_modes(false),
            b's' => {
                if self.csi_private == 0 {
                    self.save_cursor();
                }
            },
            b'u' => {
                if self.csi_private == 0 {
                    self.restore_cursor();
                }
            },
            // SGR — tracked for the replay snapshot. `CSI > m` / `CSI ? m` (modifyOtherKeys etc.)
            // are different sequences and NOT SGR, so they fall through to the ignored tail.
            b'm' if self.csi_private == 0 => self.apply_sgr(),
            // DSR / DA / window ops / TBC / DECLL — text placement unaffected — and every unknown
            // final, which is consumed.
            _ => {},
        }
    }

    // MARK: SGR

    /// Applies an SGR parameter run to the live style. Colon-flagged params are SUB-params (e.g.
    /// underline style `4:3`) and never read as top-level codes; `38`/`48`/`58` consume their
    /// colour arguments regardless of separator form. Unknown codes are ignored.
    fn apply_sgr(&mut self) {
        if self.csi_params.is_empty() {
            self.style = CellStyle::PLAIN; // bare `CSI m` == `CSI 0 m`
            return;
        }
        let mut i = 0;
        while i < self.csi_params.len() {
            if self.csi_colon_flags.get(i).copied().unwrap_or(false) {
                i += 1; // orphan sub-param of a code we don't model (4:x, 58:…)
                continue;
            }
            let code = self.csi_params[i];
            match code {
                0 => self.style = CellStyle::PLAIN,
                1 => self.style.bold = true,
                2 => self.style.dim = true,
                3 => self.style.italic = true,
                // 21 is xterm's doubly-underlined, which renders as an underline here.
                4 | 21 => self.style.underline = true,
                5 | 6 => self.style.blink = true,
                7 => self.style.inverse = true,
                8 => self.style.hidden = true,
                9 => self.style.strikethrough = true,
                22 => {
                    self.style.bold = false;
                    self.style.dim = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                25 => self.style.blink = false,
                27 => self.style.inverse = false,
                28 => self.style.hidden = false,
                29 => self.style.strikethrough = false,
                30..=37 => self.style.fg = SgrColor::Indexed(palette_index(code - 30)),
                39 => self.style.fg = SgrColor::Default,
                40..=47 => self.style.bg = SgrColor::Indexed(palette_index(code - 40)),
                49 => self.style.bg = SgrColor::Default,
                90..=97 => self.style.fg = SgrColor::Indexed(palette_index(code - 90 + 8)),
                100..=107 => self.style.bg = SgrColor::Indexed(palette_index(code - 100 + 8)),
                38 | 48 => {
                    let (color, next) = self.parse_sgr_color(i);
                    if let Some(color) = color {
                        if code == 38 {
                            self.style.fg = color;
                        } else {
                            self.style.bg = color;
                        }
                    }
                    i = next;
                    continue;
                },
                58 => {
                    // underline colour (unmodeled) — still consume its arguments
                    i = self.parse_sgr_color(i).1;
                    continue;
                },
                _ => {},
            }
            i += 1;
        }
    }

    /// Parses the extended-colour arguments after a `38`/`48`/`58` at `index`. Returns the decoded
    /// colour (`None` for malformed/unknown subtype) and the index of the first param NOT consumed.
    /// Both wild forms decode: semicolon (`38;2;r;g;b`, strict shape) and colon (`38:2:r:g:b` /
    /// `38:2::r:g:b` with a colourspace id — the colour is the LAST three args of the colon run).
    fn parse_sgr_color(&self, index: usize) -> (Option<SgrColor>, usize) {
        let channel = |value: i64| u8::try_from(value).ok();
        // A colon run is self-delimiting: consume it whole regardless of validity.
        let mut run_end = index + 1;
        while run_end < self.csi_params.len() && self.csi_colon_flags.get(run_end).copied().unwrap_or(false) {
            run_end += 1;
        }
        if run_end > index + 1 {
            let args = &self.csi_params[index + 1..run_end];
            return match args.first() {
                Some(5) if args.len() >= 2 => (channel(args[1]).map(SgrColor::Indexed), run_end),
                Some(2) if args.len() >= 4 => {
                    let (r, g, b) = (args[args.len() - 3], args[args.len() - 2], args[args.len() - 1]);
                    match (channel(r), channel(g), channel(b)) {
                        (Some(r), Some(g), Some(b)) => (Some(SgrColor::Rgb(r, g, b)), run_end),
                        _ => (None, run_end),
                    }
                },
                _ => (None, run_end),
            };
        }
        // Semicolon form — consume exactly the strict shape.
        let subtype = index + 1;
        let Some(&kind) = self.csi_params.get(subtype) else {
            return (None, subtype);
        };
        match kind {
            5 => {
                let Some(&value) = self.csi_params.get(subtype + 1) else {
                    return (None, subtype + 1);
                };
                (channel(value).map(SgrColor::Indexed), subtype + 2)
            },
            2 => {
                if subtype + 3 >= self.csi_params.len() {
                    return (None, self.csi_params.len());
                }
                let (r, g, b) = (
                    self.csi_params[subtype + 1],
                    self.csi_params[subtype + 2],
                    self.csi_params[subtype + 3],
                );
                match (channel(r), channel(g), channel(b)) {
                    (Some(r), Some(g), Some(b)) => (Some(SgrColor::Rgb(r, g, b)), subtype + 4),
                    _ => (None, subtype + 4),
                }
            },
            _ => (None, subtype + 1),
        }
    }

    fn set_modes(&mut self, enable: bool) {
        if self.csi_private != b'?' {
            return; // SM/RM (IRM etc.) unmodeled
        }
        for mode in self.csi_params.clone() {
            match mode {
                6 => {
                    self.origin_mode = enable;
                    self.set_cursor_position(0, 0);
                },
                7 => {
                    self.autowrap = enable;
                    self.wrap_pending = false;
                },
                25 => self.cursor_visible = enable,
                47 | 1047 => self.switch_screen(enable, false, mode == 1047),
                1049 => self.switch_screen(enable, true, true),
                // mouse / bracketed-paste / kitty modes — no grid effect
                _ => {},
            }
        }
    }

    // MARK: Screen switching / reset

    fn switch_screen(&mut self, to_alt: bool, save_restore_cursor: bool, clear_alt_on_enter: bool) {
        if to_alt == self.using_alt {
            return;
        }
        if to_alt {
            if save_restore_cursor {
                self.save_cursor();
            }
            self.using_alt = true;
            if clear_alt_on_enter {
                let fill = self.blank_fill();
                self.alt = Grid::new(self.rows, self.cols, &fill);
            }
            if save_restore_cursor {
                self.set_cursor_position(0, 0);
            }
        } else {
            self.using_alt = false;
            if save_restore_cursor {
                self.restore_cursor();
            }
        }
        self.wrap_pending = false;
    }

    fn full_reset(&mut self) {
        let blank = Cell::blank();
        self.main = Grid::new(self.rows, self.cols, &blank);
        self.alt = Grid::new(self.rows, self.cols, &blank);
        self.using_alt = false;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.wrap_pending = false;
        self.autowrap = true;
        self.origin_mode = false;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.g0_graphics = false;
        self.g1_graphics = false;
        self.using_g1 = false;
        self.saved_main = SavedCursor::default();
        self.saved_alt = SavedCursor::default();
        self.last_graphic = None;
        self.style = CellStyle::PLAIN;
        self.application_keypad = false;
        self.cursor_shape = 0;
        self.prompt_mark_match = None;
        // Scrollback survives RIS (xterm: only `ED 3` erases saved lines).
    }

    // MARK: BCE fill helpers

    /// A blank cell in the CURRENT erase style (xterm background-colour-erase: fills take the live
    /// background, never the other attributes).
    const fn blank_fill(&self) -> Cell {
        Cell::erase_fill(&self.style)
    }

    fn blank_row_cells(&self) -> Vec<Cell> {
        vec![self.blank_fill(); self.cols]
    }

    fn dec_alignment_test(&mut self) {
        let rows = self.rows;
        let cols = self.cols;
        let filled = Cell {
            text: CellText::Char('E'),
            is_continuation: false,
            style: CellStyle::PLAIN,
        };
        let grid = self.active_grid_mut();
        for r in 0..rows {
            for c in 0..cols {
                grid.cells[r][c] = filled.clone();
            }
        }
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
        self.set_cursor_position(0, 0);
    }

    // MARK: Cursor

    fn clamp_row(&self, row: i64) -> usize {
        usize::try_from(row.clamp(0, signed(self.rows - 1))).unwrap_or(0)
    }

    fn clamp_col(&self, col: i64) -> usize {
        usize::try_from(col.clamp(0, signed(self.cols - 1))).unwrap_or(0)
    }

    const fn save_cursor(&mut self) {
        let saved = SavedCursor {
            row: self.cursor_row,
            col: self.cursor_col,
            origin_mode: self.origin_mode,
            g0_graphics: self.g0_graphics,
            g1_graphics: self.g1_graphics,
            using_g1: self.using_g1,
            style: self.style,
        };
        if self.using_alt {
            self.saved_alt = saved;
        } else {
            self.saved_main = saved;
        }
    }

    fn restore_cursor(&mut self) {
        let saved = if self.using_alt {
            self.saved_alt
        } else {
            self.saved_main
        };
        self.cursor_row = self.clamp_row(signed(saved.row));
        self.cursor_col = self.clamp_col(signed(saved.col));
        self.origin_mode = saved.origin_mode;
        self.g0_graphics = saved.g0_graphics;
        self.g1_graphics = saved.g1_graphics;
        self.using_g1 = saved.using_g1;
        self.style = saved.style;
        self.wrap_pending = false;
    }

    fn set_cursor_position(&mut self, row: i64, col: i64) {
        if self.origin_mode {
            let target = signed(self.scroll_top) + row;
            let clamped = target.clamp(signed(self.scroll_top), signed(self.scroll_bottom));
            self.cursor_row = usize::try_from(clamped).unwrap_or(0);
        } else {
            self.cursor_row = self.clamp_row(row);
        }
        self.cursor_col = self.clamp_col(col);
        self.wrap_pending = false;
    }

    fn move_cursor(&mut self, row_delta: i64, col_delta: i64) {
        if row_delta != 0 {
            // Relative vertical motion pins inside the scroll region when starting inside it.
            let top = if self.cursor_row >= self.scroll_top {
                self.scroll_top
            } else {
                0
            };
            let bottom = if self.cursor_row <= self.scroll_bottom {
                self.scroll_bottom
            } else {
                self.rows - 1
            };
            let target = (signed(self.cursor_row) + row_delta).clamp(signed(top), signed(bottom));
            self.cursor_row = usize::try_from(target).unwrap_or(0);
        }
        if col_delta != 0 {
            self.cursor_col = self.clamp_col(signed(self.cursor_col) + col_delta);
        }
        self.wrap_pending = false;
    }

    fn set_scroll_region(&mut self, top: i64, bottom: i64) {
        let t = self.clamp_row(top);
        let b = self.clamp_row(bottom);
        if t >= b {
            return; // degenerate region — ignored, xterm-style
        }
        self.scroll_top = t;
        self.scroll_bottom = b;
        self.set_cursor_position(0, 0);
    }

    // MARK: Scrolling / line feed

    fn line_feed(&mut self) {
        self.wrap_pending = false;
        if self.cursor_row == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor_row < self.rows - 1 {
            self.cursor_row += 1;
        }
    }

    fn reverse_index(&mut self) {
        self.wrap_pending = false;
        if self.cursor_row == self.scroll_top {
            self.scroll_down(1);
        } else if self.cursor_row > 0 {
            self.cursor_row -= 1;
        }
    }

    fn scroll_up(&mut self, n: usize) {
        let count = n.max(1).min(self.scroll_bottom - self.scroll_top + 1);
        // Scrollback capture (xterm): only the MAIN screen with a FULL-SCREEN scroll region accrues
        // history — a DECSTBM sub-region discards, and the alt screen never captures.
        if !self.using_alt
            && self.scroll_top == 0
            && self.scroll_bottom == self.rows - 1
            && self.scrollback_limit > 0
        {
            for r in 0..count {
                let cells = self.main.cells[r].clone();
                // The join guard: a wrap flag is only trusted on a line still FULL to its last
                // column (a since-rewritten short row must not merge with its old continuation).
                let soft_wrapped = self.main.wrapped[r] && row_reaches_last_column(&cells);
                let is_prompt = self.main.prompt[r];
                self.scrollback_storage.push(ScrollbackLine {
                    cells,
                    soft_wrapped,
                    is_prompt,
                });
            }
            let live = self.scrollback_storage.len() - self.scrollback_head;
            if live > self.scrollback_limit {
                self.scrollback_head += live - self.scrollback_limit;
                if self.scrollback_head >= self.scrollback_limit {
                    self.scrollback_storage.drain(..self.scrollback_head);
                    self.scrollback_head = 0;
                }
            }
        }
        let blank_row = self.blank_row_cells();
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let grid = self.active_grid_mut();
        for r in top..=bottom {
            let source = r + count;
            if source <= bottom {
                grid.cells.swap(r, source);
                grid.wrapped[r] = grid.wrapped[source];
                grid.prompt[r] = grid.prompt[source];
            } else {
                grid.cells[r].clone_from(&blank_row);
                grid.wrapped[r] = false;
                grid.prompt[r] = false;
            }
        }
    }

    fn scroll_down(&mut self, n: usize) {
        let count = n.max(1).min(self.scroll_bottom - self.scroll_top + 1);
        let blank_row = self.blank_row_cells();
        let (top, bottom) = (self.scroll_top, self.scroll_bottom);
        let grid = self.active_grid_mut();
        for r in (top..=bottom).rev() {
            match r.checked_sub(count) {
                Some(source) if source >= top => {
                    grid.cells.swap(r, source);
                    grid.wrapped[r] = grid.wrapped[source];
                    grid.prompt[r] = grid.prompt[source];
                },
                _ => {
                    grid.cells[r].clone_from(&blank_row);
                    grid.wrapped[r] = false;
                    grid.prompt[r] = false;
                },
            }
        }
    }

    // MARK: Erase / insert / delete

    fn erase_in_display(&mut self, mode: i64) {
        let blank_row = self.blank_row_cells();
        let fill = self.blank_fill();
        let (rows, cols) = (self.rows, self.cols);
        let (cursor_row, cursor_col) = (self.cursor_row, self.cursor_col);
        match mode {
            0 => {
                let grid = self.active_grid_mut();
                erase_cells(grid, cursor_row, cursor_col, cols, &fill);
                for r in (cursor_row + 1)..rows {
                    grid.cells[r].clone_from(&blank_row);
                    grid.wrapped[r] = false;
                    grid.prompt[r] = false;
                }
            },
            1 => {
                let grid = self.active_grid_mut();
                for r in 0..cursor_row {
                    grid.cells[r].clone_from(&blank_row);
                    grid.wrapped[r] = false;
                    grid.prompt[r] = false;
                }
                erase_cells(grid, cursor_row, 0, cursor_col + 1, &fill);
            },
            2 | 3 => {
                let fresh = Grid::new(rows, cols, &fill);
                *self.active_grid_mut() = fresh;
                // ED 3 = xterm "Erase Saved Lines". (The screen-clearing side keeps the model's
                // long-standing 2≡3 behaviour — herdr-parity pins it.)
                if mode == 3 {
                    self.scrollback_storage.clear();
                    self.scrollback_head = 0;
                }
            },
            _ => {},
        }
        self.wrap_pending = false;
    }

    fn erase_in_line(&mut self, mode: i64) {
        let fill = self.blank_fill();
        let blank_row = self.blank_row_cells();
        let (cursor_row, cursor_col, cols) = (self.cursor_row, self.cursor_col, self.cols);
        let grid = self.active_grid_mut();
        match mode {
            0 => erase_cells(grid, cursor_row, cursor_col, cols, &fill),
            1 => erase_cells(grid, cursor_row, 0, cursor_col + 1, &fill),
            2 => grid.cells[cursor_row] = blank_row,
            _ => {},
        }
        self.wrap_pending = false;
    }

    fn insert_lines(&mut self, n: usize) {
        if self.cursor_row < self.scroll_top || self.cursor_row > self.scroll_bottom {
            return;
        }
        let count = n.max(1).min(self.scroll_bottom - self.cursor_row + 1);
        let blank_row = self.blank_row_cells();
        let (cursor_row, bottom) = (self.cursor_row, self.scroll_bottom);
        let grid = self.active_grid_mut();
        for r in (cursor_row..=bottom).rev() {
            match r.checked_sub(count) {
                Some(source) if source >= cursor_row => {
                    grid.cells.swap(r, source);
                    grid.wrapped[r] = grid.wrapped[source];
                    grid.prompt[r] = grid.prompt[source];
                },
                _ => {
                    grid.cells[r].clone_from(&blank_row);
                    grid.wrapped[r] = false;
                    grid.prompt[r] = false;
                },
            }
        }
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    fn delete_lines(&mut self, n: usize) {
        if self.cursor_row < self.scroll_top || self.cursor_row > self.scroll_bottom {
            return;
        }
        let count = n.max(1).min(self.scroll_bottom - self.cursor_row + 1);
        let blank_row = self.blank_row_cells();
        let (cursor_row, bottom) = (self.cursor_row, self.scroll_bottom);
        let grid = self.active_grid_mut();
        for r in cursor_row..=bottom {
            let source = r + count;
            if source <= bottom {
                grid.cells.swap(r, source);
                grid.wrapped[r] = grid.wrapped[source];
                grid.prompt[r] = grid.prompt[source];
            } else {
                grid.cells[r].clone_from(&blank_row);
                grid.wrapped[r] = false;
                grid.prompt[r] = false;
            }
        }
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    fn insert_chars(&mut self, n: usize) {
        let count = n.max(1).min(self.cols - self.cursor_col);
        let fill = self.blank_fill();
        let (cursor_row, cursor_col, cols) = (self.cursor_row, self.cursor_col, self.cols);
        let grid = self.active_grid_mut();
        let row = &mut grid.cells[cursor_row];
        // The shift splits a wide pair at two seams — the insertion point (a blank lands between
        // the halves) and the right edge (the continuation is pushed off, the lead is not). A split
        // half blanks whole, as with erasing and overwriting.
        if row[cursor_col].is_continuation {
            if cursor_col > 0 {
                row[cursor_col - 1] = Cell::blank();
            }
            row[cursor_col] = Cell::blank();
        }
        if cols - count > 0 && row[cols - count].is_continuation {
            row[cols - count - 1] = Cell::blank();
        }
        row.drain(cols - count..cols);
        row.splice(cursor_col..cursor_col, std::iter::repeat_n(fill, count));
        self.wrap_pending = false;
    }

    fn delete_chars(&mut self, n: usize) {
        let count = n.max(1).min(self.cols - self.cursor_col);
        let fill = self.blank_fill();
        let (cursor_row, cursor_col, cols) = (self.cursor_row, self.cursor_col, self.cols);
        let grid = self.active_grid_mut();
        let row = &mut grid.cells[cursor_row];
        // The deleted range can split a wide pair at either end: a lead left behind at the start,
        // or a continuation shifted onto the cursor from past the end. Both halves blank.
        if row[cursor_col].is_continuation && cursor_col > 0 {
            row[cursor_col - 1] = Cell::blank();
        }
        if cursor_col + count < cols && row[cursor_col + count].is_continuation {
            row[cursor_col + count] = Cell::blank();
        }
        row.drain(cursor_col..cursor_col + count);
        row.extend(std::iter::repeat_n(fill, count));
        self.wrap_pending = false;
    }

    fn erase_chars(&mut self, n: usize) {
        let count = n.max(1).min(self.cols - self.cursor_col);
        let fill = self.blank_fill();
        let (cursor_row, cursor_col) = (self.cursor_row, self.cursor_col);
        let grid = self.active_grid_mut();
        erase_cells(grid, cursor_row, cursor_col, cursor_col + count, &fill);
        self.wrap_pending = false;
    }

    const fn active_grid(&self) -> &Grid {
        if self.using_alt { &self.alt } else { &self.main }
    }

    const fn active_grid_mut(&mut self) -> &mut Grid {
        if self.using_alt {
            &mut self.alt
        } else {
            &mut self.main
        }
    }

    // MARK: Printing

    fn print_scalar(&mut self, scalar: char) {
        let mut resolved = scalar;
        let graphics_active = if self.using_g1 {
            self.g1_graphics
        } else {
            self.g0_graphics
        };
        if graphics_active && let Some(mapped) = dec_graphic(scalar as u32) {
            resolved = mapped;
        }
        let width = scalar_width(resolved as u32);
        if width == 0 {
            self.attach_combining(resolved);
            return;
        }
        let text = CellText::Char(resolved);
        self.put(text.clone(), width);
        self.last_graphic = Some((text, width));
    }

    /// Appends a zero-width scalar (combining mark, ZWJ, variation selector) to the LAST printed
    /// cell — width stays what the base character established.
    fn attach_combining(&mut self, scalar: char) {
        let (Some(row), Some(col)) = (self.last_cell_row, self.last_cell_col) else {
            return;
        };
        if row >= self.rows || col >= self.cols {
            return;
        }
        self.active_grid_mut().cells[row][col]
            .text
            .append_combining(scalar);
    }

    fn put(&mut self, text: CellText, width: usize) {
        if self.wrap_pending && self.autowrap {
            self.wrap_pending = false;
            // The row being left continues into its successor — one logical line.
            self.mark_wrapped(self.cursor_row);
            self.cursor_col = 0;
            self.line_feed();
        }
        // A wide char that doesn't fit in the remaining columns wraps whole (or pins).
        if width == 2 && self.cursor_col >= self.cols - 1 {
            if self.autowrap {
                self.blank_cell(self.cursor_row, self.cursor_col);
                self.mark_wrapped(self.cursor_row);
                self.cursor_col = 0;
                self.line_feed();
            } else {
                self.cursor_col = self.cols.saturating_sub(2);
            }
        }

        let style = self.style;
        let (row, col, cols) = (self.cursor_row, self.cursor_col, self.cols);
        let grid = self.active_grid_mut();
        clear_wide_partner(grid, row, col, cols);
        grid.cells[row][col] = Cell {
            text,
            is_continuation: false,
            style,
        };
        if width == 2 && col + 1 < cols {
            clear_wide_partner(grid, row, col + 1, cols);
            grid.cells[row][col + 1] = Cell {
                text: CellText::Empty,
                is_continuation: true,
                style,
            };
        }
        self.last_cell_row = Some(row);
        self.last_cell_col = Some(col);

        if self.cursor_col + width >= self.cols {
            self.cursor_col = self.cols - 1;
            if self.autowrap {
                self.wrap_pending = true;
            }
        } else {
            self.cursor_col += width;
        }
    }

    fn blank_cell(&mut self, row: usize, col: usize) {
        let fill = self.blank_fill();
        let cols = self.cols;
        let grid = self.active_grid_mut();
        clear_wide_partner(grid, row, col, cols);
        grid.cells[row][col] = fill;
    }

    /// Marks `row` as soft-wrapping into its successor on the ACTIVE grid.
    fn mark_wrapped(&mut self, row: usize) {
        if row >= self.rows {
            return;
        }
        self.active_grid_mut().wrapped[row] = true;
    }
}

/// A grid coordinate as signed arithmetic. Every dimension here is bounded by [`MAX_ROWS`] /
/// [`MAX_COLS`], so the conversion is always exact — the saturating fallback exists only to keep
/// the function total.
fn signed(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

/// An SGR palette index from its already-range-checked offset (`30..=37` etc.), so the caller reads
/// as the colour table it is rather than a cast.
fn palette_index(offset: i64) -> u8 {
    u8::try_from(offset).unwrap_or_default()
}

/// Tab stops are every 8 columns, fixed — this model does not implement HTS/TBC, so the stop is
/// arithmetic rather than a table.
#[expect(
    clippy::integer_division,
    reason = "the division IS the every-8-columns tab stop"
)]
const fn next_tab_stop(col: usize) -> usize {
    (col / 8 + 1) * 8
}

/// The tab stop at or before `col` (CBT), never below column 0.
#[expect(
    clippy::integer_division,
    reason = "the division IS the every-8-columns tab stop"
)]
const fn previous_tab_stop(col: usize) -> usize {
    col.saturating_sub(1) / 8 * 8
}

/// The scrollback/transcript join guard: a wrap flag is only trusted on a row still FULL to its
/// last column.
#[must_use]
pub fn row_reaches_last_column(cells: &[Cell]) -> bool {
    cells.last().is_some_and(|last| !last.is_blank())
}

/// Erases `[from, to)` on `row`. An erase that splits a wide pair blanks the half OUTSIDE the range
/// too — a lone lead cell would still render two columns wide, and a lone continuation cell would
/// render as nothing, either way disagreeing with what a terminal shows. Only the range's two edges
/// can split a pair; interior partners are inside the range and erased anyway.
fn erase_cells(grid: &mut Grid, row: usize, from: usize, to: usize, fill: &Cell) {
    if from >= to {
        return;
    }
    let cols = grid.cells[row].len();
    clear_wide_partner(grid, row, from, cols);
    clear_wide_partner(grid, row, to - 1, cols);
    for col in from..to.min(cols) {
        grid.cells[row][col] = fill.clone();
    }
}

/// Overwriting half a wide pair blanks the other half (no orphan continuation cells).
fn clear_wide_partner(grid: &mut Grid, row: usize, col: usize, cols: usize) {
    if col >= cols {
        return;
    }
    if grid.cells[row][col].is_continuation {
        if col > 0 {
            grid.cells[row][col - 1] = Cell::blank();
        }
    } else if col + 1 < cols && grid.cells[row][col + 1].is_continuation {
        grid.cells[row][col + 1] = Cell::blank();
    }
}
