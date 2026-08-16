//! The verb byte that selects a metadata operation, and the status byte that answers it.
//!
//! The wire carries the RAW byte in both directions — [`WireMessage::MetadataRequest`] and
//! [`WireMessage::MetadataResponse`] store `u8`, not these enums — so a verb this build does not
//! know is CARRIED rather than dropped, and answered [`MetadataStatus::UnsupportedVerb`]. That is
//! the whole forward-tolerance story: one generic request/response pair backs every host-metadata
//! surface, and a new verb costs no new message type and breaks no older peer.
//!
//! [`WireMessage::MetadataRequest`]: crate::WireMessage::MetadataRequest
//! [`WireMessage::MetadataResponse`]: crate::WireMessage::MetadataResponse

/// The operation a metadata request selects.
///
/// **Read-only vs side-effecting.** Verbs 1–8 are PURE READS against the request's pane (the mux
/// channel carries which pane) — a git/lsof/proc/directory lookup that mutates nothing. Verbs 9–12,
/// 15 and 18–22 are SIDE-EFFECTING: they actuate on the host's own Finder,
/// `~/.claude/settings.json`, pasteboard or a lazily-spawned child, and answer with only a status
/// byte (or a tiny state payload) — no host file CONTENTS cross the wire for those, which is why
/// they need no cwd confinement. Verbs 13, 14, 16 and 17 are pure reads that are host-global rather
/// than pane-scoped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum MetadataVerb {
    /// List the pane's foreground processes. Request: empty. Response: a process list.
    Processes = 1,
    /// List the pane's listening ports. Request: empty. Response: a port list.
    Ports = 2,
    /// The pane's working directory. Request: empty. Response: raw UTF-8 (no nested codec).
    Cwd = 3,
    /// The pane cwd's git status — branch, remote, ahead/behind, stash and changed files.
    GitStatus = 4,
    /// A unified `git diff` of one file. Request: repo-relative path. Response: raw diff bytes.
    GitDiff = 5,
    /// One level of a host directory (lazy per-expand). Request: UTF-8 path, empty = the pane cwd.
    ListDirectory = 6,
    /// Enumerate a project's agent session files. Request: project path, empty = the pane cwd.
    ListAgentSessions = 7,
    /// Read one agent session's raw transcript. Response: opaque JSONL/JSON bytes.
    ReadAgentSession = 8,
    /// **Side-effecting.** Open a host path in the host's default app / Finder.
    OpenPath = 9,
    /// **Side-effecting.** Reveal a host path in the host's Finder.
    RevealPath = 10,
    /// **Side-effecting.** Install the slopdesk Claude Code hooks on the host.
    InstallAgentHooks = 11,
    /// **Side-effecting.** Strip exactly the slopdesk hook entries, leaving the user's own intact.
    UninstallAgentHooks = 12,
    /// **Pure read.** The 2-byte `[installed][listenerActive]` hook state — no file contents.
    AgentHookStatus = 13,
    /// **Pure read.** The host's own hostname, as raw UTF-8.
    HostInfo = 14,
    /// **Side-effecting.** Write the client's clipboard onto the host pasteboard.
    SetClipboard = 15,
    /// **Pure read.** The host pasteboard's content, gated on a last-seen change count.
    ReadClipboard = 16,
    /// **Pure read.** The host machine's pulse — CPU busy, memory in use, pressure, disk free.
    HostVitals = 17,
    /// **Side-effecting.** Ensure the host's code-server is running; answers a service endpoint.
    EnsureCodeServer = 18,
    /// **Side-effecting.** Open one host file in the embedded workbench; answers a disposition.
    OpenInCodeServer = 19,
    /// **Side-effecting.** Push the client's terminal-font truth into the shared workbench
    /// settings.
    SyncCodeFont = 20,
    /// **Side-effecting.** Ensure the host's simulator server; answers a service endpoint.
    EnsureSimulatorServer = 21,
    /// **Side-effecting.** Ensure the host's Android bridge; answers a service endpoint.
    EnsureAndroidBridge = 22,
}

impl MetadataVerb {
    /// Every verb this build routes, in wire order.
    pub const ALL: [Self; 22] = [
        Self::Processes,
        Self::Ports,
        Self::Cwd,
        Self::GitStatus,
        Self::GitDiff,
        Self::ListDirectory,
        Self::ListAgentSessions,
        Self::ReadAgentSession,
        Self::OpenPath,
        Self::RevealPath,
        Self::InstallAgentHooks,
        Self::UninstallAgentHooks,
        Self::AgentHookStatus,
        Self::HostInfo,
        Self::SetClipboard,
        Self::ReadClipboard,
        Self::HostVitals,
        Self::EnsureCodeServer,
        Self::OpenInCodeServer,
        Self::SyncCodeFont,
        Self::EnsureSimulatorServer,
        Self::EnsureAndroidBridge,
    ];

