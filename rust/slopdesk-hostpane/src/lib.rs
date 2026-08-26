//! One pane, as hostd holds it: the descriptor superd handed over, and the stream that comes back.
//!
//! ```text
//!            ┌──────────────────────────────────────────────┐
//!            │            MuxChannelSession (C.2)           │
//!            └───────────────┬──────────────────┬───────────┘
//!         keystrokes, resize │                  │ chunks, EOF
//!            ┌───────────────▼──────┐   ┌───────▼───────────┐
//!            │      PtyProcess      │   │  PaneOutputStream │
//!            │  the master, the     │   │  the subscription │
//!            │  verbs, the exit     │   │  and the pause    │
//!            └───────┬──────────────┘   └───────┬───────────┘
//!                    │  every verb              │  every chunk
//!            ┌───────▼──────────────────────────▼───────────┐
//!            │             SupervisorClient (C.0)           │
//!            └──────────────────────┬───────────────────────┘
//!                                   │  AF_UNIX
//!            ┌──────────────────────▼───────────────────────┐
//!            │      slopdesk-superd — forks it, reaps it,   │
//!            │      and owns `read` on the master           │
//!            └──────────────────────────────────────────────┘
//! ```
//!
//! - [`PtyProcess`] — spawn-or-take-over, adopt, the ioctls on hostd's own duplicate of the master,
//!   the signal ladder that routes through superd, and one-shot exit plumbing.
//! - [`PaneOutputStream`] — the subscription to superd's read of that master, delivered with no
//!   buffer on this side, plus the pause the bounded-queue gate asserts through it.
//! - [`resolve_cwd`] — where a fresh shell starts, validated here because the child's `chdir` runs
//!   in the fork window where nothing can fall back.
//!
//! ## What this crate does not decide
//! What a chunk BECOMES. There is no transport here, no framing, no queue policy and no replay
//! buffer: those are the session's, one layer up. This crate's whole contract is that a chunk
//! reaches its sink synchronously, once, in order, with the events found in exactly those bytes —
//! and that saying "pause" reaches superd.
//!
//! ## The two directions are deliberately asymmetric
//! Output goes superd → hostd, because superd must keep draining a pane no hostd is attached to.
//! Input goes hostd → the PTY directly, with no hop, because a keystroke's latency is the product's
//! whole premise. `TIOCSWINSZ` and `tcgetpgrp` go direct for the same reason. Only `read` moved,
//! and only `read` could.

pub mod cwd;
pub mod pane;
pub mod stream;

pub use cwd::resolve_cwd;
pub use pane::{PtyProcess, RedrawJiggle, WindowSize};
pub use stream::{FROM_NOW_ON, PaneChunkSink, PaneOutputStream, READ_CHUNK_BYTES};
