//! The two lifecycles every lazily-spawned panel backend runs on — the port of
//! `Sources/SlopDeskHost/SupervisedServiceLifecycle.swift`.
//!
//! Neither type decides anything. The announce parse, the probe step, the adopt verdict and the
//! first-writer-wins rule are all `slopdesk_sidecars::service_lifecycle`'s already, and were before
//! this port started. What lands here is what the Swift had left: the mutex, the handle, the
//! bounded wait and the loopback connect.
//!
//! ## Two departures from the Swift, both about a lock
//!
//! **The announce record is on its own mutex, and the boot closure runs OUTSIDE the other one.**
//! The Swift held one `NSLock` across the whole round, boot included, and the boot for a panel
//! backend is `SupervisorClient::spawn` — a request that blocks until superd's reply arrives on the
//! client's single reader thread. That same reader thread delivers the child's log lines, and a log
//! line calls back in to record the port. One lock across both is a cycle: the round holds it and
//! waits for a reply, the reader waits for the lock to hand over a line, and the reply is behind
//! the line. It has a narrow window in Swift and none at all here.
//!
//! So the port and the version live behind [`Announced`], which is taken for a field write and
//! nothing else, and the child handle lives behind [`Live`], which is never held across a spawn.
//! The nesting is one-way — live → announced, never back.
//!
//! **A second round that arrives mid-boot reports `starting` rather than queueing behind it.** That
//! is the never-wait contract this type exists for, stated one level stronger: its callers sit on
//! per-session metadata queues answering an RPC with a five-second client-side deadline, and two
//! panes asking at once used to mean the second one waited out the first one's Node boot. A
//! `booting` latch is also what keeps them from spawning twins now that the spawn is unlocked.
//!
//! One consequence is a FIX rather than a trade. The announce slot goes live when the generation is
//! bumped, before the spawn rather than after it, so a line that arrives while the child is being
//! spawned is recorded instead of dropped. The Swift dropped it — `has_record` was false until the
//! `Instance` existed — and the path where that matters is the adopt: a survivor's ring replays
//! from offset 0 and hands back the announce line immediately, inside exactly that window.

use std::fmt;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use slopdesk_sidecars::service_lifecycle::{
    AdoptVerdict, ProbeRecord, ProbeStep, ServiceState, accepts_announcement, adopt_verdict, probe_step,
};

/// One live (or launching) supervised child.
///
/// The same three questions `HostServiceProcessHandle` asked, and a seam for the same reason: a
/// unit test must never spawn a real service, and a real one is a multi-second boot behind a
/// network listener.
pub trait ServiceHandle: Send + Sync + fmt::Debug {
    /// Whether the child is still alive. A `false` — a crash, an idle-timeout self-exit, superd
    /// going away — is the whole of crash recovery: the next round drops the record and boots one.
    fn is_running(&self) -> bool;

    /// Ends the service for good. Idempotent.
    ///
    /// The counterpart to [`ServiceHandle::relinquish`], and the line `docs/51` §5.5 draws for
    /// panes drawn identically here: this one means "this service is over", never "hostd is going
    /// away". A daemon shutdown must not call it.
    fn terminate(&self);

    /// Lets the service GO: hostd stops listening to it and superd keeps the child running.
    ///
    /// What a daemon shutdown calls. Before superd held these, a stop terminated them, so every
    /// host edit cost the user a Node reboot in the code panel.
    fn relinquish(&self);
}

/// Where, and whether, a service is listening — the answer one ensure round produces.
///
/// The port is meaningful only when the state is [`ServiceState::Ready`]; it rides along while
/// starting because it is the honest answer to "where will it be", and the caller gates on the
/// state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Endpoint {
    /// What the client is told.
    pub state: ServiceState,
    /// The learned port, or `0`.
    pub port: u16,
}

impl Endpoint {
    /// The endpoint of a service with no child this round.
    #[must_use]
    pub const fn nothing(state: ServiceState) -> Self {
        Self { state, port: 0 }
    }
}

/// Why a spawn did not produce a child.
///
/// One string, because every caller does the same thing with it: writes it to the log and reports
/// the panel state its own face decided a failed spawn means.
#[derive(Debug)]
pub struct SpawnFailed {
    /// What went wrong, in the words of whatever refused.
    pub reason: String,
}

