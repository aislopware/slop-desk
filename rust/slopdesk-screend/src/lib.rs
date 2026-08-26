//! `slopdesk-screend` — the terminal SCREEN service.
//!
//! Raw PTY bytes in, an ANSWER out. Four things in the host used to do this in Swift and no
//! longer do: the agent-detection tier ([`detect`] — what a pane's screen SAYS, rule ladder and
//! manifests included, so the answer that crosses the socket is a verdict rather than a screen),
//! the `screen` ctl verb (what an agent can READ back), the cold-reattach composer (the VT stream
//! that reproduces a pane's visible state on a client that just reconnected), and the scrollback
//! REPLAY transform ([`sanitize`]) — seven byte passes over the retained ring that used to cross
//! this socket once each and now cross it once in total.
//!
//! ## Why it is a separate binary
//! The screen model is the hottest byte loop in the host and the least macOS-specific code in it —
//! a state machine over bytes with no framework anywhere near it. The Swift original ran at
//! 17.9 MiB/s (a `String` per cell and a `[[Cell]]` grid: ARC traffic plus a nested-array
//! uniqueness check per printed character); this one runs an order of magnitude faster on the same
//! corpus, and it runs OFF the host's actor. That matters most on the path nobody sees: iOS drops
//! TCP seconds after backgrounding, so every foreground is a cold reattach that composes the whole
//! retained ring.
//!
//! Since then the same line has drawn in everything else in the host that READS the outbound
//! stream: the command-block segmenter ([`commandblocks`]) and the fused out-of-band sniffer
//! ([`sniffer`]) that finds title, bell, command status, working directory and notifications in one
//! pass. Anything that parses these bytes lives here; anything that decides what FRAME to send
//! about them does not.
//!
//! Per the tree's standing rule, this is a separate binary over a socket — never FFI — so
//! `swift build` stays headless and cargo-free.

pub mod cell;
pub mod detect;
pub mod manifest;
pub mod model;
pub mod osc;
/// The wire, re-exported from [`slopdesk_screenwire`] so this crate's modules and its `main` keep
/// naming it `protocol` — it is screend's wire whichever crate compiles it.
pub use slopdesk_screenwire as protocol;
pub mod region;
pub mod registry;
pub mod render;
pub mod rules;
pub mod server;
pub mod syncwatch;

// The replay transform and the byte scanners live in `slopdesk-sanitize` now — one crate, linked by
// this daemon AND by the app, rather than a socket verb the host had to dial to reach a pure
// function. Re-exported so this crate's own callers and modules name them in one place.
pub use cell::{Cell, CellStyle, CellText, SgrColor};
pub use detect::{
    Input as DetectionInput, Verdict, detect, explain, known_agent_idle_fallback, verdict_from_rule,
};
pub use manifest::{Manifest, State as AgentScreenState};
pub use model::{ReplaySnapshot, ScreenModel, ScrollbackLine, Snapshot};
pub use render::{render, render_transcript};
pub use rules::CompiledManifest;
pub use slopdesk_sanitize::{
    InputModeFinalState, Options as SanitizeOptions, altscreen, boundary, collapse, distill, inputmode,
    overprint, prompteol, query, sanitize, syncframe, vtscan, width,
};
