/*
 * aislopdesk_ffi.h — the C ABI of `aislopdesk-ffi`.
 *
 * This header is the contract a non-Rust platform shell links against to drive the pure
 * `aislopdesk-core` codecs (Swift on Apple via a bridging header; a JNI shim on Android).
 * It is hand-maintained to mirror the `#[repr(C)]` types in `src/lib.rs` field-for-field;
 * `tests/smoke.c` (and the Rust `tests/ffi_boundary.rs`) prove the two agree.
 *
 * Memory contract: every `AisdBytes` this library *returns* owns a Rust allocation and
 * MUST be released with `aisd_bytes_free` / `aisd_wire_message_free` — never C `free()`.
 * Buffers you pass *in* are borrowed for the call only and never freed by Rust. Opaque
 * handles are created by `*_new` and destroyed by `*_free`; use-after-free / double-free
 * is undefined behaviour, exactly as in C.
 */
#ifndef AISLOPDESK_FFI_H
#define AISLOPDESK_FFI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Status codes (return type of every fallible call) ----------------------------- */

typedef int32_t AisdStatus;

#define AISD_OK 0                  /* success                                           */
#define AISD_EMPTY 1               /* decoder needs more bytes (not an error)           */
#define AISD_ERR_NULL (-1)         /* a required pointer was null (nothing dereferenced) */
#define AISD_ERR_FRAME_TOO_LARGE (-2)
#define AISD_ERR_TRUNCATED (-3)
#define AISD_ERR_UNKNOWN_TYPE (-4)
#define AISD_ERR_MALFORMED (-5)
#define AISD_ERR_INVALID_ARGUMENT (-6) /* caller-supplied message was not encodable      */

/* ---- Owned byte buffer (Rust-allocated, Rust-freed) -------------------------------- */

typedef struct AisdBytes {
    uint8_t *ptr; /* points to `len` bytes, or NULL when `len == 0`                     */
    size_t len;   /* number of valid bytes                                              */
    size_t cap;   /* Rust allocation capacity — pass back to `*_free` unchanged         */
} AisdBytes;

/* Release a buffer this library returned. NULL/empty is a safe no-op. */
void aisd_bytes_free(AisdBytes bytes);

/* ---- Sequence arithmetic ----------------------------------------------------------- */

/* Wrap-aware signed distance a-b in 32-bit sequence space (positive => a is ahead). */
int32_t aisd_seq_distance(uint32_t a, uint32_t b);

/* ---- WireMessage tags (equal to the on-wire message type byte) --------------------- */

#define AISD_WIRE_OUTPUT 1
#define AISD_WIRE_EXIT 2
#define AISD_WIRE_INPUT 3
#define AISD_WIRE_HELLO 10
#define AISD_WIRE_RESIZE 11
#define AISD_WIRE_ACK 12
#define AISD_WIRE_BYE 13
#define AISD_WIRE_PING 14
#define AISD_WIRE_HELLO_ACK 20
#define AISD_WIRE_TITLE 21
#define AISD_WIRE_BELL 22
#define AISD_WIRE_COMMAND_STATUS 23
#define AISD_WIRE_PONG 24
#define AISD_WIRE_NOTIFICATION 25

/*
 * A decoded (or to-be-encoded) terminal-protocol message, flattened for the C ABI.
 * `tag` selects which fields are meaningful (see the per-tag table in src/lib.rs). Unused
 * numeric fields are 0; unused buffers are {NULL,0,0}. Field order MUST match the Rust
 * `#[repr(C)] struct AisdWireMessage` exactly.
 */
typedef struct AisdWireMessage {
    uint8_t tag;
    int64_t seq;
    int32_t code;
    uint16_t protocol_version;
    int64_t last_received_seq;
    int64_t resume_from_seq;
    uint16_t cols;
    uint16_t rows;
    uint16_t px_width;
    uint16_t px_height;
    uint64_t timestamp_ms;
    uint8_t returning_client; /* 0 = false, any nonzero = true */
    uint8_t session_id[16];
    uint8_t cmd_running;       /* nonzero = running, 0 = idle      */
    uint8_t cmd_has_exit_code; /* nonzero if `code` is meaningful  */
    uint32_t duration_ms;
    AisdBytes data;
    AisdBytes data2;
} AisdWireMessage;

