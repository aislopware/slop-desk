//! Byte-for-byte parity against the committed golden corpus.
//!
//! `golden/golden_vectors.json` is generated from the SWIFT implementation
//! (`Sources/slopdesk-corevectors/main.swift`) and predates this crate, so it is an oracle rather
//! than a fixture written alongside the port: "did moving the FEC to Rust change the wire" is
//! answered here by bytes nobody wrote for this test.
//!
//! ## What the corpus pins, and what it does not
//! Both groups are generated from `XORParityFEC(groupSize: 5)` — which is
//! `RustReedSolomonFEC(groupSize: 5, parityCount: 1)` under its compatibility alias — so every
//! pinned vector exercises `m == 1`, the shipped operating point and the one the wire contract
//! declares byte-identical to plain XOR. That is exactly the half a port can break invisibly: the
//! `m >= 2` Cauchy path is checked by its own algebra (any `k` of `k + m` shards reconstruct, and
//! `A · A⁻¹ == I` for all 35 four-subsets of a `[7,4]` encoder) in the unit tests, because its
//! answer is *verifiable* while `m == 1`'s bytes are merely *agreed*. Agreement needs a witness;
//! correctness does not.
//!
//! ## Beyond the FEC
//! Every codec group below is checked in BOTH directions by `assert_codec_round_trip`: the pinned
//! hex must decode, and re-encoding what came back must reproduce the same hex. Encode-only would
//! miss a decoder that happily accepted the wrong bytes; decode-only would miss an encoder that
//! emitted them.
//!
//! `naluSplit` / `naluJoin` pin the AVCC walk in both directions, `ycbcr` pins the shader's seven
//! coefficients as raw `f32` bit patterns, and `coordWindowPoint` pins the pointer mapping as raw
//! `f64` bit patterns. The last two are pinned as BITS rather than decimals on purpose: a value
//! that drifted by one ulp — an `f64` intermediate narrowed to `f32`, or a `mul_add` fusing what
//! the wire rounds twice — still prints as the same number.
//!
//! ## The send path
//! `fragmentEncode` pins the 19-byte per-datagram header and `muxFragment` its muxed sibling, which
//! is ALSO 19 bytes over a different layout — the two are checked field by field rather than as
//! rebuilt structs, because a same-width field swap round-trips its own bytes perfectly and would
//! otherwise pass. `adaptiveGroupSize` pins the tier→group table including the `null` that only an
//! `Option` can spell, and `adaptiveTier` sweeps the loss ladder against every previous tier with
//! the loss pinned as an `f64` bit pattern, for the same one-ulp reason as `ycbcr`.
//!
//! ## Both directions, on purpose
//! `fecParity` pins the ENCODER: the same fragments in, the same parity hex out. `fecRecover` pins
//! the DECODER against three outcomes the Swift generator chose deliberately — a repaired hole, two
//! holes in one group that must BOTH stay lost, and a hole whose parity was also lost. The two
//! negative vectors matter as much as the positive one: a decoder that repaired more than it should
//! would pass the first vector and corrupt a frame in production.

#![expect(
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::indexing_slicing,
    reason = "serde_json's Index panics on a missing key, which is the failure this test wants when the \
              corpus and the codec disagree about a field name"
)]

use core::fmt::Write as _;

use serde_json::Value;
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};
use slopdesk_video::video_control::{
    DisplaySummary, HostWindowFlags, HostWindowRecord, MaskRect, SystemDialogSummary, VideoControlMessage,
    WindowSummary,
};
use slopdesk_video::{
    AudioChannelMessage, AudioStreamConfig, AudioWireFormat, ColorRange, CursorChannelMessage,
    CursorShapeMessage, CursorUpdate, FrameFragment, InputEvent, InputModifiers, MouseButton,
    MuxFrameFragmentHeader, NetworkStatsReport, RecoveryMessage, ReedSolomonFec, SwipeNavStatusMessage,
    VideoProtocolError, WindowGeometryMessage, adaptive_fec, capture_region, coordinate_mapping, input_event,
    mux_header, nal_unit, window_placement, ycbcr,
};

/// The pinned corpus, read at compile time so a missing or renamed file is a build failure rather
/// than a test that silently passes with zero vectors.
const GOLDEN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../golden/golden_vectors.json"
));

/// The codec the generator used: `XORParityFEC(groupSize: 5)`, i.e. `k = 5, m = 1`.
const GENERATOR_CODEC: ReedSolomonFec = ReedSolomonFec::new(5, 1);

fn from_hex(hex: &str) -> Vec<u8> {
    assert!(
        hex.len().is_multiple_of(2),
        "a hex string has an even length: {hex:?}"
    );
    hex.as_bytes()
        .chunks(2)
        .map(|pair| {
            let text = core::str::from_utf8(pair).expect("hex is ASCII");
            u8::from_str_radix(text, 16).expect("hex digits")
        })
        .collect()
}

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn corpus() -> Value {
    serde_json::from_str(GOLDEN).expect("the golden corpus parses")
}

fn group_of(root: &Value, name: &str) -> Vec<Value> {
    root[name].as_array().expect("a vector group is an array").clone()
}

/// A `["aabb", null, …]` list of optional hex strings, as the recover vectors carry it.
fn optional_fragments(value: &Value) -> Vec<Option<Vec<u8>>> {
    value
        .as_array()
        .expect("an array of optional hex strings")
        .iter()
        .map(|entry| entry.as_str().map(from_hex))
        .collect()
}

fn group_size_of(vector: &Value) -> usize {
    usize::try_from(vector["groupSize"].as_u64().expect("a group size")).expect("fits usize")
}

#[test]
fn every_pinned_parity_vector_encodes_to_the_pinned_bytes() {
    let root = corpus();
    let vectors = group_of(&root, "fecParity");
    assert_eq!(vectors.len(), 4, "the corpus pins four parity vectors");

    for (index, vector) in vectors.iter().enumerate() {
        let data: Vec<Vec<u8>> = vector["dataHex"]
            .as_array()
            .expect("an array of hex fragments")
            .iter()
            .map(|entry| from_hex(entry.as_str().expect("a hex fragment")))
            .collect();
        let fragments: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();

        let parity = GENERATOR_CODEC.parity(&fragments, group_size_of(vector));
        let mine: Vec<String> = parity.iter().map(|shard| to_hex(shard)).collect();
        let pinned: Vec<String> = vector["parityHex"]
            .as_array()
            .expect("an array of parity shards")
            .iter()
            .map(|entry| entry.as_str().expect("a hex shard").to_owned())
            .collect();

        assert_eq!(
            mine, pinned,
            "fecParity[{index}] parity bytes drifted from the Swift codec"
        );
    }
}

