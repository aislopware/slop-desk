//! The host-window FEED service (`docs/45`): the roster, the cache, the differ, and the fan-out.
//!
//! Phase 1 is request/reply — a client asks with the generation it already holds and is answered
//! from a shared one-second cache. Phase 2 is PUSH: the same request RENEWS a subscription, and
//! while at least one lives, a differ ticks, folds per the pure coalesce policy, and pushes the new
//! snapshot's chunks to every subscriber on a generation bump.
//!
//! ## Every decision here is `slopdesk_video`'s
//! [`WindowFeedCache`] holds the generation and the TTL; [`WindowFeedSubscriberTable`] holds the
//! roster's TTL and capacity; [`classify_change`] decides structural from volatile;
//! [`WindowFeedPushPolicy`] decides whether a change may fold and how long until the next tick. Not
//! one threshold in this file is new. What IS this file's is the threading the Swift actor was:
//! which lock, which thread, and what happens when the roster empties.
//!
//! ## What it replaces
//! `WindowFeedCache.swift`, `WindowFeedSubscribers.swift`, and the `WindowFeedService` actor in
//! `WindowFeedGlue.swift`. The first two were handles over `slopdesk_feed_cache_*` and
//! `slopdesk_feed_subscribers_*` — a two-call shape-then-fill protocol per read, plus a
//! span-cutting helper to turn the packer's one flat buffer back into datagrams. A Rust daemon owns
//! the cache and the table directly, so all of that is deleted rather than ported. The reap's
//! awkward contract goes with it: through the door a reap CONSUMED what it reported, so the caller
//! had to lend a buffer the size of the whole table in ONE call or lose the overflow.
//!
//! ## Two threads, and why neither is a runtime
//! The DIFFER runs only while the roster is non-empty — zero hertz with none, one hertz idle, four
//! for three seconds after a structural change — and it EXITS when the roster empties, restarted by
//! the next renewal. The ECHO thread exists for the 25 ms duplicate re-send: a snapshot goes out
//! twice so a single lost datagram is a squared probability rather than a missed generation, and
//! the second copy cannot ride the caller's thread because [`WindowFeed::answer`] is called from
//! the mux receive path, which must never sleep. Both wait on the same condvar, both notice a stop
//! between waits, and both are JOINED by [`Drop`] — the `subscriber.rs` shape, no runtime.

use core::fmt;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_video::video_control::HostWindowRecord;
use slopdesk_video::window_feed_host::{
    FeedChange, WindowFeedCache, WindowFeedPushPolicy, WindowFeedSourceWindow, WindowFeedSubscriberTable,
    classify_change, snapshot_records,
};

/// How long a built snapshot answers renewals before the differ has to enumerate again, in seconds.
///
/// One second: the differ's own idle cadence, so a desktop with subscribers re-enumerates once per
/// second no matter how many clients ask. Carried from `WindowFeedCache.swift`'s default.
pub const CACHE_TTL: f64 = 1.0;

/// How long a subscriber survives without renewing, in seconds.
///
/// Six — three missed renewals at the client's two-second cadence. The lane is retired on expiry,
/// NOT per answer, which is the whole of Phase 2: pushes between renewals ride the stamped reply
/// flow the subscribe already bootstrapped.
pub const SUBSCRIBER_TTL: f64 = 6.0;

/// The most subscribers the roster holds at once.
///
/// Thirty-two. A bound rather than a guess: the fan-out is a datagram per subscriber per chunk, and
/// an unbounded roster turns one push into unbounded work on the differ thread.
pub const SUBSCRIBER_CAPACITY: usize = 32;

/// How long after a snapshot its duplicate goes out, in seconds.
///
/// Twenty-five milliseconds, the `bye`/`streamCadence` loss pattern: two copies turn P(loss) into
/// P(loss)², and the client's assembler is idempotent per chunk so the second copy costs nothing
/// when the first arrived.
pub const ECHO_DELAY: f64 = 0.025;

