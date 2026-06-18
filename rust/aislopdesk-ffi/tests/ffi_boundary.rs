//! End-to-end tests of the C-ABI boundary, driving the `extern "C"` surface exactly as a C
//! caller would (raw pointers, owned buffers, status codes). Every payload that the safe
//! core round-trips is verified to round-trip through the flat C struct as well, and every
//! decode error / null guard is exercised.

// Driving a C-ABI surface from a test means passing `&mut x` / `&x` where the function wants
// `*mut` / `*const`; that implicit coercion is the clearest way to write these calls.
// Rewriting ~30 call sites as `&raw mut x` to satisfy the pedantic `borrow_as_ptr` lint would
// buy no safety here — the references are consumed immediately by the call.
#![allow(clippy::borrow_as_ptr)]

use aislopdesk_ffi::video::{
    AISD_DECODE_GATE_MODE_BROKEN_CHAIN, AISD_DECODE_GATE_MODE_NEED_KEYFRAME,
    AISD_DECODE_GATE_MODE_OPEN, AISD_DECODE_GATE_VERDICT_DROP, AISD_DECODE_GATE_VERDICT_SUBMIT,
    AISD_MUX_BOOTSTRAP_DELIVER, AISD_MUX_BOOTSTRAP_DROP_NO_STAMP, AISD_MUX_DECISION_DROP,
    AISD_MUX_DECISION_DROP_DRAINING, AISD_MUX_DECISION_DROP_RETIRED,
    AISD_MUX_DECISION_REJECT_UNADMITTED, AISD_MUX_DECISION_ROUTE, AISD_PACER_GAP_FIRST,
    AISD_REASSEMBLY_COMPLETED, AISD_REASSEMBLY_PENDING, AISD_REASSEMBLY_STALE,
    AISD_RECOVERY_IDR_GRANT, AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT,
    AISD_RECOVERY_IDR_SUPPRESS_STALE, AISD_RECOVERY_NETWORK_STATS,
    AISD_RECOVERY_REQUEST_LTR_REFRESH, AISD_SCROLL_PHASE_ACTIVE, AISD_SCROLL_PHASE_ENDED,
    AISD_SCROLL_PHASE_MOMENTUM, AISD_VIDEO_CONTROL_WINDOW_LIST, AisdNetworkStats,
    AisdPacerDepthConfig, AisdPacketizeOptions, AisdReassemblyResult, AisdRecoveryMessage,
    AisdRect, AisdScrollReprojectorConfig, AisdSystemDialog, AisdVideoControl, AisdVideoSummary,
    aisd_decode_gate_free, aisd_decode_gate_max_lost_frame_id, aisd_decode_gate_min_lost_frame_id,
    aisd_decode_gate_mode, aisd_decode_gate_new, aisd_decode_gate_note_decode_succeeded,
    aisd_decode_gate_note_hard_decode_failure, aisd_decode_gate_note_loss,
    aisd_decode_gate_verdict, aisd_fec_codec_free, aisd_fec_codec_new, aisd_fec_parity,
    aisd_fec_recover, aisd_input_button_balance_free, aisd_input_button_balance_held_mask,
    aisd_input_button_balance_new, aisd_input_button_balance_plan, aisd_owd_late_detector_free,
    aisd_owd_late_detector_new, aisd_owd_late_detector_note, aisd_pacer_depth_policy_depth,
    aisd_pacer_depth_policy_drain_counters, aisd_pacer_depth_policy_free,
    aisd_pacer_depth_policy_late_threshold_seconds, aisd_pacer_depth_policy_new,
    aisd_pacer_depth_policy_note_arrival, aisd_pacer_depth_policy_note_network_late,
    aisd_pacer_depth_policy_note_present, aisd_pacer_depth_policy_set_interval_hint,
    aisd_packetize, aisd_reassembler_free, aisd_reassembler_ingest, aisd_reassembler_new,
    aisd_reassembler_next_dropped, aisd_reassembly_result_free, aisd_recovery_deduper_admit,
    aisd_recovery_deduper_free, aisd_recovery_deduper_new,
    aisd_recovery_idr_policy_available_tokens, aisd_recovery_idr_policy_decide,
    aisd_recovery_idr_policy_free, aisd_recovery_idr_policy_grace, aisd_recovery_idr_policy_new,
    aisd_recovery_idr_policy_note_keyframe_delivered, aisd_recovery_idr_policy_note_keyframe_sent,
    aisd_recovery_message_decode, aisd_recovery_message_encode, aisd_scroll_reprojector_advance,
    aisd_scroll_reprojector_free, aisd_scroll_reprojector_new,
    aisd_scroll_reprojector_note_real_frame, aisd_scroll_reprojector_note_velocity,
    aisd_scroll_reprojector_reset, aisd_static_idr_decider_free, aisd_static_idr_decider_heartbeat,
    aisd_static_idr_decider_last_complete_encode, aisd_static_idr_decider_new,
    aisd_static_idr_decider_on_complete_frame, aisd_static_idr_decider_quiet_window,
    aisd_static_idr_decider_record_synthetic, aisd_static_idr_decider_should_reencode,
    aisd_system_dialog_classify, aisd_system_dialog_free, aisd_system_dialog_min_size,
    aisd_video_control_decode, aisd_video_control_encode, aisd_video_control_free,
    aisd_video_mux_header_decode, aisd_video_mux_header_encode, aisd_video_mux_router_admit,
    aisd_video_mux_router_begin_drain, aisd_video_mux_router_bootstrap_action,
    aisd_video_mux_router_end_drain, aisd_video_mux_router_free, aisd_video_mux_router_is_admitted,
    aisd_video_mux_router_is_draining, aisd_video_mux_router_new, aisd_video_mux_router_retire,
    aisd_video_mux_router_route, aisd_video_packetizer_free, aisd_video_packetizer_new,
    aisd_video_packetizer_peek_next_frame_id, aisd_video_packetizer_peek_next_stream_seq,
    aisd_ycbcr_coefficients,
};
use aislopdesk_ffi::video::{AISD_FRAME_HASH_SENTINEL, aisd_frame_hash_nv12};
use aislopdesk_ffi::{
    AISD_EMPTY, AISD_ERR_FRAME_TOO_LARGE, AISD_ERR_INVALID_ARGUMENT, AISD_ERR_MALFORMED,
    AISD_ERR_NULL, AISD_ERR_TRUNCATED, AISD_ERR_UNKNOWN_TYPE, AISD_OK, AISD_WIRE_ACK,
    AISD_WIRE_BELL, AISD_WIRE_BYE, AISD_WIRE_COMMAND_STATUS, AISD_WIRE_EXIT, AISD_WIRE_HELLO,
    AISD_WIRE_HELLO_ACK, AISD_WIRE_INPUT, AISD_WIRE_NOTIFICATION, AISD_WIRE_OUTPUT, AISD_WIRE_PING,
    AISD_WIRE_PONG, AISD_WIRE_RESIZE, AISD_WIRE_TITLE, AisdBytes, AisdBytesArray,
    AisdDataFrameView, AisdWireMessage, aisd_bytes_array_free, aisd_bytes_free,
    aisd_frame_decoder_append, aisd_frame_decoder_free, aisd_frame_decoder_new,
    aisd_frame_decoder_next, aisd_seq_distance, aisd_wire_data_frame_encode_into,
    aisd_wire_data_frame_view, aisd_wire_message_decode, aisd_wire_message_encode,
    aisd_wire_message_free,
};

/// A zeroed message — every field default, both buffers empty.
const fn base() -> AisdWireMessage {
    AisdWireMessage {
        tag: 0,
        seq: 0,
        code: 0,
        protocol_version: 0,
        last_received_seq: 0,
        resume_from_seq: 0,
        cols: 0,
        rows: 0,
        px_width: 0,
        px_height: 0,
        timestamp_ms: 0,
        returning_client: 0,
        session_id: [0u8; 16],
        cmd_running: 0,
        cmd_has_exit_code: 0,
        duration_ms: 0,
        data: AisdBytes::EMPTY,
        data2: AisdBytes::EMPTY,
    }
}

/// Borrows a slice as an input `AisdBytes` (read-only; encode copies it, never frees it).
const fn borrow(bytes: &[u8]) -> AisdBytes {
    if bytes.is_empty() {
        AisdBytes::EMPTY
    } else {
        AisdBytes {
            ptr: bytes.as_ptr().cast_mut(),
            len: bytes.len(),
            cap: 0,
        }
    }
}

/// Reads an owned/returned `AisdBytes` as a slice.
unsafe fn view(b: AisdBytes) -> Vec<u8> {
    unsafe {
        if b.ptr.is_null() || b.len == 0 {
            Vec::new()
        } else {
            core::slice::from_raw_parts(b.ptr, b.len).to_vec()
        }
    }
}

/// Encodes `msg`, feeds the frame through a fresh decoder, and returns the decoded flat
/// struct (status must be `AISD_OK`). The caller frees the returned message's buffers.
unsafe fn round_trip(msg: &AisdWireMessage) -> AisdWireMessage {
    unsafe {
        let mut frame = AisdBytes::EMPTY;
        assert_eq!(
            aisd_wire_message_encode(msg, &mut frame),
            AISD_OK,
            "encode should succeed for tag {}",
            msg.tag
        );

        let decoder = aisd_frame_decoder_new();
        assert_eq!(
            aisd_frame_decoder_append(decoder, frame.ptr, frame.len),
            AISD_OK
        );

        let mut out = base();
        let status = aisd_frame_decoder_next(decoder, &mut out);
        assert_eq!(status, AISD_OK, "decode should succeed for tag {}", msg.tag);

        // The stream is now drained.
        let mut spare = base();
        assert_eq!(aisd_frame_decoder_next(decoder, &mut spare), AISD_EMPTY);

        aisd_frame_decoder_free(decoder);
        aisd_bytes_free(frame);
        out
    }
}

#[test]
fn seq_distance_is_wrap_aware() {
    assert_eq!(aisd_seq_distance(10, 4), 6);
    assert_eq!(aisd_seq_distance(4, 10), -6);
    assert_eq!(aisd_seq_distance(2, u32::MAX), 3);
}

