//! A session template becoming a tab, and a tab becoming one back, in C.
//!
//! The rules are `slopdesk_workspace::templates::{expand, capture}`; what is here is the
//! marshalling.
//!
//! ## Two streams, and why neither could be the template stream
//!
//! The layout GOING IN is the template stream `slopdesk_ws_template_repair` already speaks, read
//! back through the same reader — a second reader for one grammar is the drift this crate exists to
//! avoid, and the layout crossing here is the same layout that one repairs.
//!
//! What comes BACK cannot be that stream: an expansion carries three things a template does not —
//! an identity on every node, a share on every seam, and a launch ORDER. And what goes in for a
//! CAPTURE is not that stream either: a live tab carries specs that may be MISSING, which a
//! template's leaf cannot express. So each direction has its own grammar, written down once in
//! `rust/slopdesk-ffi/include/slopdesk_ffi.h` and once here, and the Swift face is written against
//! the header paragraph rather than against this file — a codec whose only proof is its own round
//! trip agrees with itself however both halves are wrong.
//!
//! ```text
//! text      := u32 BE length, then that many UTF-8 bytes
//! opt-text  := u8 present (0 or 1), then text when present
//! uuid      := 16 bytes, canonical UUID order
//! weight    := u8 is_fixed, then u64 BE of the f64's raw bit pattern
//!
//! expanded  := 0x00 uuid:pane u8:kind text:title opt-text:cwd opt-text:command
//!            | 0x01 uuid:split u8:axis u32:child_count (weight expanded) × child_count
//!
//! captured  := 0x00 u8:has_spec [u8:kind text:title when has_spec]
//!            | 0x01 u8:axis u32:child_count captured × child_count
//! ```
//!
//! A weight rides as its raw BIT PATTERN, never a re-parsed decimal — the repo's bit-exact float
//! rule, and the same nine bytes `slopdesk_ws_encode_weights` already uses for a divider drag.
//!
//! ## Why `has_spec` is a byte and not a blank title
//!
//! A leaf whose session has no spec for it is a document that has lost track of one of its own
//! panes, and it captures as an unnamed terminal. A leaf whose spec title is BLANK is a pane the
//! user never named, and it captures verbatim. Collapsing them would silently rename every blank
//! pane on the way through — `docs/55` §4b's rule, at the one place in this file where the two
//! readings differ.

use core::ffi::c_uchar;

use slopdesk_tree::session::PaneKind;
use slopdesk_tree::split_tree::{SplitAxis, SplitNode, SplitWeight};
use slopdesk_wire::bytes::{ByteReader, ByteWriter};
use slopdesk_workspace::templates::{
    self, CapturedNode, CapturedPane, Expansion, TemplateNode, TemplatePane,
};

use crate::workspace::{MintedPool, Uuid};
use crate::workspace_templates::{decode_layout, put_node};
use crate::{borrow, deliver, saturating_u32};

/// A leaf node's tag, in both grammars above.
const TAG_PANE: u8 = 0;
/// A partition node's tag, in both grammars above.
const TAG_SPLIT: u8 = 1;

/// The deepest nesting the CAPTURE reader will build.
///
/// The same bound, for the same reason, that `workspace_templates`' reader carries: a post-decode
/// cap cannot protect the walk that produced its input, so the reader holds its own. It is a bound
/// on STACK rather than a rule about layouts — nothing on the far side may branch on it, which is
/// why no door exports it and why the two modules each state it rather than sharing a constant that
/// would look like a contract.
const MAX_STREAM_DEPTH: usize = 512;

// MARK: Writing the expansion

/// Appends a `u32`-length-prefixed string.
fn put_text(out: &mut ByteWriter<'_>, text: &str) {
    out.put_u32(saturating_u32(text.len()));
    out.put_bytes(text.as_bytes());
}

/// Appends a presence byte, and the string behind it when there is one.
fn put_optional_text(out: &mut ByteWriter<'_>, text: Option<&str>) {
    match text {
        Some(present) => {
            out.put_u8(1);
            put_text(out, present);
        },
        None => out.put_u8(0),
    }
}

/// Appends one child's share: a kind byte, then the raw bits of its magnitude.
fn put_weight(out: &mut ByteWriter<'_>, weight: SplitWeight) {
    let (is_fixed, value) = match weight {
        SplitWeight::Flex(value) => (0, value),
        SplitWeight::Fixed(value) => (1, value),
    };
    out.put_u8(is_fixed);
    out.put_u64(value.to_bits());
}

