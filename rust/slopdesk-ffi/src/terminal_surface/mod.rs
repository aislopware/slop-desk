//! The terminal surface: one handle that is the engine, the arithmetic, the fonts and the GPU.
//!
//! `docs/68-terminal-surface-in-rust.md` is the argument; this is the door. The four crates it
//! §10.1 names meet HERE and nowhere else, the same way [`crate::decoder`] is where
//! `slopdesk-video`'s rules meet `slopdesk-apple-vt`'s calls:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_vterm`] | what the bytes did — the grid, the cursor, the selection, the encoders |
//! | [`slopdesk_termrender`] | where every pixel of that goes, with no GPU and no font engine |
//! | `slopdesk-apple-text` | what a glyph looks like |
//! | `slopdesk-apple-metal` | the draw |
//!
//! ## Why ONE handle rather than four
//!
//! Because they only exist together, and every state in which two of them disagree is a bug the
//! type system would otherwise be unable to see. The contents scale is the clearest case: it picks
//! the font's rasterisation size, the cell's pixel extent, the grid's column count, the drawable's
//! size and the layer's `contentsScale`. Four handles means five copies of one number and five
//! chances for a Retina window dragged onto a 1× display to keep one of them. One handle means
//! [`SlopDeskTerminalSurface::set_geometry`] is the only writer and there is nothing to drift.
//!
//! The same argument answers why the glyph cache is not its own door: an atlas is only meaningful
//! beside the font stack that filled it and the renderer that uploaded it, and handing a caller two
//! of the three is handing it the chance to pair a cache with the wrong face.
//!
//! ## The thread rule, which is the whole safety story here
//!
//! **Every door in this module must be called on the main thread**, and unlike the audio and video
//! handles that is not a convention this file chose — it is what the types are. `libghostty-vt`'s
//! terminal is `!Send` and `!Sync` and upstream locks nothing (`slopdesk-vterm`'s own header states
//! it), a `CAMetalLayer` is main-thread-affine, and Core Text's font objects are the same. So the
//! handle carries no lock at all: there is nothing for a second thread to contend for, because a
//! second thread may not have it. The Swift owner is `@MainActor` and the display link hops to the
//! main actor before it draws.
//!
//! That is a stronger obligation than [`crate::decoder`]'s and it is stated rather than implied,
//! because the failure it prevents is silent: the engine's page allocator is not thread-safe, so a
//! feed from a background queue corrupts the grid rather than tripping an assertion.
//!
//! ## The layer crosses at +0, and that is the opposite of the decoder's pixels
//!
//! [`crate::decoder`] hands its image buffers over at +1 and the caller must release. This module's
//! [`slopdesk_term_surface_layer`] LENDS: Rust made the `CAMetalLayer`, Rust owns it for the whole
//! life of the handle, and Swift only hosts it on a view. Swift takes it with
//! `Unmanaged<CAMetalLayer>.fromOpaque(_:).takeUnretainedValue()` — no release, ever.
//!
//! The difference is not a taste. A decoded frame outlives the call that produced it (a pacer holds
//! it to the next vsync), so ownership has to move. A layer does not outlive its surface: the view
//! is torn down first, and a Swift-owned reference surviving `_free` would be a layer whose
//! drawable source is gone. Lending makes that unrepresentable.
//!
//! ## Why this is a DIRECTORY, and what stayed here
//! One file held all of it until 2026-09-01, at 4 300 lines. What stayed is the STATE: the handle,
//! [`Surface`] and its arithmetic, because every child reaches it and a child that owned part of it
//! would be a second writer of the contents scale this header just argued against. The children are
//! the doors over it — [`doors`] is the lifecycle and every setting written, [`pointer`] is what a
//! click does, [`reading`] is what the surface answers, [`blocks`] is the block layout with the
//! links and the caret that ride its coordinates. The cut follows the file's own `// MARK:`
//! banners; no door moved between them.

pub mod blocks;
pub mod doors;
pub mod pointer;
pub mod reading;

#[cfg(test)]
mod tests;

use blocks::{SlopDeskTerminalChromeStyle, settled_scroll};
use slopdesk_apple_metal::Renderer;
use slopdesk_apple_text::{FontStack, Rasterizer, Shaper};
use slopdesk_terminal::config::FontSpec;
use slopdesk_terminal::geometry::{CellMetrics, Rect};
use slopdesk_termrender::{
    BlockLayout, BlockSpan, CellGeometry, Chrome, ChromeFrame, DrawList, GlyphCache, ImagePlacement,
    ImageStore, Insets, LayoutMode, PaintStyle, Painter, PlacedBlock, Preedit, Rgba, SelectionColors, Thumb,
    Viewport, blockjoin, chrome, grid_size, lay_out, place, scrollbar, segment,
};
use slopdesk_vterm::input::SurfaceGeometry;
use slopdesk_vterm::{Frame, VtSession};

/// The gutter, header and gap a command block is drawn with, in POINTS.
///
/// Points rather than pixels because these are design numbers — `DESIGN.md`'s, not the font's — and
/// a design number that changed with the display would be a different design on a Retina screen.
/// [`SlopDeskTerminalSurface::chrome`] scales them once, where every other point→pixel conversion
/// in this file happens.
const BLOCK_HEADER_PT: f64 = 22.0;
/// The gap between one block and the next, in points.
const BLOCK_GAP_PT: f64 = 6.0;
/// The gutter reserved at the leading edge for a block's status mark, in points.
const BLOCK_GUTTER_PT: f64 = 14.0;
/// The inset between the drawable's edge and the grid, in points, on all four sides.
const GRID_INSET_PT: f64 = 4.0;

