//! What a `HiDPI` virtual display IS, before `WindowServer` is asked for one.
//!
//! The four answers in `slopdesk_video::virtual_display`, and every one of them is arithmetic with
//! nothing to own: no handle, no allocation, no lifetime a caller could get wrong. The scalar
//! answers cross BY VALUE (`docs/55` §4b); the ones that carry a list borrow it for the call — a
//! display list as a flat run of `f64`s, four per display, exactly as `window_placement`'s door
//! already does, because that is what a Swift `[CGRect]` maps to without a second layout for either
//! side to agree on.
//!
//! The advertised modes are the one answer whose SIZE is not fixed, and it is bounded by
//! construction: the baseline pair plus at most the oversample and the window's own rate, so four
//! is the ceiling and the caller lends a fixed buffer rather than being handed one to free.
//!
//! Bit-exactness is the point of the boundary being here rather than in Swift.
//! `golden/golden_vectors.json` pins the millimetre conversion and the rightmost-edge fold as bit
//! patterns, which means the operand order, the NaN handling and the tie-breaking must survive the
//! crossing unchanged — they do, because nothing is recomputed on this side. The door hands over
//! the caller's scalars and hands back the crate's.
//!
//! ## The other half: the DISPLAY, which is a handle, and macOS-only
//!
//! Everything above is arithmetic and both slices declare it. Below is
//! `slopdesk-apple-cgvirtualdisplay` — the four private `CGVirtualDisplay*` classes, the
//! registration, and the `WindowServer` transaction that makes the new display a separate desktop
//! rather than a mirror. There is no `WindowServer` on a phone, so those doors are gated item by
//! item and `slopdesk_ffi.h` declares them INSIDE its `MACOS-ONLY` region while the geometry doors
//! stay outside it. That is `audio_codec`'s encoder/decoder split exactly.
//!
//! ### This handle is the THIRD that may be called from two threads
//!
//! `docs/55` §4b says no two calls on one handle may overlap, with two documented exceptions today
//! — `SlopDeskCursorSampler` and `SlopDeskInjector`, each because it carries its own locks and says
//! so in its own doors. This is the third, for the same reason and one more of its own:
//! [`slopdesk_virtual_display_id`] and [`slopdesk_virtual_display_scale`] take a `const` handle and
//! are called on EVERY pane mint, while a [`slopdesk_virtual_display_create`] for another pane can
//! be blocked inside `WindowServer` for seconds. Serialising those against each other would mean a
//! mint waiting on an unrelated pane's display bring-up. The two readable answers are atomics and
//! everything else is behind a lock, so the overlap is the design rather than a hazard — and
//! [`slopdesk_virtual_display_free`] is still the one call that may not overlap anything.
//!
//! ### The threading rule is INVERTED from the Swift it replaces
//!
//! The class this replaced was `@MainActor`, because `initWithDescriptor:` must be main.
//! `applySettings:` must NOT be, and blocks for seconds. The door resolves that the only way that
//! is honest: [`slopdesk_virtual_display_create`] is an OFF-MAIN blocking call that hops to main
//! twice inside itself. Calling it FROM the main thread DEADLOCKS.

// The handle half's context pointer, and macOS-only with the handle itself: a `CGVirtualDisplay` is
// something only a host has, and only a host is asked to hold one.
#[cfg(target_os = "macos")]
use core::ffi::c_void;
use std::os::raw::c_uchar;

#[cfg(target_os = "macos")]
use slopdesk_apple_cgvirtualdisplay::{VirtualDisplay, private_classes_available};
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::virtual_display;

/// The most refresh modes [`slopdesk_vd_refresh_rates`] can ever answer.
///
/// The baseline 60 and 30, the capped `min(120, 2 × fps)` oversample, and the window's own rate.
/// Stated here so the caller can size one stack buffer and never ask how big the answer is first.
pub const SLOPDESK_VD_MAX_REFRESH_RATES: usize = 4;

