//! The injection doors — the first in this crate that cause an EFFECT rather than compute an
//! answer, and macOS-only for the same reason `git_status` is.
//!
//! `rust/slopdesk-apple-cgevent` builds and posts the events; `slopdesk_video::input_routing`
//! decides what should be posted. This is the door, and it holds neither half.
//!
//! ## Why these four take a struct BY VALUE instead of `(ptr, len)`
//!
//! The convention in `crate`'s header exists to move an ANSWER across without an allocation. These
//! carry no answer — the return is whether CoreGraphics made the event at all — and what they carry
//! IN is a fixed record of scalars on the hottest path in the product: a remote pointer stream is
//! about 150 hover moves a second, each of which would otherwise be a serialise on one side and a
//! parse on the other for eleven fields that already have a C layout. A `#[repr(C)]` struct by
//! value is that layout, so the crossing costs registers and no memory at all.
//!
//! [`slopdesk_inject_text`] is the exception, and takes the usual `(ptr, len)` because its input is
//! a string.
//!
//! ## macOS only, and the three spellings that keep it true
//!
//! The `cfg` here, the `TARGET_OS_OSX` guard in `slopdesk_ffi.h`, and the `MACOS-ONLY` region
//! `scripts/build-ffi.sh` reads out of that header. The script requires each symbol PRESENT on the
//! macOS slice and ABSENT on both iOS slices, so a `cfg` that stopped matching the header fails the
//! build in whichever direction it drifted. See `docs/57-apple-frameworks-in-rust.md` §3.

use core::ffi::c_uchar;

use slopdesk_apple_cgevent::{Button, PointerKind, PointerPost, ScrollPost};

use crate::borrow;

/// A pure hover move.
pub const SLOPDESK_INJECT_MOVE: u8 = 0;
/// A button going down.
pub const SLOPDESK_INJECT_DOWN: u8 = 1;
/// A button coming up.
pub const SLOPDESK_INJECT_UP: u8 = 2;
/// A button-held move.
pub const SLOPDESK_INJECT_DRAG: u8 = 3;

/// The primary button.
pub const SLOPDESK_INJECT_BUTTON_LEFT: u8 = 0;
/// The secondary button.
pub const SLOPDESK_INJECT_BUTTON_RIGHT: u8 = 1;
/// Everything else, which CoreGraphics numbers as the centre button.
pub const SLOPDESK_INJECT_BUTTON_OTHER: u8 = 2;

/// One pointer event, as it crosses.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskInjectPointer {
    /// The absolute CG point, top-left origin.
    pub x: f64,
    /// The absolute CG point's Y.
    pub y: f64,
    /// The self-inject stamp the cursor and geometry watchers filter on.
    pub tag: u32,
    /// Deliver straight to this pid; `0` posts at the HID tap, which is the production path.
    pub to_pid: i32,
    /// One of the four `SLOPDESK_INJECT_*` event codes. An unknown code is a hover.
    pub kind: u8,
    /// One of the three `SLOPDESK_INJECT_BUTTON_*` codes. An unknown code is the primary button.
    pub button: u8,
    /// The originating click's count; raised to 1 on the way out.
    pub click_count: u8,
    /// The wire's modifier bits.
    pub modifiers: u8,
    /// Warp the cursor before posting.
    pub warp: bool,
    /// Post the one-round-trip tablet-point move instead of warping. Hover only.
    pub tablet: bool,
}

/// One scroll event, as it crosses.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskInjectScroll {
    /// Horizontal delta in points, pre-gain.
    pub dx: f64,
    /// Vertical delta in points, pre-gain.
    pub dy: f64,
    /// The gain applied before the delta is narrowed.
    pub gain: f64,
    /// The self-inject stamp, as [`SlopDeskInjectPointer::tag`].
    pub tag: u32,
    /// The loopback seam, as [`SlopDeskInjectPointer::to_pid`].
    pub to_pid: i32,
    /// The CoreGraphics scroll-phase code; `0` is absent.
    pub scroll_phase: u8,
    /// The CoreGraphics momentum-phase code; `0` is absent.
    pub momentum_phase: u8,
    /// Whether the source gesture was precise rather than a wheel notch.
    pub continuous: bool,
    /// Whether the two phase fields are replayed at all.
    pub phased: bool,
}

/// `0` means the HID tap, which is what the production path always passes.
const fn destination(to_pid: i32) -> Option<i32> {
    if to_pid == 0 { None } else { Some(to_pid) }
}

impl SlopDeskInjectPointer {
    /// The crate's spec.
    const fn of(self) -> PointerPost {
        PointerPost {
            kind: match self.kind {
                SLOPDESK_INJECT_DOWN => PointerKind::Down,
                SLOPDESK_INJECT_UP => PointerKind::Up,
                SLOPDESK_INJECT_DRAG => PointerKind::Drag,
                _ => PointerKind::Move,
            },
            button: match self.button {
                SLOPDESK_INJECT_BUTTON_RIGHT => Button::Right,
                SLOPDESK_INJECT_BUTTON_OTHER => Button::Other,
                _ => Button::Left,
            },
            x: self.x,
            y: self.y,
            click_count: self.click_count,
            modifiers: self.modifiers,
            tag: self.tag,
            warp: self.warp,
            tablet: self.tablet,
            to_pid: destination(self.to_pid),
        }
    }
}