/// The opaque handle every door takes, and the ONE place the close/free split lives.
///
/// ## Why the state is behind an `Option` rather than being the handle itself
///
/// A `CAMetalLayer` is LENT to the view, and its drawable source is the [`Surface`] below. The view
/// must therefore drop the layer BEFORE the state dies — an ordering `deinit` cannot express, since
/// `deinit` runs when the last reference goes and the view may still be holding one. So teardown is
/// two doors: [`slopdesk_term_surface_close`] takes the state at the moment the view says it has
/// let go, and [`slopdesk_term_surface_free`] returns the allocation in `deinit`, where nothing
/// else can still be reading it. `slopdesk-invariants`' `handle-freed-in-deinit` is the ratchet on
/// exactly that shape: a `_free` called from anywhere but `deinit` is a claim about which threads
/// are running, and `VideoMuxClientFlow` is what that claim costs when it is wrong.
///
/// A closed handle stays VALID and answers every door its inert value — `0`, `false`, NULL. That is
/// deliberate: a Swift object may outlive its detach by a runloop turn, and a door that faulted
/// instead would turn an ordinary teardown race into a crash.
#[derive(Debug)]
pub struct SlopDeskTerminalSurface {
    /// The live state, or `None` once closed.
    inner: Option<Surface>,
}

/// A live terminal surface: the engine, its fonts, its arithmetic and its GPU.
///
/// See the module header for why this is one object and not four, and for the thread rule every
/// door on it inherits.
// Four independent flags, and the lint's own remedy is the wrong shape for them: `focused` comes
// from the responder chain, `blink_visible` from a timer, `follow_bottom` from the scroll, and
// `images_enabled` from the config file. Nothing constrains their combinations, so the "state
// machine" the lint asks for would be a sixteen-state enum enumerating a product of four bits — more
// spelling, no fewer states, and each owner would then write through a translation.
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent inputs from four owners; their product is not a state machine"
)]
#[derive(Debug)]
struct Surface {
    /// The engine. Fed bytes, asked for frames.
    session: VtSession,
    /// The faces, and the two traits the paint pass reaches them through.
    font: FontStack,
    /// What [`Self::font`] was built FROM, kept because a `FontStack` does not answer it and a
    /// scale change has to rebuild the stack from the same inputs. Storing the whole spec is what
    /// makes that rebuild reproducible rather than a second call into the config — and what makes
    /// "did anything about the font move" ONE comparison, rather than one per row that the next
    /// `terminal.font-*` setting would have to be remembered to join.
    spec: FontSpec,
    /// Core Text shaping, rebuilt whenever [`Self::font`] is.
    shaper: Shaper,
    /// Core Text rasterisation, rebuilt whenever [`Self::font`] is.
    rasterizer: Rasterizer,
    /// The atlas and its index. Survives a resize, because a glyph's raster does not depend on the
    /// grid — only on the face and the scale, and a change to either rebuilds this outright.
    cache: GlyphCache,
    /// The paint pass's reusable scratch.
    painter: Painter,
    /// The instances one frame draws. Cleared and refilled rather than reallocated.
    list: DrawList,
    /// Every inline image the engine holds, as pixels. Survives a frame, unlike [`Self::list`] —
    /// the whole point of a store is that a picture is not retransmitted to be redrawn.
    images: ImageStore,
    /// The engine's placements for this frame. A field rather than a local so the `Vec`'s
    /// allocation survives sixty frames a second; [`VtSession::placements`] clears it on entry.
    placements: Vec<ImagePlacement>,
    /// Which image ids this frame placed, scratch for [`ImageStore::retain`]. Same reason.
    placed_ids: Vec<u32>,
    /// Whether inline images are drawn at all — `terminal.images`.
    ///
    /// The engine keeps its storage either way, so this gates the RENDER and nothing else: turning
    /// it back on redraws whatever is still on screen without asking a program to retransmit.
    images_enabled: bool,
    /// The device, the queue, the layer and the pipelines.
    renderer: Renderer,
    /// The drawable's size in device pixels, and the scale it was derived at.
    geometry: PixelGeometry,
    /// How far the block list has scrolled, in device pixels. Zero on the alternate screen, which
    /// has no scrollback to reach.
    ///
    /// This is the CHROME's scroll and nothing else. `grid_size` sizes the grid from the drawable
    /// alone, so headers and gaps push the block list taller than the viewport by roughly one
    /// header per command on screen; that overflow lives here rather than in the row count. The
    /// alternative — shrinking the grid to make room — would make the PTY's height depend on how
    /// many prompts happen to be visible, which is a `SIGWINCH` per command.
    scroll_y: f64,
    /// Whether the block list stays pinned to its bottom as content grows.
    ///
    /// True is the live-terminal default: new output has to stay on screen without the user
    /// chasing it. An upward scroll drops the pin, and reaching the bottom again — or any
    /// [`Scroll::Bottom`] — takes it back.
    follow_bottom: bool,
    /// Which blocks the user folded, indexed the way [`lay_out`] reads it — positionally, so a
    /// short slice means "not collapsed" for the rest.
    collapsed: Vec<bool>,
    /// Where the last [`Self::draw`] put every block.
    ///
    /// Kept because the chrome doors have to answer BETWEEN frames: `paint.rs` refuses to draw
    /// headers, gutter marks and the scrollbar — they carry the client's design language — and
    /// hands over their rects instead, so a hit test and a header's frame are questions asked long
    /// after the draw that computed them.
    layout: BlockLayout,
    /// Whether the surface holds the keyboard. Drives the hollow cursor and nothing else — an
    /// unfocused split sibling still repaints.
    focused: bool,
    /// The renderer's blink clock. The view owns the timer; this is where its phase lands.
    blink_visible: bool,
    /// How solid the caret is drawn, `0.0`–`1.0`.
    ///
    /// Lives HERE and not on the session because no terminal escape can express it — see
    /// [`PaintStyle::cursor_opacity`]. It is the one cursor setting the engine has no opinion
    /// about, which is exactly why it is the one held on the surface.
    cursor_opacity: f64,
    /// The glyph colour under a filled caret, or [`None`] to keep the cell's own background.
    ///
    /// Here for [`Self::cursor_opacity`]'s reason: the engine has no default to override.
    cursor_text: Option<Rgba>,
    /// How a selection recolours what it covers, as the theme set it.
    selection: SelectionColors,
    /// The client's design for the block furniture, in the POINTS it stated it in.
    ///
    /// Held as the record that crossed rather than as a [`ChromeStyle`] because a `ChromeStyle` is
    /// device pixels by definition, and the scale it would be converted at moves — dragging a
    /// window between a Retina display and a 1× one rebuilds the font stack but must not oblige
    /// the client to restate its design. Converting in [`Self::draw`] is what makes the scale
    /// change free.
    ///
    /// [`SlopDeskTerminalChromeStyle::default`] draws nothing, which is the honest state before an
    /// appearance is installed: a surface whose client has not said what a divider looks like
    /// should show output and no furniture, not a guess.
    chrome_style: SlopDeskTerminalChromeStyle,
    /// Where the pointer is, in POINTS, when it is inside the surface at all.
    ///
    /// A POINT and not a block index: an index goes stale the moment output arrives and re-lays the
    /// list out, so a client that reported one would light the wrong block for a frame every time a
    /// command printed. The point stays true until the pointer actually moves.
    hover: Option<(f64, f64)>,
    /// The clear colour, which is also the reason `quad.rs` may drop a background rect that
    /// matches.
    background: Rgba,
    /// Bytes drained from the engine's pty-reply queue and not yet handed to the caller.
    ///
    /// Held on the handle rather than drained per call because the two-attempt convention lets a
    /// first call answer "too small". Draining straight into the caller's buffer would lose the
    /// reply on exactly the call that told them to try again — and a lost device-status reply is a
    /// program that waits forever. Cleared only once `deliver` has actually written it.
    pty_replies: Vec<u8>,
    /// The encoded clipboard frame, held for the same reason and cleared under the same rule.
    clipboard_writes: Vec<u8>,
    /// What an input method is composing over the cursor, or `None` when nothing is.
    composing: Option<Composition>,
    /// What the host has said about this pane's command blocks, newest last.
    ///
    /// The surface holds these ONLY to print them on a header. It does not own them — the client's
    /// `TerminalBlockModel` is the ring, fed by wire type 28 — and it does not interpret them:
    /// which record describes which laid-out block is [`blockjoin`]'s decision, retaken every
    /// frame because both sides move (output re-lays the blocks out, and a completion rewrites
    /// a record).
    ///
    /// Bounded by [`MAX_RECORDS`], because a long-lived pane would otherwise accumulate one entry
    /// per command it ever ran for the sake of headers that scrolled out of reach hours ago.
    records: Vec<BlockRecord>,
}

