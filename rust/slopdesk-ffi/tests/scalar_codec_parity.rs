//! The scalar field codec is written twice in RUST, and until this file nothing compared the
//! leaves.
//!
//! `snapshot_codec_parity.rs` beside this one pins the snapshot GRAMMAR — the
//! `[u32 count][kind][uuid][field][u32 len][value]` envelope. It never opens a `value`. So the two
//! implementations of what goes INSIDE that length prefix — `slopdesk_wire::document::codec` and
//! `slopdesk_workspace::state_codec` — have been free to disagree about every field the document
//! actually carries, in two crates that do not depend on each other, with both suites green.
//!
//! This is the drift class docs/55 §8 catalogues, minus the one property that makes it easy to
//! spot: it is not cross-LANGUAGE, so no gate that greps for a Swift spelling can see it, and
//! `check-supervisor.sh` has nothing to compare a Rust file against another Rust file with. The
//! arrow points wire → workspace and `state_codec` is below the fork, so neither can `use` the
//! other without a cycle; `slopdesk-ffi` is the only crate that depends on both, which is why the
//! question is asked here and can only be asked here.
//!
//! ## What is compared, and what "the same" means for each
//!
//! Every scalar leaf that exists on both sides, in both directions: identical bytes out of the two
//! encoders, and each decoder reading the other encoder's bytes to the same value. Where only one
//! side has an encoder (`state_codec` has no `encode_u8`, `encode_bool` or `encode_uuid` — the shim
//! writes those bytes itself) the DECODERS are still compared against the other side's encoder,
//! because that is the direction a real disagreement travels: a host encodes, a client decodes.
//!
//! ## The two that were nearly divergent, recorded so a future reader does not re-derive them
//!
//! `encode_string`'s UTF-8 clamp is written twice and differently: the wire half walks FORWARD
//! through `char_indices` accumulating while the next boundary fits, the workspace half walks
//! BACKWARD from the limit until `is_char_boundary`. They reach the same answer for every input —
//! the tests below hammer that with multi-byte scalars straddling every offset around the limit —
//! but "the same answer by two different routes" is precisely the arrangement that stops being true
//! without anything failing to compile.
//!
//! `encode_i32` and `encode_i64` reach the bit pattern by different casts (`to_be_bytes` on the
//! signed value against `cast_unsigned().to_be_bytes()`). Those are the same operation and the
//! compiler knows it; the pin is here so that a future "clarifying" edit to either has somewhere to
//! be caught.

#![expect(
    clippy::indexing_slicing,
    reason = "the width sweep slices a fixture it declared; a panic here IS the report"
)]

use slopdesk_wire::document::codec as wire;
use slopdesk_workspace::state_codec as ws;

/// A UUID whose bytes are all `seed`, so a fixture's identity is readable from the seed alone.
const fn id(seed: u8) -> [u8; 16] {
    [seed; 16]
}

// ---------------------------------------------------------------------------------------------- //
// The fixed-width leaves
// ---------------------------------------------------------------------------------------------- //

/// Every `u32` boundary and a spread of ordinary values, both encoders and both decoders.
#[test]
fn the_two_u32_codecs_agree_on_every_boundary() {
    for value in [
        0,
        1,
        2,
        255,
        256,
        65_535,
        65_536,
        1_000_000,
        u32::MAX - 1,
        u32::MAX,
    ] {
        let from_wire = wire::encode_u32(value);
        let from_ws = ws::encode_u32(value);
        assert_eq!(from_wire.as_slice(), from_ws.as_slice(), "encode_u32({value})");
        assert_eq!(
            wire::decode_u32(&from_ws),
            Some(value),
            "wire reads workspace's u32 {value}"
        );
        assert_eq!(
            ws::decode_u32(&from_wire),
            Some(value),
            "workspace reads wire's u32 {value}"
        );
    }
}

/// The signed four-byte field — `pane/lastExitCode`, which carries a signal-killed child's negative
/// code as the `u32` bit pattern. The two encoders reach that pattern by different casts.
#[test]
fn the_two_i32_codecs_agree_including_the_negative_exit_codes() {
    for value in [
        0,
        1,
        -1,
        127,
        -128,
        i32::from(i16::MIN),
        130,
        -9,
        i32::MIN,
        i32::MAX,
    ] {
        let from_wire = wire::encode_i32(value);
        let from_ws = ws::encode_i32(value);
        assert_eq!(from_wire.as_slice(), from_ws.as_slice(), "encode_i32({value})");
        assert_eq!(
            wire::decode_i32(&from_ws),
            Some(value),
            "wire reads workspace's i32 {value}"
        );
        assert_eq!(
            ws::decode_i32(&from_wire),
            Some(value),
            "workspace reads wire's i32 {value}"
        );
    }
}