/// Appends one expanded node and everything under it, pre-order.
///
/// Recursive, and safely so: every node this writes came out of `templates::expand`, whose input
/// went through the layout reader's own depth bound on the way in.
fn put_expanded(out: &mut ByteWriter<'_>, node: &SplitNode, launches: &[templates::ExpandedPane]) {
    match *node {
        SplitNode::Leaf(id) => {
            out.put_u8(TAG_PANE);
            out.put_bytes(&id.bytes());
            // The launch list is the leaves in the same pre-order this walk takes, so the pane for
            // this leaf is the one that carries its id. A leaf with no entry cannot happen — both
            // come out of one walk — and answers a blank terminal rather than dropping the leaf,
            // which would change the SHAPE the caller is about to build.
            let fallback = TemplatePane::new(templates::FALLBACK_PANE_TITLE);
            let pane = launches
                .iter()
                .find(|launch| launch.id == id)
                .map_or(&fallback, |launch| &launch.pane);
            out.put_u8(pane.kind.as_byte());
            put_text(out, &pane.title);
            put_optional_text(out, pane.cwd.as_deref());
            put_optional_text(out, pane.command.as_deref());
        },
        SplitNode::Split {
            id,
            axis,
            ref children,
        } => {
            out.put_u8(TAG_SPLIT);
            out.put_bytes(&id.bytes());
            out.put_u8(axis.as_byte());
            out.put_u32(saturating_u32(children.len()));
            for child in children {
                put_weight(out, child.weight);
                put_expanded(out, &child.node, launches);
            }
        },
    }
}

/// One whole expansion, as the stream above.
fn encode_expansion(expansion: &Expansion) -> Vec<u8> {
    let mut writer = ByteWriter::new();
    put_expanded(&mut writer, &expansion.root, &expansion.launches);
    writer.into_vec()
}

// MARK: Reading a captured tab

/// Reads one `u32`-prefixed string, or `None` for a length that leaves the buffer or bytes that are
/// not UTF-8.
fn read_text(reader: &mut ByteReader<'_>) -> Option<String> {
    let len = usize::try_from(reader.read_u32().ok()?).ok()?;
    let bytes = reader.read_bytes(len).ok()?;
    Some(core::str::from_utf8(bytes).ok()?.to_owned())
}

/// Reads a leaf's presence byte and the spec behind it.
///
/// The kind byte is TOTAL — an unknown one reads as a terminal, the degradation the whole codebase
/// picked — while a presence byte that is neither `0` nor `1` is a SHAPE disagreement and refuses
/// the stream. Guessing there would let a desynchronised buffer read as a valid tab.
#[expect(
    clippy::option_option,
    reason = "the outer Option is the stream's verdict and the inner is the leaf's spec — the distinction \
              this reader exists to preserve"
)]
fn read_spec(reader: &mut ByteReader<'_>) -> Option<Option<CapturedPane>> {
    match reader.read_u8().ok()? {
        0 => Some(None),
        1 => {
            let kind = PaneKind::from_byte(reader.read_u8().ok()?);
            let title = read_text(reader)?;
            Some(Some(CapturedPane { kind, title }))
        },
        _ => None,
    }
}

/// A split that has been opened and is still collecting the children the stream promised it.
#[derive(Debug)]
struct OpenSplit {
    axis: SplitAxis,
    remaining: usize,
    children: Vec<CapturedNode>,
}

/// One whole captured tab, or `None` for a stream this reader could not consume exactly.
///
/// Iterative, with an explicit frame stack, so a deeply nested stream is a REFUSAL rather than a
/// stack overflow — the same shape `state_codec`'s decoder took and for the same reason: a depth
/// cap checked before descending is correct and is one forgotten check away from being fatal.
fn decode_captured(bytes: &[u8]) -> Option<CapturedNode> {
    let mut reader = ByteReader::new(bytes);
    let mut stack: Vec<OpenSplit> = Vec::new();
    loop {
        let mut node = match reader.read_u8().ok()? {
            TAG_PANE => CapturedNode::Pane(read_spec(&mut reader)?),
            TAG_SPLIT => {
                let axis = SplitAxis::from_byte(reader.read_u8().ok()?);
                let remaining = usize::try_from(reader.read_u32().ok()?).ok()?;
                if remaining > 0 {
                    if stack.len() >= MAX_STREAM_DEPTH {
                        return None;
                    }
                    stack.push(OpenSplit {
                        axis,
                        remaining,
                        children: Vec::new(),
                    });
                    continue;
                }
                // A childless split cannot come off a live tab. It is kept rather than refused
                // because the crate's own repair is what decides what an empty layout becomes, and
                // deciding it here would be this shim holding an opinion.
                CapturedNode::Split {
                    axis,
                    children: Vec::new(),
                }
            },
            _ => return None,
        };
        loop {
            let Some(top) = stack.last_mut() else {
                // A trailing byte is refused rather than ignored: two encoders that disagree about
                // a field's width would otherwise still agree on every shallow input.
                return (reader.bytes_remaining() == 0).then_some(node);
            };
            top.children.push(node);
            top.remaining -= 1;
            if top.remaining > 0 {
                break;
            }
            let done = stack.pop()?;
            node = CapturedNode::Split {
                axis: done.axis,
                children: done.children,
            };
        }
    }
}

