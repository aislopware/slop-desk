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

use core::ffi::{c_uchar, c_void};
use core::time::Duration;

use slopdesk_apple_metal::Renderer;
use slopdesk_apple_text::{FontStack, Rasterizer, Shaper};
use slopdesk_terminal::geometry::{CellMetrics, Rect};
use slopdesk_terminal::surface_action::{SelectionEdge, SurfaceAction};
use slopdesk_termrender::{
    BlockLayout, BlockSpan, CellGeometry, Chrome, ChromeFrame, ChromeStyle, DrawList, GlyphCache, Insets,
    LayoutMode, PaintStyle, Painter, Preedit, Rgba, SelectionColors, Thumb, Viewport, chrome, grid_size,
    lay_out, scrollbar, segment,
};
use slopdesk_vterm::input::SurfaceGeometry;
use slopdesk_vterm::{
    Autoscroll, CellFlags, ClickLadder, ClipboardWrite, CopyFormat, CursorShape, Frame, KeyAction, KeyPress,
    Mods, MouseAction, MouseButton, MouseMove, OptionAsAlt, Rgb, Scroll, SearchQuery, SelectionAdjust,
    SurfacePoint, VtSession, key_from_macos_keycode, text_cells,
};

use crate::{borrow, deliver, lent, push_text, records_of, saturating_u32, spill};

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
#[derive(Debug)]
struct Surface {
    /// The engine. Fed bytes, asked for frames.
    session: VtSession,
    /// The faces, and the two traits the paint pass reaches them through.
    font: FontStack,
    /// What [`Self::font`] was built FROM, kept because a `FontStack` does not answer it and a
    /// scale change has to rebuild the stack from the same two inputs. Storing them is what makes
    /// that rebuild reproducible rather than a second call into the config.
    family: String,
    /// The point size [`Self::font`] was built at.
    point_size: f64,
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
    /// Builds a surface on the system default Metal device with `family` at `point_size`.
    ///
    /// `None` when there is no Metal device, when the pipelines will not build, or when Core Text
    /// resolves no face for `family` — each of which is a machine or a configuration this build
    /// cannot draw on, and none of which becomes true a frame later. The caller latches the
    /// refusal.
    fn create(family: &str, point_size: f64, scale: f64, width: f64, height: f64) -> Option<Self> {
        let font = FontStack::new(family, point_size, scale)?;
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
            family: family.to_owned(),
            point_size,
            cache: GlyphCache::default(),
            painter: Painter::new(),
            list: DrawList::default(),
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
            if let Some(font) = FontStack::new(&self.family, self.point_size, scale) {
                self.shaper = font.shaper();
                self.rasterizer = font.rasterizer();
                self.font = font;
                self.cache = GlyphCache::default();
            }
        }
        self.apply_geometry();
        self.session.size()
    }

    /// Rebuilds the face stack at a new family and point size, answering the grid that now fits.
    ///
    /// The rebuild is [`Self::set_geometry`]'s rescale branch with the other two inputs moving
    /// instead of the scale, and for the same reason: the atlas holds coverage masks measured
    /// against ONE face at ONE size, so a new face invalidates every glyph in it. Rebuilding any
    /// subset would pair last size's atlas with this size's shaper.
    ///
    /// A family Core Text cannot resolve leaves the current stack standing rather than refusing to
    /// draw — the honest outcome for a font name the user mistyped in `config.toml`, and the same
    /// one a scale change takes.
    fn set_font(&mut self, family: &str, point_size: f64) -> (u16, u16) {
        // Bit-equality is a CONSERVATIVE test here, not an exact one: an identical pair is
        // certainly unchanged, and a pair that differs by an ulp costs one needless atlas rebuild
        // rather than a wrong frame. The publish this answers fires on every settings write, so the
        // early-out is what keeps an unrelated toggle from re-rasterising the screen.
        #[expect(
            clippy::float_cmp,
            reason = "a conservative unchanged-test, argued immediately above"
        )]
        let unchanged = family == self.family && point_size == self.point_size;
        if unchanged {
            return self.session.size();
        }
        let Some(font) = FontStack::new(family, point_size, self.geometry.scale) else {
            return self.session.size();
        };
        self.shaper = font.shaper();
        self.rasterizer = font.rasterizer();
        self.font = font;
        self.cache = GlyphCache::default();
        family.clone_into(&mut self.family);
        self.point_size = point_size;
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
            chrome::paint(
                &layout,
                &self.chrome_style.scaled(self.geometry.scale),
                &frame,
                &style,
                &mut self.cache,
                &mut self.shaper,
                &mut self.rasterizer,
                &mut self.list,
            );
        }
        self.layout = layout;
        self.renderer
            .draw(&self.list, &mut self.cache, self.background)
            .is_ok()
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

/// Opens a terminal surface, or NULL when this machine cannot draw one.
///
/// `family` is a font family name; `point_size` its size in points and `scale` the view's contents
/// scale, from which every device-pixel number below is derived. `width_points` and `height_points`
/// are the hosting view's bounds.
///
/// # Safety
/// `(family, family_len)` must describe `family_len` live bytes for the call. The answer must be
/// passed to [`slopdesk_term_surface_free`] exactly once, from the main thread.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_new(
    family: *const c_uchar,
    family_len: usize,
    point_size: f64,
    scale: f64,
    width_points: f64,
    height_points: f64,
) -> *mut SlopDeskTerminalSurface {
    // SAFETY: the caller's obligation, restated above.
    let family = unsafe { lent(family, family_len) };
    Surface::create(family, point_size, scale, width_points, height_points)
        .map_or(core::ptr::null_mut(), |surface| {
            Box::into_raw(Box::new(SlopDeskTerminalSurface { inner: Some(surface) }))
        })
}

/// Tears the surface's STATE down — the engine, the atlas, the layer and the device — and leaves
/// the handle valid and inert.
///
/// ⚠️ **Call this the instant the view has let go of the lent layer, and not before.** The layer's
/// drawable source dies here, so a view still hosting it afterwards is hosting a layer with nothing
/// behind it. That ordering is the whole reason `TerminalSurfaceHosting.detachSurface` exists, and
/// the reason this is not folded into [`slopdesk_term_surface_free`]: `deinit` runs when the last
/// reference goes, which may be after the view has been asked to draw again.
///
/// Idempotent. Every other door on a closed handle answers its inert value.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_term_surface_new`] that has not been freed,
/// with no call on it in flight and no drawable outstanding.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_close(handle: *mut SlopDeskTerminalSurface) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(held) = unsafe { handle.as_mut() } {
        drop(held.inner.take());
    }
}

/// Returns the handle's allocation. The state is already gone if
/// [`slopdesk_term_surface_close`] ran; this drops whatever is left.
///
/// ⚠️ **`deinit` and nowhere else** — see [`SlopDeskTerminalSurface`].
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_term_surface_new`] that has not already been
/// freed, with no call on it in flight and no drawable outstanding.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_free(handle: *mut SlopDeskTerminalSurface) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner. Every field's teardown is its own `Drop`.
    drop(unsafe { Box::from_raw(handle) });
}

/// The `CAMetalLayer` to host, LENT — see the module header. NULL for a null handle.
///
/// Swift installs it with `view.layer = layer; view.wantsLayer = true` (`AppKit`) or by returning
/// `CAMetalLayer.self` from `layerClass` and never replacing it (`UIKit`). It must not be released,
/// resized or reconfigured: this handle owns its `drawableSize` and `contentsScale`, and a second
/// writer is the drift [`SlopDeskTerminalSurface::set_geometry`] exists to prevent.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_layer(handle: *mut SlopDeskTerminalSurface) -> *mut c_void {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return core::ptr::null_mut();
    };
    core::ptr::from_ref(surface.renderer.surface().layer())
        .cast::<c_void>()
        .cast_mut()
}

/// Feeds inbound PTY bytes. Never fails and never blocks — `vt_write` is documented total.
///
/// # Safety
/// [`held`]'s, plus `(bytes, len)` describing `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_feed(
    handle: *mut SlopDeskTerminalSurface,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: as above.
    surface.session.feed(unsafe { borrow(bytes, len) });
}

/// Re-measures the view and answers the grid it now fits, packed `cols << 16 | rows`.
///
/// One `u32` rather than two out-parameters because the pair is one answer: a caller that read the
/// columns and then the rows across two calls could straddle a second resize, and the grid it
/// mirrored to the host would be one that never existed. `0` for a null handle.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_geometry(
    handle: *mut SlopDeskTerminalSurface,
    width_points: f64,
    height_points: f64,
    scale: f64,
) -> u32 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let (cols, rows) = surface.set_geometry(width_points, height_points, scale);
    (u32::from(cols) << 16) | u32::from(rows)
}

/// Draws one frame. `false` when there was nowhere to draw, which needs no recovery.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_draw(handle: *mut SlopDeskTerminalSurface) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.draw()
}

/// Sets the pane's WORKSPACE focus, and the blink clock's phase, in one call.
///
/// Together because they are read together — `PaintStyle` carries both and the cursor is the only
/// thing either changes — and because an unfocused surface has no cursor to blink, so a caller that
/// set them separately would be able to describe a state the painter cannot draw.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_focus(
    handle: *mut SlopDeskTerminalSurface,
    focused: bool,
    blink_visible: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.focused = focused;
    surface.blink_visible = blink_visible;
}

/// The theme: the clear colour, the default foreground and the selection fill.
///
/// One door for all three because they are one decision — a theme — and because two of them are
/// read by DIFFERENT owners: the background is the engine's default colour AND the pass's clear
/// colour, and setting only one produces a one-pixel border of the other around every glyph.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_theme(
    handle: *mut SlopDeskTerminalSurface,
    foreground: u32,
    background: u32,
    selection: u32,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    let foreground = rgb(foreground);
    let background = rgb(background);
    let _refused = surface.session.set_default_colors(foreground, background);
    surface.background = background.into();
    surface.selection = SelectionColors {
        background: rgb(selection).into(),
        foreground: None,
    };
}

/// The ANSI palette, as a PREFIX of `0x00RRGGBB` words from index `0`.
///
/// Apart from [`slopdesk_term_surface_set_theme`] because the two have different lifetimes: a theme
/// always states its three colours, and a palette is optional — a config that names none leaves the
/// engine's own 256 standing, which is a different outcome from naming sixteen black ones. Folding
/// them into one door would make "no palette" unspellable.
///
/// A prefix rather than all 256 for [`slopdesk_vterm::VtSession::set_palette`]'s reason: a theme
/// states the sixteen ANSI colours and says nothing about the cube or the ramp. `count` past 256 is
/// ignored past the 256th entry rather than refused.
///
/// # Safety
/// [`held`]'s, plus `entries` being null or describing `count` live `u32` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_palette(
    handle: *mut SlopDeskTerminalSurface,
    entries: *const u32,
    count: usize,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the caller's obligation; `records_of` answers an empty slice for a null pointer.
    let packed = unsafe { records_of(entries, count) };
    let palette: Vec<Rgb> = packed.iter().copied().map(rgb).collect();
    let _refused = surface.session.set_palette(&palette);
}

