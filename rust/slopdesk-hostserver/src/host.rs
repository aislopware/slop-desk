//! The live [`ControlHost`]: hostd's pane tables, as the eleven agent-control verbs see them.
//!
//! D.5 ported the verbs and left this trait abstract on purpose — `list_panes`, `spawn_standalone`,
//! `kill_pane` and the cross-pane status fan-out are `HostServer`'s adoption and observer tables,
//! which `docs/60` names as D.6's. This module is that half, composed out of what the earlier
//! stages already hold: [`Sessions`](crate::sessions::Sessions) is D.1's registry,
//! [`DetachedStore`](crate::detached::DetachedStore) is D.1's retention, and one pane is
//! [`crate::live::LivePane`] over `slopdesk-hostsession`.
//!
//! ## The three sources, and why the store is one of them
//!
//! `list-panes` answers out of THREE disjoint tables: the mux panes, the standalone control panes,
//! and the DETACHED ones. The third is the surprising one and it is not optional — a detached
//! pane's shell is still running, with no client attached, which is tmux's semantics and this
//! product's. Omitting it made a pane that survived a client quit invisible to the one "describe
//! every pane" API there is, and that is precisely the pane an orchestrator reattaching to a
//! machine is looking for. Disjoint because the detach unregisters before it inserts and the claim
//! removes before the reattach re-registers, so a pane is never in two at once and the
//! concatenation needs no dedupe.
//!
//! ## One lock, and the direction it nests
//!
//! The registry's lock is taken here and the store's is taken inside the store. The nesting is
//! ONE-WAY — registry then store, never the reverse — which is why the pane list is read out of the
//! registry under the lock, the lock is dropped, and only then is the store asked. The Swift
//! carried the same rule as a comment; here it is the shape of the function.
//!
//! ## Two things happen OUTSIDE the lock, and one of them is a fan-out
//!
//! Every status transition is published to whoever subscribed with a top-level `subscribe`, and the
//! subscriber's reaction is an NDJSON write. So the tap table is SNAPSHOTTED under its own lock and
//! the taps are called after it is released: one slow subscriber must not serialise the next pane's
//! transition. The other is the teardown fan — see [`Host::fan_teardown`], which is the whole
//! reason a `kill` is more than a `shutdown`.

use core::fmt;
use std::collections::BTreeMap;
use std::io::Read as _;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};
use slopdesk_agent::ClaudeStatus;
use slopdesk_agent::supervision::SupervisionState;
use slopdesk_hostsession::{SessionObserver, StatusObserver, TapToken};
use slopdesk_ids::{parse_uuid, uuid_text};
use slopdesk_muxsession::registry::Uuid;
use slopdesk_muxsession::spawn_env::{self, Exports};

use crate::control::{AgentStatusEvent, AgentStatusTap, ControlHost, PaneRecord, SpawnRefused};
use crate::detached::{Claim, DetachedStore};
use crate::pane::Pane;
use crate::sessions::Sessions;

/// The grid a pane reports when its PTY will not answer — the same `0 × 0` the Swift wrote.
///
/// Zero rather than the 24×80 fallback `screen` uses, and the difference is deliberate: a renderer
/// needs SOME grid to draw into, while a pane list is describing what is, and `0` is the honest
/// description of a master that is gone.
const NO_GRID: (u16, u16) = (0, 0);

/// Where a fresh pane id comes from.
///
/// A seam for `slopdesk_ids::IdSource`'s reason, restated one layer down: the id is entropy,
/// entropy is the RUNTIME's, and a suite that had to accept a different pane id every run could not
/// assert what a `spawn` answered. `slopdesk-ids` refuses to mint for exactly this, so the mint
/// lands where the runtime is.
pub trait SessionIds: Send + Sync + fmt::Debug {
    /// Sixteen fresh bytes, or `None` when the system would not supply them.
    fn mint(&self) -> Option<Uuid>;
}