impl fmt::Display for SpawnFailed {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.reason)
    }
}

impl std::error::Error for SpawnFailed {}

/// Where each line of a child's merged stdout/stderr goes — the port parse, and nothing else.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;

/// Reads a child's own announce line for the port it bound, or `None` for every other line.
pub type PortParser = Arc<dyn Fn(&str) -> Option<u16> + Send + Sync>;

/// Reads the crate version off the same line. Only the daemons in this repo print one.
pub type VersionParser = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Whether a TCP connect to `127.0.0.1:port` succeeds. Bounded, never hangs.
pub type ReadinessProbe = Arc<dyn Fn(u16) -> bool + Send + Sync>;

/// Finds the service's executable, or `None` when the host has none.
pub type BinaryLocator = Arc<dyn Fn() -> Option<String> + Send + Sync>;

/// Spawns the child and streams each line of its merged output to the sink.
pub type Spawner =
    Arc<dyn Fn(&str, &[String], LogSink) -> Result<Arc<dyn ServiceHandle>, SpawnFailed> + Send + Sync>;

// MARK: - The announce record

/// The two facts a child's own announce line carries, on the mutex the reader thread may take.
///
/// Separate from [`Live`] for the reason in this module's header: the thread that fills this in is
/// the one a boot is waiting on, so the two must never be one lock.
#[derive(Debug, Default)]
struct Announced {
    /// Which spawn this record belongs to. A dying child's last line carries the old one.
    generation: u64,
    /// Whether there is a record to write onto at all. Goes true when a boot begins.
    live: bool,
    /// Learned from the child's announce line; `None` until it prints one.
    port: Option<u16>,
    /// The crate version off the same line. `None` for a third-party backend that announces none,
    /// and for one that predates the field — both mean "unknown", never "current".
    version: Option<String>,
}

impl Announced {
    /// Opens a record for `generation`, discarding whatever the last child said.
    fn open(&mut self, generation: u64) {
        self.generation = generation;
        self.live = true;
        self.port = None;
        self.version = None;
    }

    /// Closes the record. Every later line is dropped until the next [`Announced::open`].
    fn close(&mut self) {
        self.live = false;
        self.port = None;
        self.version = None;
    }
}

// MARK: - The OS-picks-the-port lifecycle

/// What a face's boot closure answers.
#[derive(Debug)]
pub enum Boot {
    /// A child is up. The service takes the handle and reports `starting` — the port arrives later,
    /// on the child's own line.
    Spawned(Arc<dyn ServiceHandle>),
    /// No child this round, and the state to report instead. The faces disagree here on purpose: a
    /// spawn that FAILED is `unavailable` for the panel backends (a broken binary reads the same as
    /// an absent one) and `starting` for androidd (superd unreachable or a thread limit is
    /// transient, and the client's poll retries).
    NotYet(ServiceState),
}

/// One live child's handle and the two facts only a round may write.
#[derive(Debug)]
struct Instance {
    handle: Arc<dyn ServiceHandle>,
    /// Latched by the first successful probe — a listening server is never un-probed.
    ready: bool,
    last_probe: Option<Instant>,
}

/// The child, and whether a boot is in flight for one.
#[derive(Debug, Default)]
struct Live {
    instance: Option<Instance>,
    /// A boot is running on another thread, unlocked. It owns [`Live::spawn_generation`] and will
    /// install the instance; a second round must neither spawn a twin nor wait for it.
    booting: bool,
    /// Bumped per spawn. A stale child's log line (a respawn raced its last words) must not write
    /// its old port onto the fresh record.
    spawn_generation: u64,
}

/// The lifecycle of a sidecar whose port the OS picks: spawn once, learn the port from the child's
/// own line, probe until it answers, and report where it stands RIGHT NOW — never wait.
///
/// Crash recovery is implicit: a child that exited reads `is_running() == false` on the next round,
/// which drops the record and lets the face boot a fresh one.
pub struct ProbedPortService {
    live: Mutex<Live>,
    announced: Mutex<Announced>,
    probe: ReadinessProbe,
    probe_interval: Duration,
}