/*
 * Encode a caller-built message into a complete length-prefixed wire frame. On AISD_OK,
 * `*out` receives an owned frame (release with `aisd_bytes_free`). Returns AISD_ERR_NULL
 * for a null argument or AISD_ERR_INVALID_ARGUMENT for an unknown tag / non-UTF-8 string.
 */
AisdStatus aisd_wire_message_encode(const AisdWireMessage *msg, AisdBytes *out);

/*
 * Decode a single complete payload ([type byte][body...], WITHOUT the 4-byte length prefix
 * — framing is the caller's job) into `*out`. The de-framed counterpart of the streaming
 * decoder, for callers that buffer/de-frame the stream themselves and only want the protocol
 * body parsed by the shared codec. On AISD_OK, `*out` owns buffers (release with
 * `aisd_wire_message_free`). `payload` may be NULL only when `len == 0`. Returns
 * AISD_ERR_NULL, AISD_ERR_TRUNCATED, AISD_ERR_UNKNOWN_TYPE, or AISD_ERR_MALFORMED on failure.
 */
AisdStatus aisd_wire_message_decode(const uint8_t *payload, size_t len, AisdWireMessage *out);

/* Release the owned buffers inside a decoded message (its `data`/`data2`). Idempotent. */
void aisd_wire_message_free(AisdWireMessage *msg);

/* ---- Zero-copy DATA-frame path (Output/Input; single payload copy) ----------------- */

/*
 * A borrowed view of a DATA-channel payload (Output/Input). `bytes` points INTO the caller's
 * payload buffer (NOT owned, never free it) and is valid only while that buffer lives. `tag` is
 * 1 (output) or 3 (input) for a DATA frame, or 0 when the payload is a control message the caller
 * must decode via aisd_wire_message_decode. Field order MUST match the Rust struct AisdDataFrameView.
 */
typedef struct AisdDataFrameView {
    uint8_t tag;          /* 1=output, 3=input, 0=not a DATA frame (use the owned decode) */
    int64_t seq;          /* Output.seq (0 otherwise)                                     */
    const uint8_t *bytes; /* borrowed bulk bytes (NULL when empty)                        */
    size_t bytes_len;
} AisdDataFrameView;

/* Frame a DATA message (tag 1 output uses seq; tag 3 input ignores it) whose bulk payload is
 * borrowed, writing [u32 BE len][type][seq?][payload] into `out` with ONE payload copy. On AISD_OK,
 * *written = frame length. Size `out` to the message's wireByteCount. Returns AISD_ERR_NULL or
 * AISD_ERR_INVALID_ARGUMENT (non-DATA tag / out too small). */
AisdStatus aisd_wire_data_frame_encode_into(uint8_t tag, int64_t seq, const uint8_t *payload,
                                            size_t payload_len, uint8_t *out, size_t out_cap,
                                            size_t *written);

/* Parse a complete payload ([type][body...], no length prefix) into a borrowed *out view. On
 * AISD_OK: tag 1/3 = a DATA frame whose `bytes` borrow into `payload` (copy them out before
 * `payload` is freed; never free `bytes`); tag 0 = a control message (decode via
 * aisd_wire_message_decode). Returns AISD_ERR_TRUNCATED (empty / short Output header) or
 * AISD_ERR_NULL. */
AisdStatus aisd_wire_data_frame_view(const uint8_t *payload, size_t len, AisdDataFrameView *out);

/* ---- Streaming frame decoder (opaque handle) --------------------------------------- */

typedef struct AisdFrameDecoder AisdFrameDecoder;

/* Create an empty decoder. Destroy with `aisd_frame_decoder_free`. */
AisdFrameDecoder *aisd_frame_decoder_new(void);

/* Destroy a decoder. NULL is a safe no-op. */
void aisd_frame_decoder_free(AisdFrameDecoder *decoder);

/* Append received bytes. `data` may be NULL only when `len == 0`. */
AisdStatus aisd_frame_decoder_append(AisdFrameDecoder *decoder, const uint8_t *data, size_t len);

/*
 * Drain the next complete message into `*out`. AISD_OK => a message was written (free its
 * buffers with `aisd_wire_message_free`); AISD_EMPTY => need more bytes (nothing written);
 * negative => a decode error (nothing written).
 */
AisdStatus aisd_frame_decoder_next(AisdFrameDecoder *decoder, AisdWireMessage *out);

