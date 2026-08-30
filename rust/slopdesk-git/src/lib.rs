//! # `slopdesk-git`
//!
//! The repository state behind the sidebar's git line, answered in process.
//!
//! - [`status`] — the whole answer for one directory: whether it is a repository, its branch, its
//!   divergence from upstream, its stash depth, its toplevel, its origin, and one entry per changed
//!   path carrying the porcelain `XY` pair the wire is pinned to. The answer's TYPE is the wire's
//!   own `GitStatusPayload` — a struct here with the same eight fields would be a mirror to keep in
//!   step, and the reply this feeds already has one.
//! - [`project_key`] — which repository a directory belongs to, by the boundary alone: the nearest
//!   ancestor carrying a `.git`. The one question here that does not open the repository.
//! - [`porcelain`] — the `XY` pair itself: how `git2`'s bitflags become the two characters `git
//!   status --porcelain` prints, and how those characters pack into the byte the client unpacks.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.** The C is behind `git2`'s bindings.
//! * **Every answer is best-effort.** A missing repository, an unreadable index, a branch with no
//!   upstream and a repository that vanished between two calls all answer the same way: the field
//!   keeps its default and the rest of the answer stands. This replaced four subprocesses that
//!   already behaved this way — a probe that returns "could not tell" for the whole struct because
//!   one of seven questions failed is a worse answer than the six that succeeded.
//! * **The porcelain pair is a WIRE contract, not an internal choice.**
//!   `golden/golden_vectors.json` freezes the packed byte and the client mirrors the nibble table's
//!   inverse to name a change category. [`porcelain`] is the only place either half of that is
//!   spelled.

pub mod porcelain;
pub mod project_key;
pub mod status;

pub use status::of_path;
