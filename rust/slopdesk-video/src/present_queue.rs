//! Which decoded frame the client shows on this refresh, and when.
//!
//! The pacer runs in one of two modes and both of them live here. The QUEUE mode holds a few frames
//! of slack and hands them out one per tick; the DEADLINE mode holds exactly one frame and shows it
//! when its scheduled moment arrives. What the module does NOT hold is the frames — the decoder's
//! image buffers stay where they are and the queue carries opaque handles, so the whole
//! presentation policy is drivable from a virtual clock with no image pipeline anywhere near it.
//!
//! Three rules in here are worth reading before changing anything. HOMEOSTASIS trims the queue to
//! the live depth on every present, so steady-state latency settles at the depth the controller
//! asked for instead of ratcheting up to the hard cap under sustained motion. The RE-PRIME
//! threshold is a floor of two empty slots, never one, because at the adaptive floor of a single
//! frame it would otherwise collide with the transient-dip detector and pin the buffer there
//! forever. And every law that counts refreshes counts them in CONTENT SLOTS, not display ticks:
//! the link ticks at the panel's own rate, which is two to four times the content rate, so at any
//! depth above one a frame is handed out once per [`PresentQueue::ticks_per_frame`] ticks and a
//! slot is what goes empty — otherwise the slack frame a deeper buffer exists to hold is presented
//! on the very next tick, the queue never carries slack, and the empty ticks between arrivals read
//! as starvation. At depth one there is no slack to meter and the metering is off: every tick is a
//! slot, which is also what keeps present-on-arrival's between-tick step from ever being refused.

use std::collections::VecDeque;

/// How many jitter samples pass between playout recomputations on the live path.
///
/// The law itself is cheap; the cadence exists so the playout delay moves on a trend rather than on
/// one unlucky frame.
pub const PLAYOUT_RECOMPUTE_EVERY: u32 = 60;

/// The hard ceiling on the playout delay, in seconds, applied after the law has stepped.
///
/// The law's own ceiling is a configuration knob; this is the backstop that keeps a nonsense
/// configuration from parking a fifth of a second of latency in front of the user.
pub const PLAYOUT_HARD_CEILING_SECONDS: f64 = 0.2;

/// The slack allowed on the frame-rate cap, in seconds.
///
/// Without it, a refresh landing a hair early is vetoed and the cap beats against the display's
/// vsync — a periodic dropped frame that reads as stutter, from rounding alone.
pub const RENDER_CAP_SLACK_SECONDS: f64 = 0.0005;

/// The lowest tick rate the override accepts.
pub const MIN_TICK_HZ: f64 = 30.0;
/// The highest tick rate the override accepts.
pub const MAX_TICK_HZ: f64 = 240.0;

/// The deepest queue any configuration may ask for.
///
/// The env gate that sets the hard cap clamps to this before a pacer is ever built, so it bounds
/// the live path rather than truncating it — and it is what the crossing form's fixed capacity is
/// proved against.
pub const MAX_QUEUE_DEPTH: u32 = 16;

/// How many display ticks one content frame spans: the floor of the tick rate over the content
/// rate, never below one.
///
/// The FLOOR, so the metered present rate is never below the content rate: rounding 2.67 up to 3
/// would hand frames out slower than they arrive and homeostasis would drop one in nine. Rounding
/// down under-meters instead — at a ratio that is not a whole number the slack drains to nothing,
/// which is what today's unmetered queue does everywhere, and nothing is dropped. A tick rate at or
/// below the content rate is one tick per frame, the lockstep law.
#[must_use]
pub fn ticks_per_frame(tick_hz: f64, content_fps: f64) -> u32 {
    if !tick_hz.is_finite() || !content_fps.is_finite() || content_fps <= 0.0 || tick_hz <= 0.0 {
        return 1;
    }
    let ratio = (tick_hz / content_fps).floor();
    // A ratio past the tick band is a nonsense configuration; the saturating cast keeps it a
    // number.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the ratio is floored, non-negative and finite; the cast saturates past u32"
    )]
    let whole = ratio as u32;
    whole.max(1)
}

/// How many frames one crossing of the queue carries: the deepest queue, exactly.
pub const QUEUE_CAPACITY: usize = MAX_QUEUE_DEPTH as usize;

/// Bounds a stepped playout delay into the range the presentation path will accept.
#[must_use]
pub const fn clamped_playout_seconds(next_seconds: f64) -> f64 {
    // Deliberately NOT `clamp`, which passes a NaN straight through into the presentation schedule;
    // the chained max-then-min lets the bound win, which is the Swift's IEEE-754 semantics.
    next_seconds.max(0.0).min(PLAYOUT_HARD_CEILING_SECONDS)
}

/// Whether this arrival is the sixtieth since the last recomputation, and the cadence gate opens.
///
/// Returns the new sample count alongside, so the caller keeps no counter logic of its own.
#[must_use]
pub const fn playout_recompute_due(samples_since_last: u32) -> (bool, u32) {
    let next = samples_since_last.saturating_add(1);
    if next >= PLAYOUT_RECOMPUTE_EVERY {
        (true, 0)
    } else {
        (false, next)
    }
}