#[test]
fn output_round_trips_with_payload() {
    unsafe {
        let payload = b"\x1b[2J partial \xf0\x9f\x9a\x80"; // VT + emoji bytes
        let msg = AisdWireMessage {
            tag: AISD_WIRE_OUTPUT,
            seq: 7,
            data: borrow(payload),
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.tag, AISD_WIRE_OUTPUT);
        assert_eq!(out.seq, 7);
        assert_eq!(view(out.data), payload);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn output_with_empty_payload_yields_null_buffer() {
    unsafe {
        let msg = AisdWireMessage {
            tag: AISD_WIRE_OUTPUT,
            seq: i64::MAX,
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.seq, i64::MAX);
        assert!(out.data.ptr.is_null(), "empty payload is the null buffer");
        assert_eq!(out.data.len, 0);
        aisd_wire_message_free(&mut out); // no-op on the null buffer
    }
}

#[test]
fn exit_round_trips_including_negative() {
    unsafe {
        for code in [0i32, 1, -1, i32::MAX, i32::MIN] {
            let msg = AisdWireMessage {
                tag: AISD_WIRE_EXIT,
                code,
                ..base()
            };
            let mut out = round_trip(&msg);
            assert_eq!(out.tag, AISD_WIRE_EXIT);
            assert_eq!(out.code, code);
            aisd_wire_message_free(&mut out);
        }
    }
}

#[test]
fn input_round_trips() {
    unsafe {
        let bytes = vec![0x00u8, 0xff, 0x80, 0x7f];
        let msg = AisdWireMessage {
            tag: AISD_WIRE_INPUT,
            data: borrow(&bytes),
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.tag, AISD_WIRE_INPUT);
        assert_eq!(view(out.data), bytes);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn hello_round_trips_with_session_id() {
    unsafe {
        let sid = [3u8, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3];
        let msg = AisdWireMessage {
            tag: AISD_WIRE_HELLO,
            protocol_version: 1,
            session_id: sid,
            last_received_seq: 42,
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.tag, AISD_WIRE_HELLO);
        assert_eq!(out.protocol_version, 1);
        assert_eq!(out.session_id, sid);
        assert_eq!(out.last_received_seq, 42);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn resize_round_trips_boundaries() {
    unsafe {
        let msg = AisdWireMessage {
            tag: AISD_WIRE_RESIZE,
            cols: 65535,
            rows: 24,
            px_width: 0,
            px_height: 384,
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(
            (out.cols, out.rows, out.px_width, out.px_height),
            (65535, 24, 0, 384)
        );
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn ack_bye_bell_ping_pong_round_trip() {
    unsafe {
        let mut ack = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_ACK,
            seq: 9_000_000_000,
            ..base()
        });
        assert_eq!(ack.seq, 9_000_000_000);
        aisd_wire_message_free(&mut ack);

        for tag in [AISD_WIRE_BYE, AISD_WIRE_BELL] {
            let mut out = round_trip(&AisdWireMessage { tag, ..base() });
            assert_eq!(out.tag, tag);
            aisd_wire_message_free(&mut out);
        }

        for tag in [AISD_WIRE_PING, AISD_WIRE_PONG] {
            let mut out = round_trip(&AisdWireMessage {
                tag,
                timestamp_ms: u64::MAX,
                ..base()
            });
            assert_eq!(out.tag, tag);
            assert_eq!(out.timestamp_ms, u64::MAX);
            aisd_wire_message_free(&mut out);
        }
    }
}

#[test]
fn hello_ack_round_trips() {
    unsafe {
        let sid = [9u8; 16];
        let msg = AisdWireMessage {
            tag: AISD_WIRE_HELLO_ACK,
            session_id: sid,
            resume_from_seq: i64::MAX,
            returning_client: 1,
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.session_id, sid);
        assert_eq!(out.resume_from_seq, i64::MAX);
        assert_eq!(out.returning_client, 1);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn title_round_trips_unicode() {
    unsafe {
        let title = "日本語 — build ✅".as_bytes();
        let msg = AisdWireMessage {
            tag: AISD_WIRE_TITLE,
            data: borrow(title),
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.tag, AISD_WIRE_TITLE);
        assert_eq!(view(out.data), title);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn command_status_running_and_idle_round_trip() {
    unsafe {
        let mut running = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_COMMAND_STATUS,
            cmd_running: 1,
            ..base()
        });
        assert_ne!(running.cmd_running, 0);
        aisd_wire_message_free(&mut running);

        // Idle with a reported exit code.
        let mut idle = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_COMMAND_STATUS,
            cmd_running: 0,
            cmd_has_exit_code: 1,
            code: 130,
            duration_ms: 12_345,
            ..base()
        });
        assert_eq!(idle.cmd_running, 0);
        assert_ne!(idle.cmd_has_exit_code, 0);
        assert_eq!(idle.code, 130);
        assert_eq!(idle.duration_ms, 12_345);
        aisd_wire_message_free(&mut idle);

        // Idle with NO reported exit code (code must read back 0, flag false).
        let mut idle_none = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_COMMAND_STATUS,
            cmd_running: 0,
            cmd_has_exit_code: 0,
            code: 999, // ignored on encode because the flag is false
            duration_ms: 5_000,
            ..base()
        });
        assert_eq!(idle_none.cmd_has_exit_code, 0);
        assert_eq!(idle_none.code, 0);
        assert_eq!(idle_none.duration_ms, 5_000);
        aisd_wire_message_free(&mut idle_none);
    }
}

#[test]
fn nonstandard_bool_bytes_are_treated_as_true_not_ub() {
    unsafe {
        // A C/JNI caller may store ANY nonzero byte (e.g. a `jboolean`) in a flag field.
        // The boundary reads these as `!= 0` (the fields are `u8`, not Rust `bool`), so a
        // byte like 0xFF / 2 is normalized to true with no `bool`-validity UB.
        let mut ack = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_HELLO_ACK,
            session_id: [1u8; 16],
            resume_from_seq: 5,
            returning_client: 0xFF, // not 0/1
            ..base()
        });
        assert_eq!(ack.returning_client, 1, "0xFF normalizes to 1 on the wire");
        aisd_wire_message_free(&mut ack);

        let mut cs = round_trip(&AisdWireMessage {
            tag: AISD_WIRE_COMMAND_STATUS,
            cmd_running: 2,       // nonzero ⇒ running
            cmd_has_exit_code: 7, // ignored while running
            ..base()
        });
        assert_eq!(cs.cmd_running, 1, "nonzero normalizes to running=1");
        aisd_wire_message_free(&mut cs);
    }
}

#[test]
fn notification_round_trips_title_and_body() {
    unsafe {
        let title = b"CI";
        let body = "all green ✅ — đa byte".as_bytes();
        let msg = AisdWireMessage {
            tag: AISD_WIRE_NOTIFICATION,
            data: borrow(title),
            data2: borrow(body),
            ..base()
        };
        let mut out = round_trip(&msg);
        assert_eq!(out.tag, AISD_WIRE_NOTIFICATION);
        assert_eq!(view(out.data), title);
        assert_eq!(view(out.data2), body);
        aisd_wire_message_free(&mut out);
    }
}

#[test]
fn partial_append_returns_empty_until_complete() {
    unsafe {
        let msg = AisdWireMessage {
            tag: AISD_WIRE_OUTPUT,
            seq: 1,
            data: borrow(b"hello"),
            ..base()
        };
        let mut frame = AisdBytes::EMPTY;
        assert_eq!(aisd_wire_message_encode(&msg, &mut frame), AISD_OK);
        let frame_bytes = view(frame);

        let decoder = aisd_frame_decoder_new();
        // Feed one byte at a time; only the final byte completes the frame.
        let mut out = base();
        for (i, b) in frame_bytes.iter().enumerate() {
            assert_eq!(aisd_frame_decoder_append(decoder, b, 1), AISD_OK);
            let status = aisd_frame_decoder_next(decoder, &mut out);
            if i + 1 < frame_bytes.len() {
                assert_eq!(status, AISD_EMPTY, "byte {i} should not complete a frame");
            } else {
                assert_eq!(status, AISD_OK, "final byte completes the frame");
            }
        }
        assert_eq!(out.seq, 1);
        assert_eq!(view(out.data), b"hello");

        aisd_wire_message_free(&mut out);
        aisd_frame_decoder_free(decoder);
        aisd_bytes_free(frame);
    }
}

#[test]
fn decode_errors_map_to_status_codes() {
    unsafe {
        // Unknown message type: payload length 1, body = [0xFF].
        let unknown = [0u8, 0, 0, 1, 0xFF];
        // Truncated: payload length 1 = just the `exit` type byte, missing its i32 code.
        let truncated = [0u8, 0, 0, 1, 0x02];
        // Frame too large: a prefix one past the 16 MiB cap.
        let too_large = (16u32 * 1024 * 1024 + 1).to_be_bytes();
        // Malformed: a `title` (type 21) whose body is invalid UTF-8.
        let malformed = [0u8, 0, 0, 3, 21, 0xFF, 0xFE];

        for (bytes, expected) in [
            (&unknown[..], AISD_ERR_UNKNOWN_TYPE),
            (&truncated[..], AISD_ERR_TRUNCATED),
            (&too_large[..], AISD_ERR_FRAME_TOO_LARGE),
            (&malformed[..], AISD_ERR_MALFORMED),
        ] {
            let decoder = aisd_frame_decoder_new();
            assert_eq!(
                aisd_frame_decoder_append(decoder, bytes.as_ptr(), bytes.len()),
                AISD_OK
            );
            let mut out = base();
            assert_eq!(
                aisd_frame_decoder_next(decoder, &mut out),
                expected,
                "status for {bytes:?}"
            );
            aisd_frame_decoder_free(decoder);
        }
    }
}

#[test]
fn encode_rejects_unknown_tag_and_bad_utf8() {
    unsafe {
        // Unknown tag.
        let bad_tag = AisdWireMessage { tag: 99, ..base() };
        let mut out = AisdBytes::EMPTY;
        assert_eq!(
            aisd_wire_message_encode(&bad_tag, &mut out),
            AISD_ERR_INVALID_ARGUMENT
        );

        // A title with non-UTF-8 bytes cannot be a Rust `String`.
        let invalid = [0xffu8, 0xfe];
        let bad_title = AisdWireMessage {
            tag: AISD_WIRE_TITLE,
            data: borrow(&invalid),
            ..base()
        };
        assert_eq!(
            aisd_wire_message_encode(&bad_title, &mut out),
            AISD_ERR_INVALID_ARGUMENT
        );
    }
}

#[test]
fn null_pointers_are_rejected_not_dereferenced() {
    unsafe {
        let mut out = base();
        let mut bytes = AisdBytes::EMPTY;
        let valid = AisdWireMessage {
            tag: AISD_WIRE_BELL,
            ..base()
        };
        assert_eq!(
            aisd_frame_decoder_append(core::ptr::null_mut(), b"x".as_ptr(), 1),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_frame_decoder_next(core::ptr::null_mut(), &mut out),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_wire_message_encode(core::ptr::null(), &mut bytes),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_wire_message_encode(&valid, core::ptr::null_mut()),
            AISD_ERR_NULL
        );
        // Frees on null are no-ops, not crashes.
        aisd_frame_decoder_free(core::ptr::null_mut());
        aisd_wire_message_free(core::ptr::null_mut());
        aisd_bytes_free(AisdBytes::EMPTY);
    }
}

// ---- Single-payload decode (aisd_wire_message_decode) -------------------------------------

#[test]
fn decode_single_payload_matches_encode() {
    unsafe {
        let payload = b"\x1b[2J hi \xf0\x9f\x9a\x80";
        let msg = AisdWireMessage {
            tag: AISD_WIRE_OUTPUT,
            seq: 42,
            data: borrow(payload),
            ..base()
        };
        // Encode a full frame, then strip the 4-byte length prefix to get the bare payload
        // (the single-payload decode is the de-framed counterpart of the streaming decoder).
        let mut frame = AisdBytes::EMPTY;
        assert_eq!(aisd_wire_message_encode(&msg, &mut frame), AISD_OK);
        let frame_bytes = view(frame);
        let body = &frame_bytes[4..];

        let mut out = base();
        assert_eq!(
            aisd_wire_message_decode(body.as_ptr(), body.len(), &mut out),
            AISD_OK
        );
        assert_eq!(out.tag, AISD_WIRE_OUTPUT);
        assert_eq!(out.seq, 42);
        assert_eq!(view(out.data), payload);

        aisd_wire_message_free(&mut out);
        aisd_bytes_free(frame);
    }
}

// ---- Zero-copy DATA-frame path (aisd_wire_data_frame_encode_into / _view) -----------------

#[test]
fn data_frame_zero_copy_matches_owned_encode_and_round_trips() {
    unsafe {
        let cases: [(u8, i64, &[u8]); 4] = [
            (AISD_WIRE_OUTPUT, 99, b"hello world"),
            (AISD_WIRE_OUTPUT, i64::MAX, b""),
            (AISD_WIRE_INPUT, 0, &[0x1b, 0x5b, 0x41]),
            (AISD_WIRE_INPUT, 0, b""),
        ];
        for (tag, seq, payload) in cases {
            // The zero-copy frame must be byte-identical to the owned wire-message encode.
            let owned = AisdWireMessage {
                tag,
                seq,
                data: borrow(payload),
                ..base()
            };
            let mut want = AisdBytes::EMPTY;
            assert_eq!(aisd_wire_message_encode(&owned, &mut want), AISD_OK);
            let want_bytes = view(want);
            aisd_bytes_free(want);

            let mut buf = vec![0u8; want_bytes.len()];
            let mut written = 0usize;
            assert_eq!(
                aisd_wire_data_frame_encode_into(
                    tag,
                    seq,
                    payload.as_ptr(),
                    payload.len(),
                    buf.as_mut_ptr(),
                    buf.len(),
                    &mut written,
                ),
                AISD_OK
            );
            assert_eq!(written, want_bytes.len(), "written len for tag {tag}");
            assert_eq!(
                buf, want_bytes,
                "zero-copy frame == owned encode for tag {tag}"
            );

            // The borrowed view reads the bulk bytes back without a copy (payload = frame minus prefix).
            let body = &buf[4..];
            let mut dv = AisdDataFrameView {
                tag: 0,
                seq: 0,
                bytes: core::ptr::null(),
                bytes_len: 0,
            };
            assert_eq!(
                aisd_wire_data_frame_view(body.as_ptr(), body.len(), &mut dv),
                AISD_OK
            );
            assert_eq!(dv.tag, tag);
            if tag == AISD_WIRE_OUTPUT {
                assert_eq!(dv.seq, seq);
            }
            let got = if dv.bytes.is_null() {
                Vec::new()
            } else {
                core::slice::from_raw_parts(dv.bytes, dv.bytes_len).to_vec()
            };
            assert_eq!(got, payload, "borrowed bulk bytes for tag {tag}");
        }
    }
}

#[test]
fn data_frame_view_routes_control_and_guards() {
    unsafe {
        // A control payload (bye = 13) → tag 0: the caller decodes it through the owned path.
        let bye = [AISD_WIRE_BYE];
        let mut dv = AisdDataFrameView {
            tag: 9,
            seq: 7,
            bytes: core::ptr::null(),
            bytes_len: 0,
        };
        assert_eq!(
            aisd_wire_data_frame_view(bye.as_ptr(), bye.len(), &mut dv),
            AISD_OK
        );
        assert_eq!(dv.tag, 0, "control frame reported as tag 0");

        // Empty payload → truncated; null payload with len != 0 → null guard.
        assert_eq!(
            aisd_wire_data_frame_view(core::ptr::null(), 0, &mut dv),
            AISD_ERR_TRUNCATED
        );
        assert_eq!(
            aisd_wire_data_frame_view(core::ptr::null(), 1, &mut dv),
            AISD_ERR_NULL
        );

        // encode-into guards: non-DATA tag and a too-small buffer both → invalid argument.
        let mut buf = [0u8; 4];
        let mut w = 0usize;
        assert_eq!(
            aisd_wire_data_frame_encode_into(
                AISD_WIRE_EXIT,
                0,
                core::ptr::null(),
                0,
                buf.as_mut_ptr(),
                buf.len(),
                &mut w,
            ),
            AISD_ERR_INVALID_ARGUMENT
        );
        assert_eq!(
            aisd_wire_data_frame_encode_into(
                AISD_WIRE_OUTPUT,
                0,
                b"x".as_ptr(),
                1,
                buf.as_mut_ptr(),
                buf.len(),
                &mut w,
            ),
            AISD_ERR_INVALID_ARGUMENT,
            "output frame needs 14 bytes; a 4-byte out is too small"
        );
        assert_eq!(
            aisd_wire_data_frame_encode_into(
                AISD_WIRE_OUTPUT,
                0,
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
                &mut w,
            ),
            AISD_ERR_NULL
        );
    }
}

#[test]
fn decode_reports_errors_and_null_guards() {
    unsafe {
        let mut out = base();
        // Unknown type byte.
        assert_eq!(
            aisd_wire_message_decode([0xFFu8].as_ptr(), 1, &mut out),
            AISD_ERR_UNKNOWN_TYPE
        );
        // Type 2 (exit) needs a 4-byte code; one body byte => truncated.
        let short = [2u8, 0u8];
        assert_eq!(
            aisd_wire_message_decode(short.as_ptr(), short.len(), &mut out),
            AISD_ERR_TRUNCATED
        );
        // Empty payload has no type byte => truncated (null+len0 is allowed input).
        assert_eq!(
            aisd_wire_message_decode(core::ptr::null(), 0, &mut out),
            AISD_ERR_TRUNCATED
        );
        // Null guards.
        assert_eq!(
            aisd_wire_message_decode(core::ptr::null(), 1, &mut out),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_wire_message_decode([1u8].as_ptr(), 1, core::ptr::null_mut()),
            AISD_ERR_NULL
        );
    }
}

// ---- video_control (the nested-array windowList path, driven as an external C caller) --------

/// A zeroed control message — every numeric field 0, no records (the external-caller analogue of
/// the crate-internal `AisdVideoControl::zeroed`, which is private).
const fn control_base() -> AisdVideoControl {
    AisdVideoControl {
        kind: 0,
        protocol_version: 0,
        requested_window_id: 0,
        viewport_w: 0.0,
        viewport_h: 0.0,
        accepted: 0,
        stream_id: 0,
        full_range: 0,
        bounds_x: 0.0,
        bounds_y: 0.0,
        bounds_w: 0.0,
        bounds_h: 0.0,
        capture_width: 0,
        capture_height: 0,
        desired_w: 0.0,
        desired_h: 0.0,
        epoch: 0,
        fps: 0,
        scroll_dx: 0,
        scroll_dy: 0,
        records: core::ptr::null_mut(),
        records_len: 0,
        mask_rects: core::ptr::null_mut(),
        mask_rects_len: 0,
    }
}

/// One borrowed summary record (the strings are copied by `encode`, never freed by Rust).
const fn summary(
    window_id: u32,
    width: u16,
    height: u16,
    name: &[u8],
    title: &[u8],
) -> AisdVideoSummary {
    AisdVideoSummary {
        window_id,
        width,
        height,
        is_secure: 0,
        name: borrow(name),
        title: borrow(title),
    }
}

#[test]
fn video_control_window_list_round_trips_and_owned_array_frees() {
    unsafe {
        let recs = [
            summary(604, 1800, 943, b"Google Chrome", b"Tab"),
            summary(10, 920, 436, b"Finder", b""), // empty title
        ];
        let mut msg = control_base();
        msg.kind = AISD_VIDEO_CONTROL_WINDOW_LIST;
        msg.records = recs.as_ptr().cast_mut();
        msg.records_len = recs.len();

        let mut frame = AisdBytes::EMPTY;
        assert_eq!(aisd_video_control_encode(&msg, &mut frame), AISD_OK);

        let mut out = control_base();
        assert_eq!(
            aisd_video_control_decode(frame.ptr, frame.len, &mut out),
            AISD_OK
        );
        assert_eq!(out.kind, AISD_VIDEO_CONTROL_WINDOW_LIST);
        assert_eq!(out.records_len, 2);
        let decoded = core::slice::from_raw_parts(out.records, out.records_len);
        assert_eq!(decoded[0].window_id, 604);
        assert_eq!((decoded[0].width, decoded[0].height), (1800, 943));
        assert_eq!(view(decoded[0].name), b"Google Chrome");
        assert_eq!(view(decoded[0].title), b"Tab");
        assert_eq!(decoded[1].window_id, 10);
        assert_eq!(view(decoded[1].name), b"Finder");
        assert!(view(decoded[1].title).is_empty());

        aisd_video_control_free(&mut out);
        aisd_video_control_free(&mut out); // idempotent: a second free is a no-op
        assert!(out.records.is_null());
        assert_eq!(out.records_len, 0);
        aisd_bytes_free(frame);
    }
}

/// A fresh, all-empty classifier out struct.
const fn empty_dialog() -> AisdSystemDialog {
    AisdSystemDialog {
        window_id: 0,
        width: 0,
        height: 0,
        is_secure: 0,
        owner: AisdBytes::EMPTY,
        title: AisdBytes::EMPTY,
    }
}

#[test]
fn system_dialog_classify_round_trips_and_owned_strings_free() {
    unsafe {
        let owner = b"SecurityAgent";
        let bundle = b"com.apple.SecurityAgent";
        let title = b"Authenticate";
        let frame = AisdRect {
            x: 830.0,
            y: 201.0,
            width: 260.0,
            height: 312.0,
        };
        let mut out = empty_dialog();
        assert_eq!(
            aisd_system_dialog_classify(
                1966,
                owner.as_ptr(),
                owner.len(),
                bundle.as_ptr(),
                bundle.len(),
                1,
                title.as_ptr(),
                title.len(),
                frame,
                aisd_system_dialog_min_size(),
                &mut out,
            ),
            AISD_OK
        );
        assert_eq!(out.window_id, 1966);
        assert_eq!((out.width, out.height), (260, 312));
        assert_eq!(out.is_secure, 1);
        assert_eq!(view(out.owner), owner);
        assert_eq!(view(out.title), title);

        aisd_system_dialog_free(&mut out);
        aisd_system_dialog_free(&mut out); // idempotent
        assert!(out.owner.ptr.is_null() && out.title.ptr.is_null());
    }
}

#[test]
fn system_dialog_classify_non_dialog_empty_and_null_out_guard() {
    unsafe {
        let owner = b"Google Chrome";
        let bundle = b"com.google.Chrome";
        let frame = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 700.0,
            height: 500.0,
        };
        let mut out = empty_dialog();
        // A normal app window is not a system dialog → AISD_EMPTY, nothing written.
        assert_eq!(
            aisd_system_dialog_classify(
                1,
                owner.as_ptr(),
                owner.len(),
                bundle.as_ptr(),
                bundle.len(),
                1,
                core::ptr::null(),
                0,
                frame,
                60,
                &mut out,
            ),
            AISD_EMPTY
        );
        assert!(out.owner.ptr.is_null());

        // A null out is rejected without dereferencing.
        assert_eq!(
            aisd_system_dialog_classify(
                1,
                owner.as_ptr(),
                owner.len(),
                core::ptr::null(),
                0,
                1,
                core::ptr::null(),
                0,
                frame,
                60,
                core::ptr::null_mut(),
            ),
            AISD_ERR_NULL
        );
    }
}

#[test]
fn recovery_deduper_opaque_handle_dedups_and_frees() {
    unsafe {
        let d = aisd_recovery_deduper_new(0.025, 16);
        assert!(!d.is_null());
        let wire = [3u8, 0, 0, 0, 50];
        // First sighting admitted, byte-identical copy dropped.
        assert_eq!(
            aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.000),
            1
        );
        assert_eq!(
            aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.005),
            0
        );
        // A distinct datagram is admitted alongside.
        let other = [4u8, 1];
        assert_eq!(
            aisd_recovery_deduper_admit(d, other.as_ptr(), other.len(), 100.006),
            1
        );
        // After the window the original ages back to admissible.
        assert_eq!(
            aisd_recovery_deduper_admit(d, wire.as_ptr(), wire.len(), 100.030),
            1
        );
        aisd_recovery_deduper_free(d);
        aisd_recovery_deduper_free(core::ptr::null_mut()); // no-op
        // A null handle fails open (process, never drop).
        assert_eq!(
            aisd_recovery_deduper_admit(core::ptr::null_mut(), wire.as_ptr(), wire.len(), 0.0),
            1
        );
    }
}