/// How many command-block records a surface keeps.
///
/// Matched to the host ring's own `MAX_BLOCKS`, so the surface can print a header for exactly the
/// blocks the host can still describe and not one more. A larger number here would hold records
/// whose blocks the host has already forgotten; a smaller one would drop records for blocks still
/// on screen.
const MAX_RECORDS: usize = 64;

/// One host command-block record, as much of it as a header needs.
///
/// `command_text` is carried for the JOIN and not for display — the header prints the rows in front
/// of it, which are the real thing rather than the host's transcription of it. It is what confirms
/// that the ordinal counted down to this block is the ordinal the host meant.
#[derive(Debug, Clone)]
struct BlockRecord {
    /// The segmenter's 1-based OSC 133 `A` count for this block.
    ordinal: u32,
    /// The command it recorded, used to confirm the join.
    command_text: String,
    /// Its exit code, or `None` while it runs.
    exit_code: Option<i32>,
    /// How long it took, or `None` while it runs.
    duration_ms: Option<u32>,
}

/// One composition, measured where it arrived.
///
/// Measured HERE rather than in the paint pass because [`slopdesk_vterm::text_cells`] collects the
/// text's scalars to walk it with the engine's own segmenter, and a composition changes on a
/// keystroke while a frame is drawn sixty times a second. Storing the answer is what keeps that
/// allocation off the render path.
#[derive(Debug, Clone, Default)]
struct Composition {
    /// The composing text, exactly as the platform's input method last reported it.
    text: String,
    /// How many grid cells [`Self::text`] takes.
    cells: u16,
    /// How many cells into it the composition's own caret sits, clamped to [`Self::cells`].
    cursor_cells: u16,
}

