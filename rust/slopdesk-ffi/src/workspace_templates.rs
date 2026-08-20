//! The two things that SPAWN panes — a session template's layout and the shipped tables —
//! reachable from the Swift that still declares them.
//!
//! ## Why this module exists at all, which is not the usual reason
//!
//! Every other door here was cut so a rule could MOVE: the Swift went away in the same change and
//! the door became the only implementation. This one cannot do that yet. `SessionTemplate` is
//! `Codable` and is the currency of the device-preferences file, so its Swift decoder is what a
//! person's saved layouts actually come back through, and deleting it would delete the store's
//! ability to read its own file. `docs/55` §7 step 6 names exactly that case and says what is owed
//! instead: **if the port could not delete the original, PIN it** — same inputs to both sides,
//! assert the same output. These doors exist so `SessionTemplateRepairDifferentialTests` can do
//! that, and `slopdesk_workspace::templates` — thirteen unit tests and no caller until today —
//! stops being a second copy nobody ever compared.
//!
//! ## The layout crosses as a PRE-ORDER byte stream
//!
//! A [`TemplateNode`] is a pane or a partition among children, so it has no `#[repr(C)]` shape: a
//! flat record array would need a second grammar for "where do this node's children end". It gets
//! the one `slopdesk_ws_solve_layout` already uses for the split tree — the node's own tag first,
//! then its payload, then its children in order — and the encoding is written down ONCE, here, with
//! the encoder and the decoder on both sides written against this paragraph and nothing else.
//!
//! ```text
//! text     := u32 BE length, then that many UTF-8 bytes
//! opt-text := u8 present (0 or 1), then text when present
//! uuid     := 16 bytes, canonical UUID order
//! node     := 0x00 u8:kind text:title opt-text:cwd opt-text:command        -- a pane
//!           | 0x01 u8:axis u32:child_count  node × child_count             -- a split, in visual order
//! template := uuid:id text:name text:symbol u8:is_built_in node:layout
//! preset   := uuid:id text:name text:command opt-text:working_directory
//!             u8:has_split [u8:axis text:secondary_command when has_split]
//!             text:symbol u8:is_built_in
//! table    := u32 BE count, then that many records
//! ```
//!
//! **The lengths are `u32` and not the wire's `u16` on purpose.**
//! `ByteWriter::put_length_prefixed_str` CLAMPS at 64 KiB, which is right for a frame whose length
//! field is a `u16` and wrong here: a title the encoder silently truncated would come back equal to
//! a title the other side truncated the same way, and a differential that agrees because both sides
//! lost the same bytes is worse than no differential.
//!
//! **A present empty string and an absent one are different answers**, which is `docs/55` §4b's
//! presence-flag rule at the granularity of a field. `cwd: Some("")` and `cwd: None` reach
//! `templates::keystrokes` as the same "no directory" — but they are not the same VALUE, and the
//! repair copies the value through untouched, so an encoding that flattened them would make this
//! suite unable to see a repair that started rewriting one into the other.
//!
//! ## The walk is the contract, and a stream that does not fit it is a REFUSAL
//!
//! Nothing here is indexable or seekable: the reader goes forward exactly once and a length that
//! would leave the buffer stops it. A stream the reader cannot consume EXACTLY — truncated, with a
//! trailing byte, with a tag or a presence byte that is neither of its two values — answers `0`,
//! §4's "there is no answer". That is a shape disagreement between two encoders rather than a
//! degenerate template, and the difference matters: a degenerate template has a defined REPAIR and
//! must never be answered with silence, while a stream this side cannot read has no repair because
//! there is no layout to repair. `0` cannot collide with a real answer — the shortest layout there
//! is encodes to seven bytes.

use core::ffi::c_uchar;

use slopdesk_wire::bytes::{ByteReader, ByteWriter};
use slopdesk_workspace::templates::{self, LaunchPreset, SessionTemplate, TemplateNode, TemplatePane};
use slopdesk_workspace::{PaneKind, SplitAxis};

use crate::{borrow, deliver, saturating_u32};

/// A leaf node's tag.
const TAG_PANE: u8 = 0;
/// A partition node's tag.
const TAG_SPLIT: u8 = 1;

