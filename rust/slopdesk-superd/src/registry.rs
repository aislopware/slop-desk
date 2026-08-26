//! What superd actually is: a map from pane id to a live child and the master fd nobody else may
//! be the last holder of.
//!
//! ## The one rule
//! **A master fd is closed on exactly two events: an explicit `release`, or the child being
//! reaped.** Never because a client went away, never because a connection dropped, never on
//! shutdown of anything. A PTY master is refcounted and the *last* close sends `SIGHUP` to the
//! foreground group — so "superd retains its own copy for the pane's whole life" is not
//! bookkeeping hygiene, it is the entire mechanism by which a `claude` survives a hostd restart.
//!
//! ## superd owns the READ side, and nothing else about the byte path
//! hostd still receives a duplicate of the master over `SCM_RIGHTS`, and still uses it for
//! everything a duplicate is good for: `write` for keystrokes, `TIOCSWINSZ` for resizes,
//! `tcgetpgrp` for the zero-config half of agent detection. Those were the two reasons the
//! full-relay design was rejected (`DECISIONS.md` 2026-08-11), and neither of them moved: no hop on
//! the keystroke path, no polled IPC for `tcgetpgrp`.
//!
//! What DID move is `read`, and only because of what the original ruling assumed away. It said the
//! kernel's PTY buffer would backpressure the writer across a restart gap, which is true, and then
//! called that acceptable, which it is not: a few KB in, the child blocks, and the `claude` superd
//! just saved from `SIGHUP` spends the whole restart frozen instead. So each pane now has a
//! [`crate::pump::Pump`] draining it for its entire life, into an offset-addressed
//! [`crate::ring::OutputRing`], and hostd subscribes to that stream instead of reading the fd. The
//! pane keeps working while nobody is home, and the returning hostd resumes from a byte offset.

// stderr IS superd's log — see `server.rs`. What gets narrated here is the one rule this module
// exists to hold: which event closed a master fd.
#![expect(clippy::print_stderr, reason = "stderr is superd's log; launchd captures it")]

use std::collections::{HashMap, HashSet, VecDeque};
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use nix::errno::Errno;
use nix::sys::signal::Signal;
use nix::sys::wait::{WaitStatus, waitpid};
use nix::unistd::Pid;
use slopdesk_posix::pty::{self, SpawnError, SpawnPlan};

use crate::journal::JournalStore;
use crate::listeners::Claims;
use crate::paths::Paths;
use crate::protocol::{ExitedNotice, PaneRecord, SpawnRequest, listener_kind};
use crate::pump::{OutputSink, Pump};
use crate::ring::Resume;
use crate::{autoprogress, blocks, shellintegration, sniffer};

/// Identifies the connection currently holding a pane, so a drop can clear exactly its own claims.
pub type ClientID = u64;

/// A supervised child and the fd that keeps it alive.
///
/// **Field order is load-bearing.** Rust drops fields in declaration order, so `pump` — whose
/// `Drop` stops and JOINS the reader thread — is gone before `master` closes. Reversing them would
/// let a thread still parked in `read` outlive the descriptor it reads, and fd numbers are
/// recycled: the straggler would eventually be reading another pane's master and publishing its
/// bytes under the wrong pane id. Not a crash. Just wrong output, in the wrong window, sometimes.
#[derive(Debug)]
struct Pane {
    record: PaneRecord,
    /// The always-on reader. Holds its own duplicate of the master, which it closes when its
    /// thread ends.
    pump: Pump,
    /// superd's own copy. Dropped only by `release` or by the reaper. Everything else that looks
    /// like a good reason to close it is the bug this daemon exists to prevent.
    master: OwnedFd,
    /// Which connection currently holds a duplicate, if any. `None` is the normal state during a
    /// hostd restart — the pane is live and simply unattached.
    holder: Option<ClientID>,
    /// The generated `ZDOTDIR` this child was spawned with, when it got one.
    ///
    /// Removed when the child is KNOWN dead — a deliberate kill, or the reaper seeing it exit — and
    /// never on a relinquish, where the shell is still running and could re-read its startup files
    /// on an `exec zsh`. A relinquished pane therefore leaves its dir behind, which is the same
    /// trade the host made before superd owned this.
    shim_dir: Option<std::path::PathBuf>,
}

/// A second descriptor for the same open master — hostd's copy, or the pump's.
///
/// `dup` never transfers anything: the open file lives until its LAST descriptor closes, which is
/// the property the whole daemon is built on. What a duplicate buys the caller is a lifetime of its
/// own, independent of whatever the reaper does to the pane it came from.
fn duplicate_master(master: &OwnedFd) -> Result<OwnedFd, RegistryError> {
    master
        .try_clone()
        .map_err(|error| RegistryError::Posix(Errno::from_raw(error.raw_os_error().unwrap_or(libc::EBADF))))
}

/// Removes a generated shim directory unless the pane that owns it was actually recorded.
///
/// Between creating the directory and inserting the pane there are three ways to return, and a
/// fourth is one refactor away. Each of them leaves a directory in tmp with nobody left to delete
/// it, so the cleanup is stated once, here, rather than repeated at every `return`.
#[derive(Debug)]
struct ShimGuard(Option<std::path::PathBuf>);

impl ShimGuard {
    /// Hands the directory to the pane record, so the guard stops owning it.
    const fn disarm(&mut self) -> Option<std::path::PathBuf> {
        self.0.take()
    }
}

impl Drop for ShimGuard {
    fn drop(&mut self) {
        if let Some(dir) = self.0.take() {
            let _ignored = std::fs::remove_dir_all(dir);
        }
    }
}

/// Removes a shim directory now that its child is known dead.
fn discard_shim(shim_dir: Option<std::path::PathBuf>) {
    if let Some(dir) = shim_dir {
        let _ignored = std::fs::remove_dir_all(dir);
    }
}

/// Why a verb could not be served.
#[derive(Debug)]
pub enum RegistryError {
    /// No pane by that id. After a superd restart this is every id, which is why hostd treats it
    /// as "spawn a fresh one" rather than an error.
    UnknownPane(String),
    /// A pane with that id is already supervised. hostd asking twice means its own bookkeeping
    /// diverged; refusing is safer than silently orphaning the first child.
    DuplicatePane(String),
    /// The spawn itself failed.
    Spawn(SpawnError),
    /// A syscall on an existing pane failed.
    Posix(Errno),
    /// The lock was poisoned by a panic on another thread. Reported rather than propagated: a
    /// panicking reaper must cost one pane, not the whole daemon (which is why this crate builds
    /// with `panic = "unwind"`).
    Poisoned,
}

impl std::fmt::Display for RegistryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownPane(id) => write!(formatter, "no supervised pane {id}"),
            Self::DuplicatePane(id) => write!(formatter, "pane {id} is already supervised"),
            Self::Spawn(error) => write!(formatter, "{error}"),
            Self::Posix(errno) => write!(formatter, "{errno}"),
            Self::Poisoned => write!(formatter, "the registry lock was poisoned by a panic"),
        }
    }
}

impl std::error::Error for RegistryError {}

/// Where an `exited` notice goes. A boxed callback rather than a channel so the registry has no
/// opinion about how the server fans out to connections.
pub type ExitNotifier = Arc<dyn Fn(ExitedNotice) + Send + Sync>;

/// How many exited panes keep their output waiting for a subscriber that never came.
///
/// Small on purpose. The window this covers is the milliseconds between a `spawn` reply and the
/// `subscribe` that follows it, so one entry would very nearly do; sixteen absorbs a burst of
/// short-lived panes without turning the graveyard into a second, unbounded pane table.
const GRAVEYARD_PANES: usize = 16;

/// A pane id held against a concurrent [`Registry::spawn`] while its child is being forked.
///
/// Exists to be dropped: the id leaves `reserving` when this goes out of scope, whichever way the
/// spawn ended.
struct Reservation<'registry> {
    registry: &'registry Registry,
    pane_id: String,
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        if let Ok(mut reserving) = self.registry.reserving.lock() {
            reserving.remove(&self.pane_id);
            drop(reserving);
        }
    }
}

/// The pane table.
pub struct Registry {
    panes: Mutex<HashMap<String, Pane>>,
    /// Pane ids whose child is being forked right now — see [`Registry::reserve`]. Always locked
    /// BEFORE `panes`, and never held across anything but that one check.
    reserving: Mutex<HashSet<String>>,
    /// The rings of panes whose child has exited, newest last.
    ///
    /// A pane dies the instant its child is reaped — the master must close, and the pump must stop
    /// — but its *output* has to outlive it by a moment. hostd subscribes only after the `spawn`
    /// reply gets back to it, and `slopdesk-ctl spawn --cmd ls` finishes long before that: without
    /// this, the pane renders empty. Ring only, never an fd, and bounded by [`GRAVEYARD_PANES`],
    /// because a hostd that dies before it reads is a hostd that will never read.
    graveyard: Mutex<VecDeque<(String, Arc<Mutex<crate::ring::OutputRing>>)>>,
    paths: Paths,
    /// Which child-facing sockets currently have a hostd behind them. Read at every `spawn`, never
    /// cached: a claim comes and goes with each hostd restart, and a child spawned during the gap
    /// must be told the truth as it stands at its own `execve`.
    claims: Arc<Claims>,
    notify: ExitNotifier,
    /// Where every pane's freshly-read bytes go. One sink for all panes — it is handed the pane id
    /// per chunk — so the registry has no opinion about how the server fans out to connections.
    sink: OutputSink,
    /// How much output each new pane retains for a hostd that is away ([`crate::ring`]).
    ring_capacity: usize,
    /// Every pane's on-disk transcript ([`crate::journal`]). Shared with the server, which answers
    /// the read/delete/sweep verbs against the same live-writer table this one opens into.
    journals: Arc<JournalStore>,
}

