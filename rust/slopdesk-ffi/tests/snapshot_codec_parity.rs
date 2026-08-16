//! The two snapshot codecs are the same format, and nothing said so until this file.
//!
//! `slopdesk_workspace::state_codec` encodes BORROWED entries in the order the caller hands them —
//! it is the zero-copy half, the one the FFI shim reaches from `slopdesk_ws_encode_snapshot`, where
//! the entries are spans into a buffer Swift still owns. `slopdesk_wire::document::codec` encodes
//! an OWNED `HostWorkspaceState`, sorting as it goes, and it is the half the host's document, its
//! diff and its intent applier are written against.
//!
//! They are the same `[u32 count][kind][uuid][field][u32 len][value]` grammar written twice, in two
//! crates, neither depending on the other — the arrow points wire → workspace, and `state_codec` is
//! below the fork. Nothing maps one onto the other, so a byte added to one would not fail to
//! compile anywhere; it would fail at RUNTIME, on a client decoding a host's snapshot, as a
//! document that silently came back wrong.
//!
//! This crate is the only one that depends on both, so this is the only place the question can be
//! asked. It asks it in both directions: identical bytes out, and each side able to read the
//! other's.
//!
//! ## What the parity is CONDITIONAL on, and why the test says it out loud
//!
//! The wire half sorts, the workspace half does not. So they agree exactly when the borrowed
//! entries are already in key order — ascending `kind`, then the objectID bytes, then `field` —
//! which is `WorkspaceKey`'s derived `Ord` and, on the other side, the order Swift's own
//! `WorkspaceStateCodec` emits. The unsorted case is pinned too, as a DIFFERENCE rather than an
//! agreement: it is the one input where the two codecs are allowed to part, and a future change
//! that quietly made `state_codec` sort would be a behaviour change worth noticing here rather
//! than in a diff that stopped churning for reasons nobody could name.

#![expect(
    clippy::expect_used,
    reason = "a codec that refuses its own fixture IS the report"
)]

use slopdesk_wire::document::codec as wire_codec;
use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceEntry, WorkspaceKey};
use slopdesk_workspace::state_codec as ws_codec;

/// A UUID whose bytes are all `seed`, so the fixture's key ORDER is readable from the seed alone.
const fn id(seed: u8) -> [u8; 16] {
    [seed; 16]
}

/// The fixture, deliberately awkward: an empty value, a kind byte no enum arm claims, a field at
/// the top of its range, a value with a zero byte in the middle, and two entries that differ only
/// by field so the sort has something to order.
fn cells() -> Vec<(u8, [u8; 16], u8, Vec<u8>)> {
    vec![
        (0, id(0), 1, b"root display name".to_vec()),
        (2, id(9), 3, Vec::new()),
        (2, id(9), 4, vec![0x00, 0xFF, 0x00]),
        (3, id(1), 2, b"tab".to_vec()),
        (0xEE, id(0x7F), 0xFE, vec![0xAB; 300]),
    ]
}

fn sorted_cells() -> Vec<(u8, [u8; 16], u8, Vec<u8>)> {
    let mut all = cells();
    all.sort_by_key(|left| (left.0, left.1, left.2));
    all
}

fn borrowed(cells: &[(u8, [u8; 16], u8, Vec<u8>)]) -> Vec<ws_codec::Entry<'_>> {
    cells
        .iter()
        .map(|(kind, object, field, value)| {
            ws_codec::Entry {
                kind: *kind,
                object: *object,
                field: *field,
                value: value.as_slice(),
            }
        })
        .collect()
}

fn owned(cells: &[(u8, [u8; 16], u8, Vec<u8>)]) -> HostWorkspaceState {
    HostWorkspaceState::from_entries(
        cells
            .iter()
            .map(|(kind, object, field, value)| {
                WorkspaceEntry::new(
                    WorkspaceKey {
                        kind: *kind,
                        object_id: *object,
                        field: *field,
                    },
                    value.clone(),
                )
            })
            .collect(),
    )
}

#[test]
fn key_ordered_entries_encode_to_identical_bytes() {
    let cells = sorted_cells();
    assert_eq!(
        ws_codec::encode_snapshot(&borrowed(&cells)),
        wire_codec::encode_snapshot(&owned(&cells)),
        "the zero-copy and the owned snapshot codec parted on the same document",
    );
}

#[test]
fn each_codec_reads_what_the_other_wrote() {
    let cells = sorted_cells();
    let from_workspace = ws_codec::encode_snapshot(&borrowed(&cells));
    let from_wire = wire_codec::encode_snapshot(&owned(&cells));

    let state = wire_codec::decode_snapshot(&from_workspace).expect("the wire half reads the zero-copy half");
    assert_eq!(state.sorted_entries(), owned(&cells).sorted_entries());

    let entries = ws_codec::decode_snapshot(&from_wire).expect("the zero-copy half reads the wire half");
    assert_eq!(entries.len(), cells.len());
    for (decoded, (kind, object, field, value)) in entries.iter().zip(&cells) {
        assert_eq!(
            (decoded.kind, decoded.object, decoded.field),
            (*kind, *object, *field)
        );
        assert_eq!(decoded.value, value.as_slice());
    }
}

#[test]
fn an_empty_document_is_the_same_four_bytes_on_both_sides() {
    assert_eq!(
        ws_codec::encode_snapshot(&[]),
        wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(Vec::new())),
    );
}

#[test]
fn the_sort_is_the_condition_and_only_the_condition() {
    // REVERSED, not merely "as authored": `cells()` happens to be in key order already, so handing
    // it over unsorted proves nothing. Reversed, this is the one input the two are allowed to part
    // on — the wire half sorts and the zero-copy half does not. Both still decode to the same SET,
    // which is what makes the difference an ordering one rather than a loss.
    let mut unsorted = sorted_cells();
    unsorted.reverse();
    assert_ne!(
        ws_codec::encode_snapshot(&borrowed(&unsorted)),
        wire_codec::encode_snapshot(&owned(&unsorted)),
        "state_codec has started sorting — parity is no longer conditional, and this test is stale",
    );

    let via_wire =
        wire_codec::decode_snapshot(&wire_codec::encode_snapshot(&owned(&unsorted))).expect("its own bytes");
    let via_workspace = wire_codec::decode_snapshot(&ws_codec::encode_snapshot(&borrowed(&unsorted)))
        .expect("the other's bytes");
    assert_eq!(via_wire.sorted_entries(), via_workspace.sorted_entries());
}
