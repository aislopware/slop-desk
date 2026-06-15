//! Video-path C ABI: the scalar realtime policies and small-buffer codecs from
//! `aislopdesk_core`'s video modules.
//!
//! Same memory / error contract as the crate root (see `lib.rs`): scalars cross by value;
//! any [`crate::AisdBytes`] returned owns a Rust allocation freed with [`crate::aisd_bytes_free`];
//! borrowed input buffers (`cap == 0`) are copied, never freed. The pure scalar functions here
//! take no pointers and cannot fail.

use crate::{
    bytes_from_vec, copy_in, drop_bytes, AisdBytes, AisdStatus, AISD_EMPTY,
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_MALFORMED, AISD_ERR_NULL, AISD_ERR_TRUNCATED, AISD_OK,
};
use aislopdesk_core::adaptive_fec;
use aislopdesk_core::adaptive_playout;
use aislopdesk_core::capture_region;
use aislopdesk_core::coordinate_mapping::{self, ScreenInfo};
use aislopdesk_core::cursor::CursorUpdate;
use aislopdesk_core::error::VideoProtocolError;
use aislopdesk_core::geometry::{VideoPoint, VideoRect, VideoSize};
use aislopdesk_core::input_event::{InputEvent, InputModifiers, MouseButton};
use aislopdesk_core::live_bitrate_policy;
use aislopdesk_core::recovery_policy::RecoveryPolicy;
use aislopdesk_core::video_control::{SystemDialogSummary, VideoControlMessage, WindowSummary};
use aislopdesk_core::virtual_display_geometry::{self, VirtualDisplayGeometry};
use aislopdesk_core::window_geometry::WindowGeometryMessage;
use aislopdesk_core::window_placement;

/// Maps a core video decode error to its boundary status code (shared by the video codecs).
pub(crate) const fn status_for_video_error(error: &VideoProtocolError) -> AisdStatus {
    match error {
        VideoProtocolError::Truncated => AISD_ERR_TRUNCATED,
        VideoProtocolError::Malformed(_) => AISD_ERR_MALFORMED,
    }
}

/// Borrows a `(ptr, len)` pair as a slice (empty for `len == 0`, even if `ptr` is null).
///
/// # Safety
/// If `len != 0`, `data` must point to at least `len` readable bytes.
pub(crate) const unsafe fn slice_in<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        core::slice::from_raw_parts(data, len)
    }
}

// ---------------------------------------------------------------------------------------
// live_bitrate_policy — pure, scalar (called ~per resolution change, never per frame)
// ---------------------------------------------------------------------------------------

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, never below `floor` or the minimum. Wraps
/// [`live_bitrate_policy::target_bitrate`].
///
/// The caller resolves the `bits_per_pixel` density (e.g. from `AISLOPDESK_BPP`) and passes it
/// in, so the core stays environment-free and the result is deterministic.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    live_bitrate_policy::target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel)
}

/// One hysteretic step of the adaptive playout-delay policy (milliseconds).
///
/// For the client's deadline presentation pacer. Maps the live measured `jitter_seconds` to a
/// target buffer `clamp(k·jitter + base, [floor, ceil])` and steps `prev_playout_ms` toward it —
/// grow-fast, shrink-slow (at most `shrink_step_ms` down per call) to avoid a latency ratchet. The
/// caller holds `prev_playout_ms` between calls and resolves the env knobs, so the core stays
/// deterministic. Wraps [`adaptive_playout::step_seconds`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_playout_step_ms(
    jitter_seconds: f64,
    prev_playout_ms: f64,
    shrink_step_ms: f64,
    k: f64,
    base_ms: f64,
    floor_ms: f64,
    ceil_ms: f64,
) -> f64 {
    let config = adaptive_playout::Config::from_ms(k, base_ms, floor_ms, ceil_ms);
    let next = adaptive_playout::step_seconds(
        jitter_seconds,
        prev_playout_ms / 1000.0,
        shrink_step_ms / 1000.0,
        &config,
    );
    next * 1000.0
}

/// The absolute minimum live bitrate (bits/sec) — a tiny window never starves the encoder.
/// Wraps [`live_bitrate_policy::MINIMUM_BITRATE`].
#[must_use]
#[no_mangle]
pub const extern "C" fn aisd_live_bitrate_minimum() -> i64 {
    live_bitrate_policy::MINIMUM_BITRATE
}

// ---------------------------------------------------------------------------------------
// cursor — the fixed 36-byte hot cursor update (≈120 Hz, small => Rust faster than Data)
// ---------------------------------------------------------------------------------------

/// A decoded cursor update, flattened for the C ABI (the hot 36-byte message; no owned
/// buffer). Field order must match the C header's `AisdCursorUpdate`.
#[repr(C)]
pub struct AisdCursorUpdate {
    /// Cursor shape id (client caches the bitmap by this id).
    pub shape_id: u16,
    /// Visibility (`0` = hidden, nonzero = visible; read as `!= 0`).
    pub visible: u8,
    /// Host-window-space x (points).
    pub x: f64,
    /// Host-window-space y (points).
    pub y: f64,
    /// Hotspot x offset (points).
    pub hotspot_x: f64,
    /// Hotspot y offset (points).
    pub hotspot_y: f64,
}

/// Encodes a cursor update into its fixed 36-byte wire form.
///
/// On [`AISD_OK`], `*out` owns the
/// buffer — release with [`crate::aisd_bytes_free`]. Wraps [`CursorUpdate::encode`]; cannot
/// fail except for a null `out`.
///
/// # Safety
/// `out` must be a writable [`AisdBytes`] pointer.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_encode(
    shape_id: u16,
    visible: u8,
    x: f64,
    y: f64,
    hotspot_x: f64,
    hotspot_y: f64,
    out: *mut AisdBytes,
) -> AisdStatus {
    if out.is_null() {
        return AISD_ERR_NULL;
    }
    let update = CursorUpdate {
        position: VideoPoint::new(x, y),
        shape_id,
        hotspot: VideoPoint::new(hotspot_x, hotspot_y),
        visible: visible != 0,
    };
    out.write(bytes_from_vec(update.encode()));
    AISD_OK
}

