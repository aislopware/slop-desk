//! The per-verb payload codecs for the host metadata RPC.
//!
//! Each [`MetadataVerb`](super::MetadataVerb) that returns something STRUCTURED rides one of these
//! manual-binary sub-codecs INSIDE the opaque
//! [`MetadataResponse`](crate::WireMessage::MetadataResponse) payload — the envelope only
//! length-prefixes the bytes; these give them meaning. The `cwd` / `gitDiff` / `readAgentSession`
//! verbs carry raw UTF-8 or raw bytes and have NO nested codec, because the envelope's length
//! prefix already frames them.
//!
//! Everything here is manual big-endian binary, never JSON: every multi-byte integer is big-endian,
//! every string is `u16`-length-prefixed UTF-8, every list is `u16`-count-prefixed.
//!
//! ## Validate-then-drop
//! A metadata payload arrives over the same trusted mesh as the rest of the wire and is still
//! treated as hostile input:
//!
//! - every list count is checked against the reader's REMAINING bytes before the per-entry loop and
//!   before any allocation ([`checked_count`] — count-before-alloc), so a `0xFFFF` in front of two
//!   bytes costs nothing;
//! - every length-prefixed field goes through [`ByteReader`], which returns
//!   [`Truncated`](WireError::Truncated) rather than over-reading;
//! - every string field is STRICT UTF-8 — an invalid sequence is
//!   [`MalformedBody`](WireError::MalformedBody), never a replacement-character repair;
//! - interop discriminator bytes (`is_dir`, `has_repo`) are read as `byte != 0`, never assumed `{0,
//!   1}`;
//! - on ENCODE every `u16` length is clamped (strings at a `char` boundary, counts at 65535) so an
//!   absurd field can never WRAP its length and corrupt the trailer.

use core::ops::Range;

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, WireError};

// ---------------------------------------------------------------------------------------------- //
// Shared helpers
// ---------------------------------------------------------------------------------------------- //

/// A list count clamped to the `[0, 65535]` its `u16` field can hold.
///
/// Unreachable in production — the host caps every list far below this — and it has to exist
/// anyway: writing a WRAPPED count while still appending every entry would make the decoder
/// mis-split the body and shred whatever follows.
fn clamped_count(count: usize) -> usize {
    count.min(usize::from(u16::MAX))
}

/// The count field for `count`, which [`clamped_count`] has already brought into range.
fn count_field(count: usize) -> u16 {
    u16::try_from(count).unwrap_or(u16::MAX)
}

/// The count-before-alloc guard: rejects a declared `count` the body cannot possibly hold BEFORE
/// any capacity is reserved for it.
///
/// `fixed_bytes_per_entry` is the entry's fixed part only — every variable field is a length prefix
/// that has already been counted, and each of those is at minimum zero bytes long. So this is a
/// sound lower bound, and the per-entry reads catch the rest.
///
/// # Errors
/// [`WireError::Truncated`] when the declared count needs more bytes than remain.
fn checked_count(reader: &ByteReader<'_>, count: usize, fixed_bytes_per_entry: usize) -> Result<usize> {
    let needed = count
        .checked_mul(fixed_bytes_per_entry)
        .ok_or(WireError::Truncated)?;
    if needed > reader.bytes_remaining() {
        return Err(WireError::Truncated);
    }
    Ok(count)
}

// ---------------------------------------------------------------------------------------------- //
// ProcessList — verb 1
// ---------------------------------------------------------------------------------------------- //

/// One foreground process of a pane.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProcessInfo {
    /// The process id.
    pub pid: u32,
    /// Seconds the process has been running, `0` when unknown.
    pub uptime_sec: u32,
    /// The process basename, e.g. `-zsh` or `claude`.
    pub name: String,
}

/// Fixed bytes per [`ProcessInfo`]: pid, uptime, name length. The name itself may be empty.
pub const PROCESS_ENTRY_FIXED_BYTES: usize = 4 + 4 + 2;

/// Encodes a process list: `[u16 count]` then `[u32 pid][u32 uptime][u16 len][name]` per entry.
#[must_use]
pub fn encode_process_list(items: &[ProcessInfo]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + items.len() * PROCESS_ENTRY_FIXED_BYTES);
    encode_process_list_into(&mut out, items);
    out.into_vec()
}

/// Writes a process list into `out`.
///
/// The shape a caller holding its own buffer needs: it neither allocates nor copies, and with
/// [`ByteWriter::borrowing`] the SAME call both sizes and fills — writes past the end are counted,
/// not performed. See [`encode_process_list`] for the layout.
pub fn encode_process_list_into(out: &mut ByteWriter<'_>, items: &[ProcessInfo]) {
    let count = clamped_count(items.len());
    out.put_u16(count_field(count));
    for item in items.iter().take(count) {
        out.put_u32(item.pid);
        out.put_u32(item.uptime_sec);
        out.put_length_prefixed_str(&item.name);
    }
}

/// Decodes a process list.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared count,
/// [`WireError::MalformedBody`] on a non-UTF-8 name.
pub fn decode_process_list(data: &[u8]) -> Result<Vec<ProcessInfo>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16()?);
    let count = checked_count(&reader, count, PROCESS_ENTRY_FIXED_BYTES)?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let pid = reader.read_u32()?;
        let uptime_sec = reader.read_u32()?;
        let name = reader.read_length_prefixed_str("processList.name")?;
        items.push(ProcessInfo {
            pid,
            uptime_sec,
            name,
        });
    }
    Ok(items)
}

// ---------------------------------------------------------------------------------------------- //
// PortList — verb 2
// ---------------------------------------------------------------------------------------------- //

/// The transport protocol of a [`PortInfo`] — the meaning of its raw `proto` byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum PortProtocol {
    /// TCP.
    Tcp = 0,
    /// UDP.
    Udp = 1,
}

impl PortProtocol {
    /// The protocol for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Tcp),
            1 => Some(Self::Udp),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// One listening port of a pane.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PortInfo {
    /// The port number.
    pub port: u16,
    /// The transport protocol as a RAW byte, carried forward-tolerantly so an unknown future value
    /// never drops the entry. See [`PortInfo::port_protocol`].
    pub proto: u8,
    /// The owning process basename.
    pub proc_name: String,
}

impl PortInfo {
    /// The typed protocol, or `None` for an unknown future [`proto`](Self::proto) byte.
    #[must_use]
    pub const fn port_protocol(&self) -> Option<PortProtocol> {
        PortProtocol::from_byte(self.proto)
    }
}

/// Fixed bytes per [`PortInfo`]: port, proto, name length.
pub const PORT_ENTRY_FIXED_BYTES: usize = 2 + 1 + 2;

/// Encodes a port list. An empty list — "No listening ports" — encodes as `[u16 0]`.
#[must_use]
pub fn encode_port_list(items: &[PortInfo]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + items.len() * PORT_ENTRY_FIXED_BYTES);
    encode_port_list_into(&mut out, items);
    out.into_vec()
}

/// Writes a port list into `out`. See [`encode_process_list_into`] for why the shape exists.
pub fn encode_port_list_into(out: &mut ByteWriter<'_>, items: &[PortInfo]) {
    let count = clamped_count(items.len());
    out.put_u16(count_field(count));
    for item in items.iter().take(count) {
        out.put_u16(item.port);
        out.put_u8(item.proto);
        out.put_length_prefixed_str(&item.proc_name);
    }
}

/// Decodes a port list.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared count,
/// [`WireError::MalformedBody`] on a non-UTF-8 process name.
pub fn decode_port_list(data: &[u8]) -> Result<Vec<PortInfo>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16()?);
    let count = checked_count(&reader, count, PORT_ENTRY_FIXED_BYTES)?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let port = reader.read_u16()?;
        let proto = reader.read_u8()?;
        let proc_name = reader.read_length_prefixed_str("portList.procName")?;
        items.push(PortInfo {
            port,
            proto,
            proc_name,
        });
    }
    Ok(items)
}

// ---------------------------------------------------------------------------------------------- //
// DirListing — verb 6
// ---------------------------------------------------------------------------------------------- //

/// One entry of a single host directory level. LEAF names only — the client joins them with the
/// request path, which is what makes the listing lazy per-expand.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DirEntry {
    /// Whether the entry is a directory (read as `byte != 0`).
    pub is_dir: bool,
    /// The leaf name, with no path components.
    pub name: String,
}

/// Fixed bytes per [`DirEntry`]: the `is_dir` byte and the name length.
pub const DIR_ENTRY_FIXED_BYTES: usize = 1 + 2;

/// Encodes a one-level directory listing.
#[must_use]
pub fn encode_dir_listing(items: &[DirEntry]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + items.len() * DIR_ENTRY_FIXED_BYTES);
    encode_dir_listing_into(&mut out, items);
    out.into_vec()
}

/// Writes a one-level directory listing into `out`. See [`encode_process_list_into`].
pub fn encode_dir_listing_into(out: &mut ByteWriter<'_>, items: &[DirEntry]) {
    let count = clamped_count(items.len());
    out.put_u16(count_field(count));
    for item in items.iter().take(count) {
        out.put_bool(item.is_dir);
        out.put_length_prefixed_str(&item.name);
    }
}