impl fmt::Debug for ProbedPortService {
    /// Written out rather than derived, because the probe is a bare closure and there is nothing to
    /// print about one. What a reader wants here is the state anyway.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProbedPortService")
            .field("live", &self.live)
            .field("announced", &self.announced)
            .field("probe_interval", &self.probe_interval)
            .finish_non_exhaustive()
    }
}

impl ProbedPortService {
    /// A service that probes `127.0.0.1:port` with `readiness_probe`, no oftener than
    /// `probe_interval`.
    #[must_use]
    pub fn new(readiness_probe: ReadinessProbe, probe_interval: Duration) -> Self {
        Self {
            live: Mutex::new(Live::default()),
            announced: Mutex::new(Announced::default()),
            probe: readiness_probe,
            probe_interval,
        }
    }

    /// The interval the Swift defaulted to, kept here so the two faces that never chose one do not
    /// each pick a number.
    pub const DEFAULT_PROBE_INTERVAL: Duration = Duration::from_millis(500);

    /// The whole round: report on the live child, or call `boot` to make one.
    ///
    /// `boot` runs with NO lock held and is handed the spawn generation to stamp its log sink with.
    /// A round that finds a boot already in flight answers `starting` and calls nothing.
    pub fn ensure<F>(&self, boot: F) -> Endpoint
    where
        F: FnOnce(u64) -> Boot,
    {
        let generation = match self.report_or_claim() {
            Ok(endpoint) => return endpoint,
            Err(claimed) => claimed,
        };
        let booted = boot(generation);
        self.install(booted)
    }

    /// The port the running child announced, once it has.
    #[must_use]
    pub fn served_port(&self) -> Option<u16> {
        self.announced.lock().map_or(None, |announced| announced.port)
    }

    /// The crate version the running child announced, or `None` when it announced none.
    #[must_use]
    pub fn announced_version(&self) -> Option<String> {
        self.announced
            .lock()
            .map_or(None, |announced| announced.version.clone())
    }

    /// The log sink to hand the spawner: it parses every line and records what it finds, unless a
    /// respawn has already superseded the generation that produced it.
    ///
    /// `parse_version` runs on the SAME line and is separate because the two facts have different
    /// availability: every backend here announces a port, only ours announces a version.
    ///
    /// The version is recorded BEFORE the port, and that ordering is load-bearing:
    /// [`ProbedPortService::served_port`] turning non-`None` is what a caller waits on, so a
    /// version that landed after it would be missed by anyone who audited on that signal.
    ///
    /// Weak on purpose — the service holds the handle that holds this closure.
    #[must_use]
    pub fn port_sink(
        self: &Arc<Self>,
        generation: u64,
        parse_version: Option<VersionParser>,
        parse: PortParser,
    ) -> LogSink {
        let service = Arc::downgrade(self);
        Arc::new(move |line: &str| {
            let Some(service) = Weak::upgrade(&service) else {
                return;
            };
            if let Some(parse_version) = parse_version.as_ref()
                && let Some(version) = parse_version(line)
            {
                service.record_version(&version, generation);
            }
            if let Some(port) = parse(line) {
                service.record_port(port, generation);
            }
        })
    }

    /// Drops the record and answers the handle, for the caller to end or release.
    ///
    /// A boot in flight is NOT cancelled — there is nothing to cancel it with — but the generation
    /// it carries is retired here, so the child it produces is installed against a closed record
    /// and the next round boots a fresh one. That is the same answer the Swift's `forget` gave
    /// a spawn that had already been superseded.
    pub fn forget(&self) -> Option<Arc<dyn ServiceHandle>> {
        let stranded = self.live.lock().ok().and_then(|mut live| {
            live.spawn_generation = live.spawn_generation.wrapping_add(1);
            live.instance.take()
        });
        if let Ok(mut announced) = self.announced.lock() {
            announced.close();
        }
        stranded.map(|instance| instance.handle)
    }

    // MARK: Internals