#[test]
fn every_pinned_parity_vector_recovers_each_of_its_own_fragments() {
    // The corpus pins the encoder; this pins the ENCODER AND DECODER against each other over the
    // same pinned bytes — every single-hole loss pattern in every pinned vector, repaired from the
    // corpus's own parity hex rather than from parity this crate just computed.
    let root = corpus();
    for (index, vector) in group_of(&root, "fecParity").iter().enumerate() {
        let data: Vec<Option<Vec<u8>>> = optional_fragments(&vector["dataHex"]);
        let parity: Vec<Option<Vec<u8>>> = optional_fragments(&vector["parityHex"]);
        let group_size = group_size_of(vector);

        for hole in 0..data.len() {
            let mut holed = data.clone();
            holed[hole] = None;
            GENERATOR_CODEC.recover(&mut holed, &parity, group_size);
            assert_eq!(
                holed[hole], data[hole],
                "fecParity[{index}]: losing fragment {hole} must be repairable from the pinned parity"
            );
        }
    }
}

#[test]
fn every_pinned_recover_vector_repairs_exactly_what_swift_repaired() {
    let root = corpus();
    let vectors = group_of(&root, "fecRecover");
    assert_eq!(vectors.len(), 3, "the corpus pins three recover vectors");

    for (index, vector) in vectors.iter().enumerate() {
        let mut data = optional_fragments(&vector["dataHex"]);
        let parity = optional_fragments(&vector["parityHex"]);
        let expected = optional_fragments(&vector["recoveredHex"]);

        GENERATOR_CODEC.recover(&mut data, &parity, group_size_of(vector));

        let mine: Vec<Option<String>> = data.iter().map(|entry| entry.as_deref().map(to_hex)).collect();
        let pinned: Vec<Option<String>> = expected
            .iter()
            .map(|entry| entry.as_deref().map(to_hex))
            .collect();
        assert_eq!(
            mine, pinned,
            "fecRecover[{index}]: this decoder disagreed with Swift about what is repairable"
        );
    }
}

#[test]
fn every_pinned_nalu_split_finds_the_same_units_swift_found() {
    let root = corpus();
    let vectors = group_of(&root, "naluSplit");
    assert_eq!(vectors.len(), 3, "the corpus pins three split vectors");

    for (index, vector) in vectors.iter().enumerate() {
        let avcc = from_hex(vector["avccHex"].as_str().expect("a hex buffer"));
        let mine: Vec<String> = nal_unit::split(&avcc).iter().map(|unit| to_hex(unit)).collect();
        let pinned: Vec<String> = vector["unitsHex"]
            .as_array()
            .expect("an array of units")
            .iter()
            .map(|entry| entry.as_str().expect("a hex unit").to_owned())
            .collect();
        assert_eq!(
            mine, pinned,
            "naluSplit[{index}]: the AVCC walk disagreed with Swift"
        );
    }
}

#[test]
fn every_pinned_nalu_join_rebuilds_the_same_buffer_swift_built() {
    let root = corpus();
    let vectors = group_of(&root, "naluJoin");
    assert_eq!(vectors.len(), 2, "the corpus pins two join vectors");

    for (index, vector) in vectors.iter().enumerate() {
        let units: Vec<Vec<u8>> = vector["unitsHex"]
            .as_array()
            .expect("an array of units")
            .iter()
            .map(|entry| from_hex(entry.as_str().expect("a hex unit")))
            .collect();
        let borrowed: Vec<&[u8]> = units.iter().map(Vec::as_slice).collect();
        let joined = nal_unit::join(&borrowed);
        assert_eq!(
            to_hex(&joined),
            vector["hex"].as_str().expect("a hex buffer"),
            "naluJoin[{index}]: the rebuilt AVCC buffer drifted"
        );
        // Round-trip: whatever join writes, split must read back unchanged. The corpus pins each
        // direction on its own; this pins them against each other.
        let round_tripped: Vec<Vec<u8>> = nal_unit::split(&joined)
            .iter()
            .map(|unit| unit.to_vec())
            .collect();
        assert_eq!(
            round_tripped, units,
            "naluJoin[{index}]: join/split are not inverses"
        );
    }
}

#[test]
fn every_pinned_ycbcr_coefficient_has_the_same_f32_bit_pattern() {
    // Pinned as raw `f32` bit patterns, not decimals: the shader's inputs must be bit-identical,
    // and an `f64` intermediate narrowed on the way in would still print as "0.1873".
    let root = corpus();
    let vectors = group_of(&root, "ycbcr");
    assert_eq!(vectors.len(), 2, "the corpus pins both ranges");

    for (index, vector) in vectors.iter().enumerate() {
        let range = match vector["range"].as_str().expect("a range name") {
            "full" => ColorRange::Full,
            "video" => ColorRange::Video,
            other => panic!("ycbcr[{index}]: unknown range {other:?}"),
        };
        let mine = ycbcr::coefficients(range);
        let pinned =
            |field: &str| u32::try_from(vector[field].as_u64().expect("a bit pattern")).expect("fits u32");
        for (field, bits) in [
            ("lumaScale", mine.luma_scale.to_bits()),
            ("lumaBias", mine.luma_bias.to_bits()),
            ("chromaBias", mine.chroma_bias.to_bits()),
            ("crToR", mine.cr_to_r.to_bits()),
            ("cbToG", mine.cb_to_g.to_bits()),
            ("crToG", mine.cr_to_g.to_bits()),
            ("cbToB", mine.cb_to_b.to_bits()),
        ] {
            assert_eq!(
                bits,
                pinned(field),
                "ycbcr[{index}].{field} drifted from the shader"
            );
        }
    }
}

