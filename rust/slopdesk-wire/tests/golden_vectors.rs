//! Byte-for-byte parity against the committed golden corpus.
//!
//! `golden/golden_vectors.json` is generated from the SWIFT codec and predates this crate, so it is
//! an oracle rather than a fixture written alongside the port: "did moving this to Rust change the
//! wire" is answered here by bytes nobody wrote for this test.
//!
//! ## Why this checks FIELDS and not only the round-trip
//! Decoding a pinned frame and re-encoding it back to the same hex proves less than it looks: a
//! decoder that read two fields in the wrong order, paired with an encoder that wrote them in the
//! same wrong order, round-trips perfectly and is still incompatible with every Swift peer. So each
//! vector's decoded fields are compared against the JSON's own field values, which the Swift
//! generator wrote independently of the hex. The round-trip is then checked too, because it is what
//! pins the ENCODER — the two together bracket the codec from both sides.
//!
//! The `workspaceWireMessages` vectors carry no per-field values, only `hex` and `wireByteCount`.
//! For those this can only assert the round-trip and the size prediction, which is stated here
//! rather than left to look like full coverage.

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
use slopdesk_wire::document::{
    HostWorkspaceState, MAX_LAYOUT_DEPTH, NewTabPosition, PaneDropEdge, PaneKind, ROOT_OBJECT_ID, SplitAxis,
    SplitWeight, VideoEndpoint, WorkspaceEntry, WorkspaceIntentOp, WorkspaceKey, WorkspaceLayoutNode,
    decode_detached_panes, decode_diff, decode_divider_weight, decode_dock_at_tab_edge, decode_flag,
    decode_identity, decode_layout, decode_move, decode_name, decode_new_session, decode_reopen_closed_tab,
    decode_reorder_tabs, decode_set_pane_video_target, decode_set_tab_layout, decode_snapshot,
    decode_spawn_detached_pane, decode_spawn_tab, decode_split, decode_swap_panes, decode_uuid,
    decode_video_target, decode_weight, decode_weights, encode_detached_panes, encode_diff,
    encode_divider_weight, encode_dock_at_tab_edge, encode_flag, encode_identity, encode_key, encode_layout,
    encode_move, encode_name, encode_new_session, encode_reopen_closed_tab, encode_reorder_tabs,
    encode_set_pane_video_target, encode_set_tab_layout, encode_snapshot, encode_spawn_detached_pane,
    encode_spawn_tab, encode_split, encode_swap_panes, encode_uuid, encode_video_target, encode_weight,
    encode_weights,
};
use slopdesk_wire::metadata::{
    AgentSessionInfo, DirEntry, GitFileChange, GitStatusPayload, HostVitals, PortInfo, ProcessInfo,
    decode_agent_session_list, decode_dir_listing, decode_git_status, decode_host_vitals, decode_port_list,
    decode_process_list, encode_agent_session_list, encode_dir_listing, encode_git_status,
    encode_host_vitals, encode_port_list, encode_process_list,
};
use slopdesk_wire::{CommandStatus, MuxCloseReason, MuxFrame, MuxFrameDecoder, WireMessage};

/// The pinned corpus, read at compile time so a missing or renamed file is a build failure rather
/// than a test that silently passes with zero vectors.
const GOLDEN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../golden/golden_vectors.json"
));

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
        // whole string instead of one per byte, which matters on the 256 KiB output vector.
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn i32_of(value: &Value) -> i32 {
    i32::try_from(value.as_i64().expect("an integer")).expect("fits i32")
}

fn u32_of(value: &Value) -> u32 {
    u32::try_from(value.as_u64().expect("a non-negative integer")).expect("fits u32")
}

fn u16_of(value: &Value) -> u16 {
    u16::try_from(value.as_u64().expect("a non-negative integer")).expect("fits u16")
}

fn uuid_of(hex: &str) -> [u8; 16] {
    <[u8; 16]>::try_from(from_hex(hex).as_slice()).expect("a uuid is 16 bytes")
}

/// An optional wire field: present only when its `has*` flag is set.
fn optional<T>(present: bool, value: T) -> Option<T> {
    present.then_some(value)
}

/// Decodes a full frame's hex, checking the length prefix agrees with the body it introduces.
fn decode_frame(hex: &str) -> WireMessage {
    let frame = from_hex(hex);
    let prefix = <[u8; 4]>::try_from(&frame[..4]).expect("a frame carries a 4-byte prefix");
    let declared = usize::try_from(u32::from_be_bytes(prefix)).expect("fits usize");
    assert_eq!(
        declared,
        frame.len() - 4,
        "the pinned prefix disagrees with the pinned body"
    );
    WireMessage::decode(&frame[4..]).expect("a pinned frame decodes")
}

/// The two halves of parity, applied to every vector that has a `hex`.
fn assert_round_trips(hex: &str, message: &WireMessage) {
    assert_eq!(
        to_hex(&message.encode()),
        hex,
        "re-encoding the decoded message changed the wire"
    );
    assert_eq!(
        message.wire_byte_count(),
        hex.len().div_euclid(2), // two hex digits per byte
        "the size prediction disagrees with the pinned frame, which would leak flow-control window"
    );
}

