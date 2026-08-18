//! Per-pane AGENT DETECTION: who is running in a pane, and what they are doing.
//!
//! This is the half of detection that reads the CLOCK. The other half — the manifest rule ladder,
//! the region resolver, the OSC and sync-frame trackers, everything that reads the terminal's
//! BYTES — is [`slopdesk-screend`](../../slopdesk-screend) (docs/50, docs/52). The two meet at one
//! value, [`AgentScreenDetection`]: screend produces it, and everything here consumes it.
//!
//! ## The modules
//! - [`kind`] — which agent a process name names (herdr's alias table, verbatim).
//! - [`job`] — which agent holds a pane's foreground process group, unwrapping the runtimes and
//!   shells that host one.
//! - [`process`] — the narrower question the presence poll asks: is it `claude`, or something that
//!   commonly WRAPS one?
//! - [`status`] — the rolled-up status, its urgency order, and the wire qualifier byte.
//! - [`signal`] — the semantic hook vocabulary and the signal envelope the machine folds.
//! - [`sleep`] — what a working agent means for the machine's own sleep.
//! - [`screen`] — the screen engine's verdict, in the terms the machine speaks.
//! - [`hold`] — the temporal layer over that verdict: the confirmation holds and the publish gate.
//! - [`input`] — does an input chunk carry a keystroke, or only the emulator's own replies?
//! - [`machine`] — the state machine itself, the one place all of it comes together.
//! - [`detector`] — one layer up: not "what is the status now" but what the host OWES the client
//!   after that fold — the dedupe anchors, the stickiness clock, the session intent, the title
//!   ownership. One of these per pane, and it is the only thing that constructs a machine.
//!
//! ## What is guaranteed
//! - **No `unsafe`.** `#![forbid(unsafe_code)]`, so not even a downstream `allow` can bring it
//!   back.
//! - **No panics on hostile input.** Every input here is untrusted — a hook body from a nested
//!   agent, a title written by whatever holds the PTY foreground, an input chunk from a client
//!   emulator, an argv from a process nobody here launched. Indexing goes through `get`, every
//!   scanner is total, and a malformed sequence is a conservative answer rather than an abort.
//! - **No clock and no randomness.** Every time-driven rule takes an absolute `now` argument, so
//!   the same signals in the same order give the same statuses, forever. That is what makes a
//!   detection bug reproducible from a transcript instead of from a machine.
//! - **No dependencies.** See the manifest for why.

#![forbid(unsafe_code)]

pub mod badge;
pub mod detector;
pub mod hold;
pub mod input;
pub mod job;
pub mod kind;
pub mod machine;
pub mod process;
pub mod screen;
pub mod signal;
pub mod sleep;
pub mod status;
pub mod watch;

pub use detector::{Emission, PaneDetector, StatusTriple, block_kind, intent_line, topic_line};
pub use hold::AgentDetectionHold;
pub use input::{contains_cancel_keystroke, contains_user_keystroke};
pub use job::{ForegroundJob, ForegroundJobProcess, SymlinkResolver};
pub use kind::AgentKind;
pub use machine::ClaudeStatusMachine;
pub use screen::{AgentScreenDetection, AgentScreenState};
pub use signal::{ClaudeHookEvent, ClaudeSignal, NotificationKind};
pub use status::{AgentStatusKind, ClaudeStatus};
pub use watch::{WatchExit, WatchObservation, WatchStep};
