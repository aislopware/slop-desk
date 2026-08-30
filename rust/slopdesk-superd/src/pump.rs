//! One thread per pane, draining the PTY master for as long as the pane lives.
//!
//! This is the file that changes what superd is. It used to hold a master fd and never look at it;
//! now it reads every byte a pane produces, from the moment of `spawn` to the moment the child
//! dies, whether or not any hostd is attached.
//!
//! ## What the always-on drain buys
//! A PTY's kernel buffer is a few KB. With nobody reading, a child's `write` blocks once it fills.
//! That is the correct behaviour for a terminal nobody is watching — it is what
//! [`crate::registry`]'s pause gate deliberately leans on — but it is the wrong behaviour for the
//! ten seconds hostd spends being rebuilt, because the pane superd just saved from `SIGHUP` spends
//! them frozen instead. Draining into [`crate::ring::OutputRing`] converts a stall into a buffered
//! catch-up, and the returning hostd resumes from a byte offset rather than from wherever the
//! kernel happened to stop.
//!
//! ## The pause gate moved here, and it means something narrower now
//! `PTYReadLoop` used to pause its own reads when the client's output queue crossed the high-water
//! mark, so the kernel would backpressure the shell rather than let anything be dropped. hostd
//! still decides that — it is the only side that can see its transport queues — but it now says so
//! over the socket, and superd is what stops reading.
//!
//! The narrower part is the rule that goes with it: **pausing is something a subscriber does, so
//! losing the subscriber clears it.** A hostd that died while paused must not leave the pane frozen
//! for the rest of its life, and a pane with no subscriber has no queue to protect. See
//! [`Pump::clear_pause_on_last_unsubscribe`].
//!
//! ## Ordering against `exited`
//! A subscriber must see a pane's last byte before it sees its death notice, or a shell's farewell
//! output arrives after the session that would have shown it is gone. The pump guarantees this by
//! construction: [`Pump::drain_to_end`] runs the reader to EOF and joins the thread, and the reaper
//! calls it before broadcasting (`registry::start_reaper`). Both go out through the same
//! per-connection write lock, so the order the pump establishes is the order that reaches the wire.

use std::os::fd::{AsFd as _, AsRawFd as _, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::unistd::{pipe, read, write};

use crate::blocks::{BlockEvent, BlockMeta, BlockTracker, ControlBlock};
use crate::commandblocks::CommandBlock;
use crate::ring::OutputRing;
use crate::sniffer::{OutputSniffer, SniffEvent};

/// One `read(2)` per iteration.
///
/// 32 KiB, the size `PTYReadLoop` used and for the same reason: it is half the per-channel
/// bounded-queue capacity on hostd's side, so the worst overshoot past a pause is capacity plus one
/// read rather than capacity plus a much larger read. Changing it here without changing
/// `MuxFlowControl.hostQueueCapacityBytes` re-opens a latency problem that was already solved once.
pub const READ_CHUNK_BYTES: usize = 32 * 1024;

/// Where a pane's freshly-read bytes go.
///
/// `(pane_id, offset_of_first_byte, bytes, sniffed, blocks)`. The offset is absolute and is what
/// makes a subscriber able to detect a gap; see [`crate::ring`].
///
/// Both batches ride along with the bytes they were found IN, rather than on channels of their own,
/// and that is the whole reason the readers sit in this thread. A subscriber latches a title at
/// the same moment it forwards the chunk that carried it; separate channels would make that
/// ordering a race nobody could fix downstream. Both are empty for the overwhelming majority of
/// chunks.
pub type OutputSink = Arc<dyn Fn(&str, u64, &[u8], &[SniffEvent], &[BlockEvent]) + Send + Sync>;

/// Wall-clock milliseconds, for the sniffer's command-duration measurement.
///
/// A clock read per chunk, which is a vDSO call — cheaper than the `read(2)` that produced the
/// chunk. Taken here rather than inside the sniffer so the parser itself stays a pure function of
/// its bytes and a time, and so a test can hand it any moment it likes.
#[must_use]
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| {
            i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX)
        })
}

/// The pause/stop state shared between the pump thread and everyone who steers it.
#[derive(Debug, Default)]
struct Gate {
    /// Guarded state, in one mutex so a wait cannot miss a signal.
    flags: Mutex<GateFlags>,
    changed: Condvar,
}

#[derive(Debug, Default, Clone, Copy)]
struct GateFlags {
    paused: bool,
    stopped: bool,
    /// Set by [`Pump::drain_to_end`]: read to EOF and ignore `paused` on the way.
    draining: bool,
}

