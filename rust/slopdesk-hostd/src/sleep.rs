//! Keeping the Mac awake while an agent is working.
//!
//! ## The set and the assertion move together, on ONE thread
//! `slopdesk_agent::sleep::PreventSleep` is the working-pane set and the opt-in rule;
//! `slopdesk_apple_power::SleepAssertion` is the `IOPMAssertion`. The failure that slips past a
//! reviewer is one thread applying a verdict computed against a set another thread has already
//! changed, leaving the assertion held over an empty set — which does not self-heal, and keeps the
//! Mac awake until the daemon dies.
//!
//! The Swift bought that property with a lock across both objects. This buys it with OWNERSHIP: one
//! thread holds the pair and nothing else can reach either, so the update and the apply are not
//! merely adjacent, they are unreachable from anywhere the order could be broken. A channel carries
//! the edges, and a channel is FIFO, so the thread sees them in the order the fan-out published
//! them.
//!
//! ## Confinement is not a preference here
//! [`SleepAssertion`] holds a `CFString` and is therefore neither `Send` nor `Sync`, and this crate
//! may not `unsafe impl` its way out of that — an `unsafe impl Send` is a claim about RUST, and the
//! `slopdesk-apple-*` family may only make claims about a FRAMEWORK. So the type stays on the
//! thread that built it, which is the answer the language was pointing at.
//!
//! ## Why a tap and not a poll
//! [`Host::fan`](slopdesk_hostserver::Host::fan) already publishes every transition, from every
//! producer, and [`Host::fan_teardown`](slopdesk_hostserver::Host::fan_teardown) publishes the
//! CLEARING one for a pane torn down mid-turn — a tab closed, a child that died, a link that
//! dropped, a ctl `kill`. Without that second edge the aggregate keeps a dead pane id for ever. A
//! poll would have to rediscover both, and would be a second opinion about which panes are working.
//!
//! ## The teardown release is `Drop`'s, twice over
//! Dropping this type closes the channel; the owner thread's `recv` then fails, it returns, and
//! `SleepAssertion`'s own `Drop` releases anything still held. A daemon that stops while an agent
//! is working does not leave the Mac awake, and nothing here has to remember that.
//!
//! ## The C twin, and when it goes
//! `slopdesk-ffi`'s `slopdesk_prevent_sleep_*` doors compose the same two objects for the SWIFT
//! hostd, under a lock rather than a thread because a C handle cannot own one. They are the same
//! Rust reached over a C ABI, not a second implementation, and they are deleted with
//! `PreventSleepDriver.swift` when stage F cuts the daemon over.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_agent::sleep::PreventSleep;
use slopdesk_apple_power::{SleepAssertion, SleepKind};
use slopdesk_hostserver::control::{AgentStatusEvent, AgentStatusTap};

/// What the assertion tells the system it is for. Visible in `pmset -g assertions`.
const REASON: &str = "slopdesk: an agent is working";

/// The name [`slopdesk_agent::supervision::SupervisionState`] gives the one state that holds.
///
/// Compared as the published TEXT rather than re-derived from a status: the fan-out has already
/// decided, and a second mapping here would be a second opinion about what "working" means.
const WORKING: &str = "working";

/// One pane's transition, as the owner thread receives it.
type Edge = (String, bool);

/// hostd's prevent-sleep driver.
#[derive(Debug)]
pub struct KeepAwake {
    /// `None` once the owner thread could not be spawned — every later edge is then dropped, which
    /// is the same outcome a host with the gate off already has.
    edges: Mutex<Option<Sender<Edge>>>,
    /// Whether the assertion is held, as the owner thread last left it. Diagnostic only.
    held: Arc<AtomicBool>,
}

impl KeepAwake {
    /// A driver with nothing working, and the thread that owns its assertion.
    ///
    /// `enabled` is `SLOPDESK_AGENT_PREVENT_SLEEP`, resolved once at launch — there is no live
    /// config reload, and a host restart is the reload.
    #[must_use]
    pub fn new(enabled: bool) -> Self {
        let (sender, receiver) = channel::<Edge>();
        let held = Arc::new(AtomicBool::new(false));
        let reported = Arc::clone(&held);
        let spawned = std::thread::Builder::new()
            .name(String::from("prevent-sleep"))
            .spawn(move || {
                // Both live and die HERE. Nothing outside this closure can name either, which is
                // what makes the fold-then-apply pair unbreakable rather than merely careful.
                let mut fold = PreventSleep::new(enabled);
                let mut assertion = SleepAssertion::new(SleepKind::System, REASON);
                while let Ok((pane, working)) = receiver.recv() {
                    // ONE statement: the fold's answer is computed from the set this iteration just
                    // updated, and applied before the next edge can be taken off the channel.
                    // A refused create is not remembered — the next edge retries, which is the whole
                    // recovery story for a system that said no once.
                    reported.store(
                        assertion.set_asserted(fold.note(&pane, working)),
                        Ordering::Release,
                    );
                }
                // The channel closed: the daemon is going away. `assertion` drops here and releases
                // anything still held.
            });
        Self {
            edges: Mutex::new(spawned.ok().map(|_running| sender)),
            held,
        }
    }

    /// Whether the assertion is held right now. Diagnostic; the driver never asks itself.
    ///
    /// Eventually consistent by construction — the answer is whatever the owner thread last
    /// published, and an edge in flight has not been applied yet.
    #[must_use]
    pub fn is_held(&self) -> bool {
        self.held.load(Ordering::Acquire)
    }
}

impl AgentStatusTap for KeepAwake {
    fn changed(&self, event: &AgentStatusEvent) {
        // Cloned out from under the guard rather than sent under it: a `Sender` clone is a refcount
        // bump, and holding the lock across the send would serialise every pane's transitions behind
        // whichever one the owner thread is mid-way through applying.
        let sender = self.edges.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let Some(sender) = sender else {
            return;
        };
        // A send that fails means the owner thread is gone, which only happens on the way out. The
        // edge is dropped rather than logged: a teardown is not an error, and the assertion has
        // already been released by then.
        drop(sender.send((event.pane_id.clone(), event.state == WORKING)));
    }
}
