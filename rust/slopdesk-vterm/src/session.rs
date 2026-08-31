//! The one owner of the engine, and the only place its confinement rules are enforced.
//!
//! Every libghostty-vt handle is `!Send` and `!Sync`. Upstream does not lock anything: the caller
//! serialises. [`VtSession`] is that serialisation made structural — it owns the terminal, the
//! render state, both iterators and both encoders, so there is no way to hold one without holding
//! all of them, and no way to read the grid while a write is in flight.
//!
//! ## The fill is the only phase that touches the engine
//!
//! [`VtSession::render`] is deliberately shaped around `begin_update` / `end`:
//!
//! 1. `begin_update` is the only call that needs the terminal. It is the only one that would have
//!    to be serialised against `vt_write` if the two ever ran on different threads.
//! 2. `end` performs the deferred work, reading only render-state memory.
//! 3. The scan then copies the viewport into a [`Frame`], which is plain owned data.
//!
//! Everything downstream — quads, atlas residency, the Metal encode — reads the frame and never the
//! engine. That is what buys the renderer its freedom from the confinement.
//!
//! ## Why the scan resolves colours itself
//!
//! The bindings offer `fg_color()` and `bg_color()`, which resolve palette indices for you. The
//! scan does not use them, for two reasons that both cost correctness otherwise:
//!
//! * **Bold brightening needs the index, and those doors have already spent it.** SGR 1 on one of
//!   the first eight palette colours selects the bright counterpart. Once the index is an
//!   `RgbColor` the rule cannot be applied, so the scan reads the raw [`Style`] and brightens
//!   before lookup.
//! * **Every resolved door is another C call per cell.** [`CellIteration::raw_cell`] is one call
//!   that answers text presence, styling presence, the wide-pair role and the cell-level background
//!   all at once, from a struct copied into Rust. A blank cell — most of a viewport — costs exactly
//!   that one call. A styled one costs three.

use core::fmt;

use libghostty_vt::error::Error as EngineError;
use libghostty_vt::render::{CellIterator, Dirty, RenderState, RowIterator};
use libghostty_vt::screen::{CellContentTag, CellWide};
use libghostty_vt::style::{Style, StyleColor};
use libghostty_vt::terminal::{ClipboardLocation, Mode, ScrollViewport, Terminal};

use crate::events::{self, ClipboardTarget, ClipboardWrite, EventSink};
use crate::frame::{
    CellFlags, ColumnSpan, Frame, FrameCell, FrameColors, FrameCursor, FrameDirty, Rgb, TextSpan,
    UnderlineStyle,
};
use crate::input::{KeyPress, Keyboard, MouseMove, OptionAsAlt, Pointer, SurfaceGeometry};

/// What went wrong. There is exactly one failure mode worth distinguishing from the engine's own.
#[derive(Debug, Clone, Copy)]
pub enum VtError {
    /// The engine refused. Carries its reason verbatim rather than flattening it, because
    /// `OutOfMemory` and `InvalidValue` call for different responses from a caller.
    Engine(EngineError),
    /// A grid dimension was zero. The engine treats that as invalid; catching it here names it.
    EmptyGrid,
}

/// Written out rather than derived: the engine's `Error` implements neither `PartialEq` nor `Eq`,
/// and comparing two engine errors by their *shape* is the only comparison a caller ever wants —
/// `OutOfSpace { required }` differing only in how many bytes it wanted is the same failure.
impl PartialEq for VtError {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::EmptyGrid, Self::EmptyGrid) => true,
            (Self::Engine(left), Self::Engine(right)) => {
                matches!(
                    (left, right),
                    (EngineError::OutOfMemory, EngineError::OutOfMemory)
                        | (EngineError::InvalidValue, EngineError::InvalidValue)
                        | (EngineError::OutOfSpace { .. }, EngineError::OutOfSpace { .. })
                        | (EngineError::IoError, EngineError::IoError)
                        | (EngineError::LimitExceeded, EngineError::LimitExceeded)
                )
            },
            _ => false,
        }
    }
}

impl Eq for VtError {}

impl fmt::Display for VtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Engine(error) => write!(f, "terminal engine: {error}"),
            Self::EmptyGrid => f.write_str("a terminal grid must have at least one row and column"),
        }
    }
}

impl std::error::Error for VtError {}

impl From<EngineError> for VtError {
    fn from(value: EngineError) -> Self {
        Self::Engine(value)
    }
}

/// The result of anything that talks to the engine.
pub type Result<T> = core::result::Result<T, VtError>;

/// How much larger than its payload a paste encoding can be.
///
/// `ESC [ 200 ~` and `ESC [ 201 ~` are six bytes each and nothing else the encoder does grows the
/// text — the control-byte scrub replaces in place and the newline rewrite is one-for-one. Twelve
/// is therefore the exact bound rather than a guess; [`VtSession::encode_paste`] still honours the
/// encoder's `OutOfSpace` because the bound is upstream's to change, not this crate's to assume.
const PASTE_FRAMING_HEADROOM: usize = 12;

/// How far to scroll the viewport.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    /// To the oldest row in the scrollback.
    Top,
    /// To the newest row, which is where output lands.
    Bottom,
    /// By a signed number of rows — negative is towards the scrollback.
    Delta(i32),
    /// So that an absolute SCREEN row is at the viewport's top — the coordinate space
    /// [`crate::screen`] addresses, where row 0 is the oldest retained row.
    Row(u32),
}

impl From<Scroll> for ScrollViewport {
    fn from(value: Scroll) -> Self {
        match value {
            Scroll::Top => Self::Top,
            Scroll::Bottom => Self::Bottom,
            // The engine takes an `isize`; the door takes an `i32` so the same value crosses FFI
            // unchanged on both a 64-bit host and a 32-bit one.
            Scroll::Delta(rows) => Self::Delta(isize::try_from(rows).unwrap_or(0)),
            // Widening, so `try_from` cannot fail on any target this ships to; the fallback is row
            // 0 rather than a panic because the crate promises not to panic on any input.
            Scroll::Row(row) => Self::Row(usize::try_from(row).unwrap_or(0)),
        }
    }
}