/// Compares one decoded message against the vector's OWN field values.
#[expect(clippy::too_many_lines, reason = "one arm per pinned message kind")]
fn assert_fields(kind: &str, vector: &Value, message: &WireMessage) {
    match (kind, message) {
        ("output", WireMessage::Output { seq, bytes }) => {
            assert_eq!(*seq, vector["seq"].as_i64().expect("seq"));
            assert_eq!(to_hex(bytes), vector["bytesHex"].as_str().expect("bytesHex"));
        },
        ("exit", WireMessage::Exit { code }) => assert_eq!(*code, i32_of(&vector["code"])),
        ("input", WireMessage::Input(bytes)) => {
            assert_eq!(to_hex(bytes), vector["bytesHex"].as_str().expect("bytesHex"));
        },
        (
            "hello",
            WireMessage::Hello {
                protocol_version,
                session_id,
                last_received_seq,
            },
        ) => {
            assert_eq!(*protocol_version, u16_of(&vector["protocolVersion"]));
            assert_eq!(
                *session_id,
                uuid_of(vector["sessionIdHex"].as_str().expect("sessionIdHex"))
            );
            assert_eq!(
                *last_received_seq,
                vector["lastReceivedSeq"].as_i64().expect("seq")
            );
        },
        (
            "resize",
            WireMessage::Resize {
                cols,
                rows,
                px_width,
                px_height,
            },
        ) => {
            assert_eq!(*cols, u16_of(&vector["cols"]));
            assert_eq!(*rows, u16_of(&vector["rows"]));
            assert_eq!(*px_width, u16_of(&vector["pxWidth"]));
            assert_eq!(*px_height, u16_of(&vector["pxHeight"]));
        },
        ("ack", WireMessage::Ack { seq }) => {
            assert_eq!(*seq, vector["seq"].as_i64().expect("seq"));
        },
        ("bye", WireMessage::Bye) | ("bell", WireMessage::Bell) => {},
        ("ping", WireMessage::Ping { timestamp_ms }) | ("pong", WireMessage::Pong { timestamp_ms }) => {
            assert_eq!(
                *timestamp_ms,
                vector["timestampMs"].as_u64().expect("timestampMs")
            );
        },
        (
            "helloAck",
            WireMessage::HelloAck {
                session_id,
                resume_from_seq,
                returning_client,
            },
        ) => {
            assert_eq!(
                *session_id,
                uuid_of(vector["sessionIdHex"].as_str().expect("sessionIdHex"))
            );
            assert_eq!(*resume_from_seq, vector["resumeFromSeq"].as_i64().expect("seq"));
            assert_eq!(
                *returning_client,
                vector["returningClient"].as_bool().expect("bool")
            );
        },
        ("title", WireMessage::Title(text)) => {
            assert_eq!(text, vector["title"].as_str().expect("title"));
        },
        ("cwd", WireMessage::Cwd(text)) | ("project_key", WireMessage::ProjectKey(text)) => {
            assert_eq!(text, vector["path"].as_str().expect("path"));
        },
        ("agent_session_intent", WireMessage::AgentSessionIntent(text)) => {
            assert_eq!(text, vector["intent"].as_str().expect("intent"));
        },
        ("foregroundProcess", WireMessage::ForegroundProcess { name }) => {
            assert_eq!(name, vector["name"].as_str().expect("name"));
        },
        ("notification", WireMessage::Notification { title, body }) => {
            assert_eq!(title, vector["title"].as_str().expect("title"));
            assert_eq!(body, vector["body"].as_str().expect("body"));
        },
        (
            "claudeStatus",
            WireMessage::ClaudeStatus {
                state,
                kind: kind_byte,
                label,
            },
        ) => {
            assert_eq!(u32::from(*state), u32_of(&vector["state"]));
            assert_eq!(u32::from(*kind_byte), u32_of(&vector["kindByte"]));
            assert_eq!(label, vector["label"].as_str().expect("label"));
        },
        ("inputEcho", WireMessage::InputEcho { enabled }) => {
            assert_eq!(*enabled, vector["enabled"].as_bool().expect("bool"));
        },
        ("progress", WireMessage::Progress { state, percent }) => {
            assert_eq!(u32::from(*state), u32_of(&vector["state"]));
            assert_eq!(u32::from(*percent), u32_of(&vector["percent"]));
        },
        ("commandStatus", WireMessage::CommandStatus(status)) => {
            match status {
                CommandStatus::Running => assert_eq!(vector["cmd"], "running"),
                CommandStatus::Idle {
                    exit_code,
                    duration_ms,
                } => {
                    assert_eq!(vector["cmd"], "idle");
                    let has_exit = vector["hasExit"].as_bool().expect("hasExit");
                    assert_eq!(*exit_code, optional(has_exit, i32_of(&vector["exitCode"])));
                    assert_eq!(*duration_ms, u32_of(&vector["durationMs"]));
                },
            }
        },
        ("project_git_status", WireMessage::ProjectGitStatus(status)) => {
            assert_eq!(status.repo_root, vector["repoRoot"].as_str().expect("repoRoot"));
            assert_eq!(status.branch, vector["branch"].as_str().expect("branch"));
            assert_eq!(status.ahead, i32_of(&vector["ahead"]));
            assert_eq!(status.behind, i32_of(&vector["behind"]));
            assert_eq!(status.stash_count, i32_of(&vector["stash"]));
            assert_eq!(status.staged, u32_of(&vector["staged"]));
            assert_eq!(status.modified, u32_of(&vector["modified"]));
            assert_eq!(status.untracked, u32_of(&vector["untracked"]));
            assert_eq!(status.conflicted, u32_of(&vector["conflicted"]));
            assert_eq!(status.changed_count, u32_of(&vector["changed"]));
        },
        ("requestBlockOutput", WireMessage::RequestBlockOutput { index }) => {
            assert_eq!(*index, u32_of(&vector["index"]));
        },
        ("blockOutput", WireMessage::BlockOutput { index, output }) => {
            assert_eq!(*index, u32_of(&vector["index"]));
            assert_eq!(to_hex(output), vector["outputHex"].as_str().expect("outputHex"));
        },
        (
            "commandBlock",
            WireMessage::CommandBlock {
                index,
                exit_code,
                duration_ms,
                complete,
                output_len,
                command_text,
                prompt_ordinal,
            },
        ) => {
            assert_eq!(*index, u32_of(&vector["index"]));
            let has_exit = vector["hasExit"].as_bool().expect("hasExit");
            assert_eq!(*exit_code, optional(has_exit, i32_of(&vector["exitCode"])));
            let has_duration = vector["hasDuration"].as_bool().expect("hasDuration");
            assert_eq!(
                *duration_ms,
                optional(has_duration, u32_of(&vector["durationMs"]))
            );
            assert_eq!(*complete, vector["complete"].as_bool().expect("complete"));
            assert_eq!(*output_len, u32_of(&vector["outputLen"]));
            assert_eq!(command_text, vector["commandText"].as_str().expect("commandText"));
            assert_eq!(*prompt_ordinal, u32_of(&vector["promptOrdinal"]));
        },
        (
            "metadataRequest",
            WireMessage::MetadataRequest {
                request_id,
                verb,
                payload,
            },
        ) => {
            assert_eq!(*request_id, u32_of(&vector["requestId"]));
            assert_eq!(u32::from(*verb), u32_of(&vector["verb"]));
            assert_eq!(
                to_hex(payload),
                vector["payloadHex"].as_str().expect("payloadHex")
            );
        },
        (
            "metadataResponse",
            WireMessage::MetadataResponse {
                request_id,
                status,
                payload,
            },
        ) => {
            assert_eq!(*request_id, u32_of(&vector["requestId"]));
            assert_eq!(u32::from(*status), u32_of(&vector["status"]));
            assert_eq!(
                to_hex(payload),
                vector["payloadHex"].as_str().expect("payloadHex")
            );
        },
        (other, decoded) => {
            panic!("vector kind {other:?} decoded to an unexpected variant: {decoded:?}")
        },
    }
}

