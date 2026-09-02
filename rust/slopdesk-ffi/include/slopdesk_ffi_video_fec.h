// slopdesk_ffi_video_fec.h — the video path's forward error correction, and the host's bounded accumulators
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_VIDEO_FEC_H
#define SLOPDESK_FFI_VIDEO_FEC_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * The video path's forward error correction.
 *
 * A frame's fragments are a LIST, not a span, so they cross as one: a blob list is
 *
 *     u32 count | for each: u32 len | len bytes        (big-endian)
 *
 * where len == 0xFFFFFFFF marks a fragment that was lost in flight and carries no bytes. A
 * present-but-EMPTY fragment writes len == 0, which is a different thing: repairing one that was
 * never lost would corrupt the frame. Both calls answer with a blob list under §4's convention, so
 * a refusal is 0 and an empty answer is the four bytes of an empty list.
 *
 * The two answers do NOT mean the same thing. `parity` answers with the parity shards, all present.
 * `recover` answers with the REPAIRS: a list as long as the data list in which a fragment is
 * present only if this call is the reason it exists, so everything that arrived intact — and every
 * hole the code could not close — comes back absent. A single-loss frame is therefore one shard and
 * a run of four-byte absences, not a copy of the whole frame the caller just passed in. Arguments
 * are copied rather than described for a reason worth reading before changing it: docs/55 §4d.
 * ---------------------------------------------------------------------------- */

size_t slopdesk_video_fec_parity(size_t k, size_t m, size_t group_size, const uint8_t *data,
                                 size_t data_len, uint8_t *out, size_t cap);
size_t slopdesk_video_fec_recover(size_t k, size_t m, size_t group_size, const uint8_t *data,
                                  size_t data_len, const uint8_t *parity, size_t parity_len,
                                  uint8_t *out, size_t cap);

/* ---------------------------------------------------------------------------- *
 * The recovery channel: what the client says when it loses a frame, and when it stops asking.
 *
 * The message crosses FLAT, not as a tagged union. Six arms, one of them variable-length; a C union
 * would have to be kept in step with the Rust enum by hand on BOTH sides, which is the drift this
 * port removes. So every arm's fields sit beside each other with a type byte over them, and reading
 * a field an arm does not carry is a caller error the type byte already names.
 *
 * The NACK indices need no second call: the codec caps them at slopdesk_recovery_constant(1), so a
 * buffer that size can never be told to ask again. They land during the one decode and frag_count
 * says how many are real. A NULL frags buffer still parses and still counts.
 *
 * `decode` answers TRUNCATED or MALFORMED, writing nothing, for a short body or for an unknown
 * type, a NACK over the cap or TRAILING bytes. The two are told apart because the caller's own
 * vocabulary tells them apart; the malformed REASON does not cross, being diagnostic only. The
 * trailing-bytes rejection is load-bearing rather than fastidious: the
 * host's request deduper keys on the RAW datagram bytes, so a decoder tolerating suffixes would let
 * suffix-varied copies of one logical request each decode identically and each bypass the dedup,
 * firing a second refresh or IDR. `encode` returns 0 for a type byte no arm answers to.
 *
 * The loss window crosses as a PLAIN ARRAY, because a ring of timestamps is data. The caller keeps
 * the array and this side keeps the law: `note` answers the ring that pruning and the capacity drop
 * leave behind, `observing` reads one without touching it. Nothing is owned across the boundary and
 * no shape has to be mirrored here.
 *
 * `constant(index)`: 0 the no-frame-decoded sentinel · 1 the NACK fragment cap · 2 the redundancy
 * copy cap.
 * ---------------------------------------------------------------------------- */

typedef struct {
  uint32_t stream_seq;
  uint32_t from_frame_id;
  uint32_t to_frame_id;
  uint32_t last_decoded_frame_id;
  uint32_t frame_id;
  uint32_t frames_received;
  uint32_t fec_recovered;
  uint32_t unrecovered;
  uint32_t latest_host_send_ts;
  uint32_t client_hold_ms;
  uint32_t owd_jitter_micros;
  uint32_t owd_trend_milli;
  uint32_t owd_trend_flags;
  uint32_t pacer_late_frames;
  uint32_t pacer_present_gaps;
  uint32_t pacer_depth;
  uint16_t frag_count;
  uint16_t shape_id;
  uint8_t message_type;
} SlopDeskRecoveryMessage;

