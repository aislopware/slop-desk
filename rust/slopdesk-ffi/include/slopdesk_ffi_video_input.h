// slopdesk_ffi_video_input.h — client to host input events, and the operating points both ends read
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_VIDEO_INPUT_H
#define SLOPDESK_FFI_VIDEO_INPUT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * The UDP mux prefix: four big-endian bytes saying which lane a datagram belongs to.
 *
 * Every outgoing datagram on the video flow is framed by it and every incoming one is split by it,
 * on both ends — the cheapest possible thing to get wrong in two places.
 *
 * `encode` writes straight into your buffer rather than allocating: the answer is the payload with
 * four (or five) bytes in front, so an allocating shape would copy the whole datagram again to
 * prepend a lane. `has_tag` picks the media-socket shape, `[lane][tag][payload]`, over the bare
 * `[lane][payload]`; one entry point with a flag rather than two symbols to pick wrongly between.
 * The length is knowable up front, so there is never a sizing call — but a short `cap` still leaves
 * the buffer untouched and returns what was needed, under §4's convention.
 *
 * `decode` answers the OFFSET the payload starts at, never the payload, and 0 for a datagram too
 * short to be split — unambiguous, because a payload can never start at offset 0.
 *
 * The MUXED FRAGMENT header is the second shape: the plain fragment's fields with a lane at offset
 * 0 and NO host timestamp. It is also 19 bytes, and that is a coincidence to be careful around
 * rather than a compatibility — reading one with the other's decoder parses cleanly and produces
 * nonsense.
 *
 * slopdesk_mux_constant: 0 the lane prefix, 1 the muxed header, 2 the largest muxed payload.
 * ---------------------------------------------------------------------------- */

typedef struct {
  uint32_t channel_id;
  uint32_t stream_seq;
  uint32_t frame_id;
  uint16_t frag_index;
  uint16_t frag_count;
  uint16_t payload_length;
  uint8_t flags;
  uint8_t payload_offset;
} SlopDeskMuxFragmentHeader;

size_t slopdesk_mux_encode(uint32_t channel_id, bool has_tag, uint8_t tag, const uint8_t *payload,
                           size_t payload_len, uint8_t *out, size_t cap);
size_t slopdesk_mux_decode(const uint8_t *bytes, size_t len, uint32_t *channel_id);
size_t slopdesk_mux_fragment_encode(uint32_t channel_id, uint32_t stream_seq, uint32_t frame_id,
                                    uint16_t frag_index, uint16_t frag_count, uint8_t flags,
                                    const uint8_t *payload, size_t payload_len, uint8_t *out,
                                    size_t cap);
bool slopdesk_mux_fragment_decode(const uint8_t *bytes, size_t len, SlopDeskMuxFragmentHeader *out);
size_t slopdesk_mux_constant(uint8_t index);

