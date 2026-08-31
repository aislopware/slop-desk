//! Selecting text with a pointer, and reading back what was selected.
//!
//! ## Why this is a state machine and not four functions
//!
//! A selection is not "the rectangle between where the button went down and where it is now". Its
//! granularity depends on how many times the button was clicked and how fast; a double-click drag
//! extends by WORDS, and once it does, dragging back inside the first word must not shrink the
//! selection below that word. A drag past the top edge scrolls, and keeps scrolling while the
//! pointer is held still. Reversing direction past the anchor flips which end moves. Every one of
//! those is a rule about the gesture's own history, so the history has to live somewhere.
//!
//! `libghostty-vt` ships that state machine — `selection::gesture` — and this module is the door on
//! it. The alternative was re-deriving click sequencing and drag granularity in
//! `slopdesk-termrender` from a stream of pointer events, which is a second implementation of a
//! thing the engine already gets right, in the one area where "roughly right" is most visible.
//!
//! ## Pixels in, cells out, and where the conversion happens
//!
//! Every door here takes SURFACE PIXELS, because that is what a view has. The pixel→cell conversion
//! is here rather than at the caller for the same reason [`crate::input`]'s mouse encoding is: the
//! session already holds the geometry (it must, to encode a mouse report), and a second copy of
//! `(x - padding_left) / cell_width` is a second place for a padding change to be forgotten. The
//! gesture wants BOTH — a grid reference for what was hit and the raw pixels for the repeat-click
//! distance — so a caller that converted first would have to hand over both anyway.
//!
//! ## The selection is installed, not returned
//!
//! Every gesture door ends by handing the snapshot to the terminal with `set_selection`, which is
//! what makes the next [`VtSession::render`](crate::VtSession::render) fill
//! [`FrameRow::selection`](crate::FrameRow). Nothing crosses back out as geometry. That is the
//! whole point of the arrangement: the renderer paints a selection by reading the frame it already
//! reads, so a selection cannot be drawn in a place the engine disagrees with.

use core::time::Duration;

use libghostty_vt::selection::gesture::{
    AutoscrollTickEvent, Behavior, Behaviors, DragEvent, Gesture, PressEvent, ReleaseEvent,
};
use libghostty_vt::selection::{FormatOptions, SelectLineOptions, SelectWordOptions};
use libghostty_vt::terminal::{Point, PointCoordinate};

use crate::input::SurfaceGeometry;
use crate::session::{Result, VtError, VtSession};

/// How much of the grid one press selects, and what a drag after it extends by.
///
/// Mirrors the engine's own `Behavior` rather than inventing a vocabulary, because the names ARE
/// the behaviour — a caller that could say `Word` but meant "the word plus its trailing space"
/// would be describing a different terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Granularity {
    /// One cell, extended cell by cell. The single-click default.
    #[default]
    Cell,
    /// The word under the pointer, extended word by word. The double-click default.
    Word,
    /// The whole line, extended line by line. The triple-click default.
    Line,
    /// The OUTPUT of the command under the pointer, bounded by the semantic prompt marks —
    /// the block, in other words. Nothing binds it to a click count by default; it is the
    /// selection a block's own "copy output" affordance asks for.
    Output,
}

impl From<Granularity> for Behavior {
    fn from(value: Granularity) -> Self {
        match value {
            Granularity::Cell => Self::Cell,
            Granularity::Word => Self::Word,
            Granularity::Line => Self::Line,
            Granularity::Output => Self::Output,
        }
    }
}

/// What each click count in a sequence selects.
///
/// A struct rather than three arguments because the three are one decision: single/double/triple is
/// a LADDER, and a caller setting the double-click behaviour without thinking about the triple has
/// almost certainly made a mistake. [`Default`] is the ladder every terminal ships — cell, word,
/// line — and is what a caller that has no opinion should pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClickLadder {
    /// What one click selects.
    pub single: Granularity,
    /// What two clicks select.
    pub double: Granularity,
    /// What three clicks select.
    pub triple: Granularity,
}