#[test]
fn every_pinned_window_point_has_the_same_f64_bit_pattern() {
    // Bit patterns again, and here they are the whole point of the vector: `origin + n * size`
    // rounds twice, `mul_add` rounds once, and the two answers differ in the last bit. This test is
    // what makes the crate-wide `suboptimal_flops = "allow"` a decision rather than an oversight.
    let root = corpus();
    let vectors = group_of(&root, "coordWindowPoint");
    assert_eq!(vectors.len(), 2, "the corpus pins two window points");

    for (index, vector) in vectors.iter().enumerate() {
        let number = |field: &str| vector[field].as_f64().expect("a number");
        let bounds = VideoRect::xywh(number("bx"), number("by"), number("bw"), number("bh"));
        let point = coordinate_mapping::window_point(VideoPoint::new(number("nx"), number("ny")), bounds);
        let pinned = |field: &str| vector[field].as_u64().expect("a bit pattern");
        assert_eq!(
            point.x.to_bits(),
            pinned("outXBits"),
            "coordWindowPoint[{index}].x drifted"
        );
        assert_eq!(
            point.y.to_bits(),
            pinned("outYBits"),
            "coordWindowPoint[{index}].y drifted"
        );
    }
}

#[test]
fn every_pinned_placement_puts_the_window_where_swift_put_it() {
    // The vectors are bit patterns because the answers a port gets subtly wrong all compare equal:
    // a `-0.0` origin, a NaN that survived an ordered compare where a NaN-ignoring minimum would
    // have swallowed it, and a half-point predicate one ulp off. `windowPlacement` was frozen in
    // the corpus with nothing reading it for a long time; this is the crate side of that pin.
    let root = corpus();
    let vectors = group_of(&root, "windowPlacement");
    assert_eq!(
        vectors.len(),
        11,
        "the corpus lost cases — vectors are added, never dropped"
    );

    for vector in &vectors {
        let name = vector["name"].as_str().expect("a name");
        let bits = |field: &str| f64::from_bits(vector[field].as_u64().expect("a bit pattern"));
        // The corpus stores the display rect as the generator built it, and the generator read it
        // back through `CGRect.width`, which returns `|size|` — a raw origin, a standardised
        // extent. That asymmetry belongs to the window system, so the caller applies it and this
        // crate compares what it is given; the `negativeSizeDisplay` vector exists to say so.
        let plan = window_placement::place(
            bits("winWBits"),
            bits("winHBits"),
            bits("dX"),
            bits("dY"),
            bits("dW").abs(),
            bits("dH").abs(),
        );
        let pinned = |field: &str| vector[field].as_u64().expect("a bit pattern");
        assert_eq!(
            plan.origin_x.to_bits(),
            pinned("outOriginXBits"),
            "{name}: origin.x"
        );
        assert_eq!(
            plan.origin_y.to_bits(),
            pinned("outOriginYBits"),
            "{name}: origin.y"
        );
        assert_eq!(plan.width.to_bits(), pinned("outWidthBits"), "{name}: width");
        assert_eq!(plan.height.to_bits(), pinned("outHeightBits"), "{name}: height");
        assert_eq!(
            plan.needs_resize,
            vector["needsResize"].as_bool().expect("a flag"),
            "{name}: needsResize"
        );
    }
}

#[test]
fn every_pinned_capture_union_encloses_what_swift_enclosed() {
    // `captureUnion` was frozen with a note claiming a `slopdesk_core::capture_region` crate and a
    // `golden_parity` test validated it. Neither had existed for a long time, so fourteen cases
    // were pinned by a sentence. They are pinned by this instead — and by bit patterns, because
    // what a port gets wrong here all compares equal otherwise: the `!(area > 0.0)` NaN guard, the
    // `>=`-inclusive fraction against the SMALLER area, a standardised extent read as a raw one,
    // and a separate multiply that became an FMA.
    let root = corpus();
    let vectors = group_of(&root, "captureUnion");
    assert_eq!(
        vectors.len(),
        14,
        "the corpus lost cases — vectors are added, never dropped"
    );

    for vector in &vectors {
        let name = vector["name"].as_str().expect("a name");
        let bits = |field: &str| f64::from_bits(vector[field].as_u64().expect("a bit pattern"));
        let windows: Vec<capture_region::WindowSnapshot> = vector["windows"]
            .as_array()
            .expect("a window list")
            .iter()
            .map(|window| {
                let field = |name: &str| f64::from_bits(window[name].as_u64().expect("a bit pattern"));
                capture_region::WindowSnapshot {
                    window_id: u32::try_from(window["windowID"].as_u64().expect("an id")).expect("a u32"),
                    owner_pid: i32::try_from(window["ownerPID"].as_i64().expect("a pid")).expect("an i32"),
                    layer: i32::try_from(window["layer"].as_i64().expect("a layer")).expect("an i32"),
                    frame: VideoRect::xywh(field("fX"), field("fY"), field("fW"), field("fH")),
                }
            })
            .collect();
        let union = capture_region::union_region(
            VideoRect::xywh(bits("tX"), bits("tY"), bits("tW"), bits("tH")),
            u32::try_from(vector["targetWindowID"].as_u64().expect("an id")).expect("a u32"),
            i32::try_from(vector["targetPID"].as_i64().expect("a pid")).expect("an i32"),
            &windows,
            VideoRect::xywh(bits("dX"), bits("dY"), bits("dW"), bits("dH")),
            bits("minOverlapBits"),
        );
        let pinned = |field: &str| vector[field].as_u64().expect("a bit pattern");
        assert_eq!(union.origin.x.to_bits(), pinned("outOriginXBits"), "{name}: x");
        assert_eq!(union.origin.y.to_bits(), pinned("outOriginYBits"), "{name}: y");
        assert_eq!(
            union.size.width.to_bits(),
            pinned("outWidthBits"),
            "{name}: width"
        );
        assert_eq!(
            union.size.height.to_bits(),
            pinned("outHeightBits"),
            "{name}: height"
        );
    }
}

