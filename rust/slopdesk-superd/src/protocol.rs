//! The `slopdesk-superd` ↔ `slopdesk-hostd` message set.
//!
//! A mirror of `Sources/SlopDeskSupervisor/SupervisorProtocol.swift`. JSON, so field names are the
//! contract — a rename on one side is a silent `None` on the other.
//!
//! ## This is the one protocol in the repo that must tolerate version skew
//! The three wire paths (`docs/46`) are golden-pinned at version `1` with no negotiation, and they
//! can be, because both ends ship in the same release. superd cannot: it is a LaunchAgent that
//! outlives not just hostd's process but hostd's **build**. You rebuild hostd all day; superd
//! stays whatever it was at login. So (`docs/51` §3):
//!
//! 1. **Append-only.** Verbs and fields are added, never repurposed or removed.
//! 2. **Both sides state a version in `hello`.** Major mismatch is refused with a diagnostic that
//!    names the fix, never a silent degradation.
//! 3. **An unknown verb is answered [`Status::Unsupported`], not dropped** — a newer hostd detects
//!    an older superd by asking, and falls back.
//! 4. **Changing this costs a superd restart, which costs every pane.** So it stays boring.
//!
//! `verb` is a `String`, not an enum, and payloads are `Option` fields on ONE struct rather than
//! enum variants, for exactly rule 3: an unknown verb must still *decode* so it can be answered.
//! A tagged enum would fail the deserialize and leave nothing to reply to. `deny_unknown_fields`
//! appears nowhere in this file, and that omission is rule 1.

use serde::{Deserialize, Serialize};

/// Bumped only for a breaking change. superd refuses a hostd whose major differs.
pub const VERSION_MAJOR: i32 = 1;
/// Bumped when a verb or field is added. Both sides interoperate freely across minors.
///
/// `2` added the output subscription — `subscribe` / `unsubscribe` / `pause` and the binary output
/// frame ([`crate::frame::TAG_OUTPUT`]).
///
/// `3` added the child-facing listeners — `listen` and the `connection` push that hands hostd an
/// accepted hook/ctl socket over `SCM_RIGHTS` — and [`StreamPosition::ended`], which is how a
/// subscriber arriving after its child already exited learns there is nothing more coming.
///
/// `4` added [`SpawnRequest::owner`] and [`PaneRecord::owner`] — which hostd a pane belongs to,
/// stored verbatim and never interpreted here.
///
/// `5` added the out-of-band sniff: [`SpawnRequest::shell_integration`] asks for it, the `0x04`
/// frame carries it, and [`verb::FORGET_TITLE`] retires its coalescing anchor.
///
/// `6` added the command-block tap: [`SpawnRequest::blocks`] asks for it, the `0x05` frame carries
/// what changed, and [`verb::BLOCK_OUTPUT`] / [`verb::BLOCK_SNAPSHOT`] / [`verb::BLOCK_CONTROL`]
/// read the retained ring that used to die with each hostd.
///
/// `7` moved the on-disk scrollback journal here: [`SpawnRequest::journal`] asks for one, and
/// [`verb::JOURNAL_INFO`] / [`verb::JOURNAL_DELETE`] / [`verb::JOURNAL_SWEEP`] read, remove and
/// bound them. It replaces the `<uuid>.scrollback.resume` sidecar outright — [`JournalReply::head`]
/// is the same number, answered by the process that numbers the stream.
pub const VERSION_MINOR: i32 = 7;

