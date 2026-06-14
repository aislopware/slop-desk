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
