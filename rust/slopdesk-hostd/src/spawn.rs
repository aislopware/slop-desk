//! The [`Spawner`]: a resolved decision in, a running pane out.
//!
//! ## What the composition already did, and what is left
//! Everything about WHICH pane — the executable, the argv, the curated environment, the resolved
//! cwd, whether the shim goes on, whether it earns a journal — was decided by
//! [`slopdesk_hostserver`] before any of these methods is called, and all of it is assertable
//! without a PTY. What is left here is the two things a fake could never do: ask superd to fork,
//! and build the session around the master that comes back.
//!
//! ## The recipe is built ONCE, and a pane assembles from it
//! Every ingredient below is a fact about the PROCESS — an environment gate, a socket, a policy —
//! and reading one per pane would let two panes forked an hour apart differ because something
//! `setenv`'d in between. So [`Recipe`] is filled at start-up and every spawn is an assembly from
//! it, which is the same rule `HostEnv` follows one layer up and the reason this type is testable
//! against fakes at all.
//!
//! ## Three doors in, one build
//! `spawn` (ctl), `open` (a mux channel) and `adopt` (a shell that outlived the last hostd) differ
//! in how the master is obtained and almost nowhere else, so they share [`Recipe::assemble`] and
//! each contributes the two or three facts that are its own: where the stream resumes, whether a
//! client is attached, and what history precedes the first live byte.
//!
//! ## A standalone pane needs no null channels
//! The Swift built a pair of null sub-channels for a ctl-spawned pane so its relay loops would exit
//! and the offline gate would engage. Nothing here does, because `Shared::recompute_client_online`
//! is `member_count() > 0`: a session with an empty roster IS the offline shape. The null objects
//! existed to satisfy a constructor, not a behaviour.

use std::sync::Arc;
use std::time::Duration;

use slopdesk_hostpane::PtyProcess;
use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{Adopted, Fresh, LivePane, Pane, Restored, Spawner, Standalone};
use slopdesk_hostsession::{
    DetectConfig, Eviction, PaneSession, ScreenOracle, SessionConfig, SessionLog, SnapshotPolicy,
};
use slopdesk_muxsession::registry::Uuid;
use slopdesk_superclient::client::SupervisorClient;
use slopdesk_superwire::protocol::{BlocksRequest, SpawnRequest};
use slopdesk_wire::replay::{ReplayBuffer, ScrollbackDistiller};

use crate::evict::{HostEviction, LateHost};
use crate::keys::{ProjectKeySink, WatchKeys};
use crate::resolve::SerialResolve;
use crate::transcripts::DiskTranscripts;

/// Everything a pane is assembled from that is the PROCESS's rather than the request's.
///
/// Sixteen fields and a public constructor would be a positional call nobody could read, so it is
/// filled field-by-field by the assembly — the same shape, and the same reason, as `HostParts`.
#[derive(Debug)]
pub struct Recipe {
    /// superd. Every fork, adopt and subscribe goes through it.
    pub supervisor: Arc<SupervisorClient>,
    /// How superd records which hostd owns a pane, so a second daemon's sweep can tell them apart.
    pub owner: String,
    /// Where a session's lines go.
    pub log: Arc<dyn SessionLog>,
    /// The disk-scrollback policy, or `None` when journalling is off.
    pub transcripts: Option<Arc<DiskTranscripts>>,
    /// The state-transfer composer, or `None` for raw replay on every reattach.
    pub snapshot: Option<Arc<dyn SnapshotPolicy>>,
    /// Where a screen scan asks its question, or `None` to run no scan loop.
    pub oracle: Option<Arc<dyn ScreenOracle>>,
    /// The repo-watch refcounts, or `None` on a host that watches nothing.
    pub keys: Option<Arc<dyn ProjectKeySink>>,
    /// The composition, once it exists — see [`crate::evict`].
    pub late_host: Arc<LateHost>,
    /// The ring's scrollback cap. `0` keeps no history at all.
    pub scrollback_bytes: usize,
    /// Whether the ring's cold replay runs the line-editor collapse.
    pub distill: bool,
    /// The laggard threshold. `0` disables eviction.
    pub lag_bytes: u64,
    /// How often the foreground poll samples.
    pub poll_interval: Duration,
    /// How long a finished turn stays `done` before decaying to `idle`.
    pub done_to_idle: f64,
    /// The latest-wins window before a resolved grid reaches `TIOCSWINSZ`.
    pub resize_debounce: Duration,
    /// The longer window a contributor-set change arms.
    pub size_settle: Duration,
    /// The block-segmenter parameters, sent with a spawn whose request asked for blocks.
    pub blocks: BlocksRequest,
}

impl Recipe {
    /// The pane id superd files this session under.
    ///
    /// The session UUID's own text, and deliberately nothing composite: the string is baked into
    /// the child's environment as `SLOPDESK_PANE_ID` and does not change when the client
    /// reattaches, so a key derived from the session is the key a reattach already has rather
    /// than one it has to remember.
    fn pane_id(session: Uuid) -> String {
        slopdesk_ids::uuid_text(session)
    }