/// Every vector in the corpus that names its kind and its field values.
#[test]
fn the_pinned_terminal_corpus_decodes_to_the_pinned_fields_and_re_encodes_identically() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let groups = [
        "terminalWireMessages",
        "blocksWireMessages",
        "metadataWireMessages",
    ];

    let mut checked = 0_usize;
    for group in groups {
        let vectors = golden[group]
            .as_array()
            .unwrap_or_else(|| panic!("{group} is an array"));
        assert!(
            !vectors.is_empty(),
            "{group} must not be empty — an empty corpus proves nothing"
        );
        for vector in vectors {
            let hex = vector["hex"].as_str().expect("every vector pins its hex");
            let kind = vector["kind"].as_str().expect("every vector names its kind");
            let message = decode_frame(hex);
            assert_fields(kind, vector, &message);
            assert_round_trips(hex, &message);
            checked += 1;
        }
    }
    // 44 terminal + 9 blocks + 10 metadata as of this writing. Asserted so that a corpus that
    // silently shrank — a regenerate that dropped a group — cannot read as a pass.
    assert_eq!(
        checked, 63,
        "the corpus changed size; confirm the change was intended"
    );
}

/// The workspace vectors, which pin only bytes and size.
#[test]
fn the_pinned_workspace_corpus_round_trips_and_matches_its_pinned_sizes() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["workspaceWireMessages"]
        .as_array()
        .expect("workspaceWireMessages is an array");
    assert!(!vectors.is_empty(), "an empty corpus proves nothing");

    for vector in vectors {
        let hex = vector["hex"].as_str().expect("every vector pins its hex");
        let name = vector["name"].as_str().unwrap_or("<unnamed>");
        let message = decode_frame(hex);
        assert_eq!(
            to_hex(&message.encode()),
            hex,
            "re-encoding changed the wire for {name}"
        );
        // This corpus pins the size EXPLICITLY, so it is an independent check rather than the
        // derived one the terminal groups get.
        let expected =
            usize::try_from(vector["wireByteCount"].as_u64().expect("wireByteCount")).expect("fits usize");
        assert_eq!(
            message.wire_byte_count(),
            expected,
            "size prediction wrong for {name}"
        );
    }
    assert_eq!(
        vectors.len(),
        10,
        "the corpus changed size; confirm the change was intended"
    );
}

/// An unknown workspace kind byte and an unknown metadata verb must both survive the codec
/// untouched.
///
/// The corpus pins `eventUnknownKind` (0xFA) and `requestUnknownVerb` (0xFA) precisely because
/// forward-tolerance is the property that lets a new verb ship without a wire version bump. A
/// decoder that validated those bytes would pass every other test here and break the next release.
#[test]
fn the_pinned_unknown_discriminants_are_carried_verbatim() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["workspaceWireMessages"]
        .as_array()
        .expect("workspaceWireMessages is an array");

    let mut seen = 0_usize;
    for vector in vectors {
        let hex = vector["hex"].as_str().expect("hex");
        match vector["name"].as_str() {
            Some("eventUnknownKind") => {
                let WireMessage::WorkspaceEvent { kind, .. } = decode_frame(hex) else {
                    panic!("eventUnknownKind is a workspaceEvent")
                };
                assert_eq!(kind, 0xFA, "an unknown kind must reach the consumer unclamped");
                seen += 1;
            },
            Some("requestUnknownVerb") => {
                let WireMessage::WorkspaceRequest { verb, .. } = decode_frame(hex) else {
                    panic!("requestUnknownVerb is a workspaceRequest")
                };
                assert_eq!(verb, 0xFA, "an unknown verb must reach the consumer unclamped");
                seen += 1;
            },
            _ => {},
        }
    }
    assert_eq!(
        seen, 2,
        "both forward-tolerance vectors must still be in the corpus"
    );
}

// ---------------------------------------------------------------------------------------------- //
// The mux envelope (stage 2)
// ---------------------------------------------------------------------------------------------- //

/// Decodes a full mux envelope's hex, checking the length prefix agrees with the inner run it
/// introduces.
fn decode_mux(hex: &str) -> MuxFrame {
    let frame = from_hex(hex);
    let prefix = <[u8; 4]>::try_from(&frame[..4]).expect("an envelope carries a 4-byte prefix");
    let declared = usize::try_from(u32::from_be_bytes(prefix)).expect("fits usize");
    assert_eq!(
        declared,
        frame.len() - 4,
        "the pinned prefix disagrees with the pinned inner run"
    );
    MuxFrame::decode(&frame[4..]).expect("a pinned envelope decodes")
}

/// Compares one decoded envelope against the vector's OWN field values.
fn assert_mux_fields(kind: &str, vector: &Value, frame: &MuxFrame) {
    assert_eq!(
        frame.channel_id(),
        u32_of(&vector["channelId"]),
        "channelId disagrees"
    );
    match (kind, frame) {
        (
            "channelOpen",
            MuxFrame::ChannelOpen {
                session_id,
                last_received_seq,
                channel_class,
                initial_cwd,
                ..
            },
        ) => {
            assert_eq!(
                *session_id,
                uuid_of(vector["sessionIdHex"].as_str().expect("sessionIdHex"))
            );
            assert_eq!(
                *last_received_seq,
                vector["lastReceivedSeq"].as_i64().expect("lastReceivedSeq")
            );
            assert_eq!(
                u64::from(*channel_class),
                vector["channelClass"].as_u64().expect("channelClass")
            );
            // The class byte is carried RAW, so the 255 vector must survive as 255 rather than
            // being clamped to a class this build routes.
            assert_eq!(
                initial_cwd.as_deref(),
                vector["initialCwd"].as_str(),
                "an absent cwd in the corpus must decode absent"
            );
        },
        (
            "channelOpenAck",
            MuxFrame::ChannelOpenAck {
                accepted,
                resume_from_seq,
                ..
            },
        ) => {
            assert_eq!(*accepted, vector["accepted"].as_bool().expect("accepted"));
            assert_eq!(
                *resume_from_seq,
                vector["resumeFromSeq"].as_i64().expect("resumeFromSeq")
            );
        },
        ("channelData", MuxFrame::ChannelData { payload, .. }) => {
            assert_eq!(
                to_hex(payload),
                vector["payloadHex"].as_str().expect("payloadHex"),
                "the inner frame must be carried verbatim"
            );
        },
        ("channelClose", MuxFrame::ChannelClose { reason, .. }) => {
            // An absent `closeReason` in the corpus is the default-encoded, empty-bodied close.
            let expected = vector["closeReason"]
                .as_u64()
                .map_or(MuxCloseReason::Retired, |byte| {
                    MuxCloseReason::from_byte_or_retired(u8::try_from(byte).expect("fits u8"))
                });
            assert_eq!(*reason, expected);
        },
        ("windowAdjust", MuxFrame::WindowAdjust { bytes_to_add, .. }) => {
            assert_eq!(*bytes_to_add, u32_of(&vector["bytesToAdd"]));
        },
        (other, decoded) => panic!("vector kind {other:?} decoded as {decoded:?}"),
    }
}