/// A pane's reader thread.
#[derive(Debug)]
pub struct Pump {
    ring: Arc<Mutex<OutputRing>>,
    gate: Arc<Gate>,
    /// Write end of the self-pipe. One byte here wakes a thread parked in `poll`, which is what
    /// makes stopping a reader independent of killing its child — the same trick, and the same
    /// reason, as the loop this replaces.
    wake: OwnedFd,
    /// True once the reader has seen EOF or an error on the master.
    ended: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
    /// How many connections are currently subscribed. Only
    /// [`Pump::clear_pause_on_last_unsubscribe`] reads it, and only to decide whether a
    /// leftover pause is still anybody's.
    subscribers: Mutex<usize>,
    /// Set by [`Pump::forget_title_coalescing`], cleared by the worker before its next sniff.
    forget_title: Arc<AtomicBool>,
    /// Whether this pane is sniffed. Read by the subscribe path, which replays the backlog through
    /// a FRESH sniffer and must not do that for a pane nobody asked to sniff.
    sniffed: bool,
    /// The command-block tap, when this pane asked for one.
    ///
    /// Behind a mutex rather than owned by the worker outright, which the sniffer is: a block's
    /// retained output is FETCHED, by index, long after the chunk that produced it — from the verb
    /// dispatch thread, not this one. One uncontended lock per chunk beside the ring's, and in
    /// exchange the panel survives the hostd rebuild that used to empty it.
    blocks: Option<Arc<Mutex<BlockTracker>>>,
}

impl Pump {
    /// Starts draining `master` (a duplicate this pump owns and closes) into a fresh ring.
    ///
    /// # Errors
    /// The `pipe(2)` or the thread spawn failing. Both mean the process is out of a resource, and
    /// the caller must treat the pane as unspawnable rather than run it unread — an undrained pane
    /// is the stall this module exists to prevent.
    ///
    /// `sniffer` present means this pane's bytes are also scanned for what the shell says out of
    /// band — title, bell, command status, working directory, notifications. It runs HERE because
    /// this thread already holds every byte before anyone else does: no extra copy, no round trip,
    /// and the events stay in step with the chunk they came from.
    pub fn start(
        pane_id: &str,
        master: OwnedFd,
        capacity: usize,
        sink: OutputSink,
        sniffer: Option<OutputSniffer>,
        blocks: Option<BlockTracker>,
    ) -> Result<Self, Errno> {
        let (wake_read, wake_write) = pipe()?;
        // Both ends close-on-exec: this pump outlives many later spawns, and a shell that inherited
        // the write end would keep the pump's wakeup alive after superd meant to drop it.
        slopdesk_posix::pty::set_cloexec(wake_read.as_raw_fd());
        slopdesk_posix::pty::set_cloexec(wake_write.as_raw_fd());
        let gate = Arc::new(Gate::default());
        let ring = Arc::new(Mutex::new(OutputRing::new(capacity)));
        let ended = Arc::new(AtomicBool::new(false));
        let forget_title = Arc::new(AtomicBool::new(false));
        let scanning = sniffer.is_some();
        let blocks = blocks.map(|tracker| Arc::new(Mutex::new(tracker)));

        let worker = Worker {
            pane_id: pane_id.to_owned(),
            master,
            wake_read,
            ring: Arc::clone(&ring),
            gate: Arc::clone(&gate),
            ended: Arc::clone(&ended),
            sink,
            sniffer,
            forget_title: Arc::clone(&forget_title),
            blocks: blocks.as_ref().map(Arc::clone),
        };
        let handle = std::thread::Builder::new()
            .name(format!("superd-pump-{pane_id}"))
            .stack_size(256 * 1024)
            .spawn(move || worker.run())
            .map_err(|_ignored| Errno::EAGAIN)?;

        Ok(Self {
            ring,
            gate,
            wake: wake_write,
            ended,
            thread: Mutex::new(Some(handle)),
            subscribers: Mutex::new(0),
            forget_title,
            sniffed: scanning,
            blocks,
        })
    }

    /// Everything the block tap still knows, in ascending index order.
    ///
    /// `None` for a pane with no tap, which is not the same answer as an empty list: one says the
    /// question does not apply, the other that nothing has been typed yet.
    #[must_use]
    pub fn blocks_snapshot(&self) -> Option<Vec<BlockMeta>> {
        self.with_blocks(BlockTracker::snapshot)
    }

