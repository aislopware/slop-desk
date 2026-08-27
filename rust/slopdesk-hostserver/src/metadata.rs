//! The metadata performer: one pure reducer, one query door, and a delegate for what is still
//! Swift.
//!
//! `MetadataResponseBuilder.swift` is 389 lines of which almost none is host
//! work. It decodes an argument, confines a path, calls a query and encodes the answer — and every
//! one of those four was already Rust before this stage started: `PathConfinement` is
//! [`slopdesk_probe::path_confine`], the encoders are [`slopdesk_wire::metadata::codec`], and the
//! queries are `slopdesk-panecensus`, `slopdesk-git` and `slopdesk-probe`. What the Swift added was
//! the ORDER, which is what this module is.
//!
//! ## Two halves, and the seam between them is a trait
//!
//! [`HostMetadata`] is a REDUCER: given an argument and a query door it decides a status and a
//! payload, and it performs no IO of its own. [`HostQuerying`] is the door, and [`HostQueries`] is
//! the one that reads the real machine. The split is the Swift's, kept for the Swift's reason: the
//! confinement rules are the security-critical part, their failure mode is a read that should never
//! have happened, and the only way to assert "the query was never called" is for the query to be
//! something a test can hold.
//!
//! ## What is delegated, and why it is not "the Rust half is unfinished"
//!
//! [`slopdesk_muxsession::metadata_admission::performer`] already routes each verb, in Rust, off
//! the wire's own enum. Ten of the twenty-two land on [`Performer::Builder`], and those are this
//! module's. The other twelve are claimed by six named performers that actuate on host-global
//! state: the Finder, `~/.claude/settings.json`, the pasteboard, the workbench child, the simulator
//! server, the Android bridge. Under `docs/60` §5's carve-out those are Swift until the stage F
//! cutover, so [`HostMetadata`] holds a delegate and hands them over UNTOUCHED.
//!
//! Three of that twelve — `agentHookStatus`, `ensureSimulatorServer`, `ensureAndroidBridge` — could
//! be served here today, and are deliberately not. They belong to named performers that a live
//! hostd injects separately, and serving them from a second place would put two implementations
//! over one `~/.claude/settings.json` and one sidecar socket for as long as the carve-out lasts.
//! What moves them is stage F retiring their Swift, not this module reaching past its routing.
//!
//! So the delegate shrinks to nothing at F rather than this composite being rewritten, and the
//! routing itself never moves at all.
//!
//! ## The probe is LINKED, not forked
//!
//! `HostProbe.swift` forks `slopdesk-probe` for four verbs, because a Swift process had no other
//! way to reach Rust code that was already written. This side calls the same functions in-process,
//! at the SAME level the probe's `main.rs` dispatches to — `git::diff`, `files::list_directory`,
//! `files::list_sessions`, `files::read_session` — so every rule inside them travels with the call.
//! That matters most for `read_session`, which confines the id against the host's session roots a
//! second time under this reducer's own shape check; reaching one level below it would silently
//! drop that. The `main.rs` above them is an argv parser and a JSON printer, and neither is a rule.
//!
//! The fork's one theoretical advantage — a wedged mount kills with the child — was never realised:
//! Swift's `waitUntilExit` has no timeout, so both shapes park the same pane executor on the same
//! `stat`. `gitStatus` already made this move when its cadence made forks expensive.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use slopdesk_hostsession::{MetadataAnswer, MetadataPerformer, MetadataRequest, UnservedMetadata};
use slopdesk_muxsession::metadata_admission::Performer;
use slopdesk_probe::path_confine::{self, Shape};
use slopdesk_wire::MetadataStatus;
use slopdesk_wire::metadata::MetadataVerb;
use slopdesk_wire::metadata::codec::{
    AgentSessionInfo, DirEntry, GitStatusPayload, HostVitals, encode_agent_session_list, encode_dir_listing,
    encode_git_status, encode_host_vitals,
};

/// The directory-listing entry cap.
///
/// The codec clamps the `u16` count on its own; this is the much smaller production limit, so a
/// pathological directory costs one truncated listing rather than a frame the peer drops whole.
pub const MAX_DIR_ENTRIES: usize = 4096;