uint32_t slopdesk_recovery_constant(uint8_t index);
size_t slopdesk_recovery_encode(const SlopDeskRecoveryMessage *message, const uint16_t *frags,
                                uint8_t *out, size_t cap);
#define SLOPDESK_RECOVERY_DECODE_OK 0u
#define SLOPDESK_RECOVERY_DECODE_TRUNCATED 1u
#define SLOPDESK_RECOVERY_DECODE_MALFORMED 2u

uint32_t slopdesk_recovery_decode(const uint8_t *bytes, size_t len, SlopDeskRecoveryMessage *out,
                                  uint16_t *frags, size_t frags_cap);

/* ----------------------------------------------------------------------------
 * ROUTING one raw recovery datagram: the guard, the decode and the arm, once.
 *
 * The guard ORDER is the rule and not an implementation detail — a session that
 * is not streaming ignores the datagram BEFORE any decode, so a hostile packet
 * is never parsed on a session that is not even up. An undecodable one drops.
 *
 * The verdict is flat because a C enum with a payload is not a thing: only the
 * fields the returned code names carry meaning and the rest are zero. `shape_id`
 * is widened from the wire's uint16_t so the record is sixteen words with no
 * interior padding for this header to have to transcribe, and the bool lands
 * LAST for the same reason.
 *
 * The frontier arrives on the wire carrying a no-frame-decoded sentinel and
 * leaves here as a value plus a flag, so the near side never learns the sentinel.
 *
 * Fragment indices land in `frags` on the retransmit arm, and `frag_count` says
 * how many the request names WHETHER OR NOT they fit — an over-cap request
 * leaves the buffer untouched, still answers arm 7, and still reports the count,
 * which is this header's retry at the width of an index. It never travels: the
 * codec caps a NACK at `slopdesk_recovery_constant(1)`. A NULL `frags` still
 * routes and still counts.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_RECOVERY_ROUTE_IGNORE_NOT_STREAMING 0u
#define SLOPDESK_RECOVERY_ROUTE_DROP 1u
#define SLOPDESK_RECOVERY_ROUTE_FORCE_KEYFRAME 2u
#define SLOPDESK_RECOVERY_ROUTE_REFRESH_LTR 3u
#define SLOPDESK_RECOVERY_ROUTE_ACK 4u
#define SLOPDESK_RECOVERY_ROUTE_RESHIP_CURSOR_SHAPE 5u
#define SLOPDESK_RECOVERY_ROUTE_NETWORK_STATS 6u
#define SLOPDESK_RECOVERY_ROUTE_RETRANSMIT_FRAGMENTS 7u

typedef struct {
  uint32_t frontier;
  uint32_t stream_seq;
  uint32_t shape_id;
  uint32_t frame_id;
  uint32_t frag_count;
  uint32_t frames_received;
  uint32_t fec_recovered;
  uint32_t unrecovered;
  uint32_t latest_host_send_ts;
  uint32_t client_hold_ms;
  uint32_t owd_jitter_micros;
  uint32_t owd_trend_milli;
  uint32_t owd_trend_flags;
  uint32_t pacer_late_frames;
  uint32_t pacer_present_gaps;
  uint32_t pacer_depth;
  bool has_frontier;
} SlopDeskRecoveryDecision;

double slopdesk_recovery_escalation_floor_seconds(const uint8_t *raw, size_t len);
bool slopdesk_recovery_should_escalate_to_idr(double idr_timeout_rtt_multiple,
                                              double lossy_idr_timeout_rtt_multiple,
                                              double lossy_escalation_floor,
                                              double lossy_escalation_floor_rtt_multiple,
                                              double elapsed_since_request, double rtt,
                                              bool observing_loss);
/* One client's forced-IDR escalation episode, crossing as a VALUE.
 *
 * Two optionals and nothing else, so there is no handle to own: the caller keeps the value and each
 * door answers the value that follows from it. A payload whose `has_` flag is false is not a
 * reading — it is zero, and reading it anyway is a caller error the flag already named. */
typedef struct {
  double   first_request_time;
  uint32_t max_lost_frame_id;
  bool     has_first_request;
  bool     has_max_lost;
} SlopDeskLtrEscalation;

/* A non-keyframe decode fed to the episode: the value that follows, and whether it CLOSED it. */
typedef struct {
  SlopDeskLtrEscalation state;
  bool                  cleared;
} SlopDeskLtrEscalationDecode;

SlopDeskLtrEscalation slopdesk_ltr_escalation_clear(void);
SlopDeskLtrEscalation slopdesk_ltr_escalation_note_loss(SlopDeskLtrEscalation state,
                                                        uint32_t frame_id);