/// One terminal: the engine, its render state, and the frame the last scan produced.
///
/// Not `Send` and not `Sync`, and deliberately so — see the module header.
pub struct VtSession {
    /// `pub(crate)` for [`crate::selection`] alone: the selection doors need the terminal AND the
    /// gesture in the same borrow, and a getter cannot hand out both. Nothing outside this crate
    /// can reach it, so the confinement the module header describes is unchanged.
    pub(crate) terminal: Terminal<'static, 'static>,
    render: RenderState<'static>,
    row_iter: RowIterator<'static>,
    cell_iter: CellIterator<'static>,
    keyboard: Keyboard,
    pointer: Pointer,
    /// The selection gesture machine and its four reusable events. `pub(crate)` because
    /// [`crate::selection`] drives it and nothing else may — a second gesture over one terminal
    /// would mean two click sequences disagreeing about what is selected.
    pub(crate) selecting: crate::selection::Selecting,
    /// The find bar's needle, hits and cursor. `pub(crate)` for [`crate::find`] alone, for the
    /// reason `selecting` is: the current hit and the terminal's one selection must move together.
    pub(crate) find: crate::find::FindState,
    frame: Frame,
    /// `pub(crate)` for [`crate::selection`]'s pixel→cell clamp, for the reason `terminal` is.
    pub(crate) cols: u16,
    /// `pub(crate)` for [`crate::selection`]'s pixel→cell clamp, for the reason `terminal` is.
    pub(crate) rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    /// The surface's pixel geometry, as the last `set_surface_geometry` gave it.
    geometry: SurfaceGeometry,
    revision: u64,
    /// Set when something OUTSIDE the engine's own damage tracking invalidated the frame, which
    /// forces a full refill even where the engine reports nothing dirty.
    ///
    /// Two things do that. Geometry: a reshaped frame has rows that were never filled at all. And
    /// colour: `frame.colors` is written past the clean early-out, and every cell's resolved colour
    /// is filled against it, so a theme or palette the engine accepted without touching a cell
    /// would otherwise sit invisible until the next byte arrived.
    refill: bool,
    /// Reused buffers for the cell currently being copied. Held on the session rather than made per
    /// cell so a repaint of a full viewport allocates nothing.
    scratch: CellScratch,
    /// What the far side pushed while the parser ran — pty replies, bells, clipboard writes,
    /// notifications, progress. The session's half of the shared cell described in
    /// [`crate::events`]; the engine's handlers hold the other. Drained through `take_*` below.
    events: EventSink,
}

/// The two buffers one cell's text passes through on its way into a row arena.
#[derive(Debug, Default)]
struct CellScratch {
    /// The cluster's scalars, as the engine hands them over.
    scalars: Vec<char>,
    /// The same cluster as UTF-8, which is what a row arena stores.
    text: String,
}

impl fmt::Debug for VtSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VtSession")
            .field("cols", &self.cols)
            .field("rows", &self.rows)
            .field("revision", &self.revision)
            .finish_non_exhaustive()
    }
}

impl VtSession {
    /// A session over a `cols` × `rows` grid.
    ///
    /// `cell_width_px` and `cell_height_px` are what the terminal reports to programs that ask its
    /// pixel size (XTWINOPS, and the sixel/kitty size negotiation). They are the renderer's cell
    /// metrics, so they arrive here rather than being invented.
    ///
    /// # Errors
    /// [`VtError::EmptyGrid`] for a zero dimension, or the engine's own error if allocation fails.
    pub fn new(cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) -> Result<Self> {
        if cols == 0 || rows == 0 {
            return Err(VtError::EmptyGrid);
        }
        let mut terminal = Terminal::new(cols, rows)?;
        terminal.resize(cols, rows, cell_width_px, cell_height_px)?;
        let events = EventSink::new();
        Self::attach_handlers(&mut terminal, &events)?;
        let mut frame = Frame::new();
        frame.reshape(cols, rows);
        Ok(Self {
            terminal,
            render: RenderState::new()?,
            row_iter: RowIterator::new()?,
            cell_iter: CellIterator::new()?,
            keyboard: Keyboard::new()?,
            pointer: Pointer::new()?,
            selecting: crate::selection::Selecting::new()?,
            find: crate::find::FindState::default(),
            frame,
            cols,
            rows,
            cell_width_px,
            cell_height_px,
            geometry: SurfaceGeometry::default(),
            revision: 0,
            refill: true,
            scratch: CellScratch::default(),
            events,
        })
    }

    /// Points the engine's five push handlers at `events`.
    ///
    /// Registered once, at construction, and never changed — a handler that could be swapped later
    /// would be a second way for the surface to be wired, and `docs/68` §4's promise is that there
    /// is exactly one. Each closure captures a clone of the sink, which is the same sink; the
    /// engine boxes them for its own lifetime, which is why they must own rather than borrow.
    ///
    /// [`Terminal::on_enquiry`] and [`Terminal::on_xtversion`] are deliberately NOT registered:
    /// both are questions the engine answers correctly by itself, and overriding them would mean
    /// this crate inventing a terminal name rather than reporting the one it is.
    ///
    /// Neither are `on_bell`, `on_desktop_notification` or `on_progress_report`, and that is a
    /// decision rather than an omission: the host already sniffs all three out of the PTY stream
    /// and sends each as its own wire message, which is the only owner that survives multiclient
    /// and the only one that does not re-fire on a replay. [`crate::events`] carries the argument.
    ///
    /// # Errors
    /// The engine's own, if it declines a handler.
    fn attach_handlers(terminal: &mut Terminal<'static, 'static>, events: &EventSink) -> Result<()> {
        // The one that is a correctness bug rather than a feature. `CSI 6n`, `CSI c`, `CSI > q`,
        // `OSC 10/11/4 ?` and the in-band size report are all composed by the engine and handed out
        // ONCE, here. Without this the far side asks and never hears back, and a program that waits
        // for the answer — vim probing for truecolour, tmux for the cursor — hangs or guesses
        // wrong.
        let sink = events.clone();
        terminal.on_pty_write(move |_terminal, bytes| sink.push_pty(bytes))?;

        // OSC-52 and iTerm2's OSC 1337 Copy, already base64-decoded and rejoined by the engine.
        // The result is only RECORDED here: whether it reaches a pasteboard is
        // `slopdesk_terminal::surface::clipboard_write`'s decision, made where the user's
        // `clipboard-write` setting lives. A read request (`?`) never arrives — upstream documents
        // that it ignores those, which `docs/DECISIONS.md` records the consequence of.
        let sink = events.clone();
        terminal.on_clipboard_write(move |_terminal, write| {
            let target = match write.location() {
                ClipboardLocation::Standard => ClipboardTarget::Standard,
                ClipboardLocation::Selection => ClipboardTarget::Selection,
                ClipboardLocation::Primary => ClipboardTarget::Primary,
            };
            if let Some(text) = events::preferred_text(write.contents().map(|item| (item.mime, item.data))) {
                sink.push_clipboard(ClipboardWrite { target, text });
            }
            Ok(())
        })?;

        Ok(())
    }

