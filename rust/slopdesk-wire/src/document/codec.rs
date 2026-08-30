//! The hand-rolled big-endian codec for the workspace document (docs/45 §5.3).
//!
//! The wire ENVELOPE (types 17 / 37) lives in [`crate::message`] carrying an opaque payload, and
//! [`crate::workspace`] decodes the channel's own request/event bodies. This module is one layer
//! further in: what rides inside a snapshot, a diff, or a single field's value.
//!
//! Every decode is validate-then-drop: counts are checked against the bytes actually remaining
//! BEFORE anything is reserved, no field is unwrapped, and the recursion depth cap is checked
//! before descending rather than after.
//!
//! ## Two failure vocabularies, on purpose
//! The structural decoders ([`decode_snapshot`], [`decode_diff`], [`decode_layout`],
//! [`decode_weight`]) answer [`Result`], because a caller that is parsing a frame wants to know
//! WHY it was refused. The single-cell decoders answer [`Option`], because their caller is reading
//! one field of a document it otherwise holds fine, and the only useful reaction to a wrong-width
//! cell is to drop that cell and render the rest. Swift drew the same line; it is carried across
//! rather than smoothed over, because collapsing it either way would change what a caller does.

use super::state::{HostWorkspaceState, ROOT_OBJECT_ID, WorkspaceEntry, WorkspaceKey, WorkspaceStateDiff};
use crate::bytes::{ByteReader, ByteWriter, clamp_utf8};
use crate::error::{Result, WireError};
use crate::message::{RawUuid, SESSION_ID_BYTE_COUNT};

/// Upper bound on entries in one snapshot or diff.
///
/// Rejects an absurd count before it can drive an allocation; the real corpus is hundreds of
/// entries, not tens of thousands.
pub const MAX_ENTRY_COUNT: u32 = 65536;

/// The cheapest an entry can possibly be: a bare key plus a zero length prefix.
const ENTRY_FLOOR_BYTES: usize = WorkspaceKey::ENCODED_SIZE + 4;

/// The largest value length a single entry may declare.
///
/// `Int32.max` in Swift, spelled as a literal here so no cast lint has to be silenced to say it.
const MAX_ENTRY_VALUE_BYTES: usize = 2_147_483_647;

/// The deepest a `layoutStructure` may nest — `SplitNode.maxDepth`, mirrored.
///
/// This is the STACK-SAFETY mechanism, not a taste limit. A hand-rolled binary decoder over network
/// input has nothing underneath it the way a JSON decoder has its own nesting cap, so an unbounded
/// recursion here would be a remote stack overflow. Far above any real layout — a human nests a
/// handful.
pub const MAX_LAYOUT_DEPTH: usize = 12;

/// Default cap on a string field value, the width its `u16` length prefix can address.
pub const MAX_STRING_BYTES: usize = 65535;

// ---------------------------------------------------------------------------------------------- //
// Layout structure
// ---------------------------------------------------------------------------------------------- //

// The axis is the DOMAIN's, re-exported rather than redefined: the byte lives on
// `slopdesk_tree::SplitAxis` itself, so there is no second mapping to keep in agreement.
pub use slopdesk_tree::SplitAxis;

/// The tab's pane-tree SHAPE, weights deliberately excluded.
///
/// Weights ride as their own `splitNode/weight` entries so two clients dragging two DIFFERENT
/// dividers write two different keys and cannot clobber each other (docs/45 §5.3). Putting them in
/// this blob would make every divider drag rewrite the whole structure.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum WorkspaceLayoutNode {
    /// A single pane, named by its id.
    Leaf(RawUuid),
    /// A split partitioning its bound along `axis` among `children`.
    Split {
        /// The split's own identity — what a `splitNode/weight` entry is keyed by.
        id: RawUuid,
        /// Which way the bound is partitioned.
        axis: SplitAxis,
        /// The children, in layout order.
        children: Vec<Self>,
    },
}

// Both are the DOMAIN's values, for the same reason the axis is: a weight that the solver and the
// wire described separately is a weight that can drift, and the video endpoint's `display_id`-wins
// rule is a product decision, not a framing one.
pub use slopdesk_tree::{SplitWeight, VideoEndpoint};

// ---------------------------------------------------------------------------------------------- //
// Key and entry
// ---------------------------------------------------------------------------------------------- //

fn put_key(out: &mut ByteWriter<'_>, key: &WorkspaceKey) {
    out.put_u8(key.kind);
    out.put_bytes(&key.object_id);
    out.put_u8(key.field);
}

/// One key's fixed 18 bytes.
#[must_use]
pub fn encode_key(key: &WorkspaceKey) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(WorkspaceKey::ENCODED_SIZE);
    put_key(&mut out, key);
    out.into_vec()
}