/* ==== Video path =================================================================== *
 * Scalar realtime policies + small-buffer codecs from aislopdesk-core's video modules.
 * Same memory/error contract as above. Pure scalar functions take no pointers and never
 * fail. (Implemented in src/video.rs.)
 */

/* ---- live_bitrate_policy (pure scalar) -------------------------------------------- */

/* Resolution-aware target bitrate (bits/sec) for pixel_width x pixel_height at fps, never
 * below floor or the minimum. The caller resolves bits_per_pixel (e.g. from AISLOPDESK_BPP)
 * so the core stays environment-free. */
int64_t aisd_live_bitrate_target(int64_t pixel_width, int64_t pixel_height, int64_t fps,
                                 int64_t floor, double bits_per_pixel);

/* The absolute minimum live bitrate (bits/sec). */
int64_t aisd_live_bitrate_minimum(void);

/* ---- adaptive_playout (pure scalar) ----------------------------------------------- */

/* One hysteretic step of the client deadline-pacer's adaptive playout delay (milliseconds).
 * Maps live jitter_seconds to clamp(k*jitter + base, [floor, ceil]) and steps prev_playout_ms
 * toward it: grow-fast, shrink-slow (<= shrink_step_ms down per call). The caller holds
 * prev_playout_ms between calls and resolves the env knobs. */
double aisd_adaptive_playout_step_ms(double jitter_seconds, double prev_playout_ms,
                                     double shrink_step_ms, double k, double base_ms,
                                     double floor_ms, double ceil_ms);

/* ---- cursor (the fixed 36-byte hot cursor update) --------------------------------- */

/* A decoded cursor update (no owned buffer). Field order mirrors src/video.rs. */
typedef struct AisdCursorUpdate {
    uint16_t shape_id;
    uint8_t visible;     /* 0 = hidden, nonzero = visible */
    double x;
    double y;
    double hotspot_x;
    double hotspot_y;
} AisdCursorUpdate;

/* Encode a cursor update into its fixed 36-byte wire form. On AISD_OK, *out owns the buffer
 * (release with aisd_bytes_free). Cannot fail except for a null out. */
AisdStatus aisd_cursor_update_encode(uint16_t shape_id, uint8_t visible, double x, double y,
                                     double hotspot_x, double hotspot_y, AisdBytes *out);

/* Decode a cursor update into *out. Rejects a wrong type byte / non-finite coordinate
 * (AISD_ERR_MALFORMED) or a short body (AISD_ERR_TRUNCATED). data may be NULL iff len == 0. */
AisdStatus aisd_cursor_update_decode(const uint8_t *data, size_t len, AisdCursorUpdate *out);

/* ---- window_geometry (move/resize/bounds/title metadata channel) ------------------ */

#define AISD_WINDOW_GEOMETRY_MOVE 1
#define AISD_WINDOW_GEOMETRY_RESIZE 2
#define AISD_WINDOW_GEOMETRY_BOUNDS 3
#define AISD_WINDOW_GEOMETRY_TITLE 4

/*
 * A window-geometry message, flattened for the C ABI. `kind` (AISD_WINDOW_GEOMETRY_*) selects
 * which fields are meaningful: MOVE → x,y; RESIZE → width,height; BOUNDS → all four; TITLE →
 * title (UTF-8). On a decode *out the `title` owns a Rust allocation (release with
 * aisd_window_geometry_free); on an encode input it is a borrowed {ptr,len} (cap ignored) or
 * {NULL,0,0}. Field order MUST match the Rust #[repr(C)] struct AisdWindowGeometry exactly.
 */
typedef struct AisdWindowGeometry {
    uint8_t kind;
    double x;
    double y;
    double width;
    double height;
    AisdBytes title;
} AisdWindowGeometry;

/* Encode a caller-built window-geometry message into its wire form. On AISD_OK, *out owns the
 * buffer (release with aisd_bytes_free). Returns AISD_ERR_NULL for a null argument or
 * AISD_ERR_INVALID_ARGUMENT for an unknown kind / non-UTF-8 title. */
AisdStatus aisd_window_geometry_encode(const AisdWindowGeometry *msg, AisdBytes *out);

/* Decode a window-geometry message into *out. On AISD_OK, *out may own a `title` buffer (release
 * with aisd_window_geometry_free). data may be NULL iff len == 0. Maps a non-finite coordinate /
 * non-UTF-8 title / unknown type to AISD_ERR_MALFORMED and a short body to AISD_ERR_TRUNCATED. */