/// Decodes a cursor update into `*out`.
///
/// Wraps [`CursorUpdate::decode`]: rejects a wrong type
/// byte or non-finite coordinate ([`AISD_ERR_MALFORMED`]) and a short body
/// ([`AISD_ERR_TRUNCATED`]). `data` may be null only when `len == 0`.
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdCursorUpdate,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match CursorUpdate::decode(slice_in(data, len)) {
        Ok(c) => {
            out.write(AisdCursorUpdate {
                shape_id: c.shape_id,
                visible: u8::from(c.visible),
                x: c.position.x,
                y: c.position.y,
                hotspot_x: c.hotspot.x,
                hotspot_y: c.hotspot.y,
            });
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

// ---------------------------------------------------------------------------------------
// window_geometry — the move/resize/bounds/title metadata channel (occasional, per window
// move/resize/title; one owned title buffer, marshaled like AisdWireMessage)
// ---------------------------------------------------------------------------------------

/// [`WindowGeometryMessage::Move`] discriminator (`kind`).
pub const AISD_WINDOW_GEOMETRY_MOVE: u8 = 1;
/// [`WindowGeometryMessage::Resize`] discriminator.
pub const AISD_WINDOW_GEOMETRY_RESIZE: u8 = 2;
/// [`WindowGeometryMessage::Bounds`] discriminator.
pub const AISD_WINDOW_GEOMETRY_BOUNDS: u8 = 3;
/// [`WindowGeometryMessage::Title`] discriminator.
pub const AISD_WINDOW_GEOMETRY_TITLE: u8 = 4;

/// A window-geometry message, flattened for the C ABI.
///
/// `kind` (`AISD_WINDOW_GEOMETRY_*`) selects which fields are meaningful: `MOVE` uses `x`/`y`;
/// `RESIZE` uses `width`/`height`; `BOUNDS` uses all four; `TITLE` uses `title` (UTF-8). On a
/// decode `out` the `title` owns a Rust allocation — release with [`aisd_window_geometry_free`];
/// on an encode input it is a borrowed `(ptr, len)` (`cap` ignored) or [`AisdBytes::EMPTY`].
#[repr(C)]
pub struct AisdWindowGeometry {
    /// Message discriminator (`AISD_WINDOW_GEOMETRY_*`).
    pub kind: u8,
    /// `MOVE` / `BOUNDS` origin x (points).
    pub x: f64,
    /// `MOVE` / `BOUNDS` origin y (points).
    pub y: f64,
    /// `RESIZE` / `BOUNDS` width (points).
    pub width: f64,
    /// `RESIZE` / `BOUNDS` height (points).
    pub height: f64,
    /// `TITLE` UTF-8 bytes (owned out / borrowed in; [`AisdBytes::EMPTY`] otherwise).
    pub title: AisdBytes,
}

impl AisdWindowGeometry {
    /// An all-zero `MOVE`-shaped struct with an empty title — the base every decode fills in.
    const fn zeroed() -> Self {
        Self {
            kind: 0,
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            title: AisdBytes::EMPTY,
        }
    }
}

/// Rebuilds a core [`WindowGeometryMessage`] from the caller's C struct, validating the `kind`
/// and any UTF-8 title.
///
/// # Safety
/// A non-empty `title` in `m` must point to that many readable bytes.
unsafe fn c_to_window_geometry(
    m: &AisdWindowGeometry,
) -> Result<WindowGeometryMessage, AisdStatus> {
    let message = match m.kind {
        AISD_WINDOW_GEOMETRY_MOVE => WindowGeometryMessage::Move(VideoPoint::new(m.x, m.y)),
        AISD_WINDOW_GEOMETRY_RESIZE => {
            WindowGeometryMessage::Resize(VideoSize::new(m.width, m.height))
        }
        AISD_WINDOW_GEOMETRY_BOUNDS => {
            WindowGeometryMessage::Bounds(VideoRect::xywh(m.x, m.y, m.width, m.height))
        }
        AISD_WINDOW_GEOMETRY_TITLE => {
            let title =
                String::from_utf8(copy_in(m.title)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?;
            WindowGeometryMessage::Title(title)
        }
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(message)
}

/// Flattens a core [`WindowGeometryMessage`] into the C struct, allocating an owned buffer for a
/// title.
fn window_geometry_to_c(message: &WindowGeometryMessage) -> AisdWindowGeometry {
    let mut out = AisdWindowGeometry::zeroed();
    out.kind = message.message_type();
    match message {
        WindowGeometryMessage::Move(p) => {
            out.x = p.x;
            out.y = p.y;
        }
        WindowGeometryMessage::Resize(s) => {
            out.width = s.width;
            out.height = s.height;
        }
        WindowGeometryMessage::Bounds(r) => {
            out.x = r.origin.x;
            out.y = r.origin.y;
            out.width = r.size.width;
            out.height = r.size.height;
        }
        WindowGeometryMessage::Title(t) => out.title = bytes_from_vec(t.clone().into_bytes()),
    }
    out
}

/// Encodes a caller-built [`AisdWindowGeometry`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`
/// / non-UTF-8 `title`.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; a non-empty `title` inside `*msg` must
/// point to that many readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_window_geometry_encode(
    msg: *const AisdWindowGeometry,
    out: *mut AisdBytes,
) -> AisdStatus {
    if msg.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    match c_to_window_geometry(&*msg) {
        Ok(message) => {
            out.write(bytes_from_vec(message.encode()));
            AISD_OK
        }
        Err(status) => status,
    }
}

/// Decodes a window-geometry message into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `title` buffer — release with [`aisd_window_geometry_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / non-UTF-8 title /
/// unknown type to [`AISD_ERR_MALFORMED`] and a short body to [`AISD_ERR_TRUNCATED`].
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_window_geometry_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdWindowGeometry,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match WindowGeometryMessage::decode(slice_in(data, len)) {
        Ok(message) => {
            out.write(window_geometry_to_c(&message));
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

/// Releases the owned `title` buffer inside an [`AisdWindowGeometry`] and resets it to empty.
/// Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdWindowGeometry`] previously filled by this library.
#[no_mangle]
pub unsafe extern "C" fn aisd_window_geometry_free(msg: *mut AisdWindowGeometry) {
    if msg.is_null() {
        return;
    }
    let m = &mut *msg;
    drop_bytes(m.title);
    m.title = AisdBytes::EMPTY;
}

// ---------------------------------------------------------------------------------------
// input_event — client→host pointer/key/scroll/text events (per user action; one owned text
// buffer, marshaled like AisdWireMessage)
// ---------------------------------------------------------------------------------------

/// [`InputEvent::MouseMove`] discriminator (`kind`).
pub const AISD_INPUT_MOUSE_MOVE: u8 = 1;
/// [`InputEvent::MouseDown`] discriminator.
pub const AISD_INPUT_MOUSE_DOWN: u8 = 2;
/// [`InputEvent::MouseUp`] discriminator.
pub const AISD_INPUT_MOUSE_UP: u8 = 3;
/// [`InputEvent::Scroll`] discriminator.
pub const AISD_INPUT_SCROLL: u8 = 4;
/// [`InputEvent::Key`] discriminator.
pub const AISD_INPUT_KEY: u8 = 5;
/// [`InputEvent::Text`] discriminator.
pub const AISD_INPUT_TEXT: u8 = 6;
/// [`InputEvent::MouseDrag`] discriminator.
pub const AISD_INPUT_MOUSE_DRAG: u8 = 7;

/// A client→host input event, flattened for the C ABI.
///
/// `kind` (`AISD_INPUT_*`) selects which fields are meaningful; `tag` (the self-inject filter)
/// is valid for EVERY kind. Field usage: `MOUSE_MOVE` → `x`/`y`; `MOUSE_DOWN`/`MOUSE_UP`/
/// `MOUSE_DRAG` → `button`/`click_count`/`modifiers`/`x`/`y`; `SCROLL` → `dx`/`dy`/`x`/`y`/
/// `scroll_phase`/`momentum_phase`/`continuous`; `KEY` → `key_code`/`down`/`modifiers`; `TEXT`
/// → `text` (UTF-8, owned out via [`aisd_input_event_free`] / borrowed in).
#[repr(C)]
pub struct AisdInputEvent {
    /// Message discriminator (`AISD_INPUT_*`).
    pub kind: u8,
    /// Self-inject filter tag (valid for every kind).
    pub tag: u32,
    /// Normalised (0..1) x (`MOVE`/`DOWN`/`UP`/`DRAG`/`SCROLL`).
    pub x: f64,
    /// Normalised (0..1) y.
    pub y: f64,
    /// `SCROLL` horizontal delta (pixels).
    pub dx: f64,
    /// `SCROLL` vertical delta (pixels).
    pub dy: f64,
    /// Mouse button raw (`0`=left, `1`=right, `2`=other) for `DOWN`/`UP`/`DRAG`.
    pub button: u8,
    /// Originating click count for `DOWN`/`UP`/`DRAG`.
    pub click_count: u8,
    /// Modifier bitmask for `DOWN`/`UP`/`DRAG`/`KEY`.
    pub modifiers: u8,
    /// `SCROLL` `CGScrollPhase` code (carried opaquely).
    pub scroll_phase: u8,
    /// `SCROLL` `CGMomentumScrollPhase` code (carried opaquely).
    pub momentum_phase: u8,
    /// `SCROLL` pixel-precise flag (`0`/nonzero, read `!= 0`).
    pub continuous: u8,
    /// `KEY` host virtual keycode.
    pub key_code: u16,
    /// `KEY` down flag (`0`/nonzero, read `!= 0`).
    pub down: u8,
    /// `TEXT` UTF-8 bytes (owned out / borrowed in; [`AisdBytes::EMPTY`] otherwise).
    pub text: AisdBytes,
}

impl AisdInputEvent {
    /// An all-zero struct with an empty text buffer — the base every decode fills in.
    const fn zeroed() -> Self {
        Self {
            kind: 0,
            tag: 0,
            x: 0.0,
            y: 0.0,
            dx: 0.0,
            dy: 0.0,
            button: 0,
            click_count: 0,
            modifiers: 0,
            scroll_phase: 0,
            momentum_phase: 0,
            continuous: 0,
            key_code: 0,
            down: 0,
            text: AisdBytes::EMPTY,
        }
    }
}

/// Rebuilds a core [`InputEvent`] from the caller's C struct, validating the `kind`, the mouse
/// button, and any UTF-8 text.
///
/// # Safety
/// A non-empty `text` in `m` must point to that many readable bytes.
unsafe fn c_to_input_event(m: &AisdInputEvent) -> Result<InputEvent, AisdStatus> {
    let normalized = VideoPoint::new(m.x, m.y);
    let modifiers = InputModifiers(m.modifiers);
    let event = match m.kind {
        AISD_INPUT_MOUSE_MOVE => InputEvent::MouseMove {
            normalized,
            tag: m.tag,
        },
        AISD_INPUT_MOUSE_DOWN | AISD_INPUT_MOUSE_UP | AISD_INPUT_MOUSE_DRAG => {
            let button = MouseButton::from_u8(m.button).ok_or(AISD_ERR_INVALID_ARGUMENT)?;
            let click_count = m.click_count;
            match m.kind {
                AISD_INPUT_MOUSE_DOWN => InputEvent::MouseDown {
                    button,
                    normalized,
                    click_count,
                    modifiers,
                    tag: m.tag,
                },
                AISD_INPUT_MOUSE_UP => InputEvent::MouseUp {
                    button,
                    normalized,
                    click_count,
                    modifiers,
                    tag: m.tag,
                },
                _ => InputEvent::MouseDrag {
                    button,
                    normalized,
                    click_count,
                    modifiers,
                    tag: m.tag,
                },
            }
        }
        AISD_INPUT_SCROLL => InputEvent::Scroll {
            dx: m.dx,
            dy: m.dy,
            normalized,
            scroll_phase: m.scroll_phase,
            momentum_phase: m.momentum_phase,
            continuous: m.continuous != 0,
            tag: m.tag,
        },
        AISD_INPUT_KEY => InputEvent::Key {
            key_code: m.key_code,
            down: m.down != 0,
            modifiers,
            tag: m.tag,
        },
        AISD_INPUT_TEXT => {
            let text = String::from_utf8(copy_in(m.text)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?;
            InputEvent::Text { text, tag: m.tag }
        }
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(event)
}

/// Flattens a core [`InputEvent`] into the C struct, allocating an owned buffer for text.
fn input_event_to_c(e: &InputEvent) -> AisdInputEvent {
    let mut out = AisdInputEvent::zeroed();
    out.kind = e.message_type();
    out.tag = e.tag();
    match e {
        InputEvent::MouseMove { normalized, .. } => {
            out.x = normalized.x;
            out.y = normalized.y;
        }
        InputEvent::MouseDown {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        }
        | InputEvent::MouseUp {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        }
        | InputEvent::MouseDrag {
            button,
            normalized,
            click_count,
            modifiers,
            ..
        } => {
            out.button = button.raw();
            out.click_count = *click_count;
            out.modifiers = modifiers.raw();
            out.x = normalized.x;
            out.y = normalized.y;
        }
        InputEvent::Scroll {
            dx,
            dy,
            normalized,
            scroll_phase,
            momentum_phase,
            continuous,
            ..
        } => {
            out.dx = *dx;
            out.dy = *dy;
            out.x = normalized.x;
            out.y = normalized.y;
            out.scroll_phase = *scroll_phase;
            out.momentum_phase = *momentum_phase;
            out.continuous = u8::from(*continuous);
        }
        InputEvent::Key {
            key_code,
            down,
            modifiers,
            ..
        } => {
            out.key_code = *key_code;
            out.down = u8::from(*down);
            out.modifiers = modifiers.raw();
        }
        InputEvent::Text { text, .. } => out.text = bytes_from_vec(text.clone().into_bytes()),
    }
    out
}

/// Encodes a caller-built [`AisdInputEvent`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`
/// / out-of-range `button` / non-UTF-8 `text`.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; a non-empty `text` inside `*msg` must
/// point to that many readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_input_event_encode(
    msg: *const AisdInputEvent,
    out: *mut AisdBytes,
) -> AisdStatus {
    if msg.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    match c_to_input_event(&*msg) {
        Ok(event) => {
            out.write(bytes_from_vec(event.encode()));
            AISD_OK
        }
        Err(status) => status,
    }
}

/// Decodes an input event into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `text` buffer — release with [`aisd_input_event_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / unknown button /
/// non-UTF-8 text / unknown type to [`AISD_ERR_MALFORMED`] and a short body to
/// [`AISD_ERR_TRUNCATED`].
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_input_event_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdInputEvent,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match InputEvent::decode(slice_in(data, len)) {
        Ok(event) => {
            out.write(input_event_to_c(&event));
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

/// Releases the owned `text` buffer inside an [`AisdInputEvent`] and resets it to empty.
/// Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdInputEvent`] previously filled by this library.
#[no_mangle]
pub unsafe extern "C" fn aisd_input_event_free(msg: *mut AisdInputEvent) {
    if msg.is_null() {
        return;
    }
    let m = &mut *msg;
    drop_bytes(m.text);
    m.text = AisdBytes::EMPTY;
}

// ---------------------------------------------------------------------------------------
// video_control — PATH-2 session bring-up control (hello/ack/bye/resize/keepalive/cadence +
// the two window/dialog discovery LISTS). Occasional (session setup + slow discovery poll),
// so the marshaling cost is irrelevant; the two list variants carry an array of summary
// records, each with two owned strings — the one nested-array codec in the protocol.
// ---------------------------------------------------------------------------------------

/// [`VideoControlMessage::Hello`] discriminator (`kind`).
pub const AISD_VIDEO_CONTROL_HELLO: u8 = 1;
/// [`VideoControlMessage::HelloAck`] discriminator.
pub const AISD_VIDEO_CONTROL_HELLO_ACK: u8 = 2;
/// [`VideoControlMessage::Bye`] discriminator.
pub const AISD_VIDEO_CONTROL_BYE: u8 = 3;
/// [`VideoControlMessage::ResizeRequest`] discriminator.
pub const AISD_VIDEO_CONTROL_RESIZE_REQUEST: u8 = 4;
/// [`VideoControlMessage::ResizeAck`] discriminator.
pub const AISD_VIDEO_CONTROL_RESIZE_ACK: u8 = 5;
/// [`VideoControlMessage::Keepalive`] discriminator.
pub const AISD_VIDEO_CONTROL_KEEPALIVE: u8 = 6;
/// [`VideoControlMessage::ListWindows`] discriminator.
pub const AISD_VIDEO_CONTROL_LIST_WINDOWS: u8 = 7;
/// [`VideoControlMessage::WindowList`] discriminator.
pub const AISD_VIDEO_CONTROL_WINDOW_LIST: u8 = 8;
/// [`VideoControlMessage::FocusWindow`] discriminator.
pub const AISD_VIDEO_CONTROL_FOCUS_WINDOW: u8 = 9;
/// [`VideoControlMessage::StreamCadence`] discriminator.
pub const AISD_VIDEO_CONTROL_STREAM_CADENCE: u8 = 10;
/// [`VideoControlMessage::ListSystemDialogs`] discriminator.
pub const AISD_VIDEO_CONTROL_LIST_SYSTEM_DIALOGS: u8 = 11;
/// [`VideoControlMessage::SystemDialogList`] discriminator.
pub const AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST: u8 = 12;

/// One window/dialog summary record, flattened for the C ABI — the element type of the
/// `WindowList` / `SystemDialogList` record arrays.
///
/// Both list variants share this struct: for a `WindowList` record `name` is the application
/// name and `is_secure` / `keystrokes_blocked` are unused (`0`); for a `SystemDialogList` record
/// `name` is the owning process, `is_secure` is the secure-prompt CLASS flag and
/// `keystrokes_blocked` is the live "synthetic typing is dropped right now" flag. On a decode `out`
/// the `name` / `title` buffers own Rust allocations (released together by
/// [`aisd_video_control_free`]); on an encode input they are borrowed `(ptr, len)` (`cap` ignored)
/// or [`AisdBytes::EMPTY`].
#[repr(C)]
pub struct AisdVideoSummary {
    /// Host `CGWindowID`.
    pub window_id: u32,
    /// Window/dialog width in points.
    pub width: u16,
    /// Window/dialog height in points.
    pub height: u16,
    /// `SystemDialogList` secure-prompt CLASS flag (`0`/`1`); unused (`0`) for `WindowList`.
    pub is_secure: u8,
    /// `SystemDialogList` live "synthetic keystrokes dropped right now" flag (`0`/`1`); unused (`0`)
    /// for `WindowList`. Distinct from `is_secure` (the static class) — see
    /// [`SystemDialogSummary::keystrokes_blocked`](aislopdesk_core::video_control::SystemDialogSummary).
    pub keystrokes_blocked: u8,
    /// `WindowList` app name / `SystemDialogList` owner (UTF-8; owned out / borrowed in).
    pub name: AisdBytes,
    /// The window/dialog title (UTF-8; owned out / borrowed in).
    pub title: AisdBytes,
}

/// A PATH-2 video control message, flattened for the C ABI.
///
/// `kind` (`AISD_VIDEO_CONTROL_*`) selects which fields are meaningful; unused numeric fields are
/// `0` and the record array is empty (`records` null, `records_len` 0). Field usage:
/// `HELLO` → `protocol_version`/`requested_window_id`/`viewport_*`; `HELLO_ACK` → `accepted`/
/// `stream_id`/`capture_*`/`full_range`/`bounds_*`; `RESIZE_REQUEST` → `desired_*`/`epoch`;
/// `RESIZE_ACK` → `capture_*`/`epoch`; `STREAM_CADENCE` → `fps`; `WINDOW_LIST` /
/// `SYSTEM_DIALOG_LIST` → `records`/`records_len`; the zero-body kinds use none. On a decode `out`
/// the `records` array owns a Rust allocation (released by [`aisd_video_control_free`]); on an
/// encode input it is a borrowed `(records, records_len)` the library copies and never frees.
/// Field order MUST match the C header's `AisdVideoControl`.
#[repr(C)]
pub struct AisdVideoControl {
    /// Message discriminator (`AISD_VIDEO_CONTROL_*`).
    pub kind: u8,
    /// `HELLO.protocol_version`.
    pub protocol_version: u16,
    /// `HELLO.requested_window_id`.
    pub requested_window_id: u32,
    /// `HELLO.viewport` width (points).
    pub viewport_w: f64,
    /// `HELLO.viewport` height (points).
    pub viewport_h: f64,
    /// `HELLO_ACK.accepted` (`0`/`1`, read `!= 0`).
    pub accepted: u8,
    /// `HELLO_ACK.stream_id`.
    pub stream_id: u32,
    /// `HELLO_ACK.full_range` (`0`/`1`, read `!= 0`).
    pub full_range: u8,
    /// `HELLO_ACK` window bounds origin x (CG-top-left).
    pub bounds_x: f64,
    /// `HELLO_ACK` window bounds origin y.
    pub bounds_y: f64,
    /// `HELLO_ACK` window bounds width.
    pub bounds_w: f64,
    /// `HELLO_ACK` window bounds height.
    pub bounds_h: f64,
    /// Negotiated capture width (`HELLO_ACK` / `RESIZE_ACK`).
    pub capture_width: u16,
    /// Negotiated capture height (`HELLO_ACK` / `RESIZE_ACK`).
    pub capture_height: u16,
    /// `RESIZE_REQUEST.desired` width (points).
    pub desired_w: f64,
    /// `RESIZE_REQUEST.desired` height (points).
    pub desired_h: f64,
    /// Request epoch (`RESIZE_REQUEST` / `RESIZE_ACK`).
    pub epoch: u32,
    /// `STREAM_CADENCE.fps` (content cadence in frames per second).
    pub fps: u16,
    /// `WINDOW_LIST` / `SYSTEM_DIALOG_LIST` record array (owned out / borrowed in; null otherwise).
    pub records: *mut AisdVideoSummary,
    /// Number of records at `records`.
    pub records_len: usize,
}

impl AisdVideoControl {
    /// An all-zero struct with an empty record array — the base every decode fills in.
    const fn zeroed() -> Self {
        Self {
            kind: 0,
            protocol_version: 0,
            requested_window_id: 0,
            viewport_w: 0.0,
            viewport_h: 0.0,
            accepted: 0,
            stream_id: 0,
            full_range: 0,
            bounds_x: 0.0,
            bounds_y: 0.0,
            bounds_w: 0.0,
            bounds_h: 0.0,
            capture_width: 0,
            capture_height: 0,
            desired_w: 0.0,
            desired_h: 0.0,
            epoch: 0,
            fps: 0,
            records: core::ptr::null_mut(),
            records_len: 0,
        }
    }
}

/// Borrows a caller-supplied record array as a slice (empty for `len == 0` or a null pointer).
///
/// # Safety
/// If `len != 0` and `records` is non-null, it must point to at least `len` readable
/// [`AisdVideoSummary`] values.
const unsafe fn records_slice<'a>(
    records: *const AisdVideoSummary,
    len: usize,
) -> &'a [AisdVideoSummary] {
    if len == 0 || records.is_null() {
        &[]
    } else {
        core::slice::from_raw_parts(records, len)
    }
}

/// Rebuilds the core [`WindowSummary`] list from a borrowed C record array, validating UTF-8.
///
/// # Safety
/// Each record's non-empty `name` / `title` must point to that many readable bytes.
unsafe fn c_to_window_summaries(
    records: *const AisdVideoSummary,
    len: usize,
) -> Result<Vec<WindowSummary>, AisdStatus> {
    let slice = records_slice(records, len);
    let mut out = Vec::with_capacity(slice.len());
    for r in slice {
        out.push(WindowSummary {
            window_id: r.window_id,
            app_name: String::from_utf8(copy_in(r.name)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            title: String::from_utf8(copy_in(r.title)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            width: r.width,
            height: r.height,
        });
    }
    Ok(out)
}

/// Rebuilds the core [`SystemDialogSummary`] list from a borrowed C record array, validating UTF-8.
///
/// # Safety
/// Each record's non-empty `name` / `title` must point to that many readable bytes.
unsafe fn c_to_dialog_summaries(
    records: *const AisdVideoSummary,
    len: usize,
) -> Result<Vec<SystemDialogSummary>, AisdStatus> {
    let slice = records_slice(records, len);
    let mut out = Vec::with_capacity(slice.len());
    for r in slice {
        out.push(SystemDialogSummary {
            window_id: r.window_id,
            owner: String::from_utf8(copy_in(r.name)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            title: String::from_utf8(copy_in(r.title)).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            width: r.width,
            height: r.height,
            is_secure: r.is_secure != 0,
            keystrokes_blocked: r.keystrokes_blocked != 0,
        });
    }
    Ok(out)
}

/// Rebuilds a core [`VideoControlMessage`] from the caller's C struct, validating the `kind` and
/// any UTF-8 record strings.
///
/// # Safety
/// For a list `kind`, a non-empty `records` must point to that many readable
/// [`AisdVideoSummary`] values, each with valid `name` / `title` buffers.
unsafe fn c_to_video_control(m: &AisdVideoControl) -> Result<VideoControlMessage, AisdStatus> {
    let message = match m.kind {
        AISD_VIDEO_CONTROL_HELLO => VideoControlMessage::Hello {
            protocol_version: m.protocol_version,
            requested_window_id: m.requested_window_id,
            viewport: VideoSize::new(m.viewport_w, m.viewport_h),
        },
        AISD_VIDEO_CONTROL_HELLO_ACK => VideoControlMessage::HelloAck {
            accepted: m.accepted != 0,
            stream_id: m.stream_id,
            capture_width: m.capture_width,
            capture_height: m.capture_height,
            window_bounds_cg: VideoRect::xywh(m.bounds_x, m.bounds_y, m.bounds_w, m.bounds_h),
            full_range: m.full_range != 0,
        },
        AISD_VIDEO_CONTROL_BYE => VideoControlMessage::Bye,
        AISD_VIDEO_CONTROL_RESIZE_REQUEST => VideoControlMessage::ResizeRequest {
            desired: VideoSize::new(m.desired_w, m.desired_h),
            epoch: m.epoch,
        },
        AISD_VIDEO_CONTROL_RESIZE_ACK => VideoControlMessage::ResizeAck {
            capture_width: m.capture_width,
            capture_height: m.capture_height,
            epoch: m.epoch,
        },
        AISD_VIDEO_CONTROL_KEEPALIVE => VideoControlMessage::Keepalive,
        AISD_VIDEO_CONTROL_LIST_WINDOWS => VideoControlMessage::ListWindows,
        AISD_VIDEO_CONTROL_WINDOW_LIST => {
            VideoControlMessage::WindowList(c_to_window_summaries(m.records, m.records_len)?)
        }
        AISD_VIDEO_CONTROL_FOCUS_WINDOW => VideoControlMessage::FocusWindow,
        AISD_VIDEO_CONTROL_STREAM_CADENCE => VideoControlMessage::StreamCadence { fps: m.fps },
        AISD_VIDEO_CONTROL_LIST_SYSTEM_DIALOGS => VideoControlMessage::ListSystemDialogs,
        AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST => {
            VideoControlMessage::SystemDialogList(c_to_dialog_summaries(m.records, m.records_len)?)
        }
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(message)
}

/// Moves a `Vec` of summary records across the boundary as a raw `(ptr, len)` the caller releases
/// via [`aisd_video_control_free`]. An empty vec yields `(null, 0)` (no allocation).
fn summaries_into_raw(records: Vec<AisdVideoSummary>) -> (*mut AisdVideoSummary, usize) {
    if records.is_empty() {
        return (core::ptr::null_mut(), 0);
    }
    let len = records.len();
    // `into_boxed_slice` guarantees `cap == len`, so the matching `from_raw_parts_mut` in
    // `drop_summaries` reconstructs the exact same allocation.
    let mut boxed = records.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    core::mem::forget(boxed);
    (ptr, len)
}

/// Builds one C summary record, allocating owned buffers for its two strings.
fn summary_to_c(
    window_id: u32,
    width: u16,
    height: u16,
    is_secure: bool,
    keystrokes_blocked: bool,
    name: &str,
    title: &str,
) -> AisdVideoSummary {
    AisdVideoSummary {
        window_id,
        width,
        height,
        is_secure: u8::from(is_secure),
        keystrokes_blocked: u8::from(keystrokes_blocked),
        name: bytes_from_vec(name.as_bytes().to_vec()),
        title: bytes_from_vec(title.as_bytes().to_vec()),
    }
}

/// Flattens a core [`VideoControlMessage`] into the C struct, allocating an owned record array
/// (with owned per-record strings) for the two list variants.
fn video_control_to_c(message: &VideoControlMessage) -> AisdVideoControl {
    let mut out = AisdVideoControl::zeroed();
    out.kind = message.message_type();
    match message {
        VideoControlMessage::Hello {
            protocol_version,
            requested_window_id,
            viewport,
        } => {
            out.protocol_version = *protocol_version;
            out.requested_window_id = *requested_window_id;
            out.viewport_w = viewport.width;
            out.viewport_h = viewport.height;
        }
        VideoControlMessage::HelloAck {
            accepted,
            stream_id,
            capture_width,
            capture_height,
            window_bounds_cg,
            full_range,
        } => {
            out.accepted = u8::from(*accepted);
            out.stream_id = *stream_id;
            out.capture_width = *capture_width;
            out.capture_height = *capture_height;
            out.full_range = u8::from(*full_range);
            out.bounds_x = window_bounds_cg.origin.x;
            out.bounds_y = window_bounds_cg.origin.y;
            out.bounds_w = window_bounds_cg.size.width;
            out.bounds_h = window_bounds_cg.size.height;
        }
        VideoControlMessage::Bye
        | VideoControlMessage::Keepalive
        | VideoControlMessage::ListWindows
        | VideoControlMessage::FocusWindow
        | VideoControlMessage::ListSystemDialogs => {}
        VideoControlMessage::ResizeRequest { desired, epoch } => {
            out.desired_w = desired.width;
            out.desired_h = desired.height;
            out.epoch = *epoch;
        }
        VideoControlMessage::ResizeAck {
            capture_width,
            capture_height,
            epoch,
        } => {
            out.capture_width = *capture_width;
            out.capture_height = *capture_height;
            out.epoch = *epoch;
        }
        VideoControlMessage::StreamCadence { fps } => out.fps = *fps,
        VideoControlMessage::WindowList(windows) => {
            let recs: Vec<AisdVideoSummary> = windows
                .iter()
                .map(|w| {
                    summary_to_c(
                        w.window_id,
                        w.width,
                        w.height,
                        false,
                        false,
                        &w.app_name,
                        &w.title,
                    )
                })
                .collect();
            let (ptr, len) = summaries_into_raw(recs);
            out.records = ptr;
            out.records_len = len;
        }
        VideoControlMessage::SystemDialogList(dialogs) => {
            let recs: Vec<AisdVideoSummary> = dialogs
                .iter()
                .map(|d| {
                    summary_to_c(
                        d.window_id,
                        d.width,
                        d.height,
                        d.is_secure,
                        d.keystrokes_blocked,
                        &d.owner,
                        &d.title,
                    )
                })
                .collect();
            let (ptr, len) = summaries_into_raw(recs);
            out.records = ptr;
            out.records_len = len;
        }
    }
    out
}

/// Reconstructs and drops the owned record array behind a decoded [`AisdVideoControl`], freeing
/// each record's `name` / `title` buffer first. No-op on a null pointer.
///
/// # Safety
/// `ptr` / `len` must be a record array previously produced by [`summaries_into_raw`] and not yet
/// freed.
unsafe fn drop_summaries(ptr: *mut AisdVideoSummary, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let boxed: Box<[AisdVideoSummary]> =
        Box::from_raw(core::ptr::slice_from_raw_parts_mut(ptr, len));
    for rec in &boxed {
        drop_bytes(rec.name);
        drop_bytes(rec.title);
    }
    drop(boxed);
}

/// Encodes a caller-built [`AisdVideoControl`] into its wire form.
///
/// On [`AISD_OK`], `*out` owns the buffer — release with [`crate::aisd_bytes_free`]. Returns
/// [`AISD_ERR_NULL`] for a null argument or [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `kind`
/// / non-UTF-8 record string.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; for a list `kind`, a non-empty `records`
/// inside `*msg` must point to that many readable [`AisdVideoSummary`] values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_video_control_encode(
    msg: *const AisdVideoControl,
    out: *mut AisdBytes,
) -> AisdStatus {
    if msg.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    match c_to_video_control(&*msg) {
        Ok(message) => {
            out.write(bytes_from_vec(message.encode()));
            AISD_OK
        }
        Err(status) => status,
    }
}

/// Decodes a video control message into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `records` array — release with [`aisd_video_control_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / unknown type to
/// [`AISD_ERR_MALFORMED`] and a short body to [`AISD_ERR_TRUNCATED`] (record strings decode
/// lossily, never malformed).
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_video_control_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdVideoControl,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match VideoControlMessage::decode(slice_in(data, len)) {
        Ok(message) => {
            out.write(video_control_to_c(&message));
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

/// Releases the owned `records` array inside an [`AisdVideoControl`] (and every record's `name` /
/// `title` buffer) and resets it to empty. Idempotent; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdVideoControl`] previously filled by this library.
#[no_mangle]
pub unsafe extern "C" fn aisd_video_control_free(msg: *mut AisdVideoControl) {
    if msg.is_null() {
        return;
    }
    let m = &mut *msg;
    drop_summaries(m.records, m.records_len);
    m.records = core::ptr::null_mut();
    m.records_len = 0;
}

// ---------------------------------------------------------------------------------------
// adaptive_fec — pure, scalar (tier/next_tier_state ~per netstats report; group_size on the
// reassemble/packetize path; FFI overhead negligible vs decode/encode)
// ---------------------------------------------------------------------------------------

/// Tier-decision state for the dwell-gated adaptive-FEC variant, flattened for the C ABI.
///
/// Mirrors [`adaptive_fec::TierState`] field-for-field (`#[repr(C)]`, same field order). Crosses
/// by value in both directions.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdTierState {
    /// Current wire tier (0..=7 on the wire; any `u8` is total).
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
}

impl From<adaptive_fec::TierState> for AisdTierState {
    fn from(s: adaptive_fec::TierState) -> Self {
        Self {
            tier: s.tier,
            relax_streak: s.relax_streak,
            sticky_relax_remaining: s.sticky_relax_remaining,
        }
    }
}

impl From<AisdTierState> for adaptive_fec::TierState {
    fn from(s: AisdTierState) -> Self {
        Self::new(s.tier, s.relax_streak, s.sticky_relax_remaining)
    }
}

/// Maps a wire tier to the FEC group size both ends must use.
///
/// Wraps
/// [`adaptive_fec::group_size`]. Returns `1` and writes the group size to `*out` for a parity
/// tier; returns `0` for the OFF (no-parity) tier (leaving `*out` untouched — treat as nil).
/// TOTAL over every `tier` (unknown → `default_group_size`, never traps). A null `out` returns
/// `0` without writing.
///
/// # Safety
/// `out`, if non-null, must be a writable `usize` pointer.
#[must_use]
#[no_mangle]
pub const unsafe extern "C" fn aisd_adaptive_fec_group_size(
    tier: u8,
    default_group_size: usize,
    out: *mut usize,
) -> u8 {
    match adaptive_fec::group_size(tier, default_group_size) {
        // Return `1` only when a size was actually written, so the return is a clean
        // postcondition (`1` ⟺ `*out` holds a valid group size). A null `out` (caller error)
        // yields `0` like the OFF tier — nothing written, no UB.
        Some(g) if !out.is_null() => {
            out.write(g);
            1
        }
        _ => 0,
    }
}

/// Picks the next wire tier from the EWMA `loss` and the `previous_tier` (the plain decider;
/// the production host uses [`aisd_adaptive_fec_next_tier_state`]).
///
/// Wraps [`adaptive_fec::tier`].
/// `allow_off` is the OFF-tier escape hatch resolved by the caller from `AISLOPDESK_FEC_ALLOW_OFF`
/// (read `!= 0`), keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_tier(loss: f64, previous_tier: u8, allow_off: u8) -> u8 {
    adaptive_fec::tier(loss, previous_tier, allow_off != 0)
}

/// Dwell-gated tier step — the production entry point.
///
/// Wraps [`adaptive_fec::next_tier_state`]:
/// escalation is immediate (one step, resets the relax streak); relaxation is counted across
/// consecutive relax-demanding reports and applied at the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Returns the next state by value.
/// `allow_off` / `saw_unrecovered_loss` are bytes read `!= 0`; the caller resolves `allow_off`
/// from the environment and passes `dwell`, keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_next_tier_state(
    loss: f64,
    state: AisdTierState,
    dwell: i32,
    allow_off: u8,
    saw_unrecovered_loss: u8,
) -> AisdTierState {
    adaptive_fec::next_tier_state(
        loss,
        state.into(),
        dwell,
        allow_off != 0,
        saw_unrecovered_loss != 0,
    )
    .into()
}

// ---------------------------------------------------------------------------------------
// coordinate_mapping — pure, scalar (per pointer event; FFI cost dwarfed by the CGEvent
// post it precedes, so it swaps unconditionally — no per-frame buffers)
// ---------------------------------------------------------------------------------------

/// A 2-D point in host points, flattened for the C ABI (field-for-field [`VideoPoint`]).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPoint {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl AisdPoint {
    const fn to_core(self) -> VideoPoint {
        VideoPoint::new(self.x, self.y)
    }
    const fn from_core(p: VideoPoint) -> Self {
        Self { x: p.x, y: p.y }
    }
}

/// A rectangle (origin + size), flattened for the C ABI (`x, y, width, height`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdRect {
    /// Origin x.
    pub x: f64,
    /// Origin y.
    pub y: f64,
    /// Extent width.
    pub width: f64,
    /// Extent height.
    pub height: f64,
}

impl AisdRect {
    const fn to_core(self) -> VideoRect {
        VideoRect::xywh(self.x, self.y, self.width, self.height)
    }
    const fn from_core(r: VideoRect) -> Self {
        Self {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        }
    }
}

/// A display (Cocoa-bottom-left frame + Retina backing scale), flattened for the C ABI.
/// Passed in as a borrowed array, never freed by Rust.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdScreenInfo {
    /// The screen's frame in Cocoa bottom-left space (`NSScreen.frame`).
    pub cocoa_frame: AisdRect,
    /// `NSScreen.backingScaleFactor` (1.0 standard, 2.0 Retina).
    pub backing_scale_factor: f64,
}

impl AisdScreenInfo {
    const fn to_core(self) -> ScreenInfo {
        ScreenInfo::new(self.cocoa_frame.to_core(), self.backing_scale_factor)
    }
}

/// Maps a normalised (0..1) window point to a host-window point in CG top-left space (no Y
/// flip, no scale). Wraps [`coordinate_mapping::window_point`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_window_point(
    normalized: AisdPoint,
    window_bounds: AisdRect,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point(
        normalized.to_core(),
        window_bounds.to_core(),
    ))
}

/// Flips a CG-top-left rect into Cocoa bottom-left space given the primary display height.
/// Wraps [`coordinate_mapping::cg_rect_to_cocoa`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_cg_rect_to_cocoa(cg_rect: AisdRect, primary_height: f64) -> AisdRect {
    AisdRect::from_core(coordinate_mapping::cg_rect_to_cocoa(
        cg_rect.to_core(),
        primary_height,
    ))
}

/// Picks the screen a window lives on (largest overlap) and writes its `backing_scale_factor`
/// to `*out_scale`.
///
/// Wraps [`coordinate_mapping::backing_scale_factor`]. Returns [`AISD_OK`]
/// (overlap; `*out_scale` written), [`AISD_EMPTY`] (no overlap; `*out_scale` untouched), or
/// [`AISD_ERR_NULL`] if `out_scale` is null, or `screens` is null while `screen_count != 0`.
/// `screens` is borrowed for the call only.
///
/// # Safety
/// `out_scale` must be a writable `f64`; if `screen_count != 0`, `screens` must point to at
/// least `screen_count` readable [`AisdScreenInfo`] values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_coord_backing_scale_factor(
    window_bounds_cg: AisdRect,
    screens: *const AisdScreenInfo,
    screen_count: usize,
    primary_height: f64,
    out_scale: *mut f64,
) -> AisdStatus {
    if out_scale.is_null() || (screens.is_null() && screen_count != 0) {
        return AISD_ERR_NULL;
    }
    let core_screens: Vec<ScreenInfo> = if screen_count == 0 {
        Vec::new()
    } else {
        core::slice::from_raw_parts(screens, screen_count)
            .iter()
            .map(|s| s.to_core())
            .collect()
    };
    coordinate_mapping::backing_scale_factor(
        window_bounds_cg.to_core(),
        &core_screens,
        primary_height,
    )
    .map_or(AISD_EMPTY, |scale| {
        out_scale.write(scale);
        AISD_OK
    })
}

/// Pixel path: divide by `backing_scale_factor` to get points, then add the window origin.
/// Wraps [`coordinate_mapping::window_point_from_pixel`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_window_point_from_pixel(
    pixel: AisdPoint,
    window_bounds_cg: AisdRect,
    backing_scale_factor: f64,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point_from_pixel(
        pixel.to_core(),
        window_bounds_cg.to_core(),
        backing_scale_factor,
    ))
}

