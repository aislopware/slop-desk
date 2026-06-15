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
    aisd_video_control_decode, aisd_video_control_encode, aisd_video_control_free,
    AisdVideoControl, AisdVideoSummary, AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST,
    AISD_VIDEO_CONTROL_WINDOW_LIST,
};
use aislopdesk_ffi::{
    aisd_bytes_free, aisd_frame_decoder_append, aisd_frame_decoder_free, aisd_frame_decoder_new,
    aisd_frame_decoder_next, aisd_seq_distance, aisd_wire_data_frame_encode_into,
    aisd_wire_data_frame_view, aisd_wire_message_decode, aisd_wire_message_encode,
    aisd_wire_message_free, AisdBytes, AisdDataFrameView, AisdWireMessage, AISD_EMPTY,
    AISD_ERR_FRAME_TOO_LARGE, AISD_ERR_INVALID_ARGUMENT, AISD_ERR_MALFORMED, AISD_ERR_NULL,
    AISD_ERR_TRUNCATED, AISD_ERR_UNKNOWN_TYPE, AISD_OK, AISD_WIRE_ACK, AISD_WIRE_BELL,
    AISD_WIRE_BYE, AISD_WIRE_COMMAND_STATUS, AISD_WIRE_EXIT, AISD_WIRE_HELLO, AISD_WIRE_HELLO_ACK,
    AISD_WIRE_INPUT, AISD_WIRE_NOTIFICATION, AISD_WIRE_OUTPUT, AISD_WIRE_PING, AISD_WIRE_PONG,
    AISD_WIRE_RESIZE, AISD_WIRE_TITLE,
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
    if b.ptr.is_null() || b.len == 0 {
        Vec::new()
    } else {
        core::slice::from_raw_parts(b.ptr, b.len).to_vec()
    }
}

/// Encodes `msg`, feeds the frame through a fresh decoder, and returns the decoded flat
/// struct (status must be `AISD_OK`). The caller frees the returned message's buffers.
unsafe fn round_trip(msg: &AisdWireMessage) -> AisdWireMessage {
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
        records: core::ptr::null_mut(),
        records_len: 0,
    }
}

/// One borrowed summary record (the strings are copied by `encode`, never freed by Rust). The two
/// dialog flags default off (a `WindowList` record never uses them).
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
        keystrokes_blocked: 0,
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

#[test]
fn video_control_system_dialog_list_carries_both_flags_independently() {
    unsafe {
        // A blocked login prompt and a secure-CLASS admin-auth prompt that is still typable — the
        // two flags must survive the boundary INDEPENDENTLY (the badge-accuracy fix).
        let blocked = AisdVideoSummary {
            window_id: 9,
            width: 400,
            height: 200,
            is_secure: 1,
            keystrokes_blocked: 1,
            name: borrow(b"SecurityAgent"),
            title: borrow(b""),
        };
        let typable = AisdVideoSummary {
            window_id: 10,
            width: 420,
            height: 220,
            is_secure: 1,
            keystrokes_blocked: 0,
            name: borrow(b"SecurityAgent"),
            title: borrow(b"Authorize"),
        };
        let recs = [blocked, typable];
        let mut msg = control_base();
        msg.kind = AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST;
        msg.records = recs.as_ptr().cast_mut();
        msg.records_len = recs.len();

        let mut frame = AisdBytes::EMPTY;
        assert_eq!(aisd_video_control_encode(&msg, &mut frame), AISD_OK);

        let mut out = control_base();
        assert_eq!(
            aisd_video_control_decode(frame.ptr, frame.len, &mut out),
            AISD_OK
        );
        assert_eq!(out.records_len, 2);
        let decoded = core::slice::from_raw_parts(out.records, out.records_len);
        assert_eq!(
            (decoded[0].is_secure, decoded[0].keystrokes_blocked),
            (1, 1),
            "blocked login prompt"
        );
        assert_eq!(
            (decoded[1].is_secure, decoded[1].keystrokes_blocked),
            (1, 0),
            "secure-class but typable"
        );
        assert_eq!(view(decoded[1].title), b"Authorize");

        aisd_video_control_free(&mut out);
        aisd_bytes_free(frame);
    }
}