    /// A finished block's retained output.
    #[must_use]
    pub fn block_output(&self, index: u32) -> Option<Vec<u8>> {
        self.with_blocks(|tracker| tracker.output(index).map(<[u8]>::to_vec))?
    }

    /// The last `limit` finished blocks, oldest first, each with its output.
    #[must_use]
    pub fn recent_blocks(&self, limit: usize) -> Option<Vec<ControlBlock>> {
        self.with_blocks(|tracker| tracker.recent(limit))
    }

    /// The block still running, if one is.
    #[must_use]
    pub fn open_block(&self) -> Option<CommandBlock> {
        self.with_blocks(BlockTracker::open_block)?
    }

    /// The index the next command typed at this prompt will close under.
    #[must_use]
    pub fn expected_next_block_index(&self) -> Option<u32> {
        self.with_blocks(BlockTracker::expected_next_index)
    }

    /// Reads the tap under its lock, answering `None` for a pane without one.
    ///
    /// A poisoned lock answers `None` too: it means a pump thread panicked mid-ingest, and the
    /// honest reply to "what blocks does this pane have" is then "no answer", not a half-written
    /// one.
    fn with_blocks<T>(&self, read: impl FnOnce(&BlockTracker) -> T) -> Option<T> {
        let tracker = self.blocks.as_ref()?;
        let guard = tracker.lock().ok()?;
        let answer = read(&guard);
        drop(guard);
        Some(answer)
    }

    /// Whether this pane's stream is scanned for what the shell says out of band.
    #[must_use]
    pub const fn is_sniffed(&self) -> bool {
        self.sniffed
    }

    /// Retires the sniffer's title-coalescing anchor before the next chunk is scanned.
    ///
    /// The sniffer drops a title identical to the one it last emitted, and hostd needs that anchor
    /// forgotten when a detected agent EXITS: the next agent's opening title is very often
    /// byte-identical to the one just retired (`✳ Claude Code`), and deduping it away leaves the
    /// pane untitled. A flag rather than a call into the sniffer because the sniffer belongs to the
    /// pump thread — this is the one bit of it any other thread may touch.
    pub fn forget_title_coalescing(&self) {
        self.forget_title.store(true, Ordering::Release);
    }

    /// A handle on the retained output that outlives this pump.
    ///
    /// Exists for one caller: the reaper, which drops the pane — and with it this pump and the
    /// master fd — the moment the child is gone, but must keep what the child *said*. A subscriber
    /// that arrives after a fast `ls` has nowhere else to read it from
    /// ([`crate::registry::Registry::resume`]).
    #[must_use]
    pub fn ring(&self) -> Arc<Mutex<OutputRing>> {
        Arc::clone(&self.ring)
    }

    /// Retained output from `offset` onwards, and where the live stream continues.
    #[must_use]
    pub fn resume_from(&self, offset: u64) -> crate::ring::Resume {
        self.ring.lock().map_or_else(
            |_poisoned| {
                crate::ring::Resume {
                    start: offset,
                    head: offset,
                    bytes: Vec::new(),
                }
            },
            |ring| {
                let resumed = ring.read_from(offset);
                drop(ring);
                resumed
            },
        )
    }

    /// Stops or resumes reading. Paused means zero syscalls on the master, so the kernel buffer
    /// fills and the shell backpressures — nothing is dropped.
    pub fn set_paused(&self, paused: bool) {
        if let Ok(mut flags) = self.gate.flags.lock() {
            flags.paused = paused;
            drop(flags);
            self.gate.changed.notify_all();
        }
        // Both directions need the pipe. A resume has to wake a thread parked on the condvar; a
        // PAUSE has to wake one parked in `poll`, or it would not take effect until the master
        // next had something to say — which, on an idle pane, is never, and on a flooding one is
        // one whole chunk too late.
        self.poke();
    }

    /// Records a new subscriber.
    pub fn subscribed(&self) {
        if let Ok(mut count) = self.subscribers.lock() {
            *count = count.saturating_add(1);
            drop(count);
        }
    }

    /// Records a subscriber leaving, and un-pauses the pane if that was the last one.
    ///
    /// The un-pause is the load-bearing half. A pause is a statement about a subscriber's queue,
    /// and hostd dying mid-flood is precisely when one is outstanding. Leaving it set would freeze
    /// a pane that superd had just successfully carried through a restart — the exact failure this
    /// daemon exists to prevent, arrived at from the other direction.
    pub fn clear_pause_on_last_unsubscribe(&self) {
        let last = self.subscribers.lock().is_ok_and(|mut count| {
            *count = count.saturating_sub(1);
            let last = *count == 0;
            drop(count);
            last
        });
        if last {
            self.set_paused(false);
        }
    }