// ---------------------------------------------------------------------------------------
// recovery_policy — pure, scalar (per gated frame on the client recovery clock)
// ---------------------------------------------------------------------------------------

/// Whether the client should escalate a stalled LTR-refresh recovery to a forced IDR,
///
/// given
/// the configured policy multiples, time since the first request, the RTT estimate, and
/// whether it is observing loss.
///
/// Wraps [`RecoveryPolicy::should_escalate_to_idr`].
///
/// `observing_loss` crosses as a byte read `!= 0`. The lossy escalation floor (`lossy_floor_s`,
/// from `AISLOPDESK_ESCALATION_FLOOR_MS`) is resolved by the caller and passed in, keeping the
/// core environment-free. Returns `1` to escalate, `0` otherwise. The four multiples map
/// field-for-field onto [`RecoveryPolicy`].
#[must_use]
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn aisd_recovery_policy_should_escalate_to_idr(
    idr_rtt_mult: f64,
    lossy_idr_rtt_mult: f64,
    lossy_floor_s: f64,
    lossy_floor_rtt_mult: f64,
    elapsed_since_request: f64,
    rtt: f64,
    observing_loss: u8,
) -> u8 {
    let policy = RecoveryPolicy::new(
        idr_rtt_mult,
        lossy_idr_rtt_mult,
        lossy_floor_s,
        lossy_floor_rtt_mult,
    );
    u8::from(policy.should_escalate_to_idr(elapsed_since_request, rtt, observing_loss != 0))
}

