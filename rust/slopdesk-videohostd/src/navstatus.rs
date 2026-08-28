//! The swipe-nav status push: one 4 Hz beat for the whole daemon, fanned out to every live session.
//!
//! `SwipeNavStatusGlue.swift`'s `SwipeNavStatusKicker`, which died with the Swift daemon.
//!
//! The client's peel-feedback mirror needs to know whether a swipe would translate and which
//! thresholds the host operates on (`docs/05` §8, `docs/20` §9.6). That answer changes when the
//! frontmost app changes and when the target navigates, neither of which the client can see, so the
//! host pushes it: a 6-byte datagram on the cursor channel, fire-and-forget.
//!
//! ## Daemon-level, not per-session
//! The frontmost app is ONE global truth shared by every lane — mirroring [`crate::feed`]'s own
//! kicker — and the accessibility read behind it is the expensive part. N sessions polling it
//! separately would pay N scans for one answer. Each session still decides its OWN message, because
//! a window-scoped pane is eligible only while its own app is frontmost; that decision is
//! [`SwipeNavHostConfig`]'s and is asked once per session per push.
//!
//! ## What it owns, and what it asks
//! It owns the CADENCE and nothing else: the thread, the 250 ms beat, the forced-every-eighth
//! heartbeat, and the change key. Every verdict — eligibility, the travel
//! threshold, the zeroing rule for an ineligible push — is [`SwipeNavHostConfig`]'s, which is why
//! no function here is named for the gesture it serves.
//!
//! ## Three costs this shape exists to avoid, each one measured before
//! * **The idle daemon.** With ZERO sessions a beat returns before the window-server query and the
//!   accessibility read. The idle daemon is the COMMON state and this loop otherwise runs for its
//!   whole life; a perf audit caught it paying 4 Hz polling for an audience of nobody.
//! * **The overlapping worker.** A cold scan can take ~200 ms, which is most of a beat. The Swift
//!   dispatched each beat onto a detached task and needed an explicit in-flight latch, because a
//!   later beat reaching the sessions before an earlier fan-out finished would show every lane
//!   NEW-then-OLD and leave it stale until the next heartbeat. ONE thread is that latch, and it is
//!   why the read is blocking here rather than dispatched: a beat cannot start until the last one
//!   has finished pushing.
//! * **The per-beat verify.** Only a forced beat may retry a pid whose last scan found no pair, or
//!   pay the toolbar-pair window-currency round trip. Verifying every beat cost 1–6 ms of live IPC
//!   at 4 Hz into Safari-family targets.
//!
//! ## The one thing the Swift had that this does not
//! An instant push on `NSWorkspace.didActivateApplicationNotification`. Nothing in the
//! `slopdesk-apple-*` family carries workspace notifications, and which crate would own them is a
//! `docs/57` §2 question rather than a convenience. What it costs is bounded and small: an
//! activation still lands on the next CHANGE beat, so the chip is at most one 250 ms beat late
//! rather than never. The heartbeat and the change detection are unaffected.

use core::fmt;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_video::injector_gates::SWIPE_NAV_TRACE_KEY;
use slopdesk_video::swipe_nav_config::{KEYS, NavHistoryFlags, SwipeNavHostConfig};

use crate::diag;
use crate::env::Overlay;
use crate::navhistory::NavHistoryReader;

/// The poll interval. Four a second, which is what a chip that must not lie about a link click can
/// afford to be stale by.
pub const BEAT: Duration = Duration::from_millis(250);

/// One beat in every this many is the FORCED beat: it pushes whether or not anything changed, and
/// it is the only beat allowed to retry an unknown pid or verify a held pair's window.
///
/// Eight beats is the ~2 s heartbeat, and it wears two hats: the loss self-heal for a
/// fire-and-forget UDP push, and the bootstrap for a session minted since the last change.
pub const FORCED_EVERY: u32 = 8;

/// The operating point, resolved through the settings overlay.
///
/// ONE resolution of the `SLOPDESK_SWIPE_NAV*` family, shared by the beat here and by the chord
/// [`crate::injector`] fires. Two would be exactly the drift
/// [`slopdesk_video::swipe_nav_config`]'s own note names: a chip promising a fire the host
/// swallows.
///
/// The key ORDER matters and is not restated — the names are looked up in
/// [`slopdesk_video::swipe_nav_config::KEYS`] by name, so a key resolved into the wrong slot is not
/// a thing this can do.
#[must_use]
pub fn operating_point(overlay: &Overlay) -> SwipeNavHostConfig {
    let values = overlay.resolve(&KEYS);
    let at = |key: &str| -> Option<&str> {
        KEYS.iter()
            .position(|name| *name == key)
            .and_then(|index| values.get(index))
            .and_then(Option::as_deref)
    };
    SwipeNavHostConfig::from_env(
        at("SLOPDESK_SWIPE_NAV"),
        at("SLOPDESK_SWIPE_NAV_APPS"),
        at("SLOPDESK_SWIPE_NAV_TRAVEL"),
        at("SLOPDESK_SWIPE_NAV_SLOW"),
        at("SLOPDESK_SWIPE_NAV_HISTORY"),
    )
}

