//! The multiclient document's codec: the scalar leaves, the snapshot and the diff, the layout with
//! its weights, and the two composite field values.
//!
//! Every decoder here is STRICT about width and checks each bound against the bytes ACTUALLY
//! remaining, because the counts and the lengths are chosen by whoever is on the other end of the
//! socket. The banners below argue each one where it differs.

use slopdesk_workspace::state_codec;

use super::tree::Share;
use super::{Span, Uuid};
use crate::deliver;

// MARK: The document's scalar field codec
//
// The leaves of the multiclient state protocol (docs/45). Every decoder is STRICT about width — a
// value of the wrong length answers "absent" rather than a lenient prefix read — because these
// bytes came off a socket and a mis-numbered field must FAIL rather than succeed into something
// plausible.
//
// The out-parameter shape rather than a return value, because every one of these has to be able to
// say "these bytes are not a value of this kind" without a sentinel that could also be data: a
// `lastExitCode` of -1 is a real exit code, and `0xFFFFFFFF` is its encoding.

/// Reads a caller's byte field.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading through a caller's pointer"
)]
const unsafe fn field(bytes: *const u8, len: usize) -> &'static [u8] {
    if bytes.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: non-null and, by the caller's obligation, `len` live bytes for the call. The lifetime
    // is erased to `'static` and immediately consumed by a total decoder, none of which retains it.
    unsafe { core::slice::from_raw_parts(bytes, len) }
}

/// A one-byte field's value. False when the bytes are not exactly one.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `u8`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u8(bytes: *const u8, len: usize, out: *mut u8) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_u8(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u8`.
        unsafe { *out = value };
    }
    true
}

/// A two-byte pair's values — `agentState` is `(state, kind)`, `progress` is `(state, percent)`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each out null or writable for one `u8`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u8_pair(
    bytes: *const u8,
    len: usize,
    first: *mut u8,
    second: *mut u8,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some((a, b)) = state_codec::decode_u8_pair(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !first.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u8`.
        unsafe { *first = a };
    }
    if !second.is_null() {
        // SAFETY: as above.
        unsafe { *second = b };
    }
    true
}

/// A `[u16 BE][u16 BE]` pair's values — `pane/grid` is `(cols, rows)`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each out null or writable for one `u16`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u16_pair(
    bytes: *const u8,
    len: usize,
    first: *mut u16,
    second: *mut u16,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some((a, b)) = state_codec::decode_u16_pair(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !first.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u16`.
        unsafe { *first = a };
    }
    if !second.is_null() {
        // SAFETY: as above.
        unsafe { *second = b };
    }
    true
}

/// A `[u32 BE]` field's value.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `u32`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_u32(bytes: *const u8, len: usize, out: *mut u32) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_u32(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `u32`.
        unsafe { *out = value };
    }
    true
}

/// A `[u32 BE]` field read as a SIGNED value — `pane/lastExitCode`, where a signal-killed child
/// reports a negative code and the bit pattern is what crosses.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `i32`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_i32(bytes: *const u8, len: usize, out: *mut i32) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_i32(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `i32`.
        unsafe { *out = value };
    }
    true
}

/// A `[u64 BE]` field read as a signed value — `pane/lastActivityMS`.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one `i64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_i64(bytes: *const u8, len: usize, out: *mut i64) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_i64(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `i64`.
        unsafe { *out = value };
    }
    true
}

/// A `[u16 BE count][uuid…]` list's ids, under §4's convention. [`usize::MAX`] when the count and
/// the bytes disagree — which is a REFUSAL, not the empty list that a well-formed zero count is.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`Uuid`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_uuid_list(
    bytes: *const u8,
    len: usize,
    out: *mut Uuid,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(ids) = state_codec::decode_uuid_list(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<Uuid> = ids.into_iter().map(|bytes| Uuid { bytes }).collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// A `[u16 BE count][uuid…]` list's bytes, under §4's convention.
///
/// # Safety
/// `ids` must be null or point to `count` live [`Uuid`]s; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_uuid_list(
    ids: *const Uuid,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let raw: Vec<[u8; 16]> = if ids.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live `Uuid`s for the call.
        unsafe { core::slice::from_raw_parts(ids, count) }
            .iter()
            .map(|id| id.bytes)
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_uuid_list(&raw), out, cap) }
}