/// The drawable, measured.
///
/// Every field is a DEVICE pixel except [`Self::scale`], which is what produced them. Points stop
/// at the view (`slopdesk-termrender`'s "Units" header), and this struct is the one place the
/// conversion is recorded so a later reader can tell which space a number is in by its type.
#[derive(Debug, Clone, Copy, PartialEq)]
struct PixelGeometry {
    /// Drawable width in device pixels.
    width: f64,
    /// Drawable height in device pixels.
    height: f64,
    /// The contents scale the two above were derived at.
    scale: f64,
}

impl Surface {
    /// Builds a surface on the system default Metal device wearing `spec`.
    ///
    /// `None` when there is no Metal device, when the pipelines will not build, or when the spec
    /// names a size Core Text cannot measure a grid at — each of which is a machine or a
    /// configuration this build cannot draw on, and none of which becomes true a frame later. The
    /// caller latches the refusal.
    fn create(spec: &FontSpec, scale: f64, width: f64, height: f64) -> Option<Self> {
        let font = FontStack::new(spec, scale)?;
        let renderer = Renderer::new().ok()?;
        let geometry = PixelGeometry {
            width: width * scale,
            height: height * scale,
            scale,
        };
        let (cols, rows) = grid_size(
            geometry.width,
            geometry.height,
            Insets::uniform(GRID_INSET_PT * scale),
            font.cell_width(),
            font.cell_height(),
        );
        // The engine is told the cell size in whole pixels because that is what its own pointer
        // encoder divides by. Rounding here rather than at each read keeps the cell the mouse
        // resolves and the cell the painter draws the same one.
        let session = VtSession::new(
            cols,
            rows,
            round_px(font.cell_width()),
            round_px(font.cell_height()),
        )
        .ok()?;

        let mut surface = Self {
            shaper: font.shaper(),
            rasterizer: font.rasterizer(),
            session,
            font,
            spec: spec.clone(),
            cache: GlyphCache::default(),
            painter: Painter::new(),
            list: DrawList::default(),
            images: ImageStore::new(),
            placements: Vec::new(),
            placed_ids: Vec::new(),
            // ON by default, and the setting exists to turn it OFF rather than to opt in. A
            // terminal that silently discards what a program drew is the surprising one; `docs/68`
            // §5.7 argues it.
            images_enabled: true,
            renderer,
            geometry,
            scroll_y: 0.0,
            follow_bottom: true,
            collapsed: Vec::new(),
            layout: BlockLayout::default(),
            focused: false,
            blink_visible: true,
            cursor_opacity: 1.0,
            cursor_text: None,
            // A slate the theme immediately overwrites. Not black, because a surface that flashed
            // pure black between `new` and the first `set_theme` would read as a broken pane rather
            // than an empty one.
            selection: SelectionColors {
                background: Rgba::opaque(62, 68, 81),
                foreground: None,
            },
            background: Rgba::opaque(15, 17, 21),
            chrome_style: SlopDeskTerminalChromeStyle::default(),
            hover: None,
            pty_replies: Vec::new(),
            clipboard_writes: Vec::new(),
            composing: None,
            records: Vec::new(),
        };
        surface.apply_geometry();
        Some(surface)
    }