/// A virtual display's point grid, its backing framebuffer, and whether the chip can drive it.
///
/// The FLOORED dimensions come back with the derived ones on purpose. The near side fills a
/// `CGVirtualDisplayMode` from the POINT grid and `settings.hiDPI` from the SCALE, so if it kept
/// its own `max(1, …)` the floor would be spelled in two languages — which is the drift this
/// crossing exists to end, and the one a rule about literals could never see.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskVirtualDisplayGeometry {
    /// The logical width in points, floored at 1 — what a `CGVirtualDisplayMode` is built from.
    pub point_width: i32,
    /// The logical height in points, by the same rule.
    pub point_height: i32,
    /// The backing pixel scale, floored at 1. `>= 2` is what makes `settings.hiDPI` 1.
    pub scale: i32,
    /// The chip's horizontal framebuffer budget this geometry was judged against, floored at 1.
    pub max_horizontal_pixels: i32,
    /// The backing framebuffer width, `points × scale`, after the caller's dimensions are floored.
    pub pixel_width: i32,
    /// The backing framebuffer height, by the same rule.
    pub pixel_height: i32,
    /// Whether the framebuffer is over the chip's horizontal budget, and the display must NOT be
    /// created — `applySettings:` would answer YES and leave `displayID` at 0.
    pub exceeds_pixel_limit: bool,
}

/// A physical size in millimetres.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskVirtualDisplaySize {
    /// The width, in millimetres.
    pub width: f64,
    /// The height, in millimetres.
    pub height: f64,
}

/// A point in the global display space.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskVirtualDisplayOrigin {
    /// The horizontal coordinate.
    pub x: f64,
    /// The vertical coordinate.
    pub y: f64,
}

/// The backing framebuffer for a point grid at a scale, judged against a chip budget.
///
/// Every dimension is floored at 1 on the far side, so a zero or negative one crosses verbatim and
/// is answered rather than rejected.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_geometry(
    point_width: i32,
    point_height: i32,
    scale: i32,
    max_horizontal_pixels: i32,
) -> SlopDeskVirtualDisplayGeometry {
    let geometry = virtual_display::Geometry::new(point_width, point_height, scale, max_horizontal_pixels);
    SlopDeskVirtualDisplayGeometry {
        point_width: geometry.point_width(),
        point_height: geometry.point_height(),
        scale: geometry.scale(),
        max_horizontal_pixels: geometry.max_horizontal_pixels(),
        pixel_width: geometry.pixel_width(),
        pixel_height: geometry.pixel_height(),
        exceeds_pixel_limit: geometry.exceeds_pixel_limit(),
    }
}

/// The physical size to advertise for a point grid at a target pixel density.
///
/// `target_ppi` is floored at 1.0 by a comparison that sends a NaN to the floor; the division and
/// the multiplication stay separate, so the two `f64`s that come back are the ones
/// `golden/golden_vectors.json` pins by bit pattern.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_vd_size_in_millimeters(
    point_width: i32,
    point_height: i32,
    scale: i32,
    max_horizontal_pixels: i32,
    target_ppi: f64,
) -> SlopDeskVirtualDisplaySize {
    let (width, height) =
        virtual_display::Geometry::new(point_width, point_height, scale, max_horizontal_pixels)
            .size_in_millimeters(target_ppi);
    SlopDeskVirtualDisplaySize { width, height }
}

/// The density a virtual display reports at unless a caller asks for another.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_default_target_ppi() -> f64 {
    virtual_display::DEFAULT_TARGET_PPI
}

/// The origin to place the virtual display at: flush right of every display in `displays`.
///
/// `displays` is `4 * display_count` scalars — `x, y, width, height` per display, in the global
/// space the caller enumerates in. Each is standardised before its right edge is read, and an empty
/// or absent list answers the origin.
///
/// # Safety
/// `displays` must be null or point to `4 * display_count` readable, aligned `f64`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_origin_to_right(
    displays: *const f64,
    display_count: usize,
) -> SlopDeskVirtualDisplayOrigin {
    // SAFETY: the caller's obligation above, discharged by Swift's `withUnsafeBufferPointer`,
    // whose scope is exactly this call.
    let scalars = unsafe { crate::borrow(displays, display_count.saturating_mul(4)) };
    let bounds: Vec<VideoRect> = scalars
        .as_chunks::<4>()
        .0
        .iter()
        .map(|&[x, y, width, height]| VideoRect::xywh(x, y, width, height))
        .collect();
    let origin = virtual_display::origin_to_right(&bounds);
    SlopDeskVirtualDisplayOrigin {
        x: origin.x,
        y: origin.y,
    }
}