/// `/dev/urandom`, shaped into a version-4 UUID.
///
/// Read rather than pulled from a crate: this is the only randomness anywhere in the tree, sixteen
/// bytes of it per spawned pane, and a dependency whose whole job is one `read(2)` earns less than
/// it costs. `None` on any failure — a pane id that is not random is worse than a refused `spawn`,
/// because it is a JOIN KEY and a collision points a reattach at the wrong conversation.
#[derive(Debug, Clone, Copy)]
pub struct SystemIds;

impl SessionIds for SystemIds {
    fn mint(&self) -> Option<Uuid> {
        let mut raw = [0_u8; 16];
        let mut source = std::fs::File::open("/dev/urandom").ok()?;
        source.read_exact(&mut raw).ok()?;
        // Version 4, variant RFC 4122 — the shape every reader of this id already expects, and what
        // Swift's `UUID()` wrote into every persisted file on disk.
        *raw.get_mut(6)? = (raw.get(6)? & 0x0F) | 0x40;
        *raw.get_mut(8)? = (raw.get(8)? & 0x3F) | 0x80;
        Some(raw)
    }
}

/// Where a killed pane's saved scrollback goes.
///
/// A seam rather than a call because the transcript store is still Swift's — the journal is its own
/// port. Named here anyway, because the DELETE has to happen on the detached branches of a `kill`
/// and a `kill` that silently kept a dead pane's transcript is not something a later stage would
/// notice was missing.
pub trait Transcripts: Send + Sync + fmt::Debug {
    /// Forgets everything saved for `session`.
    fn delete(&self, session: Uuid);
}

/// A transcript store that keeps nothing, so has nothing to forget.
#[derive(Debug, Clone, Copy)]
pub struct NoTranscripts;

impl Transcripts for NoTranscripts {
    fn delete(&self, _session: Uuid) {}
}

/// What every ctl-spawned pane's environment is built from, before the request adds to it.
///
/// Read off the host ONCE, at construction, rather than per spawn: `PATH`, `SHELL` and the terminfo
/// pair are hostd's own environment, and a pane forked an hour apart from another must not differ
/// because something `setenv`'d in between.
#[derive(Debug, Clone, Default)]
pub struct HostEnv {
    /// hostd's own environment — the allowlist source. See [`spawn_env::curated`].
    pub parent: BTreeMap<String, String>,
    /// The `TERM` the probe resolved: the ghostty entry, or the `xterm-256color` fallback.
    pub term: String,
    /// The marketing version, which is `make release`'s to write and never this crate's to mint.
    pub version: String,
    /// The login shell a `cmd`-less spawn execs.
    pub shell: String,
    /// Where an installed hook relay POSTs, when this host claimed that listener.
    pub agent_socket_path: Option<String>,
    /// The ctl socket, when this host claimed THAT listener.
    pub control_socket_path: Option<String>,
    /// Where `slopdesk-ctl` is, when the launch recorded it.
    pub ctl_binary_path: Option<String>,
}

/// One standalone spawn, fully resolved — every decision made, nothing forked yet.
///
/// The split is the point. Everything in this struct is a choice [`Host`] made from the request and
/// its own configuration, and all of it is assertable without a PTY; what is left for [`Spawner`]
/// is the fork, the session and its threads.
#[derive(Debug)]
pub struct Standalone<'a> {
    /// The conversation this pane will be known by.
    pub session: Uuid,
    /// The absolute executable `posix_spawn` runs. No `PATH` search happens downstream.
    pub executable: String,
    /// Its arguments, `argv[0]` excluded.
    pub argv: Vec<String>,
    /// The `argv[0]` it sees — a login shell's leading-dash form, or a command's basename.
    pub argv0: String,
    /// The child's whole environment.
    pub env: BTreeMap<String, String>,
    /// The directory to start in, or `None` to inherit hostd's.
    pub cwd: Option<&'a str>,
    /// The initial grid.
    pub rows: u16,
    /// See [`Standalone::rows`].
    pub cols: u16,
    /// Whether superd lays the OSC-133 shim over this child's shell.
    pub shell_integration: bool,
    /// Whether superd segments this pane into command blocks.
    pub blocks: bool,
    /// Who hears the child's exit.
    pub exit: Arc<dyn SessionObserver>,
    /// Who hears the agent inside it move.
    pub status: Arc<dyn StatusObserver>,
}