/// A string field's bytes: strict UTF-8, clamped at a CHARACTER boundary so a truncated value is
/// still valid UTF-8 rather than a half-written scalar the far end drops entirely.
///
/// `max_bytes` is the FIELD's limit, which is not always the protocol's — a rename is clamped
/// tighter than a title.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_string(
    bytes: *const u8,
    len: usize,
    max_bytes: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(text) = state_codec::decode_string(field(bytes, len)) else {
            return 0;
        };
        deliver(&state_codec::encode_string(text, max_bytes), out, cap)
    }
}

// MARK: The snapshot and the diff
//
// The highest-risk parsing in the document: a count and a length, both chosen by whoever is on the
// other end of the socket. Every bound is checked against the bytes ACTUALLY remaining before any
// capacity is reserved, so a hostile `0xFFFFFFFF` costs a comparison rather than four gigabytes.
//
// A decoded value is a SPAN into the caller's own input buffer rather than a copy. A snapshot is
// hundreds of entries and arrives on every attach; copying each value into a second blob would
// double the work for no property. The caller still holds the buffer, so the spans are live for
// exactly as long as they are useful.

/// The upper bound on entries in one snapshot or diff, exported rather than transcribed.
///
/// It is a REFUSAL threshold, so two copies of it would be two different ideas of what counts as an
/// absurd document — and the smaller one would reject states the other happily sends.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_entry_count() -> usize {
    state_codec::MAX_ENTRY_COUNT
}

/// One document entry on the way across: a key, and where its value sits in the input.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CEntry {
    /// Which kind of object the key names — root, session, tab, pane.
    pub kind: u8,
    /// Which field of it.
    pub field: u8,
    /// The object's identity.
    pub object: Uuid,
    /// Where the value sits in the buffer that was decoded. `present` is always true for a decode;
    /// it is the ENCODE direction that uses it, where a key with no value is a delete.
    pub value: Span,
}

/// Reads the entries a decode answered into the flat form.
fn flatten(entries: &[state_codec::Entry<'_>], base: *const u8) -> Vec<CEntry> {
    entries
        .iter()
        .map(|entry| {
            CEntry {
                kind: entry.kind,
                field: entry.field,
                object: Uuid { bytes: entry.object },
                value: Span {
                    // The value is a subslice of the input, so its offset is the pointer difference.
                    // Both pointers are into one allocation, which is what makes the arithmetic defined.
                    offset: (entry.value.as_ptr() as usize).saturating_sub(base as usize),
                    len: entry.value.len(),
                    present: true,
                },
            }
        })
        .collect()
}

/// The entries a snapshot carries, under §4's convention, with each value a span into `bytes`.
///
/// [`usize::MAX`] when the bytes are malformed — a REFUSAL, which is not the empty snapshot that a
/// well-formed zero count is. Trailing bytes are malformed on purpose: a snapshot that decoded to
/// fewer entries than it carries would have the client ack a state it does not hold.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`CEntry`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_snapshot(
    bytes: *const u8,
    len: usize,
    out: *mut CEntry,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some(entries) = state_codec::decode_snapshot(input) else {
        return usize::MAX;
    };
    let answers = flatten(&entries, input.as_ptr());
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// The two halves a diff carries. Both counts are written even when a buffer was too small, so one
/// call sizes both and the retry needs no guessing.
///
/// False when the bytes are malformed. `sets_needed`/`deletes_needed` are then untouched, because
/// there is no partial answer to size for: a diff that half-decoded is not a diff.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; each `out` null or writable for its `cap`;
/// each `needed` null or writable for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_diff(
    bytes: *const u8,
    len: usize,
    sets_out: *mut CEntry,
    sets_cap: usize,
    deletes_out: *mut CEntry,
    deletes_cap: usize,
    sets_needed: *mut usize,
    deletes_needed: *mut usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some((sets, deletes)) = state_codec::decode_diff(input) else {
        return false;
    };
    let set_entries = flatten(&sets, input.as_ptr());
    // A delete is a key with no value, which is what `present: false` says here.
    let delete_entries: Vec<CEntry> = deletes
        .iter()
        .map(|key| {
            CEntry {
                kind: key.kind,
                field: key.field,
                object: Uuid { bytes: key.object },
                value: Span {
                    offset: 0,
                    len: 0,
                    present: false,
                },
            }
        })
        .collect();
    // SAFETY: each pointer is null or writable for what its obligation says, and both source
    // vectors were allocated inside this call so neither can overlap a destination.
    unsafe {
        if !sets_needed.is_null() {
            *sets_needed = set_entries.len();
        }
        if !deletes_needed.is_null() {
            *deletes_needed = delete_entries.len();
        }
        if set_entries.len() <= sets_cap && !sets_out.is_null() {
            core::ptr::copy_nonoverlapping(set_entries.as_ptr(), sets_out, set_entries.len());
        }
        if delete_entries.len() <= deletes_cap && !deletes_out.is_null() {
            core::ptr::copy_nonoverlapping(delete_entries.as_ptr(), deletes_out, delete_entries.len());
        }
    }
    true
}