/// Rebuilds the face stack at `family` and `point_size`, answering the grid it now fits, packed
/// `cols << 16 | rows` exactly as [`slopdesk_term_surface_set_geometry`] does.
///
/// The grid comes BACK rather than being read separately for that door's reason: a font change
/// resizes the cell, so it reflows the grid, and the caller owes the host a `resize` for the new
/// one. `0` for a null handle.
///
/// # Safety
/// [`held`]'s, plus `(family, family_len)` being a live UTF-8 span for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_font(
    handle: *mut SlopDeskTerminalSurface,
    family: *const c_uchar,
    family_len: usize,
    point_size: f64,
) -> u32 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, discharged by the shared span helper.
    let family = unsafe { lent(family, family_len) };
    let (cols, rows) = surface.set_font(family, point_size);
    (u32::from(cols) << 16) | u32::from(rows)
}

/// A `0x00RRGGBB` word as a colour. The high byte is ignored rather than read as alpha: every
/// colour on this door is opaque, and a caller that passed one would get a silently different
/// theme.
const fn rgb(packed: u32) -> Rgb {
    Rgb {
        r: ((packed >> 16) & 0xFF) as u8,
        g: ((packed >> 8) & 0xFF) as u8,
        b: (packed & 0xFF) as u8,
    }
}

/// A `0xAARRGGBB` word as a colour, high byte and all.
///
/// The counterpart to [`rgb`] and deliberately a second function rather than a flag on it: the two
/// answer different questions. A terminal colour is a cell's ink and is opaque by definition, so
/// reading its high byte would be reading a field the caller never filled; chrome is drawn OVER
/// output, and a wash that could not be translucent would not be a wash.
const fn argb(packed: u32) -> Rgba {
    Rgba {
        r: ((packed >> 16) & 0xFF) as u8,
        g: ((packed >> 8) & 0xFF) as u8,
        b: (packed & 0xFF) as u8,
        a: ((packed >> 24) & 0xFF) as u8,
    }
}

/// Scrolls the viewport. `lines` is signed: negative reveals OLDER output.
///
/// `mode` is `0` by rows, `1` by PAGES, `2` to the bottom, `3` to the top — one door because they
/// are one gesture arriving four ways, and four doors would be four places for a caller to combine
/// two of them.
///
/// A page is converted to rows HERE, against the grid this surface last fitted, because that is the
/// only number that can be right: a caller doing the multiplication would be holding a row count
/// that a resize since the last frame has already invalidated.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_scroll(
    handle: *mut SlopDeskTerminalSurface,
    mode: u8,
    lines: i32,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    let (_, rows) = surface.session.size();
    surface.session.scroll(match mode {
        // Saturating rather than wrapping: a page count large enough to overflow is a caller asking
        // for the end of the scrollback, and that is what saturating gives it.
        1 => Scroll::Delta(lines.saturating_mul(i32::from(rows))),
        2 => Scroll::Bottom,
        3 => Scroll::Top,
        _ => Scroll::Delta(lines),
    });
}

/// Encodes one key press to the bytes the far side expects.
///
/// `keycode` is an `AppKit` `NSEvent.keyCode` — a POSITION — which
/// [`key_from_macos_keycode`] turns into the KEY the encoder needs. `0xFFFF` means "no key at all",
/// which is an IME commit: `text` is then the whole event. iOS passes `0xFFFF` for every press, its
/// `UIKey` carrying characters rather than a hardware position.
///
/// Answers §4's byte count, so a caller with a small buffer retries. `0` is a press that encodes to
/// nothing — a modifier on its own, or a press while composing.
///
/// # Safety
/// [`held`]'s, plus `(text, text_len)` describing live bytes for the call and `(out, cap)` being
/// writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_key(
    handle: *mut SlopDeskTerminalSurface,
    keycode: u16,
    action: u8,
    mods: u16,
    consumed_mods: u16,
    text: *const c_uchar,
    text_len: usize,
    composing: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: as above.
    let text = unsafe { lent(text, text_len) };
    let press = KeyPress {
        key: key_from_macos_keycode(keycode),
        action: match action {
            1 => KeyAction::Release,
            2 => KeyAction::Repeat,
            _ => KeyAction::Press,
        },
        mods: Mods::from_bits(mods),
        consumed_mods: Mods::from_bits(consumed_mods),
        text: (!text.is_empty()).then_some(text),
        unshifted: text.chars().next(),
        composing,
    };
    let mut encoded = Vec::new();
    if surface.session.encode_key(&press, &mut encoded).is_err() {
        return 0;
    }
    // SAFETY: as above; `deliver` writes at most `cap`.
    unsafe { deliver(&encoded, out, cap) }
}

/// Encodes one pointer event, or answers `0` when the far side is not tracking the mouse.
///
/// `x`/`y` are in the view's POINTS, top-left origin — the surface scales them, because the scale
/// it would use is the one it drew with and a caller's own copy could be a frame stale.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_mouse(
    handle: *mut SlopDeskTerminalSurface,
    action: u8,
    button: u8,
    mods: u16,
    x: f64,
    y: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let scale = surface.geometry.scale;
    let event = MouseMove {
        action: match action {
            1 => MouseAction::Release,
            2 => MouseAction::Motion,
            _ => MouseAction::Press,
        },
        button: match button {
            0 => Some(MouseButton::Left),
            1 => Some(MouseButton::Right),
            2 => Some(MouseButton::Middle),
            // `255` is a bare motion, which has no button at all. Every other value is a button past
            // the first three, by the one-based index from four the engine names.
            255 => None,
            other => Some(MouseButton::Extra(other)),
        },
        mods: Mods::from_bits(mods),
        x: narrow_f32(x * scale),
        y: narrow_f32(y * scale),
    };
    let mut encoded = Vec::new();
    match surface.session.encode_mouse(&event, &mut encoded) {
        // `false` is the engine saying the far side does not track the mouse, which is a different
        // answer from "it does and this encodes to nothing" — but both leave the caller with no
        // bytes to send, and the caller's next move (fall through to selection) is the same.
        Ok(true) => {
            // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
            unsafe { deliver(&encoded, out, cap) }
        },
        Ok(false) | Err(_) => 0,
    }
}

/// An `f64` point coordinate as the `f32` the engine's encoder takes.
///
/// NaN answered first, because it must not fall out as a coordinate: the encoder would resolve it
/// to a cell rather than refuse it. Same trap `slopdesk_vterm::selection`'s `axis` names.
const fn narrow_f32(value: f64) -> f32 {
    if value.is_nan() {
        return 0.0;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a surface coordinate is orders of magnitude inside f32's range; the NaN case is answered \
                  above"
    )]
    let narrowed = value as f32;
    narrowed
}

/// Sets whether the alt modifier is Alt, per `macos-option-as-alt`. `0` off, `1` both, `2` left,
/// `3` right.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_option_as_alt(
    handle: *mut SlopDeskTerminalSurface,
    value: u8,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.session.set_option_as_alt(match value {
        1 => OptionAsAlt::True,
        2 => OptionAsAlt::Left,
        3 => OptionAsAlt::Right,
        _ => OptionAsAlt::False,
    });
}

/// Caps the scrollback at `lines` rows. Zero or negative keeps none at all.
///
/// LINES rather than bytes, and that is the point of the door: the engine's own limit is a row
/// count, so a client that states one gets exactly what it asked for. The path this replaced spent
/// a 256-byte-per-line ESTIMATE to reach ghostty's byte-only `scrollback-limit`, which meant a user
/// asking for 10 000 lines got somewhere between 5 000 and 40 000 depending on how wide their
/// output happened to be.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_scrollback(
    handle: *mut SlopDeskTerminalSurface,
    lines: i64,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    // `try_from` fails only for a negative, which is the same request as zero: keep nothing.
    let rows = usize::try_from(lines).unwrap_or(0);
    let _ = surface.session.set_scrollback_rows(Some(rows));
}

/// The shape the caret wears until a program asks for another: `0` block, `1` bar, `2` underline,
/// `3` hollow block. Anything else restores the engine's own default.
///
/// A DEFAULT, so `DECSCUSR` from a running program still wins — see
/// [`VtSession::set_default_cursor_shape`] for why that distinction is the whole design.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_cursor_style(
    handle: *mut SlopDeskTerminalSurface,
    style: u8,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    let _ = surface.session.set_default_cursor_shape(match style {
        0 => Some(CursorShape::Block),
        1 => Some(CursorShape::Bar),
        2 => Some(CursorShape::Underline),
        3 => Some(CursorShape::Hollow),
        _ => None,
    });
}

/// Whether the caret blinks until a program says otherwise: `1` on, `2` off, anything else the
/// engine's default.
///
/// Three states rather than a `bool` because the setting genuinely has three: a user who has not
/// chosen leaves the decision to DEC mode 12, and a `bool` would have to invent an answer for them.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_cursor_blink(
    handle: *mut SlopDeskTerminalSurface,
    mode: u8,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    let _ = surface.session.set_default_cursor_blink(match mode {
        1 => Some(true),
        2 => Some(false),
        _ => None,
    });
}

/// The caret's colour until a program overrides it, packed `0x00RRGGBB`. `present` false follows
/// the foreground, which is the engine's own default.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_cursor_color(
    handle: *mut SlopDeskTerminalSurface,
    rgb: u32,
    present: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    // The three shifts cannot overflow a `u8` after the mask, so the truncation is exact.
    let colour = present.then_some(Rgb {
        r: ((rgb >> 16) & 0xFF) as u8,
        g: ((rgb >> 8) & 0xFF) as u8,
        b: (rgb & 0xFF) as u8,
    });
    let _ = surface.session.set_default_cursor_color(colour);
}

/// How solid the caret is drawn, `0.0`–`1.0`. Zero hides it entirely.
///
/// The one cursor setting that never reaches the engine, because no escape sequence can express it
/// — see [`PaintStyle::cursor_opacity`]. Out-of-range and NaN are clamped where the caret is
/// painted, so no value can produce a cursor nobody asked for.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_cursor_opacity(
    handle: *mut SlopDeskTerminalSurface,
    opacity: f64,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.cursor_opacity = opacity;
}

/// The colour the glyph under a filled caret takes, packed `0x00RRGGBB`. `present` false keeps the
/// cell's own background, which is the reading that is always legible.
///
/// A renderer setting for [`slopdesk_term_surface_set_cursor_opacity`]'s reason: no escape sequence
/// names this colour, so unlike the shape, the blink and the caret's own colour there is no engine
/// default for a program to override.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_cursor_text_color(
    handle: *mut SlopDeskTerminalSurface,
    rgb: u32,
    present: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    // The three shifts cannot overflow a `u8` after the mask, so the truncation is exact.
    surface.cursor_text = present.then_some(Rgba {
        r: ((rgb >> 16) & 0xFF) as u8,
        g: ((rgb >> 8) & 0xFF) as u8,
        b: (rgb & 0xFF) as u8,
        a: 0xFF,
    });
}

