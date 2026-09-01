//! The handle's LIFECYCLE and every setting written onto it.
//!
//! One shape holds this file together: each door here takes the handle, reaches [`super::Surface`]
//! through [`super::held`], writes one field and returns. Nothing reads back and nothing decides —
//! the arithmetic that would is in `super`, where the state it reads lives beside it.

use core::ffi::{c_uchar, c_void};

use slopdesk_terminal::config::FontSpec;
use slopdesk_terminal::controls::{Overscroll, ScrollPastFirst, ScrollPastLast};
use slopdesk_termrender::{Rgba, SelectionColors};
use slopdesk_vterm::{
    CursorShape, KeyAction, KeyPress, Mods, MouseAction, MouseButton, MouseMove, OptionAsAlt, Rgb, Scroll,
    key_from_macos_keycode,
};

use super::{SlopDeskTerminalSurface, Surface, held};
use crate::{SlopDeskByteSpan, arena_text, borrow, deliver, lent, records_of};

/// The four face names, the two numbers and the two thickening fields one font spec carries.
///
/// A record rather than eight more arguments on two doors, and spans rather than pointers for the
/// reason [`SlopDeskByteSpan`]'s own header gives: the names travel in ONE arena, so no field makes
/// the caller own a lifetime, and the two doors that speak this shape stay readable. The two LISTS
/// — the fallback families and the feature settings — cross beside it as span arrays into the same
/// arena, which is the shape `slopdesk_prompt_add_command` already speaks.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskTermFontSpec {
    /// The primary family, `terminal.font-family`.
    pub family: SlopDeskByteSpan,
    /// `terminal.font-family-bold`, empty to take the primary family's own cut.
    pub bold: SlopDeskByteSpan,
    /// `terminal.font-family-italic`, on `bold`'s terms.
    pub italic: SlopDeskByteSpan,
    /// `terminal.font-family-bold-italic`, on `bold`'s terms.
    pub bold_italic: SlopDeskByteSpan,
    /// The point size, before the view's contents scale.
    pub point_size: f64,
    /// The cell height as a multiple of the face's natural one; `1` for the face's own.
    pub line_height: f64,
    /// `terminal.font-thicken`.
    pub thicken: bool,
    /// `terminal.font-thicken-strength`, `0`-`255`. Read only when `thicken` is set.
    pub thicken_strength: u8,
}

/// One crossing font spec, read into the value the renderer takes.
///
/// A NULL record answers the FACTORY spec rather than refusing: every field it would have carried
/// has a declared default one layer down, in `slopdesk-settings`' table, and a surface that drew
/// nothing because a caller passed no font would be the wrong shape of failure for a row that
/// cannot be unset.
///
/// The feature entries cross as the TEXT a user typed and are parsed here, by
/// [`FontSpec::features_of`], for the reason its own crate header gives: `-calt` is a string, a
/// `(tag, value)` pair is a fact, and the crate full of Core Text `unsafe` should be handed facts.
///
/// # Safety
/// `spec` must be null or name one live record for the call; each span array must be null or name
/// its stated count of live records; `(arena, arena_len)` must name live bytes. Every span in every
/// record is read against the arena and answers empty when it does not fit, so a lying span costs
/// a name rather than a read out of bounds.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's record and arrays IS the boundary this module documents"
)]
unsafe fn font_spec(
    spec: *const SlopDeskTermFontSpec,
    fallback: *const SlopDeskByteSpan,
    fallback_count: usize,
    features: *const SlopDeskByteSpan,
    feature_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) -> FontSpec {
    // SAFETY: the caller's obligation above; each helper states its own.
    let (record, fallback, features, bytes) = unsafe {
        (
            spec.as_ref(),
            records_of(fallback, fallback_count),
            records_of(features, feature_count),
            borrow(arena, arena_len),
        )
    };
    let Some(record) = record else {
        return FontSpec::default();
    };
    let read = |span: SlopDeskByteSpan| arena_text(bytes, span.offset, span.length);
    let entries: Vec<String> = features.iter().copied().map(read).collect();
    FontSpec {
        family: read(record.family),
        bold: read(record.bold),
        italic: read(record.italic),
        bold_italic: read(record.bold_italic),
        fallback: fallback.iter().copied().map(read).collect(),
        features: FontSpec::features_of(&entries),
        thicken: record.thicken,
        thicken_strength: record.thicken_strength,
        point_size: record.point_size,
        line_height: record.line_height,
    }
}