/// Decodes a one-level directory listing.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared count,
/// [`WireError::MalformedBody`] on a non-UTF-8 leaf name.
pub fn decode_dir_listing(data: &[u8]) -> Result<Vec<DirEntry>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16()?);
    let count = checked_count(&reader, count, DIR_ENTRY_FIXED_BYTES)?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let is_dir = reader.read_bool()?;
        let name = reader.read_length_prefixed_str("dirListing.name")?;
        items.push(DirEntry { is_dir, name });
    }
    Ok(items)
}

// ---------------------------------------------------------------------------------------------- //
// GitStatus — verb 4
// ---------------------------------------------------------------------------------------------- //

/// One changed file in a git working tree.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GitFileChange {
    /// The porcelain `XY` status packed into one byte — high nibble = X (index), low nibble = Y
    /// (worktree), in the host probe's packing. Carried RAW; the client unpacks it.
    pub status_code: u8,
    /// The repo-relative path.
    pub path: String,
}

/// The porcelain breakdown folded from a status list's packed `XY` codes.
///
/// Each file counts INDEPENDENTLY per axis — an `MM` file is BOTH staged and modified. This is the
/// ONE fold shared by the client's pane summary and the host's push, so the two surfaces can never
/// disagree about what "3 modified" means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FoldedCounts {
    /// Files with an index change (X is not space).
    pub staged: usize,
    /// Files with a worktree change (Y is not space).
    pub modified: usize,
    /// Untracked files (`??`).
    pub untracked: usize,
    /// Unmerged files — a `U` on either side, or the `AA` / `DD` both-changed states.
    pub conflicted: usize,
}

/// The git status of a pane's cwd. Branch, remote and ahead/behind are SUBSUMED here rather than
/// answered by their own verb, because they render together with the changed-file list.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GitStatusPayload {
    /// Whether the cwd is inside a git repository (read as `byte != 0`).
    pub has_repo: bool,
    /// The current branch name; empty when detached or when there is no repo.
    pub branch: String,
    /// The `origin` remote URL; empty when there is no remote or no repo.
    pub remote_url: String,
    /// The absolute git toplevel — the precise By-Project grouping key. Empty when
    /// [`has_repo`](Self::has_repo) is false, and possibly empty even inside a repo when the probe
    /// could not resolve it; the client falls back to the pane cwd rather than depending on it.
    pub repo_root: String,
    /// Commits ahead of the upstream, `0` when there is none.
    pub ahead: i32,
    /// Commits behind the upstream, `0` when there is none.
    pub behind: i32,
    /// Entries in the repo's stash — a repo-global count, so the sidebar can show `$N` without the
    /// client shelling out to git.
    pub stash_count: i32,
    /// The changed files.
    pub files: Vec<GitFileChange>,
}

impl GitStatusPayload {
    /// The canonical "not a git repo" payload, every field at its wire-default.
    #[must_use]
    pub const fn no_repo() -> Self {
        Self {
            has_repo: false,
            branch: String::new(),
            remote_url: String::new(),
            repo_root: String::new(),
            ahead: 0,
            behind: 0,
            stash_count: 0,
            files: Vec::new(),
        }
    }

    /// See [`FoldedCounts`].
    #[must_use]
    pub fn folded_counts(&self) -> FoldedCounts {
        fold_status_codes(self.files.iter().map(|file| file.status_code))
    }
}

/// Which axes one packed `XY` status code counts on, as bit `0` staged, `1` modified, `2`
/// untracked, `3` conflicted.
///
/// The packing is: space=0 M=1 A=2 D=3 R=4 C=5 U=6 ?=7 !=8 T=9. Each code counts INDEPENDENTLY per
/// axis — an `MM` file is BOTH staged and modified, `??` is untracked, and a `U` on either side (or
/// `AA` / `DD`) is a conflict. This `const fn` is the ONE statement of that rule; the table below
/// is only it, evaluated 256 times at compile time.
const fn axes(code: u8) -> u8 {
    let x = code >> 4;
    let y = code & 0x0F;
    if x == 7 && y == 7 {
        return 0b0100; // ??
    }
    if x == 6 || y == 6 || (x == 2 && y == 2) || (x == 3 && y == 3) {
        return 0b1000; // unmerged: U on either side, or the AA / DD both-changed states
    }
    let staged = if x == 0 { 0 } else { 0b0001 }; // index change (X not space)
    let modified = if y == 0 { 0 } else { 0b0010 }; // worktree change (Y not space)
    staged | modified
}

/// [`axes`] for every byte, so the fold is a load and four adds per file rather than a branch tree.
#[expect(
    clippy::indexing_slicing,
    reason = "a const block cannot call get_mut, and the loop's bound IS the array's length"
)]
const AXES: [u8; 256] = {
    let mut table = [0u8; 256];
    let mut code = 0u8;
    loop {
        table[code as usize] = axes(code);
        if code == u8::MAX {
            break;
        }
        code += 1;
    }
    table
};

/// Folds packed `XY` status codes into their porcelain breakdown. See [`axes`] for the rule.
///
/// Takes the CODES rather than the files because the paths decide nothing here, and a caller that
/// only has the bytes — the FFI door, folding for a client that holds its files across a boundary —
/// must not have to rebuild a path per entry to ask.
pub fn fold_status_codes(codes: impl IntoIterator<Item = u8>) -> FoldedCounts {
    let mut counts = FoldedCounts::default();
    for code in codes {
        // The table has an entry for every byte, so the lookup is total.
        let axes = AXES.get(code as usize).copied().unwrap_or(0);
        counts.staged += usize::from(axes & 0b0001);
        counts.modified += usize::from((axes >> 1) & 0b0001);
        counts.untracked += usize::from((axes >> 2) & 0b0001);
        counts.conflicted += usize::from((axes >> 3) & 0b0001);
    }
    counts
}

/// Fixed bytes per [`GitFileChange`]: the status code and the path length.
pub const GIT_FILE_FIXED_BYTES: usize = 1 + 2;

/// Encodes a git status.
///
/// When `has_repo` is false ONLY the single `0` byte is written — the remaining fields never reach
/// the wire, which is why the no-repo payload is one byte rather than a run of empty strings.
#[must_use]
pub fn encode_git_status(status: &GitStatusPayload) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(1 + 6 + 12 + 2 + status.files.len() * GIT_FILE_FIXED_BYTES);
    encode_git_status_into(&mut out, status);
    out.into_vec()
}

/// Writes a git status into `out`. See [`encode_process_list_into`].
pub fn encode_git_status_into(out: &mut ByteWriter<'_>, status: &GitStatusPayload) {
    if !status.has_repo {
        out.put_u8(0);
        return;
    }
    let count = clamped_count(status.files.len());
    out.put_u8(1);
    out.put_length_prefixed_str(&status.branch);
    out.put_length_prefixed_str(&status.remote_url);
    out.put_length_prefixed_str(&status.repo_root);
    out.put_i32(status.ahead);
    out.put_i32(status.behind);
    out.put_i32(status.stash_count);
    out.put_u16(count_field(count));
    for file in status.files.iter().take(count) {
        out.put_u8(file.status_code);
        out.put_length_prefixed_str(&file.path);
    }
}

/// Decodes a git status. A false `has_repo` returns [`GitStatusPayload::no_repo`] regardless of any
/// trailing bytes.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared file count,
/// [`WireError::MalformedBody`] on a non-UTF-8 string field.
pub fn decode_git_status(data: &[u8]) -> Result<GitStatusPayload> {
    let mut reader = ByteReader::new(data);
    if !reader.read_bool()? {
        return Ok(GitStatusPayload::no_repo());
    }
    let branch = reader.read_length_prefixed_str("gitStatus.branch")?;
    let remote_url = reader.read_length_prefixed_str("gitStatus.remoteURL")?;
    let repo_root = reader.read_length_prefixed_str("gitStatus.repoRoot")?;
    let ahead = reader.read_i32()?;
    let behind = reader.read_i32()?;
    let stash_count = reader.read_i32()?;
    let count = usize::from(reader.read_u16()?);
    let count = checked_count(&reader, count, GIT_FILE_FIXED_BYTES)?;
    let mut files = Vec::with_capacity(count);
    for _ in 0..count {
        let status_code = reader.read_u8()?;
        let path = reader.read_length_prefixed_str("gitStatus.file.path")?;
        files.push(GitFileChange { status_code, path });
    }
    Ok(GitStatusPayload {
        has_repo: true,
        branch,
        remote_url,
        repo_root,
        ahead,
        behind,
        stash_count,
        files,
    })
}

// ---------------------------------------------------------------------------------------------- //
// AgentSessionList — verb 7
// ---------------------------------------------------------------------------------------------- //

/// The agent that owns an [`AgentSessionInfo`] — the meaning of its raw kind byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum AgentKind {
    /// Claude Code.
    Claude = 0,
    /// codex.
    Codex = 1,
    /// opencode.
    Opencode = 2,
}

