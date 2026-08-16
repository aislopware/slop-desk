//! The per-op argument payloads of a workspace intent (docs/45 §5.4 — the verb-3 body).
//!
//! The tree ops these drive were exercised only from the client's main actor with trusted local
//! input. Running them inside a host actor exposes them to a network peer, so every payload here is
//! validate-then-drop: counts bounded before allocating, strings strict UTF-8 and capped, no field
//! unwrapped.
//!
//! ## Why the decoders are typed
//! Swift read these fields inline in its applier — `reader.uuid()`, `reader.axis()`,
//! `reader.name()` in a `guard` chain per op. Each decoder here returns the op's arguments as a
//! value instead, so the "did every field get read, and was the payload exhausted" check is made
//! once by the codec rather than re-typed at each of twenty-seven call sites. `isAtEnd` was a
//! separate clause in every one of those guards; here it is part of what decoding MEANS.

use super::codec::{SplitAxis, VideoEndpoint, WorkspaceLayoutNode, encode_layout, encode_string};
use crate::bytes::{ByteReader, ByteWriter, truncating_u16};
use crate::error::{Result, WireError};
use crate::message::{RawUuid, SESSION_ID_BYTE_COUNT};

/// The topology changes a client may ASK for.
///
/// The discriminant is the `op` byte inside a type-17 `intent` request, so these numbers are frozen
/// — a golden vector carries every one. A renumbering would decode cleanly into the WRONG meaning,
/// because every argument payload is length-prefixed rather than self-describing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum WorkspaceIntentOp {
    /// The legacy one-shot: a client uploads its own tree to a host whose document is untouched.
    AdoptWorkspace = 0,
    /// Set a pane's title.
    RenamePane = 1,
    /// Set a tab's title.
    RenameTab = 2,
    /// Set a session's name.
    RenameSession = 3,
    /// Close one pane.
    ClosePane = 4,
    /// Close one tab.
    CloseTab = 5,
    /// Split a pane, inserting a new one beside it.
    SplitPane = 6,
    /// Move a pane beside another.
    MovePane = 7,
    /// Reorder a session's tabs.
    ReorderTabs = 8,
    /// Focus a tab.
    FocusTab = 9,
    /// Focus a pane.
    FocusPane = 10,
    /// Arm or disarm synchronised input on a pane.
    SetSyncInput = 11,
    /// Spawn a pane beside another — the split's sibling verb.
    SpawnPane = 12,
    /// Spawn a tab in a session.
    SpawnTab = 13,
    /// Zoom a pane, or release the zoom.
    SetZoom = 14,
    /// Detach a pane from its tab.
    DetachPane = 15,
    /// Reattach a detached pane.
    ReattachPane = 16,
    /// The ONLY writer of `splitNode/weight`.
    SetDividerWeight = 17,
    /// Mint a new session.
    NewSession = 18,
    /// Close a session.
    CloseSession = 19,
    /// Reopen a tab from the closed-tab ring.
    ReopenClosedTab = 20,
    /// ⌃⌘T — eject a pane into a new tab of its session.
    BreakPaneToTab = 21,
    /// Exchange two leaves in place.
    ///
    /// Backs both the drag-onto-pane swap and the directional move: the client resolves the
    /// geometric neighbour against the layout IT is looking at and sends the resolved pair, so the
    /// host never needs a viewport to answer "which pane is to the left".
    SwapPanes = 22,
    /// Dock a pane at an OUTER edge of a tab, wrapping the whole tab root.
    ///
    /// No `(source, target, axis, before)` triple can express it — there is no target leaf, the
    /// target is the container.
    DockPaneAtTabEdge = 23,
    /// Re-shape a tab from a whole `layoutStructure`.
    ///
    /// One op for every re-tile: apply a preset, cycle to the next one, and balance the splits are
    /// all "this tab now has this shape".
    SetTabLayout = 24,
    /// Mint a pane straight into a session's DETACHED set — how a desktop pane is born, and the
    /// only intent that can write `pane/kind`.
    SpawnDetachedPane = 25,
    /// Re-point an EXISTING pane's video binding.
    ///
    /// The display switcher and the window re-pick both move a stream that is already running, so
    /// the mint's target cannot be the last word: without this the document keeps naming the
    /// display the pane opened on, and a relaunch re-streams it.
    SetPaneVideoTarget = 26,
}

impl WorkspaceIntentOp {
    /// Every op this build routes, in wire order.
    pub const ALL: [Self; 27] = [
        Self::AdoptWorkspace,
        Self::RenamePane,
        Self::RenameTab,
        Self::RenameSession,
        Self::ClosePane,
        Self::CloseTab,
        Self::SplitPane,
        Self::MovePane,
        Self::ReorderTabs,
        Self::FocusTab,
        Self::FocusPane,
        Self::SetSyncInput,
        Self::SpawnPane,
        Self::SpawnTab,
        Self::SetZoom,
        Self::DetachPane,
        Self::ReattachPane,
        Self::SetDividerWeight,
        Self::NewSession,
        Self::CloseSession,
        Self::ReopenClosedTab,
        Self::BreakPaneToTab,
        Self::SwapPanes,
        Self::DockPaneAtTabEdge,
        Self::SetTabLayout,
        Self::SpawnDetachedPane,
        Self::SetPaneVideoTarget,
    ];