SlopDeskLtrEscalation slopdesk_ltr_escalation_note_request_sent(SlopDeskLtrEscalation state,
                                                                double now);
SlopDeskLtrEscalation slopdesk_ltr_escalation_note_escalated(SlopDeskLtrEscalation state,
                                                             double now);
SlopDeskLtrEscalationDecode slopdesk_ltr_escalation_frame_decoded(SlopDeskLtrEscalation state,
                                                                  uint32_t frame_id);
bool slopdesk_ltr_escalation_should_escalate(SlopDeskLtrEscalation state,
                                             double idr_timeout_rtt_multiple,
                                             double lossy_idr_timeout_rtt_multiple,
                                             double lossy_escalation_floor,
                                             double lossy_escalation_floor_rtt_multiple, double now,
                                             double rtt, bool observing_loss);
size_t slopdesk_recovery_send_offsets(size_t copies, double spacing, double *out, size_t cap);
size_t slopdesk_recovery_clamped_copies(size_t copies);
double slopdesk_recovery_all_copies_lost_probability(double per_datagram_loss, size_t copies);
double slopdesk_recovery_expected_request_loss_freeze(double per_datagram_loss, size_t copies,
                                                      double escalation_delay);
/* The host frameQueue timer's decision: re-encode the cached buffer as a forced keyframe?
 *
 * The decider's whole state is the first four doubles, so it crosses as scalars rather than as a
 * handle — there is nothing to own across the call. `0.0` is the "never happened" sentinel for both
 * anchors, and it is NOT a time: an anchor of zero means no such encode has occurred, never one at
 * time zero.
 *
 * `quiet_window` defaults to `heartbeat` on the Rust side; a caller with no separate window passes
 * `heartbeat` twice. */
/* Rewrites the ring IN PLACE: `events` is both the `count` timestamps held and the `cap` slots the
 * answer may use. Returns the new length; `cap` too small leaves the buffer untouched. */
size_t slopdesk_recovery_loss_window_note(double window_seconds, size_t capacity, double *events,
                                          size_t count, double now, size_t cap);
bool slopdesk_recovery_loss_window_observing(double window_seconds, size_t min_events,
                                             const double *events, size_t count, double now);

/* ---------------------------------------------------------------------------- *
 * The FEC ladder: measured loss becoming the per-frame redundancy both ends agree on.
 *
 * Not a handle, even though the tier decision looks stateful: the state IS the answer, so it
 * crosses by value — one SlopDeskFecTierState in, one out. Three scalars are cheaper to copy than a
 * handle is to own, and a value the host keeps in its own session struct cannot drift from a
 * counter living somewhere else.
 *
 * `group_size` answers false, writing nothing, for the OFF tier that carries no parity — the
 * absence is the return value and not a reserved size because EVERY size is legal here, including
 * the 0 a caller may pass as its own default. It is TOTAL over every uint8_t: a tier read off a
 * corrupt fragment must never trap, and a reserved value falls back to the caller's default.
 *
 * The two `resolve_*` calls take the RAW environment strings because the lookup is the app's —
 * Swift's EnvConfig reads the process environment and the settings overlay a GUI toggle writes —
 * while what the string MEANS (parse, default, clamp, the joint k + m <= 255 field bound) is the
 * codec's. A missing variable and an unparseable one answer the same, so absence needs no flag:
 * pass (NULL, 0). `resolve_group_size` takes both strings because the bound is joint.
 *
 * `constant(index)` vends the ladder's numbers so neither end writes one the other also writes:
 * 0 default tier · 1/2/3 the parity tiers CLEAN/NORMAL/BURST · 4 relax dwell reports · 5 the
 * sticky-relax window · 6 the multi-loss default k · 7/8 the m bounds · 9/10 the k bounds · 11
 * the multi-loss default m, which is NOT index 7: `M_MIN` answers "how low may a caller drive the
 * parity count", index 11 answers "what does a caller who has not chosen get". They are both 1
 * today, and that coincidence is exactly why the settings sheet had regrown its own literal.
 *
 * `multi_loss_active(m)` is the THRESHOLD rather than a bound — `m >= 2` is what changes the
 * parity count per group on the wire, selects the true [k + m, k] code over the XOR-equivalent
 * default, and is what `wire_tier`'s `multi_loss_active` argument is asking about. It is a door of
 * its own because the two bounds cannot stand in for it: `M_MIN` is 1, so a caller composing the
 * threshold out of `constant(7)`/`constant(8)` would answer "always active".
 * ---------------------------------------------------------------------------- */