impl std::fmt::Debug for Registry {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Registry")
            .field("paths", &self.paths)
            .finish_non_exhaustive()
    }
}

impl Registry {
    /// Builds an empty registry.
    #[must_use]
    pub fn new(
        paths: Paths,
        claims: Arc<Claims>,
        notify: ExitNotifier,
        sink: OutputSink,
        ring_capacity: usize,
        journals: Arc<JournalStore>,
    ) -> Self {
        Self {
            panes: Mutex::new(HashMap::new()),
            reserving: Mutex::new(HashSet::new()),
            graveyard: Mutex::new(VecDeque::with_capacity(GRAVEYARD_PANES)),
            paths,
            claims,
            notify,
            sink,
            ring_capacity,
            journals,
        }
    }

    /// Forks a pane shell, records it, and hands back the record with a master duplicate for the
    /// client.
    ///
    /// The duplicate is superd's to give away: the caller passes it to [`crate::frame::write`],
    /// which makes the kernel install a *separate* descriptor in hostd again, and then drops it.
    /// superd's own copy — the one in the map — stays open and untouched, which is the whole point.
    ///
    /// # Errors
    /// [`RegistryError::DuplicatePane`] or [`RegistryError::Spawn`].
    pub fn spawn(
        self: &Arc<Self>,
        request: &SpawnRequest,
        holder: ClientID,
    ) -> Result<(PaneRecord, OwnedFd), RegistryError> {
        // Held until this function returns, which is what makes the duplicate check and the insert
        // ~200 lines below behave as one decision even though the fork between them must not run
        // under a lock. Without it the check was advisory: two hostds overlapping across a restart
        // both `spawn` the stable id `service:code-server`, both pass `contains_key`, both fork a
        // real child, and the second insert silently overwrites the first pane — whose master fd,
        // pump and pid leave the map with no `abandon`, leaving superd holding a running Node it
        // can no longer list, kill or reap. The only thing that stood in the way was a
        // `debug_assert!`, which is compiled out of the `--release` build `make superd` produces.
        let _reservation = self.reserve(&request.pane_id)?;

        let cwd = resolve_cwd(request.cwd.as_deref(), request.environment.get("HOME"));
        let (environment, shim_dir) = self.overlay_environment(request);
        // Armed from here to the insert: every failure below leaves the generated directory with no
        // owner, and a guard says that once rather than at each `return`.
        let mut shim = ShimGuard(shim_dir);
        let arguments = request.arguments.clone();
        let plan = SpawnPlan {
            executable: &request.executable,
            argv0: request.argv0.as_deref(),
            arguments: &arguments,
            environment: &environment,
            cwd: cwd.as_deref(),
            rows: request.rows,
            cols: request.cols,
        };
        let spawned = pty::spawn_pty(&plan).map_err(RegistryError::Spawn)?;

        // The pump gets its own duplicate and starts draining immediately — before the pane is even
        // recorded, and before hostd has been told the spawn succeeded. A pane must never exist in
        // a state where nobody is reading it, however briefly: that state is the stall this whole
        // change removes, and "briefly" is exactly how long a shell's banner takes to fill a PTY
        // buffer.
        //
        // Everything from here to the insert can still fail, and by now a CHILD EXISTS. Each of
        // those failures goes through `abandon`, never through a bare `?`: the fork has to be
        // undone by hand, because nothing else in this daemon will.
        let duplicate = match duplicate_master(&spawned.master) {
            Ok(duplicate) => duplicate,
            Err(error) => {
                self.abandon(&request.pane_id, spawned.pid);
                return Err(error);
            },
        };
        // The caller's duplicate, made HERE — while this function still holds the master outright
        // — and handed back with the record, rather than looked up again once the pane is in the
        // map. The gap between the insert below and any second lookup is not theoretical: a
        // `/bin/sh -c "exit 0"` is often already dead by then, and the reaper removes the pane and
        // drops its master the moment it is. A lookup landing after that answers one of two ways,
        // and both are wrong — it finds nothing, so an `ok` spawn reply goes out carrying no
        // descriptor at all (hostd reports `missingDescriptor` for a child that really did run),
        // or it finds a RAW fd number the reaper has already closed and some other thread has
        // since been given, and the client is handed a descriptor belonging to something else.
        // An owned duplicate has neither window: its lifetime stops depending on the pane's the
        // instant it exists.
        let for_client = match duplicate_master(&spawned.master) {
            Ok(for_client) => for_client,
            Err(error) => {
                self.abandon(&request.pane_id, spawned.pid);
                return Err(error);
            },
        };
        // The journal is fed from INSIDE the sink, ahead of the fan-out, so a pane persists its
        // transcript whether or not anybody is subscribed — and so the server, which owns the
        // fan-out, needs to know nothing about the file. An append is a `memcpy` under an
        // uncontended mutex; the fan-out that follows walks every subscribed connection and writes
        // to sockets, and a pane whose hostd is wedged must still be persisting.
        let journals = Arc::clone(&self.journals);
        let downstream = Arc::clone(&self.sink);
        let sink: OutputSink = Arc::new(
            move |pane_id: &str, offset: u64, bytes: &[u8], events: &[_], blocks: &[_]| {
                journals.append(pane_id, bytes, offset.saturating_add(bytes.len() as u64));
                downstream(pane_id, offset, bytes, events, blocks);
            },
        );
        let pump = match Pump::start(
            &request.pane_id,
            duplicate,
            self.ring_capacity,
            sink,
            // Only a pane that asked for shell integration has a shell saying anything out of band;
            // a panel backend's stdout is not an OSC stream and scanning it would be pure cost.
            request
                .shell_integration
                .then(|| sniffer::OutputSniffer::new(sniffer::local_hostnames())),
            // Absent means the operator turned blocks off, or hostd is older than the field: either
            // way no segmenter touches this pane's stream and no `0x05` frame is ever sent.
            request.blocks.as_ref().map(|blocks| {
                blocks::BlockTracker::new(
                    autoprogress::parse_prefixes(blocks.auto_progress_commands.as_deref()),
                    blocks.output_cap,
                    blocks.max_blocks,
                    blocks.max_total_output_bytes,
                )
            }),
        ) {
            Ok(pump) => pump,
            Err(errno) => {
                self.abandon(&request.pane_id, spawned.pid);
                return Err(RegistryError::Posix(errno));
            },
        };

        // Opened BEFORE the insert, so the first chunk the pump reads already has somewhere to go:
        // the pump is draining by now, and a journal armed a moment later would start the
        // transcript after the shell's banner. A pane whose caller asked for no journal registers
        // nothing, and every append for it is a map miss.
        if let Some(wanted) = request.journal.as_ref() {
            self.journals.open(
                &request.pane_id,
                std::path::Path::new(&wanted.directory),
                &request.session_id,
                wanted.cap_bytes,
            );
            // The spawn-time winsize is the first geometry this pane ever had, and a pane whose
            // client never resizes would otherwise leave a later life's renderer with no size at all.
            self.journals
                .record_size(&request.pane_id, request.rows, request.cols);
        }
        let record = PaneRecord {
            pane_id: request.pane_id.clone(),
            session_id: request.session_id.clone(),
            pid: spawned.pid,
            executable: request.executable.clone(),
            cwd,
            rows: request.rows,
            cols: request.cols,
            spawned_at: unix_seconds(),
            attached: true,
            owner: request.owner.clone(),
        };
        {
            let mut panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
            let previous = panes.insert(request.pane_id.clone(), Pane {
                record: record.clone(),
                pump,
                master: spawned.master,
                holder: Some(holder),
                shim_dir: shim.disarm(),
            });
            drop(panes);
            debug_assert!(
                previous.is_none(),
                "the reservation above should have made this impossible"
            );
        }
        self.clone().start_reaper(request.pane_id.clone(), spawned.pid);
        Ok((record, for_client))
    }

