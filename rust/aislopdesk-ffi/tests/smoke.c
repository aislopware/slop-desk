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

    if (failures == 0) {
        printf("aislopdesk-ffi C smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "aislopdesk-ffi C smoke: %d FAILURE(S)\n", failures);
    return 1;
}
