//! Command BLOCKS, the chrome they wear, and the two text surfaces that ride the same coordinates:
//! hyperlinks and the marked-text caret.
//!
//! `docs/68` §4 argues why blocks are the surface's own layout rather than decoration over a grid.
//! The link spans and the preedit caret sit with them because all three answer in the SAME frame —
//! a block's scroll offset moves a link's rectangle and the caret's alike, and a module that held
//! one without the others would have to re-derive that offset.

use core::ffi::c_uchar;

use slopdesk_termrender::ChromeStyle;
use slopdesk_vterm::{CellFlags, Scroll, text_cells};

use super::doors::argb;
use super::{BlockRecord, Composition, MAX_RECORDS, SlopDeskTerminalSurface, block_at, held};
use crate::{borrow, deliver, lent, spill};

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
    pub(super) fn scaled(self, scale: f64) -> ChromeStyle {
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

/// What a right-click found under it: the block, and what a menu may offer for it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskTerminalBlockTarget {
    /// The point landed inside a laid-out block at all. `false` means no block section is drawn —
    /// every other field is then meaningless.
    pub hit: bool,
    /// The block's 1-based PROMPT-CYCLE ordinal, or `0` when it joined no host record.
    ///
    /// The key everything acts by: the ring's index, the output request, the star and the fold are
    /// all reached from it, and unlike a layout position it survives the output that arrives while
    /// the menu is open.
    pub ordinal: u32,
    /// The block has prompt rows of its own, so folding it leaves something behind.
    pub foldable: bool,
    /// It is folded RIGHT NOW, which is what the fold verb's own label reads off.
    pub collapsed: bool,
}

/// Which block a point lands in, and the block's own half of the menu context, in one crossing.
///
/// [`slopdesk_term_surface_block_at_point`] answers the LAYOUT position, which is what a click on a
/// header spends immediately; this answers the JOIN key plus the two state bits a menu needs, which
/// is what a right-click spends seconds later. Two doors rather than one because a hover and a menu
/// want different halves of the same hit, and folding them would make the cheap one pay the join.
///
/// In POINTS, like every other pointer door.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_block_target(
    handle: *mut SlopDeskTerminalSurface,
    x: f64,
    y: f64,
) -> SlopDeskTerminalBlockTarget {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return SlopDeskTerminalBlockTarget::default();
    };
    let Some(index) = block_at(&surface.layout, |rect| surface.on_screen(rect), x, y) else {
        return SlopDeskTerminalBlockTarget::default();
    };
    let Some(block) = surface.layout.blocks.get(index) else {
        return SlopDeskTerminalBlockTarget::default();
    };
    SlopDeskTerminalBlockTarget {
        hit: true,
        ordinal: surface
            .joined_ordinals(&surface.layout)
            .get(index)
            .copied()
            .flatten()
            .unwrap_or(0),
        foldable: !block.span.is_orphan(),
        collapsed: surface.collapsed.get(index).copied().unwrap_or(false),
    }
}

/// Flips the fold of the block wearing `ordinal`, and answers its new state.
///
/// The ordinal-keyed sibling of [`slopdesk_term_surface_toggle_block_collapsed`], and the one a
/// MENU uses. ⚠️ The fold vector is positional, so the layout index is resolved HERE rather than
/// stashed when the menu was built: output arriving in between re-segments the list, and a stale
/// index folds a block the user never clicked. `false` for an ordinal no block wears, or for one
/// whose block cannot fold.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_toggle_block_collapsed_at_ordinal(
    handle: *mut SlopDeskTerminalSurface,
    ordinal: u32,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(index) = surface.layout_index_of_ordinal(ordinal) else {
        return false;
    };
    // A joined block always has prompt rows, so it is never the orphan the positional door has to
    // refuse — the fold is spelled out here rather than delegated because `held` has already handed
    // out the one mutable borrow this surface gets.
    let wanted = !surface.collapsed.get(index).copied().unwrap_or(false);
    if index >= surface.collapsed.len() {
        surface.collapsed.resize(index.saturating_add(1), false);
    }
    if let Some(slot) = surface.collapsed.get_mut(index) {
        *slot = wanted;
    }
    wanted
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

