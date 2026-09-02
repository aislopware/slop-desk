//! Every draw decision in this crate, taken over the engine's own fuzz corpus.
//!
//! `slopdesk-vterm`'s sibling file asks whether the frame SAYS what the terminal says. This one
//! asks the question after that: given a frame the terminal really produced, does the pass that
//! turns it into instances survive, and is what it emits drawable.
//!
//! Every other test in this crate builds its frame by hand. That is the right shape for pinning a
//! rule — a hand-built frame is the only way to state "a block cursor must not hide its character"
//! and check exactly it — and it is the wrong shape for finding the rows nobody thought to write.
//! A grid that a real VT stream drove into a state is a different distribution: a scrolling region
//! left half-set, a wide cell whose head scrolled off, a row of combining marks with no base, a
//! frame whose every row is dirty and whose cursor is past the last column. `docs/68` §5.1 put the
//! renderer's risk here, and the crate header says why the arithmetic is the half most likely to be
//! subtly wrong.
//!
//! The corpus is ghostty's minimised stream-fuzzer set, reached through `GHOSTTY_SOURCE_DIR` — see
//! `slopdesk_vterm`'s `conformance` module for what it is and why nothing is committed from it.
//!
//! ## What is asserted, and why it is not a golden
//!
//! A [`DrawList`] for a fuzz input is not a picture anybody can review, so pinning one would pin a
//! blob nobody could re-derive when it changed. What holds instead are the properties every
//! drawable list has, whatever it draws:
//!
//! * **No panic.** The pass runs `forbid(unsafe_code)` with `indexing_slicing` denied, so the
//!   failure a hostile frame reaches is an ordinary one — and this is the only place in the tree
//!   that feeds it frames it did not write.
//! * **Every coordinate is finite.** A NaN reaches the GPU as a quad that vanishes or as one that
//!   swallows the screen, and it survives every equality assertion a hand-built test makes because
//!   the hand-built frame never produced one.
//! * **Nothing is drawn outside the content box.** The box is the FRAME's own grid width and the
//!   LAYOUT's own content height, not the surface the sweep chose: a corpus input is free to send
//!   DECCOLM and make the grid 132 columns wide, and a renderer that then drew 132 columns is
//!   right. What the bound catches is the paint disagreeing with the two things that decide where a
//!   cell goes — a whole row placed a row's height away, a column index used as a row index.
//! * **The glyph count is bounded by the grid.** A cell may emit several glyphs (a ligature, a
//!   cluster), but a pass that emits thousands per cell is a loop that is not terminating on the
//!   input it was handed.

#![cfg(test)]
#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]

use std::fs;
use std::path::PathBuf;

use slopdesk_terminal::geometry::CellMetrics;
use slopdesk_vterm::recording::{Event, Recording};
use slopdesk_vterm::{Frame, VtSession};

use crate::atlas::AtlasFormat;
use crate::block::{Chrome, LayoutMode, Viewport, lay_out, segment};
use crate::glyph::{GlyphCache, GlyphKey, GlyphRasterizer, RasterGlyph, ShapedGlyph, TextRun, TextShaper};
use crate::layout::{CellGeometry, FontMetrics};
use crate::paint::{PaintStyle, Painter, SelectionColors};
use crate::quad::{DrawList, Rgba};

/// The grid the sweep runs at, and the surface it draws onto.
const COLS: u16 = 81;
/// See [`COLS`].
const ROWS: u16 = 25;
/// Cell width in device pixels, matching [`style`]'s metrics.
const CELL_W: f32 = 10.0;
/// Cell height in device pixels, matching [`style`]'s metrics.
const CELL_H: f32 = 20.0;

/// How far outside the drawable an instance may land before it counts as misplaced.
///
/// Not zero, and the slack is named rather than tuned: a glyph's raster box hangs off its cell by
/// its bearing, a cursor is drawn at its own thickness, and the fake rasteriser below returns an
/// 8×8 box for every glyph whatever the cell is. One cell in every direction covers all three and
/// still catches a row placed a row's height away, which is the bug worth catching.
const SLACK: f32 = CELL_H;

