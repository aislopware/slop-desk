//! The inspector CLIENT's store rules, in C.
//!
//! The rules are `slopdesk_workspace::inspector_store`; what is here is the marshalling. The
//! `inspector` module in this crate is the other end of the same feature and shares nothing with
//! it: that one is the daemon's FRAME, this one is the fold the read-only client applies to what
//! the frame delivered. The door prefixes are `slopdesk_inspector_` and `slopdesk_inspector_store_`
//! for exactly that reason.
//!
//! ## No identity crosses
//!
//! An agent id is a string the near side's map is keyed by, and the join that resolves a parent id
//! to an agent stays there: a parent crosses as the POSITION of the agent it names, or as one of
//! the two refusals. What does cross is the id BYTES, and only because a level is ordered by them
//! — `slopdesk_ws_search_rank`'s shape, where text crosses so that the answer can name the caller's
//! own rows.
//!
//! ## The tree answers a flat pre-order list
//!
//! A nested answer would mean an allocation per node crossing the boundary, which `docs/55`'s cost
//! table is unambiguous about. Instead the door answers one `(position, parent_slot)` record per
//! rendered agent, parents before children, and the near side rebuilds the nesting by walking that
//! list BACKWARDS — a mechanical transcription, with the deciding all on this side.

use core::ffi::c_uchar;

use slopdesk_workspace::inspector_store::{
    AgentEntry, has_renderable_activity, ring_ceiling, ring_overflow, subagent_tree,
};

use crate::{borrow, spill};

/// One agent, as the tree door reads it.
///
/// The id is a span into the blob lent alongside this array, never a pointer: no record here makes
/// the caller own a lifetime, which is the arena convention the rest of this crate keeps.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskInspectorStoreAgent {
    /// Where this agent's id starts in the id blob.
    pub id_offset: u32,
    /// How many bytes long it is. `0` — and any span that does not fit — is the empty id, which
    /// renders nothing.
    pub id_length: u32,
    /// The POSITION of this agent's parent in the same array, `-1` for a top-level agent, and `-2`
    /// for a parent id that names no agent.
    pub parent: i32,
}

/// One row of the answer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskInspectorStoreSlot {
    /// Which entry of the caller's array this row draws.
    pub position: u32,
    /// The SLOT in this same answer holding this row's parent, or `-1` for a root.
    pub parent_slot: i32,
}

/// The count above which the ring `kind` names evicts, or `0` for a kind this build cannot name.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_inspector_store_cap(kind: u8) -> usize {
    ring_ceiling(kind)
}

/// How many oldest entries the ring `kind` names evicts at `count`.
///
/// `0` until the ceiling is passed, and `0` for a kind this build cannot name — which is the answer
/// that cannot lose anything.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_inspector_store_overflow(kind: u8, count: usize) -> usize {
    ring_overflow(kind, count)
}

/// Whether anything user-visible has been folded in yet — the empty-state placeholder's gate.
///
/// `has_subagent_tree` is the TREE's emptiness, never the raw map's, so one malformed agent cannot
/// suppress the placeholder while rendering nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_inspector_store_has_activity(
    has_tool_cards: bool,
    has_todos: bool,
    has_subagent_tree: bool,
    has_thinking: bool,
    unknown_line_count: u64,
) -> bool {
    has_renderable_activity(
        has_tool_cards,
        has_todos,
        has_subagent_tree,
        has_thinking,
        unknown_line_count,
    )
}

/// The agent tree as a PRE-ORDER list of `(position, parent_slot)` rows, roots first, each level
/// ordered by id.
///
/// Answers the number of rows NEEDED — `docs/55` §4 — so a caller that lent too little is told what
/// to lend. The answer is never longer than `entries_len`, so a caller that sizes its buffer from
/// the list it already holds never travels the retry path.
///
/// # Safety
/// `(ids, ids_len)` and `(entries, entries_len)` must be readable for the call, and `out` either
/// null or writable for `cap` records for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and all three pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_inspector_store_subagent_tree(
    ids: *const c_uchar,
    ids_len: usize,
    entries: *const SlopDeskInspectorStoreAgent,
    entries_len: usize,
    out: *mut SlopDeskInspectorStoreSlot,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; both borrows die with this call.
    let (blob, lent) = unsafe { (borrow(ids, ids_len), borrow(entries, entries_len)) };
    let rows: Vec<AgentEntry> = lent
        .iter()
        .map(|agent| {
            AgentEntry {
                id_offset: agent.id_offset,
                id_length: agent.id_length,
                parent: agent.parent,
            }
        })
        .collect();
    let answer: Vec<SlopDeskInspectorStoreSlot> = subagent_tree(blob, &rows)
        .into_iter()
        .map(|slot| {
            SlopDeskInspectorStoreSlot {
                position: slot.position,
                parent_slot: slot.parent_slot,
            }
        })
        .collect();
    // SAFETY: `out` is the caller's, writable for `cap` records by the obligation above.
    unsafe { spill(&answer, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary the way Swift does IS what these tests are for"
)]
mod tests {
    use slopdesk_workspace::inspector_store::{DANGLING, ROOT, Ring};

    use super::{
        SlopDeskInspectorStoreAgent, SlopDeskInspectorStoreSlot, slopdesk_inspector_store_cap,
        slopdesk_inspector_store_has_activity, slopdesk_inspector_store_overflow,
        slopdesk_inspector_store_subagent_tree,
    };