/// The eight-byte signed field — a millisecond timestamp, so the interesting values are large and
/// the sign is real (a pre-epoch clock is a wrong clock, not an impossible one).
#[test]
fn the_two_i64_codecs_agree_including_a_pre_epoch_timestamp() {
    for value in [
        0,
        1,
        -1,
        1_700_000_000_000,
        -1_700_000_000_000,
        i64::MIN,
        i64::MAX,
    ] {
        let from_wire = wire::encode_i64(value);
        let from_ws = ws::encode_i64(value);
        assert_eq!(from_wire.as_slice(), from_ws.as_slice(), "encode_i64({value})");
        assert_eq!(
            wire::decode_i64(&from_ws),
            Some(value),
            "wire reads workspace's i64 {value}"
        );
        assert_eq!(
            ws::decode_i64(&from_wire),
            Some(value),
            "workspace reads wire's i64 {value}"
        );
    }
}

/// `pane/grid` is `(cols, rows)` in that order, and the order is the whole content of the rule — a
/// pair swapped on one side transposes every restored terminal without failing a decode.
#[test]
fn the_two_u16_pair_codecs_agree_and_keep_the_order() {
    for (first, second) in [
        (0, 0),
        (1, 2),
        (80, 24),
        (u16::MAX, 0),
        (0, u16::MAX),
        (u16::MAX, u16::MAX),
    ] {
        let from_wire = wire::encode_u16_pair(first, second);
        let from_ws = ws::encode_u16_pair(first, second);
        assert_eq!(
            from_wire.as_slice(),
            from_ws.as_slice(),
            "encode_u16_pair({first},{second})"
        );
        assert_eq!(wire::decode_u16_pair(&from_ws), Some((first, second)));
        assert_eq!(ws::decode_u16_pair(&from_wire), Some((first, second)));
    }
}

/// `agentState` is `[state][kind]` and `progress` is `[state][percent]`. Only the wire half has an
/// encoder; the decoders are what both sides run.
#[test]
fn the_two_u8_pair_decoders_agree_on_the_wire_halfs_bytes() {
    for (first, second) in [(0, 0), (1, 0), (0, 1), (3, 100), (u8::MAX, u8::MAX)] {
        let bytes = wire::encode_u8_pair(first, second);
        assert_eq!(wire::decode_u8_pair(&bytes), Some((first, second)));
        assert_eq!(ws::decode_u8_pair(&bytes), Some((first, second)));
    }
}

/// The one-byte field, and the same byte read as a BOOL. The bool rule is the interesting half:
/// both sides must say "any non-zero byte is true", because a side that read `== 1` would answer
/// false for every non-canonical byte a peer sends while the other answered true, and no decode
/// would fail.
#[test]
fn the_two_byte_decoders_agree_including_the_non_canonical_bools() {
    for value in 0u8..=255 {
        let bytes = wire::encode_u8(value);
        assert_eq!(
            ws::decode_u8(&bytes),
            Some(value),
            "workspace reads wire's u8 {value}"
        );
        assert_eq!(
            wire::decode_bool(&bytes),
            ws::decode_bool(&bytes),
            "the two bool readings part on byte {value}"
        );
        assert_eq!(
            ws::decode_bool(&bytes),
            Some(value != 0),
            "non-zero is true, byte {value}"
        );
    }
}

// ---------------------------------------------------------------------------------------------- //
// The refusals — a width neither side may accept
// ---------------------------------------------------------------------------------------------- //

/// A field of the wrong length is `None` on both sides, at every width around each leaf's own.
///
/// This is the half a round-trip test cannot reach: both codecs agree perfectly on well-formed
/// input and can still disagree about what to do with a truncated field, which is exactly what
/// arrives when a peer of another version writes one.
#[test]
fn the_two_codecs_refuse_the_same_wrong_widths() {
    let filler = [7u8; 20];
    for len in 0..=20usize {
        let bytes = &filler[..len];
        assert_eq!(
            wire::decode_u32(bytes).is_some(),
            ws::decode_u32(bytes).is_some(),
            "u32 at width {len}"
        );
        assert_eq!(
            wire::decode_i32(bytes).is_some(),
            ws::decode_i32(bytes).is_some(),
            "i32 at width {len}"
        );
        assert_eq!(
            wire::decode_i64(bytes).is_some(),
            ws::decode_i64(bytes).is_some(),
            "i64 at width {len}"
        );
        assert_eq!(
            wire::decode_u16_pair(bytes).is_some(),
            ws::decode_u16_pair(bytes).is_some(),
            "u16 pair at width {len}"
        );
        assert_eq!(
            wire::decode_u8_pair(bytes).is_some(),
            ws::decode_u8_pair(bytes).is_some(),
            "u8 pair at width {len}"
        );
        assert_eq!(
            wire::decode_u8(bytes).is_some(),
            ws::decode_u8(bytes).is_some(),
            "u8 at width {len}"
        );
        assert_eq!(
            wire::decode_bool(bytes).is_some(),
            ws::decode_bool(bytes).is_some(),
            "bool at width {len}"
        );
        assert_eq!(
            wire::decode_uuid(bytes).is_some(),
            ws::decode_uuid(bytes).is_some(),
            "uuid at width {len}"
        );
    }
}

