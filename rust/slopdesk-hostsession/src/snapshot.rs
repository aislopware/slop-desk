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

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, PoisonError};

    use slopdesk_hostpane::PtyProcess;
    use slopdesk_superclient::client::{ListenerKind, SupervisorClient, SupervisorObserver};
    use slopdesk_superclient::connection::Connection;
    use slopdesk_superwire::protocol::ExitedNotice;
    use slopdesk_wire::message::WireMessage;
    use slopdesk_wire::replay::ReplayBuffer;

    use super::{
        FALLBACK_COLS, FALLBACK_ROWS, SnapshotPolicy, compose, compose_join, frame_cap, replay_tail,
    };
    use crate::evict::Eviction;
    use crate::session::{IgnoreStatus, SilentObserver};
    use crate::shared::{DiscardLog, Shared};

    /// A renderer that answers one fixed screen and remembers what it was asked, so a test can tell
    /// "declined" from "composed something that happened to look like a decline".
    #[derive(Debug)]
    struct StubScreen {
        threshold: usize,
        screen: Vec<u8>,
        calls: AtomicUsize,
        grid: Mutex<Option<(u16, u16)>>,
    }

    impl StubScreen {
        fn new(threshold: usize, screen: Vec<u8>) -> Arc<Self> {
            Arc::new(Self {
                threshold,
                screen,
                calls: AtomicUsize::new(0),
                grid: Mutex::new(None),
            })
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::Acquire)
        }

        fn grid(&self) -> Option<(u16, u16)> {
            *self.grid.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }

    impl SnapshotPolicy for StubScreen {
        fn warm_threshold_bytes(&self) -> usize {
            self.threshold
        }

        fn compose(&self, _history: &[u8], rows: u16, cols: u16) -> Vec<u8> {
            self.calls.fetch_add(1, Ordering::AcqRel);
            *self.grid.lock().unwrap_or_else(PoisonError::into_inner) = Some((rows, cols));
            self.screen.clone()
        }
    }

    /// Nothing this suite drives ever reaches superd, so every notice is dropped on the floor.
    #[derive(Debug)]
    struct DeafSuperd;

    impl SupervisorObserver for DeafSuperd {
        fn exited(&self, _notice: &ExitedNotice) {}
        fn connection(&self, _kind: ListenerKind, descriptor: OwnedFd) {
            drop(descriptor);
        }
        fn disconnected(&self) {}
        fn log(&self, _line: &str) {}
    }

    /// An UNSPAWNED pane: no master, so `window_size` answers `None` and the fallback grid applies.
    ///
    /// The client is real — `Connection::adopt` over a socket pair is this crate's own seam — and
    /// its peer is closed straight away so the reader and writer threads EOF out rather than park.
    fn pane() -> Arc<PtyProcess> {
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        drop(theirs);
        let (client, threads) = SupervisorClient::serve(
            Arc::new(Connection::adopt(OwnedFd::from(ours))),
            Arc::new(DeafSuperd),
        );
        drop(threads);
        Arc::new(PtyProcess::new(client))
    }

    /// A ring holding one chunk per entry in `sizes`, acked up to and including seq `acked`.
    ///
    /// The ack is what splits the history: acked chunks move into the scrollback ring, where they
    /// still count toward a snapshot's `replay_bytes` but no longer toward `retained_bytes`.
    fn ring(sizes: &[usize], acked: i64) -> ReplayBuffer {
        let mut buffer = ReplayBuffer::new();
        for &size in sizes {
            buffer.append(vec![b'x'; size]);
        }
        buffer.ack(acked);
        buffer
    }

    /// A pane's shared state over `replay`, with no client and nothing else running.
    fn shared(replay: ReplayBuffer) -> Arc<Shared> {
        Arc::new(Shared::new(
            replay,
            1 << 20,
            8.0,
            Arc::new(DiscardLog),
            Arc::new(SilentObserver),
            Arc::new(IgnoreStatus),
            Eviction::off(),
        ))
    }

    /// The `(seq, bytes)` pairs a replay carried, so an assertion names the wire, not the enum.
    fn outputs(messages: &[WireMessage]) -> Vec<(i64, Vec<u8>)> {
        messages
            .iter()
            .filter_map(|message| {
                match *message {
                    WireMessage::Output { seq, ref bytes } => Some((seq, bytes.clone())),
                    _ => None,
                }
            })
            .collect()
    }

    // MARK: The four declines

    /// The cheap check is the AUTHORITATIVE one for a warm client: an un-acked tail under the
    /// threshold declines even when the history above the client's cursor is far over it.
    ///
    /// The ring holds 550 acked bytes above seq 1 and the tail holds 50, so a decline that ran the
    /// `replay_bytes` test first would compose here. It must not: the point of ordering the
    /// `retained_bytes` test first is that the ordinary reconnect never pays for the history copy.
    #[test]
    fn a_warm_client_under_the_threshold_declines_before_the_history_is_copied() {
        let shared = shared(ring(&[100, 500, 50], 2));
        let pty = pane();
        let policy = StubScreen::new(300, b"SCREEN".to_vec());

        assert_eq!(shared.retained_bytes(), 50, "only the un-acked tail is retained");
        assert_eq!(
            shared.snapshot_source(1).replay_bytes,
            550,
            "while the replay window above the cursor is well over the threshold",
        );
        assert!(
            compose(&shared, &pty, policy.as_ref(), 1, false).is_none(),
            "and the cheap check is the one that answers",
        );
        assert_eq!(policy.calls(), 0, "so the renderer was never asked");
    }

    /// Nothing above the cursor is nothing to ride: a history with no un-acked seqs declines.
    ///
    /// The threshold is zero so neither warm check can be what answers — this isolates the empty
    /// seq budget, which is the idle warm reconnect.
    #[test]
    fn a_history_with_no_seqs_above_the_cursor_declines() {
        let shared = shared(ring(&[64], 1));
        let pty = pane();
        let policy = StubScreen::new(0, b"SCREEN".to_vec());

        assert!(
            !shared.snapshot_source(1).history.is_empty(),
            "the acked chunk is still history",
        );
        assert!(
            compose(&shared, &pty, policy.as_ref(), 1, false).is_none(),
            "but there is no seq above the cursor for a rendered stream to travel on",
        );
        assert_eq!(policy.calls(), 0, "and the renderer was never asked");
    }

    /// A seq with no bytes behind it is not a screen: an empty history declines.
    #[test]
    fn a_history_of_no_bytes_declines_even_with_a_seq_to_ride() {
        let shared = shared(ring(&[0], 0));
        let pty = pane();
        let policy = StubScreen::new(0, b"SCREEN".to_vec());

        assert_eq!(
            shared.snapshot_source(0).replay_seqs,
            [1],
            "the empty chunk still took a seq",
        );
        assert!(
            compose(&shared, &pty, policy.as_ref(), 0, false).is_none(),
            "and there is nothing to render onto it",
        );
        assert_eq!(policy.calls(), 0, "and the renderer was never asked");
    }

    /// The second warm test prices the REPLAY window rather than the retained tail, and the two
    /// differ: 400 bytes are retained but only the 200 above the cursor would be replaced, so a
    /// warm client two hundred bytes behind still gets its byte-exact continuation.
    #[test]
    fn a_warm_client_whose_replay_window_is_under_the_threshold_declines() {
        let shared = shared(ring(&[200, 200], 0));
        let pty = pane();
        let policy = StubScreen::new(300, b"SCREEN".to_vec());

        assert_eq!(shared.retained_bytes(), 400, "the cheap check passes");
        assert!(
            compose(&shared, &pty, policy.as_ref(), 1, false).is_none(),
            "but only 200 bytes sit above the cursor",
        );
        assert_eq!(policy.calls(), 0, "and the renderer was never asked");
    }

    /// A render the seq budget cannot carry declines, and one that exactly fills it composes.
    ///
    /// The boundary is the whole law: one byte over `seqs × cap` would make the last chunk exceed
    /// the per-frame cap and park the credit window for good, while a render sitting exactly ON the
    /// budget still fits.
    #[test]
    fn a_render_over_the_seq_budget_declines_and_one_at_the_budget_composes() {
        let pty = pane();

        let over = StubScreen::new(0, vec![b'r'; frame_cap() + 1]);
        assert!(
            compose(&shared(ring(&[10], 0)), &pty, over.as_ref(), 0, false).is_none(),
            "one seq cannot carry one byte more than one frame",
        );
        assert_eq!(
            over.calls(),
            1,
            "and the decline is made ON the render, not before it"
        );

        let exact = StubScreen::new(0, vec![b'r'; frame_cap()]);
        let composed = compose(&shared(ring(&[10], 0)), &pty, exact.as_ref(), 0, false)
            .expect("a render that fills the budget exactly still fits it");
        assert_eq!(
            outputs(&composed),
            [(1, vec![b'r'; frame_cap()])],
            "and it rides the one seq whole",
        );
    }

    // MARK: Cold, and the grid

    /// A COLD client is never held to either warm threshold — it has no live grid to keep
    /// byte-exact, so there is nothing for a continuation to be worth more than.
    #[test]
    fn a_cold_client_composes_under_any_threshold() {
        let shared = shared(ring(&[10], 0));
        let pty = pane();
        let policy = StubScreen::new(usize::MAX, b"SCREEN".to_vec());

        let composed = compose(&shared, &pty, policy.as_ref(), 0, false)
            .expect("a cold client snapshots however little is retained");
        assert_eq!(outputs(&composed), [(1, b"SCREEN".to_vec())]);
        assert_eq!(policy.calls(), 1);
    }

    /// A pane whose master will not answer is rendered at 24×80 rather than not rendered at all.
    #[test]
    fn a_pane_with_no_master_renders_at_the_fallback_grid() {
        let shared = shared(ring(&[10], 0));
        let pty = pane();
        let policy = StubScreen::new(0, b"SCREEN".to_vec());

        assert!(
            pty.window_size().is_none(),
            "an unspawned pane has no size to give"
        );
        drop(compose(&shared, &pty, policy.as_ref(), 0, false));
        assert_eq!(policy.grid(), Some((FALLBACK_ROWS, FALLBACK_COLS)));
        assert_eq!(policy.grid(), Some((24, 80)), "which is the openpty default");
    }

    // MARK: Adoption, and the two callers

    /// A REATTACH adopts the rendered screen as the retained history — as if the host had emitted
    /// it all along — so the next compose parses one screen instead of re-walking the raw ring.
    #[test]
    fn a_reattach_adopts_the_rendered_screen_as_the_history() {
        let shared = shared(ring(&[10], 0));
        let pty = pane();
        let policy: Arc<dyn SnapshotPolicy> = StubScreen::new(0, b"SCREEN".to_vec());

        let (messages, rendered) = replay_tail(&shared, &pty, Some(&policy), 0);
        assert!(rendered, "the caller is told it state-transferred");
        assert_eq!(outputs(&messages), [(1, b"SCREEN".to_vec())]);
        assert_eq!(
            shared.snapshot_source(0).history,
            b"SCREEN",
            "and the raw history is gone, replaced by exactly what was sent",
        );
    }

    /// A JOIN to a live session composes READ-ONLY: the incumbent's drain is mid-stream on those
    /// seqs, so rewriting the history under it is exactly what must not happen.
    #[test]
    fn a_join_composes_without_adopting() {
        let shared = shared(ring(&[10], 0));
        let pty = pane();
        let stub = StubScreen::new(0, b"SCREEN".to_vec());
        let policy: Arc<dyn SnapshotPolicy> = Arc::<StubScreen>::clone(&stub);

        let (messages, _covered) = compose_join(&shared, &pty, Some(&policy));
        assert_eq!(stub.calls(), 1, "the joiner really did get a rendered screen");
        assert_eq!(outputs(&messages), [(1, b"SCREEN".to_vec())]);
        assert_eq!(
            shared.snapshot_source(0).history,
            vec![b'x'; 10],
            "and the retained history is untouched",
        );
    }

    /// The coverage point is read off what was PRODUCED: the highest seq the rendered stream rode.
    ///
    /// Four seqs are available and the screen fills exactly two frames, so the re-chunker emits two
    /// messages and lifts the second onto the TOP seq. The coverage point is therefore none of the
    /// three things it could be mistaken for — not the message count (2), not the first seq emitted
    /// (1), not the count of seqs consumed — and each of those would leave the joiner's transcript
    /// short, which is a hole in what it believes it has seen.
    #[test]
    fn a_join_covers_the_highest_seq_it_produced() {
        let shared = shared(ring(&[10, 10, 10, 10], 0));
        let pty = pane();
        let policy: Arc<dyn SnapshotPolicy> = StubScreen::new(0, vec![b's'; frame_cap().saturating_mul(2)]);

        let (messages, covered) = compose_join(&shared, &pty, Some(&policy));
        let seqs: Vec<i64> = outputs(&messages).into_iter().map(|(seq, _bytes)| seq).collect();
        assert_eq!(seqs, [1, 4], "two frames, the second lifted onto the top seq");
        assert_eq!(covered, 4);
    }

    /// A join that produced no output covers nothing, and says 0 rather than inventing a frontier.
    #[test]
    fn a_join_that_produced_nothing_covers_seq_zero() {
        let (messages, covered) = compose_join(&shared(ring(&[], 0)), &pane(), None);
        assert!(messages.is_empty(), "an empty ring replays nothing");
        assert_eq!(covered, 0);
    }

    /// Every decline falls back to the RAW tail, byte-exact and on its own seqs.
    #[test]
    fn a_declined_snapshot_replays_the_raw_tail_instead() {
        let shared = shared(ring(&[200, 200], 0));
        let pty = pane();
        let stub = StubScreen::new(300, b"SCREEN".to_vec());
        let policy: Arc<dyn SnapshotPolicy> = Arc::<StubScreen>::clone(&stub);

        let (messages, rendered) = replay_tail(&shared, &pty, Some(&policy), 1);
        assert!(!rendered, "the caller is told it did NOT state-transfer");
        assert_eq!(stub.calls(), 0);
        assert_eq!(
            outputs(&messages),
            [(2, vec![b'x'; 200])],
            "the un-acked tail above the cursor, unchanged",
        );
    }

    /// With no policy injected there is nothing to compose, and the session replays raw.
    #[test]
    fn a_session_with_no_policy_replays_raw() {
        let shared = shared(ring(&[10], 0));
        let (messages, rendered) = replay_tail(&shared, &pane(), None, 0);
        assert!(!rendered);
        assert_eq!(outputs(&messages), [(1, vec![b'x'; 10])]);
    }
}
