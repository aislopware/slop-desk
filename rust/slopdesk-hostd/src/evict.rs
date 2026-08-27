//! The laggard's other end: a session latched one, and this is what closes its channel.
//!
//! ## The circularity, and the one join that resolves it
//! A pane's `SessionConfig` is built by the spawner; the spawner is built before the [`Host`],
//! because `HostParts` takes one; and the eviction has to call back INTO the host, which does not
//! exist yet — and would name a pane that does not exist yet either, since `LivePane::adopt` runs
//! after the session it wraps. Three things in a cycle, and none of them can be reordered without
//! breaking a rule that was paid for elsewhere.
//!
//! What breaks it is that the seam is not needed until a member falls behind, which is a long time
//! after start-up. So the host arrives LATE, through a [`OnceLock`] the assembly fills once
//! everything exists, and a seam whose host has not landed yet simply evicts nobody — which is the
//! same thing `Eviction::off()` does, and the correct behaviour for a daemon that has not finished
//! starting.
//!
//! ## Weak, and for the usual reason
//! The host owns the spawner, the spawner owns the seam. A strong edge back would make the whole
//! composition immortal — every pane, every table, every thread — for exactly as long as one
//! session held a config, which is for ever. The upgrade failing is the daemon having stopped, and
//! evicting a member of a host that is gone is not work worth doing.

use std::sync::{Arc, OnceLock, Weak};

use slopdesk_hostserver::Host;
use slopdesk_hostsession::EvictionSeam;
use slopdesk_muxsession::fanout::SubscriberId;
use slopdesk_muxsession::registry::Uuid;

/// The host every pane's eviction resolves against, filled once the composition exists.
///
/// One per daemon, shared by every pane's seam: the late-bound edge is a property of the process,
/// not of a pane, and a `OnceLock` per session would be N chances to forget to fill one.
#[derive(Debug, Default)]
pub struct LateHost {
    host: OnceLock<Weak<Host>>,
}

impl LateHost {
    /// Publishes the assembled composition. The first call wins; later ones are ignored.
    ///
    /// Ignored rather than asserted-on because there is exactly one caller — the assembly — and a
    /// second would be a bug in code that has already started serving. Refusing to overwrite keeps
    /// the seam pointing at the host whose panes it was built for.
    pub fn publish(&self, host: &Arc<Host>) {
        let _first = self.host.set(Arc::downgrade(host));
    }

    /// The composition, if it has landed and is still alive.
    pub(crate) fn resolve(&self) -> Option<Arc<Host>> {
        self.host.get().and_then(Weak::upgrade)
    }
}

/// One pane's eviction seam: the session it speaks for, and the host that acts.
#[derive(Debug)]
pub struct HostEviction {
    late: Arc<LateHost>,
    session: Uuid,
}

impl HostEviction {
    /// The seam for the pane serving `session`.
    #[must_use]
    pub fn new(late: &Arc<LateHost>, session: Uuid) -> Self {
        Self {
            late: Arc::clone(late),
            session,
        }
    }
}

impl EvictionSeam for HostEviction {
    /// Retires the member, and tells it why.
    ///
    /// Two lookups rather than one because the session's vocabulary and the registry's do not meet:
    /// the fold latched a `SubscriberId`, and closing a channel needs the KEY that member rides,
    /// which only the tables know. `Host::evict_subscriber` does the second half.
    ///
    /// The guard is dropped before the call: `evict_subscriber` takes the sessions lock itself, and
    /// holding it across the call would be the same lock twice on one thread.
    fn evict(&self, id: SubscriberId) {
        let Some(host) = self.late.resolve() else {
            return;
        };
        let pane = host.sessions().pane_for_session(self.session).map(Arc::clone);
        let Some(pane) = pane else {
            // The pane left between the fold latching the laggard and this running — a shell that
            // exited, a link that dropped. Its members are being closed by that path already.
            return;
        };
        host.evict_subscriber(&pane, id);
    }
}