/// Reads the entries a caller is encoding, whose values are spans into `blob`.
///
/// A span the blob cannot back reads as an EMPTY value rather than trapping — the same bounds
/// discipline the decode side uses, applied to a caller who got their own arithmetic wrong.
fn gather<'a>(entries: &[CEntry], blob: &'a [u8]) -> Vec<state_codec::Entry<'a>> {
    entries
        .iter()
        .map(|entry| {
            state_codec::Entry {
                kind: entry.kind,
                object: entry.object.bytes,
                field: entry.field,
                value: entry
                    .value
                    .offset
                    .checked_add(entry.value.len)
                    .and_then(|end| blob.get(entry.value.offset..end))
                    .unwrap_or_default(),
            }
        })
        .collect()
}

/// A snapshot's bytes, under §4's convention.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s, `blob` null or to `blob_len` live
/// bytes, and `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_snapshot(
    entries: *const CEntry,
    count: usize,
    blob: *const u8,
    blob_len: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let flat = borrow_entries(entries, count);
        let bytes = field(blob, blob_len);
        deliver(&state_codec::encode_snapshot(&gather(&flat, bytes)), out, cap)
    }
}

/// A diff's bytes, under §4's convention. The DELETES carry only their keys; their spans are
/// ignored.
///
/// # Safety
/// As [`slopdesk_ws_encode_snapshot`], for both entry arrays.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_diff(
    sets: *const CEntry,
    set_count: usize,
    deletes: *const CEntry,
    delete_count: usize,
    blob: *const u8,
    blob_len: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let flat_sets = borrow_entries(sets, set_count);
        let flat_deletes = borrow_entries(deletes, delete_count);
        let bytes = field(blob, blob_len);
        let keys: Vec<state_codec::Key> = flat_deletes
            .iter()
            .map(|entry| {
                state_codec::Key {
                    kind: entry.kind,
                    object: entry.object.bytes,
                    field: entry.field,
                }
            })
            .collect();
        deliver(
            &state_codec::encode_diff(&gather(&flat_sets, bytes), &keys),
            out,
            cap,
        )
    }
}

/// Reads a caller's entry array.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading through a caller's pointer"
)]
unsafe fn borrow_entries(entries: *const CEntry, count: usize) -> Vec<CEntry> {
    if entries.is_null() || count == 0 {
        return Vec::new();
    }
    // SAFETY: non-null and, by the caller's obligation, `count` live `CEntry`s for the call.
    unsafe { core::slice::from_raw_parts(entries, count) }.to_vec()
}

// MARK: The layout structure and the split weights
//
// The layout decoder that crossed is ITERATIVE where the Swift one recursed. A depth cap checked
// before descending is correct, but it is one forgotten check away from a remote stack overflow;
// walking a flat array with an explicit frame stack makes the overflow structurally impossible, and
// the cap goes back to being a statement about documents rather than a safety mechanism.

/// One node of the layout structure, in a pre-order walk.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CLayoutNode {
    /// `0` leaf, `1` split.
    pub kind: u8,
    /// `0` horizontal, `1` vertical. Meaningless on a leaf.
    pub axis: u8,
    /// A split's child count. A `u8` by the FORMAT, so fan-out is bounded before any allocation.
    pub child_count: u8,
    /// The pane's or the split's identity.
    pub id: Uuid,
}

