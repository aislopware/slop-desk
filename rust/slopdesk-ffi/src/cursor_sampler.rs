//! The cursor side-channel's host end: the shape, the seed, and every decision between them.
//!
//! `Sources/SlopDeskVideoHost/CursorSampler.swift` was a 389-line class holding four rules, two
//! `AppKit` reads and a `dlsym`, none of it tested because none of it could run without an `AppKit`
//! run loop. This handle is what is left of it on this side of the boundary; the Swift keeps the
//! timer, the one window-server mouse query, and the two sockets.
//!
//! Three crates meet here, which is the reason this module is in the shim rather than in any of
//! them:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | [`slopdesk_video::cursor_sampling`] | when to refresh, where the pointer is, which id, what size |
//! | `slopdesk-apple-cursor` | the displayed shape's bitmap and hotspot, and a PNG at a given size |
//! | [`slopdesk_posix::dynsym`] | the window server's cursor seed |
//!
//! ## This handle is the ONE that may be called from two threads
//! The header's handle convention says no two calls on one handle may overlap. Every other handle
//! keeps that because its Swift owner is already serialised; this one cannot, and the reason is the
//! bug it was built around. The 120 Hz position sample runs OFF the main thread precisely so that a
//! main-thread window raise — six to ten synchronous accessibility round-trips — cannot freeze the
//! pointer, while the shape read is main-thread-ONLY because `AppKit` says so. So two threads call
//! this handle by design, and it carries its own locks instead of borrowing the caller's.
//!
//! The locks are two, not one, and nothing is rendered while either is held: a PNG render under the
//! position path's lock would reintroduce exactly the stall the split exists to prevent.
//!
//! ## What still crosses per call
//! Encoded wire messages, both ways — `docs/55` §4's "the answer that is a REPLY". The Swift face
//! forwards a [`CursorUpdate`] or a [`CursorShapeMessage`] to a socket verbatim and never looks
//! inside one, so decoding here to re-encode there would be work with no reader.

use core::ffi::c_uchar;
use std::collections::HashMap;
use std::sync::Mutex;

use slopdesk_video::cursor::{CursorShapeMessage, CursorUpdate};
use slopdesk_video::cursor_sampling::{
    MAX_SHAPE_BITMAP_BYTES, ShapeRefreshPolicy, ShapeTable, render_ladder, window_position,
};
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

use crate::deliver;

/// The cursor sampler's whole state.
#[derive(Debug)]
pub struct SlopDeskCursorSampler {
    /// Everything the 120 Hz position path reads, and the refresh path writes. Held for a handful
    /// of arithmetic operations and never across a framework call.
    hot: Mutex<Hot>,
    /// The shape inventory: content-to-id, and every encoded message minted so far. Touched only on
    /// the refresh path and by the re-ship door.
    shapes: Mutex<Shapes>,
}

/// The state the two threads share.
#[derive(Debug)]
struct Hot {
    /// The captured window in CG top-left points, kept current by the geometry watcher.
    bounds: VideoRect,
    /// The primary display's height, for the Cocoa-to-CG flip. Refreshed on the same main-thread
    /// trip as the shape, because nothing else brings the sampler to the main thread.
    primary_height: f64,
    /// The shape id every position update carries until the next refresh changes it.
    shape_id: u16,
    /// That shape's hotspot.
    hotspot: VideoPoint,
    /// Whether the first main-thread refresh has landed. Until it has, the position path answers
    /// NOTHING — an update sent before this would carry shape id 0, which the client has not been
    /// told about, and a screen height of 0, which would put the pointer off the bottom of the
    /// window.
    primed: bool,
    /// Ticks counted for the refresh cadence.
    tick: u64,
    /// The seed-to-refresh rule.
    policy: ShapeRefreshPolicy,
    /// Set when a refresh changed the shape id, cleared by
    /// [`slopdesk_cursor_sampler_take_id_change`]. The client only switches its pointer on the next
    /// update that carries the new id, so the face emits one immediately rather than letting the
    /// shape lag the mouse by up to a tick.
    id_changed: bool,
}

