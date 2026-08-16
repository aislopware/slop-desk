//! The message table: one decoded PATH-1 protocol message, its type byte, its channel, and the
//! exact size its frame will be.
//!
//! Frame layout is `[u32 BE payload_length][u8 message_type][body…]`, where `payload_length` counts
//! the type byte plus the body and EXCLUDES the four prefix bytes. All multi-byte integers are
//! big-endian; the hot path is manual binary encoding, never JSON.
//!
//! ## Additive within wire version 1
//! The host accepts only version 1 and there is no negotiation — host and client redeploy together
//! — so a new type is added by taking the next free byte. A peer that meets a type it does not know
//! DROPS the frame ([`WireError::UnknownMessageType`](crate::WireError::UnknownMessageType))
//! instead of trapping, which is what makes that safe. The type bytes are NOT contiguous by
//! accident: 15–17 were taken by later client→host additions while 20–37 filled up host→client, and
//! renumbering would break every pinned golden vector.

use crate::bytes::clamp_u16_field;

/// A UUID as its 16 raw bytes, in canonical order.
///
/// How both the session id and the workspace epoch travel. Kept as raw bytes rather than a parsed
/// type because nothing on this path inspects the version or variant fields; the value is an opaque
/// identity, and parsing it would only add a way to fail.
pub type RawUuid = [u8; 16];

/// Bytes a [`RawUuid`] occupies on the wire.
pub const SESSION_ID_BYTE_COUNT: usize = 16;

/// The all-zero session id, meaning "open a NEW session" in [`WireMessage::Hello`].
pub const NEW_SESSION_ID: RawUuid = [0; SESSION_ID_BYTE_COUNT];

/// The two TCP connections that make up a session.
///
/// A session uses **two** connections so a burst of PTY output on the data channel cannot delay a
/// resize or disconnect on the control channel. Advisory metadata only: framing and decoding are
/// identical on both, and nothing here opens a socket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Channel {
    /// PTY byte stream: `output`, `exit` (host → client) and `input` (client → host).
    Data,
    /// Session lifecycle, sizing and every inline signal.
    Control,
}

/// The semantic state of the foreground command in a pane's shell, from OSC 133.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandStatus {
    /// OSC 133;C — a command began executing (preexec). The pane is RUNNING.
    Running,
    /// OSC 133;D — the command finished (precmd of the next prompt). The pane is IDLE again.
    Idle {
        /// The command's `$?`, or `None` if the shell did not report one.
        exit_code: Option<i32>,
        /// Host-measured C→D wall-clock time, driving the long-command notification threshold.
        duration_ms: u32,
    },
}

/// One project's folded git status — the body of [`WireMessage::ProjectGitStatus`].
///
/// Every count is already folded host-side: `staged`/`modified`/`untracked` count each file's X and
/// Y porcelain nibble INDEPENDENTLY, so an `MM` file is both staged and modified.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProjectGitStatus {
    /// The repo's absolute toplevel — the By-Project section key this summary books under.
    pub repo_root: String,
    /// The current branch name (empty = detached HEAD).
    pub branch: String,
    /// Commits ahead of the upstream (0 when there is none).
    pub ahead: i32,
    /// Commits behind the upstream (0 when there is none).
    pub behind: i32,
    /// The repo's stash depth.
    pub stash_count: i32,
    /// Files with staged changes.
    pub staged: u32,
    /// Files with unstaged modifications.
    pub modified: u32,
    /// Untracked files.
    pub untracked: u32,
    /// Files in a conflicted state.
    pub conflicted: u32,
    /// The raw changed-file total.
    pub changed_count: u32,
}