/// Whether a copy drops the blanks a terminal padded each short line with.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_trim_trailing(
    handle: *mut SlopDeskTerminalSurface,
    trim: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.session.set_trim_selection(trim);
}

/// Forgets any pointer button the encoder was tracking.
///
/// What a surface calls when the pointer leaves mid-drag: without it the encoder still believes a
/// button is down and keeps reporting drag motion the user is no longer making.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_reset_pointer(handle: *mut SlopDeskTerminalSurface) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.session.reset_pointer();
}

// MARK: - Selection

/// Whether the selection stops exactly where the cursor stands, which is the only arrangement in
/// which a cut's backspaces delete the selected text rather than somebody else's.
///
/// Asked of the SURFACE rather than computed by the caller because the surface is the only thing
/// that holds both halves — see [`Frame::selection_ends_at_cursor`]. A client that guessed would be
/// guessing about where a shell put its cursor.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_selection_ends_at_cursor(
    handle: *mut SlopDeskTerminalSurface,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface.session.frame().selection_ends_at_cursor()
}

/// One pointer press against the selection, answering whether the selection changed.
///
/// `time_ms` and the two repeat thresholds are the platform's own click-sequencing numbers
/// (`NSEvent.doubleClickInterval`, and the slop a finger is allowed): the engine's gesture machine
/// owns the LADDER — single is a cell, double a word, triple a line — and this door only tells it
/// what the platform considers one sequence. See `slopdesk-vterm`'s `selection` header for why the
/// ladder is not re-derived here.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_press(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    time_ms: f64,
    repeat_interval_ms: f64,
    repeat_distance: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let scale = surface.geometry.scale;
    surface
        .session
        .select_press(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            millis(time_ms),
            millis(repeat_interval_ms),
            repeat_distance * scale,
            ClickLadder::default(),
        )
        .unwrap_or(false)
}

/// A millisecond count as a [`Duration`], with every value the platform cannot mean answered.
///
/// `Duration::try_from_secs_f64` refuses a negative or a NaN rather than panicking, and zero is the
/// honest fallback: a press whose timestamp did not survive the crossing starts a NEW click
/// sequence instead of joining the previous one, which is a lost double-click rather than a
/// selection the user did not ask for.
fn millis(value: f64) -> Duration {
    Duration::try_from_secs_f64(value / 1000.0).unwrap_or(Duration::ZERO)
}

/// Extends a live selection to `(x, y)`. `rectangle` selects a block (⌥-drag / ⌃V).
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_drag(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let scale = surface.geometry.scale;
    surface
        .session
        .select_drag(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            rectangle,
        )
        .unwrap_or(false)
}

/// Ends the drag, leaving the selection standing.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_select_release(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    let scale = surface.geometry.scale;
    let _refused = surface.session.select_release(SurfacePoint {
        x: x * scale,
        y: y * scale,
    });
}

/// Which way a live selection drag wants the viewport to move: `0` nowhere, `1` up, `2` down.
///
/// Asked by the view's display link, which then calls [`slopdesk_term_surface_select_autoscroll`].
/// Two doors rather than one because the tick needs the pointer's CURRENT position and only the
/// view has it — folding them would mean the engine keeping a copy that a mouse-up could strand.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_autoscroll_direction(
    handle: *mut SlopDeskTerminalSurface,
) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    match surface.session.selection_autoscroll() {
        Ok(Autoscroll::Up) => 1,
        Ok(Autoscroll::Down) => 2,
        Ok(Autoscroll::None) | Err(_) => 0,
    }
}

/// One autoscroll tick with the pointer at `(x, y)`.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_select_autoscroll(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let scale = surface.geometry.scale;
    surface
        .session
        .select_autoscroll_tick(
            SurfacePoint {
                x: x * scale,
                y: y * scale,
            },
            rectangle,
        )
        .unwrap_or(false)
}

/// The selection verbs that take no pointer: `0` clear, `1` select all, `2` has-selection.
///
/// Answers whether anything is selected AFTERWARDS, which makes `2` a read and the other two a
/// write-then-read. One door because the caller — a menu item's enablement, a ⌘A — asks the same
/// question after each, and three doors would be three places to forget it.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_selection_verb(
    handle: *mut SlopDeskTerminalSurface,
    verb: u8,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    match verb {
        1 => drop(surface.session.select_all()),
        2 => {},
        _ => drop(surface.session.clear_selection()),
    }
    surface.session.has_selection().unwrap_or(false)
}

/// The selection as text: `0` plain, `1` with its SGR escapes, `2` as HTML.
///
/// §4's byte count, and `0` for no selection. Soft-wrapped lines are UNWRAPPED and trailing blanks
/// trimmed, which is `slopdesk-vterm`'s decision and not this door's — see its `selection` header
/// for why a copied command that pastes back as two broken ones is the failure that settles it.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_selection_text(
    handle: *mut SlopDeskTerminalSurface,
    format: u8,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let format = match format {
        1 => CopyFormat::Vt,
        2 => CopyFormat::Html,
        _ => CopyFormat::Plain,
    };
    let Ok(Some(text)) = surface.session.selection_text(format) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

// MARK: - Modifier bits

/// The `mods` word [`slopdesk_term_surface_key`] and [`slopdesk_term_surface_mouse`] take, built
/// from what the platform says is held.
///
/// ⚠️ **This door exists so that no modifier BIT is ever spelled in Swift.** The bits are
/// `libghostty_vt`'s `key::Mods`, which is upstream's to renumber; a client that hard-coded them
/// would be a second copy of a layout it does not own, and the failure mode is silent — ⌃C encoding
/// as ⌥C rather than as an error. So the client passes what it actually knows, which is which
/// PHYSICAL keys `AppKit` or `UIKit` reported, and gets back the one word the encoder wants.
///
/// The `right_*` flags say which side a held modifier is on, and are meaningless without the
/// matching held flag. Only `macos-option-as-alt = left|right` reads one, but they cross for every
/// press rather than only when that setting is on: a `mods` word that depended on a config value
/// would be a word the caller could build differently from the one the encoder resolves against.
///
/// Pure — no handle, no state, no failure. A press that holds nothing is `0`.
///
/// Ten `bool`s rather than a packed byte, deliberately: a packed argument would be a bit layout the
/// caller had to know, which is the one thing this door exists to keep on this side.
///
/// # Safety
/// None to honour. The door takes ten `bool`s by value and touches no pointer, so it is `unsafe`
/// only because edition 2024 spells every exported C entry point that way; any call is sound.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_mods(
    shift: bool,
    alt: bool,
    ctrl: bool,
    command: bool,
    caps_lock: bool,
    num_lock: bool,
    right_shift: bool,
    right_alt: bool,
    right_ctrl: bool,
    right_command: bool,
) -> u16 {
    let mut mods = Mods::NONE;
    for (held, bit) in [
        (shift, Mods::SHIFT),
        (alt, Mods::ALT),
        (ctrl, Mods::CTRL),
        (command, Mods::SUPER),
        (caps_lock, Mods::CAPS_LOCK),
        (num_lock, Mods::NUM_LOCK),
        (shift && right_shift, Mods::RIGHT_SHIFT),
        (alt && right_alt, Mods::RIGHT_ALT),
        (ctrl && right_ctrl, Mods::RIGHT_CTRL),
        (command && right_command, Mods::RIGHT_SUPER),
    ] {
        if held {
            mods = mods.union(bit);
        }
    }
    mods.bits()
}

// MARK: - Screen coordinates

/// Where the viewport sits in the screen coordinate space, and where the cursor is in it.
///
/// ```text
/// [u32 total_rows][u32 viewport_top_row][u32 viewport_rows][u32 cols][u32 cursor_col][u32 cursor_row]
/// ```
///
/// One door for six numbers because copy mode reads them together and any two of them from
/// different moments describe a grid that never existed — the argument
/// [`slopdesk_vterm::ViewportInfo`] makes for its own shape, carried across the boundary intact.
///
/// The cursor is in SCREEN rows, not viewport rows: everything else in this blob is screen-space,
/// and mixing one viewport-relative number in would be the kind of seam that reads correct until
/// the user scrolls. A terminal with no visible cursor reports it at the viewport's top-left, which
/// is where copy mode starts when there is nothing better to start from.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_viewport_info(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(info) = surface.session.viewport_info() else {
        return 0;
    };
    let cursor = surface.frame().cursor;
    let mut blob = Vec::with_capacity(24);
    for value in [
        info.total_rows,
        info.viewport_top_row,
        info.viewport_rows,
        u32::from(info.cols),
        u32::from(cursor.map_or(0, |at| at.x)),
        info.viewport_top_row
            .saturating_add(u32::from(cursor.map_or(0, |at| at.y))),
    ] {
        blob.extend_from_slice(&value.to_be_bytes());
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Selects from one SCREEN coordinate to another, replacing whatever was selected.
///
/// Both ends are inclusive and either order; `rectangle` selects a block. Answers whether the
/// engine accepted the range — `false` means an endpoint has scrolled out of the buffer, which is
/// an ordinary outcome for a coordinate the caller held across time.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_selection(
    handle: *mut SlopDeskTerminalSurface,
    anchor_col: u32,
    anchor_row: u32,
    head_col: u32,
    head_row: u32,
    rectangle: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    surface
        .session
        .set_screen_selection(
            (narrow_col(anchor_col), anchor_row),
            (narrow_col(head_col), head_row),
            rectangle,
        )
        .unwrap_or(false)
}

/// One SCREEN row's text, trailing padding trimmed.
///
/// §4's byte count. `0` for a row that is no longer retained AND for a blank one — the two are the
/// same answer to "what text is there", and a caller that needs to tell them apart asks
/// [`slopdesk_term_surface_viewport_info`] for the extent.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_screen_row(
    handle: *mut SlopDeskTerminalSurface,
    row: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(Some(text)) = surface.session.screen_row_text(row) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// The inclusive SCREEN row range of the logical line containing `row`.