    /// Empties the queue of bytes the TERMINAL owes the pty into `out`, answering whether any were
    /// there.
    ///
    /// The caller's obligation is to poll this after every [`Self::feed`] and write what it finds
    /// to the far side. Not after every keystroke — a keystroke's bytes are [`Self::encode_key`]'s
    /// answer — and not on a timer: a program that asked `CSI 6n` is blocked until the reply lands,
    /// so the latency of this poll is the latency of that program.
    pub fn take_pty_replies(&mut self, out: &mut Vec<u8>) -> bool {
        self.events.take_pty(out)
    }

    /// Empties the queue of clipboard writes running programs asked for, oldest first.
    ///
    /// ⚠️ **Asked for, not applied.** Whether one of these reaches a pasteboard is
    /// `slopdesk_terminal::surface::clipboard_write`'s decision, made where the user's
    /// `clipboard-write` setting lives. Writing straight from this would make "Ask" behave as
    /// "Allow".
    pub fn take_clipboard_writes(&mut self) -> Vec<ClipboardWrite> {
        self.events.take_clipboard()
    }

    /// Whether [`Self::take_clipboard_writes`] would find anything, without draining it.
    #[must_use]
    pub fn has_clipboard_writes(&self) -> bool {
        self.events.has_clipboard()
    }

