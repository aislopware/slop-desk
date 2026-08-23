//! The operator tools, with their decidable halves out of the binaries.
//!
//! Every one of these was a Python script under `scripts/`, and every one had the same untested
//! core: the scanner that decides which Swift line is a declaration, the projection that decides
//! which JSON field counts as a difference, the corpus generator whose determinism is the only
//! reason a parity run means anything twice. As a library those are functions with unit tests; as
//! a script they were prose in a docstring.
//!
//! The release pipeline arrived the same way and for the same reason: nine shell scripts sharing a
//! tool table, a semver arithmetic and a commit grammar by `source`-ing each other, none of which
//! any gate could reach. As [`release`] they are modules with unit tests, and the binary over them
//! is the eight verbs a release needs.
//!
//! ## Where the line with `slopdesk-invariants` actually falls
//! That crate holds every rule a gate can decide by READING the tree, and its gate is `cargo test`.
//! [`gates`] is the other half: the seven whose verdict comes from a PROCESS — an xcodebuild, a
//! booted simulator, a `swift test`, an `adb` handshake. Neither belongs in the other. A rule that
//! spawns a toolchain is not a unit test, and a build gate that only reads text would not be a
//! build gate. What the two share is the discipline: the decidable half — the selection, the key
//! sets, the stamp, the count — is a function with a test beside it, not prose in a comment.
//!
//! The binaries in `src/bin/` are argument parsing, process spawning and printing, and nothing
//! else.

#![deny(missing_docs)]
#![deny(missing_debug_implementations)]
#![deny(unreachable_pub)]

pub mod access;
pub mod differential;
pub mod gates;
pub mod manifests;
pub mod release;
pub mod repo;
pub mod rng;
pub mod synclient;
