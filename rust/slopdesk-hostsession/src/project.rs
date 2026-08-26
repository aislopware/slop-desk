//! Where the pane IS, and which project that makes it — the type-33/34 pair.
//!
//! Two truths that travel together and must not be published together, because one of them can
//! block for ever.
//!
//! ## The cwd is synchronous, the key is not
//!
//! The cwd is a latch: gate the batch, prefer the probe where the gate says to, fold, send. All of
//! it is bounded, so it happens on the read loop and the client's cwd line updates with the bytes
//! that caused it.
//!
//! The KEY is a `stat(2)`-per-ancestor walk looking for a repository root, and an ancestor on a
//! wedged NFS/SMB/FUSE mount blocks that walk INDEFINITELY. Running it on the read loop would
//! freeze the pane's output on a hung mount, so it goes to an executor and the type-34 is sent from
//! there. The type-33 has already gone by then, which is the point: the tab's directory is right
//! even while the resolver is parked.
//!
//! ## Type-33 is single-source, and this is the source
//!
//! The raw sniffed OSC-7 is WITHHELD by the truths fold ([`Route::Withheld`]), so the only cwd a
//! client ever sees is this one — warm-up-gated, dedupe-anchored, probe-preferred. That is what
//! lets the client apply it ungated: it needs no startup-noise filter of its own, because the noise
//! never crosses.
//!
//! [`Route::Withheld`]: slopdesk_muxsession::truths::Route

use std::sync::Arc;

use slopdesk_muxsession::truths::CwdGate;
use slopdesk_superwire::sniffwire::{CommandStatus as SniffedStatus, SniffEvent};
use slopdesk_wire::message::WireMessage;

use crate::shared::Shared;

/// Where the resolver walk runs.
///
/// A trait rather than a thread of its own, because the walk shares its serialization with the
/// metadata RPC's blocking probe work — one serial queue per pane, so two `cd`s resolve in the
/// order they happened and neither forks a subprocess behind the other's back. A test injects a
/// run-inline executor for a deterministic emission, or a deferred one to pin that a parked resolve
/// never holds the read loop.
pub trait ResolveExecutor: Send + Sync + core::fmt::Debug {
    /// Runs `walk` off the caller's thread, in submission order.
    fn submit(&self, walk: Box<dyn FnOnce() + Send>);
}

/// An executor that runs the walk on the calling thread.
///
/// The default, and it is the correct one for a session with no serial queue behind it: the walk
/// still happens, in order, and the only thing given up is the guarantee that a hung mount cannot
/// stall the caller. A production session is handed the real one.
#[derive(Debug, Clone, Copy)]
pub struct InlineResolve;

impl ResolveExecutor for InlineResolve {
    fn submit(&self, walk: Box<dyn FnOnce() + Send>) {
        walk();
    }
}

/// Who hears that a NEW project key latched for this pane.
///
/// hostd wires this to the repo-watch refcounts, so exactly the repositories with live panes are
/// FSEvents-watched. Fired on the resolver's thread, never the read loop.
pub trait KeyObserver: Send + Sync + core::fmt::Debug {
    /// A key that was not this pane's a moment ago.
    fn latched(&self, key: &str);
}

/// A [`KeyObserver`] that does nothing.
#[derive(Debug, Clone, Copy)]
pub struct IgnoreKeys;

impl KeyObserver for IgnoreKeys {
    fn latched(&self, _key: &str) {}
}

/// The pane's project derivation: where the walk runs and who hears its answer.
#[derive(Debug, Clone)]
pub(crate) struct Project {
    executor: Arc<dyn ResolveExecutor>,
    observer: Arc<dyn KeyObserver>,
}

impl Project {
    /// A derivation over `executor`, telling `observer` about every new key.
    pub(crate) const fn new(executor: Arc<dyn ResolveExecutor>, observer: Arc<dyn KeyObserver>) -> Self {
        Self { executor, observer }
    }