/// The chip's maximum horizontal framebuffer pixels, from its `machdep.cpu.brand_string`.
///
/// # Safety
/// `brand` must be null or name `brand_len` initialised bytes that stay live for the call. A null
/// or non-UTF-8 span reads as the empty brand, which answers the permissive limit.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_chip_pixel_limit(brand: *const c_uchar, brand_len: usize) -> i32 {
    // SAFETY: the caller's obligation above, discharged by the shared text helper.
    let text = unsafe { crate::lent(brand, brand_len) };
    virtual_display::chip_pixel_limit(text)
}

/// The refresh modes to advertise for a capture source feeding an `fps` encode, descending.
///
/// Writes at most `capacity` rates into `out` and answers how many the rule produced — which is
/// never more than [`SLOPDESK_VD_MAX_REFRESH_RATES`], so a caller that lends that many is never
/// short. A returned count above `capacity` means the buffer was too small and nothing beyond it
/// was written; the order is part of the answer, so a truncated read is a wrong one.
///
/// # Safety
/// `out` must be null or point to `capacity` writable, aligned `f64`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_refresh_rates(fps: i32, out: *mut f64, capacity: usize) -> usize {
    let rates = virtual_display::refresh_rates(fps);
    if !out.is_null() && capacity >= rates.len() {
        // SAFETY: the caller's obligation above. `rates` is a fresh local, so the two regions
        // cannot overlap, and the length is checked against the lent capacity first.
        unsafe { std::ptr::copy_nonoverlapping(rates.as_ptr(), out, rates.len()) }
    }
    rates.len()
}

// ---------------------------------------------------------------------------- //
// The HANDLE half — macOS only, item by item.
// ---------------------------------------------------------------------------- //

/// The owner of one live virtual display.
#[cfg(target_os = "macos")]
#[derive(Debug)]
pub struct SlopDeskVirtualDisplay {
    /// The registration, and the locks and atomics that make it callable from two threads.
    display: VirtualDisplay,
}

/// What the caller is told when `WindowServer` terminates the display out from under it.
///
/// Called on the framework's delivery queue, never on the main thread, and never reentrantly into
/// this handle. `context` is the pointer given to [`slopdesk_virtual_display_set_terminated`], and
/// it must stay live until [`slopdesk_virtual_display_free`] RETURNS.
#[cfg(target_os = "macos")]
pub type SlopDeskVirtualDisplayTerminatedFn = Option<unsafe extern "C" fn(context: *mut c_void)>;

/// The caller's opaque context, carried across the thread the framework chose.
#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug)]
struct TerminationContext(*mut c_void);

// SAFETY: the caller of `slopdesk_virtual_display_set_terminated` promises this pointer is valid
// until `slopdesk_virtual_display_free` returns and safe to use from any thread. That promise is
// the door's documented term; it cannot be checked here, and it is the same one `slopdesk_video_
// encoder_new`'s context already asks for.
#[cfg(target_os = "macos")]
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Send for TerminationContext {}
// SAFETY: as above.
#[cfg(target_os = "macos")]
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Sync for TerminationContext {}

#[cfg(target_os = "macos")]
impl TerminationContext {
    /// The caller's pointer, read through the WRAPPER.
    ///
    /// A method rather than a field access, because an edition-2024 closure captures the field a
    /// body NAMES: `carried.0` would capture a bare `*mut c_void`, which is neither `Send` nor
    /// `Sync`, and the promise this type carries would never reach the closure at all.
    const fn pointer(&self) -> *mut c_void {
        self.0
    }
}