typedef struct {
  uint32_t relax_streak;
  uint32_t sticky_relax_remaining;
  uint8_t tier;
} SlopDeskFecTierState;

uint32_t slopdesk_adaptive_fec_constant(uint8_t index);
bool slopdesk_adaptive_fec_group_size(uint8_t tier, size_t default_group_size, size_t *out);
uint8_t slopdesk_adaptive_fec_wire_tier(uint8_t adaptive_tier, bool adaptive_m_enabled,
                                        bool multi_loss_active);
uint8_t slopdesk_adaptive_fec_tier(double loss, uint8_t previous_tier, bool allow_off);
SlopDeskFecTierState slopdesk_adaptive_fec_next_tier_state(double loss, SlopDeskFecTierState state,
                                                           uint32_t dwell, bool allow_off,
                                                           bool saw_unrecovered_loss);
SlopDeskFecTierState slopdesk_adaptive_fec_next_parity_tier_state(double loss,
                                                                  SlopDeskFecTierState state,
                                                                  uint32_t dwell,
                                                                  bool saw_unrecovered_loss);
size_t slopdesk_adaptive_fec_resolve_parity_count(const uint8_t *raw, size_t len);
size_t slopdesk_adaptive_fec_resolve_group_size(const uint8_t *raw_k, size_t len_k,
                                                const uint8_t *raw_m, size_t len_m);
bool slopdesk_adaptive_fec_multi_loss_active(size_t parity_count);

/* ---------------------------------------------------------------------------- *
 * The video datagram codec: the 19-byte header, both directions.
 *
 * Not a handle — a datagram carries nothing forward, so the codec has no state to keep. Every
 * caller on either side reaches this one: the host's send path, the client's router (which reads
 * frameID and hostSendTsMillis off a datagram before it knows where the datagram goes) and the
 * golden generator.
 *
 * Decoding answers a header and an OFFSET, never a payload: the caller still holds the datagram it
 * just handed over, so copying the payload back would copy every byte of every frame a second time.
 * Slice your own buffer at `payload_offset` — the wire layout stays on this side, so no caller has
 * to spell 19.
 *
 * `decode` answers false — writing nothing — for a datagram too short to hold a header, or one
 * whose declared payload runs past its end, which is what a corrupt packet on an unauthenticated
 * socket looks like. A NULL `out` is inert: it still parses and still answers.
 *
 * `encode` takes no payload_length: the declared length comes from the payload, and the two cannot
 * disagree on the wire if only one of them exists. It returns bytes NEEDED, under §4's convention.
 * ---------------------------------------------------------------------------- */

typedef struct {
  uint32_t stream_seq;
  uint32_t frame_id;
  uint32_t host_send_ts_millis;
  uint16_t frag_index;
  uint16_t frag_count;
  uint16_t payload_length;
  uint8_t flags;
  uint8_t payload_offset;
} SlopDeskVideoFragmentHeader;

bool slopdesk_video_fragment_decode(const uint8_t *bytes, size_t len,
                                    SlopDeskVideoFragmentHeader *out);
size_t slopdesk_video_fragment_encode(uint32_t stream_seq, uint32_t frame_id, uint16_t frag_index,
                                      uint16_t frag_count, uint8_t flags,
                                      uint32_t host_send_ts_millis, const uint8_t *payload,
                                      size_t payload_len, uint8_t *out, size_t cap);
// A fragment size budget: 0 the header, 1 the whole datagram (the MTU claim), 2 the payload
// the two leave between them. Unknown index answers 0, which packetizes nothing.
size_t slopdesk_video_fragment_size(uint8_t index);

// Where the adaptive-FEC tier sits in the flags byte: 0 the shift, 1 the mask. Unknown index
// answers 0, which reads every frame as tier 0 — the plain wire.
uint8_t slopdesk_video_flags_tier_layout(uint8_t index);

