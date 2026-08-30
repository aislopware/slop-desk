//! `NSEvent` — the live input hardware, read as a value.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and makes no decisions of its own. Where the pointer is relative to a
//! captured window, whether that counts as visible, and how often to ask are all
//! `slopdesk_video::cursor_sampling`'s, and this crate cannot see any of them.
//!
//! ## The space, which is the whole reason this crate is `NSEvent`
//! [`pointer_cocoa`] answers GLOBAL COCOA POINTS — origin at the primary display's BOTTOM-LEFT,
//! +Y up. That is the space `cursor_sampling::window_position` documents as its input, so the
//! sampler's flip to CG happens once, there, against a display height it already caches.
//!
//! `CGEventGetLocation` would answer the same pointer in CG global points, top-left origin, and
//! would therefore need flipping BACK through the primary display's height before it could be
//! handed over — a second flip against a number this crate would have to fetch per sample.
//! `slopdesk-apple-cgdisplay`'s header names that y-flip as the bug it exists to avoid; asking
//! `AppKit` for a number `AppKit` already keeps in the caller's space avoids writing it at all.
//!
//! ## Off the main thread, on purpose
//! `mouseLocation` is a CLASS method with no `MainThreadMarker` in its generated signature: it is a
//! window-server query rather than `AppKit` view state, which is exactly what lets
//! `slopdesk-videohostd`'s 120 Hz cursor thread call it directly. A read that had to hop would put
//! the pointer stream behind whatever the main thread is doing, and the main thread is where a
//! window raise spends six to ten accessibility round-trips.
//!
//! ## No `unsafe`, and neither CoreFoundation admission
//! `objc2-app-kit` generates `mouseLocation` SAFE — nothing in, a `CGPoint` out — so there is no
//! `#[expect(unsafe_code)]` in this file. Neither §2 admission is spent: no CoreFoundation object
//! crosses this boundary, only the two `f64`s inside the point.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
use slopdesk_video::geometry::VideoPoint;

/// The pointer, in GLOBAL COCOA POINTS — origin bottom-left, +Y up.
///
/// The module note has why this space and not CG's, and why the call is safe off the main thread.
/// There is no failure arm: `NSEvent.mouseLocation` answers the last location the window server
/// recorded, and a host with no pointer events yet answers wherever the pointer was placed at
/// login — a number, never an absence.
#[cfg(target_os = "macos")]
#[must_use]
pub fn pointer_cocoa() -> VideoPoint {
    // Generated SAFE — see the module note. A class method with no marker, so nothing here asserts
    // a thread and nothing here can refuse.
    let point = objc2_app_kit::NSEvent::mouseLocation();
    VideoPoint::new(point.x, point.y)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::pointer_cocoa;

    /// The read answers a real number from any thread, which is the whole contract the sampling
    /// thread depends on. Its VALUE is the window server's and cannot be asserted — a headless
    /// runner, a shared CI machine and a desk with a hand on the mouse all answer differently — so
    /// what is pinned is that neither coordinate comes back as a NaN the position math would
    /// silently propagate into every datagram.
    ///
    /// The thread is spawned explicitly rather than trusting libtest's harness, for
    /// `slopdesk-apple-nsapp`'s reason: which thread a test body runs on is the harness's business
    /// and changes with `--test-threads`, and this assertion is about a thread.
    #[test]
    fn the_pointer_reads_finite_off_the_main_thread() {
        let read = std::thread::spawn(pointer_cocoa).join().ok();
        assert!(
            read.is_some_and(|point| point.x.is_finite() && point.y.is_finite()),
            "{read:?}",
        );
    }

    /// Asked a thousand times it accumulates nothing — the leak test `docs/57` §3 asks each crate
    /// in this family for, in the shape this crate's one observable has. No object is retained on
    /// this path at all: the class method answers a `CGPoint` by value and nothing enters an
    /// autorelease pool, so what the loop proves is that the read stays a read.
    #[test]
    fn repeated_reads_accumulate_nothing() {
        for _ in 0..1_000 {
            let point = pointer_cocoa();
            assert!(point.x.is_finite() && point.y.is_finite(), "{point:?}");
        }
    }
}