/// The walk a layout structure carries, under §4's convention.
///
/// [`usize::MAX`] when the bytes do not decode, with `depth_exceeded` saying WHICH refusal it was:
/// a well-formed tree nested past the cap sets it, an unknown tag or a truncated node does not. The
/// caller reports those differently, because one is a document this build declines to hold and the
/// other is a bug or an attack — so the distinction crosses as a flag rather than being flattened
/// into the one sentinel.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` nodes;
/// `depth_exceeded` null or writable for one `bool`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_layout(
    bytes: *const u8,
    len: usize,
    out: *mut CLayoutNode,
    cap: usize,
    depth_exceeded: *mut bool,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let decoded = state_codec::decode_layout(unsafe { field(bytes, len) });
    if !depth_exceeded.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { *depth_exceeded = decoded == Err(state_codec::LayoutError::DepthExceeded) };
    }
    let Ok(walk) = decoded else {
        return usize::MAX;
    };
    let answers: Vec<CLayoutNode> = walk
        .into_iter()
        .map(|node| {
            CLayoutNode {
                kind: node.kind,
                axis: node.axis,
                child_count: node.child_count,
                id: Uuid { bytes: node.id },
            }
        })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// A layout structure's bytes, under §4's convention.
///
/// # Safety
/// `walk` must be null or point to `count` live nodes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_layout(
    walk: *const CLayoutNode,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let nodes: Vec<state_codec::LayoutNode> = if walk.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live nodes for the call.
        unsafe { core::slice::from_raw_parts(walk, count) }
            .iter()
            .map(|node| {
                state_codec::LayoutNode {
                    kind: node.kind,
                    id: node.id.bytes,
                    axis: node.axis,
                    child_count: node.child_count,
                }
            })
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_layout(&nodes), out, cap) }
}

/// One split's child weights, under §4's convention. [`usize::MAX`] when the count and the bytes
/// disagree — a refusal, not the empty list a well-formed zero count is.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` [`Share`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_weights(
    bytes: *const u8,
    len: usize,
    out: *mut Share,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(weights) = state_codec::decode_weights(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<Share> = weights
        .into_iter()
        .map(|(is_fixed, value)| Share { is_fixed, value })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// One split's child weights as bytes, under §4's convention.
///
/// # Safety
/// `shares` must be null or point to `count` live [`Share`]s; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_weights(
    shares: *const Share,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let weights: Vec<(bool, f64)> = if shares.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live `Share`s for the call.
        unsafe { core::slice::from_raw_parts(shares, count) }
            .iter()
            .map(|share| (share.is_fixed, share.value))
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_weights(&weights), out, cap) }
}

/// A `[16B]` field value. False when the bytes are not exactly sixteen.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_uuid(bytes: *const u8, len: usize, out: *mut Uuid) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(value) = state_codec::decode_uuid(unsafe { field(bytes, len) }) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Uuid`.
        unsafe { *out = Uuid { bytes: value } };
    }
    true
}

/// A key's eighteen bytes, under §4's convention.
///
/// The addressing scheme is the document's, so it is written once in the crate rather than being a
/// small append loop on each side of the boundary.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_key(
    kind: u8,
    object: Uuid,
    field_tag: u8,
    out: *mut u8,
    cap: usize,
) -> usize {
    let key = state_codec::Key {
        kind,
        object: object.bytes,
        field: field_tag,
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_key(key), out, cap) }
}

/// A `[u32 BE]` field value's bytes, under §4's convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_u32(value: u32, out: *mut u8, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_u32(value), out, cap) }
}

/// An `[i64 BE]` field value's bytes, under §4's convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_ws_encode_i64(value: i64, out: *mut u8, cap: usize) -> usize {
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_i64(value), out, cap) }
}

// MARK: - The two composite field values

/// A detached pane and the tab it came from, if that is still known.
///
/// `has_origin` is a FLAG, not a zero id: the wire's fixed-width pair spells absence as the
/// all-zero uuid, and the crate translates it here so no caller on this side has to know that
/// spelling.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CDetachedPane {
    /// The pane itself.
    pub pane: Uuid,
    /// The tab it was detached from. Meaningless when `has_origin` is false.
    pub origin: Uuid,
    /// Whether the origin is remembered at all.
    pub has_origin: bool,
}

/// A pane's video source, its two strings as SPANS into the caller's own input buffer.
///
/// Zero-copy the way a decoded entry is: the bytes are already in Swift's hands, so a span is an
/// offset into what it lent rather than a second allocation it then has to free.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CVideoTarget {
    /// The window's id on the host.
    pub window_id: u32,
    /// The display it sits on. Meaningless when `has_display` is false — `0` is the MAIN display,
    /// so it could never have carried the absence itself.
    pub display_id: u32,
    /// Whether the endpoint is display-shaped at all.
    pub has_display: bool,
    /// The window title, as an offset into the bytes the caller lent.
    pub title: Span,
    /// The owning application's name, likewise.
    pub app_name: Span,
}

