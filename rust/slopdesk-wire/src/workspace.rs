//! The workspace-document channel's payload codecs.
//!
//! These ride INSIDE [`WorkspaceRequest`](crate::WireMessage::WorkspaceRequest) (type 17) and
//! [`WorkspaceEvent`](crate::WireMessage::WorkspaceEvent) (type 37).
//!
//! Both envelopes are verb-multiplexed the way the metadata RPC is, for the same reason: the whole
//! multi-client document costs exactly TWO message types no matter how many operations it grows,
//! and every operation after the first costs zero — which matters because three unknown-type probes
//! had already pinned 17 before this document claimed it.
//!
//! ## What is here and what is not
//! These are the CHANNEL payloads: who is subscribing, who is present, what they intend, and what
//! came of it. The DOCUMENT entries themselves — the tab/pane/layout state a snapshot or diff
//! carries — are a separate codec, and the `WorkspaceEvent` payload holds those bytes opaquely.
//!
//! ## Bounds, not credentials
//! Every field that a peer controls the size of is bounded here
//! ([`WorkspaceSubscribe::MAX_LABEL_BYTES`], [`WorkspacePresenceRoster::MAX_RECORDS`]) so a hostile
//! peer cannot make the host retain an arbitrarily large string or list per connection. Nothing
//! here authenticates anything: [`WorkspaceClientKind`] is a LABEL, checked nowhere and granting
//! nothing, so the no-app-layer-auth directive is untouched.

use core::ops::Range;

use crate::bytes::{ByteReader, ByteWriter, clamp_utf8};
use crate::error::{Result, WireError};
use crate::message::{RawUuid, SESSION_ID_BYTE_COUNT};

// ---------------------------------------------------------------------------------------------- //
// Verb / kind vocabulary
// ---------------------------------------------------------------------------------------------- //

/// The client → host verbs multiplexed inside `workspaceRequest` (type 17).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WorkspaceRequestVerb {
    /// Also the RESYNC verb: re-sending it is how a client recovers from a mis-based diff. There is
    /// deliberately no separate "resend", so reconnect and steady state are ONE code path.
    Subscribe = 0,
    /// Acknowledge a state number, retiring the diffs the host was holding for this client.
    Ack = 1,
    /// This client's viewport and focus.
    Presence = 2,
    /// A mutation the client wants applied to the document.
    Intent = 3,
}

impl WorkspaceRequestVerb {
    /// Every verb this build routes, in wire order.
    pub const ALL: [Self; 4] = [Self::Subscribe, Self::Ack, Self::Presence, Self::Intent];

    /// The verb for `byte`, or `None` for one this build does not route.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Subscribe),
            1 => Some(Self::Ack),
            2 => Some(Self::Presence),
            3 => Some(Self::Intent),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The host → client frame kinds multiplexed inside `workspaceEvent` (type 37).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WorkspaceEventKind {
    /// The whole document at a state number.
    Snapshot = 0,
    /// A change from one state number to the next.
    Diff = 1,
    /// The presence roster — a full REPLACE, never diffed, and never touching the state number.
    /// Presence is not part of the document and must not make the host retire, via assumed-acked, a
    /// diff it never sent.
    Presence = 2,
    /// The outcome of one intent.
    IntentResult = 3,
    /// Drop everything and resubscribe from 0. Carries the NEW epoch.
    Reset = 4,
}

impl WorkspaceEventKind {
    /// Every kind this build emits, in wire order.
    pub const ALL: [Self; 5] = [
        Self::Snapshot,
        Self::Diff,
        Self::Presence,
        Self::IntentResult,
        Self::Reset,
    ];

