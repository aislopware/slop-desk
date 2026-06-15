/*
 * smoke.c — a minimal C consumer of libaislopdesk_ffi, proving real cross-language
 * linkage and ABI agreement (struct layout, ownership, status codes) from actual C — not
 * just from Rust calling its own `extern "C"` functions.
 *
 * Build + run via `tests/run_c_smoke.sh` (which resolves the right link flags). Exit code
 * 0 = all checks passed; any failure prints a message and returns non-zero.
 */
#include "aislopdesk_ffi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                                  \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            fprintf(stderr, "FAIL: %s\n", (msg));                                         \
            failures++;                                                                   \
        }                                                                                 \
    } while (0)

/* Packs one video fragment datagram (the fixed 19-byte big-endian header + payload) into `out`,
 * matching the Rust `FrameFragment::encode` wire so aisd_reassembler_ingest can parse it. Returns
 * the total datagram length (19 + payload_len). `flags`: bit0 keyframe, bit1 parity. */
static size_t pack_fragment(uint8_t *out, uint32_t stream_seq, uint32_t frame_id, uint16_t frag_index,
                            uint16_t frag_count, uint8_t flags, const uint8_t *payload,
                            uint16_t payload_len) {
    size_t o = 0;
    out[o++] = (uint8_t)(stream_seq >> 24); out[o++] = (uint8_t)(stream_seq >> 16);
    out[o++] = (uint8_t)(stream_seq >> 8);  out[o++] = (uint8_t)(stream_seq);
    out[o++] = (uint8_t)(frame_id >> 24);   out[o++] = (uint8_t)(frame_id >> 16);
    out[o++] = (uint8_t)(frame_id >> 8);    out[o++] = (uint8_t)(frame_id);
    out[o++] = (uint8_t)(frag_index >> 8);  out[o++] = (uint8_t)(frag_index);
    out[o++] = (uint8_t)(frag_count >> 8);  out[o++] = (uint8_t)(frag_count);
    out[o++] = flags;
    out[o++] = 0; out[o++] = 0; out[o++] = 0; out[o++] = 0; /* host_send_ts_millis = 0 */
    out[o++] = (uint8_t)(payload_len >> 8);  out[o++] = (uint8_t)(payload_len);
    if (payload_len > 0) { memcpy(out + o, payload, payload_len); }
    return o + payload_len;
}