/// The deepest nesting the READER will build, as opposed to the deepest the repair will KEEP.
///
/// Two different numbers doing two different jobs, and the same split `slopdesk_workspace::json`
/// makes between its own `MAX_DEPTH` of 64 and the split tree's of 12. The repair is a POST-decode
/// cap: it cannot protect the walk that produces its input, because that walk has already run by
/// the time it sees a tree. So the reader carries its own bound, and it is a bound on stack rather
/// than a rule about layouts — the crate's `repaired()` recurses once per level, and `panic =
/// "abort"` makes an overflow a dead process rather than a caught fault.
///
/// 512 because that is the nesting Foundation's `JSONDecoder` admits before it throws, and a
/// template arrives on the shipping path as JSON that decoder read. A stream deeper than that
/// describes a layout no persisted file could have held, so refusing it costs nothing a person
/// could ever have saved. It is a floor on safety, not a law either side implements, which is why
/// no door exports it: nothing on the far side may branch on this number.
const MAX_STREAM_DEPTH: usize = 512;

// MARK: Writing

/// Appends a `u32`-length-prefixed string.
///
/// A string past `u32::MAX` bytes would have its length saturate while its bytes were written
/// whole — not a template anything could hold, and [`saturating_u32`] is the house answer to a
/// length that cannot be a length.
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

/// Appends one node and everything under it, pre-order.
///
/// Recursive where [`read_node`] is not, and the asymmetry is deliberate: every node this writes
/// is one the crate produced — a `repaired()` answer, bounded by `split_tree::MAX_DEPTH`, or a
/// shipped table three levels deep — while everything the reader is handed came from the other
/// side of a C boundary.
fn put_node(out: &mut ByteWriter<'_>, node: &TemplateNode) {
    match *node {
        TemplateNode::Pane(ref pane) => {
            out.put_u8(TAG_PANE);
            out.put_u8(pane.kind.as_byte());
            put_text(out, &pane.title);
            put_optional_text(out, pane.cwd.as_deref());
            put_optional_text(out, pane.command.as_deref());
        },
        TemplateNode::Split { axis, ref children } => {
            out.put_u8(TAG_SPLIT);
            out.put_u8(axis.as_byte());
            out.put_u32(saturating_u32(children.len()));
            for child in children {
                put_node(out, child);
            }
        },
    }
}

/// Appends one shipped session template.
fn put_template(out: &mut ByteWriter<'_>, template: &SessionTemplate) {
    out.put_bytes(&template.id.bytes());
    put_text(out, &template.name);
    put_text(out, &template.symbol);
    out.put_bool(template.is_built_in);
    put_node(out, &template.layout);
}

/// Appends one shipped launch preset.
fn put_preset(out: &mut ByteWriter<'_>, preset: &LaunchPreset) {
    out.put_bytes(&preset.id.bytes());
    put_text(out, &preset.name);
    put_text(out, &preset.command);
    put_optional_text(out, preset.working_directory.as_deref());
    match preset.split {
        Some(ref split) => {
            out.put_u8(1);
            out.put_u8(split.axis.as_byte());
            put_text(out, &split.secondary_command);
        },
        None => out.put_u8(0),
    }
    put_text(out, &preset.symbol);
    out.put_bool(preset.is_built_in);
}

// MARK: Reading

/// Reads one `u32`-prefixed string, or `None` for a length that leaves the buffer or bytes that are
/// not UTF-8.
fn read_text(reader: &mut ByteReader<'_>) -> Option<String> {
    let len = usize::try_from(reader.read_u32().ok()?).ok()?;
    let bytes = reader.read_bytes(len).ok()?;
    Some(core::str::from_utf8(bytes).ok()?.to_owned())
}

/// Reads a presence byte and the string behind it. A byte that is neither `0` nor `1` is a shape
/// disagreement, not an absent value — guessing would let a corrupt stream read as a valid layout.
///
/// The two `Option`s are two different questions and that is the whole reason this door exists: the
/// OUTER is "did the stream parse", the INNER is "did the field have a value". Collapsing them
/// would make `cwd: Some("")` and a truncated buffer the same answer, which is exactly the
/// absent-versus-empty distinction the module header says the encoding is carrying a byte for.
#[expect(
    clippy::option_option,
    reason = "the outer Option is the stream's verdict and the inner is the field's presence — the \
              distinction this reader exists to preserve"
)]
fn read_optional_text(reader: &mut ByteReader<'_>) -> Option<Option<String>> {
    match reader.read_u8().ok()? {
        0 => Some(None),
        1 => read_text(reader).map(Some),
        _ => None,
    }
}