    /// The kind for `byte`, or `None` for one this build does not know.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Snapshot),
            1 => Some(Self::Diff),
            2 => Some(Self::Presence),
            3 => Some(Self::IntentResult),
            4 => Some(Self::Reset),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The outcome of one intent, carried by [`WorkspaceEventKind::IntentResult`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WorkspaceIntentStatus {
    /// The document changed.
    Applied = 0,
    /// The intent was based on a state the document has moved past.
    RejectedStale = 1,
    /// The intent's arguments do not describe a legal change.
    RejectedInvalid = 2,
    /// The host does not know this op byte.
    UnknownOp = 3,
    /// The intent named an entity the document does not hold.
    RejectedNotFound = 4,
}

impl WorkspaceIntentStatus {
    /// Every status this build produces, in wire order.
    pub const ALL: [Self; 5] = [
        Self::Applied,
        Self::RejectedStale,
        Self::RejectedInvalid,
        Self::UnknownOp,
        Self::RejectedNotFound,
    ];

    /// The status for `byte`, or `None` for an unknown future value.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Applied),
            1 => Some(Self::RejectedStale),
            2 => Some(Self::RejectedInvalid),
            3 => Some(Self::UnknownOp),
            4 => Some(Self::RejectedNotFound),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Which kind of device is on the far end.
///
/// A LABEL, not a credential: it is checked nowhere and grants nothing. The host branches on it for
/// the size fold — an iPhone is size-passive — and the roster shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WorkspaceClientKind {
    /// A Mac.
    MacOs = 0,
    /// An iPhone or iPad.
    Ios = 1,
}

impl WorkspaceClientKind {
    /// Every kind this build knows, in wire order.
    pub const ALL: [Self; 2] = [Self::MacOs, Self::Ios];

    /// The kind for `byte`, or `None` for an unknown future device class.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::MacOs),
            1 => Some(Self::Ios),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

// ---------------------------------------------------------------------------------------------- //
// Shared helpers
// ---------------------------------------------------------------------------------------------- //

/// Reads the 16 raw bytes of a UUID.
///
/// # Errors
/// [`WireError::Truncated`] when fewer than 16 bytes remain.
fn read_uuid(reader: &mut ByteReader<'_>) -> Result<RawUuid> {
    let bytes = reader.read_bytes(SESSION_ID_BYTE_COUNT)?;
    RawUuid::try_from(bytes).map_err(|_| WireError::Truncated)
}

/// Reads a `u16`-length-prefixed strict-UTF-8 string whose declared length is first checked against
/// `max_bytes`.
///
/// # Errors
/// [`WireError::MalformedBody`] when the declared length exceeds the cap or the bytes are not valid
/// UTF-8, [`WireError::Truncated`] when they are not there.
fn read_capped_label(reader: &mut ByteReader<'_>, max_bytes: usize, context: &str) -> Result<String> {
    let declared = usize::from(reader.read_u16()?);
    if declared > max_bytes {
        return Err(WireError::malformed(format!(
            "{context}: label {declared} > {max_bytes}"
        )));
    }
    let bytes = reader.read_bytes(declared)?;
    core::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| WireError::malformed(format!("{context}: label is not valid UTF-8")))
}

/// Writes a `u16`-length-prefixed label, clamped to `max_bytes` at a `char` boundary.
fn put_capped_label(out: &mut ByteWriter<'_>, label: &str, max_bytes: usize) {
    let bytes = clamp_utf8(label, max_bytes).as_bytes();
    out.put_u16(u16::try_from(bytes.len()).unwrap_or(u16::MAX));
    out.put_bytes(bytes);
}

// ---------------------------------------------------------------------------------------------- //
// subscribe — verb 0
// ---------------------------------------------------------------------------------------------- //

/// `[16B clientInstanceID][u8 clientKind][16B knownEpoch][i64 BE knownStateNum][u8 flags][u16 BE
/// labelLen][label]`
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceSubscribe {
    /// Minted per CONNECTION, not per install — two windows of one app are two identities.
    pub client_instance_id: RawUuid,
    /// The far end's device class as a raw byte. See [`WorkspaceClientKind`].
    pub client_kind: u8,
    /// All-zero, together with a zero [`known_state_num`](Self::known_state_num), means "I know
    /// nothing" and a snapshot follows.
    pub known_epoch: RawUuid,
    /// The state number this client believes it holds.
    pub known_state_num: i64,
    /// See [`FLAG_CONTRIBUTES_SIZE`](Self::FLAG_CONTRIBUTES_SIZE) and
    /// [`FLAG_FOLLOWS_FOCUS`](Self::FLAG_FOLLOWS_FOCUS).
    pub flags: u8,
    /// A human device name, bounded by [`MAX_LABEL_BYTES`](Self::MAX_LABEL_BYTES).
    pub label: String,
}

impl WorkspaceSubscribe {
    /// b0 — this client's viewport participates in the PTY size fold.
    pub const FLAG_CONTRIBUTES_SIZE: u8 = 1 << 0;
    /// b1 — this client follows host focus rather than steering its own view.
    pub const FLAG_FOLLOWS_FOCUS: u8 = 1 << 1;
    /// The label cap, so a hostile peer cannot make the host retain an arbitrarily long string per
    /// connection.
    pub const MAX_LABEL_BYTES: usize = 64;

    /// Whether [`FLAG_CONTRIBUTES_SIZE`](Self::FLAG_CONTRIBUTES_SIZE) is set.
    #[must_use]
    pub const fn contributes_size(&self) -> bool {
        self.flags & Self::FLAG_CONTRIBUTES_SIZE != 0
    }

    /// Whether [`FLAG_FOLLOWS_FOCUS`](Self::FLAG_FOLLOWS_FOCUS) is set.
    #[must_use]
    pub const fn follows_focus(&self) -> bool {
        self.flags & Self::FLAG_FOLLOWS_FOCUS != 0
    }

    /// Encodes the payload.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(16 + 1 + 16 + 8 + 1 + 2 + self.label.len());
        self.encode_into(&mut out);
        out.into_vec()
    }

    /// Writes the payload into a writer the caller owns, which may be a LENT buffer.
    ///
    /// This is the form the FFI door calls twice — once to be told the size, once to fill it — so
    /// the sizing pass costs no allocation and no copy.
    pub fn encode_into(&self, out: &mut ByteWriter<'_>) {
        out.put_bytes(&self.client_instance_id);
        out.put_u8(self.client_kind);
        out.put_bytes(&self.known_epoch);
        out.put_i64(self.known_state_num);
        out.put_u8(self.flags);
        put_capped_label(out, &self.label, Self::MAX_LABEL_BYTES);
    }

    /// Decodes the payload.
    ///
    /// # Errors
    /// [`WireError::Truncated`] on a short body, [`WireError::MalformedBody`] on an over-cap or
    /// non-UTF-8 label.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(payload);
        let client_instance_id = read_uuid(&mut reader)?;
        let client_kind = reader.read_u8()?;
        let known_epoch = read_uuid(&mut reader)?;
        let known_state_num = reader.read_i64()?;
        let flags = reader.read_u8()?;
        let label = read_capped_label(&mut reader, Self::MAX_LABEL_BYTES, "workspace subscribe")?;
        Ok(Self {
            client_instance_id,
            client_kind,
            known_epoch,
            known_state_num,
            flags,
            label,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// presence — verb 2
// ---------------------------------------------------------------------------------------------- //

/// `[i64 BE presenceClock][16B viewingTabID][16B viewingPaneID][u16 cols][u16 rows][u8 flags]`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WorkspacePresenceUpdate {
    /// Per-client monotone. NEWEST WINS, with no merge — an older clock from a reconnecting client
    /// must never resurrect a view it has since left.
    pub presence_clock: i64,
    /// The tab this client is looking at.
    pub viewing_tab_id: RawUuid,
    /// The pane this client is looking at.
    pub viewing_pane_id: RawUuid,
    /// The client's viewport width in cells.
    pub cols: u16,
    /// The client's viewport height in cells.
    pub rows: u16,
    /// The same bits [`WorkspaceSubscribe::flags`] carries.
    pub flags: u8,
}

/// The fixed size of a presence update on the wire.
const PRESENCE_UPDATE_BYTES: usize = 8 + 16 + 16 + 2 + 2 + 1;

impl WorkspacePresenceUpdate {
    /// Whether this client's viewport participates in the PTY size fold.
    #[must_use]
    pub const fn contributes_size(&self) -> bool {
        self.flags & WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE != 0
    }

    /// Encodes the payload.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(PRESENCE_UPDATE_BYTES);
        self.encode_into(&mut out);
        out.into_vec()
    }

    /// Writes the payload into a writer the caller owns, which may be a LENT buffer.
    pub fn encode_into(&self, out: &mut ByteWriter<'_>) {
        out.put_i64(self.presence_clock);
        out.put_bytes(&self.viewing_tab_id);
        out.put_bytes(&self.viewing_pane_id);
        out.put_u16(self.cols);
        out.put_u16(self.rows);
        out.put_u8(self.flags);
    }

    /// Decodes the payload.
    ///
    /// # Errors
    /// [`WireError::Truncated`] on a short body.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(payload);
        Ok(Self {
            presence_clock: reader.read_i64()?,
            viewing_tab_id: read_uuid(&mut reader)?,
            viewing_pane_id: read_uuid(&mut reader)?,
            cols: reader.read_u16()?,
            rows: reader.read_u16()?,
            flags: reader.read_u8()?,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// intent — verb 3
// ---------------------------------------------------------------------------------------------- //

/// `[16B intentID][u8 op][u32 BE argLen][args…]`
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceIntent {
    /// Client-minted, so the host's result can be matched to the optimistic local patch standing in
    /// for it.
    pub intent_id: RawUuid,
    /// Which mutation. Carried RAW — an op this host does not know is answered
    /// [`WorkspaceIntentStatus::UnknownOp`], never guessed at.
    pub op: u8,
    /// The op's arguments, opaque here.
    pub args: Vec<u8>,
}

/// The most bytes a `u32` length field can describe. Spelled as a literal rather than cast from
/// `u32::MAX`, so the constant carries no target-width cast for a lint to argue with.
const MAX_U32_LENGTH: usize = 4_294_967_295;

/// The declared-argument cap, which the Swift decoder states as `UInt32(Int32.max)`.
const MAX_INTENT_ARG_BYTES: usize = 2_147_483_647;

impl WorkspaceIntent {
    /// Encodes the payload.
    ///
    /// The argument length is clamped to what its `u32` field can hold, on the same reasoning as
    /// every other length on this wire: writing a WRAPPED length while still appending every byte
    /// would make the decoder mis-split the body. Unreachable in practice — the frame cap is 16
    /// MiB.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let count = self.args.len().min(MAX_U32_LENGTH);
        let mut out = ByteWriter::with_capacity(16 + 1 + 4 + count);
        Self::encode_parts_into(&mut out, &self.intent_id, self.op, &self.args);
        out.into_vec()
    }

    /// Writes the payload into a writer the caller owns, which may be a LENT buffer.
    pub fn encode_into(&self, out: &mut ByteWriter<'_>) {
        Self::encode_parts_into(out, &self.intent_id, self.op, &self.args);
    }

    /// Writes an intent whose arguments the caller only BORROWS.
    ///
    /// The FFI door has a `(ptr, len)` for the args and no reason to own them; asking it to build a
    /// [`WorkspaceIntent`] first would copy a body that is opaque here on its way to being copied
    /// again into the answer.
    pub fn encode_parts_into(out: &mut ByteWriter<'_>, intent_id: &RawUuid, op: u8, args: &[u8]) {
        let count = args.len().min(MAX_U32_LENGTH);
        out.put_bytes(intent_id);
        out.put_u8(op);
        out.put_u32(u32::try_from(count).unwrap_or(u32::MAX));
        out.put_bytes(args.get(..count).unwrap_or(args));
    }

    /// Decodes the payload.
    ///
    /// # Errors
    /// [`WireError::Truncated`] on a short body, or on a declared argument length the body cannot
    /// hold — a hostile `0xFFFFFFFF` is checked against the bytes ACTUALLY left, so it costs
    /// nothing.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let (intent_id, op, args) = Self::decode_leaving_args(payload)?;
        let args = payload.get(args).unwrap_or_default().to_vec();
        Ok(Self { intent_id, op, args })
    }

    /// Decodes everything but the arguments, answering WHERE they sit in `payload`.
    ///
    /// An intent's args are opaque here and can run to the frame cap, so the door that hands them
    /// to Swift has no reason to copy them into a buffer Swift will copy out of. The range is in
    /// `payload`'s own address space.
    ///
    /// # Errors
    /// The same as [`decode`](Self::decode).
    pub fn decode_leaving_args(payload: &[u8]) -> Result<(RawUuid, u8, Range<usize>)> {
        let mut reader = ByteReader::new(payload);
        let intent_id = read_uuid(&mut reader)?;
        let op = reader.read_u8()?;
        let arg_len = reader.read_u32()?;
        let arg_len = usize::try_from(arg_len).map_err(|_| WireError::Truncated)?;
        if arg_len > MAX_INTENT_ARG_BYTES || arg_len > reader.bytes_remaining() {
            return Err(WireError::Truncated);
        }
        let start = reader.position();
        reader.read_bytes(arg_len)?;
        Ok((intent_id, op, start..start + arg_len))
    }
}

// ---------------------------------------------------------------------------------------------- //
// intentResult — kind 3
// ---------------------------------------------------------------------------------------------- //

/// `[16B intentID][u8 status]`
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WorkspaceIntentResult {
    /// The intent this answers.
    pub intent_id: RawUuid,
    /// The outcome as a raw byte. See [`WorkspaceIntentStatus`].
    pub status: u8,
}

impl WorkspaceIntentResult {
    /// Encodes the payload.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(17);
        self.encode_into(&mut out);
        out.into_vec()
    }

    /// Writes the payload into a writer the caller owns, which may be a LENT buffer.
    pub fn encode_into(&self, out: &mut ByteWriter<'_>) {
        out.put_bytes(&self.intent_id);
        out.put_u8(self.status);
    }

    /// Decodes the payload.
    ///
    /// # Errors
    /// [`WireError::Truncated`] on a short body.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(payload);
        Ok(Self {
            intent_id: read_uuid(&mut reader)?,
            status: reader.read_u8()?,
        })
    }
}

// ---------------------------------------------------------------------------------------------- //
// presence roster — kind 2
// ---------------------------------------------------------------------------------------------- //

/// One client currently on this host, as the host describes it to everyone else.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceRosterClient {
    /// The client's per-connection identity.
    pub client_instance_id: RawUuid,
    /// The far end's device class as a raw byte.
    pub client_kind: u8,
    /// The same bits [`WorkspaceSubscribe::flags`] carries.
    pub flags: u8,
    /// The tab this client is looking at.
    pub viewing_tab_id: RawUuid,
    /// The pane this client is looking at.
    pub viewing_pane_id: RawUuid,
    /// The client's viewport width in cells.
    pub cols: u16,
    /// The client's viewport height in cells.
    pub rows: u16,
    /// The client's human device name.
    pub label: String,
}

/// One client attached to a pane, and the grid it asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WorkspaceRosterAttachment {
    /// Which client.
    pub client_instance_id: RawUuid,
    /// Whether this attachment participates in the size fold (read as `byte != 0`).
    pub contributes: bool,
    /// The attachment's width in cells.
    pub cols: u16,
    /// The attachment's height in cells.
    pub rows: u16,
}