/* ---------------------------------------------------------------------------- *
 * Client -> host INPUT EVENTS: the shortest path from a hostile datagram to a syscall.
 *
 * The host decodes one of these off an unauthenticated UDP socket and posts it into the window
 * server. A non-finite coordinate reaching the injector is a trapping Int32(Double) and a dead
 * host, so the finite check is a DECODE guard here, not a caller's manners.
 *
 * One flat struct for all seven types rather than a C union: a union would have to be kept in step
 * with the Rust enum by hand on both sides, which is the drift this port removes. `message_type`
 * says which fields carry meaning — 1 move, 2 down, 3 up, 4 scroll, 5 key, 6 text, 7 drag — and
 * every other field is zero, never stale.
 *
 * decode answers a VERDICT (SLOPDESK_INPUT_DECODE_*), because a short datagram and a hostile one
 * are different things to the caller. The TEXT arm answers an OFFSET: the bytes stay in the
 * datagram you passed in, already proven UTF-8, so build the string from the span without checking
 * again. encode returns bytes NEEDED under §4, and 0 for a type or button no arm answers to.
 *
 * slopdesk_input_event_constant: 0 the text offset.
 *
 * COALESCING answers a PLAN, not events. A remote pointer stream is ~99% motion and the host posts
 * every event behind synchronous window-server round-trips, so a run of same-class motion collapses
 * to its LATEST (a merged scroll additionally SUMS its deltas, because keeping the latest would drop
 * scrolled distance) while every button, key, text or uncoalesced scroll event is a hard BARRIER
 * that buffered motion flushes before. The survivor is always an input the caller is already
 * holding, so the answer names it — which keeps the text arm's bytes, homeless in the flat record,
 * from crossing at all. `source` indices strictly increase.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_INPUT_DECODE_OK 0u
#define SLOPDESK_INPUT_DECODE_TRUNCATED 1u
#define SLOPDESK_INPUT_DECODE_MALFORMED 2u

typedef struct {
  double x;
  double y;
  double dx;
  double dy;
  uint32_t tag;
  uint16_t key_code;
  uint8_t message_type;
  uint8_t button;
  uint8_t click_count;
  uint8_t modifiers;
  uint8_t scroll_phase;
  uint8_t momentum_phase;
  bool continuous;
  bool down;
  bool autorepeat;
  uint8_t text_offset;
} SlopDeskInputEvent;

uint32_t slopdesk_input_event_decode(const uint8_t *bytes, size_t len, SlopDeskInputEvent *out);
size_t slopdesk_input_event_encode(SlopDeskInputEvent event, const uint8_t *text, size_t text_len,
                                   uint8_t *out, size_t cap);
uint8_t slopdesk_input_event_constant(uint8_t index);

typedef struct {
  double dx;
  double dy;
  uint32_t source;
} SlopDeskCoalescedSlot;


/* ---------------------------------------------------------------------------- *
 * The BUTTON AND MODIFIER LEDGER. The ordered consumer keeps one interaction's down, drag and up in
 * order, but it cannot conjure a mouse-up the wire dropped: a target app that got a down with no up
 * stays stuck mid-selection, so the next click lands inside a selection already in progress. A down
 * for an already-held button therefore asks for a synthetic release FIRST, and an up for a button
 * that is not held is the client's loss-resilient duplicate and is SUPPRESSED — which is what makes
 * that redundancy idempotent at the host. Modifier key edges get the same treatment (a lost release
 * latches the modifier on the shared event source until the user presses it again); ordinary keys,
 * whose auto-repeat is identical downs, and the caps-lock toggle pass through.
 *
 * The ledger crosses BY VALUE. Both its domains are fixed — three buttons, nine modifier keycodes —
 * so it is twelve bits, and a caller holding it in a struct it copies needs exactly that: a handle
 * it copied would be two ledgers by the second copy. The modifier bit is the key's position in
 * slopdesk_input_modifier_key_codes, which is the only place that says which keys these are.
 * ---------------------------------------------------------------------------- */

typedef struct {
  uint16_t modifiers;
  uint8_t buttons;
} SlopDeskInputBalance;

typedef struct {
  SlopDeskInputBalance state;
  uint8_t pre_release;
  bool has_pre_release;
  bool suppress;
} SlopDeskInjectionPlan;

size_t   slopdesk_input_modifier_key_codes(uint16_t *out, size_t cap);
uint16_t slopdesk_input_caps_lock_key_code(void);

/* ---------------------------------------------------------------------------- *
 * The TIME-GATED SCROLL ACCUMULATOR. A fast trackpad scroll and its momentum coast are a ~200/s
 * flood; uncoalesced, each delta is one synchronous post, which saturates the window server and
 * stalls CAPTURE. So continuous-phase deltas are SUMMED into an accumulator held ACROSS drains and
 * emitted at most once per interval, while a gesture boundary or any non-scroll event flushes it
 * FIRST, in order, and a trailing flush covers a run that ends mid-gesture. Total travel is exact
 * either way, because the deltas are additive.
 *
 * The state crosses BY VALUE, like the ledger and for the same reason. It answers a PLAN: a
 * passed-through event is NAMED (the caller holds it, text payload and all) and a summed emit is
 * the planner's own, carried whole because a scroll is all scalars.
 *
 * plan() only COMMITS the state when the answer fits, so a caller that lent too little may retry
 * without folding the run twice. Lend 2 * count + 2 slots and it always fits on the first call.
 * ---------------------------------------------------------------------------- */

typedef struct {
  double accumulated_dx;
  double accumulated_dy;
  double template_x;
  double template_y;
  double last_inject_at;
  double inject_interval;
  uint32_t template_tag;
  uint8_t template_scroll_phase;
  uint8_t template_momentum_phase;
  bool template_continuous;
  bool has_template;
  bool coalesce_scroll;
} SlopDeskScrollPlanner;

typedef struct {
  SlopDeskInputEvent event;
  uint32_t source;
  bool has_source;
} SlopDeskPlannedEvent;