#[test]
fn every_pinned_retarget_gate_opens_exactly_where_swift_opened_it() {
    // The gate is a STRICT `>` per edge: a difference of exactly `minDelta` does not retarget.
    // `exactThreshold` and `customZeroDelta` are the two cases that say so, and each region change
    // they wave through is an encoder rebuild and an IDR on a live stream.
    let root = corpus();
    let vectors = group_of(&root, "captureRetarget");
    assert_eq!(
        vectors.len(),
        9,
        "the corpus lost cases — vectors are added, never dropped"
    );

    for vector in &vectors {
        let name = vector["name"].as_str().expect("a name");
        let bits = |field: &str| f64::from_bits(vector[field].as_u64().expect("a bit pattern"));
        assert_eq!(
            capture_region::should_retarget(
                VideoRect::xywh(bits("cX"), bits("cY"), bits("cW"), bits("cH")),
                VideoRect::xywh(bits("eX"), bits("eY"), bits("eW"), bits("eH")),
                bits("minDeltaBits"),
            ),
            vector["shouldRetarget"].as_bool().expect("a flag"),
            "{name}"
        );
    }
}

#[test]
fn every_pinned_fit_agrees_with_what_swift_would_have_parked() {
    let root = corpus();
    let vectors = group_of(&root, "windowFits");
    assert_eq!(
        vectors.len(),
        8,
        "the corpus lost cases — vectors are added, never dropped"
    );

    for vector in &vectors {
        let name = vector["name"].as_str().expect("a name");
        let bits = |field: &str| f64::from_bits(vector[field].as_u64().expect("a bit pattern"));
        assert_eq!(
            window_placement::fits(
                bits("sizeWBits"),
                bits("sizeHBits"),
                bits("bW").abs(),
                bits("bH").abs(),
            ),
            vector["fits"].as_bool().expect("a flag"),
            "{name}"
        );
    }
}

/// Decodes the pinned hex, re-encodes what came back, and asserts BOTH directions agree with the
/// corpus. Encode-only would miss a decoder that accepted the wrong bytes; decode-only would miss
/// an encoder that emitted them. The pair is what pins a codec.
fn assert_codec_round_trip<T: PartialEq + core::fmt::Debug>(
    label: &str,
    pinned_hex: &str,
    decode: impl Fn(&[u8]) -> Result<T, VideoProtocolError>,
    encode: impl Fn(&T) -> Vec<u8>,
) -> T {
    let bytes = from_hex(pinned_hex);
    let decoded =
        decode(&bytes).unwrap_or_else(|error| panic!("{label}: the pinned bytes must decode: {error}"));
    assert_eq!(
        to_hex(&encode(&decoded)),
        pinned_hex,
        "{label}: re-encoding drifted"
    );
    decoded
}

#[test]
fn every_pinned_window_geometry_message_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "windowGeometry");
    assert_eq!(vectors.len(), 4, "the corpus pins all four variants");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("windowGeometry[{index}]");
        let hex = vector["hex"].as_str().expect("a hex message");
        let decoded = assert_codec_round_trip(
            &label,
            hex,
            WindowGeometryMessage::decode,
            WindowGeometryMessage::encode,
        );
        let number = |field: &str| vector[field].as_f64().expect("a number");
        let expected = match vector["variant"].as_str().expect("a variant name") {
            "move" => WindowGeometryMessage::Move(VideoPoint::new(number("x"), number("y"))),
            "resize" => WindowGeometryMessage::Resize(VideoSize::new(number("w"), number("h"))),
            "bounds" => {
                WindowGeometryMessage::Bounds(VideoRect::xywh(
                    number("x"),
                    number("y"),
                    number("w"),
                    number("h"),
                ))
            },
            "title" => WindowGeometryMessage::Title(vector["title"].as_str().expect("a title").to_owned()),
            other => panic!("{label}: unknown variant {other:?}"),
        };
        assert_eq!(decoded, expected, "{label}: the decoded value drifted");
    }
}

#[test]
fn every_pinned_cursor_message_matches_in_both_directions() {
    let root = corpus();

    let updates = group_of(&root, "cursorUpdate");
    assert_eq!(updates.len(), 2, "the corpus pins two cursor updates");
    for (index, vector) in updates.iter().enumerate() {
        let label = format!("cursorUpdate[{index}]");
        let hex = vector["hex"].as_str().expect("a hex message");
        let decoded = assert_codec_round_trip(&label, hex, CursorUpdate::decode, CursorUpdate::encode);
        let number = |field: &str| vector[field].as_f64().expect("a number");
        let shape_id = u16::try_from(vector["shapeID"].as_u64().expect("a shape id")).expect("fits u16");
        assert_eq!(
            decoded,
            CursorUpdate::new(
                VideoPoint::new(number("x"), number("y")),
                shape_id,
                VideoPoint::new(number("hx"), number("hy")),
                vector["visible"].as_bool().expect("a visibility flag"),
            ),
            "{label}: the decoded value drifted"
        );
        // The whole reason the hot message is shaped this way.
        assert!(
            from_hex(hex).len() < 64,
            "{label}: the hot cursor message must stay inside the 64-byte budget"
        );
    }

    let shapes = group_of(&root, "cursorShape");
    assert_eq!(shapes.len(), 2, "the corpus pins two cursor shapes");
    for (index, vector) in shapes.iter().enumerate() {
        let label = format!("cursorShape[{index}]");
        let decoded = assert_codec_round_trip(
            &label,
            vector["hex"].as_str().expect("a hex message"),
            CursorShapeMessage::decode,
            CursorShapeMessage::encode,
        );
        let number = |field: &str| vector[field].as_f64().expect("a number");
        let shape_id = u16::try_from(vector["shapeID"].as_u64().expect("a shape id")).expect("fits u16");
        assert_eq!(
            decoded,
            CursorShapeMessage::new(
                shape_id,
                VideoSize::new(number("w"), number("h")),
                VideoPoint::new(number("hx"), number("hy")),
                from_hex(vector["bitmapHex"].as_str().expect("a hex bitmap")),
            ),
            "{label}: the decoded value drifted"
        );
    }

    // And the router must land every pinned datagram on the right variant from its first byte alone.
    for vector in &updates {
        let bytes = from_hex(vector["hex"].as_str().expect("a hex message"));
        assert!(matches!(
            CursorChannelMessage::decode(&bytes),
            Ok(CursorChannelMessage::Update(_))
        ));
    }
    for vector in &shapes {
        let bytes = from_hex(vector["hex"].as_str().expect("a hex message"));
        assert!(matches!(
            CursorChannelMessage::decode(&bytes),
            Ok(CursorChannelMessage::Shape(_))
        ));
    }
}