/* ---------------------------------------------------------------------------- *
 * The three measurements the capture path takes on a frame it has just locked.
 *
 * These are the ONE family of entries that does not take bytes the caller owns. The pixels only
 * exist as an address inside a Core Video mapping, so a plane crosses as a base address and a row
 * stride, and the lock around the call is what `withUnsafeBytes` is everywhere else. The length is
 * `stride * rows`, computed with a checked multiply on the Rust side: an absurd stride is a defined
 * "no measurement", never a read past the mapping.
 *
 * hash_nv12 answers one 64-bit value per frame, over the VISIBLE bytes of each row only, so the
 * same picture hashes equal however the capture padded it. A null luma plane, a degenerate
 * dimension, a stride narrower than the width or an overflowing product answer the SENTINEL, which
 * slopdesk_video_frame_hash_sentinel vends rather than either side spelling it.
 *
 * scroll_nv12 and adaptive_qp_nv12 both compare two planes of the same picture, so they take the
 * pair as one value: two planes that may be padded differently, and the one width and height they
 * are both read at. An unmeasurable pair is a defined answer for each — a no-shift estimate whose
 * band is -1/-1, and the configured static ceiling with a zero change — and never a fault.
 *
 * The results come back BY VALUE rather than through an out pointer: each is four words or fewer,
 * so there is no buffer to size, nothing to write into and no §4 sizing call.
 * ---------------------------------------------------------------------------- */

typedef struct {
  const uint8_t *base;
  size_t stride;
} SlopDeskLumaPlane;

typedef struct {
  SlopDeskLumaPlane prev;
  SlopDeskLumaPlane cur;
  size_t width;
  size_t height;
} SlopDeskLumaPair;

typedef struct {
  int32_t shift;
  uint32_t confidence_milli;
  int32_t band_top;
  int32_t band_bottom;
} SlopDeskScrollEstimate;

typedef struct {
  uint8_t qp;
  uint32_t change_milli;
} SlopDeskQpDecision;

uint64_t slopdesk_video_frame_hash_sentinel(void);
uint64_t slopdesk_video_frame_hash_nv12(const uint8_t *y, size_t y_stride, size_t width,
                                        size_t height, const uint8_t *cbcr, size_t cbcr_stride);
SlopDeskScrollEstimate slopdesk_video_scroll_nv12(SlopDeskLumaPair pair, size_t max_shift,
                                                  uint8_t quantize_shift);
SlopDeskQpDecision slopdesk_video_adaptive_qp_nv12(SlopDeskLumaPair pair, uint8_t qp_sharp,
                                                   uint8_t qp_max, uint32_t b_lo_milli,
                                                   uint32_t b_hi_milli);

/* ---------------------------------------------------------------------------- *
 * Four pure policies with no state behind them: a colour matrix, a click, a buffer, a verdict.
 *
 * Like the frame measurements above, these answer BY VALUE — every argument and every result is a
 * scalar or a handful of them, so nothing here takes bytes the caller owns and there is no §4
 * sizing call.
 *
 * ycbcr_coefficients and coord_window_point are the two the golden corpus pins as raw IEEE bit
 * patterns, which is why they cross at all: a second implementation of either agrees with the first
 * until a compiler fuses a multiply and an add, and then a click lands a pixel off on one machine.
 * The multiply and the add stay separate on the Rust side, and every coefficient stays 32-bit end
 * to end — an f64 intermediate narrowed on the way out moves the low bits the corpus pins.
 *
 * playout_step_ms takes the caller's knobs already resolved from the environment and clamps each
 * into its band on the Rust side, so an absent or hostile knob cannot widen the buffer past its
 * ceiling. Jitter is in SECONDS; everything else is milliseconds, in and out.
 *
 * stall_verdict's two arrival stamps carry their own presence flag rather than a sentinel time,
 * because "no frame has EVER arrived" and "the last frame arrived at time zero" are different
 * states and only one of them can be a stall. Under idle_skip_active the host is suppressing frames
 * BY DESIGN, so only the heartbeat counts; otherwise the newer of the two does.
 * ---------------------------------------------------------------------------- */

typedef struct {
  float luma_scale;
  float luma_bias;
  float chroma_bias;
  float cr_to_r;
  float cb_to_g;
  float cr_to_g;
  float cb_to_b;
} SlopDeskYCbCrCoefficients;

typedef struct {
  double x;
  double y;
} SlopDeskVideoPoint;

typedef struct {
  double now;
  double last_frame_at;
  double last_heartbeat_at;
  double threshold;
  bool   has_frame;
  bool   has_heartbeat;
  bool   connected;
  bool   idle_skip_active;
} SlopDeskLiveness;

#define SLOPDESK_STREAM_LIVE 0u
#define SLOPDESK_STREAM_STALLED 1u
#define SLOPDESK_STREAM_NOT_CONNECTED 2u
#define SLOPDESK_STREAM_UNKNOWN 3u