    /// Feeds host output through the VT parser.
    ///
    /// Never fails: the far side of a PTY is untrusted, so the engine logs a malformed sequence and
    /// keeps its state consistent rather than surfacing an error the caller could not act on.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.terminal.vt_write(bytes);
    }

    /// Resizes the grid, reflowing the primary screen.
    ///
    /// A no-op when nothing changed, which matters because a resize disables synchronised output
    /// and can emit an in-band size report — neither of which should fire on a redundant call.
    ///
    /// # Errors
    /// [`VtError::EmptyGrid`] for a zero dimension, or the engine's own error.
    pub fn resize(&mut self, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) -> Result<()> {
        if cols == 0 || rows == 0 {
            return Err(VtError::EmptyGrid);
        }
        if cols == self.cols
            && rows == self.rows
            && cell_width_px == self.cell_width_px
            && cell_height_px == self.cell_height_px
        {
            return Ok(());
        }
        self.terminal.resize(cols, rows, cell_width_px, cell_height_px)?;
        self.cols = cols;
        self.rows = rows;
        self.cell_width_px = cell_width_px;
        self.cell_height_px = cell_height_px;
        self.frame.reshape(cols, rows);
        self.refill = true;
        Ok(())
    }

    /// Scrolls the viewport.
    pub fn scroll(&mut self, scroll: Scroll) {
        self.terminal.scroll_viewport(scroll.into());
    }

    /// A full reset (RIS), keeping the grid dimensions.
    pub fn reset(&mut self) {
        self.terminal.reset();
        self.refill = true;
        // A reply the OLD terminal owed is an answer about state that no longer exists, and a bell
        // it rang was about output that is gone. Sending either after a reset would be reporting
        // the wrong terminal.
        self.events.clear();
    }

    /// The grid size in cells.
    #[must_use]
    pub const fn size(&self) -> (u16, u16) {
        (self.cols, self.rows)
    }

    /// The last frame the scan produced.
    #[must_use]
    pub const fn frame(&self) -> &Frame {
        &self.frame
    }

    /// Encodes one keystroke into the bytes to send, refreshing the encoder's modes first.
    ///
    /// The refresh is not optional and not an optimisation. An application enters the kitty
    /// keyboard protocol with an escape sequence, so a `feed` can change what the *next* keystroke
    /// must encode to. Reading the modes here — rather than trusting a caller to remember — is why
    /// there is no way to send a keystroke under a stale protocol.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn encode_key(&mut self, press: &KeyPress<'_>, out: &mut Vec<u8>) -> Result<()> {
        self.keyboard.sync(&self.terminal);
        self.keyboard.encode(press, out)
    }

    /// Encodes one pointer event, refreshing the encoder's tracking mode and format first.
    ///
    /// Answers `false`, having written nothing, when the running program asked for no mouse
    /// reporting — which is the caller's signal that the gesture is the *surface's* to handle, as a
    /// selection drag or a scroll.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn encode_mouse(&mut self, event: &MouseMove, out: &mut Vec<u8>) -> Result<bool> {
        if !self.terminal.is_mouse_tracking()? {
            return Ok(false);
        }
        self.pointer.sync(&self.terminal);
        let before = out.len();
        self.pointer.encode(event, out)?;
        Ok(out.len() > before)
    }

    /// Tells the pointer encoder the surface's pixel geometry.
    pub fn set_surface_geometry(&mut self, geometry: SurfaceGeometry) {
        self.geometry = geometry;
        self.pointer.set_geometry(geometry);
    }

    /// The surface geometry the last [`VtSession::set_surface_geometry`] set.
    ///
    /// Held on the session as well as inside the pointer encoder, because [`crate::selection`]
    /// needs the same numbers to convert a pixel into a cell and the encoder does not hand them
    /// back. Storing it once here is what keeps the mouse report and the selection resolving a
    /// click to the SAME cell.
    #[must_use]
    pub const fn surface_geometry(&self) -> SurfaceGeometry {
        self.geometry
    }

    /// How the macOS Option key is treated by the key encoder.
    pub fn set_option_as_alt(&mut self, value: OptionAsAlt) {
        self.keyboard.set_option_as_alt(value);
    }

    /// Forgets any pointer button the encoder was tracking.
    ///
    /// Needed when the surface loses the pointer mid-drag: without it the encoder still believes a
    /// button is down and reports drag motion the user is no longer making.
    pub fn reset_pointer(&mut self) {
        self.pointer.reset();
    }

    /// Whether a full-screen program owns the screen.
    ///
    /// The single most consequential bit in the whole surface: it decides whether blocks are drawn
    /// at all, whether a click is the user's or the program's, and which input box is offered.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn is_alternate_screen(&self) -> Result<bool> {
        Ok(self.terminal.active_screen()? == libghostty_vt::screen::Screen::Alternate)
    }

    /// Whether a program has asked for mouse reporting, and so owns the pointer.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn is_mouse_tracking(&self) -> Result<bool> {
        Ok(self.terminal.is_mouse_tracking()?)
    }

    /// Whether the viewport is pinned to the bottom, where new output lands.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn is_viewport_at_bottom(&self) -> Result<bool> {
        Ok(self.terminal.viewport_active()?)
    }

    /// Whether the foreground program asked for DEC bracketed paste (`?2004h`).
    ///
    /// The live mode, read from the engine that parsed the DECSET — not the client's own tracker,
    /// which watches the same bytes a second time and can only agree or be wrong.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn wants_bracketed_paste(&self) -> Result<bool> {
        Ok(self.terminal.mode(Mode::BRACKETED_PASTE)?)
    }

    /// The exact bytes a paste of `text` should put on the pty.
    ///
    /// ## Why the framing is HERE and not in Swift
    ///
    /// A paste is not "write these bytes". `libghostty_vt::paste::encode` scrubs the control bytes
    /// a payload must never carry into a prompt (NUL, ESC, DEL), turns newlines into carriage
    /// returns when the paste is *not* bracketed, and — the part that matters — strips any
    /// embedded `ESC [ 201 ~` before wrapping, which is the classic bracketed-paste breakout: a
    /// clipboard that smuggled an end marker would otherwise close the block early and inject
    /// its tail as live input. Every one of those is a rule about how the far side's parser
    /// behaves, so it belongs to the engine that owns that parser.
    ///
    /// `bracketed` is the CALLER's, not this function's, because three menu items disagree about it
    /// on purpose: ordinary Paste asks [`Self::wants_bracketed_paste`], "Bracketed Paste" forces
    /// it, and "Paste as Keystrokes" suppresses it so the payload arrives as if typed.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn encode_paste(&self, text: &str, bracketed: bool) -> Result<Vec<u8>> {
        // `encode` rewrites its input in place, so the payload is copied first — the caller's
        // `&str` is borrowed and must survive the call unchanged.
        let mut payload = text.as_bytes().to_vec();
        // The brackets add ten bytes and the scrub never grows the payload, so this is the answer
        // on the first attempt for every real paste; the `OutOfSpace` arm below is the
        // contract, not a path anything is expected to take.
        let mut out = vec![0_u8; payload.len() + PASTE_FRAMING_HEADROOM];
        match libghostty_vt::paste::encode(&mut payload, bracketed, &mut out) {
            Ok(written) => {
                out.truncate(written);
                Ok(out)
            },
            Err(EngineError::OutOfSpace { required }) => {
                let mut payload = text.as_bytes().to_vec();
                let mut out = vec![0_u8; required];
                let written = libghostty_vt::paste::encode(&mut payload, bracketed, &mut out)?;
                out.truncate(written);
                Ok(out)
            },
            Err(error) => Err(error.into()),
        }
    }

    /// The window title the far side last set, or `""`.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn title(&self) -> Result<&str> {
        Ok(self.terminal.title()?)
    }

    /// The working directory OSC 7 last reported, or `""`.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn pwd(&self) -> Result<&str> {
        Ok(self.terminal.pwd()?)
    }

    /// How many rows of scrollback are behind the viewport.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn scrollback_rows(&self) -> Result<usize> {
        Ok(self.terminal.scrollback_rows()?)
    }

    /// Caps the scrollback, in rows. `None` restores the engine's default.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn set_scrollback_rows(&mut self, rows: Option<usize>) -> Result<()> {
        self.terminal.set_scrollback_max_lines(rows)?;
        Ok(())
    }

    /// Sets the default colours a cell falls back to.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn set_default_colors(&mut self, foreground: Rgb, background: Rgb) -> Result<()> {
        self.terminal.set_default_fg_color(Some(rgb_out(foreground)))?;
        self.terminal.set_default_bg_color(Some(rgb_out(background)))?;
        self.refill = true;
        Ok(())
    }

    /// Overrides the palette from index `0`, leaving every slot past `palette` at the engine's own
    /// default.
    ///
    /// A PREFIX rather than all 256 entries because that is the shape the only caller has: a theme
    /// states the 16 ANSI colours and says nothing about the 6×6×6 cube or the greyscale ramp, and
    /// a door that demanded 256 would make the caller invent 240 of them. Entries past 255 are
    /// ignored, so a longer slice is a caller's arithmetic error rather than a panic.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn set_palette(&mut self, palette: &[Rgb]) -> Result<()> {
        let mut out = libghostty_vt::style::Palette::default();
        for (index, colour) in palette.iter().enumerate() {
            let Ok(index) = u8::try_from(index) else {
                continue;
            };
            out.set(libghostty_vt::style::PaletteIndex(index), rgb_out(*colour));
        }
        self.terminal.set_default_color_palette(Some(out))?;
        self.refill = true;
        Ok(())
    }

    /// Scans the engine into [`VtSession::frame`], and answers how much changed.
    ///
    /// Only rows the engine reports dirty are refilled; a clean row keeps the cells and the text
    /// arena it already had. A caller that skips the draw must NOT call
    /// [`Frame::clear_damage`](crate::frame::Frame) — the damage is sticky in the frame precisely
    /// so that a dropped frame does not lose it.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn render(&mut self) -> Result<FrameDirty> {
        let Self {
            terminal,
            render,
            row_iter,
            cell_iter,
            frame,
            refill,
            revision,
            scratch,
            ..
        } = self;

        // Phase one is the only phase that reads the terminal; phase two touches render-state
        // memory only. Splitting them is what would let a future caller hold a lock across the
        // first and not the second.
        let snapshot = render.begin_update(terminal)?.end()?;

        let reported = FrameDirty::from(snapshot.dirty()?);
        let force = *refill || reported == FrameDirty::Full;
        if !force && reported == FrameDirty::Clean {
            return Ok(FrameDirty::Clean);
        }
        // A refill covers every row whatever the engine reported, so the answer must not be
        // `Clean`: a caller that keys its draw off the return value would skip the one repaint that
        // has to happen — the frame it is holding has rows that were never filled, or were filled
        // against colours that are no longer the ones in force.
        let dirty = if force { FrameDirty::Full } else { reported };

        let colors = snapshot.colors()?;
        frame.colors = FrameColors {
            background: colors.background.into(),
            foreground: colors.foreground.into(),
            palette: colors.palette.map(Into::into),
        };
        frame.cursor = if snapshot.cursor_visible()? {
            snapshot.cursor_viewport()?.map(|viewport| {
                FrameCursor {
                    x: viewport.x,
                    y: viewport.y,
                    shape: snapshot
                        .cursor_visual_style()
                        .map_or_else(|_| crate::frame::CursorShape::Block, Into::into),
                    color: snapshot
                        .cursor_color()
                        .ok()
                        .flatten()
                        .map_or(frame.colors.foreground, Into::into),
                    blinking: snapshot.cursor_blinking().unwrap_or(false),
                    at_wide_tail: viewport.at_wide_tail,
                    password_input: snapshot.cursor_password_input().unwrap_or(false),
                }
            })
        } else {
            None
        };

        let cols = snapshot.cols()?;
        let row_count = snapshot.rows()?;
        if cols != frame.cols || usize::from(row_count) != frame.rows.len() {
            frame.reshape(cols, row_count);
        }

        let mut rows = row_iter.update(&snapshot)?;
        let mut y = 0_usize;
        while let Some(row) = rows.next() {
            let Some(target) = frame.rows.get_mut(y) else {
                break;
            };
            y += 1;

            let selection = row.selection()?.map(|span| {
                ColumnSpan {
                    start: span.start_x,
                    end: span.end_x.saturating_add(1),
                }
            });
            let row_dirty = row.dirty()?;
            if !row_dirty && !force && selection == target.selection {
                continue;
            }

            target.dirty = true;
            target.begin_fill();
            target.selection = selection;
            let raw = row.raw_row()?;
            target.semantic = raw.semantic_prompt()?.into();
            target.wrapped = raw.is_wrapped()?;

            let mut cells = cell_iter.update(row)?;
            let mut x = 0_u16;
            while let Some(cell) = cells.next() {
                fill_cell(cell, target, &frame.colors, selection, x, scratch)?;
                x = x.saturating_add(1);
            }
            // The engine's per-row flag is cleared here rather than after the draw: the damage now
            // lives in `FrameRow::dirty`, which the renderer clears when it has actually drawn.
            row.set_dirty(false)?;
        }

        *refill = false;
        *revision = revision.wrapping_add(1);
        frame.revision = *revision;
        frame.dirty = dirty;
        snapshot.set_dirty(Dirty::Clean)?;
        Ok(dirty)
    }
}