    /// Takes a pane id out of circulation for the length of a spawn.
    ///
    /// Checked against the live panes AND the ids currently being forked, under one acquisition of
    /// each lock, in the order this module always takes them (`reserving` before `panes`; nothing
    /// takes them the other way round). The returned guard releases the id on every path out of
    /// `spawn`, including a panic.
    ///
    /// # Errors
    /// [`RegistryError::DuplicatePane`] when the id is live or already being forked.
    fn reserve(&self, pane_id: &str) -> Result<Reservation<'_>, RegistryError> {
        let mut reserving = self
            .reserving
            .lock()
            .map_err(|_ignored| RegistryError::Poisoned)?;
        let panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let taken = panes.contains_key(pane_id) || reserving.contains(pane_id);
        drop(panes);
        if taken {
            return Err(RegistryError::DuplicatePane(pane_id.to_owned()));
        }
        reserving.insert(pane_id.to_owned());
        drop(reserving);
        Ok(Reservation {
            registry: self,
            pane_id: pane_id.to_owned(),
        })
    }

    /// Lets go of a child that was forked but never recorded.
    ///
    /// The failure window is small — a `try_clone` or a `pipe`, both EMFILE-shaped — and its cost
    /// is not. `spawn` returning `Err` after the fork leaves a shell whose master is about to close
    /// (so it hangs up and dies) but which NOTHING will ever `waitpid`, because the only reaper is
    /// started at the end of the happy path. In a daemon that runs for the machine's life a zombie
    /// per failure never goes away, and the failure is EMFILE — a state that repeats.
    ///
    /// The reaper is safe to start for a pane that will never exist: it waits, looks the id up,
    /// finds nothing (or finds a later pane whose pid does not match, which its own guard rejects)
    /// and announces nothing. `SIGHUP` first so the child goes even if it somehow outlives the
    /// master close that follows this call.
    fn abandon(self: &Arc<Self>, pane_id: &str, pid: i32) {
        eprintln!("superd: pane {pane_id} could not be recorded after its fork — hanging up pid {pid}");
        let _ignored = nix::sys::signal::kill(Pid::from_raw(pid), Signal::SIGHUP);
        self.clone().start_reaper(pane_id.to_owned(), pid);
    }

    /// superd's socket paths win over anything hostd sent — but ONLY for sockets superd is
    /// actually listening on.
    ///
    /// `docs/51` §1 made mechanical: the child-facing socket paths want to be superd's, because
    /// they have to outlive the hostd that spawned the child, and a child's environment is a
    /// snapshot taken at `execve` that can never be corrected afterwards.
    ///
    /// The CLAIM is the whole point of the shape. An earlier version overlaid these
    /// unconditionally while superd bound neither of them — hostd still did, at its own paths. So
    /// every child was handed the address of a socket with nothing behind it, and the symptom was
    /// not an error anywhere: Claude's hooks simply `POST`ed into the void and agent detection
    /// silently fell back to the screen engine. Advertising an address is a promise to be listening
    /// at it, so the overlay asks whether the promise can currently be kept — superd bound the
    /// socket AND some hostd has claimed it — and passes hostd's own value through when it cannot.
    ///
    /// It is also how a hostd feature flag survives the move. The ctl surface is default-off, and
    /// what that now means is that hostd claims [`listener_kind::HOOK`] and not
    /// [`listener_kind::CONTROL`] — superd learns the policy by being asked, rather than by growing
    /// a copy of a flag that is not its business.
    ///
    /// hostd curates the rest of the environment — that is its job and it changes often, which is
    /// exactly why superd must not need a rebuild when it does.
    fn overlay_environment(&self, request: &SpawnRequest) -> (Vec<String>, Option<std::path::PathBuf>) {
        let mut merged = request.environment.clone();
        // The shim goes on FIRST, so superd's own socket paths below still win over anything a
        // generated rc file could be pointed at, and so a caller who set `ZDOTDIR` by hand does not
        // silently defeat the shim it also asked for.
        let shim_dir = request.shell_integration.then(|| {
            match shellintegration::install(
                &request.environment,
                &request.executable,
                &shellintegration::Probes::system(),
            ) {
                Ok(shim) => {
                    merged.extend(shim.overrides());
                    Some(shim.directory)
                },
                Err(reason) => {
                    // Never fatal: every rejection leaves a perfectly usable shell, and saying so
                    // in the log is the difference between "integration is off" and "nobody knows".
                    eprintln!(
                        "superd: pane {} without shell integration — {reason}",
                        request.pane_id
                    );
                    None
                },
            }
        });
        for (kind, key) in [
            (listener_kind::HOOK, "SLOPDESK_SOCKET_PATH"),
            (listener_kind::CONTROL, "SLOPDESK_CONTROL_SOCKET"),
        ] {
            if !self.claims.is_served(kind) {
                continue;
            }
            if let Some(path) = self.paths.for_kind(kind) {
                merged.insert(key.to_owned(), path.display().to_string());
            }
        }
        // The pane id is hostd's to choose but superd's to guarantee: the hook relay routes by it,
        // and a restarted hostd recovers it from `list` rather than minting a new one.
        merged.insert("SLOPDESK_PANE_ID".to_owned(), request.pane_id.clone());
        let environment = merged
            .into_iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect();
        (environment, shim_dir.flatten())
    }

    /// Hands back a pane that survived a restart, with a master duplicate for the client. This is
    /// the verb the whole design exists for.
    ///
    /// The duplicate is taken under the same hold of the lock that marks the pane attached, for
    /// the reason [`Self::spawn`] states: a fd this daemon has handed out is only meaningful if
    /// its lifetime no longer depends on the pane surviving the trip to the wire.
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`], or [`RegistryError::Posix`] if the master cannot be
    /// duplicated (`EMFILE`).
    pub fn adopt(&self, pane_id: &str, holder: ClientID) -> Result<(PaneRecord, OwnedFd), RegistryError> {
        let mut panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let pane = panes
            .get_mut(pane_id)
            .ok_or_else(|| RegistryError::UnknownPane(pane_id.to_owned()))?;
        let for_client = duplicate_master(&pane.master)?;
        pane.holder = Some(holder);
        pane.record.attached = true;
        let record = pane.record.clone();
        drop(panes);
        Ok((record, for_client))
    }

    /// Everything currently supervised. A restarted hostd calls this first.
    ///
    /// # Errors
    /// [`RegistryError::Poisoned`].
    pub fn list(&self) -> Result<Vec<PaneRecord>, RegistryError> {
        let panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let mut records: Vec<PaneRecord> = panes.values().map(|pane| pane.record.clone()).collect();
        drop(panes);
        // Stable order so a restarted hostd rebuilds panes deterministically.
        records.sort_by(|a, b| a.spawned_at.cmp(&b.spawned_at).then(a.pane_id.cmp(&b.pane_id)));
        Ok(records)
    }

    /// Signals a pane, at whichever of the terminal's two targets the signal is *about*.
    ///
    /// A tty has two, and they are not interchangeable:
    ///
    /// * the **session leader** — the shell superd forked. A hangup is addressed here, because it
    ///   means "your terminal went away"; the shell is the thing that has one. It answers by
    ///   hanging up its own jobs, and an interactive zsh flushes `$HISTFILE` on the way out.
    /// * the **foreground process group** — whatever the shell is currently running. This is where
    ///   the line discipline puts a `^C`, and addressing a shell instead would kill the session to
    ///   interrupt a `sleep`.
    ///
    /// Routing everything at the foreground group (which this did until it was caught in review)
    /// breaks the teardown ladder in ``MuxChannelSession/shutdown()`` exactly when it matters: a
    /// pane closed while a foreground job is running would signal the job, the shell would never
    /// hear the hangup, and the typed history would go unwritten.
    ///
    /// So the target is chosen from the signal, by what the kernel itself would do with it, and
    /// [`targets_foreground_group`] is that table. Note that in practice a `^C` arrives as a *byte*
    /// through the pane's own input and is raised by the line discipline — this verb is the
    /// out-of-band path, and today only the teardown ladder uses it.
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`] or [`RegistryError::Posix`].
    pub fn signal(&self, pane_id: &str, number: i32) -> Result<(), RegistryError> {
        let (master, pid) = {
            let panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
            let found = panes
                .get(pane_id)
                .map(|pane| (pane.master.as_raw_fd(), pane.record.pid));
            drop(panes);
            found.ok_or_else(|| RegistryError::UnknownPane(pane_id.to_owned()))?
        };
        let signal = Signal::try_from(number).map_err(RegistryError::Posix)?;
        // `tcgetpgrp` answering 0 (or failing) means nothing has claimed the terminal, so even a
        // job-control signal has only the child to go to.
        let group = if targets_foreground_group(signal) {
            pty::foreground_process_group(master).unwrap_or(0)
        } else {
            0
        };
        let target = if group > 0 { -group } else { pid };
        nix::sys::signal::kill(Pid::from_raw(target), signal).map_err(RegistryError::Posix)
    }

    /// RECORDS a resize hostd has already applied, so a restarted hostd inherits a truthful size.
    ///
    /// It does **not** `TIOCSWINSZ`. There is exactly one writer of a pane's window size and it is
    /// hostd, through its own duplicate of the master — the side that knows the PIXEL geometry
    /// superd is never told, and the side that owns the sub-cell dances (the cold-reattach redraw
    /// jiggle shrinks a row and puts it back within milliseconds). A second writer here does not
    /// re-apply the same size, it applies a STALE one: this verb is a notification, so it lands
    /// whenever the thread gets to it, and the jiggle's shrink that went out afterwards is undone
    /// by a resize that was already in flight. The pane then never re-lays-out, which is the entire
    /// point of the jiggle. Recording is all that is wanted, because the record is only ever read
    /// by `list`.
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`].
    pub fn resize(&self, pane_id: &str, rows: u16, cols: u16) -> Result<(), RegistryError> {
        let mut panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let outcome = panes.get_mut(pane_id).map_or_else(
            || Err(RegistryError::UnknownPane(pane_id.to_owned())),
            |pane| {
                pane.record.rows = rows;
                pane.record.cols = cols;
                Ok(())
            },
        );
        drop(panes);
        // The size a transcript must be parsed at is the size it was WRITTEN at, and that number
        // has to outlive the process that knew it. Deduped inside the store — a resize repeats the
        // same pair far more often than it changes it.
        if outcome.is_ok() {
            self.journals.record_size(pane_id, rows, cols);
        }
        outcome
    }

    /// The retained output for a subscriber joining or rejoining at `offset`, and whether the
    /// stream is already finished.
    ///
    /// The second half of the answer is what lets a subscriber that arrives late be served at all.
    /// A live pane's `ended` is normally false and the subscriber waits for frames; a pane whose
    /// child is already reaped answers true, and the backlog it returns is the whole stream —
    /// there will never be another byte, and no `exited` notice is coming either, because that one
    /// was broadcast before this subscriber existed.
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`], once even the graveyard has forgotten it.
    pub fn resume(&self, pane_id: &str, offset: u64) -> Result<(Resume, bool), RegistryError> {
        let panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let live = panes
            .get(pane_id)
            .map(|pane| (pane.pump.resume_from(offset), pane.pump.has_ended()));
        drop(panes);
        if let Some(found) = live {
            return Ok(found);
        }
        self.exhume(pane_id, offset)
            .ok_or_else(|| RegistryError::UnknownPane(pane_id.to_owned()))
    }

    /// Re-reads a pane's retained backlog through a FRESH sniffer, for a subscriber just arriving.
    ///
    /// A restarted hostd learns a pane's title, command status and progress by reading them out of
    /// the bytes it is replayed — that is how it worked when hostd did the sniffing, and replaying
    /// the EVENTS rather than a state snapshot keeps it working the same way, with no second copy
    /// of "current truth" to drift. The live sniffer is untouched: it belongs to the pump thread,
    /// and this one starts at ground on a stream that starts mid-flight, which is exactly the
    /// resync case its state machine is built for.
    ///
    /// `None` for a pane nobody asked to sniff, and for one already in the graveyard — a dead
    /// pane's title is not a fact anybody can act on.
    #[must_use]
    pub fn sniff_backlog(
        &self,
        pane_id: &str,
        bytes: &[u8],
        now_ms: i64,
    ) -> Option<Vec<sniffer::SniffEvent>> {
        let panes = self.panes.lock().ok()?;
        let sniffed = panes.get(pane_id).is_some_and(|pane| pane.pump.is_sniffed());
        drop(panes);
        if !sniffed {
            return None;
        }
        let mut fresh = sniffer::OutputSniffer::new(sniffer::local_hostnames());
        Some(fresh.observe(bytes, now_ms))
    }

    /// Reads an exited pane's retained output out of the graveyard.
    fn exhume(&self, pane_id: &str, offset: u64) -> Option<(Resume, bool)> {
        let graveyard = self.graveyard.lock().ok()?;
        let ring = graveyard
            .iter()
            .find(|(id, _ring)| id == pane_id)
            .map(|(_id, ring)| Arc::clone(ring));
        drop(graveyard);
        let ring = ring?;
        let guard = ring.lock().ok()?;
        let resumed = guard.read_from(offset);
        drop(guard);
        Some((resumed, true))
    }

    /// Keeps an exited pane's output for the subscriber that has not arrived yet, evicting the
    /// oldest once the graveyard is full.
    fn entomb(&self, pane_id: String, ring: Arc<Mutex<crate::ring::OutputRing>>) {
        let Ok(mut graveyard) = self.graveyard.lock() else {
            return;
        };
        graveyard.push_back((pane_id, ring));
        while graveyard.len() > GRAVEYARD_PANES {
            let _evicted = graveyard.pop_front();
        }
        drop(graveyard);
    }

    /// Forgets an exited pane's retained output. Returns whether there was any.
    fn bury(&self, pane_id: &str) -> bool {
        self.graveyard.lock().is_ok_and(|mut graveyard| {
            let before = graveyard.len();
            graveyard.retain(|(id, _ring)| id != pane_id);
            let removed = graveyard.len() < before;
            drop(graveyard);
            removed
        })
    }

    /// Counts a subscriber onto a pane. Paired with [`Registry::unsubscribed`].
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`].
    pub fn subscribed(&self, pane_id: &str) -> Result<(), RegistryError> {
        self.with_pump(pane_id, Pump::subscribed)
    }

    /// Counts a subscriber off a pane, releasing any pause it left behind.
    ///
    /// Not an error when the pane is already gone: this runs on the disconnect path, and a client
    /// dropping at the same moment its pane exits is ordinary rather than exceptional.
    pub fn unsubscribed(&self, pane_id: &str) {
        let _ignored = self.with_pump(pane_id, Pump::clear_pause_on_last_unsubscribe);
    }

    /// Reads a pane's command-block tap.
    ///
    /// `None` both for a pane with no tap and for one that is gone, and the caller answers the same
    /// way to either: a pane superd cannot find has no blocks to report, and saying so is not an
    /// error worth a different reply than "blocks are off here".
    #[must_use]
    pub fn read_blocks<T>(&self, pane_id: &str, read: impl FnOnce(&Pump) -> Option<T>) -> Option<T> {
        let panes = self.panes.lock().ok()?;
        let answer = panes.get(pane_id).and_then(|pane| read(&pane.pump));
        drop(panes);
        answer
    }

    /// Retires a pane sniffer's title-coalescing anchor.
    ///
    /// Not an error when the pane is gone, for the same reason [`Registry::unsubscribed`] is not:
    /// the caller is reacting to an agent that just exited, and the pane going with it is ordinary.
    pub fn forget_title_coalescing(&self, pane_id: &str) {
        let _ignored = self.with_pump(pane_id, Pump::forget_title_coalescing);
    }

    /// Stops or resumes superd's reads on a pane — hostd's backpressure gate.
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`].
    pub fn set_paused(&self, pane_id: &str, paused: bool) -> Result<(), RegistryError> {
        self.with_pump(pane_id, |pump| pump.set_paused(paused))
    }

    fn with_pump<Action: FnOnce(&Pump)>(&self, pane_id: &str, action: Action) -> Result<(), RegistryError> {
        let panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let found = panes.get(pane_id).map(|pane| action(&pane.pump));
        drop(panes);
        found.ok_or_else(|| RegistryError::UnknownPane(pane_id.to_owned()))
    }

    /// hostd is done with this pane for good.
    ///
    /// The ONLY caller-driven path that closes a master fd. `kill: false` is "the child already
    /// exited, just clean up".
    ///
    /// # Errors
    /// [`RegistryError::UnknownPane`].
    pub fn release(&self, pane_id: &str, kill: bool) -> Result<(), RegistryError> {
        // Flush and close first, whichever way this ends. The file is KEPT — deleting one is a
        // separate verb, because "hostd is done with this pane" and "this pane's history is over"
        // are different facts and only the caller knows which it means.
        self.journals.close(pane_id);
        let pane = {
            let mut panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
            let gone = panes.remove(pane_id);
            drop(panes);
            gone
        };
        let Some(pane) = pane else {
            // Nothing live under that id. If the graveyard still holds its output then this is the
            // ordinary teardown of a pane whose child beat hostd to the finish, and forgetting it
            // is exactly what was asked for — not an error.
            return if self.bury(pane_id) {
                Ok(())
            } else {
                Err(RegistryError::UnknownPane(pane_id.to_owned()))
            };
        };
        if kill {
            // SIGHUP, not SIGKILL: a shell hung up on saves its history, which SIGKILL skips. The
            // master close below would send one anyway once this was the last holder — doing it
            // explicitly means the child gets it even if hostd still holds a duplicate.
            let _ignored = nix::sys::signal::kill(Pid::from_raw(pane.record.pid), Signal::SIGHUP);
            // Only on the KILL branch. A relinquish leaves a running shell that could still re-read
            // its startup files, and this pane is about to leave the map, so nothing would put the
            // directory back.
            discard_shim(pane.shim_dir.clone());
        }
        // Dropping the `OwnedFd` closes superd's copy. The reaper thread for this pid is still in
        // `waitpid` and will find the pane gone, so it stays quiet — see `start_reaper`.
        drop(pane);
        Ok(())
    }

    /// A connection dropped. Marks its panes unattached and **closes nothing**.
    ///
    /// This method is where the daemon earns its keep, so it is worth reading as prose: hostd has
    /// died, and the correct response is to update one boolean.
    ///
    /// # Errors
    /// [`RegistryError::Poisoned`].
    pub fn detach_client(&self, holder: ClientID) -> Result<usize, RegistryError> {
        let mut panes = self.panes.lock().map_err(|_ignored| RegistryError::Poisoned)?;
        let mut detached = 0;
        for pane in panes.values_mut() {
            if pane.holder == Some(holder) {
                pane.holder = None;
                pane.record.attached = false;
                detached += 1;
            }
        }
        drop(panes);
        Ok(detached)
    }

    /// One blocking `waitpid` thread per pane.
    ///
    /// A thread rather than a `SIGCHLD` handler: only the forking process may reap, superd is that
    /// process, and a handler would have to be async-signal-safe while doing map lookups and JSON.
    /// The thread costs 8KB of stack per pane and buys ordinary code.
    fn start_reaper(self: Arc<Self>, pane_id: String, pid: i32) {
        let builder = std::thread::Builder::new()
            .name(format!("superd-reap-{pid}"))
            .stack_size(64 * 1024);
        let spawned = builder.spawn(move || {
            let code = wait_for_exit(pid);
            // Remove-if-present-AND-still-ours. Two ways this reaper can find something other than
            // what it waited for: a `release` may have got here first, in which case the pane is
            // already gone and nobody is owed an `exited`; or the id has since been re-used by a
            // fresh `spawn` — hostd re-spawns a pane under the pane's own UUID, and a
            // `service:<name>` id is stable *by design* (`docs/51` §6.7), so a backend that dies
            // and is immediately respawned lands on exactly this. Removing by name alone would
            // then evict a live pane and announce it dead, on the strength of an unrelated pid.
            let removed = self.panes.lock().ok().and_then(|mut panes| {
                let gone = match panes.get(&pane_id) {
                    Some(pane) if pane.record.pid == pid => panes.remove(&pane_id),
                    _ => None,
                };
                drop(panes);
                gone
            });
            if let Some(pane) = removed {
                // Collect the child's last words BEFORE announcing its death. The pump and this
                // thread are independent, so without the drain a shell's farewell output would race
                // the `exited` that tears down the session meant to display it — and lose about as
                // often as it won. `drain_to_end` reads to EOF and joins, and both this notice and
                // those bytes leave through the same per-connection write lock, so the order
                // established here is the order that reaches the wire.
                pane.pump.drain_to_end();
                // The child's last words are in the ring now, so they are in the journal too — the
                // drain above went through the same sink. Close the file before the notice goes
                // out: hostd reacts to `exited` by restoring or deleting a transcript, and both
                // want the last bytes already on disk.
                self.journals.close(&pane_id);
                // The ring outlives the pane by design: dropping `pane` closes the master and
                // stops the pump, which must happen now, but a subscriber may still be in flight —
                // a `spawn` of `ls` is answered, exits, and is reaped before hostd's `subscribe`
                // gets back here. Entomb before the notice, so a client reacting to `exited` by
                // reading one last time finds something there.
                let ring = pane.pump.ring();
                // The child is gone for certain — this thread just reaped it — so its generated
                // startup files can go too. The one disposal site that survives hostd dying.
                discard_shim(pane.shim_dir.clone());
                drop(pane);
                self.entomb(pane_id.clone(), ring);
                (self.notify)(ExitedNotice { pane_id, pid, code });
            }
        });
        if let Err(error) = spawned {
            // A pane whose reaper never started is still alive and usable; it just leaves a zombie
            // and never reports its exit. Worth a loud log and nothing more drastic.
            eprintln!("superd: could not start reaper for pid {pid}: {error}");
        }
    }
}