    /// A blob of ids and the records naming them, from `(id, parent)` pairs.
    fn corpus(rows: &[(&str, i32)]) -> (Vec<u8>, Vec<SlopDeskInspectorStoreAgent>) {
        let mut ids: Vec<u8> = Vec::new();
        let mut entries: Vec<SlopDeskInspectorStoreAgent> = Vec::new();
        for (id, parent) in rows {
            let offset = u32::try_from(ids.len()).unwrap_or(u32::MAX);
            ids.extend_from_slice(id.as_bytes());
            entries.push(SlopDeskInspectorStoreAgent {
                id_offset: offset,
                id_length: u32::try_from(id.len()).unwrap_or(u32::MAX),
                parent: *parent,
            });
        }
        (ids, entries)
    }

    /// The door run the way the Swift face runs it: one buffer sized from the caller's own list.
    fn tree(rows: &[(&str, i32)]) -> Vec<(u32, i32)> {
        let (ids, entries) = corpus(rows);
        let mut room = vec![SlopDeskInspectorStoreSlot::default(); entries.len()];
        // SAFETY: all three borrows live for the call, and `room` holds `entries.len()` records.
        let needed = unsafe {
            slopdesk_inspector_store_subagent_tree(
                ids.as_ptr(),
                ids.len(),
                entries.as_ptr(),
                entries.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert!(
            needed <= room.len(),
            "the answer never outgrows the list it came from"
        );
        room.truncate(needed);
        room.into_iter()
            .map(|slot| (slot.position, slot.parent_slot))
            .collect()
    }

    #[test]
    fn the_tree_crosses_pre_order_with_each_level_ordered_by_id() {
        assert!(tree(&[]).is_empty());
        assert_eq!(tree(&[("c", ROOT), ("a", ROOT), ("b", ROOT)]), [
            (1, -1),
            (2, -1),
            (0, -1)
        ]);
        assert_eq!(tree(&[("a", ROOT), ("b", 0), ("c", ROOT)]), [
            (0, -1),
            (1, 0),
            (2, -1)
        ]);
    }

    #[test]
    fn the_three_kinds_of_unreachable_agent_render_nowhere() {
        assert!(
            tree(&[("", ROOT), ("child", 0)]).is_empty(),
            "an empty id takes its children with it",
        );
        assert_eq!(tree(&[("orphan", DANGLING), ("root", ROOT)]), [(1, -1)]);
        assert_eq!(tree(&[("loop", 0), ("root", ROOT)]), [(1, -1)]);
    }

    #[test]
    fn null_pointers_read_as_an_empty_tree_rather_than_a_trap() {
        // SAFETY: null with zero lengths is the documented empty input, and `borrow` answers an
        // empty slice for it.
        let needed = unsafe {
            slopdesk_inspector_store_subagent_tree(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0);
    }

    #[test]
    fn a_short_buffer_writes_nothing_and_reports_what_it_needed() {
        let (ids, entries) = corpus(&[("a", ROOT), ("b", ROOT), ("c", ROOT)]);
        let mut room = [SlopDeskInspectorStoreSlot::default(); 1];
        // SAFETY: every borrow lives for the call; the buffer is deliberately too small.
        let needed = unsafe {
            slopdesk_inspector_store_subagent_tree(
                ids.as_ptr(),
                ids.len(),
                entries.as_ptr(),
                entries.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert_eq!(needed, 3, "a short lend is told what to lend");
        assert_eq!(
            room,
            [SlopDeskInspectorStoreSlot::default()],
            "and nothing was written"
        );
    }

    #[test]
    fn a_null_output_is_the_length_probe() {
        let (ids, entries) = corpus(&[("a", ROOT), ("b", 0)]);
        // SAFETY: the two inputs live for the call; a null output is §4's documented probe.
        let needed = unsafe {
            slopdesk_inspector_store_subagent_tree(
                ids.as_ptr(),
                ids.len(),
                entries.as_ptr(),
                entries.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 2);
    }

    #[test]
    fn every_ring_crosses_and_an_unnamed_kind_refuses() {
        for ring in Ring::ALL {
            assert_eq!(slopdesk_inspector_store_cap(ring.code()), ring.ceiling());
            assert_eq!(slopdesk_inspector_store_overflow(ring.code(), 0), 0);
            assert_eq!(slopdesk_inspector_store_overflow(ring.code(), ring.ceiling()), 0);
            let over = ring.ceiling().saturating_add(1);
            assert_eq!(
                over - slopdesk_inspector_store_overflow(ring.code(), over),
                ring.retained(),
            );
        }
        let unnamed = u8::try_from(Ring::ALL.len()).unwrap_or(u8::MAX);
        assert_eq!(slopdesk_inspector_store_cap(unnamed), 0);
        assert_eq!(slopdesk_inspector_store_overflow(unnamed, 1_000_000), 0);
    }

    #[test]
    fn the_empty_state_gate_crosses_whole() {
        assert!(!slopdesk_inspector_store_has_activity(
            false, false, false, false, 0
        ));
        assert!(slopdesk_inspector_store_has_activity(
            true, false, false, false, 0
        ));
        assert!(slopdesk_inspector_store_has_activity(
            false, true, false, false, 0
        ));
        assert!(slopdesk_inspector_store_has_activity(
            false, false, true, false, 0
        ));
        assert!(slopdesk_inspector_store_has_activity(
            false, false, false, true, 0
        ));
        assert!(slopdesk_inspector_store_has_activity(
            false, false, false, false, 1
        ));
    }
}