/// What turns a resolved [`Standalone`] into a running pane.
///
/// Two calls rather than one, because the host has to file the pane BETWEEN them: the Swift's order
/// is spawn → insert → register the hook route → start the relay, and an insert that arrives after
/// the first output byte is a pane that dropped its own opening.
pub trait Spawner: Send + Sync + fmt::Debug {
    /// Forks the child and builds its session — everything up to, but not including, its threads.
    ///
    /// # Errors
    /// [`SpawnRefused`] carries why no pane was made: a `cwd` that is not a directory, a superd
    /// that would not fork, an executable that is not there.
    fn spawn(&self, request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused>;

    /// Starts the pane's threads, and seeds its project truth from the spawn directory.
    ///
    /// The seed rides here rather than in [`Spawner::spawn`] for the reason the mux path seeds at
    /// the same point: a ctl-spawned pane is often a raw command with no shell integration at all,
    /// so the `cd` that would otherwise derive its By-Project key never happens, and a later
    /// reattach would file it under nothing.
    fn start(&self, pane: &Arc<dyn Pane>, cwd: Option<&str>);
}

/// hostd's pane tables, as [`ControlHost`].
#[derive(Debug)]
pub struct Host {
    sessions: Mutex<Sessions>,
    detached: Option<Arc<DetachedStore>>,
    spawner: Arc<dyn Spawner>,
    ids: Arc<dyn SessionIds>,
    transcripts: Arc<dyn Transcripts>,
    env: HostEnv,
    blocks_enabled: bool,
    stopping: AtomicBool,
    /// The cross-pane subscribers, and the counter that names them.
    ///
    /// A `Vec` of pairs rather than a map: the table holds a handful of entries at most — one per
    /// live top-level `subscribe` — and a fan-out walks all of them every time, which is the
    /// operation a map would not make faster.
    taps: Mutex<Vec<(u64, Arc<dyn AgentStatusTap>)>>,
    next_tap: AtomicU64,
    me: Weak<Self>,
}

impl Host {
    /// A host over an empty registry.
    ///
    /// `Arc::new_cyclic` because the pane observers this hands to [`Spawner`] have to be able to
    /// reach back — an exit has to unfile its own pane, and a status transition has to fan out —
    /// and a strong edge in that direction would keep the host alive for as long as one pane does.
    #[must_use]
    pub fn new(
        spawner: Arc<dyn Spawner>,
        detached: Option<Arc<DetachedStore>>,
        env: HostEnv,
        blocks_enabled: bool,
    ) -> Arc<Self> {
        Self::with(
            spawner,
            detached,
            env,
            blocks_enabled,
            Arc::new(SystemIds),
            Arc::new(NoTranscripts),
        )
    }

    /// The same, with the two seams named — the shape a suite builds.
    #[must_use]
    pub fn with(
        spawner: Arc<dyn Spawner>,
        detached: Option<Arc<DetachedStore>>,
        env: HostEnv,
        blocks_enabled: bool,
        ids: Arc<dyn SessionIds>,
        transcripts: Arc<dyn Transcripts>,
    ) -> Arc<Self> {
        Arc::new_cyclic(|me| {
            Self {
                sessions: Mutex::new(Sessions::new()),
                detached,
                spawner,
                ids,
                transcripts,
                env,
                blocks_enabled,
                stopping: AtomicBool::new(false),
                taps: Mutex::new(Vec::new()),
                next_tap: AtomicU64::new(1),
                me: me.clone(),
            }
        })
    }