impl AgentKind {
    /// The kind for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Claude),
            1 => Some(Self::Codex),
            2 => Some(Self::Opencode),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// One agent session file for a project.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AgentSessionInfo {
    /// The owning agent as a RAW byte, carried forward-tolerantly. See
    /// [`agent_kind`](Self::agent_kind).
    pub agent_kind_byte: u8,
    /// The session id or path the client passes back to
    /// [`ReadAgentSession`](super::MetadataVerb::ReadAgentSession).
    pub id: String,
    /// A human-readable session title, possibly empty.
    pub title: String,
    /// The session's project cwd.
    pub cwd: String,
    /// Last-modified time in milliseconds since the Unix epoch — newest first when sorted.
    pub mtime_ms: i64,
}

impl AgentSessionInfo {
    /// The typed agent, or `None` for an unknown future kind byte.
    #[must_use]
    pub const fn agent_kind(&self) -> Option<AgentKind> {
        AgentKind::from_byte(self.agent_kind_byte)
    }
}

/// Fixed bytes per [`AgentSessionInfo`]: kind, three length prefixes and the mtime.
pub const AGENT_SESSION_FIXED_BYTES: usize = 1 + 2 + 2 + 2 + 8;

/// Encodes an agent-session list.
#[must_use]
pub fn encode_agent_session_list(items: &[AgentSessionInfo]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + items.len() * AGENT_SESSION_FIXED_BYTES);
    encode_agent_session_list_into(&mut out, items);
    out.into_vec()
}

/// Writes an agent-session list into `out`. See [`encode_process_list_into`].
pub fn encode_agent_session_list_into(out: &mut ByteWriter<'_>, items: &[AgentSessionInfo]) {
    let count = clamped_count(items.len());
    out.put_u16(count_field(count));
    for item in items.iter().take(count) {
        out.put_u8(item.agent_kind_byte);
        out.put_length_prefixed_str(&item.id);
        out.put_length_prefixed_str(&item.title);
        out.put_length_prefixed_str(&item.cwd);
        out.put_i64(item.mtime_ms);
    }
}

/// Decodes an agent-session list.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared count,
/// [`WireError::MalformedBody`] on a non-UTF-8 string field.
pub fn decode_agent_session_list(data: &[u8]) -> Result<Vec<AgentSessionInfo>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16()?);
    let count = checked_count(&reader, count, AGENT_SESSION_FIXED_BYTES)?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let agent_kind_byte = reader.read_u8()?;
        let id = reader.read_length_prefixed_str("agentSession.id")?;
        let title = reader.read_length_prefixed_str("agentSession.title")?;
        let cwd = reader.read_length_prefixed_str("agentSession.cwd")?;
        let mtime_ms = reader.read_i64()?;
        items.push(AgentSessionInfo {
            agent_kind_byte,
            id,
            title,
            cwd,
            mtime_ms,
        });
    }
    Ok(items)
}

// ---------------------------------------------------------------------------------------------- //
// AgentHookStatus — verb 13
// ---------------------------------------------------------------------------------------------- //

/// Where the host's slopdesk Claude Code hooks stand.
///
/// The two flags are NOT one fact. Installed alone does not mean the integration works: every
/// installed hook opens by exiting when it finds no socket, so without a bound listener each one
/// exits silently and nothing ever reaches a pane. The settings card has to be able to say
/// installed-but-INACTIVE, with the restart instruction, rather than paint a green that means
/// nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AgentHookStatus {
    /// The slopdesk entries are present in the host's `~/.claude/settings.json`.
    pub installed: bool,
    /// The hostd hook listener socket is ACTUALLY bound, so hooks can flow.
    pub listener_active: bool,
}

/// Encodes an agent-hook-status response payload: `[u8 installed][u8 listenerActive]`.
#[must_use]
pub fn encode_agent_hook_status(status: AgentHookStatus) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2);
    encode_agent_hook_status_into(&mut out, status);
    out.into_vec()
}

/// Writes an agent-hook-status payload into `out`. See [`encode_process_list_into`].
pub fn encode_agent_hook_status_into(out: &mut ByteWriter<'_>, status: AgentHookStatus) {
    out.put_u8(u8::from(status.installed));
    out.put_u8(u8::from(status.listener_active));
}

/// Decodes an agent-hook-status response payload.
///
/// A flag is true for the byte `1` and for nothing else — NOT for "any non-zero". Both flags gate a
/// green light on a settings card, and the honest reading of a byte this build did not write is
/// that nothing has been established.
///
/// A MISSING second byte reads `listener_active == false`, which is the same rule applied to a
/// shorter body: a reply that predates the flag says nothing about the listener, and the answer
/// that says nothing must never be the green one. A longer body is tolerated (trailer ignored).
///
/// # Errors
/// [`WireError::Truncated`] on an EMPTY body — a reply carrying no flags at all is not a status,
/// and the caller shows "connect a session to manage hooks" rather than a false "not installed".
pub fn decode_agent_hook_status(data: &[u8]) -> Result<AgentHookStatus> {
    let mut reader = ByteReader::new(data);
    let installed = reader.read_u8()?;
    let listener_active = reader.read_u8().unwrap_or(0);
    Ok(AgentHookStatus {
        installed: installed == 1,
        listener_active: listener_active == 1,
    })
}

// ---------------------------------------------------------------------------------------------- //
// Clipboard sync — verbs 15 and 16
// ---------------------------------------------------------------------------------------------- //

/// The meaning of a [`ClipboardClip`]'s kind byte. `0` is RESERVED for the read-response's
/// "unchanged / empty" arm and is never a clip kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ClipboardKind {
    /// UTF-8 text.
    Text = 1,
    /// PNG image bytes.
    ImagePng = 2,
}

impl ClipboardKind {
    /// The kind for `byte`, or `None` for an unknown future value (including the reserved `0`).
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Text),
            2 => Some(Self::ImagePng),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// One synced clipboard clip: a raw kind byte plus the content.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ClipboardClip {
    /// The content kind as a RAW byte. See [`kind`](Self::kind).
    pub kind_byte: u8,
    /// The content — UTF-8 text bytes for [`ClipboardKind::Text`], PNG bytes for
    /// [`ClipboardKind::ImagePng`]. Opaque at this layer, because PNG is not UTF-8; the APPLIER
    /// validates text strictly before use.
    pub bytes: Vec<u8>,
}

impl ClipboardClip {
    /// The typed kind, or `None` for an unknown future kind byte — the receiver drops the clip.
    #[must_use]
    pub const fn kind(&self) -> Option<ClipboardKind> {
        ClipboardKind::from_byte(self.kind_byte)
    }
}

/// The per-clip content cap, 12 MiB — well under the 16 MiB frame cap with envelope headroom.
///
/// Both ends enforce it, and asymmetrically on purpose: the SENDER skips an over-cap clip, so sync
/// silently lags and the clipboard stays local, while the DECODER rejects one as malformed.
pub const MAX_CLIPBOARD_CONTENT_BYTES: usize = 12 * 1024 * 1024;

/// The read-request value meaning "baseline probe".
///
/// The host replies with its current change count and NO content, so a fresh connection learns
/// where the host clipboard stands without pulling — and applying — stale pre-connection state.
pub const CLIPBOARD_BASELINE_PROBE: i64 = -1;

/// Encodes a set-clipboard request payload: `[u8 kind][content]`. The content runs to the end of
/// the payload, because the RPC envelope already frames it.
#[must_use]
pub fn encode_clipboard_set(clip: &ClipboardClip) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(1 + clip.bytes.len());
    encode_clipboard_set_into(&mut out, clip.kind_byte, &clip.bytes);
    out.into_vec()
}

/// Writes a set-clipboard payload into `out` from BORROWED content.
///
/// The content is borrowed rather than owned for the reason this whole shape exists at the
/// clipboard: a clip runs to [`MAX_CLIPBOARD_CONTENT_BYTES`], and a caller that already holds
/// those 12 MiB must not have to hand over a copy of them to encode.
pub fn encode_clipboard_set_into(out: &mut ByteWriter<'_>, kind_byte: u8, bytes: &[u8]) {
    out.put_u8(kind_byte);
    out.put_bytes(bytes);
}

/// Decodes a set-clipboard request payload. The kind byte is carried RAW — an unknown future kind
/// decodes fine and the applier refuses it with `.error`.
///
/// # Errors
/// [`WireError::Truncated`] on an empty payload, [`WireError::MalformedBody`] when the content
/// exceeds [`MAX_CLIPBOARD_CONTENT_BYTES`].
pub fn decode_clipboard_set(data: &[u8]) -> Result<ClipboardClip> {
    let (kind_byte, content) = decode_clipboard_set_leaving_content(data)?;
    Ok(ClipboardClip {
        kind_byte,
        bytes: data.get(content).unwrap_or(&[]).to_vec(),
    })
}

/// A clip left in place: its kind byte, and the range its content occupies in the payload read.
pub type ElidedClip = (u8, Range<usize>);