/// The verbs hostd may send. Kept as `&str` constants rather than an enum for rule 3.
pub mod verb {
    /// Version handshake. Must be first on every connection.
    pub const HELLO: &str = "hello";
    /// Fork a shell under a PTY and hand back the master.
    pub const SPAWN: &str = "spawn";
    /// Everything superd currently supervises.
    pub const LIST: &str = "list";
    /// Re-acquire a master fd for a pane superd already owns — the restart path.
    pub const ADOPT: &str = "adopt";
    /// Signal a supervised child.
    pub const SIGNAL: &str = "signal";
    /// Done with this pane for good.
    pub const RELEASE: &str = "release";
    /// Resize a supervised pane's PTY.
    pub const RESIZE: &str = "resize";
    /// Start receiving a pane's output, resuming from a byte offset.
    pub const SUBSCRIBE: &str = "subscribe";
    /// Stop receiving a pane's output. Does not end the pane, and does not stop superd reading it.
    pub const UNSUBSCRIBE: &str = "unsubscribe";
    /// Stop or resume superd's reads on a pane — the backpressure gate.
    pub const PAUSE: &str = "pause";
    /// Claim the child-facing listeners superd binds, by [`listener_kind`].
    pub const LISTEN: &str = "listen";
    /// Retire a pane sniffer's title-coalescing anchor. See
    /// [`crate::pump::Pump::forget_title_coalescing`].
    pub const FORGET_TITLE: &str = "forgetTitle";
    /// Fetch one finished command block's retained output, by index.
    pub const BLOCK_OUTPUT: &str = "blockOutput";
    /// Every block a pane's tap still knows — what a reattaching client is backfilled from.
    pub const BLOCK_SNAPSHOT: &str = "blockSnapshot";
    /// The agent-control read: the last N finished blocks with their output, the running one, and
    /// the index the next command will close under.
    pub const BLOCK_CONTROL: &str = "blockControl";
    /// Where a session's transcript is on disk, how big it is, the geometry it was written at, and
    /// how much of a LIVE pane's stream it already holds.
    pub const JOURNAL_INFO: &str = "journalInfo";
    /// Remove a session's transcript — the deliberate end of a pane.
    pub const JOURNAL_DELETE: &str = "journalDelete";
    /// Bound the orphans: unlink journals past an age or a count.
    pub const JOURNAL_SWEEP: &str = "journalSweep";
}

/// Unsolicited events superd pushes.
pub mod event {
    /// A supervised child was reaped.
    pub const EXITED: &str = "exited";
    /// An accepted child-facing connection, riding `SCM_RIGHTS`. See [`super::listener_kind`].
    pub const CONNECTION: &str = "connection";
}

/// The child-facing sockets superd binds and hostd serves.
///
/// These strings are wire values, so they are spelled once here and compared, never constructed.
/// The *sockets* are superd's — the addresses have to outlive the hostd whose pid used to be in
/// them — but everything that arrives on one is hostd's, and it arrives as a descriptor rather than
/// as relayed bytes. superd accepts and hands over; it parses nothing (`docs/51` §7).
pub mod listener_kind {
    /// The Claude-hook socket, advertised to children as `SLOPDESK_SOCKET_PATH`.
    pub const HOOK: &str = "hook";
    /// The agent-control socket, advertised to children as `SLOPDESK_CONTROL_SOCKET`.
    pub const CONTROL: &str = "control";
}

/// `ok` / `error` / `unsupported`.
///
/// `Unsupported` is deliberately distinct from `Error`: it is the answer that lets a newer hostd
/// discover an older superd's capability set at runtime instead of guessing from a version number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// The verb succeeded.
    Ok,
    /// The verb is known and failed. Not recoverable by falling back.
    Error,
    /// The verb is not in this superd's vocabulary — it is older than the caller.
    Unsupported,
}

// MARK: - Requests (hostd → superd)

/// One request. Exactly one payload field is set, chosen by `verb`.
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    /// Correlates the reply. Monotonic per connection, never `0` (`0` marks a notification).
    pub id: u64,
    /// One of [`verb`], or something newer than us — which is why this is a `String`.
    pub verb: String,
    /// Payload for [`verb::HELLO`].
    #[serde(default)]
    pub hello: Option<HelloRequest>,
    /// Payload for [`verb::SPAWN`].
    #[serde(default)]
    pub spawn: Option<SpawnRequest>,
    /// Payload for [`verb::ADOPT`].
    #[serde(default)]
    pub adopt: Option<AdoptRequest>,
    /// Payload for [`verb::SIGNAL`].
    #[serde(default)]
    pub signal: Option<SignalRequest>,
    /// Payload for [`verb::RELEASE`].
    #[serde(default)]
    pub release: Option<ReleaseRequest>,
    /// Payload for [`verb::RESIZE`].
    #[serde(default)]
    pub resize: Option<ResizeRequest>,
    /// Payload for [`verb::SUBSCRIBE`].
    #[serde(default)]
    pub subscribe: Option<SubscribeRequest>,
    /// Payload for [`verb::FORGET_TITLE`].
    #[serde(default, rename = "forgetTitle")]
    pub forget_title: Option<ForgetTitleRequest>,
    /// Payload for [`verb::UNSUBSCRIBE`].
    #[serde(default)]
    pub unsubscribe: Option<UnsubscribeRequest>,
    /// Payload for [`verb::PAUSE`].
    #[serde(default)]
    pub pause: Option<PauseRequest>,
    /// Payload for [`verb::LISTEN`].
    #[serde(default)]
    pub listen: Option<ListenRequest>,
    /// Payload for [`verb::BLOCK_OUTPUT`].
    #[serde(default, rename = "blockOutput")]
    pub block_output: Option<BlockOutputRequest>,
    /// Payload shared by [`verb::BLOCK_SNAPSHOT`] and [`verb::BLOCK_CONTROL`].
    #[serde(default, rename = "blockRead")]
    pub block_read: Option<BlockReadRequest>,
    /// Payload shared by the three journal verbs.
    #[serde(default)]
    pub journal: Option<JournalRequest>,
}