    /// The registry, for the composition around this one — the channel ladders are D.6's other half
    /// and they attach and detach through the SAME table these verbs read.
    pub fn sessions(&self) -> MutexGuard<'_, Sessions> {
        self.sessions.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The detached store, when retention is on.
    #[must_use]
    pub const fn detached(&self) -> Option<&Arc<DetachedStore>> {
        self.detached.as_ref()
    }

    /// Refuses every further spawn. Idempotent, and there is no way back — a host stops once.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
    }

    /// Whether a `spawn` would be refused right now.
    #[must_use]
    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }

    // ------------------------------------------------------------------ the cross-pane fan-out

    /// Publishes one pane's transition to every top-level subscriber.
    ///
    /// Snapshot under the lock, call outside it — see the module doc. A host with no subscriber
    /// returns before it reads a clock or formats an id, which is the ordinary case: nobody is
    /// watching most of the time, and the poll that drives this runs once a second per pane.
    pub fn fan(&self, pane: &Arc<dyn Pane>, status: ClaudeStatus) {
        let taps = {
            let held = self.taps.lock().unwrap_or_else(PoisonError::into_inner);
            if held.is_empty() {
                return;
            }
            held.iter().map(|(_, tap)| Arc::clone(tap)).collect::<Vec<_>>()
        };
        let event = AgentStatusEvent {
            pane_id: uuid_text(pane.id()),
            state: String::from(SupervisionState::from_status(status).name()),
            agent_present: status != ClaudeStatus::None,
            title: pane.title(),
            // The one wall-clock read in this file, and it is a driver's: the stamp is a FACT about
            // when the transition was published, not an input to any decision. Every deciding
            // clock in the pane below is monotonic uptime.
            ts: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |since| i64::try_from(since.as_secs()).unwrap_or(i64::MAX)),
        };
        for tap in &taps {
            tap.changed(&event);
        }
    }

    /// Publishes a FINAL clearing transition for a pane torn down while it still carried an agent.
    ///
    /// The prevent-sleep strict balance, and it is not bookkeeping. A pane normally delivers its
    /// own `working → done` edge, but one closed MID-TURN — a tab closed, a child that died, a
    /// link that dropped, a ctl `kill` — never does. Without this fan the daemon's `.working`
    /// aggregate keeps that dead pane id for ever, the `IOPMAssertion` is never released, and
    /// the Mac stays awake for the rest of the process's life over a pane that no longer
    /// exists.
    ///
    /// Gated on [`Pane::agent_present`] so a plain shell that never had an agent stays silent.
    pub fn fan_teardown(&self, pane: &Arc<dyn Pane>) {
        if !pane.agent_present() {
            return;
        }
        self.fan(pane, ClaudeStatus::None);
    }

    /// Unfiles a standalone pane whose child has exited.
    ///
    /// The exit ladder's host half: drop it from the control table, retire its hook route with it —
    /// the exit closure will not find it in the table a moment later, so a key retired anywhere
    /// else leaks one per spawned pane for the daemon's life — and fan the final transition.
    pub fn retire_control(&self, session: Uuid) {
        let pane = {
            let mut sessions = self.sessions();
            let pane = sessions.detach_control(session);
            if let Some(ref pane) = pane {
                drop(sessions.unregister_hook(pane));
            }
            pane
        };
        if let Some(pane) = pane {
            self.fan_teardown(&pane);
        }
    }

    // ---------------------------------------------------------------------------- the readouts

    /// One pane as `list-panes` describes it.
    ///
    /// Each row costs one `TIOCGWINSZ` and one foreground probe — the same syscall class the input
    /// path already pays per keystroke batch, which is what makes an O(N) walk here affordable.
    fn record(pane: &Arc<dyn Pane>) -> PaneRecord {
        let (state, state_message) = pane.agent_status();
        let (rows, cols) = pane.window_size().unwrap_or(NO_GRID);
        PaneRecord {
            pane_id: uuid_text(pane.id()),
            title: pane.title(),
            pid: pane.pid(),
            is_alive: !pane.is_child_exited(),
            state,
            state_message,
            cwd: pane.cwd(),
            command: pane.foreground_name(),
            rows,
            cols,
            last_exit_code: pane.last_exit_code(),
        }
    }

    // ------------------------------------------------------------------------------- the spawn

    /// The environment, the executable and the argv one `spawn` request resolves to.
    ///
    /// Split out so the resolution is assertable on its own: this is where a `cmd` pane and a login
    /// shell part company, and the difference decides three things at once — what is exec'd, what
    /// `argv[0]` reads, and whether superd lays the shell-integration shim over it.
    fn resolve<'a>(&self, session: Uuid, cmd: Option<&'a [String]>, cwd: Option<&'a str>) -> Resolved {
        let pane_id = uuid_text(session);
        // A `cmd` pane is `exec`d directly and never sees a prompt, so the shim — which is prompt
        // machinery — is skipped. An empty `cmd` array is a caller asking for a shell in a clumsier
        // way, not a request to exec nothing.
        let shell_integration = cmd.is_none_or(<[String]>::is_empty);
        let mut env = spawn_env::curated(&self.env.parent, &self.env.term, &self.env.version, Exports {
            // Only when the listener is up: a pane told where to POST when nothing is listening
            // makes every hook a silent timeout instead of a silent no-op.
            agent_socket_path: self.env.agent_socket_path.as_deref(),
            // ALWAYS, unlike the socket above. The Swift set this twice — once through the
            // curated call and once after — because the two questions had been tangled: where to
            // POST is the listener's, but which pane this IS is the pane's own, and an agent
            // asking `slopdesk-ctl` about itself needs it whether or not a hook is installed.
            pane_id: Some(&pane_id),
            control_socket_path: self.env.control_socket_path.as_deref(),
            ctl_sentinel: true,
            ctl_binary_path: self.env.ctl_binary_path.as_deref(),
        });
        // The shell sources it, and a `cmd` child reads it as its own idea of where it is.
        if let Some(cwd) = cwd {
            env.insert(String::from("PWD"), cwd.to_owned());
        }
        match cmd {
            Some(cmd) if !cmd.is_empty() => {
                let executable = cmd.first().cloned().unwrap_or_default();
                Resolved {
                    argv0: basename(&executable),
                    argv: cmd.get(1..).unwrap_or_default().to_vec(),
                    executable,
                    env,
                    shell_integration,
                }
            },
            _ => {
                Resolved {
                    executable: self.env.shell.clone(),
                    argv: Vec::new(),
                    argv0: spawn_env::login_argv0(&self.env.shell),
                    env,
                    shell_integration,
                }
            },
        }
    }
}

