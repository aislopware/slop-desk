//! CoreGraphics window-list reads — ask the `WindowServer`, decode the answer, hand back records.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns an
//! observation into a value and makes no decisions of its own. Who is frontmost is
//! `slopdesk_video::window_list`; which occluder is an attached panel is the caller's; both of
//! those forbid `unsafe` and always will.
//!
//! ## The three `unsafe` blocks, and why each is the framework's contract and not Rust's
//!
//! `CGWindowListCopyWindowInfo` is generated SAFE, and so is every CoreFoundation accessor the
//! decode uses — `CFArray::get`, `CFDictionary::get`, `CFRetained::downcast`, `CFNumber::as_i64`,
//! `CFString`'s `Display`. Three things are not:
//!
//! 1. Reading the `kCGWindow*` key constants. They are `extern` statics, which Rust cannot prove
//!    initialised; CoreGraphics initialises them at image load.
//! 2. Naming the element type of the array the query answers. C's `CFArrayRef` carries no element
//!    type, so the documentation is the only place that says "an array of `CFDictionary`".
//! 3. The same, for the `CGRect` dictionary a record's bounds field holds — and there the value is
//!    checked against `CFDictionaryGetTypeID` FIRST, so only the key and value types are asserted.
//!
//! None of the three dereferences a pointer, transmutes, or takes ownership of a raw one. A typed
//! view of a CF collection only decides which `get` applies; every value read through it goes on to
//! check its own type id.
//!
//! ## What a missing field means
//!
//! Dropped, never defaulted. A record that cannot answer its layer, its owner or its bounds is a
//! record about a window this host has no business acting on — the Swift this replaced spelled that
//! rule four separate times, and one of the four defaulted `layer` to `Int.min` instead. There is
//! one spelling now, and it is the `?` in the decode.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod list;

#[cfg(target_os = "macos")]
pub use list::{WindowRecord, bounds_of, frontmost_pid, windows_in_front_of, windows_of_pid};