#[test]
fn ycbcr_coefficients_video_vs_full() {
    let video = aisd_ycbcr_coefficients(0);
    let full = aisd_ycbcr_coefficients(1);
    // Only the luma expansion differs between the two ranges.
    assert!((video.luma_scale - 255.0 / 219.0).abs() < 1e-6);
    assert!(video.luma_bias > 0.0);
    assert_eq!(full.luma_scale, 1.0);
    assert_eq!(full.luma_bias, 0.0);
    // Chroma centre + the four matrix coefficients are range-independent.
    assert_eq!(video.chroma_bias, full.chroma_bias);
    assert_eq!(video.cr_to_r, full.cr_to_r);
    assert_eq!(video.cb_to_g, full.cb_to_g);
    assert_eq!(video.cr_to_g, full.cr_to_g);
    assert_eq!(video.cb_to_b, full.cb_to_b);
    // Any nonzero byte selects full range (the C ABI reads `!= 0`).
    assert_eq!(aisd_ycbcr_coefficients(0xFF), full);
}

#[test]
fn recovery_message_round_trips_through_the_c_struct() {
    unsafe {
        // A NetworkStats report (eleven u32s, incl. a negative trend bit-pattern) round-trips.
        let mut msg = AisdRecoveryMessage {
            kind: AISD_RECOVERY_NETWORK_STATS,
            stats: AisdNetworkStats {
                frames_received: 600,
                fec_recovered: 12,
                unrecovered: 3,
                latest_host_send_ts: 1_234_567,
                client_hold_ms: 7,
                owd_jitter_micros: 850,
                owd_trend_milli: (-987_i32) as u32,
                owd_trend_flags: (42_u32 << 8) | 1,
                pacer_late_frames: 4,
                pacer_present_gaps: 6,
                pacer_depth: 2,
            },
            ..AisdRecoveryMessage::default()
        };
        let mut frame = AisdBytes::EMPTY;
        assert_eq!(aisd_recovery_message_encode(&msg, &mut frame), AISD_OK);
        let mut out = AisdRecoveryMessage::default();
        assert_eq!(
            aisd_recovery_message_decode(frame.ptr, frame.len, &mut out),
            AISD_OK
        );
        assert_eq!(out, msg);
        aisd_bytes_free(frame);

        // A valid body with a trailing byte is malformed (byte-keyed dedup contract).
        msg.kind = AISD_RECOVERY_REQUEST_LTR_REFRESH;
        msg.stats = AisdNetworkStats::default();
        msg.from_frame_id = 1;
        let mut lframe = AisdBytes::EMPTY;
        assert_eq!(aisd_recovery_message_encode(&msg, &mut lframe), AISD_OK);
        let mut padded = core::slice::from_raw_parts(lframe.ptr, lframe.len).to_vec();
        padded.push(0);
        assert_eq!(
            aisd_recovery_message_decode(padded.as_ptr(), padded.len(), &mut out),
            AISD_ERR_MALFORMED
        );
        aisd_bytes_free(lframe);

        // An unknown kind cannot encode.
        let bad = AisdRecoveryMessage {
            kind: 99,
            ..AisdRecoveryMessage::default()
        };
        let mut bframe = AisdBytes::EMPTY;
        assert_eq!(
            aisd_recovery_message_encode(&bad, &mut bframe),
            AISD_ERR_INVALID_ARGUMENT
        );
    }
}

