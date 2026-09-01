// slopdesk_ffi_host_session.h — the host session machine, and what one key event is called
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_HOST_SESSION_H
#define SLOPDESK_FFI_HOST_SESSION_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * The HOST session machine — the other end of the handshake the client machine above answers, and
 * it crosses the same way: nine scalars by VALUE, effects into two lent buffers, and a transition
 * that COMMITS only when the answer fits, so measuring is never a second transition.
 *
 * The three resolvers are ANSWERS, not callbacks. Exactly one can matter per message — the
 * message's own variant decides which — so the near side resolves that one against its live state
 * and hands the size across, where `resolved == false` is the reject its closure spelled as nil.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_VIDEO_SESSION_IDLE 0u
#define SLOPDESK_VIDEO_SESSION_LISTENING 1u
#define SLOPDESK_VIDEO_SESSION_STREAMING 2u
#define SLOPDESK_VIDEO_SESSION_STOPPED 3u

#define SLOPDESK_SESSION_EFFECT_SEND_CONTROL 0u
#define SLOPDESK_SESSION_EFFECT_START_CAPTURE 1u
#define SLOPDESK_SESSION_EFFECT_STOP_CAPTURE 2u
#define SLOPDESK_SESSION_EFFECT_RESIZE_CAPTURE 3u
#define SLOPDESK_SESSION_EFFECT_APPLY_STREAM_SETTINGS 4u
#define SLOPDESK_SESSION_EFFECT_APPLY_AUDIO_CONTROL 5u
#define SLOPDESK_SESSION_EFFECT_APPLY_PRIVACY_MODE 6u

typedef struct {
  uint32_t state;
  uint32_t window_id;
  uint32_t next_stream_id;
  uint32_t last_stream_id;
  uint32_t last_resize_epoch;
  uint16_t capture_width;
  uint16_t capture_height;
  bool is_display_target;
  bool full_range;
} SlopDeskVideoSessionMachine;

/* A size the near side settled on, or `resolved == false` for the REJECT. */
typedef struct {
  uint16_t width;
  uint16_t height;
  bool resolved;
} SlopDeskResolvedSize;

typedef struct {
  uint32_t kind;
  SlopDeskByteSpan control;
  uint32_t window_id;
  uint32_t epoch;
  uint32_t first;
  uint32_t second;
  uint16_t width;
  uint16_t height;
  bool enabled;
} SlopDeskVideoSessionEffect;

typedef struct {
  size_t effects;
  size_t arena;
} SlopDeskVideoSessionShape;


SlopDeskVideoClientMachine slopdesk_video_client_new(uint32_t target_kind, uint32_t target_id,
                                                     SlopDeskVideoSize viewport);
bool slopdesk_video_client_media_flowing(SlopDeskVideoClientMachine machine);
uint32_t slopdesk_video_client_requested_window_id(SlopDeskVideoClientMachine machine);

SlopDeskVideoClientShape slopdesk_video_client_start(SlopDeskVideoClientMachine *machine,
                                                     SlopDeskVideoClientEffect *effects,
                                                     size_t effects_cap,
                                                     SlopDeskVideoMaskRect *masks, size_t masks_cap,
                                                     uint8_t *arena, size_t arena_cap);
SlopDeskVideoClientShape slopdesk_video_client_resend_hello(SlopDeskVideoClientMachine *machine,
                                                            SlopDeskVideoClientEffect *effects,
                                                            size_t effects_cap,
                                                            SlopDeskVideoMaskRect *masks,
                                                            size_t masks_cap, uint8_t *arena,
                                                            size_t arena_cap);
SlopDeskVideoClientShape slopdesk_video_client_stop(SlopDeskVideoClientMachine *machine,
                                                    SlopDeskVideoClientEffect *effects,
                                                    size_t effects_cap,
                                                    SlopDeskVideoMaskRect *masks, size_t masks_cap,
                                                    uint8_t *arena, size_t arena_cap);
SlopDeskVideoClientShape slopdesk_video_client_handle_control(
    SlopDeskVideoClientMachine *machine, const uint8_t *data, size_t data_len,
    SlopDeskVideoClientEffect *effects, size_t effects_cap, SlopDeskVideoMaskRect *masks,
    size_t masks_cap, uint8_t *arena, size_t arena_cap);

double slopdesk_video_client_hello_retry_delay(uint32_t attempt);

int32_t slopdesk_stall_scrim_note_reconnecting(bool *visible);
int32_t slopdesk_stall_scrim_apply(bool *visible, uint32_t verdict);


/* What the client pane does with the size it was given: the pan gate and its clamp, the layer-to-
 * decoded scale, the pre-decode triage, the frame-gated resize adoption, the drag debounce and the
 * one-to-one snap. Every one is a fold over two or three sizes. The debounce is four fields the
 * caller reads all of, so it rides in and out as a RECORD rather than a handle — §4b. An absent
 * previous size crosses as a value plus a flag, because "no frame yet" and "a frame of zero by
 * zero" mean different things and only one of them means adopt. */
