//! What superd is holding that outlived the last hostd, through the two questions adoption asks.
//!
//! ## Narrow on purpose
//! [`Survivors`] has exactly two methods where [`SupervisorClient`] has thirty, and the gap IS the
//! design: a seam that could reach the whole client would let the adoption ladder `release`,
//! `signal` and `subscribe` — none of which is adoption's, and all of which would be reachable from
//! a ladder that runs before any pane exists.
//!
//! ## The error crosses as text, and is only ever logged
//! `list` answering `Err` is not an empty list, and the ladder is explicit that it must not be
//! treated as one: an unreadable list would otherwise relinquish the notes for panes that are still
//! running. So the message crosses as a `String` — the ladder has no case to distinguish and no
//! recovery to attempt, and a typed error here would be a vocabulary nobody reads.

use std::sync::Arc;

use slopdesk_hostserver::Survivors;
use slopdesk_superclient::client::SupervisorClient;
use slopdesk_superwire::protocol::PaneRecord;

/// The adoption ladder's view of superd.
#[derive(Debug)]
pub struct Supervised {
    supervisor: Arc<SupervisorClient>,
}

impl Supervised {
    /// Asks `supervisor` both questions.
    #[must_use]
    pub fn new(supervisor: &Arc<SupervisorClient>) -> Self {
        Self {
            supervisor: Arc::clone(supervisor),
        }
    }
}

impl Survivors for Supervised {
    fn is_connected(&self) -> bool {
        self.supervisor.is_connected()
    }

    fn list(&self) -> Result<Vec<PaneRecord>, String> {
        self.supervisor.list().map_err(|why| format!("{why}"))
    }
}