/// A shaper that emits one glyph per char, one cell wide, with no ligatures.
///
/// The same fake the rest of the crate's tests use, with ONE difference that the corpus forces and
/// that a real shaper has for free: a glyph is never placed past the run it belongs to.
/// `TextRun::cells` says so in its own doc — "not the same as the character count" — and the other
/// tests never notice because their text is ASCII, where the two agree. Corpus text is not: a
/// grapheme cluster is several chars in one cell, so an offset taken from the char index walks off
/// the right of the run and every instance after it is misplaced by an amount no paint decided.
/// Clamping to the run's own width is what Core Text does, and without it this sweep would be
/// measuring the fake.
#[derive(Debug, Default)]
struct OneToOne;

impl TextShaper for OneToOne {
    fn shape(&mut self, run: &TextRun<'_>, out: &mut Vec<ShapedGlyph>) {
        let last_cell = run.cells.saturating_sub(1);
        for (index, ch) in run.text.chars().enumerate() {
            let offset = u16::try_from(index).unwrap_or(u16::MAX).min(last_cell);
            out.push(ShapedGlyph {
                key: GlyphKey {
                    font: 0,
                    glyph: ch as u32,
                    size_px: run.size_px,
                    subpixel: run.subpixel,
                    synthetic: crate::glyph::Synthetic {
                        bold: run.bold,
                        italic: run.italic,
                    },
                },
                x: f32::from(offset) * CELL_W,
                y: 0.0,
                cell: offset,
            });
        }
    }
}

/// A rasteriser that draws every glyph as an 8×8 square with no bearing.
#[derive(Debug)]
struct Square;

impl GlyphRasterizer for Square {
    fn rasterize(&mut self, _key: GlyphKey) -> Option<RasterGlyph> {
        Some(RasterGlyph {
            width: 8,
            height: 8,
            bearing_x: 0.0,
            bearing_y: 8.0,
            format: AtlasFormat::Alpha8,
            pixels: vec![0xFF; 64],
        })
    }
}

/// The style the sweep paints with. Ordinary values; nothing here is under test.
fn style() -> PaintStyle {
    PaintStyle {
        geometry: CellGeometry {
            metrics: CellMetrics {
                cell_width: f64::from(CELL_W),
                cell_height: f64::from(CELL_H),
                origin_x: 0.0,
                origin_y: 0.0,
            },
            font: FontMetrics {
                baseline: 15.0,
                underline_position: 17.0,
                underline_thickness: 1.0,
                strikethrough_position: 10.0,
                strikethrough_thickness: 1.0,
                cursor_thickness: 2.0,
            },
        },
        size_px: 24,
        content_origin_y: 0.0,
        selection: SelectionColors {
            background: Rgba::opaque(0x33, 0x66, 0x99),
            foreground: Some(Rgba::opaque(0xFF, 0xFF, 0xFF)),
        },
        focused: true,
        blink_visible: true,
        cursor_opacity: 1.0,
        cursor_text: None,
        arrow_box_drawing_join: true,
    }
}

/// A session fed `bytes`, rendered, with both push queues drained.
fn frame_for(bytes: &[u8]) -> VtSession {
    let mut session = VtSession::new(COLS, ROWS, 10, 20).expect("session");
    session.feed(bytes);
    let mut replies = Vec::new();
    session.take_pty_replies(&mut replies);
    drop(session.take_clipboard_writes());
    session.render().expect("render");
    session
}

/// The box every instance a paint emits has to land inside, in device pixels.
///
/// Read off the two things that decide placement rather than off the sweep's own constants. The
/// width is the FRAME's column count because a corpus input may have sent DECCOLM and legitimately
/// widened the grid; the height is the LAYOUT's `content_height` because in `Blocks` mode the
/// headers and gaps between blocks are content too.
#[derive(Debug, Clone, Copy)]
struct ContentBox {
    width: f32,
    height: f32,
}