/// Claim the child-facing listeners.
///
/// A claim is per-kind and the most recent one wins, which is deliberately the same rule as
/// [`AdoptRequest`]: the hostd that just started is the one that should get the connections, and the
/// one it displaced is by definition the one that died. It is dropped when the claiming connection
/// goes away, which is what makes an unclaimed kind — a restart in progress — a state superd can
/// answer honestly rather than a queue of connections nobody will ever read.
#[derive(Debug, Clone, Deserialize)]
pub struct ListenRequest {
    /// Which listeners to claim, from [`listener_kind`]. An unknown kind fails the whole verb.
    #[serde(default)]
    pub kinds: Vec<String>,
}

/// The version handshake.
#[derive(Debug, Clone, Deserialize)]
pub struct HelloRequest {
    /// The caller's major. A mismatch is refused.
    #[serde(rename = "versionMajor")]
    pub version_major: i32,
    /// The caller's minor. Informational — both sides interoperate across minors.
    #[serde(rename = "versionMinor")]
    pub version_minor: i32,
    /// Free-form, for the log only — e.g. `slopdesk-hostd 0.3.0`.
    #[serde(default)]
    pub client: String,
}

/// Fork a shell under a PTY and hand back the master.
///
/// The environment is passed WHOLE rather than curated here: `HostEnvironment.curated` is hostd's
/// job and changes often, and superd must not need a rebuild when it does. superd overlays only
/// the values that are its own to know — the stable socket paths (`docs/51` §1).
#[derive(Debug, Clone, Deserialize)]
pub struct SpawnRequest {
    /// The value baked into the child as `SLOPDESK_PANE_ID`. superd records it so a later hostd
    /// can recover it verbatim instead of re-deriving it (`docs/51` §5).
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// The client-declared session UUID, recorded so hostd can re-associate a pane with its
    /// scrollback journal after a restart. Opaque to superd.
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// Absolute path to the binary.
    pub executable: String,
    /// `argv[0]`, when it must differ from `executable` — a login shell wants a leading `-`.
    #[serde(default)]
    pub argv0: Option<String>,
    /// `argv[1..]`.
    #[serde(default)]
    pub arguments: Vec<String>,
    /// The child's whole environment, before superd's socket-path overlay.
    #[serde(default)]
    pub environment: std::collections::BTreeMap<String, String>,
    /// Working directory. A path superd cannot `chdir` into falls back to `$HOME`, then `/`.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Initial window size.
    pub rows: u16,
    /// Initial window size.
    pub cols: u16,
    /// Which hostd this pane belongs to. Opaque to superd — it is stored, echoed back in `list`,
    /// and never interpreted.
    ///
    /// It exists because `attached` cannot answer the question on its own. After the rekey every
    /// hostd pane id is a bare session UUID, so a second hostd sweeping for survivors sees another
    /// daemon's panes as indistinguishable from its own, and a pane is unattached for the whole
    /// ~0.2 s of its owner's restart. Absent (an older hostd) means "unknown", and the reader falls
    /// back to `attached` alone.
    #[serde(default)]
    pub owner: Option<String>,
    /// Whether to install the zsh shell-integration shim for this child.
    ///
    /// A REQUEST, not a policy: hostd decides that a pane is an interactive user shell rather than
    /// a panel backend, and superd — which owns the child's whole lifetime, and therefore the
    /// generated directory's — decides whether a shim is possible and cleans it up afterwards. The
    /// falsy default keeps a service backend, and an older hostd, exactly as they were.
    #[serde(default, rename = "shellIntegration")]
    pub shell_integration: bool,
    /// Where to journal this pane's output, and how much of it to keep.
    ///
    /// Absent means no journal at all — a panel backend, a pane with no client-owned session id, or
    /// an operator who turned disk scrollback off. superd owns the FILE; every policy in this
    /// payload is hostd's, which is why it crosses the socket rather than being read from an
    /// environment superd would have to be restarted to change.
    #[serde(default)]
    pub journal: Option<JournalSpawn>,
    /// Whether to segment this pane's output into command blocks, and with what.
    ///
    /// Absent — an older hostd, or a pane whose operator turned blocks off — means no tap at all:
    /// no segmenter touches the stream, no `0x05` frame is ever sent, and the block verbs answer
    /// "not tapped" rather than "nothing yet".
    #[serde(default)]
    pub blocks: Option<BlocksRequest>,
}