/// The opaque-payload byte cap, for a `gitDiff` or a session transcript.
///
/// Held well under the 16 MiB frame cap so the answer plus its envelope can never exceed it. A
/// truncated tail is still valid opaque bytes the client renders best-effort — the cut is by BYTE
/// and not by character, deliberately, because the alternative is a cap that a multi-byte sequence
/// can push past.
pub const MAX_OPAQUE_PAYLOAD_BYTES: usize = 15 * 1024 * 1024;

/// The pane a request came from, as the pane-scoped queries need it.
///
/// A pair rather than two arguments because they travel together through three call sites and are
/// both `i32`, which is the argument list whose order gets swapped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaneHandles {
    /// The PTY master's descriptor number — see [`MetadataRequest::master_fd`] on the seam this is.
    pub master_fd: i32,
    /// The pane's shell pid, or `0` when superd has not answered with one.
    pub shell_pid: i32,
}

/// Everything the reducer has to ask the machine.
///
/// Every method is best-effort by contract: a `None` is the verb's `notFound` or `error`, never a
/// failure an operator resolves. Called on the pane's serial executor, so an implementation MAY
/// block — that is what the executor is for.
pub trait HostQuerying: Send + Sync + core::fmt::Debug {
    /// The pane's working directory — the `cwd` verb's answer AND the confinement root for
    /// `gitDiff`, `listDirectory` and `listAgentSessions`. `None` or empty replies `error`.
    fn working_directory(&self, pane: PaneHandles) -> Option<String>;

    /// The pane's foreground processes, ALREADY ENCODED.
    ///
    /// Encoded rather than as records because this reducer holds no opinion about the list — it
    /// forwards it verbatim, and a `Vec<ProcessInfo>` here would only be built to be re-encoded one
    /// line later. An empty list is valid and encodes as a zero count; there is no `None`.
    fn processes(&self, pane: PaneHandles) -> Vec<u8>;

    /// The pane's listening ports, ALREADY ENCODED. Empty is valid — see
    /// [`HostQuerying::processes`].
    fn ports(&self, pane: PaneHandles) -> Vec<u8>;

    /// The git status of `cwd`. As VALUES rather than bytes, unlike the two above: it is one small
    /// record, and a test that can read its branch off the answer is worth the one encode.
    fn git_status(&self, cwd: &str) -> GitStatusPayload;

    /// A unified `git diff` of `file`, which arrives already confined repo-relative. `None` is the
    /// verb's `notFound`.
    fn git_diff(&self, cwd: &str, file: &str) -> Option<Vec<u8>>;

    /// One level of `absolute`, which arrives already confined within the pane cwd. `None` is the
    /// verb's `notFound`.
    fn list_directory(&self, absolute: &str) -> Option<Vec<DirEntry>>;

    /// The agent sessions for `project`, which arrives already confined. Empty is valid.
    fn list_agent_sessions(&self, project: &str) -> Vec<AgentSessionInfo>;

    /// The raw transcript for session `id`, whose SHAPE the reducer checked and whose confinement
    /// against the host's session roots is this door's own. `None` is the verb's `notFound`.
    fn read_agent_session(&self, id: &str) -> Option<Vec<u8>>;

    /// The host machine's own name — the client chrome's durable host identity. `None` or empty
    /// replies `error`.
    fn host_name(&self) -> Option<String>;

    /// The machine's pulse. `None` means NO READING YET — the CPU percent needs two tick snapshots,
    /// so the first call only primes a baseline — or a refused syscall. Either way the verb replies
    /// `error` and the client keeps whatever it last had.
    fn host_vitals(&self) -> Option<HostVitals>;
}

/// The metadata performer: this reducer for its ten verbs, a delegate for the rest.
#[derive(Debug)]
pub struct HostMetadata {
    query: Arc<dyn HostQuerying>,
    delegate: Arc<dyn MetadataPerformer>,
    max_dir_entries: usize,
    max_opaque_payload_bytes: usize,
}

impl HostMetadata {
    /// A performer reading `query`, handing every verb it does not own to `delegate`.
    #[must_use]
    pub fn new(query: Arc<dyn HostQuerying>, delegate: Arc<dyn MetadataPerformer>) -> Self {
        Self {
            query,
            delegate,
            max_dir_entries: MAX_DIR_ENTRIES,
            max_opaque_payload_bytes: MAX_OPAQUE_PAYLOAD_BYTES,
        }
    }

