//! Everything between a terminal frame and a draw call.
//!
//! `docs/68-terminal-surface-in-rust.md` §5.1 is the argument for this crate existing:
//! `libghostty-vt` "leaves pixel-pushing to the host application", and this is the host
//! application's half. It takes a [`Frame`] — plain owned data, no engine — and answers instances a
//! GPU can draw.
//!
//! ## The two things it deliberately does not have
//!
//! **No GPU.** Not a Metal type in the tree. `slopdesk-apple-metal` owns the device, the layer and
//! the pipelines, and takes a [`quad::DrawList`] and an [`atlas::Atlas`] from here.
//!
//! **No font engine.** Not a Core Text call. `slopdesk-apple-text` implements [`glyph::TextShaper`]
//! and [`glyph::GlyphRasterizer`], and this crate never learns what a font is.
//!
//! What is left over is arithmetic — packing, caching, run coalescing, layout — and it is the half
//! most likely to be subtly wrong. Keeping it here means a smeared underline, a block cursor that
//! hides its character, a virtualised list that skips a row, and an atlas region that overlaps its
//! neighbour are all reachable from `cargo test` with no display attached. Every test in this crate
//! runs against a fake shaper and a fake rasteriser for exactly that reason.
//!
//! ## What is here
//!
//! - [`atlas`] — one texture, packed by shelves, owned on the CPU side.
//! - [`glyph`] — the cache over it, and the two traits a font engine comes in through.
//! - [`quad`] — the instance structs the shaders read.
//! - [`layout`] — where cells, decorations, the cursor and the scrollbar thumb are.
//! - [`block`] — the command-block list, virtualised, with the alt screen as its degenerate case.
//! - [`paint`] — the pass that turns a frame into instances, sixty times a second.
//!
//! ## Units
//!
//! Every coordinate that leaves this crate is a DEVICE pixel with a top-left origin. Points are
//! converted once, by the view, before anything here sees them. A renderer that carried both would
//! be a renderer with two places for the contents scale to be wrong.

#![forbid(unsafe_code)]

pub mod atlas;
pub mod block;
pub mod glyph;
pub mod layout;
pub mod paint;
pub mod quad;

pub use atlas::{Atlas, AtlasFormat, AtlasRegion};
pub use block::{
    BlockLayout, BlockSpan, Chrome, LayoutMode, PlacedBlock, RowRange, Viewport, lay_out, segment,
};
pub use glyph::{
    CachedGlyph, GlyphCache, GlyphKey, GlyphRasterizer, RasterGlyph, ShapedGlyph, Synthetic, TextRun,
    TextShaper,
};
pub use layout::{CellGeometry, FontMetrics, Insets, Thumb, Underline, grid_size, scrollbar};
pub use paint::{PaintStyle, Painter, SelectionColors};
pub use quad::{DrawList, GlyphInstance, RectInstance, RectStyle, Rgba};