///
/// ```text
/// [u32 first][u32 last]
/// ```
///
/// `0` for a row that is no longer retained. A row that is not soft-wrapped answers `row, row`, so
/// the caller never needs a separate "is this wrapped" question.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_line_range(
    handle: *mut SlopDeskTerminalSurface,
    row: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(Some((first, last))) = surface.session.logical_line_range(row) else {
        return 0;
    };
    let mut blob = Vec::with_capacity(8);
    blob.extend_from_slice(&first.to_be_bytes());
    blob.extend_from_slice(&last.to_be_bytes());
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The WHOLE retained buffer as logical lines, oldest first.
///
/// ```text
/// [u32 line_count] line_count × [u32 first_row][u32 last_row][u32 length][UTF-8 bytes]
/// ```
///
/// Each line carries its screen rows because every caller turns a line it matched back into
/// somewhere to SCROLL, and a line's index is not its row — one wrapped line is several rows. A
/// blob without them would make that mapping the client's arithmetic to get wrong, in Swift, which
/// is the wrong side of the boundary for arithmetic.
///
/// ⚠️ This reads the entire scrollback and allocates its text. It is a gesture door — the find
/// bar's row-driven modes and the block extractor — and must never be called per frame.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_logical_lines(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(lines) = surface.session.logical_lines() else {
        return 0;
    };
    let mut blob = Vec::new();
    blob.extend_from_slice(&saturating_u32(lines.len()).to_be_bytes());
    for line in &lines {
        blob.extend_from_slice(&line.first_row.to_be_bytes());
        blob.extend_from_slice(&line.last_row.to_be_bytes());
        push_text(&mut blob, &line.text);
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

// MARK: - The find bar

/// Runs the find bar's query over the whole retained buffer and answers how many hits there are.
///
/// ⚠️ **This door exists because the find bar has four modes and `search:` carries one.** The
/// keybinding verb is a needle and nothing else — a user writing `search:TODO` wants the plain find
/// — so case-sensitivity, whole-word and regex had no way across, and the bar answered them with a
/// SECOND scan of its own over a flat text mirror. Two scans of one buffer meant the `N of M` it
/// printed and the cells the surface lit could disagree. Both routes now end at
/// `VtSession::search_with`; this one just carries the other three flags. See
/// `docs/ui-shell/current-state/terminal-features.md` gap 4.
///
/// The count is the answer rather than a `bool` for the same reason: the bar needs it, and
/// [`slopdesk_term_surface_binding_action`] could only ever say whether something happened.
///
/// An empty needle, or a regex that does not compile, answers `0` and clears the highlight — the
/// two states a find field passes through on the way to a real query, which are not errors.
///
/// # Safety
/// [`held`]'s, plus `(needle, needle_len)` describing `needle_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_find(
    handle: *mut SlopDeskTerminalSurface,
    needle: *const c_uchar,
    needle_len: usize,
    case_sensitive: bool,
    whole_word: bool,
    regex: bool,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `lent` answers "" for anything not valid UTF-8, which is an
    // empty needle and so finds nothing.
    let needle = unsafe { lent(needle, needle_len) };
    let query = SearchQuery::new(needle)
        .case_sensitive(case_sensitive)
        .whole_word(whole_word)
        .regex(regex);
    surface.session.search_with(&query).unwrap_or(0)
}

/// The current hit's position, as the `3 of 17` a find bar prints.
///
/// Answers `false` when nothing is current — no query, or a query with no hits — and writes neither
/// output in that case, so a caller that ignores the answer keeps whatever it had rather than
/// reading a zero as "hit 0 of 0".
///
/// A PULL rather than a return from the navigation verb, which is docs/55 §4's rule for this seam:
/// `navigate_search:` is a keybinding action like any other and answers only whether it moved. The
/// position is read after it, by the one caller that draws a counter.
///
/// # Safety
/// [`held`]'s, plus `current` and `total` each being writable for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_find_position(
    handle: *mut SlopDeskTerminalSurface,
    current: *mut usize,
    total: *mut usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some((at, of)) = surface.session.search_position() else {
        return false;
    };
    if current.is_null() || total.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation; both pointers are non-null and writable for one `usize`.
    unsafe {
        current.write(at);
        total.write(of);
    }
    true
}

// MARK: - Binding actions

/// Performs one keybinding action, spelled by [`SurfaceAction::spell`] on the other side.
///
/// ⚠️ **The client never parses this string and never composes one by hand.**
/// `slopdesk_terminal::surface_action` is the grammar's only home; a spelling this door does not
/// recognise is answered by doing NOTHING and returning `false`, because there is no sound way to
/// guess what a typo meant. That is also why the answer is a `bool` rather than a void: a keystroke
/// that quietly did nothing is the failure mode this seam is built to make visible.
///
/// `false` also means the action was understood and had nothing to do — no prompt in that
/// direction, no selection to adjust, no hit to navigate to. The caller wants the same thing in
/// both cases: leave the key unhandled so something else can have it.
///
/// # Safety
/// [`held`]'s, plus `(action, action_len)` describing `action_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_binding_action(
    handle: *mut SlopDeskTerminalSurface,
    action: *const c_uchar,
    action_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation; `lent` answers "" for anything not valid UTF-8, which then
    // parses to `None` and does nothing.
    let spelling = unsafe { lent(action, action_len) };
    run(&mut surface.session, spelling)
}

/// Parses a spelling and runs it, or answers `false` for one the grammar does not know.
///
/// The door above is pointer discipline, this is the grammar, and [`perform`] is the engine. Three
/// steps rather than one because only the first needs `unsafe` and only the last needs a terminal,
/// so the middle one is where a spelling can be tested against a real session with no surface.
fn run(session: &mut VtSession, spelling: &str) -> bool {
    SurfaceAction::parse(spelling).is_some_and(|action| perform(session, action))
}

/// Runs a parsed action against the engine.
///
/// Split out of the door so it is reachable without a live surface — this is where every decision
/// is, and the door above it is only the pointer discipline.
fn perform(session: &mut VtSession, action: SurfaceAction<'_>) -> bool {
    match action {
        SurfaceAction::Search { needle } => session.search(needle).is_ok(),
        SurfaceAction::NavigateSearch { forward } => session.navigate_search(forward).unwrap_or(false),
        SurfaceAction::EndSearch => session.end_search().is_ok(),
        SurfaceAction::ScrollToRow(row) => {
            session.scroll(Scroll::Row(row));
            true
        },
        SurfaceAction::ScrollLines(delta) => {
            session.scroll(Scroll::Delta(delta));
            true
        },
        SurfaceAction::ScrollFraction(fraction) => {
            let Ok(info) = session.viewport_info() else {
                return false;
            };
            session.scroll(Scroll::Delta(page_lines(fraction, info.viewport_rows)));
            true
        },
        SurfaceAction::ScrollToTop => {
            session.scroll(Scroll::Top);
            true
        },
        SurfaceAction::ScrollToBottom => {
            session.scroll(Scroll::Bottom);
            true
        },
        SurfaceAction::JumpToPrompt(delta) => {
            match session.prompt_row(delta) {
                Ok(Some(row)) => {
                    session.scroll(Scroll::Row(row));
                    true
                },
                // No prompt that way, or the engine could not say. Either way the hop had nowhere to
                // go, and reporting `true` would swallow a key that should fall through.
                _ => false,
            }
        },
        SurfaceAction::AdjustSelection(edge) => {
            let adjust = match edge {
                SelectionEdge::Up => SelectionAdjust::Up,
                SelectionEdge::Down => SelectionAdjust::Down,
                SelectionEdge::Left => SelectionAdjust::Left,
                SelectionEdge::Right => SelectionAdjust::Right,
            };
            session.adjust_selection(adjust).unwrap_or(false)
        },
    }
}

/// How many rows a fractional page motion moves.
///
/// ⚠️ **At least one row, whatever the arithmetic says.** A page fraction of 0.9 over a two-row
/// viewport truncates to 1, but over a ONE-row viewport it truncates to 0 — and a page-down that
/// moves nothing reads as a dead key rather than as a small pane. The floor is the same rule the
/// client applied before this seam moved into Rust, kept here so there is one page-size decision
/// instead of one per platform.
fn page_lines(fraction: f64, viewport_rows: u32) -> i32 {
    let rows = f64::from(viewport_rows) * fraction.abs();
    let magnitude = i32::try_from(narrow_u32(rows.floor())).unwrap_or(i32::MAX).max(1);
    if fraction < 0.0 { -magnitude } else { magnitude }
}

/// A column that crossed the boundary as a `u32`, clamped to the grid's addressable width.
///
/// Saturating rather than truncating: a column of `u32::MAX` is a caller's bug either way, and
/// clamping to the last column selects something visible while a wrapping cast would select
/// column 0 — a silently WRONG selection, which is worse than a clamped one.
fn narrow_col(value: u32) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}

// MARK: - Readback

/// The visible rows as text, for the link and hint overlays.
///
/// ```text
/// [u32 row_count] row_count × [u32 length][UTF-8 bytes]
/// ```
///
/// The rows the OVERLAYS index, which is why they come from the same frame the painter drew and not
/// from a second scan: an underline placed against a row the surface has since scrolled is an
/// underline under the wrong text.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_viewport_rows(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let frame = surface.frame();
    let count = frame.row_count();
    let mut blob = Vec::new();
    blob.extend_from_slice(&u32::from(count).to_be_bytes());
    for index in 0..count {
        push_text(&mut blob, frame.row(index).map_or("", |row| row.text.as_str()));
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The live cell geometry, in POINTS, as the overlays' `TerminalCellMetrics` reads it.
///
/// ```text
/// [f64 cell_width][f64 cell_height][u32 cols][u32 rows][f64 origin_x][f64 origin_y]
/// ```
///
/// Points, not pixels, and this is the ONE door that converts back: an overlay is an AppKit/UIKit
/// view laid out in points, and handing it pixels would put a second contents-scale division in the
/// client. `slopdesk-termrender`'s "every coordinate that leaves this crate is a DEVICE pixel"
/// holds up to here; this door is where the boundary is crossed, once.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_cell_metrics(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let scale = surface.geometry.scale;
    let (cols, rows) = surface.session.size();
    let insets = surface.insets();
    let mut blob = Vec::with_capacity(40);
    blob.extend_from_slice(&(surface.font.cell_width() / scale).to_be_bytes());
    blob.extend_from_slice(&(surface.font.cell_height() / scale).to_be_bytes());
    blob.extend_from_slice(&u32::from(cols).to_be_bytes());
    blob.extend_from_slice(&u32::from(rows).to_be_bytes());
    blob.extend_from_slice(&(insets.left / scale).to_be_bytes());
    blob.extend_from_slice(&(insets.top / scale).to_be_bytes());
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The four flags the client's policy layers ask about, as bits: `1` alternate screen, `2` mouse
/// tracking, `4` viewport at the bottom, `8` DEC bracketed paste (`?2004h`).
///
/// One door because all four are read TOGETHER on the same events — a keystroke, a scroll, a
/// pointer move, a paste — and reading them separately is four chances to act on a mixed state:
/// forwarding a scroll as a mouse report because tracking was read before the alt-screen flip, or
/// skipping the paste-protection sheet on a `?2004h` the program has since turned off.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_modes(handle: *mut SlopDeskTerminalSurface) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    u8::from(surface.session.is_alternate_screen().unwrap_or(false))
        | (u8::from(surface.session.is_mouse_tracking().unwrap_or(false)) << 1)
        | (u8::from(surface.session.is_viewport_at_bottom().unwrap_or(true)) << 2)
        | (u8::from(surface.session.wants_bracketed_paste().unwrap_or(false)) << 3)
}