int main(void) {
    /* 1. A trivial stateless call: wrap-aware sequence distance. */
    CHECK(aisd_seq_distance(10, 4) == 6, "seq_distance ahead");
    CHECK(aisd_seq_distance(2, 0xFFFFFFFFu) == 3, "seq_distance across wrap");

    /* 2. Encode an Output(seq=7, "hi\xff") in C, decode it back, compare every field. */
    uint8_t payload[3] = {'h', 'i', 0xFF};
    AisdWireMessage out_msg;
    memset(&out_msg, 0, sizeof(out_msg));
    out_msg.tag = AISD_WIRE_OUTPUT;
    out_msg.seq = 7;
    out_msg.data.ptr = payload;
    out_msg.data.len = sizeof(payload);
    out_msg.data.cap = 0; /* borrowed; encode never frees it */

    AisdBytes frame = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&out_msg, &frame) == AISD_OK, "encode output ok");
    CHECK(frame.ptr != NULL && frame.len > 0, "encode produced a frame");

    AisdFrameDecoder *dec = aisd_frame_decoder_new();
    CHECK(dec != NULL, "decoder allocated");
    CHECK(aisd_frame_decoder_append(dec, frame.ptr, frame.len) == AISD_OK, "append frame");

    AisdWireMessage decoded;
    memset(&decoded, 0, sizeof(decoded));
    CHECK(aisd_frame_decoder_next(dec, &decoded) == AISD_OK, "decode output ok");
    CHECK(decoded.tag == AISD_WIRE_OUTPUT, "decoded tag is output");
    CHECK(decoded.seq == 7, "decoded seq");
    CHECK(decoded.data.len == sizeof(payload), "decoded payload length");
    CHECK(decoded.data.ptr != NULL &&
              memcmp(decoded.data.ptr, payload, sizeof(payload)) == 0,
          "decoded payload bytes");

    AisdWireMessage spare;
    memset(&spare, 0, sizeof(spare));
    CHECK(aisd_frame_decoder_next(dec, &spare) == AISD_EMPTY, "stream drained");

    aisd_wire_message_free(&decoded);
    aisd_bytes_free(frame);

    /* 3. A control message with no payload round-trips too. */
    AisdWireMessage bell;
    memset(&bell, 0, sizeof(bell));
    bell.tag = AISD_WIRE_BELL;
    AisdBytes bell_frame = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&bell, &bell_frame) == AISD_OK, "encode bell");
    CHECK(aisd_frame_decoder_append(dec, bell_frame.ptr, bell_frame.len) == AISD_OK,
          "append bell");
    AisdWireMessage bell_out;
    memset(&bell_out, 0, sizeof(bell_out));
    CHECK(aisd_frame_decoder_next(dec, &bell_out) == AISD_OK, "decode bell");
    CHECK(bell_out.tag == AISD_WIRE_BELL, "decoded tag is bell");
    aisd_wire_message_free(&bell_out);
    aisd_bytes_free(bell_frame);

    /* 4. Error + null guards behave. */
    AisdWireMessage bad;
    memset(&bad, 0, sizeof(bad));
    bad.tag = 99; /* not a real message type */
    AisdBytes junk = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&bad, &junk) == AISD_ERR_INVALID_ARGUMENT,
          "encode rejects unknown tag");
    CHECK(aisd_frame_decoder_next(NULL, &decoded) == AISD_ERR_NULL, "null decoder rejected");

    aisd_frame_decoder_free(dec);
    aisd_frame_decoder_free(NULL); /* no-op */

    /* 5. Pure flat-struct geometry policies (FFI wiring round). Exercises AisdRect, AisdPoint,
     * AisdPlacement, AisdVDGeometry, AisdVDMillimeters, AisdCaptureWindowSnapshot layouts from C. */
    AisdRect display = {0.0, 0.0, 1920.0, 1080.0};

    AisdPlacement plc = aisd_window_placement(2400.0, 800.0, display);
    CHECK(plc.x == 0.0 && plc.width == 1920.0 && plc.height == 800.0 && plc.needs_resize == 1,
          "window_placement clamps oversized width and flags resize");
    CHECK(aisd_window_fits(1920.0, 1080.0, display) == 1, "window_fits exact");
    CHECK(aisd_window_fits(1921.0, 1080.0, display) == 0, "window_fits width over");

    AisdVDGeometry g = aisd_vd_geometry(1920, 1080, 2, 7680);
    CHECK(g.pixel_width == 3840 && g.pixel_height == 2160 && g.exceeds_pixel_limit == 0,
          "vd_geometry 2x pixel dims under limit");
    CHECK(aisd_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit == 1,
          "vd_geometry over base-M chip limit");

    AisdVDMillimeters mm = aisd_vd_size_in_millimeters(3840, 2160, 163.0);
    CHECK(mm.width > 598.0 && mm.width < 599.0, "vd_size_in_millimeters width ~598.5mm");

    AisdRect displays[2] = {{0.0, 0.0, 1920.0, 1080.0}, {1920.0, 0.0, 2560.0, 1440.0}};
    AisdPoint origin = aisd_vd_origin_to_right(displays, 2);
    CHECK(origin.x == 4480.0 && origin.y == 0.0, "vd_origin_to_right rightmost edge");
    AisdPoint origin0 = aisd_vd_origin_to_right(NULL, 0);
    CHECK(origin0.x == 0.0 && origin0.y == 0.0, "vd_origin_to_right empty -> (0,0)");

    CHECK(aisd_vd_chip_pixel_limit("Apple M3 Pro") == 7680, "chip limit pro/max/ultra");
    CHECK(aisd_vd_chip_pixel_limit("Apple M2") == 6144, "chip limit base M");
    CHECK(aisd_vd_chip_pixel_limit(NULL) == 7680, "chip limit NULL -> default");

    double rates[3] = {0.0, 0.0, 0.0};
    size_t nrates = aisd_vd_refresh_rates(120, rates, 3);
    CHECK(nrates == 3 && rates[0] == 120.0 && rates[1] == 60.0 && rates[2] == 30.0,
          "vd_refresh_rates 120 -> [120,60,30]");
    CHECK(aisd_vd_refresh_rates(60, rates, 3) == 2, "vd_refresh_rates 60 -> 2 modes");

    AisdRect target = {100.0, 100.0, 800.0, 600.0};
    AisdCaptureWindowSnapshot front[1] = {{2, 42, 0, {700.0, 100.0, 400.0, 300.0}}};
    AisdRect uni = aisd_capture_union_region(target, 1, 42, front, 1, display, 0.30);
    CHECK(uni.width == 1000.0 && uni.height == 600.0,
          "capture_union_region extends to cover the same-pid panel");
    AisdRect noneuni = aisd_capture_union_region(target, 1, 42, NULL, 0, display, 0.30);
    CHECK(noneuni.width == 800.0, "capture_union_region with no panels = target");

    AisdRect ca = {0.0, 0.0, 100.0, 100.0};
    AisdRect cb = {0.0, 0.0, 120.0, 100.0};
    CHECK(aisd_capture_should_retarget(ca, cb, 8.0) == 1, "capture_should_retarget over delta");
    CHECK(aisd_capture_should_retarget(ca, ca, 8.0) == 0, "capture_should_retarget identical");
    CHECK(aisd_capture_reorigin_on_geometry(1) == 1, "capture_reorigin no active region");
    CHECK(aisd_capture_reorigin_on_geometry(0) == 0, "capture_reorigin active union holds");

    /* 6. Adaptive playout step (pure scalar, ms domain): 12ms jitter from the floor grows to 13.6ms;
     * a clean link shrinks by at most the step; a huge jitter clamps at the ceiling. */
    double pl_grow = aisd_adaptive_playout_step_ms(0.012, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
    CHECK(pl_grow > 13.59 && pl_grow < 13.61, "adaptive_playout grows to k*jitter+base");
    double pl_shrink = aisd_adaptive_playout_step_ms(0.002, 28.0, 2.0, 0.8, 4.0, 4.0, 35.0);
    CHECK(pl_shrink > 25.99 && pl_shrink < 26.01, "adaptive_playout shrinks slow by <= step");
    double pl_ceil = aisd_adaptive_playout_step_ms(0.040, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
    CHECK(pl_ceil > 34.99 && pl_ceil < 35.01, "adaptive_playout clamps at ceil");

    /* 7. Window-geometry + input-event wire codecs (owned-buffer marshaling from C). */
    AisdWindowGeometry geo_in;
    memset(&geo_in, 0, sizeof(geo_in));
    geo_in.kind = AISD_WINDOW_GEOMETRY_BOUNDS;
    geo_in.x = 12.0;
    geo_in.y = 34.0;
    geo_in.width = 800.0;
    geo_in.height = 600.0;
    AisdBytes geo_frame = {NULL, 0, 0};
    CHECK(aisd_window_geometry_encode(&geo_in, &geo_frame) == AISD_OK, "geometry encode ok");
    AisdWindowGeometry geo_out;
    memset(&geo_out, 0, sizeof(geo_out));
    CHECK(aisd_window_geometry_decode(geo_frame.ptr, geo_frame.len, &geo_out) == AISD_OK,
          "geometry decode ok");
    CHECK(geo_out.kind == AISD_WINDOW_GEOMETRY_BOUNDS && geo_out.x == 12.0 && geo_out.y == 34.0 &&
              geo_out.width == 800.0 && geo_out.height == 600.0,
          "geometry bounds round-trips");
    aisd_window_geometry_free(&geo_out);
    aisd_bytes_free(geo_frame);

    /* A title carries an owned UTF-8 buffer back; a non-UTF-8 title is rejected on encode. */
    const char *title = "héllo 窗口";
    AisdWindowGeometry title_in;
    memset(&title_in, 0, sizeof(title_in));
    title_in.kind = AISD_WINDOW_GEOMETRY_TITLE;
    title_in.title.ptr = (uint8_t *)title;
    title_in.title.len = strlen(title);
    title_in.title.cap = 0; /* borrowed */
    AisdBytes title_frame = {NULL, 0, 0};
    CHECK(aisd_window_geometry_encode(&title_in, &title_frame) == AISD_OK, "title encode ok");
    AisdWindowGeometry title_out;
    memset(&title_out, 0, sizeof(title_out));
    CHECK(aisd_window_geometry_decode(title_frame.ptr, title_frame.len, &title_out) == AISD_OK,
          "title decode ok");
    CHECK(title_out.kind == AISD_WINDOW_GEOMETRY_TITLE &&
              title_out.title.len == strlen(title) &&
              memcmp(title_out.title.ptr, title, strlen(title)) == 0,
          "title bytes round-trip");
    aisd_window_geometry_free(&title_out);
    aisd_bytes_free(title_frame);

    uint8_t bad_title_bytes[2] = {0xFF, 0xFE};
    AisdWindowGeometry bad_title;
    memset(&bad_title, 0, sizeof(bad_title));
    bad_title.kind = AISD_WINDOW_GEOMETRY_TITLE;
    bad_title.title.ptr = bad_title_bytes;
    bad_title.title.len = sizeof(bad_title_bytes);
    AisdBytes junk2 = {NULL, 0, 0};
    CHECK(aisd_window_geometry_encode(&bad_title, &junk2) == AISD_ERR_INVALID_ARGUMENT,
          "geometry rejects non-UTF-8 title");

    /* A scroll input event (all-scalar) and a text event (owned buffer). */
    AisdInputEvent scroll_in;
    memset(&scroll_in, 0, sizeof(scroll_in));
    scroll_in.kind = AISD_INPUT_SCROLL;
    scroll_in.tag = 4242;
    scroll_in.dx = -3.5;
    scroll_in.dy = 12.0;
    scroll_in.x = 0.25;
    scroll_in.y = 0.75;
    scroll_in.scroll_phase = 2;
    scroll_in.continuous = 1;
    AisdBytes scroll_frame = {NULL, 0, 0};
    CHECK(aisd_input_event_encode(&scroll_in, &scroll_frame) == AISD_OK, "scroll encode ok");
    AisdInputEvent scroll_out;
    memset(&scroll_out, 0, sizeof(scroll_out));
    CHECK(aisd_input_event_decode(scroll_frame.ptr, scroll_frame.len, &scroll_out) == AISD_OK,
          "scroll decode ok");
    CHECK(scroll_out.kind == AISD_INPUT_SCROLL && scroll_out.tag == 4242 &&
              scroll_out.dx == -3.5 && scroll_out.dy == 12.0 && scroll_out.scroll_phase == 2 &&
              scroll_out.continuous == 1,
          "scroll round-trips fields");
    aisd_input_event_free(&scroll_out);
    aisd_bytes_free(scroll_frame);

    const char *typed = "gõ được";
    AisdInputEvent text_in;
    memset(&text_in, 0, sizeof(text_in));
    text_in.kind = AISD_INPUT_TEXT;
    text_in.tag = 9;
    text_in.text.ptr = (uint8_t *)typed;
    text_in.text.len = strlen(typed);
    AisdBytes text_frame = {NULL, 0, 0};
    CHECK(aisd_input_event_encode(&text_in, &text_frame) == AISD_OK, "text encode ok");
    AisdInputEvent text_out;
    memset(&text_out, 0, sizeof(text_out));
    CHECK(aisd_input_event_decode(text_frame.ptr, text_frame.len, &text_out) == AISD_OK,
          "text decode ok");
    CHECK(text_out.kind == AISD_INPUT_TEXT && text_out.tag == 9 &&
              text_out.text.len == strlen(typed) &&
              memcmp(text_out.text.ptr, typed, strlen(typed)) == 0,
          "text bytes round-trip");
    aisd_input_event_free(&text_out);
    aisd_bytes_free(text_frame);

    /* An out-of-range mouse button is rejected on encode. */
    AisdInputEvent bad_button;
    memset(&bad_button, 0, sizeof(bad_button));
    bad_button.kind = AISD_INPUT_MOUSE_DOWN;
    bad_button.button = 9;
    AisdBytes junk3 = {NULL, 0, 0};
    CHECK(aisd_input_event_encode(&bad_button, &junk3) == AISD_ERR_INVALID_ARGUMENT,
          "input rejects out-of-range button");

    /* 8. Zero-copy DATA-frame path: frame an output in C, confirm it matches the owned encode,
     * then read the bulk bytes back through the borrowed view (no copy). */
    uint8_t pay[5] = {'v', 't', 0x1b, '[', 'J'};
    int64_t out_seq = 7;
    AisdWireMessage om;
    memset(&om, 0, sizeof(om));
    om.tag = AISD_WIRE_OUTPUT;
    om.seq = out_seq;
    om.data.ptr = pay;
    om.data.len = sizeof(pay);
    AisdBytes want = {NULL, 0, 0};
    CHECK(aisd_wire_message_encode(&om, &want) == AISD_OK, "owned output encode");

    uint8_t frame_buf[64];
    size_t written = 0;
    CHECK(aisd_wire_data_frame_encode_into(AISD_WIRE_OUTPUT, out_seq, pay, sizeof(pay), frame_buf,
                                           sizeof(frame_buf), &written) == AISD_OK,
          "data_frame encode_into ok");
    CHECK(written == want.len && memcmp(frame_buf, want.ptr, want.len) == 0,
          "zero-copy frame == owned encode");
    aisd_bytes_free(want);

    AisdDataFrameView dv;
    memset(&dv, 0, sizeof(dv));
    CHECK(aisd_wire_data_frame_view(frame_buf + 4, written - 4, &dv) == AISD_OK, "data_frame_view ok");
    CHECK(dv.tag == AISD_WIRE_OUTPUT && dv.seq == out_seq && dv.bytes_len == sizeof(pay) &&
              memcmp(dv.bytes, pay, sizeof(pay)) == 0,
          "borrowed view exposes seq + bulk bytes");

    uint8_t bye_payload = AISD_WIRE_BYE;
    AisdDataFrameView cv;
    memset(&cv, 0, sizeof(cv));
    CHECK(aisd_wire_data_frame_view(&bye_payload, 1, &cv) == AISD_OK && cv.tag == 0,
          "control payload reported as tag 0");

    /* 9. video_control: a scalar (resizeAck) and the nested-array windowList — encode a
     * borrowed record array, decode back into an owned one, then free it. */
    AisdVideoControl rack;
    memset(&rack, 0, sizeof(rack));
    rack.kind = AISD_VIDEO_CONTROL_RESIZE_ACK;
    rack.capture_width = 640;
    rack.capture_height = 480;
    rack.epoch = 9;
    AisdBytes rack_frame = {NULL, 0, 0};
    CHECK(aisd_video_control_encode(&rack, &rack_frame) == AISD_OK, "resizeAck encode ok");
    AisdVideoControl rack_out;
    memset(&rack_out, 0, sizeof(rack_out));
    CHECK(aisd_video_control_decode(rack_frame.ptr, rack_frame.len, &rack_out) == AISD_OK,
          "resizeAck decode ok");
    CHECK(rack_out.kind == AISD_VIDEO_CONTROL_RESIZE_ACK && rack_out.capture_width == 640 &&
              rack_out.capture_height == 480 && rack_out.epoch == 9 && rack_out.records == NULL,
          "resizeAck round-trips, no records");
    aisd_video_control_free(&rack_out);
    aisd_bytes_free(rack_frame);

    const char *app = "Google Chrome";
    const char *win_title = "Tab";
    AisdVideoSummary rec;
    memset(&rec, 0, sizeof(rec));
    rec.window_id = 604;
    rec.width = 1800;
    rec.height = 943;
    rec.name.ptr = (uint8_t *)app;
    rec.name.len = strlen(app);
    rec.title.ptr = (uint8_t *)win_title;
    rec.title.len = strlen(win_title);
    AisdVideoControl wl;
    memset(&wl, 0, sizeof(wl));
    wl.kind = AISD_VIDEO_CONTROL_WINDOW_LIST;
    wl.records = &rec;
    wl.records_len = 1;
    AisdBytes wl_frame = {NULL, 0, 0};
    CHECK(aisd_video_control_encode(&wl, &wl_frame) == AISD_OK, "windowList encode ok");
    AisdVideoControl wl_out;
    memset(&wl_out, 0, sizeof(wl_out));
    CHECK(aisd_video_control_decode(wl_frame.ptr, wl_frame.len, &wl_out) == AISD_OK,
          "windowList decode ok");
    CHECK(wl_out.kind == AISD_VIDEO_CONTROL_WINDOW_LIST && wl_out.records_len == 1 &&
              wl_out.records != NULL && wl_out.records[0].window_id == 604 &&
              wl_out.records[0].width == 1800 &&
              wl_out.records[0].name.len == strlen(app) &&
              memcmp(wl_out.records[0].name.ptr, app, strlen(app)) == 0 &&
              wl_out.records[0].title.len == strlen(win_title),
          "windowList record fields + strings round-trip");
    aisd_video_control_free(&wl_out);
    aisd_video_control_free(&wl_out); /* idempotent */
    CHECK(wl_out.records == NULL && wl_out.records_len == 0, "free nulls the record array");
    aisd_bytes_free(wl_frame);

    /* 10. system_dialog_detector: classify a SecurityAgent prompt (secure, owned owner buffer),
     * and confirm a normal app window classifies AISD_EMPTY. */
    CHECK(aisd_system_dialog_min_size() == 60, "system_dialog min_size is 60");

    const char *sa_owner = "SecurityAgent";
    const char *sa_bundle = "com.apple.SecurityAgent";
    const char *sa_title = "Authenticate";
    AisdRect sa_frame = {830.0, 201.0, 260.0, 312.0};
    AisdSystemDialog dlg;
    memset(&dlg, 0, sizeof(dlg));
    CHECK(aisd_system_dialog_classify(1966, (const uint8_t *)sa_owner, strlen(sa_owner),
                                      (const uint8_t *)sa_bundle, strlen(sa_bundle), 1,
                                      (const uint8_t *)sa_title, strlen(sa_title), sa_frame,
                                      aisd_system_dialog_min_size(), &dlg) == AISD_OK,
          "SecurityAgent classifies as a dialog");
    CHECK(dlg.window_id == 1966 && dlg.width == 260 && dlg.height == 312 && dlg.is_secure == 1 &&
              dlg.owner.len == strlen(sa_owner) &&
              memcmp(dlg.owner.ptr, sa_owner, strlen(sa_owner)) == 0 &&
              dlg.title.len == strlen(sa_title),
          "dialog fields + owned owner/title round-trip");
    aisd_system_dialog_free(&dlg);
    aisd_system_dialog_free(&dlg); /* idempotent */
    CHECK(dlg.owner.ptr == NULL && dlg.title.ptr == NULL, "free nulls the owner/title buffers");

    const char *chrome_owner = "Google Chrome";
    const char *chrome_bundle = "com.google.Chrome";
    AisdRect chrome_frame = {0.0, 0.0, 700.0, 500.0};
    AisdSystemDialog not_dlg;
    memset(&not_dlg, 0, sizeof(not_dlg));
    CHECK(aisd_system_dialog_classify(1, (const uint8_t *)chrome_owner, strlen(chrome_owner),
                                      (const uint8_t *)chrome_bundle, strlen(chrome_bundle), 1,
                                      NULL, 0, chrome_frame, 60, &not_dlg) == AISD_EMPTY,
          "a normal app window is not a system dialog");
    CHECK(aisd_system_dialog_classify(1, (const uint8_t *)sa_owner, strlen(sa_owner), NULL, 0, 1,
                                      NULL, 0, sa_frame, 60, NULL) == AISD_ERR_NULL,
          "null out rejected");

    /* 11. recovery_request_deduper opaque handle: a redundant burst dedups to one; a distinct
     * datagram is admitted; the window expires; a NULL handle fails open. */
    AisdRecoveryDeduper *ded = aisd_recovery_deduper_new(0.025, 16);
    CHECK(ded != NULL, "recovery deduper allocated");
    uint8_t rwire[5] = {3, 0, 0, 0, 50};
    CHECK(aisd_recovery_deduper_admit(ded, rwire, sizeof(rwire), 100.000) == 1, "first sighting admitted");
    CHECK(aisd_recovery_deduper_admit(ded, rwire, sizeof(rwire), 100.005) == 0, "duplicate dropped");
    uint8_t rwire2[2] = {4, 1};
    CHECK(aisd_recovery_deduper_admit(ded, rwire2, sizeof(rwire2), 100.006) == 1, "distinct admitted");
    CHECK(aisd_recovery_deduper_admit(ded, rwire, sizeof(rwire), 100.030) == 1, "window expiry re-admits");
    aisd_recovery_deduper_free(ded);
    aisd_recovery_deduper_free(NULL); /* no-op */
    CHECK(aisd_recovery_deduper_admit(NULL, rwire, sizeof(rwire), 0.0) == 1, "null handle fails open");

    /* 12. ycbcr coefficients: video vs full differ only in luma; matrix/chroma shared. */
    AisdYCbCrCoefficients vid = aisd_ycbcr_coefficients(0);
    AisdYCbCrCoefficients full = aisd_ycbcr_coefficients(1);
    CHECK(vid.luma_scale > 1.16f && vid.luma_scale < 1.17f && vid.luma_bias > 0.0f,
          "video range expands luma");
    CHECK(full.luma_scale == 1.0f && full.luma_bias == 0.0f, "full range is identity luma");
    CHECK(vid.chroma_bias == full.chroma_bias && vid.cr_to_r == full.cr_to_r &&
              vid.cb_to_g == full.cb_to_g && vid.cr_to_g == full.cr_to_g && vid.cb_to_b == full.cb_to_b,
          "chroma + matrix coefficients are range-independent");

    /* 13. recovery codec: a RequestLtrRefresh + a NetworkStats report round-trip; trailing bytes
     * and an unknown kind are rejected. */
    AisdRecoveryMessage rmsg;
    memset(&rmsg, 0, sizeof(rmsg));
    rmsg.kind = AISD_RECOVERY_REQUEST_LTR_REFRESH;
    rmsg.from_frame_id = 50;
    rmsg.to_frame_id = 52;
    rmsg.last_decoded_frame_id = 49;
    AisdBytes rframe = {0};
    CHECK(aisd_recovery_message_encode(&rmsg, &rframe) == AISD_OK, "recovery encode ok");
    AisdRecoveryMessage rout;
    memset(&rout, 0, sizeof(rout));
    CHECK(aisd_recovery_message_decode(rframe.ptr, rframe.len, &rout) == AISD_OK, "recovery decode ok");
    CHECK(rout.kind == AISD_RECOVERY_REQUEST_LTR_REFRESH && rout.from_frame_id == 50 &&
              rout.to_frame_id == 52 && rout.last_decoded_frame_id == 49,
          "RequestLtrRefresh fields round-trip");

    /* trailing byte => malformed (byte-keyed dedup contract); copy into a stack buffer + pad. */
    uint8_t rc_padded[32];
    CHECK(rframe.len + 1 <= sizeof(rc_padded), "recovery wire fits the pad buffer");
    memcpy(rc_padded, rframe.ptr, rframe.len);
    rc_padded[rframe.len] = 0;
    CHECK(aisd_recovery_message_decode(rc_padded, rframe.len + 1, &rout) == AISD_ERR_MALFORMED,
          "trailing bytes rejected");
    aisd_bytes_free(rframe);

    AisdRecoveryMessage stats;
    memset(&stats, 0, sizeof(stats));
    stats.kind = AISD_RECOVERY_NETWORK_STATS;
    stats.stats.frames_received = 600;
    stats.stats.owd_trend_milli = (uint32_t)(-987);
    stats.stats.pacer_depth = 2;
    AisdBytes sframe = {0};
    CHECK(aisd_recovery_message_encode(&stats, &sframe) == AISD_OK, "netstats encode ok");
    AisdRecoveryMessage sout;
    memset(&sout, 0, sizeof(sout));
    CHECK(aisd_recovery_message_decode(sframe.ptr, sframe.len, &sout) == AISD_OK, "netstats decode ok");
    CHECK(sout.stats.frames_received == 600 && sout.stats.owd_trend_milli == (uint32_t)(-987) &&
              sout.stats.pacer_depth == 2,
          "NetworkStats fields round-trip");
    aisd_bytes_free(sframe);

    AisdRecoveryMessage rc_bad;
    memset(&rc_bad, 0, sizeof(rc_bad));
    rc_bad.kind = 99;
    AisdBytes rc_bframe = {0};
    CHECK(aisd_recovery_message_encode(&rc_bad, &rc_bframe) == AISD_ERR_INVALID_ARGUMENT,
          "unknown recovery kind rejected");

    /* 14. static_idr_decider opaque handle: cadence + quiet window + null guards. */
    AisdStaticIdrDecider *sid = aisd_static_idr_decider_new(1.0, 0.0, 0);
    CHECK(sid != NULL, "static-IDR decider allocated");
    CHECK(aisd_static_idr_decider_heartbeat(sid) == 1.0 &&
              aisd_static_idr_decider_quiet_window(sid) == 1.0,
          "default quiet window == heartbeat");
    CHECK(aisd_static_idr_decider_should_reencode(sid, 0.5, 0, 1) == 1, "armed + quiet => fire");
    CHECK(aisd_static_idr_decider_should_reencode(sid, 50.0, 1, 0) == 0, "no buffer => never fire");
    aisd_static_idr_decider_on_complete_frame(sid, 10.0);
    CHECK(aisd_static_idr_decider_last_complete_encode(sid) == 10.0, "real frame anchors");
    CHECK(aisd_static_idr_decider_should_reencode(sid, 10.5, 0, 1) == 0, "quiet window suppresses");
    CHECK(aisd_static_idr_decider_should_reencode(sid, 11.0, 0, 1) == 1, "heartbeat elapsed => fire");
    aisd_static_idr_decider_free(sid);
    aisd_static_idr_decider_free(NULL); /* no-op */
    CHECK(aisd_static_idr_decider_should_reencode(NULL, 0.0, 1, 1) == 0, "null handle never fires");

    /* 15. decode_gate opaque handle: mode transitions + Option<u32> out-param + null guards. */
    AisdDecodeGate *dg = aisd_decode_gate_new();
    CHECK(dg != NULL, "decode gate new");
    CHECK(aisd_decode_gate_mode(dg) == AISD_DECODE_GATE_MODE_OPEN, "fresh gate is open");
    CHECK(aisd_decode_gate_verdict(dg, 10, 0, 0) == AISD_DECODE_GATE_VERDICT_SUBMIT,
          "open submits");
    uint32_t dg_lost = 7777;
    CHECK(aisd_decode_gate_min_lost_frame_id(dg, &dg_lost) == 0 && dg_lost == 7777,
          "no loss => out untouched");
    aisd_decode_gate_note_loss(dg, 100);
    aisd_decode_gate_note_loss(dg, 110);
    CHECK(aisd_decode_gate_mode(dg) == AISD_DECODE_GATE_MODE_BROKEN_CHAIN, "loss => broken chain");
    CHECK(aisd_decode_gate_min_lost_frame_id(dg, &dg_lost) == 1 && dg_lost == 100, "min lost = 100");
    CHECK(aisd_decode_gate_max_lost_frame_id(dg, &dg_lost) == 1 && dg_lost == 110, "max lost = 110");
    CHECK(aisd_decode_gate_verdict(dg, 105, 0, 0) == AISD_DECODE_GATE_VERDICT_DROP,
          "mid-episode delta drops");
    CHECK(aisd_decode_gate_verdict(dg, 111, 0, 1) == AISD_DECODE_GATE_VERDICT_SUBMIT,
          "acked anchor submits while alive");
    aisd_decode_gate_note_hard_decode_failure(dg);
    CHECK(aisd_decode_gate_mode(dg) == AISD_DECODE_GATE_MODE_NEED_KEYFRAME, "hard fail => need kf");
    CHECK(aisd_decode_gate_verdict(dg, 111, 0, 1) == AISD_DECODE_GATE_VERDICT_DROP,
          "acked anchor drops after teardown");
    aisd_decode_gate_note_decode_succeeded(dg, 112, 1);
    CHECK(aisd_decode_gate_mode(dg) == AISD_DECODE_GATE_MODE_OPEN, "fresh keyframe re-opens");
    aisd_decode_gate_free(dg);
    aisd_decode_gate_free(NULL); /* no-op */
    CHECK(aisd_decode_gate_mode(NULL) == AISD_DECODE_GATE_MODE_OPEN, "null gate is open");
    CHECK(aisd_decode_gate_verdict(NULL, 1, 0, 0) == AISD_DECODE_GATE_VERDICT_SUBMIT,
          "null gate submits");

    /* 16. owd_late_detector opaque handle: warmup, spike flag + out-param, null guard. */
    AisdOwdLateDetector *owd = aisd_owd_late_detector_new(2000.0, 25.0, 1.25, 20);
    CHECK(owd != NULL, "owd detector new");
    double owd_interval = 1000.0 / 60.0;
    double owd_arrival = 5000.0;
    uint32_t owd_send = 91000;
    double owd_dev = -1.0;
    int owd_warm_late = 0;
    for (int i = 0; i < 30; i++) {
        owd_warm_late |= aisd_owd_late_detector_note(owd, owd_arrival, owd_send, owd_interval,
                                                     &owd_dev);
        owd_arrival += 16.7;
        owd_send += 17;
    }
    CHECK(owd_warm_late == 0 && owd_dev == -1.0, "clean warmup never late, out untouched");
    owd_arrival += 16.7 + 40.0;
    owd_send += 17;
    CHECK(aisd_owd_late_detector_note(owd, owd_arrival, owd_send, owd_interval, &owd_dev) == 1 &&
              owd_dev > 10.0,
          "40ms spike flagged, deviation written");
    aisd_owd_late_detector_free(owd);
    aisd_owd_late_detector_free(NULL); /* no-op */
    CHECK(aisd_owd_late_detector_note(NULL, 0.0, 0, owd_interval, &owd_dev) == 0,
          "null detector never late");

    /* 17. input_button_balance opaque handle: plan struct + held mask + null guards. */
    AisdInputButtonBalance *ibb = aisd_input_button_balance_new();
    CHECK(ibb != NULL, "input button balance new");
    AisdInputPlan ip = aisd_input_button_balance_plan(ibb, AISD_INPUT_MOUSE_DOWN, 0);
    CHECK(ip.has_pre_release == 0 && ip.suppress == 0, "clean down posts");
    CHECK(aisd_input_button_balance_held_mask(ibb) == 0x01, "left held");
    ip = aisd_input_button_balance_plan(ibb, AISD_INPUT_MOUSE_DOWN, 0);
    CHECK(ip.has_pre_release == 1 && ip.pre_release_button == 0, "stuck down pre-releases left");
    ip = aisd_input_button_balance_plan(ibb, AISD_INPUT_MOUSE_UP, 0);
    CHECK(ip.suppress == 0 && aisd_input_button_balance_held_mask(ibb) == 0, "up releases left");
    ip = aisd_input_button_balance_plan(ibb, AISD_INPUT_MOUSE_UP, 0);
    CHECK(ip.suppress == 1, "duplicate up suppressed");
    aisd_input_button_balance_free(ibb);
    aisd_input_button_balance_free(NULL); /* no-op */
    ip = aisd_input_button_balance_plan(NULL, AISD_INPUT_MOUSE_UP, 0);
    CHECK(ip.has_pre_release == 0 && ip.suppress == 0, "null balance default plan");
    CHECK(aisd_input_button_balance_held_mask(NULL) == 0, "null balance empty mask");

    /* 18. recovery_idr_policy opaque handle: grant/suppress verdicts + null guards. */
    AisdRecoveryIdrPolicy *rip = aisd_recovery_idr_policy_new(0.75, 0.040, 0.250, 2.0, 2.0, 1.5, 4);
    CHECK(rip != NULL, "recovery idr policy new");
    CHECK(aisd_recovery_idr_policy_available_tokens(rip) == 2.0, "starts full");
    CHECK(aisd_recovery_idr_policy_decide(rip, 10.0, 0, 0, 0.05) == AISD_RECOVERY_IDR_GRANT,
          "first request grants");
    CHECK(aisd_recovery_idr_policy_available_tokens(rip) == 1.0, "grant spends a token");
    aisd_recovery_idr_policy_note_keyframe_sent(rip, 100, 5.0);
    CHECK(aisd_recovery_idr_policy_decide(rip, 5.02, 99, 1, 0.05) ==
              AISD_RECOVERY_IDR_SUPPRESS_IN_FLIGHT,
          "behind client suppressed in-flight");
    aisd_recovery_idr_policy_note_keyframe_delivered(rip, 100);
    CHECK(aisd_recovery_idr_policy_decide(rip, 9.0, 99, 1, 0.05) == AISD_RECOVERY_IDR_SUPPRESS_STALE,
          "request older than acked keyframe is stale");
    aisd_recovery_idr_policy_free(rip);
    aisd_recovery_idr_policy_free(NULL); /* no-op */
    CHECK(aisd_recovery_idr_policy_decide(NULL, 0.0, 0, 0, 0.0) == AISD_RECOVERY_IDR_GRANT,
          "null policy grants");
    CHECK(aisd_recovery_idr_policy_available_tokens(NULL) == 0.0, "null policy zero tokens");

    /* 19. video_mux_router opaque handle: admit/retire/drain routing + bootstrap + null guards. */
    AisdVideoMuxRouter *mux = aisd_video_mux_router_new();
    CHECK(mux != NULL, "video mux router new");
    CHECK(aisd_video_mux_router_route(mux, 11, 1, 1200) == AISD_MUX_DECISION_REJECT_UNADMITTED,
          "unknown lane rejected");
    aisd_video_mux_router_admit(mux, 11);
    CHECK(aisd_video_mux_router_is_admitted(mux, 11) == 1, "lane admitted");
    CHECK(aisd_video_mux_router_route(mux, 11, 1, 1200) == AISD_MUX_DECISION_ROUTE,
          "admitted lane routes");
    CHECK(aisd_video_mux_router_route(mux, 11, 1, 0) == AISD_MUX_DECISION_DROP, "empty drops");
    aisd_video_mux_router_retire(mux, 11);
    CHECK(aisd_video_mux_router_route(mux, 11, 1, 1200) == AISD_MUX_DECISION_DROP_RETIRED,
          "retired lane drop-retired");
    aisd_video_mux_router_admit(mux, 12);
    aisd_video_mux_router_begin_drain(mux, 12);
    CHECK(aisd_video_mux_router_is_draining(mux, 12) == 1, "lane draining");
    CHECK(aisd_video_mux_router_route(mux, 12, 1, 1200) == AISD_MUX_DECISION_DROP_DRAINING,
          "draining lane drop-draining");
    CHECK(aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_RETIRED, 0, 1, 0) ==
              AISD_MUX_BOOTSTRAP_DELIVER,
          "retired hello on control re-admits");
    CHECK(aisd_video_mux_router_bootstrap_action(AISD_MUX_DECISION_DROP_DRAINING, 0, 1, 0) ==
              AISD_MUX_BOOTSTRAP_DROP_NO_STAMP,
          "draining drops even a hello");
    aisd_video_mux_router_free(mux);
    aisd_video_mux_router_free(NULL); /* no-op */
    CHECK(aisd_video_mux_router_route(NULL, 1, 1, 100) == AISD_MUX_DECISION_REJECT_UNADMITTED,
          "null router rejects");

    /* 20. pacer_depth_policy opaque handle: config-by-value, promote/drain, GapClass, null guards. */
    AisdPacerDepthConfig pcfg = {
        .late_gap_factor = 1.6, .absolute_late_floor_seconds = 0.028, .idle_gap_seconds = 0.25,
        .gap_gradient_factor = 1.45, .dense_min_arrivals = 8, .dense_window_seconds = 0.35,
        .late_slack_fraction = 0.25, .promote_late_count = 2, .promote_window_seconds = 1.0,
        .demote_clean_seconds = 2.5, .min_hold_seconds = 1.0, .demote_tolerance_lates = 1,
        .promote_warmup_seconds = 2.0, .boost_depth = 2, .interval_ring_size = 15,
        .min_samples_for_estimate = 5, .default_interval_seconds = 1.0 / 60.0,
        .min_interval_seconds = 1.0 / 240.0, .max_interval_seconds = 1.0 / 10.0,
    };
    AisdPacerDepthPolicy *pdp = aisd_pacer_depth_policy_new(pcfg, 1);
    CHECK(pdp != NULL, "pacer depth policy new");
    CHECK(aisd_pacer_depth_policy_depth(pdp) == 1, "starts at depth 1");
    aisd_pacer_depth_policy_note_arrival(pdp, 0.0);
    aisd_pacer_depth_policy_note_network_late(pdp, 3.0);
    CHECK(aisd_pacer_depth_policy_depth(pdp) == 1, "one late never promotes");
    aisd_pacer_depth_policy_note_network_late(pdp, 3.2);
    CHECK(aisd_pacer_depth_policy_depth(pdp) == 2, "2nd late within window promotes");
    AisdPacerCounters pc = aisd_pacer_depth_policy_drain_counters(pdp);
    CHECK(pc.late_frames == 2, "drained 2 late frames");
    CHECK(aisd_pacer_depth_policy_drain_counters(pdp).late_frames == 0, "second drain empty");
    CHECK(aisd_pacer_depth_policy_note_present(pdp, 10.0) == AISD_PACER_GAP_FIRST, "first present");
    aisd_pacer_depth_policy_free(pdp);
    aisd_pacer_depth_policy_free(NULL); /* no-op */
    CHECK(aisd_pacer_depth_policy_depth(NULL) == 1, "null policy depth 1");
    CHECK(aisd_pacer_depth_policy_note_present(NULL, 0.0) == AISD_PACER_GAP_FIRST, "null first");

    /* 20b. scroll_reprojector opaque handle: drive velocity -> advance -> reset-to-0, clamp, nulls. */
    AisdScrollReprojectorConfig scfg = {.max_band = 0.125, .decay_seconds = 0.12};
    AisdScrollReprojector *srp = aisd_scroll_reprojector_new(scfg);
    CHECK(srp != NULL, "scroll reprojector new");
    double sox = 0.0, soy = 0.0;
    aisd_scroll_reprojector_note_velocity(srp, 0.0, 0.2, AISD_SCROLL_PHASE_ACTIVE);
    CHECK(aisd_scroll_reprojector_advance(srp, 0.05, &sox, &soy) == AISD_OK, "advance ok");
    CHECK(soy > 0.0099 && soy < 0.0101 && sox == 0.0, "offset grows ~vel*elapsed");
    /* RESET on a real frame -> exactly zero (the no-double-count invariant). */
    aisd_scroll_reprojector_note_real_frame(srp);
    CHECK(aisd_scroll_reprojector_advance(srp, 0.0, &sox, &soy) == AISD_OK, "advance after reset ok");
    CHECK(sox == 0.0 && soy == 0.0, "real frame resets offset to exactly 0");
    /* A fast flick clamps to the band. */
    aisd_scroll_reprojector_note_velocity(srp, 0.0, 9.0, AISD_SCROLL_PHASE_MOMENTUM);
    aisd_scroll_reprojector_advance(srp, 1.0, &sox, &soy);
    CHECK(soy > 0.1249 && soy < 0.1251, "fast flick clamps to max_band");
    aisd_scroll_reprojector_free(srp);
    aisd_scroll_reprojector_free(NULL); /* no-op */
    /* Null handle: advance reports NULL and leaves the out-params untouched. */
    sox = 3.0; soy = 4.0;
    CHECK(aisd_scroll_reprojector_advance(NULL, 0.1, &sox, &soy) == AISD_ERR_NULL, "null advance NULL");
    CHECK(sox == 3.0 && soy == 4.0, "null advance leaves out-params untouched");
    aisd_scroll_reprojector_note_velocity(NULL, 1.0, 1.0, AISD_SCROLL_PHASE_ENDED); /* no-op */
    aisd_scroll_reprojector_note_real_frame(NULL); /* no-op */
    aisd_scroll_reprojector_reset(NULL); /* no-op */

    /* 21. fec: NEON-backed Reed-Solomon. Build a k=4 m=2 codec, generate parity over 4 data shards,
     * erase 2, recover them, assert byte-equality, then free everything (+ a double-free of the
     * array to prove idempotence). An invalid config returns NULL, not an abort. */
    CHECK(aisd_fec_codec_new(0, 2) == NULL, "fec codec rejects k<1");
    CHECK(aisd_fec_codec_new(128, 128) == NULL, "fec codec rejects k+m>255");
    AisdFecCodec *fec = aisd_fec_codec_new(4, 2);
    CHECK(fec != NULL, "fec codec new k=4 m=2");

    uint8_t s0[4] = {0x10, 0x11, 0x12, 0x13};
    uint8_t s1[4] = {0x20, 0x21, 0x22, 0x23};
    uint8_t s2[4] = {0x30, 0x31, 0x32, 0x33};
    uint8_t s3[4] = {0x40, 0x41, 0x42, 0x43};
    AisdBytes data_in[4] = {
        {s0, sizeof(s0), 0}, {s1, sizeof(s1), 0}, {s2, sizeof(s2), 0}, {s3, sizeof(s3), 0}};
    AisdBytesArray parity = {NULL, 0};
    CHECK(aisd_fec_parity(fec, data_in, 4, 4, &parity) == AISD_OK, "fec parity ok");
    CHECK(parity.count == 2 && parity.items != NULL, "one group => m=2 parity shards");

    /* Erase shards 1 and 3: present=0, their bytes carried as the empty buffer (a hole, not empty). */
    AisdBytes data[4] = {
        {s0, sizeof(s0), 0}, {NULL, 0, 0}, {s2, sizeof(s2), 0}, {NULL, 0, 0}};
    uint8_t data_present[4] = {1, 0, 1, 0};
    uint8_t parity_present[2] = {1, 1};
    uint8_t out_recovered[4] = {0, 0, 0, 0};
    CHECK(aisd_fec_recover(fec, data, data_present, 4, parity.items, parity_present, parity.count, 4,
                           out_recovered) == AISD_OK,
          "fec recover ok");
    CHECK(out_recovered[0] == 0 && out_recovered[1] == 1 && out_recovered[2] == 0 &&
              out_recovered[3] == 1,
          "exactly the two holes were filled");
    CHECK(data[1].len == sizeof(s1) && memcmp(data[1].ptr, s1, sizeof(s1)) == 0,
          "shard 1 recovered byte-exact");
    CHECK(data[3].len == sizeof(s3) && memcmp(data[3].ptr, s3, sizeof(s3)) == 0,
          "shard 3 recovered byte-exact");

    /* Free the two recovered (Rust-owned) shards, then the parity array (twice => idempotent). */
    aisd_bytes_free(data[1]);
    aisd_bytes_free(data[3]);
    aisd_bytes_array_free(&parity);
    CHECK(parity.items == NULL && parity.count == 0, "array free nulls the items");
    aisd_bytes_array_free(&parity);     /* idempotent double-free */
    aisd_bytes_array_free(NULL);        /* null pointer no-op */
    aisd_fec_codec_free(fec);
    aisd_fec_codec_free(NULL);          /* no-op */

    /* An unrecoverable group (3 holes > m=2) leaves the holes, never panics. */
    AisdFecCodec *fec2 = aisd_fec_codec_new(5, 2);
    uint8_t u[5][3] = {{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}, {5, 5, 5}};
    AisdBytes uin[5];
    for (int i = 0; i < 5; i++) { uin[i].ptr = u[i]; uin[i].len = 3; uin[i].cap = 0; }
    AisdBytesArray uparity = {NULL, 0};
    CHECK(aisd_fec_parity(fec2, uin, 5, 5, &uparity) == AISD_OK, "fec parity (unrecoverable case)");
    AisdBytes udata[5];
    for (int i = 0; i < 5; i++) { udata[i].ptr = u[i]; udata[i].len = 3; udata[i].cap = 0; }
    udata[0] = (AisdBytes){NULL, 0, 0};
    udata[2] = (AisdBytes){NULL, 0, 0};
    udata[4] = (AisdBytes){NULL, 0, 0};
    uint8_t upresent[5] = {0, 1, 0, 1, 0};
    uint8_t uparity_present[2] = {1, 1};
    uint8_t uout[5] = {9, 9, 9, 9, 9};
    CHECK(aisd_fec_recover(fec2, udata, upresent, 5, uparity.items, uparity_present, uparity.count,
                           5, uout) == AISD_OK,
          "fec recover (unrecoverable) ok");
    CHECK(uout[0] == 0 && uout[2] == 0 && uout[4] == 0, "3 holes > m=2 => none recovered");
    CHECK(udata[0].ptr == NULL && udata[2].ptr == NULL && udata[4].ptr == NULL,
          "unrecovered holes carry no buffer");
    aisd_bytes_array_free(&uparity);
    aisd_fec_codec_free(fec2);

    /* 22. reassembler: drive raw fragment datagrams through the receive hot path.
     *
     * 22a. A whole 3-fragment no-FEC keyframe completes with the concatenated payload + flags. */
    AisdReassembler *ra = aisd_reassembler_new(0, 1, 2); /* k==0 => no-FEC */
    CHECK(ra != NULL, "reassembler new (no-fec)");
    CHECK(aisd_reassembler_new(200, 56, 2) == NULL, "reassembler rejects k+m>255");
    uint8_t p0[3] = {0xA0, 0xA1, 0xA2};
    uint8_t p1[2] = {0xB0, 0xB1};
    uint8_t p2[4] = {0xC0, 0xC1, 0xC2, 0xC3};
    uint8_t frag_buf[64];
    AisdReassemblyResult rr;
    size_t n;
    n = pack_fragment(frag_buf, 0, 7, 0, 3, 0x01 /* keyframe */, p0, 3);
    CHECK(aisd_reassembler_ingest(ra, frag_buf, n, &rr) == AISD_OK && rr.kind == AISD_REASSEMBLY_PENDING,
          "fragment 0 pending");
    n = pack_fragment(frag_buf, 1, 7, 1, 3, 0x01, p1, 2);
    CHECK(aisd_reassembler_ingest(ra, frag_buf, n, &rr) == AISD_OK && rr.kind == AISD_REASSEMBLY_PENDING,
          "fragment 1 pending");
    n = pack_fragment(frag_buf, 2, 7, 2, 3, 0x01, p2, 4);
    CHECK(aisd_reassembler_ingest(ra, frag_buf, n, &rr) == AISD_OK && rr.kind == AISD_REASSEMBLY_COMPLETED,
          "fragment 2 completes the frame");
    uint8_t ra_want[9] = {0xA0, 0xA1, 0xA2, 0xB0, 0xB1, 0xC0, 0xC1, 0xC2, 0xC3};
    CHECK(rr.frame_id == 7 && rr.keyframe == 1 && rr.recovered_via_fec == 0, "completed flags");
    CHECK(rr.avcc.len == sizeof(ra_want) && memcmp(rr.avcc.ptr, ra_want, sizeof(ra_want)) == 0,
          "avcc is the concatenated payloads");
    aisd_reassembly_result_free(&rr); /* frees the owned avcc */
    CHECK(rr.avcc.ptr == NULL, "result free nulls avcc");
    aisd_reassembly_result_free(&rr); /* idempotent */
    aisd_reassembler_free(ra);

    /* 22b. A single dropped data fragment FEC-recovers (k=2 m=1 => 2 data + 1 parity). Compute the
     * parity through aisd_fec_parity, ingest data[0] + parity (drop data[1]); the frame completes
     * with recovered_via_fec set and the exact original bytes. */
    AisdReassembler *raf = aisd_reassembler_new(2, 1, 2);
    AisdFecCodec *rcodec = aisd_fec_codec_new(2, 1);
    uint8_t d0[4] = {0xD0, 0xD1, 0xD2, 0xD3};
    uint8_t d1[4] = {0xE0, 0xE1, 0xE2, 0xE3};
    AisdBytes rdata[2] = {{d0, sizeof(d0), 0}, {d1, sizeof(d1), 0}};
    AisdBytesArray rparity = {NULL, 0};
    CHECK(aisd_fec_parity(rcodec, rdata, 2, 2, &rparity) == AISD_OK && rparity.count == 1,
          "fec parity for the recovery frame");
    /* 3 fragments total: data 0, data 1 (dropped), parity at frag_index 2 (parity flag bit1). */
    n = pack_fragment(frag_buf, 10, 9, 0, 3, 0x01, d0, (uint16_t)sizeof(d0));
    CHECK(aisd_reassembler_ingest(raf, frag_buf, n, &rr) == AISD_OK && rr.kind == AISD_REASSEMBLY_PENDING,
          "recovery data 0 pending");
    /* data fragment 1 is LOST — never ingested. */
    n = pack_fragment(frag_buf, 12, 9, 2, 3, 0x01 | 0x02 /* keyframe + parity */, rparity.items[0].ptr,
                      (uint16_t)rparity.items[0].len);
    CHECK(aisd_reassembler_ingest(raf, frag_buf, n, &rr) == AISD_OK &&
              rr.kind == AISD_REASSEMBLY_COMPLETED,
          "parity completes the frame via FEC");
    CHECK(rr.recovered_via_fec == 1, "recovered_via_fec flag set");
    uint8_t ra_rwant[8] = {0xD0, 0xD1, 0xD2, 0xD3, 0xE0, 0xE1, 0xE2, 0xE3};
    CHECK(rr.avcc.len == sizeof(ra_rwant) && memcmp(rr.avcc.ptr, ra_rwant, sizeof(ra_rwant)) == 0,
          "FEC-recovered avcc is byte-exact");
    aisd_reassembly_result_free(&rr);
    aisd_bytes_array_free(&rparity);
    aisd_fec_codec_free(rcodec);
    aisd_reassembler_free(raf);

    /* 22c. An unrecoverable loss (no FEC): drop a data fragment of frame 0, then a newer frame 1
     * advances the loss frontier => frame 0 is surfaced as dropped via next_dropped. */
    AisdReassembler *rad = aisd_reassembler_new(0, 1, 2);
    n = pack_fragment(frag_buf, 20, 0, 0, 2, 0x01, p0, 3); /* frame 0 frag 0 (of 2); frag 1 lost */
    CHECK(aisd_reassembler_ingest(rad, frag_buf, n, &rr) == AISD_OK && rr.kind == AISD_REASSEMBLY_PENDING,
          "frame 0 frag 0 pending");
    n = pack_fragment(frag_buf, 21, 1, 0, 1, 0x01, p1, 2); /* frame 1 advances the frontier */
    CHECK(aisd_reassembler_ingest(rad, frag_buf, n, &rr) == AISD_OK, "frame 1 ingested");
    uint32_t lost = 0xFFFFFFFFu;
    CHECK(aisd_reassembler_next_dropped(rad, &lost) == 1 && lost == 0, "frame 0 surfaced as dropped");
    CHECK(aisd_reassembler_next_dropped(rad, &lost) == 0, "drop queue drained");
    /* 22d. Hostile / truncated input is ignored, never a crash. */
    uint8_t rsbad[4] = {1, 2, 3, 4};
    CHECK(aisd_reassembler_ingest(rad, rsbad, sizeof(rsbad), &rr) == AISD_OK &&
              rr.kind == AISD_REASSEMBLY_PENDING,
          "truncated datagram ignored as pending");
    CHECK(aisd_reassembler_ingest(NULL, rsbad, sizeof(rsbad), &rr) == AISD_ERR_NULL, "null handle");
    CHECK(aisd_reassembler_ingest(rad, rsbad, sizeof(rsbad), NULL) == AISD_ERR_NULL, "null out");
    CHECK(aisd_reassembler_next_dropped(NULL, &lost) == 0, "null handle next_dropped");
    aisd_reassembler_free(rad);
    aisd_reassembler_free(NULL); /* no-op */
    aisd_reassembly_result_free(NULL); /* no-op */

    /* 23. frame_hash: the NEON NV12 frame hash over borrowed plane pointers. Build a small padded
     * NV12 frame (stride > width) and assert: deterministic; padding-independent; a one-byte change
     * differs; nulls / degenerate dims return the sentinel. */
    {
        const size_t fw = 24, fh = 16, fstride = 32; /* 8 padding bytes per row */
        uint8_t fy[32 * 16];
        uint8_t fc[32 * 8]; /* chroma: height/2 rows */
        for (size_t i = 0; i < sizeof(fy); i++) { fy[i] = (uint8_t)(i * 31 + 7); }
        for (size_t i = 0; i < sizeof(fc); i++) { fc[i] = (uint8_t)(i * 17 + 3); }

        uint64_t h1 = aisd_frame_hash_nv12(fy, fstride, fw, fh, fc, fstride);
        uint64_t h2 = aisd_frame_hash_nv12(fy, fstride, fw, fh, fc, fstride);
        CHECK(h1 == h2, "frame hash is deterministic for the same frame");
        CHECK(h1 != AISD_FRAME_HASH_SENTINEL, "a valid frame does not return the sentinel");

        /* Scribble the row PADDING (cols [fw, fstride)) with different bytes — the hash must NOT
         * change, proving only the visible `width` bytes are read. */
        for (size_t r = 0; r < fh; r++) {
            for (size_t c = fw; c < fstride; c++) { fy[r * fstride + c] = (uint8_t)(0xA0 + c); }
        }
        CHECK(aisd_frame_hash_nv12(fy, fstride, fw, fh, fc, fstride) == h1,
              "row padding must not affect the frame hash");

        /* A one-byte change inside the VISIBLE region must change the hash. */
        fy[5 * fstride + 3] ^= 0x01;
        CHECK(aisd_frame_hash_nv12(fy, fstride, fw, fh, fc, fstride) != h1,
              "a one-byte change differs");

        /* Luma-only (null chroma) is valid and deterministic. */
        uint64_t hy1 = aisd_frame_hash_nv12(fy, fstride, fw, fh, NULL, 0);
        uint64_t hy2 = aisd_frame_hash_nv12(fy, fstride, fw, fh, NULL, 0);
        CHECK(hy1 == hy2 && hy1 != AISD_FRAME_HASH_SENTINEL, "luma-only hash deterministic");

        /* Null / degenerate ⇒ sentinel, never a crash. */
        CHECK(aisd_frame_hash_nv12(NULL, fstride, fw, fh, fc, fstride) == AISD_FRAME_HASH_SENTINEL,
              "null luma ⇒ sentinel");
        CHECK(aisd_frame_hash_nv12(fy, 0, 0, 0, NULL, 0) == AISD_FRAME_HASH_SENTINEL,
              "zero dims ⇒ sentinel");
        CHECK(aisd_frame_hash_nv12(fy, 4, 8, 2, NULL, 0) == AISD_FRAME_HASH_SENTINEL,
              "stride < width ⇒ sentinel");
    }

    /* 24. packetizer: the SEND hot path (the symmetric counterpart of 22's reassembler). Fragment a
     * synthetic AVCC frame into wire datagrams, assert the count + each fragment's header, that the
     * data fragments concatenate back to the AVCC, and that feeding the produced datagrams to the
     * reassembler reconstructs the exact frame. Then an m=2 case producing 2 parity per group. */
    {
        /* invalid FEC config => NULL (no abort across the boundary). */
        CHECK(aisd_video_packetizer_new(200, 56) == NULL, "packetizer rejects k+m>255");
        AisdVideoPacketizer *pk = aisd_video_packetizer_new(0, 1); /* k==0 => no-FEC */
        CHECK(pk != NULL, "packetizer new (no-fec)");
        CHECK(aisd_video_packetizer_peek_next_frame_id(pk) == 0, "peek frame_id starts 0");

        /* MAX_PAYLOAD_SIZE = 1200 - 19 = 1181; 1181*2 + 37 => 3 MTU payloads. */
        const size_t flen = 1181 * 2 + 37;
        uint8_t *avcc = (uint8_t *)malloc(flen);
        CHECK(avcc != NULL, "avcc alloc");
        for (size_t i = 0; i < flen; i++) { avcc[i] = (uint8_t)(i * 7 + 1); }

        AisdPacketizeOptions popts;
        memset(&popts, 0, sizeof(popts));
        popts.keyframe = 1;
        popts.host_send_ts_millis = 4242;

        AisdBytesArray frags = {NULL, 0};
        CHECK(aisd_packetize(pk, avcc, flen, popts, &frags) == AISD_OK, "packetize ok");
        CHECK(frags.count == 3, "1181*2+37 => 3 fragments");
        /* Parse each returned datagram's header (big-endian) and rebuild the data section. */
        uint8_t rebuilt[1181 * 2 + 37];
        size_t rebuilt_len = 0;
        int all_keyframe = 1, no_parity = 1, frame_id_ok = 1, count_ok = 1;
        for (size_t i = 0; i < frags.count; i++) {
            const uint8_t *d = frags.items[i].ptr;
            size_t dl = frags.items[i].len;
            CHECK(dl >= 19, "datagram carries the header");
            uint32_t frame_id = ((uint32_t)d[4] << 24) | ((uint32_t)d[5] << 16) |
                                ((uint32_t)d[6] << 8) | (uint32_t)d[7];
            uint16_t frag_count = (uint16_t)((d[10] << 8) | d[11]);
            uint8_t fl = d[12];
            uint16_t payload_len = (uint16_t)((d[17] << 8) | d[18]);
            CHECK(dl == (size_t)19 + payload_len, "payload_len matches the body");
            if (frame_id != 0) { frame_id_ok = 0; }
            if (frag_count != 3) { count_ok = 0; }
            if ((fl & 0x01) == 0) { all_keyframe = 0; }
            if ((fl & 0x02) != 0) { no_parity = 0; }
            memcpy(rebuilt + rebuilt_len, d + 19, payload_len);
            rebuilt_len += payload_len;
        }
        CHECK(frame_id_ok && count_ok, "shared frame_id 0, frag_count 3");
        CHECK(all_keyframe && no_parity, "keyframe bit set, no parity (no-FEC)");
        CHECK(rebuilt_len == flen && memcmp(rebuilt, avcc, flen) == 0,
              "data fragments concatenate back to the AVCC");
        CHECK(aisd_video_packetizer_peek_next_frame_id(pk) == 1, "peek frame_id advanced");
        CHECK(aisd_video_packetizer_peek_next_stream_seq(pk) == 3, "peek stream_seq advanced");

        /* Feed the produced datagrams to the reassembler => the exact frame reconstructs. */
        AisdReassembler *pra = aisd_reassembler_new(0, 1, 2);
        int reassembled_ok = 0;
        for (size_t i = 0; i < frags.count; i++) {
            AisdReassemblyResult pr;
            memset(&pr, 0, sizeof(pr));
            CHECK(aisd_reassembler_ingest(pra, frags.items[i].ptr, frags.items[i].len, &pr) == AISD_OK,
                  "reassembler ingest of a produced datagram");
            if (pr.kind == AISD_REASSEMBLY_COMPLETED) {
                reassembled_ok = (pr.avcc.len == flen && memcmp(pr.avcc.ptr, avcc, flen) == 0);
                aisd_reassembly_result_free(&pr);
            }
        }
        CHECK(reassembled_ok, "produced datagrams reassemble to the sent frame (send==recv SoT)");
        aisd_reassembler_free(pra);

        aisd_bytes_array_free(&frags);
        aisd_bytes_array_free(&frags); /* idempotent */
        CHECK(frags.items == NULL && frags.count == 0, "fragment array freed + zeroed");
        aisd_video_packetizer_free(pk);

        /* m=2: 5 data fragments at group 2 => ceil(5/2)=3 groups * m=2 = 6 parity. */
        AisdVideoPacketizer *pk2 = aisd_video_packetizer_new(2, 2);
        const size_t blen = 1181 * 5;
        for (size_t i = 0; i < flen; i++) { avcc[i] = (uint8_t)(i % 251); }
        uint8_t *big = (uint8_t *)malloc(blen);
        CHECK(big != NULL, "big alloc");
        for (size_t i = 0; i < blen; i++) { big[i] = (uint8_t)(i % 251); }
        AisdPacketizeOptions popts2;
        memset(&popts2, 0, sizeof(popts2));
        popts2.fec_group_size = 2;
        AisdBytesArray frags2 = {NULL, 0};
        CHECK(aisd_packetize(pk2, big, blen, popts2, &frags2) == AISD_OK, "packetize m=2 ok");
        size_t data_n = 0, parity_n = 0;
        for (size_t i = 0; i < frags2.count; i++) {
            uint8_t fl = frags2.items[i].ptr[12];
            if ((fl & 0x02) != 0) { parity_n++; } else { data_n++; }
        }
        CHECK(data_n == 5 && parity_n == 6, "m=2 produces 6 parity (3 groups * 2)");
        aisd_bytes_array_free(&frags2);
        aisd_video_packetizer_free(pk2);
        aisd_video_packetizer_free(NULL); /* no-op */

        /* null guards. */
        AisdBytesArray og = {NULL, 0};
        uint8_t three[3] = {1, 2, 3};
        AisdPacketizeOptions zopts;
        memset(&zopts, 0, sizeof(zopts));
        CHECK(aisd_packetize(NULL, three, 3, zopts, &og) == AISD_ERR_NULL, "packetize null handle");
        AisdVideoPacketizer *pk3 = aisd_video_packetizer_new(0, 1);
        CHECK(aisd_packetize(pk3, three, 3, zopts, NULL) == AISD_ERR_NULL, "packetize null out");
        CHECK(aisd_packetize(pk3, NULL, 3, zopts, &og) == AISD_ERR_NULL, "null avcc with nonzero len");
        CHECK(aisd_packetize(pk3, NULL, 0, zopts, &og) == AISD_OK && og.count == 1,
              "empty frame yields one fragment");
        aisd_bytes_array_free(&og);
        CHECK(aisd_video_packetizer_peek_next_frame_id(NULL) == 0, "null peek frame_id => 0");
        CHECK(aisd_video_packetizer_peek_next_stream_seq(NULL) == 0, "null peek stream_seq => 0");
        aisd_video_packetizer_free(pk3);

        free(avcc);
        free(big);
    }

    /* ---- mux_header: the per-datagram channelID prefix (caller-out encode + borrow decode) ---- */
    {
        /* Caller-out encode of [u32 BE channelID] into a sized buffer, then copy the payload. */
        const uint8_t payload[5] = {9, 8, 7, 6, 5};
        uint8_t datagram[4 + 5];
        size_t written = 0;
        CHECK(aisd_video_mux_header_encode(0x01020304u, datagram, sizeof(datagram), &written) == AISD_OK,
              "mux header encode ok");
        CHECK(written == AISD_VIDEO_MUX_CHANNEL_ID_LENGTH, "mux header wrote 4 prefix bytes");
        memcpy(datagram + 4, payload, sizeof(payload));
        const uint8_t expect[9] = {1, 2, 3, 4, 9, 8, 7, 6, 5};
        CHECK(memcmp(datagram, expect, sizeof(expect)) == 0, "mux header prefix is big-endian");

        /* Borrow+offset decode recovers the channelID and the payload offset (always 4). */
        uint32_t channel_id = 0;
        size_t offset = 0;
        CHECK(aisd_video_mux_header_decode(datagram, sizeof(datagram), &channel_id, &offset) == AISD_OK,
              "mux header decode ok");
        CHECK(channel_id == 0x01020304u, "mux header channelID round-trips");
        CHECK(offset == 4 && memcmp(datagram + offset, payload, sizeof(payload)) == 0,
              "payload offset is 4 + payload borrows correctly");

        /* A < 4-byte datagram is truncated; out-params untouched. */
        const uint8_t three[3] = {1, 2, 3};
        channel_id = 77;
        offset = 77;
        CHECK(aisd_video_mux_header_decode(three, 3, &channel_id, &offset) == AISD_ERR_TRUNCATED,
              "short datagram truncated");
        CHECK(channel_id == 77 && offset == 77, "truncated leaves out-params untouched");

        /* Undersized encode buffer truncated (nothing written); null guards report NULL. */
        uint8_t small[3];
        written = 9;
        CHECK(aisd_video_mux_header_encode(1, small, sizeof(small), &written) == AISD_ERR_TRUNCATED,
              "undersized encode buffer truncated");
        CHECK(written == 9, "truncated encode leaves *written untouched");
        CHECK(aisd_video_mux_header_encode(1, NULL, 4, &written) == AISD_ERR_NULL, "encode null out");
        CHECK(aisd_video_mux_header_decode(datagram, 4, NULL, &offset) == AISD_ERR_NULL,
              "decode null channelID out");
        CHECK(aisd_video_mux_header_decode(NULL, 4, &channel_id, &offset) == AISD_ERR_NULL,
              "decode null datagram with nonzero len");
    }

    if (failures == 0) {
        printf("aislopdesk-ffi C smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "aislopdesk-ffi C smoke: %d FAILURE(S)\n", failures);
    return 1;
}