    /// The op for `byte`, or `None` when this build serves nothing under it.
    ///
    /// `None` is answered `unknownOp` and the intent is over. Guessing would apply one topology
    /// change for a request that asked for another.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        if byte > 26 {
            return None;
        }
        // The discriminants are 0..=26 with no gaps, so the index IS the byte. Written as a table
        // rather than a `transmute` because this crate forbids `unsafe`.
        match byte {
            0 => Some(Self::AdoptWorkspace),
            1 => Some(Self::RenamePane),
            2 => Some(Self::RenameTab),
            3 => Some(Self::RenameSession),
            4 => Some(Self::ClosePane),
            5 => Some(Self::CloseTab),
            6 => Some(Self::SplitPane),
            7 => Some(Self::MovePane),
            8 => Some(Self::ReorderTabs),
            9 => Some(Self::FocusTab),
            10 => Some(Self::FocusPane),
            11 => Some(Self::SetSyncInput),
            12 => Some(Self::SpawnPane),
            13 => Some(Self::SpawnTab),
            14 => Some(Self::SetZoom),
            15 => Some(Self::DetachPane),
            16 => Some(Self::ReattachPane),
            17 => Some(Self::SetDividerWeight),
            18 => Some(Self::NewSession),
            19 => Some(Self::CloseSession),
            20 => Some(Self::ReopenClosedTab),
            21 => Some(Self::BreakPaneToTab),
            22 => Some(Self::SwapPanes),
            23 => Some(Self::DockPaneAtTabEdge),
            24 => Some(Self::SetTabLayout),
            25 => Some(Self::SpawnDetachedPane),
            _ => Some(Self::SetPaneVideoTarget),
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

// Three DOMAIN enums, re-exported rather than redefined. Each already had to answer the same three
// questions the wire asks — where does a new tab land, which gutter was dropped into, what is this
// pane — and a second copy here would be a mapping with nothing standing between it and a silent
// divergence from the one the layout engine actually obeys.
pub use slopdesk_workspace::{NewTabPosition, PaneDropEdge, PaneKind};

/// Cap on a name a client may set.
///
/// Long enough for any real title, short enough that a peer cannot make the host retain megabytes
/// per rename.
pub const MAX_NAME_BYTES: usize = 512;

/// Cap on a `reorderTabs` list. Real sessions have single-digit tab counts.
pub const MAX_TAB_COUNT: usize = 4096;

/// Cap on the two blobs that carry a whole sub-payload — a `layoutStructure` and a `videoTarget`.
///
/// Both are bounded by their own grammars once decoded; this bounds them BEFORE anything is copied
/// out of the reader.
pub const MAX_BLOB_BYTES: usize = 16384;

// ---------------------------------------------------------------------------------------------- //
// Encode
// ---------------------------------------------------------------------------------------------- //

/// A bare identity payload — `closePane`, `focusTab`, `detachPane`, and every other op whose whole
/// argument is one id.
#[must_use]
pub fn encode_identity(id: &RawUuid) -> Vec<u8> {
    id.to_vec()
}

fn put_name(out: &mut ByteWriter<'_>, name: &str) {
    let bytes = encode_string(name, MAX_NAME_BYTES);
    out.put_u16(u16::try_from(bytes.len()).unwrap_or(u16::MAX));
    out.put_bytes(&bytes);
}

/// A rename: `[16B id][u16 len][name]`.
#[must_use]
pub fn encode_name(id: &RawUuid, name: &str) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(18 + name.len());
    out.put_bytes(id);
    put_name(&mut out, name);
    out.into_vec()
}

/// A flag toggle — `setSyncInput`, `setZoom`: `[16B id][u8 flag]`.
#[must_use]
pub fn encode_flag(id: &RawUuid, flag: bool) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(17);
    out.put_bytes(id);
    out.put_bool(flag);
    out.into_vec()
}

/// `splitPane` / `spawnPane`: `[16B target][u8 axis][u8 before][16B newPane][u16 len][spawnCwd]`.
///
/// The NEW pane's id is PROPOSED BY THE CLIENT, not minted by the host, and the reason is latency:
/// an optimistic overlay cannot insert a leaf it has no id for, so a host-minted id would make
/// every split wait a round trip before anything appeared. It also makes a retried intent
/// idempotent. The host still decides — a proposed id already in use is rejected.
#[must_use]
pub fn encode_split(
    target: &RawUuid,
    axis: SplitAxis,
    before: bool,
    new_pane: &RawUuid,
    spawn_cwd: &str,
) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(36 + spawn_cwd.len());
    out.put_bytes(target);
    out.put_u8(axis.as_byte());
    out.put_bool(before);
    out.put_bytes(new_pane);
    put_name(&mut out, spawn_cwd);
    out.into_vec()
}

/// `movePane`: `[16B source][16B target][u8 axis][u8 before]`.
#[must_use]
pub fn encode_move(source: &RawUuid, target: &RawUuid, axis: SplitAxis, before: bool) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(34);
    out.put_bytes(source);
    out.put_bytes(target);
    out.put_u8(axis.as_byte());
    out.put_bool(before);
    out.into_vec()
}