/// [`Host::resolve`]'s answer.
#[derive(Debug)]
struct Resolved {
    executable: String,
    argv: Vec<String>,
    argv0: String,
    env: BTreeMap<String, String>,
    shell_integration: bool,
}

/// The last path component, which is what a spawned command's `argv[0]` reads as.
///
/// A trailing slash yields the empty string, which is what a caller that handed this a directory
/// deserves and still a valid argv entry — the exec fails on the path, which is the honest failure.
fn basename(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_owned()
}

/// The exit handler one standalone pane is given: unfile it, in the host that made it.
#[derive(Debug)]
struct Retire {
    host: Weak<Host>,
    session: Uuid,
}

impl SessionObserver for Retire {
    fn exited(&self, _code: i32) {
        if let Some(host) = self.host.upgrade() {
            host.retire_control(self.session);
        }
    }
}

/// The status handler one pane is given: fan its transitions cross-pane.
///
/// Holds the pane WEAKLY as well as the host. The pane owns the session that owns the detector that
/// calls this, so a strong edge back would be a cycle that outlives both.
#[derive(Debug)]
struct Fan {
    host: Weak<Host>,
    pane: Mutex<Weak<dyn Pane>>,
}

impl StatusObserver for Fan {
    fn status_changed(&self, status: ClaudeStatus, _quiet: bool) {
        let Some(host) = self.host.upgrade() else {
            return;
        };
        let held = self.pane.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(pane) = held.upgrade() {
            host.fan(&pane, status);
        }
    }
}