/// Decodes a set-clipboard payload, answering WHERE its content sits instead of copying it.
///
/// The eliding shape, for the caller that already holds `data`: a clip runs to
/// [`MAX_CLIPBOARD_CONTENT_BYTES`], and handing back a copy of 12 MiB the caller would only copy
/// again is the one cost this layer can remove outright.
///
/// # Errors
/// As [`decode_clipboard_set`].
pub fn decode_clipboard_set_leaving_content(data: &[u8]) -> Result<ElidedClip> {
    let mut reader = ByteReader::new(data);
    let kind_byte = reader.read_u8()?;
    let content = reader.position()..data.len();
    if content.len() > MAX_CLIPBOARD_CONTENT_BYTES {
        return Err(WireError::malformed("clipboardSet: content exceeds cap"));
    }
    Ok((kind_byte, content))
}

/// Encodes a read-clipboard request payload: the `i64` host change count the client last saw
/// ([`CLIPBOARD_BASELINE_PROBE`] = none yet).
#[must_use]
pub fn encode_clipboard_read_request(last_seen_change_count: i64) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(8);
    encode_clipboard_read_request_into(&mut out, last_seen_change_count);
    out.into_vec()
}

/// Writes a read-clipboard request payload into `out`. See [`encode_process_list_into`].
pub fn encode_clipboard_read_request_into(out: &mut ByteWriter<'_>, last_seen_change_count: i64) {
    out.put_i64(last_seen_change_count);
}

/// Decodes a read-clipboard request payload.
///
/// # Errors
/// [`WireError::Truncated`] on a body shorter than 8 bytes.
pub fn decode_clipboard_read_request(data: &[u8]) -> Result<i64> {
    ByteReader::new(data).read_i64()
}

/// Encodes a read-clipboard response payload: `[i64 changeCount][u8 kind][content]`, where `None`
/// writes kind `0` — "unchanged / empty / the client's own push" — and no content.
#[must_use]
pub fn encode_clipboard_read_response(change_count: i64, clip: Option<&ClipboardClip>) -> Vec<u8> {
    let content_len = clip.map_or(0, |clip| clip.bytes.len());
    let mut out = ByteWriter::with_capacity(8 + 1 + content_len);
    encode_clipboard_read_response_into(
        &mut out,
        change_count,
        clip.map(|clip| (clip.kind_byte, clip.bytes.as_slice())),
    );
    out.into_vec()
}

/// Writes a read-clipboard response into `out` from BORROWED content. See
/// [`encode_clipboard_set_into`] for why the content is borrowed.
pub fn encode_clipboard_read_response_into(
    out: &mut ByteWriter<'_>,
    change_count: i64,
    clip: Option<(u8, &[u8])>,
) {
    out.put_i64(change_count);
    match clip {
        None => out.put_u8(0),
        Some((kind_byte, bytes)) => {
            out.put_u8(kind_byte);
            out.put_bytes(bytes);
        },
    }
}

/// Decodes a read-clipboard response payload.
///
/// Kind `0` returns no clip, and any trailing bytes after a kind-`0` marker are malformed rather
/// than ignored — a body that carries content it also says is absent is a framing bug, not a clip.
///
/// # Errors
/// [`WireError::Truncated`] on a short body, [`WireError::MalformedBody`] on content after a
/// kind-`0` marker or content over [`MAX_CLIPBOARD_CONTENT_BYTES`].
pub fn decode_clipboard_read_response(data: &[u8]) -> Result<(i64, Option<ClipboardClip>)> {
    let (change_count, clip) = decode_clipboard_read_response_leaving_content(data)?;
    Ok((
        change_count,
        clip.map(|(kind_byte, content)| {
            ClipboardClip {
                kind_byte,
                bytes: data.get(content).unwrap_or(&[]).to_vec(),
            }
        }),
    ))
}

/// Decodes a read-clipboard response, answering WHERE its content sits instead of copying it.
///
/// See [`decode_clipboard_set_leaving_content`]. The answer is the change count and, when a clip is
/// present, its kind byte with the [`ElidedClip`] range of its content.
///
/// # Errors
/// As [`decode_clipboard_read_response`].
pub fn decode_clipboard_read_response_leaving_content(data: &[u8]) -> Result<(i64, Option<ElidedClip>)> {
    let mut reader = ByteReader::new(data);
    let change_count = reader.read_i64()?;
    let kind_byte = reader.read_u8()?;
    let content = reader.position()..data.len();
    if kind_byte == 0 {
        if content.is_empty() {
            return Ok((change_count, None));
        }
        return Err(WireError::malformed("clipboardRead: content after kind-0 marker"));
    }
    if content.len() > MAX_CLIPBOARD_CONTENT_BYTES {
        return Err(WireError::malformed("clipboardRead: content exceeds cap"));
    }
    Ok((change_count, Some((kind_byte, content))))
}

// ---------------------------------------------------------------------------------------------- //
// HostVitals — verb 17
// ---------------------------------------------------------------------------------------------- //

/// The kernel's own memory-pressure verdict.
///
/// This is the reading that actually predicts a miserable session: a high memory PERCENT is normal
/// on a healthy Mac, and pressure is what says the machine is thrashing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MemoryPressure {
    /// Nothing to say.
    Normal = 0,
    /// The kernel is asking for memory back.
    Warn = 1,
    /// The kernel is thrashing.
    Critical = 2,
}

impl MemoryPressure {
    /// The level for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Normal),
            1 => Some(Self::Warn),
            2 => Some(Self::Critical),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The wire value for "the host could not read the disk".
///
/// Free space is a real `0` when a volume is genuinely full, so the unreadable case needs its own
/// value rather than borrowing zero — otherwise a failed syscall would draw a full-disk alarm.
pub const DISK_FREE_UNKNOWN: u32 = u32::MAX;

/// The host machine's pulse: how hard the Mac on the other end is working right now. Aggregates
/// only — nothing about WHAT it runs, only how much of it.
///
/// Percentages are pre-rounded by the HOST, which owns the sampling window; the client renders what
/// it is told and never re-derives a rate from two readings. Both are clamped to `0..=100` on
/// encode AND decode, so a wrong or hostile byte can never render "197%".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HostVitals {
    /// All-core CPU busy percent (`0..=100`) — `100 - idle`, so a 10-core Mac pegged on one core
    /// reads ~10, not 100.
    pub cpu_percent: u8,
    /// Physical memory in use percent (`0..=100`): wired + app-internal (minus purgeable) +
    /// compressed over installed RAM, with the file cache EXCLUDED — counting it would pin every
    /// Mac at 99% and say nothing.
    pub memory_percent: u8,
    /// The kernel's memory-pressure level as a RAW byte. See
    /// [`memory_pressure`](Self::memory_pressure).
    pub pressure_byte: u8,
    /// Free space in MiB on the volume the user's work lives on, or `None` when the host could not
    /// read it. ABSOLUTE rather than a percent: a 4 TB disk at 2% free still builds, a 128 GB disk
    /// at 8% does not. MiB granularity keeps the field 4 bytes and still spans 4 PiB.
    pub disk_free_mib: Option<u32>,
}

impl HostVitals {
    /// The typed pressure level. An unknown future byte reads [`MemoryPressure::Normal`] — a level
    /// this build cannot interpret must never light an alarm ink it cannot justify.
    #[must_use]
    pub const fn memory_pressure(&self) -> MemoryPressure {
        match MemoryPressure::from_byte(self.pressure_byte) {
            Some(level) => level,
            None => MemoryPressure::Normal,
        }
    }
}

/// Encodes a host-vitals response payload: `[u8 cpu%][u8 mem%][u8 pressure][u32 disk free MiB]`.
/// Both percents are clamped at the SOURCE; a missing disk reading goes out as
/// [`DISK_FREE_UNKNOWN`].
#[must_use]
pub fn encode_host_vitals(vitals: &HostVitals) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(7);
    encode_host_vitals_into(&mut out, vitals);
    out.into_vec()
}

/// Writes a host-vitals payload into `out`. See [`encode_process_list_into`].
pub fn encode_host_vitals_into(out: &mut ByteWriter<'_>, vitals: &HostVitals) {
    out.put_u8(vitals.cpu_percent.min(100));
    out.put_u8(vitals.memory_percent.min(100));
    out.put_u8(vitals.pressure_byte);
    out.put_u32(vitals.disk_free_mib.unwrap_or(DISK_FREE_UNKNOWN));
}

/// Decodes a host-vitals response payload.
///
/// An out-of-range percent is CLAMPED rather than rejected — the reading is still usable and a
/// status row must not vanish over one wild byte. A LONGER body is tolerated and its trailer
/// ignored, so a future field can be appended without breaking this reader.
///
/// # Errors
/// [`WireError::Truncated`] on a body shorter than 7 bytes.
pub fn decode_host_vitals(data: &[u8]) -> Result<HostVitals> {
    let mut reader = ByteReader::new(data);
    let cpu = reader.read_u8()?;
    let memory = reader.read_u8()?;
    let pressure_byte = reader.read_u8()?;
    let disk = reader.read_u32()?;
    Ok(HostVitals {
        cpu_percent: cpu.min(100),
        memory_percent: memory.min(100),
        pressure_byte,
        disk_free_mib: (disk != DISK_FREE_UNKNOWN).then_some(disk),
    })
}

// ---------------------------------------------------------------------------------------------- //
// ServiceEndpoint — verbs 18, 21 and 22
// ---------------------------------------------------------------------------------------------- //