#[test]
fn every_pinned_swipe_nav_status_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "swipeNavStatus");
    assert_eq!(vectors.len(), 3, "the corpus pins three status pushes");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("swipeNavStatus[{index}]");
        let hex = vector["hex"].as_str().expect("a hex message");
        let decoded = assert_codec_round_trip(
            &label,
            hex,
            SwipeNavStatusMessage::decode,
            SwipeNavStatusMessage::encode,
        );
        let flag = |field: &str| vector[field].as_bool().expect("a flag");
        let fire_travel = u16::try_from(vector["fireTravel"].as_u64().expect("a travel")).expect("fits u16");
        assert_eq!(
            decoded,
            SwipeNavStatusMessage::new(
                flag("eligible"),
                flag("slowTier"),
                fire_travel,
                flag("canGoBack"),
                flag("canGoForward"),
                flag("historyKnown"),
            ),
            "{label}: the decoded value drifted"
        );
        assert_eq!(from_hex(hex).len(), SwipeNavStatusMessage::ENCODED_SIZE);
        assert!(matches!(
            CursorChannelMessage::decode(&from_hex(hex)),
            Ok(CursorChannelMessage::SwipeNavStatus(_))
        ));
    }
}

#[test]
fn every_pinned_input_event_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "inputEvent");
    assert_eq!(vectors.len(), 8, "the corpus pins eight input events");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("inputEvent[{index}]");
        let decoded = assert_codec_round_trip(
            &label,
            vector["hex"].as_str().expect("a hex message"),
            InputEvent::decode,
            InputEvent::encode,
        );
        let number = |field: &str| vector[field].as_f64().expect("a number");
        let byte = |field: &str| u8::try_from(vector[field].as_u64().expect("a byte")).expect("fits u8");
        let tag = u32::try_from(vector["tag"].as_u64().expect("a tag")).expect("fits u32");
        // Lazily, because the key and text vectors carry no coordinates at all.
        let normalized = || VideoPoint::new(number("nx"), number("ny"));
        let variant = vector["variant"].as_str().expect("a variant name");
        let button_event = || {
            input_event::MouseButtonEvent {
                button: MouseButton::from_raw(byte("button")).expect("a known button"),
                normalized: normalized(),
                click_count: byte("clickCount"),
                modifiers: InputModifiers::from_bits(byte("mods")),
            }
        };
        let expected = match variant {
            "mouseMove" => {
                InputEvent::MouseMove {
                    normalized: normalized(),
                    tag,
                }
            },
            "mouseDown" => InputEvent::MouseDown(button_event(), tag),
            "mouseUp" => InputEvent::MouseUp(button_event(), tag),
            "mouseDrag" => InputEvent::MouseDrag(button_event(), tag),
            "scroll" => {
                InputEvent::Scroll(
                    input_event::ScrollEvent {
                        dx: number("dx"),
                        dy: number("dy"),
                        normalized: normalized(),
                        scroll_phase: byte("scrollPhase"),
                        momentum_phase: byte("momentumPhase"),
                        continuous: vector["continuous"].as_bool().expect("a continuous flag"),
                    },
                    tag,
                )
            },
            "key" => {
                InputEvent::Key(
                    input_event::KeyEvent {
                        key_code: u16::try_from(vector["keyCode"].as_u64().expect("a keycode"))
                            .expect("fits u16"),
                        down: vector["down"].as_bool().expect("a down flag"),
                        modifiers: InputModifiers::from_bits(byte("mods")),
                    },
                    tag,
                )
            },
            "text" => InputEvent::Text(vector["text"].as_str().expect("a text").to_owned(), tag),
            other => panic!("{label}: unknown variant {other:?}"),
        };
        assert_eq!(decoded, expected, "{label}: the decoded value drifted");
        assert_eq!(decoded.tag(), tag, "{label}: the self-inject tag drifted");
    }
}

#[test]
fn every_pinned_audio_datagram_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "audioWire");
    assert_eq!(vectors.len(), 3, "the corpus pins three audio datagrams");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("audioWire[{index}]");
        let decoded = assert_codec_round_trip(
            &label,
            vector["hex"].as_str().expect("a hex datagram"),
            AudioChannelMessage::decode,
            AudioChannelMessage::encode,
        );
        let seq = u32::try_from(vector["seq"].as_u64().expect("a seq")).expect("fits u32");
        let host_send_ts_millis =
            u32::try_from(vector["hostTs"].as_u64().expect("a timestamp")).expect("fits u32");
        let expected = if vector["variant"]
            .as_str()
            .expect("a variant name")
            .starts_with("config")
        {
            let format_id = u8::try_from(vector["format"].as_u64().expect("a format")).expect("fits u8");
            AudioChannelMessage::Config {
                seq,
                host_send_ts_millis,
                config: AudioStreamConfig::new(
                    AudioWireFormat::from_raw(format_id).expect("a known format"),
                    u32::try_from(vector["sampleRate"].as_u64().expect("a rate")).expect("fits u32"),
                    u8::try_from(vector["channels"].as_u64().expect("a channel count")).expect("fits u8"),
                    from_hex(vector["cookieHex"].as_str().expect("a hex cookie")),
                ),
            }
        } else {
            AudioChannelMessage::Frame {
                seq,
                host_send_ts_millis,
                payload: from_hex(vector["payloadHex"].as_str().expect("a hex payload")),
            }
        };
        assert_eq!(decoded, expected, "{label}: the decoded value drifted");
    }
}

#[test]
fn every_pinned_video_control_message_matches_in_both_directions() {
    // Thirty vectors across twenty-eight type bytes: the widest group in the corpus, and the one a
    // port is most likely to drift on, because most of its variants are pure field order.
    let root = corpus();
    let vectors = group_of(&root, "videoControl");
    assert_eq!(vectors.len(), 30, "the corpus pins thirty control messages");

    let mut seen_types = Vec::new();
    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("videoControl[{index}] {}", vector["variant"]);
        let decoded = assert_codec_round_trip(
            &label,
            vector["hex"].as_str().expect("a hex message"),
            VideoControlMessage::decode,
            VideoControlMessage::encode,
        );
        seen_types.push(decoded.message_type());
        assert_control_matches(&label, vector, &decoded);
    }
    seen_types.sort_unstable();
    seen_types.dedup();
    assert_eq!(
        seen_types,
        (1..=28).collect::<Vec<u8>>(),
        "the corpus must still cover every type byte, with no gap for a port to drift into"
    );
}