/// Whether every CHANGE is traced.
///
/// The same switch the injector's per-gesture trace reads, because they are one question: an
/// operator turning the gesture trace on wants both halves of the gesture, and the push is the half
/// that shipped a freeze silently.
#[must_use]
pub fn traced(overlay: &Overlay) -> bool {
    overlay.get(SWIPE_NAV_TRACE_KEY).is_some()
}

/// Which app is in front, and what it is called.
///
/// A trait because the answer is a window-server query the suite cannot make, and because the probe
/// and the tests want to name a target rather than find one.
pub trait ReadsFrontmost: Send + Sync + fmt::Debug {
    /// The frontmost process id, or `None` when the window server has no answer.
    fn pid(&self) -> Option<i32>;

    /// A process's bundle identifier, or `None` for a process that has none.
    fn bundle_id(&self, pid: i32) -> Option<String>;
}

/// Where a push goes: every live session, each deciding its own message.
pub trait PushesStatus: Send + Sync + fmt::Debug {
    /// Whether anything would render the chip. `false` skips the whole beat.
    fn has_audience(&self) -> bool;

    /// Ships the status to every live session.
    fn push(
        &self,
        config: &SwipeNavHostConfig,
        frontmost_bundle_id: Option<&str>,
        history: Option<NavHistoryFlags>,
    );
}

/// A shared reader is a reader, and a shared sink is a sink — so the daemon can hold the same
/// registry the kicker pushes into. The forwarding [`crate::cursor`] and [`crate::windowgeometry`]
/// give their own traits, for the same reason.
impl<T: ReadsFrontmost + ?Sized> ReadsFrontmost for Arc<T> {
    fn pid(&self) -> Option<i32> {
        (**self).pid()
    }

    fn bundle_id(&self, pid: i32) -> Option<String> {
        (**self).bundle_id(pid)
    }
}

/// The same, for the sink.
impl<T: PushesStatus + ?Sized> PushesStatus for Arc<T> {
    fn has_audience(&self) -> bool {
        (**self).has_audience()
    }

    fn push(
        &self,
        config: &SwipeNavHostConfig,
        frontmost_bundle_id: Option<&str>,
        history: Option<NavHistoryFlags>,
    ) {
        (**self).push(config, frontmost_bundle_id, history);
    }
}

/// The real window server's answer.
///
/// Both calls are `slopdesk-apple-*`'s, so nothing here is `unsafe` and nothing here decides
/// anything. `slopdesk_apple_cgwindow::frontmost_pid` and NOT an `NSWorkspace` snapshot, and the
/// difference is a shipped bug: the Swift daemon's `NSWorkspace` view froze at first access — on
/// and off the main thread — so every heartbeat kept pushing the launch-time app's eligibility and
/// the chip never lit for the browser actually in front.
#[derive(Debug, Clone, Copy, Default)]
pub struct HostFrontmost;

impl ReadsFrontmost for HostFrontmost {
    fn pid(&self) -> Option<i32> {
        slopdesk_apple_cgwindow::frontmost_pid()
    }

    fn bundle_id(&self, pid: i32) -> Option<String> {
        slopdesk_apple_app::bundle_id(pid)
    }
}

/// What one beat found, as the string a change is detected on.
///
/// A rendered key rather than a tuple of fields, because it is also the trace line: the push path
/// is otherwise UNOBSERVABLE, and the `eligible=false` freeze above shipped silently precisely
/// because nothing logged what the heartbeat was saying.
#[must_use]
pub fn describe(
    frontmost_bundle_id: Option<&str>,
    eligible: bool,
    history: Option<NavHistoryFlags>,
) -> String {
    let reading = history.map_or_else(
        || "unknown".to_owned(),
        |flags| format!("back={} fwd={}", flags.can_go_back, flags.can_go_forward),
    );
    format!(
        "{} eligible={eligible} history={reading}",
        frontmost_bundle_id.unwrap_or("nil")
    )
}

/// Whether this beat is the forced one.
///
/// Beats are counted from one, so the first beat of each group of eight is the forced one — which
/// makes the kicker's very first beat a forced beat, and that is the bootstrap.
#[must_use]
pub const fn is_forced(beat: u32) -> bool {
    beat % FORCED_EVERY == 1
}

/// The change memory: what was last pushed, so an unforced beat can stay silent.
#[derive(Debug, Default)]
pub struct Beats {
    last: Mutex<Option<String>>,
}

