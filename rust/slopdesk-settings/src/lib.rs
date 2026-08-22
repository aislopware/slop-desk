//! # `slopdesk-settings`
//!
//! What Settings OFFERS, as data, plus the two projections the window chrome switches between.
//!
//! - [`settings_catalog`] — the sections, the choices in every group, and the scalar ladders' stops
//!   and readouts.
//! - [`settings_rows`] — the other half of the same page: every setting as a ROW, with the one
//!   label and the one description it carries wherever it appears.
//! - [`settings_layout`] — how those rows fall into pages, and what a page looks like once it has
//!   them.
//! - [`chrome`] — what the window shows AROUND the panes: the tabs panel that must not fight a
//!   manual collapse, the close prompt, and the Dock tile.
//! - [`responsive`] — the one switch between the two projections, and the live-video ceiling that
//!   scales with the machine behind it.
//!
//! ## Why this is not a module of `slopdesk-workspace`
//!
//! Five thousand lines that decide nothing. A change in here changes a string, a stop or a default
//! — never a behaviour — and while it sat beside the tree operations, anything that wanted to know
//! a slider's default had the workspace document's domain rules underneath it.
//!
//! ## Invariants
//!
//! * **No `unsafe`, enforced by `forbid(unsafe_code)`.**
//! * **No dependencies, ours or anyone else's.** The module graph says this crate earns the leaf
//!   position rather than merely occupying it: nothing in here reaches for a pane, a tab or a
//!   session. A catalogue that needed one would not be a catalogue.
//! * **One deliberate cycle, and it is why this is one crate rather than two.** [`settings_layout`]
//!   and [`settings_rows`] are mutually recursive — a row needs the page it lands on and a page
//!   needs its rows — so the split line cannot pass between them.
//! * **Total functions.** Nothing here indexes, unwraps or panics — the lint table denies all
//!   three.

pub mod chrome;
pub mod responsive;
pub mod settings_catalog;
pub mod settings_layout;
pub mod settings_rows;