/// Tells the surface what the host said about one command block, so a header can print it.
///
/// Upserted by `ordinal`, because that is what identifies a block across its life: the same block
/// arrives once as running (no exit code, no duration) and again as finished, and the second must
/// replace the first rather than stack behind it.
///
/// `exit_code` and `duration_ms` are read only when their `has_` flag is set — C has no `Option`,
/// and a sentinel would collide with a real exit code (`-1` is one) or a real duration (`0` is
/// one). A running block therefore says so explicitly rather than by looking like a fast success.
///
/// An `ordinal` of zero is DROPPED. The host stamps zero when it attached mid-stream and cannot
/// count prompts, and a record that names no position cannot be joined to a block — keeping it
/// would only give the join something it has to defend against.
///
/// # Safety
/// [`held`]'s obligation, plus `(text, text_len)` being readable for `text_len` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_note_block(
    handle: *mut SlopDeskTerminalSurface,
    ordinal: u32,
    text: *const c_uchar,
    text_len: usize,
    has_exit_code: bool,
    exit_code: i32,
    has_duration: bool,
    duration_ms: u32,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    if ordinal == 0 {
        return;
    }
    // SAFETY: the caller's obligation. A null pointer or a non-UTF-8 command is an empty one, which
    // the join treats as no confirmation rather than as a match — the record still lands, so its
    // exit code prints once some other block confirms the anchor.
    let command_text = core::str::from_utf8(unsafe { borrow(text, text_len) })
        .unwrap_or_default()
        .to_owned();
    let record = BlockRecord {
        ordinal,
        command_text,
        exit_code: has_exit_code.then_some(exit_code),
        duration_ms: has_duration.then_some(duration_ms),
    };
    if let Some(held) = surface.records.iter_mut().find(|held| held.ordinal == ordinal) {
        *held = record;
    } else {
        surface.records.push(record);
        // Ordinals arrive in order in practice, but a reattach replays a snapshot and nothing
        // guarantees it — sorting is what lets the eviction below always drop the OLDEST.
        surface.records.sort_unstable_by_key(|record| record.ordinal);
        if surface.records.len() > MAX_RECORDS {
            let excess = surface.records.len() - MAX_RECORDS;
            surface.records.drain(..excess);
        }
    }
}

/// Forgets every block record, for a pane whose shell died and came back fresh.
///
/// The one edge the join cannot survive on its own, and the reason this door exists rather than the
/// records ageing out: a fresh shell re-counts its prompts from one, while the surface still holds
/// the dead session's ordinals in the forties. The join anchors on the NEWEST ordinal it holds, so
/// it would map today's first prompt onto yesterday's fortieth — and because everyday commands
/// repeat (`ls`, `just quick`), the text check can CONFIRM that wrong anchor rather than reject it.
/// A confidently wrong exit code is the one failure the whole design is built to avoid, so the
/// caller that drops its own block list on a fresh session drops these in the same breath.
///
/// Not called on a reattach that RESUMED the same shell: those blocks are still the ones on screen.
///
/// # Safety
/// [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_forget_blocks(handle: *mut SlopDeskTerminalSurface) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.records.clear();
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
pub(super) fn settled_scroll(current: f64, content_height: f64, viewport_height: f64, follow: bool) -> f64 {
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
pub(super) fn spill_rows(spill: f64, cell_height: f64) -> i32 {
    if spill == 0.0 || cell_height <= 0.0 {
        return 0;
    }
    num_to_i32((spill / cell_height).trunc()).unwrap_or(0)
}

pub(super) fn num_to_i32(value: f64) -> Option<i32> {
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