/// Copies one cell out of the engine and into the row being filled.
fn fill_cell(
    cell: &libghostty_vt::render::CellIteration<'_, '_>,
    target: &mut crate::frame::FrameRow,
    colors: &FrameColors,
    selection: Option<ColumnSpan>,
    x: u16,
    scratch: &mut CellScratch,
) -> Result<()> {
    let raw = cell.raw_cell()?;
    let style = if raw.has_styling()? {
        cell.style()?
    } else {
        Style::default()
    };

    let mut flags = CellFlags::NONE
        .set(CellFlags::BOLD, style.bold)
        .set(CellFlags::ITALIC, style.italic)
        .set(CellFlags::FAINT, style.faint)
        .set(CellFlags::BLINK, style.blink)
        .set(CellFlags::STRIKETHROUGH, style.strikethrough)
        .set(CellFlags::OVERLINE, style.overline);
    flags = match raw.wide()? {
        CellWide::Narrow => flags,
        CellWide::Wide => flags.union(CellFlags::WIDE),
        CellWide::SpacerTail => flags.union(CellFlags::WIDE_TAIL),
        CellWide::SpacerHead => flags.union(CellFlags::WIDE_HEAD),
    };
    if selection.is_some_and(|span| span.contains(x)) {
        flags = flags.union(CellFlags::SELECTED);
    }

    let mut fg = resolve(style.fg_color, style.bold, colors).unwrap_or(colors.foreground);
    // A cell-level background beats the style's: the engine stores one directly on the cell for
    // the common `\x1b[4Xm` run, and `content_tag` is how it says which source is live.
    let mut bg = match raw.content_tag()? {
        CellContentTag::BgColorRgb => raw.bg_color_rgb()?.into(),
        CellContentTag::BgColorPalette => palette_at(colors, usize::from(raw.bg_color_palette()?.0)),
        CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
            resolve(style.bg_color, false, colors).unwrap_or(colors.background)
        },
    };
    if style.inverse {
        core::mem::swap(&mut fg, &mut bg);
    }
    if style.faint {
        fg = dim(fg, bg);
    }

    // Invisible (SGR 8) blanks the cell by writing no text at all rather than by setting a flag a
    // renderer could forget to read. The failure mode of a missed flag is a leaked password.
    //
    // The codepoint door rather than the crate's `graphemes_utf8`: that one writes its cluster at
    // the START of the string it is handed, so appending cell after cell into one row arena would
    // leave only the last cell's text. Reading scalars into a reused scratch costs one extra copy
    // of at most a handful of `char`s and cannot lose a cell.
    scratch.text.clear();
    if raw.has_text()? && !style.invisible && !flags.hides_glyph() {
        let len = cell.graphemes_len()?;
        scratch.scalars.clear();
        scratch.scalars.resize(len, '\0');
        cell.graphemes_buf(&mut scratch.scalars)?;
        scratch.text.extend(scratch.scalars.iter());
    }

    target.push_cell(&scratch.text, FrameCell {
        text: TextSpan::default(),
        fg,
        bg,
        underline_color: resolve(style.underline_color, false, colors).unwrap_or(fg),
        flags,
        underline: UnderlineStyle::from(style.underline),
    });
    Ok(())
}

