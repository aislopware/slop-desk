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
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                                                  \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            fprintf(stderr, "FAIL: %s\n", (msg));                                         \
            failures++;                                                                   \
        }                                                                                 \
    } while (0)

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

    if (failures == 0) {
        printf("aislopdesk-ffi C smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "aislopdesk-ffi C smoke: %d FAILURE(S)\n", failures);
    return 1;
}