fn read_uuid(reader: &mut ByteReader<'_>) -> Result<RawUuid> {
    let bytes = reader.read_bytes(SESSION_ID_BYTE_COUNT)?;
    RawUuid::try_from(bytes).map_err(|_| WireError::Truncated)
}

fn read_key(reader: &mut ByteReader<'_>) -> Result<WorkspaceKey> {
    let kind = reader.read_u8()?;
    let object_id = read_uuid(reader)?;
    let field = reader.read_u8()?;
    Ok(WorkspaceKey::new(kind, object_id, field))
}

fn put_entry(out: &mut ByteWriter<'_>, entry: &WorkspaceEntry) {
    put_key(out, &entry.key);
    out.put_u32(u32::try_from(entry.value.len()).unwrap_or(u32::MAX));
    out.put_bytes(&entry.value);
}

fn read_entry(reader: &mut ByteReader<'_>) -> Result<WorkspaceEntry> {
    let key = read_key(reader)?;
    let declared = usize::try_from(reader.read_u32()?).unwrap_or(usize::MAX);
    // Bound the length against the bytes ACTUALLY left before allocating — a hostile `u32::MAX`
    // must cost nothing.
    if declared > MAX_ENTRY_VALUE_BYTES || reader.bytes_remaining() < declared {
        return Err(WireError::malformed(format!(
            "workspace entry: value {declared} exceeds the {} bytes left",
            reader.bytes_remaining()
        )));
    }
    let value = reader.read_bytes(declared)?.to_vec();
    Ok(WorkspaceEntry::new(key, value))
}

/// Decodes `count` entries, having first proven the buffer could plausibly hold them.
///
/// An unknown `kindTag` or `field` is KEPT, not skipped. Length-prefixing makes forward tolerance
/// free either way, but keeping is strictly stronger than the skip docs/45 §5.3 proposed: a client
/// that retains bytes it cannot yet interpret still round-trips them, so its entries stay
/// byte-equal to the host's and its ack means what it says. Skipping would make an older client
/// silently ack a state it does not hold.
fn read_entries(reader: &mut ByteReader<'_>, count: u32) -> Result<Vec<WorkspaceEntry>> {
    if count > MAX_ENTRY_COUNT {
        return Err(WireError::malformed(format!(
            "workspace entries: count {count} > {MAX_ENTRY_COUNT}"
        )));
    }
    let count = usize::try_from(count).unwrap_or(usize::MAX);
    let floor = count.saturating_mul(ENTRY_FLOOR_BYTES);
    if reader.bytes_remaining() < floor {
        return Err(WireError::malformed(format!(
            "workspace entries: {count} entries need at least {floor} bytes"
        )));
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(read_entry(reader)?);
    }
    Ok(out)
}

// ---------------------------------------------------------------------------------------------- //
// Snapshot — `[u32 entryCount][entry…]`
// ---------------------------------------------------------------------------------------------- //

/// A whole document, in canonical key order.
#[must_use]
pub fn encode_snapshot(state: &HostWorkspaceState) -> Vec<u8> {
    let entries = state.sorted_entries();
    let mut out = ByteWriter::with_capacity(4 + entries.len() * ENTRY_FLOOR_BYTES);
    out.put_u32(u32::try_from(entries.len()).unwrap_or(u32::MAX));
    for entry in &entries {
        put_entry(&mut out, entry);
    }
    out.into_vec()
}

/// Reads a whole document.
///
/// # Errors
/// [`WireError::MalformedBody`] on a count the bytes cannot back or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_snapshot(data: &[u8]) -> Result<HostWorkspaceState> {
    let mut reader = ByteReader::new(data);
    let count = reader.read_u32()?;
    let entries = read_entries(&mut reader, count)?;
    if reader.bytes_remaining() != 0 {
        return Err(WireError::malformed("workspace snapshot: trailing bytes"));
    }
    Ok(HostWorkspaceState::from_entries(entries))
}

// ---------------------------------------------------------------------------------------------- //
// Diff — `[u32 setCount][entry…][u32 delCount][key…]`
// ---------------------------------------------------------------------------------------------- //

/// A diff: the sets first, then the deletes.
#[must_use]
pub fn encode_diff(diff: &WorkspaceStateDiff) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(
        8 + diff.sets.len() * ENTRY_FLOOR_BYTES + diff.deletes.len() * WorkspaceKey::ENCODED_SIZE,
    );
    out.put_u32(u32::try_from(diff.sets.len()).unwrap_or(u32::MAX));
    for entry in &diff.sets {
        put_entry(&mut out, entry);
    }
    out.put_u32(u32::try_from(diff.deletes.len()).unwrap_or(u32::MAX));
    for key in &diff.deletes {
        put_key(&mut out, key);
    }
    out.into_vec()
}