/// The lifecycle state of a lazily-spawned host service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ServiceState {
    /// Spawned but not confirmed listening — the client polls the verb again.
    Starting = 0,
    /// Listening; the port is live and a webview can load it.
    Ready = 1,
    /// The service's binary is not installed on the host — the panel shows the install hint.
    Unavailable = 2,
}

impl ServiceState {
    /// The state for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Starting),
            1 => Some(Self::Ready),
            2 => Some(Self::Unavailable),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The host's answer to an ENSURE verb: where, and whether, a host-side service is listening.
///
/// Three verbs share the shape because they share the LIFECYCLE exactly — lazy, host-global,
/// never-wait, poll-until-ready. Nothing in it claims the far side is HTTP; verb 22's Android
/// bridge is a listener inside hostd, not a child serving a web UI.
///
/// The port is meaningful ONLY when the state is [`ServiceState::Ready`]: a starting instance may
/// not have bound its socket yet (the host spawns with port `0` and learns the real port from the
/// child's own log line), and an unavailable one has no port at all. Both carry `0`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ServiceEndpoint {
    /// The lifecycle state as a RAW byte. See [`state`](Self::state).
    pub state_byte: u8,
    /// The TCP port the instance listens on — `0` unless the state is [`ServiceState::Ready`].
    pub port: u16,
}

impl ServiceEndpoint {
    /// The typed state. An unknown future byte reads [`ServiceState::Starting`] — "keep polling" is
    /// the benign fallback, and a state this build cannot interpret must never render the
    /// install-hint surface it cannot justify.
    #[must_use]
    pub const fn state(&self) -> ServiceState {
        match ServiceState::from_byte(self.state_byte) {
            Some(state) => state,
            None => ServiceState::Starting,
        }
    }
}

/// Encodes an ensure-verb response payload: `[u8 state][u16 BE port]`.
#[must_use]
pub fn encode_service_endpoint(endpoint: &ServiceEndpoint) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(3);
    encode_service_endpoint_into(&mut out, endpoint);
    out.into_vec()
}

/// Writes an ensure-verb response payload into `out`. See [`encode_process_list_into`].
pub fn encode_service_endpoint_into(out: &mut ByteWriter<'_>, endpoint: &ServiceEndpoint) {
    out.put_u8(endpoint.state_byte);
    out.put_u16(endpoint.port);
}

/// Decodes an ensure-verb response payload. A longer body is tolerated and its trailer ignored, so
/// a future field can be appended without breaking this reader.
///
/// # Errors
/// [`WireError::Truncated`] on a body shorter than 3 bytes.
pub fn decode_service_endpoint(data: &[u8]) -> Result<ServiceEndpoint> {
    let mut reader = ByteReader::new(data);
    let state_byte = reader.read_u8()?;
    let port = reader.read_u16()?;
    Ok(ServiceEndpoint { state_byte, port })
}

// ---------------------------------------------------------------------------------------------- //
// CodeOpenDisposition — verb 19
// ---------------------------------------------------------------------------------------------- //

/// Where the host routed an open-in-code-server request.
///
/// The client reveals its code panel ONLY for [`Workbench`](Self::Workbench); a
/// [`HostDefault`](Self::HostDefault) open happened on the host's own screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum CodeOpenDisposition {
    /// Dispatched to the embedded VS Code workbench.
    Workbench = 0,
    /// Opened in the host's default app or Finder — the verb-9 behaviour.
    HostDefault = 1,
}

impl CodeOpenDisposition {
    /// The disposition for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Workbench),
            1 => Some(Self::HostDefault),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Encodes an open-in-code-server response payload: `[u8 disposition]`.
#[must_use]
pub fn encode_code_open_disposition(disposition: CodeOpenDisposition) -> Vec<u8> {
    vec![disposition.as_byte()]
}

/// Writes an open-in-code-server response payload into `out`. See [`encode_process_list_into`].
pub fn encode_code_open_disposition_into(out: &mut ByteWriter<'_>, disposition: CodeOpenDisposition) {
    out.put_u8(disposition.as_byte());
}

/// Decodes an open-in-code-server response payload.
///
/// A longer body is tolerated, and an unknown future byte reads [`CodeOpenDisposition::Workbench`]
/// — revealing the panel is the benign fallback, whose worst case is an expanded panel rather than
/// a silently invisible open.
///
/// # Errors
/// [`WireError::Truncated`] on an empty body.
pub fn decode_code_open_disposition(data: &[u8]) -> Result<CodeOpenDisposition> {
    let byte = ByteReader::new(data).read_u8()?;
    Ok(CodeOpenDisposition::from_byte(byte).unwrap_or(CodeOpenDisposition::Workbench))
}

// ---------------------------------------------------------------------------------------------- //
// CodeFontSpec — verb 20
// ---------------------------------------------------------------------------------------------- //

/// The client's terminal-font truth for the embedded workbench.
///
/// The terminal face, size and rhythm are CLIENT state — libghostty renders on the client and those
/// preferences never otherwise cross the wire — while the editor reads a host-side shared
/// `settings.json`. So the client pushes the three values and the host folds them in.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CodeFontSpec {
    /// The terminal font family name, e.g. `JetBrains Mono`.
    pub family: String,
    /// The terminal font size in points.
    pub size: f64,
    /// The EFFECTIVE cell-height ratio — family metrics times the adjust-cell-height mode, not the
    /// raw preference — with editor `lineHeight` semantics (a multiple of the size).
    pub line_height: f64,
}

/// Encodes a sync-code-font request payload:
/// `[u16 len][family UTF-8][u64 BE size bits][u64 BE lineHeight bits]`.
///
/// The doubles ride as IEEE-754 BIT PATTERNS rather than text, which is the bit-exact-floats
/// invariant: no textual round-trip is allowed to perturb a value the workbench then renders by.
#[must_use]
pub fn encode_code_font_spec(spec: &CodeFontSpec) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + spec.family.len() + 16);
    encode_code_font_spec_into(&mut out, spec);
    out.into_vec()
}

/// Writes a sync-code-font payload into `out`. See [`encode_process_list_into`].
pub fn encode_code_font_spec_into(out: &mut ByteWriter<'_>, spec: &CodeFontSpec) {
    out.put_length_prefixed_str(&spec.family);
    out.put_u64(spec.size.to_bits());
    out.put_u64(spec.line_height.to_bits());
}

/// Whether `ch` belongs to Swift's `CharacterSet.whitespaces` — Unicode general category `Zs` plus
/// CHARACTER TABULATION.
///
/// Deliberately NOT [`char::is_whitespace`], which also matches the line terminators (`\n`, `\r`,
/// `U+0085`, `U+2028`, `U+2029`). A family of `"\n"` is empty to Rust's `trim` and non-empty to
/// Swift's, and this validation decides whether a payload reaches a file the workbench trusts — the
/// two implementations have to refuse exactly the same bodies.
const fn is_swift_whitespace(ch: char) -> bool {
    matches!(
        ch,
        '\u{9}' | '\u{20}' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Decodes a sync-code-font request payload.
///
/// Out-of-range values are rejected as hard as truncation is: the host writes these into a file the
/// workbench trusts, so hostile bytes die here rather than there. `NaN` fails every comparison and
/// therefore throws, which is the intent. A longer body is tolerated (trailer ignored).
///
/// # Errors
/// [`WireError::Truncated`] on a short body, or [`WireError::MalformedBody`] on invalid UTF-8, an
/// all-whitespace family, a size outside `4..=128` pt, or a ratio outside `0.5..=4`.
pub fn decode_code_font_spec(data: &[u8]) -> Result<CodeFontSpec> {
    let mut reader = ByteReader::new(data);
    let family = reader.read_length_prefixed_str("codeFontSpec.family")?;
    let size = f64::from_bits(reader.read_u64()?);
    let line_height = f64::from_bits(reader.read_u64()?);
    if family.chars().all(is_swift_whitespace) {
        return Err(WireError::malformed("codeFontSpec.family: empty"));
    }
    if !(4.0..=128.0).contains(&size) {
        return Err(WireError::malformed("codeFontSpec.size: out of range"));
    }
    if !(0.5..=4.0).contains(&line_height) {
        return Err(WireError::malformed("codeFontSpec.lineHeight: out of range"));
    }
    Ok(CodeFontSpec {
        family,
        size,
        line_height,
    })
}

// ---------------------------------------------------------------------------------------------- //
// ShellComplete — verb 23
// ---------------------------------------------------------------------------------------------- //

/// One group's fixed part: two string lengths and a candidate count.
pub const SHELL_GROUP_FIXED_BYTES: usize = 6;

/// One candidate's fixed part: two string lengths and the flags byte.
pub const SHELL_CANDIDATE_FIXED_BYTES: usize = 5;

/// The candidate carries its own shell quoting and is inserted verbatim — zsh's `compadd -Q`.
const SHELL_FLAG_VERBATIM: u8 = 1 << 0;

/// The candidate has a description. Separate from its emptiness because "the completion function
/// offered none" and "it offered an empty one" are different facts, and only the first should
/// suppress the list's second column.
const SHELL_FLAG_HAS_DETAIL: u8 = 1 << 1;

/// One thing the user's own shell completion would insert.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellCandidate {
    /// The literal that replaces its group's prefix and suffix, affixes already composed in.
    pub text: String,
    /// The right-hand column — a flag's summary, a subcommand's one-line help. Meaningless unless
    /// `has_detail`.
    pub detail: String,
    /// Whether `detail` means anything.
    pub has_detail: bool,
    /// Whether the text is already quoted and must be inserted as-is. Quoting it a second time
    /// would put the escapes on the user's command line.
    pub verbatim: bool,
}

/// One `compadd` call's candidates, and the text they replace.
///
/// The group carries the text rather than an offset because the answer is asynchronous: the user is
/// typing through the round trip, and an offset computed against the buffer the host was asked
/// about would land somewhere else in the buffer that is now on screen. A prefix is
/// self-describing, so the client re-derives the range against its LIVE document and offers nothing
/// when it no longer matches.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellCompletionGroup {
    /// The text BEFORE the caret that accepting one of these replaces.
    pub prefix: String,
    /// The text AFTER the caret that it replaces. Empty at a normal caret.
    pub suffix: String,
    /// What the call offered.
    pub candidates: Vec<ShellCandidate>,
}

