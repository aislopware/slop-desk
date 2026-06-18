//! `video_control`: PATH-2 session bring-up control (hello/ack/bye/resize/keepalive/cadence +
//! the two window/dialog discovery LISTS). Occasional (session setup + slow discovery poll),
//! so the marshaling cost is irrelevant; the two list variants carry an array of summary
//! records, each with two owned strings — the one nested-array codec in the protocol.

use super::{slice_in, status_for_video_error};
use crate::{
    AISD_ERR_INVALID_ARGUMENT, AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec,
    copy_in, drop_bytes,
};
use aislopdesk_core::geometry::{VideoRect, VideoSize};
use aislopdesk_core::video_control::{
    MaskRect, SystemDialogSummary, VideoControlMessage, WindowSummary,
};

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
/// [`VideoControlMessage::ScrollOffset`] discriminator.
pub const AISD_VIDEO_CONTROL_SCROLL_OFFSET: u8 = 13;
/// [`VideoControlMessage::ContentMask`] discriminator.
pub const AISD_VIDEO_CONTROL_CONTENT_MASK: u8 = 14;

/// One opaque content rectangle (capture PIXEL coords) — the element type of the `ContentMask`
/// rect array. Plain POD (no owned buffers), so the array needs no per-element free.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdMaskRect {
    /// Left edge in capture pixels.
    pub x: u16,
    /// Top edge in capture pixels.
    pub y: u16,
    /// Width in capture pixels.
    pub width: u16,
    /// Height in capture pixels.
    pub height: u16,
}