/// Reads a diff.
///
/// # Errors
/// [`WireError::MalformedBody`] on a count the bytes cannot back or a trailing byte, and
/// [`WireError::Truncated`] when a declared field runs off the end.
pub fn decode_diff(data: &[u8]) -> Result<WorkspaceStateDiff> {
    let mut reader = ByteReader::new(data);
    let set_count = reader.read_u32()?;
    let sets = read_entries(&mut reader, set_count)?;
    let delete_count = reader.read_u32()?;
    if delete_count > MAX_ENTRY_COUNT {
        return Err(WireError::malformed(format!(
            "workspace diff: delete count {delete_count} > {MAX_ENTRY_COUNT}"
        )));
    }
    let delete_count = usize::try_from(delete_count).unwrap_or(usize::MAX);
    let floor = delete_count.saturating_mul(WorkspaceKey::ENCODED_SIZE);
    if reader.bytes_remaining() < floor {
        return Err(WireError::malformed(format!(
            "workspace diff: {delete_count} deletes need {floor} bytes"
        )));
    }
    let mut deletes = Vec::with_capacity(delete_count);
    for _ in 0..delete_count {
        deletes.push(read_key(&mut reader)?);
    }
    if reader.bytes_remaining() != 0 {
        return Err(WireError::malformed("workspace diff: trailing bytes"));
    }
    Ok(WorkspaceStateDiff::new(sets, deletes))
}

// ---------------------------------------------------------------------------------------------- //
// layoutStructure — pre-order, self-describing, weights EXCLUDED
// ---------------------------------------------------------------------------------------------- //

/// A tab's tree shape, pre-order.
#[must_use]
pub fn encode_layout(node: &WorkspaceLayoutNode) -> Vec<u8> {
    let mut out = ByteWriter::new();
    put_layout(&mut out, node);
    out.into_vec()
}

fn put_layout(out: &mut ByteWriter<'_>, node: &WorkspaceLayoutNode) {
    match node {
        WorkspaceLayoutNode::Leaf(pane_id) => {
            out.put_u8(0);
            out.put_bytes(pane_id);
        },
        WorkspaceLayoutNode::Split { id, axis, children } => {
            out.put_u8(1);
            out.put_bytes(id);
            out.put_u8(axis.as_byte());
            // `childCount` is a u8 → fan-out is bounded at 255 by the FORMAT, before any
            // allocation.
            out.put_u8(u8::try_from(children.len()).unwrap_or(u8::MAX));
            for child in children.iter().take(usize::from(u8::MAX)) {
                put_layout(out, child);
            }
        },
    }
}

/// Reads a tab's tree shape.
///
/// # Errors
/// [`WireError::MalformedBody`] on an unknown node tag, a count the bytes cannot back, nesting past
/// [`MAX_LAYOUT_DEPTH`], or a trailing byte.
pub fn decode_layout(data: &[u8]) -> Result<WorkspaceLayoutNode> {
    let mut reader = ByteReader::new(data);
    let node = read_layout_node(&mut reader, 0)?;
    if reader.bytes_remaining() != 0 {
        return Err(WireError::malformed("workspace layout: trailing bytes"));
    }
    Ok(node)
}

fn read_layout_node(reader: &mut ByteReader<'_>, depth: usize) -> Result<WorkspaceLayoutNode> {
    // Checked BEFORE descending, which is what makes the bound a bound.
    if depth > MAX_LAYOUT_DEPTH {
        return Err(WireError::malformed(format!(
            "workspace layout: nested past depth {MAX_LAYOUT_DEPTH}"
        )));
    }
    match reader.read_u8()? {
        0 => Ok(WorkspaceLayoutNode::Leaf(read_uuid(reader)?)),
        1 => {
            let id = read_uuid(reader)?;
            let axis = SplitAxis::from_byte(reader.read_u8()?);
            let child_count = usize::from(reader.read_u8()?);
            // One byte minimum per child (a bare leaf tag) — bound before reserving.
            if reader.bytes_remaining() < child_count {
                return Err(WireError::malformed(format!(
                    "workspace layout: {child_count} children need at least that many bytes"
                )));
            }
            let mut children = Vec::with_capacity(child_count);
            for _ in 0..child_count {
                children.push(read_layout_node(reader, depth + 1)?);
            }
            Ok(WorkspaceLayoutNode::Split { id, axis, children })
        },
        tag => {
            Err(WireError::malformed(format!(
                "workspace layout: unknown node tag {tag}"
            )))
        },
    }
}

// ---------------------------------------------------------------------------------------------- //
// Weights
// ---------------------------------------------------------------------------------------------- //

fn put_weight(out: &mut ByteWriter<'_>, weight: SplitWeight) {
    out.put_u8(weight.kind_byte());
    out.put_u64(weight.value().to_bits());
}

/// One weight: `[u8 weightKind][u64 BE f64 bit pattern]`.
#[must_use]
pub fn encode_weight(weight: SplitWeight) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(9);
    put_weight(&mut out, weight);
    out.into_vec()
}

