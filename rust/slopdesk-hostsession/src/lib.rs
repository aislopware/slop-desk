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
//! ## What C.2 turned out to be
//!
//! Stage C.2a was the pane→wire direction; C.2c added the ladders that change WHO is attached —
//! [`PaneSession::join`] with its snapshot compose, [`PaneSession::detach`],
//! [`PaneSession::rebind`] and the size fold with its three timers. C.2d added the DETECTION
//! surface: the foreground poll, the screen scan, the echo probe, the cwd/project derivation, the
//! full arrival re-assert and the readouts a supervision caller asks for. C.2e added the
//! ORCHESTRATOR's: the three tap registries ([`taps`]), the metadata RPC with its bound and its
//! serial queue ([`metadata`]), and the scrollback readouts behind `read`/`last-output`
//! ([`history`]). Every one of them lands over this same [`shared::Shared`], which is why the lock
//! partition is the module worth reading first.
//!
//! Three of C.2d's decisions are worth knowing before reading it. The detector lives INSIDE the
//! truths lock rather than beside it ([`shared::Folds`]), because every readout that pairs the two
//! must see them agree. The screen scan's question is INJECTED ([`ScreenOracle`]), for the reason
//! the snapshot renderer is: a session that linked the screend client would spawn a daemon the
//! moment a test built one. And both detection loops park on a condvar rather than sleeping, so a
//! teardown does not wait out an interval the engine chose.
//!
//! C.2e's are three more of the same shape. The metadata RPC and the project walk share ONE
//! executor instance, because a `git status` overtaking the resolve of the `cd` that caused it
//! would report a project the pane had already left. The performer is injected for
//! [`ScreenOracle`]'s reason, while the ROUTING it is given stays in Rust. And the close tap fires
//! between the EOF gate and the exit message, which is what makes "every output byte, then the
//! close" a guarantee rather than a timing accident.
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
mod detect;
mod drain;
mod facts;
mod history;
mod ingest;
mod metadata;
mod probe;
mod project;
mod resize;
mod session;
mod shared;
mod snapshot;
mod subscriber;
mod taps;
mod timer;

pub use detect::{DetectConfig, ScreenOracle, ScreenRequest};
pub use metadata::{MetadataAnswer, MetadataPerformer, MetadataRequest, UnservedMetadata};
pub use project::{IgnoreKeys, InlineResolve, KeyObserver, ResolveExecutor};
pub use resize::{RESIZE_DEBOUNCE, SIZE_SETTLE};
pub use session::{PaneSession, SessionConfig, SessionObserver, SilentObserver};
pub use shared::{DiscardLog, SessionLog};
pub use snapshot::SnapshotPolicy;
pub use taps::{BlockTap, BlockUpdate, CloseTap, OutputTap, TapToken};