/// Turns a style colour into a literal one, applying the bold-brightening rule on the way.
///
/// SGR 1 over one of the first eight palette entries selects the bright counterpart — that is the
/// convention every terminal follows and the reason the scan reads the raw style rather than the
/// engine's pre-resolved colour, which has already spent the index.
fn resolve(color: StyleColor, bold: bool, colors: &FrameColors) -> Option<Rgb> {
    match color {
        StyleColor::None => None,
        StyleColor::Rgb(rgb) => Some(rgb.into()),
        StyleColor::Palette(index) => {
            let index = usize::from(index.0);
            let index = if bold && index < 8 { index + 8 } else { index };
            Some(palette_at(colors, index))
        },
    }
}

/// One palette entry, falling back to the default foreground for an index the palette cannot hold.
fn palette_at(colors: &FrameColors, index: usize) -> Rgb {
    colors.palette.get(index).copied().unwrap_or(colors.foreground)
}

/// SGR 2, as a blend halfway to the background.
///
/// Halfway rather than a fixed multiply towards black: dimming towards black turns faint text on a
/// light theme *darker*, which is the opposite of faint. Blending towards the actual background is
/// correct on both polarities.
///
/// The arithmetic is integer on purpose. `CLAUDE.md` forbids a fused multiply-add, and there is no
/// float here to fuse.
const fn dim(fg: Rgb, bg: Rgb) -> Rgb {
    Rgb {
        r: u8::midpoint(fg.r, bg.r),
        g: u8::midpoint(fg.g, bg.g),
        b: u8::midpoint(fg.b, bg.b),
    }
}