/// Paints one frame, in both layout modes, and answers what the properties say.
fn painted(frame: &Frame, mode: LayoutMode) -> (DrawList, ContentBox) {
    let chrome = if mode == LayoutMode::Grid {
        Chrome::NONE
    } else {
        Chrome {
            header: 24.0,
            gap: 8.0,
            gutter: 12.0,
        }
    };
    let spans = segment(frame, mode);
    let collapsed = vec![false; spans.len()];
    // The frame's own size, not the sweep's constants: a recorded session ran at its own geometry
    // and a corpus input may have sent DECCOLM, and a viewport smaller than the grid would clip the
    // paint into passing.
    let viewport = Viewport {
        scroll_y: 0.0,
        height: f64::from(frame.row_count()) * f64::from(CELL_H),
        width: f64::from(frame.cols) * f64::from(CELL_W),
    };
    let layout = lay_out(&spans, &collapsed, chrome, f64::from(CELL_H), viewport);

    let mut out = DrawList::new();
    let mut cache = GlyphCache::new();
    Painter::new().paint(
        frame,
        &layout,
        &style(),
        None,
        &mut cache,
        &mut OneToOne,
        &mut Square,
        &mut out,
    );

    let bounds = ContentBox {
        width: f32::from(frame.cols) * CELL_W,
        // Whichever is taller: a viewport nothing filled still has rows in it, and a content box
        // shorter than the viewport would fail a cursor drawn on an empty grid.
        height: content_height_px(&layout).max(f32::from(ROWS) * CELL_H),
    };
    (out, bounds)
}

/// [`crate::block::BlockLayout::content_height`] as the pixels the instances are measured in.
///
/// A layout that produced a non-finite or negative height answers zero rather than a bound nothing
/// can fail: the height is only ever used as a CEILING here, and a NaN one would silently forgive
/// every instance drawn below it.
#[expect(
    clippy::cast_possible_truncation,
    reason = "a ceiling compared against f32 instance coordinates; precision past them is not a bound"
)]
fn content_height_px(layout: &crate::block::BlockLayout) -> f32 {
    let height = layout.content_height;
    if height.is_finite() && height > 0.0 {
        height as f32
    } else {
        0.0
    }
}

/// The first property a list breaks, if any.
fn misdrawn(frame: &Frame, list: &DrawList, bounds: ContentBox) -> Option<String> {
    let ContentBox { width, height } = bounds;

    let rects = list
        .backgrounds
        .iter()
        .chain(&list.underlines)
        .chain(&list.overlays)
        .chain(&list.pinned_underlines)
        .chain(&list.pinned_backgrounds)
        .chain(&list.pinned_overlays)
        .map(|rect| ("rect", rect.x, rect.y, rect.width, rect.height));
    let glyphs = list
        .glyphs
        .iter()
        .chain(&list.pinned_glyphs)
        .map(|glyph| ("glyph", glyph.x, glyph.y, glyph.width, glyph.height));

    for (kind, x, y, w, h) in rects.chain(glyphs) {
        if !(x.is_finite() && y.is_finite() && w.is_finite() && h.is_finite()) {
            return Some(format!("{kind} at ({x}, {y}) {w}×{h} is not finite"));
        }
        if x < -SLACK || y < -SLACK || x + w > width + SLACK || y + h > height + SLACK {
            return Some(format!(
                "{kind} at ({x}, {y}) {w}×{h} falls outside the {width}×{height} content box"
            ));
        }
    }

    // One glyph per cell is the ordinary case and a cluster can add a few; the ceiling is loose on
    // purpose, because what it is watching for is unbounded rather than several.
    let cells = usize::from(frame.cols) * usize::from(frame.row_count());
    let glyphs = list.glyphs.len() + list.pinned_glyphs.len();
    if glyphs > cells * 8 {
        return Some(format!("{glyphs} glyphs for {cells} cells"));
    }
    None
}

/// ghostty's minimised stream-fuzzer corpus, or `None` when the tree is not provisioned.
fn stream_corpus() -> Option<PathBuf> {
    let root = PathBuf::from(std::env::var_os("GHOSTTY_SOURCE_DIR")?);
    let corpus = root.join("test/fuzz-libghostty/corpus/stream-cmin");
    corpus.is_dir().then_some(corpus)
}