/// Turns a caller's handle pointer into a reference for one call.
///
/// SHARED rather than exclusive, which is the whole of this handle's exception: the state behind it
/// is locked and its two readable answers are atomics, so two threads holding this reference at
/// once is what the module documents rather than aliasing UB.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_virtual_display_new`] that has not been
/// freed.
#[cfg(target_os = "macos")]
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskVirtualDisplay) -> Option<&'a SlopDeskVirtualDisplay> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and the state behind it is guarded,
    // so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Whether this process can create a virtual display at all: `1` yes, `0` no.
///
/// Four `objc_getClass` lookups, cached for the process lifetime. It instantiates nothing, sends no
/// message and touches no `WindowServer`, so it is safe to ask on every pane mint and safe to ask
/// on an OS that no longer has the classes — which is the whole point of asking.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[must_use]
pub extern "C" fn slopdesk_virtual_display_private_classes_available() -> u32 {
    u32::from(private_classes_available())
}

/// An owner with no display yet. Never null; creates nothing and touches no framework.
///
/// # Safety
/// The answer must be passed to [`slopdesk_virtual_display_free`] exactly once.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_virtual_display_new() -> *mut SlopDeskVirtualDisplay {
    Box::into_raw(Box::new(SlopDeskVirtualDisplay {
        display: VirtualDisplay::new(),
    }))
}

/// Releases the owner, and with it the display. Null is inert; a second call would not be.
///
/// Tears down in the one order that is safe: the termination handler is dropped FIRST, so
/// `WindowServer` has nothing left to call, and only then is the registration given up — on the
/// main thread, because its `-dealloc` is the unregistering IPC.
///
/// The caller may release its own context box once this RETURNS, and not before. That is a real
/// term, not a hope: dropping the handler WAITS on the framework's serial delivery queue, so a
/// callback already inside the caller's function pointer has finished before this comes back.
/// Clearing the callback with [`slopdesk_virtual_display_set_terminated`] does NOT give the same
/// promise — it only stops the NEXT delivery — so a context is released here or never.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_virtual_display_new`] that has not already
/// been freed, and no call on it may be in flight.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_virtual_display_free(handle: *mut SlopDeskVirtualDisplay) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free. Dropping it runs the teardown.
    drop(unsafe { Box::from_raw(handle) });
}

/// Creates the display and answers its `CGDirectDisplayID`, or `0` for EVERY failure.
///
/// ONE door for a sequence of eight steps — snapshot the physical displays, fold the rightmost
/// edge, build the descriptor, register it, apply the settings under a ceiling, wait for the
/// display to be published, settle, and commit the extend transaction — because the sequence has no
/// intermediate state a caller could act on and every step's failure means the same thing: no
/// display, capture a real one at 1×.
///
/// `name` is the ONLY variable-length input, lent as `(bytes, len)` per `docs/55` §4. Absent or
/// non-UTF-8 text reads as empty, which names the display nothing rather than refusing to build it.
///
/// ⚠️ BLOCKS. Up to ten seconds of `applySettings:` plus about 1.2 seconds of polling and settling.
/// ⚠️ MUST NOT be called from the main thread: it hops to main twice inside itself, and
/// `dispatch_sync` onto the queue you are already on deadlocks.
///
/// # Safety
/// `handle` must be null or live. `name` must be null or name `name_len` initialised bytes that
/// stay live for the whole call.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_virtual_display_create(
    handle: *const SlopDeskVirtualDisplay,
    point_width: u32,
    point_height: u32,
    scale: u32,
    max_horizontal_pixels: u32,
    fps: u32,
    name: *const c_uchar,
    name_len: usize,
) -> u32 {
    // SAFETY: the caller's obligation, above.
    let Some(owner) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, above.
    let name = unsafe { crate::lent(name, name_len) };
    let geometry = virtual_display::Geometry::new(
        widened(point_width),
        widened(point_height),
        widened(scale),
        widened(max_horizontal_pixels),
    );
    owner.display.create(&geometry, name, widened(fps)).unwrap_or(0)
}

/// A `u32` the far side takes as `i32`, saturating rather than wrapping.
///
/// The rules in `slopdesk-video` are written in `i32` because the geometry doors above are; a value
/// that cannot fit is a caller asking for something absurd, and saturating makes it fail the
/// pixel-limit guard instead of coming back as a small negative that passes it.
#[cfg(target_os = "macos")]
const fn widened(value: u32) -> i32 {
    if value > i32::MAX.cast_unsigned() {
        i32::MAX
    } else {
        value.cast_signed()
    }
}