/// Byte-for-byte parity for the mux envelope, checked from BOTH sides.
///
/// Same reasoning as the terminal corpus: a decoder that reads two fields in the wrong order,
/// paired with an encoder that writes them in the same wrong order, round-trips perfectly and is
/// incompatible with every Swift peer. So each vector's decoded fields are compared against the
/// JSON's own values first, and the re-encode is what pins the encoder.
///
/// COVERAGE GAP, stated rather than left to look complete: no pinned vector carries an
/// `initialCwd`, so the corpus does not exercise the optional cwd field, its `u16` length prefix or
/// its strict-UTF-8 rule. Those are covered by `mux::envelope`'s own round-trip and malformed-input
/// tests instead — which is a weaker pin, because they were written alongside the port.
#[test]
fn the_pinned_mux_corpus_decodes_to_the_pinned_fields_and_re_encodes_identically() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["muxEnvelopes"]
        .as_array()
        .expect("muxEnvelopes is an array");
    assert!(!vectors.is_empty(), "an empty corpus proves nothing");

    for vector in vectors {
        let hex = vector["hex"].as_str().expect("every vector pins its hex");
        let kind = vector["kind"].as_str().expect("every vector pins its kind");
        let frame = decode_mux(hex);
        assert_mux_fields(kind, vector, &frame);
        assert_eq!(
            to_hex(&frame.encode()),
            hex,
            "re-encoding the decoded envelope changed the wire for {kind}"
        );
    }
    assert_eq!(
        vectors.len(),
        12,
        "the corpus changed size; confirm the change was intended"
    );
}

/// The whole pinned corpus, concatenated and fed to the streaming decoder one byte at a time.
///
/// `MuxFrame::decode` is handed an inner run whose boundary the test computed; this is the only
/// check that the DECODER finds the same boundaries in a byte stream that carries no message
/// framing of its own. A prefix read that was off by one would pass every field assertion above and
/// desynchronise the moment two frames shared a read.
#[test]
fn the_pinned_mux_corpus_survives_being_delivered_one_byte_at_a_time() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["muxEnvelopes"]
        .as_array()
        .expect("muxEnvelopes is an array");

    let mut stream = Vec::new();
    let mut expected = Vec::new();
    for vector in vectors {
        let hex = vector["hex"].as_str().expect("hex");
        stream.extend_from_slice(&from_hex(hex));
        expected.push(decode_mux(hex));
    }

    // An empty corpus section would make every assertion below compare two empty vectors and pass,
    // and this test is the only place the decoder's boundary search is driven by a byte stream that
    // carries no framing of its own — so a vacuous pass here leaves that path unchecked entirely.
    // Two is the floor the test's own premise needs: one frame cannot share a read with anything.
    assert!(
        expected.len() >= 2,
        "muxEnvelopes must pin at least two frames — one frame cannot share a read"
    );

    let mut decoder = MuxFrameDecoder::new();
    let mut collected = Vec::new();
    for &byte in &stream {
        decoder.append(&[byte]);
        while let Some(frame) = decoder.next_frame().expect("no decode fault") {
            collected.push(frame);
        }
    }
    assert_eq!(collected, expected);
    assert_eq!(decoder.next_frame().expect("no decode fault"), None);
}

// ---------------------------------------------------------------------------------------------- //
// The metadata payload codecs (stage 3)
// ---------------------------------------------------------------------------------------------- //