AisdStatus aisd_window_geometry_decode(const uint8_t *data, size_t len, AisdWindowGeometry *out);

/* Release the owned `title` buffer inside a decoded message. Idempotent; struct is caller-owned. */
void aisd_window_geometry_free(AisdWindowGeometry *msg);

/* ---- input_event (client→host pointer/key/scroll/text events) --------------------- */

#define AISD_INPUT_MOUSE_MOVE 1
#define AISD_INPUT_MOUSE_DOWN 2
#define AISD_INPUT_MOUSE_UP 3
#define AISD_INPUT_SCROLL 4
#define AISD_INPUT_KEY 5
#define AISD_INPUT_TEXT 6
#define AISD_INPUT_MOUSE_DRAG 7

/*
 * A client→host input event, flattened for the C ABI. `kind` (AISD_INPUT_*) selects which fields
 * are meaningful; `tag` (the self-inject filter) is valid for EVERY kind. MOUSE_MOVE → x,y;
 * MOUSE_DOWN/UP/DRAG → button,click_count,modifiers,x,y; SCROLL → dx,dy,x,y,scroll_phase,
 * momentum_phase,continuous; KEY → key_code,down,modifiers; TEXT → text (UTF-8; owned out via
 * aisd_input_event_free / borrowed in). Field order MUST match the Rust #[repr(C)] struct
 * AisdInputEvent exactly.
 */
typedef struct AisdInputEvent {
    uint8_t kind;
    uint32_t tag;
    double x;
    double y;
    double dx;
    double dy;
    uint8_t button;       /* 0=left, 1=right, 2=other (DOWN/UP/DRAG) */
    uint8_t click_count;
    uint8_t modifiers;
    uint8_t scroll_phase;   /* CGScrollPhase code (SCROLL)         */
    uint8_t momentum_phase; /* CGMomentumScrollPhase code (SCROLL) */
    uint8_t continuous;     /* pixel-precise flag, read != 0       */
    uint16_t key_code;
    uint8_t down;           /* KEY down flag, read != 0            */
    AisdBytes text;
} AisdInputEvent;

/* Encode a caller-built input event into its wire form. On AISD_OK, *out owns the buffer (release
 * with aisd_bytes_free). Returns AISD_ERR_NULL for a null argument or AISD_ERR_INVALID_ARGUMENT
 * for an unknown kind / out-of-range button / non-UTF-8 text. */
AisdStatus aisd_input_event_encode(const AisdInputEvent *msg, AisdBytes *out);

/* Decode an input event into *out. On AISD_OK, *out may own a `text` buffer (release with
 * aisd_input_event_free). data may be NULL iff len == 0. Maps a non-finite coordinate / unknown
 * button / non-UTF-8 text / unknown type to AISD_ERR_MALFORMED and a short body to
 * AISD_ERR_TRUNCATED. */
AisdStatus aisd_input_event_decode(const uint8_t *data, size_t len, AisdInputEvent *out);

/* Release the owned `text` buffer inside a decoded event. Idempotent; struct is caller-owned. */
void aisd_input_event_free(AisdInputEvent *msg);

/* ---- video_control (PATH-2 session bring-up + window/dialog discovery lists) ------- */

#define AISD_VIDEO_CONTROL_HELLO 1
#define AISD_VIDEO_CONTROL_HELLO_ACK 2
#define AISD_VIDEO_CONTROL_BYE 3
#define AISD_VIDEO_CONTROL_RESIZE_REQUEST 4
#define AISD_VIDEO_CONTROL_RESIZE_ACK 5
#define AISD_VIDEO_CONTROL_KEEPALIVE 6
#define AISD_VIDEO_CONTROL_LIST_WINDOWS 7
#define AISD_VIDEO_CONTROL_WINDOW_LIST 8
#define AISD_VIDEO_CONTROL_FOCUS_WINDOW 9
#define AISD_VIDEO_CONTROL_STREAM_CADENCE 10
#define AISD_VIDEO_CONTROL_LIST_SYSTEM_DIALOGS 11
#define AISD_VIDEO_CONTROL_SYSTEM_DIALOG_LIST 12