// MARK: The doors

/// How many identities [`slopdesk_ws_template_expand`] will spend on this layout.
///
/// A pool one short does not fail — it REPEATS an identity, and two panes born with one id surface
/// days later as a pane that will not close. So the arithmetic lives in the crate that spends the
/// ids and a caller asks, exactly as `slopdesk_ws_normalize_minted_ids` is asked.
///
/// `0` means the layout stream was refused, which is also the one input for which expanding is not
/// worth attempting.
///
/// # Safety
/// `layout` must be null or point to `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(layout, len)` is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_template_minted_ids(layout: *const c_uchar, len: usize) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let bytes = unsafe { borrow(layout, len) };
    decode_layout(bytes).map_or(0, |node| templates::minted_ids_for_template(&node))
}

/// A template layout, expanded into the tab it describes: fresh ids, equal shares, leaves in launch
/// order.
///
/// `minted` is the caller's pool of pre-minted identities, sized by
/// [`slopdesk_ws_template_minted_ids`] and spent in the walk's own order — one cursor, so a leaf
/// and the seam above it never share an entry. A pool that runs dry repeats its last entry rather
/// than trapping: a refusal the caller can see in the tree beats a process that is gone.
///
/// Answers the `expanded` stream at the top of this module. `0` is the layout-stream refusal and
/// nothing else — every layout that decodes expands, and the shortest expansion is a lone leaf.
///
/// # Safety
/// `layout` must be null or point to `len` live bytes for the call; `minted` null or naming
/// `minted_count` live entries; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer here is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_template_expand(
    layout: *const c_uchar,
    len: usize,
    minted: *const Uuid,
    minted_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, forwarded unchanged.
    let (bytes, ids) = unsafe { (borrow(layout, len), borrow(minted, minted_count)) };
    let Some(node) = decode_layout(bytes) else {
        return 0;
    };
    let mut pool = MintedPool { ids, next: 0 };
    let expansion = templates::expand(&node, &mut pool);
    // SAFETY: the caller's buffer obligation, forwarded unchanged.
    unsafe { deliver(&encode_expansion(&expansion), out, cap) }
}

