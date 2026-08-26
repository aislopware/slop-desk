//! One pane's session: the shell that turns `slopdesk-hostpane`'s descriptor, `slopdesk-hostnet`'s
//! transport and `slopdesk-muxsession`'s verdicts into a running pane.
//!
//! This is stage C.2 of `docs/60-hostd-in-rust.md`, and the shape of it is the finding that scoped
//! the stage: almost none of `Sources/SlopDeskHost/MuxChannelSession.swift` is a DECISION. The
//! outbox, the fanout, the truths, the lifecycle and the resize fold are `slopdesk-muxsession`'s;
//! the replay ring and the pause gate are `slopdesk-wire`'s; the detector and the screen engine are
//! `slopdesk-agent`'s; the probes are `slopdesk-posix`'s. What was left in Swift was the SHELL
//! around them — the threads, the locks, the queues and the ladders — and that is what lives here.
//!
//! ## Why its own crate
//!
//! Not `slopdesk-muxsession`: that crate is verdicts with NO IO, deliberately, and it does not
//! depend on the protocol crate at all — the merge cap is passed IN so it stays spelled once. Not
//! `slopdesk-hostpane`: that is one pane's descriptor and its supervised stream, and it knows
//! nothing about members or the wire. Not `slopdesk-hostnet`: that is the transport, and it decides
//! nothing about panes. This crate is the one place that may hold all four, so it is the one place
//! the joins between them can live.
//!
//! ## What it does not do yet
//!
//! Stage C.2a is the pane→wire direction and enough of an attach to test it end to end. The ladders
//! that change WHO is attached — join with its snapshot compose, detach, rebind, the resize
//! ladder — are C.2c, and the metadata verbs, the agent detector, the screen scanner and the
//! project-key derivation are C.2d. Every one of them lands over this same [`shared::Shared`],
//! which is why the lock partition is the module worth reading first.
//!
//! ## What it does not DELETE, and why
//!
//! Nothing. `docs/60` §5's carve-out is the reason: stages A–E cannot obey "one implementation,
//! never two languages" literally, because hostd is still a Swift process until the cutover at
//! stage F. The eleven Swift faces this ports — `PaneOutbox`, `PaneFanout`, `PaneTruths`,
//! `PaneLifecycle`, `PaneResizeFold`, `PausableQueueGate`, `ReplayBuffer`, `ClaudePaneDetector`,
//! `PaneScreenScanner`, `PTYEcho` and `TerminalReplaySnapshot` — stand until then, and F is what
//! takes all of them at once.

// Every module below is PRIVATE, and `lib.rs`'s `pub use` block is this crate's whole surface: the
// six locks, the roster and the drain's frames are internals that hostd must reach only through
// `PaneSession`, because the ladders that land at C.2c and C.2d get their atomicity from being the
// only writers. Two lints disagree about how to spell that, and they disagree with each other:
// `unreachable_pub` says an item in a private module must be `pub(crate)`, and
// `redundant_pub_crate` says a `pub(crate)` item in a private module should be `pub`. There is no
// spelling that satisfies both, so the crate keeps `unreachable_pub` — the one that catches a
// genuine mistake, an item accidentally exported — and expects the other here.
#![expect(
    clippy::redundant_pub_crate,
    reason = "directly contradicts `unreachable_pub`, which this crate keeps"
)]

mod clock;
mod drain;
mod facts;
mod ingest;
mod session;
mod shared;
mod subscriber;

pub use session::{PaneSession, SessionConfig, SessionObserver, SilentObserver};
pub use shared::{DiscardLog, SessionLog};