/// The detached panes a value carries, under §4's convention. [`usize::MAX`] when the count and the
/// bytes disagree.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for `cap` panes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_detached_panes(
    bytes: *const u8,
    len: usize,
    out: *mut CDetachedPane,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let Some(panes) = state_codec::decode_detached_panes(unsafe { field(bytes, len) }) else {
        return usize::MAX;
    };
    let answers: Vec<CDetachedPane> = panes
        .into_iter()
        .map(|entry| {
            CDetachedPane {
                pane: Uuid { bytes: entry.pane },
                origin: Uuid {
                    bytes: entry.origin.unwrap_or([0; 16]),
                },
                has_origin: entry.origin.is_some(),
            }
        })
        .collect();
    if answers.len() > cap || out.is_null() {
        return answers.len();
    }
    // SAFETY: `answers.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `answers` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(answers.as_ptr(), out, answers.len()) };
    answers.len()
}

/// The detached panes as bytes, under §4's convention.
///
/// # Safety
/// `panes` must be null or point to `count` live [`CDetachedPane`]s; `out` null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_detached_panes(
    panes: *const CDetachedPane,
    count: usize,
    out: *mut u8,
    cap: usize,
) -> usize {
    let entries: Vec<state_codec::DetachedPane> = if panes.is_null() || count == 0 {
        Vec::new()
    } else {
        // SAFETY: non-null and, by the caller's obligation, `count` live panes for the call.
        unsafe { core::slice::from_raw_parts(panes, count) }
            .iter()
            .map(|entry| {
                state_codec::DetachedPane {
                    pane: entry.pane.bytes,
                    origin: entry.has_origin.then_some(entry.origin.bytes),
                }
            })
            .collect()
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_detached_panes(&entries), out, cap) }
}

/// A pane's video target, its strings spanning the bytes the caller lent. False when a length
/// overruns, a string is not UTF-8, or bytes are left over.
///
/// # Safety
/// `bytes` must be null or point to `len` live bytes; `out` null or writable for one
/// [`CVideoTarget`]. The spans it writes are offsets into `bytes`, so they are meaningful only for
/// as long as the caller keeps that buffer alive.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_decode_video_target(
    bytes: *const u8,
    len: usize,
    out: *mut CVideoTarget,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let input = unsafe { field(bytes, len) };
    let Some(target) = state_codec::decode_video_target(input) else {
        return false;
    };
    // The decoded strings BORROW `input`, so their offsets are found by pointer arithmetic within
    // it rather than by re-scanning the format — which is what makes this leg zero-copy.
    let span_of = |text: &str| {
        let offset = (text.as_ptr() as usize).saturating_sub(input.as_ptr() as usize);
        Span {
            offset,
            len: text.len(),
            present: true,
        }
    };
    if !out.is_null() {
        let answer = CVideoTarget {
            window_id: target.window_id,
            display_id: target.display_id.unwrap_or(0),
            has_display: target.display_id.is_some(),
            title: span_of(target.title),
            app_name: span_of(target.app_name),
        };
        // SAFETY: non-null and, by the caller's obligation, writable for one `CVideoTarget`.
        unsafe { *out = answer };
    }
    true
}

/// A pane's video target as bytes, under §4's convention. The two strings arrive as spans into one
/// `blob`, the same way every other multi-string call here takes them.
///
/// # Safety
/// `blob` must be null or point to `blob_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_encode_video_target(
    window_id: u32,
    display_id: u32,
    has_display: bool,
    blob: *const u8,
    blob_len: usize,
    title: Span,
    app_name: Span,
    out: *mut u8,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `field` states its own.
    let strings = unsafe { field(blob, blob_len) };
    // A span that does not fit the blob reads as the empty string: the caller got its arithmetic
    // wrong, and an empty title is a visible bug where a read past the end is not one at all.
    let text = |span: Span| {
        span.offset
            .checked_add(span.len)
            .and_then(|end| strings.get(span.offset..end))
            .and_then(|slice| core::str::from_utf8(slice).ok())
            .unwrap_or("")
    };
    let target = state_codec::VideoTarget {
        window_id,
        display_id: has_display.then_some(display_id),
        title: text(title),
        app_name: text(app_name),
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&state_codec::encode_video_target(&target), out, cap) }
}