/// `reorderTabs`: `[16B session][u16 n][16B tab]*`.
#[must_use]
pub fn encode_reorder_tabs(session: &RawUuid, tab_order: &[RawUuid]) -> Vec<u8> {
    let count = tab_order.len().min(usize::from(u16::MAX));
    let mut out = ByteWriter::with_capacity(18 + count * 16);
    out.put_bytes(session);
    out.put_u16(u16::try_from(count).unwrap_or(u16::MAX));
    for tab in tab_order.iter().take(count) {
        out.put_bytes(tab);
    }
    out.into_vec()
}

/// `spawnTab`: `[16B session][16B newPane][u8 position][u16 len][spawnCwd]`.
#[must_use]
pub fn encode_spawn_tab(
    session: &RawUuid,
    new_pane: &RawUuid,
    position: NewTabPosition,
    spawn_cwd: &str,
) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(35 + spawn_cwd.len());
    out.put_bytes(session);
    out.put_bytes(new_pane);
    out.put_u8(position.as_byte());
    put_name(&mut out, spawn_cwd);
    out.into_vec()
}

/// `newSession`: `[16B session][16B newPane][u16 len][name][u16 len][spawnCwd]`.
///
/// The cwd rides alongside the name because a new window INHERITS one. Without it the pane's
/// starting directory is unrepresentable and every new session silently opens at the host default —
/// the same fact `splitPane` and `spawnTab` already carry.
#[must_use]
pub fn encode_new_session(new_session: &RawUuid, new_pane: &RawUuid, name: &str, spawn_cwd: &str) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(36 + name.len() + spawn_cwd.len());
    out.put_bytes(new_session);
    out.put_bytes(new_pane);
    put_name(&mut out, name);
    put_name(&mut out, spawn_cwd);
    out.into_vec()
}

/// `swapPanes`: `[16B a][16B b]`.
#[must_use]
pub fn encode_swap_panes(first: &RawUuid, second: &RawUuid) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(32);
    out.put_bytes(first);
    out.put_bytes(second);
    out.into_vec()
}

/// `dockPaneAtTabEdge`: `[16B source][16B tab][u8 edge]`.
///
/// The tab is named even though the source's own tab could be derived, because it is what makes the
/// intent SELF-VALIDATING: the client is asserting which container it saw the pane docked into, and
/// a host whose tree has since moved the pane elsewhere refuses instead of docking it somewhere the
/// user never pointed at.
#[must_use]
pub fn encode_dock_at_tab_edge(source: &RawUuid, tab: &RawUuid, edge: PaneDropEdge) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(33);
    out.put_bytes(source);
    out.put_bytes(tab);
    out.put_u8(edge.as_byte());
    out.into_vec()
}

/// `setTabLayout`: `[16B tab][layoutStructure bytes]`.
///
/// The SAME encoding `tab/layoutStructure` carries in the document — one shape grammar, so a client
/// can round-trip the layout it is looking at straight back as an intent. The blob is the last
/// field and needs no length prefix of its own: the codec underneath validates its framing to the
/// last byte.
#[must_use]
pub fn encode_set_tab_layout(tab: &RawUuid, layout: &WorkspaceLayoutNode) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(64);
    out.put_bytes(tab);
    out.put_bytes(&encode_layout(layout));
    out.into_vec()
}

/// Writes a `u16`-length-prefixed sub-payload, truncating the blob to the length actually written.
///
/// Swift wrote a WRAPPED `u16` here and appended every byte regardless, which for a blob past 64
/// KiB produces a frame that mis-splits at the decoder. Truncating to the declared length instead
/// keeps the frame self-consistent. Identical bytes for every input under 64 KiB — that is every
/// real payload and every pinned vector, since [`MAX_BLOB_BYTES`] refuses anything past 16 KiB on
/// the way back in.
fn put_blob(out: &mut ByteWriter<'_>, blob: &[u8]) {
    let length = u16::try_from(blob.len()).unwrap_or(u16::MAX);
    out.put_u16(length);
    out.put_bytes(blob.get(..usize::from(length)).unwrap_or(blob));
}

/// `spawnDetachedPane`: `[16B newPane][u8 kind][u16 len][videoTarget]`.
///
/// A zero length is "no target" — a detached terminal. The blob is the `pane/videoTarget` encoding,
/// so what the intent proposes and what the document publishes are the same bytes.
#[must_use]
pub fn encode_spawn_detached_pane(
    new_pane: &RawUuid,
    kind: PaneKind,
    video: Option<&VideoEndpoint>,
) -> Vec<u8> {
    let blob = video.map(super::codec::encode_video_target).unwrap_or_default();
    let mut out = ByteWriter::with_capacity(19 + blob.len());
    out.put_bytes(new_pane);
    out.put_u8(kind.as_byte());
    put_blob(&mut out, &blob);
    out.into_vec()
}

/// `setPaneVideoTarget`: `[16B pane][u16 len][videoTarget]`.
///
/// The same blob [`encode_spawn_detached_pane`] carries, so the mint and the re-point speak one
/// grammar. A zero length UNBINDS the pane — a picker cleared, a target that went away — which
/// stays distinct from "the bytes did not decode".
#[must_use]
pub fn encode_set_pane_video_target(pane: &RawUuid, video: Option<&VideoEndpoint>) -> Vec<u8> {
    let blob = video.map(super::codec::encode_video_target).unwrap_or_default();
    let mut out = ByteWriter::with_capacity(18 + blob.len());
    out.put_bytes(pane);
    put_blob(&mut out, &blob);
    out.into_vec()
}