    /// The endpoint of the live child, or the generation this round claimed for a boot.
    fn report_or_claim(&self) -> Result<Endpoint, u64> {
        let Ok(mut live) = self.live.lock() else {
            // A poisoned lock means another round panicked mid-mutation. Reporting `starting` is
            // the honest answer and lets the client keep polling; booting into it would spawn on
            // top of state nobody can read.
            return Ok(Endpoint::nothing(ServiceState::Starting));
        };
        if let Some(endpoint) = self.live_endpoint(&mut live) {
            return Ok(endpoint);
        }
        if live.booting {
            // Never-wait: the round that claimed the generation is spawning, and this one is on a
            // metadata queue with a deadline. `starting` is exactly true.
            return Ok(Endpoint::nothing(ServiceState::Starting));
        }
        live.spawn_generation = live.spawn_generation.wrapping_add(1);
        live.booting = true;
        let generation = live.spawn_generation;
        drop(live);
        // Opened BEFORE the spawn, which is the one thing the Swift could not do: an adopt replays
        // the survivor's ring from offset 0 and hands the announce line back immediately.
        if let Ok(mut announced) = self.announced.lock() {
            announced.open(generation);
        }
        Err(generation)
    }

    /// Files whatever the boot produced, and answers the round's endpoint.
    fn install(&self, booted: Boot) -> Endpoint {
        let Ok(mut live) = self.live.lock() else {
            return Endpoint::nothing(ServiceState::Starting);
        };
        live.booting = false;
        match booted {
            Boot::Spawned(handle) => {
                live.instance = Some(Instance {
                    handle,
                    ready: false,
                    last_probe: None,
                });
                Endpoint::nothing(ServiceState::Starting)
            },
            Boot::NotYet(state) => {
                // Deliberately no record: a boot that did not produce a child must leave nothing
                // behind, so the next round tries again rather than observing a phantom. The
                // announce slot closes with it, or a line from the child that never was would be
                // written onto the next one.
                live.instance = None;
                drop(live);
                if let Ok(mut announced) = self.announced.lock() {
                    announced.close();
                }
                Endpoint::nothing(state)
            },
        }
    }

    /// The endpoint of the LIVE child, or `None` when there is none to report on — the caller's cue
    /// to boot. Caller holds `live`.
    ///
    /// The whole round is `probe_step`; what happens here is the three things it cannot do: forget
    /// an exited child, make the loopback connect, and stamp the record with when that connect ran.
    ///
    /// The connect runs under the lock, as it did in the Swift. It is bounded at a quarter second
    /// and it is the same loopback the caller's own round would have made, so moving it out would
    /// buy a re-validation of the record for nothing.
    fn live_endpoint(&self, live: &mut Live) -> Option<Endpoint> {
        let port = self.announced.lock().map_or(None, |announced| announced.port);
        let instance = live.instance.as_mut()?;
        let record = ProbeRecord {
            port,
            since_probe: instance.last_probe.map(elapsed_nanos),
            ready: instance.ready,
            running: instance.handle.is_running(),
        };
        match probe_step(Some(record), nanos(self.probe_interval), None) {
            ProbeStep::Boot => {
                live.instance = None;
                if let Ok(mut announced) = self.announced.lock() {
                    announced.close();
                }
                None
            },
            ProbeStep::Report { state, port } => Some(Endpoint { state, port }),
            ProbeStep::Probe { port } => {
                let answered = (self.probe)(port);
                instance.last_probe = Some(Instant::now());
                instance.ready = answered;
                match probe_step(Some(record), nanos(self.probe_interval), Some(answered)) {
                    ProbeStep::Report { state, port } => Some(Endpoint { state, port }),
                    // The rule answers `Report` for every input that reached a probe. The other two
                    // arms are unreachable rather than unhandled, and `starting` keeps the client
                    // polling if the rule ever grows a third answer.
                    ProbeStep::Boot | ProbeStep::Probe { .. } => {
                        Some(Endpoint::nothing(ServiceState::Starting))
                    },
                }
            },
        }
    }

    fn record_port(&self, port: u16, generation: u64) {
        if let Ok(mut announced) = self.announced.lock()
            && accepts_announcement(
                generation,
                announced.generation,
                announced.live,
                announced.port.is_some(),
            )
        {
            announced.port = Some(port);
        }
    }