/// What a pane's command-block tap should be built with.
///
/// The auto-progress list crosses as the RAW env value rather than a parsed list, and that is the
/// whole point: `None` means the operator never set the bridge and superd's built-in slow-command
/// list applies, `Some("")` means they cleared it and the feature is off, and any other value is
/// theirs. Sending a parsed list would put the built-in copy back in hostd, which is the second
/// implementation this port exists to remove.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct BlocksRequest {
    /// The verbatim `SLOPDESK_AUTO_PROGRESS_COMMANDS` value, absent when unset.
    #[serde(default, rename = "autoProgressCommands")]
    pub auto_progress_commands: Option<String>,
    /// Per-block output ceiling; `0` takes [`crate::commandblocks::DEFAULT_OUTPUT_CAP`].
    #[serde(default, rename = "outputCap")]
    pub output_cap: usize,
    /// How many finished blocks keep their output; `0` takes
    /// [`crate::blocks::DEFAULT_MAX_BLOCKS`].
    #[serde(default, rename = "maxBlocks")]
    pub max_blocks: usize,
    /// Total retained output ceiling; `0` takes
    /// [`crate::blocks::DEFAULT_MAX_TOTAL_OUTPUT_BYTES`].
    #[serde(default, rename = "maxTotalOutputBytes")]
    pub max_total_output_bytes: usize,
}

/// Re-acquire a master fd for a pane superd already owns.
#[derive(Debug, Clone, Deserialize)]
pub struct AdoptRequest {
    /// The pane to take back.
    #[serde(rename = "paneID")]
    pub pane_id: String,
}

/// Signal a supervised child.
///
/// hostd could `kill(2)` it directly (a non-parent with the same uid may signal), but routing it
/// through superd keeps superd's view of the pane honest and lets it distinguish a deliberate
/// teardown from a crash.
#[derive(Debug, Clone, Deserialize)]
pub struct SignalRequest {
    /// The pane whose process group is signalled.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// The signal number.
    pub signal: i32,
}

/// hostd is done with this pane **for good** — not merely detaching.
///
/// This is the distinction the whole design turns on. hostd exiting must NOT release panes, or the
/// restart takes the shells with it; only an explicit close does. `kill: false` is the "the child
/// already exited, just clean up" case.
#[derive(Debug, Clone, Deserialize)]
pub struct ReleaseRequest {
    /// The pane to forget.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// Whether to `SIGHUP` the child first.
    pub kill: bool,
}

/// Resize a supervised pane's PTY.
///
/// hostd holds the master and could `TIOCSWINSZ` it itself — and does, for latency. This verb
/// exists so superd's record stays truthful, because that record is what a *restarted* hostd reads
/// before it has a size of its own.
#[derive(Debug, Clone, Deserialize)]
pub struct ResizeRequest {
    /// The pane being resized.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// New row count.
    pub rows: u16,
    /// New column count.
    pub cols: u16,
}

/// Start receiving a pane's output.
///
/// The reply states where the stream actually resumes, and the backlog follows it immediately on
/// the same connection as [`crate::frame::TAG_OUTPUT`] frames, before any live byte — see
/// `Connection::subscribe`.
#[derive(Debug, Clone, Deserialize)]
pub struct SubscribeRequest {
    /// The pane to follow.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// The absolute offset to resume from. `0` for a pane this client has never seen; for a
    /// restart, the offset the previous life stopped at — which hostd does NOT have, so in practice
    /// an adopting hostd asks for `0` and takes whatever the ring still holds.
    #[serde(rename = "fromOffset")]
    pub from_offset: u64,
}