    /// A performer with nothing behind the carve-out: every delegated verb answers
    /// `unsupportedVerb`. The honest shape for a host built without the Swift half, and what stage
    /// F leaves behind once there is no Swift half to build.
    #[must_use]
    pub fn unaccompanied(query: Arc<dyn HostQuerying>) -> Self {
        Self::new(query, Arc::new(UnservedMetadata))
    }

    /// The same performer with smaller caps, so a test can assert the truncation guards without
    /// allocating 15 MiB or synthesising four thousand directory entries.
    #[must_use]
    pub const fn capped(mut self, dir_entries: usize, opaque_payload_bytes: usize) -> Self {
        self.max_dir_entries = dir_entries;
        self.max_opaque_payload_bytes = opaque_payload_bytes;
        self
    }

    /// The pane cwd, or the `error` every verb rooted in it answers without it.
    fn rooted(&self, pane: PaneHandles) -> Result<String, MetadataAnswer> {
        match self.query.working_directory(pane) {
            Some(cwd) if !cwd.is_empty() => Ok(cwd),
            _ => Err(MetadataAnswer::failed()),
        }
    }

    /// Truncates an opaque answer to the cap. A backstop: a real diff or transcript is orders of
    /// magnitude smaller, and the source-side read is bounded one byte past the same number so a
    /// truncation is still visible here.
    fn capped_opaque(&self, mut bytes: Vec<u8>) -> Vec<u8> {
        bytes.truncate(self.max_opaque_payload_bytes);
        bytes
    }

    /// `gitDiff`: a repo-relative pathspec, confined BEFORE any read.
    fn git_diff(&self, pane: PaneHandles, payload: &[u8]) -> MetadataAnswer {
        let cwd = match self.rooted(pane) {
            Ok(cwd) => cwd,
            Err(refusal) => return refusal,
        };
        let Some(file) = utf8_argument(payload).filter(|file| !file.is_empty()) else {
            return MetadataAnswer::failed();
        };
        let Some(confined) = path_confine::confine(&cwd, file, Shape::RelativeOnly) else {
            return MetadataAnswer::failed();
        };
        self.query
            .git_diff(&cwd, confined.relative())
            .map_or_else(not_found, |diff| MetadataAnswer::ok(self.capped_opaque(diff)))
    }

    /// `listDirectory`: an empty argument is the pane cwd; anything else must land inside it.
    fn list_directory(&self, pane: PaneHandles, payload: &[u8]) -> MetadataAnswer {
        let target = match self.confined_target(pane, payload) {
            Ok(target) => target,
            Err(refusal) => return refusal,
        };
        let Some(mut entries) = self.query.list_directory(&target) else {
            return not_found();
        };
        entries.truncate(self.max_dir_entries);
        MetadataAnswer::ok(encode_dir_listing(&entries))
    }

    /// `listAgentSessions`: the same argument rule as `listDirectory`, and an empty list is an
    /// answer rather than a miss — a project with no sessions is the ordinary first case.
    fn list_agent_sessions(&self, pane: PaneHandles, payload: &[u8]) -> MetadataAnswer {
        let project = match self.confined_target(pane, payload) {
            Ok(project) => project,
            Err(refusal) => return refusal,
        };
        MetadataAnswer::ok(encode_agent_session_list(
            &self.query.list_agent_sessions(&project),
        ))
    }

    /// The argument rule the two listing verbs share: empty means the pane cwd, and anything else —
    /// relative or absolute — must resolve to a normalised path inside it. The root ITSELF is
    /// allowed, because a pane listing its own cwd is the ordinary case.
    fn confined_target(&self, pane: PaneHandles, payload: &[u8]) -> Result<String, MetadataAnswer> {
        let cwd = self.rooted(pane)?;
        let Some(argument) = utf8_argument(payload) else {
            return Err(MetadataAnswer::failed());
        };
        if argument.is_empty() {
            return Ok(cwd);
        }
        path_confine::confine(&cwd, argument, Shape::Either)
            .map(|confined| confined.absolute().to_owned())
            .ok_or_else(MetadataAnswer::failed)
    }

