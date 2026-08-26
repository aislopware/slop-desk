//! Who else is watching this pane — the three registries the agent-control verbs hang off.
//!
//! A client watches a pane by subscribing to it; an ORCHESTRATOR watches it by asking
//! `slopdesk-ctl` to, and that is what these are for. `wait --until` needs every output byte as it
//! lands, `subscribe` needs one notice when the pane closes, and `run --wait` needs the block
//! metadata for the command it started. None of them is a wire message, so none of them belongs in
//! the fanout; all three are callbacks the control surface installs and removes.
//!
//! ## The ordering that is a contract
//!
//! **Every output tap sees the whole stream before any close tap fires**, and the child is gone by
//! then. An orchestrator that read `{"event":"closed"}` and then received two more output lines
//! would have to buffer against a promise the host had already broken. Two paths reach the end and
//! each satisfies the sentence differently, which is why the sequencing lives in
//! [`crate::session`] rather than here.
//!
//! On the path where the CHILD ends first, the exit thread waits out the EOF latch — the same gate
//! the `.exit` message rides behind — and fires from that thread immediately ahead of it. On the
//! path where the HOST ends the pane, the teardown has already unsubscribed the stream at the top
//! of its ladder, so every byte hostd will ever see has landed before anything else runs; the close
//! then fires at the END of that ladder, after the latch is released and after the child is reaped,
//! because an announcement before the signal would report an agent gone while its shell still ran.
//! A `relinquish` reaches neither: the pane is handed back to superd alive, and saying nothing is
//! the truthful answer. This module only guarantees that a close fires exactly ONCE.
//!
//! ## A late registration is answered, not dropped
//!
//! Swift latched nothing: a close tap installed after the pane had already closed simply never
//! fired, and the `subscribe` verb's caller waited out its own timeout for an event that could no
//! longer happen. The latch here closes that window — [`Taps::add_close`] on an already-closed pane
//! fires the tap at once and stores nothing. The registry is the only place that can know, because
//! the check and the insertion have to be one operation; a caller doing `is_closed()` then
//! `add_close()` has the race back.
//!
//! ## Nothing allocates on the read loop
//!
//! [`Taps::notify_output`] runs on superd's reader thread for every chunk. The common case is an
//! EMPTY registry, which costs one uncontended lock and a pointer test. When taps ARE installed,
//! what is taken under the lock is a clone of an [`Arc`] over the whole list — one refcount bump,
//! never a `Vec` copy — so the calls happen outside the lock with no per-chunk allocation and no
//! chance of a tap re-entering the registry it is being called from.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_wire::message::WireMessage;

/// What a registration hands back, and the only thing that can retire it.
///
/// Opaque and minted here rather than supplied by the caller, so two independent control
/// connections cannot collide on a key and silently unregister each other — the bug a caller-chosen
/// `UUID` leaves available.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TapToken(u64);

/// A watcher of this pane's raw output, called on the READ LOOP.
///
/// Called with the payload BORROWED out of the frame that carried it: a tap that needs to keep the
/// bytes copies them, and one that only scans for a pattern copies nothing. It must not block and
/// must not call back into the session — the read loop is what backpressures the shell, so time
/// spent here is time the pane is not draining.
pub trait OutputTap: Send + Sync + core::fmt::Debug {
    /// One chunk, exactly as the sniffer saw it.
    fn chunk(&self, payload: &[u8]);
}

/// A watcher of this pane's END, called once from the exit thread.
pub trait CloseTap: Send + Sync + core::fmt::Debug {
    /// The pane's output stream is complete and the child is gone.
    fn closed(&self);
}

/// A watcher of this pane's command blocks, called on the read loop after the fold.
pub trait BlockTap: Send + Sync + core::fmt::Debug {
    /// One block's metadata, as the fold just published it.
    fn updated(&self, update: &BlockUpdate);
}