#[test]
fn static_idr_decider_opaque_handle_drives_cadence_and_frees() {
    unsafe {
        // Default quiet window == heartbeat (has_quiet_window = 0).
        let d = aisd_static_idr_decider_new(1.0, 0.0, 0);
        assert!(!d.is_null());
        assert_eq!(aisd_static_idr_decider_heartbeat(d), 1.0);
        assert_eq!(aisd_static_idr_decider_quiet_window(d), 1.0);
        // Armed, none emitted, no real frame ⇒ fire.
        assert_eq!(aisd_static_idr_decider_should_reencode(d, 0.5, 0, 1), 1);
        // A real frame anchors the live clock; the quiet window then suppresses.
        aisd_static_idr_decider_on_complete_frame(d, 10.0);
        assert_eq!(aisd_static_idr_decider_last_complete_encode(d), 10.0);
        assert_eq!(aisd_static_idr_decider_should_reencode(d, 10.5, 0, 1), 0);
        assert_eq!(aisd_static_idr_decider_should_reencode(d, 11.0, 0, 1), 1);
        // A synthetic re-anchors the cadence.
        aisd_static_idr_decider_record_synthetic(d, 11.0);
        assert_eq!(aisd_static_idr_decider_should_reencode(d, 11.5, 0, 1), 0);
        aisd_static_idr_decider_free(d);
        aisd_static_idr_decider_free(core::ptr::null_mut()); // no-op
        // A null handle never forces an encode.
        assert_eq!(
            aisd_static_idr_decider_should_reencode(core::ptr::null(), 0.0, 1, 1),
            0
        );
    }
}

#[test]
fn decode_gate_opaque_handle_gates_until_anchor_and_frees() {
    unsafe {
        let g = aisd_decode_gate_new();
        assert!(!g.is_null());
        assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_OPEN);
        assert_eq!(
            aisd_decode_gate_verdict(g, 10, 0, 0),
            AISD_DECODE_GATE_VERDICT_SUBMIT
        );

        // Two losses open a broken-chain episode with wrap-aware min/max bounds.
        aisd_decode_gate_note_loss(g, 110);
        aisd_decode_gate_note_loss(g, 100);
        assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_BROKEN_CHAIN);
        let mut id: u32 = 0;
        assert_eq!(aisd_decode_gate_min_lost_frame_id(g, &mut id), 1);
        assert_eq!(id, 100);
        assert_eq!(aisd_decode_gate_max_lost_frame_id(g, &mut id), 1);
        assert_eq!(id, 110);
        // Mid-episode delta drops; pre-break delta + acked anchor submit while session alive.
        assert_eq!(
            aisd_decode_gate_verdict(g, 105, 0, 0),
            AISD_DECODE_GATE_VERDICT_DROP
        );
        assert_eq!(
            aisd_decode_gate_verdict(g, 99, 0, 0),
            AISD_DECODE_GATE_VERDICT_SUBMIT
        );
        assert_eq!(
            aisd_decode_gate_verdict(g, 111, 0, 1),
            AISD_DECODE_GATE_VERDICT_SUBMIT
        );

        // Hard failure tears the session down: only a keyframe re-anchors.
        aisd_decode_gate_note_hard_decode_failure(g);
        assert_eq!(
            aisd_decode_gate_mode(g),
            AISD_DECODE_GATE_MODE_NEED_KEYFRAME
        );
        assert_eq!(
            aisd_decode_gate_verdict(g, 111, 0, 1),
            AISD_DECODE_GATE_VERDICT_DROP
        );
        aisd_decode_gate_note_decode_succeeded(g, 112, 1);
        assert_eq!(aisd_decode_gate_mode(g), AISD_DECODE_GATE_MODE_OPEN);
        let mut none: u32 = 4242;
        assert_eq!(aisd_decode_gate_min_lost_frame_id(g, &mut none), 0);
        assert_eq!(none, 4242);

        aisd_decode_gate_free(g);
        aisd_decode_gate_free(core::ptr::null_mut()); // no-op
        // A null handle reads Open and submits everything.
        assert_eq!(
            aisd_decode_gate_mode(core::ptr::null()),
            AISD_DECODE_GATE_MODE_OPEN
        );
        assert_eq!(
            aisd_decode_gate_verdict(core::ptr::null(), 7, 0, 0),
            AISD_DECODE_GATE_VERDICT_SUBMIT
        );
    }
}