    /// The ring this host's panes are built with.
    ///
    /// The distiller is [`slopdesk_sanitize`]'s, with `reassert_input_modes` TRUE — the ring fronts
    /// a LIVE session, so a TUI that is still running needs its modes re-established after the
    /// stripped replay. The journal path passes false through the same function, and that one bool
    /// is the whole difference between the two restore chains.
    fn ring(&self) -> ReplayBuffer {
        let distill = self.distill;
        let distiller: ScrollbackDistiller = Arc::new(move |bytes: &[u8]| {
            slopdesk_sanitize::sanitize(bytes, slopdesk_sanitize::Options {
                reassert_input_modes: true,
                distill,
            })
        });
        ReplayBuffer::with_scrollback(self.scrollback_bytes).distilling(distiller)
    }

    /// The eviction policy for the pane serving `session`.
    fn eviction(&self, session: Uuid) -> Eviction {
        if self.lag_bytes == 0 {
            return Eviction::off();
        }
        Eviction {
            lag_bytes: self.lag_bytes,
            seam: Arc::new(HostEviction::new(&self.late_host, session)),
        }
    }

    /// The block request for a spawn, or `None` when this pane is not to be tapped.
    ///
    /// A tap cannot be added to a shell that is already running — superd holds the block ring — so
    /// the decision is made HERE, at the fork, and never revisited.
    fn blocks(&self, wanted: bool) -> Option<BlocksRequest> {
        wanted.then(|| self.blocks.clone())
    }

    /// The session config every pane shares, before the per-door facts are laid on it.
    ///
    /// `keys` is returned alongside because the same object is BOTH the key observer and the close
    /// tap that releases the refcount — and the tap can only be installed on a session that exists.
    fn assemble(
        &self,
        session: Uuid,
        exit: Arc<dyn slopdesk_hostsession::SessionObserver>,
        status: Arc<dyn slopdesk_hostsession::StatusObserver>,
        blocks_enabled: bool,
    ) -> (SessionConfig, Option<Arc<WatchKeys>>) {
        let pane_key = Self::pane_id(session);
        let mut config = SessionConfig::new(Arc::clone(&self.log), exit);
        config.replay = self.ring();
        config.status = status;
        config.snapshot.clone_from(&self.snapshot);
        config.resize_debounce = self.resize_debounce;
        config.size_settle = self.size_settle;
        config.evict = self.eviction(session);
        config.blocks_enabled = blocks_enabled;
        config.resolve = Arc::new(SerialResolve::new(&pane_key));
        config.detect = DetectConfig {
            // No gate: agent detection is the pane's primary presence signal and the clock that
            // decays a finished turn, and it is cheap enough to run on every pane, always. The
            // EXPENSIVE half is the screen scan, and that one is gated — by whether an oracle
            // exists at all.
            foreground: true,
            poll_interval: self.poll_interval,
            screen: self.oracle.clone(),
            pane_key,
            done_to_idle: self.done_to_idle,
        };
        let keys = self.keys.as_ref().map(|sink| {
            let watching = Arc::new(WatchKeys::new(sink, crate::keys::mint_owner()));
            config.project_keys = Arc::<WatchKeys>::clone(&watching);
            watching
        });
        (config, keys)
    }
}

/// hostd's [`Spawner`]: superd on one side, a [`PaneSession`] on the other.
#[derive(Debug)]
pub struct PaneSpawner {
    recipe: Recipe,
}

impl PaneSpawner {
    /// Spawns every pane from `recipe`.
    #[must_use]
    pub const fn new(recipe: Recipe) -> Self {
        Self { recipe }
    }

    /// Builds the pane around `pty`, installs its taps, and seeds any restored history.
    ///
    /// The seed is the LAST thing before the caller starts the pane, and that ordering is the whole
    /// contract: restored history must precede every live byte, and the read loop is what produces
    /// a live byte. See [`PaneSession::seed_restored`].
    fn wrap(
        pty: &Arc<PtyProcess>,
        config: SessionConfig,
        keys: Option<Arc<WatchKeys>>,
        restored: Option<Restored>,
    ) -> Arc<PaneSession> {
        let built = PaneSession::new(Arc::clone(pty), config);
        if let Some(watching) = keys {
            // The refcount's release. Installed on the SESSION rather than driven from the host's
            // close ladder because that ladder has four ends and a refcount released on only some of
            // them is a repo watched for the life of the process.
            let _token = built.add_close_tap(watching);
        }
        if let Some(history) = restored {
            built.seed_restored(history.bytes);
        }
        built
    }

    /// superd's refusal, in the composition's vocabulary.
    fn refused(why: &slopdesk_superclient::client::ClientError) -> SpawnRefused {
        SpawnRefused(format!("{why}"))
    }
}