    /// Derives the pane's cwd from one sniffed batch, and schedules the key it implies.
    ///
    /// Runs on the read loop. The common case — a mid-command chunk with no cwd signal at all — is
    /// the first branch and costs one scan of the batch and nothing else.
    pub(crate) fn derive(
        &self,
        shared: &Arc<Shared>,
        pty: &slopdesk_hostpane::PtyProcess,
        batch: &[SniffEvent],
    ) {
        let mut osc_cwd = None;
        let mut prompt_edge = false;
        let mut command_edge = false;
        for event in batch {
            match *event {
                SniffEvent::Cwd(ref path) => osc_cwd = Some(path.as_str()),
                SniffEvent::Status(ref status) => {
                    command_edge = true;
                    prompt_edge |= matches!(*status, SniffedStatus::Idle { .. });
                },
                _ => {},
            }
        }
        if osc_cwd.is_none() && !prompt_edge {
            return;
        }
        let gate =
            shared.with_truths(|truths| truths.open_cwd_gate(osc_cwd.is_some(), prompt_edge, command_edge));
        // The probe is a syscall, so it runs with NO lock held — the same window the fold's own
        // dedupe closes below, and the same one this derivation has always had.
        let freshest = match gate {
            CwdGate::Skip => None,
            CwdGate::UseOsc => osc_cwd.map(ToOwned::to_owned),
            CwdGate::PreferProbe => {
                crate::probe::working_directory(pty).or_else(|| osc_cwd.map(ToOwned::to_owned))
            },
        };
        let Some(cwd) = freshest else { return };
        if !shared.with_truths(|truths| truths.latch_cwd(&cwd)) {
            return;
        }
        // Synchronously, BEFORE the walk: the client's tab directory must update even while the
        // resolver is parked on a hung mount. It also covers OSC-7-less shells, whose prompt-edge
        // probe changes push the cwd with no metadata round trip behind them.
        shared.broadcast_control(&[WireMessage::Cwd(cwd.clone())]);
        self.resolve(shared, cwd);
    }

    /// Seeds both truths from the SPAWN directory.
    ///
    /// Ungated, and safely so: the spawn cwd is the server's own `channelOpen` value or a ctl
    /// `--cwd`, never shell-controlled input, and the warm-up gate exists to drop a plugin
    /// manager's pre-first-prompt `cd` noise. It closes two holes the derivation cannot: a pane
    /// whose shell emits no OSC-133/OSC-7 at all would otherwise never resolve a key, and every
    /// fresh split would otherwise sit under a subdirectory-named section for a full warm-up.
    /// An already-latched truth WINS — the seed runs before the first prompt in practice, but a
    /// lost race must not clobber a real observation.
    pub(crate) fn seed(&self, shared: &Arc<Shared>, cwd: &str) {
        if cwd.is_empty() {
            return;
        }
        if !shared.with_truths(|truths| truths.seed_cwd(cwd)) {
            return;
        }
        shared.broadcast_control(&[WireMessage::Cwd(String::from(cwd))]);
        self.resolve(shared, String::from(cwd));
    }

    /// Hands the ancestor walk to the executor and publishes the key it answers.
    ///
    /// The latch DROPS a resolve whose `cwd` is no longer the pane's anchor: a later `cd`
    /// superseded it, and that change's own resolve is already queued behind this one. It also
    /// dedupes against the latched key, so a `cd` within one repository resolves and publishes
    /// nothing.
    ///
    /// The type-34 does NOT ride the out-FIFO beside the bytes that produced it. FIFO ordering is
    /// not load-bearing for a latest-state truth: the client folds the newest key it sees, and
    /// the reattach re-assert reads the latch rather than the stream.
    fn resolve(&self, shared: &Arc<Shared>, cwd: String) {
        let shared = Arc::clone(shared);
        let observer = Arc::clone(&self.observer);
        self.executor.submit(Box::new(move || {
            let key = slopdesk_git::project_key::key_of(&cwd);
            if !shared.with_truths(|truths| truths.latch_project_key(&cwd, &key)) {
                return;
            }
            shared.broadcast_control(&[WireMessage::ProjectKey(key.clone())]);
            observer.latched(&key);
        }));
    }
}