/// One window/dialog summary record, flattened for the C ABI — the element type of the
/// `WindowList` / `SystemDialogList` record arrays.
///
/// Both list variants share this struct: for a `WindowList` record `name` is the application
/// name and `is_secure` is unused (`0`); for a `SystemDialogList` record `name` is the owning
/// process and `is_secure` reflects Secure Event Input. On a decode `out` the `name` / `title`
/// buffers own Rust allocations (released together by [`aisd_video_control_free`]); on an encode
/// input they are borrowed `(ptr, len)` (`cap` ignored) or [`AisdBytes::EMPTY`].
#[repr(C)]
pub struct AisdVideoSummary {
    /// Host `CGWindowID`.
    pub window_id: u32,
    /// Window/dialog width in points.
    pub width: u16,
    /// Window/dialog height in points.
    pub height: u16,
    /// `SystemDialogList` Secure-Event-Input flag (`0`/`1`); unused (`0`) for `WindowList`.
    pub is_secure: u8,
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
/// `RESIZE_ACK` → `capture_*`/`epoch`; `STREAM_CADENCE` → `fps`; `SCROLL_OFFSET` → `scroll_dx`/`scroll_dy`; `WINDOW_LIST` /
/// `SYSTEM_DIALOG_LIST` → `records`/`records_len`; `CONTENT_MASK` → `mask_rects`/`mask_rects_len`;
/// the zero-body kinds use none. On a decode `out`
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
    /// `SCROLL_OFFSET.dx` — horizontal content shift in pixels (signed; `0` for the v1 host).
    pub scroll_dx: i16,
    /// `SCROLL_OFFSET.dy` — vertical content shift in pixels (signed; positive = content moved DOWN).
    pub scroll_dy: i16,
    /// `WINDOW_LIST` / `SYSTEM_DIALOG_LIST` record array (owned out / borrowed in; null otherwise).
    pub records: *mut AisdVideoSummary,
    /// Number of records at `records`.
    pub records_len: usize,
    /// `CONTENT_MASK` rect array (owned out / borrowed in; null otherwise).
    pub mask_rects: *mut AisdMaskRect,
    /// Number of rects at `mask_rects`.
    pub mask_rects_len: usize,
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
            scroll_dx: 0,
            scroll_dy: 0,
            records: core::ptr::null_mut(),
            records_len: 0,
            mask_rects: core::ptr::null_mut(),
            mask_rects_len: 0,
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
        // SAFETY: per the contract, a non-null `records` covers `len` readable summary values.
        unsafe { core::slice::from_raw_parts(records, len) }
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
    // SAFETY: per the contract, a non-empty `records` covers `len` readable summary values.
    let slice = unsafe { records_slice(records, len) };
    let mut out = Vec::with_capacity(slice.len());
    for r in slice {
        // SAFETY: per the contract, each non-empty `name` / `title` covers that many readable bytes.
        let (name, title) = unsafe { (copy_in(r.name), copy_in(r.title)) };
        out.push(WindowSummary {
            window_id: r.window_id,
            app_name: String::from_utf8(name).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            title: String::from_utf8(title).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
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
    // SAFETY: per the contract, a non-empty `records` covers `len` readable summary values.
    let slice = unsafe { records_slice(records, len) };
    let mut out = Vec::with_capacity(slice.len());
    for r in slice {
        // SAFETY: per the contract, each non-empty `name` / `title` covers that many readable bytes.
        let (name, title) = unsafe { (copy_in(r.name), copy_in(r.title)) };
        out.push(SystemDialogSummary {
            window_id: r.window_id,
            owner: String::from_utf8(name).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            title: String::from_utf8(title).map_err(|_| AISD_ERR_INVALID_ARGUMENT)?,
            width: r.width,
            height: r.height,
            is_secure: r.is_secure != 0,
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
            // SAFETY: per the contract, a list `kind`'s records cover `records_len` readable values.
            VideoControlMessage::WindowList(unsafe {
                c_to_window_summaries(m.records, m.records_len)
            }?)
        }
        AISD_VIDEO_CONTROL_FOCUS_WINDOW => VideoControlMessage::FocusWindow,
        AISD_VIDEO_CONTROL_STREAM_CADENCE => VideoControlMessage::StreamCadence { fps: m.fps },
        AISD_VIDEO_CONTROL_SCROLL_OFFSET => VideoControlMessage::ScrollOffset {
            dx: m.scroll_dx,
            dy: m.scroll_dy,
        },
        AISD_VIDEO_CONTROL_CONTENT_MASK => {
            // SAFETY: per the contract, a content-mask `kind`'s rects cover `mask_rects_len`
            // readable values.
            VideoControlMessage::ContentMask(unsafe {
                c_to_mask_rects(m.mask_rects, m.mask_rects_len)
            })
        }
        AISD_VIDEO_CONTROL_LIST_SYSTEM_DIALOGS => VideoControlMessage::ListSystemDialogs,
        AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST => {
            // SAFETY: per the contract, a list `kind`'s records cover `records_len` readable values.
            VideoControlMessage::SystemDialogList(unsafe {
                c_to_dialog_summaries(m.records, m.records_len)
            }?)
        }
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(message)
}

/// Rebuilds the core [`MaskRect`] list from a borrowed C rect array (plain POD copy).
///
/// # Safety
/// If `len != 0` and `rects` is non-null, it must point to `len` readable [`AisdMaskRect`] values.
unsafe fn c_to_mask_rects(rects: *const AisdMaskRect, len: usize) -> Vec<MaskRect> {
    if len == 0 || rects.is_null() {
        return Vec::new();
    }
    // SAFETY: per the contract, a non-null `rects` covers `len` readable rect values.
    unsafe { core::slice::from_raw_parts(rects, len) }
        .iter()
        .map(|r| MaskRect::new(r.x, r.y, r.width, r.height))
        .collect()
}

/// Moves a `Vec` of mask rects across the boundary as a raw `(ptr, len)` the caller releases via
/// [`aisd_video_control_free`]. An empty vec yields `(null, 0)` (no allocation). POD elements, so
/// the free side just drops the boxed slice (no per-element cleanup).
fn mask_rects_into_raw(rects: Vec<AisdMaskRect>) -> (*mut AisdMaskRect, usize) {
    if rects.is_empty() {
        return (core::ptr::null_mut(), 0);
    }
    let len = rects.len();
    let mut boxed = rects.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    core::mem::forget(boxed);
    (ptr, len)
}

/// Reconstructs and drops the owned mask-rect array behind a decoded [`AisdVideoControl`]. No-op on
/// a null pointer. POD elements need no inner free.
///
/// # Safety
/// `ptr` / `len` must be an array previously produced by [`mask_rects_into_raw`] and not yet freed.
unsafe fn drop_mask_rects(ptr: *mut AisdMaskRect, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    // SAFETY: per the contract, `(ptr, len)` is a live `mask_rects_into_raw` boxed slice
    // (`into_boxed_slice` makes `cap == len`, so this reconstructs the exact allocation).
    drop(unsafe { Box::from_raw(core::ptr::slice_from_raw_parts_mut(ptr, len)) });
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
    name: &str,
    title: &str,
) -> AisdVideoSummary {
    AisdVideoSummary {
        window_id,
        width,
        height,
        is_secure: u8::from(is_secure),
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
        VideoControlMessage::ScrollOffset { dx, dy } => {
            out.scroll_dx = *dx;
            out.scroll_dy = *dy;
        }
        VideoControlMessage::ContentMask(rects) => {
            let recs: Vec<AisdMaskRect> = rects
                .iter()
                .map(|r| AisdMaskRect {
                    x: r.x,
                    y: r.y,
                    width: r.width,
                    height: r.height,
                })
                .collect();
            let (ptr, len) = mask_rects_into_raw(recs);
            out.mask_rects = ptr;
            out.mask_rects_len = len;
        }
        VideoControlMessage::WindowList(windows) => {
            let recs: Vec<AisdVideoSummary> = windows
                .iter()
                .map(|w| summary_to_c(w.window_id, w.width, w.height, false, &w.app_name, &w.title))
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
    // SAFETY: per the contract, `(ptr, len)` is a live `summaries_into_raw` boxed slice
    // (`into_boxed_slice` makes `cap == len`, so this reconstructs the exact allocation).
    let boxed: Box<[AisdVideoSummary]> =
        unsafe { Box::from_raw(core::ptr::slice_from_raw_parts_mut(ptr, len)) };
    for rec in &boxed {
        // SAFETY: each record's `name` / `title` is a live `bytes_from_vec` allocation owned by
        // this array (freed exactly once here before the slice itself is dropped).
        unsafe {
            drop_bytes(rec.name);
            drop_bytes(rec.title);
        }
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_control_encode(
    msg: *const AisdVideoControl,
    out: *mut AisdBytes,
) -> AisdStatus {
    if msg.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    // SAFETY: `msg` is non-null per the check + valid per the contract, including any record
    // buffers a list `kind` borrows.
    let message = match unsafe { c_to_video_control(&*msg) } {
        Ok(message) => message,
        Err(status) => return status,
    };
    // SAFETY: `out` is non-null per the check above and writable per the contract.
    unsafe { out.write(bytes_from_vec(message.encode())) };
    AISD_OK
}

/// Decodes a video control message into `*out`.
///
/// On [`AISD_OK`], `*out` may own a `records` array — release with [`aisd_video_control_free`].
/// `data` may be null only when `len == 0`. Maps a non-finite coordinate / unknown type to
/// [`crate::AISD_ERR_MALFORMED`] and a short body to [`crate::AISD_ERR_TRUNCATED`] (record strings
/// decode lossily, never malformed).
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes. On a
/// non-[`AISD_OK`] return `*out` is untouched; on [`AISD_OK`] it is overwritten as raw output
/// WITHOUT freeing prior contents.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_control_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdVideoControl,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    // SAFETY: `data` covers `len` readable bytes per the contract (and the null+len check).
    match VideoControlMessage::decode(unsafe { slice_in(data, len) }) {
        Ok(message) => {
            // SAFETY: `out` is non-null per the check above and writable per the contract.
            unsafe { out.write(video_control_to_c(&message)) };
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_control_free(msg: *mut AisdVideoControl) {
    if msg.is_null() {
        return;
    }
    // SAFETY: `msg` is non-null per the check above and points to a writable, library-filled
    // `AisdVideoControl` per the contract.
    let m = unsafe { &mut *msg };
    // SAFETY: `(records, records_len)` is the array `video_control_to_c` allocated (or `(null, 0)`),
    // freed exactly once — the reset below makes a second call a no-op (idempotent).
    unsafe { drop_summaries(m.records, m.records_len) };
    m.records = core::ptr::null_mut();
    m.records_len = 0;
    // SAFETY: `(mask_rects, mask_rects_len)` is the array `video_control_to_c` allocated (or
    // `(null, 0)`), freed exactly once — the reset makes a second call a no-op (idempotent).
    unsafe { drop_mask_rects(m.mask_rects, m.mask_rects_len) };
    m.mask_rects = core::ptr::null_mut();
    m.mask_rects_len = 0;
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;
    use crate::{AISD_ERR_MALFORMED, AISD_ERR_TRUNCATED};

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        unsafe {
            if b.ptr.is_null() || b.len == 0 {
                Vec::new()
            } else {
                core::slice::from_raw_parts(b.ptr, b.len).to_vec()
            }
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
            let scroll_c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_SCROLL_OFFSET,
                scroll_dx: -5,
                scroll_dy: 42,
                ..AisdVideoControl::zeroed()
            };
            let scroll_core = VideoControlMessage::ScrollOffset { dx: -5, dy: 42 };

            for (c, core) in [
                (hello_c, hello_core),
                (ack_c, ack_core),
                (rreq_c, rreq_core),
                (rack_c, rack_core),
                (cadence_c, cadence_core),
                (scroll_c, scroll_core),
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
                assert_eq!(out.scroll_dx, c.scroll_dx);
                assert_eq!(out.scroll_dy, c.scroll_dy);
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
                    name: borrow(chrome.as_bytes()),
                    title: borrow(tab.as_bytes()),
                },
                AisdVideoSummary {
                    window_id: 2,
                    width: 80,
                    height: 24,
                    is_secure: 0,
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
            let recs = [AisdVideoSummary {
                window_id: 9,
                width: 400,
                height: 200,
                is_secure: 1,
                name: borrow(owner.as_bytes()),
                title: borrow(b""),
            }];
            let c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST,
                records: recs.as_ptr().cast_mut(),
                records_len: recs.len(),
                ..AisdVideoControl::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
            let core = VideoControlMessage::SystemDialogList(vec![SystemDialogSummary {
                window_id: 9,
                owner: owner.to_owned(),
                title: String::new(),
                width: 400,
                height: 200,
                is_secure: true,
            }]);
            assert_eq!(view(frame), core.encode());
            let mut out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            let decoded = core::slice::from_raw_parts(out.records, out.records_len);
            assert_eq!(decoded[0].is_secure, 1, "Secure Event Input flag survives");
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
    fn video_control_round_trips_content_mask_and_empty() {
        unsafe {
            let rects = [
                AisdMaskRect {
                    x: 0,
                    y: 0,
                    width: 2880,
                    height: 1800,
                },
                AisdMaskRect {
                    x: 96,
                    y: 1406,
                    width: 538,
                    height: 172,
                },
            ];
            let c = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_CONTENT_MASK,
                mask_rects: rects.as_ptr().cast_mut(),
                mask_rects_len: rects.len(),
                ..AisdVideoControl::zeroed()
            };
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&c, &mut frame), AISD_OK);
            let core = VideoControlMessage::ContentMask(vec![
                MaskRect::new(0, 0, 2880, 1800),
                MaskRect::new(96, 1406, 538, 172),
            ]);
            assert_eq!(view(frame), core.encode(), "FFI encode == core encode");

            let mut out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.kind, AISD_VIDEO_CONTROL_CONTENT_MASK);
            assert_eq!(out.mask_rects_len, 2);
            let decoded = core::slice::from_raw_parts(out.mask_rects, out.mask_rects_len);
            assert_eq!((decoded[0].width, decoded[0].height), (2880, 1800));
            assert_eq!(
                (
                    decoded[1].x,
                    decoded[1].y,
                    decoded[1].width,
                    decoded[1].height
                ),
                (96, 1406, 538, 172)
            );
            aisd_video_control_free(&mut out);
            aisd_video_control_free(&mut out); // idempotent
            assert!(out.mask_rects.is_null());
            assert_eq!(out.mask_rects_len, 0);
            crate::aisd_bytes_free(frame);

            // Empty mask (contracted state) → [type][count=0], decodes to a null rect array.
            let empty = AisdVideoControl {
                kind: AISD_VIDEO_CONTROL_CONTENT_MASK,
                ..AisdVideoControl::zeroed()
            };
            let mut empty_frame = AisdBytes::EMPTY;
            assert_eq!(aisd_video_control_encode(&empty, &mut empty_frame), AISD_OK);
            assert_eq!(
                view(empty_frame),
                VideoControlMessage::ContentMask(vec![]).encode()
            );
            let mut empty_out = AisdVideoControl::zeroed();
            assert_eq!(
                aisd_video_control_decode(empty_frame.ptr, empty_frame.len, &mut empty_out),
                AISD_OK
            );
            assert_eq!(empty_out.mask_rects_len, 0);
            assert!(empty_out.mask_rects.is_null());
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
}