SlopDeskYCbCrCoefficients slopdesk_ycbcr_coefficients(bool full_range);
SlopDeskVideoPoint slopdesk_coord_window_point(double normalized_x, double normalized_y,
                                               double bounds_x, double bounds_y,
                                               double bounds_width, double bounds_height);
double slopdesk_playout_step_ms(double jitter_seconds, double prev_playout_ms,
                                double shrink_step_ms, double k, double base_ms, double floor_ms,
                                double ceil_ms);
/* The playout law's own default for each knob, in the units the knobs are configured in: 0 the
 * dimensionless k, 1 base, 2 floor, 3 ceiling, 4 shrink step (the last four in ms). An unknown
 * index answers NaN, which the law already reads as "take the default". */
double slopdesk_playout_default_ms(unsigned char index);
uint32_t slopdesk_stream_stall_verdict(SlopDeskLiveness inputs);

/* The aspect geometry, and the virtual-display re-create throttle. The first two are pinned
 * bit-exactly: `view_point` is the exact inverse of the input encoder's normalise, so the cursor
 * overlay lands where the click does, and a contracted multiply-add on one side would move it. */

typedef struct {
  double width;
  double height;
} SlopDeskVideoSize;

typedef struct {
  double x;
  double y;
  double width;
  double height;
} SlopDeskVideoRect;

#define SLOPDESK_CONTENT_MODE_FIT 0u
#define SLOPDESK_CONTENT_MODE_FILL 1u

double slopdesk_geometry_intersection_area(SlopDeskVideoRect first, SlopDeskVideoRect second);
SlopDeskVideoRect slopdesk_geometry_displayed_video_rect(SlopDeskVideoSize view,
                                                         SlopDeskVideoSize video_native,
                                                         uint32_t mode);
SlopDeskVideoPoint slopdesk_geometry_view_point(SlopDeskVideoPoint host_point,
                                                SlopDeskVideoSize view,
                                                SlopDeskVideoSize video_native, double zoom,
                                                SlopDeskVideoPoint pan, uint32_t mode);

/* ---- The window record, and the two things decided over a list of them --------------------------
 *
 * The record is declared HERE, outside the macOS-only region, although only a macOS door ever fills
 * one: `slopdesk_cgwindow_in_front_of` answers an array of these and the `slopdesk_capture_*` doors
 * below consume it unchanged. Declaring the layout on both sides of the `TARGET_OS_OSX` guard is how
 * a field reorder ships as green tests and a scrambled capture region.
 *
 * The DECIDERS are portable because they decide rather than read: `golden/golden_vectors.json` pins
 * the union and the hysteresis gate as raw `f64` bit patterns, and that check runs wherever the
 * crate builds. */

typedef struct {
  SlopDeskVideoRect bounds; // CG global points, top-left origin
  uint32_t window_id;       // per-boot and reusable — names a window only with owner_pid
  int32_t owner_pid;        // the owning process
  int32_t layer;            // 0 an ordinary window, 101 a pop-up menu, 24 the menu bar
} SlopDeskWindowRecord;

// The display a window sits on: the one holding its CENTRE, else the LARGEST. false — there are no
// displays at all — leaves *out untouched, and the caller then reports the window's own size as its
// resize ceiling rather than a zero one nobody could resize to.

// DIALOG-EXPAND. `windows` is the front-to-back slice strictly IN FRONT of the target — exactly what
// slopdesk_cgwindow_in_front_of answers — and the region is the target frame ∪ every same-pid panel
// on an associatable layer that overlaps it enough, clamped to the display.
//
// The overlap fraction and the hysteresis delta do NOT cross: they are the crate's constants, and
// the one caller took both defaults, so carrying them over would have made a second place to change
// one.

// The OPAQUE pieces inside that region — the target, then each panel — so the client can mask the
// black flank BETWEEN them, which the bounding box cannot express. The answer is the count NEEDED.

// Whether a region change is worth acting on — every one is an encoder rebuild and an IDR.

// Whether a window MOVE should re-origin the input and cursor mapping to the plain window frame.
// The pair is this ABI's spelling of `CGRect?`: active_region is read only when region_active.

#define SLOPDESK_REGION_HOLD 0u
#define SLOPDESK_REGION_EXPAND 1u
#define SLOPDESK_REGION_CONTRACT 2u

// What a freshly measured union means for a capture currently at `current` — has_current false
// being the plain window frame. Answers one of the three SLOPDESK_REGION_* verdicts, and writes
// *out only for EXPAND. A null out cannot carry an expansion, so it is answered HOLD.