#define SLOPDESK_FRAME_DECODABLE 0u
#define SLOPDESK_FRAME_DROP_SILENTLY 1u
#define SLOPDESK_FRAME_REQUEST_KEYFRAME 2u

#define SLOPDESK_RESIZE_HOLD 0u
#define SLOPDESK_RESIZE_REQUEST 1u

typedef struct {
  SlopDeskVideoSize last_requested;
  bool has_last_requested;
  uint32_t last_epoch;
  double min_delta;
  double settle_interval;
} SlopDeskResizeDebounce;

bool slopdesk_client_is_navigable(SlopDeskVideoSize window, SlopDeskVideoSize pane, double zoom);
SlopDeskVideoPoint slopdesk_client_max_pan_offset(SlopDeskVideoSize window, SlopDeskVideoSize pane,
                                                  double zoom);
double slopdesk_client_video_scale(SlopDeskVideoSize layer_size, SlopDeskVideoSize decoded_size);
uint32_t slopdesk_frame_decodability(bool keyframe, size_t byte_count);
bool slopdesk_resize_should_adopt(SlopDeskVideoSize pending, SlopDeskVideoSize decoded,
                                  SlopDeskVideoSize previous_decoded, bool has_previous);

SlopDeskResizeDebounce slopdesk_resize_debounce_default(void);
SlopDeskResizeDebounce slopdesk_resize_debounce_new(double min_delta, double settle_interval);
uint32_t slopdesk_resize_debounce_decide(SlopDeskResizeDebounce debounce,
                                         SlopDeskVideoSize layer_size,
                                         double elapsed_since_last_change, SlopDeskVideoSize *out);
uint32_t slopdesk_resize_debounce_note_requested(SlopDeskResizeDebounce *debounce,
                                                 SlopDeskVideoSize size);
void slopdesk_resize_debounce_note_adopted(SlopDeskResizeDebounce *debounce, SlopDeskVideoSize size);

SlopDeskVideoSize slopdesk_snap_target_points(SlopDeskVideoSize pixel_size, double capture_scale);
double slopdesk_snap_inferred_capture_scale(SlopDeskVideoSize decoded_pixels,
                                            SlopDeskVideoSize window_points);
bool slopdesk_snap_should_snap(SlopDeskVideoSize target, SlopDeskVideoSize current, double epsilon);
double slopdesk_snap_epsilon(void);

/* How jittery the link is, and how deep the buffer should be because of it. Three numbers and seven,
 * every one of them read by the caller, so both ride in and out as RECORDS — §4b. An absent stamp
 * crosses as a value plus a flag: the first arrival has no interval and the second has no second
 * difference, which is what keeps an initial burst from emitting a spurious spike. */
typedef struct {
  double last_arrival;
  bool has_last_arrival;
  double last_inter_arrival;
  bool has_last_inter_arrival;
  double jitter_seconds;
} SlopDeskOwdJitter;

typedef struct {
  uint32_t min_depth;
  uint32_t max_depth;
  double fps;
  double jitter_safety;
  uint32_t shrink_cooldown_frames;
  uint32_t target_depth;
  uint32_t shrink_run;
} SlopDeskAdaptiveJitter;

SlopDeskOwdJitter slopdesk_owd_jitter_new(void);
double slopdesk_owd_jitter_note(SlopDeskOwdJitter *estimator, double arrival);
uint32_t slopdesk_owd_jitter_micros(SlopDeskOwdJitter estimator);

double slopdesk_adaptive_jitter_default_safety(void);
uint32_t slopdesk_adaptive_jitter_default_cooldown(void);
SlopDeskAdaptiveJitter slopdesk_adaptive_jitter_new(uint32_t min_depth, uint32_t max_depth,
                                                    double fps, uint32_t initial_depth,
                                                    double jitter_safety,
                                                    uint32_t shrink_cooldown_frames);
uint32_t slopdesk_adaptive_jitter_note_frame(SlopDeskAdaptiveJitter *controller,
                                             double jitter_seconds);
uint32_t slopdesk_adaptive_jitter_note_underrun(SlopDeskAdaptiveJitter *controller);


/* ── client input: the pointer inverse and the modifier latch ────────────────────────────────── */
/* The mapping crosses FLAT with a flag, because C has no two-variant enum and because an all-zero
 * crop is a degenerate viewport rather than an absence — only one of the two takes the aspect-fit
 * path the golden vectors pin. */
typedef struct {
  SlopDeskVideoSize video_native_size;
  double zoom;
  SlopDeskVideoPoint pan;
  uint32_t mode;
  SlopDeskVideoRect crop;
  bool has_crop;
} SlopDeskPointerMapping;

SlopDeskVideoPoint slopdesk_input_normalize(SlopDeskVideoPoint view_point,
                                            SlopDeskVideoSize layer_size,
                                            SlopDeskPointerMapping mapping);
uint32_t slopdesk_input_next_tag(uint32_t tag);
/* Each knob crosses as its RAW bytes, empty meaning unset: the precedence between them and both
 * clamps are one rule, and a caller that pre-filtered the values would be applying half of it. */