/// One command block, in the terms `run --wait` asks about it.
///
/// A projection of [`WireMessage::CommandBlock`] rather than the message itself, and deliberately
/// so: a tap wants the four fields that say whether the command it started has finished, and
/// handing it the wire envelope would let a caller depend on `output_len` or `prompt_ordinal`,
/// which describe the RING rather than the command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockUpdate {
    /// The block's index in this pane's segmenter lifetime — the key every block verb takes.
    pub index: u32,
    /// The typed command line, capped by the segmenter.
    pub command_text: String,
    /// The command's `$?`, or `None` while it is still running.
    pub exit_code: Option<i32>,
    /// Host-measured start-to-end milliseconds, or `None` while it is still running.
    pub duration_ms: Option<u32>,
    /// Whether the matching OSC 133 `D` has arrived.
    pub complete: bool,
}

impl BlockUpdate {
    /// The update `message` describes, or `None` for a message that is not a block.
    fn of(message: &WireMessage) -> Option<Self> {
        match *message {
            WireMessage::CommandBlock {
                index,
                exit_code,
                duration_ms,
                complete,
                ref command_text,
                ..
            } => {
                Some(Self {
                    index,
                    command_text: command_text.clone(),
                    exit_code,
                    duration_ms,
                    complete,
                })
            },
            _ => None,
        }
    }
}

/// One registry's list, shared: the value a notification clones and reads outside the lock.
type Entries<T> = Arc<Vec<(TapToken, Arc<T>)>>;

/// A copy-on-write list of taps: cheap to read on the hot path, rare to write.
///
/// The `Arc` is the point. Cloning it under the lock is a refcount bump, so the read loop never
/// allocates and never holds the lock across a call into code it does not own.
#[derive(Debug)]
struct Registry<T: ?Sized> {
    entries: Mutex<Entries<T>>,
}

impl<T: ?Sized> Default for Registry<T> {
    fn default() -> Self {
        Self {
            entries: Mutex::new(Arc::new(Vec::new())),
        }
    }
}

impl<T: ?Sized> Registry<T> {
    /// Adds `tap` under `token`, replacing any entry already there.
    fn add(&self, token: TapToken, tap: Arc<T>) {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let mut next = Vec::with_capacity(entries.len() + 1);
        next.extend(entries.iter().filter(|(key, _)| *key != token).cloned());
        next.push((token, tap));
        *entries = Arc::new(next);
    }

    /// Retires `token`. A token that is not here is a no-op, so a double-remove is safe.
    fn remove(&self, token: TapToken) {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if !entries.iter().any(|(key, _)| *key == token) {
            return;
        }
        *entries = Arc::new(
            entries
                .iter()
                .filter(|(key, _)| *key != token)
                .cloned()
                .collect::<Vec<_>>(),
        );
    }