// ---------------------------------------------------------------------------------------------- //
// The string clamp — the same answer by two different routes
// ---------------------------------------------------------------------------------------------- //

/// Two clamps, one walking forward through `char_indices` and one walking backward from the limit,
/// held against each other at every limit from 0 to past the end for strings whose multi-byte
/// scalars straddle every offset in that range.
#[test]
fn the_two_utf8_clamps_agree_at_every_limit() {
    let cases = [
        "",
        "ascii",
        "héllo",               // 2-byte scalar at offset 1
        "日本語",              // 3-byte scalars only
        "a日b本c語d",          // 3-byte scalars at odd offsets
        "🐈‍⬛ cat",              // 4-byte scalar plus a ZWJ sequence
        "e\u{301}\u{301}tail", // combining marks, so a boundary is not a grapheme
    ];
    for text in cases {
        for limit in 0..=(text.len() + 4) {
            let from_wire = wire::encode_string(text, limit);
            let from_ws = ws::encode_string(text, limit);
            assert_eq!(
                from_wire, from_ws,
                "encode_string({text:?}, {limit}) — the forward and backward clamps parted"
            );
            // Whatever they agreed on has to still BE a string: a clamp that cut mid-scalar would
            // make the value undecodable on both sides at once, which agreement alone cannot catch.
            assert!(
                core::str::from_utf8(&from_wire).is_ok(),
                "encode_string({text:?}, {limit}) cut mid-scalar"
            );
            assert!(
                from_wire.len() <= limit,
                "encode_string({text:?}, {limit}) overshot its limit"
            );
        }
    }
}

/// Both string decoders are strict UTF-8 — never lossy — and must refuse the same bytes. A side
/// that rendered `U+FFFD` instead would show the replacement character as if the program had
/// printed it, while the other visibly dropped the field.
#[test]
fn the_two_string_decoders_refuse_the_same_bytes() {
    let cases: [&[u8]; 6] = [
        b"",
        b"ok",
        &[0xFF],
        &[0xC3],             // a truncated 2-byte scalar
        &[0xE6, 0x97],       // a truncated 3-byte scalar
        &[0xF0, 0x9F, 0x90], // a truncated 4-byte scalar
    ];
    for bytes in cases {
        assert_eq!(
            wire::decode_string(bytes).as_deref(),
            ws::decode_string(bytes),
            "the two string decoders part on {bytes:?}"
        );
    }
}

// ---------------------------------------------------------------------------------------------- //
// The UUID list — `root/sessionOrder`, `session/tabOrder`, `root/closedTabRing`
// ---------------------------------------------------------------------------------------------- //

/// Both encoders truncate at `u16::MAX` rather than refusing, and both decoders demand the count
/// and the bytes agree exactly. The empty list is a REAL value here — a workspace with no closed
/// tabs — so it is pinned as an answer rather than left to the refusal cases above.
#[test]
fn the_two_uuid_list_codecs_agree_on_the_ordinary_lists() {
    let lists: [Vec<[u8; 16]>; 4] = [
        vec![],
        vec![id(1)],
        vec![id(1), id(2)],
        (0..64u8).map(id).collect(),
    ];
    for ids in lists {
        let from_wire = wire::encode_uuid_list(&ids);
        let from_ws = ws::encode_uuid_list(&ids);
        assert_eq!(from_wire, from_ws, "encode_uuid_list of {} ids", ids.len());
        assert_eq!(wire::decode_uuid_list(&from_ws), Some(ids.clone()));
        assert_eq!(ws::decode_uuid_list(&from_wire), Some(ids));
    }
}

/// A count that does not match the bytes is `None` on both sides — including the hostile `0xFFFF`
/// with nothing behind it, which the workspace half is careful to refuse before reserving capacity.
#[test]
fn the_two_uuid_list_decoders_refuse_the_same_malformed_counts() {
    let cases: Vec<Vec<u8>> = vec![
        vec![],
        vec![0],
        vec![0, 1],                           // claims one, carries none
        vec![0xFF, 0xFF],                     // claims 65535, carries none
        [vec![0, 1], vec![9u8; 15]].concat(), // one short
        [vec![0, 1], vec![9u8; 17]].concat(), // one long
        [vec![0, 2], vec![9u8; 16]].concat(), // claims two, carries one
    ];
    for bytes in cases {
        assert_eq!(
            wire::decode_uuid_list(&bytes).is_some(),
            ws::decode_uuid_list(&bytes).is_some(),
            "the two uuid-list decoders part on {bytes:?}"
        );
        assert!(
            ws::decode_uuid_list(&bytes).is_none(),
            "malformed list accepted: {bytes:?}"
        );
    }
}

/// The single UUID, which only the wire half encodes.
#[test]
fn the_two_uuid_decoders_agree() {
    for seed in [0u8, 1, 128, 255] {
        let bytes = wire::encode_uuid(&id(seed));
        assert_eq!(wire::decode_uuid(&bytes), Some(id(seed)));
        assert_eq!(ws::decode_uuid(&bytes), Some(id(seed)));
    }
}