/// Decodes one pinned metadata payload, asserts its fields against values written out HERE, and
/// hands back the re-encoding.
///
/// The expected values are transcribed from each vector's own `note` and read off the pinned hex by
/// hand, because — unlike the terminal and mux groups — this group pins only `hex`, `kind` and
/// `note`, with no machine-readable field values. Transcribing them is what stops this from
/// degenerating into a round-trip test, which a decoder and encoder that agree on the WRONG field
/// order would pass.
#[expect(clippy::too_many_lines, reason = "one arm per pinned payload kind")]
fn round_trip_metadata(kind: &str, note: &str, body: &[u8]) -> Vec<u8> {
    match kind {
        "processList" => {
            let items = decode_process_list(body).expect("a pinned process list decodes");
            if note == "empty" {
                assert!(items.is_empty());
            } else {
                assert_eq!(items, vec![
                    ProcessInfo {
                        pid: 16_909_060,
                        uptime_sec: 42,
                        name: "-zsh".to_owned(),
                    },
                    ProcessInfo {
                        pid: 3_735_928_559,
                        uptime_sec: 3600,
                        name: "claude 🚀".to_owned(),
                    },
                ]);
            }
            encode_process_list(&items)
        },
        "portList" => {
            let items = decode_port_list(body).expect("a pinned port list decodes");
            if note.starts_with("empty") {
                assert!(items.is_empty());
            } else {
                assert_eq!(items, vec![
                    PortInfo {
                        port: 8080,
                        proto: 0,
                        proc_name: "node".to_owned(),
                    },
                    PortInfo {
                        port: 53,
                        proto: 1,
                        proc_name: "mDNSResponder".to_owned(),
                    },
                ]);
            }
            encode_port_list(&items)
        },
        "dirListing" => {
            let items = decode_dir_listing(body).expect("a pinned dir listing decodes");
            assert_eq!(items, vec![
                DirEntry {
                    is_dir: true,
                    name: "Sources".to_owned(),
                },
                DirEntry {
                    is_dir: false,
                    name: "README.md".to_owned(),
                },
                DirEntry {
                    is_dir: true,
                    name: "docs".to_owned(),
                },
            ]);
            encode_dir_listing(&items)
        },
        "gitStatus" => {
            let status = decode_git_status(body).expect("a pinned git status decodes");
            if note.starts_with("no repo") {
                assert_eq!(status, GitStatusPayload::no_repo());
            } else {
                assert_eq!(status, GitStatusPayload {
                    has_repo: true,
                    branch: "main".to_owned(),
                    remote_url: "git@github.com:aislopware/slop-desk.git".to_owned(),
                    repo_root: "/Users/me/slopdesk".to_owned(),
                    ahead: 3,
                    behind: 0,
                    stash_count: 2,
                    files: vec![
                        GitFileChange {
                            status_code: 0x12,
                            path: "Sources/main.swift".to_owned(),
                        },
                        GitFileChange {
                            status_code: 0xFF,
                            path: "docs/x.md".to_owned(),
                        },
                    ],
                });
                // 0x12 is `M` staged + `A`… no: high nibble 1 = M (index), low 2 = A (worktree).
                // 0xFF is a nibble pair no porcelain packing produces, and the fold must still be
                // total rather than trapping on it.
                let counts = status.folded_counts();
                assert_eq!(counts.staged, 2);
                assert_eq!(counts.modified, 2);
            }
            encode_git_status(&status)
        },
        "agentSessionList" => {
            let items = decode_agent_session_list(body).expect("a pinned session list decodes");
            assert_eq!(items, vec![
                AgentSessionInfo {
                    agent_kind_byte: 0,
                    id: "9f3c".to_owned(),
                    title: "Fix the wire codec".to_owned(),
                    cwd: "/Users/me/project".to_owned(),
                    mtime_ms: 1_749_700_000_123,
                },
                AgentSessionInfo {
                    agent_kind_byte: 1,
                    id: "c42".to_owned(),
                    title: String::new(),
                    cwd: "/tmp/x".to_owned(),
                    mtime_ms: -1,
                },
            ]);
            encode_agent_session_list(&items)
        },
        "hostVitals" => {
            let vitals = decode_host_vitals(body).expect("pinned vitals decode");
            if note.starts_with("cpu/mem") {
                assert_eq!(vitals, HostVitals {
                    cpu_percent: 34,
                    memory_percent: 61,
                    pressure_byte: 0,
                    disk_free_mib: Some(245_760),
                });
            } else {
                assert_eq!(
                    vitals,
                    HostVitals {
                        cpu_percent: 100,
                        memory_percent: 100,
                        pressure_byte: 2,
                        disk_free_mib: None,
                    },
                    "the all-ones disk reading is the unreadable sentinel, not a full disk"
                );
            }
            encode_host_vitals(&vitals)
        },
        other => panic!("the corpus grew a metadata payload kind this test does not cover: {other:?}"),
    }
}

/// Byte-for-byte parity for the nested metadata payload codecs, checked from both sides.
///
/// These ride INSIDE the opaque `metadataResponse` payload the terminal group already pins, so
/// nothing above catches a field-order slip here: the envelope would round-trip perfectly while the
/// body meant something else to every Swift peer.
#[test]
fn the_pinned_metadata_payloads_decode_to_the_pinned_fields_and_re_encode_identically() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["metadataCodecPayloads"]
        .as_array()
        .expect("metadataCodecPayloads is an array");
    assert!(!vectors.is_empty(), "an empty corpus proves nothing");

    for vector in vectors {
        let hex = vector["hex"].as_str().expect("every vector pins its hex");
        let kind = vector["kind"].as_str().expect("every vector pins its kind");
        let note = vector["note"].as_str().expect("every vector pins its note");
        let re_encoded = round_trip_metadata(kind, note, &from_hex(hex));
        assert_eq!(
            to_hex(&re_encoded),
            hex,
            "re-encoding the decoded payload changed the wire for {kind} ({note})"
        );
    }
    assert_eq!(
        vectors.len(),
        10,
        "the corpus changed size; confirm the change was intended"
    );
}

// ------------------------------------------------------------------------------------------------
// The workspace DOCUMENT — `workspaceStateCodec`, `workspaceIntentOps`, `workspaceIntentArgs`
// ------------------------------------------------------------------------------------------------

/// The generator's deterministic fixture UUIDs: a FIXED byte pattern, never a fresh `UUID()`.
const fn ws_uuid(byte: u8) -> [u8; 16] {
    [byte; 16]
}

const WS_PANE: [u8; 16] = ws_uuid(0xA1);
const WS_TAB: [u8; 16] = ws_uuid(0xB2);
const WS_SPLIT: [u8; 16] = ws_uuid(0xC3);

fn ws_entry(kind: u8, object: [u8; 16], field: u8, value: &str) -> WorkspaceEntry {
    WorkspaceEntry::new(WorkspaceKey::new(kind, object, field), value.as_bytes().to_vec())
}

/// A state exercising a normal string field, a ZERO-LENGTH value (the retirement signal — present
/// and empty, not absent), the all-zero root objectID, and an out-of-order insertion that must
/// still emit in canonical order.
fn ws_state() -> HostWorkspaceState {
    HostWorkspaceState::from_entries(vec![
        ws_entry(3, WS_PANE, 8, "vi ."),
        ws_entry(0, ROOT_OBJECT_ID, 2, "mac-studio"),
        ws_entry(3, WS_PANE, 3, ""),
        ws_entry(2, WS_TAB, 0, "slopdesk"),
    ])
}

fn ws_base() -> HostWorkspaceState {
    HostWorkspaceState::from_entries(vec![
        ws_entry(3, WS_PANE, 3, "main.go - NVIM"),
        ws_entry(3, WS_PANE, 99, "gone"),
    ])
}

/// `layoutStructure` nested `depth` deep. Depth 13 is deliberately not a vector: it does not ENCODE
/// to anything valid, it is a DECODE rejection, and the unit tests own that.
fn ws_nested(depth: usize) -> WorkspaceLayoutNode {
    let mut node = WorkspaceLayoutNode::Leaf(WS_PANE);
    for i in 0..depth {
        node = WorkspaceLayoutNode::Split {
            id: ws_uuid(0xD0_u8.wrapping_add(u8::try_from(i).expect("a fixture depth fits a byte"))),
            axis: if i.is_multiple_of(2) {
                SplitAxis::Horizontal
            } else {
                SplitAxis::Vertical
            },
            children: vec![node],
        };
    }
    node
}