    /// The current list, as one refcount bump.
    fn snapshot(&self) -> Entries<T> {
        Arc::clone(&self.entries.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// The close registry and its latch, under ONE lock.
///
/// One lock rather than a registry beside a flag, because "add unless already closed" and "close
/// and take everyone" must not interleave: with two, an add that lost the race would be stored into
/// a list nobody will read again, and an add that won it could be called twice.
#[derive(Debug, Default)]
struct Closers {
    taps: Vec<(TapToken, Arc<dyn CloseTap>)>,
    closed: bool,
}

/// One pane's three registries.
#[derive(Debug, Default)]
pub(crate) struct Taps {
    /// Mints tokens. Monotonic for the session's life — a retired token is never reissued, so a
    /// stale `remove` cannot retire somebody else's tap.
    next: AtomicU64,
    output: Registry<dyn OutputTap>,
    block: Registry<dyn BlockTap>,
    close: Mutex<Closers>,
}

impl Taps {
    /// The next token, which is not any token this session has issued before.
    fn mint(&self) -> TapToken {
        TapToken(self.next.fetch_add(1, Ordering::Relaxed))
    }

    /// Registers an output watcher and answers the token that retires it.
    pub(crate) fn add_output(&self, tap: Arc<dyn OutputTap>) -> TapToken {
        let token = self.mint();
        self.output.add(token, tap);
        token
    }

    /// Retires an output watcher. Idempotent.
    pub(crate) fn remove_output(&self, token: TapToken) {
        self.output.remove(token);
    }

    /// Registers a block watcher and answers the token that retires it.
    pub(crate) fn add_block(&self, tap: Arc<dyn BlockTap>) -> TapToken {
        let token = self.mint();
        self.block.add(token, tap);
        token
    }

    /// Retires a block watcher. Idempotent.
    pub(crate) fn remove_block(&self, token: TapToken) {
        self.block.remove(token);
    }

    /// Registers a close watcher, or fires it AT ONCE if the pane has already closed.
    ///
    /// See the module note: the check and the insertion are one acquisition because a caller cannot
    /// do them separately without the race back.
    pub(crate) fn add_close(&self, tap: Arc<dyn CloseTap>) -> TapToken {
        let token = self.mint();
        let late = {
            let mut close = self.close.lock().unwrap_or_else(PoisonError::into_inner);
            if close.closed {
                Some(tap)
            } else {
                close.taps.retain(|(key, _)| *key != token);
                close.taps.push((token, tap));
                None
            }
        };
        // OUTSIDE the lock, like every other notification here: a tap is somebody else's code.
        if let Some(tap) = late {
            tap.closed();
        }
        token
    }

    /// Retires a close watcher. Idempotent.
    pub(crate) fn remove_close(&self, token: TapToken) {
        let mut close = self.close.lock().unwrap_or_else(PoisonError::into_inner);
        close.taps.retain(|(key, _)| *key != token);
    }

    /// Hands one chunk to every output watcher. The read loop's call.
    pub(crate) fn notify_output(&self, payload: &[u8]) {
        let taps = self.output.snapshot();
        for (_, tap) in taps.iter() {
            tap.chunk(payload);
        }
    }

    /// Hands every block message in `messages` to every block watcher.
    ///
    /// Called AFTER the fold that produced them, so a completed block's output is already retained
    /// by the time its watcher hears the block is complete and asks for it.
    pub(crate) fn notify_blocks(&self, messages: &[WireMessage]) {
        let taps = self.block.snapshot();
        if taps.is_empty() {
            return;
        }
        for message in messages {
            let Some(update) = BlockUpdate::of(message) else {
                continue;
            };
            for (_, tap) in taps.iter() {
                tap.updated(&update);
            }
        }
    }

    /// Fires every close watcher, exactly once for the session's life.
    ///
    /// Takes the list rather than copying it: after this there is nothing left to notify, and a tap
    /// that outlived its own `remove_close` must not be reachable from here again.
    pub(crate) fn notify_closed(&self) {
        let taps = {
            let mut close = self.close.lock().unwrap_or_else(PoisonError::into_inner);
            if close.closed {
                return;
            }
            close.closed = true;
            core::mem::take(&mut close.taps)
        };
        for (_, tap) in taps {
            tap.closed();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex, PoisonError};

    use slopdesk_wire::message::WireMessage;

    use super::{BlockTap, BlockUpdate, CloseTap, OutputTap, Taps};

    #[derive(Debug, Default)]
    struct Recorder {
        chunks: Mutex<Vec<Vec<u8>>>,
        blocks: Mutex<Vec<BlockUpdate>>,
        closes: AtomicUsize,
    }

    impl OutputTap for Recorder {
        fn chunk(&self, payload: &[u8]) {
            self.chunks
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(payload.to_vec());
        }
    }

    impl BlockTap for Recorder {
        fn updated(&self, update: &BlockUpdate) {
            self.blocks
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(update.clone());
        }
    }

    impl CloseTap for Recorder {
        fn closed(&self) {
            self.closes.fetch_add(1, Ordering::SeqCst);
        }
    }

    /// The recorder as one of its three faces. A named coercion rather than an `as` at each call
    /// site, which `trivial_casts` rejects and which reads worse anyway.
    fn watching(recorder: &Arc<Recorder>) -> (Arc<dyn OutputTap>, Arc<dyn BlockTap>, Arc<dyn CloseTap>) {
        let (one, two, three) = (Arc::clone(recorder), Arc::clone(recorder), Arc::clone(recorder));
        let output: Arc<dyn OutputTap> = one;
        let blocks: Arc<dyn BlockTap> = two;
        let close: Arc<dyn CloseTap> = three;
        (output, blocks, close)
    }

    fn block(index: u32, complete: bool) -> WireMessage {
        WireMessage::CommandBlock {
            index,
            exit_code: complete.then_some(0),
            duration_ms: complete.then_some(12),
            complete,
            output_len: 4,
            command_text: String::from("ls"),
            prompt_ordinal: 1,
        }
    }

    #[test]
    fn a_retired_output_tap_stops_hearing_chunks() {
        let taps = Taps::default();
        let recorder = Arc::new(Recorder::default());
        let (output, ..) = watching(&recorder);
        let token = taps.add_output(output);
        taps.notify_output(b"one");
        taps.remove_output(token);
        taps.notify_output(b"two");
        taps.remove_output(token);

        let chunks = recorder.chunks.lock().unwrap_or_else(PoisonError::into_inner);
        assert_eq!(
            *chunks,
            vec![b"one".to_vec()],
            "the second chunk was after the retirement"
        );
    }

    #[test]
    fn only_block_messages_reach_a_block_tap() {
        let taps = Taps::default();
        let recorder = Arc::new(Recorder::default());
        let (_, blocks, _) = watching(&recorder);
        taps.add_block(blocks);
        taps.notify_blocks(&[
            WireMessage::Title(String::from("not a block")),
            block(0, false),
            block(0, true),
        ]);

        let seen = {
            let blocks = recorder.blocks.lock().unwrap_or_else(PoisonError::into_inner);
            blocks
                .iter()
                .map(|block| (block.complete, block.exit_code))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            seen,
            vec![(false, None), (true, Some(0))],
            "the title carried no block; the running edge and the completion each carried one",
        );
    }

    #[test]
    fn a_close_fires_once_however_often_it_is_declared() {
        let taps = Taps::default();
        let recorder = Arc::new(Recorder::default());
        let (_, _, close) = watching(&recorder);
        taps.add_close(close);
        taps.notify_closed();
        taps.notify_closed();
        assert_eq!(
            recorder.closes.load(Ordering::SeqCst),
            1,
            "an end declared twice is one end"
        );
    }

    #[test]
    fn a_tap_registered_after_the_close_is_told_rather_than_left_waiting() {
        let taps = Taps::default();
        taps.notify_closed();
        let recorder = Arc::new(Recorder::default());
        let (_, _, close) = watching(&recorder);
        taps.add_close(close);
        assert_eq!(
            recorder.closes.load(Ordering::SeqCst),
            1,
            "the latch answers a subscriber that arrived one instant late",
        );
    }

    #[test]
    fn a_retired_close_tap_hears_nothing() {
        let taps = Taps::default();
        let recorder = Arc::new(Recorder::default());
        let (_, _, close) = watching(&recorder);
        let token = taps.add_close(close);
        taps.remove_close(token);
        taps.remove_close(token);
        taps.notify_closed();
        assert_eq!(recorder.closes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn two_taps_of_the_same_kind_both_hear_and_neither_evicts_the_other() {
        let taps = Taps::default();
        let first = Arc::new(Recorder::default());
        let second = Arc::new(Recorder::default());
        for recorder in [&first, &second] {
            let (output, ..) = watching(recorder);
            taps.add_output(output);
        }
        taps.notify_output(b"shared");

        for recorder in [&first, &second] {
            let chunks = recorder.chunks.lock().unwrap_or_else(PoisonError::into_inner);
            assert_eq!(
                *chunks,
                vec![b"shared".to_vec()],
                "a minted token is nobody else's"
            );
        }
    }
}