/// The shape inventory.
#[derive(Debug, Default)]
struct Shapes {
    /// Content to id.
    table: ShapeTable,
    /// Every encoded shape message minted this session, so a client whose one-shot shipment was
    /// lost can ask for it again without the cursor ever being read a second time.
    messages: HashMap<u16, Vec<u8>>,
    /// The message the last refresh minted, waiting to be read out.
    ///
    /// Parked rather than returned because the answer's size is what the render ladder DECIDES: a
    /// caller that guessed its buffer too small and called again would re-run the whole render, and
    /// the second run could legitimately answer a different size. The convention is
    /// [`crate::video_packetize`]'s.
    pending: Vec<u8>,
}

/// Turns a caller's handle pointer into a reference for one call.
///
/// Shared rather than exclusive, which is the whole difference from every other handle here: the
/// state behind it is locked, so two threads holding this reference at once is exactly what the
/// module documents rather than aliasing UB.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_cursor_sampler_new`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskCursorSampler) -> Option<&'a SlopDeskCursorSampler> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and the state behind it is guarded,
    // so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Builds a sampler for a window at these CG top-left bounds.
///
/// Never null. There is no argument this can refuse: a degenerate rect simply makes every pointer
/// position report as outside the window, which is what a zero-sized window means.
///
/// # Safety
/// The answer must be passed to [`slopdesk_cursor_sampler_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_cursor_sampler_new(
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> *mut SlopDeskCursorSampler {
    Box::into_raw(Box::new(SlopDeskCursorSampler {
        hot: Mutex::new(Hot {
            bounds: VideoRect::xywh(x, y, width, height),
            primary_height: 0.0,
            shape_id: 0,
            hotspot: VideoPoint::new(0.0, 0.0),
            primed: false,
            tick: 0,
            policy: ShapeRefreshPolicy::new(),
            id_changed: false,
        }),
        shapes: Mutex::new(Shapes::default()),
    }))
}

/// Releases a sampler. Null is inert.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_cursor_sampler_new`] that has not already
/// been freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cursor_sampler_free(handle: *mut SlopDeskCursorSampler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free.
    drop(unsafe { Box::from_raw(handle) });
}

/// Retargets the sampler at new window bounds, in CG top-left points.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cursor_sampler_set_bounds(
    handle: *mut SlopDeskCursorSampler,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return;
    };
    if let Ok(mut hot) = sampler.hot.lock() {
        hot.bounds = VideoRect::xywh(x, y, width, height);
    }
}

/// Counts one sampling tick and answers whether it should go to the main thread for a fresh shape.
///
/// Reads the window server's cursor seed itself — the caller has nothing to pass in and nothing to
/// decide. Call once per tick on the sampling thread, BEFORE or after the position sample; the two
/// are independent.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_should_refresh(handle: *mut SlopDeskCursorSampler) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return false;
    };
    let seed = slopdesk_posix::dynsym::cursor_seed();
    let Ok(mut hot) = sampler.hot.lock() else {
        return false;
    };
    hot.tick = hot.tick.wrapping_add(1);
    let tick = hot.tick;
    hot.policy.should_refresh(seed, tick)
}

/// The encoded [`CursorUpdate`] for a mouse at these GLOBAL COCOA points — bottom-left origin, the
/// space the off-main window-server query answers in.
///
/// Answers `0` before the first refresh has primed the shape and screen height, which is the whole
/// gate: an update sent early would name a shape the client has never been given.
///
/// The answer is a fixed [`CursorUpdate::ENCODED_SIZE`] bytes, so a caller sizes its buffer once
/// and never retries. Nothing here mutates the sampler, so a caller that did retry would get the
/// same answer for the same mouse position.
///
/// # Safety
/// `handle` must be null or live; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_position(
    handle: *mut SlopDeskCursorSampler,
    mouse_x: f64,
    mouse_y: f64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(hot) = sampler.hot.lock() else {
        return 0;
    };
    if !hot.primed {
        return 0;
    }
    let (position, visible) =
        window_position(VideoPoint::new(mouse_x, mouse_y), hot.primary_height, hot.bounds);
    let update = CursorUpdate::new(position, hot.shape_id, hot.hotspot, visible);
    drop(hot);
    // SAFETY: the caller's obligation, above.
    unsafe { deliver(&update.encode(), out, cap) }
}