    /// Reads whatever remains and joins the thread. Idempotent.
    ///
    /// Called before an `exited` broadcast so a pane's final bytes cannot arrive after news of its
    /// death. `draining` overrides `paused` on purpose: the child is already gone, so there is no
    /// writer left to backpressure and a pause could only deadlock the join.
    pub fn drain_to_end(&self) {
        if let Ok(mut flags) = self.gate.flags.lock() {
            flags.draining = true;
            drop(flags);
            self.gate.changed.notify_all();
        }
        self.poke();
        self.join();
    }

    /// Stops the reader without waiting for EOF, and joins. Idempotent.
    pub fn stop(&self) {
        if let Ok(mut flags) = self.gate.flags.lock() {
            flags.stopped = true;
            drop(flags);
            self.gate.changed.notify_all();
        }
        self.poke();
        self.join();
    }

    /// Whether the reader has reached the end of the master.
    #[must_use]
    pub fn has_ended(&self) -> bool {
        self.ended.load(Ordering::Acquire)
    }

    /// The absolute offset just past the newest byte read so far.
    #[must_use]
    pub fn head(&self) -> u64 {
        self.ring.lock().map_or(0, |ring| {
            let head = ring.head();
            drop(ring);
            head
        })
    }

    fn poke(&self) {
        let token = [1_u8];
        // A full pipe already carries the wake; a failure here can only mean the reader is gone.
        let _ignored = write(&self.wake, &token);
    }

    fn join(&self) {
        let handle = self.thread.lock().ok().and_then(|mut slot| {
            let taken = slot.take();
            drop(slot);
            taken
        });
        if let Some(handle) = handle {
            // A panicked pump costs one pane's output, not the daemon. `panic = "unwind"` is set
            // for exactly this.
            let _ignored = handle.join();
        }
    }
}

impl Drop for Pump {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The thread's own state. Separate from [`Pump`] so the borrow checker enforces that only the
/// worker touches the master.
struct Worker {
    pane_id: String,
    /// The pump's own duplicate of the pane's master. Owned here and closed when the thread ends,
    /// so the fd can never be recycled out from under a straggling read — which, with `read`
    /// pointed at another pane's master, would be silent cross-pane corruption rather than a fault.
    master: OwnedFd,
    wake_read: OwnedFd,
    ring: Arc<Mutex<OutputRing>>,
    gate: Arc<Gate>,
    ended: Arc<AtomicBool>,
    sink: OutputSink,
    /// `None` for a pane nobody asked to sniff — a panel backend, say, which has no shell saying
    /// anything out of band.
    sniffer: Option<OutputSniffer>,
    forget_title: Arc<AtomicBool>,
    /// `None` for a pane that did not ask for the command-block tap.
    blocks: Option<Arc<Mutex<BlockTracker>>>,
}

impl Worker {
    fn run(mut self) {
        let mut buffer = vec![0_u8; READ_CHUNK_BYTES];
        loop {
            match self.wait_for_readable() {
                Step::Stop => return,
                Step::Ended => {
                    self.ended.store(true, Ordering::Release);
                    return;
                },
                Step::Again => continue,
                Step::Readable => (),
            }

            let got = match read(&self.master, &mut buffer) {
                Ok(0) => {
                    self.ended.store(true, Ordering::Release);
                    return;
                },
                Ok(got) => got,
                Err(Errno::EINTR | Errno::EAGAIN) => continue,
                // EIO is how a master reports the last slave closing on macOS; anything else is
                // equally terminal for this pane.
                Err(_) => {
                    self.ended.store(true, Ordering::Release);
                    return;
                },
            };
            let chunk = buffer.get(..got).unwrap_or_default();
            self.publish(chunk);
        }
    }