/* ---------------------------------------------------------------------------- *
 * The three low-rate metadata wires: window geometry, swipe-nav status, app audio.
 *
 * One block because they share a shape — a small message off the same untrusted mesh — and one
 * verdict vocabulary (SLOPDESK_METADATA_DECODE_*). What each GUARDS differs:
 *   geometry — coordinates land in a CALayer frame, where a NaN is an uncaught
 *              CALayerInvalidGeometry and a dead client, so they are finite-checked at decode;
 *   swipe    — the status drives an affordance that must never promise a navigation the host
 *              would refuse, so the type byte is checked and not assumed;
 *   audio    — the datagram declares its own payload length, the classic over-allocate lever, so
 *              the cap, the bounds and the exact-consumption check are all decode guards.
 *
 * All three answer OFFSETS into the datagram you passed in — a title, a codec frame, an AAC
 * cookie — never copies. Slice your own buffer; the layouts stay on the Rust side.
 *
 * slopdesk_window_geometry_constant: 0 the title offset.
 * slopdesk_swipe_nav_constant: 0 the message type, 1 the encoded size.
 * slopdesk_audio_constant: 0 the header size, 1 the payload cap, 2 the config payload's head.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_METADATA_DECODE_OK 0u
#define SLOPDESK_METADATA_DECODE_TRUNCATED 1u
#define SLOPDESK_METADATA_DECODE_MALFORMED 2u

typedef struct {
  double x;
  double y;
  double width;
  double height;
  uint8_t message_type;
  uint8_t title_offset;
} SlopDeskWindowGeometry;

uint32_t slopdesk_window_geometry_decode(const uint8_t *bytes, size_t len,
                                         SlopDeskWindowGeometry *out);
size_t slopdesk_window_geometry_encode(SlopDeskWindowGeometry message, const uint8_t *title,
                                       size_t title_len, uint8_t *out, size_t cap);
uint8_t slopdesk_window_geometry_constant(uint8_t index);

/* Where a remoted window goes when it is parked on the virtual display. macOS CROPS a window that
 * overhangs its display, so an oversized one is shrunk BEFORE the move — and after the move the
 * achieved size is checked, because an app that refused the shrink still overhangs and must not be
 * reported as a successful 2x park (the capture crop would exceed the framebuffer and the client's
 * input mapping would desync).
 *
 * The caller keeps its window-system semantics: pass the display's STANDARDISED extents
 * (`CGRect.width` returns |size|) and the window's RAW size (`CGSize.width` is a stored field). The
 * clamp is asymmetric on purpose and the far side never abs's anything. Both comparisons are
 * ORDERED, so a NaN passes through rather than being swallowed by a NaN-ignoring minimum — the
 * `windowPlacement` / `windowFits` corpora pin that as bit patterns. Tolerance: half a point. */
typedef struct {
  double origin_x;      /* the display origin, verbatim — negative coordinates included */
  double origin_y;
  double width;         /* the size to resize to: the window's own, or the display's if narrower */
  double height;
  bool   needs_resize;  /* false when the shrink is inside the tolerance — the app is not asked */
} SlopDeskWindowPlacement;


/* Whether launch hygiene should move a window a CRASHED daemon left parked back to the frame that
 * run recorded for it. A clean shutdown un-parks everything, so this only ever reads a sidecar a
 * SIGKILL left behind — and the sidecar naming a window is not evidence it is still lost. Two
 * things say nothing is wrong, and either one alone stops the move: the window already sits at the
 * recorded origin (within two points of AX drift), or it overlaps a display that exists, so somebody
 * can see it. An EMPTY list is the CG enumeration having FAILED, not "on no display", and answers
 * false — every uncertainty resolves to leaving the window alone.
 *
 * `displays` is 4 * display_count doubles: x, y, width, height per display, in the same global
 * top-left space as the window frame (`CGDisplayBounds` / `CGWindowBounds`, both standardised). */

/* ---- What a HiDPI virtual display IS, before WindowServer is asked for one ---------------
 * The arithmetic half of `VirtualDisplay.swift`: everything the descriptor is filled with, and
 * nothing that talks to the window server. Every answer here fails SILENTLY when it drifts —
 * `applySettings:` returns YES for an over-budget framebuffer and leaves `displayID` at 0, a
 * millimetre size off by a rounding step brings the display up SOFT rather than failing, a display
 * placed over a real one makes WindowServer reflow the user's actual monitor arrangement, and a
 * refresh mode that is not advertised is simply never granted.
 *
 * The geometry carries the FLOORED point grid and scale back beside the derived pixels on purpose:
 * the mode is built from the points and `settings.hiDPI` from the scale, so a near-side `max(1, …)`
 * would be a second answer to the same question rather than a defensive check. */
typedef struct {
  int32_t point_width;           /* the logical grid, floored at 1 — what a mode is built from */
  int32_t point_height;
  int32_t scale;                 /* the backing scale, floored at 1; >= 2 sets settings.hiDPI */
  int32_t max_horizontal_pixels; /* the chip budget it was judged against, floored at 1 */
  int32_t pixel_width;           /* the backing framebuffer, points x scale */
  int32_t pixel_height;
  bool exceeds_pixel_limit;      /* over budget: do NOT create the display, fall back to 1x */
} SlopDeskVirtualDisplayGeometry;