/// `reopenClosedTab`: `[u16 lifoIndex][u8 position]`.
///
/// The index counts from the END of the ring — `0` is the most recently closed tab. Index-addressed
/// rather than implicit because Open-Quickly's Recent rows must reopen row N, and always popping
/// the newest is exactly the bug that produced.
#[must_use]
pub fn encode_reopen_closed_tab(lifo_index: usize, position: NewTabPosition) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(3);
    out.put_u16(truncating_u16(lifo_index));
    out.put_u8(position.as_byte());
    out.into_vec()
}

/// `setDividerWeight`: `[16B split][u16 leadingIndex][u64 BE f64 bit pattern]`.
///
/// The leading weight only — the op is sum-preserving, so naming the trailing one too would let a
/// hostile pair sum to something the solver has to repair anyway.
#[must_use]
pub fn encode_divider_weight(split: &RawUuid, leading_index: usize, leading_weight: f64) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(26);
    out.put_bytes(split);
    out.put_u16(truncating_u16(leading_index));
    out.put_u64(leading_weight.to_bits());
    out.into_vec()
}

// ---------------------------------------------------------------------------------------------- //
// Decode
// ---------------------------------------------------------------------------------------------- //

fn read_uuid(reader: &mut ByteReader<'_>) -> Result<RawUuid> {
    let bytes = reader.read_bytes(SESSION_ID_BYTE_COUNT)?;
    RawUuid::try_from(bytes).map_err(|_| WireError::Truncated)
}

/// A length-prefixed name. Over-long is MALFORMED, never clamped: silently truncating a field a
/// peer over-declared hides a framing bug behind a plausible value.
fn read_name(reader: &mut ByteReader<'_>, context: &str) -> Result<String> {
    let declared = usize::from(reader.read_u16()?);
    if declared > MAX_NAME_BYTES {
        return Err(WireError::malformed(format!(
            "{context}: name {declared} > {MAX_NAME_BYTES}"
        )));
    }
    let bytes = reader.read_bytes(declared)?;
    core::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| WireError::malformed(format!("{context}: name is not valid UTF-8")))
}

/// A length-prefixed sub-payload, bounded before anything is copied.
fn read_blob(reader: &mut ByteReader<'_>, context: &str) -> Result<Vec<u8>> {
    let declared = usize::from(reader.read_u16()?);
    if declared > MAX_BLOB_BYTES {
        return Err(WireError::malformed(format!(
            "{context}: blob {declared} > {MAX_BLOB_BYTES}"
        )));
    }
    Ok(reader.read_bytes(declared)?.to_vec())
}

fn expect_end(reader: &ByteReader<'_>, context: &str) -> Result<()> {
    if reader.bytes_remaining() == 0 {
        Ok(())
    } else {
        Err(WireError::malformed(format!("{context}: trailing bytes")))
    }
}

/// Reads a bare identity payload.
///
/// # Errors
/// [`WireError::Truncated`] when the 16 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_identity(data: &[u8]) -> Result<RawUuid> {
    let mut reader = ByteReader::new(data);
    let id = read_uuid(&mut reader)?;
    expect_end(&reader, "intent identity")?;
    Ok(id)
}

/// Reads a rename.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long or non-UTF-8 name or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_name(data: &[u8]) -> Result<(RawUuid, String)> {
    let mut reader = ByteReader::new(data);
    let id = read_uuid(&mut reader)?;
    let name = read_name(&mut reader, "intent rename")?;
    expect_end(&reader, "intent rename")?;
    Ok((id, name))
}

/// Reads a flag toggle.
///
/// # Errors
/// [`WireError::Truncated`] when the 17 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_flag(data: &[u8]) -> Result<(RawUuid, bool)> {
    let mut reader = ByteReader::new(data);
    let id = read_uuid(&mut reader)?;
    let flag = reader.read_bool()?;
    expect_end(&reader, "intent flag")?;
    Ok((id, flag))
}

/// The arguments of `splitPane` / `spawnPane`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitArgs {
    /// The pane being split.
    pub target: RawUuid,
    /// Which way the new split partitions its bound.
    pub axis: SplitAxis,
    /// Whether the new pane lands before the target along the axis.
    pub before: bool,
    /// The client-proposed id of the pane being minted.
    pub new_pane: RawUuid,
    /// The directory the new pane starts in; empty means the host default.
    pub spawn_cwd: String,
}

/// Reads a `splitPane` / `spawnPane` payload.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long or non-UTF-8 cwd or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_split(data: &[u8]) -> Result<SplitArgs> {
    let mut reader = ByteReader::new(data);
    let target = read_uuid(&mut reader)?;
    let axis = SplitAxis::from_byte(reader.read_u8()?);
    let before = reader.read_bool()?;
    let new_pane = read_uuid(&mut reader)?;
    let spawn_cwd = read_name(&mut reader, "intent split")?;
    expect_end(&reader, "intent split")?;
    Ok(SplitArgs {
        target,
        axis,
        before,
        new_pane,
        spawn_cwd,
    })
}

/// The arguments of `movePane`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MoveArgs {
    /// The pane being moved.
    pub source: RawUuid,
    /// The leaf it lands beside.
    pub target: RawUuid,
    /// Which way the resulting split partitions its bound.
    pub axis: SplitAxis,
    /// Whether the source lands before the target along the axis.
    pub before: bool,
}