/// Reads one weight.
///
/// # Errors
/// [`WireError::Truncated`] when fewer than nine bytes are there, and
/// [`WireError::MalformedBody`] on a trailing byte.
pub fn decode_weight(data: &[u8]) -> Result<SplitWeight> {
    let mut reader = ByteReader::new(data);
    let weight = read_weight(&mut reader)?;
    if reader.bytes_remaining() != 0 {
        return Err(WireError::malformed("workspace weight: trailing bytes"));
    }
    Ok(weight)
}

fn read_weight(reader: &mut ByteReader<'_>) -> Result<SplitWeight> {
    let kind = reader.read_u8()?;
    let value = f64::from_bits(reader.read_u64()?);
    // C-style discipline again: any non-zero kind is `fixed`.
    Ok(if kind == 0 {
        SplitWeight::Flex(value)
    } else {
        SplitWeight::Fixed(value)
    })
}

/// A `splitNode/weight` value: `[u8 childCount]([u8 weightKind][u64 BE bits])*` — ALL of one
/// split's child weights, in child order.
///
/// One entry per SPLIT rather than per child is what makes a divider drag atomic: the op the intent
/// maps onto moves a leading/trailing PAIR, so splitting the pair across two cells would let a diff
/// carry half a drag. Two clients dragging dividers in two DIFFERENT splits still write two
/// different keys and cannot clobber each other, which is the conflict granularity docs/45 §5.3 is
/// after.
///
/// `childCount` is a `u8`, so the fan-out is bounded by the FORMAT — the same discipline
/// [`encode_layout`] uses, and it must stay in step with it.
#[must_use]
pub fn encode_weights(weights: &[SplitWeight]) -> Vec<u8> {
    let count = weights.len().min(usize::from(u8::MAX));
    let mut out = ByteWriter::with_capacity(1 + count * 9);
    out.put_u8(u8::try_from(count).unwrap_or(u8::MAX));
    for weight in weights.iter().take(count) {
        put_weight(&mut out, *weight);
    }
    out.into_vec()
}

/// Reads a split's child weights, or `None` on any framing the bytes cannot back.
///
/// A wrong-width value is a DROP, and the caller falls back to an even share rather than rendering
/// a layout it half-understood.
#[must_use]
pub fn decode_weights(data: &[u8]) -> Option<Vec<SplitWeight>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u8().ok()?);
    // Nine bytes per weight, checked before reserving: a declared 255 over an empty tail costs
    // nothing.
    if reader.bytes_remaining() != count * 9 {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(read_weight(&mut reader).ok()?);
    }
    Some(out)
}

// ---------------------------------------------------------------------------------------------- //
// Identity field values
// ---------------------------------------------------------------------------------------------- //

/// A bare UUID field value — `root/activeSessionID`, `tab/sessionID`, `tab/activePaneID`.
///
/// An ABSENT optional is an absent KEY, never the all-zero UUID: the zero UUID is the wire's "none"
/// in the presence records, and letting it mean the same thing here would make "no active pane" and
/// "the pane whose id happens to be zero" the same cell.
#[must_use]
pub fn encode_uuid(id: &RawUuid) -> Vec<u8> {
    id.to_vec()
}

/// Reads a bare UUID field value, or `None` on any length but exactly 16.
#[must_use]
pub fn decode_uuid(data: &[u8]) -> Option<RawUuid> {
    RawUuid::try_from(data).ok()
}

/// `session/detachedPanes`: `[u16 n]([16B paneID][16B originTabID])*`.
///
/// A detached pane with no remembered origin tab rides as the all-zero UUID — here it IS the
/// sentinel, because a pane always has an id but its origin is genuinely optional and the pair is
/// fixed-width.
#[must_use]
pub fn encode_detached_panes(panes: &[(RawUuid, Option<RawUuid>)]) -> Vec<u8> {
    let count = panes.len().min(usize::from(u16::MAX));
    let mut out = ByteWriter::with_capacity(2 + count * 32);
    out.put_u16(u16::try_from(count).unwrap_or(u16::MAX));
    for (pane, origin) in panes.iter().take(count) {
        out.put_bytes(pane);
        out.put_bytes(&origin.unwrap_or(ROOT_OBJECT_ID));
    }
    out.into_vec()
}

/// Reads `session/detachedPanes`, or `None` on a count the bytes cannot back exactly.
#[must_use]
pub fn decode_detached_panes(data: &[u8]) -> Option<Vec<(RawUuid, Option<RawUuid>)>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16().ok()?);
    if reader.bytes_remaining() != count * 32 {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let pane = read_uuid(&mut reader).ok()?;
        let origin = read_uuid(&mut reader).ok()?;
        out.push((pane, (origin != ROOT_OBJECT_ID).then_some(origin)));
    }
    Some(out)
}