/// The exact bytes a paste of `(bytes, len)` should put on the pty.
///
/// ## Why a paste is not "write these bytes"
///
/// The engine scrubs the control bytes a payload must never carry into a prompt (NUL, ESC, DEL),
/// turns newlines into carriage returns when the paste is *not* bracketed, and strips any embedded
/// `ESC [ 201 ~` before wrapping — the classic bracketed-paste breakout, where a clipboard that
/// smuggled an end marker closes the block early and injects its tail as live input. Every one of
/// those is a rule about how the FAR side's parser behaves, so it belongs to the engine that owns
/// that parser, and a Swift `"\u{1b}[200~" + text` would be a second, worse paste implementation.
///
/// `bracketed` is the caller's on purpose: three menu items disagree about it. Ordinary **Paste**
/// passes bit `8` of [`slopdesk_term_surface_modes`], **Bracketed Paste** forces `true`, and
/// **Paste as Keystrokes** forces `false` so the payload arrives as if typed.
///
/// ⚠️ This door does NOT write anything, ask anything or consult a setting. The paste-protection
/// decision is the client's (`PastePrecheck`), and it happens BEFORE these bytes are asked for.
///
/// Non-UTF-8 input answers `0`, as does a null handle. Otherwise the two-attempt convention: the
/// return is bytes NEEDED, written when it fits.
///
/// # Safety
/// [`held`]'s, plus `bytes` being null or readable for `len`, and `(out, cap)` writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_encode_paste(
    handle: *mut SlopDeskTerminalSurface,
    bytes: *const c_uchar,
    len: usize,
    bracketed: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `borrow` states its own.
    let Ok(text) = core::str::from_utf8(unsafe { borrow(bytes, len) }) else {
        return 0;
    };
    let Ok(encoded) = surface.session.encode_paste(text, bracketed) else {
        return 0;
    };
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    unsafe { deliver(&encoded, out, cap) }
}

/// Drains the bytes the TERMINAL owes the pty, and empties the queue.
///
/// ⚠️ **The caller must poll this after every [`slopdesk_term_surface_feed`] and write what it
/// finds to the host.** It is not optional and not a feature: `CSI 6n` asks where the cursor is,
/// `CSI c` what the terminal is, `CSI > q` its version, `OSC 10/11/4 ?` its colours, and the engine
/// composes every one of those answers itself and hands it over exactly once, here. A surface that
/// never polls is a terminal that never answers — vim probing for truecolour, tmux for the cursor,
/// a prompt negotiating bracketed paste all block or guess wrong.
///
/// Distinct from [`slopdesk_term_surface_key`]'s answer, which is what the USER typed. Both end up
/// on the same pty and neither can stand in for the other: a keystroke's bytes exist because a
/// person pressed a key, and these exist because a program asked a question.
///
/// The queue is bounded (`slopdesk_vterm::events`), so a surface that stops polling costs bounded
/// memory rather than the process. `0` for a null handle or an empty queue — the common answer.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_take_pty_replies(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // Drained into the surface's own buffer rather than straight out, because the two-attempt
    // convention means a first call that found the caller's buffer too small must still have
    // something to hand over on the second. Emptying the engine's queue into a buffer this handle
    // owns makes the retry an ordinary re-read instead of a lost reply.
    if surface.pty_replies.is_empty() {
        surface.session.take_pty_replies(&mut surface.pty_replies);
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    let needed = unsafe { deliver(&surface.pty_replies, out, cap) };
    if needed <= cap {
        surface.pty_replies.clear();
    }
    needed
}

/// Drains the clipboard writes running programs asked for, as one frame.
///
/// The other push the engine can see and this door does NOT carry: the bell, the OSC-9/777
/// notification, the OSC-9;4 progress report, the OSC 0/2 title and the OSC-7 working directory.
/// Every one of those already arrives as its own wire message from the host, which is the only
/// owner that survives multiclient and the only one that does not re-fire when
/// `TerminalViewModel.attachSurface` replays the retained ring into a rebuilt surface.
/// `slopdesk_vterm::events` carries the whole argument. A clipboard is per-CLIENT, so it is the one
/// with nowhere else to come from.
///
/// The frame, big-endian throughout:
///
/// ```text
/// u16  count
///   u8   target             0 standard · 1 selection · 2 primary
///   u32  length + bytes     the text, `text/plain` where the program offered one
/// ```
///
/// `0` on the common day, which costs one call and no allocation.
///
/// ⚠️ **A write here has NOT been applied.** The door reports what a program ASKED for; whether it
/// reaches a pasteboard is `slopdesk_term_clipboard_write`'s decision, made where the user's
/// `clipboard-write` setting lives. Writing straight from this frame would make "Ask" behave as
/// "Allow" — the exact defect the deleted fork's `write_clipboard_cb` carried before it honoured
/// the flag.
///
/// # Safety
/// [`held`]'s, plus `(out, cap)` being writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_take_clipboard_writes(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // Same retry contract as the pty door: drain into the handle's buffer, and keep it until it has
    // actually been delivered. `has_clipboard_writes` is what keeps the quiet path free of a `Vec`.
    if surface.clipboard_writes.is_empty() && surface.session.has_clipboard_writes() {
        surface.clipboard_writes = encode_clipboard_writes(&surface.session.take_clipboard_writes());
    }
    // SAFETY: the caller's obligation; `deliver` writes at most `cap`.
    let needed = unsafe { deliver(&surface.clipboard_writes, out, cap) };
    if needed <= cap {
        surface.clipboard_writes.clear();
    }
    needed
}

/// The frame [`slopdesk_term_surface_take_clipboard_writes`] documents, built from one drain.
fn encode_clipboard_writes(writes: &[ClipboardWrite]) -> Vec<u8> {
    let mut blob = Vec::new();
    // The queue is capped far below `u16::MAX` in `slopdesk_vterm::events`, so the saturation is a
    // proof obligation discharged rather than a case that can arise.
    blob.extend_from_slice(&u16::try_from(writes.len()).unwrap_or(u16::MAX).to_be_bytes());
    for write in writes {
        blob.push(write.target.code());
        push_text(&mut blob, &write.text);
    }
    blob
}

/// Where one block sits on screen, and what a header drawn over it would be heading.
///
/// Every rect is in DEVICE pixels, already carrying the insets and the block scroll — the same
/// transform the paint pass applied to the rows below it, computed once on this side. `paint.rs`'s
/// "What this pass does NOT draw" is the contract this record completes: the renderer places the
/// chrome, the client fills it in its own design language.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalBlock {
    /// Left edge of the whole block.
    pub x: f64,
    /// Top edge of the whole block, header included.
    pub y: f64,
    /// Width of the whole block.
    pub width: f64,
    /// Height of the whole block, header included.
    pub height: f64,
    /// Left edge of the header. Meaningless without `has_header`.
    pub header_x: f64,
    /// Top edge of the header.
    pub header_y: f64,
    /// Width of the header.
    pub header_width: f64,
    /// Height of the header.
    pub header_height: f64,
    /// Left edge of the rows, which is the block's left edge plus the gutter.
    pub body_x: f64,
    /// Top edge of the rows.
    pub body_y: f64,
    /// Width of the rows.
    pub body_width: f64,
    /// Height of the rows a collapse left standing.
    pub body_height: f64,
    /// Whether the header rect means anything. False for an ORPHAN — output whose command has
    /// scrolled off the viewport, which has no command to head.
    pub has_header: bool,
    /// Whether the user folded this block down to its prompt.
    pub collapsed: bool,
    /// Whether the viewport touches this block at all, and so whether its rows were resolved.
    pub visible: bool,
    /// First frame row the block covers.
    pub first_row: u16,
    /// One past the last frame row it covers.
    pub end_row: u16,
    /// How many of those rows are the prompt itself — what a collapse keeps.
    pub prompt_rows: u16,
}

/// What a scrollbar over the block list measures against.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalBlockScroll {
    /// How far the list has scrolled, in device pixels.
    pub scroll_y: f64,
    /// How tall the whole list is, chrome included.
    pub content_height: f64,
    /// How much of it fits.
    pub viewport_height: f64,
    /// Whether the list is pinned to its bottom, so new output stays on screen.
    pub following: bool,
}

/// The client's design for the block furniture: six colours and five lengths.
///
/// Colours are `0xAARRGGBB` — the one place on this surface where the high byte IS alpha. A cell's
/// ink is opaque by definition, so [`rgb`] drops it; a hover wash and a scrollbar thumb are
/// translucent BY DESIGN, and folding them into an opaque word plus a separate float would let a
/// caller state a colour and a transparency that disagree.
///
/// Lengths are POINTS, like every other length crossing this boundary, and are scaled where the
/// design is turned into pixels — once, in [`Surface::draw`].
///
/// [`Default`] is every field zero, which is a whole design that draws nothing: `Rgba::CLEAR` for
/// each colour and a zero thickness for each length. That is what a surface shows before an
/// appearance is installed, and it is also exactly [`ChromeStyle::NONE`].
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskTerminalChromeStyle {
    /// The hairline between one block and the next.
    pub divider: u32,
    /// The bar down a block's leading edge, at rest.
    pub gutter: u32,
    /// The same bar for the block holding the cursor.
    pub gutter_active: u32,
    /// The wash over the block the pointer is inside.
    pub hover: u32,
    /// The collapse mark and its folded-row count.
    pub label: u32,
    /// The scrollbar thumb.
    pub scrollbar: u32,
    /// How thick the divider is, in points.
    pub divider_thickness: f64,
    /// How wide the gutter bar is, in points.
    pub gutter_thickness: f64,
    /// How wide the thumb is, in points.
    pub scrollbar_thickness: f64,
    /// How short the thumb may get, in points.
    pub scrollbar_min_height: f64,
    /// The gap between the thumb and the trailing edge, in points.
    pub scrollbar_inset: f64,
}

impl SlopDeskTerminalChromeStyle {
    /// This design in device pixels, which is the only unit the renderer has.
    fn scaled(self, scale: f64) -> ChromeStyle {
        ChromeStyle {
            divider: argb(self.divider),
            divider_thickness: self.divider_thickness * scale,
            gutter: argb(self.gutter),
            gutter_active: argb(self.gutter_active),
            gutter_thickness: self.gutter_thickness * scale,
            hover: argb(self.hover),
            label: argb(self.label),
            scrollbar: argb(self.scrollbar),
            scrollbar_thickness: self.scrollbar_thickness * scale,
            scrollbar_min_height: self.scrollbar_min_height * scale,
            scrollbar_inset: self.scrollbar_inset * scale,
        }
    }
}