double slopdesk_input_motion_interval(const uint8_t *hz, size_t hz_len, const uint8_t *milliseconds,
                                      size_t milliseconds_len);

/* The latch is nine keycodes, all of them 54..63, so it crosses as its own bitmask. */
uint64_t slopdesk_modifier_latch_new(void);
bool slopdesk_modifier_latch_is_empty(uint64_t latched);
bool slopdesk_modifier_latch_is_down(uint64_t latched, uint16_t key_code);
uint64_t slopdesk_modifier_latch_note(uint64_t latched, uint16_t key_code, bool down);
size_t slopdesk_modifier_latch_capacity(void);
size_t slopdesk_modifier_latch_drain(uint64_t *latched, uint16_t *out, size_t capacity);

/* ---- what the immersive tap does with one key ------------------------------------------------
 * `CGEventFlags` stops at this boundary: `modifiers` is the WIRE's own six-bit mask — shift 1,
 * control 2, option 4, command 8, caps lock 16, fn 32 — the same one every other input door
 * speaks, so Apple's numbers stay on the side with a header for them.
 * `kind` is 0 key down · 1 key up · 2 flags changed; anything else is an event with no rule, and
 * passes through. Swallowing the unknown is what turns an engaged pane into a keyboard trap.     */

// 0 forward and swallow · 1 pass through · 2 disengage.
uint8_t slopdesk_key_capture_decision(uint16_t key_code, uint8_t modifiers, uint8_t kind);
bool    slopdesk_key_capture_is_down(uint16_t key_code, uint8_t modifiers, uint8_t kind);
// The modifier bit a keycode drives, or -1 for a keycode that is not a modifier key.
int32_t slopdesk_key_capture_modifier_bit(uint16_t key_code);
// The cancel key, for the local monitors a transient gesture installs over the whole window.
bool    slopdesk_key_capture_is_escape(uint16_t key_code);

/* ---- What a key event is CALLED, for the dispatcher that keys bindings on it ----
 *
 * A live keystroke has to land on the name the binding table is keyed by, and a `keybind` line in
 * `config.toml` names the same keys — one table, therefore, and it answers a SUM: a named key, a
 * printable character, or nothing.
 *
 * The named-key indices are 0 return · 1 tab · 2 space · 3 left · 4 right · 5 up · 6 down ·
 * 7 pageup · 8 pagedown · 9 home · 10 end. Return covers the keypad's Enter — one intent, one name.
 */
typedef struct {
  uint8_t kind;   /* 0 nothing to key on · 1 a named key · 2 a printable character */
  uint8_t named;  /* the index above, read only when kind == 1 */
  size_t  length; /* the UTF-8 bytes written to (out, cap), read only when kind == 2 */
} SlopDeskKeyBase;

// `non_shift_modifier_held` decides the space bar and nothing else: bare and ⇧-only Space is typing
// the terminal must receive; ⌃/⌥/⌘ Space is the Vi-mode chord.
SlopDeskKeyBase slopdesk_key_chord_base(uint16_t key_code, const uint8_t *chars, size_t chars_len,
                                        bool non_shift_modifier_held, uint8_t *out, size_t cap);
// The two token doors: a named key's canonical SPELLING by case index, and the index a spelling
// names (-1 for a single character, an alias the grammar folds, or a token nothing produces). A
// caller with the same eleven cases needs the text to key a stored binding by, and asking for it is
// what keeps a `keybind` line from being read back under a spelling the dispatcher never builds.
size_t  slopdesk_key_named_canonical(uint8_t index, uint8_t *out, size_t cap);  // 0 = no such case
int32_t slopdesk_key_named_index(const uint8_t *text, size_t len);

/* The cursor-shape self-heal. Two lists of UNBOUNDED length — the ids whose bitmap arrived, and the
 * asks still outstanding — so the tracker rides in and out through lent buffers rather than as a
 * fixed record. `send` is only an answer when both counts fit: a call that could not write is not a
 * decision, and acting on it would send an ask the tracker has no record of. */
typedef struct {
  size_t known;
  size_t pending;
  bool send;
} SlopDeskCursorShapeAnswer;

double slopdesk_cursor_shape_default_interval(void);
bool slopdesk_cursor_shape_is_known(const uint16_t *known, size_t known_len, uint16_t shape_id);
SlopDeskCursorShapeAnswer slopdesk_cursor_shape_note_arrived(
    const uint16_t *known, size_t known_len, const uint16_t *pending_ids, const double *pending_at,
    size_t pending_len, uint16_t shape_id, uint16_t *out_known, size_t out_known_cap,
    uint16_t *out_pending_ids, double *out_pending_at, size_t out_pending_cap);
SlopDeskCursorShapeAnswer slopdesk_cursor_shape_should_request(
    const uint16_t *known, size_t known_len, const uint16_t *pending_ids, const double *pending_at,
    size_t pending_len, uint16_t shape_id, double now, double re_request_interval,
    uint16_t *out_known, size_t out_known_cap, uint16_t *out_pending_ids, double *out_pending_at,
    size_t out_pending_cap);


#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_HOST_SESSION_H */