/// One decoded protocol message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireMessage {
    // -- DATA, host → client ----------------------------------------------------------------- //
    /// PTY output. `seq` is a monotonic per-message index starting at 1 — NOT a byte offset — and
    /// `bytes` is the raw VT payload.
    Output {
        /// Monotonic per-message index, starting at 1.
        seq: i64,
        /// Raw VT bytes.
        bytes: Vec<u8>,
    },

    /// The child process exited with this status code.
    Exit {
        /// The child's exit status.
        code: i32,
    },

    // -- DATA, client → host ----------------------------------------------------------------- //
    /// Bytes to write to the PTY's stdin — keystrokes, pasted text, and so on.
    Input(Vec<u8>),

    // -- CONTROL, client → host -------------------------------------------------------------- //
    /// Session handshake. An all-zero `session_id` ([`NEW_SESSION_ID`]) opens a new session; a
    /// non-zero one resumes. `last_received_seq` is the highest contiguous output seq the client
    /// already holds, so the host replays only past it.
    Hello {
        /// Wire version the client speaks; the host accepts only [`crate::PROTOCOL_VERSION`].
        protocol_version: u16,
        /// The session to resume, or [`NEW_SESSION_ID`].
        session_id: RawUuid,
        /// Highest contiguous output seq already held.
        last_received_seq: i64,
    },

    /// Terminal resize — character cells plus optional pixel dimensions, mapping to `TIOCSWINSZ`.
    Resize {
        /// Columns.
        cols: u16,
        /// Rows.
        rows: u16,
        /// Pixel width, 0 if unknown.
        px_width: u16,
        /// Pixel height, 0 if unknown.
        px_height: u16,
    },

    /// Acknowledge output up to and including `seq`, letting the host release replay entries.
    Ack {
        /// Highest contiguous output seq durably received.
        seq: i64,
    },

    /// The client is leaving cleanly (empty body).
    Bye,

    /// Application-layer RTT probe. The timestamp is the CLIENT's monotonic clock, echoed verbatim
    /// in [`WireMessage::Pong`] by a stateless responder, so only the client interprets it.
    Ping {
        /// The client's monotonic clock reading.
        timestamp_ms: u64,
    },

    /// Request for a block's captured output bytes, by an index learned from a
    /// [`WireMessage::CommandBlock`] update.
    RequestBlockOutput {
        /// The block index to fetch.
        index: u32,
    },

    /// A generic host-metadata RPC request. ONE request/response pair backs every Details-Panel
    /// surface that reads host-side metadata, instead of a frozen wire type per surface.
    MetadataRequest {
        /// Client-chosen monotonic id, echoed verbatim in the response.
        request_id: u32,
        /// Raw verb byte; an unknown one is carried forward-tolerantly and answered
        /// `unsupportedVerb`.
        verb: u8,
        /// The verb's request argument, opaque to this envelope.
        payload: Vec<u8>,
    },

    /// A workspace-document request, verb-multiplexed exactly like [`WireMessage::MetadataRequest`]
    /// so a future workspace verb costs no type byte.
    WorkspaceRequest {
        /// The client's monotone request counter, for correlation only.
        request_seq: u32,
        /// Raw verb byte (`0` subscribe · `1` ack · `2` presence · `3` intent).
        verb: u8,
        /// Verb-specific body, opaque to this envelope.
        payload: Vec<u8>,
    },

    // -- CONTROL, host → client -------------------------------------------------------------- //
    /// Handshake reply carrying the authoritative session id and the seq the host will replay from.
    /// `returning_client` is decided BY THE HOST.
    HelloAck {
        /// The authoritative session id.
        session_id: RawUuid,
        /// The seq the host will replay from.
        resume_from_seq: i64,
        /// True when the host recognises this as a resuming client.
        returning_client: bool,
    },

    /// Window title text, driven by OSC 0/2 from the child.
    Title(String),

    /// Terminal bell (empty body).
    Bell,

    /// Per-command semantic status derived from OSC 133 C/D marks.
    CommandStatus(CommandStatus),

    /// An RTT probe reply: the client's [`WireMessage::Ping`] timestamp echoed verbatim.
    Pong {
        /// The client's timestamp, unmodified.
        timestamp_ms: u64,
    },

    /// An explicit desktop notification the child requested via OSC 9 or OSC 777. An OSC 9 with no
    /// explicit title carries an empty `title` and the client falls back to the pane title.
    Notification {
        /// The notification title, possibly empty.
        title: String,
        /// The notification body.
        body: String,
    },

    /// The PTY's current foreground-process basename — the coarse agent-detection path. `"claude"`
    /// means a `claude` is foreground; `""` or any other name clears it.
    ForegroundProcess {
        /// The foreground process basename.
        name: String,
    },

    /// A rich agent-status update folded from Claude Code hook events.
    ClaudeStatus {
        /// Raw urgency byte (`0` none · `1` idle · `2` done · `3` working · `4` needsPermission).
        /// Carried verbatim: an unknown future state is the CONSUMER's to clamp, not the decoder's.
        state: u8,
        /// Notification class (`0` none · `1` permission · `2` waitingForInput · `3` other).
        kind: u8,
        /// The often-empty hook message. Length-prefixed, so an empty label is unambiguous.
        label: String,
    },

    /// A per-command block METADATA update. Carries only metadata — never the output bytes, which
    /// are fetched on demand — so CONTROL cannot flood with command output.
    CommandBlock {
        /// 0-based block index in the channel's segmenter lifetime; the request key.
        index: u32,
        /// The command's `$?`, or `None` while running.
        exit_code: Option<i32>,
        /// Host-measured C→D time, or `None` while running.
        duration_ms: Option<u32>,
        /// True once the matching OSC 133 `D` arrived.
        complete: bool,
        /// Output bytes the host currently holds for this block.
        output_len: u32,
        /// The typed command line, capped by the segmenter.
        command_text: String,
        /// 1-based count of OSC 133 `A` prompt marks when this block's cycle began; `0` = unknown,
        /// on which the client skips the outline jump rather than mis-landing.
        prompt_ordinal: u32,
    },

    /// A block's captured output bytes, replying to [`WireMessage::RequestBlockOutput`]. Raw VT
    /// bytes with control sequences preserved; empty means the block was evicted or never existed.
    BlockOutput {
        /// The block index this answers.
        index: u32,
        /// The captured bytes.
        output: Vec<u8>,
    },

    /// A metadata RPC response. The host ALWAYS replies, so a client's pending-request registry can
    /// never hang.
    MetadataResponse {
        /// Echoes the request's id — the correlation key.
        request_id: u32,
        /// Raw status byte (`0` ok · `1` notFound · `2` error · `3` unsupportedVerb).
        status: u8,
        /// Verb-specific body, opaque to this envelope.
        payload: Vec<u8>,
    },

    /// The PTY's canonical-echo state, watched host-side via termios `ECHO`. `false` is a no-echo
    /// password prompt, on which the client engages secure event input.
    ///
    /// This genuinely requires a host→client signal: `ECHO` is set with `tcsetattr` and is
    /// INVISIBLE to the output byte stream, so no amount of VT parsing could derive it.
    InputEcho {
        /// True for canonical echo (the default), false for a no-echo prompt.
        enabled: bool,
    },

    /// An OSC 9;4 taskbar-style progress update, parsed out of the OSC-9 stream so a `4;1;50` never
    /// surfaces as a desktop alert.
    Progress {
        /// Raw state byte (`0` clear · `1` in-progress · `2` error · `3` indeterminate). Carried
        /// verbatim so the codec stays a faithful round-trip; the client re-validates and drops an
        /// unknown discriminant.
        state: u8,
        /// `0…100`; meaningful for states 1 and 2.
        percent: u8,
    },

    /// The pane's current working directory, from OSC 7.
    Cwd(String),

    /// The pane's By-Project sidebar key: the git toplevel containing the pane's cwd, else the cwd.
    /// Host-computed, so every client renders identical sections with zero re-derivation.
    ProjectKey(String),

    /// One project's folded git status — the event-driven sibling of the pull-only metadata RPC.
    ProjectGitStatus(ProjectGitStatus),

    /// The pane's sticky agent-session intent: the first real prompt of the session, so a sidebar
    /// row can be titled by its task instead of the process name every agent row shares. An empty
    /// string means the session ended.
    AgentSessionIntent(String),

    /// A workspace-document event.
    ///
    /// The epoch and BOTH state numbers are hoisted ahead of the payload so a client can drop a
    /// mis-based frame after a fixed 33-byte header read. That is load-bearing rather than tidy: a
    /// delta computed against a different document applies CLEANLY and corrupts silently, so cheap
    /// rejection is the whole defence.
    WorkspaceEvent {
        /// `0` snapshot · `1` diff · `2` presence · `3` intentResult · `4` reset. Only 0 and 1 may
        /// advance a client's state number or trigger an ack.
        kind: u8,
        /// Minted at every hostd start; a foreign epoch means reset-then-snapshot.
        epoch: RawUuid,
        /// The document state this frame is based on.
        base_state_num: i64,
        /// The document state this frame produces.
        new_state_num: i64,
        /// Verb-specific body, opaque to this envelope.
        payload: Vec<u8>,
    },
}