/// `pane/videoTarget`: `[u32 windowID][u8 hasDisplay][u32 displayID][u16 titleLen][title][u16
/// appLen][app]`.
///
/// `displayID` is optional in the model — a window-shaped endpoint has none — so it carries its own
/// presence byte rather than overloading `0`, which is a legitimate display id (the main one).
#[must_use]
pub fn encode_video_target(endpoint: &VideoEndpoint) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(64);
    out.put_u32(endpoint.window_id);
    out.put_bool(endpoint.display_id.is_some());
    out.put_u32(endpoint.display_id.unwrap_or(0));
    for text in [&endpoint.title, &endpoint.app_name] {
        let bytes = clamp_utf8(text, MAX_STRING_BYTES).as_bytes();
        out.put_u16(u16::try_from(bytes.len()).unwrap_or(u16::MAX));
        out.put_bytes(bytes);
    }
    out.into_vec()
}

/// Reads `pane/videoTarget`, or `None` on framing the bytes cannot back or non-UTF-8 text.
#[must_use]
pub fn decode_video_target(data: &[u8]) -> Option<VideoEndpoint> {
    let mut reader = ByteReader::new(data);
    let window_id = reader.read_u32().ok()?;
    // C-style bool discipline on a byte that crossed the network.
    let has_display = reader.read_bool().ok()?;
    let display_id = reader.read_u32().ok()?;
    let title = read_u16_prefixed_string(&mut reader)?;
    let app_name = read_u16_prefixed_string(&mut reader)?;
    if reader.bytes_remaining() != 0 {
        return None;
    }
    Some(VideoEndpoint {
        window_id,
        title,
        app_name,
        display_id: has_display.then_some(display_id),
    })
}

fn read_u16_prefixed_string(reader: &mut ByteReader<'_>) -> Option<String> {
    let length = usize::from(reader.read_u16().ok()?);
    let bytes = reader.read_bytes(length).ok()?;
    core::str::from_utf8(bytes).map(str::to_owned).ok()
}

// ---------------------------------------------------------------------------------------------- //
// Scalar field values
// ---------------------------------------------------------------------------------------------- //

/// A string field value: strict UTF-8, never lossy. Clamped at a `char` boundary so a truncated
/// value stays valid UTF-8 (the type-35 idiom).
#[must_use]
pub fn encode_string(text: &str, max_bytes: usize) -> Vec<u8> {
    clamp_utf8(text, max_bytes).as_bytes().to_vec()
}

/// Reads a string field value, or `None` when the bytes are not valid UTF-8.
///
/// The caller drops the field rather than rendering replacement characters — the strict-UTF-8 rule
/// this wire holds everywhere.
#[must_use]
pub fn decode_string(data: &[u8]) -> Option<String> {
    core::str::from_utf8(data).map(str::to_owned).ok()
}

/// A one-byte field (`titleFresh`, `commandRunning`, `liveness`, `syncInputArmed`, `userRenamed`).
#[must_use]
pub fn encode_u8(value: u8) -> Vec<u8> {
    vec![value]
}

/// Reads a one-byte field, or `None` on any length but exactly 1.
///
/// A wrong-width value is a DROP, never a lenient prefix read: strictness here is what stops a
/// mis-numbered field from decoding into a plausible-looking value.
#[must_use]
pub const fn decode_u8(data: &[u8]) -> Option<u8> {
    match data {
        [byte] => Some(*byte),
        _ => None,
    }
}

/// A boolean field.
#[must_use]
pub fn encode_bool(value: bool) -> Vec<u8> {
    encode_u8(u8::from(value))
}

/// Reads a boolean field. C-style discipline: any non-zero byte is `true`.
#[must_use]
pub fn decode_bool(data: &[u8]) -> Option<bool> {
    decode_u8(data).map(|byte| byte != 0)
}

/// A two-byte pair — `agentState` is `[state][kind]`, `progress` is `[state][percent]`.
#[must_use]
pub fn encode_u8_pair(first: u8, second: u8) -> Vec<u8> {
    vec![first, second]
}

/// Reads a two-byte pair, or `None` on any length but exactly 2.
#[must_use]
pub const fn decode_u8_pair(data: &[u8]) -> Option<(u8, u8)> {
    match data {
        [first, second] => Some((*first, *second)),
        _ => None,
    }
}

/// A `[u16 BE][u16 BE]` pair — `pane/grid` is `(cols, rows)`, in that order.
#[must_use]
pub fn encode_u16_pair(first: u16, second: u16) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(4);
    out.put_u16(first);
    out.put_u16(second);
    out.into_vec()
}

/// Reads a `u16` pair, or `None` on any length but exactly 4.
#[must_use]
pub const fn decode_u16_pair(data: &[u8]) -> Option<(u16, u16)> {
    match data {
        [a, b, c, d] => Some((u16::from_be_bytes([*a, *b]), u16::from_be_bytes([*c, *d]))),
        _ => None,
    }
}