// ---------------------------------------------------------------------------------------
// window_placement — pure, flat-struct (HiDPI VD-park path; occasional, never per-frame)
// ---------------------------------------------------------------------------------------

/// The result of [`window_placement::placement`], flattened for the C ABI.
///
/// The move-target origin (`x`, `y`), the clamped window size (`width`, `height`), and
/// `needs_resize` (a byte, `1` = the window overhangs the display by >½ pt and must be shrunk
/// before the move).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPlacement {
    /// Move-target origin x (the display's top-left x, returned verbatim).
    pub x: f64,
    /// Move-target origin y.
    pub y: f64,
    /// Clamped window width (`min(window, display)`).
    pub width: f64,
    /// Clamped window height.
    pub height: f64,
    /// `1` if the window must be resized DOWN before the move, else `0`.
    pub needs_resize: u8,
}

/// Clamp a window of `window_w × window_h` to `display` (shrink-only) and place it at the
/// display's top-left origin. Wraps [`window_placement::placement`]. Pure; never fails.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_window_placement(
    window_w: f64,
    window_h: f64,
    display: AisdRect,
) -> AisdPlacement {
    let p = window_placement::placement(VideoSize::new(window_w, window_h), display.to_core());
    AisdPlacement {
        x: p.origin.x,
        y: p.origin.y,
        width: p.size.width,
        height: p.size.height,
        needs_resize: u8::from(p.needs_resize),
    }
}