#[test]
fn the_paint_pass_draws_every_engine_corpus_frame() {
    let Some(corpus) = stream_corpus() else { return };

    // Fanned out across the machine. Each worker builds its own sessions and painters and shares
    // nothing — a `libghostty-vt` handle is confined to the thread that made it — so the split is
    // by FILE. Serial this sweep is half a minute added to the inner loop.
    let files: Vec<PathBuf> = fs::read_dir(&corpus)
        .expect("read corpus")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();

    let workers = std::thread::available_parallelism().map_or(4, std::num::NonZeroUsize::get);
    let per = files.len().div_ceil(workers.max(1)).max(1);

    let (checked, mut failures) = std::thread::scope(|scope| {
        // The collect is what makes this parallel: `spawn` must run for every chunk before the
        // first `join`, and a lazy iterator would start each worker only as the previous one was
        // waited on — the same sweep, serial, through a thread apiece.
        #[expect(clippy::needless_collect, reason = "collecting is what starts the workers")]
        let handles: Vec<_> = files
            .chunks(per)
            .map(|chunk| {
                scope.spawn(move || {
                    let mut checked = 0_usize;
                    let mut failures: Vec<String> = Vec::new();
                    for path in chunk {
                        let Ok(bytes) = fs::read(path) else { continue };
                        checked += 1;
                        let session = frame_for(&bytes);
                        // Both modes, because the alt-screen branch skips the chrome pass entirely
                        // (`docs/68` §5.3) and a frame that only ever went through one of them
                        // leaves the other unexercised.
                        for mode in [LayoutMode::Blocks, LayoutMode::Grid] {
                            let (list, bounds) = painted(session.frame(), mode);
                            if let Some(what) = misdrawn(session.frame(), &list, bounds) {
                                let name = path
                                    .file_name()
                                    .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
                                failures.push(format!("  {name} ({mode:?}): {what}"));
                            }
                        }
                    }
                    (checked, failures)
                })
            })
            .collect();

        handles
            .into_iter()
            .fold((0_usize, Vec::new()), |mut acc, handle| {
                let (checked, failures) = handle.join().expect("worker");
                acc.0 += checked;
                acc.1.extend(failures);
                acc
            })
    });

    assert!(
        checked > 100,
        "the corpus at {} held only {checked} inputs",
        corpus.display()
    );

    let total = failures.len();
    failures.truncate(8);
    assert!(
        failures.is_empty(),
        "{total} paints of {checked} corpus frames are not drawable:\n{}",
        failures.join("\n")
    );
}

/// The committed recordings, decoded.
///
/// They live in `slopdesk-vterm` because that is the crate that owns the format and the recorder
/// writes them for. Reading them across the crate boundary is deliberate: a copy under this crate
/// would be a second corpus to keep in step, and the paint has to be checked against the same
/// frames the engine sweeps check.
fn recorded_corpus() -> Vec<Recording> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("slopdesk-vterm")
        .join("corpus");
    let recordings: Vec<Recording> = fs::read_dir(&dir)
        .expect("the recorded corpus is committed")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "sdrec"))
        .map(|path| {
            let bytes = fs::read(&path).expect("read recording");
            Recording::decode(&bytes).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
        })
        .collect();
    assert!(
        recordings.len() >= 4,
        "the recorded corpus has shrunk to {} — it is committed, so this is a deletion",
        recordings.len()
    );
    recordings
}