impl WireMessage {
    /// This message's on-wire type byte.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match *self {
            Self::Output { .. } => 1,
            Self::Exit { .. } => 2,
            Self::Input(_) => 3,
            Self::Hello { .. } => 10,
            Self::Resize { .. } => 11,
            Self::Ack { .. } => 12,
            Self::Bye => 13,
            Self::Ping { .. } => 14,
            Self::RequestBlockOutput { .. } => 15,
            Self::MetadataRequest { .. } => 16,
            Self::WorkspaceRequest { .. } => 17,
            Self::HelloAck { .. } => 20,
            Self::Title(_) => 21,
            Self::Bell => 22,
            Self::CommandStatus(_) => 23,
            Self::Pong { .. } => 24,
            Self::Notification { .. } => 25,
            Self::ForegroundProcess { .. } => 26,
            Self::ClaudeStatus { .. } => 27,
            Self::CommandBlock { .. } => 28,
            Self::BlockOutput { .. } => 29,
            Self::MetadataResponse { .. } => 30,
            Self::InputEcho { .. } => 31,
            Self::Progress { .. } => 32,
            Self::Cwd(_) => 33,
            Self::ProjectKey(_) => 34,
            Self::ProjectGitStatus(_) => 35,
            Self::AgentSessionIntent(_) => 36,
            Self::WorkspaceEvent { .. } => 37,
        }
    }

    /// The channel this message is expected to travel on (advisory; see [`Channel`]).
    #[must_use]
    pub const fn channel(&self) -> Channel {
        match *self {
            Self::Output { .. } | Self::Exit { .. } | Self::Input(_) => Channel::Data,
            _ => Channel::Control,
        }
    }

    /// The frame size this message would encode to if its opaque byte run were `run_len` bytes.
    ///
    /// The run is written verbatim — no escaping, no length that depends on its contents — so it
    /// costs exactly its own length. That is what lets a caller holding the run SEPARATELY (the FFI
    /// boundary, whose decode answers where the run sits rather than a copy of it) size a frame
    /// without materialising it. A run the message still carries is SUBSTITUTED, not added to, so
    /// the answer is the same whether the caller holds the run apart or not.
    #[must_use]
    pub fn wire_byte_count_with_run(&self, run_len: usize) -> usize {
        self.wire_byte_count()
            .saturating_sub(self.opaque_run().len())
            .saturating_add(run_len)
    }

    /// The exact byte count [`encode`](Self::encode) will produce, computed WITHOUT building the
    /// frame.
    ///
    /// The receive-side flow control credits this per consumed message, and it must match the
    /// sender's per-frame debit EXACTLY — a mismatch leaks or over-grants window forever, since the
    /// error accumulates rather than cancelling. That is why the clamped string helpers are shared
    /// with the encoder instead of each side measuring its own way.
    #[must_use]
    pub fn wire_byte_count(&self) -> usize {
        let body = match *self {
            Self::Output { ref bytes, .. } => 8 + bytes.len(),
            Self::Exit { .. } | Self::RequestBlockOutput { .. } => 4,
            Self::Input(ref bytes) => bytes.len(),
            Self::Hello { .. } => 2 + SESSION_ID_BYTE_COUNT + 8,
            Self::Resize { .. } | Self::Ack { .. } | Self::Ping { .. } | Self::Pong { .. } => 8,
            Self::Bye | Self::Bell => 0,
            Self::MetadataRequest { ref payload, .. }
            | Self::MetadataResponse { ref payload, .. }
            | Self::WorkspaceRequest { ref payload, .. } => 4 + 1 + 4 + payload.len(),
            Self::WorkspaceEvent { ref payload, .. } => 1 + 16 + 8 + 8 + 4 + payload.len(),
            Self::HelloAck { .. } => SESSION_ID_BYTE_COUNT + 8 + 1,
            Self::Title(ref text)
            | Self::Cwd(ref text)
            | Self::ProjectKey(ref text)
            | Self::AgentSessionIntent(ref text) => text.len(),
            Self::ForegroundProcess { ref name } => name.len(),
            Self::CommandStatus(status) => {
                match status {
                    CommandStatus::Running => 1,
                    CommandStatus::Idle { .. } => 1 + 1 + 4 + 4,
                }
            },
            Self::Notification { ref title, ref body } => 2 + clamp_u16_field(title).len() + body.len(),
            Self::ClaudeStatus { ref label, .. } => 1 + 1 + 2 + clamp_u16_field(label).len(),
            Self::CommandBlock { ref command_text, .. } => {
                4 + 1 + 4 + 1 + 4 + 1 + 4 + 4 + 2 + clamp_u16_field(command_text).len()
            },
            Self::BlockOutput { ref output, .. } => 4 + 4 + output.len(),
            Self::InputEcho { .. } => 1,
            Self::Progress { .. } => 2,
            Self::ProjectGitStatus(ref status) => {
                2 + clamp_u16_field(&status.repo_root).len()
                    + 2
                    + clamp_u16_field(&status.branch).len()
                    + 12
                    + 20
            },
        };
        // 4-byte length prefix + 1 type byte + body.
        4 + 1 + body
    }
}
