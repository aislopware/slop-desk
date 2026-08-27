//! `CoreGraphics`' virtual-display area — creating ONE `HiDPI` display and holding it registered.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything. This crate does one thing:
//! it turns a [`Geometry`] into a live `CGDirectDisplayID` and keeps it alive. Every number that
//! geometry carries — the point grid, the backing pixels, the millimetre size, the advertised
//! refresh rates, where the display lands in the global space — is decided in `slopdesk-video`,
//! which is `forbid(unsafe_code)` and pinned by the golden corpus. Nothing here recomputes one.
//!
//! ## The four classes, and why reaching them needs no raw-pointer work
//!
//! `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings` and
//! `CGVirtualDisplayMode` are Objective-C CLASSES that live in the PUBLIC
//! `CoreGraphics.framework` — only their headers are private. A class is reachable by NAME through
//! the Objective-C runtime, so [`objc2::runtime::AnyClass::get`] plus `msg_send!` is the whole
//! mechanism: no `dlsym`, no hand-declared `extern` signature, no function-pointer `transmute`, no
//! `slice::from_raw_parts`, no `ptr::read`. That is what keeps this area inside the
//! `slopdesk-apple-*` family instead of pushing it into `slopdesk-posix` the way
//! `_AXUIElementGetWindow` had to go.
//!
//! `AnyClass::get` answers `Option`, which collapses TWO of the old Objective-C shim's devices into
//! one lookup: the `weak_import` linkage attribute that stopped dyld failing the bind at launch,
//! and the `NSClassFromString` gate the Swift ran before the first message send. A future macOS
//! that renames one of the four turns [`private_classes_available`] `false`, and every entry point
//! answers "no display" instead of crashing the daemon.
//!
//! NEITHER `CoreFoundation` admission is spent here. There is no `CFRetained::from_raw` and no
//! `CFRetained::retain` in this crate, because no `CoreFoundation` object crosses its boundary:
//! every object arrives as an Objective-C `Retained` from a message send, where `msg_send!` already
//! encodes the ownership convention.
//!
//! ## The two threading rules, which point in opposite directions
//!
//! - `initWithDescriptor:` is a SYNCHRONOUS `WindowServer` Mach round-trip and must run on the main
//!   thread; [`mainhop::on_main`] is the only way it is ever called.
//! - `applySettings:` BLOCKS for seconds on the same link and must NOT run on the main thread; it
//!   runs on a thread of its own under a ceiling ([`apply`]), so a wedged `WindowServer` costs the
//!   caller ten seconds rather than the process.
//!
//! [`VirtualDisplay::create`] is therefore an OFF-MAIN call that hops to main twice inside itself.
//! Calling it FROM the main thread deadlocks, and its own doc says so.
//!
//! ## What keeps the display alive
//!
//! The `Retained<CGVirtualDisplay>` IS the registration — releasing it unregisters the display
//! through the same synchronous Mach IPC, which is why every release in this crate goes through the
//! main queue. The process must also keep a live run loop, which is the caller's business
//! (`slopdesk-videohostd` runs `NSApplication.run()` when the virtual display is enabled).

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod apply;
#[cfg(target_os = "macos")]
mod classes;
#[cfg(target_os = "macos")]
mod descriptor;
#[cfg(target_os = "macos")]
mod display;
#[cfg(target_os = "macos")]
mod extend;
#[cfg(target_os = "macos")]
mod mainhop;
#[cfg(target_os = "macos")]
mod settings;

#[cfg(target_os = "macos")]
pub use classes::private_classes_available;
#[cfg(target_os = "macos")]
pub use display::VirtualDisplay;
#[cfg(target_os = "macos")]
pub use extend::{ExtendOutcome, Pin, extend, pins};
// The geometry is RE-EXPORTED, never redefined: `slopdesk-video` owns it and the golden corpus
// pins its arithmetic bit-for-bit, so a second spelling here would be a second answer.
#[cfg(target_os = "macos")]
pub use slopdesk_video::virtual_display::Geometry;