/// Encodes a shell-completion REQUEST: `[u32 cursor][utf8 buffer]`.
///
/// `cursor` is a CHARACTER index, not a byte one, because the shell's own caret is measured in
/// characters and the host hands it straight to the shell. It is the only unit boundary in the
/// whole verb; every other quantity that crosses is a string. The working directory is NOT here —
/// it comes from the pane, exactly as `gitStatus`'s does, which is what keeps the request from
/// naming a host path at all.
#[must_use]
pub fn encode_shell_complete_request(cursor: u32, buffer: &str) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(4 + buffer.len());
    encode_shell_complete_request_into(&mut out, cursor, buffer);
    out.into_vec()
}

/// Writes a shell-completion request into `out`. See [`encode_shell_complete_request`].
pub fn encode_shell_complete_request_into(out: &mut ByteWriter<'_>, cursor: u32, buffer: &str) {
    out.put_u32(cursor);
    // Unprefixed: the request payload's own envelope length frames it, and the buffer is everything
    // that follows the caret field.
    out.put_bytes(buffer.as_bytes());
}

/// Decodes a shell-completion request.
///
/// # Errors
/// [`WireError::Truncated`] on a body too short to hold the caret,
/// [`WireError::MalformedBody`] on a non-UTF-8 buffer.
pub fn decode_shell_complete_request(data: &[u8]) -> Result<(u32, String)> {
    let mut reader = ByteReader::new(data);
    let cursor = reader.read_u32()?;
    Ok((cursor, reader.remaining_str("shellComplete.buffer")?))
}

/// Encodes a shell-completion answer.
///
/// Layout: `[u16 groupCount]` then per group `[str prefix][str suffix][u16 candidateCount]` and per
/// candidate `[str text][str detail][u8 flags]`.
#[must_use]
pub fn encode_shell_complete(groups: &[ShellCompletionGroup]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(2 + groups.len() * SHELL_GROUP_FIXED_BYTES);
    encode_shell_complete_into(&mut out, groups);
    out.into_vec()
}

/// Writes a shell-completion answer into `out`. See [`encode_shell_complete`].
pub fn encode_shell_complete_into(out: &mut ByteWriter<'_>, groups: &[ShellCompletionGroup]) {
    let group_count = clamped_count(groups.len());
    out.put_u16(count_field(group_count));
    for group in groups.iter().take(group_count) {
        out.put_length_prefixed_str(&group.prefix);
        out.put_length_prefixed_str(&group.suffix);
        let count = clamped_count(group.candidates.len());
        out.put_u16(count_field(count));
        for candidate in group.candidates.iter().take(count) {
            out.put_length_prefixed_str(&candidate.text);
            out.put_length_prefixed_str(&candidate.detail);
            let mut flags = 0_u8;
            if candidate.verbatim {
                flags |= SHELL_FLAG_VERBATIM;
            }
            if candidate.has_detail {
                flags |= SHELL_FLAG_HAS_DETAIL;
            }
            out.put_u8(flags);
        }
    }
}