/// Reads the displayed cursor and caches what the position path needs.
///
/// MAIN THREAD ONLY — `AppKit` says so, and a call from anywhere else answers `0` without touching
/// a thing.
///
/// Answers the byte length of a newly minted shape message, parked for
/// [`slopdesk_cursor_sampler_answer`], or `0` when the shape was one already shipped. `0` is the
/// common case by far: a session sees a few dozen distinct cursors and refreshes thousands of
/// times.
///
/// `primary_height` is the main display's height in points, for the Cocoa-to-CG flip. It is passed
/// in rather than read here because it is an `NSScreen` question, and `NSScreen` is a different
/// framework area than this crate's one cursor — `docs/57` §2 would want its own crate for it.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_refresh(
    handle: *mut SlopDeskCursorSampler,
    primary_height: f64,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Some(shape) = slopdesk_apple_cursor::current_system() else {
        return 0;
    };
    let hotspot = VideoPoint::new(shape.hotspot_x, shape.hotspot_y);

    let (id, minted) = {
        let Ok(mut shapes) = sampler.shapes.lock() else {
            return 0;
        };
        shapes.table.intern(&shape.tiff, hotspot)
    };

    {
        let Ok(mut hot) = sampler.hot.lock() else {
            return 0;
        };
        hot.id_changed |= hot.primed && hot.shape_id != id;
        hot.primary_height = primary_height;
        hot.shape_id = id;
        hot.hotspot = hotspot;
        hot.primed = true;
    }

    if !minted {
        return 0;
    }
    // The render is OUTSIDE both locks. It is the one expensive thing on this path — up to sixteen
    // draws and PNG encodes — and holding the position path's lock through it would stall the very
    // 120 Hz stream this design exists to keep flowing.
    let Some(png) = fitting_png(&shape.tiff, shape.width, shape.height) else {
        return 0;
    };
    let message =
        CursorShapeMessage::new(id, VideoSize::new(shape.width, shape.height), hotspot, png).encode();
    let length = message.len();
    let Ok(mut shapes) = sampler.shapes.lock() else {
        return 0;
    };
    shapes.messages.insert(id, message.clone());
    shapes.pending = message;
    length
}

/// Copies out the shape message the last [`slopdesk_cursor_sampler_refresh`] minted.
///
/// # Safety
/// `handle` must be null or live; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_answer(
    handle: *mut SlopDeskCursorSampler,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(shapes) = sampler.shapes.lock() else {
        return 0;
    };
    // SAFETY: the caller's obligation, above.
    unsafe { deliver(&shapes.pending, out, cap) }
}

/// An already-shipped shape message, by id, for a client that lost the one-shot shipment and asked
/// again over the recovery channel.
///
/// `0` for an id never minted — there is nothing to re-send, and reading the cursor again would
/// answer whatever shape is displayed NOW rather than the one asked for. Safe to call from any
/// thread: it reads a cache and touches no framework.
///
/// # Safety
/// `handle` must be null or live; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_shape(
    handle: *mut SlopDeskCursorSampler,
    shape_id: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(shapes) = sampler.shapes.lock() else {
        return 0;
    };
    let Some(message) = shapes.messages.get(&shape_id) else {
        return 0;
    };
    // SAFETY: the caller's obligation, above.
    unsafe { deliver(message, out, cap) }
}

/// Whether a refresh has changed the shape id since this was last asked — and CLEARS the flag.
///
/// Taken rather than read so the caller emits exactly one extra position update per change. The
/// client switches its pointer on the next update carrying the new id, and waiting for the ordinary
/// tick would show the old shape for up to one sampling interval after the cursor has already
/// changed under the person's hand.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_cursor_sampler_take_id_change(handle: *mut SlopDeskCursorSampler) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(sampler) = (unsafe { held(handle) }) else {
        return false;
    };
    let Ok(mut hot) = sampler.hot.lock() else {
        return false;
    };
    std::mem::replace(&mut hot.id_changed, false)
}