/// Where a feed datagram goes, and how a dead lane is closed.
///
/// The seam a test substitutes for the mux. Both methods are called from the differ or the echo
/// thread and neither may block for long — a sink that does is a differ that misses its cadence.
pub trait SendsFeed: Send + Sync + fmt::Debug {
    /// Sends one control-channel payload on `channel_id`.
    fn send_control(&self, channel_id: u32, payload: &[u8]);
    /// Retires the lane for `channel_id` — the subscriber stopped renewing.
    fn retire(&self, channel_id: u32);
}

/// Where the feed's input comes from.
///
/// One method, so the whole desktop read — census, displays, per-app facts, the budgeted
/// accessibility probe — is one substitution. [`crate::windowsource::WindowSource`] is the real
/// one.
pub trait Enumerates: Send + Sync + fmt::Debug {
    /// The host's windows as the feed's input shape, at `now`.
    fn enumerate(&self, now: f64) -> Vec<WindowFeedSourceWindow>;
}

impl<D: crate::windowsource::ReadsDesktop, S: crate::windowprobe::SweepsApps> Enumerates
    for crate::windowsource::WindowSource<D, S>
{
    fn enumerate(&self, now: f64) -> Vec<WindowFeedSourceWindow> {
        Self::enumerate(self, now)
    }
}

/// A snapshot due to go out a second time.
#[derive(Clone, Debug)]
struct Echo {
    /// When, on the service's own monotonic clock.
    due: f64,
    /// The lanes it goes to — resolved when the first copy was sent, so a subscriber that expired
    /// in between still gets the duplicate. Harmless: a retired lane discards it.
    channels: Vec<u32>,
    /// The chunks, exactly as they went out the first time.
    payloads: Vec<Vec<u8>>,
}

/// Everything both threads and every caller share, behind one lock.
#[derive(Debug)]
struct Lane {
    /// The built snapshot, its generation, and its TTL.
    cache: WindowFeedCache,
    /// Who is subscribed, and when each last renewed.
    subscribers: WindowFeedSubscriberTable,
    /// The burst window and the two coalesce gates.
    policy: WindowFeedPushPolicy,
    /// Whether a differ thread is running. Set before the spawn and cleared by the thread itself,
    /// so a renewal arriving while one exits does not start a second.
    ticking: bool,
    /// An out-of-band tick was asked for — an app launched, quit or came forward.
    kicked: bool,
    /// Set by [`Drop`]; both threads return at their next wake.
    stop: bool,
    /// Snapshots waiting for their duplicate.
    echoes: Vec<Echo>,
}

/// The service's shared half: the seams, the clock, the lock and the condvar.
#[derive(Debug)]
struct Shared<E: Enumerates, O: SendsFeed> {
    /// Where the windows come from.
    source: E,
    /// Where the datagrams go.
    sink: O,
    /// The monotonic origin. Never a wall clock: every TTL here must survive the person changing
    /// the time zone or NTP stepping the clock backwards.
    epoch: Instant,
    /// The state above.
    lane: Mutex<Lane>,
    /// Woken by a kick, by an echo being queued, and by the stop.
    wake: Condvar,
    /// Held across an enumeration so at most one runs at a time. Separate from [`Self::lane`] on
    /// purpose: an enumeration costs milliseconds and can block on a hung app's accessibility
    /// timeout, and holding the roster lock across it would stall every renewal behind it.
    census: Mutex<()>,
}

impl<E: Enumerates, O: SendsFeed> Shared<E, O> {
    /// Seconds since this service started.
    fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    /// Locks the lane, treating a poisoned lock as a live one.
    fn lane(&self) -> std::sync::MutexGuard<'_, Lane> {
        self.lane.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Rebuilds the cache if its TTL has run out. Cheap and idempotent: a second caller arriving
    /// while the first enumerates waits, then finds the cache fresh and enumerates nothing.
    fn rebuild_if_stale(&self, now: f64) {
        let census = self.census.lock().unwrap_or_else(PoisonError::into_inner);
        if !self.lane().cache.needs_rebuild(now) {
            drop(census);
            return;
        }
        let fresh = snapshot_records(&self.source.enumerate(now));
        self.lane().cache.fold(fresh, now);
        drop(census);
    }