/// Stop receiving a pane's output.
///
/// Deliberately not the same thing as `release`: superd keeps reading the pane, because a pane
/// nobody is reading is a pane whose child blocks. This only stops the frames.
#[derive(Debug, Clone, Deserialize)]
pub struct UnsubscribeRequest {
    /// The pane to stop following.
    #[serde(rename = "paneID")]
    pub pane_id: String,
}

/// Retire a pane sniffer's title-coalescing anchor.
///
/// Sent when hostd's detector sees an agent EXIT, so the next agent's byte-identical opening title
/// is not deduped away. Fire-and-forget by design: the anchor is an optimisation, and the cost of
/// losing the race is a stale pane title, not a wrong one.
#[derive(Debug, Clone, Deserialize)]
pub struct ForgetTitleRequest {
    /// The pane whose anchor to retire.
    #[serde(rename = "paneID")]
    pub pane_id: String,
}

/// Fetch one finished block's retained output.
///
/// Answered from superd's ring rather than hostd's, because hostd's did not survive its own
/// restart: a client that clicked a block from before a rebuild got an empty body for output superd
/// had never stopped holding.
#[derive(Debug, Clone, Deserialize)]
pub struct BlockOutputRequest {
    /// The pane the block belongs to.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// Which block. An evicted or unknown index answers with no output, never an error — a block
    /// that aged out of the ring is an ordinary outcome, not a fault.
    pub index: u32,
}

/// Where a pane's transcript lives and how big it may get.
#[derive(Debug, Clone, Deserialize)]
pub struct JournalSpawn {
    /// The directory journals are filed in. Created if it is not there.
    pub directory: String,
    /// Per-file byte cap; `0` means "do not journal this pane", so a caller can pass the operator's
    /// number through without growing an `if` at every call site.
    #[serde(default, rename = "capBytes")]
    pub cap_bytes: usize,
}

/// Ask about, remove, or bound the journals in a directory.
///
/// One payload for three verbs because they differ only in which fields they read: the info and the
/// delete want a session, the sweep wants an age and a count.
#[derive(Debug, Clone, Deserialize)]
pub struct JournalRequest {
    /// The directory, as in [`JournalSpawn::directory`].
    pub directory: String,
    /// Which transcript, for [`verb::JOURNAL_INFO`] and [`verb::JOURNAL_DELETE`].
    #[serde(default, rename = "sessionID")]
    pub session_id: String,
    /// For [`verb::JOURNAL_SWEEP`]: anything not written within this many seconds goes.
    #[serde(default, rename = "maxAgeSeconds")]
    pub max_age_seconds: u64,
    /// For [`verb::JOURNAL_SWEEP`]: how many of the newest survive the age cut regardless.
    #[serde(default, rename = "keepNewest")]
    pub keep_newest: usize,
}

/// Read a pane's block tap.
///
/// One payload for two verbs because they differ only in how much they answer: the snapshot is
/// metadata for every block, the control read is the last `limit` blocks WITH their bytes. `limit`
/// is ignored by the snapshot.
#[derive(Debug, Clone, Deserialize)]
pub struct BlockReadRequest {
    /// The pane to read.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// How many recent blocks to answer with, for [`verb::BLOCK_CONTROL`].
    #[serde(default)]
    pub limit: usize,
}

/// The backpressure gate that used to live inside `PTYReadLoop`.
///
/// hostd asserts a pause when a channel's output queue crosses its high-water mark. superd then
/// issues no reads at all, the kernel's PTY buffer fills, and the shell blocks — which is how this
/// system has always kept its never-drop promise. Nothing is buffered on hostd's behalf and nothing
/// is discarded.
#[derive(Debug, Clone, Deserialize)]
pub struct PauseRequest {
    /// The pane to gate.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// `true` stops superd's reads on this pane.
    pub paused: bool,
}

// MARK: - Replies (superd → hostd)