typedef struct {
  double width;   /* millimetres */
  double height;
} SlopDeskVirtualDisplaySize;

typedef struct {
  double x;
  double y;
} SlopDeskVirtualDisplayOrigin;


/* The physical size to advertise for a target density. `target_ppi` is floored at 1.0 by an ORDERED
 * comparison, so a NaN takes the floor rather than propagating; the division and the multiplication
 * stay separate and left-to-right, because `virtualDisplayGeometry` pins both as bit patterns. */

/* Flush RIGHT of every display in `displays`, at y = 0 — the placement that can never overlap a
 * real display. `displays` is 4 * display_count doubles: x, y, width, height per display.
 *
 * Pass each rect's RAW stored fields (`origin.x`, `size.width`), NOT `CGRect.width` — the far side
 * standardises, and pre-abs'ing an extent while keeping the raw origin would move the right edge.
 * The fold updates only on a strict `<`, so a tie keeps the FIRST display; an empty or NULL list
 * answers the origin. */

/* The chip's horizontal framebuffer budget, from `machdep.cpu.brand_string`. Pro/Max/Ultra is
 * tested BEFORE the bare "apple m" prefix, so "Apple M1 Max" is the wide budget. An unknown or
 * absent brand answers the PERMISSIVE one — an over-budget create still fails safe through the
 * `displayID == 0` guard, where an over-strict limit refuses a display that would have worked. */

/* The refresh modes to advertise for a capture source feeding an `fps` encode, descending: the
 * 60 + 30 baseline, the capped 2:1 oversample that keeps the capture from beating against the
 * commit, and the window's own rate when it exceeds 60.
 *
 * Writes into `out` only when `capacity` holds the WHOLE answer, and always returns how many rates
 * the rule produced. A return above `capacity` means nothing was written — the order is part of the
 * answer, so a truncated read is a wrong one; re-call with a buffer of the returned size. */

/* ---- What content size a window OPENS at, and where it lands ----------------------------
 * The sibling of the placement above, for the client's own window rather than a remoted one.
 * Numbers in, numbers out — the only pointer is the saved descriptor's text.
 *
 * Two disciplines: validate-then-clamp (a persisted 0 / negative / five-figure value can never
 * become a 0x0 or off-screen-gigantic window, and a corrupt descriptor yields NO answer rather
 * than a degenerate rect), and ORDERED comparisons (a NaN font size or extent propagates instead
 * of being swallowed by a NaN-ignoring minimum — the same spelling as the placement above).
 *
 * A rectangle arrives as the four scalars the caller derived from it, never as a rect: `CGRect`
 * standardises its extents and `CGSize` does not, and that asymmetry stays with those types.   */

#define SLOPDESK_WINDOW_SIZE_MODE_REMEMBER 0u
#define SLOPDESK_WINDOW_SIZE_MODE_GRID     1u
#define SLOPDESK_WINDOW_SIZE_MODE_FRAME    2u

typedef struct { double width, height; } SlopDeskWindowExtent;
typedef struct { double width, height; bool present; } SlopDeskWindowContentSize;
typedef struct { double x, y; } SlopDeskWindowUnitPoint;

typedef struct {
  int32_t min_cells, max_cells;               /* the column / row band */
  int32_t min_px, max_px;                     /* the pixel band */
  double  min_content_width, min_content_height;
  double  fallback_cell_width_ratio, fallback_cell_height_ratio;
  double  min_font_point_size, max_font_point_size;
} SlopDeskWindowSizeLimits;

typedef struct {
  uint8_t mode;                 /* SLOPDESK_WINDOW_SIZE_MODE_*; an unknown code sizes nothing */
  int32_t cols, rows;           /* persisted counts, UNCLAMPED — the far side clamps */
  int32_t width_px, height_px;  /* persisted pixels, UNCLAMPED */
  double  cell_width, cell_height;         /* the live per-cell advance */
  double  visible_width, visible_height;   /* the screen's visible extent, already standardised */
  double  chrome_inset_width, chrome_inset_height;       /* out-of-content: title bar, borders */
  double  chrome_overhead_width, chrome_overhead_height; /* in-content: sidebar, inspector, inset */
} SlopDeskWindowSizeInputs;

typedef struct {
  double frame_x, frame_y, frame_width, frame_height;
  double screen_x, screen_y, screen_width, screen_height;
  bool   present;               /* false leaves every field zero — nothing may be sized from it */
} SlopDeskWindowFrameDescriptor;