/// Byte-for-byte parity for the workspace document codec.
///
/// Stronger than the metadata group's decode-and-re-encode: here the Rust side CONSTRUCTS the same
/// fixture the Swift generator did and compares the bytes it produces. A decoder and encoder that
/// agreed with each other on a wrong field order would still pass a pure round-trip; they cannot
/// pass this, because the value never came from the pinned bytes.
#[test]
fn the_pinned_workspace_document_vectors_encode_to_the_pinned_bytes() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["workspaceStateCodec"]
        .as_object()
        .expect("workspaceStateCodec is an object");

    let expect = |name: &str| -> &str {
        vectors[name]
            .as_str()
            .unwrap_or_else(|| panic!("the corpus pins {name}"))
    };

    assert_eq!(
        to_hex(&encode_key(&WorkspaceKey::new(3, WS_PANE, 8))),
        expect("key")
    );
    assert_eq!(to_hex(&encode_snapshot(&ws_state())), expect("snapshot"));
    assert_eq!(
        to_hex(&encode_diff(&ws_state().diff_from(&ws_base()))),
        expect("diff")
    );
    assert_eq!(
        to_hex(&encode_diff(&ws_state().diff_from(&ws_state()))),
        expect("emptyDiff")
    );
    assert_eq!(to_hex(&encode_layout(&ws_nested(1))), expect("layoutDepth1"));
    assert_eq!(to_hex(&encode_layout(&ws_nested(11))), expect("layoutDepth11"));
    assert_eq!(
        to_hex(&encode_layout(&ws_nested(MAX_LAYOUT_DEPTH))),
        expect("layoutDepthCap"),
        "the cap vector pins that Rust's MAX_LAYOUT_DEPTH is still Swift's SplitNode.maxDepth"
    );
    assert_eq!(
        to_hex(&encode_layout(&WorkspaceLayoutNode::Split {
            id: WS_SPLIT,
            axis: SplitAxis::Vertical,
            children: (0..4)
                .map(|i| WorkspaceLayoutNode::Leaf(ws_uuid(0xE0 + i)))
                .collect(),
        })),
        expect("layoutFanout")
    );
    // Weights ride as a raw bit pattern — never a re-parsed decimal (the bit-exact float rule).
    assert_eq!(
        to_hex(&encode_weight(SplitWeight::Flex(1.0 / 3.0))),
        expect("weightFlexThird")
    );
    assert_eq!(
        to_hex(&encode_weight(SplitWeight::Fixed(240.0))),
        expect("weightFixed240")
    );
    assert_eq!(
        to_hex(&encode_weights(&[
            SplitWeight::Flex(1.0 / 3.0),
            SplitWeight::Fixed(240.0)
        ])),
        expect("weightsPair")
    );
    assert_eq!(to_hex(&encode_weights(&[])), expect("weightsEmpty"));
    assert_eq!(to_hex(&encode_uuid(&WS_TAB)), expect("uuidValue"));
    assert_eq!(
        to_hex(&encode_detached_panes(&[
            (WS_PANE, Some(WS_TAB)),
            (ws_uuid(0xA2), None),
        ])),
        expect("detachedPanes"),
        "here the zero UUID IS the no-origin sentinel, because the pair is fixed-width"
    );
    assert_eq!(
        to_hex(&encode_video_target(&VideoEndpoint {
            window_id: 0,
            title: "Display 1".to_owned(),
            app_name: String::new(),
            display_id: Some(0),
        })),
        expect("videoTargetDisplay"),
        "displayID carries its own presence byte rather than overloading 0, a legitimate display id"
    );
    assert_eq!(
        to_hex(&encode_video_target(&VideoEndpoint {
            window_id: 0x1234_5678,
            title: "main.swift".to_owned(),
            app_name: "Ghostty".to_owned(),
            display_id: None,
        })),
        expect("videoTargetWindow")
    );

    assert_eq!(
        vectors.len(),
        16,
        "the corpus changed size; confirm the change was intended"
    );
}

/// Every pinned document vector decodes to a value that re-encodes to the same bytes.
///
/// The encoder is pinned above; this pins the DECODER against the same corpus, so a field read in
/// the wrong order cannot hide behind an encoder that writes it in the same wrong order.
#[test]
fn every_pinned_workspace_document_vector_decodes_and_re_encodes_identically() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["workspaceStateCodec"]
        .as_object()
        .expect("workspaceStateCodec is an object");

    for (name, value) in vectors {
        let hex = value.as_str().expect("every vector pins its hex");
        let body = from_hex(hex);
        let re_encoded = match name.as_str() {
            "key" => {
                let mut reader = body.as_slice();
                assert_eq!(reader.len(), WorkspaceKey::ENCODED_SIZE);
                // A key has no standalone decoder — it is only ever read inside a snapshot or a
                // diff — so this checks the field split directly against the pinned layout.
                let key = WorkspaceKey::new(
                    reader[0],
                    <[u8; 16]>::try_from(&reader[1..17]).expect("16 bytes"),
                    reader[17],
                );
                assert_eq!(key, WorkspaceKey::new(3, WS_PANE, 8));
                reader = &[];
                assert!(reader.is_empty());
                encode_key(&key)
            },
            "snapshot" => {
                let state = decode_snapshot(&body).expect("a pinned snapshot decodes");
                assert_eq!(state, ws_state());
                assert_eq!(
                    state.get(&WorkspaceKey::new(3, WS_PANE, 3)),
                    Some(&[][..]),
                    "a retired field is present-and-empty, never absent"
                );
                encode_snapshot(&state)
            },
            "diff" | "emptyDiff" => {
                let diff = decode_diff(&body).expect("a pinned diff decodes");
                if name == "emptyDiff" {
                    assert!(diff.is_empty());
                } else {
                    assert_eq!(diff, ws_state().diff_from(&ws_base()));
                    assert_eq!(diff.deletes, vec![WorkspaceKey::new(3, WS_PANE, 99)]);
                    assert_eq!(ws_base().applying(&diff), ws_state());
                }
                encode_diff(&diff)
            },
            "layoutDepth1" | "layoutDepth11" | "layoutDepthCap" | "layoutFanout" => {
                let node = decode_layout(&body).expect("a pinned layout decodes");
                encode_layout(&node)
            },
            "weightFlexThird" | "weightFixed240" => {
                let weight = decode_weight(&body).expect("a pinned weight decodes");
                encode_weight(weight)
            },
            "weightsPair" | "weightsEmpty" => {
                let weights = decode_weights(&body).expect("pinned weights decode");
                encode_weights(&weights)
            },
            "uuidValue" => {
                let id = decode_uuid(&body).expect("a pinned uuid decodes");
                assert_eq!(id, WS_TAB);
                encode_uuid(&id)
            },
            "detachedPanes" => {
                let panes = decode_detached_panes(&body).expect("pinned detached panes decode");
                assert_eq!(panes, vec![(WS_PANE, Some(WS_TAB)), (ws_uuid(0xA2), None)]);
                encode_detached_panes(&panes)
            },
            "videoTargetDisplay" | "videoTargetWindow" => {
                let endpoint = decode_video_target(&body).expect("a pinned video target decodes");
                if name == "videoTargetDisplay" {
                    assert_eq!(endpoint.display_id, Some(0));
                } else {
                    assert_eq!(endpoint.display_id, None);
                    assert_eq!(endpoint.app_name, "Ghostty");
                }
                encode_video_target(&endpoint)
            },
            other => panic!("the corpus grew a document vector this test does not cover: {other:?}"),
        };
        assert_eq!(
            to_hex(&re_encoded),
            hex,
            "re-encoding the decoded value changed the wire for {name}"
        );
    }
}