/// Opens a terminal surface, or NULL when this machine cannot draw one.
///
/// `spec` is the whole of `[terminal]`'s font settings — see [`SlopDeskTermFontSpec`] — and `scale`
/// the view's contents scale, from which every device-pixel number below is derived.
/// `width_points` and `height_points` are the hosting view's bounds.
///
/// # Safety
/// [`font_spec`]'s, for the spec and its two arrays. The answer must be passed to
/// [`slopdesk_term_surface_free`] exactly once, from the main thread.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_new(
    spec: *const SlopDeskTermFontSpec,
    fallback: *const SlopDeskByteSpan,
    fallback_count: usize,
    features: *const SlopDeskByteSpan,
    feature_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    scale: f64,
    width_points: f64,
    height_points: f64,
) -> *mut SlopDeskTerminalSurface {
    // SAFETY: the caller's obligation, restated above.
    let spec = unsafe {
        font_spec(
            spec,
            fallback,
            fallback_count,
            features,
            feature_count,
            arena,
            arena_len,
        )
    };
    Surface::create(&spec, scale, width_points, height_points).map_or(core::ptr::null_mut(), |surface| {
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
/// ⚠️ Focus is no longer only the painter's. A program that set DEC mode 1004 is owed `CSI I`/`CSI
/// O` on each edge, so the focus goes to the ENGINE as well as to the flag `PaintStyle` reads. The
/// edge is detected inside `VtSession::set_focused` — a view pushes its focus from
/// `didMoveToWindow` and from every layout pass, and a report per pass would be one `CSI I` per
/// pass on the program's input. The bytes join the pty queue, so the caller must drain it after
/// this call as it does after a feed.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_focus(
    handle: *mut SlopDeskTerminalSurface,
    focused: bool,
    blink_visible: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.focused = focused;
    surface.session.set_focused(focused);
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

/// Rebuilds the face stack at `spec`, answering the grid it now fits, packed
/// `cols << 16 | rows` exactly as [`slopdesk_term_surface_set_geometry`] does.
///
/// The grid comes BACK rather than being read separately for that door's reason: a font change
/// resizes the cell, so it reflows the grid, and the caller owes the host a `resize` for the new
/// one. `0` for a null handle.
///
/// # Safety
/// [`held`]'s, plus [`font_spec`]'s for the spec and its two arrays.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_term_surface_set_font(
    handle: *mut SlopDeskTerminalSurface,
    spec: *const SlopDeskTermFontSpec,
    fallback: *const SlopDeskByteSpan,
    fallback_count: usize,
    features: *const SlopDeskByteSpan,
    feature_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) -> u32 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, discharged by the shared reader.
    let spec = unsafe {
        font_spec(
            spec,
            fallback,
            fallback_count,
            features,
            feature_count,
            arena,
            arena_len,
        )
    };
    let (cols, rows) = surface.set_font(&spec);
    (u32::from(cols) << 16) | u32::from(rows)
}

/// A `0x00RRGGBB` word as a colour. The high byte is ignored rather than read as alpha: every
/// colour on this door is opaque, and a caller that passed one would get a silently different
/// theme.
pub(super) const fn rgb(packed: u32) -> Rgb {
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
pub(super) const fn argb(packed: u32) -> Rgba {
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
pub(super) const fn narrow_f32(value: f64) -> f32 {
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
/// ⚠️ Saying so was not enough to make it true — the engine's SECOND cap, on bytes, was still
/// pruning underneath this one and a 10 000-line request kept 1065 rows. `set_scrollback_rows`
/// clears it; the numbers are in its doc.
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
    let _ = surface.session.set_scrollback_rows(rows);
}

/// The quiet a scrollback must hold before a compression pass is worth starting, in milliseconds.
///
/// Here so that the caller's timer carries no number of its own: this is the delay it arms after a
/// feed, and every delay after that is what [`slopdesk_term_surface_compress_step`] answered.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_term_surface_compression_idle_ms() -> i64 {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a quarter second in milliseconds is a small positive constant"
    )]
    {
        slopdesk_vterm::compression::IDLE_INTERVAL_MS as i64
    }
}