SlopDeskWindowSizeLimits slopdesk_window_size_limits(void);
int32_t slopdesk_window_size_clamp_cells(int32_t raw);
int32_t slopdesk_window_size_clamp_px(int32_t raw);
SlopDeskWindowExtent slopdesk_window_size_fallback_cell(double font_point_size);
SlopDeskWindowExtent slopdesk_window_size_grid(int32_t cols, int32_t rows,
                                               double cell_width, double cell_height);
SlopDeskWindowExtent slopdesk_window_size_clamp_to_screen(double width, double height,
                                                          double visible_width,
                                                          double visible_height,
                                                          double chrome_width,
                                                          double chrome_height);
SlopDeskWindowContentSize slopdesk_window_size_resolved(SlopDeskWindowSizeInputs inputs);
SlopDeskWindowUnitPoint slopdesk_window_size_unit_position(double frame_min_x, double frame_max_y,
                                                           double frame_width, double frame_height,
                                                           double screen_min_x, double screen_max_y,
                                                           double screen_width,
                                                           double screen_height);
SlopDeskWindowFrameDescriptor slopdesk_window_size_parse_frame(const uint8_t *text, size_t len);

/* The off-screen window rescue, driven one step at a time: every effect it needs suspends on the
 * near side, and no C ABI can call back into that and wait. `step` is both what to do next and
 * where the rescue is — no two stages ask for the same step, so nothing else has to cross. No
 * window handle does either: the caller keeps the two it might mint from and this side names
 * which. */
#define SLOPDESK_MINT_STEP_FULL_LIST      0u
#define SLOPDESK_MINT_STEP_DEMINIATURIZE  1u
#define SLOPDESK_MINT_STEP_POLL_FULL      2u
#define SLOPDESK_MINT_STEP_POLL_ON_SCREEN 3u
#define SLOPDESK_MINT_STEP_REFUSE         4u
#define SLOPDESK_MINT_STEP_MINT_TARGET    5u
#define SLOPDESK_MINT_STEP_MINT_SIGHTED   6u

#define SLOPDESK_MINT_SAW_NOTHING       0u
#define SLOPDESK_MINT_SAW_WINDOW        1u
#define SLOPDESK_MINT_SAW_DEMINIATURIZE 2u

#define SLOPDESK_MINT_NOT_MINIMIZED 0u
#define SLOPDESK_MINT_RESTORING     1u
#define SLOPDESK_MINT_FAILED        2u

typedef struct {
  uint32_t step;
  uint32_t polls_left;
  double   prior_x;
  double   prior_y;
  double   prior_width;
  double   prior_height;
  bool     has_prior;            /* an absent frame is not a frame of zeroes */
} SlopDeskMintRescue;


typedef struct {
  uint16_t fire_travel;
  bool eligible;
  bool slow_tier;
  bool can_go_back;
  bool can_go_forward;
  bool history_known;
} SlopDeskSwipeNavStatus;

/* The client's PEEL mirror of the same law: the edge chip's state, driven from the same event
 * stream the host's injector reads. It folds by value for the reason the recogniser does — it IS
 * the recogniser, plus what the chip is doing. */

#define SLOPDESK_PEEL_IDLE 0u
#define SLOPDESK_PEEL_SHOW 1u
#define SLOPDESK_PEEL_COMMIT 2u
#define SLOPDESK_PEEL_RETRACT 3u

typedef struct {
  double progress_quantum;
  double show_travel_fraction;
  /* How long a committed chip is held after the mirror fires, in seconds — the beat where the
   * host's chord lands and the navigated-to page streams in. Both clients hold it; neither spells
   * it, because a Mac holding a fire for one length and a phone for another would be two answers
   * to "how long does a fire stay acknowledged". */
  double confirm_hold_seconds;
} SlopDeskPeelConstants;

typedef struct {
  SlopDeskSwipeRecognizer recognizer;
  double                  show_travel;
  double                  glass_progress;
  uint32_t                shown_direction;
  bool                    showing;
  bool                    has_shown_direction;
} SlopDeskPeelPlanner;

typedef struct {
  SlopDeskPeelPlanner planner;
  double              progress;
  uint32_t            verdict;
  uint32_t            direction;
  bool                committed;
  bool                confirming;
} SlopDeskPeelIngest;

SlopDeskPeelConstants slopdesk_peel_constants(void);
SlopDeskPeelPlanner   slopdesk_peel_new(double fire_travel, bool slow_swipe);
SlopDeskPeelIngest    slopdesk_peel_ingest(SlopDeskPeelPlanner planner, double dx, double dy,
                                           uint8_t scroll_phase, uint8_t momentum_phase,
                                           bool continuous, double now);
SlopDeskPeelIngest    slopdesk_peel_cancel(SlopDeskPeelPlanner planner);
uint32_t              slopdesk_peel_history_gated(uint32_t verdict, uint32_t direction,
                                                  SlopDeskSwipeNavStatus status);