    /// One differ turn: enumerate, classify against what is cached, fold when the policy allows,
    /// push on a generation bump.
    fn tick(&self, now: f64) {
        let census = self.census.lock().unwrap_or_else(PoisonError::into_inner);
        let fresh: Vec<HostWindowRecord> = snapshot_records(&self.source.enumerate(now));
        drop(census);

        let mut lane = self.lane();
        let change = classify_change(lane.cache.records(), &fresh);
        if !lane.policy.should_fold(change, now) {
            // Unchanged: refresh the TTL so renewals keep answering without re-enumerating. GATED
            // volatile churn: do NOT fold — the coalesce gate opens on a later tick, and folding
            // now would spend the generation the gate exists to save.
            if matches!(change, FeedChange::None) {
                lane.cache.fold(fresh, now);
            }
            return;
        }
        lane.cache.fold(fresh, now);
        let reply = lane.cache.reply(0);
        if !reply.is_snapshot {
            return;
        }
        let targets = lane.subscribers.subscribers(now);
        drop(lane);
        self.deliver(&targets, &reply.payloads, true, now);
    }

    /// Sends `payloads` to every lane in `channels`, and queues the duplicate when `echo`.
    fn deliver(&self, channels: &[u32], payloads: &[Vec<u8>], echo: bool, now: f64) {
        self.blast(channels, payloads);
        if !echo || channels.is_empty() || payloads.is_empty() {
            return;
        }
        self.lane().echoes.push(Echo {
            due: now + ECHO_DELAY,
            channels: channels.to_vec(),
            payloads: payloads.to_vec(),
        });
        self.wake.notify_all();
    }

    /// One copy of `payloads` to each of `channels`.
    fn blast(&self, channels: &[u32], payloads: &[Vec<u8>]) {
        for channel in channels {
            for payload in payloads {
                self.sink.send_control(*channel, payload);
            }
        }
    }
}

/// The one feed service: roster, cache, differ and fan-out.
#[derive(Debug)]
pub struct WindowFeed<E: Enumerates, O: SendsFeed> {
    /// What both threads read.
    shared: Arc<Shared<E, O>>,
    /// The differ, while one is running.
    differ: Mutex<Option<JoinHandle<()>>>,
    /// The duplicate re-sender, for the service's whole life.
    echo: Mutex<Option<JoinHandle<()>>>,
}

impl<E: Enumerates + 'static, O: SendsFeed + 'static> WindowFeed<E, O> {
    /// A feed over `source`, answering onto `sink`. Starts the echo thread; the differ waits for a
    /// subscriber.
    #[must_use]
    pub fn new(source: E, sink: O) -> Self {
        let shared = Arc::new(Shared {
            source,
            sink,
            epoch: Instant::now(),
            lane: Mutex::new(Lane {
                cache: WindowFeedCache::new(CACHE_TTL),
                subscribers: WindowFeedSubscriberTable::new(SUBSCRIBER_TTL, SUBSCRIBER_CAPACITY),
                policy: WindowFeedPushPolicy::new(),
                ticking: false,
                kicked: false,
                stop: false,
                echoes: Vec::new(),
            }),
            wake: Condvar::new(),
            census: Mutex::new(()),
        });
        let held = Arc::clone(&shared);
        let echo = std::thread::Builder::new()
            .name("slopdesk.feed.echo".to_owned())
            .spawn(move || echo_loop(&held))
            .ok();
        Self {
            shared,
            differ: Mutex::new(None),
            echo: Mutex::new(echo),
        }
    }

