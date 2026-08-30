//! The byte-pin the frozen `muxEnvelopes` block is held by.
//!
//! MuxEnvelope.swift, under Sources/SlopDeskProtocol/Mux — Swift's `MuxFrame` and
//! `MuxEnvelopeCodec` — is deleted, and with it the only thing that could EMIT this block of
//! `golden/golden_vectors.json` from a live codec. So the key moves to `FROZEN_KEYS` in
//! `slopdesk-devtools`' golden gate, and a frozen key is pinned by a suite that replays it or it is
//! not pinned at all: without this file the twelve records would sit in the corpus as bytes nothing
//! produces and nothing checks.
//!
//! ## Why this exists next to `golden_vectors.rs`, which also reads the block
//! That file's stage-2 section goes DECODE-first: it reads each record's hex, checks the fields it
//! decoded against the record's own field values, and re-encodes. This one goes the other way — it
//! CONSTRUCTS a [`MuxFrame`] out of the record's fields and asserts the encoder produces the
//! record's hex. The pinned bytes are never the input, so an encoder and a decoder that agreed with
//! each other on a wrong field order — which a round-trip cannot tell from a right one — fail here.
//! That is the direction the block loses when the Swift emitter goes away: the corpus used to be
//! re-derived from a codec on every `just golden`, and this is what re-derives it now.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
#![expect(
    clippy::indexing_slicing,
    reason = "serde_json's Index panics on a missing key, which is the failure this test wants when the \
              corpus and the codec disagree about a field name"
)]

use core::fmt::Write as _;

use serde_json::Value;
use slopdesk_wire::{MuxCloseReason, MuxFrame};

/// The pinned corpus, read at compile time so a missing or renamed file is a build failure rather
/// than a test that silently passes with zero vectors.
const GOLDEN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../golden/golden_vectors.json"
));

/// How many envelopes the block pins.
///
/// Hard-coded rather than derived from the array, because deriving it is exactly the check that
/// cannot fail: a corpus hand-shrunk to three records would replay three records and pass. The key
/// is FROZEN — no generator will ever legitimately grow or shrink this block again — so the literal
/// is the honest expectation.
const PINNED_ENVELOPE_COUNT: usize = 12;

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
        // `write!` into the buffer rather than `push_str(&format!(…))`: one allocation for the
        // whole string instead of one per byte.
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn u32_of(value: &Value) -> u32 {
    u32::try_from(value.as_u64().expect("a non-negative integer")).expect("fits u32")
}

fn u8_of(value: &Value) -> u8 {
    u8::try_from(value.as_u64().expect("a non-negative integer")).expect("fits u8")
}

fn uuid_of(hex: &str) -> [u8; 16] {
    <[u8; 16]>::try_from(from_hex(hex).as_slice()).expect("a uuid is 16 bytes")
}

/// Builds the envelope one record DESCRIBES, using nothing from its `hex`.
///
/// Every field is read from the record's own JSON value, so the frame handed to the encoder is
/// independent of the bytes it will be compared against. An unknown kind panics rather than being
/// skipped: a record this function does not understand is a record nothing pins.
fn frame_of(kind: &str, vector: &Value) -> MuxFrame {
    let channel_id = u32_of(&vector["channelId"]);
    match kind {
        "channelOpen" => {
            MuxFrame::ChannelOpen {
                channel_id,
                session_id: uuid_of(vector["sessionIdHex"].as_str().expect("sessionIdHex")),
                last_received_seq: vector["lastReceivedSeq"].as_i64().expect("lastReceivedSeq"),
                channel_class: u8_of(&vector["channelClass"]),
                // No pinned record carries a cwd, and an ABSENT field is not an empty one — the
                // encoder writes a `u16` length for `Some("")` and nothing at all for `None`, so
                // reading a missing key as `Some(String::new())` would move two bytes.
                initial_cwd: vector["initialCwd"].as_str().map(str::to_owned),
            }
        },
        "channelOpenAck" => {
            MuxFrame::ChannelOpenAck {
                channel_id,
                accepted: vector["accepted"].as_bool().expect("accepted"),
                resume_from_seq: vector["resumeFromSeq"].as_i64().expect("resumeFromSeq"),
            }
        },
        "channelData" => {
            MuxFrame::ChannelData {
                channel_id,
                payload: from_hex(vector["payloadHex"].as_str().expect("payloadHex")),
            }
        },
        "channelClose" => {
            MuxFrame::ChannelClose {
                channel_id,
                // An absent `closeReason` is the default-encoded close with no body at all, which is
                // the shape every close had before the reason existed.
                reason: vector["closeReason"]
                    .as_u64()
                    .map_or(MuxCloseReason::Retired, |byte| {
                        MuxCloseReason::from_byte_or_retired(u8::try_from(byte).expect("fits u8"))
                    }),
            }
        },
        "windowAdjust" => {
            MuxFrame::WindowAdjust {
                channel_id,
                bytes_to_add: u32_of(&vector["bytesToAdd"]),
            }
        },
        other => panic!("the corpus pins an envelope kind this test does not build: {other:?}"),
    }
}

/// Every pinned envelope, rebuilt from its fields, encodes to the bytes the corpus holds.
#[test]
fn every_pinned_mux_envelope_encodes_to_the_bytes_swift_encoded() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["muxEnvelopes"]
        .as_array()
        .expect("muxEnvelopes is an array");

    let mut replayed = 0_usize;
    for vector in vectors {
        let hex = vector["hex"].as_str().expect("every record pins its hex");
        let kind = vector["kind"].as_str().expect("every record names its kind");
        let frame = frame_of(kind, vector);
        assert_eq!(
            to_hex(&frame.encode()),
            hex,
            "the encoder moved the wire for {kind} on channel {}",
            frame.channel_id()
        );
        // The size prediction rides the same layout and is what a flow-control window is spent
        // against, so a frame whose bytes are right and whose count is wrong still breaks a peer.
        assert_eq!(
            frame.encoded_byte_count_with_payload(frame.opaque_payload().len()),
            hex.len().div_euclid(2), // two hex digits per byte
            "the size prediction disagrees with the pinned envelope for {kind}"
        );
        replayed += 1;
    }

    assert_eq!(
        replayed,
        vectors.len(),
        "a record was pinned by nothing — every one in the block must be replayed"
    );
    assert_eq!(
        replayed, PINNED_ENVELOPE_COUNT,
        "the frozen block changed size, which nothing may do now that no generator emits it"
    );
}