size_t slopdesk_swipe_nav_status_encode(SlopDeskSwipeNavStatus status, uint8_t *out, size_t cap);
uint32_t slopdesk_swipe_nav_status_decode(const uint8_t *bytes, size_t len,
                                          SlopDeskSwipeNavStatus *out);
/* direction: 0 back, anything else forward. */
bool slopdesk_swipe_nav_allows_chip(SlopDeskSwipeNavStatus status, uint8_t direction);
size_t slopdesk_swipe_nav_constant(uint8_t index);

/* ---------------------------------------------------------------------------- *
 * The video host's whole `SLOPDESK_*` OPERATING POINT — every default, every clamp, and the
 * precedence between the pacing keys, resolved once per process.
 *
 * TWO calls, because only the middle step is the caller's business. `_gate_keys` hands over the
 * NAMES, `\0`-separated with no trailing separator; the caller resolves each through its own
 * overlay-aware lookup (env then settings — `docs/58`, a lookup rule and not a gate rule); then
 * `_host_gates` takes the resolved texts back as a blob list, IN KEY ORDER, and answers the lot.
 *
 * An unset key is an ABSENT blob, not an empty one, and the difference is load-bearing: two of
 * these gates test PRESENCE (`SLOPDESK_VIDEO_DEBUG`, `SLOPDESK_INPUT_TRACE`), so `=0` turns them
 * ON, and a third is overridden by the mere presence of a sibling whose value never parses.
 *
 * The three scalars are the inputs no key carries — the injector's resampler state, which the
 * scroll coalescer's default follows, and the keepalive window the silence pause is clamped into.
 * Answers false and writes nothing on a blob that is not a blob list or an entry that is not UTF-8.
 * ---------------------------------------------------------------------------- */

typedef struct {
  bool debug_stderr;
  bool interleave_transmit;
  bool pace_send;
  bool pacing_adaptive;
  bool send_lane_enabled;
  bool backpressure_enabled;
  bool scroll_coalesce_enabled;
  bool fps_governor_enabled;
  bool in_place_resize_enabled;
  bool kf_dup;
  bool small_dup;
  bool nack_enabled;
  bool recovery_idr_v2;
  bool telemetry_enabled;
  bool abr_enabled;
  bool adaptive_fec_enabled;
  bool full_range;
  bool ltr_enabled;
  bool input_trace;
  bool dialog_expand_enabled;
  bool fec_disabled;
  uint64_t pace_gap_nanos;
  double pace_rate_multiplier;
  int64_t kf_pace_floor_bps;
  int64_t delta_pace_floor_bps;
  int64_t backpressure_depth;
  double scroll_inject_interval;
  double kf_dup_loss_threshold;
  int64_t small_dup_max_bytes;
  int64_t retransmit_ring_frames;
  int64_t retransmit_ring_max_bytes;
  double recovery_dedup_window;
  double client_silence_pause_seconds;
} SlopDeskVideoHostGates;


/* ---------------------------------------------------------------------------- *
 * The CLIENT's pointer and gesture policies. Every rule here belongs to a view that is never
 * instantiated in a test — no Metal, no VT — so each one is asked here instead.
 *
 * The two stateful ones cross BY VALUE, unlike the denylist below: their owner is a SwiftUI view,
 * which the framework copies whenever it pleases, and a handle it copied would be one accumulator
 * shared by two gestures. So each door answers the new state beside its verdict.
 * ---------------------------------------------------------------------------- */

bool slopdesk_gesture_forwards_pointer(bool is_active, bool background_pointer);
bool slopdesk_gesture_background_click(bool background_pointer, bool window_is_key);

typedef struct {
  double residual;
} SlopDeskPinchPlanner;

typedef struct {
  SlopDeskPinchPlanner state;
  int32_t steps;
} SlopDeskPinchPlan;

SlopDeskPinchPlanner slopdesk_pinch_planner_new(void);
SlopDeskPinchPlan    slopdesk_pinch_planner_plan(SlopDeskPinchPlanner state, double magnification);

typedef struct {
  bool remote;
  bool has_pin;
} SlopDeskScrollPin;

typedef struct {
  SlopDeskScrollPin state;
  bool remote;
} SlopDeskScrollRoute;

SlopDeskScrollPin   slopdesk_scroll_pin_new(void);
SlopDeskScrollRoute slopdesk_scroll_pin_route(SlopDeskScrollPin state, bool live_remote,
                                              uint8_t scroll_phase, uint8_t momentum_phase);

/* The zoom-reset denylist IS a handle, for the swipe-nav config's reason: a runtime extension set,
 * owned by a process-lifetime namespace that never copies it. A NULL app name is a desktop pane,
 * which fails OPEN — it streams a display whose frontmost app the client cannot know. */