impl Default for ClickLadder {
    fn default() -> Self {
        Self {
            single: Granularity::Cell,
            double: Granularity::Word,
            triple: Granularity::Line,
        }
    }
}

impl From<ClickLadder> for Behaviors {
    fn from(value: ClickLadder) -> Self {
        Self::new()
            .with_single_click_behavior(value.single.into())
            .with_double_click_behavior(value.double.into())
            .with_triple_click_behavior(value.triple.into())
    }
}

/// Whether a held drag is asking the viewport to move, and which way.
///
/// The caller drives this: the engine reports the REQUEST, and something on the caller's side has
/// to tick — an autoscroll that scrolled itself would need a clock the engine does not have.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Autoscroll {
    /// The pointer is inside the grid; nothing to do.
    #[default]
    None,
    /// The pointer is above the grid — scroll towards the scrollback.
    Up,
    /// The pointer is below the grid — scroll towards the newest output.
    Down,
}

impl From<libghostty_vt::selection::gesture::Autoscroll> for Autoscroll {
    fn from(value: libghostty_vt::selection::gesture::Autoscroll) -> Self {
        match value {
            libghostty_vt::selection::gesture::Autoscroll::Up => Self::Up,
            libghostty_vt::selection::gesture::Autoscroll::Down => Self::Down,
            // `None` shares this arm with the wildcard, and the wildcard is required rather than
            // defensive: the engine's enum is `#[non_exhaustive]`. A direction a newer engine grows
            // is answered as "do not scroll" rather than guessed at — scrolling the wrong way is
            // worse than not scrolling, and the drag still tracks the pointer either way.
            _ => Self::None,
        }
    }
}

/// How the selected text is spelled when it is read back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CopyFormat {
    /// Characters only. What ⌘C means.
    #[default]
    Plain,
    /// Characters plus the SGR sequences that coloured them, so a paste into another terminal
    /// arrives styled.
    Vt,
    /// HTML with inline styles, for a paste into something that reads rich text.
    Html,
}

impl From<CopyFormat> for libghostty_vt::fmt::Format {
    fn from(value: CopyFormat) -> Self {
        match value {
            CopyFormat::Plain => Self::Plain,
            CopyFormat::Vt => Self::Vt,
            CopyFormat::Html => Self::Html,
        }
    }
}

/// A point on the surface, in the same pixels the pointer encoder is given.
///
/// `f64` and not a cell pair, because sub-cell position is not noise here: the repeat-click
/// distance that decides whether a second click continues a sequence or starts a new one is
/// measured in pixels, and a pre-rounded point would make a click at the far edge of a wide cell
/// look like a click at its near edge.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct SurfacePoint {
    /// Distance from the surface's left edge, in pixels.
    pub x: f64,
    /// Distance from the surface's top edge, in pixels.
    pub y: f64,
}

/// The gesture machine and the four reusable events it is driven by.
///
/// All five are allocated once and reused for the same reason [`crate::input::Pointer`] reuses its
/// event: a drag fires on every pointer motion, and allocating an engine object per motion would
/// put a malloc on the one path `docs/68` §6 measures.
pub(crate) struct Selecting {
    gesture: Gesture<'static>,
    press: PressEvent<'static>,
    drag: DragEvent<'static>,
    release: ReleaseEvent<'static>,
    autoscroll: AutoscrollTickEvent<'static>,
}

impl core::fmt::Debug for Selecting {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("Selecting { .. }")
    }
}

impl Selecting {
    /// The five engine objects, allocated once.
    ///
    /// # Errors
    /// The engine's own error, if any allocation fails.
    pub(crate) fn new() -> Result<Self> {
        Ok(Self {
            gesture: Gesture::new()?,
            press: PressEvent::new()?,
            drag: DragEvent::new()?,
            release: ReleaseEvent::new()?,
            autoscroll: AutoscrollTickEvent::new()?,
        })
    }
}