    /// `readAgentSession`: the id's SHAPE is checked here — a well-formed absolute path with no
    /// `..` — which stops the obvious `../../secrets` without a syscall. The confinement proper is
    /// the door's, against roots under the host's `$HOME` that a pure reducer has no business
    /// knowing.
    fn read_agent_session(&self, payload: &[u8]) -> MetadataAnswer {
        let Some(id) = utf8_argument(payload).filter(|id| path_confine::is_confinable_absolute(id)) else {
            return MetadataAnswer::failed();
        };
        self.query
            .read_agent_session(id)
            .map_or_else(not_found, |bytes| MetadataAnswer::ok(self.capped_opaque(bytes)))
    }

    /// The two pane-agnostic reads: the machine's name and the machine's pulse.
    fn host_verb(&self, verb: MetadataVerb) -> MetadataAnswer {
        match verb {
            MetadataVerb::HostInfo => {
                self.query
                    .host_name()
                    .filter(|name| !name.is_empty())
                    .map_or_else(MetadataAnswer::failed, |name| {
                        MetadataAnswer::ok(name.into_bytes())
                    })
            },
            // A missing reading is `error` and NOT `notFound`: the client reads it as "ask again
            // next poll" and keeps the number it has, where a `notFound` would blank the readout
            // every time the sampler primes.
            _ => {
                self.query
                    .host_vitals()
                    .map_or_else(MetadataAnswer::failed, |vitals| {
                        MetadataAnswer::ok(encode_host_vitals(&vitals))
                    })
            },
        }
    }
}

impl MetadataPerformer for HostMetadata {
    fn perform(&self, request: &MetadataRequest<'_>) -> MetadataAnswer {
        if request.performer != Performer::Builder {
            return self.delegate.perform(request);
        }
        // An unknown byte routes to `Builder` by design, so it arrives HERE and is answered once.
        // Narrowing it any earlier would put a second place in the tree deciding what this build
        // serves, and the two would drift.
        let Some(verb) = MetadataVerb::from_byte(request.verb) else {
            return answered(MetadataStatus::UnsupportedVerb);
        };
        let pane = PaneHandles {
            master_fd: request.master_fd,
            shell_pid: request.shell_pid,
        };
        match verb {
            MetadataVerb::Processes => MetadataAnswer::ok(self.query.processes(pane)),
            MetadataVerb::Ports => MetadataAnswer::ok(self.query.ports(pane)),
            MetadataVerb::Cwd => {
                match self.rooted(pane) {
                    Ok(cwd) => MetadataAnswer::ok(cwd.into_bytes()),
                    Err(refusal) => refusal,
                }
            },
            MetadataVerb::GitStatus => {
                match self.rooted(pane) {
                    Ok(cwd) => MetadataAnswer::ok(encode_git_status(&self.query.git_status(&cwd))),
                    Err(refusal) => refusal,
                }
            },
            MetadataVerb::GitDiff => self.git_diff(pane, request.payload),
            MetadataVerb::ListDirectory => self.list_directory(pane, request.payload),
            MetadataVerb::ListAgentSessions => self.list_agent_sessions(pane, request.payload),
            MetadataVerb::ReadAgentSession => self.read_agent_session(request.payload),
            MetadataVerb::HostInfo | MetadataVerb::HostVitals => self.host_verb(verb),
            // Unreachable in production: every verb below is claimed by a named performer and the
            // routing table sends it there before this call. Reaching one is a ROUTING bug, and the
            // answer is a refusal rather than a best effort — this reducer must never perform a
            // host side effect, and "the table disagreed with itself" is not a reason to start.
            MetadataVerb::OpenPath
            | MetadataVerb::RevealPath
            | MetadataVerb::InstallAgentHooks
            | MetadataVerb::UninstallAgentHooks
            | MetadataVerb::AgentHookStatus
            | MetadataVerb::SetClipboard
            | MetadataVerb::ReadClipboard
            | MetadataVerb::EnsureCodeServer
            | MetadataVerb::OpenInCodeServer
            | MetadataVerb::SyncCodeFont
            | MetadataVerb::EnsureSimulatorServer
            | MetadataVerb::EnsureAndroidBridge => MetadataAnswer::failed(),
        }
    }
}