impl Beats {
    /// An empty memory: the first beat always counts as a change.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores `key` and answers whether it differs from the last one stored.
    ///
    /// Stores even when the caller will not push, which is the point: a forced beat that ships an
    /// unchanged key must not leave the memory able to call the NEXT beat a change.
    pub fn changed(&self, key: &str) -> bool {
        let mut last = self.last.lock().unwrap_or_else(PoisonError::into_inner);
        let changed = last.as_deref() != Some(key);
        *last = Some(key.to_owned());
        changed
    }
}

/// Everything the beat thread shares with its owner.
#[derive(Debug)]
struct Shared<F, S>
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    /// The operating point, parsed once. There is no live reload; `just host-restart` is the
    /// reload.
    config: SwipeNavHostConfig,
    /// Whether every CHANGE is traced (`SLOPDESK_SWIPE_NAV_TRACE`).
    trace: bool,
    frontmost: F,
    sink: S,
    beats: Beats,
    stop: Mutex<bool>,
    wake: Condvar,
}

/// The daemon's status beat: one thread, one reader, one fan-out.
///
/// The thread ends on `Drop`, which JOINS it — a push racing the teardown of the sockets it fans
/// out to is the one failure this rules out entirely, the same reason [`crate::cursor`]'s sampler
/// joins.
#[derive(Debug)]
pub struct StatusKicker<F, S>
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    shared: Arc<Shared<F, S>>,
    thread: Option<JoinHandle<()>>,
}

impl<F, S> StatusKicker<F, S>
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    /// Starts the beat.
    #[must_use]
    pub fn start(config: SwipeNavHostConfig, trace: bool, frontmost: F, sink: S) -> Self {
        let shared = Arc::new(Shared {
            config,
            trace,
            frontmost,
            sink,
            beats: Beats::new(),
            stop: Mutex::new(false),
            wake: Condvar::new(),
        });
        let thread = {
            let shared = Arc::clone(&shared);
            thread::Builder::new()
                .name("slopdesk-navstatus".to_owned())
                .spawn(move || run(&shared))
                .ok()
        };
        Self { shared, thread }
    }

    /// Ends the beat thread and waits for it. Idempotent, and `Drop` calls it.
    pub fn stop(&mut self) {
        *self.shared.stop.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.shared.wake.notify_all();
        if let Some(thread) = self.thread.take() {
            drop(thread.join());
        }
    }
}

impl<F, S> Drop for StatusKicker<F, S>
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    fn drop(&mut self) {
        self.stop();
    }
}

/// One beat: read, decide, and fan out if anything is worth saying.
fn beat<F, S>(shared: &Shared<F, S>, history: &NavHistoryReader, forced: bool)
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    // Nobody can render the chip, so neither read is worth making. The change memory is left as it
    // is: a freshly minted session bootstraps off the ≤2 s forced beat exactly as it would anyway.
    if !shared.sink.has_audience() {
        return;
    }
    let pid = shared.frontmost.pid();
    let bundle_id = pid.and_then(|pid| shared.frontmost.bundle_id(pid));
    let eligible = shared.config.eligible(bundle_id.as_deref());
    // The accessibility read only runs for an ELIGIBLE frontmost: a dark chip needs no history, and
    // an ineligible push zeroes the bits anyway.
    let flags = if shared.config.history_gate
        && eligible
        && let Some(pid) = pid
    {
        history.read(pid, forced, forced)
    } else {
        None
    };
    let key = describe(bundle_id.as_deref(), eligible, flags);
    let changed = shared.beats.changed(&key);
    if !forced && !changed {
        return;
    }
    if shared.trace && changed {
        diag::say(&format!("swipe-nav status push → {key}"));
    }
    shared.sink.push(&shared.config, bundle_id.as_deref(), flags);
}

/// The cadence: beat, then wait one interval or until told to stop.
fn run<F, S>(shared: &Arc<Shared<F, S>>)
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    // The reader is built HERE and never leaves this thread. Its cached pair holds live
    // accessibility elements, which are Core Foundation objects and therefore neither `Send` nor
    // `Sync` — a field on `Shared` would need an `unsafe impl` this crate may not write. Nothing
    // wants a second caller anyway: the beat is the only reader, and the cache exists to make ITS
    // next beat cheap.
    let history = NavHistoryReader::new();
    let mut count = 0_u32;
    loop {
        if stopped(shared) {
            return;
        }
        count = count.saturating_add(1);
        beat(shared, &history, is_forced(count));
        if !wait_a_beat(shared) {
            return;
        }
    }
}