/// Reads a `movePane` payload.
///
/// # Errors
/// [`WireError::Truncated`] when the 34 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_move(data: &[u8]) -> Result<MoveArgs> {
    let mut reader = ByteReader::new(data);
    let source = read_uuid(&mut reader)?;
    let target = read_uuid(&mut reader)?;
    let axis = SplitAxis::from_byte(reader.read_u8()?);
    let before = reader.read_bool()?;
    expect_end(&reader, "intent move")?;
    Ok(MoveArgs {
        source,
        target,
        axis,
        before,
    })
}

/// Reads a `reorderTabs` payload.
///
/// # Errors
/// [`WireError::MalformedBody`] on a count past [`MAX_TAB_COUNT`] or a trailing byte, and
/// [`WireError::Truncated`] when the declared tabs are not there.
pub fn decode_reorder_tabs(data: &[u8]) -> Result<(RawUuid, Vec<RawUuid>)> {
    let mut reader = ByteReader::new(data);
    let session = read_uuid(&mut reader)?;
    let count = usize::from(reader.read_u16()?);
    if count > MAX_TAB_COUNT {
        return Err(WireError::malformed(format!(
            "intent reorderTabs: count {count} > {MAX_TAB_COUNT}"
        )));
    }
    // Bound the declared count against the bytes ACTUALLY left before reserving.
    if reader.bytes_remaining() < count * SESSION_ID_BYTE_COUNT {
        return Err(WireError::malformed(format!(
            "intent reorderTabs: {count} tabs need {} bytes",
            count * SESSION_ID_BYTE_COUNT
        )));
    }
    let mut tabs = Vec::with_capacity(count);
    for _ in 0..count {
        tabs.push(read_uuid(&mut reader)?);
    }
    expect_end(&reader, "intent reorderTabs")?;
    Ok((session, tabs))
}

/// The arguments of `spawnTab`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnTabArgs {
    /// The session the tab is minted in.
    pub session: RawUuid,
    /// The client-proposed id of the tab's first pane.
    pub new_pane: RawUuid,
    /// Where the tab lands in the list.
    pub position: NewTabPosition,
    /// The directory the pane starts in; empty means the host default.
    pub spawn_cwd: String,
}

/// Reads a `spawnTab` payload.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long or non-UTF-8 cwd or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_spawn_tab(data: &[u8]) -> Result<SpawnTabArgs> {
    let mut reader = ByteReader::new(data);
    let session = read_uuid(&mut reader)?;
    let new_pane = read_uuid(&mut reader)?;
    let position = NewTabPosition::from_byte(reader.read_u8()?);
    let spawn_cwd = read_name(&mut reader, "intent spawnTab")?;
    expect_end(&reader, "intent spawnTab")?;
    Ok(SpawnTabArgs {
        session,
        new_pane,
        position,
        spawn_cwd,
    })
}

/// The arguments of `newSession`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewSessionArgs {
    /// The client-proposed id of the session being minted.
    pub session: RawUuid,
    /// The client-proposed id of its first pane.
    pub new_pane: RawUuid,
    /// The session's name.
    pub name: String,
    /// The directory the first pane inherits; empty means the host default.
    pub spawn_cwd: String,
}

/// Reads a `newSession` payload.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long or non-UTF-8 field or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_new_session(data: &[u8]) -> Result<NewSessionArgs> {
    let mut reader = ByteReader::new(data);
    let session = read_uuid(&mut reader)?;
    let new_pane = read_uuid(&mut reader)?;
    let name = read_name(&mut reader, "intent newSession")?;
    let spawn_cwd = read_name(&mut reader, "intent newSession")?;
    expect_end(&reader, "intent newSession")?;
    Ok(NewSessionArgs {
        session,
        new_pane,
        name,
        spawn_cwd,
    })
}

/// Reads a `swapPanes` payload.
///
/// # Errors
/// [`WireError::Truncated`] when the 32 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_swap_panes(data: &[u8]) -> Result<(RawUuid, RawUuid)> {
    let mut reader = ByteReader::new(data);
    let first = read_uuid(&mut reader)?;
    let second = read_uuid(&mut reader)?;
    expect_end(&reader, "intent swapPanes")?;
    Ok((first, second))
}

/// The arguments of `dockPaneAtTabEdge`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DockArgs {
    /// The pane being docked.
    pub source: RawUuid,
    /// The tab whose root it wraps.
    pub tab: RawUuid,
    /// Which outer gutter it docks into.
    pub edge: PaneDropEdge,
}

/// Reads a `dockPaneAtTabEdge` payload.
///
/// # Errors
/// [`WireError::Truncated`] when the 33 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_dock_at_tab_edge(data: &[u8]) -> Result<DockArgs> {
    let mut reader = ByteReader::new(data);
    let source = read_uuid(&mut reader)?;
    let tab = read_uuid(&mut reader)?;
    let edge = PaneDropEdge::from_byte(reader.read_u8()?);
    expect_end(&reader, "intent dockPaneAtTabEdge")?;
    Ok(DockArgs { source, tab, edge })
}

