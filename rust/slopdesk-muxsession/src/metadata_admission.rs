//! Who serves a metadata request, and whether this session has room to serve it at all.
//!
//! One pane answers every host-metadata verb over the SAME unwindowed control sub-channel, so two
//! separate questions have to be settled before any host work starts:
//!
//! 1. **Is there room?** The control channel applies no back-pressure, so a peer streaming
//!    back-to-back tiny `metadataRequest` frames would otherwise queue an unbounded pile of
//!    closures — each retaining its payload, each free to fork `git`/`lsof`. [`Admission`] is the
//!    only bound: a fixed number of work items may be in flight per session, and past it the
//!    request is REFUSED rather than deferred, because "always replies" is a stronger contract than
//!    "eventually serves".
//! 2. **Whose verb is it?** Nine of the twenty-two verbs actuate on host-global state — Finder,
//!    `~/.claude/settings.json`, the pasteboard, a lazily-spawned child — and must never reach the
//!    read-only response builder, which performs no side effects by construction. [`performer`] is
//!    the whole mapping, and it is a mapping rather than a chain of "not mine" answers because a
//!    verb claimed by nobody and a verb claimed by two are both bugs the chain could not state.
//!
//! Neither answer needs a descriptor, a pasteboard or a subprocess — the first is a counter and
//! the second is a table over one wire byte — so both live here and hostd performs what they name.

use slopdesk_wire::metadata::MetadataVerb;

/// The per-session cap on admitted-not-yet-finished metadata work items.
///
/// Thirty-two is not a throughput target: the queue behind it is SERIAL, so the cap bounds how
/// much a flood may retain, not how fast the pane answers. A client's own request registry never
/// has this many outstanding at once, so reaching it means a peer that is not asking questions.
pub const MAX_IN_FLIGHT: u32 = 32;

/// The bounded-admission counter for one pane's metadata work.
///
/// Holds a count and a cap and nothing else — the queue, the closures and the subprocesses stay
/// where they can run. Every [`Admission::admit`] that answers `true` owes exactly one
/// [`Admission::release`]; the release saturates at zero so a double-release can never mint room
/// the session does not have.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Admission {
    in_flight: u32,
    cap: u32,
}

impl Default for Admission {
    fn default() -> Self {
        Self::with_cap(MAX_IN_FLIGHT)
    }
}

impl Admission {
    /// A fresh counter with `cap` slots. A cap of zero admits nothing — every request is refused,
    /// which is the honest reading of "no room", not a reason to fall back to unbounded.
    #[must_use]
    pub const fn with_cap(cap: u32) -> Self {
        Self { in_flight: 0, cap }
    }

    /// Takes a slot if one is free. `true` means the caller MUST release exactly once.
    pub const fn admit(&mut self) -> bool {
        if self.in_flight >= self.cap {
            return false;
        }
        self.in_flight += 1;
        true
    }

    /// Returns a slot taken by an `admit` that answered `true`.
    pub const fn release(&mut self) {
        self.in_flight = self.in_flight.saturating_sub(1);
    }

    /// How many work items are admitted and unfinished.
    #[must_use]
    pub const fn in_flight(&self) -> u32 {
        self.in_flight
    }
}

/// Who serves a verb once it has been admitted.
///
/// The six named performers actuate on host-global state; [`Performer::Builder`] is the pure
/// read-only path, and it is also where an UNKNOWN byte goes — the builder already answers
/// `unsupportedVerb` for one, and adding a second place that recognises "unknown" is how the two
/// would drift into disagreeing about which bytes this build serves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Performer {
    /// Verbs 9–10: the host's Finder / Launch Services.
    Path = 1,
    /// Verbs 11–13: the agent hooks in `~/.claude/settings.json`, and their live state.
    Agent = 2,
    /// Verbs 15–16: the host pasteboard, with its change-count dedupe.
    Clipboard = 3,
    /// Verbs 18–20: the embedded workbench — its child, its open, its font.
    CodeServer = 4,
    /// Verb 21: the host's simulator server.
    Simulator = 5,
    /// Verb 22: the host's Android bridge.
    Android = 6,
    /// Every read verb, and every byte this build does not serve.
    Builder = 7,
}

impl Performer {
    /// The performer for `byte`, or [`Performer::Builder`] for one this build does not name.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Path,
            2 => Self::Agent,
            3 => Self::Clipboard,
            4 => Self::CodeServer,
            5 => Self::Simulator,
            6 => Self::Android,
            _ => Self::Builder,
        }
    }

    /// The byte a door answers with.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Which performer owns `verb`.