/*
 * One window/dialog summary record — the element type of the WINDOW_LIST / SYSTEM_DIALOG_LIST
 * arrays. Both lists share it: WINDOW_LIST → `name` is the app name, `is_secure`/`keystrokes_blocked`
 * unused (0); SYSTEM_DIALOG_LIST → `name` is the owning process, `is_secure` is the secure-prompt
 * CLASS flag and `keystrokes_blocked` is the live "synthetic typing dropped right now" flag. On a
 * decode the `name`/`title` buffers own Rust allocations (released by aisd_video_control_free);
 * on an encode input they are borrowed {ptr,len} (cap ignored) or {NULL,0,0}. Field order MUST
 * match the Rust #[repr(C)] struct AisdVideoSummary exactly.
 */
typedef struct AisdVideoSummary {
    uint32_t window_id;
    uint16_t width;
    uint16_t height;
    uint8_t is_secure;         /* SYSTEM_DIALOG_LIST secure-prompt CLASS flag (0/1); 0 for WINDOW_LIST */
    uint8_t keystrokes_blocked; /* SYSTEM_DIALOG_LIST live "typing dropped now" flag (0/1); 0 for WINDOW_LIST */
    AisdBytes name;            /* app name (WINDOW_LIST) / owner (SYSTEM_DIALOG_LIST)                 */
    AisdBytes title;
} AisdVideoSummary;

/*
 * A PATH-2 video control message, flattened for the C ABI. `kind` (AISD_VIDEO_CONTROL_*) selects
 * which fields are meaningful: HELLO → protocol_version,requested_window_id,viewport_*; HELLO_ACK
 * → accepted,stream_id,capture_*,full_range,bounds_*; RESIZE_REQUEST → desired_*,epoch; RESIZE_ACK
 * → capture_*,epoch; STREAM_CADENCE → fps; WINDOW_LIST / SYSTEM_DIALOG_LIST → records,records_len;
 * the zero-body kinds use none. On a decode *out the `records` array owns a Rust allocation
 * (release with aisd_video_control_free); on an encode input it is a borrowed {records,records_len}
 * the library copies and never frees. Field order MUST match the Rust #[repr(C)] struct
 * AisdVideoControl exactly.
 */
typedef struct AisdVideoControl {
    uint8_t kind;
    uint16_t protocol_version;
    uint32_t requested_window_id;
    double viewport_w;
    double viewport_h;
    uint8_t accepted;   /* HELLO_ACK, read != 0 */
    uint32_t stream_id;
    uint8_t full_range; /* HELLO_ACK, read != 0 */
    double bounds_x;
    double bounds_y;
    double bounds_w;
    double bounds_h;
    uint16_t capture_width;  /* HELLO_ACK / RESIZE_ACK */
    uint16_t capture_height; /* HELLO_ACK / RESIZE_ACK */
    double desired_w;
    double desired_h;
    uint32_t epoch; /* RESIZE_REQUEST / RESIZE_ACK */
    uint16_t fps;   /* STREAM_CADENCE */
    AisdVideoSummary *records; /* WINDOW_LIST / SYSTEM_DIALOG_LIST (NULL otherwise) */
    size_t records_len;
} AisdVideoControl;

/* Encode a caller-built video control message into its wire form. On AISD_OK, *out owns the buffer
 * (release with aisd_bytes_free). Returns AISD_ERR_NULL for a null argument or
 * AISD_ERR_INVALID_ARGUMENT for an unknown kind / non-UTF-8 record string. */
AisdStatus aisd_video_control_encode(const AisdVideoControl *msg, AisdBytes *out);

/* Decode a video control message into *out. On AISD_OK, *out may own a `records` array (release with
 * aisd_video_control_free). data may be NULL iff len == 0. Maps a non-finite coordinate / unknown
 * type to AISD_ERR_MALFORMED and a short body to AISD_ERR_TRUNCATED (record strings decode lossily). */
AisdStatus aisd_video_control_decode(const uint8_t *data, size_t len, AisdVideoControl *out);

/* Release the owned `records` array (and each record's name/title) inside a decoded message.
 * Idempotent; the struct itself is caller-owned. */
void aisd_video_control_free(AisdVideoControl *msg);

/* ---- adaptive_fec (pure scalar; WF-4 FEC tier policy) ----------------------------- */

