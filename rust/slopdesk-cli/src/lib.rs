//! The pure core of the user-facing `slopdesk` CLI.
//!
//! One binary exposing a subcommand surface onto the control plane. Everything here is a value
//! transform: no socket, no `exit`, no GUI launch — so the whole flag, table and validation surface
//! is exhaustively testable without a running app, which is the hang-safety rule that shaped the
//! Swift original and is worth keeping.
//!
//! - [`vocabulary`] — WHICH subcommands exist, which of them run, and what each is for. The one
//!   table the completions, the help text and the dispatcher all derive from.
//! - [`args`] — the global-flag parser, and the flags' own help rows beside the grammar.
//! - [`completions`] — the five shells' completion scripts, from the runnable half of that table.
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
//! - The **config file** lives in `slopdesk-settings::config`: where it is, what keys it holds, and
//!   the schema that describes them. It used to be here, back when the file held nothing but
//!   `keybind` lines and the CLI was its only reader. The app reads the same file now, so the
//!   grammar belongs with the table rather than with one of its callers.
//!
//! Each of those was a file in `SlopDeskCLICore` only because Swift's module graph put it there.
//! Splitting on what a thing is ABOUT, rather than on which binary happens to call it, is what lets
//! all four crates stay dependency-free of one another.

#![forbid(unsafe_code)]

pub mod args;
pub mod completions;
pub mod formatting;
pub mod version;
pub mod vocabulary;

pub use args::{GlobalFlag, Invocation, OutputFormat, ParseError};
pub use completions::Shell;
pub use formatting::Row;
pub use vocabulary::{Availability, Subcommand};
