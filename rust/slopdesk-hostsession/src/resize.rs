//! The size fold's shell: the two locks around it, and the three timers it arms.
//!
//! [`slopdesk_muxsession::resize_fold::ResizeFold`] is the arithmetic — a monotone min over the
//! clients holding a pane — and it decides nothing about descriptors, threads or wall clocks. This
//! module is everything it deliberately left out: WHEN a resolution is applied, WHO writes it, and
//! what a redraw needs afterwards. It is the port of `MuxChannelSession`'s "size fold" section, and
//! it keeps that section's two rules exactly.
//!
//! ## Rule one: idempotence is against the LIVE `TIOCGWINSZ`, never a memo
//!
//! [`PtyProcess::begin_redraw_jiggle`](slopdesk_hostpane::PtyProcess::begin_redraw_jiggle)
//! deliberately leaves the PTY one row short while an app re-layouts. A "the fold resolved the same
//! grid, skip the write" memo would then leave the pane one row short for the rest of the session —
//! the fold's own last resolution is the one number that must never decide this. Reading what the
//! PTY actually holds costs one non-blocking ioctl and cannot go stale, so that is what
//! [`Resize::apply`] compares.
//!
//! ## Rule two: the resolve and the write are ONE critical section
//!
//! Two locks, and the order is always `write` → `fold`. Resolving under the fold's lock and writing
//! after releasing it lets two callers land their ioctls in the opposite order to their
//! resolutions — the geometry the PTY keeps would be whichever thread the scheduler resumed last
//! rather than the one the state says. Serialised behind [`Resize::write`], the last write is by
//! construction the newest resolution, and the `if_generation` guard is only meaningful because it
//! shares that section with the write it guards.
//!
//! ## The three timers, and why they are `Weak`
//!
//! The debounce and the settle call back into this object, so their closures hold a `Weak<Resize>`
//! and upgrade at fire time — the same `[weak self]` the Swift tasks carried, and for the same
//! reason: a strong capture would be `Resize` → [`Timers`] → closure → `Resize`, a cycle that
//! outlives every pane whose teardown did not run. The nudge is different: it needs only the
//! descriptor, so it captures the `Arc<PtyProcess>` outright and is a no-op on a closed PTY.
//!
//! The timer thread is joined by [`Resize::stop`] rather than counted in the session's thread
//! census. The census exists for the thread that OUTLIVES its owner — a member's sender parked past
//! its retirement — and this one cannot: `stop` is synchronous and the teardown ladder calls it.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_hostpane::{PtyProcess, WindowSize};
use slopdesk_muxsession::resize_fold::{ArmDecision, Attachment, Grid, ResizeFold, SubscriberId};

use crate::detect::Detect;
use crate::timer::{Timer, Timers};

/// The latest-wins window before a resolved grid reaches `TIOCSWINSZ`.
///
/// Short because it is a DRAG's coalescer and nothing else: a client emits an offer per frame while
/// a window is being dragged, and 16 ms is one frame at 60 Hz — long enough that a drag costs one
/// ioctl per frame rather than one per event, short enough that letting go feels instant.
pub const RESIZE_DEBOUNCE: Duration = Duration::from_millis(16);

/// The longer window a CONTRIBUTOR-SET change arms (docs/45 §8.3 rule 2).
///
/// A set change is a client arriving or leaving, and those come in bursts — a reconnecting client
/// opens several panes at once. Folding each arrival separately would `SIGWINCH` the shell once per
/// pane per arrival; 750 ms lets the whole burst land in one resolution.
pub const SIZE_SETTLE: Duration = Duration::from_millis(750);

/// How long after a size change the shell is nudged into repainting.
///
/// The nudge is a second `SIGWINCH` at the SAME size, so a full-screen app repaints its prompt
/// after the client's own grid has settled rather than while it is still animating.
const REDRAW_NUDGE: Duration = Duration::from_millis(90);