/// When a newly arrived frame should be presented, in the deadline mode.
///
/// The first frame schedules itself one playout delay out. After that the schedule EXTENDS the
/// content rhythm — the previous deadline plus one interval — anchored to the schedule rather than
/// to the arrival, so jitter on arrivals does not modulate the spacing the user sees.
///
/// The catch-up branch is the one that matters after a stall: when the rhythm has fallen more than
/// a whole interval behind the arrival, re-anchor instead of fast-forwarding through the backlog,
/// so the end of a network stall costs one re-anchor and not a burst of crammed presents.
#[must_use]
pub fn deadline_for_arrival(arrival: f64, last_deadline: f64, interval: f64, playout_delay: f64) -> f64 {
    if last_deadline <= 0.0 {
        return arrival + playout_delay;
    }
    let next = last_deadline + interval;
    if next < arrival - interval {
        return arrival + playout_delay;
    }
    next
}

/// Whether a scheduled present is due at this tick.
///
/// The half-tick lookahead is what keeps a deadline that "just missed" a tick from waiting a whole
/// one: it waits at most half.
#[must_use]
pub fn deadline_due(deadline: f64, now: f64, half_tick: f64) -> bool {
    deadline <= now + half_tick
}

/// The rate the display link should run at.
///
/// It ticks at the DISPLAY's native refresh rather than the content rate, so a decoded frame waits
/// at most one native interval for a slot — half the worst case on a high-refresh panel. The floor
/// is the content rate, which is what keeps a screen reporting something degenerate, or nothing at
/// all, from throttling presentation below the stream itself.
#[must_use]
pub fn resolve_tick_rate(env_override: Option<&str>, display_max_hz: u32, floor: f64) -> f64 {
    if let Some(hz) = env_override.and_then(|raw| raw.parse::<f64>().ok())
        && hz.is_finite()
    {
        return hz.clamp(MIN_TICK_HZ, MAX_TICK_HZ);
    }
    floor.max(f64::from(display_max_hz))
}

/// Whether a render may run under the frame-rate cap. The first tick always renders.
#[must_use]
pub fn should_render(now: f64, last_render: f64, max_frame_rate: f64) -> bool {
    if max_frame_rate <= 0.0 || last_render <= 0.0 {
        return true;
    }
    let min_interval = 1.0 / max_frame_rate;
    (now - last_render) >= (min_interval - RENDER_CAP_SLACK_SECONDS)
}

/// Whether an arriving frame should be presented immediately rather than waiting for the next tick.
///
/// This only fires into a queue that WAS empty and is now at depth — a starved display, where the
/// next tick is a whole refresh away and the frame is already late. A queue that was not empty is
/// being served on cadence and must stay on it.
#[must_use]
pub const fn should_present_on_arrival(
    enabled: bool,
    queue_was_empty: bool,
    queue_count: u32,
    live_depth: u32,
) -> bool {
    enabled && queue_was_empty && queue_count >= live_depth
}

/// One frame waiting its turn, as the queue sees it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QueuedFrame {
    /// The caller's own handle for the image buffer; the queue never looks inside it.
    pub handle: u64,
    /// When it was submitted, in the caller's monotonic seconds — the other end of the hold the
    /// presentation-latency measurement is taken across.
    pub submitted_at: f64,
}

/// The handles one fold made obsolete, oldest first.
///
/// The queue carries handles it never dereferences, so the caller is the one holding the images and
/// has to be told WHICH of them died. A count would say how many, and leave the caller inferring
/// which from a queue order it is precisely not supposed to be keeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DroppedHandles {
    handles: [u64; QUEUE_CAPACITY],
    len: usize,
}

impl DroppedHandles {
    /// Nothing dropped.
    const fn new() -> Self {
        Self {
            handles: [0; QUEUE_CAPACITY],
            len: 0,
        }
    }

    /// Records one obsolete handle. Silently full-stops at the capacity, which the trim bounds
    /// below the queue's own depth can never reach.
    fn push(&mut self, handle: u64) {
        if let Some(slot) = self.handles.get_mut(self.len) {
            *slot = handle;
            self.len += 1;
        }
    }

    /// The handles, oldest first.
    #[must_use]
    pub fn slice(&self) -> &[u64] {
        self.handles.get(..self.len).unwrap_or(&[])
    }

    /// How many there are.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether the fold dropped nothing.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}

/// What one submission did to the queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Submission {
    /// The handle the HARD cap evicted to make room, if it had to.
    pub evicted: Option<u64>,
    /// Whether the queue was empty before this frame landed — what the present-on-arrival gate
    /// reads, and the one thing it cannot recover afterwards.
    pub was_empty: bool,
}