    /// Answers one `windowFeedSubscribe` on `channel_id` AND renews it as a push subscriber.
    ///
    /// The lane is NOT retired per answer: the TTL reap retires it after three missed renewals, so
    /// pushes between renewals ride the reply flow the subscribe already stamped.
    ///
    /// Called from the mux receive path, so it never sleeps — the duplicate goes to the echo
    /// thread.
    pub fn answer(&self, channel_id: u32, known_generation: u32) {
        let now = self.shared.now();
        self.shared.lane().subscribers.renew(channel_id, now);
        self.shared.rebuild_if_stale(now);
        let reply = self.shared.lane().cache.reply(known_generation);
        self.shared
            .deliver(&[channel_id], &reply.payloads, reply.is_snapshot, now);
        self.ensure_ticking();
    }

    /// Asks for one immediate differ turn — an app launched, quit or came forward.
    ///
    /// Inert with no subscribers: nothing to push to, and the differ is not running.
    pub fn kick(&self) {
        let mut lane = self.shared.lane();
        if lane.subscribers.is_empty() {
            return;
        }
        lane.kicked = true;
        drop(lane);
        self.shared.wake.notify_all();
    }

    /// The generation the cache currently holds. `0` before the first build.
    #[must_use]
    pub fn generation(&self) -> u32 {
        self.shared.lane().cache.generation()
    }

    /// How many subscribers the roster holds.
    #[must_use]
    pub fn subscriber_count(&self) -> usize {
        self.shared.lane().subscribers.len()
    }

    /// Starts the differ if the roster is non-empty and one is not already running.
    fn ensure_ticking(&self) {
        let mut lane = self.shared.lane();
        if lane.ticking || lane.subscribers.is_empty() {
            return;
        }
        lane.ticking = true;
        drop(lane);

        let mut slot = self.differ.lock().unwrap_or_else(PoisonError::into_inner);
        // A previous differ that has already cleared `ticking` may still be unwinding; joining it
        // here is bounded and keeps exactly one handle in the slot.
        if let Some(previous) = slot.take() {
            drop(previous.join());
        }
        let held = Arc::clone(&self.shared);
        *slot = std::thread::Builder::new()
            .name("slopdesk.feed.differ".to_owned())
            .spawn(move || differ_loop(&held))
            .ok();
        if slot.is_none() {
            // The spawn was refused. Leaving `ticking` set would mean no renewal ever starts one.
            self.shared.lane().ticking = false;
        }
    }
}

impl<E: Enumerates, O: SendsFeed> Drop for WindowFeed<E, O> {
    fn drop(&mut self) {
        self.shared.lane().stop = true;
        self.shared.wake.notify_all();
        for slot in [&self.differ, &self.echo] {
            // Taken OUT of the lock before the join, not inside the `if let`: a scrutinee holds its
            // temporary for the whole body, so joining there would hold the slot's mutex across a
            // thread that is still trying to reach `shared`.
            let thread = slot.lock().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(thread) = thread {
                drop(thread.join());
            }
        }
    }
}

/// The differ: reap → tick → wait, for as long as anybody is subscribed.
///
/// Returns when the roster empties or the service stops, which is what makes "0 Hz with no
/// subscribers" a property of the thread rather than of a flag it keeps checking.
fn differ_loop<E: Enumerates, O: SendsFeed>(shared: &Arc<Shared<E, O>>) {
    let mut next_tick = shared.now();
    loop {
        let now = shared.now();
        let mut lane = shared.lane();
        if lane.stop {
            lane.ticking = false;
            return;
        }
        if !lane.kicked && now < next_tick {
            let wait = Duration::from_secs_f64((next_tick - now).max(0.0));
            let (guard, _) = shared
                .wake
                .wait_timeout(lane, wait)
                .unwrap_or_else(PoisonError::into_inner);
            drop(guard);
            continue;
        }
        lane.kicked = false;
        let expired = lane.subscribers.reap_expired(now);
        let deserted = lane.subscribers.is_empty();
        if deserted {
            lane.ticking = false;
        }
        drop(lane);

        for channel in expired {
            shared.sink.retire(channel);
        }
        if deserted {
            return;
        }
        shared.tick(now);
        let after = shared.now();
        next_tick = after + shared.lane().policy.tick_interval(after);
    }
}