///
/// Reads the wire's own enum rather than raw byte ranges: the set of verbs this build serves is
/// `MetadataVerb`'s, and a second copy of it here is exactly the copy that would keep routing a
/// verb after the wire retired it.
#[must_use]
pub const fn performer(verb: u8) -> Performer {
    let Some(verb) = MetadataVerb::from_byte(verb) else {
        return Performer::Builder;
    };
    match verb {
        MetadataVerb::OpenPath | MetadataVerb::RevealPath => Performer::Path,
        MetadataVerb::InstallAgentHooks
        | MetadataVerb::UninstallAgentHooks
        | MetadataVerb::AgentHookStatus => Performer::Agent,
        MetadataVerb::SetClipboard | MetadataVerb::ReadClipboard => Performer::Clipboard,
        MetadataVerb::EnsureCodeServer | MetadataVerb::OpenInCodeServer | MetadataVerb::SyncCodeFont => {
            Performer::CodeServer
        },
        MetadataVerb::EnsureSimulatorServer => Performer::Simulator,
        MetadataVerb::EnsureAndroidBridge => Performer::Android,
        MetadataVerb::Processes
        | MetadataVerb::Ports
        | MetadataVerb::Cwd
        | MetadataVerb::GitStatus
        | MetadataVerb::GitDiff
        | MetadataVerb::ListDirectory
        | MetadataVerb::ListAgentSessions
        | MetadataVerb::ReadAgentSession
        | MetadataVerb::HostInfo
        | MetadataVerb::HostVitals
        | MetadataVerb::ShellComplete => Performer::Builder,
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_wire::metadata::MetadataVerb;

    use super::{Admission, MAX_IN_FLIGHT, Performer, performer};

    #[test]
    fn a_flood_is_refused_at_the_cap_rather_than_queued_behind_it() {
        let mut admission = Admission::default();
        for _ in 0..MAX_IN_FLIGHT {
            assert!(admission.admit());
        }
        assert_eq!(admission.in_flight(), MAX_IN_FLIGHT);
        assert!(!admission.admit(), "the cap is a refusal, not a wait");
        assert_eq!(admission.in_flight(), MAX_IN_FLIGHT, "a refusal takes no slot");
    }

    #[test]
    fn a_released_slot_is_reusable_and_a_double_release_mints_none() {
        let mut admission = Admission::with_cap(1);
        assert!(admission.admit());
        assert!(!admission.admit());
        admission.release();
        admission.release();
        assert_eq!(admission.in_flight(), 0, "the release floor is zero, not a wrap");
        assert!(admission.admit());
        assert!(!admission.admit(), "the second release did not widen the cap");
    }

    #[test]
    fn a_cap_of_zero_admits_nothing() {
        let mut admission = Admission::with_cap(0);
        assert!(!admission.admit());
        assert_eq!(admission.in_flight(), 0);
    }

    #[test]
    fn every_verb_this_build_serves_has_exactly_one_performer() {
        for verb in MetadataVerb::ALL {
            let owner = performer(verb.as_byte());
            assert_eq!(
                owner,
                Performer::from_byte(owner.as_byte()),
                "verb {verb:?} does not survive its own byte",
            );
        }
    }

    #[test]
    fn the_side_effecting_verbs_never_reach_the_read_only_builder() {
        for verb in [
            MetadataVerb::OpenPath,
            MetadataVerb::RevealPath,
            MetadataVerb::InstallAgentHooks,
            MetadataVerb::UninstallAgentHooks,
            MetadataVerb::AgentHookStatus,
            MetadataVerb::SetClipboard,
            MetadataVerb::ReadClipboard,
            MetadataVerb::EnsureCodeServer,
            MetadataVerb::OpenInCodeServer,
            MetadataVerb::SyncCodeFont,
            MetadataVerb::EnsureSimulatorServer,
            MetadataVerb::EnsureAndroidBridge,
        ] {
            assert_ne!(
                performer(verb.as_byte()),
                Performer::Builder,
                "{verb:?} actuates on the host and the builder performs no side effects",
            );
        }
    }

    #[test]
    fn the_pure_reads_all_land_on_the_builder() {
        for verb in [
            MetadataVerb::Processes,
            MetadataVerb::Ports,
            MetadataVerb::Cwd,
            MetadataVerb::GitStatus,
            MetadataVerb::GitDiff,
            MetadataVerb::ListDirectory,
            MetadataVerb::ListAgentSessions,
            MetadataVerb::ReadAgentSession,
            MetadataVerb::HostInfo,
            MetadataVerb::HostVitals,
        ] {
            assert_eq!(
                performer(verb.as_byte()),
                Performer::Builder,
                "{verb:?} is a pure read"
            );
        }
    }

    #[test]
    fn an_unserved_byte_goes_where_the_unsupported_answer_already_lives() {
        assert_eq!(performer(0), Performer::Builder);
        assert_eq!(performer(24), Performer::Builder);
        assert_eq!(performer(u8::MAX), Performer::Builder);
    }

    #[test]
    fn an_unknown_performer_byte_reads_as_the_builder() {
        assert_eq!(Performer::from_byte(0), Performer::Builder);
        assert_eq!(Performer::from_byte(99), Performer::Builder);
    }
}