/// The intent op BYTES are frozen the moment a vector exists.
///
/// A renumbering decodes CLEANLY into the wrong meaning, because every argument payload is
/// length-prefixed rather than self-describing — nothing downstream would notice.
#[test]
fn every_pinned_intent_op_byte_still_names_the_same_op() {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    let vectors = golden["workspaceIntentOps"]
        .as_array()
        .expect("workspaceIntentOps is an array");

    for (index, vector) in vectors.iter().enumerate() {
        let name = vector["name"].as_str().expect("every op pins its name");
        let op = u8::try_from(vector["op"].as_u64().expect("an op byte")).expect("fits a byte");
        let mine = WorkspaceIntentOp::ALL
            .get(index)
            .copied()
            .unwrap_or_else(|| panic!("the corpus has an op at index {index} and this build does not"));
        assert_eq!(mine.as_byte(), op, "op byte drift at {name}");
        assert_eq!(WorkspaceIntentOp::from_byte(op), Some(mine));
        // The Swift name is lowerCamelCase, the Rust variant UpperCamelCase — compare the shapes
        // rather than the spellings, so a RENAME is free and a REORDER is not.
        let rust_name = format!("{mine:?}");
        assert_eq!(
            rust_name.to_lowercase(),
            name.to_lowercase(),
            "op {op} is {name} in the corpus and {rust_name} here"
        );
    }
    assert_eq!(
        vectors.len(),
        WorkspaceIntentOp::ALL.len(),
        "the op table changed size; confirm the change was intended"
    );
}

/// The `pane/videoTarget` blob a detached desktop pane is minted with.
fn ws_desktop_endpoint() -> VideoEndpoint {
    VideoEndpoint {
        window_id: 0,
        title: "Desktop".to_owned(),
        app_name: String::new(),
        display_id: Some(0),
    }
}

/// The same blob re-pointed at display 1 — the display switcher's move.
fn ws_display_one_endpoint() -> VideoEndpoint {
    VideoEndpoint {
        display_id: Some(1),
        ..ws_desktop_endpoint()
    }
}

/// The pinned intent-argument hex, by vector name.
fn ws_intent_args() -> serde_json::Map<String, Value> {
    let golden: Value = serde_json::from_str(GOLDEN).expect("the golden corpus is valid JSON");
    golden["workspaceIntentArgs"]
        .as_object()
        .expect("workspaceIntentArgs is an object")
        .clone()
}

/// Byte-for-byte parity for the intent argument payloads, CONSTRUCTED rather than round-tripped.
#[test]
#[expect(clippy::too_many_lines, reason = "one assertion per pinned argument payload")]
fn the_pinned_intent_arguments_encode_to_the_pinned_bytes() {
    let vectors = ws_intent_args();
    let expect = |name: &str| -> String {
        vectors[name]
            .as_str()
            .unwrap_or_else(|| panic!("the corpus pins {name}"))
            .to_owned()
    };

    let desktop = ws_desktop_endpoint();
    let display_one = ws_display_one_endpoint();

    assert_eq!(to_hex(&encode_name(&WS_TAB, "slopdesk")), expect("rename"));
    assert_eq!(to_hex(&encode_name(&WS_TAB, "")), expect("renameEmpty"));
    assert_eq!(to_hex(&encode_flag(&WS_PANE, true)), expect("flag"));
    assert_eq!(to_hex(&encode_identity(&WS_PANE)), expect("identity"));
    assert_eq!(
        to_hex(&encode_split(
            &WS_PANE,
            SplitAxis::Vertical,
            true,
            &ws_uuid(0xA3),
            "/Volumes/Lacie",
        )),
        expect("split"),
        "the new pane's id is PROPOSED BY THE CLIENT, so an overlay inserts the leaf with no round trip"
    );
    assert_eq!(
        to_hex(&encode_move(
            &WS_PANE,
            &ws_uuid(0xA4),
            SplitAxis::Horizontal,
            false
        )),
        expect("move")
    );
    assert_eq!(
        to_hex(&encode_reorder_tabs(&ws_uuid(0xF1), &[WS_TAB, ws_uuid(0xB3)])),
        expect("reorderTabs")
    );
    assert_eq!(
        to_hex(&encode_spawn_tab(
            &ws_uuid(0xF1),
            &ws_uuid(0xA5),
            NewTabPosition::AfterCurrent,
            "",
        )),
        expect("spawnTab")
    );
    assert_eq!(
        to_hex(&encode_new_session(
            &ws_uuid(0xF2),
            &ws_uuid(0xA6),
            "notes",
            "/Volumes/Lacie",
        )),
        expect("newSession"),
        "a new session carries the cwd it INHERITS alongside its name"
    );
    assert_eq!(
        to_hex(&encode_swap_panes(&WS_PANE, &ws_uuid(0xA4))),
        expect("swapPanes")
    );
    assert_eq!(
        to_hex(&encode_dock_at_tab_edge(&WS_PANE, &WS_TAB, PaneDropEdge::Bottom)),
        expect("dockAtTabEdge"),
        "a ROOT-edge dock names the container, not a target leaf"
    );
    assert_eq!(
        to_hex(&encode_set_tab_layout(&WS_TAB, &WorkspaceLayoutNode::Split {
            id: WS_SPLIT,
            axis: SplitAxis::Horizontal,
            children: vec![
                WorkspaceLayoutNode::Leaf(WS_PANE),
                WorkspaceLayoutNode::Leaf(ws_uuid(0xA4)),
            ],
        },)),
        expect("setTabLayout"),
        "the layout blob is the SAME grammar tab/layoutStructure carries"
    );
    assert_eq!(
        to_hex(&encode_spawn_detached_pane(
            &ws_uuid(0xA7),
            PaneKind::Desktop,
            Some(&desktop)
        )),
        expect("spawnDetachedDesktop")
    );
    assert_eq!(
        to_hex(&encode_spawn_detached_pane(
            &ws_uuid(0xA7),
            PaneKind::Terminal,
            None
        )),
        expect("spawnDetachedNoTarget")
    );
    assert_eq!(
        to_hex(&encode_set_pane_video_target(&ws_uuid(0xA7), Some(&display_one))),
        expect("setPaneVideoTarget")
    );
    assert_eq!(
        to_hex(&encode_set_pane_video_target(&ws_uuid(0xA7), None)),
        expect("setPaneVideoTargetUnbound"),
        "a zero length UNBINDS, which stays distinct from 'the bytes did not decode'"
    );
    assert_eq!(
        to_hex(&encode_reopen_closed_tab(1, NewTabPosition::AfterCurrent)),
        expect("reopenClosedTab"),
        "the index counts from the NEWEST end of the ring, not always the newest tab"
    );
    assert_eq!(
        to_hex(&encode_divider_weight(&WS_SPLIT, 1, 1.0 / 3.0)),
        expect("dividerWeight"),
        "the LEADING weight only — the op is sum-preserving"
    );

    assert_eq!(
        vectors.len(),
        18,
        "the corpus changed size; confirm the change was intended"
    );
}

