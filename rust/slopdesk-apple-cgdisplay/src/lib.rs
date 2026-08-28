//! Quartz display services — which displays exist, where each one sits, and each one's gamma ramp.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value, or a wish into one framework call, and makes no decisions of its own.
//! Which display a window belongs to is `slopdesk-video`'s rule, and so is what to do about it;
//! whether a session should darken the host's own panel is `slopdesk-video`'s rule too, and
//! [`set_gamma_black`] only knows how to do it and how to undo it.
//!
//! Every rect here is CG global points, top-left origin — the same space `kCGWindowBounds` and the
//! Accessibility API use. `NSScreen.frame` is NOT that space (it is bottom-left) and reading a
//! display through `AppKit` would need a y-flip nobody remembers to write, which is why this crate
//! exists rather than a two-line `AppKit` call.
//!
//! ## The `unsafe` here, and why it is the framework's contract and not Rust's
//!
//! `CGDisplayBounds` is generated safe: an id in, a `CGRect` out. The three enumerators are not,
//! because each reports through an out-pointer. Each call below lends a FULLY INITIALISED local
//! array and a fully initialised count, so nothing on this side is uninitialised, nothing is
//! dereferenced, and no length is asserted after the fact — the whole obligation is the framework's
//! own "write at most `max_displays` ids and report how many", which the buffer's size satisfies by
//! construction. The reported count is then clamped to the buffer anyway, because a framework that
//! over-reported would otherwise be trusted.
//!
//! The gamma pair adds two more of the same kind. `CGDisplayRestoreColorSyncSettings` and
//! `CGSetDisplayTransferByFormula` are generated safe — scalars in, nothing out. The setter and the
//! getter are not, because a gamma table is passed as three parallel arrays: the setter lends ONE
//! fully initialised value the header explicitly allows to be shared across all three channels, the
//! getter lends three fully initialised arrays and is told a capacity that is exactly their length.
//! Neither dereferences anything on this side, and the getter's reported sample count is clamped to
//! the arrays for the same reason the enumerators clamp theirs.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod displays;
#[cfg(target_os = "macos")]
mod gamma;

#[cfg(target_os = "macos")]
pub use displays::{Display, active, backing_scale, bounds_of, online, under};
#[cfg(target_os = "macos")]
pub use gamma::{restore_gamma, set_gamma_black};