    /// Re-measures the drawable and re-fits the grid, answering the new `(cols, rows)`.
    ///
    /// The caller mirrors the answer to the host as a `resize`, which is why it comes back rather
    /// than being read separately: a caller that re-asked would be asking a question this call has
    /// already answered, and the two could differ across a second resize.
    fn set_geometry(&mut self, width: f64, height: f64, scale: f64) -> (u16, u16) {
        // Bit-equality is the RIGHT test here and an epsilon would be the wrong one: a contents
        // scale is COPIED from the platform (`NSWindow.backingScaleFactor`, `UIScreen.scale`),
        // never computed, so the only values it takes are the handful the system reports
        // and any difference at all is a real display change. A margin would let a 1×
        // window dragged onto a 2× display keep a 1× atlas.
        #[expect(
            clippy::float_cmp,
            reason = "a platform-reported scale, argued immediately above"
        )]
        let rescaled = scale != self.geometry.scale;
        self.geometry = PixelGeometry {
            width: width * scale,
            height: height * scale,
            scale,
        };
        if rescaled {
            // A scale change invalidates every rasterised glyph — the atlas holds coverage masks
            // measured in device pixels — so the face stack, both traits and the cache are rebuilt
            // together. Rebuilding any subset would pair a 1× atlas with a 2× shaper.
            if let Some(font) = FontStack::new(&self.spec, scale) {
                self.shaper = font.shaper();
                self.rasterizer = font.rasterizer();
                self.font = font;
                self.cache = GlyphCache::default();
            }
        }
        self.apply_geometry();
        self.session.size()
    }

    /// Rebuilds the face stack at a new spec, answering the grid that now fits.
    ///
    /// The rebuild is [`Self::set_geometry`]'s rescale branch with the spec moving instead of the
    /// scale, and for the same reason: the atlas holds coverage masks measured against ONE face at
    /// ONE size, so a new face invalidates every glyph in it. Rebuilding any subset would pair last
    /// size's atlas with this size's shaper. It is the WHOLE spec that decides, not the family and
    /// the size: a `font-feature` line that turned ligatures off would otherwise be read, published
    /// and dropped, because nothing the early-out compared had moved.
    ///
    /// A family Core Text cannot resolve leaves the current stack standing rather than refusing to
    /// draw — the honest outcome for a font name the user mistyped in `config.toml`, and the same
    /// one a scale change takes.
    fn set_font(&mut self, spec: &FontSpec) -> (u16, u16) {
        // Bit-equality is a CONSERVATIVE test here, not an exact one: an identical spec is
        // certainly unchanged, and one that differs by an ulp costs one needless atlas rebuild
        // rather than a wrong frame. The publish this answers fires on every settings write, so the
        // early-out is what keeps an unrelated toggle from re-rasterising the screen.
        if *spec == self.spec {
            return self.session.size();
        }
        let Some(font) = FontStack::new(spec, self.geometry.scale) else {
            return self.session.size();
        };
        self.shaper = font.shaper();
        self.rasterizer = font.rasterizer();
        self.font = font;
        self.cache = GlyphCache::default();
        self.spec = spec.clone();
        self.apply_geometry();
        self.session.size()
    }

    /// Fits the grid to the drawable and pushes both to the engine and the layer.
    ///
    /// Split out because two callers need it and they need it in the same order: measure, resize
    /// the engine, then tell the engine the SURFACE geometry its pointer encoder divides by. A
    /// caller that did the last two the other way round would report a click against the
    /// previous grid.
    fn apply_geometry(&mut self) {
        let (cols, rows) = grid_size(
            self.geometry.width,
            self.geometry.height,
            self.insets(),
            self.font.cell_width(),
            self.font.cell_height(),
        );
        let cell_width = round_px(self.font.cell_width());
        let cell_height = round_px(self.font.cell_height());
        // A refused resize leaves the previous grid standing, which is the honest outcome: the
        // engine still holds a grid that matches the frame it last produced.
        let _refused = self.session.resize(cols, rows, cell_width, cell_height);
        let insets = self.insets();
        self.session.set_surface_geometry(SurfaceGeometry {
            width: narrow_u32(self.geometry.width),
            height: narrow_u32(self.geometry.height),
            cell_width,
            cell_height,
            padding_top: narrow_u32(insets.top),
            padding_bottom: narrow_u32(insets.bottom),
            padding_left: narrow_u32(insets.left),
            padding_right: narrow_u32(insets.right),
        });
        self.renderer.surface().set_size(
            self.geometry.width / self.geometry.scale,
            self.geometry.height / self.geometry.scale,
            self.geometry.scale,
        );
    }

    /// The grid's inset inside the drawable, in device pixels.
    fn insets(&self) -> Insets {
        Insets::uniform(GRID_INSET_PT * self.geometry.scale)
    }

    /// The block furniture, in device pixels — nothing at all on the alternate screen.
    ///
    /// The alternate screen's `Chrome::NONE` is not a special case bolted on: a full-screen program
    /// owns every cell, and a header drawn across the middle of one is vandalism. Pairing it with
    /// [`LayoutMode::Grid`] is what makes the alt screen the block layout's degenerate case rather
    /// than a second path.
    fn chrome(&self, alternate: bool) -> Chrome {
        if alternate {
            return Chrome::NONE;
        }
        let scale = self.geometry.scale;
        Chrome {
            header: BLOCK_HEADER_PT * scale,
            gap: BLOCK_GAP_PT * scale,
            gutter: BLOCK_GUTTER_PT * scale,
        }
    }

    /// Renders the engine's viewport and draws one frame.
    ///
    /// `false` when there was nothing to draw on — a collapsed split, a window mid-resize, or a
    /// drawable the compositor declined — which is not an error and needs no recovery: the next
    /// frame has somewhere to go.
    fn draw(&mut self) -> bool {
        if self.session.render().is_err() {
            return false;
        }
        let alternate = self.session.is_alternate_screen().unwrap_or(false);
        let mode = LayoutMode::for_screen(alternate);
        let chrome = self.chrome(alternate);
        let insets = self.insets();
        let cell_height = self.font.cell_height();

        let spans: Vec<BlockSpan> = segment(self.session.frame(), mode);
        let viewport_height = self.geometry.height - insets.top - insets.bottom;
        let viewport = Viewport {
            scroll_y: self.scroll_y,
            height: viewport_height,
            width: self.geometry.width - insets.left - insets.right,
        };
        let mut layout: BlockLayout = lay_out(&spans, &self.collapsed, chrome, cell_height, viewport);

        // The list's height is only knowable once it is laid out, and the scroll it is clamped
        // against is an input to that layout — so the pin costs a second pass. Laying out twice
        // rather than measuring the height a second way is what keeps ONE height formula: a
        // `measure` helper beside `lay_out` would be a rule that could drift from the rects it
        // predicts. The pass is O(blocks) over at most a screenful, and only runs when the clamp
        // actually moved something.
        let settled = self.settle_scroll(layout.content_height, viewport_height);
        if settled {
            layout = lay_out(&spans, &self.collapsed, chrome, cell_height, Viewport {
                scroll_y: self.scroll_y,
                ..viewport
            });
        }

        let style = PaintStyle {
            geometry: CellGeometry {
                metrics: CellMetrics {
                    cell_width: self.font.cell_width(),
                    cell_height,
                    origin_x: insets.left,
                    origin_y: insets.top,
                },
                font: self.font.metrics(),
            },
            size_px: self.font.size_px(),
            content_origin_y: insets.top - self.scroll_y,
            selection: self.selection,
            focused: self.focused,
            blink_visible: self.blink_visible,
            cursor_opacity: self.cursor_opacity,
            cursor_text: self.cursor_text,
        };

        // The paint pass and the draw are separated by nothing but this line, and that is the
        // point: every decision was made above by `forbid(unsafe_code)` code, and what
        // crosses into Metal is a flat instance list with no rule left in it.
        self.painter.paint(
            self.session.frame(),
            &layout,
            &style,
            self.composing.as_ref().map(Composition::run),
            &mut self.cache,
            &mut self.shaper,
            &mut self.rasterizer,
            &mut self.list,
        );
        // The furniture goes on AFTER the text and reads the layout the text was placed against —
        // the same `layout`, not `self.layout`, because assigning first would put a re-borrow of
        // `self` between the two passes for no gain. `chrome::paint` writes to the list's two ENDS,
        // so drawing second does not mean drawing over.
        //
        // The alternate screen gets no second pass at all, rather than `ChromeStyle::NONE`. The two
        // draw the same picture — every one of NONE's lengths is zero — but they are not the same
        // work, and skipping is what says the pass is inapplicable rather than merely invisible:
        // the frame this branch would build hit-tests the pointer and asks the engine for its
        // viewport, and both answers would be thrown away. The picture matters too.
        // `LayoutMode::for_screen` hands a full-screen program ONE headerless block, so a style
        // that survived here would run a gutter down `vim`'s left column and — the cursor being
        // inside block zero by definition — accent it.
        if !alternate {
            let frame = ChromeFrame {
                hovered: self
                    .hover
                    .and_then(|(x, y)| block_at(&layout, |rect| self.on_screen(rect), x, y)),
                active: active_block(&layout, self.session.frame()),
                viewport: Rect {
                    x: insets.left,
                    y: insets.top,
                    width: viewport.width,
                    height: viewport_height,
                },
                thumb: self.thumb(&layout, viewport_height, cell_height),
            };
            let statuses = self.statuses(&layout);
            chrome::paint(
                &layout,
                &self.chrome_style.scaled(self.geometry.scale),
                &frame,
                &statuses,
                &style,
                &mut self.cache,
                &mut self.shaper,
                &mut self.rasterizer,
                &mut self.list,
            );
        }
        // AFTER both paint passes, because `Painter::paint` is what clears the list and an image
        // pushed before it would be thrown away. Order within the frame is otherwise free: images
        // live in their own instance array and `renderer.rs` interleaves the three z bands itself.
        //
        // Runs on the ALTERNATE screen too, unlike the chrome pass above, and that is where it
        // matters most — `timg`, `chafa` and every image-viewing TUI live on the alternate screen.
        // `LayoutMode::for_screen` gives them one headerless block, so the clip is the viewport and
        // the arithmetic is the same.
        self.place_images(&layout, &style, Rect {
            x: insets.left,
            y: insets.top,
            width: viewport.width,
            height: viewport_height,
        });

        self.layout = layout;
        self.renderer
            .draw(&self.list, &mut self.cache, &self.images, self.background)
            .is_ok()
    }

    /// Fetches whatever pixels this frame needs and appends every visible placement.
    ///
    /// The first line is the whole cost for a session that has never received an image, which is
    /// every ordinary session: the engine's graphics generation starts at zero and only a kitty
    /// transmission moves it, so an image-free terminal pays one comparison per frame and touches
    /// neither the store nor the placement iterator.
    ///
    /// Pixels are fetched by PLACEMENT rather than by walking the engine's image table, so an image
    /// that is stored but not on screen is never copied. The generation comparison
    /// ([`ImageStore::is_stale`]) is what makes the steady state free — a chart on screen for a
    /// minute is fetched once and drawn three and a half thousand times.
    fn place_images(&mut self, layout: &BlockLayout, style: &PaintStyle, viewport: Rect) {
        if !self.images_enabled || self.session.graphics_generation() == 0 {
            return;
        }

        self.session.placements(&mut self.placements);
        self.placed_ids.clear();
        for index in 0..self.placements.len() {
            let Some(id) = self.placements.get(index).map(|placement| placement.image_id) else {
                continue;
            };
            if !self.placed_ids.contains(&id) {
                self.placed_ids.push(id);
            }
            // A fetch failure is left alone rather than retried or cached as a miss: `place` skips
            // a placement whose pixels the store lacks, and the next frame asks again —
            // which is exactly right for a transmission still arriving in chunks.
            if self
                .session
                .image_meta(id)
                .is_some_and(|meta| self.images.is_stale(meta))
                && let Some(pixels) = self.session.image_pixels(id)
            {
                self.images.insert(pixels);
            }
        }

        // Dropping what this frame did not place is what bounds the store — see [`ImageStore`]. It
        // runs before `place` rather than after so the pixels and the textures are released in the
        // same frame the last placement of them went away.
        self.images.retain(&self.placed_ids);
        place(
            &mut self.placements,
            layout,
            style,
            viewport,
            &self.images,
            &mut self.list,
        );
    }

    /// The prompt rows of one laid-out block, rejoined into one string.
    ///
    /// The rows AS RENDERED, PS1 and all — see [`slopdesk_term_surface_block_text`], which answers
    /// the same thing to the client and is the reason this is factored out rather than written
    /// twice. A block with no prompt rows (an orphan, whose command scrolled off) answers empty.
    fn prompt_text(&self, block: &PlacedBlock) -> String {
        let frame = self.frame();
        let start = block.span.rows.start;
        let end = start.saturating_add(block.span.prompt_rows);
        let mut text = String::new();
        let mut joined = false;
        for row in start..end {
            let Some(line) = frame.row(row) else { continue };
            if joined {
                text.push('\n');
            }
            text.push_str(line.text.trim_end());
            joined = !line.wrapped;
        }
        text
    }

    /// What each laid-out block's header should print, positionally against `layout`.
    ///
    /// Retaken every frame rather than cached against the layout, because both inputs move
    /// independently: output re-segments the blocks, and a `commandBlock` update rewrites a record
    /// in place when a running command finishes. A cache would have to be invalidated by both, and
    /// the join is a walk over at most a screenful of blocks.
    ///
    /// Orphan blocks — no prompt rows, so no command of their own — are skipped before the join and
    /// hold `None` after it, which is what keeps the ordinals counting over the blocks that have
    /// prompts rather than over the rows on screen.
    fn statuses(&self, layout: &BlockLayout) -> Vec<Option<chrome::BlockStatus>> {
        if self.records.is_empty() {
            return Vec::new();
        }
        self.joined_ordinals(layout)
            .into_iter()
            .map(|ordinal| {
                let ordinal = ordinal?;
                let record = self.records.iter().find(|record| record.ordinal == ordinal)?;
                Some(chrome::BlockStatus {
                    exit_code: record.exit_code,
                    duration_ms: record.duration_ms,
                })
            })
            .collect()
    }

    /// Which host RECORD each laid-out block joined to, positionally against `layout`.
    ///
    /// The join itself, with the ordinal KEPT. [`statuses`](Self::statuses) throws it away and
    /// keeps the outcome, because a header prints an exit code; a right-click needs the key
    /// instead, so it can name the same block to the ring after the layout under it has
    /// re-flowed. Two callers, one join — writing it twice is how they would come to disagree
    /// about which block is which.
    ///
    /// Orphan blocks — no prompt rows, so no command of their own — are skipped before the join and
    /// hold `None` after it, which is what keeps the ordinals counting over the blocks that have
    /// prompts rather than over the rows on screen. An alt-screen program has no prompts at all, so
    /// every slot is `None` and the block section offers nothing.
    fn joined_ordinals(&self, layout: &BlockLayout) -> Vec<Option<u32>> {
        let mut out = vec![None; layout.blocks.len()];
        if self.records.is_empty() {
            return out;
        }
        let mut prompts: Vec<String> = Vec::new();
        let mut where_from: Vec<usize> = Vec::new();
        for (index, block) in layout.blocks.iter().enumerate() {
            if block.span.prompt_rows > 0 {
                prompts.push(self.prompt_text(block));
                where_from.push(index);
            }
        }
        let borrowed: Vec<&str> = prompts.iter().map(String::as_str).collect();
        let records: Vec<blockjoin::Record<'_>> = self
            .records
            .iter()
            .map(|record| {
                blockjoin::Record {
                    ordinal: record.ordinal,
                    command_text: &record.command_text,
                }
            })
            .collect();
        for (ordinal, index) in blockjoin::join(&borrowed, &records).into_iter().zip(where_from) {
            if let Some(slot) = out.get_mut(index) {
                *slot = ordinal;
            }
        }
        out
    }

    /// Where the block wearing `ordinal` sits in the CURRENT layout, or `None` when none does.
    ///
    /// ⚠️ **Resolved at action time on purpose.** A menu stays open for seconds and the layout
    /// indices move underneath it — output re-segments the list, and the fold vector is read
    /// positionally — so a stashed index can fold a block the user never clicked. The ordinal does
    /// not move, which is why it is what the pointer door answers and this is what spends it.
    ///
    /// Zero is not an ordinal: it is "the host attached mid-stream and could not count prompts", so
    /// it names no block rather than the first unjoined one.
    fn layout_index_of_ordinal(&self, ordinal: u32) -> Option<usize> {
        if ordinal == 0 {
            return None;
        }
        self.joined_ordinals(&self.layout)
            .into_iter()
            .position(|found| found == Some(ordinal))
    }

    /// The scrollbar thumb for everything that scrolls under this surface, in device pixels.
    ///
    /// Two things scroll and one thumb reports both: the engine's scrollback, which moves in whole
    /// rows, and the block list's own overflow, which is the chrome the layout spends above each
    /// command. Adding them in pixels is what makes the thumb honest in the two cases a single
    /// source would get wrong — a long scrollback with no chrome, and a short session whose headers
    /// alone push it past the viewport.
    ///
    /// The rows ABOVE the viewport contribute plain rows because they were never laid out; only the
    /// viewport's own slice has chrome, and [`BlockLayout::content_height`] already measured it.
    fn thumb(&self, layout: &BlockLayout, viewport_height: f64, cell_height: f64) -> Option<Thumb> {
        let info = self.session.viewport_info().ok()?;
        let above = f64::from(info.total_rows.saturating_sub(info.viewport_rows)) * cell_height;
        scrollbar(
            above + layout.content_height,
            viewport_height,
            f64::from(info.viewport_top_row) * cell_height + self.scroll_y,
            viewport_height,
            self.chrome_style.scrollbar_min_height * self.geometry.scale,
        )
    }

    /// Clamps [`Self::scroll_y`] into the range this content allows, honouring the bottom pin.
    ///
    /// Answers whether it moved, which is the only reason a caller would lay out again.
    fn settle_scroll(&mut self, content_height: f64, viewport_height: f64) -> bool {
        let wanted = settled_scroll(self.scroll_y, content_height, viewport_height, self.follow_bottom);
        // An exact comparison IS the question — "is this a different number than the one the layout
        // was built with" — not a measurement whose last bits are noise. A tolerance here would
        // re-lay-out for a scroll nobody made, or skip one the user did.
        #[expect(
            clippy::float_cmp,
            reason = "identity, not proximity: did the clamp move the offset at all"
        )]
        let moved = wanted != self.scroll_y;
        self.scroll_y = wanted;
        moved
    }

    /// The on-screen rect of one content-space rect, as the paint pass places it.
    ///
    /// The doors answer SCREEN rects rather than content ones because the client is filling chrome
    /// into the same drawable, and handing it the untranslated rect would put
    /// `insets.top - scroll_y` in two languages — the second copy free to drift by a frame.
    fn on_screen(&self, rect: Rect) -> Rect {
        let insets = self.insets();
        // Divided back to POINTS, because that is the unit every other pointer door on this
        // surface takes and answers — `_mouse`, `_select_press`, `_link_hit`. The layout works in
        // device pixels because the atlas does; the boundary does not, and a caller holding a
        // `CGRect` in one unit and a click in another is the drift this divide removes.
        let scale = if self.geometry.scale > 0.0 {
            self.geometry.scale
        } else {
            1.0
        };
        Rect {
            x: (rect.x + insets.left) / scale,
            y: (rect.y + insets.top - self.scroll_y) / scale,
            width: rect.width / scale,
            height: rect.height / scale,
        }
    }

    /// The engine's current frame, for the readback doors.
    const fn frame(&self) -> &Frame {
        self.session.frame()
    }

    /// The caret's rect in POINTS, as the last draw placed it — `None` when nothing is on screen.
    ///
    /// The rect the CELL occupies rather than the shape the cursor is drawn as, because the one
    /// caller is an input method asking where to hang its candidate window, and a bar cursor's
    /// two-pixel sliver would put the candidate list under the character rather than under the
    /// insertion point. Answered off `self.layout` — the placement the last frame actually used —
    /// so a scrolled-back cursor answers where it is, not where its row would be at scroll zero.
    fn caret_rect(&self) -> Option<Rect> {
        let cursor = self.session.frame().cursor?;
        let block = self
            .layout
            .block_at_row(cursor.y)
            .filter(|block| block.visible.contains(cursor.y))?;
        let cell_height = self.font.cell_height();
        let content_y = block.row_y(cursor.y, cell_height)?;
        // The trailing half of a wide character belongs to the pair's leading edge — the same
        // correction `CellGeometry::cursor` makes, for the same reason.
        let col = if cursor.at_wide_tail {
            cursor.x.saturating_sub(1)
        } else {
            cursor.x
        };
        let cell_width = self.font.cell_width();
        Some(self.on_screen(Rect {
            x: block.body.x + f64::from(col) * cell_width,
            y: content_y,
            width: cell_width,
            height: cell_height,
        }))
    }
}

