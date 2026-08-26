//! The state-transfer replay: a returning or joining client opens on a RENDERED screen.
//!
//! The port of `snapshotReplayTailForSend`, `composeSnapshotReplay` and `composeJoinSnapshot`
//! (docs/DECISIONS.md 2026-07-25). The idea is one line long: instead of replaying however many
//! kilobytes of byte history a client missed, feed that history through a screen model once, render
//! the resulting grid, and ship THAT. A client that has been away for an hour receives one screen
//! rather than an hour of scrollback, and the seqs the rendered stream rides are the ones the raw
//! replay would have used, so nothing downstream can tell the difference.
//!
//! ## The renderer is INJECTED, and that is deliberate
//!
//! [`SnapshotPolicy`] is a trait this crate never implements. The production composer is a screen
//! model that lives above hostsession, and wiring it in here would give the session an edge to it —
//! the same edge `MuxChannelSession` refused by taking a `SnapshotReplayPolicy` struct. A session
//! with no policy replays raw, which is exactly what every test that has not asked for a screen
//! model wants. hostd injects the real one at stage C.2d.
//!
//! ## Three ways to decline, and every one of them is cheaper than composing
//!
//! 1. **No seqs to ride.** Nothing retained above the client's cursor — an idle warm reconnect. The
//!    rendered stream would have no frame numbers to travel on.
//! 2. **A WARM client under the threshold.** Byte-exact continuation is worth more than a wipe and
//!    re-render when the gap is small, and this is EVERY ordinary reconnect — which is why the
//!    cheap `retained_bytes` check runs before the history copy rather than after it.
//! 3. **The render does not fit the seq budget.** `rechunk` caps per-frame payloads, so rendered
//!    bytes above `seqs × cap` would make the last chunk exceed the cap and stall the credit
//!    window. Pathological tiny-session expansion, and the raw path is cheap there anyway.
//!
//! ## `adopting` is the difference between a reattach and a join
//!
//! Adopting the rendered stream AS the retained history — "as if the host had emitted it all
//! along" — is what stops the NEXT compose from re-walking the raw ring. It is safe only in the
//! caller sequence [detached → drain stopped → replay → rebind], because it rewrites the seqs a
//! live drain would be mid-stream on. A join to a LIVE session therefore composes read-only.

use std::sync::Arc;

use slopdesk_hostpane::PtyProcess;
use slopdesk_wire::message::WireMessage;
use slopdesk_wire::mux::flow::MuxFlowControl;
use slopdesk_wire::replay::ReplayBuffer;

use crate::shared::Shared;

/// The rows and columns a snapshot is rendered at when the PTY will not say.
///
/// The `openpty` default, and the same pair the Swift fell back to. A pane whose master has already
/// been closed still has history worth transferring, and rendering it at a plausible terminal size
/// beats declining to render it at all.
const FALLBACK_ROWS: u16 = 24;
/// See [`FALLBACK_ROWS`].
const FALLBACK_COLS: u16 = 80;

/// How a session turns raw output history into the screen a client should open on.
///
/// A trait rather than a boxed closure for the reason [`crate::SessionLog`] is one: the strict lint
/// set denies a struct with no `Debug`, and this is a field.
pub trait SnapshotPolicy: Send + Sync + core::fmt::Debug {
    /// A WARM reconnect whose pending replay meets this many bytes is snapshotted; below it the
    /// tail replays raw and byte-exact. A COLD client always snapshots.
    fn warm_threshold_bytes(&self) -> usize;

    /// Renders `history` — the complete retained bytes, oldest first — as the screen it produces at
    /// `rows` × `cols`.
    fn compose(&self, history: &[u8], rows: u16, cols: u16) -> Vec<u8>;
}

/// The reattach replay: the rendered snapshot when one can be composed, the raw tail otherwise.
///
/// Returns the messages and whether they were a RENDERED snapshot — a caller that state-transferred
/// needs no redraw-jiggle workaround, because every row the app believes is painted IS painted.
pub(crate) fn replay_tail(
    shared: &Arc<Shared>,
    pty: &Arc<PtyProcess>,
    policy: Option<&Arc<dyn SnapshotPolicy>>,
    after: i64,
) -> (Vec<WireMessage>, bool) {
    if let Some(policy) = policy
        && let Some(rendered) = compose(shared, pty, policy.as_ref(), after, true)
    {
        return (rendered, true);
    }
    (shared.raw_replay(after), false)
}

/// The rendered screen a JOINER opens on, and the highest seq it actually covers.
///
/// Read-only: the same state transfer a cold reattach receives, composed without consuming the
/// out-FIFO or replacing the retained history, because the incumbent's drain is live.
///
/// The coverage point is DERIVED from what was produced rather than read off the buffer afterwards.
/// A frame appended between the snapshot source being taken and that read would otherwise be either
/// skipped — a hole in the joiner's transcript — or shipped twice, depending on which side of the
/// race won.
pub(crate) fn compose_join(
    shared: &Arc<Shared>,
    pty: &Arc<PtyProcess>,
    policy: Option<&Arc<dyn SnapshotPolicy>>,
) -> (Vec<WireMessage>, i64) {
    let messages = policy
        .and_then(|policy| compose(shared, pty, policy.as_ref(), 0, false))
        .unwrap_or_else(|| shared.raw_replay(0));
    let covered = messages
        .iter()
        .filter_map(|message| {
            match *message {
                WireMessage::Output { seq, .. } => Some(seq),
                _ => None,
            }
        })
        .max()
        .unwrap_or(0);
    (messages, covered)
}

/// Builds the rendered-snapshot replay, or answers `None` for any of the three declines above.
fn compose(
    shared: &Arc<Shared>,
    pty: &Arc<PtyProcess>,
    policy: &dyn SnapshotPolicy,
    after: i64,
    adopting: bool,
) -> Option<Vec<WireMessage>> {
    // Cheap eligibility FIRST — the warm-below-threshold case is every ordinary reconnect, and must
    // not pay the history copy just to say no.
    let cold = after == 0;
    if !cold && shared.retained_bytes() < policy.warm_threshold_bytes() {
        return None;
    }
    let source = shared.snapshot_source(after);
    if source.replay_seqs.is_empty() || source.history.is_empty() {
        return None;
    }
    if !cold && source.replay_bytes < policy.warm_threshold_bytes() {
        return None;
    }
    let grid = pty.window_size();
    let rows = grid.map_or(FALLBACK_ROWS, |grid| grid.rows);
    let columns = grid.map_or(FALLBACK_COLS, |grid| grid.cols);
    let rendered = policy.compose(&source.history, rows, columns);
    // Credit-progress invariant: the re-chunker caps per-frame payloads, so the rendered bytes must
    // fit the seq budget or the LAST chunk would exceed the cap and park the window for good.
    if rendered.len() > source.replay_seqs.len().saturating_mul(frame_cap()) {
        return None;
    }
    let messages = ReplayBuffer::rechunk_snapshot(&rendered, &source.replay_seqs);
    if adopting {
        // Adopt the rendered stream as the retained history so the next compose parses the small
        // canonical screen instead of re-walking the raw ring.
        shared.adopt_snapshot_replay(&messages);
    }
    Some(messages)
}

/// The per-frame payload ceiling, read per compose for the reason [`crate::shared`] reads the merge
/// cap per pop: it is `slopdesk-wire`'s number, and `SLOPDESK_MUX_MERGE_CAP` stays live.
fn frame_cap() -> usize {
    usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(usize::MAX)
}