/// Reads a `setTabLayout` payload, answering the tab and the still-encoded layout blob.
///
/// The blob is handed back unparsed because its own decoder ([`super::codec::decode_layout`]) has
/// the depth cap and the exhaustion check, and running it here would fold two distinct rejections
/// — "this is not a layout" and "this tab is not in the document" — into one answer.
///
/// # Errors
/// [`WireError::MalformedBody`] when the trailing blob exceeds [`MAX_BLOB_BYTES`], and
/// [`WireError::Truncated`] when the tab id is not there.
pub fn decode_set_tab_layout(data: &[u8]) -> Result<(RawUuid, Vec<u8>)> {
    let mut reader = ByteReader::new(data);
    let tab = read_uuid(&mut reader)?;
    if reader.bytes_remaining() > MAX_BLOB_BYTES {
        return Err(WireError::malformed(format!(
            "intent setTabLayout: blob {} > {MAX_BLOB_BYTES}",
            reader.bytes_remaining()
        )));
    }
    Ok((tab, reader.remaining().to_vec()))
}

/// The arguments of `spawnDetachedPane`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnDetachedArgs {
    /// The client-proposed id of the pane being minted.
    pub new_pane: RawUuid,
    /// What the pane IS.
    pub kind: PaneKind,
    /// The still-encoded `videoTarget` blob; empty UNBINDS, which is distinct from "did not
    /// decode".
    pub video: Vec<u8>,
}

/// Reads a `spawnDetachedPane` payload.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long blob or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_spawn_detached_pane(data: &[u8]) -> Result<SpawnDetachedArgs> {
    let mut reader = ByteReader::new(data);
    let new_pane = read_uuid(&mut reader)?;
    let kind = PaneKind::from_byte(reader.read_u8()?);
    let video = read_blob(&mut reader, "intent spawnDetachedPane")?;
    expect_end(&reader, "intent spawnDetachedPane")?;
    Ok(SpawnDetachedArgs {
        new_pane,
        kind,
        video,
    })
}

/// Reads a `setPaneVideoTarget` payload, answering the pane and the still-encoded blob.
///
/// # Errors
/// [`WireError::MalformedBody`] on an over-long blob or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_set_pane_video_target(data: &[u8]) -> Result<(RawUuid, Vec<u8>)> {
    let mut reader = ByteReader::new(data);
    let pane = read_uuid(&mut reader)?;
    let video = read_blob(&mut reader, "intent setPaneVideoTarget")?;
    expect_end(&reader, "intent setPaneVideoTarget")?;
    Ok((pane, video))
}

/// Reads a `reopenClosedTab` payload.
///
/// # Errors
/// [`WireError::Truncated`] when the three bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_reopen_closed_tab(data: &[u8]) -> Result<(u16, NewTabPosition)> {
    let mut reader = ByteReader::new(data);
    let lifo_index = reader.read_u16()?;
    let position = NewTabPosition::from_byte(reader.read_u8()?);
    expect_end(&reader, "intent reopenClosedTab")?;
    Ok((lifo_index, position))
}

