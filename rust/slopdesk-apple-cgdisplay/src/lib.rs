//! Quartz display-services reads — which displays exist, and where each one sits.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and makes no decisions of its own. Which display a window belongs to is
//! `slopdesk-video`'s rule, and so is what to do about it.
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

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod displays;

#[cfg(target_os = "macos")]
pub use displays::{Display, active, bounds_of, online, under};
