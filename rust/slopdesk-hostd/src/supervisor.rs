//! What superd tells this daemon, and where each of those four things goes.
//!
//! ## Two listeners, two destinations, one rule
//! superd binds both child-facing sockets — the hook relay's and `slopdesk-ctl`'s — because both
//! addresses are baked into a spawned child's environment and must outlive hostd's pid. hostd
//! CLAIMS a listener at handshake and is handed each accepted connection over `SCM_RIGHTS`. The
//! kind decides the destination and nothing else does: a `Hook` goes to the hook table's drain, a
//! `Control` goes to the ctl dispatcher.
//!
//! ## The descriptor arrives on the READER thread
//! Which is also every pane's output and every reply. So each arm hands the fd straight to a worker
//! and returns: parking here stops the whole host, and the peer on the other end of a hook
//! connection is a binary blocking its agent. [`ControlConnections::serve`] spawns its own thread;
//! the hook table submits to its drain queue.
//!
//! ## A kind nobody serves is CLOSED, not kept
//! Dropping the descriptor closes it, which is the right answer: a connection nothing will read is
//! worse than a refused one, because the peer waits for an ack no code path will send. That is why
//! the two arms below are exhaustive over what this daemon claimed, and why the fall-through drops.
//!
//! ## Late binding, for the reason `evict` has one
//! The ctl dispatcher is built around the composition, and the composition is built around a
//! spawner that needs this observer — so the observer must exist before its destination does. A
//! [`OnceLock`] filled by the assembly closes that loop, and a connection arriving before it is
//! filled is closed rather than queued: the window is the microseconds between `Host::assemble` and
//! the `listen` claim, and superd cannot hand over a connection on a listener nobody has claimed.

use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, OnceLock};

use slopdesk_hostserver::ctlserve::ControlConnections;
use slopdesk_superclient::client::{ListenerKind, SupervisorObserver};
use slopdesk_superwire::protocol::ExitedNotice;

use crate::hooks::HookTable;
use crate::observer::Stderr;

/// hostd's ear on superd.
#[derive(Debug)]
pub struct DaemonObserver {
    hooks: Arc<HookTable>,
    /// The ctl dispatcher, once the composition exists. `None` for the life of the process on a
    /// host that did not claim the control listener.
    control: OnceLock<Arc<ControlConnections>>,
    log: Arc<Stderr>,
}

impl DaemonObserver {
    /// An observer routing hooks to `hooks` and logging to `log`.
    #[must_use]
    pub fn new(hooks: &Arc<HookTable>, log: &Arc<Stderr>) -> Self {
        Self {
            hooks: Arc::clone(hooks),
            control: OnceLock::new(),
            log: Arc::clone(log),
        }
    }

    /// Publishes the ctl dispatcher. First call wins; later ones are ignored.
    ///
    /// Called by the assembly once the composition exists. A second call would mean two
    /// dispatchers over one socket, so it is refused rather than honoured.
    pub fn serve_control(&self, connections: Arc<ControlConnections>) {
        let _first = self.control.set(connections);
    }
}

impl SupervisorObserver for DaemonObserver {
    /// A supervised child exited.
    ///
    /// Nothing is done here, deliberately: the pane's OWN exit handler — registered per pane with
    /// `SupervisorClient::observe_exit` — is what folds the code and tears the session down, and it
    /// has already run by the time this fires. A second reaction would be a second teardown for one
    /// exit.
    fn exited(&self, _notice: &ExitedNotice) {}

    fn connection(&self, kind: ListenerKind, descriptor: OwnedFd) {
        match kind {
            ListenerKind::Hook => self.hooks.serve(UnixStream::from(descriptor)),
            ListenerKind::Control => {
                // An unclaimed control listener has no dispatcher, and the descriptor closes with
                // this scope — see the module note on why that is the answer rather than a queue.
                if let Some(connections) = self.control.get() {
                    connections.serve(descriptor);
                }
            },
        }
    }

    /// The control socket dropped. The panes are still alive on superd's side.
    ///
    /// Logged and nothing else. This is superd's link, not the shells: the children keep running,
    /// the client keeps rendering what it has, and every verb reports `NotConnected` until the link
    /// is back. Tearing panes down here would turn a socket hiccup into lost work.
    fn disconnected(&self) {
        self.log
            .say("superd link down — panes keep running, verbs will refuse");
    }

    fn log(&self, line: &str) {
        self.log.say(line);
    }
}