/// Whether a signal is one the terminal raises *at whatever is running*, rather than at the
/// session.
///
/// The list is the kernel's own: these are precisely the signals a tty's line discipline generates
/// from the `VINTR`, `VQUIT` and `VSUSP` characters, and they go to the foreground process group.
/// `SIGTTIN`/`SIGTTOU` join them because they are raised by the same machinery, at the same target,
/// for a background group touching the terminal.
///
/// Everything else — the `SIGHUP`/`SIGTERM`/`SIGKILL` teardown ladder above all — is addressed at
/// the session leader. See [`Registry::signal`] for why the difference is load-bearing.
const fn targets_foreground_group(signal: Signal) -> bool {
    matches!(
        signal,
        Signal::SIGINT | Signal::SIGQUIT | Signal::SIGTSTP | Signal::SIGTTIN | Signal::SIGTTOU
    )
}

/// Blocks until `pid` exits, returning the code hostd's exit handling already understands:
/// the exit status, or `128 + signal` for a signalled child.
fn wait_for_exit(pid: i32) -> i32 {
    loop {
        match waitpid(Pid::from_raw(pid), None) {
            Ok(WaitStatus::Exited(_, code)) => return code,
            Ok(WaitStatus::Signaled(_, signal, _)) => return 128_i32.saturating_add(signal as i32),
            // Stopped/continued are not exits, and EINTR is not an answer — keep waiting.
            Ok(_) | Err(Errno::EINTR) => (),
            // ECHILD means someone else reaped it, or it never existed. Either way there is
            // nothing left to wait for; report the conventional "killed" code rather than spin.
            Err(_) => return 128_i32.saturating_add(libc::SIGHUP),
        }
    }
}