/// Whether a window of `size_w × size_h` fits inside `bounds` (½-pt tolerance). Returns `1` if it
/// fits, `0` otherwise. Wraps [`window_placement::fits`]. Pure; never fails.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_window_fits(size_w: f64, size_h: f64, bounds: AisdRect) -> u8 {
    u8::from(window_placement::fits(
        VideoSize::new(size_w, size_h),
        bounds.to_core(),
    ))
}

// ---------------------------------------------------------------------------------------
// virtual_display_geometry — pure scalar (VD creation path; startup-or-rare)
// ---------------------------------------------------------------------------------------

/// A virtual-display geometry: the clamped input fields plus the derived framebuffer pixel
/// dimensions and the chip-limit check.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdVDGeometry {
    /// Clamped logical width in points.
    pub point_width: i64,
    /// Clamped logical height in points.
    pub point_height: i64,
    /// Clamped backing scale (1 = standard, 2 = Retina).
    pub scale: i64,
    /// Clamped chip horizontal pixel ceiling.
    pub max_horizontal_pixels: i64,
    /// `point_width * scale`.
    pub pixel_width: i64,
    /// `point_height * scale`.
    pub pixel_height: i64,
    /// `1` if `pixel_width` exceeds the chip ceiling, else `0`.
    pub exceeds_pixel_limit: u8,
}

/// A physical millimetre size (width, height) for a virtual display descriptor.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdVDMillimeters {
    /// Physical width in millimetres.
    pub width: f64,
    /// Physical height in millimetres.
    pub height: f64,
}

/// Builds a (clamped) virtual-display geometry and returns its derived scalar fields. Wraps
/// [`VirtualDisplayGeometry::new`]. Pure; never fails.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_vd_geometry(
    point_width: i64,
    point_height: i64,
    scale: i64,
    max_horizontal_pixels: i64,
) -> AisdVDGeometry {
    let g = VirtualDisplayGeometry::new(point_width, point_height, scale, max_horizontal_pixels);
    AisdVDGeometry {
        point_width: g.point_width,
        point_height: g.point_height,
        scale: g.scale,
        max_horizontal_pixels: g.max_horizontal_pixels,
        pixel_width: g.pixel_width(),
        pixel_height: g.pixel_height(),
        exceeds_pixel_limit: u8::from(g.exceeds_pixel_limit()),
    }
}

/// Physical size in millimetres for a display of `pixel_width × pixel_height` at `target_ppi`
/// (non-finite / `< 1` ppi is clamped to `1.0`). Wraps
/// [`VirtualDisplayGeometry::size_in_millimeters`].
///
/// Built with `scale = 1` so the geometry's pixel dimensions equal the inputs verbatim,
/// preserving the exact `(pixel / ppi) * 25.4` op order for bit parity.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_vd_size_in_millimeters(
    pixel_width: i64,
    pixel_height: i64,
    target_ppi: f64,
) -> AisdVDMillimeters {
    let g = VirtualDisplayGeometry::new(pixel_width, pixel_height, 1, i64::MAX);
    let mm = g.size_in_millimeters(target_ppi);
    AisdVDMillimeters {
        width: mm.width,
        height: mm.height,
    }
}

/// The VD global origin flush to the right of the rightmost existing display.
///
/// Returns (`maxX`, `0`), or `(0, 0)` when there are no displays. Wraps
/// [`virtual_display_geometry::origin_to_right`]. `displays` is borrowed for the call only.
///
/// # Safety
/// If `display_count != 0`, `displays` must point to at least `display_count` readable
/// [`AisdRect`] values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_vd_origin_to_right(
    displays: *const AisdRect,
    display_count: usize,
) -> AisdPoint {
    let rects: Vec<VideoRect> = if display_count == 0 || displays.is_null() {
        Vec::new()
    } else {
        core::slice::from_raw_parts(displays, display_count)
            .iter()
            .map(|r| r.to_core())
            .collect()
    };
    AisdPoint::from_core(virtual_display_geometry::origin_to_right(&rects))
}

/// The chip's horizontal pixel ceiling from a CPU brand string (Pro/Max/Ultra → 7680, base
/// Apple M → 6144, else 7680). Wraps [`virtual_display_geometry::chip_pixel_limit`].
///
/// # Safety
/// `cpu_brand` must be a valid NUL-terminated C string, or null (treated as the default).
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_vd_chip_pixel_limit(cpu_brand: *const core::ffi::c_char) -> i64 {
    if cpu_brand.is_null() {
        return virtual_display_geometry::chip_pixel_limit("");
    }
    let s = core::ffi::CStr::from_ptr(cpu_brand).to_string_lossy();
    virtual_display_geometry::chip_pixel_limit(&s)
}

/// Writes the descending refresh-rate modes for a VD driven at `fps` into `rates` and returns
/// the count. Wraps [`virtual_display_geometry::refresh_rates`] (always 2 or 3 values).
///
/// Writes nothing (but still returns the needed count) if `rates` is null or `capacity` is
/// smaller than the count, so a caller can size a buffer; in practice 3 slots always suffice.
///
/// # Safety
/// If non-null, `rates` must point to at least `capacity` writable `f64` values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_vd_refresh_rates(
    fps: i64,
    rates: *mut f64,
    capacity: usize,
) -> usize {
    let v = virtual_display_geometry::refresh_rates(fps);
    if !rates.is_null() && capacity >= v.len() {
        for (i, r) in v.iter().enumerate() {
            rates.add(i).write(*r);
        }
    }
    v.len()
}

// ---------------------------------------------------------------------------------------
// capture_region — pure, flat-struct (dialog-expand capture math; AX-event-driven)
// ---------------------------------------------------------------------------------------

/// One window snapshot (`CGWindowListCopyWindowInfo` row) for capture-region math, flattened
/// for the C ABI. `frame` is the window's global bounds.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdCaptureWindowSnapshot {
    /// `kCGWindowNumber`.
    pub window_id: u32,
    /// `kCGWindowOwnerPID`.
    pub owner_pid: i32,
    /// `kCGWindowLayer`.
    pub layer: i64,
    /// Global window bounds.
    pub frame: AisdRect,
}

impl AisdCaptureWindowSnapshot {
    const fn to_core(self) -> capture_region::WindowSnapshot {
        capture_region::WindowSnapshot::new(
            self.window_id,
            self.owner_pid,
            self.layer,
            self.frame.to_core(),
        )
    }
}

/// The capture union region: the target window unioned with qualifying same-pid panels in
/// front of it, clamped to the display. Wraps [`capture_region::union_region`].
///
/// `windows_in_front` is borrowed for the call only. Pass
/// [`capture_region::DEFAULT_MIN_OVERLAP_FRACTION`] (`0.30`) for `min_overlap_fraction`.
///
/// # Safety
/// If `windows_count != 0`, `windows_in_front` must point to at least `windows_count`
/// readable [`AisdCaptureWindowSnapshot`] values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_capture_union_region(
    target_frame: AisdRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: *const AisdCaptureWindowSnapshot,
    windows_count: usize,
    display_bounds: AisdRect,
    min_overlap_fraction: f64,
) -> AisdRect {
    let core_windows: Vec<capture_region::WindowSnapshot> =
        if windows_count == 0 || windows_in_front.is_null() {
            Vec::new()
        } else {
            core::slice::from_raw_parts(windows_in_front, windows_count)
                .iter()
                .map(|w| w.to_core())
                .collect()
        };
    AisdRect::from_core(capture_region::union_region(
        target_frame.to_core(),
        target_window_id,
        target_pid,
        &core_windows,
        display_bounds.to_core(),
        min_overlap_fraction,
    ))
}

/// Hysteresis gate for capture retargeting.
///
/// Returns `1` if `desired` differs from `current` by more than `min_delta` on any edge, else
/// `0`. Wraps [`capture_region::should_retarget`]. Pass [`capture_region::DEFAULT_MIN_DELTA`]
/// (`8.0`) for `min_delta`. Pure; never fails.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_capture_should_retarget(
    current: AisdRect,
    desired: AisdRect,
    min_delta: f64,
) -> u8 {
    u8::from(capture_region::should_retarget(
        current.to_core(),
        desired.to_core(),
        min_delta,
    ))
}