    /// The verb for `byte`, or `None` when this build serves nothing under it.
    ///
    /// `None` is the answer, not a guess: the caller replies
    /// [`MetadataStatus::UnsupportedVerb`] and the request is over. Guessing would run one host
    /// operation for a request that asked for another.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Processes),
            2 => Some(Self::Ports),
            3 => Some(Self::Cwd),
            4 => Some(Self::GitStatus),
            5 => Some(Self::GitDiff),
            6 => Some(Self::ListDirectory),
            7 => Some(Self::ListAgentSessions),
            8 => Some(Self::ReadAgentSession),
            9 => Some(Self::OpenPath),
            10 => Some(Self::RevealPath),
            11 => Some(Self::InstallAgentHooks),
            12 => Some(Self::UninstallAgentHooks),
            13 => Some(Self::AgentHookStatus),
            14 => Some(Self::HostInfo),
            15 => Some(Self::SetClipboard),
            16 => Some(Self::ReadClipboard),
            17 => Some(Self::HostVitals),
            18 => Some(Self::EnsureCodeServer),
            19 => Some(Self::OpenInCodeServer),
            20 => Some(Self::SyncCodeFont),
            21 => Some(Self::EnsureSimulatorServer),
            22 => Some(Self::EnsureAndroidBridge),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The outcome of a metadata response. The host ALWAYS replies — the client's pending-request
/// registry must never hang — and this byte discriminates whether the payload carries the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum MetadataStatus {
    /// The verb ran and the payload carries its result.
    Ok = 0,
    /// The requested file / session / path does not exist; the payload is empty.
    NotFound = 1,
    /// The verb failed — query error, confinement rejection, cap exceeded; the payload is empty.
    Error = 2,
    /// The host does not recognise the request's verb byte; the payload is empty.
    UnsupportedVerb = 3,
}

impl MetadataStatus {
    /// Every status this build produces, in wire order.
    pub const ALL: [Self; 4] = [Self::Ok, Self::NotFound, Self::Error, Self::UnsupportedVerb];

    /// The status for `byte`, or `None` for a value from a newer peer.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Ok),
            1 => Some(Self::NotFound),
            2 => Some(Self::Error),
            3 => Some(Self::UnsupportedVerb),
            _ => None,
        }
    }

    /// The status for `byte`, reading an unknown future value as [`Self::Error`].
    ///
    /// This is the CLIENT's reading, and the fallback direction matters: a status this build cannot
    /// interpret must never be mistaken for [`Self::Ok`], which would hand a payload the client
    /// cannot trust to a decoder that assumes it is well-formed.
    #[must_use]
    pub const fn from_byte_or_error(byte: u8) -> Self {
        match Self::from_byte(byte) {
            Some(status) => status,
            None => Self::Error,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

#[cfg(test)]
mod tests {
    use super::{MetadataStatus, MetadataVerb};

    #[test]
    fn every_verb_round_trips_through_its_byte() {
        for (index, verb) in MetadataVerb::ALL.into_iter().enumerate() {
            // The wire numbering starts at 1; 0 is deliberately not a verb.
            assert_eq!(u32::from(verb.as_byte()), u32::try_from(index).unwrap_or(0) + 1);
            assert_eq!(MetadataVerb::from_byte(verb.as_byte()), Some(verb));
        }
    }

    #[test]
    fn a_verb_this_build_does_not_serve_is_none_rather_than_a_guess() {
        for byte in [0_u8, 23, 200, 0xFF] {
            assert_eq!(MetadataVerb::from_byte(byte), None);
        }
    }

    #[test]
    fn every_status_round_trips_through_its_byte() {
        for (index, status) in MetadataStatus::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(status.as_byte()), index);
            assert_eq!(MetadataStatus::from_byte(status.as_byte()), Some(status));
        }
    }

    #[test]
    fn an_unknown_status_reads_as_error_and_never_as_ok() {
        for byte in [4_u8, 100, 200, 0xFF] {
            assert_eq!(MetadataStatus::from_byte(byte), None);
            assert_eq!(MetadataStatus::from_byte_or_error(byte), MetadataStatus::Error);
        }
        assert_eq!(MetadataStatus::from_byte_or_error(0), MetadataStatus::Ok);
    }
}