/// The rendered geometry the gesture resolves a drag against.
///
/// Built from the geometry the session already holds. `columns` and the two non-zero fields are
/// forced above zero because the engine documents them as "must be non-zero" and a surface that is
/// mid-layout can legitimately be zero-sized for one frame — refusing there would turn a transient
/// layout state into an error the caller has to handle.
fn geometry_of(geometry: SurfaceGeometry, cols: u16) -> libghostty_vt::selection::gesture::Geometry {
    libghostty_vt::selection::gesture::Geometry {
        columns: u32::from(cols.max(1)),
        cell_width: geometry.cell_width.max(1),
        padding_left: geometry.padding_left,
        screen_height: geometry.height.max(1),
    }
}

/// Which cell a surface pixel falls in, clamped into the grid.
///
/// Clamped rather than refused: a drag that leaves the surface is the commonest way to select to
/// the end of a line, and answering `None` there would make the caller re-derive the very clamp
/// this avoids. The edge cases are the reason this is one function — a point left of the padding is
/// column zero, not a negative column that wraps when it becomes a `u32`.
fn cell_at(point: SurfacePoint, geometry: SurfaceGeometry, cols: u16, rows: u16) -> PointCoordinate {
    let column = axis(
        point.x,
        f64::from(geometry.padding_left),
        f64::from(geometry.cell_width),
        cols,
    );
    PointCoordinate {
        // The engine's column is a `u16` and its row a `u32`. `axis` has already fenced the value
        // into `[0, cols-1]`, so the narrowing cannot lose anything — and the fallback is that same
        // bound rather than zero, because a value that somehow escaped the fence escaped it upwards.
        x: u16::try_from(column).unwrap_or_else(|_| cols.saturating_sub(1)),
        y: axis(
            point.y,
            f64::from(geometry.padding_top),
            f64::from(geometry.cell_height),
            rows,
        ),
    }
}

/// One axis of [`cell_at`]: pixels to a clamped cell index.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the two f64::max/min below fence the value into [0, count-1] before the cast"
)]
fn axis(value: f64, padding: f64, cell: f64, count: u16) -> u32 {
    // NaN is answered first, because `f64::min` implements IEEE `minNum` and does NOT propagate it
    // — a NaN coordinate would otherwise fall out as the LAST cell rather than the first. The
    // same trap `slopdesk_termrender::glyph::GlyphKey::phase` names.
    if value.is_nan() || cell <= 0.0 {
        return 0;
    }
    let last = f64::from(count.saturating_sub(1));
    let index = (value - padding) / cell;
    let floored = index.floor();
    f64::min(f64::max(floored, 0.0), last) as u32
}