/// Installs the design the block furniture is drawn with. By value, because it is one decision.
///
/// One door and not eleven for [`slopdesk_term_surface_set_theme`]'s reason: a divider colour with
/// last frame's gutter thickness is a state the client never described, and a door per field is a
/// door per chance to leave the surface in one.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_chrome_style(
    handle: *mut SlopDeskTerminalSurface,
    style: SlopDeskTerminalChromeStyle,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.chrome_style = style;
}

/// Where the pointer is, in POINTS, so the block under it can take the hover wash.
///
/// `inside` is how "nowhere" is spelled, rather than a sentinel coordinate: a surface the pointer
/// has left is a different state from one it is hovering at the origin, and `(0, 0)` is a real
/// point inside the first block.
///
/// A POSITION rather than a block index — see [`Surface::hover`] for why an index the client held
/// would light the wrong block the moment output arrived.
///
/// Answers whether the next frame would DIFFER, which is the only reason the client asked. A
/// pointer gliding inside one block delivers a move event per sample and changes no pixel, and a
/// caller that presented on each of them would pay a full render — engine frame, layout, both paint
/// passes, GPU — for a picture identical to the one already on screen. The test belongs here rather
/// than in the client because it is a hit-test against the layout, and the layout is here; the
/// answer is over the LAST draw's, which is exactly the picture the caller would be re-presenting.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_hover(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
    inside: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let wanted = inside.then_some((x, y));
    let hit = |point: Option<(f64, f64)>| {
        point.and_then(|(x, y)| block_at(&surface.layout, |rect| surface.on_screen(rect), x, y))
    };
    let changed = hit(wanted) != hit(surface.hover);
    surface.hover = wanted;
    changed
}

/// Copies the last draw's block placements out, answering the count NEEDED.
///
/// Empty before the first draw and on the alternate screen, where `Chrome::NONE` collapses the
/// whole viewport into one headerless block: a fullscreen TUI owns every row it was given, and
/// drawing chrome over it would be drawing over the program.
///
/// # Safety
/// [`held`]'s obligation, plus `out` being null or writable for `cap` records.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_blocks(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut SlopDeskTerminalBlock,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let records: Vec<SlopDeskTerminalBlock> = surface
        .layout
        .blocks
        .iter()
        .map(|block| {
            let frame = surface.on_screen(block.frame);
            let header = block.header.map(|rect| surface.on_screen(rect));
            let body = surface.on_screen(block.body);
            SlopDeskTerminalBlock {
                x: frame.x,
                y: frame.y,
                width: frame.width,
                height: frame.height,
                header_x: header.map_or(0.0, |rect| rect.x),
                header_y: header.map_or(0.0, |rect| rect.y),
                header_width: header.map_or(0.0, |rect| rect.width),
                header_height: header.map_or(0.0, |rect| rect.height),
                body_x: body.x,
                body_y: body.y,
                body_width: body.width,
                body_height: body.height,
                has_header: header.is_some(),
                collapsed: block.collapsed,
                visible: block.is_visible(),
                first_row: block.span.rows.start,
                end_row: block.span.rows.end,
                prompt_rows: block.span.prompt_rows,
            }
        })
        .collect();
    // SAFETY: `out` is null or writable for `cap` records, and `records` was built inside this
    // call.
    unsafe { spill(&records, out, cap) }
}

/// Reads the block list's scroll position, for a scrollbar and for a follow indicator.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_block_scroll(
    handle: *mut SlopDeskTerminalSurface,
) -> SlopDeskTerminalBlockScroll {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return SlopDeskTerminalBlockScroll::default();
    };
    let insets = surface.insets();
    // Points, for `on_screen`'s reason: a scrollbar sized in device pixels beside a rect in points
    // would draw at half height on every Retina display.
    let scale = if surface.geometry.scale > 0.0 {
        surface.geometry.scale
    } else {
        1.0
    };
    SlopDeskTerminalBlockScroll {
        scroll_y: surface.scroll_y / scale,
        content_height: surface.layout.content_height / scale,
        viewport_height: (surface.geometry.height - insets.top - insets.bottom) / scale,
        following: surface.follow_bottom,
    }
}

/// Which block a point lands in, or `-1` for none. In POINTS, like every other pointer door.
///
/// The whole block, not just its header: the same hit answers a click on a header, a right-click
/// anywhere in a block's output, and a drag that starts inside one.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_block_at_point(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return -1;
    };
    block_at(&surface.layout, |rect| surface.on_screen(rect), x, y)
        .and_then(|index| i64::try_from(index).ok())
        .unwrap_or(-1)
}

/// Folds a block down to its prompt, or unfolds it. Answers what the block's state now is.
///
/// An index past the list still records the flag, because the collapse vector is read positionally
/// and a block that has not been laid out yet is one the next frame will place. Refusing here would
/// lose a collapse the user asked for during a resize.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_block_collapsed(
    handle: *mut SlopDeskTerminalSurface,
    index: usize,
    collapsed: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    if index >= surface.collapsed.len() {
        surface.collapsed.resize(index.saturating_add(1), false);
    }
    if let Some(slot) = surface.collapsed.get_mut(index) {
        *slot = collapsed;
    }
}

/// Flips one block's fold and answers its new state. `false` for a block the layout cannot fold —
/// an orphan, which would have nothing left.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_toggle_block_collapsed(
    handle: *mut SlopDeskTerminalSurface,
    index: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    // An orphan refuses the fold in `lay_out` anyway; refusing HERE too is what keeps the flag and
    // the drawing from disagreeing about a block the user clicked.
    if surface
        .layout
        .blocks
        .get(index)
        .is_some_and(|block| block.span.is_orphan())
    {
        return false;
    }
    let wanted = !surface.collapsed.get(index).copied().unwrap_or(false);
    if index >= surface.collapsed.len() {
        surface.collapsed.resize(index.saturating_add(1), false);
    }
    if let Some(slot) = surface.collapsed.get_mut(index) {
        *slot = wanted;
    }
    wanted
}

/// Drops every fold — the "expand all" verb, and what a reset owes the block list.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_expand_all_blocks(handle: *mut SlopDeskTerminalSurface) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(surface) = unsafe { held(handle) } {
        surface.collapsed.clear();
    }
}

/// The wheel and the trackpad: scrolls by POINTS, spending the block chrome first.
///
/// A separate verb from [`slopdesk_term_surface_scroll`]'s lines and pages because the granularity
/// is genuinely different, and the spill rule only makes sense at this one. The chrome makes the
/// list taller than the viewport, so the first pixels of an upward scroll uncover a header rather
/// than a row; only once the list is at its top does the rest reach the engine's scrollback, in
/// whole rows. Going the other way, arriving at the bottom takes the follow pin back.
///
/// Positive `delta` scrolls toward older output, matching a natural-direction wheel.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_scroll_points(
    handle: *mut SlopDeskTerminalSurface,
    delta: f64,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    if !delta.is_finite() || delta == 0.0 {
        return;
    }
    let insets = surface.insets();
    let viewport_height = surface.geometry.height - insets.top - insets.bottom;
    let limit = f64::max(surface.layout.content_height - viewport_height, 0.0);
    // Into the layout's unit, which is the atlas's: the gesture arrives in points because every
    // other pointer door takes points.
    let delta = delta
        * if surface.geometry.scale > 0.0 {
            surface.geometry.scale
        } else {
            1.0
        };
    // Up is toward the top of the list, which is `scroll_y` DECREASING — so a positive delta,
    // which means "show me older output", spends the offset downward first.
    let wanted = surface.scroll_y - delta;
    let clamped = f64::min(f64::max(wanted, 0.0), limit);
    let spill_px = wanted - clamped;
    surface.scroll_y = clamped;
    surface.follow_bottom = clamped >= limit;

    // What the chrome could not absorb becomes engine rows. Whole rows only: the engine's viewport
    // has no sub-row position, and rounding here rather than accumulating a remainder is what keeps
    // one flick from drifting the two scrolls apart.
    let cell_height = surface.font.cell_height();
    let rows = spill_rows(spill_px, cell_height);
    if rows != 0 {
        surface.session.scroll(Scroll::Delta(rows));
    }
}

/// The text of one block's prompt rows, which is what a header prints.
///
/// The rows AS RENDERED, so a shell that decorates its prompt sends that decoration too: OSC 133
/// `A` marks where a prompt begins and `B` where the command does, but only the first crosses the
/// engine's per-row API, so this side cannot cut the two apart. A header wanting the bare command —
/// with its exit code and duration — reads the command-block ring instead; this door is what a
/// header can always answer, including for a block the ring never saw.
///
/// Answers §4's byte count, so a caller with a small buffer retries.
///
/// # Safety
/// [`held`]'s obligation, plus `(out, cap)` being writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_block_text(
    handle: *mut SlopDeskTerminalSurface,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Some(block) = surface.layout.blocks.get(index) else {
        return 0;
    };
    let frame = surface.frame();
    let start = block.span.rows.start;
    let end = start.saturating_add(block.span.prompt_rows);
    let mut text = String::new();
    let mut joined = false;
    for row in start..end {
        let Some(line) = frame.row(row) else { continue };
        // A wrapped prompt is ONE logical line the engine happened to break, so it rejoins without
        // a separator — the same rule the selection's logical lines are read by.
        if joined {
            text.push('\n');
        }
        text.push_str(line.text.trim_end());
        joined = !line.wrapped;
    }
    // SAFETY: `out` is null or writable for `cap` bytes, and `text` was built inside this call.
    unsafe { deliver(text.as_bytes(), out, cap) }
}

/// One whole-number scroll count as the `i32` the engine takes, or `None` when it will not fit.
///
/// A flick large enough to overflow is one asking for the end of the scrollback, and the engine
/// clamps there anyway — but converting through a saturating cast would turn a NaN into a real
/// scroll, so the refusal is explicit.
/// The OSC 8 hyperlink URI at one viewport cell, or nothing when that cell carries no link.
///
/// Answers §4's byte count, so a caller with a small buffer retries; `0` means no link, which is
/// the common answer and costs no allocation on either side.
///
/// The frame's own `CellFlags::HYPERLINK` is the fast path, and it is checked FIRST: a pointer
/// moving across ordinary text asks this door once per cell, and every one of those answers without
/// touching the engine. The URI itself is not in the frame because one link's URI is shared by
/// every cell of its run, and carrying it per cell would allocate a URL per character per frame.
///
/// This is the AUTHORED link — what a program declared with OSC 8 — and it is a different question
/// from the detected one `slopdesk-terminal`'s `link` scanner answers over plain text. A cell can
/// have both; the authored URI wins, because the program said what it meant.
///
/// # Safety
/// [`held`]'s obligation, plus `(out, cap)` being writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_hyperlink_at(
    handle: *mut SlopDeskTerminalSurface,
    column: u16,
    row: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // The frame answers first, and for a pointer over ordinary text it is the whole answer.
    let linked = surface
        .frame()
        .row(row)
        .and_then(|line| line.cells.get(usize::from(column)))
        .is_some_and(|cell| cell.flags.contains(CellFlags::HYPERLINK));
    if !linked {
        return 0;
    }
    // An engine error here is a cell that cannot be resolved — a coordinate off the viewport, or a
    // terminal mid-resize — and "no link" is the honest answer to both.
    let uri = surface
        .session
        .hyperlink_at(column, u32::from(row))
        .ok()
        .flatten()
        .unwrap_or_default();
    // SAFETY: `out` is null or writable for `cap` bytes, and `uri` was built inside this call.
    unsafe { deliver(uri.as_bytes(), out, cap) }
}