/// Checks the DECODED value against the corpus's own field record — not just that the bytes survive
/// a round trip. A codec that consistently swapped two same-width fields would pass the round trip
/// and fail here.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per pinned variant; the corpus's field names are the point"
)]
fn assert_control_matches(label: &str, vector: &Value, decoded: &VideoControlMessage) {
    let u64_of = |field: &str| vector[field].as_u64().expect("an integer");
    let u32_of = |field: &str| u32::try_from(u64_of(field)).expect("fits u32");
    let u16_of = |field: &str| u16::try_from(u64_of(field)).expect("fits u16");
    let u8_of = |field: &str| u8::try_from(u64_of(field)).expect("fits u8");
    let f64_of = |field: &str| vector[field].as_f64().expect("a number");
    let bool_of = |field: &str| vector[field].as_bool().expect("a flag");
    let str_of = |value: &Value, field: &str| value[field].as_str().expect("a string").to_owned();

    let expected = match vector["variant"].as_str().expect("a variant name") {
        "hello" => {
            VideoControlMessage::Hello {
                protocol_version: u16_of("version"),
                requested_window_id: u32_of("windowID"),
                viewport: VideoSize::new(f64_of("vw"), f64_of("vh")),
            }
        },
        "helloAck" => {
            VideoControlMessage::HelloAck {
                accepted: bool_of("accepted"),
                stream_id: u32_of("streamID"),
                capture_width: u16_of("cw"),
                capture_height: u16_of("ch"),
                window_bounds_cg: VideoRect::xywh(f64_of("bx"), f64_of("by"), f64_of("bw"), f64_of("bh")),
                full_range: bool_of("fullRange"),
            }
        },
        "bye" => VideoControlMessage::Bye,
        "resizeRequest" => {
            VideoControlMessage::ResizeRequest {
                desired: VideoSize::new(f64_of("w"), f64_of("h")),
                epoch: u32_of("epoch"),
            }
        },
        "resizeAck" => {
            VideoControlMessage::ResizeAck {
                capture_width: u16_of("cw"),
                capture_height: u16_of("ch"),
                epoch: u32_of("epoch"),
            }
        },
        "keepalive" => VideoControlMessage::Keepalive,
        "listWindows" => VideoControlMessage::ListWindows,
        "windowList" => {
            VideoControlMessage::WindowList(
                vector["windows"]
                    .as_array()
                    .expect("an array of windows")
                    .iter()
                    .map(|window| {
                        WindowSummary {
                            window_id: u32::try_from(window["windowID"].as_u64().expect("an id"))
                                .expect("fits u32"),
                            app_name: str_of(window, "appName"),
                            title: str_of(window, "title"),
                            width: u16::try_from(window["width"].as_u64().expect("a width"))
                                .expect("fits u16"),
                            height: u16::try_from(window["height"].as_u64().expect("a height"))
                                .expect("fits u16"),
                        }
                    })
                    .collect(),
            )
        },
        "focusWindow" => VideoControlMessage::FocusWindow,
        "streamCadence" => VideoControlMessage::StreamCadence { fps: u16_of("fps") },
        "listSystemDialogs" => VideoControlMessage::ListSystemDialogs,
        "systemDialogList" => {
            VideoControlMessage::SystemDialogList(
                vector["dialogs"]
                    .as_array()
                    .expect("an array of dialogs")
                    .iter()
                    .map(|dialog| {
                        SystemDialogSummary {
                            window_id: u32::try_from(dialog["windowID"].as_u64().expect("an id"))
                                .expect("fits u32"),
                            owner: str_of(dialog, "owner"),
                            title: str_of(dialog, "title"),
                            width: u16::try_from(dialog["width"].as_u64().expect("a width"))
                                .expect("fits u16"),
                            height: u16::try_from(dialog["height"].as_u64().expect("a height"))
                                .expect("fits u16"),
                            is_secure: dialog["isSecure"].as_bool().expect("a flag"),
                        }
                    })
                    .collect(),
            )
        },
        "scrollOffset" => {
            VideoControlMessage::ScrollOffset {
                dx: i16::try_from(vector["dx"].as_i64().expect("a signed dx")).expect("fits i16"),
                dy: i16::try_from(vector["dy"].as_i64().expect("a signed dy")).expect("fits i16"),
                band_top: u16_of("bandTop"),
                band_bottom: u16_of("bandBottom"),
            }
        },
        "contentMask" => {
            VideoControlMessage::ContentMask(
                vector["rects"]
                    .as_array()
                    .expect("an array of rects")
                    .iter()
                    .map(|rect| {
                        let field = |name: &str| {
                            u16::try_from(rect[name].as_u64().expect("a coordinate")).expect("fits u16")
                        };
                        MaskRect {
                            x: field("x"),
                            y: field("y"),
                            width: field("w"),
                            height: field("h"),
                        }
                    })
                    .collect(),
            )
        },
        "displayMax" => {
            VideoControlMessage::DisplayMax {
                width: u16_of("maxWidth"),
                height: u16_of("maxHeight"),
            }
        },
        "windowFeedSubscribe" => {
            VideoControlMessage::WindowFeedSubscribe {
                known_generation: u32_of("knownGeneration"),
            }
        },
        "windowFeedSnapshot" => {
            VideoControlMessage::WindowFeedSnapshot {
                generation: u32_of("generation"),
                chunk_index: u8_of("chunkIndex"),
                chunk_count: u8_of("chunkCount"),
                records: vector["records"]
                    .as_array()
                    .expect("an array of records")
                    .iter()
                    .map(|record| {
                        HostWindowRecord {
                            window_id: u32::try_from(record["windowID"].as_u64().expect("an id"))
                                .expect("fits u32"),
                            width_pt: u16::try_from(record["width"].as_u64().expect("a width"))
                                .expect("fits u16"),
                            height_pt: u16::try_from(record["height"].as_u64().expect("a height"))
                                .expect("fits u16"),
                            flags: HostWindowFlags::from_bits(
                                u8::try_from(record["flags"].as_u64().expect("flags")).expect("fits u8"),
                            ),
                            display_index: u8::try_from(record["display"].as_u64().expect("a display"))
                                .expect("fits u8"),
                            bundle_id: str_of(record, "bundleID"),
                            app_name: str_of(record, "appName"),
                            title: str_of(record, "title"),
                        }
                    })
                    .collect(),
            }
        },
        "windowFeedCurrent" => {
            VideoControlMessage::WindowFeedCurrent {
                generation: u32_of("generation"),
            }
        },
        "appIconRequest" => {
            VideoControlMessage::AppIconRequest {
                size_px: u16_of("sizePx"),
                bundle_id: str_of(vector, "bundleID"),
            }
        },
        "blobChunk" => {
            VideoControlMessage::BlobChunk {
                blob_kind: u8_of("blobKind"),
                // The corpus carries the u64 id as a STRING, because JSON numbers cannot hold it.
                blob_id: vector["blobID"]
                    .as_str()
                    .expect("a blob id")
                    .parse()
                    .expect("a u64 blob id"),
                meta_a: u16_of("metaA"),
                meta_b: u16_of("metaB"),
                chunk_index: u8_of("chunkIndex"),
                chunk_count: u8_of("chunkCount"),
                bytes: from_hex(vector["bytesHex"].as_str().expect("hex bytes")),
            }
        },
        "windowPreviewRequest" => {
            VideoControlMessage::WindowPreviewRequest {
                window_id: u32_of("windowID"),
                max_width_px: u16_of("maxWidthPx"),
            }
        },
        "listDisplays" => VideoControlMessage::ListDisplays,
        "displayList" => {
            VideoControlMessage::DisplayList(
                vector["displays"]
                    .as_array()
                    .expect("an array of displays")
                    .iter()
                    .map(|display| {
                        DisplaySummary {
                            display_id: u32::try_from(display["displayID"].as_u64().expect("an id"))
                                .expect("fits u32"),
                            width: u16::try_from(display["width"].as_u64().expect("a width"))
                                .expect("fits u16"),
                            height: u16::try_from(display["height"].as_u64().expect("a height"))
                                .expect("fits u16"),
                            is_main: display["isMain"].as_bool().expect("a flag"),
                        }
                    })
                    .collect(),
            )
        },
        "helloDisplay" => {
            VideoControlMessage::HelloDisplay {
                protocol_version: u16_of("version"),
                requested_display_id: u32_of("displayID"),
                viewport: VideoSize::new(f64_of("vw"), f64_of("vh")),
            }
        },
        "streamSettings" => {
            VideoControlMessage::StreamSettings {
                fps_cap: u8_of("fpsCap"),
                bitrate_ceiling_bps: u32_of("bitrateCeilingBps"),
            }
        },
        "audioControlOn" | "audioControlOff" => {
            VideoControlMessage::AudioControl {
                enabled: bool_of("enabled"),
            }
        },
        "hostStats" => {
            VideoControlMessage::HostStats {
                rtt_tenths_millis: u16_of("rttTenthsMillis"),
                encode_tenths_millis: u16_of("encodeTenthsMillis"),
            }
        },
        "privacyModeOn" | "privacyModeOff" => {
            VideoControlMessage::PrivacyMode {
                enabled: bool_of("enabled"),
            }
        },
        other => panic!("{label}: unknown variant {other:?}"),
    };
    assert_eq!(*decoded, expected, "{label}: the decoded value drifted");
}