/// One type carries both replies and notifications: `id == 0` means unsolicited, and `event` says
/// which. Keeping them in one type means the read loop has exactly one decode.
#[derive(Debug, Clone, Serialize)]
pub struct Reply {
    /// The `id` of the request being answered, or [`NOTIFICATION_ID`].
    pub id: u64,
    /// The outcome.
    pub status: Status,
    /// Human-readable diagnostic. Always populated for `Error` / `Unsupported`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Set for [`verb::HELLO`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hello: Option<HelloReply>,
    /// Set for [`verb::SPAWN`] and [`verb::ADOPT`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneRecord>,
    /// Set for [`verb::LIST`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub panes: Option<Vec<PaneRecord>>,
    /// Set only when `id` is [`NOTIFICATION_ID`]; one of [`event`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    /// Set for the [`event::EXITED`] notification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exited: Option<ExitedNotice>,
    /// Set for [`verb::SUBSCRIBE`].
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<StreamPosition>,
    /// Set for the [`event::CONNECTION`] notification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection: Option<ConnectionNotice>,
    /// Set for [`verb::JOURNAL_INFO`]. Absent when that session has no transcript on disk, which is
    /// a different answer from an empty one: only the first may fall back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub journal: Option<JournalReply>,
    /// Set for the three block-reading verbs.
    ///
    /// Absent — rather than an empty answer — for a pane with no tap, so hostd can tell "blocks are
    /// off for this pane" from "this pane has run nothing yet".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocks: Option<BlocksReply>,
}

/// What a block read answers with. Every field is optional because the three verbs fill different
/// ones, and a reader that wants the whole shape can ask for it in one round trip if it ever needs
/// to.
#[derive(Debug, Clone, Serialize)]
pub struct BlocksReply {
    /// [`verb::BLOCK_OUTPUT`]: the retained bytes, base64. Absent for an evicted or unknown index.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// [`verb::BLOCK_SNAPSHOT`]: every block still known, ascending.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<Vec<crate::blocks::BlockMeta>>,
    /// [`verb::BLOCK_CONTROL`]: the last `limit` finished blocks, oldest first, with their bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recent: Option<Vec<crate::blocks::ControlBlock>>,
    /// [`verb::BLOCK_CONTROL`]: the block still running, if one is.
    ///
    /// Its command line and how much it has printed, never its bytes: a `last-output` call while
    /// `tail -f` is running would otherwise ship a quarter of a megabyte to answer a question about
    /// the commands BEFORE it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open: Option<OpenBlock>,
    /// [`verb::BLOCK_CONTROL`]: the index the next command typed at this prompt will close under.
    #[serde(rename = "nextIndex", skip_serializing_if = "Option::is_none")]
    pub next_index: Option<u32>,
}

/// What [`verb::JOURNAL_INFO`] answers with.
#[derive(Debug, Clone, Serialize)]
pub struct JournalReply {
    /// Absolute path to the transcript. The caller reads the bytes itself — shipping a multi-MiB
    /// transcript back through JSON to hand it straight to a renderer would be a copy for nothing.
    pub path: String,
    /// How many bytes are on disk, once everything buffered was flushed.
    pub bytes: u64,
    /// The last geometry the pane applied, or `0` when the sidecar did not survive. A transcript
    /// parses faithfully only at the width it was emitted for.
    pub rows: u16,
    /// See [`JournalReply::rows`].
    pub cols: u16,
    /// How much of the LIVE pane's stream is already in the file, or absent when no pane is
    /// journaling there.
    ///
    /// This is the number the `<uuid>.scrollback.resume` sidecar used to carry, and the reason that
    /// file is gone: a subscriber resumes exactly here, and the process answering is the process
    /// that numbered the offsets, so there is nothing to write down and nothing to be stale.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<u64>,
}

/// The running command, as much of it as any caller has ever wanted.
#[derive(Debug, Clone, Serialize)]
pub struct OpenBlock {
    /// The typed command line.
    #[serde(rename = "commandText")]
    pub command_text: String,
    /// How many output bytes it has produced so far.
    #[serde(rename = "outputLen")]
    pub output_len: u32,
}

impl BlocksReply {
    /// An answer with nothing filled in yet.
    #[must_use]
    pub const fn empty() -> Self {
        Self {
            output: None,
            snapshot: None,
            recent: None,
            open: None,
            next_index: None,
        }
    }
}

/// The reserved `id` marking an unsolicited notification rather than an answer.
pub const NOTIFICATION_ID: u64 = 0;

impl Reply {
    /// A bare success with no payload.
    #[must_use]
    pub const fn ok(id: u64) -> Self {
        Self {
            id,
            status: Status::Ok,
            message: None,
            hello: None,
            pane: None,
            panes: None,
            event: None,
            exited: None,
            stream: None,
            connection: None,
            blocks: None,
            journal: None,
        }
    }

    /// A refusal. The verb is known and failed.
    #[must_use]
    pub fn error(id: u64, message: impl Into<String>) -> Self {
        Self {
            message: Some(message.into()),
            status: Status::Error,
            ..Self::ok(id)
        }
    }

