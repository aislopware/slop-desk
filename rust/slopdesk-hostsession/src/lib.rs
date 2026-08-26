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
//! Stage C.2a was the pane→wire direction; C.2c added the ladders that change WHO is attached —
//! [`PaneSession::join`] with its snapshot compose, [`PaneSession::detach`],
//! [`PaneSession::rebind`] and the size fold with its three timers. What is left for C.2d is the
//! CONTROL surface: the metadata verbs and their admission, the agent detector's three loops, the
//! screen scanner, the echo probe's re-assert on join, and the project-key derivation. Every one of
//! them lands over this same [`shared::Shared`], which is why the lock partition is the module
//! worth reading first.
//!
//! Two things C.2c leaves marked rather than done, both because they need a face C.2d brings: the
//! join and rebind re-asserts stop at the block backfill (the echo truth and the activity burst are
//! the detector's), and [`resize::Resize::apply`] does not yet mark the screen model dirty.
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
mod resize;
mod session;
mod shared;
mod snapshot;
mod subscriber;
mod timer;

pub use resize::{RESIZE_DEBOUNCE, SIZE_SETTLE};
pub use session::{PaneSession, SessionConfig, SessionObserver, SilentObserver};
pub use shared::{DiscardLog, SessionLog};
pub use snapshot::SnapshotPolicy;