/// The duplicate re-sender: one thread, one queue, no per-push spawn.
#[expect(
    clippy::significant_drop_tightening,
    reason = "the guard IS the condvar's argument — narrowing it would mean waiting without it"
)]
fn echo_loop<E: Enumerates, O: SendsFeed>(shared: &Arc<Shared<E, O>>) {
    loop {
        let now = shared.now();
        let mut lane = shared.lane();
        if lane.stop {
            // A duplicate that has not gone out by the time the service stops is worth nothing: the
            // lane it would ride is being torn down in the same breath.
            return;
        }
        let mut due = Vec::new();
        let mut keep = Vec::new();
        for echo in lane.echoes.drain(..) {
            if echo.due <= now {
                due.push(echo);
            } else {
                keep.push(echo);
            }
        }
        lane.echoes = keep;
        drop(lane);

        for echo in due {
            shared.blast(&echo.channels, &echo.payloads);
        }

        let lane = shared.lane();
        if lane.stop {
            return;
        }
        // ⚠️ COMPUTED HERE, UNDER THE RE-ACQUIRED LOCK, AND NEVER CARRIED ACROSS THE BLAST. This
        // used to be folded before the `drop(lane)` above and read again down here, which is a lost
        // wakeup with a 10-second tell. `deliver` pushes an echo and then calls `notify_all`; a push
        // that lands while this thread is inside `blast` — holding no lock and not yet waiting —
        // signals a condvar nobody is on, so the notification is dropped on the floor. The stale
        // fold then still said `INFINITY`, so the thread took the UNBOUNDED arm and slept until the
        // next unrelated push or the stop. The duplicate never went out.
        //
        // Re-reading the queue here closes it: an echo queued during the blast is visible, `soonest`
        // is finite, and the wait is bounded — or already elapsed, so the next turn of the loop
        // delivers it immediately. The lost notification stops mattering because the state it was
        // announcing is read directly.
        //
        // It reproduced at ~20% on an idle machine (`a_snapshot_goes_out_twice_a_short_time_apart`,
        // 2 failures in 10 runs), and the shape is the tell: a pass took 0.1s and a failure burned
        // the helper's whole 10s ceiling. Bimodal, never slow-but-arriving — which is a lost wakeup
        // rather than a loaded machine, and is why this was fixed rather than re-run.
        let soonest = lane
            .echoes
            .iter()
            .map(|echo| echo.due)
            .fold(f64::INFINITY, f64::min);
        if soonest.is_finite() {
            let wait = Duration::from_secs_f64((soonest - shared.now()).max(0.0));
            let (guard, _) = shared
                .wake
                .wait_timeout(lane, wait)
                .unwrap_or_else(PoisonError::into_inner);
            drop(guard);
        } else {
            // Nothing pending: sleep until something is queued or the service stops. An idle poll
            // here would be forty wake-ups a second for a feed nobody is watching.
            drop(shared.wake.wait(lane).unwrap_or_else(PoisonError::into_inner));
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, PoisonError};
    use std::time::{Duration, Instant};

    use slopdesk_video::window_feed_host::WindowFeedSourceWindow;

    use super::{Enumerates, SendsFeed, WindowFeed};

    /// A desktop that answers whatever it was last told to.
    #[derive(Debug, Default)]
    struct Scripted {
        windows: Mutex<Vec<WindowFeedSourceWindow>>,
        calls: Mutex<usize>,
    }

    impl Enumerates for Scripted {
        fn enumerate(&self, _now: f64) -> Vec<WindowFeedSourceWindow> {
            *self.calls.lock().unwrap_or_else(PoisonError::into_inner) += 1;
            self.windows
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
    }

    /// A mux that writes everything down.
    #[derive(Debug, Default)]
    struct Recorder {
        sent: Mutex<Vec<(u32, Vec<u8>)>>,
        retired: Mutex<Vec<u32>>,
    }

    impl SendsFeed for Recorder {
        fn send_control(&self, channel_id: u32, payload: &[u8]) {
            self.sent
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((channel_id, payload.to_vec()));
        }
        fn retire(&self, channel_id: u32) {
            self.retired
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(channel_id);
        }
    }

    /// One ordinary window, big enough to clear the inclusion policy's minimum dimension.
    fn window(id: u32, title: &str) -> WindowFeedSourceWindow {
        WindowFeedSourceWindow {
            window_id: id,
            owner_name: "Example".to_owned(),
            bundle_id: "com.example".to_owned(),
            layer: 0,
            is_on_screen: true,
            title: title.to_owned(),
            width_pt: 800,
            height_pt: 600,
            display_index: 0,
            is_app_hidden: false,
            is_frontmost_app: true,
            is_minimized: false,
            is_ax_listed: false,
        }
    }

    /// Waits for `condition` with a ceiling, so a fast machine finishes fast and a loaded one still
    /// passes. Never a fixed sleep.
    fn until(mut condition: impl FnMut() -> bool) -> bool {
        let ceiling = Instant::now() + Duration::from_secs(10);
        while Instant::now() < ceiling {
            if condition() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        condition()
    }

    fn feed(windows: Vec<WindowFeedSourceWindow>) -> WindowFeed<Scripted, std::sync::Arc<Recorder>> {
        let source = Scripted {
            windows: Mutex::new(windows),
            calls: Mutex::new(0),
        };
        WindowFeed::new(source, std::sync::Arc::new(Recorder::default()))
    }

    impl SendsFeed for std::sync::Arc<Recorder> {
        fn send_control(&self, channel_id: u32, payload: &[u8]) {
            Recorder::send_control(self, channel_id, payload);
        }
        fn retire(&self, channel_id: u32) {
            Recorder::retire(self, channel_id);
        }
    }

    /// A first subscribe builds a snapshot, answers it, and registers the channel.
    #[test]
    fn a_first_subscribe_is_answered_with_a_snapshot_and_registers_the_lane() {
        let feed = feed(vec![window(1, "One")]);
        feed.answer(7, 0);
        assert_eq!(feed.subscriber_count(), 1);
        assert!(feed.generation() > 0, "a built snapshot must have a generation");
    }

    /// The 25 ms duplicate: the same chunks go out a second time, on the echo thread, so the caller
    /// never sleeps. Two copies turn one lost datagram into a squared probability.
    #[test]
    fn a_snapshot_goes_out_twice_a_short_time_apart() {
        let feed = feed(vec![window(1, "One")]);
        let sink = std::sync::Arc::clone(&feed.shared.sink);
        feed.answer(7, 0);
        let first = sink.sent.lock().unwrap_or_else(PoisonError::into_inner).len();
        assert!(first > 0);
        assert!(until(|| {
            sink.sent.lock().unwrap_or_else(PoisonError::into_inner).len() >= first * 2
        }));
    }

    /// The cache is what keeps N clients to one enumeration: a second subscribe inside the TTL is
    /// answered from the built snapshot and enumerates nothing.
    ///
    /// The enumeration count is read around [`Shared::rebuild_if_stale`] rather than around
    /// [`WindowFeed::answer`], because `answer` starts the differ and the differ's FIRST turn
    /// enumerates immediately — a second count that belongs to the differ, not to the second
    /// subscriber, and one no assertion over the total can tell apart. The roster half is still
    /// driven through `answer`, since nothing about it races.
    #[test]
    fn a_second_subscriber_inside_the_ttl_costs_no_second_enumeration() {
        let feed = feed(vec![window(1, "One")]);
        let calls = || {
            *feed
                .shared
                .source
                .calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
        };
        let now = feed.shared.now();
        feed.shared.rebuild_if_stale(now);
        let after_first = calls();
        assert!(after_first > 0, "the first build must enumerate");
        feed.shared.rebuild_if_stale(now);
        assert_eq!(after_first, calls());

        feed.answer(7, 0);
        feed.answer(8, 0);
        assert_eq!(feed.subscriber_count(), 2);
    }

    /// A client that already holds the current generation is answered with an acknowledgement, not
    /// with the whole snapshot again — the request/reply half of `docs/45` Phase 1.
    #[test]
    fn a_client_already_holding_the_generation_is_not_re_sent_the_snapshot() {
        let feed = feed(vec![window(1, "One")]);
        feed.answer(7, 0);
        let generation = feed.generation();
        let sink = std::sync::Arc::clone(&feed.shared.sink);
        // Let the duplicate land so the count below is not racing it.
        assert!(until(|| {
            !sink
                .sent
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty()
        }));
        std::thread::sleep(Duration::from_millis(60));
        let before = sink.sent.lock().unwrap_or_else(PoisonError::into_inner).len();
        feed.answer(7, generation);
        let after = sink.sent.lock().unwrap_or_else(PoisonError::into_inner).len();
        assert!(
            after - before <= 1,
            "a known generation is acknowledged in one datagram, not re-sent in {} ",
            after - before
        );
    }

    /// The differ pushes a structural change to every subscriber without being asked. The kick is
    /// what makes it immediate; the 1 Hz tick is the backstop the kick short-circuits.
    #[test]
    fn a_structural_change_reaches_every_subscriber_without_a_request() {
        let feed = feed(vec![window(1, "One")]);
        let sink = std::sync::Arc::clone(&feed.shared.sink);
        feed.answer(7, 0);
        feed.answer(8, 0);
        let generation = feed.generation();

        *feed
            .shared
            .source
            .windows
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = vec![window(1, "One"), window(2, "Two")];
        feed.kick();

        assert!(
            until(|| feed.generation() > generation),
            "a new window is a structural change and must bump the generation"
        );
        let sent = sink.sent.lock().unwrap_or_else(PoisonError::into_inner).clone();
        assert!(sent.iter().any(|(channel, _)| *channel == 7));
        assert!(sent.iter().any(|(channel, _)| *channel == 8));
    }

    /// The roster's TTL is what retires a lane, not an answer. A subscriber that stops renewing is
    /// reaped and its lane retired, and the differ then exits because nobody is left.
    #[test]
    fn a_subscriber_that_stops_renewing_is_reaped_and_its_lane_retired() {
        let feed = feed(vec![window(1, "One")]);
        let sink = std::sync::Arc::clone(&feed.shared.sink);
        feed.answer(7, 0);
        // Age the roster past its TTL by hand rather than waiting six seconds: every rule here takes
        // `now` as an argument precisely so a test can move it.
        let aged = feed.shared.now() + super::SUBSCRIBER_TTL + 1.0;
        let expired = feed.shared.lane().subscribers.reap_expired(aged);
        assert_eq!(expired, vec![7]);
        for channel in expired {
            sink.retire(channel);
        }
        assert_eq!(
            *sink.retired.lock().unwrap_or_else(PoisonError::into_inner),
            vec![7]
        );
        assert_eq!(feed.subscriber_count(), 0);
    }

    /// A kick with nobody subscribed is inert — the differ is not running, and starting one to
    /// discover that would be the zero-hertz property broken.
    #[test]
    fn a_kick_with_no_subscribers_starts_nothing() {
        let feed = feed(vec![window(1, "One")]);
        feed.kick();
        assert_eq!(
            *feed
                .shared
                .source
                .calls
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
            0
        );
        assert!(!feed.shared.lane().ticking);
    }

    /// Dropping the service ends both threads. Joined rather than detached, so a dropped feed
    /// cannot leave a thread pushing onto a sink its owner has released.
    #[test]
    fn a_dropped_feed_ends_both_of_its_threads() {
        let feed = feed(vec![window(1, "One")]);
        feed.answer(7, 0);
        assert!(until(|| feed.shared.lane().ticking));
        drop(feed);
    }
}