/// The live `CGDirectDisplayID`, or `0`. Null is `0`.
///
/// One atomic load, no message send and no lock — which is why it takes a `const` handle and may be
/// called WHILE a create is in flight for another pane.
///
/// # Safety
/// `handle` must be null or live.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_virtual_display_id(handle: *const SlopDeskVirtualDisplay) -> u32 {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle) }.map_or(0, |owner| owner.display.display_id())
}

/// The live display's backing scale, or `1` when there is none. Null is `1`.
///
/// One atomic load, as [`slopdesk_virtual_display_id`] is, and `1` rather than `0` because a caller
/// multiplies by it: a zero would make a zero-pixel capture rect.
///
/// # Safety
/// `handle` must be null or live.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_virtual_display_scale(handle: *const SlopDeskVirtualDisplay) -> u32 {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle) }.map_or(1, |owner| owner.display.scale())
}

/// Registers what to run when `WindowServer` terminates the display.
///
/// A null `callback` CLEARS the registration, and a second call REPLACES it. Neither is a barrier:
/// they stop the NEXT delivery and say nothing about one already in flight, so a context box stays
/// live until [`slopdesk_virtual_display_free`] returns even after it has been unregistered here.
/// By the time the callback runs the identifier is already `0`, so a concurrent mint fails soft to
/// 1× rather than parking a window onto a dead display.
///
/// ⚠️ The callback must not call [`slopdesk_virtual_display_destroy`] or
/// [`slopdesk_virtual_display_free`]: it runs ON the delivery queue, and teardown orders itself
/// against that queue.
///
/// # Safety
/// `handle` must be null or live. `context` must stay valid until
/// [`slopdesk_virtual_display_free`] returns, and `callback` must be safe to call from any thread.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_virtual_display_set_terminated(
    handle: *const SlopDeskVirtualDisplay,
    callback: SlopDeskVirtualDisplayTerminatedFn,
    context: *mut c_void,
) {
    // SAFETY: the caller's obligation, above.
    let Some(owner) = (unsafe { held(handle) }) else {
        return;
    };
    let carried = TerminationContext(context);
    owner.display.on_terminated(Box::new(move || {
        let Some(callback) = callback else {
            return;
        };
        // SAFETY: the context is live until `_free` returns by the door's stated term, and the
        // callback is the caller's own function pointer, which it promised is callable from any
        // thread. Calling it IS this door's boundary.
        unsafe { callback(carried.pointer()) };
    }));
}