#[test]
fn every_pinned_fragment_header_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "fragmentEncode");
    assert_eq!(vectors.len(), 3, "the corpus pins three fragment vectors");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("fragmentEncode[{index}]");
        let hex = vector["hex"].as_str().expect("a hex datagram");
        let decoded = assert_codec_round_trip(&label, hex, FrameFragment::decode, FrameFragment::encode);

        let u32_of = |key: &str| u32::try_from(vector[key].as_u64().expect("a number")).expect("fits u32");
        let u16_of = |key: &str| u16::try_from(vector[key].as_u64().expect("a number")).expect("fits u16");
        // Field by field rather than against a rebuilt struct: a swapped pair of same-width fields
        // would round-trip its own bytes perfectly and only show up here.
        assert_eq!(
            decoded.header.stream_seq,
            u32_of("streamSeq"),
            "{label}.streamSeq"
        );
        assert_eq!(decoded.header.frame_id, u32_of("frameID"), "{label}.frameID");
        assert_eq!(
            decoded.header.frag_index,
            u16_of("fragIndex"),
            "{label}.fragIndex"
        );
        assert_eq!(
            decoded.header.frag_count,
            u16_of("fragCount"),
            "{label}.fragCount"
        );
        assert_eq!(
            decoded.header.flags.bits(),
            u8::try_from(vector["flags"].as_u64().expect("a number")).expect("fits u8"),
            "{label}.flags"
        );
        assert_eq!(
            decoded.header.host_send_ts_millis,
            u32_of("hostTs"),
            "{label}.hostTs"
        );
        assert_eq!(
            to_hex(&decoded.payload),
            vector["payloadHex"].as_str().expect("a hex payload"),
            "{label}.payload"
        );
    }
}

#[test]
fn the_pinned_mux_prefix_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "muxBare");
    assert_eq!(vectors.len(), 1, "the corpus pins one bare-prefix vector");

    for (index, vector) in vectors.iter().enumerate() {
        let hex = vector["hex"].as_str().expect("a hex datagram");
        let bytes = from_hex(hex);
        let (channel_id, payload) = mux_header::decode(&bytes).expect("the pinned bytes must decode");
        assert_eq!(
            u64::from(channel_id),
            vector["channelID"].as_u64().expect("a number"),
            "muxBare[{index}].channelID"
        );
        assert_eq!(
            to_hex(payload),
            vector["payloadHex"].as_str().expect("a hex payload"),
            "muxBare[{index}].payload"
        );
        assert_eq!(
            to_hex(&mux_header::encode(channel_id, payload)),
            hex,
            "muxBare[{index}]: re-encoding drifted"
        );
    }
}