#[test]
fn owd_late_detector_opaque_handle_flags_spikes_and_frees() {
    unsafe {
        let d = aisd_owd_late_detector_new(2000.0, 25.0, 1.25, 20);
        assert!(!d.is_null());
        let interval = 1000.0 / 60.0;
        let mut arrival = 5000.0;
        let mut send: u32 = 91_000;
        let mut dev = f64::NAN;
        // Warm 30 clean samples — none late, out-param never touched.
        for _ in 0..30 {
            assert_eq!(
                aisd_owd_late_detector_note(d, arrival, send, interval, &mut dev),
                0
            );
            arrival += 16.7;
            send = send.wrapping_add(17);
        }
        assert!(dev.is_nan());
        // A 40ms spike past the 25ms floor is late with deviation > 10ms.
        arrival += 16.7 + 40.0;
        send = send.wrapping_add(17);
        assert_eq!(
            aisd_owd_late_detector_note(d, arrival, send, interval, &mut dev),
            1
        );
        assert!(dev > 10.0);
        aisd_owd_late_detector_free(d);
        aisd_owd_late_detector_free(core::ptr::null_mut()); // no-op
        // A null handle never reports late.
        assert_eq!(
            aisd_owd_late_detector_note(core::ptr::null_mut(), 0.0, 0, interval, &mut dev),
            0
        );
    }
}

#[test]
fn input_button_balance_opaque_handle_balances_and_frees() {
    unsafe {
        let b = aisd_input_button_balance_new();
        assert!(!b.is_null());
        // Clean left click: posts, held then cleared.
        let p = aisd_input_button_balance_plan(b, 2, 0); // MOUSE_DOWN, left
        assert_eq!(p.has_pre_release, 0);
        assert_eq!(p.suppress, 0);
        assert_eq!(aisd_input_button_balance_held_mask(b), 0b001);
        // Stuck down (lost up) pre-releases.
        let p = aisd_input_button_balance_plan(b, 2, 0);
        assert_eq!(p.has_pre_release, 1);
        assert_eq!(p.pre_release_button, 0);
        // Up releases; a duplicate up is suppressed.
        assert_eq!(aisd_input_button_balance_plan(b, 3, 0).suppress, 0); // MOUSE_UP
        assert_eq!(aisd_input_button_balance_held_mask(b), 0);
        assert_eq!(aisd_input_button_balance_plan(b, 3, 0).suppress, 1);
        // Independent right + other tracking via the bitmask.
        let _ = aisd_input_button_balance_plan(b, 2, 1); // right down
        let _ = aisd_input_button_balance_plan(b, 2, 2); // other down
        assert_eq!(aisd_input_button_balance_held_mask(b), 0b110);
        aisd_input_button_balance_free(b);
        aisd_input_button_balance_free(core::ptr::null_mut()); // no-op
        // A null handle returns the default plan and an empty mask.
        let p = aisd_input_button_balance_plan(core::ptr::null_mut(), 3, 0);
        assert_eq!(p.has_pre_release, 0);
        assert_eq!(p.suppress, 0);
        assert_eq!(aisd_input_button_balance_held_mask(core::ptr::null()), 0);
    }
}

#[test]
fn recovery_idr_policy_opaque_handle_gates_grants_and_frees() {
    unsafe {
        let p = aisd_recovery_idr_policy_new(0.75, 0.040, 0.250, 2.0, 2.0, 1.5, 4);
        assert!(!p.is_null());
        assert_eq!(aisd_recovery_idr_policy_available_tokens(p), 2.0);
        // First request (sentinel "nothing decoded") grants and spends a token.
        assert_eq!(
            aisd_recovery_idr_policy_decide(p, 10.0, 0, 0, 0.05),
            AISD_RECOVERY_IDR_GRANT
        );
        assert_eq!(aisd_recovery_idr_policy_available_tokens(p), 1.0);
        // A fresh keyframe in flight ⇒ a behind client is suppressed within the grace window.
        aisd_recovery_idr_policy_note_keyframe_sent(p, 100, 5.0);
        assert_eq!(
            aisd_recovery_idr_policy_decide(p, 5.02, 99, 1, 0.05),
            AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT
        );
        assert!((aisd_recovery_idr_policy_grace(p, 0.0) - 0.040).abs() < 1e-9);
        // A request older than an acked keyframe is stale.
        aisd_recovery_idr_policy_note_keyframe_delivered(p, 100);
        assert_eq!(
            aisd_recovery_idr_policy_decide(p, 9.0, 99, 1, 0.05),
            AISD_RECOVERY_IDR_SUPPRESS_STALE
        );
        aisd_recovery_idr_policy_free(p);
        aisd_recovery_idr_policy_free(core::ptr::null_mut()); // no-op
        // A null handle grants and reports zero tokens.
        assert_eq!(
            aisd_recovery_idr_policy_decide(core::ptr::null_mut(), 0.0, 0, 0, 0.0),
            AISD_RECOVERY_IDR_GRANT
        );
        assert_eq!(
            aisd_recovery_idr_policy_available_tokens(core::ptr::null()),
            0.0
        );
    }
}

#[test]
fn video_mux_router_opaque_handle_routes_and_frees() {
    unsafe {
        let r = aisd_video_mux_router_new();
        assert!(!r.is_null());
        // Unknown → reject; admit → route; empty → drop.
        assert_eq!(
            aisd_video_mux_router_route(r, 11, 1, 1200),
            AISD_MUX_DECISION_REJECT_UNADMITTED
        );
        aisd_video_mux_router_admit(r, 11);
        assert_eq!(aisd_video_mux_router_is_admitted(r, 11), 1);
        assert_eq!(
            aisd_video_mux_router_route(r, 11, 1, 1200),
            AISD_MUX_DECISION_ROUTE
        );
        assert_eq!(
            aisd_video_mux_router_route(r, 11, 1, 0),
            AISD_MUX_DECISION_DROP
        );
        // Retire → drop-retired.
        aisd_video_mux_router_retire(r, 11);
        assert_eq!(
            aisd_video_mux_router_route(r, 11, 1, 1200),
            AISD_MUX_DECISION_DROP_RETIRED
        );
        // begin/end drain transitions.
        aisd_video_mux_router_admit(r, 12);
        aisd_video_mux_router_begin_drain(r, 12);
        assert_eq!(aisd_video_mux_router_is_draining(r, 12), 1);
        assert_eq!(
            aisd_video_mux_router_route(r, 12, 1, 1200),
            AISD_MUX_DECISION_DROP_DRAINING
        );
        aisd_video_mux_router_end_drain(r, 12);
        assert_eq!(aisd_video_mux_router_is_draining(r, 12), 0);
        assert_eq!(
            aisd_video_mux_router_route(r, 12, 1, 1200),
            AISD_MUX_DECISION_DROP_RETIRED
        );
        // bootstrap_action (static, pure): retired hello on control re-admits; non-hello drops.
        assert_eq!(
            aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_RETIRED, 0, 1, 0),
            AISD_MUX_BOOTSTRAP_DELIVER
        );
        assert_eq!(
            aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_RETIRED, 0, 0, 0),
            AISD_MUX_BOOTSTRAP_DROP_NO_STAMP
        );
        // A list request on control also bootstraps an unadmitted lane.
        assert_eq!(
            aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_REJECT_UNADMITTED, 0, 0, 1),
            AISD_MUX_BOOTSTRAP_DELIVER
        );
        aisd_video_mux_router_free(r);
        aisd_video_mux_router_free(core::ptr::null_mut()); // no-op
        assert_eq!(
            aisd_video_mux_router_route(core::ptr::null(), 1, 1, 100),
            AISD_MUX_DECISION_REJECT_UNADMITTED
        );
        assert_eq!(aisd_video_mux_router_is_admitted(core::ptr::null(), 1), 0);
    }
}

#[test]
fn pacer_depth_policy_opaque_handle_promotes_and_frees() {
    unsafe {
        // The default config crosses by value as a flat struct.
        let cfg = AisdPacerDepthConfig {
            late_gap_factor: 1.6,
            absolute_late_floor_seconds: 0.028,
            idle_gap_seconds: 0.25,
            gap_gradient_factor: 1.45,
            dense_min_arrivals: 8,
            dense_window_seconds: 0.35,
            late_slack_fraction: 0.25,
            promote_late_count: 2,
            promote_window_seconds: 1.0,
            demote_clean_seconds: 2.5,
            min_hold_seconds: 1.0,
            demote_tolerance_lates: 1,
            promote_warmup_seconds: 2.0,
            boost_depth: 2,
            interval_ring_size: 15,
            min_samples_for_estimate: 5,
            default_interval_seconds: 1.0 / 60.0,
            min_interval_seconds: 1.0 / 240.0,
            max_interval_seconds: 1.0 / 10.0,
        };
        let p = aisd_pacer_depth_policy_new(cfg, 1);
        assert!(!p.is_null());
        assert_eq!(aisd_pacer_depth_policy_depth(p), 1);
        // Config round-trips: late boundary = 0.028 + 0.25/60 (slack term on top, before warmup).
        let expected_late = 0.028 + 0.25 / 60.0;
        assert!((aisd_pacer_depth_policy_late_threshold_seconds(p) - expected_late).abs() < 1e-6);
        // Two network-late events past the warmup window promote to boost depth.
        aisd_pacer_depth_policy_note_arrival(p, 0.0);
        aisd_pacer_depth_policy_note_network_late(p, 3.0);
        assert_eq!(aisd_pacer_depth_policy_depth(p), 1);
        aisd_pacer_depth_policy_note_network_late(p, 3.2);
        assert_eq!(aisd_pacer_depth_policy_depth(p), 2);
        // Counters drain then reset.
        let c = aisd_pacer_depth_policy_drain_counters(p);
        assert_eq!(c.late_frames, 2);
        assert_eq!(aisd_pacer_depth_policy_drain_counters(p).late_frames, 0);
        aisd_pacer_depth_policy_set_interval_hint(p, 1.0 / 30.0, 1);
        aisd_pacer_depth_policy_set_interval_hint(p, 0.0, 0); // clear
        assert_eq!(
            aisd_pacer_depth_policy_note_present(p, 10.0),
            AISD_PACER_GAP_FIRST
        );
        aisd_pacer_depth_policy_free(p);
        aisd_pacer_depth_policy_free(core::ptr::null_mut()); // no-op
        // Null handle: depth 1, First, empty drain.
        assert_eq!(aisd_pacer_depth_policy_depth(core::ptr::null()), 1);
        assert_eq!(
            aisd_pacer_depth_policy_drain_counters(core::ptr::null_mut()).late_frames,
            0
        );
    }
}