#[test]
fn the_paint_pass_draws_every_frame_of_a_recorded_session() {
    // The fuzz sweep above paints one frame per input — a still picture, of a screen no program
    // ever produced. This paints EVERY frame of a real program: `slopdesk-vterm/corpus` holds an
    // `@opentui/core` demo, nvim, fzf, lazygit and `less`, recorded under `slopdesk-ttyrec` with
    // every pty read kept as its own chunk. What that reaches and the fuzz corpus does not is the
    // paint over a frame that CHANGED — a block layout re-segmented after a repaint, a row that the
    // engine reported clean and the frame therefore kept, an alternate screen entered and left.
    let recordings = recorded_corpus();
    let mut painted_frames = 0_usize;
    let mut failures: Vec<String> = Vec::new();
    for recording in &recordings {
        let mut session = VtSession::new(
            recording.cols,
            recording.rows,
            recording.cell_width,
            recording.cell_height,
        )
        .expect("session");
        session.set_scrollback_rows(0).expect("scrollback");

        for (index, event) in recording.events.iter().enumerate() {
            let Event::Output(bytes) = event else { continue };
            session.feed(bytes);
            let mut replies = Vec::new();
            session.take_pty_replies(&mut replies);
            drop(session.take_clipboard_writes());
            session.render().expect("render");
            painted_frames += 1;

            for mode in [LayoutMode::Blocks, LayoutMode::Grid] {
                let (list, bounds) = painted(session.frame(), mode);
                if let Some(what) = misdrawn(session.frame(), &list, bounds) {
                    failures.push(format!("  {} frame {index} ({mode:?}): {what}", recording.title));
                }
            }
        }
    }

    assert!(
        painted_frames > 100,
        "only {painted_frames} frames across the whole recorded corpus"
    );
    let total = failures.len();
    failures.truncate(8);
    assert!(
        failures.is_empty(),
        "{total} paints of {painted_frames} recorded frames are not drawable:\n{}",
        failures.join("\n")
    );
}

#[test]
fn the_paint_pass_survives_a_grid_that_changes_size_under_it() {
    // The paint's bounds come from the FRAME — `frame.cols` and the layout's content height — and
    // the reason they must is that the grid changes size while a session is running. A resize is
    // the one event that invalidates a cached width, a cached row count and a block segmentation
    // all at once, and a painter that kept any of the three would draw outside the surface it was
    // given for exactly one frame: long enough to be a visible tear and short enough that no still
    // picture would ever hold it.
    let recordings = recorded_corpus();
    let mut painted_frames = 0_usize;
    let mut failures: Vec<String> = Vec::new();

    for recording in &recordings {
        let outputs: Vec<&[u8]> = recording
            .events
            .iter()
            .filter_map(|event| {
                match event {
                    Event::Output(bytes) => Some(bytes.as_slice()),
                    _ => None,
                }
            })
            .collect();
        if outputs.len() < 6 {
            continue;
        }

        // Narrower and shorter, then wider and taller than it started. Both directions, because a
        // shrink drops rows the layout had and a grow asks for rows nothing has written.
        #[expect(
            clippy::integer_division,
            reason = "a chunk index, and the truncation is the point: a third of the way through is \
                      whichever whole read that lands on"
        )]
        let points = [
            (outputs.len() / 3, 47_u16, 13_u16),
            (outputs.len() * 2 / 3, 137, 41),
        ];
        for (at, cols, rows) in points {
            let mut session = VtSession::new(
                recording.cols,
                recording.rows,
                recording.cell_width,
                recording.cell_height,
            )
            .expect("session");
            session.set_scrollback_rows(0).expect("scrollback");

            for (index, bytes) in outputs.iter().enumerate() {
                if index == at {
                    session
                        .resize(cols, rows, recording.cell_width, recording.cell_height)
                        .expect("resize");
                }
                session.feed(bytes);
                let mut replies = Vec::new();
                session.take_pty_replies(&mut replies);
                drop(session.take_clipboard_writes());
                session.render().expect("render");
                painted_frames += 1;

                for mode in [LayoutMode::Blocks, LayoutMode::Grid] {
                    let (list, bounds) = painted(session.frame(), mode);
                    if let Some(what) = misdrawn(session.frame(), &list, bounds) {
                        failures.push(format!(
                            "  {} frame {index} at {cols}x{rows} ({mode:?}): {what}",
                            recording.title
                        ));
                    }
                }
            }
        }
    }

    assert!(
        painted_frames > 100,
        "only {painted_frames} frames were painted across a resize"
    );
    let total = failures.len();
    failures.truncate(8);
    assert!(
        failures.is_empty(),
        "{total} paints of {painted_frames} frames across a resize are not drawable:\n{}",
        failures.join("\n")
    );
}