#[test]
fn the_pinned_muxed_fragment_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "muxFragment");
    assert_eq!(vectors.len(), 1, "the corpus pins one muxed-fragment vector");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("muxFragment[{index}]");
        let hex = vector["hex"].as_str().expect("a hex datagram");
        let bytes = from_hex(hex);
        let (header, payload) = MuxFrameFragmentHeader::decode(&bytes).expect("the pinned bytes must decode");

        let u32_of = |key: &str| u32::try_from(vector[key].as_u64().expect("a number")).expect("fits u32");
        let u16_of = |key: &str| u16::try_from(vector[key].as_u64().expect("a number")).expect("fits u16");
        // The channel id sits where the plain header's `stream_seq` does, and this layout carries
        // no host timestamp though both headers are 19 bytes. Checking the fields individually is
        // what would catch the two decoders being confused for each other.
        assert_eq!(header.channel_id, u32_of("channelID"), "{label}.channelID");
        assert_eq!(header.stream_seq, u32_of("streamSeq"), "{label}.streamSeq");
        assert_eq!(header.frame_id, u32_of("frameID"), "{label}.frameID");
        assert_eq!(header.frag_index, u16_of("fragIndex"), "{label}.fragIndex");
        assert_eq!(header.frag_count, u16_of("fragCount"), "{label}.fragCount");
        assert_eq!(
            header.flags.bits(),
            u8::try_from(vector["flags"].as_u64().expect("a number")).expect("fits u8"),
            "{label}.flags"
        );
        assert_eq!(
            to_hex(&payload),
            vector["payloadHex"].as_str().expect("a hex payload"),
            "{label}.payload"
        );
        assert_eq!(
            to_hex(&header.encode(&payload)),
            hex,
            "{label}: re-encoding drifted"
        );
    }
}

#[test]
fn every_pinned_adaptive_group_size_matches() {
    let root = corpus();
    let vectors = group_of(&root, "adaptiveGroupSize");
    assert_eq!(
        vectors.len(),
        9,
        "the corpus pins every tier plus the reserved slots"
    );

    for (index, vector) in vectors.iter().enumerate() {
        let tier = u8::try_from(vector["tier"].as_u64().expect("a tier")).expect("fits u8");
        let default = usize::try_from(vector["def"].as_u64().expect("a default")).expect("fits usize");
        // `null` is the OFF tier, and it is the one value a `usize` cannot spell — the corpus
        // distinguishing "no parity" from "a group of zero" is why the Rust returns an `Option`.
        let pinned = vector["groupSize"]
            .as_u64()
            .map(|value| usize::try_from(value).expect("fits usize"));
        assert_eq!(
            adaptive_fec::group_size(tier, default),
            pinned,
            "adaptiveGroupSize[{index}]: tier {tier} at default {default} drifted"
        );
    }
}

#[test]
fn every_pinned_adaptive_tier_step_matches() {
    let root = corpus();
    let vectors = group_of(&root, "adaptiveTier");
    assert_eq!(
        vectors.len(),
        80,
        "the corpus sweeps the loss ladder against every previous tier"
    );

    for (index, vector) in vectors.iter().enumerate() {
        // The loss is pinned as an `f64` BIT PATTERN, not a decimal: a threshold comparison that
        // drifted by one ulp would still print as 0.005.
        let loss = f64::from_bits(vector["lossBits"].as_u64().expect("a loss bit pattern"));
        let previous = u8::try_from(vector["prevTier"].as_u64().expect("a tier")).expect("fits u8");
        let allow_off = vector["allowOff"].as_bool().expect("a flag");
        let pinned = u8::try_from(vector["tier"].as_u64().expect("a tier")).expect("fits u8");
        assert_eq!(
            adaptive_fec::tier_for_loss(loss, previous, allow_off),
            pinned,
            "adaptiveTier[{index}]: loss {loss} from tier {previous} (allow_off {allow_off}) drifted"
        );
    }
}

#[test]
fn every_pinned_recovery_message_matches_in_both_directions() {
    let root = corpus();
    let vectors = group_of(&root, "recovery");
    assert_eq!(vectors.len(), 6, "the corpus pins all six variants");

    for (index, vector) in vectors.iter().enumerate() {
        let label = format!("recovery[{index}]");
        let hex = vector["hex"].as_str().expect("a hex message");
        let decoded = assert_codec_round_trip(&label, hex, RecoveryMessage::decode, RecoveryMessage::encode);

        let u32_of = |key: &str| u32::try_from(vector[key].as_u64().expect("a number")).expect("fits u32");
        let expected = match vector["variant"].as_str().expect("a variant name") {
            "ack" => {
                RecoveryMessage::Ack {
                    stream_seq: u32_of("streamSeq"),
                }
            },
            "requestLTRRefresh" => {
                RecoveryMessage::RequestLtrRefresh {
                    from_frame_id: u32_of("from"),
                    to_frame_id: u32_of("to"),
                    last_decoded_frame_id: u32_of("lastDecoded"),
                }
            },
            "requestIDR" => {
                RecoveryMessage::RequestIdr {
                    last_decoded_frame_id: u32_of("lastDecoded"),
                }
            },
            "requestCursorShape" => {
                RecoveryMessage::RequestCursorShape {
                    shape_id: u16::try_from(vector["shapeID"].as_u64().expect("a number")).expect("fits u16"),
                }
            },
            "networkStats" => {
                RecoveryMessage::NetworkStats(NetworkStatsReport {
                    frames_received: u32_of("framesReceived"),
                    fec_recovered: u32_of("fecRecovered"),
                    unrecovered: u32_of("unrecovered"),
                    latest_host_send_ts: u32_of("latestHostSendTs"),
                    client_hold_ms: u32_of("clientHoldMs"),
                    owd_jitter_micros: u32_of("owdJitterMicros"),
                    owd_trend_milli: u32_of("owdTrendMilli"),
                    owd_trend_flags: u32_of("owdTrendFlags"),
                    pacer_late_frames: u32_of("pacerLateFrames"),
                    pacer_present_gaps: u32_of("pacerPresentGaps"),
                    pacer_depth: u32_of("pacerDepth"),
                })
            },
            "requestFragments" => {
                RecoveryMessage::RequestFragments {
                    frame_id: u32_of("frameID"),
                    frag_indices: vector["fragIndices"]
                        .as_array()
                        .expect("an index list")
                        .iter()
                        .map(|entry| u16::try_from(entry.as_u64().expect("a number")).expect("fits u16"))
                        .collect(),
                }
            },
            other => panic!("{label}: unknown variant {other:?}"),
        };
        assert_eq!(decoded, expected, "{label}: the decoded value drifted");
    }
}