/// Decodes a request payload as a UTF-8 argument. `None` on invalid UTF-8, which every verb reads
/// as `error`; an EMPTY payload decodes to `""`, which is the "no argument" case and valid.
fn utf8_argument(payload: &[u8]) -> Option<&str> {
    core::str::from_utf8(payload).ok()
}

/// An empty answer carrying `status` — the shape every refusal that is not [`MetadataAnswer::ok`]
/// takes.
const fn answered(status: MetadataStatus) -> MetadataAnswer {
    MetadataAnswer {
        status: status.as_byte(),
        payload: Vec::new(),
    }
}

/// The "there is no such thing" answer, distinct from the "I could not tell" one.
const fn not_found() -> MetadataAnswer {
    answered(MetadataStatus::NotFound)
}

/// The door onto the real machine.
///
/// Holds exactly two things that cannot be re-derived per request: the host's `$HOME`, which the
/// session roots and the free-space volume are both under, and the CPU sampler's baseline, which
/// only exists across calls — the first `hostVitals` banks a tick snapshot and answers nothing, and
/// a sampler rebuilt per request would answer nothing for ever.
#[derive(Debug)]
pub struct HostQueries {
    home: String,
    vitals: Mutex<slopdesk_panecensus::vitals::Sampler>,
    /// The monotonic origin the sampler's window is measured from. An `Instant` rather than a wall
    /// clock because the window is a DURATION and a wall clock can step backwards over it.
    started: Instant,
}

impl HostQueries {
    /// A door reading the machine, with `$HOME` as the session-root and free-space anchor.
    #[must_use]
    pub fn new(home: String) -> Self {
        Self {
            home,
            vitals: Mutex::new(slopdesk_panecensus::vitals::Sampler::new()),
            started: Instant::now(),
        }
    }

    /// A door onto the running host, taking `$HOME` from the environment.
    #[must_use]
    pub fn from_environment() -> Self {
        Self::new(std::env::var("HOME").unwrap_or_default())
    }
}

impl HostQuerying for HostQueries {
    fn working_directory(&self, pane: PaneHandles) -> Option<String> {
        slopdesk_panecensus::working_directory(pane.master_fd, pane.shell_pid)
    }

    fn processes(&self, pane: PaneHandles) -> Vec<u8> {
        slopdesk_panecensus::process_list(pane.master_fd, unix_seconds())
    }

    fn ports(&self, pane: PaneHandles) -> Vec<u8> {
        slopdesk_panecensus::port_list(pane.master_fd)
    }

    fn git_status(&self, cwd: &str) -> GitStatusPayload {
        slopdesk_git::status::of_path(cwd)
    }

    fn git_diff(&self, cwd: &str, file: &str) -> Option<Vec<u8>> {
        slopdesk_probe::git::diff(cwd, file)
    }

    fn list_directory(&self, absolute: &str) -> Option<Vec<DirEntry>> {
        let entries = slopdesk_probe::files::list_directory(std::path::Path::new(absolute))?;
        Some(
            entries
                .into_iter()
                .map(|entry| {
                    DirEntry {
                        is_dir: entry.is_dir,
                        name: entry.name,
                    }
                })
                .collect(),
        )
    }

    fn list_agent_sessions(&self, project: &str) -> Vec<AgentSessionInfo> {
        slopdesk_probe::files::list_sessions(&self.home, project)
            .into_iter()
            .map(|session| {
                AgentSessionInfo {
                    agent_kind_byte: session.kind,
                    id: session.id,
                    title: session.title,
                    cwd: session.cwd,
                    mtime_ms: session.mtime_ms,
                }
            })
            .collect()
    }

    fn read_agent_session(&self, id: &str) -> Option<Vec<u8>> {
        slopdesk_probe::files::read_session(&self.home, id)
    }

    fn host_name(&self) -> Option<String> {
        nix::unistd::gethostname()
            .ok()
            .map(|name| name.to_string_lossy().into_owned())
    }

    fn host_vitals(&self) -> Option<HostVitals> {
        let elapsed = u64::try_from(self.started.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.vitals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .sample(&self.home, elapsed)
    }
}

/// Seconds since the Unix epoch, or `0` on a clock before it — the process-list encoder reads it as
/// an age baseline, and an age of "everything started now" is a harmless answer to a broken clock.
fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|since| i64::try_from(since.as_secs()).ok())
        .unwrap_or_default()
}