/// What one refresh should do.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PresentOutcome {
    /// Still filling the buffer: re-show the last frame, if there is one, and build the slack.
    Priming {
        /// The handle to re-show, absent when nothing has ever decoded.
        last_shown: Option<u64>,
    },
    /// Present this frame.
    Present {
        /// The frame to show.
        frame: QueuedFrame,
        /// Whether this present follows at least one empty slot WHILE STILL PRIMED — a real,
        /// transient starvation, which is the caller's cue to grow the buffer. It is deliberately
        /// false after an idle re-prime, so the host going quiet never inflates anything.
        transient_dip: bool,
    },
    /// Between two content slots on a display that ticks faster than the content: re-show the last
    /// frame and keep the slack. Not an underflow — the queue may well be holding a frame — so it
    /// carries no starvation signal and a caller counting hitches must not count it.
    Hold {
        /// The handle to re-show, absent when nothing has ever decoded.
        last_shown: Option<u64>,
    },
    /// The producer fell behind: re-show the last frame.
    Reshow {
        /// The handle to re-show, absent when nothing has ever decoded.
        last_shown: Option<u64>,
        /// Whether this tick dropped back to priming, which is also the caller's cue to reset the
        /// jitter estimator — otherwise the long idle gap becomes one enormous inter-arrival and
        /// the buffer inflates on every stop-and-resume, defeating the whole latency reclaim.
        re_primed: bool,
    },
}

/// One refresh: what to show, and which handles the caller may now let go of.
///
/// The drop list is not part of the outcome because it is not part of the picture — it is the
/// bookkeeping a queue of opaque handles owes whoever holds the images behind them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PresentStep {
    /// What this refresh should do.
    pub outcome: PresentOutcome,
    /// The handles this refresh made obsolete, oldest first.
    pub dropped: DroppedHandles,
}

/// The queue-mode presentation state machine.
#[derive(Debug, Clone, PartialEq)]
pub struct PresentQueue {
    queue: VecDeque<QueuedFrame>,
    max_depth: u32,
    live_depth: u32,
    primed: bool,
    underflow_run: u32,
    last_shown: Option<u64>,
    ticks_per_frame: u32,
    ticks_since_slot: u32,
}

impl PresentQueue {
    /// A queue at the given live depth, under the hard cap the pacer was built with — itself
    /// bounded by [`MAX_QUEUE_DEPTH`], which is the band the crossing form is sized for — ticking
    /// `ticks_per_frame` times per content frame (see [`ticks_per_frame`]).
    #[must_use]
    pub fn new(live_depth: u32, max_depth: u32, ticks_per_frame: u32) -> Self {
        // `clamp` panics when its bounds cross; both of these are constants and one is 1, so the
        // ordering is proved here rather than assumed — which is the only condition it may be used
        // under on a path that aborts on panic.
        let cap = max_depth.clamp(1, MAX_QUEUE_DEPTH);
        let ticks_per_frame = ticks_per_frame.max(1);
        Self {
            queue: VecDeque::new(),
            max_depth: cap,
            live_depth: live_depth.max(1).min(cap),
            primed: false,
            underflow_run: 0,
            last_shown: None,
            ticks_per_frame,
            // The first slot is open at once: nothing has been handed out for it to follow.
            ticks_since_slot: ticks_per_frame,
        }
    }

    /// How many display ticks one content frame spans.
    #[must_use]
    pub const fn ticks_per_frame(&self) -> u32 {
        self.ticks_per_frame
    }

    /// Adopts a new tick-to-content ratio — the host announced a new cadence, or the link moved to
    /// another panel. The slot in progress is opened, so a rebase never lengthens a hold.
    pub const fn set_ticks_per_frame(&mut self, ticks_per_frame: u32) {
        self.ticks_per_frame = if ticks_per_frame < 1 { 1 } else { ticks_per_frame };
        self.ticks_since_slot = self.ticks_per_frame;
    }

    /// Whether this tick is a content slot: at depth one every tick is, and above it one tick in
    /// [`Self::ticks_per_frame`] is. Counts the tick.
    const fn slot_opens(&mut self) -> bool {
        self.ticks_since_slot = self.ticks_since_slot.saturating_add(1);
        if self.live_depth < 2 {
            return true;
        }
        self.ticks_since_slot >= self.ticks_per_frame
    }

    /// The depth being served right now.
    #[must_use]
    pub const fn live_depth(&self) -> u32 {
        self.live_depth
    }

    /// How many frames are waiting.
    #[must_use]
    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    /// Whether the buffer has filled and steady presentation has begun.
    #[must_use]
    pub const fn primed(&self) -> bool {
        self.primed
    }

    /// The last frame handed out, which is what a hold or an underflow re-shows.
    #[must_use]
    pub const fn last_shown(&self) -> Option<u64> {
        self.last_shown
    }

    /// Adopts a new live depth from the depth controller.
    ///
    /// A PROMOTE re-primes, because otherwise the extra depth only changes the trim limits and the
    /// gates — the standing slack frame it was asked for never actually gets built. A DEMOTE needs
    /// nothing: homeostasis trims the extra frame on the next present by itself.
    pub const fn set_live_depth(&mut self, depth: u32) {
        let bounded = self.bounded_depth(depth);
        if bounded > self.live_depth {
            self.primed = false;
        }
        self.live_depth = bounded;
    }

    /// Adopts a new live depth WITHOUT re-priming on a promote.
    ///
    /// This is the older arrival-jitter controller's path, which recommends a depth on every frame
    /// and on every underrun. It predates the promote rule above and does not carry it: re-priming
    /// on a recommendation that moves this often would hold the picture on a schedule the user can
    /// see. The two controllers are mutually exclusive, so the two doors never both apply.
    pub const fn adopt_live_depth(&mut self, depth: u32) {
        self.live_depth = self.bounded_depth(depth);
    }