/// Every pinned intent argument reads back to the fields it was built from.
///
/// The encoder is pinned above; this pins the DECODER, so a field read in the wrong order cannot
/// hide behind an encoder that writes it in the same wrong order.
#[test]
fn every_pinned_intent_argument_decodes_to_the_fields_it_was_built_from() {
    let vectors = ws_intent_args();
    let expect = |name: &str| -> Vec<u8> {
        from_hex(
            vectors[name]
                .as_str()
                .unwrap_or_else(|| panic!("the corpus pins {name}")),
        )
    };
    let desktop = ws_desktop_endpoint();
    let display_one = ws_display_one_endpoint();

    assert_eq!(
        decode_name(&expect("rename")).expect("a pinned rename decodes"),
        (WS_TAB, "slopdesk".to_owned())
    );
    assert_eq!(
        decode_flag(&expect("flag")).expect("a pinned flag decodes"),
        (WS_PANE, true)
    );
    assert_eq!(
        decode_identity(&expect("identity")).expect("a pinned identity decodes"),
        WS_PANE
    );
    let split = decode_split(&expect("split")).expect("a pinned split decodes");
    assert_eq!(split.axis, SplitAxis::Vertical);
    assert!(split.before);
    assert_eq!(split.new_pane, ws_uuid(0xA3));
    assert_eq!(split.spawn_cwd, "/Volumes/Lacie");
    let moved = decode_move(&expect("move")).expect("a pinned move decodes");
    assert_eq!(moved.axis, SplitAxis::Horizontal);
    assert!(!moved.before);
    assert_eq!(
        decode_reorder_tabs(&expect("reorderTabs")).expect("pinned tab order decodes"),
        (ws_uuid(0xF1), vec![WS_TAB, ws_uuid(0xB3)])
    );
    assert_eq!(
        decode_spawn_tab(&expect("spawnTab"))
            .expect("a pinned spawnTab decodes")
            .position,
        NewTabPosition::AfterCurrent
    );
    let session = decode_new_session(&expect("newSession")).expect("a pinned session decodes");
    assert_eq!(session.name, "notes");
    assert_eq!(session.spawn_cwd, "/Volumes/Lacie");
    assert_eq!(
        decode_swap_panes(&expect("swapPanes")).expect("a pinned swap decodes"),
        (WS_PANE, ws_uuid(0xA4))
    );
    assert_eq!(
        decode_dock_at_tab_edge(&expect("dockAtTabEdge"))
            .expect("a pinned dock decodes")
            .edge,
        PaneDropEdge::Bottom
    );
    let (layout_tab, layout_blob) =
        decode_set_tab_layout(&expect("setTabLayout")).expect("a pinned layout intent decodes");
    assert_eq!(layout_tab, WS_TAB);
    assert_eq!(
        decode_layout(&layout_blob).expect("its blob is a layout"),
        WorkspaceLayoutNode::Split {
            id: WS_SPLIT,
            axis: SplitAxis::Horizontal,
            children: vec![
                WorkspaceLayoutNode::Leaf(WS_PANE),
                WorkspaceLayoutNode::Leaf(ws_uuid(0xA4)),
            ],
        }
    );
    let detached =
        decode_spawn_detached_pane(&expect("spawnDetachedDesktop")).expect("a pinned detached mint decodes");
    assert_eq!(detached.kind, PaneKind::Desktop);
    assert_eq!(
        decode_video_target(&detached.video).expect("its blob is a video target"),
        desktop
    );
    let (video_pane, video_blob) =
        decode_set_pane_video_target(&expect("setPaneVideoTarget")).expect("a pinned re-point decodes");
    assert_eq!(video_pane, ws_uuid(0xA7));
    assert_eq!(
        decode_video_target(&video_blob).expect("its blob is a video target"),
        display_one
    );
    assert_eq!(
        decode_reopen_closed_tab(&expect("reopenClosedTab")).expect("a pinned reopen decodes"),
        (1, NewTabPosition::AfterCurrent)
    );
    let (weight_split, leading_index, leading_weight) =
        decode_divider_weight(&expect("dividerWeight")).expect("a pinned weight decodes");
    assert_eq!(weight_split, WS_SPLIT);
    assert_eq!(leading_index, 1);
    assert_eq!(leading_weight.to_bits(), (1.0_f64 / 3.0).to_bits());

    assert_eq!(
        vectors.len(),
        18,
        "the corpus changed size; confirm the change was intended"
    );
}