impl Fan {
    /// Points this handler at the pane it describes.
    ///
    /// Late, because the pane cannot exist before the session it wraps and the session cannot be
    /// built without this handler. The window between the two is the spawn itself, during which no
    /// fold can run — the pane's threads start after [`Spawner::start`].
    fn aim(&self, pane: &Arc<dyn Pane>) {
        *self.pane.lock().unwrap_or_else(PoisonError::into_inner) = Arc::downgrade(pane);
    }
}

impl ControlHost for Host {
    fn list_panes(&self) -> Vec<PaneRecord> {
        // Deduped by construction: one row per PANE, not one per attached client, which is what
        // `live_panes` and `control_panes` each already answer.
        let held = {
            let sessions = self.sessions();
            let mut held = sessions.live_panes();
            held.extend(sessions.control_panes());
            held
        };
        // The store takes its own lock, and the nesting is one-way — see the module doc. `None`
        // when retention is off: no store, nothing detached, nothing to add.
        let detached = self
            .detached
            .as_ref()
            .map(|store| store.all())
            .unwrap_or_default();
        held.iter().chain(detached.iter()).map(Self::record).collect()
    }

    fn lookup_pane(&self, pane_id: &str) -> Option<Arc<dyn Pane>> {
        let id = parse_uuid(pane_id)?;
        let sessions = self.sessions();
        // The channel panes first — the common case — then the standalone ones.
        sessions
            .pane_for_session(id)
            .or_else(|| sessions.control_pane(id))
            .map(Arc::clone)
    }

    fn spawn_standalone(
        &self,
        cmd: Option<&[String]>,
        cwd: Option<&str>,
        env: Option<&Map<String, Value>>,
        rows: u16,
        cols: u16,
    ) -> Result<String, SpawnRefused> {
        if self.is_stopping() {
            return Err(SpawnRefused(String::from("the host is stopping")));
        }
        let Some(session) = self.ids.mint() else {
            return Err(SpawnRefused(String::from("no entropy for a pane id")));
        };
        let mut resolved = self.resolve(session, cmd, cwd);
        // The caller's own variables go over the curated ones, and under nothing: a request that
        // named `SLOPDESK_PANE_ID` would be lying to its own agent about which pane it is, so the
        // three self-orientation keys are re-applied after this and cannot be displaced.
        if let Some(extra) = env {
            for (key, value) in extra {
                if let Some(text) = value.as_str() {
                    resolved.env.insert(key.clone(), text.to_owned());
                }
            }
            let pane_id = uuid_text(session);
            resolved
                .env
                .insert(String::from(spawn_env::AGENT_PANE_ID_KEY), pane_id);
            resolved
                .env
                .insert(String::from(spawn_env::CTL_SENTINEL_KEY), String::from("1"));
        }

        let fan = Arc::new(Fan {
            host: self.me.clone(),
            pane: Mutex::new(Weak::<crate::live::LivePane>::new()),
        });
        // Coerced through a named binding rather than an `as` at the call site, which is the
        // `trivial_casts` this crate denies. `Arc::<Fan>::clone` pins the SOURCE type so the
        // coercion is left to the annotation — the same turbofish the suite's fakes need.
        let status: Arc<dyn StatusObserver> = Arc::<Fan>::clone(&fan);
        let pane = self.spawner.spawn(&Standalone {
            session,
            executable: resolved.executable,
            argv: resolved.argv,
            argv0: resolved.argv0,
            env: resolved.env,
            cwd,
            rows,
            cols,
            shell_integration: resolved.shell_integration,
            // Blocks follow the server flag even with no GUI client — the ctl socket itself consumes
            // the segmentation, since `last-output` reads the block ring and `run --wait` resolves on
            // a block closing. AND the shim, matching the spawn: a `--cmd` pane has no prompt
            // machinery, so there are no OSC-133 marks to segment and a tap on it would report
            // nothing for the pane's whole life.
            blocks: self.blocks_enabled && resolved.shell_integration,
            exit: Arc::new(Retire {
                host: self.me.clone(),
                session,
            }),
            status,
        })?;
        fan.aim(&pane);

        {
            let mut sessions = self.sessions();
            // Checked AGAIN, under the lock that files it. The gate at the top of this function
            // refuses the common case cheaply; this one is the correct one — a `stop()` that landed
            // while the child was forking would otherwise file a pane into a table nobody will ever
            // drain, and `stop`'s own sweep has already run.
            if self.is_stopping() {
                drop(sessions);
                pane.shutdown();
                return Err(SpawnRefused(String::from("the host is stopping")));
            }
            sessions.attach_control(&pane);
            // Under the SAME acquisition as the insert, and after it: the route is advertised to the
            // child as `SLOPDESK_PANE_ID`, and a refused insert must leave no key behind to retire.
            sessions.register_hook(&pane, &uuid_text(session));
        }
        self.spawner.start(&pane, cwd);
        Ok(uuid_text(session))
    }