#[test]
fn scroll_reprojector_opaque_handle_integrates_resets_and_frees() {
    unsafe {
        // The default config crosses by value as a flat struct.
        let cfg = AisdScrollReprojectorConfig {
            max_band: 0.125,
            decay_seconds: 0.12,
        };
        let r = aisd_scroll_reprojector_new(cfg);
        assert!(!r.is_null());
        let (mut x, mut y) = (0.0_f64, 0.0_f64);
        // Drive a downward velocity → advance → a non-zero offset (vel*elapsed within the band).
        aisd_scroll_reprojector_note_velocity(r, 0.0, 0.2, AISD_SCROLL_PHASE_ACTIVE);
        assert_eq!(
            aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y),
            AISD_OK
        );
        assert!((y - 0.01).abs() < 1e-9 && x.abs() < 1e-12);
        // RESET on a real decoded frame → EXACTLY zero (the no-double-count invariant).
        aisd_scroll_reprojector_note_real_frame(r);
        assert_eq!(
            aisd_scroll_reprojector_advance(r, 0.0, &mut x, &mut y),
            AISD_OK
        );
        assert_eq!((x, y), (0.0, 0.0));
        // The live velocity survives the reset: the next tick re-integrates FROM zero.
        assert_eq!(
            aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y),
            AISD_OK
        );
        assert!((y - 0.01).abs() < 1e-9);
        // A momentum flick clamps to the band; ended arms the decay (offset shrinks).
        aisd_scroll_reprojector_note_real_frame(r);
        aisd_scroll_reprojector_note_velocity(r, 0.0, 9.0, AISD_SCROLL_PHASE_MOMENTUM);
        let _ = aisd_scroll_reprojector_advance(r, 1.0, &mut x, &mut y);
        assert!((y - 0.125).abs() < 1e-9);
        aisd_scroll_reprojector_note_velocity(r, 0.0, 0.0, AISD_SCROLL_PHASE_ENDED);
        let before = y;
        let _ = aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y);
        assert!(y < before);
        // reset clears velocity too: no stale resume.
        aisd_scroll_reprojector_reset(r);
        let _ = aisd_scroll_reprojector_advance(r, 0.05, &mut x, &mut y);
        assert_eq!((x, y), (0.0, 0.0));
        aisd_scroll_reprojector_free(r);
        aisd_scroll_reprojector_free(core::ptr::null_mut()); // no-op
        // Null handle: every fold is a no-op; advance reports NULL and leaves the out-params alone.
        aisd_scroll_reprojector_note_velocity(
            core::ptr::null_mut(),
            1.0,
            1.0,
            AISD_SCROLL_PHASE_ACTIVE,
        );
        aisd_scroll_reprojector_note_real_frame(core::ptr::null_mut());
        x = 3.0;
        y = 4.0;
        assert_eq!(
            aisd_scroll_reprojector_advance(core::ptr::null_mut(), 0.1, &mut x, &mut y),
            AISD_ERR_NULL
        );
        assert_eq!((x, y), (3.0, 4.0));
    }
}

// ---- fec (NEON-backed Reed-Solomon codec over the C ABI) -----------------------------------

/// Borrows a slice as an input data shard (read-only; never freed by the call).
const fn shard(bytes: &[u8]) -> AisdBytes {
    if bytes.is_empty() {
        AisdBytes::EMPTY
    } else {
        AisdBytes {
            ptr: bytes.as_ptr().cast_mut(),
            len: bytes.len(),
            cap: 0,
        }
    }
}

#[test]
fn fec_multi_loss_recover_via_c_abi() {
    unsafe {
        // k=4, m=2: lose 2 data shards in a single group and recover BOTH, byte-exact.
        let codec = aisd_fec_codec_new(4, 2);
        assert!(!codec.is_null());
        let owned: Vec<Vec<u8>> = (0..4u8)
            .map(|i| vec![i, i.wrapping_mul(37), i ^ 0xA5, i.wrapping_add(200)])
            .collect();
        let data_in: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();

        let mut parity = AisdBytesArray::EMPTY;
        assert_eq!(
            aisd_fec_parity(codec, data_in.as_ptr(), data_in.len(), 4, &mut parity),
            AISD_OK
        );
        assert_eq!(parity.count, 2, "one group of k=4 => m=2 parity shards");

        // Erase shards 0 and 2 (present=0; their bytes become a hole carrying no AisdBytes).
        let mut data: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();
        let mut present = [1u8; 4];
        present[0] = 0;
        present[2] = 0;
        data[0] = AisdBytes::EMPTY;
        data[2] = AisdBytes::EMPTY;
        let parity_present = vec![1u8; parity.count];
        let mut recovered = [0u8; 4];

        assert_eq!(
            aisd_fec_recover(
                codec,
                data.as_mut_ptr(),
                present.as_ptr(),
                4,
                parity.items,
                parity_present.as_ptr(),
                parity.count,
                4,
                recovered.as_mut_ptr(),
            ),
            AISD_OK
        );
        assert_eq!(recovered, [1, 0, 1, 0], "exactly the two holes filled");
        assert_eq!(view(data[0]), owned[0], "shard 0 recovered byte-exact");
        assert_eq!(view(data[2]), owned[2], "shard 2 recovered byte-exact");
        // Surviving shards are still borrowed (cap==0) — only the two recovered ones are owned.
        aisd_bytes_free(data[0]);
        aisd_bytes_free(data[2]);
        aisd_bytes_array_free(&mut parity);
        aisd_fec_codec_free(codec);
    }
}

#[test]
fn fec_unrecoverable_more_holes_than_parity_leaves_holes() {
    unsafe {
        // k=5, m=2 but 3 holes in the group => unrecoverable; no panic, holes stay holes.
        let codec = aisd_fec_codec_new(5, 2);
        let owned: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i; 6]).collect();
        let data_in: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();
        let mut parity = AisdBytesArray::EMPTY;
        assert_eq!(
            aisd_fec_parity(codec, data_in.as_ptr(), data_in.len(), 5, &mut parity),
            AISD_OK
        );

        let mut data: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();
        let mut present = [1u8; 5];
        for h in [0usize, 2, 4] {
            present[h] = 0;
            data[h] = AisdBytes::EMPTY;
        }
        let parity_present = vec![1u8; parity.count];
        let mut recovered = [7u8; 5];
        assert_eq!(
            aisd_fec_recover(
                codec,
                data.as_mut_ptr(),
                present.as_ptr(),
                5,
                parity.items,
                parity_present.as_ptr(),
                parity.count,
                5,
                recovered.as_mut_ptr(),
            ),
            AISD_OK
        );
        assert_eq!(recovered, [0; 5], "3 holes > m=2 => nothing recovered");
        // No buffer was written to the holes — nothing to free for them.
        assert!(data[0].ptr.is_null() && data[2].ptr.is_null() && data[4].ptr.is_null());
        aisd_bytes_array_free(&mut parity);
        aisd_fec_codec_free(codec);
    }
}

#[test]
fn fec_free_idempotence_and_recovered_shard_free() {
    unsafe {
        // Prove: aisd_bytes_array_free is idempotent (second call no-op), and a recovered shard is
        // a freeable Rust-owned buffer.
        let codec = aisd_fec_codec_new(3, 1);
        let owned: Vec<Vec<u8>> = vec![vec![1, 2, 3], vec![4, 5], vec![6]];
        let data_in: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();
        let mut parity = AisdBytesArray::EMPTY;
        assert_eq!(
            aisd_fec_parity(codec, data_in.as_ptr(), data_in.len(), 3, &mut parity),
            AISD_OK
        );
        assert_eq!(parity.count, 1, "one group, m=1 => one XOR parity");

        let mut data: Vec<AisdBytes> = owned.iter().map(|v| shard(v)).collect();
        let present = [1u8, 0, 1];
        data[1] = AisdBytes::EMPTY;
        let parity_present = [1u8];
        let mut recovered = [0u8; 3];
        assert_eq!(
            aisd_fec_recover(
                codec,
                data.as_mut_ptr(),
                present.as_ptr(),
                3,
                parity.items,
                parity_present.as_ptr(),
                parity.count,
                3,
                recovered.as_mut_ptr(),
            ),
            AISD_OK
        );
        assert_eq!(recovered, [0, 1, 0]);
        assert_eq!(view(data[1]), owned[1]);

        // The recovered shard owns a Rust allocation (cap > 0) — free it.
        assert!(
            data[1].cap > 0 || data[1].len == 0,
            "recovered shard is Rust-owned"
        );
        aisd_bytes_free(data[1]);

        // Free the parity array TWICE — the second is a no-op (idempotent).
        aisd_bytes_array_free(&mut parity);
        assert!(parity.items.is_null() && parity.count == 0);
        aisd_bytes_array_free(&mut parity);
        aisd_bytes_array_free(core::ptr::null_mut()); // null pointer no-op
        aisd_fec_codec_free(codec);
        aisd_fec_codec_free(core::ptr::null_mut()); // no-op
    }
}

#[test]
fn fec_codec_new_rejects_bad_config_and_guards() {
    unsafe {
        // Invalid configs return null instead of aborting across the boundary.
        assert!(aisd_fec_codec_new(0, 1).is_null());
        assert!(aisd_fec_codec_new(1, 0).is_null());
        assert!(aisd_fec_codec_new(128, 128).is_null()); // 256 > 255

        let codec = aisd_fec_codec_new(4, 2);
        let mut out = AisdBytesArray::EMPTY;
        // Null codec / out_parity / data-with-count, and group_size 0.
        assert_eq!(
            aisd_fec_parity(core::ptr::null(), core::ptr::null(), 0, 4, &mut out),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_fec_parity(codec, core::ptr::null(), 0, 4, core::ptr::null_mut()),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_fec_parity(codec, core::ptr::null(), 2, 4, &mut out),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_fec_parity(codec, core::ptr::null(), 0, 0, &mut out),
            AISD_ERR_INVALID_ARGUMENT
        );
        aisd_fec_codec_free(codec);
    }
}

/// Packs one video fragment datagram (the fixed 19-byte big-endian header + payload) onto the wire
/// the way `aislopdesk_core::fragment::FrameFragment::encode` does, so `aisd_reassembler_ingest` can
/// parse it from a raw C-style buffer (no core types needed). `flags`: bit0 keyframe, bit1 parity.
fn pack_fragment(
    stream_seq: u32,
    frame_id: u32,
    frag_index: u16,
    frag_count: u16,
    flags: u8,
    payload: &[u8],
) -> Vec<u8> {
    let mut v = Vec::with_capacity(19 + payload.len());
    v.extend_from_slice(&stream_seq.to_be_bytes());
    v.extend_from_slice(&frame_id.to_be_bytes());
    v.extend_from_slice(&frag_index.to_be_bytes());
    v.extend_from_slice(&frag_count.to_be_bytes());
    v.push(flags);
    v.extend_from_slice(&0u32.to_be_bytes()); // host_send_ts_millis = 0
    v.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    v.extend_from_slice(payload);
    v
}