impl Spawner for PaneSpawner {
    fn spawn(&self, request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
        let pty = Arc::new(PtyProcess::new(Arc::clone(&self.recipe.supervisor)));
        pty.spawn(SpawnRequest {
            pane_id: Recipe::pane_id(request.session),
            session_id: slopdesk_ids::uuid_text(request.session),
            executable: request.executable.clone(),
            argv0: Some(request.argv0.clone()),
            arguments: request.argv.clone(),
            environment: request.env.clone(),
            cwd: request.cwd.map(str::to_owned),
            rows: request.rows,
            cols: request.cols,
            owner: Some(self.recipe.owner.clone()),
            shell_integration: request.shell_integration,
            // No journal, and that is not an oversight: a ctl-spawned pane may be a raw command
            // whose transcript nothing will ever re-present, and journalling it would produce a file
            // whose only future is being swept.
            journal: None,
            blocks: self.recipe.blocks(request.blocks),
        })
        .map_err(|why| Self::refused(&why))?;
        let (config, keys) = self.recipe.assemble(
            request.session,
            Arc::clone(&request.exit),
            Arc::clone(&request.status),
            request.blocks,
        );
        let session = Self::wrap(&pty, config, keys, None);
        Ok(LivePane::adopt(session, request.session))
    }

    fn start(&self, pane: &Arc<dyn Pane>, cwd: Option<&str>) {
        pane.start();
        // AFTER the start, so the control this enqueues rides a live sender. A pane that requested
        // no directory still lands in a real one, and skipping its seed would leave it outside every
        // project section until an OSC-7 edge an unshimmed shell never sends.
        if let Some(cwd) = cwd.filter(|cwd| !cwd.is_empty()) {
            pane.seed_project(cwd);
        }
    }

    fn open(&self, request: Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
        let pty = Arc::new(PtyProcess::new(Arc::clone(&self.recipe.supervisor)));
        let session_text = slopdesk_ids::uuid_text(request.session);
        pty.spawn(SpawnRequest {
            pane_id: Recipe::pane_id(request.session),
            session_id: session_text.clone(),
            executable: request.executable.clone(),
            argv0: Some(request.argv0.clone()),
            arguments: Vec::new(),
            environment: request.env.clone(),
            cwd: request.cwd.map(str::to_owned),
            // The `openpty` default. A mux client's real grid arrives moments later as a size offer
            // and the fold applies it; spawning at the client's first guess instead would only move
            // the `SIGWINCH` earlier, not remove it.
            rows: FALLBACK_ROWS,
            cols: FALLBACK_COLS,
            owner: Some(self.recipe.owner.clone()),
            // Always: a mux channel is an interactive login shell, which is the one pane shape
            // prompt machinery applies to.
            shell_integration: true,
            journal: request
                .journal
                .then(|| self.recipe.transcripts.as_ref()?.spawn_request(&session_text))
                .flatten(),
            blocks: self.recipe.blocks(request.blocks),
        })
        .map_err(|why| Self::refused(&why))?;
        let (mut config, keys) = self.recipe.assemble(
            request.session,
            Arc::clone(&request.exit),
            Arc::clone(&request.status),
            request.blocks,
        );
        // Usually 0 — this shell was forked a moment ago and has no history to arrive twice. But the
        // fork may have found superd ALREADY holding this id and taken that shell over, and then the
        // supervised ring holds the same bytes the restore below does: subscribing from 0 would
        // print the user's whole history a second time and re-feed the sniffer and the block ledger
        // with it. Only the fork knows which happened, which is why both offsets rode in together.
        config.resume_from = if pty.took_over_a_survivor() {
            request.resume_takeover
        } else {
            0
        };
        config.opened_size_passive = request.size_passive;
        let session = Self::wrap(&pty, config, keys, request.restored);
        // The client's two lanes, admitted BEFORE the seed and the start: a member added afterwards
        // would have a cursor above frames already sequenced, and would open on a pane that had
        // apparently emitted nothing.
        let _first = session.attach(
            request.wires.data,
            request.wires.data_inbound,
            request.wires.control,
            request.wires.control_inbound,
            request.size_passive,
        );
        Ok(LivePane::adopt(session, request.session))
    }

    fn adopt(&self, request: Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
        let pty = Arc::new(PtyProcess::new(Arc::clone(&self.recipe.supervisor)));
        pty.adopt(request.pane_id).map_err(|why| Self::refused(&why))?;
        let (mut config, keys) = self.recipe.assemble(
            request.session,
            // A pane taken back at start-up has no client and no channel to close, so its exit is
            // nobody's to relay yet. The host parks it and installs the real observer when a client
            // reattaches.
            Arc::new(slopdesk_hostsession::SilentObserver),
            Arc::clone(&request.status),
            request.blocks,
        );
        config.resume_from = request.resume_from;
        // The SIZE is deliberately not re-asserted here. The kernel's `winsize` on this master is
        // the live truth and survived the restart intact, while superd's record is only what the
        // last hostd told it — a pane whose client never resized still carries the spawn-time 24×80,
        // and writing that back would `SIGWINCH` a 200×50 agent into re-wrapping at 80 columns.
        let session = Self::wrap(&pty, config, keys, request.restored);
        Ok(LivePane::adopt(session, request.session))
    }
}

/// The grid a mux shell is forked at, before its client's first size offer lands.
const FALLBACK_ROWS: u16 = 24;
/// See [`FALLBACK_ROWS`].
const FALLBACK_COLS: u16 = 80;