    /// Same first-writer-wins rule as [`ProbedPortService::record_port`], for the same reason: the
    /// child announces once, and a later line that happened to contain the marker is not a new
    /// fact.
    fn record_version(&self, version: &str, generation: u64) {
        if let Ok(mut announced) = self.announced.lock()
            && accepts_announcement(
                generation,
                announced.generation,
                announced.live,
                announced.version.is_some(),
            )
        {
            announced.version = Some(version.to_owned());
        }
    }
}

// MARK: - The hostd-picks-the-port lifecycle

/// The port and version of a daemon hostd chose the port for, plus what it takes to wait for them.
#[derive(Debug, Default)]
struct Chosen {
    port: Option<u16>,
    version: Option<String>,
}

/// The lifecycle of a sidecar whose port hostd CHOOSES.
///
/// Spawn — or adopt a survivor — wait a bounded while for the child's announce line, and verify
/// that what it announced is the port this hostd advertises, respawning it when it is not.
///
/// The waiting is the difference from [`ProbedPortService`], and it is affordable for exactly one
/// reason: these run on hostd's STARTUP path, where there is no RPC deadline to miss, and the port
/// they serve goes into a metadata answer that must be right the first time. There is no readiness
/// probe here for the same reason — a daemon that printed its announce line has bound.
///
/// ## Why the port is VERIFIED after an adopt
/// The pane id is stable (`service:<name>`, `docs/51` §1) but the port is not: a hostd started on a
/// different `--port` wants a different sidecar port, and the survivor is on the old one. Adopting
/// it would leave hostd advertising a port nothing listens on, which fails with no log line to say
/// why. The comparison is `adopt_verdict`; the terminate and the relaunch are here.
pub struct AnnouncedPortService {
    spawn: Spawner,
    locate_binary: BinaryLocator,
    parse_port: PortParser,
    parse_version: Option<VersionParser>,
    announce_timeout: Duration,
    handle: Mutex<Option<Arc<dyn ServiceHandle>>>,
    chosen: Mutex<Chosen>,
    announced: Condvar,
}

impl fmt::Debug for AnnouncedPortService {
    /// Written out for the reason [`ProbedPortService`]'s is: four of the seven fields are bare
    /// closures.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AnnouncedPortService")
            .field("handle", &self.handle)
            .field("chosen", &self.chosen)
            .field("announce_timeout", &self.announce_timeout)
            .finish_non_exhaustive()
    }
}

impl AnnouncedPortService {
    /// The timeout the Swift defaulted to: long enough for a daemon to bind and print, short enough
    /// that hostd's startup does not stall on one that never will.
    pub const DEFAULT_ANNOUNCE_TIMEOUT: Duration = Duration::from_secs(3);

    /// A service that spawns through `spawner` and reads its port off the child's own line.
    ///
    /// `parse_announced_version` is optional because only the daemons in this repo print a version.
    #[must_use]
    pub fn new(
        spawner: Spawner,
        binary_locator: BinaryLocator,
        parse_announced_port: PortParser,
        parse_announced_version: Option<VersionParser>,
        announce_timeout: Duration,
    ) -> Self {
        Self {
            spawn: spawner,
            locate_binary: binary_locator,
            parse_port: parse_announced_port,
            parse_version: parse_announced_version,
            announce_timeout,
            handle: Mutex::new(None),
            chosen: Mutex::new(Chosen::default()),
            announced: Condvar::new(),
        }
    }

    /// Brings the daemon up on `port`, adopting a survivor when there is one.
    ///
    /// Answers the port actually being served, or `None` when there is no binary, superd is
    /// unreachable, or the child never announced. A `None` is NOT fatal to hostd: it logs and
    /// serves the other paths, exactly as a failed bind always did.
    ///
    /// The loop is bounded by the rule rather than by a count spelled here — `Respawn` is only ever
    /// answered for the first attempt, so the second round can end in `Adopt` or `GiveUp` and
    /// nothing else.
    pub fn start(self: &Arc<Self>, port: u16, arguments: &[String]) -> Option<u16> {
        let binary = (self.locate_binary)()?;
        let mut attempt = 0_u32;
        loop {
            let started = self.launch(&binary, arguments).ok()?;
            let announced = self.await_announced_port();
            match adopt_verdict(attempt, announced, port) {
                AdoptVerdict::Adopt => return announced,
                AdoptVerdict::Respawn => {
                    // Either it never spoke, or it is the survivor of a hostd that wanted a
                    // different port. Both are answered the same way: end it and start one on the
                    // port this hostd advertises.
                    started.terminate();
                    self.clear_announcement();
                    attempt = attempt.saturating_add(1);
                },
                AdoptVerdict::GiveUp => {
                    started.terminate();
                    return None;
                },
            }
        }
    }

