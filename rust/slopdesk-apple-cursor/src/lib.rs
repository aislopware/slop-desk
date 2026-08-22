//! `NSCursor` — the shape the person is looking at, as bytes.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and makes no decisions of its own. WHEN to re-read the cursor, what id
//! a shape gets, whether the pointer is inside the captured window and what size to render at next
//! are all `slopdesk_video::cursor`'s, which forbids `unsafe`.
//!
//! ## `currentSystemCursor`, never `current`
//! `NSCursor::currentCursor` is THIS process's own cursor stack, and a background `.accessory`
//! daemon's stack is empty — so it answers the arrow forever while the person is looking at an
//! I-beam, and the client's pointer freezes on the wrong shape for the session's whole life. The
//! system-wide displayed cursor is the one that crosses the window-server boundary.
//!
//! The fallback to `currentCursor` when `currentSystemCursor` is nil is kept from the Swift this
//! replaced: nil is rare, and an arrow is a better answer than no pointer at all.
//!
//! ## The seed is not here
//! `CGSCurrentCursorSeed` — the counter that says the displayed shape changed — is resolved with
//! `dlsym` and called through a declared C signature, which is a raw function-pointer transmute.
//! §2 bars that from this family, so the OPERATION moved rather than the rule bending:
//! `slopdesk_posix::dynsym::cursor_seed`.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod imaging;

#[cfg(target_os = "macos")]
pub use imaging::{Bitmap, measure, render_png};

/// The displayed cursor, as values.
///
/// The bitmap is TIFF because that is what `AppKit` hands back without a re-encode, and because the
/// caller's first use for it is a CONTENT KEY: two reads of the same displayed shape must compare
/// equal even though the framework builds a fresh object per read. PNG is what finally ships, and
/// it is produced separately by [`render_png`] at whatever size the caller decided on.
#[derive(Clone, Debug, PartialEq)]
pub struct CursorShape {
    /// The hotspot in cursor-local points — where inside the image the click actually lands.
    pub hotspot_x: f64,
    /// The hotspot's y, in the same points.
    pub hotspot_y: f64,
    /// The LOGICAL size in points, which is what the client composites at. Not the pixel size:
    /// a `HiDPI` cursor's bitmap can be many times this.
    pub width: f64,
    /// The logical height, in the same points.
    pub height: f64,
    /// The image's TIFF bytes, empty when the framework had no representation to give.
    pub tiff: Vec<u8>,
}

/// The displayed system cursor, or `None` when neither it nor this process's own stack answers.
///
/// # Panics
/// Never. The `MainThreadMarker` is obtained rather than asserted, and a call from another thread
/// answers `None` — which the caller already treats as "keep the last shape", the same degraded
/// path a nil cursor takes.
#[cfg(target_os = "macos")]
#[must_use]
pub fn current_system() -> Option<CursorShape> {
    use objc2_app_kit::NSCursor;

    // AppKit requires the main thread for both of these. Asking for the marker rather than
    // asserting one is what makes an off-main call a `None` instead of a crash in a daemon whose
    // cursor sampler is deliberately multi-threaded.
    let _main = objc2_foundation::MainThreadMarker::new()?;
    // DEPRECATED in the bindings, with a note pointing at ScreenCaptureKit's `showsCursor`. That
    // advice is for a capture that DRAWS the pointer into the frame; this one deliberately does
    // not — the client composites the cursor itself from a bitmap shipped once, so the frame stays
    // free of it and a cursor move costs a 64-byte datagram rather than a re-encode. There is no
    // non-deprecated API for "what shape is the window server displaying".
    #[expect(
        deprecated,
        reason = "the replacement draws the cursor INTO the capture, which is the design this avoids"
    )]
    let cursor = NSCursor::currentSystemCursor().unwrap_or_else(NSCursor::currentCursor);
    let hotspot = cursor.hotSpot();
    let image = cursor.image();
    let size = image.size();
    let tiff = image
        .TIFFRepresentation()
        .map(|data| data.to_vec())
        .unwrap_or_default();
    Some(CursorShape {
        hotspot_x: hotspot.x,
        hotspot_y: hotspot.y,
        width: size.width,
        height: size.height,
        tiff,
    })
}

/// The non-macOS shape, so a caller compiles everywhere and links the doors only where they exist.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub const fn current_system() -> Option<CursorShape> {
    None
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::current_system;

    /// Off the main thread the read must answer NOTHING rather than trap. A `cargo test` thread is
    /// not `AppKit`'s main thread, so this is also the only arm a headless suite can reach — and it
    /// is the arm that matters, because the sampler's hot path runs on its own queue.
    #[test]
    fn a_read_off_the_main_thread_answers_nothing_rather_than_trapping() {
        let read = std::thread::spawn(current_system).join();
        assert_eq!(read.ok().flatten(), None);
    }

    /// Called repeatedly off-main it keeps answering the same nothing — no state accumulates, no
    /// autorelease pool grows, nothing is cached. The leak test `docs/57` §3 asks each crate for.
    #[test]
    fn repeated_reads_accumulate_nothing() {
        for _ in 0..1_000 {
            assert_eq!(std::thread::spawn(current_system).join().ok().flatten(), None);
        }
    }
}