/// Whether a stop has been asked for.
fn stopped<F, S>(shared: &Shared<F, S>) -> bool
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    *shared.stop.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Waits one interval, or until [`StatusKicker::stop`] says otherwise. Answers whether to continue.
fn wait_a_beat<F, S>(shared: &Shared<F, S>) -> bool
where
    F: ReadsFrontmost + 'static,
    S: PushesStatus + 'static,
{
    let stop = shared.stop.lock().unwrap_or_else(PoisonError::into_inner);
    let (stop, _) = shared
        .wake
        .wait_timeout(stop, BEAT)
        .unwrap_or_else(PoisonError::into_inner);
    !*stop
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, PoisonError};

    use slopdesk_video::swipe_nav_config::{NavHistoryFlags, SwipeNavHostConfig};

    use super::{Beats, FORCED_EVERY, PushesStatus, ReadsFrontmost, StatusKicker, describe, is_forced};

    /// A frontmost that answers whatever the test set.
    #[derive(Debug, Default)]
    struct Named {
        bundle: Mutex<Option<String>>,
    }

    impl ReadsFrontmost for Named {
        fn pid(&self) -> Option<i32> {
            Some(i32::MAX)
        }

        fn bundle_id(&self, _pid: i32) -> Option<String> {
            self.bundle.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    /// A sink that records every push, and can claim to have nobody listening.
    #[derive(Debug)]
    struct Log {
        audience: Mutex<bool>,
        pushes: Mutex<Vec<String>>,
    }

    impl Log {
        fn new(audience: bool) -> Self {
            Self {
                audience: Mutex::new(audience),
                pushes: Mutex::new(Vec::new()),
            }
        }

        fn count(&self) -> usize {
            self.pushes.lock().unwrap_or_else(PoisonError::into_inner).len()
        }

        /// Waits for the beat thread to reach `want` pushes, or gives up.
        ///
        /// A deadline and not a sleep: the beat runs on a spawned thread, and a machine under load
        /// can take longer to start one than the 250 ms interval itself. An assertion timed off a
        /// sleep would be reading the machine's scheduler rather than the cadence under test.
        fn settle(&self, want: usize) -> bool {
            let deadline = std::time::Instant::now() + super::BEAT * 20;
            while std::time::Instant::now() < deadline {
                if self.count() >= want {
                    return true;
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            false
        }
    }

    impl PushesStatus for Log {
        fn has_audience(&self) -> bool {
            *self.audience.lock().unwrap_or_else(PoisonError::into_inner)
        }

        fn push(
            &self,
            _config: &SwipeNavHostConfig,
            frontmost_bundle_id: Option<&str>,
            _history: Option<NavHistoryFlags>,
        ) {
            self.pushes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(frontmost_bundle_id.unwrap_or("nil").to_owned());
        }
    }

    /// The first beat of each group of eight is forced, and the first beat of the kicker's life is
    /// one — which is what makes a client that connects before anything changes still see a status.
    #[test]
    fn the_first_beat_and_every_eighth_after_it_are_forced() {
        assert!(is_forced(1));
        for beat in 2..FORCED_EVERY {
            assert!(!is_forced(beat));
        }
        assert!(is_forced(FORCED_EVERY + 1));
    }

    /// A key is stored whether or not the caller pushes it, so a forced beat cannot make the next
    /// beat report a change that never happened.
    #[test]
    fn a_repeated_key_is_a_change_exactly_once() {
        let beats = Beats::new();
        assert!(beats.changed("a"));
        assert!(!beats.changed("a"));
        assert!(beats.changed("b"));
        assert!(!beats.changed("b"));
    }

    /// An unknown history reads as `unknown` rather than as a pair of falses, because the client
    /// fails OPEN on unknown and would dark the chip on a false pair.
    #[test]
    fn an_unknown_reading_is_named_apart_from_a_negative_one() {
        let negative = NavHistoryFlags {
            can_go_back: false,
            can_go_forward: false,
        };
        assert_ne!(
            describe(Some("com.apple.Safari"), true, None),
            describe(Some("com.apple.Safari"), true, Some(negative))
        );
    }

    /// With nobody listening the beat returns before the window-server query, so the idle daemon
    /// pays nothing. This is the perf-audit finding that shaped the whole loop.
    #[test]
    fn an_audience_of_nobody_costs_no_reads() {
        let sink = Arc::new(Log::new(false));
        let mut kicker = StatusKicker::start(
            SwipeNavHostConfig::default(),
            false,
            Arc::new(Named::default()),
            Arc::clone(&sink),
        );
        std::thread::sleep(super::BEAT * 2);
        kicker.stop();
        assert_eq!(sink.count(), 0);
    }

    /// A live audience gets the bootstrap push on the very first beat, without waiting for anything
    /// to change.
    #[test]
    fn a_live_audience_is_told_before_anything_changes() {
        let sink = Arc::new(Log::new(true));
        let mut kicker = StatusKicker::start(
            SwipeNavHostConfig::default(),
            false,
            Arc::new(Named::default()),
            Arc::clone(&sink),
        );
        assert!(sink.settle(1), "the bootstrap beat never pushed");
        kicker.stop();
    }
}