impl Composition {
    /// The measured composition as the paint pass reads it.
    fn run(&self) -> Preedit<'_> {
        Preedit {
            text: &self.text,
            cells: self.cells,
            cursor_cells: self.cursor_cells,
        }
    }
}

/// Which block a POINT-space `(x, y)` lands in, given the placement each block was drawn at.
///
/// `place` rather than a `&Surface` because the hover resolve inside [`Surface::draw`] runs against
/// the layout the frame is being built from, not the one the last frame left on the handle. One
/// predicate for both is what stops a click and a hover disagreeing about which block they are in.
fn block_at(layout: &BlockLayout, place: impl Fn(Rect) -> Rect, x: f64, y: f64) -> Option<usize> {
    layout.blocks.iter().position(|block| {
        let rect = place(block.frame);
        x >= rect.min_x() && x < rect.max_x() && y >= rect.min_y() && y < rect.max_y()
    })
}

/// The block holding the cursor — the command still producing output.
///
/// The cursor's row rather than "the last block": a program that redraws in place leaves the cursor
/// where it is working, and the newest block is only the same answer while output is appending.
/// A frame with no visible cursor has no running command to mark.
fn active_block(layout: &BlockLayout, frame: &Frame) -> Option<usize> {
    let row = frame.cursor?.y;
    layout
        .blocks
        .iter()
        .position(|block| row >= block.span.rows.start && row < block.span.rows.end)
}

