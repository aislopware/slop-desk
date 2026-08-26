//! The [`Pane`] a real hostd puts in the table: one [`PaneSession`], plus the two identities the
//! session itself deliberately does not carry.
//!
//! [`PaneSession`] knows about a PTY, its members and the wire between them, and it knows nothing
//! about being ONE OF MANY — no session id, no slot, no table. That is not an omission: a crate
//! that named its own position in a collection could not be tested apart from the collection, and
//! `docs/60` stage C.2 spent its whole scoping keeping that line. So the identities are pinned on
//! HERE, at the join, which is the first place both halves are in scope.

use std::sync::Arc;

use slopdesk_hostsession::PaneSession;
use slopdesk_muxsession::registry::{self, Slot, Uuid};

use crate::pane::Pane;

/// A live pane in hostd: the session, the conversation it serves, and its object identity.
#[derive(Debug)]
pub struct LivePane {
    session: Arc<PaneSession>,
    id: Uuid,
    slot: Slot,
}

impl LivePane {
    /// Adopts `session` as the pane serving conversation `id`, minting it a fresh slot.
    ///
    /// The mint happens HERE, exactly once per object, because a slot minted anywhere else could be
    /// minted twice for one pane — and two slots for one pane is two entries in every enumeration
    /// hostd has, which shuts the same PTY twice.
    #[must_use]
    pub fn adopt(session: Arc<PaneSession>, id: Uuid) -> Arc<Self> {
        Arc::new(Self {
            session,
            id,
            slot: registry::mint_slot(),
        })
    }

    /// The session underneath, for the callers that steer the pane rather than file it.
    #[must_use]
    pub const fn session(&self) -> &Arc<PaneSession> {
        &self.session
    }
}

impl Pane for LivePane {
    fn id(&self) -> Uuid {
        self.id
    }

    fn slot(&self) -> Slot {
        self.slot
    }

    fn is_child_exited(&self) -> bool {
        self.session.is_child_exited()
    }

    fn member_count(&self) -> usize {
        self.session.member_count()
    }

    fn shutdown(&self) {
        self.session.shutdown();
    }

    fn relinquish(&self) {
        self.session.relinquish();
    }
}