    /// Lets the daemon GO: hostd stops listening to its log and superd keeps it, with everything it
    /// had in flight. What a daemon SHUTDOWN calls.
    pub fn relinquish(&self) {
        if let Some(stranded) = self.forget() {
            stranded.relinquish();
        }
    }

    /// Ends the daemon for good. Only a deliberate stop may call it.
    pub fn shutdown(&self) {
        if let Some(stranded) = self.forget() {
            stranded.terminate();
        }
    }

    /// The port the running daemon announced, once it has.
    #[must_use]
    pub fn served_port(&self) -> Option<u16> {
        self.chosen.lock().map_or(None, |chosen| chosen.port)
    }

    /// The crate version the running daemon announced, or `None` when it announced none.
    #[must_use]
    pub fn announced_version(&self) -> Option<String> {
        self.chosen.lock().map_or(None, |chosen| chosen.version.clone())
    }

    // MARK: Internals

    fn forget(&self) -> Option<Arc<dyn ServiceHandle>> {
        let stranded = self.handle.lock().ok().and_then(|mut handle| handle.take());
        self.clear_announcement();
        stranded
    }

    fn launch(
        self: &Arc<Self>,
        binary: &str,
        arguments: &[String],
    ) -> Result<Arc<dyn ServiceHandle>, SpawnFailed> {
        let service = Arc::downgrade(self);
        let parse = Arc::clone(&self.parse_port);
        let version = self.parse_version.clone();
        let sink: LogSink = Arc::new(move |line: &str| {
            let Some(service) = Weak::upgrade(&service) else {
                return;
            };
            // Before the port, for the reason `ProbedPortService::port_sink` gives: `served_port` is
            // what the wait below is on, so anything learned after it is missed.
            if let Some(version) = version.as_ref()
                && let Some(announced) = version(line)
            {
                service.record_version(&announced);
            }
            if let Some(port) = parse(line) {
                service.record_port(port);
            }
        });
        let started = (self.spawn)(binary, arguments, sink)?;
        if let Ok(mut handle) = self.handle.lock() {
            *handle = Some(Arc::clone(&started));
        }
        Ok(started)
    }

    /// The announced port, waiting up to the timeout for it.
    ///
    /// A condvar rather than the Swift's twenty-millisecond sleep loop. Same bound, no polling, and
    /// a port that arrives in the first millisecond is answered in the first millisecond.
    fn await_announced_port(&self) -> Option<u16> {
        let Ok(chosen) = self.chosen.lock() else {
            return None;
        };
        self.announced
            .wait_timeout_while(chosen, self.announce_timeout, |chosen| chosen.port.is_none())
            .map_or(None, |(chosen, _timed_out)| chosen.port)
    }

    fn record_port(&self, port: u16) {
        if let Ok(mut chosen) = self.chosen.lock() {
            chosen.port = Some(port);
        }
        self.announced.notify_all();
    }

    fn record_version(&self, version: &str) {
        if let Ok(mut chosen) = self.chosen.lock() {
            chosen.version = Some(version.to_owned());
        }
    }

    fn clear_announcement(&self) {
        if let Ok(mut chosen) = self.chosen.lock() {
            chosen.port = None;
            chosen.version = None;
        }
    }
}

/// `duration` in nanoseconds, saturating — the rule takes a `u64` and no interval anyone configures
/// is five centuries long.
fn nanos(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

/// How long ago `stamp` was, in nanoseconds.
fn elapsed_nanos(stamp: Instant) -> u64 {
    nanos(stamp.elapsed())
}
