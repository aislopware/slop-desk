//! `FSEvents` — one directory in, "something under it changed" out.
//!
//! Read `docs/57-apple-frameworks-in-rust.md` §2 before adding anything: this crate turns a
//! framework subscription into a Rust value with a `Drop`, and makes no decision of its own. WHICH
//! directory to watch, how long to wait before believing a burst has ended, and whether the change
//! is worth pushing to a client are `slopdesk_muxsession::repo_watch`'s, which forbids `unsafe`.
//!
//! ## The event carries nothing, on purpose
//! [`Watch`] delivers a bare `()`. `FSEvents` hands its callback a path list, a flag word and an
//! event id per event, and `repo_watch` reads none of the three — its debounce keys on the WATCH
//! path it already knows and its verdict comes from re-reading the repository. Surfacing them would
//! be a decode this repository never consults, which §2 says a wrapper crate may not perform, and a
//! second definition of "did this matter" beside the one that already exists.
//!
//! ## The one thing worth reading twice: there is no context pointer
//! The Swift this replaces (`RepoStatusWatcher.fsEventsSource`) round-tripped an
//! `Unmanaged<EventBox>` through `FSEventStreamContext.info`, balanced by a `release` callback and
//! by a manual `box.release()` on the create-failure arm. In Rust that shape is `Box::into_raw` on
//! one side and a raw-pointer dereference on the other, and §2 bars this family from writing the
//! second.
//!
//! So the context is NULL and the callback identifies itself by the `FSEventStreamRef` the
//! framework passes it as its first argument — an ADDRESS, used as a key, never dereferenced. The
//! table is a process-wide `Mutex<HashMap<usize, …>>`; [`Watch`]'s `Drop` removes its row after
//! `FSEventStreamInvalidate` returns. A callback already dispatched when that happens finds no row
//! and does nothing, which is the whole failure mode — where the pointer version's equivalent race
//! is a read of freed memory.
//!
//! ## Why a queue is a parameter
//! `repo_watch`'s handle door forbids two overlapping calls, and the confinement that satisfies it
//! is the caller's serial queue. Owning a queue here would give the caller a second one to
//! serialise against, so the queue arrives from outside and this crate retains it only so the
//! stream's delivery target cannot be freed before the stream is.
//!
//! macOS-only, with no cross-platform shape: `FSEvents` is a HOST capability and the host is a Mac.
//! `slopdesk-apple-power` is the precedent — a crate whose whole subject does not exist elsewhere
//! offers no stub to call there.

#![cfg_attr(not(target_os = "macos"), allow(unused_crate_dependencies))]

#[cfg(target_os = "macos")]
mod watch;

#[cfg(target_os = "macos")]
pub use watch::Watch;