/// A live tab's geometry as a reusable template layout.
///
/// `has_tab` is `false` when the session has NO active tab, and `(tab, len)` is then not read: the
/// crate answers a single default terminal pane, because a template that expanded to nothing could
/// not be opened again. It is a flag rather than a zero length because an empty stream is a stream
/// that failed to encode, which is a different report.
///
/// Answers the layout in the TEMPLATE stream — the one `slopdesk_ws_template_repair` speaks — so
/// the far side already has a reader for it. `0` means the `captured` stream was refused.
///
/// # Safety
/// `tab` must be null or point to `len` live bytes for the call; `out` null or writable for `cap`
/// bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer here is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_template_capture(
    tab: *const c_uchar,
    len: usize,
    has_tab: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let bytes = unsafe { borrow(tab, len) };
    let captured = if has_tab {
        let Some(node) = decode_captured(bytes) else {
            return 0;
        };
        Some(node)
    } else {
        None
    };
    let layout: TemplateNode = templates::capture(captured.as_ref());
    let mut writer = ByteWriter::new();
    put_node(&mut writer, &layout);
    // SAFETY: the caller's buffer obligation, forwarded unchanged.
    unsafe { deliver(&writer.into_vec(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_tree::session::PaneKind;
    use slopdesk_tree::split_tree::SplitAxis;
    use slopdesk_wire::bytes::ByteWriter;
    use slopdesk_workspace::templates::{TemplateNode, TemplatePane};

    use super::{
        MAX_STREAM_DEPTH, TAG_PANE, TAG_SPLIT, Uuid, decode_captured, put_text, slopdesk_ws_template_capture,
        slopdesk_ws_template_expand, slopdesk_ws_template_minted_ids,
    };
    use crate::workspace_templates::{decode_layout, put_node};

    fn encoded(node: &TemplateNode) -> Vec<u8> {
        let mut writer = ByteWriter::new();
        put_node(&mut writer, node);
        writer.into_vec()
    }

    /// A pool of distinct identities, the way the Swift face brings one.
    fn pool(count: usize) -> Vec<Uuid> {
        (0..count)
            .map(|index| {
                Uuid {
                    bytes: [u8::try_from(index % 256).unwrap_or_default(); 16],
                }
            })
            .collect()
    }

    /// One `captured` leaf, with or without a spec.
    fn captured_leaf(spec: Option<(PaneKind, &str)>) -> Vec<u8> {
        let mut writer = ByteWriter::new();
        writer.put_u8(TAG_PANE);
        match spec {
            Some((kind, title)) => {
                writer.put_u8(1);
                writer.put_u8(kind.as_byte());
                put_text(&mut writer, title);
            },
            None => writer.put_u8(0),
        }
        writer.into_vec()
    }

    /// The expand door under §4's size-then-read protocol.
    fn expand(layout: &[u8], ids: &[Uuid]) -> Vec<u8> {
        // SAFETY: the null probe §4 describes, over live locals.
        let needed = unsafe {
            slopdesk_ws_template_expand(
                layout.as_ptr(),
                layout.len(),
                ids.as_ptr(),
                ids.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        if needed == 0 {
            return Vec::new();
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes, and both inputs are live locals.
        let written = unsafe {
            slopdesk_ws_template_expand(
                layout.as_ptr(),
                layout.len(),
                ids.as_ptr(),
                ids.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed);
        out
    }

    /// The capture door under the same protocol, answered as a decoded layout.
    fn capture(tab: &[u8], has_tab: bool) -> Option<TemplateNode> {
        // SAFETY: the null probe §4 describes, over a live local.
        let needed = unsafe {
            slopdesk_ws_template_capture(tab.as_ptr(), tab.len(), has_tab, core::ptr::null_mut(), 0)
        };
        if needed == 0 {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes, and `tab` is a live local.
        let written = unsafe {
            slopdesk_ws_template_capture(tab.as_ptr(), tab.len(), has_tab, out.as_mut_ptr(), out.len())
        };
        assert_eq!(written, needed);
        decode_layout(&out)
    }

    /// The stream, spelled out rather than round-tripped: a round trip agrees with itself however
    /// both halves are wrong, and the Swift reader is written against the header paragraph.
    #[test]
    fn a_lone_leaf_expands_to_the_bytes_the_header_promises() {
        let layout = encoded(&TemplateNode::Pane(TemplatePane::new("Editor")));
        let ids = pool(1);
        let stream = expand(&layout, &ids);

        let mut expected = vec![TAG_PANE];
        expected.extend_from_slice(&[0_u8; 16]);
        expected.push(PaneKind::Terminal.as_byte());
        expected.extend_from_slice(&6_u32.to_be_bytes());
        expected.extend_from_slice(b"Editor");
        expected.push(0); // no cwd
        expected.push(0); // no command
        assert_eq!(stream, expected);
    }

    /// A seam carries its identity, its axis, its child count and a share per child — and the share
    /// is the raw bit pattern of `1.0`, never a decimal anyone re-parses.
    #[test]
    fn a_split_carries_a_share_before_every_child() {
        let layout = encoded(&TemplateNode::split(SplitAxis::Vertical, vec![
            TemplateNode::Pane(TemplatePane::new("A")),
            TemplateNode::Pane(TemplatePane::new("B")),
        ]));
        let ids = pool(3);
        let stream = expand(&layout, &ids);

        assert_eq!(stream.first().copied(), Some(TAG_SPLIT));
        let mut share = vec![0_u8]; // flex, not fixed
        share.extend_from_slice(&1.0_f64.to_bits().to_be_bytes());
        let head = 1 + 16 + 1 + 4;
        assert_eq!(
            stream.get(head..head + 9).map(<[u8]>::to_vec),
            Some(share),
            "an equal share, bit for bit"
        );
    }

    /// The pool the caller must bring is the pool the walk spends.
    #[test]
    fn the_sizing_door_answers_what_the_expansion_costs() {
        let layout = encoded(&TemplateNode::split(SplitAxis::Horizontal, vec![
            TemplateNode::Pane(TemplatePane::new("A")),
            TemplateNode::split(SplitAxis::Vertical, vec![
                TemplateNode::Pane(TemplatePane::new("B")),
                TemplateNode::Pane(TemplatePane::new("C")),
            ]),
        ]));
        // SAFETY: `layout` is a live local.
        let needed = unsafe { slopdesk_ws_template_minted_ids(layout.as_ptr(), layout.len()) };
        assert_eq!(needed, 5, "three leaves and two seams");

        // SAFETY: the refusal path, over a stream that is not a layout.
        let refused = unsafe { slopdesk_ws_template_minted_ids([0xFF_u8].as_ptr(), 1) };
        assert_eq!(refused, 0);
    }

    /// A layout stream the reader cannot consume exactly answers `0` on both doors rather than a
    /// tree with a field guessed at.
    #[test]
    fn a_refused_layout_answers_zero_rather_than_an_empty_buffer() {
        let ids = pool(4);
        let mut out = [0xAA_u8; 8];
        // SAFETY: both inputs are live locals.
        let needed = unsafe {
            slopdesk_ws_template_expand(
                [0xFF_u8].as_ptr(),
                1,
                ids.as_ptr(),
                ids.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, 0);
        assert_eq!(out, [0xAA; 8], "nothing was written");
    }

    /// A pool one short repeats rather than trapping — the promise `MintedPool` makes, asserted at
    /// the door that spends it.
    #[test]
    fn a_dry_pool_repeats_rather_than_taking_the_process_with_it() {
        let layout = encoded(&TemplateNode::split(SplitAxis::Horizontal, vec![
            TemplateNode::Pane(TemplatePane::new("A")),
            TemplateNode::Pane(TemplatePane::new("B")),
        ]));
        let stream = expand(&layout, &pool(1));
        assert!(!stream.is_empty(), "a short pool is still an answer");
    }

    #[test]
    fn a_captured_tab_comes_back_as_the_template_stream() {
        let tab = captured_leaf(Some((PaneKind::Terminal, "Solo")));
        assert_eq!(
            capture(&tab, true),
            Some(TemplateNode::Pane(TemplatePane::new("Solo")))
        );
    }

    /// The two absences, kept apart by the flag rather than by a length.
    #[test]
    fn a_missing_spec_and_a_missing_tab_both_capture_a_terminal() {
        assert_eq!(
            capture(&captured_leaf(None), true),
            Some(TemplateNode::Pane(TemplatePane::new("Terminal")))
        );
        assert_eq!(
            capture(&[], false),
            Some(TemplateNode::Pane(TemplatePane::new("Terminal"))),
            "no active tab still captures a layout, and does not read the buffer"
        );
    }

    /// A blank spec title is a pane the user never named, and survives whole.
    #[test]
    fn a_blank_title_is_captured_and_not_repaired() {
        assert_eq!(
            capture(&captured_leaf(Some((PaneKind::Desktop, ""))), true),
            Some(TemplateNode::Pane(TemplatePane {
                kind: PaneKind::Desktop,
                title: String::new(),
                cwd: None,
                command: None,
            }))
        );
    }

    #[test]
    fn a_captured_stream_the_reader_cannot_consume_exactly_is_refused() {
        assert_eq!(capture(&[0xFF], true), None, "an unknown tag");
        assert_eq!(capture(&[TAG_PANE], true), None, "a truncated presence byte");
        let mut trailing = captured_leaf(Some((PaneKind::Terminal, "A")));
        trailing.push(0);
        assert_eq!(capture(&trailing, true), None, "a trailing byte");
        let mut short_split = vec![TAG_SPLIT, SplitAxis::Horizontal.as_byte()];
        short_split.extend_from_slice(&9_u32.to_be_bytes());
        assert_eq!(
            capture(&short_split, true),
            None,
            "a split claiming more children than it carries"
        );
    }

    /// The reader's own bound, asserted where it matters: a stream deeper than any layout could be
    /// is a refusal, not a stack overflow.
    #[test]
    fn a_stream_nested_past_the_readers_bound_is_refused() {
        let mut deep = ByteWriter::new();
        for _ in 0..=MAX_STREAM_DEPTH {
            deep.put_u8(TAG_SPLIT);
            deep.put_u8(SplitAxis::Horizontal.as_byte());
            deep.put_u32(1);
        }
        deep.put_u8(TAG_PANE);
        deep.put_u8(0);
        assert_eq!(decode_captured(&deep.into_vec()), None);
    }
}