impl VtSession {
    /// Starts a selection gesture at `point`.
    ///
    /// `time` is a MONOTONIC instant, not a wall clock, and it is what turns two presses into a
    /// double-click. Passing the same value twice makes every press a single click, which is the
    /// honest degradation for a caller that has no clock — the engine documents an unset time as
    /// exactly that.
    ///
    /// `repeat_distance` is how far in pixels a second press may land from the first and still
    /// continue the sequence. A platform has a number for this; the caller owns it, because it is
    /// the one value here that is a system preference rather than a terminal rule.
    ///
    /// Answers whether a selection now exists.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_press(
        &mut self,
        point: SurfacePoint,
        time: Duration,
        repeat_interval: Duration,
        repeat_distance: f64,
        ladder: ClickLadder,
    ) -> Result<bool> {
        let coord = cell_at(point, self.surface_geometry(), self.cols, self.rows);
        let behaviors = Behaviors::from(ladder);
        let Self {
            terminal, selecting, ..
        } = self;

        let grid_ref = terminal.grid_ref(Point::Viewport(coord))?;
        selecting
            .press
            .set_position(point.x, point.y)?
            .set_time(time)?
            .set_repeat_interval(repeat_interval)?
            .set_repeat_distance(repeat_distance)?
            .set_behaviors(&behaviors)?;
        let selection = selecting
            .press
            .apply(&mut selecting.gesture, terminal, grid_ref)?;
        terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Extends the gesture to `point`.
    ///
    /// `rectangle` is the block-selection modifier (⌥ on the Mac). It is read on every drag rather
    /// than latched at press, because a user who starts an ordinary drag and then holds ⌥ expects
    /// the selection they are still holding to become rectangular.
    ///
    /// Answers whether a selection now exists.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_drag(&mut self, point: SurfacePoint, rectangle: bool) -> Result<bool> {
        let geometry = self.surface_geometry();
        let coord = cell_at(point, geometry, self.cols, self.rows);
        let rendered = geometry_of(geometry, self.cols);
        let Self {
            terminal, selecting, ..
        } = self;

        let grid_ref = terminal.grid_ref(Point::Viewport(coord))?;
        selecting
            .drag
            .set_position(point.x, point.y)?
            .set_rectangle(rectangle)?;
        let selection = selecting
            .drag
            .apply(&mut selecting.gesture, terminal, grid_ref, rendered)?;
        terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Ends the gesture, leaving the selection standing.
    ///
    /// The selection is deliberately NOT cleared: a release is what makes a selection copyable, and
    /// a terminal that dropped it on mouse-up would have no selection to copy from. What ends is
    /// the gesture — the next press starts a new sequence unless it lands inside the repeat
    /// window.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_release(&mut self, point: SurfacePoint) -> Result<()> {
        let coord = cell_at(point, self.surface_geometry(), self.cols, self.rows);
        let Self {
            terminal, selecting, ..
        } = self;

        let grid_ref = terminal.grid_ref(Point::Viewport(coord)).ok();
        selecting
            .release
            .apply(&mut selecting.gesture, terminal, grid_ref)?;
        Ok(())
    }

    /// Whether the held drag wants the viewport scrolled, and which way.
    ///
    /// The caller scrolls — with [`VtSession::scroll`] — and then calls
    /// [`VtSession::select_autoscroll_tick`]. Two calls rather than one because the SCROLL is the
    /// caller's cadence: a 60 Hz tick and a trackpad's own momentum are different rates, and the
    /// engine has no opinion about which the surface uses.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn selection_autoscroll(&self) -> Result<Autoscroll> {
        Ok(self.selecting.gesture.autoscroll(&self.terminal)?.into())
    }

    /// Re-extends the selection after the caller scrolled under a held drag.
    ///
    /// Answers whether a selection now exists.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_autoscroll_tick(&mut self, point: SurfacePoint, rectangle: bool) -> Result<bool> {
        let geometry = self.surface_geometry();
        let coord = cell_at(point, geometry, self.cols, self.rows);
        let rendered = geometry_of(geometry, self.cols);
        let Self {
            terminal, selecting, ..
        } = self;

        selecting
            .autoscroll
            .set_position(point.x, point.y)?
            .set_rectangle(rectangle)?;
        let selection = selecting
            .autoscroll
            .apply(&mut selecting.gesture, terminal, coord, rendered)?;
        terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Abandons the gesture and drops the selection.
    ///
    /// Both halves, and that is the difference from [`VtSession::select_release`]: this is what a
    /// key press, a focus loss or an Escape means, where a release means "I am done choosing".
    ///
    /// # Errors
    /// The engine's own error.
    pub fn clear_selection(&mut self) -> Result<()> {
        let Self {
            terminal, selecting, ..
        } = self;
        selecting.gesture.reset(terminal);
        terminal.set_selection(None)?;
        Ok(())
    }

    /// Whether anything is selected.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn has_selection(&self) -> Result<bool> {
        Ok(self.terminal.selection()?.is_some())
    }

    /// Selects the whole scrollback.
    ///
    /// Answers whether anything was selected — `false` on a terminal that has never printed.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_all(&mut self) -> Result<bool> {
        let selection = self.terminal.select_all()?;
        self.terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Selects the word under `point`.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_word_at(&mut self, point: SurfacePoint) -> Result<bool> {
        let coord = cell_at(point, self.surface_geometry(), self.cols, self.rows);
        let grid_ref = self.terminal.grid_ref(Point::Viewport(coord))?;
        let selection = self.terminal.select_word(SelectWordOptions::new(grid_ref))?;
        self.terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Selects the line under `point`, stopping at a semantic prompt mark.
    ///
    /// The prompt boundary is on, and it is what makes a triple-click at a prompt select the
    /// command rather than the command plus whatever the previous one printed on the same
    /// visual line.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_line_at(&mut self, point: SurfacePoint) -> Result<bool> {
        let coord = cell_at(point, self.surface_geometry(), self.cols, self.rows);
        let grid_ref = self.terminal.grid_ref(Point::Viewport(coord))?;
        let selection = self
            .terminal
            .select_line(SelectLineOptions::new(grid_ref).with_semantic_prompt_boundary(true))?;
        self.terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// Selects the OUTPUT of the command under `point` — one block's body.
    ///
    /// This is the door `slopdesk_termrender::block` was written for: a block's "copy output"
    /// affordance asks for exactly the rows the engine's own semantic marks bound, so the block
    /// list and the clipboard cannot disagree about where a command's output ended.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn select_output_at(&mut self, point: SurfacePoint) -> Result<bool> {
        let coord = cell_at(point, self.surface_geometry(), self.cols, self.rows);
        let grid_ref = self.terminal.grid_ref(Point::Viewport(coord))?;
        let selection = self.terminal.select_output(grid_ref)?;
        self.terminal.set_selection(selection.as_ref())?;
        Ok(selection.is_some())
    }

    /// The selected text, or `None` when nothing is selected.
    ///
    /// `unwrap` is on: a line the terminal soft-wrapped at column 80 is ONE line as far as the
    /// program that printed it is concerned, and pasting it back with a newline in the middle is
    /// how a copied command runs as two broken ones. `trim` is on for the same class of reason
    /// — the blanks a terminal pads a short line with are not text anybody selected.
    ///
    /// # Errors
    /// The engine's own error, or [`VtError::Engine`] with `OutOfSpace` if the selection grew
    /// between the two attempts below — which is not reachable from one thread, and is answered
    /// rather than looped so that a caller can never spin here.
    pub fn selection_text(&self, format: CopyFormat) -> Result<Option<String>> {
        // Two attempts, never a loop. The first sizes with a stack buffer that covers an ordinary
        // line; the engine answers `OutOfSpace { required }` with the exact size, so the second
        // attempt cannot be short. A loop would be a loop over a value that cannot change, because
        // this session is the only thing that may touch the terminal.
        let mut small = [0_u8; 512];
        let options = FormatOptions::new()
            .with_emit_format(format.into())
            .with_unwrap(true)
            .with_trim(true);

        let required = match self.terminal.format_selection_buf(options, &mut small) {
            Ok(None) => return Ok(None),
            Ok(Some(written)) => return Ok(Some(decode(small.get(..written).unwrap_or(&[])))),
            Err(libghostty_vt::error::Error::OutOfSpace { required }) => required,
            Err(error) => return Err(VtError::from(error)),
        };

        let mut large = vec![0_u8; required];
        let options = FormatOptions::new()
            .with_emit_format(format.into())
            .with_unwrap(true)
            .with_trim(true);
        Ok(self
            .terminal
            .format_selection_buf(options, &mut large)?
            .map(|written| decode(large.get(..written).unwrap_or(&[]))))
    }
}