impl SlopDeskInjectScroll {
    /// The crate's spec.
    const fn of(self) -> ScrollPost {
        ScrollPost {
            dx: self.dx,
            dy: self.dy,
            gain: self.gain,
            scroll_phase: self.scroll_phase,
            momentum_phase: self.momentum_phase,
            continuous: self.continuous,
            phased: self.phased,
            tag: self.tag,
            to_pid: destination(self.to_pid),
        }
    }
}

/// Posts one pointer event. `false` means CoreGraphics refused to build it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_inject_pointer(spec: SlopDeskInjectPointer) -> bool {
    slopdesk_apple_cgevent::post_pointer(&spec.of())
}

/// Posts one scroll event. `false` means CoreGraphics refused to build it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_inject_scroll(spec: SlopDeskInjectScroll) -> bool {
    slopdesk_apple_cgevent::post_scroll(&spec.of())
}

/// Posts one key edge, at the HID tap and never stamped — see the crate's `post_keyboard`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_inject_key(key_code: u16, down: bool, modifiers: u8) -> bool {
    slopdesk_apple_cgevent::post_key(key_code, down, modifiers)
}

/// Types `text` as Unicode, layout-independently. `false` means the bytes were not UTF-8 or
/// CoreGraphics refused to build the event.
///
/// # Safety
/// `text` must be null or point to `len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inject_text(text: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    core::str::from_utf8(bytes).is_ok_and(slopdesk_apple_cgevent::post_text)
}

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    reason = "the translation must be exact, so an exact comparison is the assertion"
)]
mod tests {
    use slopdesk_apple_cgevent::{Button, PointerKind};

    use super::{
        SLOPDESK_INJECT_BUTTON_OTHER, SLOPDESK_INJECT_BUTTON_RIGHT, SLOPDESK_INJECT_DRAG,
        SLOPDESK_INJECT_MOVE, SLOPDESK_INJECT_UP, SlopDeskInjectPointer, SlopDeskInjectScroll,
    };

    const fn pointer(kind: u8, button: u8) -> SlopDeskInjectPointer {
        SlopDeskInjectPointer {
            x: 12.5,
            y: -3.25,
            tag: 7,
            to_pid: 0,
            kind,
            button,
            click_count: 2,
            modifiers: 0b0000_1001,
            warp: true,
            tablet: false,
        }
    }

    /// The two code tables, both directions of the ones that matter.
    #[test]
    fn every_code_names_the_event_and_button_the_header_says_it_does() {
        assert_eq!(pointer(SLOPDESK_INJECT_MOVE, 0).of().kind, PointerKind::Move);
        assert_eq!(pointer(SLOPDESK_INJECT_UP, 0).of().kind, PointerKind::Up);
        assert_eq!(pointer(SLOPDESK_INJECT_DRAG, 0).of().kind, PointerKind::Drag);
        assert_eq!(
            pointer(0, SLOPDESK_INJECT_BUTTON_RIGHT).of().button,
            Button::Right
        );
        assert_eq!(
            pointer(0, SLOPDESK_INJECT_BUTTON_OTHER).of().button,
            Button::Other
        );
    }

    /// An unknown code is the harmless member of its family, never a panic and never a different
    /// gesture: a garbled `kind` hovers, a garbled `button` is the primary one.
    #[test]
    fn an_unknown_code_degrades_rather_than_inventing_a_gesture() {
        assert_eq!(pointer(200, 200).of().kind, PointerKind::Move);
        assert_eq!(pointer(200, 200).of().button, Button::Left);
    }

    /// `to_pid` is a presence flag, not a pid to trust: only a non-zero one names a destination.
    #[test]
    fn a_zero_pid_is_the_hid_tap_and_anything_else_is_a_destination() {
        assert_eq!(pointer(0, 0).of().to_pid, None);
        let mut spec = pointer(0, 0);
        spec.to_pid = 4242;
        assert_eq!(spec.of().to_pid, Some(4242));
    }

    /// Every remaining field crosses unchanged. The door's whole job is that it does not edit them.
    #[test]
    fn the_scalars_cross_verbatim() {
        let post = pointer(SLOPDESK_INJECT_DRAG, SLOPDESK_INJECT_BUTTON_RIGHT).of();
        assert_eq!(post.x, 12.5);
        assert_eq!(post.y, -3.25);
        assert_eq!(post.tag, 7);
        assert_eq!(post.click_count, 2);
        assert_eq!(post.modifiers, 0b0000_1001);
        assert!(post.warp);
        assert!(!post.tablet);

        let scroll = SlopDeskInjectScroll {
            dx: -1.5,
            dy: 2.5,
            gain: 1.25,
            tag: 9,
            to_pid: 0,
            scroll_phase: 4,
            momentum_phase: 0,
            continuous: true,
            phased: true,
        }
        .of();
        assert_eq!(scroll.dx, -1.5);
        assert_eq!(scroll.dy, 2.5);
        assert_eq!(scroll.gain, 1.25);
        assert_eq!(scroll.tag, 9);
        assert_eq!(scroll.scroll_phase, 4);
        assert_eq!(scroll.momentum_phase, 0);
        assert!(scroll.continuous);
        assert!(scroll.phased);
        assert_eq!(scroll.to_pid, None);
    }
}