/// Picks a directory the child can actually start in: the request, else `$HOME`, else `/`.
///
/// Validated HERE, in the parent, because the child's pre-`execve` `chdir` is best-effort and
/// cannot fall back — an unvalidated path would be a silently mis-rooted pane.
fn resolve_cwd(requested: Option<&str>, home: Option<&String>) -> Option<String> {
    for candidate in [requested, home.map(String::as_str), Some("/")]
        .into_iter()
        .flatten()
    {
        if std::fs::metadata(candidate).is_ok_and(|meta| meta.is_dir()) {
            return Some(candidate.to_owned());
        }
    }
    None
}

/// Unix seconds as an integer. No float ever crosses the supervisor boundary.
fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| i64::try_from(elapsed.as_secs()).unwrap_or(i64::MAX))
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::collections::BTreeMap;
    use std::os::fd::{AsFd as _, AsRawFd as _, BorrowedFd};
    use std::sync::{Arc, mpsc};

    use super::{
        Claims, ExitedNotice, GRAVEYARD_PANES, JournalStore, OutputSink, PaneRecord, Paths, Registry,
        RegistryError, Signal, SpawnRequest, blocks, listener_kind, pty, sniffer,
    };

    fn registry() -> (Arc<Registry>, mpsc::Receiver<ExitedNotice>) {
        let (registry, exits, _output) = registry_watching_output();
        (registry, exits)
    }

    /// A registry whose listener claims the caller controls — the only thing that decides whether a
    /// child-facing socket path reaches a spawned child.
    fn registry_with(claims: Arc<Claims>) -> Arc<Registry> {
        let notify = Arc::new(|_notice: ExitedNotice| {});
        let sink: OutputSink = Arc::new(
            |_pane: &str,
             _offset: u64,
             _bytes: &[u8],
             _events: &[sniffer::SniffEvent],
             _blocks: &[blocks::BlockEvent]| {},
        );
        let paths = Paths::resolve(Some("/tmp/slopdesk-superd-test"), None, None);
        Arc::new(Registry::new(
            paths,
            claims,
            notify,
            sink,
            64 * 1024,
            Arc::new(JournalStore::start()),
        ))
    }

    /// A registry whose panes' bytes are collected, for the tests that care what the pump saw.
    #[expect(
        clippy::type_complexity,
        reason = "a test fixture's tuple, read once at each call site"
    )]
    fn registry_watching_output() -> (
        Arc<Registry>,
        mpsc::Receiver<ExitedNotice>,
        mpsc::Receiver<(String, u64, Vec<u8>)>,
    ) {
        let (sender, receiver) = mpsc::channel();
        let notify = Arc::new(move |notice: ExitedNotice| {
            let _ignored = sender.send(notice);
        });
        let (bytes_out, bytes_in) = mpsc::channel();
        let sink: OutputSink = Arc::new(
            move |pane_id: &str,
                  offset: u64,
                  bytes: &[u8],
                  _events: &[sniffer::SniffEvent],
                  _blocks: &[blocks::BlockEvent]| {
                let _ignored = bytes_out.send((pane_id.to_owned(), offset, bytes.to_vec()));
            },
        );
        let paths = Paths::resolve(Some("/tmp/slopdesk-superd-test"), None, None);
        // Bound but unclaimed — no hostd is serving anything, which is what the pane-lifecycle
        // tests here are about. The environment overlay has its own two tests below.
        let claims = Arc::new(Claims::bound());
        (
            Arc::new(Registry::new(
                paths,
                claims,
                notify,
                sink,
                64 * 1024,
                Arc::new(JournalStore::start()),
            )),
            receiver,
            bytes_in,
        )
    }

    fn request(pane_id: &str, script: &str) -> SpawnRequest {
        SpawnRequest {
            pane_id: pane_id.to_owned(),
            session_id: "session".to_owned(),
            executable: "/bin/sh".to_owned(),
            argv0: None,
            arguments: vec!["-c".to_owned(), script.to_owned()],
            environment: BTreeMap::new(),
            cwd: Some("/tmp".to_owned()),
            rows: 24,
            cols: 80,
            journal: None,
            owner: None,
            // `/bin/sh` is not a zsh, so asking for it here would only exercise the skip.
            shell_integration: false,
            // The block tap has its own suite; a pane here is about lifetime, not about what it said.
            blocks: None,
        }
    }

    /// The pane's bytes reach its transcript, and the head superd answers with is where the file
    /// actually stops.
    ///
    /// That pairing is the whole of stage 27: hostd restores everything in the file and subscribes
    /// at the head, so a head that disagreed with the file by one byte would either print a line
    /// twice or lose one, on every restart.
    #[test]
    fn a_journaled_pane_writes_its_transcript_and_agrees_about_where_it_stops() {
        let (registry, _exits) = registry();
        let directory = std::env::temp_dir().join("slopdesk-superd-registry-journal");
        drop(std::fs::remove_dir_all(&directory));
        // Still running when the head is read: a reaped pane has no head to answer with, which is
        // the ordinary state of every journal a restore looks at and is asserted separately below.
        let mut asked = request("pane-j", "printf 'hello journal\n'; sleep 30");
        asked.session_id = "S-JOURNAL".to_owned();
        asked.journal = Some(crate::protocol::JournalSpawn {
            directory: directory.display().to_string(),
            cap_bytes: 1 << 20,
        });
        registry.spawn(&asked, 1).unwrap();

        let path = crate::journal::journal_path(&directory, "S-JOURNAL");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut written = Vec::new();
        while std::time::Instant::now() < deadline {
            registry.journals.sync("pane-j");
            written = std::fs::read(&path).unwrap_or_default();
            if !written.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(
            String::from_utf8_lossy(&written).contains("hello journal"),
            "the pane's own output should be in its transcript, got {:?}",
            String::from_utf8_lossy(&written)
        );
        assert_eq!(
            registry.journals.head("pane-j"),
            Some(written.len() as u64),
            "the resume point is the file's end, not a number written down beside it"
        );

        // Releasing the pane keeps the file: "hostd is done with this pane" is not "this history is
        // over", and only the caller knows which it meant.
        registry.release("pane-j", true).unwrap();
        assert!(path.exists(), "a release keeps the transcript");
        assert_eq!(
            registry.journals.head("pane-j"),
            None,
            "and with the pane goes the only process that could number its stream"
        );
        registry.journals.delete(&directory, "S-JOURNAL");
        assert!(!path.exists(), "and the delete verb is what removes it");
    }

    /// The daemon's whole reason for existing, as one test: the client that spawned the pane goes
    /// away, and the child keeps running because superd never let go of the master.
    #[test]
    fn a_detached_pane_stays_alive_and_can_be_adopted_back() {
        let (registry, _exits) = registry();
        let (record, first_master) = registry
            .spawn(&request("pane-a", "while :; do printf tick; sleep 0.05; done"), 1)
            .unwrap();
        assert!(record.attached);
        // hostd's duplicate, dropped where hostd dies below. Closing it must change nothing: the
        // registry holds its own, and that is the whole claim of this test.
        drop(first_master);

        // hostd dies. Nothing is closed; one boolean changes.
        assert_eq!(registry.detach_client(1).unwrap(), 1);
        let listed = registry.list().unwrap();
        assert_eq!(listed.len(), 1);
        assert!(!listed.first().unwrap().attached, "live but unattached");

        // The child is still there and still writing — watched through the ring the pump fills,
        // because the pump is the only thing allowed to read a master. A raw read here would
        // consume the very `tick` it is waiting for and then park until the next one.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut produced = 0;
        while produced == 0 && std::time::Instant::now() < deadline {
            produced = registry
                .resume("pane-a", 0)
                .map_or(0, |(resumed, _ended)| resumed.bytes.len());
            if produced == 0 {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        assert!(produced > 0, "the child should still be producing output");

        // A new hostd takes it back.
        let (readopted, _readopted_master) = registry.adopt("pane-a", 2).unwrap();
        assert!(readopted.attached);
        assert_eq!(readopted.pid, record.pid, "same process, not a fresh one");

        registry.release("pane-a", true).unwrap();
    }

    /// `release` is the only caller-driven close, and it must actually stop the child.
    #[test]
    fn release_kills_the_child_and_forgets_the_pane() {
        let (registry, exits) = registry();
        registry.spawn(&request("pane-b", "sleep 30"), 1).unwrap();
        registry.release("pane-b", true).unwrap();

        assert!(registry.list().unwrap().is_empty());
        assert!(matches!(
            registry.adopt("pane-b", 1),
            Err(RegistryError::UnknownPane(_))
        ));
        // A released pane owes nobody an `exited` — hostd asked for this and already knows.
        assert!(exits.recv_timeout(std::time::Duration::from_millis(300)).is_err());
    }

    /// A child that exits on its own must produce exactly one `exited`, and free the pane id.
    #[test]
    fn a_child_that_exits_reports_once_and_frees_its_id() {
        let (registry, exits) = registry();
        registry.spawn(&request("pane-c", "exit 3"), 1).unwrap();

        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.pane_id, "pane-c");
        assert_eq!(notice.code, 3);
        assert!(registry.list().unwrap().is_empty());

        // The id is reusable, because the record is gone rather than tombstoned.
        assert!(registry.spawn(&request("pane-c", "exit 0"), 1).is_ok());
    }

    /// The descriptor a spawn hands back outlives the pane it came from.
    ///
    /// `exit 0` is the shape that made this a live bug rather than a theoretical one: the child is
    /// usually already reaped by the time the reply is being assembled, and the reaper's first act
    /// is to remove the pane and drop its master. While the fd was looked up a second time, by
    /// name, that lookup lost the race — hostd was answered `ok` with no descriptor attached and
    /// reported `missingDescriptor` for a child that really had run, and the same window could
    /// instead hand over a raw fd number the reaper had closed and the kernel had reissued to
    /// something else entirely. Taking the duplicate inside `spawn` closes both: what comes back is
    /// an open file, and it stays one no matter what the reaper does next.
    #[test]
    fn the_spawned_descriptor_survives_the_pane_being_reaped() {
        let (registry, exits) = registry();
        let (record, master) = registry.spawn(&request("pane-instant", "exit 0"), 1).unwrap();

        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.pane_id, "pane-instant");
        assert_eq!(notice.pid, record.pid);
        assert!(
            registry.list().unwrap().is_empty(),
            "the reaper should have removed the pane by now — without that this proves nothing",
        );

        // Still a terminal, still ours. `tcgetattr` is the cheapest question only a live tty
        // answers: a closed fd gives `EBADF`, and a number reissued to a pipe or a file gives
        // `ENOTTY`.
        assert!(
            nix::sys::termios::tcgetattr(&master).is_ok(),
            "the descriptor handed to hostd must still name this pane's master",
        );
    }

    #[test]
    fn a_signalled_child_reports_128_plus_signal() {
        let (registry, exits) = registry();
        let (record, _master) = registry.spawn(&request("pane-d", "sleep 30"), 1).unwrap();
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(record.pid), Signal::SIGKILL).unwrap();
        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.code, 128 + libc::SIGKILL);
    }

    /// The teardown ladder's hangup is addressed at the SHELL, not at the job it is running.
    ///
    /// The pane here is a session leader that hands the terminal to a child in its own process
    /// group — the shape of an interactive shell running a foreground job, which is when the two
    /// targets stop being the same pid. Routing a `SIGHUP` at the foreground group would kill the
    /// job and leave the shell waiting, and `MuxChannelSession`'s ladder depends on the opposite:
    /// zsh writes `$HISTFILE` from its own hangup handler, so a hangup the shell never sees is a
    /// session's typed history thrown away.
    ///
    /// Exit 7 is the leader's own handler; a leader that never heard the signal is still asleep
    /// when the receive times out.
    #[test]
    fn a_hangup_reaches_the_session_leader_past_a_foreground_job() {
        let (registry, exits) = registry();
        let (record, master) = registry
            .spawn(&leader_holding_a_foreground_job("pane-hup"), 1)
            .unwrap();

        // Wait for the fixture to hand the terminal over — before that moment the two targets are
        // the same pid and the assertion below would pass either way.
        assert!(
            wait_for_a_foreground_job(master.as_fd(), record.pid),
            "fixture never put its job in the foreground — the test cannot tell the targets apart",
        );

        registry.signal("pane-hup", libc::SIGHUP).unwrap();
        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.code, 7, "the leader's own SIGHUP handler must have run");
    }

    /// An interrupt goes the other way: at whatever the shell is running.
    ///
    /// Same fixture, so the same two pids are in play. `SIGINT` at the leader would end the session
    /// to interrupt one job; at the foreground group it kills the job, and the leader — which
    /// ignores `SIGINT` here — lives on to be released.
    #[test]
    fn an_interrupt_reaches_the_foreground_job_and_spares_the_leader() {
        let (registry, exits) = registry();
        let (record, master) = registry
            .spawn(&leader_holding_a_foreground_job("pane-int"), 1)
            .unwrap();
        assert!(wait_for_a_foreground_job(master.as_fd(), record.pid));

        registry.signal("pane-int", libc::SIGINT).unwrap();
        assert!(
            exits.recv_timeout(std::time::Duration::from_millis(750)).is_err(),
            "the leader must survive an interrupt aimed at its foreground job",
        );
        registry.release("pane-int", true).unwrap();
    }

    /// A stale reaper must not evict the pane that inherited its id.
    ///
    /// Pane ids come back: hostd re-spawns a pane under the pane's own UUID, and a `service:<name>`
    /// id is stable by design (`docs/51` §6.7), so a panel backend that dies and is respawned lands
    /// on exactly this. Removing by name alone would let the old child's `waitpid`, returning at
    /// any moment afterwards, delete a live pane and announce it dead.
    #[test]
    fn a_reaper_whose_pid_is_stale_leaves_the_reused_id_alone() {
        let (registry, exits, output) = registry_watching_output();
        // `trap "" HUP` outlives the master close in `release`, so the old child is still running —
        // and its reaper still parked in `waitpid` — while the id is re-used. That is the window.
        // The marker is what makes it a window rather than a race: releasing before the shell has
        // run its `trap` closes the master on a child still carrying the default disposition, and
        // the hangup kills it there and then.
        let (old, _old_master) = registry
            .spawn(&request("pane-reuse", "trap '' HUP; printf READY; sleep 30"), 1)
            .unwrap();
        wait_for_marker(&output, "READY");
        registry.release("pane-reuse", false).unwrap();

        let (fresh, _fresh_master) = registry.spawn(&request("pane-reuse", "sleep 30"), 1).unwrap();
        assert_ne!(fresh.pid, old.pid);

        nix::sys::signal::kill(nix::unistd::Pid::from_raw(old.pid), Signal::SIGKILL).unwrap();
        assert!(
            exits.recv_timeout(std::time::Duration::from_secs(2)).is_err(),
            "a dead pid whose id was re-used owes nobody an `exited`",
        );
        let listed = registry.list().unwrap();
        assert_eq!(listed.len(), 1, "the live pane must still be supervised");
        assert_eq!(listed.first().unwrap().pid, fresh.pid);

        registry.release("pane-reuse", true).unwrap();
    }

    /// Blocks until a pane's foreground process group is a real group OTHER than its leader — the
    /// moment [`leader_holding_a_foreground_job`] has actually handed the terminal over.
    ///
    /// Both halves matter. A `tcgetpgrp` that has not settled yet answers 0 or an error, and taking
    /// that for "the job is in front" would signal a leader that has not installed its handlers,
    /// which is the default disposition and a dead pane.
    fn wait_for_a_foreground_job(master: BorrowedFd<'_>, leader: i32) -> bool {
        let master = master.as_raw_fd();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::time::Instant::now() < deadline {
            if pty::foreground_process_group(master).is_ok_and(|group| group > 0 && group != leader) {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        false
    }

    /// Blocks until a pane prints `marker`, the child's own word that it has reached the state the
    /// test is about. Panics on timeout, which is the failure report.
    fn wait_for_marker(output: &mpsc::Receiver<(String, u64, Vec<u8>)>, marker: &str) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut seen = String::new();
        while std::time::Instant::now() < deadline && !seen.contains(marker) {
            if let Ok((_pane, _offset, bytes)) = output.recv_timeout(std::time::Duration::from_millis(250)) {
                seen.push_str(&String::from_utf8_lossy(&bytes));
            }
        }
        assert!(
            seen.contains(marker),
            "the child never printed {marker} — saw {seen:?}"
        );
    }

    /// A pane that becomes a session leader, forks a job into its own process group and hands it
    /// the terminal — the only arrangement in which "the session" and "the foreground group" are
    /// different pids, which is what the two signal-routing tests need.
    ///
    /// perl rather than a shell: a non-interactive `sh` runs its children in its OWN process group
    /// (no job control), so the two targets would coincide and neither test could fail. Exit 7 on
    /// `SIGHUP`, ignore `SIGINT`, sleep otherwise.
    fn leader_holding_a_foreground_job(pane_id: &str) -> SpawnRequest {
        let program = "use POSIX; $SIG{HUP} = sub { exit 7 }; $SIG{INT} = 'IGNORE'; my $job = fork(); if \
                       ($job == 0) { setpgrp(0, 0); sleep 30; exit 0 } setpgrp($job, $job); \
                       POSIX::tcsetpgrp(0, $job); sleep 30; exit 0";
        SpawnRequest {
            executable: "/usr/bin/perl".to_owned(),
            arguments: vec!["-e".to_owned(), program.to_owned()],
            ..request(pane_id, "")
        }
    }

    /// Spawning the same id twice would orphan the first child — the second fork's record would
    /// overwrite the first's and nothing would ever close its master.
    #[test]
    fn duplicate_pane_id_is_refused() {
        let (registry, _exits) = registry();
        registry.spawn(&request("pane-e", "sleep 30"), 1).unwrap();
        assert!(matches!(
            registry.spawn(&request("pane-e", "sleep 30"), 1),
            Err(RegistryError::DuplicatePane(_))
        ));
        registry.release("pane-e", true).unwrap();
    }

    /// Runs `env` in a pane and returns everything the child printed.
    ///
    /// Read through the RING, never off the master. superd's pump owns the only `read` on a pane's
    /// master and drains it for the pane's whole life, so a second reader here does not observe the
    /// stream, it STEALS from it: the two race for each write and this helper gets an arbitrary
    /// subset of the environment, failing on a variable that really was there. Waiting for the
    /// stream to END is what makes an absence assertion (`!text.contains(…)`) mean anything.
    fn environment_the_child_saw(registry: &Arc<Registry>, pane_id: &str) -> String {
        let mut spawn_request = request(pane_id, "env; sleep 1");
        spawn_request.environment.insert(
            "SLOPDESK_SOCKET_PATH".to_owned(),
            "/tmp/slopdesk-agent-99999.sock".to_owned(),
        );
        spawn_request
            .environment
            .insert("PATH".to_owned(), "/usr/bin:/bin".to_owned());
        registry.spawn(&spawn_request, 1).unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut text = String::new();
        while let Ok((resumed, ended)) = registry.resume(pane_id, 0) {
            text = String::from_utf8_lossy(&resumed.bytes).into_owned();
            // `env` prints and exits, so the end of the stream is the end of the output. Anything
            // read before that is a prefix, and a prefix cannot answer "is this variable absent?".
            if ended || std::time::Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ignored = registry.release(pane_id, true);
        text
    }

    /// A socket nobody is serving is passed through as hostd sent it, and the pane id is
    /// guaranteed either way.
    ///
    /// This test asserted the opposite until 2026-08-11, and the code obliged: superd overwrote
    /// `SLOPDESK_SOCKET_PATH` with a stable path of its own that it never bound. Every spawned
    /// agent was handed the address of a socket with nothing behind it, and nothing failed
    /// loudly — Claude's hooks `POST`ed into the void and detection quietly fell back to the screen
    /// engine. The green test was the reason nobody looked.
    ///
    /// It is still the un-served case that is asserted here, but it now means something narrower
    /// and true: superd binds the socket, and no hostd has claimed it — a restart in progress.
    #[test]
    fn an_unserved_socket_path_is_passed_through_not_overwritten() {
        let registry = registry_with(Arc::new(Claims::bound()));
        let text = environment_the_child_saw(&registry, "pane-f");
        assert!(
            text.contains("SLOPDESK_SOCKET_PATH=/tmp/slopdesk-agent-99999.sock"),
            "hostd's value must reach the child while nobody serves the hook socket: {text}"
        );
        // The rest of hostd's environment is passed through untouched.
        assert!(text.contains("PATH=/usr/bin:/bin"), "{text}");
        // And the pane id superd guarantees.
        assert!(text.contains("SLOPDESK_PANE_ID=pane-f"), "{text}");
    }

    /// The override the test above described for a year and could not perform: with a hostd serving
    /// the hook listener, the child is told superd's stable, pid-free address instead of hostd's.
    ///
    /// This is the point of the whole daemon, reduced to one assertion. The value below outlives
    /// the hostd that spawned the child, so a `claude` mid-task keeps posting its hooks to a socket
    /// that is still bound after hostd is rebuilt.
    #[test]
    fn a_served_socket_path_overrides_what_hostd_sent() {
        let claims = Arc::new(Claims::bound());
        let _ignored = claims.claim(listener_kind::HOOK, 1);
        let registry = registry_with(claims);
        let text = environment_the_child_saw(&registry, "pane-f-served");
        assert!(
            text.contains("SLOPDESK_SOCKET_PATH=/tmp/slopdesk-superd-test/slopdesk-agent.sock"),
            "a served hook socket must override hostd's pid-keyed value: {text}"
        );
        // `control` was NOT claimed — hostd's ctl surface is default-off, and that is expressed as
        // a claim it does not make. superd must not advertise a listener nobody is behind.
        assert!(!text.contains("SLOPDESK_CONTROL_SOCKET="), "{text}");
    }

    /// A fork that never becomes a pane must still be reaped.
    ///
    /// `spawn` can fail AFTER the child exists (a `try_clone` or the pump's `pipe`, both EMFILE-
    /// shaped), and the reaper that would collect it is only started at the end of the happy path.
    /// The test never calls `waitpid` itself — that would race the reaper for the same child and
    /// prove nothing — it watches for the pid to leave the process table entirely: a zombie still
    /// answers `kill(pid, 0)`, so ESRCH is reached only by something having reaped it.
    #[test]
    fn a_fork_that_never_became_a_pane_is_still_reaped() {
        let (registry, _exits) = registry();
        let arguments = vec!["-c".to_owned(), "sleep 30".to_owned()];
        let environment = vec!["PATH=/usr/bin:/bin".to_owned()];
        let spawned = pty::spawn_pty(&pty::SpawnPlan {
            executable: "/bin/sh",
            argv0: None,
            arguments: &arguments,
            environment: &environment,
            cwd: Some("/tmp"),
            rows: 24,
            cols: 80,
        })
        .unwrap();
        let pid = spawned.pid;

        registry.abandon("pane-never-recorded", pid);
        // What `spawn`'s error return does a line later: superd's master goes, so the child hangs
        // up and dies. The reaper started by `abandon` is what collects the corpse.
        drop(spawned);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None),
            Err(nix::errno::Errno::ESRCH),
            "an abandoned child must be reaped, not left as a permanent zombie"
        );
    }

    /// Two spawns of one id, at once, and only one child comes out of it.
    ///
    /// The duplicate check cannot hold the pane lock across the fork, so before the reservation it
    /// was advisory: both callers passed `contains_key`, both forked a real shell, and the second
    /// insert overwrote the first pane — dropping its master, pump and pid out of the map with no
    /// `abandon`, which is a running child superd can no longer list, kill or reap. The only thing
    /// standing there was a `debug_assert!`, absent from the `--release` build `make superd`
    /// produces. Both threads race the same id; whichever loses must be told `DuplicatePane`.
    #[test]
    fn two_spawns_of_one_pane_id_produce_exactly_one_pane() {
        let (registry, _exits) = registry();
        let first = Arc::clone(&registry);
        let second = Arc::clone(&registry);
        let racing = std::thread::spawn(move || first.spawn(&request("pane-race", "sleep 30"), 1));
        let here = second.spawn(&request("pane-race", "sleep 30"), 2);
        let there = racing.join().unwrap();

        let outcomes = [here, there];
        let winners = outcomes.iter().filter(|result| result.is_ok()).count();
        assert_eq!(winners, 1, "exactly one spawn of a pane id may succeed");
        assert!(
            outcomes.iter().any(|result| {
                matches!(
                    result,
                    Err(RegistryError::DuplicatePane(id)) if id == "pane-race"
                )
            }),
            "the loser must be told the id is taken, not silently given a second child"
        );
        assert_eq!(
            registry.list().unwrap().len(),
            1,
            "and superd must hold exactly one pane for that id"
        );
        let _ignored = registry.release("pane-race", true);
    }

    /// The verb records, and ONLY records.
    ///
    /// The terminal itself must come out of it byte-identical, pixel fields included. hostd applied
    /// the size through its own duplicate before it sent this, and it is the only writer: a second
    /// `TIOCSWINSZ` here is a stale write racing hostd's next one, which is how the cold-reattach
    /// redraw jiggle lost its shrink and left a `claude` frame half-painted.
    #[test]
    fn resize_records_the_size_without_touching_the_terminal() {
        let (registry, _exits) = registry();
        let (_record, held) = registry.spawn(&request("pane-g", "sleep 30"), 1).unwrap();

        // What hostd does, in one ioctl of its own: cells AND pixels — through the duplicate the
        // spawn handed back, which is exactly the descriptor hostd would be holding.
        let master = held.as_raw_fd();
        pty::set_window_size(master, libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 1280,
            ws_ypixel: 800,
        })
        .unwrap();

        registry.resize("pane-g", 40, 100).unwrap();

        let listed = registry.list().unwrap();
        let record: &PaneRecord = listed.first().unwrap();
        assert_eq!((record.rows, record.cols), (40, 100));

        let live = pty::window_size(master).unwrap();
        assert_eq!(
            (live.ws_row, live.ws_col),
            (24, 80),
            "superd must not re-apply a size hostd already owns"
        );
        assert_eq!(
            (live.ws_xpixel, live.ws_ypixel),
            (1280, 800),
            "and least of all the pixel geometry it was never told"
        );
        registry.release("pane-g", true).unwrap();
    }

    /// The product promise, at the registry level: hostd is gone, and the pane keeps working.
    ///
    /// Before the pump, this test could not have been written. The child would fill the kernel's
    /// PTY buffer within a few KB and block there until somebody read the master, so "kept
    /// producing while unattached" was true only for the first few KB and then quietly false.
    #[test]
    fn an_unattached_pane_keeps_producing_and_its_bytes_are_recoverable() {
        let (registry, _exits, _output) = registry_watching_output();
        // 200 lines is comfortably past any PTY buffer, and the `sleep` keeps the pane alive
        // afterwards so the read below is not racing an exit.
        registry
            .spawn(
                &request(
                    "pane-pump",
                    "i=0; while [ $i -lt 200 ]; do echo line-$i; i=$((i+1)); done; sleep 30",
                ),
                1,
            )
            .unwrap();
        // hostd dies before reading a single byte.
        assert_eq!(registry.detach_client(1).unwrap(), 1);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let (mut resumed, _ended) = registry.resume("pane-pump", 0).unwrap();
        while !String::from_utf8_lossy(&resumed.bytes).contains("line-199")
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(20));
            resumed = registry.resume("pane-pump", 0).unwrap().0;
        }
        let text = String::from_utf8_lossy(&resumed.bytes).into_owned();
        assert!(
            text.contains("line-0") && text.contains("line-199"),
            "the whole run must be there, start to finish, with nobody attached"
        );
        assert!(!resumed.is_lossy(0));

        registry.release("pane-pump", true).unwrap();
    }

    /// A shell's farewell must not arrive after news of its death. The reaper drains the pump
    /// before it notifies; without that the two threads race and the output loses about half.
    #[test]
    fn a_panes_last_bytes_are_published_before_its_exit_notice() {
        let (registry, exits, output) = registry_watching_output();
        registry
            .spawn(&request("pane-last", "printf 'farewell\\n'; exit 7"), 1)
            .unwrap();

        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.code, 7);

        // Everything the sink was ever going to receive is already queued by the time the notice
        // lands, so a non-blocking drain suffices — which is exactly the property being pinned.
        let mut seen = String::new();
        while let Ok((pane_id, _offset, bytes)) = output.try_recv() {
            assert_eq!(pane_id, "pane-last");
            seen.push_str(&String::from_utf8_lossy(&bytes));
        }
        assert!(
            seen.contains("farewell"),
            "output after the exit notice: {seen:?}"
        );
    }

    /// The pane a `spawn` reply outlives by a hair. `slopdesk-ctl spawn --cmd ls` finishes and is
    /// reaped while hostd's `subscribe` is still in flight, and before the graveyard that lost
    /// every byte of it: the pane rendered empty.
    #[test]
    fn a_pane_that_exits_before_anyone_subscribes_still_has_its_output() {
        let (registry, exits, _output) = registry_watching_output();
        registry
            .spawn(&request("pane-quick", "printf 'all of it\\n'"), 1)
            .unwrap();
        // Wait for the reaper, so the subscribe below is unambiguously the late one.
        let notice = exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        assert_eq!(notice.pane_id, "pane-quick");

        // An exited pane keeps its output until somebody reads it or releases it.
        let (resumed, ended) = registry.resume("pane-quick", 0).unwrap();
        assert!(
            String::from_utf8_lossy(&resumed.bytes).contains("all of it"),
            "the whole run must survive the child: {:?}",
            String::from_utf8_lossy(&resumed.bytes)
        );
        assert!(ended, "a reaped pane's stream is finished and must say so");

        // And the teardown that follows forgets it, rather than reporting a pane hostd knows it has.
        // Releasing an exited pane is ordinary teardown, not an error.
        registry.release("pane-quick", false).unwrap();
        assert!(matches!(
            registry.resume("pane-quick", 0),
            Err(RegistryError::UnknownPane(_))
        ));
    }

    /// The graveyard is a grace period, not a second pane table — a hostd that never subscribes
    /// must not be able to grow it without bound.
    #[test]
    fn the_graveyard_forgets_its_oldest_pane_once_it_is_full() {
        let (registry, exits, _output) = registry_watching_output();
        for index in 0..=GRAVEYARD_PANES {
            registry
                .spawn(&request(&format!("pane-{index}"), "printf 'x\\n'"), 1)
                .unwrap();
            exits.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        }
        assert!(
            matches!(registry.resume("pane-0", 0), Err(RegistryError::UnknownPane(_))),
            "the first pane must have been evicted"
        );
        assert!(
            registry.resume(&format!("pane-{GRAVEYARD_PANES}"), 0).is_ok(),
            "the newest pane must still be there"
        );
    }

    /// Releasing a pane joins its reader before closing the master. The visible half of that
    /// contract is that the pane really does stop and really does die.
    #[test]
    fn releasing_a_pumped_pane_stops_the_reader_and_the_child() {
        let (registry, _exits, _output) = registry_watching_output();
        let (record, _master) = registry
            .spawn(
                &request("pane-stop", "while :; do echo tick; sleep 0.02; done"),
                1,
            )
            .unwrap();
        registry.release("pane-stop", true).unwrap();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while nix::sys::signal::kill(nix::unistd::Pid::from_raw(record.pid), None).is_ok()
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(record.pid), None).is_err(),
            "a released pane must actually end"
        );
        assert!(matches!(
            registry.resume("pane-stop", 0),
            Err(RegistryError::UnknownPane(_))
        ));
    }
}
