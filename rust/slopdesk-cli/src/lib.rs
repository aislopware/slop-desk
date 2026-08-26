//! The user-facing `slopdesk` CLI, whole.
//!
//! One binary exposing a subcommand surface onto the control plane. The PURE core is still pure —
//! flags, tables, formatting are value transforms with no socket and no process — and the two
//! modules that do touch the world are shaped so a test can still enter them: [`shell`]'s
//! subcommands talk to the app through a `Control` trait and hand back an exit code instead of
//! taking one, so the only thing left that a test cannot reach is `main.rs` wiring the real argv,
//! the real environment and the real stdio in.
//!
//! - [`vocabulary`] — WHICH subcommands exist, which of them run, and what each is for. The one
//!   table the completions, the help text and the dispatcher all derive from.
//! - [`args`] — the global-flag parser, and the flags' own help rows beside the grammar.
//! - [`completions`] — the five shells' completion scripts, from the runnable half of that table.
//! - [`formatting`] — the list/inspect tables and their JSON form.
//! - [`version`] — the `version` banner's shape (the NUMBER is the package's, and is passed in).
//! - [`clientctl`] — re-exported from `slopdesk-clientctl`: the client control protocol's method
//!   names, its token vocabularies, its parameter builders and its NDJSON framing. It is a crate
//!   rather than a module here because the app links it too, through `slopdesk-ffi` — see that
//!   crate's header for why it is neither `slopdesk-wire`'s nor this one's.
//! - [`shell`] — the process: the environment, the sinks, the failure, and one arm per verb.
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
pub mod shell;
pub mod version;
pub mod vocabulary;

pub use args::{GlobalFlag, Invocation, OutputFormat, ParseError};
pub use completions::Shell;
pub use formatting::Row;
pub use shell::{Control, Ctx, Environment, Failure, Io, Run, run};
/// The client control protocol, under the name every call site in [`shell`] already spells.
///
/// A re-export rather than a module: the app's dispatcher reads the same vocabulary through
/// `slopdesk-ffi`, and a module inside this binary's library is not something an `.xcframework` can
/// link. Nothing about the call sites changed when it moved.
pub use slopdesk_clientctl as clientctl;
pub use vocabulary::{Availability, Subcommand};