/// Ingests one packed datagram through the C ABI, returning the populated result.
unsafe fn reassembler_ingest(
    r: *mut aislopdesk_ffi::video::AisdReassembler,
    datagram: &[u8],
) -> AisdReassemblyResult {
    let mut out = AisdReassemblyResult {
        kind: AISD_REASSEMBLY_STALE,
        keyframe: 0,
        crisp: 0,
        recovered_via_fec: 0,
        is_ltr: 0,
        acked_anchored: 0,
        frame_id: 0,
        avcc: AisdBytes::EMPTY,
    };
    let status = unsafe { aisd_reassembler_ingest(r, datagram.as_ptr(), datagram.len(), &mut out) };
    assert_eq!(status, AISD_OK);
    out
}

#[test]
fn reassembler_completes_recovers_and_drops_over_the_c_abi() {
    unsafe {
        // Invalid FEC config => null (no abort across the boundary). k == 0 => no-FEC handle.
        assert!(aisd_reassembler_new(200, 56, 2).is_null());

        // --- whole no-FEC keyframe completes with the concatenated payload + flags ---
        let r = aisd_reassembler_new(0, 1, 2);
        assert!(!r.is_null());
        let f0 = pack_fragment(0, 7, 0, 3, 0x01, &[0xA0, 0xA1, 0xA2]);
        assert_eq!(reassembler_ingest(r, &f0).kind, AISD_REASSEMBLY_PENDING);
        let f1 = pack_fragment(1, 7, 1, 3, 0x01, &[0xB0, 0xB1]);
        assert_eq!(reassembler_ingest(r, &f1).kind, AISD_REASSEMBLY_PENDING);
        let f2 = pack_fragment(2, 7, 2, 3, 0x01, &[0xC0, 0xC1, 0xC2, 0xC3]);
        let mut done = reassembler_ingest(r, &f2);
        assert_eq!(done.kind, AISD_REASSEMBLY_COMPLETED);
        assert_eq!(done.frame_id, 7);
        assert_eq!(done.keyframe, 1);
        assert_eq!(done.recovered_via_fec, 0);
        let avcc = core::slice::from_raw_parts(done.avcc.ptr, done.avcc.len);
        assert_eq!(
            avcc,
            &[0xA0, 0xA1, 0xA2, 0xB0, 0xB1, 0xC0, 0xC1, 0xC2, 0xC3]
        );
        aisd_reassembly_result_free(&mut done);
        assert!(done.avcc.ptr.is_null());
        aisd_reassembly_result_free(&mut done); // idempotent
        aisd_reassembler_free(r);

        // --- single dropped data fragment FEC-recovers (k=2 m=1: 2 data + 1 parity) ---
        let rf = aisd_reassembler_new(2, 1, 2);
        let codec = aisd_fec_codec_new(2, 1);
        let d0: Vec<u8> = vec![0xD0, 0xD1, 0xD2, 0xD3];
        let d1: Vec<u8> = vec![0xE0, 0xE1, 0xE2, 0xE3];
        let data_in = [
            AisdBytes {
                ptr: d0.as_ptr().cast_mut(),
                len: d0.len(),
                cap: 0,
            },
            AisdBytes {
                ptr: d1.as_ptr().cast_mut(),
                len: d1.len(),
                cap: 0,
            },
        ];
        let mut parity = AisdBytesArray::EMPTY;
        assert_eq!(
            aisd_fec_parity(codec, data_in.as_ptr(), 2, 2, &mut parity),
            AISD_OK
        );
        assert_eq!(parity.count, 1);
        let parity_bytes = {
            let p = *parity.items;
            core::slice::from_raw_parts(p.ptr, p.len).to_vec()
        };
        // Ingest data 0 + parity (frag_index 2, parity flag); data 1 is LOST.
        let rd0 = pack_fragment(10, 9, 0, 3, 0x01, &d0);
        assert_eq!(reassembler_ingest(rf, &rd0).kind, AISD_REASSEMBLY_PENDING);
        let rp = pack_fragment(12, 9, 2, 3, 0x01 | 0x02, &parity_bytes);
        let mut rec = reassembler_ingest(rf, &rp);
        assert_eq!(rec.kind, AISD_REASSEMBLY_COMPLETED);
        assert_eq!(rec.recovered_via_fec, 1);
        let ravcc = core::slice::from_raw_parts(rec.avcc.ptr, rec.avcc.len);
        assert_eq!(ravcc, &[0xD0, 0xD1, 0xD2, 0xD3, 0xE0, 0xE1, 0xE2, 0xE3]);
        aisd_reassembly_result_free(&mut rec);
        aisd_bytes_array_free(&mut parity);
        aisd_fec_codec_free(codec);
        aisd_reassembler_free(rf);

        // --- unrecoverable loss surfaces via next_dropped ---
        let rd = aisd_reassembler_new(0, 1, 2);
        let g0 = pack_fragment(20, 0, 0, 2, 0x01, &[1, 2, 3]); // frame 0 frag 0 of 2; frag 1 lost
        assert_eq!(reassembler_ingest(rd, &g0).kind, AISD_REASSEMBLY_PENDING);
        let g1 = pack_fragment(21, 1, 0, 1, 0x01, &[9]); // frame 1 advances the frontier
        let _ = reassembler_ingest(rd, &g1);
        let mut lost = u32::MAX;
        assert_eq!(aisd_reassembler_next_dropped(rd, &mut lost), 1);
        assert_eq!(lost, 0);
        assert_eq!(aisd_reassembler_next_dropped(rd, &mut lost), 0);

        // --- hostile / truncated input is ignored, never a crash; null guards ---
        let junk = [1u8, 2, 3, 4];
        assert_eq!(reassembler_ingest(rd, &junk).kind, AISD_REASSEMBLY_PENDING);
        let mut out = AisdReassemblyResult {
            kind: AISD_REASSEMBLY_STALE,
            keyframe: 0,
            crisp: 0,
            recovered_via_fec: 0,
            is_ltr: 0,
            acked_anchored: 0,
            frame_id: 0,
            avcc: AisdBytes::EMPTY,
        };
        assert_eq!(
            aisd_reassembler_ingest(core::ptr::null_mut(), junk.as_ptr(), 4, &mut out),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_reassembler_ingest(rd, junk.as_ptr(), 4, core::ptr::null_mut()),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_reassembler_next_dropped(core::ptr::null_mut(), core::ptr::null_mut()),
            0
        );
        aisd_reassembler_free(rd);
        aisd_reassembler_free(core::ptr::null_mut()); // no-op
        aisd_reassembly_result_free(core::ptr::null_mut()); // no-op
    }
}

/// The 19-byte big-endian fragment header fields, parsed out of a wire datagram a la
/// `FrameFragment::decode` (no core types needed — the C boundary returns raw bytes).
struct ParsedFragHeader {
    stream_seq: u32,
    frame_id: u32,
    frag_index: u16,
    frag_count: u16,
    flags: u8,
    payload: Vec<u8>,
}

/// Parses one wire datagram (header + payload) the boundary returned.
fn parse_fragment(datagram: &[u8]) -> ParsedFragHeader {
    assert!(datagram.len() >= 19, "datagram carries the 19-byte header");
    let u32_at = |o: usize| u32::from_be_bytes(datagram[o..o + 4].try_into().unwrap());
    let u16_at = |o: usize| u16::from_be_bytes(datagram[o..o + 2].try_into().unwrap());
    let payload_len = usize::from(u16_at(17));
    assert_eq!(
        datagram.len(),
        19 + payload_len,
        "payload_len matches the body"
    );
    ParsedFragHeader {
        stream_seq: u32_at(0),
        frame_id: u32_at(4),
        frag_index: u16_at(8),
        frag_count: u16_at(10),
        flags: datagram[12],
        payload: datagram[19..].to_vec(),
    }
}

/// A zeroed `AisdPacketizeOptions` — every flag off, tier 0, no override, no interleave.
const fn base_packetize_opts() -> AisdPacketizeOptions {
    AisdPacketizeOptions {
        keyframe: 0,
        crisp: 0,
        is_ltr: 0,
        acked_anchored: 0,
        fec_tier: 0,
        interleave: 0,
        host_send_ts_millis: 0,
        fec_group_size: 0,
    }
}

/// Packetizes one frame through the C ABI, returning the parsed fragment headers (and freeing the
/// owned array, idempotently).
unsafe fn packetize(
    p: *mut aislopdesk_ffi::video::AisdVideoPacketizer,
    frame: &[u8],
    opts: AisdPacketizeOptions,
) -> Vec<ParsedFragHeader> {
    let mut out = AisdBytesArray::EMPTY;
    let status = unsafe { aisd_packetize(p, frame.as_ptr(), frame.len(), opts, &mut out) };
    assert_eq!(status, AISD_OK);
    let frags: Vec<ParsedFragHeader> = (0..out.count)
        .map(|i| {
            let b = unsafe { *out.items.add(i) };
            let bytes = unsafe { core::slice::from_raw_parts(b.ptr, b.len) };
            parse_fragment(bytes)
        })
        .collect();
    unsafe {
        aisd_bytes_array_free(&mut out);
        aisd_bytes_array_free(&mut out); // idempotent
    }
    assert!(out.items.is_null() && out.count == 0);
    frags
}

/// Concatenates the data fragments' payloads (sorted by `frag_index`) back into the AVCC frame.
fn concat_data(frags: &[ParsedFragHeader]) -> Vec<u8> {
    let mut data: Vec<(u16, &[u8])> = frags
        .iter()
        .filter(|f| f.flags & 0x02 == 0) // not parity
        .map(|f| (f.frag_index, f.payload.as_slice()))
        .collect();
    data.sort_by_key(|(i, _)| *i);
    data.into_iter().flat_map(|(_, p)| p.to_vec()).collect()
}