/// Who is attached to one pane, and the grid the size fold resolved for it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspaceRosterPane {
    /// The pane.
    pub pane_id: RawUuid,
    /// The width the fold resolved.
    pub resolved_cols: u16,
    /// The height the fold resolved.
    pub resolved_rows: u16,
    /// The clients attached to it.
    pub attachments: Vec<WorkspaceRosterAttachment>,
}

/// `[u16 clientCount][clientRecord…][u16 paneCount][paneAttachRecord…]`
///
/// Presence is DERIVED, TTL-expired and never persisted, so it is broadcast whole every time rather
/// than diffed. Keeping it in the versioned document would persist dead connection ids across a
/// restart and churn the state number on every `WireGuard` flap.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkspacePresenceRoster {
    /// Everyone connected.
    pub clients: Vec<WorkspaceRosterClient>,
    /// Every pane with an attachment.
    pub panes: Vec<WorkspaceRosterPane>,
}

/// The bytes a client record cannot be smaller than, as the Swift encoder's decoder states it.
///
/// A deliberately CONSERVATIVE floor — the true minimum is 56 (three ids, kind, flags, cols, rows
/// and a zero label length). Both numbers reject the same hostile counts in the end, because the
/// per-record reads catch whatever this admits; the smaller one just catches it one step later. It
/// is carried across verbatim rather than corrected, because changing it changes nothing a peer can
/// observe and the two implementations must not drift on a number either could have picked.
pub const ROSTER_CLIENT_MIN_BYTES: usize = 42;

