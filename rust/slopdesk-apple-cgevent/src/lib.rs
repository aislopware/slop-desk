//! CoreGraphics event synthesis — build it, aim it, post it.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate translates a
//! decision into an effect and translates an observation back into a value, and it makes no
//! decisions of its own. Which event to build, whether the cursor is warped first, whether a
//! duplicate release is dropped — all of it is `slopdesk_video::input_routing`, which forbids
//! `unsafe` and always will.
//!
//! ## The one `unsafe` in the crate
//!
//! [`post_text`]. `CGEvent::keyboard_set_unicode_string` is one of the seven raw-pointer functions
//! `objc2-core-graphics` cannot generate safe, because its signature is `(count, *const u16)` and
//! nothing in the type says the two agree. Everything else here — the source, the three
//! constructors, every field setter, the warp, the two posts — is safe Rust.
//!
//! ## What the caller still owns
//!
//! Everything stateful. There is no injector object here and no handle protocol: the specs below
//! are plain values, the event source is a thread-local, and two callers posting concurrently is
//! two threads each holding their own handle onto the one `hidSystemState` the system shares.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod inject;

#[cfg(target_os = "macos")]
pub use inject::{
    Button, PointerKind, PointerPost, ScrollPost, post_key, post_pointer, post_scroll, post_text,
};