    /// Appends to the ring and hands the bytes on, in that order.
    ///
    /// Ring first so a subscriber that arrives during the sink call cannot see a head offset the
    /// ring cannot serve. The offset reported is the one the chunk STARTS at, computed before the
    /// append, because that is the number a subscriber checks its own position against.
    fn publish(&mut self, chunk: &[u8]) {
        let offset = self.ring.lock().map_or(0, |mut ring| {
            let offset = ring.head();
            ring.append(chunk);
            drop(ring);
            offset
        });
        let forget = self.forget_title.swap(false, Ordering::Acquire);
        // One clock reading for both readers, so a command's duration and a title that arrived in
        // the same chunk cannot disagree about when the chunk happened.
        let now_ms = now_ms();
        let events = self.sniffer.as_mut().map_or_else(Vec::new, |sniffer| {
            // Applied HERE rather than where the flag was set, so the retirement lands on a chunk
            // boundary: a title split across two reads is never half-deduped against a stale
            // anchor.
            if forget {
                sniffer.forget_title_coalescing();
            }
            sniffer.observe(chunk, now_ms)
        });
        let blocks = self.blocks.as_ref().map_or_else(Vec::new, |tracker| {
            tracker.lock().map_or_else(
                |_poisoned| Vec::new(),
                |mut tracker| tracker.ingest(chunk, now_ms),
            )
        });
        (self.sink)(&self.pane_id, offset, chunk, &events, &blocks);
    }

    /// Parks until the master has bytes, or something asks the loop to end.
    fn wait_for_readable(&self) -> Step {
        if let Some(step) = self.wait_out_the_pause() {
            return step;
        }

        let master = self.master.as_fd();
        let waker = self.wake_read.as_fd();
        let mut watched = [
            PollFd::new(master, PollFlags::POLLIN),
            PollFd::new(waker, PollFlags::POLLIN),
        ];
        // No timeout. An idle pane must cost nothing, and the only two things that can matter here
        // are the master having something to say and somebody poking the pipe.
        match poll(&mut watched, PollTimeout::NONE) {
            Ok(_ready) => (),
            Err(Errno::EINTR) => return Step::Again,
            Err(_) => return Step::Ended,
        }

        // Drain the wake byte(s) so a poke does not re-fire forever.
        if watched
            .get(1)
            .and_then(PollFd::revents)
            .is_some_and(|events| events.intersects(PollFlags::POLLIN))
        {
            let mut sink = [0_u8; 64];
            let _ignored = read(&self.wake_read, &mut sink);
        }

        let flags = self.gate.flags.lock().map_or_else(
            |_poisoned| GateFlags::default(),
            |guard| {
                let copied = *guard;
                drop(guard);
                copied
            },
        );
        // A plain stop wins over pending bytes: a pane being torn down owes its tail to nobody. A
        // DRAIN is the opposite — it exists to collect exactly that tail — so it falls through.
        if flags.stopped {
            return Step::Stop;
        }
        // A pause asserted while this thread was parked wins over the bytes that woke it. Going
        // round again parks on the condvar instead, leaving those bytes in the kernel buffer where
        // they belong — unread, undropped, and backpressuring the shell. `PTYReadLoop` could not do
        // this (its pause was only ever tested before the poll), so a pause always cost one more
        // chunk than it asked for.
        if flags.paused && !flags.draining {
            return Step::Again;
        }

        let Some(events) = watched.first().and_then(PollFd::revents) else {
            return Step::Again;
        };
        if events.intersects(PollFlags::POLLIN) {
            return Step::Readable;
        }
        // POLLHUP and friends arrive WITHOUT POLLIN when the slave side hangs up, and a loop that
        // only tested POLLIN would spin on them at full speed forever.
        if events.intersects(PollFlags::POLLHUP | PollFlags::POLLERR | PollFlags::POLLNVAL) {
            return Step::Ended;
        }
        Step::Again
    }

    /// Blocks while paused. Returns `Some` when the wait ended for a reason other than resuming.
    fn wait_out_the_pause(&self) -> Option<Step> {
        let Ok(mut flags) = self.gate.flags.lock() else {
            return Some(Step::Stop);
        };
        while flags.paused && !flags.stopped && !flags.draining {
            let Ok(next) = self.gate.changed.wait(flags) else {
                return Some(Step::Stop);
            };
            flags = next;
        }
        let stopped = flags.stopped;
        drop(flags);
        stopped.then_some(Step::Stop)
    }
}

/// What one turn of the reader's wait decided.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    /// The master has bytes.
    Readable,
    /// Nothing conclusive; go round again.
    Again,
    /// Somebody asked the loop to stop; the tail, if any, is forfeit.
    Stop,
    /// The master is finished.
    Ended,
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::os::fd::OwnedFd;
    use std::sync::mpsc;
    use std::time::Duration;

    use slopdesk_posix::pty::{SpawnPlan, spawn_pty};