/// The formatter's bytes as a `String`.
///
/// Lossy, and deliberately: the far side of a PTY is untrusted and may print any byte at all, so a
/// half-written UTF-8 sequence at a selection edge is an ordinary event rather than a failure. A
/// replacement character in the clipboard is a better answer than a copy that refuses.
fn decode(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use core::time::Duration;

    use super::{Autoscroll, ClickLadder, CopyFormat, Granularity, SurfacePoint, axis, cell_at};
    use crate::input::SurfaceGeometry;
    use crate::session::VtSession;

    /// A 20×5 session whose cells are 10×20 pixels, with no padding — so a pixel's cell is its
    /// coordinate divided by the cell size, and a wrong answer is obvious by inspection.
    fn session() -> VtSession {
        let mut vt = VtSession::new(20, 5, 10, 20).unwrap();
        vt.set_surface_geometry(SurfaceGeometry {
            width: 200,
            height: 100,
            cell_width: 10,
            cell_height: 20,
            ..SurfaceGeometry::default()
        });
        vt
    }

    fn at(x: f64, y: f64) -> SurfacePoint {
        SurfacePoint { x, y }
    }

    #[test]
    fn a_pixel_lands_in_the_cell_that_contains_it() {
        let geometry = SurfaceGeometry {
            width: 200,
            height: 100,
            cell_width: 10,
            cell_height: 20,
            ..SurfaceGeometry::default()
        };
        assert_eq!(cell_at(at(0.0, 0.0), geometry, 20, 5).x, 0);
        assert_eq!(cell_at(at(9.9, 0.0), geometry, 20, 5).x, 0);
        assert_eq!(cell_at(at(10.0, 0.0), geometry, 20, 5).x, 1);
        assert_eq!(cell_at(at(0.0, 19.9), geometry, 20, 5).y, 0);
        assert_eq!(cell_at(at(0.0, 20.0), geometry, 20, 5).y, 1);
    }

    #[test]
    fn a_pixel_outside_the_surface_clamps_rather_than_wrapping() {
        let geometry = SurfaceGeometry {
            width: 200,
            height: 100,
            cell_width: 10,
            cell_height: 20,
            padding_left: 4,
            padding_top: 6,
            ..SurfaceGeometry::default()
        };
        // Left of the padding is column zero, NOT a negative index that wraps as a u32.
        assert_eq!(cell_at(at(-1000.0, -1000.0), geometry, 20, 5), PointZero::COORD);
        let far = cell_at(at(100_000.0, 100_000.0), geometry, 20, 5);
        assert_eq!(far.x, 19);
        assert_eq!(far.y, 4);
    }

    /// Named so the assertion above reads as a claim rather than as two zeroes.
    struct PointZero;
    impl PointZero {
        const COORD: libghostty_vt::terminal::PointCoordinate =
            libghostty_vt::terminal::PointCoordinate { x: 0, y: 0 };
    }

    #[test]
    fn a_nan_coordinate_is_the_first_cell_and_not_the_last() {
        // `f64::min` answers the non-NaN operand, so the naive clamp would put NaN at the last
        // cell. This is the assertion that keeps the explicit early return honest.
        assert_eq!(axis(f64::NAN, 0.0, 10.0, 20), 0);
        assert_eq!(axis(f64::INFINITY, 0.0, 10.0, 20), 19);
        assert_eq!(axis(f64::NEG_INFINITY, 0.0, 10.0, 20), 0);
    }

    #[test]
    fn a_zero_sized_cell_does_not_divide_by_zero() {
        assert_eq!(axis(100.0, 0.0, 0.0, 20), 0);
    }

    #[test]
    fn a_one_cell_grid_has_only_cell_zero() {
        assert_eq!(axis(1000.0, 0.0, 10.0, 1), 0);
        assert_eq!(axis(1000.0, 0.0, 10.0, 0), 0);
    }

    #[test]
    fn nothing_is_selected_until_something_selects_it() {
        let vt = session();
        assert!(!vt.has_selection().unwrap());
        assert_eq!(vt.selection_text(CopyFormat::Plain).unwrap(), None);
    }

    #[test]
    fn a_press_and_drag_selects_the_text_between_them() {
        let mut vt = session();
        vt.feed(b"hello world");
        assert_eq!(vt.render().unwrap(), crate::FrameDirty::Full);

        vt.select_press(
            at(0.0, 0.0),
            Duration::from_millis(0),
            Duration::from_millis(500),
            3.0,
            ClickLadder::default(),
        )
        .unwrap();
        // 50.0 is the LEADING edge of cell 5, and that is the number to use rather than 45.0:
        // the engine snaps a drag at each cell's MIDPOINT, so a drag to the middle of cell 4 still
        // ends before it. That is ordinary terminal behaviour — it is what makes a drag feel like
        // it follows the pointer rather than lagging half a character behind it — and
        // pinning it here means a future engine that stopped doing it would be caught
        // rather than silently accepted.
        vt.select_drag(at(50.0, 0.0), false).unwrap();
        vt.select_release(at(50.0, 0.0)).unwrap();

        assert!(vt.has_selection().unwrap());
        let text = vt.selection_text(CopyFormat::Plain).unwrap().unwrap();
        assert_eq!(text, "hello", "cells 0..=4 of `hello world`");
    }

    #[test]
    fn the_selection_reaches_the_frame_the_renderer_reads() {
        let mut vt = session();
        vt.feed(b"hello world");
        vt.render().unwrap();

        vt.select_press(
            at(0.0, 0.0),
            Duration::from_millis(0),
            Duration::from_millis(500),
            3.0,
            ClickLadder::default(),
        )
        .unwrap();
        vt.select_drag(at(50.0, 0.0), false).unwrap();
        vt.render().unwrap();

        let span = vt.frame().rows.first().and_then(|row| row.selection);
        assert_eq!(
            span.map(|span| (span.start, span.end)),
            Some((0, 5)),
            "the renderer paints a selection by reading the frame, so it must arrive there"
        );
    }

    #[test]
    fn a_double_click_selects_a_word_rather_than_a_cell() {
        let mut vt = session();
        vt.feed(b"hello world");
        vt.render().unwrap();

        let ladder = ClickLadder::default();
        let click = |vt: &mut VtSession, millis: u64| {
            vt.select_press(
                at(2.0, 0.0),
                Duration::from_millis(millis),
                Duration::from_millis(500),
                3.0,
                ladder,
            )
            .unwrap();
            vt.select_release(at(2.0, 0.0)).unwrap();
        };
        click(&mut vt, 0);
        click(&mut vt, 100);

        assert_eq!(
            vt.selection_text(CopyFormat::Plain).unwrap().as_deref(),
            Some("hello")
        );
    }

    #[test]
    fn clearing_drops_the_selection_and_the_gesture() {
        let mut vt = session();
        vt.feed(b"hello");
        vt.render().unwrap();
        assert!(vt.select_all().unwrap());

        vt.clear_selection().unwrap();

        assert!(!vt.has_selection().unwrap());
        assert_eq!(vt.selection_text(CopyFormat::Plain).unwrap(), None);
    }

    #[test]
    fn selecting_a_word_and_a_line_are_two_different_answers() {
        let mut vt = session();
        vt.feed(b"hello world");
        vt.render().unwrap();

        assert!(vt.select_word_at(at(2.0, 0.0)).unwrap());
        let word = vt.selection_text(CopyFormat::Plain).unwrap().unwrap();

        assert!(vt.select_line_at(at(2.0, 0.0)).unwrap());
        let line = vt.selection_text(CopyFormat::Plain).unwrap().unwrap();

        assert_eq!(word, "hello");
        assert_eq!(line, "hello world");
    }

    #[test]
    fn a_selection_longer_than_the_stack_buffer_survives_the_second_attempt() {
        // 512 bytes is the first attempt's buffer; 20 columns × 5 rows cannot exceed it, so the
        // grid is widened until the answer must take the heap path.
        let mut vt = VtSession::new(200, 40, 10, 20).unwrap();
        vt.set_surface_geometry(SurfaceGeometry {
            width: 2000,
            height: 800,
            cell_width: 10,
            cell_height: 20,
            ..SurfaceGeometry::default()
        });
        for _ in 0..40 {
            vt.feed(&[b'x'; 200]);
        }
        vt.render().unwrap();
        assert!(vt.select_all().unwrap());

        let text = vt.selection_text(CopyFormat::Plain).unwrap().unwrap();
        assert!(
            text.len() > 512,
            "the retry path never ran — this test is no longer testing it ({} bytes)",
            text.len()
        );
        assert!(text.chars().all(|c| c == 'x' || c == '\n'));
    }

    #[test]
    fn nothing_autoscrolls_without_a_drag() {
        let vt = session();
        assert_eq!(vt.selection_autoscroll().unwrap(), Autoscroll::None);
    }

    #[test]
    fn the_ladder_defaults_to_cell_word_line() {
        let ladder = ClickLadder::default();
        assert_eq!(ladder.single, Granularity::Cell);
        assert_eq!(ladder.double, Granularity::Word);
        assert_eq!(ladder.triple, Granularity::Line);
    }
}
