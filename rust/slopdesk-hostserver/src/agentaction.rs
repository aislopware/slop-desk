//! The three agent-hooks verbs: install, uninstall, and what the host's `settings.json` says now.
//!
//! The port of `HostAgentActionPerformer.swift`, which was 97 lines of which
//! the interesting part was three sentences: the payload is ignored, install and uninstall answer a
//! bare status, and status answers two flag bytes rather than one.
//!
//! ## Two flags, because one of them would be a lie
//! Verb 13 answers `[installed][listenerActive]`. "Installed" is a fact about a JSON file; "the
//! listener is bound" is a fact about this process. Every hook the installer writes exits silently
//! when `$SLOPDESK_SOCKET_PATH` names nothing, so a green *Installed* over an unbound socket would
//! describe hooks that are written and not flowing. The second flag is the difference, and it is
//! read at PERFORM time rather than passed in per request: the bind can fail after a client
//! connected, and a flag captured at composition would keep reporting the answer from before.
//!
//! ## Host-global, and therefore payload-free
//! Install and uninstall act on the one `~/.claude/settings.json` this machine has, whichever
//! pane's channel carried the request. The wire carries an EMPTY payload for all three by contract,
//! and this performer ignores what arrives rather than refusing a non-empty one — unlike verbs 21
//! and 22, whose payload emptiness IS enforced. The asymmetry is the Swift's and it is kept: those
//! two answer a structured endpoint that a future field would scope, and these three answer a state
//! change that nothing can scope.
//!
//! ## No exfiltration, so no confinement
//! Nothing here reads a host file back onto the wire — 11 and 12 return a status and an empty
//! payload, 13 returns two booleans. The security boundary is the `WireGuard` mesh, as everywhere.

use std::sync::Arc;

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{AgentHookStatus, encode_agent_hook_status};

/// The host effects these three verbs actuate, on this machine's own Claude configuration.
///
/// Three `-> bool` methods rather than the installer's `io::Result<String>`, because the wire has
/// exactly two answers and the path it wrote is not one of them. The door is what turns "could not
/// write, and here is why" into `false`; the reason belongs in the daemon's log, which is where the
/// production door puts it.
pub trait InstallsAgentHooks: Send + Sync + core::fmt::Debug {
    /// Merges the slopdesk hook entries into the host's settings. `false` when nothing was written
    /// — a disk or permission failure, or a relay that was never staged beside this daemon.
    fn install(&self) -> bool;

    /// Strips exactly the slopdesk entries back out. `false` when the write failed.
    fn uninstall(&self) -> bool;

    /// Whether the host's settings currently carry them.
    fn is_installed(&self) -> bool;
}

/// Whether this daemon's hook listener is actually bound right now.
///
/// A closure rather than a `bool`, for the reason in the module header: the answer moves after
/// composition, and the flag must report the bind as it stands when the client asks.
pub type ListenerLive = Arc<dyn Fn() -> bool + Send + Sync>;

/// The performer for verbs 11, 12 and 13.
pub struct AgentActions<D> {
    door: D,
    listening: ListenerLive,
}

impl<D: core::fmt::Debug> core::fmt::Debug for AgentActions<D> {
    /// Written out because the listener probe is a bare closure, and there is nothing to print
    /// about one. The door is what a reader wants.
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("AgentActions")
            .field("door", &self.door)
            .finish_non_exhaustive()
    }
}

impl<D: InstallsAgentHooks> AgentActions<D> {
    /// A performer over `door`, reporting the listener through `listening`.
    #[must_use]
    pub const fn new(door: D, listening: ListenerLive) -> Self {
        Self { door, listening }
    }

    /// The two flag bytes verb 13 answers with.
    fn status_flags(&self) -> Vec<u8> {
        encode_agent_hook_status(AgentHookStatus {
            installed: self.door.is_installed(),
            listener_active: (self.listening)(),
        })
    }
}

impl<D: InstallsAgentHooks> MetadataPerformer for AgentActions<D> {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        // The payload is ignored on all three arms: these verbs are host-global and carry none.
        match MetadataVerb::from_byte(request.verb) {
            Some(MetadataVerb::InstallAgentHooks) => status_only(self.door.install()),
            Some(MetadataVerb::UninstallAgentHooks) => status_only(self.door.uninstall()),
            Some(MetadataVerb::AgentHookStatus) => MetadataAnswer::ok(self.status_flags()),
            // The routing table sends only these three here, so this is unreachable in production.
            // `unsupportedVerb` rather than `error`, because a byte this performer does not own is
            // a question about the ROUTE, and that is the answer a caller can act on.
            _ => {
                MetadataAnswer {
                    status: MetadataStatus::UnsupportedVerb.as_byte(),
                    payload: Vec::new(),
                }
            },
        }
    }
}

/// The 11/12 reply shape: a status byte over an empty payload.
///
/// A refusal is `error` rather than `notFound`: the client asked for a state change that did not
/// happen, and there is no file it can be told to go and create instead.
const fn status_only(succeeded: bool) -> MetadataAnswer {
    let status = if succeeded {
        MetadataStatus::Ok
    } else {
        MetadataStatus::Error
    };
    MetadataAnswer {
        status: status.as_byte(),
        payload: Vec::new(),
    }
}