/// Reads a `setDividerWeight` payload. The weight comes back as its raw bit pattern's `f64`.
///
/// # Errors
/// [`WireError::Truncated`] when the 26 bytes are not there, [`WireError::MalformedBody`] on a
/// trailing byte.
pub fn decode_divider_weight(data: &[u8]) -> Result<(RawUuid, u16, f64)> {
    let mut reader = ByteReader::new(data);
    let split = read_uuid(&mut reader)?;
    let leading_index = reader.read_u16()?;
    let leading_weight = f64::from_bits(reader.read_u64()?);
    expect_end(&reader, "intent setDividerWeight")?;
    Ok((split, leading_index, leading_weight))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        MAX_BLOB_BYTES, MAX_NAME_BYTES, MAX_TAB_COUNT, NewTabPosition, PaneDropEdge, PaneKind, SplitAxis,
        VideoEndpoint, WorkspaceIntentOp, WorkspaceLayoutNode, decode_divider_weight,
        decode_dock_at_tab_edge, decode_flag, decode_identity, decode_move, decode_name, decode_new_session,
        decode_reopen_closed_tab, decode_reorder_tabs, decode_set_pane_video_target, decode_set_tab_layout,
        decode_spawn_detached_pane, decode_spawn_tab, decode_split, decode_swap_panes, encode_divider_weight,
        encode_dock_at_tab_edge, encode_flag, encode_identity, encode_move, encode_name, encode_new_session,
        encode_reopen_closed_tab, encode_reorder_tabs, encode_set_pane_video_target, encode_set_tab_layout,
        encode_spawn_detached_pane, encode_spawn_tab, encode_split, encode_swap_panes,
    };
    use crate::document::codec::{decode_layout, decode_video_target};

    fn uuid(byte: u8) -> [u8; 16] {
        [byte; 16]
    }

    #[test]
    fn every_op_round_trips_through_its_byte() {
        for (index, op) in WorkspaceIntentOp::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(op.as_byte()), index);
            assert_eq!(WorkspaceIntentOp::from_byte(op.as_byte()), Some(op));
        }
        for byte in [27_u8, 100, 0xFF] {
            assert_eq!(WorkspaceIntentOp::from_byte(byte), None);
        }
    }

    #[test]
    fn an_unknown_position_or_edge_byte_defaults_rather_than_dropping_the_gesture() {
        for (index, position) in NewTabPosition::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(position.as_byte()), index);
            assert_eq!(NewTabPosition::from_byte(position.as_byte()), position);
        }
        assert_eq!(NewTabPosition::from_byte(9), NewTabPosition::Auto);
        for (index, edge) in PaneDropEdge::ALL.into_iter().enumerate() {
            assert_eq!(usize::from(edge.as_byte()), index);
            assert_eq!(PaneDropEdge::from_byte(edge.as_byte()), edge);
        }
        assert_eq!(PaneDropEdge::from_byte(9), PaneDropEdge::Left);
    }

    #[test]
    fn a_drop_edge_maps_to_one_axis_and_one_insertion_side() {
        assert_eq!(PaneDropEdge::Left.axis(), SplitAxis::Horizontal);
        assert_eq!(PaneDropEdge::Right.axis(), SplitAxis::Horizontal);
        assert_eq!(PaneDropEdge::Top.axis(), SplitAxis::Vertical);
        assert_eq!(PaneDropEdge::Bottom.axis(), SplitAxis::Vertical);
        assert!(PaneDropEdge::Left.inserts_before());
        assert!(PaneDropEdge::Top.inserts_before());
        assert!(!PaneDropEdge::Right.inserts_before());
        assert!(!PaneDropEdge::Bottom.inserts_before());
    }

    #[test]
    fn a_pane_kind_byte_defaults_to_terminal_rather_than_a_dead_video_pane() {
        assert_eq!(PaneKind::from_byte(0), PaneKind::Terminal);
        assert_eq!(PaneKind::from_byte(1), PaneKind::Desktop);
        for byte in [2_u8, 0xFF] {
            assert_eq!(PaneKind::from_byte(byte), PaneKind::Terminal);
        }
    }

    #[test]
    fn an_identity_payload_is_exactly_one_id() {
        let bytes = encode_identity(&uuid(0xA1));
        assert_eq!(decode_identity(&bytes).unwrap(), uuid(0xA1));
        assert!(decode_identity(&bytes[..15]).is_err());
        assert!(decode_identity(&[bytes.as_slice(), &[0]].concat()).is_err());
    }

    #[test]
    fn a_rename_round_trips_including_the_empty_name() {
        for name in ["slopdesk", ""] {
            let bytes = encode_name(&uuid(0xB2), name);
            assert_eq!(decode_name(&bytes).unwrap(), (uuid(0xB2), name.to_owned()));
        }
    }

    #[test]
    fn a_name_past_the_cap_is_clamped_on_encode_and_refused_on_decode() {
        let long = "x".repeat(MAX_NAME_BYTES + 100);
        let bytes = encode_name(&uuid(0xB2), &long);
        let (_, decoded) = decode_name(&bytes).unwrap();
        assert_eq!(decoded.len(), MAX_NAME_BYTES);
        // A peer that DECLARES more than the cap is refused rather than trimmed.
        let mut hostile = encode_name(&uuid(0xB2), "");
        hostile[16] = 0xFF;
        hostile[17] = 0xFF;
        assert!(decode_name(&hostile).is_err());
    }

    #[test]
    fn a_name_that_is_not_valid_utf8_is_refused() {
        let mut bytes = encode_name(&uuid(0xB2), "ok");
        bytes[18] = 0xFF;
        assert!(decode_name(&bytes).is_err());
    }

    #[test]
    fn a_flag_reads_c_style() {
        assert_eq!(
            decode_flag(&encode_flag(&uuid(0xA1), true)).unwrap(),
            (uuid(0xA1), true)
        );
        assert_eq!(
            decode_flag(&encode_flag(&uuid(0xA1), false)).unwrap(),
            (uuid(0xA1), false)
        );
        let mut bytes = encode_flag(&uuid(0xA1), false);
        bytes[16] = 0xFF;
        assert_eq!(decode_flag(&bytes).unwrap(), (uuid(0xA1), true));
    }

    #[test]
    fn a_split_carries_the_client_proposed_pane_id() {
        let bytes = encode_split(
            &uuid(0xA1),
            SplitAxis::Vertical,
            true,
            &uuid(0xA3),
            "/Volumes/Lacie",
        );
        let args = decode_split(&bytes).unwrap();
        assert_eq!(args.target, uuid(0xA1));
        assert_eq!(args.axis, SplitAxis::Vertical);
        assert!(args.before);
        assert_eq!(args.new_pane, uuid(0xA3));
        assert_eq!(args.spawn_cwd, "/Volumes/Lacie");
    }

    #[test]
    fn a_move_names_the_source_first() {
        let bytes = encode_move(&uuid(0xA1), &uuid(0xA4), SplitAxis::Horizontal, false);
        let args = decode_move(&bytes).unwrap();
        assert_eq!(args.source, uuid(0xA1));
        assert_eq!(args.target, uuid(0xA4));
        assert_eq!(args.axis, SplitAxis::Horizontal);
        assert!(!args.before);
    }

    #[test]
    fn a_reorder_bounds_its_declared_count_before_reserving() {
        let tabs = vec![uuid(0xB2), uuid(0xB3)];
        let bytes = encode_reorder_tabs(&uuid(0xF1), &tabs);
        assert_eq!(decode_reorder_tabs(&bytes).unwrap(), (uuid(0xF1), tabs));
        // A count inside the cap that the bytes cannot back.
        let mut hostile = encode_reorder_tabs(&uuid(0xF1), &[]);
        hostile[16] = 0x00;
        hostile[17] = 0xFF;
        assert!(decode_reorder_tabs(&hostile).is_err());
        // And one past it.
        let mut past_cap = encode_reorder_tabs(&uuid(0xF1), &[]);
        past_cap[16] = 0xFF;
        past_cap[17] = 0xFF;
        assert!(decode_reorder_tabs(&past_cap).is_err());
        assert_eq!(MAX_TAB_COUNT, 4096);
    }

    #[test]
    fn a_spawn_tab_and_a_new_session_round_trip_their_positions_and_names() {
        let tab = decode_spawn_tab(&encode_spawn_tab(
            &uuid(0xF1),
            &uuid(0xA5),
            NewTabPosition::AfterCurrent,
            "",
        ))
        .unwrap();
        assert_eq!(tab.position, NewTabPosition::AfterCurrent);
        assert_eq!(tab.spawn_cwd, "");
        let session = decode_new_session(&encode_new_session(
            &uuid(0xF2),
            &uuid(0xA6),
            "notes",
            "/Volumes/Lacie",
        ))
        .unwrap();
        assert_eq!(session.name, "notes");
        assert_eq!(session.spawn_cwd, "/Volumes/Lacie");
    }

    #[test]
    fn a_swap_and_a_dock_round_trip() {
        assert_eq!(
            decode_swap_panes(&encode_swap_panes(&uuid(0xA1), &uuid(0xA4))).unwrap(),
            (uuid(0xA1), uuid(0xA4))
        );
        let dock = decode_dock_at_tab_edge(&encode_dock_at_tab_edge(
            &uuid(0xA1),
            &uuid(0xB2),
            PaneDropEdge::Bottom,
        ))
        .unwrap();
        assert_eq!(dock.edge, PaneDropEdge::Bottom);
        assert_eq!(dock.tab, uuid(0xB2));
    }

    #[test]
    fn a_tab_layout_intent_carries_the_document_s_own_shape_grammar() {
        let layout = WorkspaceLayoutNode::Split {
            id: uuid(0xC3),
            axis: SplitAxis::Horizontal,
            children: vec![
                WorkspaceLayoutNode::Leaf(uuid(0xA1)),
                WorkspaceLayoutNode::Leaf(uuid(0xA4)),
            ],
        };
        let (tab, blob) = decode_set_tab_layout(&encode_set_tab_layout(&uuid(0xB2), &layout)).unwrap();
        assert_eq!(tab, uuid(0xB2));
        assert_eq!(decode_layout(&blob).unwrap(), layout);
    }

    #[test]
    fn a_trailing_layout_blob_past_the_cap_is_refused() {
        let mut bytes = uuid(0xB2).to_vec();
        bytes.extend(std::iter::repeat_n(0_u8, MAX_BLOB_BYTES + 1));
        assert!(decode_set_tab_layout(&bytes).is_err());
    }

    #[test]
    fn a_video_binding_and_its_unbinding_stay_distinct() {
        let endpoint = VideoEndpoint {
            window_id: 0,
            title: "Desktop".to_owned(),
            app_name: String::new(),
            display_id: Some(0),
        };
        let minted = decode_spawn_detached_pane(&encode_spawn_detached_pane(
            &uuid(0xA7),
            PaneKind::Desktop,
            Some(&endpoint),
        ))
        .unwrap();
        assert_eq!(minted.kind, PaneKind::Desktop);
        assert_eq!(decode_video_target(&minted.video).as_ref(), Some(&endpoint));

        let bare =
            decode_spawn_detached_pane(&encode_spawn_detached_pane(&uuid(0xA7), PaneKind::Terminal, None))
                .unwrap();
        assert_eq!(bare.kind, PaneKind::Terminal);
        assert!(bare.video.is_empty());

        let (pane, blob) =
            decode_set_pane_video_target(&encode_set_pane_video_target(&uuid(0xA7), Some(&endpoint)))
                .unwrap();
        assert_eq!(pane, uuid(0xA7));
        assert_eq!(decode_video_target(&blob).as_ref(), Some(&endpoint));
        let (_, unbound) =
            decode_set_pane_video_target(&encode_set_pane_video_target(&uuid(0xA7), None)).unwrap();
        assert!(unbound.is_empty());
    }

    #[test]
    fn a_reopen_index_counts_from_the_newest_end() {
        let bytes = encode_reopen_closed_tab(1, NewTabPosition::AfterCurrent);
        assert_eq!(bytes, vec![0x00, 0x01, 0x02]);
        assert_eq!(
            decode_reopen_closed_tab(&bytes).unwrap(),
            (1, NewTabPosition::AfterCurrent)
        );
    }

    #[test]
    fn a_divider_weight_rides_as_a_raw_bit_pattern() {
        let bytes = encode_divider_weight(&uuid(0xC3), 1, 1.0 / 3.0);
        assert_eq!(bytes.len(), 26);
        let (split, index, weight) = decode_divider_weight(&bytes).unwrap();
        assert_eq!(split, uuid(0xC3));
        assert_eq!(index, 1);
        assert_eq!(weight.to_bits(), (1.0_f64 / 3.0).to_bits());
    }
}
