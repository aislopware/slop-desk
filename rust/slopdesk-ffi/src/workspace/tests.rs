//! Every door in this module's children, exercised against the shapes `super` declares.
//!
//! They stayed in ONE file when the module became a directory: a test here names the flat
//! shapes and the fixtures (`id`, `rect`, `leaf`, `span`) far more often than it names the
//! child it is aimed at, and splitting them would have copied that fixture set five ways.
#![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#![expect(
    clippy::float_cmp,
    reason = "exact is the assertion: `CLAUDE.md` pins these results bit-exactly, so a tolerance here would \
              pass on the drift it exists to catch"
)]
#![expect(
    clippy::expect_used,
    reason = "a door that refuses its own fixture IS the report"
)]

use core::ffi::c_uchar;

use slopdesk_ids::{PaneId, SplitNodeId};
use slopdesk_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

use super::codec::{CVideoTarget, slopdesk_ws_decode_video_target, slopdesk_ws_encode_video_target};
use super::file::{
    slopdesk_ws_default_desktop_pane_title, slopdesk_ws_default_pane_title, slopdesk_ws_normalize,
    slopdesk_ws_normalize_minted_ids, slopdesk_ws_normalize_pass_count, slopdesk_ws_pane_kind_count,
    slopdesk_ws_pane_kind_is_video, slopdesk_ws_workspace_file_decode, slopdesk_ws_workspace_file_encode,
    slopdesk_ws_workspace_file_is_default_shape, slopdesk_ws_workspace_file_minted_ids,
    slopdesk_ws_workspace_file_status,
};
use super::panes::{slopdesk_ws_cwd_badge_path, slopdesk_ws_send_keys};
use super::rows::{
    slopdesk_ws_focus_cycle, slopdesk_ws_focus_neighbor, slopdesk_ws_project_key, slopdesk_ws_section_header,
    slopdesk_ws_section_precedes, slopdesk_ws_successor_after_close,
};
use super::tree::{
    DividerHandle, TreeNode, decode_tree, encode_tree, slopdesk_ws_divider_can_move,
    slopdesk_ws_divider_clamped_weight, slopdesk_ws_divider_percents, slopdesk_ws_divider_thickness,
    slopdesk_ws_divider_weight_delta, slopdesk_ws_dividers, slopdesk_ws_max_depth,
    slopdesk_ws_max_string_bytes, slopdesk_ws_min_weight, slopdesk_ws_schema_version,
    slopdesk_ws_solve_layout, slopdesk_ws_tree_removing, slopdesk_ws_tree_splitting,
};
use super::{CRect, Frame, KeyedTab, Span, Uuid};

const fn id(byte: u8) -> Uuid {
    Uuid { bytes: [byte; 16] }
}

const fn rect(x: f64, y: f64, width: f64, height: f64) -> CRect {
    CRect { x, y, width, height }
}

const fn leaf(byte: u8) -> TreeNode {
    TreeNode {
        kind: 0,
        id: id(byte),
        axis: 0,
        weight_is_fixed: false,
        child_count: 0,
        weight: 1.0,
    }
}

const fn span(offset: usize, len: usize) -> Span {
    Span {
        offset,
        len,
        present: true,
    }
}

const NO_KEY: Span = Span {
    offset: 0,
    len: 0,
    present: false,
};

fn transform(call: impl Fn(*const u8, usize, *mut u8, usize) -> usize, text: &str) -> String {
    let input = text.as_bytes();
    let mut out = vec![0_u8; 256];
    let needed = call(input.as_ptr(), input.len(), out.as_mut_ptr(), out.len());
    assert!(needed <= out.len(), "the test buffer is generous by design");
    String::from_utf8(out.get(..needed).unwrap_or_default().to_vec()).unwrap_or_default()
}

#[test]
fn a_control_token_reaches_the_pty_as_its_bytes() {
    let encoded = transform(
        |bytes, len, out, cap| unsafe { slopdesk_ws_send_keys(bytes, len, out, cap) },
        "a<Esc>b",
    );
    assert_eq!(encoded.as_bytes(), b"a\x1Bb");
}

#[test]
fn a_buffer_that_does_not_fit_is_left_untouched() {
    let input = b"hello world";
    let mut out = [0_u8; 4];
    let needed = unsafe { slopdesk_ws_send_keys(input.as_ptr(), input.len(), out.as_mut_ptr(), out.len()) };
    assert_eq!(needed, input.len());
    assert_eq!(out, [0; 4], "nothing is written when the answer does not fit");
}

#[test]
fn focus_moves_by_what_is_on_screen() {
    let frames = [
        Frame {
            id: id(1),
            rect: rect(0.0, 0.0, 100.0, 100.0),
        },
        Frame {
            id: id(2),
            rect: rect(100.0, 0.0, 100.0, 100.0),
        },
    ];
    let mut answer = id(0);
    // 1 is Right in the shared discriminant order.
    let moved =
        unsafe { slopdesk_ws_focus_neighbor(frames.as_ptr(), frames.len(), id(1), 1, &raw mut answer) };
    assert!(moved);
    assert_eq!(answer, id(2));
    // 0 is Left, and there is nothing to the left of the leftmost pane.
    assert!(!unsafe { slopdesk_ws_focus_neighbor(frames.as_ptr(), frames.len(), id(1), 0, &raw mut answer) });
}