#[test]
fn packetize_over_the_c_abi() {
    unsafe {
        // Invalid FEC config => null (no abort across the boundary); k == 0 => no-FEC handle.
        assert!(aisd_video_packetizer_new(200, 56).is_null());

        // --- a no-FEC keyframe MTU-splits, every fragment decodes with the right header, and the
        //     data fragments concatenate back to the exact AVCC frame ---
        let p = aisd_video_packetizer_new(0, 1);
        assert!(!p.is_null());
        assert_eq!(aisd_video_packetizer_peek_next_frame_id(p), 0);
        // MAX_PAYLOAD_SIZE = 1200 - 19 = 1181, so 1181*2 + 37 splits into [1181, 1181, 37].
        let frame: Vec<u8> = (0..(1181 * 2 + 37)).map(|i| (i * 7 + 1) as u8).collect();
        let opts = AisdPacketizeOptions {
            keyframe: 1,
            host_send_ts_millis: 4242,
            ..base_packetize_opts()
        };
        let frags = packetize(p, &frame, opts);
        assert_eq!(frags.len(), 3, "1181*2+37 splits into 3 MTU payloads");
        // monotonic stream_seq, shared frame_id 0, keyframe + tier-0 flags, ts stamped.
        assert_eq!(frags[0].stream_seq, 0);
        assert_eq!(frags[2].stream_seq, 2);
        assert!(frags.iter().all(|f| f.frame_id == 0));
        assert!(frags.iter().all(|f| f.frag_count == 3));
        assert!(
            frags.iter().all(|f| f.flags & 0x01 != 0),
            "keyframe bit set"
        );
        assert!(
            frags.iter().all(|f| f.flags & 0x02 == 0),
            "no parity (no-FEC)"
        );
        assert_eq!(
            concat_data(&frags),
            frame,
            "data concatenates back to the AVCC"
        );
        // counters advanced: one frame, three datagrams.
        assert_eq!(aisd_video_packetizer_peek_next_frame_id(p), 1);
        assert_eq!(aisd_video_packetizer_peek_next_stream_seq(p), 3);

        // --- the produced datagrams round-trip through the SYMMETRIC reassembler (send==recv SoT) ---
        let ra = aisd_reassembler_new(0, 1, 2);
        let mut completed: Option<Vec<u8>> = None;
        let frags2 = packetize(p, &frame, opts); // frame_id 1
        // re-emit the exact wire bytes the boundary produced and feed them to the reassembler.
        let mut out = AisdBytesArray::EMPTY;
        assert_eq!(
            aisd_packetize(p, frame.as_ptr(), frame.len(), opts, &mut out),
            AISD_OK
        ); // frame_id 2
        for i in 0..out.count {
            let b = *out.items.add(i);
            let bytes = core::slice::from_raw_parts(b.ptr, b.len);
            let mut rr = AisdReassemblyResult {
                kind: AISD_REASSEMBLY_STALE,
                keyframe: 0,
                crisp: 0,
                recovered_via_fec: 0,
                is_ltr: 0,
                acked_anchored: 0,
                frame_id: 0,
                avcc: AisdBytes::EMPTY,
            };
            assert_eq!(
                aisd_reassembler_ingest(ra, bytes.as_ptr(), bytes.len(), &mut rr),
                AISD_OK
            );
            if rr.kind == AISD_REASSEMBLY_COMPLETED {
                completed = Some(core::slice::from_raw_parts(rr.avcc.ptr, rr.avcc.len).to_vec());
                aisd_reassembly_result_free(&mut rr);
            }
        }
        aisd_bytes_array_free(&mut out);
        assert_eq!(
            completed.as_deref(),
            Some(frame.as_slice()),
            "reassembled == sent"
        );
        let _ = frags2; // (frags2 only proves the second packetize succeeded)
        aisd_reassembler_free(ra);
        aisd_video_packetizer_free(p);

        // --- m=2 produces 2 parity per group (multi-loss reachable) ---
        let pm = aisd_video_packetizer_new(2, 2);
        // 5 data fragments at group 2 => ceil(5/2)=3 groups * m=2 = 6 parity.
        let big: Vec<u8> = (0..(1181 * 5)).map(|i| (i % 251) as u8).collect();
        let opts2 = AisdPacketizeOptions {
            fec_group_size: 2,
            ..base_packetize_opts()
        };
        let pf = packetize(pm, &big, opts2);
        let data = pf.iter().filter(|f| f.flags & 0x02 == 0).count();
        let parity = pf.iter().filter(|f| f.flags & 0x02 != 0).count();
        assert_eq!(data, 5);
        assert_eq!(parity, 6, "3 groups * m=2");
        assert!(pf.iter().all(|f| f.frag_count == 11));
        assert_eq!(concat_data(&pf), big, "data still concatenates back");
        aisd_video_packetizer_free(pm);

        // --- null guards + empty-frame single fragment ---
        let pn = aisd_video_packetizer_new(0, 1);
        let mut og = AisdBytesArray::EMPTY;
        let f = [1u8, 2, 3];
        assert_eq!(
            aisd_packetize(
                core::ptr::null_mut(),
                f.as_ptr(),
                3,
                base_packetize_opts(),
                &mut og
            ),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_packetize(
                pn,
                f.as_ptr(),
                3,
                base_packetize_opts(),
                core::ptr::null_mut()
            ),
            AISD_ERR_NULL
        );
        assert_eq!(
            aisd_packetize(pn, core::ptr::null(), 3, base_packetize_opts(), &mut og),
            AISD_ERR_NULL,
            "null avcc with a nonzero len"
        );
        // empty frame (null avcc, len 0) is allowed and yields one fragment.
        assert_eq!(
            aisd_packetize(pn, core::ptr::null(), 0, base_packetize_opts(), &mut og),
            AISD_OK
        );
        assert_eq!(og.count, 1);
        aisd_bytes_array_free(&mut og);
        // null-handle getters return 0.
        assert_eq!(
            aisd_video_packetizer_peek_next_frame_id(core::ptr::null()),
            0
        );
        assert_eq!(
            aisd_video_packetizer_peek_next_stream_seq(core::ptr::null()),
            0
        );
        aisd_video_packetizer_free(pn);
        aisd_video_packetizer_free(core::ptr::null_mut()); // no-op
    }
}

/// `aisd_video_mux_header_encode` / `_decode`: the per-datagram channelID prefix over the C ABI —
/// the caller-out encode (no alloc) round-trips through the borrow+offset decode, the wire is
/// byte-identical to the core codec, and the null / truncated / undersized guards hold.
#[test]
fn video_mux_header_over_the_c_abi() {
    use aislopdesk_core::mux_header::video_mux_header;

    // Caller-out encode of `[u32 BE channelID]` into a sized buffer, then the caller copies its
    // payload — exactly the Swift framing shape. The full datagram is byte-identical to the core
    // codec's `encode` (the single source of truth the muxBare golden vector pins).
    let payload = [9u8, 8, 7, 6, 5];
    let mut datagram = vec![0u8; 4 + payload.len()];
    let mut written = 0usize;
    assert_eq!(
        unsafe {
            aisd_video_mux_header_encode(
                0x0102_0304,
                datagram.as_mut_ptr(),
                datagram.len(),
                &mut written,
            )
        },
        AISD_OK
    );
    assert_eq!(written, 4);
    datagram[4..].copy_from_slice(&payload);
    assert_eq!(datagram, video_mux_header::encode(0x0102_0304, &payload));

    // Borrow+offset decode recovers the channelID and the payload offset (always 4).
    let mut channel_id = 0u32;
    let mut offset = 0usize;
    assert_eq!(
        unsafe {
            aisd_video_mux_header_decode(
                datagram.as_ptr(),
                datagram.len(),
                &mut channel_id,
                &mut offset,
            )
        },
        AISD_OK
    );
    assert_eq!(channel_id, 0x0102_0304);
    assert_eq!(offset, 4);
    assert_eq!(&datagram[offset..], &payload);

    // A < 4-byte datagram is truncated (out-params untouched); empty (null, len 0) too.
    channel_id = 77;
    offset = 77;
    assert_eq!(
        unsafe {
            aisd_video_mux_header_decode([1u8, 2, 3].as_ptr(), 3, &mut channel_id, &mut offset)
        },
        AISD_ERR_TRUNCATED
    );
    assert_eq!((channel_id, offset), (77, 77));
    assert_eq!(
        unsafe { aisd_video_mux_header_decode(core::ptr::null(), 0, &mut channel_id, &mut offset) },
        AISD_ERR_TRUNCATED
    );

    // Undersized encode buffer is truncated, nothing written; null guards report NULL.
    let mut small = [0u8; 3];
    written = 9;
    assert_eq!(
        unsafe { aisd_video_mux_header_encode(1, small.as_mut_ptr(), small.len(), &mut written) },
        AISD_ERR_TRUNCATED
    );
    assert_eq!(written, 9);
    assert_eq!(
        unsafe { aisd_video_mux_header_encode(1, core::ptr::null_mut(), 4, &mut written) },
        AISD_ERR_NULL
    );
    assert_eq!(
        unsafe {
            aisd_video_mux_header_decode(datagram.as_ptr(), 4, core::ptr::null_mut(), &mut offset)
        },
        AISD_ERR_NULL
    );
    // null datagram with a nonzero len cannot be read => NULL.
    assert_eq!(
        unsafe { aisd_video_mux_header_decode(core::ptr::null(), 4, &mut channel_id, &mut offset) },
        AISD_ERR_NULL
    );
}

/// `aisd_frame_hash_nv12`: the NEON NV12 frame hash over BORROWED plane pointers — determinism,
/// stride/padding independence, one-byte sensitivity, and the null/degenerate sentinel guards,
/// driven exactly as a C caller (raw `*const u8`).
#[test]
fn frame_hash_over_the_c_abi() {
    let (w, h, stride) = (24usize, 16usize, 32usize); // 8 bytes row padding
    let mut y: Vec<u8> = (0..stride * h).map(|i| (i * 31 + 7) as u8).collect();
    let cbcr: Vec<u8> = (0..stride * (h / 2)).map(|i| (i * 17 + 3) as u8).collect();

    // SAFETY: the slices outlive each call and cover the implied plane sizes (stride*height etc.).
    let h1 = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
    let h2 = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
    assert_eq!(h1, h2, "deterministic for the same frame");
    assert_ne!(
        h1, AISD_FRAME_HASH_SENTINEL,
        "a valid frame is not the sentinel"
    );

    // Mutating only the row PADDING (cols [w, stride)) must not change the hash.
    for r in 0..h {
        for c in w..stride {
            y[r * stride + c] = (0xA0 + c) as u8;
        }
    }
    let padded = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
    assert_eq!(padded, h1, "row padding must not affect the hash");

    // A one-byte change in the VISIBLE region must change the hash.
    y[5 * stride + 3] ^= 0x01;
    let edited = unsafe { aisd_frame_hash_nv12(y.as_ptr(), stride, w, h, cbcr.as_ptr(), stride) };
    assert_ne!(edited, h1, "a one-byte visible change differs");

    // Null / degenerate ⇒ sentinel, never a panic.
    let null_y =
        unsafe { aisd_frame_hash_nv12(core::ptr::null(), stride, w, h, core::ptr::null(), 0) };
    assert_eq!(null_y, AISD_FRAME_HASH_SENTINEL, "null y ⇒ sentinel");
    let zero = unsafe { aisd_frame_hash_nv12(y.as_ptr(), 0, 0, 0, core::ptr::null(), 0) };
    assert_eq!(zero, AISD_FRAME_HASH_SENTINEL, "zero dims ⇒ sentinel");
    let narrow = unsafe { aisd_frame_hash_nv12(y.as_ptr(), 4, 8, 2, core::ptr::null(), 0) };
    assert_eq!(
        narrow, AISD_FRAME_HASH_SENTINEL,
        "stride < width ⇒ sentinel"
    );
}