/// Decodes a shell-completion answer.
///
/// # Errors
/// [`WireError::Truncated`] on a short body or an over-declared count,
/// [`WireError::MalformedBody`] on non-UTF-8 text.
pub fn decode_shell_complete(data: &[u8]) -> Result<Vec<ShellCompletionGroup>> {
    let mut reader = ByteReader::new(data);
    let group_count = usize::from(reader.read_u16()?);
    let group_count = checked_count(&reader, group_count, SHELL_GROUP_FIXED_BYTES)?;
    let mut groups = Vec::with_capacity(group_count);
    for _ in 0..group_count {
        let prefix = reader.read_length_prefixed_str("shellComplete.prefix")?;
        let suffix = reader.read_length_prefixed_str("shellComplete.suffix")?;
        let count = usize::from(reader.read_u16()?);
        let count = checked_count(&reader, count, SHELL_CANDIDATE_FIXED_BYTES)?;
        let mut candidates = Vec::with_capacity(count);
        for _ in 0..count {
            let text = reader.read_length_prefixed_str("shellComplete.text")?;
            let detail = reader.read_length_prefixed_str("shellComplete.detail")?;
            // Read as a MASK rather than compared to a value: an unknown future bit leaves the two
            // this build knows intact instead of turning the whole flags byte into a rejection.
            let flags = reader.read_u8()?;
            candidates.push(ShellCandidate {
                text,
                detail,
                has_detail: flags & SHELL_FLAG_HAS_DETAIL != 0,
                verbatim: flags & SHELL_FLAG_VERBATIM != 0,
            });
        }
        groups.push(ShellCompletionGroup {
            prefix,
            suffix,
            candidates,
        });
    }
    Ok(groups)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        AgentHookStatus, AgentKind, AgentSessionInfo, CLIPBOARD_BASELINE_PROBE, ClipboardClip, ClipboardKind,
        CodeFontSpec, CodeOpenDisposition, DISK_FREE_UNKNOWN, DirEntry, GitFileChange, GitStatusPayload,
        HostVitals, MAX_CLIPBOARD_CONTENT_BYTES, MemoryPressure, PortInfo, PortProtocol, ProcessInfo,
        ServiceEndpoint, ServiceState, ShellCandidate, ShellCompletionGroup, WireError,
        decode_agent_hook_status, decode_agent_session_list, decode_clipboard_read_request,
        decode_clipboard_read_response, decode_clipboard_set, decode_code_font_spec,
        decode_code_open_disposition, decode_dir_listing, decode_git_status, decode_host_vitals,
        decode_port_list, decode_process_list, decode_service_endpoint, decode_shell_complete,
        decode_shell_complete_request, encode_agent_hook_status, encode_agent_session_list,
        encode_clipboard_read_request, encode_clipboard_read_response, encode_clipboard_set,
        encode_code_font_spec, encode_code_open_disposition, encode_dir_listing, encode_git_status,
        encode_host_vitals, encode_port_list, encode_process_list, encode_service_endpoint,
        encode_shell_complete, encode_shell_complete_request,
    };

    #[test]
    fn an_empty_list_is_just_its_count() {
        assert_eq!(encode_process_list(&[]), vec![0, 0]);
        assert_eq!(encode_port_list(&[]), vec![0, 0]);
        assert_eq!(encode_dir_listing(&[]), vec![0, 0]);
        assert_eq!(encode_agent_session_list(&[]), vec![0, 0]);
        assert!(decode_process_list(&[0, 0]).unwrap().is_empty());
        assert!(decode_port_list(&[0, 0]).unwrap().is_empty());
        assert!(decode_dir_listing(&[0, 0]).unwrap().is_empty());
        assert!(decode_agent_session_list(&[0, 0]).unwrap().is_empty());
    }

    #[test]
    fn every_list_codec_round_trips_its_fields() {
        let processes = vec![
            ProcessInfo {
                pid: 1,
                uptime_sec: 2,
                name: "-zsh".to_owned(),
            },
            ProcessInfo {
                pid: u32::MAX,
                uptime_sec: 0,
                name: "claude 🚀".to_owned(),
            },
        ];
        assert_eq!(
            decode_process_list(&encode_process_list(&processes)).unwrap(),
            processes
        );

        let ports = vec![
            PortInfo {
                port: 8080,
                proto: 0,
                proc_name: "node".to_owned(),
            },
            PortInfo {
                port: 53,
                proto: 1,
                proc_name: String::new(),
            },
        ];
        assert_eq!(decode_port_list(&encode_port_list(&ports)).unwrap(), ports);

        let entries = vec![
            DirEntry {
                is_dir: true,
                name: "Sources".to_owned(),
            },
            DirEntry {
                is_dir: false,
                name: "README.md".to_owned(),
            },
        ];
        assert_eq!(
            decode_dir_listing(&encode_dir_listing(&entries)).unwrap(),
            entries
        );

        let sessions = vec![AgentSessionInfo {
            agent_kind_byte: 1,
            id: "c42".to_owned(),
            title: String::new(),
            cwd: "/tmp/x".to_owned(),
            mtime_ms: -1,
        }];
        assert_eq!(
            decode_agent_session_list(&encode_agent_session_list(&sessions)).unwrap(),
            sessions
        );
    }

    #[test]
    fn an_over_declared_count_is_refused_before_it_can_drive_an_allocation() {
        // 0xFFFF entries declared in front of two bytes. Each shape has its own fixed size, so each
        // guard is exercised separately rather than trusting one to stand for all four.
        let hostile = [0xFF, 0xFF, 0x00, 0x00];
        assert_eq!(decode_process_list(&hostile), Err(WireError::Truncated));
        assert_eq!(decode_port_list(&hostile), Err(WireError::Truncated));
        assert_eq!(decode_dir_listing(&hostile), Err(WireError::Truncated));
        assert_eq!(decode_agent_session_list(&hostile), Err(WireError::Truncated));
    }

    #[test]
    fn a_non_utf8_string_field_is_malformed_rather_than_repaired() {
        // One process, name length 2, bytes 0xFF 0xFE — never a valid sequence.
        let body = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0xFF, 0xFE];
        let err = decode_process_list(&body).unwrap_err();
        assert_eq!(err, WireError::malformed("processList.name: invalid UTF-8"));
    }

    #[test]
    fn an_unknown_discriminator_byte_is_carried_rather_than_dropped() {
        let ports = vec![PortInfo {
            port: 1,
            proto: 9,
            proc_name: "future".to_owned(),
        }];
        let decoded = decode_port_list(&encode_port_list(&ports)).unwrap();
        assert_eq!(decoded[0].proto, 9);
        assert_eq!(decoded[0].port_protocol(), None);

        let sessions = vec![AgentSessionInfo {
            agent_kind_byte: 7,
            id: "x".to_owned(),
            title: String::new(),
            cwd: String::new(),
            mtime_ms: 0,
        }];
        let decoded = decode_agent_session_list(&encode_agent_session_list(&sessions)).unwrap();
        assert_eq!(decoded[0].agent_kind(), None);
        assert_eq!(AgentKind::from_byte(0), Some(AgentKind::Claude));
        assert_eq!(PortProtocol::from_byte(1), Some(PortProtocol::Udp));
    }

    #[test]
    fn a_dir_entry_flag_is_true_for_any_non_zero_byte() {
        // 1 entry, isDir = 2, name length 0. The wire is not trusted to send only {0, 1}.
        let decoded = decode_dir_listing(&[0, 1, 2, 0, 0]).unwrap();
        assert!(decoded[0].is_dir);
    }

    #[test]
    fn a_no_repo_status_is_one_byte_and_ignores_whatever_follows() {
        assert_eq!(encode_git_status(&GitStatusPayload::no_repo()), vec![0]);
        assert_eq!(decode_git_status(&[0]).unwrap(), GitStatusPayload::no_repo());
        assert_eq!(
            decode_git_status(&[0, 0xAA, 0xBB]).unwrap(),
            GitStatusPayload::no_repo(),
            "a trailer after the no-repo byte is not part of the payload"
        );
    }

    #[test]
    fn a_repo_status_round_trips_every_field() {
        let status = GitStatusPayload {
            has_repo: true,
            branch: "main".to_owned(),
            remote_url: "git@github.com:x/y.git".to_owned(),
            repo_root: "/Users/me/y".to_owned(),
            ahead: 3,
            behind: -1,
            stash_count: 2,
            files: vec![
                GitFileChange {
                    status_code: 0x12,
                    path: "Sources/main.swift".to_owned(),
                },
                GitFileChange {
                    status_code: 0xFF,
                    path: String::new(),
                },
            ],
        };
        assert_eq!(decode_git_status(&encode_git_status(&status)).unwrap(), status);
    }

    #[test]
    fn the_porcelain_fold_counts_each_axis_independently() {
        let status = GitStatusPayload {
            has_repo: true,
            files: vec![
                GitFileChange {
                    status_code: 0x11,
                    path: "mm".to_owned(),
                }, // MM — staged AND modified
                GitFileChange {
                    status_code: 0x77,
                    path: "u".to_owned(),
                }, // ?? — untracked
                GitFileChange {
                    status_code: 0x66,
                    path: "c".to_owned(),
                }, // UU — conflicted
                GitFileChange {
                    status_code: 0x22,
                    path: "aa".to_owned(),
                }, // AA — conflicted
                GitFileChange {
                    status_code: 0x01,
                    path: "m".to_owned(),
                }, // ` M` — modified only
            ],
            ..GitStatusPayload::no_repo()
        };
        let counts = status.folded_counts();
        assert_eq!(counts.staged, 1);
        assert_eq!(counts.modified, 2);
        assert_eq!(counts.untracked, 1);
        assert_eq!(counts.conflicted, 2);
    }

    #[test]
    fn a_clipboard_set_round_trips_and_refuses_an_empty_body() {
        let clip = ClipboardClip {
            kind_byte: ClipboardKind::Text.as_byte(),
            bytes: b"hello".to_vec(),
        };
        assert_eq!(decode_clipboard_set(&encode_clipboard_set(&clip)).unwrap(), clip);
        assert_eq!(decode_clipboard_set(&[]), Err(WireError::Truncated));
        // A PNG is not UTF-8, and the codec must not care.
        let png = ClipboardClip {
            kind_byte: ClipboardKind::ImagePng.as_byte(),
            bytes: vec![0x89, b'P', b'N', b'G', 0xFF, 0xFE],
        };
        assert_eq!(decode_clipboard_set(&encode_clipboard_set(&png)).unwrap(), png);
    }

    #[test]
    fn a_clipboard_content_over_the_cap_is_malformed() {
        let mut body = vec![ClipboardKind::Text.as_byte()];
        body.resize(MAX_CLIPBOARD_CONTENT_BYTES + 2, b'a');
        assert!(matches!(
            decode_clipboard_set(&body),
            Err(WireError::MalformedBody(_))
        ));
    }

    #[test]
    fn a_clipboard_read_request_carries_the_baseline_probe_intact() {
        let encoded = encode_clipboard_read_request(CLIPBOARD_BASELINE_PROBE);
        assert_eq!(encoded, vec![0xFF; 8]);
        assert_eq!(
            decode_clipboard_read_request(&encoded).unwrap(),
            CLIPBOARD_BASELINE_PROBE
        );
        assert_eq!(decode_clipboard_read_request(&[0; 7]), Err(WireError::Truncated));
    }

    #[test]
    fn a_kind_zero_read_response_means_no_clip_and_refuses_a_trailer() {
        let encoded = encode_clipboard_read_response(42, None);
        assert_eq!(encoded.len(), 9);
        assert_eq!(decode_clipboard_read_response(&encoded).unwrap(), (42, None));

        let mut lying = encoded;
        lying.push(0xAA);
        assert!(matches!(
            decode_clipboard_read_response(&lying),
            Err(WireError::MalformedBody(_))
        ));
    }

    #[test]
    fn a_read_response_with_a_clip_round_trips() {
        let clip = ClipboardClip {
            kind_byte: ClipboardKind::Text.as_byte(),
            bytes: "héllo".as_bytes().to_vec(),
        };
        let encoded = encode_clipboard_read_response(-7, Some(&clip));
        assert_eq!(
            decode_clipboard_read_response(&encoded).unwrap(),
            (-7, Some(clip))
        );
    }

    #[test]
    fn host_vitals_clamp_at_the_source_and_at_the_reader() {
        let wild = HostVitals {
            cpu_percent: 197,
            memory_percent: 200,
            pressure_byte: MemoryPressure::Critical.as_byte(),
            disk_free_mib: None,
        };
        let encoded = encode_host_vitals(&wild);
        assert_eq!(encoded, vec![100, 100, 2, 0xFF, 0xFF, 0xFF, 0xFF]);
        let decoded = decode_host_vitals(&encoded).unwrap();
        assert_eq!(decoded.cpu_percent, 100);
        assert_eq!(decoded.memory_percent, 100);
        assert_eq!(decoded.disk_free_mib, None, "the sentinel is not a real reading");
        assert_eq!(decoded.memory_pressure(), MemoryPressure::Critical);

        // A hostile percent that never went through the encoder is clamped rather than rejected.
        let decoded = decode_host_vitals(&[250, 251, 9, 0, 0, 0, 0]).unwrap();
        assert_eq!(decoded.cpu_percent, 100);
        assert_eq!(decoded.memory_percent, 100);
        assert_eq!(
            decoded.memory_pressure(),
            MemoryPressure::Normal,
            "a level this build cannot read must not light an alarm"
        );
        assert_eq!(
            decoded.disk_free_mib,
            Some(0),
            "a genuinely full disk is a real 0"
        );
    }

    #[test]
    fn a_host_vitals_body_may_grow_but_never_shrink() {
        assert_eq!(decode_host_vitals(&[1, 2, 3, 0, 0, 0]), Err(WireError::Truncated));
        let decoded = decode_host_vitals(&[1, 2, 0, 0, 0, 0, 1, 0xAA, 0xBB]).unwrap();
        assert_eq!(decoded.disk_free_mib, Some(1));
        assert_eq!(DISK_FREE_UNKNOWN, u32::MAX);
    }

    #[test]
    fn a_service_endpoint_round_trips_and_falls_back_to_starting() {
        let endpoint = ServiceEndpoint {
            state_byte: ServiceState::Ready.as_byte(),
            port: 8443,
        };
        let encoded = encode_service_endpoint(&endpoint);
        assert_eq!(encoded, vec![1, 0x20, 0xFB]);
        assert_eq!(decode_service_endpoint(&encoded).unwrap(), endpoint);
        assert_eq!(decode_service_endpoint(&[0, 0]), Err(WireError::Truncated));
        assert_eq!(
            decode_service_endpoint(&[9, 0, 0, 0xAA]).unwrap().state(),
            ServiceState::Starting,
            "keep polling is the benign fallback, not the install hint"
        );
    }

    #[test]
    fn an_unknown_open_disposition_reveals_the_panel() {
        for disposition in [CodeOpenDisposition::Workbench, CodeOpenDisposition::HostDefault] {
            let encoded = encode_code_open_disposition(disposition);
            assert_eq!(decode_code_open_disposition(&encoded).unwrap(), disposition);
        }
        assert_eq!(decode_code_open_disposition(&[]), Err(WireError::Truncated));
        assert_eq!(
            decode_code_open_disposition(&[9, 0xAA]).unwrap(),
            CodeOpenDisposition::Workbench
        );
    }

    /// Only the byte `1` is a green light, on either flag. "Any non-zero" is the reflex that breaks
    /// this: a byte this build did not write establishes nothing, and both flags gate a claim about
    /// the user's own machine.
    #[test]
    fn only_the_byte_one_lights_a_hook_flag() {
        for installed in [false, true] {
            for listener_active in [false, true] {
                let status = AgentHookStatus {
                    installed,
                    listener_active,
                };
                let encoded = encode_agent_hook_status(status);
                assert_eq!(encoded.len(), 2);
                assert_eq!(decode_agent_hook_status(&encoded).unwrap(), status);
            }
        }
        assert_eq!(
            decode_agent_hook_status(&[2, 2]).unwrap(),
            AgentHookStatus::default(),
            "a byte nobody here wrote is not a yes"
        );
    }

    /// A reply that predates the listener flag reads INACTIVE, and one carrying no flags at all is
    /// not a status. The two silences are different: the first is a fact, the second is an absence
    /// the caller renders as "connect a session to manage hooks".
    #[test]
    fn a_short_hook_status_is_never_a_false_green() {
        assert_eq!(decode_agent_hook_status(&[1]).unwrap(), AgentHookStatus {
            installed: true,
            listener_active: false,
        });
        assert_eq!(decode_agent_hook_status(&[]), Err(WireError::Truncated));
        assert_eq!(
            decode_agent_hook_status(&[1, 1, 0xAA]).unwrap(),
            AgentHookStatus {
                installed: true,
                listener_active: true,
            },
            "a trailer a newer host added is ignored, not fatal"
        );
    }

    #[test]
    fn a_font_spec_round_trips_its_doubles_bit_for_bit() {
        let spec = CodeFontSpec {
            family: "JetBrains Mono".to_owned(),
            size: 13.5,
            line_height: 1.200_000_000_000_000_2,
        };
        let encoded = encode_code_font_spec(&spec);
        let decoded = decode_code_font_spec(&encoded).unwrap();
        assert_eq!(decoded.size.to_bits(), spec.size.to_bits());
        assert_eq!(decoded.line_height.to_bits(), spec.line_height.to_bits());
        assert_eq!(decoded.family, spec.family);
    }

    #[test]
    fn a_font_spec_outside_its_range_dies_at_the_decoder() {
        let bad = |family: &str, size: f64, line_height: f64| {
            encode_code_font_spec(&CodeFontSpec {
                family: family.to_owned(),
                size,
                line_height,
            })
        };
        for body in [
            bad("", 13.0, 1.2),
            bad("   ", 13.0, 1.2),      // Zs only — Swift's trim empties it too
            bad("\u{3000}", 13.0, 1.2), // IDEOGRAPHIC SPACE is Zs
            bad("Mono", 3.9, 1.2),
            bad("Mono", 128.5, 1.2),
            bad("Mono", 13.0, 0.4),
            bad("Mono", 13.0, 4.1),
            bad("Mono", f64::NAN, 1.2),
            bad("Mono", 13.0, f64::NAN),
            bad("Mono", f64::INFINITY, 1.2),
        ] {
            assert!(
                matches!(decode_code_font_spec(&body), Err(WireError::MalformedBody(_))),
                "the workbench reads this file; hostile values die here"
            );
        }
        // A newline is NOT whitespace to Swift's `CharacterSet.whitespaces`, so it is a legal
        // family byte-for-byte. The Swift that said so is deleted; a peer still running it is not,
        // and a decoder that refuses a body its peer accepts is a dropped pane, not a stricter
        // gate.
        assert!(decode_code_font_spec(&bad("\n", 13.0, 1.2)).is_ok());
        // The inclusive bounds are on the accepted side.
        assert!(decode_code_font_spec(&bad("Mono", 4.0, 0.5)).is_ok());
        assert!(decode_code_font_spec(&bad("Mono", 128.0, 4.0)).is_ok());
    }

    /// The caret is CHARACTERS and the buffer is the rest of the body — a multi-byte line is where
    /// a byte-index caret would put the shell's caret in the wrong word, and a buffer with a `\0`
    /// or a newline in it is a command line a user can genuinely type.
    #[test]
    fn a_completion_request_round_trips_a_character_caret_over_a_multi_byte_line() {
        for (cursor, buffer) in [
            (0_u32, ""),
            (3, "git"),
            (7, "echo \u{e9}\u{e9} th\u{e9}"),
            (2, "a\nb"),
            (1, "\u{1f600}x"),
        ] {
            let body = encode_shell_complete_request(cursor, buffer);
            assert_eq!(
                decode_shell_complete_request(&body),
                Ok((cursor, buffer.to_owned()))
            );
        }
        assert!(matches!(
            decode_shell_complete_request(&[0, 0, 0]),
            Err(WireError::Truncated)
        ));
        // The buffer is a command line and a command line is text. Non-UTF-8 is a peer fault, not a
        // filename to repair.
        assert!(matches!(
            decode_shell_complete_request(&[0, 0, 0, 1, 0xFF]),
            Err(WireError::MalformedBody(_))
        ));
    }

    /// The two flag bits carry the two facts a re-derivation on the far side would get wrong: that
    /// a candidate is already quoted, and that it has no description as opposed to an empty one.
    #[test]
    fn a_completion_answer_round_trips_both_flag_bits_and_the_empty_detail() {
        let groups = vec![
            ShellCompletionGroup {
                prefix: "com".to_owned(),
                suffix: String::new(),
                candidates: vec![ShellCandidate {
                    text: "commit".to_owned(),
                    detail: "record changes to the repository".to_owned(),
                    has_detail: true,
                    verbatim: false,
                }],
            },
            ShellCompletionGroup {
                prefix: "rust/slopdesk-w".to_owned(),
                suffix: "ire".to_owned(),
                candidates: vec![
                    ShellCandidate {
                        text: "rust/slopdesk-wire".to_owned(),
                        detail: String::new(),
                        has_detail: false,
                        verbatim: true,
                    },
                    // An empty description that WAS offered — the case a `detail.is_empty()` test
                    // on the far side would silently turn into "no description".
                    ShellCandidate {
                        text: "rust/slopdesk-workspace".to_owned(),
                        detail: String::new(),
                        has_detail: true,
                        verbatim: true,
                    },
                ],
            },
        ];
        let body = encode_shell_complete(&groups);
        assert_eq!(decode_shell_complete(&body), Ok(groups));
        assert_eq!(decode_shell_complete(&encode_shell_complete(&[])), Ok(Vec::new()));
    }

    /// Count-before-alloc, on both counts. A declared group or candidate count the body cannot hold
    /// must cost nothing rather than reserve for it.
    #[test]
    fn an_over_declared_completion_count_is_refused_before_it_allocates() {
        assert!(matches!(
            decode_shell_complete(&[0xFF, 0xFF, 0]),
            Err(WireError::Truncated)
        ));
        // One well-formed group header, then a candidate count nothing backs.
        assert!(matches!(
            decode_shell_complete(&[0, 1, 0, 0, 0, 0, 0xFF, 0xFF]),
            Err(WireError::Truncated)
        ));
    }

    /// A bit this build does not know must leave the two it does intact. The alternative — reading
    /// the flags byte as a value — would make one future bit drop every candidate in the answer.
    #[test]
    fn an_unknown_flag_bit_leaves_the_known_ones_readable() {
        let mut body = encode_shell_complete(&[ShellCompletionGroup {
            prefix: "c".to_owned(),
            suffix: String::new(),
            candidates: vec![ShellCandidate {
                text: "commit".to_owned(),
                detail: String::new(),
                has_detail: false,
                verbatim: true,
            }],
        }]);
        let last = body.len() - 1;
        body[last] |= 0b1000_0000;
        let decoded = decode_shell_complete(&body).unwrap();
        assert!(decoded[0].candidates[0].verbatim);
        assert!(!decoded[0].candidates[0].has_detail);
    }
}