#[test]
fn cycling_wraps_and_refuses_a_pane_it_does_not_hold() {
    let panes = [id(1), id(2), id(3)];
    let mut answer = id(0);
    assert!(unsafe { slopdesk_ws_focus_cycle(panes.as_ptr(), panes.len(), id(3), true, &raw mut answer) });
    assert_eq!(answer, id(1), "forward from the last wraps to the first");
    assert!(!unsafe { slopdesk_ws_focus_cycle(panes.as_ptr(), panes.len(), id(9), true, &raw mut answer) });
}

#[test]
fn a_blank_project_key_is_absent_rather_than_empty() {
    // The trailing slash folds, which is what keeps a pane's directory and its git toplevel
    // from becoming two identically-titled sections.
    let key = transform(
        |bytes, len, out, cap| unsafe { slopdesk_ws_project_key(bytes, len, true, out, cap) },
        "  /Users/me/slop-desk/  ",
    );
    assert_eq!(key, "/Users/me/slop-desk");
    let blank = transform(
        |bytes, len, out, cap| unsafe { slopdesk_ws_project_key(bytes, len, true, out, cap) },
        "   ",
    );
    assert!(blank.is_empty(), "a blank key folds to absent, which is 0 bytes");
    assert_eq!(
        unsafe { slopdesk_ws_project_key(core::ptr::null(), 0, false, core::ptr::null_mut(), 0) },
        0
    );
}

#[test]
fn the_badge_door_carries_the_collapse_and_the_directory_marker_across() {
    let badge = |text| {
        transform(
            |bytes, len, out, cap| unsafe { slopdesk_ws_cwd_badge_path(bytes, len, out, cap) },
            text,
        )
    };
    assert_eq!(badge("/Users/me/slop-desk"), "~/slop-desk/");
    assert_eq!(badge("/etc"), "/etc/");
    assert!(
        badge("").is_empty(),
        "an empty path has an empty badge, not a slash"
    );
}

#[test]
fn a_short_badge_buffer_is_told_the_length_it_should_have_lent() {
    let path = b"/Users/me/slop-desk";
    let needed = unsafe { slopdesk_ws_cwd_badge_path(path.as_ptr(), path.len(), core::ptr::null_mut(), 0) };
    assert_eq!(needed, "~/slop-desk/".len());
    let mut cramped = [0_u8; 4];
    assert_eq!(
        unsafe { slopdesk_ws_cwd_badge_path(path.as_ptr(), path.len(), cramped.as_mut_ptr(), cramped.len()) },
        needed,
        "the answer is the length NEEDED, and nothing is written",
    );
    assert_eq!(cramped, [0; 4]);
}

#[test]
fn the_keyless_section_sorts_last_however_it_is_spelled() {
    assert_eq!(
        transform(
            |bytes, len, out, cap| unsafe { slopdesk_ws_section_header(bytes, len, false, out, cap) },
            "",
        ),
        "Other"
    );
    let alpha = b"alpha";
    assert!(unsafe {
        slopdesk_ws_section_precedes(alpha.as_ptr(), alpha.len(), true, core::ptr::null(), 0, false)
    });
    assert!(!unsafe {
        slopdesk_ws_section_precedes(core::ptr::null(), 0, false, alpha.as_ptr(), alpha.len(), true)
    });
}

#[test]
fn closing_a_tab_returns_focus_to_the_one_it_was_opened_from() {
    let blob = b"alpha";
    let tabs = [
        KeyedTab {
            id: id(1),
            key: span(0, 5),
        },
        KeyedTab {
            id: id(2),
            key: span(0, 5),
        },
        KeyedTab {
            id: id(3),
            key: NO_KEY,
        },
    ];
    let history = [id(2), id(1)];
    let mut answer = id(0);
    let found = unsafe {
        slopdesk_ws_successor_after_close(
            id(2),
            tabs.as_ptr(),
            tabs.len(),
            blob.as_ptr(),
            blob.len(),
            history.as_ptr(),
            history.len(),
            &raw mut answer,
        )
    };
    assert!(found);
    assert_eq!(answer, id(1), "the most recent SURVIVOR, not the closing tab");
}

#[test]
fn with_no_history_focus_stays_inside_the_project_section() {
    let blob = b"alpha";
    let tabs = [
        KeyedTab {
            id: id(1),
            key: span(0, 5),
        },
        KeyedTab {
            id: id(2),
            key: NO_KEY,
        },
        KeyedTab {
            id: id(3),
            key: span(0, 5),
        },
    ];
    let mut answer = id(0);
    assert!(unsafe {
        slopdesk_ws_successor_after_close(
            id(1),
            tabs.as_ptr(),
            tabs.len(),
            blob.as_ptr(),
            blob.len(),
            core::ptr::null(),
            0,
            &raw mut answer,
        )
    });
    assert_eq!(
        answer,
        id(3),
        "the sibling in the same section, skipping the keyless tab"
    );
}

#[test]
fn a_span_pointing_off_the_end_reads_as_no_key_rather_than_trapping() {
    let blob = b"alpha";
    let tabs = [
        KeyedTab {
            id: id(1),
            key: span(4, usize::MAX),
        },
        KeyedTab {
            id: id(2),
            key: span(900, 5),
        },
    ];
    let mut answer = id(0);
    assert!(unsafe {
        slopdesk_ws_successor_after_close(
            id(1),
            tabs.as_ptr(),
            tabs.len(),
            blob.as_ptr(),
            blob.len(),
            core::ptr::null(),
            0,
            &raw mut answer,
        )
    });
    assert_eq!(answer, id(2));
}