/* The cursor OVERLAY placement — bit-exact with `view_point` above, because the overlay must track
 * the same displayed pixel a click lands on at every zoom and in every letterbox. */
SlopDeskVideoRect slopdesk_cursor_layer_frame_scalar(SlopDeskVideoPoint position,
                                                     SlopDeskVideoPoint hotspot, double video_scale,
                                                     SlopDeskVideoSize cursor_size);
SlopDeskVideoRect slopdesk_cursor_layer_frame_fit(SlopDeskVideoPoint position,
                                                  SlopDeskVideoPoint hotspot,
                                                  SlopDeskVideoSize view,
                                                  SlopDeskVideoSize video_native, double zoom,
                                                  SlopDeskVideoPoint pan,
                                                  SlopDeskVideoSize cursor_size, uint32_t mode);
double slopdesk_cursor_bottom_left_origin_y(double top_left_y, double height, double parent_height);
bool slopdesk_cursor_is_placeable(SlopDeskVideoRect frame);
SlopDeskVideoSize slopdesk_cursor_rendered_shape_size(SlopDeskVideoSize logical,
                                                      SlopDeskVideoSize bitmap_pixels);

/* The `windowList` reply's arrangement: on-screen first, untitled off-screen entries dropped. The
 * windows never cross — the two flags do, and the answer is the caller's own indices. */


/* The keepalive timing contract, and the stall threshold it is sized against. ONE record, because
 * the six numbers are one argument: the stall threshold tolerates two lost host heartbeats, the
 * reaper tick is what makes the worst-case reclaim `idle_timeout + reaper_tick`, and the hello
 * deadline is how long a session that never connected keeps dialling before the client says so. */
typedef struct {
  double keepalive_interval;
  double idle_timeout;
  double reaper_tick;
  double host_heartbeat_interval;
  double stall_threshold;
  double hello_deadline;
} SlopDeskKeepaliveTiming;

SlopDeskKeepaliveTiming slopdesk_keepalive_timing(void);

/* ---------------------------------------------------------------------------- *
 * The host's four bounded accumulators: the LTR map, the dedup window, the idle reaper, the
 * retransmit ring.
 *
 * All four are HANDLES, and for the same reason: each holds something across many calls that the
 * near side almost never reads. The ring is the sharp case — it is MEGABYTES of sent datagrams and
 * a repair is the handful a client actually lost, so a selection reports the shape and one take
 * copies it out.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskLtrController SlopDeskLtrController;
typedef struct SlopDeskRecoveryDeduper SlopDeskRecoveryDeduper;
typedef struct SlopDeskIdleReaper SlopDeskIdleReaper;
typedef struct SlopDeskRetransmitRing SlopDeskRetransmitRing;

#define SLOPDESK_LTR_REQUEST_REFRESH 0u
#define SLOPDESK_LTR_REQUEST_IDR 1u
#define SLOPDESK_LTR_ACTION_REFRESH 0u
#define SLOPDESK_LTR_ACTION_IDR 1u

typedef struct {
  size_t frame_token_cap;
  size_t acknowledged_token_cap;
} SlopDeskLtrCaps;

typedef struct {
  double last_inbound;
  bool   saw_keepalive;
} SlopDeskFlowRecord;

typedef struct {
  double window_seconds;
  size_t capacity;
} SlopDeskRecoveryDedupeDefaults;

typedef struct {
  uint32_t offset;
  uint32_t length;
} SlopDeskByteSpan;

/* ---------------------------------------------------------------------------- *
 * cli — GONE. The `slopdesk` CLI is one Rust process now (`rust/slopdesk-cli`),
 * so its flags, its completion scripts, its help page, its tables and its
 * version banner cross no boundary at all: they are function calls inside the
 * binary that prints them. Nine doors, two records and fourteen constants left
 * with the Swift face they existed for. See docs/55 §"The CLI" and the module
 * doc of rust/slopdesk-cli/src/shell.rs.
 * ---------------------------------------------------------------------------- */

/* The grammar for one `keybind` line of the user's config. A parsed binding is a fixed record plus
 * three runs of variable-length bytes — the base key, the payload (a literal action's resolved
 * bytes, or a named action's id) and the argument — so it crosses as a record whose runs are
 * (offset, length) pairs into ONE arena the caller lends. Ask twice: once with a null arena to
 * learn `arena_len`, then again with that much room. A record whose runs did not fit comes back
 * `valid == false` — acting on a half-written payload would put bytes on a pane the user never
 * wrote. `has_arg` is a FLAG, not an empty run: the grammar refuses `goto_tab:`, so "no argument"
 * and "an empty one" are different answers and only one can arise. */