/// Reads one leaf's payload.
fn read_pane(reader: &mut ByteReader<'_>) -> Option<TemplatePane> {
    // The kind byte is TOTAL on the way in — `PaneKind::from_byte` answers a terminal for anything
    // it does not know — because that is the degradation the whole codebase already picked, and a
    // refusal here would make an unknown kind lose the person's WHOLE layout rather than one
    // pane's kind. It is the one field this reader is deliberately tolerant about.
    let kind = PaneKind::from_byte(reader.read_u8().ok()?);
    let title = read_text(reader)?;
    let cwd = read_optional_text(reader)?;
    let command = read_optional_text(reader)?;
    Some(TemplatePane {
        kind,
        title,
        cwd,
        command,
    })
}

/// A split that has been opened and is still collecting the children the stream promised it.
#[derive(Debug)]
struct OpenSplit {
    /// The axis its tag carried.
    axis: SplitAxis,
    /// How many children it said would follow.
    expected: usize,
    /// The ones read so far, in order.
    children: Vec<TemplateNode>,
}

/// Rebuilds one node and everything under it, iteratively.
///
/// The work stack is on the HEAP rather than in stack frames, so the nesting a hostile stream can
/// reach costs memory instead of a process — and [`MAX_STREAM_DEPTH`] bounds even that, because
/// what comes back is handed straight to a recursive repair.
fn read_node(reader: &mut ByteReader<'_>) -> Option<TemplateNode> {
    let mut open: Vec<OpenSplit> = Vec::new();
    loop {
        let mut node = match reader.read_u8().ok()? {
            TAG_PANE => TemplateNode::Pane(read_pane(reader)?),
            TAG_SPLIT => {
                let axis = SplitAxis::from_byte(reader.read_u8().ok()?);
                let expected = usize::try_from(reader.read_u32().ok()?).ok()?;
                // Every child costs at least its own tag byte, so a count larger than what is left
                // is a truncated or hostile stream rather than a big tree — and refusing it here
                // is what keeps a `0xFFFFFFFF` from being an allocation.
                if expected > reader.bytes_remaining() {
                    return None;
                }
                if expected == 0 {
                    // A childless split never opens: it is complete the moment its tag is read, and
                    // it is exactly the degenerate shape the repair downstream exists to answer.
                    TemplateNode::Split {
                        axis,
                        children: Vec::new(),
                    }
                } else {
                    if open.len() >= MAX_STREAM_DEPTH {
                        return None;
                    }
                    open.push(OpenSplit {
                        axis,
                        expected,
                        children: Vec::new(),
                    });
                    continue;
                }
            },
            _ => return None,
        };
        // Hand the finished node to the innermost split still waiting, closing every split that
        // completes as a result. With nothing waiting, the node IS the answer.
        loop {
            let Some(parent) = open.last_mut() else {
                return Some(node);
            };
            parent.children.push(node);
            if parent.children.len() < parent.expected {
                break;
            }
            let closed = open.pop()?;
            node = TemplateNode::Split {
                axis: closed.axis,
                children: closed.children,
            };
        }
    }
}

/// One whole layout, or `None` for a stream this reader could not consume exactly.
fn decode_layout(bytes: &[u8]) -> Option<TemplateNode> {
    let mut reader = ByteReader::new(bytes);
    let node = read_node(&mut reader)?;
    // A trailing byte is refused rather than ignored. Two encoders that disagree about a field's
    // width would otherwise still agree on every SHALLOW input, which is the exact shape of drift
    // this suite is here to make visible.
    (reader.bytes_remaining() == 0).then_some(node)
}

// MARK: The doors

/// Re-establishes a template layout's invariants: the repair the persisted decoder runs.
///
/// A childless split becomes a plain terminal, a one-child split collapses into its child, and
/// anything nested past `split_tree::MAX_DEPTH` collapses to its first pane — repaired, never
/// rejected, because the input is a file a person can edit.
///
/// Answers the repaired layout in the module's encoding, under §4's convention. `0` is the stream
/// refusal described at the top of this file and nothing else: every layout that decodes has a
/// repair, and the shortest one encodes to seven bytes.
///
/// # Safety
/// `layout` must be null or point to `len` live bytes for the call; `out` null or writable for
/// `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_template_repair(
    layout: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(layout, len) };
    let Some(node) = decode_layout(bytes) else {
        return 0;
    };
    let mut writer = ByteWriter::new();
    put_node(&mut writer, &node.repaired());
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&writer.into_vec(), out, cap) }
}