/// Compresses a bounded slice of the retained scrollback and answers the milliseconds to wait
/// before calling again, or a negative when there is nothing left to do.
///
/// ⚠️ **The delay is Rust's answer, not the caller's policy.** The caller owns a one-shot timer and
/// nothing else: arm it 250 ms after a feed, call this when it fires, re-arm at whatever this
/// returns, stop when it goes negative. Both intervals are ghostty's, and they live beside the code
/// that knows what a step costs — see `slopdesk_vterm::compression`.
///
/// Cheap to call too often and wrong to call from another thread: a step that finds the scrollback
/// still moving does no work, but the engine requires compression to be serialized with every other
/// use of the terminal, which on this side means the same thread every other door is called from.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_compress_step(handle: *mut SlopDeskTerminalSurface) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return -1;
    };
    surface
        .session
        .compress_step()
        .delay_ms()
        .and_then(|ms| i64::try_from(ms).ok())
        .unwrap_or(-1)
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

/// Whether inline images (the kitty graphics protocol) are DRAWN.
///
/// A renderer setting and not an engine one, deliberately: the engine keeps its image storage
/// either way, so turning this back on redraws whatever is still on screen instead of waiting for a
/// program to retransmit. Off is a picture nobody sees, not a picture nobody has.
///
/// This does NOT gate what the terminal ACCEPTS. `slopdesk-vterm`'s `graphics.rs` closes the file
/// and shared-memory transmission mediums permanently, because in this app the terminal is the
/// CLIENT and a path a remote program names would resolve on the user's own laptop — that is a
/// refusal, not a preference, and no setting reopens it.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_images(
    handle: *mut SlopDeskTerminalSurface,
    enabled: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.images_enabled = enabled;
}

/// `terminal.arrow-box-drawing-join`: whether an arrow a box rule runs into grows a stem.
///
/// The one sprite family that a setting reaches. The other four are drawn from the cell whatever
/// this says, because a font's box rule, block or Braille dot is fitted to the font's own advance
/// and gaps against its neighbour — that is the bug the family exists to fix, not a preference. An
/// arrow is different: `\u{2192}` in prose is a CHARACTER, and the join condition already leaves
/// that case to the typeface. Off is for the reader who does not want the joined form in a diagram
/// either.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_term_surface_set_arrow_box_drawing_join(
    handle: *mut SlopDeskTerminalSurface,
    enabled: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.arrow_box_drawing_join = enabled;
}

/// The three scroll knobs, as one delivery: `controls.scroll-past-last-line`,
/// `controls.scroll-past-first-line` and `controls.smooth-scroll`.
///
/// A door rather than three arguments on every wheel event, unlike `controls.scroll-multiplier`
/// beside it: the multiplier is applied to a delta before it ever reaches the surface, where these
/// three are read again by the per-frame SETTLE, which no gesture is present for. A setting the
/// draw path needs has to be held.
///
/// Both policies arrive as indices into their own vocabulary, `SLOPDESK_SCROLL_PAST_*`; an index
/// past the end is repaired to the vocabulary's own default, which is `disabled` for both — the
/// same total rule every other code-taking door on this surface follows.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_term_surface_set_overscroll(
    handle: *mut SlopDeskTerminalSurface,
    past_last: u8,
    past_first: u8,
    smooth: bool,
) {
    // SAFETY: the caller's obligation, restated above.
    let Some(surface) = (unsafe { held(handle) }) else {
        return;
    };
    surface.overscroll = Overscroll {
        past_last: ScrollPastLast::ALL
            .get(past_last as usize)
            .copied()
            .unwrap_or_default(),
        past_first: ScrollPastFirst::ALL
            .get(past_first as usize)
            .copied()
            .unwrap_or_default(),
        smooth,
    };
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