    /// A depth inside the pacer's own band: never nothing, never past the hard cap.
    const fn bounded_depth(&self, depth: u32) -> u32 {
        if depth < 1 {
            1
        } else if depth > self.max_depth {
            self.max_depth
        } else {
            depth
        }
    }

    /// Enqueues a decoded frame, trimming to the HARD cap — the backstop under the live depth's own
    /// homeostasis. Answers what the caller cannot work out afterwards: whether the queue was empty
    /// before, and which handle the cap evicted.
    pub fn submit(&mut self, frame: QueuedFrame) -> Submission {
        let was_empty = self.queue.is_empty();
        self.queue.push_back(frame);
        let mut evicted = None;
        while self.queue.len() > self.max_depth as usize {
            evicted = self.queue.pop_front().map(|stale| stale.handle);
        }
        Submission { evicted, was_empty }
    }

    /// One refresh.
    pub fn step(&mut self) -> PresentStep {
        if !self.primed {
            if self.queue.len() < self.live_depth as usize {
                return PresentStep {
                    outcome: PresentOutcome::Priming {
                        last_shown: self.last_shown,
                    },
                    dropped: DroppedHandles::new(),
                };
            }
            self.primed = true;
            // The reset is what makes the dip detector below mean "starved" rather than "resumed".
            self.underflow_run = 0;
            // Priming ends on a present, whatever the tick count says: the slack is built and
            // holding it one slot longer would only be latency.
            self.ticks_since_slot = self.ticks_per_frame;
        }
        if !self.slot_opens() {
            return PresentStep {
                outcome: PresentOutcome::Hold {
                    last_shown: self.last_shown,
                },
                dropped: DroppedHandles::new(),
            };
        }
        // The slot is spent whether or not a frame fills it: a slot that went empty is a missed
        // frame, and the next one opens on the content rhythm rather than on the next tick, so a
        // late frame is shown where the cadence puts it and the slack it left is rebuilt.
        self.ticks_since_slot = 0;
        let excess = self.queue.len().saturating_sub(self.live_depth as usize);
        let mut dropped = DroppedHandles::new();
        for _ in 0..excess {
            if let Some(stale) = self.queue.pop_front() {
                dropped.push(stale.handle);
            }
        }
        if let Some(frame) = self.queue.pop_front() {
            let transient_dip = self.underflow_run > 0;
            self.underflow_run = 0;
            self.last_shown = Some(frame.handle);
            return PresentStep {
                outcome: PresentOutcome::Present { frame, transient_dip },
                dropped,
            };
        }
        self.underflow_run = self.underflow_run.saturating_add(1);
        // The floor of two keeps this STRICTLY above the single empty slot the dip detector reads.
        // At a live depth of one the two would collide: the first empty slot would re-prime before
        // any present could observe the dip, so neither growth path could ever fire and the buffer
        // would pin at one frame, judder and all, with no way back up as a clean link degrades.
        let re_prime_after = self.live_depth.max(2);
        let re_primed = self.underflow_run >= re_prime_after;
        if re_primed {
            self.primed = false;
        }
        PresentStep {
            outcome: PresentOutcome::Reshow {
                last_shown: self.last_shown,
                re_primed,
            },
            dropped,
        }
    }

    /// The whole state as one fixed-size value, for a caller that stores it rather than owning
    /// this.
    #[must_use]
    pub fn snapshot(&self) -> PresentQueueSnapshot {
        let mut snapshot = PresentQueueSnapshot {
            queue: [EMPTY_SLOT; QUEUE_CAPACITY],
            len: 0,
            last_shown: self.last_shown,
            max_depth: self.max_depth,
            live_depth: self.live_depth,
            underflow_run: self.underflow_run,
            primed: self.primed,
            ticks_per_frame: self.ticks_per_frame,
            ticks_since_slot: self.ticks_since_slot,
        };
        for (slot, frame) in snapshot.queue.iter_mut().zip(self.queue.iter()) {
            *slot = *frame;
            snapshot.len += 1;
        }
        snapshot
    }

    /// The queue a snapshot describes. Every bound is re-applied, so a snapshot that arrived from
    /// outside this crate cannot widen one.
    #[must_use]
    pub fn restored(snapshot: &PresentQueueSnapshot) -> Self {
        let mut restored = Self::new(snapshot.live_depth, snapshot.max_depth, snapshot.ticks_per_frame);
        restored.primed = snapshot.primed;
        restored.underflow_run = snapshot.underflow_run;
        restored.last_shown = snapshot.last_shown;
        restored.ticks_since_slot = snapshot.ticks_since_slot.min(restored.ticks_per_frame);
        let live = snapshot.len.min(QUEUE_CAPACITY).min(restored.max_depth as usize);
        restored
            .queue
            .extend(snapshot.queue.get(..live).unwrap_or(&[]).iter().copied());
        restored
    }
}

/// The slot a snapshot's unused entries carry.
const EMPTY_SLOT: QueuedFrame = QueuedFrame {
    handle: 0,
    submitted_at: 0.0,
};