/* Tier-decision state for the dwell-gated adaptive-FEC variant. Field order MUST match the
 * Rust #[repr(C)] struct AisdTierState (mirrors aislopdesk_core::TierState). */
typedef struct AisdTierState {
    uint8_t tier;                   /* current wire tier (0..=7 on the wire)             */
    int32_t relax_streak;           /* consecutive reports that demanded relaxation       */
    int32_t sticky_relax_remaining; /* reports left in the doubled-dwell window; 0 = off  */
} AisdTierState;

/* Map a wire tier to the FEC group size. Returns 1 and writes *out for a parity tier; returns
 * 0 for the OFF tier (leaving *out untouched — treat as nil). TOTAL over every tier (unknown
 * => default_group_size). A NULL out returns 0 without writing. */
uint8_t aisd_adaptive_fec_group_size(uint8_t tier, size_t default_group_size, size_t *out);

/* Pick the next wire tier from the EWMA loss and previous_tier (plain decider). allow_off is
 * the OFF-tier escape hatch (0 = false, any nonzero = true), resolved caller-side. */
uint8_t aisd_adaptive_fec_tier(double loss, uint8_t previous_tier, uint8_t allow_off);

/* Dwell-gated tier step (production entry point). allow_off / saw_unrecovered_loss are bytes
 * read != 0; the caller resolves allow_off and passes dwell. Returns the next state by value. */
AisdTierState aisd_adaptive_fec_next_tier_state(double loss, AisdTierState state, int32_t dwell,
                                                uint8_t allow_off, uint8_t saw_unrecovered_loss);

/* ---- coordinate_mapping (pure scalar; screens borrowed in) ------------------------- */

/* A 2-D point in host points (layout = Rust AisdPoint = Swift VideoPoint: x then y). */
typedef struct AisdPoint {
    double x;
    double y;
} AisdPoint;

/* A rectangle (origin + size), flat (x, y, width, height) — all double. */
typedef struct AisdRect {
    double x;
    double y;
    double width;
    double height;
} AisdRect;

/* A display: Cocoa-bottom-left frame + Retina backing scale. */
typedef struct AisdScreenInfo {
    AisdRect cocoa_frame;
    double backing_scale_factor;
} AisdScreenInfo;

/* Map a normalised (0..1) window point to a host-window point in CG top-left space. */
AisdPoint aisd_coord_window_point(AisdPoint normalized, AisdRect window_bounds);

/* Flip a CG-top-left rect into Cocoa bottom-left space (cocoa_y = primary_height - cg_y - h). */
AisdRect aisd_coord_cg_rect_to_cocoa(AisdRect cg_rect, double primary_height);

/* Pick the screen a window lives on (largest overlap), writing its backing_scale_factor to
 * *out_scale. AISD_OK => overlap (*out_scale written); AISD_EMPTY => no overlap (untouched);
 * AISD_ERR_NULL => out_scale NULL, or screens NULL while screen_count != 0. screens borrowed. */
AisdStatus aisd_coord_backing_scale_factor(AisdRect window_bounds_cg,
                                           const AisdScreenInfo *screens, size_t screen_count,
                                           double primary_height, double *out_scale);

/* Pixel path: divide by backing_scale_factor to get points, then add the window origin. */
AisdPoint aisd_coord_window_point_from_pixel(AisdPoint pixel, AisdRect window_bounds_cg,
                                             double backing_scale_factor);

/* ---- recovery_policy (pure scalar) ------------------------------------------------ */

/* Whether the client should escalate a stalled LTR-refresh recovery to a forced IDR. The four
 * multiples map onto aislopdesk-core RecoveryPolicy (idr_timeout_rtt_multiple,
 * lossy_idr_timeout_rtt_multiple, lossy_escalation_floor [secs, env-resolved caller-side],
 * lossy_escalation_floor_rtt_multiple). observing_loss read as a byte != 0. Returns 1 to
 * escalate, 0 otherwise. Pure: no pointers, never fails. */
uint8_t aisd_recovery_policy_should_escalate_to_idr(double idr_rtt_mult, double lossy_idr_rtt_mult,
                                                    double lossy_floor_s, double lossy_floor_rtt_mult,
                                                    double elapsed_since_request, double rtt,
                                                    uint8_t observing_loss);

/* ---- window_placement (pure, flat-struct; HiDPI VD-park path) --------------------- */