/// Releases the display, keeping the owner. Idempotent, and a no-op after a termination.
///
/// Call it AFTER every capture stream targeting the display has stopped and AFTER parked windows
/// have been restored — the display each window came from must still exist. It does NOT fire the
/// termination callback: `destroy` is the caller ASKING, and reporting that as a `WindowServer`
/// termination would make the daemon disconnect every session on an orderly shutdown.
///
/// # Safety
/// `handle` must be null or live.
#[cfg(target_os = "macos")]
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_virtual_display_destroy(handle: *const SlopDeskVirtualDisplay) {
    // SAFETY: the caller's obligation, above.
    if let Some(owner) = unsafe { held(handle) } {
        owner.display.destroy();
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SLOPDESK_VD_MAX_REFRESH_RATES, slopdesk_vd_chip_pixel_limit, slopdesk_vd_default_target_ppi,
        slopdesk_vd_geometry, slopdesk_vd_origin_to_right, slopdesk_vd_refresh_rates,
        slopdesk_vd_size_in_millimeters,
    };

    #[test]
    fn the_framebuffer_and_its_budget_cross_by_value() {
        let retina = slopdesk_vd_geometry(1920, 1080, 2, 7680);
        assert_eq!((retina.pixel_width, retina.pixel_height), (3840, 2160));
        assert!(!retina.exceeds_pixel_limit);
        assert!(slopdesk_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit);
        // The FLOORED point grid and scale come back with the derived pixels, so the near side has
        // no reason to keep a `max(1, …)` of its own — the mode and `hiDPI` are built from these.
        let floored = slopdesk_vd_geometry(0, -5, 0, 0);
        assert_eq!((floored.point_width, floored.point_height), (1, 1));
        assert_eq!((floored.scale, floored.max_horizontal_pixels), (1, 1));
        assert_eq!((floored.pixel_width, floored.pixel_height), (1, 1));
        assert_eq!((retina.point_width, retina.point_height), (1920, 1080));
        assert_eq!((retina.scale, retina.max_horizontal_pixels), (2, 7680));
    }

    #[test]
    fn the_millimetre_bit_patterns_survive_the_crossing() {
        let size = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, slopdesk_vd_default_target_ppi());
        assert_eq!(size.width.to_bits(), 4_648_474_625_199_435_851);
        assert_eq!(size.height.to_bits(), 4_644_628_951_744_622_164);
        let nan = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, f64::NAN);
        let floored = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, 1.0);
        assert_eq!(nan.width.to_bits(), floored.width.to_bits());
    }

    #[test]
    fn a_display_list_crosses_as_four_scalars_each() {
        // Bit patterns rather than values: `-0.0` is what a fold gets wrong while comparing equal.
        let bits = |origin: super::SlopDeskVirtualDisplayOrigin| (origin.x.to_bits(), origin.y.to_bits());
        let zero = (0.0_f64.to_bits(), 0.0_f64.to_bits());
        let displays = [0.0, 0.0, 1920.0, 1080.0, 1920.0, 0.0, 2560.0, 1440.0];
        // SAFETY: one live buffer of eight scalars, borrowed for the call.
        let origin = unsafe { slopdesk_vd_origin_to_right(displays.as_ptr(), 2) };
        assert_eq!(bits(origin), (4480.0_f64.to_bits(), 0.0_f64.to_bits()));
        // SAFETY: the documented empty cases, neither of which dereferences the pointer.
        let empty = unsafe { slopdesk_vd_origin_to_right(displays.as_ptr(), 0) };
        assert_eq!(bits(empty), zero);
        // SAFETY: a null list is the documented absent case.
        let absent = unsafe { slopdesk_vd_origin_to_right(std::ptr::null(), 2) };
        assert_eq!(bits(absent), zero);
    }

    #[test]
    fn the_brand_crosses_as_a_borrowed_span() {
        let limit = |brand: &str| {
            // SAFETY: the string outlives the call.
            unsafe { slopdesk_vd_chip_pixel_limit(brand.as_ptr(), brand.len()) }
        };
        assert_eq!(limit("Apple M1"), 6144);
        assert_eq!(limit("Apple M1 Max"), 7680);
        // SAFETY: a null brand is the documented absent case, answering the permissive limit.
        assert_eq!(unsafe { slopdesk_vd_chip_pixel_limit(std::ptr::null(), 8) }, 7680);
    }

    #[test]
    fn the_modes_fit_the_stated_ceiling_and_a_short_buffer_writes_nothing() {
        let mut out = [0.0_f64; SLOPDESK_VD_MAX_REFRESH_RATES];
        // SAFETY: one live buffer of the stated ceiling, written for the call.
        let count = unsafe { slopdesk_vd_refresh_rates(90, out.as_mut_ptr(), out.len()) };
        assert_eq!(count, 4);
        let bits = |rates: &[f64]| rates.iter().map(|rate| rate.to_bits()).collect::<Vec<_>>();
        assert_eq!(bits(&out), bits(&[120.0, 90.0, 60.0, 30.0]));

        let mut short = [-1.0_f64; 2];
        // SAFETY: a buffer smaller than the answer — the count comes back, the buffer does not.
        let needed = unsafe { slopdesk_vd_refresh_rates(90, short.as_mut_ptr(), short.len()) };
        assert_eq!(needed, 4);
        assert_eq!(
            bits(&short),
            bits(&[-1.0, -1.0]),
            "a truncated order is a wrong order"
        );
        assert!(needed <= SLOPDESK_VD_MAX_REFRESH_RATES);
    }
}