#[test]
fn a_pre_order_walk_tiles_the_bound_it_was_given() {
    // A horizontal split of two equal leaves: [split(2), leaf, leaf].
    let nodes = [
        TreeNode {
            kind: 1,
            id: id(9),
            axis: 0,
            weight_is_fixed: false,
            child_count: 2,
            weight: 1.0,
        },
        leaf(1),
        leaf(2),
    ];
    let mut out = [Frame {
        id: id(0),
        rect: rect(0.0, 0.0, 0.0, 0.0),
    }; 4];
    let count = unsafe {
        slopdesk_ws_solve_layout(
            nodes.as_ptr(),
            nodes.len(),
            rect(0.0, 0.0, 400.0, 200.0),
            10.0,
            10.0,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(count, 2);
    let widths: Vec<f64> = out.iter().take(2).map(|frame| frame.rect.width).collect();
    assert_eq!(widths, vec![200.0, 200.0], "columns halve the width exactly");
    assert!(out.iter().take(2).all(|frame| frame.rect.height == 200.0));
}

#[test]
fn the_same_walk_answers_the_seams_between_those_tiles() {
    let nodes = [
        TreeNode {
            kind: 1,
            id: id(9),
            axis: 0,
            weight_is_fixed: false,
            child_count: 2,
            weight: 1.0,
        },
        leaf(1),
        leaf(2),
    ];
    let bound = rect(0.0, 0.0, 400.0, 200.0);
    let needed =
        unsafe { slopdesk_ws_dividers(nodes.as_ptr(), nodes.len(), bound, 16.0, core::ptr::null_mut(), 0) };
    assert_eq!(needed, 1, "two columns share one seam");
    let mut out = [DividerHandle {
        split: id(0),
        child_index: 0,
        axis: 0,
        rect: rect(0.0, 0.0, 0.0, 0.0),
        parent_span: 0.0,
        flex_sum: 0.0,
        leading_weight: 0.0,
        trailing_weight: 0.0,
    }; 2];
    let written = unsafe {
        slopdesk_ws_dividers(
            nodes.as_ptr(),
            nodes.len(),
            bound,
            16.0,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(written, 1);
    let seam = out[0];
    assert_eq!(seam.split, id(9), "the seam names the split that owns it");
    assert_eq!(seam.axis, 0);
    assert_eq!(seam.rect.x, 200.0 - 8.0, "the band is centred on the cut");
    assert_eq!(seam.rect.width, 16.0);
    assert_eq!(seam.parent_span, 400.0);
    assert_eq!((seam.leading_weight, seam.trailing_weight), (1.0, 1.0));
    assert!(slopdesk_ws_divider_can_move(seam, true));
    assert!(slopdesk_ws_divider_can_move(seam, false));
    // Span 400 at a flex sum of 2: the 160 pt column floor is weight 0.8, either side.
    assert_eq!(slopdesk_ws_divider_clamped_weight(seam, 0.0), 0.8);
    assert_eq!(slopdesk_ws_divider_clamped_weight(seam, 9.0), 1.2);
    assert_eq!(slopdesk_ws_divider_thickness(), 16.0);
    // The drag reads the seam's OWN span and flex sum out of the handle it was given: 120 px
    // over 400 pt at a flex sum of 2 is 0.6 of weight, which renders as 120 pt of movement.
    assert_eq!(slopdesk_ws_divider_weight_delta(seam, 120.0), 0.6);

    let (mut lead, mut trail) = (0, 0);
    // SAFETY: two live local u32s, borrowed for the duration of the call.
    let readable = unsafe { slopdesk_ws_divider_percents(seam, &raw mut lead, &raw mut trail) };
    assert!(readable);
    assert_eq!((lead, trail), (50, 50));

    let fixed_side = DividerHandle {
        leading_weight: 0.0,
        ..seam
    };
    // SAFETY: the same two locals, still live.
    let absent = unsafe { slopdesk_ws_divider_percents(fixed_side, &raw mut lead, &raw mut trail) };
    assert!(!absent, "a fixed side has no ratio to read");
    assert_eq!((lead, trail), (50, 50), "a refusal writes nothing");
}

#[test]
fn a_walk_that_claims_more_children_than_it_carries_is_refused() {
    for hostile in [
        // A split promising three children with none behind it.
        vec![TreeNode {
            kind: 1,
            id: id(9),
            axis: 0,
            weight_is_fixed: false,
            child_count: 3,
            weight: 1.0,
        }],
        // …and one promising more than the array could ever hold.
        vec![
            TreeNode {
                kind: 1,
                id: id(9),
                axis: 1,
                weight_is_fixed: false,
                child_count: u32::MAX,
                weight: 1.0,
            },
            leaf(1),
        ],
        Vec::new(),
    ] {
        let count = unsafe {
            slopdesk_ws_solve_layout(
                hostile.as_ptr(),
                hostile.len(),
                rect(0.0, 0.0, 400.0, 200.0),
                10.0,
                10.0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(count, 0, "a tree that cannot be rebuilt draws nothing");
    }
}

/// The round trip is the whole safety of the tree ops: every one of them reads a walk and
/// writes one, so a leg that lost a weight or reordered a child would corrupt an arrangement
/// silently.
#[test]
fn a_tree_survives_the_walk_out_and_back() {
    let tree = SplitNode::Split {
        id: SplitNodeId::from_bytes([9; 16]),
        axis: SplitAxis::Vertical,
        children: vec![
            WeightedChild::new(
                SplitWeight::Fixed(120.0),
                SplitNode::Leaf(PaneId::from_bytes([1; 16])),
            ),
            WeightedChild::new(
                SplitWeight::Flex(3.0),
                SplitNode::Leaf(PaneId::from_bytes([2; 16])),
            ),
        ],
    };
    let mut walk = Vec::new();
    encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
    let mut cursor = 0;
    let rebuilt = decode_tree(&walk, &mut cursor);
    assert_eq!(cursor, walk.len(), "the walk is consumed exactly");
    assert_eq!(rebuilt, Some(tree), "out and back is the identity");
}

/// "This pane is not here" and "this was the last pane" are DIFFERENT answers: the first has to
/// leave the arrangement alone, where treating it as the second would close the tab.
#[test]
fn a_stranger_is_not_the_last_pane() {
    let tree = SplitNode::Leaf(PaneId::from_bytes([1; 16]));
    let mut walk = Vec::new();
    encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
    let mut out = [leaf(0); 8];
    // SAFETY: both pointers are to live arrays of the lengths given.
    let stranger =
        unsafe { slopdesk_ws_tree_removing(walk.as_ptr(), walk.len(), id(7), out.as_mut_ptr(), out.len()) };
    assert_eq!(
        stranger, 1,
        "a pane that is not here removes nothing — the tree stands"
    );
    // SAFETY: as above.
    let last =
        unsafe { slopdesk_ws_tree_removing(walk.as_ptr(), walk.len(), id(1), out.as_mut_ptr(), out.len()) };
    assert_eq!(
        last,
        usize::MAX,
        "removing the last leaf leaves no tree, which is not an empty one"
    );
}

/// A split mints nothing of its own — the identity it is given is the identity it wears, which
/// is what lets a replay reproduce a layout byte for byte.
#[test]
fn a_split_wears_the_identity_it_was_handed() {
    let tree = SplitNode::Leaf(PaneId::from_bytes([1; 16]));
    let mut walk = Vec::new();
    encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
    let mut out = [leaf(0); 8];
    // SAFETY: both pointers are to live arrays of the lengths given.
    let count = unsafe {
        slopdesk_ws_tree_splitting(
            walk.as_ptr(),
            walk.len(),
            Uuid { bytes: [1; 16] },
            1,
            Uuid { bytes: [2; 16] },
            false,
            Uuid { bytes: [42; 16] },
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(count, 3, "a root leaf split in two is a split over two leaves");
    let walked: Vec<(u8, [u8; 16])> = out
        .iter()
        .take(count)
        .map(|node| (node.kind, node.id.bytes))
        .collect();
    assert_eq!(
        walked,
        vec![(1, [42; 16]), (0, [1; 16]), (0, [2; 16])],
        "the split wears the id it was handed, and the target keeps the leading side"
    );
}

/// The span leg is pointer arithmetic, so it is worth proving the offsets land on the strings
/// they name rather than merely being in range — an off-by-one here would read a plausible
/// window title out of the neighbouring field.
#[test]
fn a_video_target_s_spans_point_at_its_own_strings() {
    let blob = b"GhosttyTerminal";
    let title = Span {
        offset: 7,
        len: 8,
        present: true,
    };
    let app = Span {
        offset: 0,
        len: 7,
        present: true,
    };
    let mut bytes = [0_u8; 64];
    // SAFETY: both buffers are live locals, and the spans sit inside `blob`.
    let written = unsafe {
        slopdesk_ws_encode_video_target(
            42,
            0,
            true,
            blob.as_ptr(),
            blob.len(),
            title,
            app,
            bytes.as_mut_ptr(),
            bytes.len(),
        )
    };
    let mut answer = CVideoTarget {
        window_id: 0,
        display_id: 9,
        has_display: false,
        title: Span {
            offset: 0,
            len: 0,
            present: false,
        },
        app_name: Span {
            offset: 0,
            len: 0,
            present: false,
        },
    };
    // SAFETY: `bytes` is live for the call and `answer` is a live local.
    let ok = unsafe { slopdesk_ws_decode_video_target(bytes.as_ptr(), written, &raw mut answer) };
    assert!(ok, "the value this call just encoded must decode");
    assert_eq!(answer.window_id, 42);
    assert!(answer.has_display, "display 0 is a display");
    assert_eq!(answer.display_id, 0);
    let text = |span: Span| {
        String::from_utf8_lossy(bytes.get(span.offset..span.offset + span.len).unwrap_or(&[])).into_owned()
    };
    assert_eq!(text(answer.title), "Terminal");
    assert_eq!(text(answer.app_name), "Ghostty");
}

// ---------------------------------------------------------------------------------------- //
// The repair pass
// ---------------------------------------------------------------------------------------- //

/// A document's cells in the flat `(CEntry, blob)` form the door takes — the encoding under
/// test as much as anything else.
fn flat_document(
    topology: &slopdesk_wire::document::topology::WorkspaceTopology,
) -> (Vec<super::CEntry>, Vec<u8>) {
    let mut blob = Vec::new();
    let cells = slopdesk_wire::document::state::HostWorkspaceState::from_entries(topology.entries())
        .sorted_entries()
        .into_iter()
        .map(|entry| {
            let offset = blob.len();
            blob.extend_from_slice(&entry.value);
            super::CEntry {
                kind: entry.key.kind,
                field: entry.key.field,
                object: Uuid {
                    bytes: entry.key.object_id,
                },
                value: Span {
                    offset,
                    len: blob.len() - offset,
                    present: true,
                },
            }
        })
        .collect();
    (cells, blob)
}

/// One repair through the C signature, sized the way §4 says to: probe, grow, call again.
fn normalize(
    pass: u8,
    cells: &[super::CEntry],
    blob: &[u8],
    pool: &[Uuid],
) -> Option<slopdesk_wire::document::topology::WorkspaceTopology> {
    // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
    // with.
    let needed = unsafe {
        slopdesk_ws_normalize(
            pass,
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            pool.as_ptr(),
            pool.len(),
            core::ptr::null_mut(),
            0,
        )
    };
    if needed == 0 {
        return None;
    }
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
    let written = unsafe {
        slopdesk_ws_normalize(
            pass,
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            pool.as_ptr(),
            pool.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(written, needed, "the sized call disagreed with the probe");
    let state = slopdesk_wire::document::codec::decode_snapshot(&out).ok()?;
    state.topology()
}

fn pool() -> Vec<Uuid> {
    (0..slopdesk_ws_normalize_minted_ids(4, 4))
        .map(|index| {
            Uuid {
                bytes: [0xB0_u8.wrapping_add(u8::try_from(index).unwrap_or(0)); 16],
            }
        })
        .collect()
}

#[test]
fn a_repair_answers_the_documents_own_encoding_and_nothing_else() {
    let broken = slopdesk_wire::document::topology::WorkspaceTopology::new(
        slopdesk_tree::workspace::TreeWorkspace::single_pane(
            slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
            slopdesk_ids::identity::TabId::from_bytes([1; 16]),
            PaneId::from_bytes([1; 16]),
            slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
        ),
    );
    let (cells, blob) = flat_document(&broken);
    let repaired = normalize(2, &cells, &blob, &pool()).expect("a repaired document");
    assert_eq!(repaired.tree.all_pane_ids(), vec![PaneId::from_bytes([1; 16])]);
    assert!(repaired.tree.invariant_holds());
}

#[test]
fn a_pass_byte_this_build_does_not_know_is_a_refusal_rather_than_a_different_repair() {
    // The one 0 this door answers. Every real pass answers a workspace — even over a document
    // with none in it, which is re-seeded rather than refused — so the refusal cannot be
    // mistaken for a repair that came back empty.
    let empty: Vec<super::CEntry> = Vec::new();
    assert!(normalize(200, &empty, &[], &pool()).is_none());
    let re_seeded = normalize(2, &empty, &[], &pool()).expect("an empty document is re-seeded");
    assert_eq!(re_seeded.tree.sessions.len(), 1);
    assert_eq!(re_seeded.tree.all_pane_ids().len(), 1);
}

#[test]
fn a_probe_that_did_not_fit_leaves_the_buffer_untouched() {
    let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
        slopdesk_tree::workspace::TreeWorkspace::single_pane(
            slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
            slopdesk_ids::identity::TabId::from_bytes([1; 16]),
            PaneId::from_bytes([1; 16]),
            slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
        ),
    );
    let (cells, blob) = flat_document(&topology);
    let ids = pool();
    let mut out = [0_u8; 8];
    // SAFETY: every pointer is a live local's; `out` is deliberately too small.
    let needed = unsafe {
        slopdesk_ws_normalize(
            2,
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            ids.as_ptr(),
            ids.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert!(needed > out.len());
    assert!(out.iter().all(|byte| *byte == 0), "a short call still wrote");
}

#[test]
fn the_video_predicate_covers_the_whole_kind_vocabulary() {
    // Walked rather than named: a third kind added to the crate makes this loop ask about a
    // byte no caller has a case for, which is exactly the drift docs/55 §8 records. A byte past
    // the vocabulary reads as a terminal, so an unknown kind degrades rather than opening a
    // stream for a window that will never exist.
    let count = slopdesk_ws_pane_kind_count();
    assert_eq!(count, slopdesk_tree::PaneKind::ALL.len());
    for (index, kind) in slopdesk_tree::PaneKind::ALL.into_iter().enumerate() {
        let byte = u8::try_from(index).unwrap_or(u8::MAX);
        assert_eq!(slopdesk_ws_pane_kind_is_video(byte), kind.is_video());
    }
    assert!(!slopdesk_ws_pane_kind_is_video(200));
}

#[test]
fn the_exported_pass_count_and_pool_size_are_the_crates_own() {
    assert_eq!(
        slopdesk_ws_normalize_pass_count(),
        slopdesk_tree::tree_ops::RepairPass::ALL.len(),
    );
    assert_eq!(
        slopdesk_ws_normalize_minted_ids(3, 5),
        slopdesk_tree::tree_ops::RepairPass::minted_ids(3, 5),
    );
}

#[test]
fn the_two_split_tree_metrics_are_the_crates_own() {
    assert_eq!(slopdesk_ws_min_weight(), slopdesk_tree::split_tree::MIN_WEIGHT);
    assert_eq!(slopdesk_ws_max_depth(), slopdesk_tree::split_tree::MAX_DEPTH);
}

#[test]
fn the_exported_schema_version_is_the_crates_own() {
    assert_eq!(
        slopdesk_ws_schema_version(),
        slopdesk_tree::CURRENT_SCHEMA_VERSION
    );
}

#[test]
fn the_exported_string_bound_is_the_codecs_own() {
    assert_eq!(
        slopdesk_ws_max_string_bytes(),
        slopdesk_workspace::state_codec::MAX_STRING_BYTES
    );
}

// ---------------------------------------------------------------------------------------- //
// The client's workspace file
// ---------------------------------------------------------------------------------------- //

/// One save through the C signature, sized the way §4 says to: probe, grow, call again.
fn file_encode(cells: &[super::CEntry], blob: &[u8]) -> Vec<u8> {
    // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
    // with.
    let needed = unsafe {
        slopdesk_ws_workspace_file_encode(
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            slopdesk_tree::CURRENT_SCHEMA_VERSION,
            core::ptr::null_mut(),
            0,
        )
    };
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
    let written = unsafe {
        slopdesk_ws_workspace_file_encode(
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            slopdesk_tree::CURRENT_SCHEMA_VERSION,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(written, needed, "the sized call disagreed with the probe");
    out
}

/// One load through the C signature, with the pool the door itself sized, answering everything
/// the door writes: the status byte, the claimed version, and the workspace if there is one.
fn file_decode(
    bytes: &[u8],
    seed: u8,
) -> (
    c_uchar,
    i64,
    Option<slopdesk_wire::document::topology::WorkspaceTopology>,
) {
    // SAFETY: `bytes` is a live local's.
    let ids: Vec<Uuid> = (0..unsafe { slopdesk_ws_workspace_file_minted_ids(bytes.as_ptr(), bytes.len()) })
        .map(|index| {
            Uuid {
                bytes: [seed.wrapping_add(u8::try_from(index).unwrap_or(0)); 16],
            }
        })
        .collect();
    let (mut status, mut version) = (u8::MAX, i64::MIN);
    // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
    // with.
    let needed = unsafe {
        slopdesk_ws_workspace_file_decode(
            bytes.as_ptr(),
            bytes.len(),
            ids.as_ptr(),
            ids.len(),
            &raw mut status,
            &raw mut version,
            core::ptr::null_mut(),
            0,
        )
    };
    if needed == 0 {
        return (status, version, None);
    }
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is now exactly `needed` bytes and every input pointer is still live.
    let written = unsafe {
        slopdesk_ws_workspace_file_decode(
            bytes.as_ptr(),
            bytes.len(),
            ids.as_ptr(),
            ids.len(),
            &raw mut status,
            &raw mut version,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert_eq!(written, needed, "the sized call disagreed with the probe");
    let state = slopdesk_wire::document::codec::decode_snapshot(&out).ok();
    (status, version, state.and_then(|read| read.topology()))
}

/// A file naming a split the writer never named — the case the whole port turns on.
const UNNAMED_SPLIT_FILE: &str = r#"{
  "schemaVersion": 12,
  "sessions": [
    {
      "id": { "raw": "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A" },
      "name": "work",
      "activeTabIndex": 0,
      "tabs": [
        {
          "id": { "raw": "0B0B0B0B-0B0B-0B0B-0B0B-0B0B0B0B0B0B" },
          "title": "",
          "root": { "split": {
            "axis": "horizontal",
            "children": [
              { "node": { "leaf": { "raw": "01010101-0101-0101-0101-010101010101" } } },
              { "node": { "leaf": { "raw": "02020202-0202-0202-0202-020202020202" } } }
            ]
          } }
        }
      ],
      "specs": [
        { "pane": { "raw": "01010101-0101-0101-0101-010101010101" },
          "spec": { "kind": "terminal", "title": "one" } },
        { "pane": { "raw": "02020202-0202-0202-0202-020202020202" },
          "spec": { "kind": "terminal", "title": "two" } }
      ]
    }
  ]
}"#;

/// Every divider group in a tree, in visual order.
fn seams(node: &SplitNode) -> Vec<SplitNodeId> {
    match *node {
        SplitNode::Leaf(_) => Vec::new(),
        SplitNode::Split { id, ref children, .. } => {
            core::iter::once(id)
                .chain(children.iter().flat_map(|child| seams(&child.node)))
                .collect()
        },
    }
}

fn tree_seams(topology: &slopdesk_wire::document::topology::WorkspaceTopology) -> Vec<SplitNodeId> {
    topology
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter().flat_map(|tab| seams(&tab.root)))
        .collect()
}

#[test]
fn a_saved_workspace_comes_back_the_same_arrangement_through_the_two_doors() {
    let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
        slopdesk_tree::workspace::TreeWorkspace::single_pane(
            slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
            slopdesk_ids::identity::TabId::from_bytes([1; 16]),
            PaneId::from_bytes([9; 16]),
            slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
        ),
    );
    let (cells, blob) = flat_document(&topology);
    let saved = file_encode(&cells, &blob);
    assert!(
        core::str::from_utf8(&saved).is_ok_and(|text| text.ends_with('\n')),
        "the file is text, and text on this project's disks ends in a newline",
    );
    let (status, _, loaded) = file_decode(&saved, 0xC0);
    let read = loaded.expect("a file this build wrote is a file this build reads");
    assert_eq!(status, slopdesk_ws_workspace_file_status(0));
    assert_eq!(read.tree.sessions.len(), 1);
    assert_eq!(read.tree.all_pane_ids(), vec![PaneId::from_bytes([9; 16])]);
    assert_eq!(
        read.tree.sessions.first().map(|session| session.name.clone()),
        topology.tree.sessions.first().map(|session| session.name.clone()),
    );
}

/// **The defect the port exists to close, pinned at the boundary Swift crosses.** Two loads of
/// one file, from two DIFFERENT identity pools, still name the seam the same thing — so the
/// `splitNode/<id>/weight` cell a person's drag wrote before a relaunch still points at their
/// divider after it. Swift's `?? SplitNodeID()` minted a fresh uuid here and lost every one.
#[test]
fn two_loads_of_one_file_name_its_dividers_the_same_way() {
    let bytes = UNNAMED_SPLIT_FILE.as_bytes();
    let first = file_decode(bytes, 0x10)
        .2
        .expect("the first load answers a workspace");
    let second = file_decode(bytes, 0x90)
        .2
        .expect("the second load answers one too");
    assert!(!tree_seams(&first).is_empty(), "the fixture has a divider in it");
    assert_eq!(
        tree_seams(&first),
        tree_seams(&second),
        "a divider's name is a function of the file, not of the pool the load was handed",
    );
    assert_eq!(
        first.tree.all_pane_ids(),
        second.tree.all_pane_ids(),
        "a pane the file named keeps that name — the pool pays only for the ones it did not",
    );
}

#[test]
fn a_version_this_build_does_not_speak_is_refused_by_a_byte_that_names_the_version() {
    let text = UNNAMED_SPLIT_FILE.replace("\"schemaVersion\": 12", "\"schemaVersion\": 99");
    let (status, version, loaded) = file_decode(text.as_bytes(), 0x10);
    assert!(loaded.is_none(), "a file this build cannot read answers nothing");
    assert_eq!(status, slopdesk_ws_workspace_file_status(2));
    assert_eq!(
        version, 99,
        "a caller that cannot log the version it was handed cannot tell the person anything",
    );
}

#[test]
fn a_refusal_that_is_not_about_a_version_leaves_the_version_alone() {
    // Every `i64` is a version somebody could have typed, so there is no byte pattern that
    // means "not about a version" — the door's answer is to write nothing at all.
    let (status, version, loaded) = file_decode(b"not a workspace", 0x10);
    assert!(loaded.is_none());
    assert_eq!(status, slopdesk_ws_workspace_file_status(1));
    assert_eq!(version, i64::MIN, "the untouched local");
}

#[test]
fn a_null_out_still_answers_the_status_and_the_size() {
    let bytes = UNNAMED_SPLIT_FILE.as_bytes();
    // SAFETY: `bytes` is a live local's.
    let count = unsafe { slopdesk_ws_workspace_file_minted_ids(bytes.as_ptr(), bytes.len()) };
    let ids = vec![Uuid { bytes: [7; 16] }; count];
    let mut status = u8::MAX;
    // SAFETY: the null `out` and `version` §4 says a verdict-only caller may pass.
    let needed = unsafe {
        slopdesk_ws_workspace_file_decode(
            bytes.as_ptr(),
            bytes.len(),
            ids.as_ptr(),
            ids.len(),
            &raw mut status,
            core::ptr::null_mut(),
            core::ptr::null_mut(),
            0,
        )
    };
    assert!(needed > 0);
    assert_eq!(status, slopdesk_ws_workspace_file_status(0));
}

/// The shape door reads the seed names off the crate, so this asks it about a file the crate
/// itself wrote — a literal here would be the second spelling the door exists to delete.
#[test]
fn the_shape_door_recognises_the_file_a_new_window_launch_autosaves() {
    let default =
        slopdesk_workspace::persist::encode_file(&slopdesk_tree::workspace::TreeWorkspace::single_pane(
            slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
            slopdesk_ids::identity::TabId::from_bytes([2; 16]),
            PaneId::from_bytes([3; 16]),
            slopdesk_tree::session::PaneSpec::new(
                slopdesk_tree::session::PaneKind::Terminal,
                slopdesk_tree::workspace::DEFAULT_PANE_TITLE,
            ),
        ));
    // SAFETY: both are live locals'.
    let (throwaway, kept) = unsafe {
        (
            slopdesk_ws_workspace_file_is_default_shape(default.as_ptr(), default.len()),
            slopdesk_ws_workspace_file_is_default_shape(
                UNNAMED_SPLIT_FILE.as_ptr(),
                UNNAMED_SPLIT_FILE.len(),
            ),
        )
    };
    assert!(throwaway, "the re-seed's own output is the throwaway");
    assert!(!kept, "a file with a split in it is a layout somebody made");
    // SAFETY: a live local's, and the null probe §4 admits everywhere.
    let unreadable = unsafe {
        (
            slopdesk_ws_workspace_file_is_default_shape(b"not a workspace".as_ptr(), 15),
            slopdesk_ws_workspace_file_is_default_shape(core::ptr::null(), 0),
        )
    };
    assert_eq!(
        unreadable,
        (false, false),
        "false is `not provably the default`, so an unreadable file is preserved aside",
    );
}

#[test]
fn a_save_that_did_not_fit_leaves_the_buffer_untouched() {
    let topology = slopdesk_wire::document::topology::WorkspaceTopology::new(
        slopdesk_tree::workspace::TreeWorkspace::single_pane(
            slopdesk_ids::identity::SessionId::from_bytes([1; 16]),
            slopdesk_ids::identity::TabId::from_bytes([1; 16]),
            PaneId::from_bytes([1; 16]),
            slopdesk_tree::PaneSpec::new(slopdesk_tree::PaneKind::Terminal, "Terminal"),
        ),
    );
    let (cells, blob) = flat_document(&topology);
    let mut out = [0_u8; 8];
    // SAFETY: every pointer is a live local's; `out` is deliberately too small.
    let needed = unsafe {
        slopdesk_ws_workspace_file_encode(
            cells.as_ptr(),
            cells.len(),
            blob.as_ptr(),
            blob.len(),
            slopdesk_tree::CURRENT_SCHEMA_VERSION,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    assert!(needed > out.len());
    assert!(out.iter().all(|byte| *byte == 0), "a short call still wrote");
}

#[test]
fn a_document_with_no_workspace_in_it_is_still_written_as_a_file() {
    // The save path cannot answer "nothing" — a client that had no arrangement to write still
    // has to leave a file the next launch can read. Reading that file back is not a refusal
    // either: an empty session list is a well-formed file, and the repair seeds the one session
    // and one pane a launch needs, from the pool the door sized.
    let empty: Vec<super::CEntry> = Vec::new();
    let saved = file_encode(&empty, &[]);
    assert!(
        !saved.is_empty(),
        "a save answers a file or the disk keeps the old one"
    );
    let (status, _, loaded) = file_decode(&saved, 0x40);
    let read = loaded.expect("an empty file loads as a re-seeded desk rather than nothing");
    assert_eq!(status, slopdesk_ws_workspace_file_status(0));
    assert_eq!(read.tree.sessions.len(), 1);
    assert_eq!(read.tree.all_pane_ids().len(), 1);
}

#[test]
fn a_save_writes_the_version_it_was_handed_rather_than_the_one_this_build_reads() {
    // The cells carry a shape and no version, so a tree rebuilt from them wears whatever
    // `TreeWorkspace::new` stamps. If the door read THAT instead of its parameter, every save
    // would silently promote a file to the current schema — and the load path's version check,
    // the one thing that can refuse a file this build does not understand, would never fire
    // again, because nothing on disk could still claim an older number.
    let stale = slopdesk_tree::CURRENT_SCHEMA_VERSION - 1;
    let empty: Vec<super::CEntry> = Vec::new();
    // SAFETY: every pointer is a live local's, and the null `out` is what §4 says to probe
    // with.
    let needed = unsafe {
        slopdesk_ws_workspace_file_encode(
            empty.as_ptr(),
            0,
            core::ptr::null(),
            0,
            stale,
            core::ptr::null_mut(),
            0,
        )
    };
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is now exactly `needed` bytes and the inputs are still the same live
    // locals.
    unsafe {
        slopdesk_ws_workspace_file_encode(
            empty.as_ptr(),
            0,
            core::ptr::null(),
            0,
            stale,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    let text = String::from_utf8(out).expect("the file is UTF-8 JSON");
    assert!(
        text.contains(&format!("\"schemaVersion\" : {stale}")),
        "the save re-stamped the version instead of writing the caller's: {text}"
    );
    // And the round trip agrees it is a file from another schema: the decode reports the claim
    // it read back, which is the half of the contract the save side only makes possible.
    let (status, claimed, _) = file_decode(text.as_bytes(), 0x50);
    assert_ne!(status, slopdesk_ws_workspace_file_status(0));
    assert_eq!(claimed, stale);
}

#[test]
fn the_pool_is_asked_of_the_file_rather_than_guessed_from_its_shape() {
    for text in ["", "{}", UNNAMED_SPLIT_FILE] {
        // SAFETY: `text` is a live local's.
        let asked = unsafe { slopdesk_ws_workspace_file_minted_ids(text.as_ptr(), text.len()) };
        assert_eq!(
            asked,
            slopdesk_workspace::minted_ids_for(text.as_bytes()),
            "{text:?}"
        );
    }
}

#[test]
fn the_exported_status_order_is_the_one_the_door_answers() {
    // Walked rather than transcribed: a caller with its own `case malformed = 1` beside this is
    // a second copy of the numbering, and the arm it drifts on is the one that decides whether
    // a file this build cannot read is kept aside or written over.
    let codes = [
        slopdesk_ws_workspace_file_status(0),
        slopdesk_ws_workspace_file_status(1),
        slopdesk_ws_workspace_file_status(2),
        slopdesk_ws_workspace_file_status(3),
    ];
    let distinct: std::collections::BTreeSet<c_uchar> = codes.iter().copied().collect();
    assert_eq!(distinct.len(), codes.len(), "two outcomes cannot share a byte");
    assert_eq!(codes.first().copied(), Some(slopdesk_workspace::NO_REFUSAL));
    assert_eq!(
        codes.get(1).copied(),
        Some(slopdesk_workspace::FileError::Malformed.code())
    );
    assert_eq!(
        slopdesk_ws_workspace_file_status(200),
        slopdesk_workspace::FileError::Malformed.code(),
        "an index past the last refuses rather than admits",
    );
}

#[test]
fn the_default_strings_come_back_whole_under_the_size_then_read_protocol() {
    // SAFETY: the null probe §4 describes.
    let needed = unsafe { slopdesk_ws_default_pane_title(core::ptr::null_mut(), 0) };
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is exactly `needed` bytes.
    let written = unsafe { slopdesk_ws_default_pane_title(out.as_mut_ptr(), out.len()) };
    assert_eq!(written, needed);
    assert_eq!(
        core::str::from_utf8(&out).ok(),
        Some(slopdesk_tree::workspace::DEFAULT_PANE_TITLE),
    );
}

/// The third seeded name crosses the same way, and it is not the terminal one.
///
/// The inequality is the load-bearing half: this door exists because the client mints desktop
/// panes and the wire crate mints them too, so a door that quietly answered the terminal title
/// would make every restored desktop pane come back named "Terminal" with nothing failing.
#[test]
fn the_desktop_title_crosses_whole_and_is_its_own_word() {
    // SAFETY: the null probe §4 describes.
    let needed = unsafe { slopdesk_ws_default_desktop_pane_title(core::ptr::null_mut(), 0) };
    let mut out = vec![0_u8; needed];
    // SAFETY: `out` is exactly `needed` bytes.
    let written = unsafe { slopdesk_ws_default_desktop_pane_title(out.as_mut_ptr(), out.len()) };
    assert_eq!(written, needed);
    assert_eq!(
        core::str::from_utf8(&out).ok(),
        Some(slopdesk_tree::workspace::DEFAULT_DESKTOP_PANE_TITLE),
    );
    assert_ne!(
        slopdesk_tree::workspace::DEFAULT_DESKTOP_PANE_TITLE,
        slopdesk_tree::workspace::DEFAULT_PANE_TITLE,
    );
}
