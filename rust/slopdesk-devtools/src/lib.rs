//! The operator tools, with their decidable halves out of the binaries.
//!
//! Every one of these was a Python script under `scripts/`, and every one had the same untested
//! core: the scanner that decides which Swift line is a declaration, the projection that decides
//! which JSON field counts as a difference, the corpus generator whose determinism is the only
//! reason a parity run means anything twice. As a library those are functions with unit tests; as
//! a script they were prose in a docstring.
//!
//! The binaries in `src/bin/` are argument parsing, process spawning and printing, and nothing
//! else.

#![deny(missing_docs)]
#![deny(missing_debug_implementations)]
#![deny(unreachable_pub)]

pub mod access;
pub mod differential;
pub mod manifests;
pub mod repo;
pub mod rng;
pub mod synclient;
