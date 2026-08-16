//! The pure core of the user-facing `slopdesk` CLI.
//!
//! One binary exposing a subcommand surface onto the control plane. Everything here is a value
//! transform: no socket, no `exit`, no GUI launch — so the whole flag, table and validation surface
//! is exhaustively testable without a running app, which is the hang-safety rule that shaped the
//! Swift original and is worth keeping.
//!
//! - [`args`] — the global-flag parser.
//! - [`completions`] — the five shells' completion scripts, from one subcommand list.
//! - [`config`] — config-file path resolution and the keybind-grammar validator.
//! - [`formatting`] — the list/inspect tables and their JSON form.
//! - [`version`] — the `version` banner.
//!
//! ## What is deliberately elsewhere
//! - The **`watch` byte vocabulary** — `OSC 9;4` progress and the `OSC 777` finish banner — lives
//!   in `slopdesk-wire::osc`, next to the parser that reads it back, so the round-trip is one test
//!   rather than two modules agreeing by review.
//! - The **`watch:claude` exit-code machine** lives in `slopdesk-agent::watch`: every input it
//!   reads is an agent fact.
//! - **Jump resolution** lives in `slopdesk-workspace::jump`, over the frecency database it ranks.
//!
//! Each of those was a file in `SlopDeskCLICore` only because Swift's module graph put it there.
//! Splitting on what a thing is ABOUT, rather than on which binary happens to call it, is what lets
//! all four crates stay dependency-free of one another.

#![forbid(unsafe_code)]

pub mod args;
pub mod completions;
pub mod config;
pub mod formatting;
pub mod version;

pub use args::{Invocation, OutputFormat, ParseError};
pub use completions::Shell;
pub use config::ValidationError;
pub use formatting::Row;