/// One run of cells a program declared as an `OSC 8` hyperlink.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskTerminalLinkSpan {
    /// The viewport row the run sits on, counted from the top.
    pub row: u16,
    /// First linked column.
    pub start: u16,
    /// One past the last linked column.
    pub end: u16,
}

/// Every authored hyperlink run in the viewport, answering §4's count.
///
/// What the hover underline needs, and the reason it is a LIST door rather than the per-cell
/// [`slopdesk_term_surface_hyperlink_at`]: an overlay draws every link at once, so asking cell by
/// cell would be `rows × cols` calls across the boundary for a picture that changes on every frame.
/// This walks the frame's `CellFlags::HYPERLINK` once and allocates nothing per link.
///
/// Two different links that touch with no character between them arrive as one span — see
/// [`Frame::hyperlink_spans`] for why that is the right answer for something drawing an underline.
///
/// # Safety
/// [`held`]'s obligation, plus `out` being null or writable for `cap` records.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_hyperlink_spans(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut SlopDeskTerminalLinkSpan,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    let spans: Vec<SlopDeskTerminalLinkSpan> = surface
        .frame()
        .hyperlink_spans()
        .into_iter()
        .map(|(row, span)| {
            SlopDeskTerminalLinkSpan {
                row,
                start: span.start,
                end: span.end,
            }
        })
        .collect();
    // SAFETY: `out` is null or writable for `cap` records, and `spans` was built inside this call.
    unsafe { spill(&spans, out, cap) }
}

/// The text an input method is composing over the cursor, or nothing at all when `len` is zero.
///
/// ## Why the composition never reaches the engine
///
/// Because nothing has been typed yet. An input method may replace the whole run on the next
/// keystroke — Telex turns `Tieengs` into `Tiếng` by rewriting what it already showed — and text
/// fed to the engine is on the grid for good. So the surface DRAWS the composition over the cells
/// the cursor stands on and the grid never changes; when the input method commits, the ordinary key
/// path sends the finished text and this door is cleared.
///
/// `cursor_bytes` is where the composition's own caret sits, as a UTF-8 offset into `text`. A BYTE
/// offset rather than a cell count because measuring cells is this side's job — `docs/68` §10's
/// rule that a number a door needs is the door's to derive, not the view's. An offset that is not a
/// character boundary, or is past the end, reads as a caret at the end: an input method that
/// reported one is reporting a composition it has finished moving through.
///
/// Answers whether the next frame would DIFFER, [`slopdesk_term_surface_set_hover`]'s convention:
/// an input method re-reports an unchanged composition on every arrow key, and a caller that
/// presented on each would pay a full render for an identical picture.
///
/// # Safety
/// [`held`]'s obligation, plus `(text, len)` describing `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_marked_text(
    handle: *mut SlopDeskTerminalSurface,
    text: *const c_uchar,
    len: usize,
    cursor_bytes: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation, restated above.
    let composing = unsafe { lent(text, len) };
    let wanted = if composing.is_empty() {
        None
    } else {
        let cells = text_cells(composing);
        // `get` refuses a non-boundary rather than panicking, and the whole string is the honest
        // fallback: the caret sits after everything the input method has composed.
        let head = composing.get(..cursor_bytes).unwrap_or(composing);
        Some(Composition {
            cursor_cells: text_cells(head).min(cells),
            text: composing.to_owned(),
            cells,
        })
    };
    let changed = match (&wanted, &surface.composing) {
        (None, None) => false,
        (Some(next), Some(held)) => next.text != held.text || next.cursor_cells != held.cursor_cells,
        _ => true,
    };
    surface.composing = wanted;
    changed
}

/// The caret's cell in POINTS, so an input method can hang its candidate window under it.
///
/// `false` — and `out` untouched — when there is no cursor on screen: a collapsed block, a frame
/// before the first draw, or a program that hid it. The caller then places its candidate window
/// wherever the platform's default is, which is the honest outcome for "the insertion point is not
/// visible" and better than a rect pointing at the origin.
///
/// The four values are written in order: `x`, `y`, `width`, `height`, in the same top-left POINT
/// space every other pointer door on this surface takes.
///
/// # Safety
/// [`held`]'s obligation, plus `out` being null or writable for four `f64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_caret_rect(
    handle: *mut SlopDeskTerminalSurface,
    out: *mut f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(rect) = surface.caret_rect() else {
        return false;
    };
    // SAFETY: `out` is null or writable for four `f64`, and the values were built in this call.
    unsafe { spill(&[rect.x, rect.y, rect.width, rect.height], out, 4) == 4 }
}

/// Where the block list's scroll belongs, given how tall it turned out and whether it is pinned.
///
/// A free function rather than a method because it is the whole rule — the clamp AND the pin — and
/// the surface it would sit on cannot be built without a Metal device, which is the one thing the
/// tests in this file may not take.
fn settled_scroll(current: f64, content_height: f64, viewport_height: f64, follow: bool) -> f64 {
    let limit = f64::max(content_height - viewport_height, 0.0);
    if follow {
        return limit;
    }
    f64::min(f64::max(current, 0.0), limit)
}

/// One whole-number scroll count as the `i32` the engine takes, or `None` when it will not fit.
/// The engine rows a flick's leftover pixels buy, SIGNED the way the engine reads them.
///
/// `spill` carries the sign the chrome could not spend, and [`Scroll::Delta`] reads negative as
/// "into the scrollback" — the same direction a positive wheel delta asked for. The two halves of
/// one flick therefore share a sign, and no negation belongs here: negating would make a single
/// continuous gesture reverse the moment the block list ran out of offset to give.
///
/// Whole rows only, truncated rather than rounded: the engine's viewport has no sub-row position,
/// and half a row of overshoot per callback is what drifts the two scrolls apart.
fn spill_rows(spill: f64, cell_height: f64) -> i32 {
    if spill == 0.0 || cell_height <= 0.0 {
        return 0;
    }
    num_to_i32((spill / cell_height).trunc()).unwrap_or(0)
}

fn num_to_i32(value: f64) -> Option<i32> {
    if !value.is_finite() {
        return None;
    }
    let fenced = value.trunc().clamp(f64::from(i32::MIN), f64::from(i32::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        reason = "fenced into i32::MIN..=i32::MAX by the clamp above, and already whole"
    )]
    Some(fenced as i32)
}

#[cfg(test)]
mod block_scroll_tests {
    use super::{num_to_i32, settled_scroll, spill_rows};

    /// The float comparison this file's neighbours use — `slopdesk-termrender`'s block tests assert
    /// the same way, because these are exact arithmetic on whole pixels and an epsilon is the
    /// clippy-shaped spelling of `==`, not a tolerance anyone needs.
    fn is(had: f64, want: f64) {
        assert!((had - want).abs() < f64::EPSILON, "had {had}, wanted {want}");
    }

    #[test]
    fn a_flick_past_the_top_keeps_going_older_in_the_engine() {
        // The bug this pins: the block list absorbs "older" by DECREASING its offset, so what
        // spills out the top is negative — and `Scroll::Delta` spells older negative too. A
        // negation anywhere in that chain makes one flick reverse at the seam.
        assert_eq!(spill_rows(-42.0, 14.0), -3);
        // And the far end: overshooting the bottom spills toward the newest row.
        assert_eq!(spill_rows(42.0, 14.0), 3);
        // Less than a row buys nothing, and a degenerate cell height cannot divide.
        assert_eq!(spill_rows(-13.0, 14.0), 0);
        assert_eq!(spill_rows(-42.0, 0.0), 0);
        assert_eq!(spill_rows(0.0, 14.0), 0);
        // Not finite, not a row count.
        assert_eq!(spill_rows(f64::NAN, 14.0), 0);
    }

    #[test]
    fn a_list_that_fits_has_nowhere_to_scroll() {
        is(settled_scroll(0.0, 400.0, 900.0, false), 0.0);
        // Following a list shorter than its viewport still means the top.
        is(settled_scroll(0.0, 400.0, 900.0, true), 0.0);
    }

    #[test]
    fn the_chrome_overflow_is_exactly_what_can_be_scrolled() {
        // Nine hundred pixels of drawable holding a thousand of blocks: the hundred the headers and
        // gaps added is the whole scroll range, and the grid keeps every row it was sized for.
        is(settled_scroll(0.0, 1000.0, 900.0, true), 100.0);
        is(settled_scroll(40.0, 1000.0, 900.0, false), 40.0);
    }

    #[test]
    fn an_offset_past_the_end_is_clamped_rather_than_kept() {
        // What a collapse does: the list shrinks under a scroll that was valid a frame ago.
        is(settled_scroll(500.0, 1000.0, 900.0, false), 100.0);
        is(settled_scroll(-20.0, 1000.0, 900.0, false), 0.0);
    }

    #[test]
    fn the_pin_moves_the_offset_as_the_list_grows() {
        let after_one_command = settled_scroll(100.0, 1000.0, 900.0, true);
        // New output stays on screen without the user chasing it.
        is(settled_scroll(after_one_command, 1200.0, 900.0, true), 300.0);
    }