/// A four-byte unsigned field.
#[must_use]
pub fn encode_u32(value: u32) -> Vec<u8> {
    value.to_be_bytes().to_vec()
}

/// Reads a four-byte unsigned field, or `None` on any length but exactly 4.
#[must_use]
pub fn decode_u32(data: &[u8]) -> Option<u32> {
    <[u8; 4]>::try_from(data).map(u32::from_be_bytes).ok()
}

/// `pane/lastExitCode`.
///
/// Rides as the `u32` bit pattern so a negative code (a signal-killed child) survives without a
/// sign convention to get wrong on either end.
#[must_use]
pub fn encode_i32(value: i32) -> Vec<u8> {
    value.to_be_bytes().to_vec()
}

/// Reads a signed four-byte field, or `None` on any length but exactly 4.
#[must_use]
pub fn decode_i32(data: &[u8]) -> Option<i32> {
    <[u8; 4]>::try_from(data).map(i32::from_be_bytes).ok()
}

/// An eight-byte signed field — a millisecond timestamp.
#[must_use]
pub fn encode_i64(value: i64) -> Vec<u8> {
    value.to_be_bytes().to_vec()
}

/// Reads an eight-byte signed field, or `None` on any length but exactly 8.
#[must_use]
pub fn decode_i64(data: &[u8]) -> Option<i64> {
    <[u8; 8]>::try_from(data).map(i64::from_be_bytes).ok()
}

/// A `[u16 BE count]` list of UUIDs — `root/sessionOrder`, `session/tabOrder`,
/// `root/closedTabRing`.
#[must_use]
pub fn encode_uuid_list(ids: &[RawUuid]) -> Vec<u8> {
    let count = ids.len().min(usize::from(u16::MAX));
    let mut out = ByteWriter::with_capacity(2 + count * 16);
    out.put_u16(u16::try_from(count).unwrap_or(u16::MAX));
    for id in ids.iter().take(count) {
        out.put_bytes(id);
    }
    out.into_vec()
}