/// A queue as a value: the waiting frames in order, and the state machine around them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PresentQueueSnapshot {
    /// The waiting frames, oldest first, the first `len` of them live.
    pub queue: [QueuedFrame; QUEUE_CAPACITY],
    /// How many queue slots are live.
    pub len: usize,
    /// The last handle handed out, which a hold or an underflow re-shows.
    pub last_shown: Option<u64>,
    /// The hard cap.
    pub max_depth: u32,
    /// The depth being served.
    pub live_depth: u32,
    /// Consecutive empty slots.
    pub underflow_run: u32,
    /// Whether steady presentation has begun.
    pub primed: bool,
    /// How many display ticks one content frame spans.
    pub ticks_per_frame: u32,
    /// Ticks since the last content slot, saturating at `ticks_per_frame`.
    pub ticks_since_slot: u32,
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the schedule fixtures are exact sums of exact binary fractions, and a wrong outcome \
                  variant is a test failure with nothing to return"
    )]

    use super::{
        MAX_QUEUE_DEPTH, PLAYOUT_HARD_CEILING_SECONDS, PresentOutcome, PresentQueue, PresentStep,
        QUEUE_CAPACITY, QueuedFrame, clamped_playout_seconds, deadline_due, deadline_for_arrival,
        playout_recompute_due, resolve_tick_rate, should_present_on_arrival, should_render, ticks_per_frame,
    };

    fn frame(handle: u64) -> QueuedFrame {
        QueuedFrame {
            handle,
            #[expect(
                clippy::cast_precision_loss,
                reason = "the fixture handles are small integers standing in for arrival times"
            )]
            submitted_at: handle as f64,
        }
    }

    fn presented(step: PresentStep) -> Option<u64> {
        match step.outcome {
            PresentOutcome::Present { frame, .. } => Some(frame.handle),
            PresentOutcome::Priming { .. } | PresentOutcome::Reshow { .. } | PresentOutcome::Hold { .. } => {
                None
            },
        }
    }

    #[test]
    fn the_first_frame_schedules_itself_one_playout_delay_out() {
        assert_eq!(deadline_for_arrival(10.0, 0.0, 0.016_25, 0.004), 10.004);
    }

    #[test]
    fn the_schedule_extends_the_rhythm_rather_than_following_the_arrivals() {
        // An arrival 3 ms late still presents on the beat, so jitter does not reach the eye.
        assert_eq!(deadline_for_arrival(10.019, 10.004, 0.016, 0.004), 10.02);
        assert_eq!(
            deadline_for_arrival(10.013, 10.004, 0.016, 0.004),
            10.02,
            "or early"
        );
    }

    #[test]
    fn a_stall_re_anchors_instead_of_cramming_the_backlog_through() {
        // The rhythm is a tenth of a second behind: fast-forwarding would present a burst.
        let after_stall = deadline_for_arrival(10.1, 10.004, 0.016, 0.004);
        assert_eq!(after_stall, 10.104);
    }

    #[test]
    fn a_deadline_that_just_missed_a_tick_waits_at_most_half_of_one() {
        assert!(deadline_due(10.0, 10.0, 0.008));
        assert!(deadline_due(10.007, 10.0, 0.008), "just missed, so it goes now");
        assert!(!deadline_due(10.009, 10.0, 0.008), "not yet — next tick");
    }

    #[test]
    fn the_link_ticks_at_the_panel_rate_but_never_below_the_content_rate() {
        assert_eq!(resolve_tick_rate(None, 120, 60.0), 120.0);
        assert_eq!(
            resolve_tick_rate(None, 0, 60.0),
            60.0,
            "a headless screen must not throttle"
        );
    }

    #[test]
    fn the_tick_override_is_clamped_into_a_sane_band() {
        assert_eq!(resolve_tick_rate(Some("90"), 60, 60.0), 90.0);
        assert_eq!(resolve_tick_rate(Some("5"), 60, 60.0), 30.0);
        assert_eq!(resolve_tick_rate(Some("10000"), 60, 60.0), 240.0);
        assert_eq!(
            resolve_tick_rate(Some("nonsense"), 120, 60.0),
            120.0,
            "and a bad one is ignored"
        );
        assert_eq!(resolve_tick_rate(Some("nan"), 120, 60.0), 120.0);
    }

    #[test]
    fn the_cap_lets_a_refresh_landing_a_hair_early_through() {
        assert!(should_render(0.0, 0.0, 60.0), "the first tick always renders");
        assert!(should_render(1.0, 0.0, 60.0));
        assert!(!should_render(1.005, 1.0, 60.0));
        assert!(
            should_render(1.0163, 1.0, 60.0),
            "a hair under one interval still counts, or the cap beats against the vsync",
        );
        assert!(should_render(1.0001, 1.0, 0.0), "an absent cap never throttles");
    }

    #[test]
    fn present_on_arrival_only_fires_into_a_starved_display() {
        assert!(should_present_on_arrival(true, true, 1, 1));
        assert!(!should_present_on_arrival(false, true, 1, 1), "off is off");
        assert!(
            !should_present_on_arrival(true, false, 3, 1),
            "a queue being served on cadence stays on it",
        );
        assert!(
            !should_present_on_arrival(true, true, 1, 2),
            "and it must still reach depth"
        );
    }

    #[test]
    fn the_playout_recompute_waits_for_a_trend_rather_than_one_unlucky_frame() {
        let mut samples = 0;
        for _ in 0..59 {
            let (due, next) = playout_recompute_due(samples);
            assert!(!due);
            samples = next;
        }
        let (due, next) = playout_recompute_due(samples);
        assert!(due);
        assert_eq!(next, 0, "and the counter starts over");
    }

    #[test]
    fn the_playout_delay_has_a_backstop_a_nonsense_configuration_cannot_pass() {
        assert_eq!(clamped_playout_seconds(0.012), 0.012);
        assert_eq!(clamped_playout_seconds(-1.0), 0.0);
        assert_eq!(clamped_playout_seconds(9.0), PLAYOUT_HARD_CEILING_SECONDS);
    }

    #[test]
    fn nothing_presents_until_the_buffer_has_filled_to_depth() {
        let mut queue = PresentQueue::new(2, 6, 1);
        assert_eq!(queue.step().outcome, PresentOutcome::Priming { last_shown: None });
        queue.submit(frame(1));
        assert_eq!(
            queue.step().outcome,
            PresentOutcome::Priming { last_shown: None },
            "one frame is not two frames of slack",
        );
        queue.submit(frame(2));
        assert_eq!(presented(queue.step()), Some(1), "and then it serves in order");
        assert!(queue.primed());
    }

    #[test]
    fn homeostasis_settles_at_the_live_depth_instead_of_ratcheting_to_the_cap() {
        let mut queue = PresentQueue::new(2, 6, 1);
        for id in 1..=6 {
            queue.submit(frame(id));
        }
        let step = queue.step();
        match step.outcome {
            PresentOutcome::Present { frame, .. } => {
                assert_eq!(
                    frame.handle, 5,
                    "it catches up to the freshest inside the slack window"
                );
                assert_eq!(
                    step.dropped.slice(),
                    &[1, 2, 3, 4],
                    "and it says WHICH, so the caller can free them",
                );
            },
            other => panic!("expected a present, got {other:?}"),
        }
        assert_eq!(
            queue.queued(),
            1,
            "exactly the slack, so the latency does not ratchet"
        );
    }

    #[test]
    fn the_hard_cap_is_the_backstop_under_the_live_depth() {
        let mut queue = PresentQueue::new(2, 3, 1);
        for id in 1..=10 {
            queue.submit(frame(id));
        }
        assert_eq!(
            queue.queued(),
            3,
            "the submit path never grows past the pacer's cap"
        );
    }

    #[test]
    fn a_single_empty_tick_reads_as_a_real_starvation() {
        let mut queue = PresentQueue::new(1, 6, 1);
        queue.submit(frame(1));
        assert_eq!(presented(queue.step()), Some(1));
        assert_eq!(
            queue.step().outcome,
            PresentOutcome::Reshow {
                last_shown: Some(1),
                re_primed: false,
            },
            "one empty tick at the floor must NOT re-prime, or the growth path can never fire",
        );
        queue.submit(frame(2));
        match queue.step().outcome {
            PresentOutcome::Present { transient_dip, .. } => {
                assert!(transient_dip, "which is the cue to grow the buffer");
            },
            other => panic!("expected a present, got {other:?}"),
        }
    }

    #[test]
    fn a_sustained_dry_spell_drops_back_to_priming_so_the_slack_is_rebuilt() {
        let mut queue = PresentQueue::new(1, 6, 1);
        queue.submit(frame(1));
        queue.step();
        assert!(matches!(queue.step().outcome, PresentOutcome::Reshow {
            re_primed: false,
            ..
        }));
        assert_eq!(queue.step().outcome, PresentOutcome::Reshow {
            last_shown: Some(1),
            re_primed: true,
        },);
        assert!(!queue.primed());
    }

    #[test]
    fn the_host_going_quiet_never_inflates_the_buffer() {
        let mut queue = PresentQueue::new(1, 6, 1);
        queue.submit(frame(1));
        queue.step();
        // Idle long enough to re-prime, then resume.
        queue.step();
        queue.step();
        queue.submit(frame(2));
        match queue.step().outcome {
            PresentOutcome::Present { transient_dip, .. } => {
                assert!(
                    !transient_dip,
                    "an idle-skip resume is not a starvation, which is the whole discriminator",
                );
            },
            other => panic!("expected a present, got {other:?}"),
        }
    }

    #[test]
    fn a_promote_re_primes_so_the_standing_frame_is_actually_built() {
        let mut queue = PresentQueue::new(1, 6, 1);
        queue.submit(frame(1));
        queue.step();
        queue.set_live_depth(2);
        assert!(!queue.primed());
        queue.submit(frame(2));
        assert_eq!(
            queue.step().outcome,
            PresentOutcome::Priming { last_shown: Some(1) },
            "the extra depth is worthless unless a frame is actually held",
        );
    }

    #[test]
    fn a_demote_needs_no_re_prime_because_homeostasis_trims_it() {
        let mut queue = PresentQueue::new(3, 6, 1);
        for id in 1..=3 {
            queue.submit(frame(id));
        }
        queue.step();
        assert!(queue.primed());
        queue.set_live_depth(1);
        assert!(queue.primed(), "still serving");
        queue.submit(frame(4));
        assert_eq!(
            presented(queue.step()),
            Some(4),
            "and the extra frames are trimmed on the way"
        );
    }

    #[test]
    fn the_depth_stays_inside_the_pacers_own_cap() {
        let mut queue = PresentQueue::new(99, 4, 1);
        assert_eq!(queue.live_depth(), 4);
        queue.set_live_depth(0);
        assert_eq!(queue.live_depth(), 1);
        queue.set_live_depth(99);
        assert_eq!(queue.live_depth(), 4);
    }

    #[test]
    fn the_submit_reports_the_empty_queue_the_arrival_gate_cannot_recover_afterwards() {
        let mut queue = PresentQueue::new(1, 4, 1);
        assert!(queue.submit(frame(1)).was_empty);
        assert!(!queue.submit(frame(2)).was_empty);
    }

    #[test]
    fn the_submit_names_the_handle_the_hard_cap_evicted() {
        let mut queue = PresentQueue::new(1, 2, 1);
        assert_eq!(queue.submit(frame(1)).evicted, None);
        assert_eq!(queue.submit(frame(2)).evicted, None, "still inside the cap");
        assert_eq!(
            queue.submit(frame(3)).evicted,
            Some(1),
            "or the caller holds that image forever",
        );
    }

    #[test]
    fn the_depth_cannot_be_configured_past_the_band_the_capacity_is_proved_against() {
        let queue = PresentQueue::new(999, 999, 1);
        assert_eq!(queue.live_depth(), MAX_QUEUE_DEPTH);
        let mut filled = PresentQueue::new(MAX_QUEUE_DEPTH, MAX_QUEUE_DEPTH, 1);
        for id in 1..=u64::from(MAX_QUEUE_DEPTH) + 4 {
            filled.submit(frame(id));
        }
        assert_eq!(
            filled.snapshot().len,
            QUEUE_CAPACITY,
            "the fullest legal queue still fits one crossing exactly",
        );
    }

    #[test]
    fn a_queue_survives_the_round_trip_through_its_own_snapshot() {
        let mut queue = PresentQueue::new(2, 6, 1);
        for id in 1..=4 {
            queue.submit(frame(id));
        }
        queue.step();
        queue.step();
        queue.step();
        let restored = PresentQueue::restored(&queue.snapshot());
        assert_eq!(restored, queue);
        let mut a = queue;
        let mut b = restored;
        a.submit(frame(9));
        b.submit(frame(9));
        assert_eq!(a.step(), b.step(), "and it keeps stepping the same afterwards");
    }

    /// Drives `frames` content frames through `queue` with `ticks` display ticks per frame, the
    /// frame landing `phase` ticks into its interval, and reports every present as
    /// `(handle, hold in ticks)` beside how many times the queue dropped back to priming.
    fn drive(queue: &mut PresentQueue, ticks: u32, frames: u64, phase: u32) -> (Vec<(u64, u32)>, u32) {
        let mut presents = Vec::new();
        let mut re_primes = 0;
        let mut submitted_at = std::collections::BTreeMap::new();
        let mut tick = 0u32;
        for handle in 1..=frames {
            for offset in 0..ticks {
                if offset == phase {
                    queue.submit(frame(handle));
                    submitted_at.insert(handle, tick);
                }
                match queue.step().outcome {
                    PresentOutcome::Present { frame, .. } => {
                        let landed = submitted_at.get(&frame.handle).copied().unwrap_or(tick);
                        presents.push((frame.handle, tick - landed));
                    },
                    PresentOutcome::Reshow { re_primed: true, .. } => re_primes += 1,
                    PresentOutcome::Reshow { .. }
                    | PresentOutcome::Priming { .. }
                    | PresentOutcome::Hold { .. } => {},
                }
                tick += 1;
            }
        }
        (presents, re_primes)
    }

    #[test]
    fn the_tick_ratio_is_floored_and_never_below_one() {
        assert_eq!(ticks_per_frame(120.0, 30.0), 4);
        assert_eq!(ticks_per_frame(120.0, 60.0), 2);
        assert_eq!(ticks_per_frame(60.0, 60.0), 1);
        assert_eq!(
            ticks_per_frame(120.0, 45.0),
            2,
            "rounding up would hand frames out slower than they arrive"
        );
        assert_eq!(ticks_per_frame(60.0, 120.0), 1, "a slow panel is lockstep");
        assert_eq!(ticks_per_frame(f64::NAN, 60.0), 1);
        assert_eq!(ticks_per_frame(120.0, 0.0), 1);
    }

    #[test]
    fn a_faster_tick_meters_the_slack_out_one_content_slot_at_a_time() {
        // A 120 Hz panel showing 30 fps content at depth two: four ticks per frame.
        let mut queue = PresentQueue::new(2, 6, 4);
        let (presents, re_primes) = drive(&mut queue, 4, 40, 1);
        assert_eq!(
            re_primes, 0,
            "the empty ticks between arrivals are not starvation"
        );
        let steady: Vec<(u64, u32)> = presents.iter().copied().skip(4).collect();
        assert_eq!(steady.len(), 35, "one present per content frame, none dropped");
        for pair in steady.windows(2) {
            if let [(earlier, _), (later, _)] = pair {
                assert_eq!(*later, earlier + 1, "in order, none skipped");
            }
        }
        for &(handle, hold) in &steady {
            assert!(
                (3..=5).contains(&hold),
                "frame {handle} held {hold} ticks: the slack is one content interval, give or take a tick",
            );
        }
    }

    #[test]
    fn presents_land_one_content_interval_apart_never_in_pairs() {
        let mut queue = PresentQueue::new(2, 6, 4);
        let mut present_ticks = Vec::new();
        let mut tick = 0u32;
        for handle in 1..=20 {
            for offset in 0..4 {
                if offset == 2 {
                    queue.submit(frame(handle));
                }
                if presented(queue.step()).is_some() {
                    present_ticks.push(tick);
                }
                tick += 1;
            }
        }
        for pair in present_ticks.windows(2) {
            if let [earlier, later] = pair {
                assert_eq!(
                    later - earlier,
                    4,
                    "a present every four ticks: {present_ticks:?}"
                );
            }
        }
    }

    #[test]
    fn a_missed_slot_counts_once_per_content_interval_not_once_per_tick() {
        let mut queue = PresentQueue::new(2, 6, 4);
        drive(&mut queue, 4, 8, 0);
        assert!(queue.primed());
        // The host goes quiet with one slack frame in hand: it fills the next slot, and the
        // re-prime then needs two EMPTY SLOTS — eight ticks — not two empty ticks, which at 120 Hz
        // is a frame merely 17 ms late at 30 fps.
        assert!(presented(queue.step()).is_some());
        let mut ticks_until_re_prime = 0;
        loop {
            ticks_until_re_prime += 1;
            if matches!(queue.step().outcome, PresentOutcome::Reshow {
                re_primed: true,
                ..
            }) {
                break;
            }
            assert!(ticks_until_re_prime < 64, "it must re-prime eventually");
        }
        assert_eq!(ticks_until_re_prime, 8);
    }

    #[test]
    fn a_late_frame_is_shown_at_the_next_slot_and_reads_as_a_transient_dip() {
        let mut queue = PresentQueue::new(2, 6, 4);
        drive(&mut queue, 4, 8, 0);
        // The queue holds one slack frame. Two empty slots would re-prime; one slot goes empty and
        // the next frame lands two ticks after it, before the slot that follows.
        let mut outcomes = Vec::new();
        for tick in 0..12 {
            if tick == 6 {
                queue.submit(frame(100));
                queue.submit(frame(101));
            }
            outcomes.push(queue.step().outcome);
        }
        assert!(
            matches!(outcomes.first(), Some(PresentOutcome::Present { .. })),
            "the slack frame fills the first slot",
        );
        assert!(
            matches!(
                outcomes.get(4),
                Some(PresentOutcome::Reshow { re_primed: false, .. })
            ),
            "the second slot is empty: {outcomes:?}",
        );
        assert!(
            matches!(
                outcomes.get(8),
                Some(PresentOutcome::Present {
                    transient_dip: true,
                    ..
                })
            ),
            "the late frame shows at the third slot as a dip: {outcomes:?}",
        );
        assert!(queue.primed(), "and nothing re-primed");
    }

    #[test]
    fn the_metering_never_holds_at_the_latency_floor() {
        // Depth one on a 120 Hz panel: a frame shows on the first tick after it lands, and a
        // present-on-arrival step between two ticks is never refused.
        let mut queue = PresentQueue::new(1, 6, 4);
        queue.submit(frame(1));
        assert_eq!(presented(queue.step()), Some(1));
        assert!(matches!(queue.step().outcome, PresentOutcome::Reshow { .. }));
        queue.submit(frame(2));
        assert_eq!(
            presented(queue.step()),
            Some(2),
            "the very next step, whatever the tick count"
        );
        queue.submit(frame(3));
        assert_eq!(
            presented(queue.step()),
            Some(3),
            "present-on-arrival's between-tick step"
        );
    }

    #[test]
    fn the_lockstep_law_never_holds() {
        // One tick per frame is the law before metering existed: a queue at depth two presents on
        // every tick it has a frame for, and a `Hold` never appears.
        let mut queue = PresentQueue::new(2, 6, 1);
        let (presents, re_primes) = drive(&mut queue, 1, 20, 0);
        assert_eq!(re_primes, 0);
        assert_eq!(presents.len(), 19);
        assert!(
            presents.iter().skip(1).all(|&(_, hold)| hold == 1),
            "{presents:?}"
        );
        queue.submit(frame(21));
        queue.submit(frame(22));
        assert_eq!(presented(queue.step()), Some(21));
        assert_eq!(
            presented(queue.step()),
            Some(22),
            "back to back, no hold between them"
        );
    }

    #[test]
    fn a_rebase_opens_the_slot_in_progress() {
        let mut queue = PresentQueue::new(2, 6, 4);
        drive(&mut queue, 4, 8, 0);
        assert!(presented(queue.step()).is_some(), "the slot after the drive");
        queue.submit(frame(50));
        assert!(matches!(queue.step().outcome, PresentOutcome::Hold { .. }));
        queue.set_ticks_per_frame(2);
        assert_eq!(queue.ticks_per_frame(), 2);
        assert!(
            presented(queue.step()).is_some(),
            "the new cadence starts now, not a slot later"
        );
    }
}