/// The bytes a pane record cannot be smaller than: the pane id, the resolved grid, a zero
/// attachment count.
pub const ROSTER_PANE_MIN_BYTES: usize = 16 + 2 + 2 + 2;

/// The exact size of an attachment record.
pub const ROSTER_ATTACHMENT_BYTES: usize = 16 + 1 + 2 + 2;

impl WorkspacePresenceRoster {
    /// The upper bound on each list. Real rosters are single digits; this exists only so a hostile
    /// count is rejected by arithmetic before it can drive an allocation.
    pub const MAX_RECORDS: usize = 4096;

    /// Encodes the payload.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let client_count = self.clients.len().min(Self::MAX_RECORDS);
        let pane_count = self.panes.len().min(Self::MAX_RECORDS);
        let mut out = ByteWriter::with_capacity(
            2 + client_count * ROSTER_CLIENT_MIN_BYTES + 2 + pane_count * ROSTER_PANE_MIN_BYTES,
        );
        self.encode_into(&mut out);
        out.into_vec()
    }

    /// Writes the payload into a writer the caller owns, which may be a LENT buffer.
    pub fn encode_into(&self, out: &mut ByteWriter<'_>) {
        let client_count = self.clients.len().min(Self::MAX_RECORDS);
        let pane_count = self.panes.len().min(Self::MAX_RECORDS);
        out.put_u16(u16::try_from(client_count).unwrap_or(u16::MAX));
        for client in self.clients.iter().take(client_count) {
            out.put_bytes(&client.client_instance_id);
            out.put_u8(client.client_kind);
            out.put_u8(client.flags);
            out.put_bytes(&client.viewing_tab_id);
            out.put_bytes(&client.viewing_pane_id);
            out.put_u16(client.cols);
            out.put_u16(client.rows);
            put_capped_label(out, &client.label, WorkspaceSubscribe::MAX_LABEL_BYTES);
        }
        out.put_u16(u16::try_from(pane_count).unwrap_or(u16::MAX));
        for pane in self.panes.iter().take(pane_count) {
            let attachment_count = pane.attachments.len().min(Self::MAX_RECORDS);
            out.put_bytes(&pane.pane_id);
            out.put_u16(pane.resolved_cols);
            out.put_u16(pane.resolved_rows);
            out.put_u16(u16::try_from(attachment_count).unwrap_or(u16::MAX));
            for attachment in pane.attachments.iter().take(attachment_count) {
                out.put_bytes(&attachment.client_instance_id);
                out.put_bool(attachment.contributes);
                out.put_u16(attachment.cols);
                out.put_u16(attachment.rows);
            }
        }
    }

    /// Decodes the payload.
    ///
    /// # Errors
    /// [`WireError::Truncated`] on a short body or an over-declared count,
    /// [`WireError::MalformedBody`] on an over-cap or non-UTF-8 label.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = ByteReader::new(payload);
        let client_count = usize::from(reader.read_u16()?);
        if client_count * ROSTER_CLIENT_MIN_BYTES > reader.bytes_remaining() {
            return Err(WireError::Truncated);
        }
        let mut clients = Vec::with_capacity(client_count);
        for _ in 0..client_count {
            let client_instance_id = read_uuid(&mut reader)?;
            let client_kind = reader.read_u8()?;
            let flags = reader.read_u8()?;
            let viewing_tab_id = read_uuid(&mut reader)?;
            let viewing_pane_id = read_uuid(&mut reader)?;
            let cols = reader.read_u16()?;
            let rows = reader.read_u16()?;
            let label = read_capped_label(
                &mut reader,
                WorkspaceSubscribe::MAX_LABEL_BYTES,
                "workspace roster",
            )?;
            clients.push(WorkspaceRosterClient {
                client_instance_id,
                client_kind,
                flags,
                viewing_tab_id,
                viewing_pane_id,
                cols,
                rows,
                label,
            });
        }
        let pane_count = usize::from(reader.read_u16()?);
        if pane_count * ROSTER_PANE_MIN_BYTES > reader.bytes_remaining() {
            return Err(WireError::Truncated);
        }
        let mut panes = Vec::with_capacity(pane_count);
        for _ in 0..pane_count {
            let pane_id = read_uuid(&mut reader)?;
            let resolved_cols = reader.read_u16()?;
            let resolved_rows = reader.read_u16()?;
            let attachment_count = usize::from(reader.read_u16()?);
            if attachment_count * ROSTER_ATTACHMENT_BYTES > reader.bytes_remaining() {
                return Err(WireError::Truncated);
            }
            let mut attachments = Vec::with_capacity(attachment_count);
            for _ in 0..attachment_count {
                attachments.push(WorkspaceRosterAttachment {
                    client_instance_id: read_uuid(&mut reader)?,
                    // C-style bool: any non-zero is true.
                    contributes: reader.read_bool()?,
                    cols: reader.read_u16()?,
                    rows: reader.read_u16()?,
                });
            }
            panes.push(WorkspaceRosterPane {
                pane_id,
                resolved_cols,
                resolved_rows,
                attachments,
            });
        }
        Ok(Self { clients, panes })
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        WireError, WorkspaceClientKind, WorkspaceEventKind, WorkspaceIntent, WorkspaceIntentResult,
        WorkspaceIntentStatus, WorkspacePresenceRoster, WorkspacePresenceUpdate, WorkspaceRequestVerb,
        WorkspaceRosterAttachment, WorkspaceRosterClient, WorkspaceRosterPane, WorkspaceSubscribe,
        clamp_utf8,
    };

    const ID_A: [u8; 16] = [0xA1; 16];
    const ID_B: [u8; 16] = [0xB2; 16];
    const ID_C: [u8; 16] = [0xC3; 16];

    #[test]
    fn every_vocabulary_byte_round_trips() {
        for verb in WorkspaceRequestVerb::ALL {
            assert_eq!(WorkspaceRequestVerb::from_byte(verb.as_byte()), Some(verb));
        }
        for kind in WorkspaceEventKind::ALL {
            assert_eq!(WorkspaceEventKind::from_byte(kind.as_byte()), Some(kind));
        }
        for status in WorkspaceIntentStatus::ALL {
            assert_eq!(WorkspaceIntentStatus::from_byte(status.as_byte()), Some(status));
        }
        for client in WorkspaceClientKind::ALL {
            assert_eq!(WorkspaceClientKind::from_byte(client.as_byte()), Some(client));
        }
        assert_eq!(WorkspaceRequestVerb::from_byte(4), None);
        assert_eq!(WorkspaceEventKind::from_byte(5), None);
        assert_eq!(WorkspaceIntentStatus::from_byte(5), None);
        assert_eq!(WorkspaceClientKind::from_byte(2), None);
    }

    #[test]
    fn a_subscribe_round_trips_and_pins_its_layout() {
        let subscribe = WorkspaceSubscribe {
            client_instance_id: ID_A,
            client_kind: WorkspaceClientKind::Ios.as_byte(),
            known_epoch: ID_B,
            known_state_num: 42,
            flags: WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE | WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS,
            label: "iPhone".to_owned(),
        };
        let encoded = subscribe.encode();
        assert_eq!(encoded.len(), 16 + 1 + 16 + 8 + 1 + 2 + 6);
        assert_eq!(&encoded[..16], &ID_A);
        assert_eq!(encoded[16], 1);
        assert_eq!(&encoded[17..33], &ID_B);
        assert_eq!(WorkspaceSubscribe::decode(&encoded).unwrap(), subscribe);
        assert!(subscribe.contributes_size());
        assert!(subscribe.follows_focus());
    }

    #[test]
    fn a_knows_nothing_subscribe_is_all_zero_and_state_zero() {
        let subscribe = WorkspaceSubscribe::default();
        assert_eq!(subscribe.known_epoch, [0; 16]);
        assert_eq!(subscribe.known_state_num, 0);
        assert!(!subscribe.contributes_size());
        assert_eq!(
            WorkspaceSubscribe::decode(&subscribe.encode()).unwrap(),
            subscribe
        );
    }

    #[test]
    fn an_over_declared_label_is_malformed_rather_than_quietly_trimmed() {
        let mut body = WorkspaceSubscribe::default().encode();
        // Overwrite the two label-length bytes with the cap plus one.
        let at = body.len() - 2;
        body[at] = 0;
        body[at + 1] = 65;
        assert!(matches!(
            WorkspaceSubscribe::decode(&body),
            Err(WireError::MalformedBody(_))
        ));
    }

    #[test]
    fn an_over_long_label_is_clamped_on_encode_at_a_scalar_boundary() {
        // 4-byte scalars against a 64-byte cap: 64 = 4 * 16 exactly, so a 17th would not fit.
        let subscribe = WorkspaceSubscribe {
            label: "😀".repeat(40),
            ..WorkspaceSubscribe::default()
        };
        let decoded = WorkspaceSubscribe::decode(&subscribe.encode()).unwrap();
        assert_eq!(decoded.label.len(), 64);
        assert!(decoded.label.chars().all(|c| c == '😀'));
        assert_eq!(clamp_utf8("hello", 64), "hello");
    }

    #[test]
    fn a_presence_update_round_trips_and_is_fixed_width() {
        let update = WorkspacePresenceUpdate {
            presence_clock: i64::MIN,
            viewing_tab_id: ID_A,
            viewing_pane_id: ID_B,
            cols: 120,
            rows: 40,
            flags: WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE,
        };
        let encoded = update.encode();
        assert_eq!(encoded.len(), 45);
        assert_eq!(WorkspacePresenceUpdate::decode(&encoded).unwrap(), update);
        assert!(update.contributes_size());
        assert_eq!(
            WorkspacePresenceUpdate::decode(&encoded[..44]),
            Err(WireError::Truncated)
        );
    }

    #[test]
    fn an_intent_round_trips_and_carries_an_unknown_op_rather_than_dropping_it() {
        let intent = WorkspaceIntent {
            intent_id: ID_C,
            op: 0xFE,
            args: vec![1, 2, 3],
        };
        let encoded = intent.encode();
        assert_eq!(encoded.len(), 16 + 1 + 4 + 3);
        assert_eq!(WorkspaceIntent::decode(&encoded).unwrap(), intent);
    }

    #[test]
    fn a_hostile_arg_length_costs_nothing() {
        let mut body = ID_C.to_vec();
        body.push(0);
        body.extend_from_slice(&u32::MAX.to_be_bytes());
        body.extend_from_slice(b"two");
        assert_eq!(WorkspaceIntent::decode(&body), Err(WireError::Truncated));
    }

    #[test]
    fn an_intent_result_round_trips() {
        let result = WorkspaceIntentResult {
            intent_id: ID_A,
            status: WorkspaceIntentStatus::RejectedStale.as_byte(),
        };
        let encoded = result.encode();
        assert_eq!(encoded.len(), 17);
        assert_eq!(WorkspaceIntentResult::decode(&encoded).unwrap(), result);
        assert_eq!(
            WorkspaceIntentResult::decode(&encoded[..16]),
            Err(WireError::Truncated)
        );
    }

    #[test]
    fn an_empty_roster_is_two_counts() {
        let roster = WorkspacePresenceRoster::default();
        assert_eq!(roster.encode(), vec![0, 0, 0, 0]);
        assert_eq!(WorkspacePresenceRoster::decode(&roster.encode()).unwrap(), roster);
    }

    #[test]
    fn a_roster_round_trips_clients_panes_and_attachments() {
        let roster = WorkspacePresenceRoster {
            clients: vec![
                WorkspaceRosterClient {
                    client_instance_id: ID_A,
                    client_kind: 0,
                    flags: WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS,
                    viewing_tab_id: ID_B,
                    viewing_pane_id: ID_C,
                    cols: 200,
                    rows: 60,
                    label: "mac-studio".to_owned(),
                },
                WorkspaceRosterClient {
                    client_instance_id: ID_B,
                    label: String::new(),
                    ..WorkspaceRosterClient::default()
                },
            ],
            panes: vec![WorkspaceRosterPane {
                pane_id: ID_C,
                resolved_cols: 100,
                resolved_rows: 30,
                attachments: vec![
                    WorkspaceRosterAttachment {
                        client_instance_id: ID_A,
                        contributes: true,
                        cols: 100,
                        rows: 30,
                    },
                    WorkspaceRosterAttachment {
                        client_instance_id: ID_B,
                        contributes: false,
                        cols: 0,
                        rows: 0,
                    },
                ],
            }],
        };
        assert_eq!(WorkspacePresenceRoster::decode(&roster.encode()).unwrap(), roster);
    }

    #[test]
    fn a_hostile_roster_count_is_refused_before_it_can_drive_an_allocation() {
        // 0xFFFF clients declared in front of nothing.
        assert_eq!(
            WorkspacePresenceRoster::decode(&[0xFF, 0xFF]),
            Err(WireError::Truncated)
        );
        // Zero clients, then 0xFFFF panes.
        assert_eq!(
            WorkspacePresenceRoster::decode(&[0, 0, 0xFF, 0xFF]),
            Err(WireError::Truncated)
        );
        // One real pane whose attachment count is a lie.
        let mut body = vec![0, 0, 0, 1];
        body.extend_from_slice(&ID_C);
        body.extend_from_slice(&[0, 0, 0, 0, 0xFF, 0xFF]);
        assert_eq!(WorkspacePresenceRoster::decode(&body), Err(WireError::Truncated));
    }

    #[test]
    fn an_attachment_contributes_flag_is_true_for_any_non_zero_byte() {
        let mut body = vec![0, 0, 0, 1];
        body.extend_from_slice(&ID_C);
        body.extend_from_slice(&[0, 0, 0, 0, 0, 1]);
        body.extend_from_slice(&ID_A);
        body.extend_from_slice(&[7, 0, 10, 0, 20]);
        let roster = WorkspacePresenceRoster::decode(&body).unwrap();
        assert!(roster.panes[0].attachments[0].contributes);
        assert_eq!(roster.panes[0].attachments[0].cols, 10);
    }
}