#[cfg(all(test, target_os = "macos"))]
mod handle_tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use core::ffi::c_void;
    use core::ptr;

    use super::{
        SlopDeskVirtualDisplay, slopdesk_virtual_display_create, slopdesk_virtual_display_destroy,
        slopdesk_virtual_display_free, slopdesk_virtual_display_id,
        slopdesk_virtual_display_private_classes_available, slopdesk_virtual_display_scale,
        slopdesk_virtual_display_set_terminated,
    };

    /// Every door must be inert on null, because the Swift face's `deinit` runs on a handle that a
    /// failed `_new` never produced, and a crash there would take the daemon down on shutdown.
    ///
    /// `_scale` answers 1 rather than 0 on purpose: the caller multiplies a capture rect by it.
    #[test]
    fn every_door_is_inert_on_null() {
        let null: *mut SlopDeskVirtualDisplay = ptr::null_mut();
        // SAFETY: null is the documented inert argument for every one of these.
        unsafe {
            assert_eq!(slopdesk_virtual_display_id(null), 0);
            assert_eq!(slopdesk_virtual_display_scale(null), 1);
            assert_eq!(
                slopdesk_virtual_display_create(null, 1920, 1080, 2, 8192, 60, ptr::null(), 0),
                0,
                "a create with no handle is a failure, and every failure is 0",
            );
            slopdesk_virtual_display_set_terminated(null, None, ptr::null_mut());
            slopdesk_virtual_display_destroy(null);
            slopdesk_virtual_display_free(null);
        }
    }

    /// A handle that never got a display must tear down clean, and `_destroy` must be idempotent.
    /// This is the path every host without the private classes takes, and the one where every lock
    /// the teardown touches holds `None`.
    #[test]
    fn an_unused_handle_frees_clean() {
        let handle = super::slopdesk_virtual_display_new();
        assert!(!handle.is_null(), "`_new` never answers null");
        // SAFETY: a live handle from `_new`, with no other call in flight.
        unsafe {
            assert_eq!(slopdesk_virtual_display_id(handle), 0);
            assert_eq!(slopdesk_virtual_display_scale(handle), 1);
            slopdesk_virtual_display_destroy(handle);
            slopdesk_virtual_display_destroy(handle);
            assert_eq!(slopdesk_virtual_display_id(handle), 0);
            // Clearing the callback before the free is what the Swift `deinit` does, so the box its
            // context points into can be released once the free returns.
            slopdesk_virtual_display_set_terminated(handle, None, ptr::null_mut());
            slopdesk_virtual_display_free(handle);
        }
    }

    /// The gate answers a strict boolean and instantiates nothing — it is asked on every pane mint,
    /// including on a machine where the answer is no, and a gate that built something to find out
    /// would be a display per mint.
    #[test]
    fn the_gate_answers_a_boolean_and_creates_nothing() {
        let first = slopdesk_virtual_display_private_classes_available();
        assert!(first <= 1, "the gate answers 1 or 0, never a count");
        assert_eq!(
            first,
            slopdesk_virtual_display_private_classes_available(),
            "the answer is cached, so asking twice cannot differ",
        );
    }

    /// A registered callback survives being replaced by a null one, which is the clear the Swift
    /// `deinit` performs. Nothing fires here — there is no `WindowServer` termination to provoke —
    /// so what is asserted is that the door accepts both forms and the handle stays usable.
    #[test]
    fn a_callback_can_be_registered_and_cleared() {
        extern "C" fn never(_context: *mut c_void) {}
        let handle = super::slopdesk_virtual_display_new();
        // SAFETY: a live handle from `_new`, and a context that outlives the free below.
        unsafe {
            let mut context = 0_u8;
            slopdesk_virtual_display_set_terminated(
                handle,
                Some(never),
                ptr::from_mut(&mut context).cast::<c_void>(),
            );
            slopdesk_virtual_display_set_terminated(handle, None, ptr::null_mut());
            assert_eq!(slopdesk_virtual_display_id(handle), 0);
            slopdesk_virtual_display_free(handle);
        }
    }
}