/// Whether a geometry change should re-origin capture to the plain window frame.
///
/// Returns `1` when no union region is active (`active_region_is_null != 0`), else `0`. Wraps
/// [`capture_region::should_reorigin_to_window_on_geometry`]. Pure; never fails.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_capture_reorigin_on_geometry(active_region_is_null: u8) -> u8 {
    let active = if active_region_is_null != 0 {
        None
    } else {
        Some(VideoRect::xywh(0.0, 0.0, 0.0, 0.0))
    };
    u8::from(capture_region::should_reorigin_to_window_on_geometry(
        active,
    ))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    const BPP: f64 = live_bitrate_policy::DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn adaptive_playout_step_matches_core() {
        // Defaults k=0.8 base=4 floor=4 ceil=35 (ms). Cold start at floor, 12ms jitter → 13.6ms (grow).
        let grown = aisd_adaptive_playout_step_ms(0.012, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((grown - 13.6).abs() < 1e-9);
        // Clean link (2ms) from a high prev → shrink by at most the 2ms step, not straight down.
        let shrunk = aisd_adaptive_playout_step_ms(0.002, 28.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((shrunk - 26.0).abs() < 1e-9);
        // Pathological 40ms jitter clamps at the 35ms ceiling.
        let capped = aisd_adaptive_playout_step_ms(0.040, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!((capped - 35.0).abs() < 1e-9);
    }

    #[test]
    fn live_bitrate_target_matches_core() {
        assert_eq!(
            aisd_live_bitrate_target(1920, 1080, 60, 12_000_000, BPP),
            18_662_400
        );
        assert_eq!(
            aisd_live_bitrate_target(2816, 1778, 60, 12_000_000, BPP),
            45_061_632
        );
        assert_eq!(
            aisd_live_bitrate_target(320, 240, 60, 12_000_000, BPP),
            12_000_000
        );
        assert_eq!(
            aisd_live_bitrate_target(64, 64, 60, 0, BPP),
            aisd_live_bitrate_minimum()
        );
        assert_eq!(
            aisd_live_bitrate_target(0, -10, 0, 0, BPP),
            aisd_live_bitrate_minimum()
        );
    }

    #[test]
    fn live_bitrate_minimum_is_one_megabit() {
        assert_eq!(aisd_live_bitrate_minimum(), 1_000_000);
    }

    fn zeroed_cursor() -> AisdCursorUpdate {
        AisdCursorUpdate {
            shape_id: 0,
            visible: 0,
            x: 0.0,
            y: 0.0,
            hotspot_x: 0.0,
            hotspot_y: 0.0,
        }
    }

    #[test]
    fn cursor_update_round_trips() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(42, 1, 1920.0, 1080.0, 8.0, 8.0, &mut frame),
                AISD_OK
            );
            assert_eq!(frame.len, 36);
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.shape_id, 42);
            assert_eq!(out.visible, 1);
            assert_eq!(
                (out.x, out.y, out.hotspot_x, out.hotspot_y),
                (1920.0, 1080.0, 8.0, 8.0)
            );
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn cursor_update_rejects_nan_wrong_type_and_short() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(1, 1, f64::NAN, 0.0, 0.0, 0.0, &mut frame),
                AISD_OK
            );
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_ERR_MALFORMED
            );
            crate::aisd_bytes_free(frame);

            let bad = [99u8; 36]; // wrong type byte
            assert_eq!(
                aisd_cursor_update_decode(bad.as_ptr(), bad.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            assert_eq!(
                aisd_cursor_update_decode([1u8].as_ptr(), 1, &mut out),
                AISD_ERR_TRUNCATED
            );
        }
    }

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        if b.ptr.is_null() || b.len == 0 {
            Vec::new()
        } else {
            core::slice::from_raw_parts(b.ptr, b.len).to_vec()
        }
    }

    /// Borrows a slice as an input `AisdBytes` (encode copies it, never frees).
    fn borrow(bytes: &[u8]) -> AisdBytes {
        if bytes.is_empty() {
            AisdBytes::EMPTY
        } else {
            AisdBytes {
                ptr: bytes.as_ptr().cast_mut(),
                len: bytes.len(),
                cap: 0,
            }
        }
    }

    #[test]
    fn window_geometry_round_trips_every_variant() {
        unsafe {
            let title = "héllo · 窗口";
            let cases = [
                (
                    WindowGeometryMessage::Move(VideoPoint::new(10.0, 20.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_MOVE,
                        x: 10.0,
                        y: 20.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Resize(VideoSize::new(640.0, 480.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_RESIZE,
                        width: 640.0,
                        height: 480.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Bounds(VideoRect::xywh(1.0, 2.0, 3.0, 4.0)),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_BOUNDS,
                        x: 1.0,
                        y: 2.0,
                        width: 3.0,
                        height: 4.0,
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
                (
                    WindowGeometryMessage::Title(title.to_owned()),
                    AisdWindowGeometry {
                        kind: AISD_WINDOW_GEOMETRY_TITLE,
                        title: borrow(title.as_bytes()),
                        ..AisdWindowGeometry::zeroed()
                    },
                ),
            ];
            for (core_msg, c_in) in cases {
                // Encode through the C struct is byte-identical to the core encode.
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_window_geometry_encode(&c_in, &mut frame), AISD_OK);
                assert_eq!(
                    view(frame),
                    core_msg.encode(),
                    "encode parity {}",
                    c_in.kind
                );
                // Decode it back; the flat struct re-decodes to the same core message.
                let mut out = AisdWindowGeometry::zeroed();
                assert_eq!(
                    aisd_window_geometry_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                let round = match out.kind {
                    AISD_WINDOW_GEOMETRY_MOVE => {
                        WindowGeometryMessage::Move(VideoPoint::new(out.x, out.y))
                    }
                    AISD_WINDOW_GEOMETRY_RESIZE => {
                        WindowGeometryMessage::Resize(VideoSize::new(out.width, out.height))
                    }
                    AISD_WINDOW_GEOMETRY_BOUNDS => WindowGeometryMessage::Bounds(VideoRect::xywh(
                        out.x, out.y, out.width, out.height,
                    )),
                    _ => WindowGeometryMessage::Title(String::from_utf8(view(out.title)).unwrap()),
                };
                assert_eq!(round, core_msg, "decode parity {}", out.kind);
                aisd_window_geometry_free(&mut out);
                aisd_window_geometry_free(&mut out); // idempotent
                crate::aisd_bytes_free(frame);
            }
        }
    }

    #[test]
    fn window_geometry_empty_title_is_null_buffer() {
        unsafe {
            let c_in = AisdWindowGeometry {
                kind: AISD_WINDOW_GEOMETRY_TITLE,
                ..AisdWindowGeometry::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_window_geometry_encode(&c_in, &mut frame), AISD_OK);
            // Just the type byte (4); an empty title adds nothing.
            assert_eq!(view(frame), vec![AISD_WINDOW_GEOMETRY_TITLE]);
            let mut out = AisdWindowGeometry::zeroed();
            assert_eq!(
                aisd_window_geometry_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.kind, AISD_WINDOW_GEOMETRY_TITLE);
            assert!(out.title.ptr.is_null(), "empty title is the null buffer");
            aisd_window_geometry_free(&mut out);
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn window_geometry_encode_and_decode_error_paths() {
        unsafe {
            let mut out_bytes = AisdBytes::EMPTY;
            // Unknown kind on encode.
            let bad_kind = AisdWindowGeometry {
                kind: 99,
                ..AisdWindowGeometry::zeroed()
            };
            assert_eq!(
                aisd_window_geometry_encode(&bad_kind, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Non-UTF-8 title on encode.
            let invalid = [0xFFu8, 0xFE];
            let bad_title = AisdWindowGeometry {
                kind: AISD_WINDOW_GEOMETRY_TITLE,
                title: borrow(&invalid),
                ..AisdWindowGeometry::zeroed()
            };
            assert_eq!(
                aisd_window_geometry_encode(&bad_title, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Null guards.
            let mut out = AisdWindowGeometry::zeroed();
            assert_eq!(
                aisd_window_geometry_encode(core::ptr::null(), &mut out_bytes),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_window_geometry_decode(core::ptr::null(), 1, &mut out),
                AISD_ERR_NULL
            );
            // Decode: unknown type → malformed; short move body → truncated; bad title → malformed.
            assert_eq!(
                aisd_window_geometry_decode([9u8].as_ptr(), 1, &mut out),
                AISD_ERR_MALFORMED
            );
            let short_move = [AISD_WINDOW_GEOMETRY_MOVE, 0, 0];
            assert_eq!(
                aisd_window_geometry_decode(short_move.as_ptr(), short_move.len(), &mut out),
                AISD_ERR_TRUNCATED
            );
            let bad_title_wire = [AISD_WINDOW_GEOMETRY_TITLE, 0xFF, 0xFE];
            assert_eq!(
                aisd_window_geometry_decode(
                    bad_title_wire.as_ptr(),
                    bad_title_wire.len(),
                    &mut out
                ),
                AISD_ERR_MALFORMED
            );
            aisd_window_geometry_free(core::ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn input_event_round_trips_every_variant() {
        unsafe {
            let mods = InputModifiers::SHIFT.union(InputModifiers::COMMAND);
            let cases = [
                InputEvent::MouseMove {
                    normalized: VideoPoint::new(0.25, 0.75),
                    tag: 42,
                },
                InputEvent::MouseDown {
                    button: MouseButton::Right,
                    normalized: VideoPoint::new(0.1, 0.2),
                    click_count: 2,
                    modifiers: mods,
                    tag: 7,
                },
                InputEvent::MouseUp {
                    button: MouseButton::Left,
                    normalized: VideoPoint::new(0.3, 0.4),
                    click_count: 1,
                    modifiers: InputModifiers::default(),
                    tag: 8,
                },
                InputEvent::MouseDrag {
                    button: MouseButton::Other,
                    normalized: VideoPoint::new(0.5, 0.6),
                    click_count: 1,
                    modifiers: InputModifiers::CONTROL,
                    tag: 9,
                },
                InputEvent::Scroll {
                    dx: -3.5,
                    dy: 12.0,
                    normalized: VideoPoint::new(0.0, 1.0),
                    scroll_phase: 2,
                    momentum_phase: 0,
                    continuous: true,
                    tag: 10,
                },
                InputEvent::Scroll {
                    dx: 0.0,
                    dy: 4.25,
                    normalized: VideoPoint::new(0.0, 1.0),
                    scroll_phase: 0,
                    momentum_phase: 2,
                    continuous: false,
                    tag: 11,
                },
                InputEvent::Key {
                    key_code: 0x35,
                    down: true,
                    modifiers: InputModifiers::OPTION,
                    tag: 12,
                },
                InputEvent::Text {
                    text: "gõ được 文字".to_owned(),
                    tag: 13,
                },
            ];
            for core_event in cases {
                // `input_event_to_c` is the decode-side marshaling, but it produces a valid C
                // struct from a core event — exactly the encode INPUT we want (and a free check
                // for its text allocation). encode borrows `text` (copies, never frees), so the
                // owned buffer is released afterwards via `aisd_input_event_free(&mut c_in)`.
                let mut c_in = input_event_to_c(&core_event);
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_input_event_encode(&c_in, &mut frame), AISD_OK);
                assert_eq!(
                    view(frame),
                    core_event.encode(),
                    "encode parity {}",
                    c_in.kind
                );

                let mut out = AisdInputEvent::zeroed();
                assert_eq!(
                    aisd_input_event_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                let round = decode_c_input(&out);
                assert_eq!(round, core_event, "decode parity {}", out.kind);
                assert_eq!(out.tag, core_event.tag(), "tag preserved {}", out.kind);
                aisd_input_event_free(&mut out);
                aisd_input_event_free(&mut out); // idempotent
                aisd_input_event_free(&mut c_in); // free the text buffer input_event_to_c made
                crate::aisd_bytes_free(frame);
            }
        }
    }

    /// Rebuilds a core `InputEvent` from a decoded C struct (test-side mirror of the Swift side).
    unsafe fn decode_c_input(out: &AisdInputEvent) -> InputEvent {
        let normalized = VideoPoint::new(out.x, out.y);
        let modifiers = InputModifiers(out.modifiers);
        match out.kind {
            AISD_INPUT_MOUSE_MOVE => InputEvent::MouseMove {
                normalized,
                tag: out.tag,
            },
            AISD_INPUT_MOUSE_DOWN => InputEvent::MouseDown {
                button: MouseButton::from_u8(out.button).unwrap(),
                normalized,
                click_count: out.click_count,
                modifiers,
                tag: out.tag,
            },
            AISD_INPUT_MOUSE_UP => InputEvent::MouseUp {
                button: MouseButton::from_u8(out.button).unwrap(),
                normalized,
                click_count: out.click_count,
                modifiers,
                tag: out.tag,
            },
            AISD_INPUT_MOUSE_DRAG => InputEvent::MouseDrag {
                button: MouseButton::from_u8(out.button).unwrap(),
                normalized,
                click_count: out.click_count,
                modifiers,
                tag: out.tag,
            },
            AISD_INPUT_SCROLL => InputEvent::Scroll {
                dx: out.dx,
                dy: out.dy,
                normalized,
                scroll_phase: out.scroll_phase,
                momentum_phase: out.momentum_phase,
                continuous: out.continuous != 0,
                tag: out.tag,
            },
            AISD_INPUT_KEY => InputEvent::Key {
                key_code: out.key_code,
                down: out.down != 0,
                modifiers,
                tag: out.tag,
            },
            _ => InputEvent::Text {
                text: String::from_utf8(view(out.text)).unwrap(),
                tag: out.tag,
            },
        }
    }

    #[test]
    fn input_event_encode_and_decode_error_paths() {
        unsafe {
            let mut out_bytes = AisdBytes::EMPTY;
            // Unknown kind on encode.
            let bad_kind = AisdInputEvent {
                kind: 99,
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_kind, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Out-of-range mouse button on encode.
            let bad_button = AisdInputEvent {
                kind: AISD_INPUT_MOUSE_DOWN,
                button: 9,
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_button, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Non-UTF-8 text on encode.
            let invalid = [0xFFu8, 0xFE];
            let bad_text = AisdInputEvent {
                kind: AISD_INPUT_TEXT,
                text: borrow(&invalid),
                ..AisdInputEvent::zeroed()
            };
            assert_eq!(
                aisd_input_event_encode(&bad_text, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Null guards.
            let mut out = AisdInputEvent::zeroed();
            assert_eq!(
                aisd_input_event_encode(core::ptr::null(), &mut out_bytes),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_input_event_decode(core::ptr::null(), 1, &mut out),
                AISD_ERR_NULL
            );
            // Decode: unknown type → malformed; unknown button → malformed; short → truncated.
            assert_eq!(
                aisd_input_event_decode([200u8].as_ptr(), 1, &mut out),
                AISD_ERR_MALFORMED
            );
            let mut down = InputEvent::MouseDown {
                button: MouseButton::Left,
                normalized: VideoPoint::new(0.0, 0.0),
                click_count: 1,
                modifiers: InputModifiers::default(),
                tag: 0,
            }
            .encode();
            down[5] = 9; // button byte (after type + 4-byte tag)
            assert_eq!(
                aisd_input_event_decode(down.as_ptr(), down.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            let short_move = [AISD_INPUT_MOUSE_MOVE, 0, 0];
            assert_eq!(
                aisd_input_event_decode(short_move.as_ptr(), short_move.len(), &mut out),
                AISD_ERR_TRUNCATED
            );
            aisd_input_event_free(core::ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn video_control_round_trips_scalar_variants() {
        unsafe {
            // Each scalar-bearing C struct must FFI-encode byte-identically to the core message and
            // FFI-decode back to the same fields.
            let hello_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_HELLO,
                protocol_version: 7,
                requested_window_id: 0xDEAD_BEEF,
                viewport_w: 1280.0,
                viewport_h: 800.0,
                ..AisdVideoControl::zeroed()
            };
            let hello_core = VideoControlMessage::Hello {
                protocol_version: 7,
                requested_window_id: 0xDEAD_BEEF,
                viewport: VideoSize::new(1280.0, 800.0),
            };
            let ack_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_HELLO_ACK,
                accepted: 1,
                stream_id: 42,
                capture_width: 1920,
                capture_height: 1080,
                full_range: 1,
                bounds_x: 0.0,
                bounds_y: 25.0,
                bounds_w: 800.0,
                bounds_h: 600.0,
                ..AisdVideoControl::zeroed()
            };
            let ack_core = VideoControlMessage::HelloAck {
                accepted: true,
                stream_id: 42,
                capture_width: 1920,
                capture_height: 1080,
                window_bounds_cg: VideoRect::xywh(0.0, 25.0, 800.0, 600.0),
                full_range: true,
            };
            let rreq_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_RESIZE_REQUEST,
                desired_w: 640.5,
                desired_h: 480.25,
                epoch: 3,
                ..AisdVideoControl::zeroed()
            };
            let rreq_core = VideoControlMessage::ResizeRequest {
                desired: VideoSize::new(640.5, 480.25),
                epoch: 3,
            };
            let rack_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_RESIZE_ACK,
                capture_width: 640,
                capture_height: 480,
                epoch: 9,
                ..AisdVideoControl::zeroed()
            };
            let rack_core = VideoControlMessage::ResizeAck {
                capture_width: 640,
                capture_height: 480,
                epoch: 9,
            };
            let cadence_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_STREAM_CADENCE,
                fps: 60,
                ..AisdVideoControl::zeroed()
            };
            let cadence_core = VideoControlMessage::StreamCadence { fps: 60 };

            for (c, core) in [
                (hello_c, hello_core),
                (ack_c, ack_core),
                (rreq_c, rreq_core),
                (rack_c, rack_core),
                (cadence_c, cadence_core),
            ] {
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
                assert_eq!(view(frame), core.encode(), "FFI encode == core encode");
                let mut out = AisdVideoControl::zeroed();
                assert_eq!(
                    aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                assert_eq!(out.kind, c.kind);
                assert_eq!(out.protocol_version, c.protocol_version);
                assert_eq!(out.requested_window_id, c.requested_window_id);
                assert_eq!(out.viewport_w, c.viewport_w);
                assert_eq!(out.viewport_h, c.viewport_h);
                assert_eq!(out.accepted, c.accepted);
                assert_eq!(out.stream_id, c.stream_id);
                assert_eq!(out.full_range, c.full_range);
                assert_eq!(out.bounds_y, c.bounds_y);
                assert_eq!(out.bounds_w, c.bounds_w);
                assert_eq!(out.capture_width, c.capture_width);
                assert_eq!(out.capture_height, c.capture_height);
                assert_eq!(out.desired_w, c.desired_w);
                assert_eq!(out.desired_h, c.desired_h);
                assert_eq!(out.epoch, c.epoch);
                assert_eq!(out.fps, c.fps);
                assert!(out.records.is_null(), "no records for a scalar variant");
                aisd_video_control_free(&mut out); // a scalar decode owns nothing — still a no-op
                crate::aisd_bytes_free(frame);
            }
        }
    }

    #[test]
    fn video_control_zero_body_variants_are_single_type_byte() {
        unsafe {
            for (kind, core) in [
                (AISD_VIDEO_CONTROL_BYE, VideoControlMessage::Bye),
                (AISD_VIDEO_CONTROL_KEEPALIVE, VideoControlMessage::Keepalive),
                (
                    AISD_VIDEO_CONTROL_LIST_WINDOWS,
                    VideoControlMessage::ListWindows,
                ),
                (
                    AISD_VIDEO_CONTROL_FOCUS_WINDOW,
                    VideoControlMessage::FocusWindow,
                ),
                (
                    AISD_VIDEO_CONTROL_LIST_SYSTEM_DIALOGS,
                    VideoControlMessage::ListSystemDialogs,
                ),
            ] {
                let c = AisdVideoControl {
                    kind,
                    ..AisdVideoControl::zeroed()
                };
                let mut frame = AisdBytes::EMPTY;
                assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
                assert_eq!(view(frame), core.encode());
                assert_eq!(view(frame), vec![kind], "zero body = a single type byte");
                let mut out = AisdVideoControl::zeroed();
                assert_eq!(
                    aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                    AISD_OK
                );
                assert_eq!(out.kind, kind);
                crate::aisd_bytes_free(frame);
            }
        }
    }

    #[test]
    fn video_control_round_trips_window_list() {
        unsafe {
            let (chrome, tab, term) = ("Google Chrome", "Tab — 窗口 🪟", "Terminal");
            let recs = [
                AisdVideoSummary {
                    window_id: 1,
                    width: 1200,
                    height: 800,
                    is_secure: 0,
                    keystrokes_blocked: 0,
                    name: borrow(chrome.as_bytes()),
                    title: borrow(tab.as_bytes()),
                },
                AisdVideoSummary {
                    window_id: 2,
                    width: 80,
                    height: 24,
                    is_secure: 0,
                    keystrokes_blocked: 0,
                    name: borrow(term.as_bytes()),
                    title: borrow(b""), // empty title
                },
            ];
            let c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_WINDOW_LIST,
                records: recs.as_ptr().cast_mut(),
                records_len: recs.len(),
                ..AisdVideoControl::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
            let core = VideoControlMessage::WindowList(vec![
                WindowSummary {
                    window_id: 1,
                    app_name: chrome.to_owned(),
                    title: tab.to_owned(),
                    width: 1200,
                    height: 800,
                },
                WindowSummary {
                    window_id: 2,
                    app_name: term.to_owned(),
                    title: String::new(),
                    width: 80,
                    height: 24,
                },
            ]);
            assert_eq!(
                view(frame),
                core.encode(),
                "nested-array FFI encode == core"
            );

            let mut out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.kind, AISD_VIDEO_CONTROL_WINDOW_LIST);
            assert_eq!(out.records_len, 2);
            let decoded = core::slice::from_raw_parts(out.records, out.records_len);
            assert_eq!(decoded[0].window_id, 1);
            assert_eq!((decoded[0].width, decoded[0].height), (1200, 800));
            assert_eq!(view(decoded[0].name), chrome.as_bytes());
            assert_eq!(view(decoded[0].title), tab.as_bytes());
            assert_eq!(decoded[1].window_id, 2);
            assert_eq!(view(decoded[1].name), term.as_bytes());
            assert!(view(decoded[1].title).is_empty());
            aisd_video_control_free(&mut out);
            aisd_video_control_free(&mut out); // idempotent
            assert!(out.records.is_null());
            assert_eq!(out.records_len, 0);
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn video_control_round_trips_system_dialog_list_and_empty() {
        unsafe {
            let owner = "SecurityAgent";
            // Two records pinning the two flags INDEPENDENTLY across the boundary: a blocked login
            // prompt (is_secure=1, keystrokes_blocked=1) and a secure-CLASS admin-auth prompt whose
            // Secure Event Input is off so typing works (is_secure=1, keystrokes_blocked=0).
            let recs = [
                AisdVideoSummary {
                    window_id: 9,
                    width: 400,
                    height: 200,
                    is_secure: 1,
                    keystrokes_blocked: 1,
                    name: borrow(owner.as_bytes()),
                    title: borrow(b""),
                },
                AisdVideoSummary {
                    window_id: 10,
                    width: 420,
                    height: 220,
                    is_secure: 1,
                    keystrokes_blocked: 0,
                    name: borrow(owner.as_bytes()),
                    title: borrow(b"Authorize"),
                },
            ];
            let c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST,
                records: recs.as_ptr().cast_mut(),
                records_len: recs.len(),
                ..AisdVideoControl::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
            let core = VideoControlMessage::SystemDialogList(vec![
                SystemDialogSummary {
                    window_id: 9,
                    owner: owner.to_owned(),
                    title: String::new(),
                    width: 400,
                    height: 200,
                    is_secure: true,
                    keystrokes_blocked: true,
                },
                SystemDialogSummary {
                    window_id: 10,
                    owner: owner.to_owned(),
                    title: "Authorize".to_owned(),
                    width: 420,
                    height: 220,
                    is_secure: true,
                    keystrokes_blocked: false,
                },
            ]);
            assert_eq!(view(frame), core.encode());
            let mut out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            let decoded = core::slice::from_raw_parts(out.records, out.records_len);
            assert_eq!(
                decoded[0].is_secure, 1,
                "Secure Event Input class flag survives"
            );
            assert_eq!(decoded[0].keystrokes_blocked, 1, "blocked flag survives");
            assert_eq!(
                (decoded[1].is_secure, decoded[1].keystrokes_blocked),
                (1, 0),
                "secure-class but typable survives independently"
            );
            assert_eq!(view(decoded[0].name), owner.as_bytes());
            aisd_video_control_free(&mut out);
            crate::aisd_bytes_free(frame);

            // An empty list encodes to [type][count=0] and decodes to a null record array.
            let empty = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST,
                ..AisdVideoControl::zeroed()
            };
            let mut empty_frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&empty, &mut empty_frame), AISD_OK);
            assert_eq!(
                view(empty_frame),
                VideoControlMessage::SystemDialogList(vec![]).encode()
            );
            let mut empty_out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(empty_frame.ptr, empty_frame.len, &mut empty_out),
                AISD_OK
            );
            assert_eq!(empty_out.records_len, 0);
            assert!(empty_out.records.is_null());
            aisd_video_control_free(&mut empty_out); // no-op
            crate::aisd_bytes_free(empty_frame);
        }
    }

    #[test]
    fn video_control_encode_and_decode_error_paths() {
        unsafe {
            let mut out_bytes = AisdBytes::EMPTY;
            // Unknown kind on encode.
            let bad_kind = AisdVideoControl {
                kind: 99,
                ..AisdVideoControl::zeroed()
            };
            assert_eq!(
                aisd_video_control_encode(&bad_kind, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Non-UTF-8 record string on encode.
            let invalid = [0xFFu8, 0xFE];
            let bad_recs = [AisdVideoSummary {
                window_id: 1,
                width: 0,
                height: 0,
                is_secure: 0,
                keystrokes_blocked: 0,
                name: borrow(&invalid),
                title: borrow(b""),
            }];
            let bad_list = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_WINDOW_LIST,
                records: bad_recs.as_ptr().cast_mut(),
                records_len: bad_recs.len(),
                ..AisdVideoControl::zeroed()
            };
            assert_eq!(
                aisd_video_control_encode(&bad_list, &mut out_bytes),
                AISD_ERR_INVALID_ARGUMENT
            );
            // Null guards.
            let mut out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_encode(core::ptr::null(), &mut out_bytes),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_video_control_decode(core::ptr::null(), 1, &mut out),
                AISD_ERR_NULL
            );
            // Decode: unknown type → malformed; non-finite viewport → malformed; short → truncated.
            assert_eq!(
                aisd_video_control_decode([250u8].as_ptr(), 1, &mut out),
                AISD_ERR_MALFORMED
            );
            let mut hello = VideoControlMessage::Hello {
                protocol_version: 1,
                requested_window_id: 0,
                viewport: VideoSize::new(1.0, 1.0),
            }
            .encode();
            let n = hello.len();
            hello[n - 8..].copy_from_slice(&f64::NAN.to_be_bytes()); // poison viewport.h
            assert_eq!(
                aisd_video_control_decode(hello.as_ptr(), hello.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            // A windowList with a record count that runs past the datagram → truncated, not OOM.
            let mut short_list = vec![AISD_VIDEO_CONTROL_WINDOW_LIST];
            short_list.extend_from_slice(&u16::MAX.to_be_bytes()); // count = 65535, no records
            assert_eq!(
                aisd_video_control_decode(short_list.as_ptr(), short_list.len(), &mut out),
                AISD_ERR_TRUNCATED
            );
            aisd_video_control_free(core::ptr::null_mut()); // no-op
        }
    }

    #[test]
    fn adaptive_fec_group_size_matches_core() {
        let mut out: usize = 0;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(0, 5, &mut out) }, 1);
        assert_eq!(out, 5);
        out = 999;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(1, 5, &mut out) }, 0);
        assert_eq!(out, 999, "OFF must not write *out");
        for (tier, def, want) in [
            (2u8, 5usize, 10usize),
            (3, 5, 3),
            (4, 5, 2),
            (5, 5, 5),
            (200, 7, 7),
        ] {
            out = 0;
            assert_eq!(
                unsafe { aisd_adaptive_fec_group_size(tier, def, &mut out) },
                1
            );
            assert_eq!(out, want, "tier {tier} default {def}");
        }
        assert_eq!(
            unsafe { aisd_adaptive_fec_group_size(0, 5, core::ptr::null_mut()) },
            0
        );
    }

    #[test]
    fn adaptive_fec_tier_matches_core() {
        assert_eq!(
            aisd_adaptive_fec_tier(0.10, 0, 0),
            adaptive_fec::tier(0.10, 0, false)
        );
        assert_eq!(aisd_adaptive_fec_tier(0.10, 0, 0), 3);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 0), 2);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 1), 1);
        assert_eq!(
            aisd_adaptive_fec_tier(0.0, 2, 2),
            1,
            "any nonzero allow_off is true"
        );
        assert_eq!(aisd_adaptive_fec_tier(0.015, 0, 0), 0);
    }

    #[test]
    fn adaptive_fec_next_tier_state_matches_core() {
        let dwell = adaptive_fec::RELAX_DWELL_REPORTS;
        let armed = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 0,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            1,
        );
        assert_eq!(
            armed.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS
        );
        let esc = aisd_adaptive_fec_next_tier_state(
            0.10,
            AisdTierState {
                tier: 0,
                relax_streak: 10,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!((esc.tier, esc.relax_streak), (3, 0));
        let core_next = adaptive_fec::next_tier_state(
            0.0,
            adaptive_fec::TierState::new(0, 5, 0),
            dwell,
            false,
            false,
        );
        let ffi_next = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 5,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!(adaptive_fec::TierState::from(ffi_next), core_next);
    }

    #[test]
    fn adaptive_fec_tier_state_repr_round_trips() {
        let s = adaptive_fec::TierState::new(3, 7, 11);
        assert_eq!(adaptive_fec::TierState::from(AisdTierState::from(s)), s);
    }

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn coord_window_point_matches_core() {
        let p = aisd_coord_window_point(
            AisdPoint { x: 0.5, y: 0.5 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(p.x, 500.0);
        approx(p.y, 500.0);
        let c = aisd_coord_window_point(
            AisdPoint { x: 1.0, y: 1.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(c.x, 900.0);
        approx(c.y, 800.0);
    }

    #[test]
    fn coord_cg_to_cocoa_flip_matches_core() {
        let r = aisd_coord_cg_rect_to_cocoa(
            AisdRect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            1080.0,
        );
        approx(r.x, 0.0);
        approx(r.y, 880.0);
        approx(r.width, 400.0);
        approx(r.height, 200.0);
    }

    #[test]
    fn coord_backing_scale_picks_retina_after_flip() {
        let screens = [
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 0.0,
                    width: 1920.0,
                    height: 1080.0,
                },
                backing_scale_factor: 1.0,
            },
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 1080.0,
                    width: 2560.0,
                    height: 1440.0,
                },
                backing_scale_factor: 2.0,
            },
        ];
        let win = AisdRect {
            x: 100.0,
            y: -1000.0,
            width: 1280.0,
            height: 800.0,
        };
        let mut scale = 0.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_OK);
        approx(scale, 2.0);
    }

    #[test]
    fn coord_backing_scale_no_overlap_and_null() {
        let screens = [AisdScreenInfo {
            cocoa_frame: AisdRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            backing_scale_factor: 1.0,
        }];
        let win = AisdRect {
            x: 10_000.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let mut scale = -1.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_EMPTY);
        approx(scale, -1.0); // untouched on AISD_EMPTY
                             // null out_scale => AISD_ERR_NULL; null screens + count 0 => empty => AISD_EMPTY.
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(
                    win,
                    core::ptr::null(),
                    0,
                    100.0,
                    core::ptr::null_mut(),
                )
            },
            AISD_ERR_NULL
        );
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(win, core::ptr::null(), 0, 100.0, &mut scale)
            },
            AISD_EMPTY
        );
    }

    #[test]
    fn coord_pixel_path_divides_by_scale_once() {
        let p = aisd_coord_window_point_from_pixel(
            AisdPoint { x: 400.0, y: 300.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
            2.0,
        );
        approx(p.x, 300.0);
        approx(p.y, 350.0);
    }

    // recovery_policy: defaults 2.0 normal, 1.0 lossy, 60 ms floor, 1.5 floor-rtt-multiple.
    fn escalate(elapsed: f64, rtt: f64, observing: u8) -> u8 {
        aisd_recovery_policy_should_escalate_to_idr(2.0, 1.0, 0.06, 1.5, elapsed, rtt, observing)
    }

    #[test]
    fn recovery_normal_path_is_two_rtt_no_floor() {
        assert_eq!(escalate(0.19, 0.1, 0), 0);
        assert_eq!(escalate(0.20, 0.1, 0), 1);
        assert_eq!(escalate(0.011, 0.006, 0), 0);
        assert_eq!(escalate(0.012, 0.006, 0), 1);
    }

    #[test]
    fn recovery_lossy_path_floored_and_byte_read() {
        assert_eq!(escalate(0.059, 0.01, 1), 0);
        assert_eq!(escalate(0.060, 0.01, 1), 1);
        assert_eq!(escalate(0.0749, 0.05, 1), 0);
        assert_eq!(escalate(0.0751, 0.05, 1), 1);
        assert_eq!(escalate(0.0751, 0.05, 0), 0); // normal clock still waits 2·RTT
        assert_eq!(escalate(0.030, 0.01, 2), 0); // any nonzero byte = observing loss
        assert_eq!(escalate(0.060, 0.01, 2), 1);
        assert_eq!(escalate(0.060, 0.01, 1), escalate(0.060, 0.01, 2));
    }

    #[test]
    fn recovery_matches_core_over_a_grid() {
        for &observing in &[0u8, 1u8] {
            let mut elapsed = 0.0;
            while elapsed <= 0.3 {
                for &rtt in &[0.005, 0.01, 0.05, 0.1, 0.25] {
                    let policy = RecoveryPolicy::new(2.0, 1.0, 0.06, 1.5);
                    let want =
                        u8::from(policy.should_escalate_to_idr(elapsed, rtt, observing != 0));
                    assert_eq!(escalate(elapsed, rtt, observing), want);
                }
                elapsed += 0.007;
            }
        }
    }

    #[test]
    fn window_placement_matches_core() {
        let display = AisdRect {
            x: 3840.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        // Oversized width clamps to the display; height kept; resize flagged.
        let p = aisd_window_placement(2400.0, 800.0, display);
        let core = window_placement::placement(
            VideoSize::new(2400.0, 800.0),
            VideoRect::xywh(3840.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.x.to_bits(), core.origin.x.to_bits());
        assert_eq!(p.y.to_bits(), core.origin.y.to_bits());
        assert_eq!(p.width.to_bits(), core.size.width.to_bits());
        assert_eq!(p.height.to_bits(), core.size.height.to_bits());
        assert_eq!(p.needs_resize, u8::from(core.needs_resize));
        assert_eq!(p.needs_resize, 1);
    }

    #[test]
    fn window_fits_matches_core() {
        let bounds = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        assert_eq!(aisd_window_fits(1920.0, 1080.0, bounds), 1); // exact
        assert_eq!(aisd_window_fits(1920.4, 1080.0, bounds), 1); // within ½-pt tol
        assert_eq!(aisd_window_fits(1921.0, 1080.0, bounds), 0); // width over
    }

    #[test]
    fn vd_geometry_matches_core() {
        let r = aisd_vd_geometry(1920, 1080, 2, 7680);
        let core = VirtualDisplayGeometry::new(1920, 1080, 2, 7680);
        assert_eq!(r.pixel_width, core.pixel_width());
        assert_eq!(r.pixel_height, core.pixel_height());
        assert_eq!(r.exceeds_pixel_limit, u8::from(core.exceeds_pixel_limit()));
        assert_eq!(r.pixel_width, 3840);
        // 4K-point at 2x exceeds a 6144 base-chip ceiling.
        assert_eq!(aisd_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit, 1);
    }

    #[test]
    fn vd_size_in_millimeters_matches_core() {
        let mm = aisd_vd_size_in_millimeters(3840, 2160, 163.0);
        let core = VirtualDisplayGeometry::new(3840, 2160, 1, i64::MAX).size_in_millimeters(163.0);
        assert_eq!(mm.width.to_bits(), core.width.to_bits());
        assert_eq!(mm.height.to_bits(), core.height.to_bits());
    }

    #[test]
    fn vd_origin_to_right_matches_core() {
        let displays = [
            AisdRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            AisdRect {
                x: 1920.0,
                y: 0.0,
                width: 2560.0,
                height: 1440.0,
            },
        ];
        let p = unsafe { aisd_vd_origin_to_right(displays.as_ptr(), displays.len()) };
        assert_eq!(p.x, 4480.0);
        assert_eq!(p.y, 0.0);
        // empty → (0,0)
        let e = unsafe { aisd_vd_origin_to_right(core::ptr::null(), 0) };
        assert_eq!(e.x, 0.0);
        assert_eq!(e.y, 0.0);
    }

    #[test]
    fn vd_chip_pixel_limit_matches_core() {
        let pro = std::ffi::CString::new("Apple M3 Pro").unwrap();
        let base = std::ffi::CString::new("Apple M2").unwrap();
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(pro.as_ptr()) }, 7680);
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(base.as_ptr()) }, 6144);
        assert_eq!(unsafe { aisd_vd_chip_pixel_limit(core::ptr::null()) }, 7680);
    }

    #[test]
    fn vd_refresh_rates_matches_core() {
        let mut buf = [0.0f64; 3];
        let n = unsafe { aisd_vd_refresh_rates(120, buf.as_mut_ptr(), buf.len()) };
        let core = virtual_display_geometry::refresh_rates(120);
        assert_eq!(n, core.len());
        assert_eq!(&buf[..n], core.as_slice());
        // 60 fps → exactly [60, 30]
        let n2 = unsafe { aisd_vd_refresh_rates(60, buf.as_mut_ptr(), buf.len()) };
        assert_eq!(n2, 2);
        assert_eq!(&buf[..2], &[60.0, 30.0]);
    }

    #[test]
    fn capture_union_region_matches_core() {
        let target = AisdRect {
            x: 100.0,
            y: 100.0,
            width: 800.0,
            height: 600.0,
        };
        let display = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        // A same-pid panel overlapping the target in front of it extends the union.
        let front = [AisdCaptureWindowSnapshot {
            window_id: 2,
            owner_pid: 42,
            layer: 0,
            frame: AisdRect {
                x: 700.0,
                y: 100.0,
                width: 400.0,
                height: 300.0,
            },
        }];
        let got =
            unsafe { aisd_capture_union_region(target, 1, 42, front.as_ptr(), 1, display, 0.30) };
        let core = capture_region::union_region(
            target.to_core(),
            1,
            42,
            &[front[0].to_core()],
            display.to_core(),
            0.30,
        );
        assert_eq!(got.x.to_bits(), core.origin.x.to_bits());
        assert_eq!(got.width.to_bits(), core.size.width.to_bits());
        // Empty windows list → just the target (clamped to display).
        let none = unsafe {
            aisd_capture_union_region(target, 1, 42, core::ptr::null(), 0, display, 0.30)
        };
        assert_eq!(none.width.to_bits(), target.width.to_bits());
    }

    #[test]
    fn capture_retarget_and_reorigin_match_core() {
        let a = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let b = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 120.0,
            height: 100.0,
        }; // +20 width > 8
        assert_eq!(aisd_capture_should_retarget(a, b, 8.0), 1);
        assert_eq!(aisd_capture_should_retarget(a, a, 8.0), 0);
        assert_eq!(aisd_capture_reorigin_on_geometry(1), 1); // no active region → reorigin
        assert_eq!(aisd_capture_reorigin_on_geometry(0), 0); // active union → hold
    }
}