/// The session templates a fresh workspace ships with, as a `table` of `template` records.
///
/// A shipped row's IDENTITY is the reason this crosses at all. The ids are fixed rather than minted
/// so that re-seeding a workspace or resetting the settings MATCHES the existing row instead of
/// appending a second copy of it — which makes the table a pair of constants written in two
/// languages, and a drift in one of sixteen bytes shows up as a duplicated menu row weeks later
/// with nothing in any log.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_built_in_templates(out: *mut c_uchar, cap: usize) -> usize {
    let shipped = templates::built_in_session_templates();
    let mut writer = ByteWriter::new();
    writer.put_u32(saturating_u32(shipped.len()));
    for template in &shipped {
        put_template(&mut writer, template);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&writer.into_vec(), out, cap) }
}

/// The launch presets a fresh workspace ships with, as a `table` of `preset` records. Crosses for
/// [`slopdesk_ws_built_in_templates`]'s reason.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_built_in_launch_presets(out: *mut c_uchar, cap: usize) -> usize {
    let shipped = templates::built_in_launch_presets();
    let mut writer = ByteWriter::new();
    writer.put_u32(saturating_u32(shipped.len()));
    for preset in &shipped {
        put_preset(&mut writer, preset);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&writer.into_vec(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    reason = "a door that refuses its own fixture IS the report"
)]
mod tests {
    use slopdesk_workspace::split_tree::MAX_DEPTH;
    use slopdesk_workspace::templates::{
        FALLBACK_PANE_TITLE, TemplateNode, TemplatePane, built_in_session_templates,
    };
    use slopdesk_workspace::{PaneKind, SplitAxis};

    use super::{
        ByteWriter, decode_layout, put_node, slopdesk_ws_built_in_launch_presets,
        slopdesk_ws_built_in_templates, slopdesk_ws_template_repair,
    };

    fn encoded(node: &TemplateNode) -> Vec<u8> {
        let mut writer = ByteWriter::new();
        put_node(&mut writer, node);
        writer.into_vec()
    }