    #[test]
    fn a_scroll_count_is_whole_and_fenced() {
        assert_eq!(num_to_i32(3.9), Some(3));
        assert_eq!(num_to_i32(-3.9), Some(-3));
        assert_eq!(num_to_i32(f64::INFINITY), None);
        assert_eq!(num_to_i32(f64::NAN), None);
        assert_eq!(
            num_to_i32(1e30),
            Some(i32::MAX),
            "a flick past the scrollback asks for its end, which is what the clamp gives"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ⚠️ NO TEST HERE OPENS A SURFACE, and that is the hang-safety rule rather than an omission:
    // `Renderer::new` takes the system default Metal device, which under `swift test` / a headless
    // `cargo test` is either absent or a software device that blocks on `nextDrawable`. What CAN be
    // tested is every pure conversion the doors do around it, and each of those is a real defect
    // this file would otherwise own alone.

    #[test]
    #[expect(
        unsafe_code,
        reason = "asserting the null contract means CALLING the doors, which are unsafe by definition"
    )]
    fn a_null_handle_is_inert_at_every_door() {
        // The one property every door shares, asserted once: a failed `new` must not become a crash
        // in `deinit`, so NULL answers rather than dereferences.
        let null: *mut SlopDeskTerminalSurface = core::ptr::null_mut();
        let mut out = [0_u8; 8];
        // SAFETY: a null handle is explicitly legal at every door.
        unsafe {
            slopdesk_term_surface_free(null);
            slopdesk_term_surface_feed(null, out.as_ptr(), 0);
            slopdesk_term_surface_set_focus(null, true, true);
            slopdesk_term_surface_set_theme(null, 0, 0, 0);
            slopdesk_term_surface_scroll(null, 0, 1);
            slopdesk_term_surface_set_option_as_alt(null, 1);
            slopdesk_term_surface_select_release(null, 0.0, 0.0);
            assert!(slopdesk_term_surface_layer(null).is_null());
            assert!(!slopdesk_term_surface_draw(null));
            assert_eq!(slopdesk_term_surface_set_geometry(null, 100.0, 100.0, 2.0), 0);
            assert_eq!(
                slopdesk_term_surface_key(null, 0, 0, 0, 0, out.as_ptr(), 0, false, out.as_mut_ptr(), 8),
                0
            );
            assert_eq!(
                slopdesk_term_surface_mouse(null, 0, 0, 0, 0.0, 0.0, out.as_mut_ptr(), 8),
                0
            );
            assert!(!slopdesk_term_surface_select_press(null, 0.0, 0.0, 0.0, 0.5, 3.0));
            assert!(!slopdesk_term_surface_select_drag(null, 0.0, 0.0, false));
            assert!(!slopdesk_term_surface_select_autoscroll(null, 0.0, 0.0, false));
            assert_eq!(slopdesk_term_surface_autoscroll_direction(null), 0);
            assert!(!slopdesk_term_surface_selection_verb(null, 1));
            assert_eq!(
                slopdesk_term_surface_selection_text(null, 0, out.as_mut_ptr(), 8),
                0
            );
            assert_eq!(slopdesk_term_surface_viewport_rows(null, out.as_mut_ptr(), 8), 0);
            assert_eq!(slopdesk_term_surface_cell_metrics(null, out.as_mut_ptr(), 8), 0);
            assert_eq!(slopdesk_term_surface_modes(null), 0);
            assert_eq!(slopdesk_term_surface_viewport_info(null, out.as_mut_ptr(), 8), 0);
            assert!(!slopdesk_term_surface_set_selection(null, 0, 0, 0, 0, false));
            assert_eq!(slopdesk_term_surface_screen_row(null, 0, out.as_mut_ptr(), 8), 0);
            assert_eq!(slopdesk_term_surface_line_range(null, 0, out.as_mut_ptr(), 8), 0);
            assert_eq!(slopdesk_term_surface_logical_lines(null, out.as_mut_ptr(), 8), 0);
            assert!(!slopdesk_term_surface_binding_action(null, out.as_ptr(), 0));
        }
    }

    /// The executor, driven through the real grammar with no surface — the whole point of splitting
    /// [`perform`] out of the door is that every decision it makes is reachable without Metal.
    mod actions {
        #![expect(
            clippy::unwrap_used,
            reason = "a panic in a test is the failure report, not a runtime fault"
        )]

        use slopdesk_terminal::surface_action::{SelectionEdge, SurfaceAction};
        use slopdesk_vterm::VtSession;

        use super::super::{page_lines, perform, run};

        fn session() -> VtSession {
            let mut vt = VtSession::new(8, 3, 20, 40).unwrap();
            vt.feed(b"\x1b]133;A\x07one\r\nfill\r\n\x1b]133;A\x07two\r\nfill\r\nthree\r\n");
            vt
        }

        /// ⚠️ The failure this seam exists to prevent: a spelling nobody recognises must be
        /// answered by doing NOTHING, and must SAY it did nothing.
        #[test]
        fn an_unknown_spelling_does_nothing_and_admits_it() {
            let mut vt = session();
            let before = vt.viewport_info().unwrap();
            assert!(!run(&mut vt, "scroll_page_lines"));
            assert!(!run(&mut vt, "teleport:3"));
            assert!(!run(&mut vt, ""));
            assert_eq!(vt.viewport_info().unwrap(), before);
        }

        #[test]
        fn the_scroll_verbs_move_the_viewport() {
            let mut vt = session();
            assert!(run(&mut vt, "scroll_to_top"));
            assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
            assert!(run(&mut vt, "scroll_to_bottom"));
            assert!(vt.viewport_info().unwrap().is_at_bottom());
            assert!(run(&mut vt, "scroll_to_row:1"));
            assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 1);
            assert!(run(&mut vt, "scroll_page_lines:-1"));
            assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
        }

        /// A hop with no prompt in that direction must fall through rather than swallow the key.
        #[test]
        fn a_prompt_hop_answers_false_when_there_is_nowhere_to_go() {
            let mut vt = session();
            assert!(run(&mut vt, "scroll_to_top"));
            assert!(!run(&mut vt, "jump_to_prompt:-1"));
        }

        #[test]
        fn a_prompt_hop_lands_on_a_prompt() {
            let mut vt = session();
            assert!(run(&mut vt, "jump_to_prompt:-1"));
            assert_eq!(
                vt.screen_row_text(vt.viewport_info().unwrap().viewport_top_row)
                    .unwrap()
                    .as_deref(),
                Some("two")
            );
        }

        #[test]
        fn the_search_verbs_run_navigate_and_end() {
            let mut vt = session();
            assert!(run(&mut vt, "search:fill"));
            assert_eq!(vt.search_matches().len(), 2);
            assert!(run(&mut vt, "navigate_search:next"));
            assert!(run(&mut vt, "navigate_search:previous"));
            assert!(run(&mut vt, "end_search"));
            assert!(vt.search_matches().is_empty());
            // Nothing to navigate once the find is closed.
            assert!(!run(&mut vt, "navigate_search:next"));
        }

        #[test]
        fn adjusting_a_selection_needs_one_to_adjust() {
            let mut vt = session();
            assert!(!run(&mut vt, "adjust_selection:right"));
            assert!(run(&mut vt, "search:fill"));
            assert!(run(&mut vt, "adjust_selection:right"));
        }

        /// Every spelling the grammar can produce reaches an arm of [`perform`] — a variant added
        /// to the enum without a case here would silently do nothing at runtime.
        #[test]
        fn every_spelling_the_grammar_produces_is_understood() {
            for action in [
                SurfaceAction::Search { needle: "fill" },
                SurfaceAction::NavigateSearch { forward: true },
                SurfaceAction::EndSearch,
                SurfaceAction::ScrollToRow(0),
                SurfaceAction::ScrollLines(-1),
                SurfaceAction::ScrollFraction(-0.9),
                SurfaceAction::ScrollToTop,
                SurfaceAction::ScrollToBottom,
                SurfaceAction::JumpToPrompt(-1),
                SurfaceAction::AdjustSelection(SelectionEdge::Right),
            ] {
                let spelling = action.spell();
                assert!(
                    SurfaceAction::parse(&spelling).is_some(),
                    "the executor cannot parse its own spelling {spelling:?}"
                );
            }
        }

        /// ⚠️ A page motion must never round DOWN to nothing: in a one-row pane, 0.9 of a page is
        /// 0.9 rows, and a page-down that moves zero rows reads as a dead key.
        #[test]
        fn a_page_motion_moves_at_least_one_row() {
            assert_eq!(page_lines(0.9, 1), 1);
            assert_eq!(page_lines(-0.9, 1), -1);
            assert_eq!(page_lines(0.9, 40), 36);
            assert_eq!(page_lines(-0.9, 40), -36);
            // A viewport of nothing still owes the caller a direction.
            assert_eq!(page_lines(0.9, 0), 1);
        }

        /// The executor never sees a non-finite fraction — the grammar refuses one — but the guard
        /// is asserted here because the arithmetic would otherwise produce a wrapped row count.
        #[test]
        fn a_non_finite_fraction_never_reaches_the_arithmetic() {
            for spelling in [
                "scroll_page_fractional:NaN",
                "scroll_page_fractional:inf",
                "scroll_page_fractional:-inf",
            ] {
                assert!(SurfaceAction::parse(spelling).is_none(), "{spelling} parsed");
            }
        }

        #[test]
        fn a_needle_carrying_a_colon_survives_the_split() {
            let mut vt = VtSession::new(16, 3, 20, 40).unwrap();
            vt.feed(b"error: bad\r\n");
            assert!(run(&mut vt, "search:error: bad"));
            assert_eq!(vt.search_matches().len(), 1);
        }

        #[test]
        fn perform_is_the_only_decision_point() {
            let mut vt = session();
            // Reached directly rather than through a spelling, so the two paths are known to agree.
            assert!(perform(&mut vt, SurfaceAction::ScrollToTop));
            assert_eq!(vt.viewport_info().unwrap().viewport_top_row, 0);
        }
    }

    #[test]
    fn a_colour_word_drops_its_high_byte_rather_than_reading_it_as_alpha() {
        assert_eq!(rgb(0x00FF_8040), Rgb {
            r: 255,
            g: 128,
            b: 64
        });
        // The high byte is ignored, so an opaque `0xFF……` and a bare `0x00……` are the same colour.
        assert_eq!(rgb(0xFFFF_8040), rgb(0x00FF_8040));
    }

    #[test]
    fn a_pixel_measurement_never_narrows_to_zero_or_wraps() {
        assert_eq!(round_px(8.4), 8);
        assert_eq!(round_px(8.6), 9);
        // A cell can never be zero pixels: `libghostty-vt`'s geometry forbids it and the pointer's
        // division would be a NaN.
        assert_eq!(round_px(0.0), 1);
        assert_eq!(round_px(-40.0), 1);
        assert_eq!(round_px(f64::NAN), 1);
        // The positive guard is what fences the cast, so a value past `u32::MAX` saturates rather
        // than wrapping to a small number.
        assert_eq!(narrow_u32(f64::INFINITY), u32::MAX);
        assert_eq!(narrow_u32(f64::NAN), 0);
    }

    #[test]
    fn a_nan_coordinate_becomes_the_origin_rather_than_a_cell() {
        // The trap `slopdesk_vterm::selection`'s `axis` names, at the other end of the same path: a
        // NaN that reached the encoder would RESOLVE to a cell instead of being refused.
        // Bit-compared rather than `==`, which for a NaN input is the whole question: a test
        // written with `==` would pass on the very value it exists to rule out.
        assert_eq!(narrow_f32(f64::NAN).to_bits(), 0.0_f32.to_bits());
        assert!((narrow_f32(12.5) - 12.5).abs() < f32::EPSILON);
    }
}