/// Reads a UUID list, or `None` on a count the bytes cannot back exactly.
///
/// The length is validated against what REMAINS before any capacity is reserved, so a hostile
/// `0xFFFF` costs nothing.
#[must_use]
pub fn decode_uuid_list(data: &[u8]) -> Option<Vec<RawUuid>> {
    let mut reader = ByteReader::new(data);
    let count = usize::from(reader.read_u16().ok()?);
    if reader.bytes_remaining() != count * 16 {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        out.push(read_uuid(&mut reader).ok()?);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        HostWorkspaceState, MAX_LAYOUT_DEPTH, SplitAxis, SplitWeight, VideoEndpoint, WorkspaceEntry,
        WorkspaceKey, WorkspaceLayoutNode, WorkspaceStateDiff, decode_bool, decode_detached_panes,
        decode_diff, decode_i32, decode_i64, decode_layout, decode_snapshot, decode_string, decode_u8,
        decode_u8_pair, decode_u16_pair, decode_u32, decode_uuid, decode_uuid_list, decode_video_target,
        decode_weight, decode_weights, encode_bool, encode_detached_panes, encode_diff, encode_i32,
        encode_i64, encode_key, encode_layout, encode_snapshot, encode_string, encode_u8, encode_u8_pair,
        encode_u16_pair, encode_u32, encode_uuid, encode_uuid_list, encode_video_target, encode_weight,
        encode_weights,
    };

    fn uuid(byte: u8) -> [u8; 16] {
        [byte; 16]
    }

    fn nested(depth: usize) -> WorkspaceLayoutNode {
        let mut node = WorkspaceLayoutNode::Leaf(uuid(0xA1));
        for i in 0..depth {
            node = WorkspaceLayoutNode::Split {
                id: uuid(0xD0_u8.wrapping_add(u8::try_from(i).unwrap_or(0))),
                axis: if i % 2 == 0 {
                    SplitAxis::Horizontal
                } else {
                    SplitAxis::Vertical
                },
                children: vec![node],
            };
        }
        node
    }

    #[test]
    fn a_key_is_eighteen_fixed_bytes_in_kind_object_field_order() {
        let bytes = encode_key(&WorkspaceKey::new(3, uuid(0xA1), 8));
        assert_eq!(bytes.len(), WorkspaceKey::ENCODED_SIZE);
        assert_eq!(bytes[0], 3);
        assert_eq!(&bytes[1..17], &uuid(0xA1));
        assert_eq!(bytes[17], 8);
    }

    #[test]
    fn a_snapshot_round_trips_including_the_zero_length_retirement_value() {
        let state = HostWorkspaceState::from_entries(vec![
            WorkspaceEntry::new(WorkspaceKey::new(3, uuid(0xA1), 3), Vec::new()),
            WorkspaceEntry::new(WorkspaceKey::root(2), b"mac-studio".to_vec()),
        ]);
        let decoded = decode_snapshot(&encode_snapshot(&state)).unwrap();
        assert_eq!(decoded, state);
        assert_eq!(decoded.get(&WorkspaceKey::new(3, uuid(0xA1), 3)), Some(&[][..]));
    }

    #[test]
    fn a_diff_round_trips_both_halves() {
        let diff = WorkspaceStateDiff::new(
            vec![WorkspaceEntry::new(
                WorkspaceKey::new(3, uuid(0xA1), 8),
                b"vi .".to_vec(),
            )],
            vec![WorkspaceKey::new(3, uuid(0xA1), 99)],
        );
        assert_eq!(decode_diff(&encode_diff(&diff)).unwrap(), diff);
        let empty = WorkspaceStateDiff::default();
        assert_eq!(encode_diff(&empty), vec![0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(decode_diff(&encode_diff(&empty)).unwrap(), empty);
    }

    #[test]
    fn a_snapshot_with_a_trailing_byte_is_refused_rather_than_half_read() {
        let state =
            HostWorkspaceState::from_entries(vec![WorkspaceEntry::new(WorkspaceKey::root(2), b"x".to_vec())]);
        let mut bytes = encode_snapshot(&state);
        bytes.push(0);
        assert!(decode_snapshot(&bytes).is_err());
    }

    #[test]
    fn a_hostile_entry_count_costs_nothing_before_it_is_refused() {
        // A four-byte count of `u32::MAX` over an empty body: rejected on the cap, never reserved.
        assert!(decode_snapshot(&[0xFF, 0xFF, 0xFF, 0xFF]).is_err());
        // And one inside the cap whose entries the buffer cannot possibly hold.
        assert!(decode_snapshot(&[0x00, 0x00, 0xFF, 0xFF]).is_err());
    }

    #[test]
    fn a_hostile_entry_value_length_is_bounded_against_what_actually_remains() {
        let mut bytes = vec![0, 0, 0, 1];
        bytes.extend_from_slice(&encode_key(&WorkspaceKey::root(2)));
        bytes.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
        assert!(decode_snapshot(&bytes).is_err());
    }

    #[test]
    fn a_layout_round_trips_at_depth_one_and_at_the_cap() {
        for depth in [1, MAX_LAYOUT_DEPTH] {
            let node = nested(depth);
            assert_eq!(decode_layout(&encode_layout(&node)).unwrap(), node);
        }
    }

    #[test]
    fn a_layout_nested_past_the_cap_is_refused_before_it_descends() {
        let bytes = encode_layout(&nested(MAX_LAYOUT_DEPTH + 1));
        assert!(decode_layout(&bytes).is_err());
    }

    #[test]
    fn an_unknown_layout_node_tag_is_refused_rather_than_guessed() {
        assert!(decode_layout(&[7]).is_err());
    }

    #[test]
    fn a_split_fans_out_to_its_children_in_order() {
        let node = WorkspaceLayoutNode::Split {
            id: uuid(0xC3),
            axis: SplitAxis::Vertical,
            children: (0..4)
                .map(|i| WorkspaceLayoutNode::Leaf(uuid(0xE0 + i)))
                .collect(),
        };
        let bytes = encode_layout(&node);
        assert_eq!(bytes[17], 1, "the axis byte");
        assert_eq!(bytes[18], 4, "the child count");
        assert_eq!(decode_layout(&bytes).unwrap(), node);
    }

    #[test]
    fn an_axis_byte_is_read_c_style_with_no_third_answer() {
        assert_eq!(SplitAxis::from_byte(0), SplitAxis::Horizontal);
        for byte in [1_u8, 2, 0xFF] {
            assert_eq!(SplitAxis::from_byte(byte), SplitAxis::Vertical);
        }
    }

    #[test]
    fn a_weight_rides_as_a_raw_bit_pattern_and_survives_it() {
        for weight in [SplitWeight::Flex(1.0 / 3.0), SplitWeight::Fixed(240.0)] {
            let bytes = encode_weight(weight);
            assert_eq!(bytes.len(), 9);
            let decoded = decode_weight(&bytes).unwrap();
            assert_eq!(decoded, weight);
            assert_eq!(decoded.value().to_bits(), weight.value().to_bits());
        }
    }

    #[test]
    fn a_split_carries_all_of_its_child_weights_in_one_cell() {
        let weights = vec![SplitWeight::Flex(1.0 / 3.0), SplitWeight::Fixed(240.0)];
        let bytes = encode_weights(&weights);
        assert_eq!(bytes[0], 2);
        assert_eq!(decode_weights(&bytes), Some(weights));
        assert_eq!(encode_weights(&[]), vec![0]);
        assert_eq!(decode_weights(&[0]), Some(Vec::new()));
    }

    #[test]
    fn a_declared_weight_count_the_bytes_cannot_back_is_dropped() {
        assert_eq!(decode_weights(&[0xFF]), None);
        assert_eq!(decode_weights(&[]), None);
        assert_eq!(decode_weights(&[1, 0, 0, 0, 0, 0, 0, 0]), None);
    }

    #[test]
    fn a_uuid_cell_is_exactly_sixteen_bytes_or_nothing() {
        let id = uuid(0xB2);
        assert_eq!(encode_uuid(&id), id.to_vec());
        assert_eq!(decode_uuid(&id), Some(id));
        assert_eq!(decode_uuid(&id[..15]), None);
        assert_eq!(decode_uuid(&[0_u8; 17]), None);
    }

    #[test]
    fn a_detached_pane_with_no_origin_tab_rides_as_the_zero_uuid() {
        let panes = vec![(uuid(0xA1), Some(uuid(0xB2))), (uuid(0xA2), None)];
        let bytes = encode_detached_panes(&panes);
        assert_eq!(bytes.len(), 2 + 2 * 32);
        assert_eq!(&bytes[bytes.len() - 16..], &[0_u8; 16]);
        assert_eq!(decode_detached_panes(&bytes), Some(panes));
        assert_eq!(decode_detached_panes(&[0, 2]), None);
    }

    #[test]
    fn a_video_target_keeps_display_zero_distinct_from_no_display() {
        let display = VideoEndpoint {
            window_id: 0,
            title: "Display 1".to_owned(),
            app_name: String::new(),
            display_id: Some(0),
        };
        let window = VideoEndpoint {
            window_id: 0x1234_5678,
            title: "main.swift".to_owned(),
            app_name: "Ghostty".to_owned(),
            display_id: None,
        };
        for endpoint in [&display, &window] {
            assert_eq!(
                decode_video_target(&encode_video_target(endpoint)).as_ref(),
                Some(endpoint)
            );
        }
        assert_ne!(encode_video_target(&display), encode_video_target(&window));
    }

    #[test]
    fn a_video_target_with_invalid_utf8_text_is_dropped() {
        let mut bytes = encode_video_target(&VideoEndpoint {
            window_id: 1,
            title: "ok".to_owned(),
            app_name: String::new(),
            display_id: None,
        });
        bytes[11] = 0xFF;
        assert_eq!(decode_video_target(&bytes), None);
    }

    #[test]
    fn a_string_cell_clamps_at_a_char_boundary_and_stays_valid_utf8() {
        // "🚀" is four bytes; a three-byte cap must drop it whole rather than split it.
        assert_eq!(encode_string("🚀", 3), Vec::<u8>::new());
        assert_eq!(encode_string("a🚀", 5), "a🚀".as_bytes().to_vec());
        assert_eq!(encode_string("a🚀", 4), b"a".to_vec());
        assert_eq!(decode_string(&encode_string("a🚀", 4)), Some("a".to_owned()));
        assert_eq!(decode_string(&[0xFF, 0xFE]), None);
    }

    #[test]
    fn every_fixed_width_cell_refuses_a_wrong_width_body() {
        assert_eq!(decode_u8(&encode_u8(7)), Some(7));
        assert_eq!(decode_u8(&[1, 2]), None);
        assert_eq!(decode_bool(&encode_bool(true)), Some(true));
        assert_eq!(decode_bool(&[0xFF]), Some(true));
        assert_eq!(decode_bool(&[]), None);
        assert_eq!(decode_u8_pair(&encode_u8_pair(2, 3)), Some((2, 3)));
        assert_eq!(decode_u8_pair(&[1]), None);
        assert_eq!(decode_u16_pair(&encode_u16_pair(120, 40)), Some((120, 40)));
        assert_eq!(decode_u16_pair(&[0, 1, 2]), None);
        assert_eq!(decode_u32(&encode_u32(u32::MAX)), Some(u32::MAX));
        assert_eq!(decode_u32(&[0, 0, 0]), None);
        assert_eq!(decode_i32(&encode_i32(-9)), Some(-9));
        assert_eq!(decode_i32(&[0, 0, 0, 0, 0]), None);
        assert_eq!(decode_i64(&encode_i64(i64::MIN)), Some(i64::MIN));
        assert_eq!(decode_i64(&[0; 7]), None);
    }

    #[test]
    fn a_uuid_list_is_validated_against_what_remains_before_anything_is_reserved() {
        let ids = vec![uuid(0xB2), uuid(0xB3)];
        assert_eq!(decode_uuid_list(&encode_uuid_list(&ids)), Some(ids));
        assert_eq!(decode_uuid_list(&[0xFF, 0xFF]), None);
        assert_eq!(decode_uuid_list(&encode_uuid_list(&[])), Some(Vec::new()));
        assert_eq!(decode_uuid_list(&[0]), None);
    }
}