typedef struct SlopDeskZoomResetPolicy SlopDeskZoomResetPolicy;

SlopDeskZoomResetPolicy *slopdesk_zoom_reset_policy_parse(const uint8_t *raw, size_t len);
void slopdesk_zoom_reset_policy_free(SlopDeskZoomResetPolicy *handle);
bool slopdesk_zoom_reset_allowed(const SlopDeskZoomResetPolicy *handle, const uint8_t *app_name,
                                 size_t name_len);

/* ---------------------------------------------------------------------------- *
 * The PHONE's half of the same seam: a finger on a remote DESKTOP.
 *
 * The two sibling mirror surfaces forward touch as touch — a finger on the mirror IS the finger. A
 * desktop is the opposite case: there is no touch to inject, only a POINTER, so the whole vocabulary
 * is SYNTHESIZED (tap = click, long press = right click, one-finger drag = left drag, two fingers at
 * 1× = a host scroll at the centroid, two fingers while zoomed = a local pan, a pinch = a local
 * zoom). None of it may be written inside a `touchesMoved` no test can reach — the iOS video surface
 * is a `CAMetalLayer` over a VideoToolbox decoder, and hang-safety keeps it out of XCTest entirely.
 *
 * These are §4's entries that take no memory at all: every argument a scalar, every answer by value,
 * no buffer to size and no return code to read. The seven numbers of the vocabulary cross through
 * ONE index-shaped door rather than seven of their own, since each is read once into a `static let`.
 * ---------------------------------------------------------------------------- */

// touch_constant index: 0 tap slop (pt), 1 long-press delay (s), 2 pinch span slop (pt), 3 pair
// travel slop (pt), 4 minimum zoom, 5 maximum zoom, 6 zoom step. An index nobody defined answers 0,
// which the family cannot hold — every one of these is a positive distance, delay or scale.
double slopdesk_touch_constant(uint8_t index);

// Squared inside, so no square root sits in a 120 Hz touch path.
bool slopdesk_touch_escapes_tap_slop(double dx, double dy);

#define SLOPDESK_TOUCH_ROUTE_ZOOM   0u
#define SLOPDESK_TOUCH_ROUTE_PAN    1u
#define SLOPDESK_TOUCH_ROUTE_SCROLL 2u

// `decided` is false while the pair is still under its slop, and that is a FLAG rather than a fourth
// route byte for §4's reason: every value of `route` is a route, so none of them could have meant
// "nothing has been decided yet" — and while nothing has, the gesture must send NOTHING, since a
// two-finger REST that scrolled the remote document is the failure the slop exists for.
typedef struct {
  uint8_t route;
  bool    decided;
} SlopDeskTouchPairRoute;

// Span BEATS travel: a pinch always drags its centroid a little, and misreading that as a scroll
// sends the remote document flying. `zoom` is the viewport's current client zoom — at 1× there is
// nothing to pan, so a translating pair can only mean a host scroll.
SlopDeskTouchPairRoute slopdesk_touch_classify_pair(double span_delta, double centroid_travel,
                                                    double zoom);

// `span_ratio` is `current_span / base_span`; a non-finite or non-positive one — a degenerate pair,
// both contacts on the same pixel — holds the base rather than sending a NaN to the UV crop.
double  slopdesk_touch_pinched_zoom(double base, double span_ratio);
double  slopdesk_touch_stepped_zoom(double zoom, bool step_in);
// Clamps to the ladder and SNAPS to exactly 1× near unity, so repeated − steps settle on actual size
// instead of stopping at 1.024× forever.
double  slopdesk_touch_clamp_zoom(double zoom);
// The renderer's UV crop travels 0.5·(1 − 1/zoom) each way. Clamped HERE and not in the shader: a pan
// the input encoder clamps and the renderer does not is a click that lands somewhere the user is not
// looking. At 1× the limit is 0, so the crop is pinned centred.
double  slopdesk_touch_clamp_pan(double pan, double zoom);
// 1 began, 2 changed, 4 ended. The phone has no `mayBegin` and no momentum tail, so a lift ENDS the
// host's gesture rather than inventing an inertia the finger never threw.
uint8_t slopdesk_touch_scroll_phase(bool is_first, bool is_last);
// The trackpad's half of the entry above, for the field CoreGraphics calls the SCROLL phase. The
// AppKit mask crosses as its raw bits rather than as a case index, because an index would need a
// table on the Swift side and removing that table is the point: the ten platform codes were spelled
// in four places across two languages, and two of the four read different sets of them. A mask may
// carry several bits at once, so the gesture's own order decides — began, then changed, then ended,
// then cancelled, then may-begin. Anything else, `.stationary` and an empty mask included, is 0: a
// phase this side does not recognise replays as a plain wheel tick, never as a guess at an edge.
uint8_t slopdesk_cg_scroll_phase_code(uint32_t ns_phase);
// The same three edges for the MOMENTUM field, which encodes them differently — its end is 3, where
// the scroll field's is 4, because one is an ordinal and the other a bit set. A separate entry and
// not a flag argument: a single entry whose answer depended on getting a "which field" flag right
// would be the same mistake wearing the boundary's clothes. An inertial tail has no cancel and no
// may-begin, so those masks answer 0 here rather than crossing over to the other table.
uint8_t slopdesk_cg_momentum_phase_code(uint32_t ns_phase);
// Floored at 1 and SATURATING at 255: the platforms count consecutive taps without bound, the host
// reads this only as a click-state hint, and trapping would be a crash on a very fast tapper.
uint8_t slopdesk_touch_click_count(int64_t tap_count);