/* Result of aisd_window_placement: the move-target origin (x, y), the shrink-clamped window
 * size (width, height), and needs_resize (1 = window overhangs the display by >½ pt). */
typedef struct AisdPlacement {
    double x;
    double y;
    double width;
    double height;
    uint8_t needs_resize;
} AisdPlacement;

/* Clamp a window (window_w × window_h) DOWN to `display` and place it at the display top-left.
 * Pure; never fails. */
AisdPlacement aisd_window_placement(double window_w, double window_h, AisdRect display);

/* Whether a window (size_w × size_h) fits inside `bounds` (½-pt tolerance). 1 = fits, 0 = not.
 * Pure; never fails. */
uint8_t aisd_window_fits(double size_w, double size_h, AisdRect bounds);

/* ---- virtual_display_geometry (pure scalar; VD creation path) --------------------- */

/* A virtual-display geometry: clamped input fields + derived pixel dims + chip-limit check. */
typedef struct AisdVDGeometry {
    int64_t point_width;
    int64_t point_height;
    int64_t scale;
    int64_t max_horizontal_pixels;
    int64_t pixel_width;          /* point_width * scale */
    int64_t pixel_height;         /* point_height * scale */
    uint8_t exceeds_pixel_limit;  /* 1 = pixel_width over the chip ceiling */
} AisdVDGeometry;

/* A physical millimetre size (width, height) for a VD descriptor. */
typedef struct AisdVDMillimeters {
    double width;
    double height;
} AisdVDMillimeters;

/* Build a (clamped) VD geometry and return its derived scalar fields. Pure; never fails. */
AisdVDGeometry aisd_vd_geometry(int64_t point_width, int64_t point_height,
                                int64_t scale, int64_t max_horizontal_pixels);

/* Physical mm size for a pixel_width × pixel_height display at target_ppi (non-finite / <1 ppi
 * clamps to 1.0). Pure; never fails. */
AisdVDMillimeters aisd_vd_size_in_millimeters(int64_t pixel_width, int64_t pixel_height,
                                              double target_ppi);

/* VD global origin flush right of the rightmost existing display (maxX, 0); (0,0) when none.
 * displays is borrowed (may be NULL iff display_count == 0). Pure; never fails. */
AisdPoint aisd_vd_origin_to_right(const AisdRect *displays, size_t display_count);

/* Chip horizontal pixel ceiling from a CPU brand C string (Pro/Max/Ultra → 7680, base Apple
 * M → 6144, else 7680). cpu_brand may be NULL (→ default). Pure; never fails. */
int64_t aisd_vd_chip_pixel_limit(const char *cpu_brand);

/* Write the descending refresh-rate modes for a VD at `fps` into `rates` (capacity slots) and
 * return the count (always 2 or 3). Writes nothing if rates is NULL or capacity < count. */
size_t aisd_vd_refresh_rates(int64_t fps, double *rates, size_t capacity);

/* ---- capture_region (pure, flat-struct; dialog-expand capture math) --------------- */

/* One CGWindowList row for capture-region math (window_id, owner_pid, layer, global frame). */
typedef struct AisdCaptureWindowSnapshot {
    uint32_t window_id;
    int32_t  owner_pid;
    int64_t  layer;
    AisdRect frame;
} AisdCaptureWindowSnapshot;

/* The capture union region: target window ∪ qualifying same-pid panels in front, clamped to
 * the display. windows_in_front is borrowed (NULL ok iff windows_count == 0). Pass 0.30 for
 * min_overlap_fraction (the default). Pure; never fails. */
AisdRect aisd_capture_union_region(AisdRect target_frame, uint32_t target_window_id,
                                   int32_t target_pid,
                                   const AisdCaptureWindowSnapshot *windows_in_front,
                                   size_t windows_count, AisdRect display_bounds,
                                   double min_overlap_fraction);

/* Hysteresis gate: 1 if |desired - current| > min_delta on any edge, else 0. Pass 8.0 for the
 * default min_delta. Pure; never fails. */
uint8_t aisd_capture_should_retarget(AisdRect current, AisdRect desired, double min_delta);

/* Whether a geometry change should re-origin capture to the plain window frame: 1 when no union
 * region is active (active_region_is_null != 0), else 0. Pure; never fails. */
uint8_t aisd_capture_reorigin_on_geometry(uint8_t active_region_is_null);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AISLOPDESK_FFI_H */
