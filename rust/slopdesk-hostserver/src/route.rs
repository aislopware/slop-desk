//! Which of the six host-global doors gets a request — the table
//! `MuxChannelSession.serveMetadata`'s cascade of `if let response = HostXPerformer.response(…)`
//! used to be.
//!
//! ## Why a table and not a chain
//! The Swift asked six shims in a fixed order and took the first non-`nil`, which meant every shim
//! carried a second copy of the routing decision: each re-derived "is this my verb" from the byte,
//! and each had a `default:` arm reasoning about verbs it did not own. Six opinions about one
//! table, with nothing checking they agreed — while
//! [`slopdesk_muxsession::metadata_admission::performer`] was already the single answer, consulted
//! by nobody on this path.
//!
//! Here it is consulted once. [`MetadataRequest::performer`] is filled in by the session from that
//! function before this is ever reached, so this module decides nothing; it dispatches on a
//! decision already made. That is why every arm is one line, and why a new VERB changes this file
//! only when it introduces a new PERFORMER.
//!
//! ## This is [`HostMetadata`](crate::metadata::HostMetadata)'s delegate, and only its delegate
//! The read verbs are the builder's and it keeps them: its first act is to hand anything that is
//! not [`Performer::Builder`] to whatever was passed as its delegate. That is the carve-out this
//! table fills. So [`Performer::Builder`] cannot arrive here — the only caller filters it out one
//! frame up — and the arm for it answers `unsupportedVerb` rather than inventing a seventh seat
//! that would then be a second place in the tree deciding what this build serves.
//!
//! ## Every seat is filled, and an empty one is still a seat
//! A host built without a door for a slot answers [`MetadataStatus::UnsupportedVerb`] AT ONCE
//! rather than dropping the request: the client's pending-request registry would otherwise wait out
//! its own timeout for an answer that was never coming. [`UnservedMetadata`] is that default, which
//! is why the fields are not `Option`.

use std::sync::Arc;

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest, UnservedMetadata};
use slopdesk_muxsession::metadata_admission::Performer;
use slopdesk_wire::MetadataStatus;

/// The six host-global doors, and the routing between them.
///
/// Each is ONE instance per daemon rather than one per pane, because each actuates on state the
/// machine has one of: a Finder, a pasteboard, a workbench child, a set of simulated devices.
#[derive(Debug)]
pub struct Performers {
    /// Verbs 9–10: Launch Services and the Finder.
    pub path: Arc<dyn MetadataPerformer>,
    /// Verbs 11–13: the hooks in `~/.claude/settings.json`, and whether they can flow.
    pub agent: Arc<dyn MetadataPerformer>,
    /// Verbs 15–16: the host pasteboard, with its change-count dedupe.
    pub clipboard: Arc<dyn MetadataPerformer>,
    /// Verbs 18–20: the embedded workbench — its child, its open, its font.
    pub code: Arc<dyn MetadataPerformer>,
    /// Verb 21: the simulator server.
    pub simulator: Arc<dyn MetadataPerformer>,
    /// Verb 22: the Android bridge.
    pub android: Arc<dyn MetadataPerformer>,
}

impl Performers {
    /// A table with every seat empty — each of the twelve verbs answers `unsupportedVerb` at once.
    ///
    /// The starting point for a composition that fills the seats it has doors for, and the whole
    /// table for one that has none: a `slopdesk-ctl` session, or a test wanting the read verbs and
    /// nothing else.
    #[must_use]
    pub fn unserved() -> Self {
        let unserved: Arc<dyn MetadataPerformer> = Arc::new(UnservedMetadata);
        Self {
            path: Arc::clone(&unserved),
            agent: Arc::clone(&unserved),
            clipboard: Arc::clone(&unserved),
            code: Arc::clone(&unserved),
            simulator: Arc::clone(&unserved),
            android: unserved,
        }
    }
}

impl Default for Performers {
    fn default() -> Self {
        Self::unserved()
    }
}

impl MetadataPerformer for Performers {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        let door = match request.performer {
            Performer::Path => &self.path,
            Performer::Agent => &self.agent,
            Performer::Clipboard => &self.clipboard,
            Performer::CodeServer => &self.code,
            Performer::Simulator => &self.simulator,
            Performer::Android => &self.android,
            // Unreachable — see the module note. Answered rather than routed, because the read
            // verbs' reducer is the one thing this table deliberately does not hold.
            Performer::Builder => {
                return MetadataAnswer {
                    status: MetadataStatus::UnsupportedVerb.as_byte(),
                    payload: Vec::new(),
                };
            },
        };
        door.perform(request)
    }
}
