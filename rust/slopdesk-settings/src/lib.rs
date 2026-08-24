//! # `slopdesk-settings`
//!
//! What slopdesk can be CONFIGURED to do, as data, plus the two projections the window chrome
//! switches between.
//!
//! - [`config`] — every setting: its path in `config.toml`, its domain, its default and its one
//!   sentence; the resolver that reads a file against that table; and the JSON Schema written out
//!   of it so an editor can complete and validate the file as it is typed.
//! - [`chrome`] — what the window shows AROUND the panes: the tabs panel that must not fight a
//!   manual collapse, the close prompt, and the Dock tile.
//! - [`responsive`] — the one switch between the two projections, and the live-video ceiling that
//!   scales with the machine behind it.
//!
//! ## Why there is no Settings window any more
//!
//! There was one — four thousand lines of pages, rows, controls and an index over them, in front of
//! a first-launch flow that asked four questions. Every answer it collected was already written
//! down as a DEFAULT in the table it read. So the window's whole job was to re-ask a question the
//! table had answered better, and the onboarding asked it before the user had seen a terminal.
//! Both are deleted. The install is the setup; the file is for the reader who wants to disagree,
//! and the schema is what makes disagreeing pleasant.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **Three dependencies, and each is here for the file.** `toml` parses it, `slopdesk-terminal`
//!   owns the control vocabularies a choice key must not respell, and nothing else. The old "zero
//!   dependencies" rule was a property of a catalogue that decided nothing; a config file that
//!   parses a real document format cannot keep it, and pretending otherwise would mean a
//!   hand-rolled parser beside the ecosystem's.
//! * **Total functions.** Nothing here indexes, unwraps or panics — the lint table denies all three
//!   — and [`config::resolve`] cannot fail at all: a file that is not TOML resolves to the defaults
//!   plus a diagnostic, because a syntax error must never be the reason a terminal will not open.

pub mod chrome;
pub mod config;
pub mod responsive;