/// One pane's size fold, its writer and its timers.
#[derive(Debug)]
pub(crate) struct Resize {
    /// The arithmetic. Innermost of the two.
    fold: Mutex<ResizeFold>,
    /// Held across [resolve → compare → ioctl] so two callers cannot invert their writes.
    write: Mutex<()>,
    timers: Timers,
    pty: Arc<PtyProcess>,
    /// The screen engine, held only to INVALIDATE its grid — see [`Resize::apply`]. Strongly, and
    /// safely so: detection reaches the pane and the shared state, never back to the size fold.
    detect: Arc<Detect>,
    debounce: Duration,
    settle: Duration,
}

impl Resize {
    /// A fold for a pane whose opening subscriber votes (or does not), with no timer thread yet.
    pub(crate) fn new(
        pty: Arc<PtyProcess>,
        detect: Arc<Detect>,
        opened_size_passive: bool,
        debounce: Duration,
        settle: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            fold: Mutex::new(ResizeFold::new(opened_size_passive)),
            write: Mutex::new(()),
            timers: Timers::new(),
            pty,
            detect,
            debounce,
            settle,
        })
    }

    /// Registers `subscriber` as a member of the contributing set, or updates its passivity.
    pub(crate) fn add_contributor(self: &Arc<Self>, subscriber: SubscriberId, size_passive: bool) {
        let decision = self
            .fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .add_contributor(subscriber, size_passive);
        self.arm_settle(decision);
    }

    /// Drops `subscriber` from the contributing set. A pane whose set empties keeps its last size.
    pub(crate) fn remove_contributor(self: &Arc<Self>, subscriber: SubscriberId) {
        let decision = self
            .fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove_contributor(subscriber);
        self.arm_settle(decision);
    }

    /// Records `subscriber`'s latest offer and re-arms the short debounce, if the fold wants one.
    ///
    /// Every offer RE-ARMS rather than blocking, so the debounce always fires after the LAST one —
    /// the trailing-edge guarantee that makes the newest size the one that lands. The fold declines
    /// to arm while a contributor settle is outstanding: the offer joins the fold that settle will
    /// resolve, and arming here is exactly what would `SIGWINCH` the shell once per arrival in a
    /// burst of joins.
    pub(crate) fn offer(self: &Arc<Self>, subscriber: SubscriberId, grid: Grid) {
        let decision = self
            .fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note_offer(subscriber, grid);
        if !decision.arm_debounce {
            return;
        }
        let generation = decision.generation;
        let weak = Arc::downgrade(self);
        self.timers.arm(
            Timer::Resize,
            self.debounce,
            Box::new(move || {
                if let Some(resize) = weak.upgrade() {
                    resize.apply(Some(generation));
                }
            }),
        );
    }

    /// Installs the ctl socket's override and applies it AT ONCE, through the one writer.
    ///
    /// Immediate rather than debounced: `slopdesk-ctl resize 132×50` means it, and the verb returns
    /// when the pane is that size. Installing the override supersedes any in-flight debounce or
    /// settle — it is being applied right now, and a timer firing afterwards with the older fold
    /// would undo it a frame later. The generation bump retires a timer that has not yet resolved;
    /// [`Resize::write`] is what stops one that already did from landing its ioctl after this
    /// one's.
    ///
    /// Through [`Resize::apply`] rather than a `TIOCSWINSZ` of its own, so the ctl verb gets the
    /// journal size sidecar and the settled redraw nudge the client path has always had. A second
    /// independent write here is what left the sidecar describing a geometry the PTY no longer
    /// held.
    pub(crate) fn set_ctl_override(self: &Arc<Self>, grid: Grid) {
        self.fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set_ctl_override(grid);
        self.apply(None);
    }

    /// Resolves the grid and applies it via `TIOCSWINSZ` — the ONE writer every client and every
    /// ctl path funnels through.
    ///
    /// `if_generation` is the timer paths' guard: a body already past its sleep must not apply a
    /// fold a newer one superseded. The flush paths pass `None` and apply unconditionally, because
    /// they must never strand a size.
    pub(crate) fn apply(self: &Arc<Self>, if_generation: Option<u64>) {
        let write = self.write.lock().unwrap_or_else(PoisonError::into_inner);
        let resolved = self
            .fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .resolve(if_generation);
        let Some(grid) = resolved else {
            drop(write);
            return;
        };
        let wanted = WindowSize {
            rows: grid.rows,
            cols: grid.cols,
            px_width: grid.px,
            px_height: grid.py,
        };
        if self.pty.window_size() == Some(wanted) {
            // The PTY already holds exactly this grid — see rule one: this is a comparison against
            // the LIVE size, so a redraw jiggle's deliberate one-row shortfall reads as a
            // difference and is corrected rather than memoised away.
            drop(write);
            return;
        }
        // The RESOLVED size, not the requester's offer — and the same call tells superd, which
        // records it beside the transcript so a later life's restore parses those bytes at the
        // geometry they were emitted for. A width no client ever had would re-wrap every line.
        self.pty.set_window_size(wanted);
        drop(write);
        // The resident screen model is a FIXED-SIZE grid, and a VT grid cannot be reflowed — so a
        // geometry change does not adjust it, it invalidates it. Marking it here rather than in the
        // scan loop is what makes the invalidation atomic with the ioctl that caused it: a scan
        // that sampled the new size but folded bytes painted for the old one would run its
        // rule ladder over a screen no program ever drew.
        self.detect.mark_screen_dirty();
        self.schedule_nudge();
    }

    /// Applies whatever the fold resolves right now, superseding nothing.
    pub(crate) fn flush(self: &Arc<Self>) {
        self.apply(None);
    }

    /// The grid the fold resolved for this pane, as the roster publishes it.
    ///
    /// Falls back to the live winsize for a pane nothing has ever resolved — a ctl-spawned shell
    /// with no contributing subscriber is still a real terminal at a real size, and publishing 0×0
    /// would make every client render a letterbox for a pane that is fine.
    pub(crate) fn resolved_grid(&self) -> (u16, u16) {
        let resolved = self
            .fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .resolved_grid();
        if let Some(grid) = resolved {
            return (grid.cols, grid.rows);
        }
        self.pty
            .window_size()
            .map_or((0, 0), |live| (live.cols, live.rows))
    }

    /// Every contributor's standing offer, in subscriber order.
    pub(crate) fn attachments(&self) -> Vec<Attachment> {
        self.fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .attachments()
    }

    /// How many delayed redraw nudges this pane has scheduled, ever. A regression seam: the nudge
    /// itself is a `SIGWINCH` to somebody else's process group, which a test cannot observe.
    pub(crate) fn scheduled_nudges(&self) -> u64 {
        self.timers.armed(Timer::Nudge)
    }

    /// Drops every member, for a pane being torn down: nobody holds a dead pane at a size.
    pub(crate) fn clear_members(&self) {
        self.fold
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear_members();
    }

    /// Ends the timer thread and drops every pending action.
    pub(crate) fn stop(&self) {
        self.timers.stop();
    }

    /// Starts the settle the fold asked for, if it asked for one.
    ///
    /// The fold arms only when the contributing set moved BETWEEN two non-empty states — a set
    /// going 0→1 or 1→0 has exactly one possible fold, so making the first client of a fresh
    /// pane wait 750 ms for a size it alone decides would be latency for nothing.
    fn arm_settle(self: &Arc<Self>, decision: ArmDecision) {
        if !decision.arm_settle {
            return;
        }
        let generation = decision.generation;
        let weak = Arc::downgrade(self);
        self.timers.arm(
            Timer::Settle,
            self.settle,
            Box::new(move || {
                let Some(resize) = weak.upgrade() else { return };
                // Release the latch FIRST, so an offer arriving between here and the apply arms its
                // own debounce instead of being swallowed by a settle that has already fired.
                resize
                    .fold
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clear_settle(generation);
                resize.apply(Some(generation));
            }),
        );
    }

    /// Schedules a single delayed `SIGWINCH`, cancel-replace, so a drag emits exactly one nudge —
    /// at the final size.
    fn schedule_nudge(&self) {
        let pty = Arc::clone(&self.pty);
        self.timers
            .arm(Timer::Nudge, REDRAW_NUDGE, Box::new(move || pty.nudge_redraw()));
    }
}