    /// The door under §4's size-then-read protocol, answering `None` for the stream refusal.
    fn repair(bytes: &[u8]) -> Option<TemplateNode> {
        // SAFETY: the null probe §4 describes, over a live local.
        let needed =
            unsafe { slopdesk_ws_template_repair(bytes.as_ptr(), bytes.len(), core::ptr::null_mut(), 0) };
        if needed == 0 {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes, and `bytes` is a live local.
        let written =
            unsafe { slopdesk_ws_template_repair(bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        decode_layout(&out)
    }

    #[test]
    fn the_stream_is_the_layout_written_down_once_and_read_back_whole() {
        // The byte layout, spelled out rather than round-tripped: a round trip agrees with itself
        // however both halves are wrong, and the Swift encoder is written against the paragraph at
        // the top of this file, not against this function.
        let pane = TemplateNode::Pane(TemplatePane {
            kind: PaneKind::Desktop,
            title: "Hi".to_owned(),
            cwd: None,
            command: Some(String::new()),
        });
        assert_eq!(encoded(&pane), vec![
            0, // a pane
            1, // kind: desktop
            0, 0, 0, 2, b'H', b'i', // title
            0,    // cwd: absent
            1, 0, 0, 0, 0, // command: present, empty — NOT the same answer as absent
        ]);
        assert_eq!(decode_layout(&encoded(&pane)), Some(pane));
    }

    #[test]
    fn a_split_carries_its_child_count_and_its_children_follow_it() {
        let split = TemplateNode::split(SplitAxis::Vertical, vec![
            TemplateNode::Pane(TemplatePane::new("A")),
            TemplateNode::Pane(TemplatePane::new("B")),
        ]);
        let bytes = encoded(&split);
        assert_eq!(bytes.get(..6), Some([1, 1, 0, 0, 0, 2].as_slice()));
        assert_eq!(decode_layout(&bytes), Some(split));
    }

    #[test]
    fn a_stream_the_reader_cannot_consume_exactly_is_refused_rather_than_guessed_at() {
        let sound = encoded(&TemplateNode::Pane(TemplatePane::new("A")));
        assert!(decode_layout(&sound).is_some());
        assert!(decode_layout(&[]).is_none(), "an empty stream names no layout");
        assert!(
            decode_layout(sound.get(..sound.len() - 1).unwrap_or_default()).is_none(),
            "a truncated stream is a shape disagreement, not a degenerate layout",
        );
        let mut trailing = sound;
        trailing.push(0);
        assert!(
            decode_layout(&trailing).is_none(),
            "a trailing byte is refused, not ignored"
        );
        assert!(
            decode_layout(&[7]).is_none(),
            "a tag that is neither pane nor split"
        );
        // A child count no stream this short could satisfy, refused before it is an allocation.
        assert!(decode_layout(&[1, 0, 0xFF, 0xFF, 0xFF, 0xFF]).is_none());
        // A presence byte that is neither of its two values.
        assert!(decode_layout(&[0, 0, 0, 0, 0, 0, 9]).is_none());
    }

    #[test]
    fn the_door_repairs_every_degenerate_shape_the_crate_does() {
        // The door adds nothing to `repaired()` and subtracts nothing from it, which is the whole
        // claim a differential on the other side rests on.
        let fallback = TemplateNode::Pane(TemplatePane::new(FALLBACK_PANE_TITLE));
        assert_eq!(
            repair(&encoded(&TemplateNode::split(SplitAxis::Horizontal, Vec::new()))),
            Some(fallback),
        );
        let lone = TemplateNode::split(SplitAxis::Horizontal, vec![TemplateNode::Pane(
            TemplatePane::new("Solo"),
        )]);
        assert_eq!(
            repair(&encoded(&lone)),
            Some(TemplateNode::Pane(TemplatePane::new("Solo")))
        );

        let mut deep = TemplateNode::Pane(TemplatePane::new("Deepest"));
        for _ in 0..MAX_DEPTH + 2 {
            deep = TemplateNode::split(SplitAxis::Horizontal, vec![
                deep,
                TemplateNode::Pane(TemplatePane::new("Filler")),
            ]);
        }
        let repaired = repair(&encoded(&deep)).expect("an over-deep layout still answers");
        assert_eq!(repaired, deep.repaired());
        assert!(repaired.depth() <= MAX_DEPTH);
    }

    #[test]
    fn a_refused_stream_answers_zero_rather_than_an_empty_buffer() {
        // SAFETY: a live local, deliberately not a layout.
        let needed = unsafe { slopdesk_ws_template_repair([9_u8].as_ptr(), 1, core::ptr::null_mut(), 0) };
        assert_eq!(needed, 0, "the refusal is 0, which no real answer can be");
    }

    #[test]
    fn a_probe_that_did_not_fit_leaves_the_buffer_untouched() {
        let bytes = encoded(&TemplateNode::Pane(TemplatePane::new("A")));
        let mut out = [0_u8; 3];
        // SAFETY: both are live locals; `out` is deliberately too small.
        let needed =
            unsafe { slopdesk_ws_template_repair(bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len()) };
        assert!(needed > out.len());
        assert!(out.iter().all(|byte| *byte == 0), "a short call still wrote");
    }

    #[test]
    fn the_shipped_tables_come_back_under_the_size_then_read_protocol() {
        // SAFETY: the null probe §4 describes.
        let needed = unsafe { slopdesk_ws_built_in_templates(core::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is exactly `needed` bytes.
        let written = unsafe { slopdesk_ws_built_in_templates(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        let shipped = built_in_session_templates();
        assert_eq!(
            out.get(..4),
            Some(
                u32::try_from(shipped.len())
                    .unwrap_or_default()
                    .to_be_bytes()
                    .as_slice()
            ),
            "the count leads the table",
        );
        assert_eq!(
            out.get(4..20).map(<[u8]>::to_vec),
            shipped.first().map(|first| first.id.bytes().to_vec()),
            "the first record opens with its own id",
        );

        // SAFETY: the null probe again, for the other table.
        let presets = unsafe { slopdesk_ws_built_in_launch_presets(core::ptr::null_mut(), 0) };
        assert!(presets > 4, "three shipped presets are more than a bare count");
    }
}