    fn kill_pane(&self, pane_id: &str) -> bool {
        let Some(id) = parse_uuid(pane_id) else {
            return false;
        };
        // The channel panes first. EVERY key naming the pane goes, not just the first match: under a
        // fan-out N keys alias one pane, and a survivor keeps the killed pane in `list-panes`, shut
        // again by the host's own stop, and read as attached by the rebind recovery.
        let mux = {
            let mut sessions = self.sessions();
            sessions
                .pane_for_session(id)
                .map(Arc::clone)
                .inspect(|pane| drop(sessions.reap(pane)))
        };
        if let Some(pane) = mux {
            self.fan_teardown(&pane);
            pane.shutdown();
            return true;
        }
        // Then the standalone ones.
        let control = {
            let mut sessions = self.sessions();
            let pane = sessions.detach_control(id);
            if let Some(ref pane) = pane {
                drop(sessions.unregister_hook(pane));
            }
            pane
        };
        if let Some(pane) = control {
            self.fan_teardown(&pane);
            pane.shutdown();
            return true;
        }
        // Then the DETACHED store — panes with no client attached right now.
        //
        // Two ways to be in there and ctl must be able to end either: a client that disconnected,
        // and a pane this host ADOPTED at start. The second is why this branch has to exist at all —
        // a survivor is parked from the moment the daemon comes up, so without it every pane that
        // outlived a restart was unkillable while being perfectly visible in `list-panes`.
        let Some(store) = self.detached.as_ref() else {
            return false;
        };
        match store.claim(id) {
            Claim::Claimed(pane) => {
                self.end_detached(&pane, id);
                pane.shutdown();
                true
            },
            // Already dead; the claim did the descriptor cleanup. The bookkeeping still runs and the
            // answer is still success — "kill this pane" asked for a state that now holds.
            //
            // The teardown fan is NOT optional here. A pane that died while detached may still carry
            // a `working` status and a prevent-sleep assertion nobody will ever clear, because its
            // exit closure is gated off by design. Skipping it leaves the row marked working in
            // every attached client and the Mac awake for the rest of the daemon's life.
            Claim::ReapedDeadChild(pane) => {
                self.end_detached(&pane, id);
                true
            },
            Claim::NotFound => false,
        }
    }

    fn add_status_tap(&self, tap: Arc<dyn AgentStatusTap>) -> TapToken {
        let key = self.next_tap.fetch_add(1, Ordering::SeqCst);
        self.taps
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((key, tap));
        TapToken::foreign(key)
    }

    fn remove_status_tap(&self, token: TapToken) {
        self.taps
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|(key, _)| TapToken::foreign(*key) != token);
    }
}

impl Host {
    /// The bookkeeping both detached-kill branches owe, in the one order they owe it.
    fn end_detached(&self, pane: &Arc<dyn Pane>, session: Uuid) {
        self.fan_teardown(pane);
        drop(self.sessions().unregister_hook(pane));
        self.transcripts.delete(session);
    }
}