    /// "I am older than you." Recoverable by the caller — rule 3.
    #[must_use]
    pub fn unsupported(id: u64, message: impl Into<String>) -> Self {
        Self {
            message: Some(message.into()),
            status: Status::Unsupported,
            ..Self::ok(id)
        }
    }

    /// The `exited` push.
    #[must_use]
    pub fn exited(notice: ExitedNotice) -> Self {
        Self {
            event: Some(event::EXITED.to_owned()),
            exited: Some(notice),
            ..Self::ok(NOTIFICATION_ID)
        }
    }

    /// The `connection` push. The accepted socket rides the frame's `SCM_RIGHTS`, so the body says
    /// only which listener it came from — everything else about it is hostd's to read.
    #[must_use]
    pub fn connection(kind: &str) -> Self {
        Self {
            event: Some(event::CONNECTION.to_owned()),
            connection: Some(ConnectionNotice {
                kind: kind.to_owned(),
            }),
            ..Self::ok(NOTIFICATION_ID)
        }
    }
}

/// Which child-facing listener an `SCM_RIGHTS` descriptor was accepted on.
#[derive(Debug, Clone, Serialize)]
pub struct ConnectionNotice {
    /// One of [`listener_kind`].
    pub kind: String,
}

/// The handshake answer, and the only place hostd learns the stable child-facing socket paths.
#[derive(Debug, Clone, Serialize)]
pub struct HelloReply {
    /// superd's major.
    #[serde(rename = "versionMajor")]
    pub version_major: i32,
    /// superd's minor.
    #[serde(rename = "versionMinor")]
    pub version_minor: i32,
    /// For the log, and for an operator asking who holds the panes.
    #[serde(rename = "superdPID")]
    pub superd_pid: i32,
    /// The STABLE agent-hook socket path children are told about. hostd must advertise this one
    /// into every spawned env, never a path of its own — hostd's pid may not appear in anything a
    /// live child remembers (`docs/51` §1).
    #[serde(rename = "hookSocketPath", skip_serializing_if = "Option::is_none")]
    pub hook_socket_path: Option<String>,
    /// The stable agent-control socket path, same rule.
    #[serde(rename = "controlSocketPath", skip_serializing_if = "Option::is_none")]
    pub control_socket_path: Option<String>,
}

/// Everything superd keeps about a pane.
///
/// Deliberately thin: no screen state, no scrollback, no detection state — those are hostd's and
/// are rebuilt (`docs/51` §6). superd storing them would make superd need a restart whenever they
/// change shape, and a superd restart costs every pane.
#[derive(Debug, Clone, Serialize)]
pub struct PaneRecord {
    /// The pane's stable identity, as hostd named it at spawn.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// Opaque to superd; hostd's key back to the scrollback journal.
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// The child's pid. Valid to `kill`, not to `waitpid` — only superd forked it.
    pub pid: i32,
    /// What was executed.
    pub executable: String,
    /// The directory the child actually got, after fallback.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Last known window size.
    pub rows: u16,
    /// Last known window size.
    pub cols: u16,
    /// Unix seconds. Integer on purpose — no float ever crosses this boundary.
    #[serde(rename = "spawnedAt")]
    pub spawned_at: i64,
    /// True when some hostd currently holds a duplicate of this pane's master fd. A pane that is
    /// live but unattached is the normal state during a hostd restart.
    pub attached: bool,
    /// Which hostd spawned it, verbatim from [`SpawnRequest::owner`]. `None` for a pane spawned by
    /// a hostd that predates the field — the reader treats that as "unknown", never as "yours".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
}

/// Where a subscription actually starts, and how far the pane has already got.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct StreamPosition {
    /// The absolute offset the backlog frames begin at. **Greater** than the requested offset when
    /// the ring had already evicted past it, which is the subscriber's only warning that its
    /// transcript has a hole. Splicing across one unannounced renders a screen that is wrong, not
    /// merely short.
    pub start: u64,
    /// The absolute offset just past the newest byte superd has read. Live frames continue here.
    pub head: u64,
    /// Whether anything was lost between the request and `start`. Redundant with comparing the two,
    /// and present anyway because a receiver that has to derive its own warning usually does not.
    pub lossy: bool,
    /// Whether the child is already gone, so `head` is the last offset there will ever be.
    ///
    /// The subscriber's only way to know. An `exited` notice would normally tell it, but a pane
    /// short-lived enough to finish before the `subscribe` arrives was announced dead before this
    /// connection was watching — so without this field the backlog would render and the session
    /// would then wait forever for an end that already happened.
    pub ended: bool,
}