/// A frame colour on its way back into the engine.
const fn rgb_out(color: Rgb) -> libghostty_vt::style::RgbColor {
    libghostty_vt::style::RgbColor {
        r: color.r,
        g: color.g,
        b: color.b,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Rgb, Scroll, VtError, VtSession, dim};
    use crate::frame::{CellFlags, FrameDirty, RowSemantic, UnderlineStyle};

    fn session() -> VtSession {
        VtSession::new(20, 5, 8, 16).unwrap()
    }

    /// The rendered text of one row, blanks and all.
    fn row_text(session: &VtSession, y: u16) -> String {
        session.frame().row_text(y)
    }

    #[test]
    fn a_zero_dimension_is_refused_by_name() {
        assert_eq!(VtSession::new(0, 24, 8, 16).unwrap_err(), VtError::EmptyGrid);
        assert_eq!(VtSession::new(80, 0, 8, 16).unwrap_err(), VtError::EmptyGrid);
    }

    #[test]
    fn plain_text_lands_in_the_frame() {
        let mut session = session();
        session.feed(b"hello");
        assert_eq!(session.render().unwrap(), FrameDirty::Full);
        assert_eq!(row_text(&session, 0), "hello");
        assert_eq!(session.frame().cols, 20);
        assert_eq!(session.frame().rows.len(), 5);
    }

    #[test]
    fn a_second_render_with_no_input_is_clean() {
        let mut session = session();
        session.feed(b"hi");
        session.render().unwrap();
        assert_eq!(
            session.render().unwrap(),
            FrameDirty::Clean,
            "nothing changed, so the renderer has nothing to do"
        );
    }

    #[test]
    fn the_cursor_follows_the_text() {
        let mut session = session();
        session.feed(b"abc");
        session.render().unwrap();
        let cursor = session.frame().cursor.unwrap();
        assert_eq!((cursor.x, cursor.y), (3, 0));
    }

    #[test]
    fn sgr_attributes_reach_the_cell() {
        let mut session = session();
        session.feed(b"\x1b[1;3;4mx");
        session.render().unwrap();
        let cell = session.frame().cell(0, 0).unwrap();
        assert!(cell.flags.contains(CellFlags::BOLD));
        assert!(cell.flags.contains(CellFlags::ITALIC));
        assert_eq!(cell.underline, UnderlineStyle::Single);
    }

    #[test]
    fn a_bold_palette_colour_brightens_to_its_counterpart() {
        let mut session = session();
        // SGR 31 is palette 1 (red); with SGR 1 it must resolve to palette 9 (bright red).
        session.feed(b"\x1b[1;31mx");
        session.render().unwrap();
        let cell = session.frame().cell(0, 0).unwrap();
        assert_eq!(cell.fg, session.frame().colors.palette[9]);
        assert_ne!(
            cell.fg,
            session.frame().colors.palette[1],
            "bold over the first eight is the bright counterpart, not the base"
        );
    }

    #[test]
    fn a_plain_palette_colour_is_not_brightened() {
        let mut session = session();
        session.feed(b"\x1b[31mx");
        session.render().unwrap();
        assert_eq!(
            session.frame().cell(0, 0).unwrap().fg,
            session.frame().colors.palette[1]
        );
    }

    #[test]
    fn inverse_swaps_the_two_colours() {
        let mut session = session();
        session.feed(b"\x1b[7mx");
        session.render().unwrap();
        let cell = session.frame().cell(0, 0).unwrap();
        let colors = session.frame().colors;
        assert_eq!(cell.fg, colors.background);
        assert_eq!(cell.bg, colors.foreground);
    }

    #[test]
    fn an_invisible_cell_carries_no_text_at_all() {
        let mut session = session();
        session.feed(b"\x1b[8msecret");
        session.render().unwrap();
        assert_eq!(
            row_text(&session, 0),
            "",
            "the glyph is gone from the data, not merely from the draw"
        );
    }

    #[test]
    fn a_wide_character_marks_its_pair() {
        let mut session = session();
        session.feed("漢".as_bytes());
        session.render().unwrap();
        let lead = session.frame().cell(0, 0).unwrap();
        let tail = session.frame().cell(1, 0).unwrap();
        assert!(lead.flags.contains(CellFlags::WIDE));
        assert!(tail.flags.contains(CellFlags::WIDE_TAIL));
        assert_eq!(row_text(&session, 0), "漢", "the tail draws nothing");
    }

    #[test]
    fn a_combining_mark_stays_in_its_cell() {
        let mut session = session();
        // "e" then U+0301 COMBINING ACUTE ACCENT: one cell, two scalars.
        session.feed("e\u{0301}".as_bytes());
        session.render().unwrap();
        let row = session.frame().row(0).unwrap();
        assert_eq!(row.cell_text(row.cells[0]), "e\u{0301}");
    }

    #[test]
    fn an_osc_133_prompt_marks_its_row() {
        let mut session = session();
        session.feed(b"\x1b]133;A\x07$ ");
        session.render().unwrap();
        assert_eq!(session.frame().row(0).unwrap().semantic, RowSemantic::Prompt);
    }

    #[test]
    fn the_alternate_screen_is_visible_to_the_caller() {
        let mut session = session();
        assert!(!session.is_alternate_screen().unwrap());
        session.feed(b"\x1b[?1049h");
        assert!(session.is_alternate_screen().unwrap());
        session.feed(b"\x1b[?1049l");
        assert!(!session.is_alternate_screen().unwrap());
    }

    #[test]
    fn a_title_sequence_is_read_back() {
        let mut session = session();
        session.feed(b"\x1b]0;slopdesk\x07");
        assert_eq!(session.title().unwrap(), "slopdesk");
    }

    /// The handler registration, exercised end to end rather than reviewed. A device status report
    /// is the cheapest proof that a reply the ENGINE composes reaches the caller at all: `CSI 6n`
    /// after moving the cursor must come back as `CSI row ; col R` with the position the grid
    /// actually holds. Everything else the far side can ask — device attributes, XTVERSION, a
    /// colour query — travels the same one handler, so this failing means every one of them is
    /// being dropped.
    #[test]
    fn a_cursor_position_query_is_answered_through_the_pty_queue() {
        let mut session = session();
        session.feed(b"\x1b[3;7H\x1b[6n");
        let mut replies = Vec::new();
        assert!(
            session.take_pty_replies(&mut replies),
            "the query went unanswered"
        );
        assert_eq!(replies, b"\x1b[3;7R");
        replies.clear();
        assert!(
            !session.take_pty_replies(&mut replies),
            "a reply must leave exactly once"
        );
    }

    /// The other push the wire cannot carry, through the sequence a real program would send.
    ///
    /// A bell, a notification and a progress report deliberately do NOT arrive — the host owns
    /// those (see [`crate::events`]) — so feeding all four and finding only the clipboard write is
    /// the assertion, not an incomplete one.
    #[test]
    fn a_clipboard_write_arrives_and_the_hosts_three_do_not() {
        let mut session = session();
        assert!(!session.has_clipboard_writes());
        // BEL; OSC 52 to the standard clipboard with base64 "hello"; OSC 777 notify; OSC 9;4 at 60
        // %.
        session.feed(b"\x07");
        session.feed(b"\x1b]52;c;aGVsbG8=\x07");
        session.feed(b"\x1b]777;notify;Build;done\x07");
        session.feed(b"\x1b]9;4;1;60\x07");
        assert!(session.has_clipboard_writes());

        let drained = session.take_clipboard_writes();
        assert_eq!(drained.len(), 1);
        assert_eq!(drained.first().map(|w| w.text.as_str()), Some("hello"));
        assert_eq!(
            drained.first().map(|w| w.target),
            Some(crate::events::ClipboardTarget::Standard)
        );
        assert!(
            session.take_clipboard_writes().is_empty(),
            "a drain empties the sink"
        );
    }

    /// The three things a paste encoding must do, in one payload that trips all three: the framing
    /// appears only when asked, an embedded END marker is stripped before wrapping (the breakout),
    /// and an unbracketed paste arrives with its newline turned into a carriage return.
    #[test]
    fn a_paste_is_framed_scrubbed_and_never_breaks_out_of_its_own_brackets() {
        let session = session();

        let bracketed = session.encode_paste("a\nb", true).unwrap();
        assert_eq!(bracketed, b"\x1b[200~a\nb\x1b[201~");

        let bare = session.encode_paste("a\nb", false).unwrap();
        assert_eq!(bare, b"a\rb");

        // The breakout: a payload carrying its own end marker must not close the block early.
        let smuggled = session.encode_paste("evil\x1b[201~rm -rf /", true).unwrap();
        let text = String::from_utf8(smuggled).unwrap();
        assert_eq!(
            text.matches("\x1b[201~").count(),
            1,
            "the only end marker left is the one this encoding wrote: {text:?}"
        );
        assert!(text.ends_with("\x1b[201~"), "{text:?}");
    }

    /// Bracketed paste is the PROGRAM's mode, read from the engine that parsed the DECSET.
    #[test]
    fn the_bracketed_paste_mode_is_the_one_the_program_set() {
        let mut session = session();
        assert!(!session.wants_bracketed_paste().unwrap());
        session.feed(b"\x1b[?2004h");
        assert!(session.wants_bracketed_paste().unwrap());
        session.feed(b"\x1b[?2004l");
        assert!(!session.wants_bracketed_paste().unwrap());
    }

    /// A reset re-makes the terminal, so a reply the old one owed must not reach the new one's pty.
    #[test]
    fn a_reset_drops_the_reply_the_old_terminal_owed() {
        let mut session = session();
        session.feed(b"\x1b[6n\x07");
        session.reset();
        let mut replies = Vec::new();
        assert!(!session.take_pty_replies(&mut replies));
        assert!(!session.has_clipboard_writes());
    }

    #[test]
    fn a_redundant_resize_is_a_no_op_and_a_real_one_reshapes() {
        let mut session = session();
        session.resize(20, 5, 8, 16).unwrap();
        assert_eq!(session.size(), (20, 5));
        session.resize(40, 10, 8, 16).unwrap();
        assert_eq!(session.size(), (40, 10));
        session.render().unwrap();
        assert_eq!(session.frame().cols, 40);
        assert_eq!(session.frame().rows.len(), 10);
        assert_eq!(session.resize(0, 10, 8, 16).unwrap_err(), VtError::EmptyGrid);
    }

    #[test]
    fn scrollback_accumulates_and_the_viewport_can_leave_the_bottom() {
        let mut session = session();
        for _ in 0..20 {
            session.feed(b"line\r\n");
        }
        assert!(session.scrollback_rows().unwrap() > 0);
        assert!(session.is_viewport_at_bottom().unwrap());
        session.scroll(Scroll::Top);
        assert!(!session.is_viewport_at_bottom().unwrap());
        session.scroll(Scroll::Bottom);
        assert!(session.is_viewport_at_bottom().unwrap());
    }

    #[test]
    fn only_the_row_that_changed_is_refilled() {
        let mut session = session();
        session.feed(b"one\r\ntwo\r\n");
        session.render().unwrap();
        for row in &mut session.frame.rows {
            row.dirty = false;
        }

        session.feed(b"three");
        session.render().unwrap();
        assert!(session.frame().row(2).unwrap().dirty, "the row that changed");
        assert!(
            !session.frame().row(0).unwrap().dirty,
            "an untouched row is not rebuilt"
        );
        assert_eq!(row_text(&session, 0), "one", "and it still reads correctly");
    }

    #[test]
    fn a_reset_clears_the_screen() {
        let mut session = session();
        session.feed(b"gone");
        session.render().unwrap();
        session.reset();
        session.render().unwrap();
        assert_eq!(row_text(&session, 0), "");
    }

    #[test]
    fn default_colours_and_the_palette_round_trip() {
        let mut session = session();
        let fg = Rgb::new(0x11, 0x22, 0x33);
        let bg = Rgb::new(0x44, 0x55, 0x66);
        session.set_default_colors(fg, bg).unwrap();
        let mut palette = [Rgb::BLACK; 256];
        palette[3] = Rgb::new(0x77, 0x88, 0x99);
        session.set_palette(&palette).unwrap();
        session.feed(b"x");
        session.render().unwrap();
        assert_eq!(session.frame().colors.foreground, fg);
        assert_eq!(session.frame().colors.background, bg);
        assert_eq!(session.frame().colors.palette[3], palette[3]);
    }

    #[test]
    fn a_short_palette_overrides_a_prefix_and_leaves_the_rest_at_the_default() {
        let mut session = session();
        let defaults = {
            session.render().unwrap();
            session.frame().colors.palette
        };
        let ansi = [Rgb::new(0xAA, 0xBB, 0xCC); 16];
        session.set_palette(&ansi).unwrap();
        session.feed(b"x");
        session.render().unwrap();
        assert_eq!(session.frame().colors.palette[0], ansi[0]);
        assert_eq!(session.frame().colors.palette[15], ansi[15]);
        // Index 16 is the first slot the theme said nothing about; it must still be the engine's.
        assert_eq!(session.frame().colors.palette[16], defaults[16]);
        assert_eq!(session.frame().colors.palette[255], defaults[255]);
    }

    #[test]
    fn a_colour_change_alone_forces_a_repaint() {
        // The engine's damage tracking counts CELLS, and a theme change touches none — so without
        // the refill flag this is the frame that would keep last theme's colours until the user
        // happened to type. Both existing colour tests feed a byte first, which hides exactly that.
        let mut session = session();
        session.feed(b"x");
        session.render().unwrap();
        assert_eq!(session.render().unwrap(), FrameDirty::Clean, "quiescent first");

        session
            .set_default_colors(Rgb::new(0x11, 0x22, 0x33), Rgb::new(0x44, 0x55, 0x66))
            .unwrap();
        assert_eq!(session.render().unwrap(), FrameDirty::Full);
        assert_eq!(session.frame().colors.foreground, Rgb::new(0x11, 0x22, 0x33));
        assert!(
            session.frame().row(0).unwrap().dirty,
            "the row repaints against them"
        );

        session.render().unwrap();
        session.set_palette(&[Rgb::new(0xAA, 0xBB, 0xCC); 16]).unwrap();
        assert_eq!(session.render().unwrap(), FrameDirty::Full);
        assert_eq!(session.frame().colors.palette[0], Rgb::new(0xAA, 0xBB, 0xCC));
    }

    #[test]
    fn faint_blends_towards_the_background_on_both_polarities() {
        assert_eq!(
            dim(Rgb::WHITE, Rgb::BLACK),
            Rgb::new(127, 127, 127),
            "on a dark theme faint is darker"
        );
        assert_eq!(
            dim(Rgb::BLACK, Rgb::WHITE),
            Rgb::new(127, 127, 127),
            "on a light theme faint is lighter, not darker"
        );
    }

    #[test]
    fn the_revision_advances_only_when_something_changed() {
        let mut session = session();
        session.feed(b"a");
        session.render().unwrap();
        let first = session.frame().revision;
        session.render().unwrap();
        assert_eq!(session.frame().revision, first, "a clean scan is not a new frame");
        session.feed(b"b");
        session.render().unwrap();
        assert!(session.frame().revision > first);
    }
}