/// A device-pixel measurement, as the whole number the engine's encoders divide by.
///
/// At least one, because a zero cell is what `libghostty-vt`'s geometry documents as forbidden and
/// what would make the pointer's division a NaN. Guards written in the POSITIVE so a NaN falls out
/// as one pixel rather than choosing an arm — `slopdesk_terminal::geometry`'s discipline.
fn round_px(value: f64) -> u32 {
    narrow_u32(value).max(1)
}

/// An `f64` device-pixel measurement as a `u32`, fenced rather than cast.
fn narrow_u32(value: f64) -> u32 {
    if value > 0.0 {
        let fenced = f64::min(value.round(), f64::from(u32::MAX));
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "fenced into 0.0..=u32::MAX by the guard and the min above"
        )]
        let narrowed = fenced as u32;
        narrowed
    } else {
        0
    }
}

/// Borrows a handle for one call, or `None` for the null the doors treat as inert.
///
/// # Safety
/// `handle` must be null, or a pointer from [`slopdesk_term_surface_new`] that has not been freed,
/// with no other call on it in flight. See the module header: "in flight" is trivially satisfied by
/// the main-thread rule, and the rule is what makes the absent lock sound.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference IS this module's boundary"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskTerminalSurface) -> Option<&'a mut Surface> {
    // SAFETY: the caller's obligation above. Non-null implies a live, uniquely-owned allocation
    // from `new`, and the main-thread rule implies no aliasing reference exists.
    match unsafe { handle.as_mut() } {
        Some(held) => held.inner.as_mut(),
        None => None,
    }
}