/// A supervised child was reaped.
#[derive(Debug, Clone, Serialize)]
pub struct ExitedNotice {
    /// Which pane died.
    #[serde(rename = "paneID")]
    pub pane_id: String,
    /// Its pid, for the log.
    pub pid: i32,
    /// The exit code, or `128 + signal` for a signalled child — the same convention
    /// `PTYProcess`'s reaper already reports, so hostd's exit handling is unchanged.
    pub code: i32,
}

#[cfg(test)]
// The fixtures here are known-good and built inline, so `unwrap` IS the assertion.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::*;

    /// Rule 3: an unknown verb must DESERIALIZE, so it can be answered `unsupported`. If this ever
    /// fails, a newer hostd can no longer discover an older superd's capabilities by asking.
    #[test]
    fn unknown_verb_still_decodes() {
        let request: Request = serde_json::from_str(r#"{"id":9,"verb":"teleport"}"#).unwrap();
        assert_eq!(request.verb, "teleport");
        assert_eq!(request.id, 9);
        assert!(request.spawn.is_none());
    }

    /// Rule 1: a field a newer peer added must be ignored, not fatal. This is what lets an OLD
    /// superd keep serving a NEW hostd.
    #[test]
    fn unknown_fields_are_ignored() {
        let json = r#"{"id":4,"verb":"spawn","spawn":{"paneID":"p","sessionID":"s",
            "executable":"/bin/zsh","rows":24,"cols":80,"futureField":true},
            "futureTopLevel":{"nested":1}}"#;
        let request: Request = serde_json::from_str(json).unwrap();
        let spawn = request.spawn.unwrap();
        assert_eq!(spawn.pane_id, "p");
        assert_eq!(spawn.rows, 24);
        // Absent optional collections default rather than failing — same rule, applied to the
        // fields a newer hostd might stop sending.
        assert!(spawn.arguments.is_empty());
        assert!(spawn.environment.is_empty());
    }

    /// `unsupported` must stay distinguishable from `error` on the wire — collapsing them would
    /// turn "you are older than me" into "something went wrong", which is not recoverable.
    #[test]
    fn unsupported_is_distinct_from_error_on_the_wire() {
        let unsupported = serde_json::to_string(&Reply::unsupported(1, "no")).unwrap();
        let failed = serde_json::to_string(&Reply::error(1, "no")).unwrap();
        assert!(unsupported.contains(r#""status":"unsupported""#), "{unsupported}");
        assert!(failed.contains(r#""status":"error""#), "{failed}");
    }

    /// The Swift side decodes these keys by name. A rename here is a silent `nil` there.
    #[test]
    fn json_keys_match_the_swift_mirror() {
        let reply = Reply {
            pane: Some(PaneRecord {
                pane_id: "pane-a".to_owned(),
                session_id: "session-a".to_owned(),
                pid: 4242,
                executable: "/bin/zsh".to_owned(),
                cwd: Some("/tmp".to_owned()),
                rows: 24,
                cols: 80,
                spawned_at: 1_700_000_000,
                attached: true,
                owner: Some("hostd port=7777 state=default".to_owned()),
            }),
            ..Reply::ok(3)
        };
        let json = serde_json::to_string(&reply).unwrap();
        for key in [
            r#""paneID":"pane-a""#,
            r#""sessionID":"session-a""#,
            r#""spawnedAt":1700000000"#,
            r#""attached":true"#,
            r#""status":"ok""#,
        ] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
        // Absent optionals are omitted, not serialised as null — Swift decodes both, but the
        // notification path relies on `event` being absent to mean "this is an answer".
        assert!(!json.contains("event"), "{json}");
    }

    #[test]
    fn notification_uses_the_reserved_zero_id() {
        let notice = Reply::exited(ExitedNotice {
            pane_id: "pane-a".to_owned(),
            pid: 99,
            code: 137,
        });
        assert_eq!(notice.id, NOTIFICATION_ID);
        let json = serde_json::to_string(&notice).unwrap();
        assert!(json.contains(r#""id":0"#), "{json}");
        assert!(json.contains(r#""event":"exited""#), "{json}");
        assert!(json.contains(r#""code":137"#), "{json}");
    }
}