    use super::{Arc, BlockEvent, BlockTracker, Mutex, OutputSink, OutputSniffer, Pump, SniffEvent};

    /// The sniffer has to run on THIS thread, with the bytes, or the events lose their place in the
    /// stream. Two assertions in one: they arrive at all, and they arrive with the chunk they were
    /// found in rather than on a channel of their own.
    #[test]
    fn a_sniffed_pane_reports_what_the_shell_said_alongside_the_bytes_that_said_it() {
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, _offset: u64, bytes: &[u8], events: &[SniffEvent], _blocks: &[BlockEvent]| {
                let _ignored = sender.send((bytes.to_vec(), events.to_vec()));
            },
        );
        let (ours, theirs) = nix::unistd::pipe().unwrap();
        let pump = Pump::start(
            "pane",
            ours,
            4096,
            sink,
            Some(OutputSniffer::new(Vec::new())),
            None,
        )
        .unwrap();
        nix::unistd::write(&theirs, b"\x1b]2;hello\x07done").unwrap();

        let (bytes, events) = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(bytes, b"\x1b]2;hello\x07done");
        assert_eq!(events, vec![SniffEvent::Title("hello".to_owned())]);
        assert!(pump.is_sniffed());
        drop(theirs);
    }

    /// The anchor a detected agent's exit retires. Without it the next agent's byte-identical
    /// opening title is deduped away and the pane stays untitled — the exact bug this flag exists
    /// for, so the test is the same title twice with the retirement in between.
    #[test]
    fn retiring_the_title_anchor_lets_the_same_title_through_again() {
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, _offset: u64, _bytes: &[u8], events: &[SniffEvent], _blocks: &[BlockEvent]| {
                let _ignored = sender.send(events.to_vec());
            },
        );
        let (ours, theirs) = nix::unistd::pipe().unwrap();
        let pump = Pump::start(
            "pane",
            ours,
            4096,
            sink,
            Some(OutputSniffer::new(Vec::new())),
            None,
        )
        .unwrap();

        let title = b"\x1b]2;\xe2\x9c\xb3 Claude Code\x07";
        nix::unistd::write(&theirs, title).unwrap();
        assert_eq!(receiver.recv_timeout(Duration::from_secs(5)).unwrap().len(), 1);

        pump.forget_title_coalescing();
        nix::unistd::write(&theirs, title).unwrap();
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(5)).unwrap().len(),
            1,
            "the retired anchor must let the identical title through"
        );
        drop(theirs);
    }

    /// The block tap runs on the same thread and reports through the same sink, so a command's
    /// metadata reaches a subscriber attached to the chunk that closed it. The retained output is
    /// readable from ANOTHER thread afterwards, which is the whole reason it sits behind a lock
    /// rather than inside the worker: a block is fetched by index, long after its bytes went by.
    #[test]
    fn a_tapped_pane_reports_its_command_blocks_and_keeps_their_output() {
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, _offset: u64, _bytes: &[u8], _events: &[SniffEvent], blocks: &[BlockEvent]| {
                let _ignored = sender.send(blocks.to_vec());
            },
        );
        let (ours, theirs) = nix::unistd::pipe().unwrap();
        let pump = Pump::start(
            "pane",
            ours,
            4096,
            sink,
            None,
            Some(BlockTracker::new(Vec::new(), 0, 0, 0)),
        )
        .unwrap();
        nix::unistd::write(
            &theirs,
            b"\x1b]133;A\x07$ \x1b]133;B\x07ls\n\x1b]133;C\x07a.txt\n\x1b]133;D;0\x07",
        )
        .unwrap();

        let mut reported = Vec::new();
        while reported.is_empty() {
            reported = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        assert!(
            reported.iter().any(|event| {
                matches!(*event, BlockEvent::Meta(ref meta) if meta.command_text == "ls" && meta.complete)
            }),
            "the closed block must ride with the chunk that closed it — got {reported:?}"
        );
        assert_eq!(pump.block_output(0), Some(b"a.txt\n".to_vec()));
        assert_eq!(pump.blocks_snapshot().map(|snapshot| snapshot.len()), Some(1));
        drop(theirs);
    }

    /// A pane nobody asked to tap pays nothing — the mirror of the unsniffed case, and the reason a
    /// panel backend's stdout never meets an OSC 133 state machine.
    #[test]
    fn an_untapped_pane_reports_no_blocks_and_answers_no_reads() {
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, _offset: u64, _bytes: &[u8], _events: &[SniffEvent], blocks: &[BlockEvent]| {
                let _ignored = sender.send(blocks.to_vec());
            },
        );
        let (ours, theirs) = nix::unistd::pipe().unwrap();
        let pump = Pump::start("pane", ours, 4096, sink, None, None).unwrap();
        nix::unistd::write(
            &theirs,
            b"\x1b]133;A\x07$ \x1b]133;B\x07ls\n\x1b]133;C\x07x\x1b]133;D;0\x07",
        )
        .unwrap();

        assert!(receiver.recv_timeout(Duration::from_secs(5)).unwrap().is_empty());
        assert!(
            pump.blocks_snapshot().is_none(),
            "no tap is a different answer from an empty one"
        );
        assert!(pump.block_output(0).is_none());
        assert!(pump.expected_next_block_index().is_none());
        drop(theirs);
    }

    /// A pane nobody asked to sniff pays nothing and reports nothing — a panel backend's stdout is
    /// not an OSC stream, and scanning it would be pure cost.
    #[test]
    fn an_unsniffed_pane_reports_no_events_at_all() {
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, _offset: u64, _bytes: &[u8], events: &[SniffEvent], _blocks: &[BlockEvent]| {
                let _ignored = sender.send(events.to_vec());
            },
        );
        let (ours, theirs) = nix::unistd::pipe().unwrap();
        let pump = Pump::start("pane", ours, 4096, sink, None, None).unwrap();
        nix::unistd::write(&theirs, b"\x1b]2;hello\x07").unwrap();

        assert!(receiver.recv_timeout(Duration::from_secs(5)).unwrap().is_empty());
        assert!(!pump.is_sniffed());
        drop(theirs);
    }

    /// Spawns a real shell under a PTY and hands the pump a duplicate of its master, exactly as
    /// the registry does.
    fn pumped(script: &str, capacity: usize) -> (Pump, i32, mpsc::Receiver<(u64, Vec<u8>)>, OwnedFd) {
        let arguments = vec!["-c".to_owned(), script.to_owned()];
        let environment = vec!["PATH=/usr/bin:/bin".to_owned()];
        let plan = SpawnPlan {
            executable: "/bin/sh",
            argv0: None,
            arguments: &arguments,
            environment: &environment,
            cwd: Some("/tmp"),
            rows: 24,
            cols: 80,
        };
        let spawned = spawn_pty(&plan).unwrap();
        let (sender, receiver) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |_pane: &str, offset: u64, bytes: &[u8], _events: &[SniffEvent], _blocks: &[BlockEvent]| {
                let _ignored = sender.send((offset, bytes.to_vec()));
            },
        );
        let duplicate = spawned.master.try_clone().unwrap();
        let pump = Pump::start("pane", duplicate, capacity, sink, None, None).unwrap();
        // The original goes back to the caller. It stands in for the registry's own copy: a PTY
        // master is refcounted and the LAST close hangs up the child, so dropping it here would end
        // the pane before the test had read a byte of it.
        (pump, spawned.pid, receiver, spawned.master)
    }

    fn collect(receiver: &mpsc::Receiver<(u64, Vec<u8>)>, until: &str) -> String {
        let mut text = String::new();
        while let Ok((_offset, bytes)) = receiver.recv_timeout(Duration::from_secs(5)) {
            text.push_str(&String::from_utf8_lossy(&bytes));
            if text.contains(until) {
                break;
            }
        }
        text
    }

    /// The point of the whole module: bytes reach the ring with nobody subscribed, so the child
    /// never blocks on a full kernel buffer while hostd is being rebuilt.
    #[test]
    fn output_accumulates_in_the_ring_with_no_subscriber() {
        let (pump, pid, _sink, _master) = pumped("printf 'ready\\n'; sleep 5", 64 * 1024);
        // Wait for the ring to see it rather than for the sink — the sink is incidental here.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while pump.head() == 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let resumed = pump.resume_from(0);
        assert!(
            String::from_utf8_lossy(&resumed.bytes).contains("ready"),
            "{:?}",
            String::from_utf8_lossy(&resumed.bytes)
        );
        assert!(!resumed.is_lossy(0));
        pump.stop();
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }

    /// A subscriber joining late gets the bytes it missed, addressed from where it left off.
    #[test]
    fn a_late_resume_replays_from_the_requested_offset() {
        let (pump, pid, sink, _master) = pumped("printf 'one\\ntwo\\n'; sleep 5", 64 * 1024);
        let seen = collect(&sink, "two");
        assert!(seen.contains("one") && seen.contains("two"), "{seen}");

        let head = pump.head();
        let all = pump.resume_from(0);
        assert_eq!(all.head, head);
        // Resuming from the middle returns the tail and nothing before it.
        let text = String::from_utf8_lossy(&all.bytes).into_owned();
        let cut = u64::try_from(text.find("two").unwrap()).unwrap();
        let tail = pump.resume_from(cut);
        assert_eq!(tail.start, cut);
        assert!(
            String::from_utf8_lossy(&tail.bytes).starts_with("two"),
            "{tail:?}"
        );

        pump.stop();
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }

    /// Pausing must stop the reads, and resuming must pick up everything that piled up meanwhile —
    /// the never-drop contract `PTYReadLoop`'s gate used to hold.
    #[test]
    fn a_paused_pump_reads_nothing_and_loses_nothing() {
        let (pump, pid, sink, _master) = pumped(
            "printf 'first\\n'; sleep 0.4; printf 'second\\n'; sleep 5",
            64 * 1024,
        );
        assert!(collect(&sink, "first").contains("first"));

        pump.set_paused(true);
        let frozen = pump.head();
        std::thread::sleep(Duration::from_millis(700));
        assert_eq!(pump.head(), frozen, "a paused pump must issue no reads");

        pump.set_paused(false);
        assert!(
            collect(&sink, "second").contains("second"),
            "nothing may be dropped"
        );

        pump.stop();
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }

    /// A hostd that dies mid-flood leaves a pause behind. If it stuck, superd would freeze the very
    /// pane it just carried through the restart.
    #[test]
    fn losing_the_last_subscriber_clears_a_leftover_pause() {
        let (pump, pid, _sink, _master) = pumped("while :; do printf 'tick\\n'; sleep 0.05; done", 64 * 1024);
        pump.subscribed();
        pump.set_paused(true);
        let frozen = pump.head();
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(pump.head(), frozen);

        pump.clear_pause_on_last_unsubscribe();

        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while pump.head() == frozen && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            pump.head() > frozen,
            "the pane must start moving again on its own"
        );

        pump.stop();
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }

    /// `drain_to_end` is what orders a pane's last bytes before its `exited` notice.
    #[test]
    fn draining_collects_the_tail_and_joins() {
        let (pump, _pid, sink, _master) = pumped("printf 'goodbye\\n'", 64 * 1024);
        pump.drain_to_end();
        assert!(
            pump.has_ended(),
            "the master must be finished once the drain returns"
        );
        let mut seen = String::new();
        while let Ok((_offset, bytes)) = sink.try_recv() {
            seen.push_str(&String::from_utf8_lossy(&bytes));
        }
        assert!(seen.contains("goodbye"), "{seen}");
    }

    /// A drain must not deadlock behind a pause nobody is left to lift.
    #[test]
    fn draining_overrides_a_pause() {
        let (pump, _pid, _sink, _master) = pumped("printf 'x\\n'", 64 * 1024);
        pump.set_paused(true);
        // Would hang forever if `draining` did not beat `paused`.
        pump.drain_to_end();
        assert!(pump.has_ended());
    }

    /// Offsets are per pane and monotonic, so two chunks never report the same start.
    #[test]
    fn reported_offsets_are_monotonic_and_contiguous() {
        let (pump, pid, sink, _master) = pumped("printf 'a'; sleep 0.1; printf 'b'; sleep 5", 64 * 1024);
        let mut expected = 0_u64;
        let mut saw = 0;
        while let Ok((offset, bytes)) = sink.recv_timeout(Duration::from_secs(5)) {
            assert_eq!(
                offset, expected,
                "chunks must tile the offset space with no holes"
            );
            expected = expected.saturating_add(bytes.len() as u64);
            saw += 1;
            if saw == 2 {
                break;
            }
        }
        assert_eq!(saw, 2);
        pump.stop();
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }

    /// Dropping the pump must join its thread. Without that, the registry's `Pane` could close the
    /// master while a read was still in flight on a duplicate.
    #[test]
    fn dropping_the_pump_joins_the_reader() {
        let (pump, pid, _sink, _master) = pumped("sleep 30", 1024);
        let ring = Arc::clone(&pump.ring);
        drop(pump);
        // If the thread were still running it would hold this lock across its next read.
        assert!(Mutex::try_lock(&ring).is_ok(), "the reader thread should be gone");
        let _ignored =
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), nix::sys::signal::Signal::SIGKILL);
    }
}
