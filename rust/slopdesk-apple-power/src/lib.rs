//! `IOKit` power-management assertions — one held assertion, driven to a desired state.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns a
//! decision that has ALREADY been made into a system effect, and makes none of its own. Who should
//! keep the Mac awake is `slopdesk_agent::sleep`'s rule; who should keep the display awake
//! is `slopdesk_video::display_wake`'s. Both are safe crates, and both answer a `bool` that arrives
//! here as [`SleepAssertion::set_asserted`]'s argument.
//!
//! ## Balance is the whole contract
//! A leaked `IOPMAssertion` keeps the machine — or its screen — awake until the process dies, and
//! it does not self-heal. So [`SleepAssertion`] creates on a false→true edge, releases on a
//! true→false edge, is a no-op in either steady state, and releases on drop. A create that FAILS
//! leaves the assertion un-held (validate-then-default), so the next edge retries rather than
//! releasing an id that was never made.
//!
//! ## The `unsafe` here, and why it is the framework's contract and not Rust's
//! ONE block, and the count is worth stating: `IOPMAssertionRelease` takes its id by value and
//! dereferences nothing, so `objc2` generates it SAFE and this crate calls it as such. Only
//! `IOPMAssertionCreateWithName` reports through an out-pointer, and this side lends it a fully
//! initialised local `u32` that outlives the call — the obligation carried is the framework's own
//! "on success, write a unique reference", and nothing is read back through the pointer here.
//!
//! `IOPMLib.h`'s other rule — an id is released ONCE per successful create — is therefore not held
//! by an `unsafe` block claiming it. It is held by the type: [`SleepAssertion`] owns the only copy
//! of the id, is neither `Clone` nor `Copy`, clears the copy before the release rather than after,
//! and never hands it out. "Once" is a property of the type, which is where §2 wants it.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod assertion;

#[cfg(target_os = "macos")]
pub use assertion::{SleepAssertion, SleepKind};