/* An INDIRECT POINTER — an iPad with a trackpad or a mouse — reports its buttons as a MASK on every
 * event, not as an edge. A client that forwarded the level rather than the edge either never
 * presses or never releases, and a button left down outlives the pane on a host whose event source
 * is process-global. So the client DIFFS, and the diff lives here.
 *
 * The bit INDEX of each set is the wire's own MouseButton ordinal (left 0, right 1, other 2), so a
 * caller walks the set with a shift rather than a table. Every button UIKit does not name — middle,
 * thumb, a tenth on a gaming mouse — collapses onto `other`, because the wire has three buttons and
 * dropping the unmapped ones would make a paste-on-middle-click silently do nothing. */
typedef struct {
  uint8_t pressed;
  uint8_t released;
  uint8_t held;
} SlopDeskPointerButtons;
// Stateless on purpose: the one byte of state stays with the caller, so this has no handle and no
// lifetime — it would otherwise be the only thing on this floor with one. Feeding it the SAME mask
// twice answers "nothing changed", which is what makes it safe to call from a move as well as a
// press: UIKit reports the mask on every event of a gesture, and a button pressed mid-drag arrives
// on a touchesMoved.
SlopDeskPointerButtons slopdesk_pointer_button_transitions(uint8_t held, uint32_t ui_button_mask);
// A FOURTH encoding of the same three edges, after the AppKit mask, the two CoreGraphics fields and
// the phone's (is_first, is_last) pair — this one a UIGestureRecognizer.State ordinal, for the
// scroll-pan recogniser an iPad trackpad drives. A cancelled or failed recogniser ENDS rather than
// cancelling, deliberately: the host has one replay for a finished gesture and none for an abandoned
// one, and sending a phase it cannot replay would leave the remote gesture open until the next
// scroll closed it. `possible` answers 0 — nothing recognised yet is a wheel tick, never a guess.
uint8_t slopdesk_scroll_phase_for_gesture_state(uint8_t state);

/* ---------------------------------------------------------------------------- *
 * The host's swipe-nav OPERATING POINT: one parse of the SLOPDESK_SWIPE_NAV* family, shared by the
 * path that fires the chord and by the status push that tells the client what the host will
 * actually do. Two parses could drift, and then the feedback LIES — a committed chip and its haptic
 * for a fire the host silently swallows.
 *
 * A HANDLE, not a record: it holds an allowlist EXTENSION read out of the environment, which no
 * fold of scalars can carry. That is safe here because its owner is a process-lifetime namespace
 * that never copies it — a handle is the wrong shape exactly when something duplicates it.
 *
 * Every environment value is a (pointer, length) pair where NULL means UNSET, which is not the same
 * as empty: an empty string is a value a user can set, and the parse treats it as one. A value that
 * is not UTF-8 reads as unset, the default every switch here already answers to.
 *
 * The history read crosses as flags plus has_history. UNKNOWN is what makes the client fail open
 * rather than show a dark chip, so it is a presence flag and not any pair of bits.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskSwipeNavConfig SlopDeskSwipeNavConfig;


typedef struct {
  uint32_t seq;
  uint32_t host_send_ts_millis;
  uint32_t sample_rate;
  uint16_t span_offset;
  uint16_t span_length;
  bool is_config;
  uint8_t format;
  uint8_t channels;
} SlopDeskAudioMessage;

uint32_t slopdesk_audio_decode(const uint8_t *bytes, size_t len, SlopDeskAudioMessage *out);
size_t slopdesk_audio_encode(SlopDeskAudioMessage message, const uint8_t *span, size_t span_len,
                             uint8_t *out, size_t cap);
size_t slopdesk_audio_constant(uint8_t index);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_VIDEO_INPUT_H */