/// Renders the largest PNG of this cursor that fits one datagram.
///
/// Walks [`render_ladder`] largest-first and stops at the first PNG within
/// [`MAX_SHAPE_BITMAP_BYTES`]. If none fits — a pathological custom cursor — the SMALLEST one that
/// encoded at all is sent anyway: it will be IP-fragmented, which risks the shipment, and that
/// still beats a session with no pointer.
fn fitting_png(tiff: &[u8], logical_width: f64, logical_height: f64) -> Option<Vec<u8>> {
    let bitmap = slopdesk_apple_cursor::measure(tiff)?;
    let mut last = None;
    for (width, height) in render_ladder(
        logical_width.max(logical_height),
        bitmap.pixels_wide,
        bitmap.pixels_high,
    ) {
        let Some(png) = slopdesk_apple_cursor::render_png(tiff, width, height) else {
            continue;
        };
        if png.len() <= MAX_SHAPE_BITMAP_BYTES {
            return Some(png);
        }
        last = Some(png);
    }
    last
}

#[cfg(test)]
// Every door here is an `extern "C"` one, so calling it is the point rather than an escape.
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "calling the boundary IS what these tests are for"
)]
mod tests {
    use slopdesk_video::cursor::CursorUpdate;

    use super::{
        SlopDeskCursorSampler, slopdesk_cursor_sampler_answer, slopdesk_cursor_sampler_free,
        slopdesk_cursor_sampler_new, slopdesk_cursor_sampler_position, slopdesk_cursor_sampler_refresh,
        slopdesk_cursor_sampler_set_bounds, slopdesk_cursor_sampler_shape,
        slopdesk_cursor_sampler_should_refresh, slopdesk_cursor_sampler_take_id_change,
    };

    /// Every door is inert on null — the shape a Swift face relies on when construction failed, and
    /// the one that turns a lifecycle bug into nothing happening rather than a crash inside a
    /// daemon's 120 Hz timer.
    #[test]
    fn every_door_is_inert_on_null() {
        let null: *mut SlopDeskCursorSampler = std::ptr::null_mut();
        // SAFETY: null is the documented inert argument for every door here.
        unsafe {
            slopdesk_cursor_sampler_set_bounds(null, 1.0, 2.0, 3.0, 4.0);
            assert!(!slopdesk_cursor_sampler_should_refresh(null));
            assert_eq!(
                slopdesk_cursor_sampler_position(null, 0.0, 0.0, std::ptr::null_mut(), 0),
                0
            );
            assert_eq!(slopdesk_cursor_sampler_refresh(null, 1080.0), 0);
            assert_eq!(slopdesk_cursor_sampler_answer(null, std::ptr::null_mut(), 0), 0);
            assert_eq!(slopdesk_cursor_sampler_shape(null, 0, std::ptr::null_mut(), 0), 0);
            assert!(!slopdesk_cursor_sampler_take_id_change(null));
            slopdesk_cursor_sampler_free(null);
        }
    }

    /// Before any refresh the position path says NOTHING, however many times it is asked. This is
    /// the gate that keeps an update naming an unshipped shape id off the wire, and in a headless
    /// suite it is also the only state the sampler can be in — the shape read needs a main thread.
    #[test]
    fn nothing_is_emitted_before_the_first_refresh_primes_the_state() {
        let sampler = slopdesk_cursor_sampler_new(0.0, 0.0, 800.0, 600.0);
        let mut out = [0u8; CursorUpdate::ENCODED_SIZE];
        // SAFETY: `sampler` is live for this block and freed exactly once at its end.
        unsafe {
            for _ in 0..100 {
                assert_eq!(
                    slopdesk_cursor_sampler_position(sampler, 400.0, 300.0, out.as_mut_ptr(), out.len()),
                    0
                );
            }
            assert!(!slopdesk_cursor_sampler_take_id_change(sampler));
            slopdesk_cursor_sampler_free(sampler);
        }
    }