#define SLOPDESK_KEYBIND_TEXT   0u  /* text:<s> — the payload run is the literal bytes */
#define SLOPDESK_KEYBIND_CSI    1u  /* csi:<p>  — the payload run leads with ESC [ */
#define SLOPDESK_KEYBIND_ESC    2u  /* esc:<p>  — the payload run leads with ESC */
#define SLOPDESK_KEYBIND_NAMED  3u  /* a registry action; the payload run is its id */
#define SLOPDESK_KEYBIND_UNBIND 4u  /* unbind:<chord> — neither run carries anything */

typedef struct {
  uint32_t offset;
  uint32_t length;
} SlopDeskKeybindRun;

typedef struct {
  SlopDeskKeybindRun key;      /* the chord's base key, lowercased */
  SlopDeskKeybindRun payload;  /* the action's bytes, or a named action's id */
  SlopDeskKeybindRun arg;      /* meaningful only when `has_arg` */
  uint32_t kind;               /* one of SLOPDESK_KEYBIND_* */
  size_t   arena_len;          /* what the three runs need in total */
  bool     has_arg;
  bool     command;
  bool     shift;
  bool     option;
  bool     control;
  bool     valid;              /* false is the grammar's "drop this line" */
} SlopDeskKeybind;

SlopDeskKeybind slopdesk_keybind_parse_line(const uint8_t *line, size_t line_len,
                                            uint8_t *arena, size_t arena_cap);
bool slopdesk_keybind_is_valid(const uint8_t *line, size_t line_len);

/* ---- A config action NAME, as the binding id it rebinds ------------------------------------
 * The other half of a `keybind` line. `slopdesk_keybind_parse_line` above answers what the line
 * LOOKS like — a chord plus a named action; this answers which binding that action actually fires,
 * which is `slopdesk-workspace`'s registry rather than the grammar's. `0` is the refusal (an
 * unknown name, a `goto_tab` outside the nine per-digit bindings, or one of the three
 * libghostty-only responder actions that have no workspace action at all) and cannot collide with
 * an answer, because every id this vocabulary can name is a non-empty string. A zero-length or
 * NULL argument reads as NO argument: only `goto_tab` reads one, and `goto_tab:` is refused by the
 * grammar before it could ever reach here.                                                    */
size_t slopdesk_ws_binding_id_for_config_name(const uint8_t *name, size_t name_len,
                                              const uint8_t *arg, size_t arg_len,
                                              uint8_t *out, size_t cap);

/* The one spelling a base key is stored under, and the one text a chord is written with — the same
 * table that decides which spellings the grammar accepts. */
size_t slopdesk_keybind_canonical_key(const uint8_t *key, size_t key_len, uint8_t *out, size_t cap);
size_t slopdesk_keybind_canonical_chord(const uint8_t *key, size_t key_len, bool command, bool shift,
                                        bool option, bool control, uint8_t *out, size_t cap);
/* The same chord written for a HUMAN: the modifier glyphs in the platform's own order (⌃⌥⇧⌘) then
 * the key — a named key's printed symbol, or the key itself upper-cased, because a chord is stored
 * lower-cased with the shift in the modifiers and a menu prints ⌘D. */
size_t slopdesk_keybind_glyph(const uint8_t *key, size_t key_len, bool command, bool shift,
                              bool option, bool control, uint8_t *out, size_t cap);

/* What a fresh install's terminal carries, and the text a settings number is written with.
 *
 * The config-TEXT door that used to sit here is gone: it spelled a whole libghostty
 * `key = value` file for the deleted fork's `ghostty_config_load_string`, and the renderer that
 * replaced the fork takes the `slopdesk_term_surface_set_*` family below instead. Every run in that
 * record was a value already crossing through a typed door.
 *
 * Field indices for the two that remain — text: 0 family, 1 weight, 2 background, 3 foreground;
 * number: 0 point size, 1 cursor opacity, 2 scrollback lines. Ask twice for the text: a null `out`
 * reports the length, then lend that much. */
size_t slopdesk_terminal_factory_text(uint8_t field, uint8_t *out, size_t cap);
double slopdesk_terminal_factory_number(uint8_t field);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_VIDEO_FEC_H */