    /// The refresh cadence runs whether or not the shape can be read: it is driven by the seed and
    /// the tick count alone, so a headless process still sees the policy's rhythm. The first tick
    /// refreshes — that is the prime — and the ticks after it do not, because the cursor has not
    /// moved.
    #[test]
    fn the_cadence_advances_without_a_main_thread() {
        let sampler = slopdesk_cursor_sampler_new(0.0, 0.0, 800.0, 600.0);
        // SAFETY: `sampler` is live for this block and freed exactly once at its end.
        unsafe {
            assert!(
                slopdesk_cursor_sampler_should_refresh(sampler),
                "the first tick primes"
            );
            let refreshed = (2..=100)
                .filter(|_| slopdesk_cursor_sampler_should_refresh(sampler))
                .count();
            assert!(
                refreshed <= 25,
                "{refreshed} refreshes in 99 ticks is not a cadence"
            );
            slopdesk_cursor_sampler_free(sampler);
        }
    }

    /// A shape never minted has nothing to re-ship, and asking does not read the cursor to invent
    /// one — a client asking for a lost id must get that id or nothing, never whatever is on screen
    /// now.
    #[test]
    fn an_unknown_shape_id_has_nothing_to_reship() {
        let sampler = slopdesk_cursor_sampler_new(0.0, 0.0, 800.0, 600.0);
        // SAFETY: `sampler` is live for this block and freed exactly once at its end.
        unsafe {
            for id in [0, 1, 7, u16::MAX] {
                assert_eq!(
                    slopdesk_cursor_sampler_shape(sampler, id, std::ptr::null_mut(), 0),
                    0
                );
            }
            assert_eq!(
                slopdesk_cursor_sampler_answer(sampler, std::ptr::null_mut(), 0),
                0
            );
            slopdesk_cursor_sampler_free(sampler);
        }
    }

    /// Two threads on one handle is the case this module exists to allow, so it is the case the
    /// suite has to cover: a sampling thread hammering the position door while another retargets
    /// the bounds and asks for refreshes must not tear, deadlock or poison a lock.
    #[test]
    fn two_threads_may_share_one_handle() {
        let sampler = slopdesk_cursor_sampler_new(0.0, 0.0, 800.0, 600.0);
        let address = sampler as usize;
        let sampling = std::thread::spawn(move || {
            let handle = std::ptr::without_provenance_mut::<SlopDeskCursorSampler>(address);
            let mut out = [0u8; CursorUpdate::ENCODED_SIZE];
            // SAFETY: the handle outlives both threads — it is freed after the joins below.
            unsafe {
                for tick in 0..2_000 {
                    let _ = slopdesk_cursor_sampler_position(
                        handle,
                        f64::from(tick),
                        300.0,
                        out.as_mut_ptr(),
                        out.len(),
                    );
                    let _ = slopdesk_cursor_sampler_should_refresh(handle);
                }
            }
        });
        let geometry = std::thread::spawn(move || {
            let handle = std::ptr::without_provenance_mut::<SlopDeskCursorSampler>(address);
            // SAFETY: the handle outlives both threads — it is freed after the joins below.
            unsafe {
                for edge in 0..2_000 {
                    slopdesk_cursor_sampler_set_bounds(handle, 0.0, 0.0, f64::from(edge), 600.0);
                    let _ = slopdesk_cursor_sampler_take_id_change(handle);
                    let _ = slopdesk_cursor_sampler_refresh(handle, 1080.0);
                }
            }
        });
        sampling.join().expect("the sampling thread must not panic");
        geometry.join().expect("the geometry thread must not panic");
        // SAFETY: both threads have joined, so nothing is in flight and this is the single free.
        unsafe { slopdesk_cursor_sampler_free(sampler) };
    }

    /// A thousand new-and-free cycles accumulate nothing. The leak test for a handle whose whole
    /// job is holding a growing inventory of bitmaps.
    #[test]
    fn a_handle_releases_everything_it_held() {
        for _ in 0..1_000 {
            let sampler = slopdesk_cursor_sampler_new(0.0, 0.0, 1.0, 1.0);
            // SAFETY: freshly created above, freed exactly once, nothing in flight.
            unsafe {
                let _ = slopdesk_cursor_sampler_should_refresh(sampler);
                slopdesk_cursor_sampler_free(sampler);
            }
        }
    }
}
