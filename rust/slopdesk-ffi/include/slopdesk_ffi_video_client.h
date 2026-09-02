// slopdesk_ffi_video_client.h — what the client's decoder is shown, when, and how deep its queue may get
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_VIDEO_CLIENT_H
#define SLOPDESK_FFI_VIDEO_CLIENT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * The quantiser ladder's tuned defaults, and nothing else.
 *
 * This section used to carry the host's two admission laws — the quantiser fold and the recovery-IDR
 * policy handle. Both are the GUI video host's, and the host is `rust/slopdesk-videohostd` now, so
 * both folds run in-process against `slopdesk_video` with no door between (docs/61 §5). What is
 * left is the one thing a CLIENT still asks: the values every `SLOPDESK_QP_*` parse falls back TO,
 * so the client's own preferences hold no second copy of them.
 * ---------------------------------------------------------------------------- */

typedef struct {
  int32_t sharp;              /* the sharpest — lowest — quantiser on a clean link */
  int32_t coarse;             /* the coarsest, under sustained congestion */
  int32_t up_step;            /* the rise per congested report */
  int32_t down_interval;      /* clean reports per one-step sharpen */
} SlopDeskQpConfig;

/* The tuned defaults each knob's parse falls back TO, so the caller holds no copy of them. */
SlopDeskQpConfig  slopdesk_qp_config_default(void);


/* ---------------------------------------------------------------------------- *
 * The PRESENTATION DEPTH — the one-way-delay spike detector, and the policy that pays one frame of
 * standing latency for a spell of spikes and refunds it after a clean dwell.
 *
 * Both cross BY VALUE, state in and state out, because both are Swift structs their owners copy out,
 * fold into and write back. The RINGS travel with them, as fixed-capacity arrays, and that is the
 * whole design question here: a promote window, a demote dwell and the dense-flow gate all read
 * TIMES rather than counts — the question is never "how many lates" but "how many inside the last
 * second" — so a crossing that carried only the counters would be a different policy that agreed
 * only while nothing aged out. The capacities are the ones the folds themselves cap at, and
 * interval_ring_size is capped to the carried capacity when the state is rebuilt.
 *
 * The ENVIRONMENT is applied one pair at a time: the caller holds a whole map, the bands live here,
 * so the door takes a KEY and a VALUE and answers the config that results. An unknown key, an
 * unparseable value and a non-finite one all answer the config unchanged. Nine optional strings in
 * one call would have put the names on the near side, which is the same law written twice.
 *
 * slopdesk_pacer_depth_eq exists because a C array is a TUPLE on the Swift side and a tuple that
 * long has no equality — the one comparison the near side cannot spell for itself.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_GAP_CLASS_FIRST  0u  /* the first present, which has no gap to classify */
#define SLOPDESK_GAP_CLASS_NORMAL 1u
#define SLOPDESK_GAP_CLASS_LATE   2u  /* past the boundary, dense, and a sharp step up */
#define SLOPDESK_GAP_CLASS_IDLE   3u  /* a host idle-skip or a motion stop: never late */

/* The ring capacities the crossing carries. */
#define SLOPDESK_DEPTH_ARRIVAL_RING  16
#define SLOPDESK_DEPTH_INTERVAL_RING 15
#define SLOPDESK_DEPTH_LATE_RING     4

typedef struct {
  double bucket_ms;                    /* the baseline's bucket span; history is one to two */
  double threshold_floor_ms;           /* above the send lane's own pacing wobble */
  double threshold_interval_fraction;
  size_t warmup_samples;
} SlopDeskOwdLateConfig;

typedef struct {
  SlopDeskOwdLateConfig config;
  double unwrapped_send_ms;            /* monotone across the wire stamp's wrap */
  bool   has_prev_send_ts;
  uint32_t prev_send_ts;
  double current_bucket_min;
  double previous_bucket_min;
  bool   has_bucket_start;
  double bucket_start_arrival_ms;      /* the ARRIVAL clock: a content gap only stretches a bucket */
  size_t samples;
} SlopDeskOwdLate;

typedef struct {
  SlopDeskOwdLate detector;            /* what the caller writes back */
  bool   has_deviation;
  double deviation_ms;                 /* how far past the threshold the spike sat */
} SlopDeskOwdLateNote;

SlopDeskOwdLateConfig slopdesk_owd_late_config_default(void);
SlopDeskOwdLateConfig slopdesk_owd_late_config_apply(SlopDeskOwdLateConfig config,
                                                     const unsigned char *key, size_t key_len,
                                                     const unsigned char *value, size_t value_len);
SlopDeskOwdLate       slopdesk_owd_late_new(SlopDeskOwdLateConfig config);
SlopDeskOwdLateNote   slopdesk_owd_late_note(SlopDeskOwdLate detector, double arrival_ms,
                                             uint32_t send_ts, double interval_ms);

typedef struct {
  double late_gap_factor;
  double absolute_late_floor_seconds;
  double idle_gap_seconds;             /* above this a gap is idle, and never late */
  double gap_gradient_factor;
  size_t dense_min_arrivals;
  double dense_window_seconds;
  double late_slack_fraction;
  size_t promote_late_count;
  double promote_window_seconds;
  double demote_clean_seconds;
  double min_hold_seconds;             /* the anti-flap */
  size_t demote_tolerance_lates;
  double promote_warmup_seconds;
  uint32_t boost_depth;
  size_t interval_ring_size;           /* how many are KEPT, capped at the carried capacity */
  size_t min_samples_for_estimate;
  double default_interval_seconds;
  double min_interval_seconds;
  double max_interval_seconds;
} SlopDeskPacerDepthConfig;

typedef struct {
  SlopDeskPacerDepthConfig config;
  bool   adapt_enabled;                /* off leaves the depth at one; the counters still run */
  uint32_t depth;
  bool   has_last_arrival;
  double last_arrival;
  double arrivals[SLOPDESK_DEPTH_ARRIVAL_RING];   /* oldest first */
  size_t arrival_len;
  double intervals[SLOPDESK_DEPTH_INTERVAL_RING]; /* oldest first */
  size_t interval_len;
  bool   has_interval_hint;
  double interval_hint;
  bool   has_last_present_at;
  double last_present_at;
  bool   has_prev_present_gap;
  double prev_present_gap;
  double lates[SLOPDESK_DEPTH_LATE_RING];         /* oldest first */
  size_t late_len;
  bool   has_promoted_at;
  double promoted_at;
  bool   has_stream_start_at;
  double stream_start_at;
  bool   gap_episode_open;             /* latched, so one episode counts exactly once */
  uint32_t late_count;
  uint32_t gap_count;
} SlopDeskPacerDepth;

typedef struct {
  SlopDeskPacerDepth policy;           /* what the caller writes back */
  uint32_t gap_class;                  /* one of the SLOPDESK_GAP_CLASS_* codes */
} SlopDeskPacerDepthPresent;

typedef struct {
  SlopDeskPacerDepth policy;           /* what the caller writes back, counters zeroed */
  uint32_t late_frames;
  uint32_t present_gaps;
  uint32_t depth;                      /* a gauge rather than a window */
} SlopDeskPacerDepthDrain;

SlopDeskPacerDepthConfig slopdesk_pacer_depth_config_default(void);
SlopDeskPacerDepthConfig slopdesk_pacer_depth_config_apply(SlopDeskPacerDepthConfig config,
                                                           const unsigned char *key, size_t key_len,
                                                           const unsigned char *value,
                                                           size_t value_len);
SlopDeskPacerDepth slopdesk_pacer_depth_new(SlopDeskPacerDepthConfig config, bool adapt_enabled);
double             slopdesk_pacer_depth_expected_interval(SlopDeskPacerDepth policy);
double             slopdesk_pacer_depth_late_threshold(SlopDeskPacerDepth policy);
SlopDeskPacerDepth slopdesk_pacer_depth_note_arrival(SlopDeskPacerDepth policy, double now);
SlopDeskPacerDepthPresent slopdesk_pacer_depth_note_present(SlopDeskPacerDepth policy, double now);
SlopDeskPacerDepth slopdesk_pacer_depth_note_network_late(SlopDeskPacerDepth policy, double now);
SlopDeskPacerDepth slopdesk_pacer_depth_note_reshow(SlopDeskPacerDepth policy, double now);
SlopDeskPacerDepth slopdesk_pacer_depth_set_interval_hint(SlopDeskPacerDepth policy,
                                                          bool has_seconds, double seconds);
SlopDeskPacerDepthDrain slopdesk_pacer_depth_drain(SlopDeskPacerDepth policy);
bool slopdesk_pacer_depth_eq(SlopDeskPacerDepth left, SlopDeskPacerDepth right);

/* ---------------------------------------------------------------------------- *
 * The one-way-delay GRADIENT detector — congestion read from the queue's SLOPE rather than its
 * level, and the one-sample-per-frame gate in front of it.
 *
 * Both cross BY VALUE. The regression WINDOW travels with the detector, as a pair of parallel
 * fixed-capacity arrays: the verdict is a least-squares slope over the samples themselves, and
 * running sums that dropped the evicted point arithmetically would be a different sequence of
 * roundings — the trend's bits are pinned on the wire and in the golden corpus. The capacity is the
 * CEILING of the window knob's own band, so every window a legal config can ask for fits.
 *
 * The law's constants do not cross as state, because no fold changes one: slopdesk_trendline_constants
 * answers them once, so the near side spells none of them.
 *
 * The two env knobs are applied one pair at a time, like the depth policy's, and REJECT an
 * out-of-band value rather than clamping it — these reshape the detector's geometry rather than move
 * it along an axis, so a typo must keep the default.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_TREND_STATE_NORMAL     0u  /* also the verdict before the window fills */
#define SLOPDESK_TREND_STATE_OVERUSING  1u
#define SLOPDESK_TREND_STATE_UNDERUSING 2u

/* The largest window a config can ask for, which is what the crossing carries. */
#define SLOPDESK_TREND_WINDOW_CAPACITY 200

typedef struct {
  size_t window_size;           /* per-frame samples; 20 is a third of a second at 60 fps */
  double threshold_gain;
} SlopDeskTrendlineConfig;

typedef struct {
  double smoothing_coef;
  double initial_threshold;
  double threshold_min;
  double threshold_max;
  double k_up;                  /* rise slowly */
  double k_down;                /* fall several times faster */
  double outlier_skip_margin;
  double max_adapt_dt_ms;
  double overusing_time_ms;     /* overuse must be SUSTAINED this long before it signals */
  double reset_gap_ms;          /* an arrival gap past this resets the window */
  size_t max_scaled_deltas;
  size_t max_num_deltas;
  size_t window_capacity;
} SlopDeskTrendlineConstants;

typedef struct {
  SlopDeskTrendlineConfig config;
  uint32_t state;               /* one of the SLOPDESK_TREND_STATE_* codes */
  double modified_trend;
  size_t num_deltas;
  double threshold;             /* an idle reset deliberately KEEPS this */
  bool   has_prev_arrival;
  double prev_arrival_ms;
  bool   has_prev_send_ts;
  uint32_t prev_send_ts;
  double accumulated_delay_ms;
  double smoothed_delay_ms;
  double window_x[SLOPDESK_TREND_WINDOW_CAPACITY];  /* arrival offsets, oldest first */
  double window_y[SLOPDESK_TREND_WINDOW_CAPACITY];  /* smoothed delays, oldest first */
  size_t window_len;
  double first_arrival_ms;
  bool   has_overuse_start;
  double overuse_start_ms;
  double prev_trend;
} SlopDeskTrendline;

typedef struct {
  bool   has_last_frame_id;
  uint32_t last_frame_id;
} SlopDeskTrendSampler;

typedef struct {
  SlopDeskTrendSampler sampler; /* what the caller writes back */
  bool sampled;
} SlopDeskTrendSample;

SlopDeskTrendlineConfig    slopdesk_trendline_config_default(void);
SlopDeskTrendlineConfig    slopdesk_trendline_config_apply(SlopDeskTrendlineConfig config,
                                                           const unsigned char *key, size_t key_len,
                                                           const unsigned char *value,
                                                           size_t value_len);
SlopDeskTrendlineConstants slopdesk_trendline_constants(void);
SlopDeskTrendline slopdesk_trendline_new(SlopDeskTrendlineConfig config);
SlopDeskTrendline slopdesk_trendline_note(SlopDeskTrendline estimator, double arrival_ms,
                                          uint32_t send_ts);
bool     slopdesk_trendline_is_stale(SlopDeskTrendline estimator, double now_ms);
uint32_t slopdesk_trendline_pack_milli(double modified_trend);
uint32_t slopdesk_trendline_pack_flags(uint32_t state, size_t num_deltas);
bool     slopdesk_trendline_eq(const SlopDeskTrendline *left, const SlopDeskTrendline *right);

SlopDeskTrendSampler slopdesk_trend_sampler_new(void);
SlopDeskTrendSample  slopdesk_trend_sampler_should_sample(SlopDeskTrendSampler sampler,
                                                          uint32_t frame_id, uint32_t send_ts);

/* ---------------------------------------------------------------------------- *
 * What the client's decoder is allowed to see, and in what order.
 *
 * Four values, all of them folds the caller copies out, folds into and writes back, so all four
 * cross by value. Three are a handful of scalars; the fourth is the sequencer.
 *
 * THE SEQUENCER MOVES IDS, AND THE CALLER KEEPS THE BYTES. The ordering law never reads a
 * compressed byte — it is a function of frame ids and one keyframe bit — so the door takes an id
 * and answers with ids: which are releasable now, in order, and which a keyframe has made obsolete.
 * The near side keys its own frames by id and looks them up. Handing megabytes of compressed video
 * to a law that does not inspect them would be a copy per frame, twice, for nothing.
 *
 * Honour a step's answers in order: RELEASE first, then FORGET. One id can be in both lists exactly
 * once — a duplicate keyframe that was already held releases as the new arrival and drops as the
 * held copy — and in that order the removal is the no-op it should be.
 *
 * WHY THE SETS TRAVEL. Which specific ids are outstanding is what the next fold reads: the run at
 * the expectation, the holes it steps over, the flush order. A count answers none of those. Both
 * valves bound how much can be outstanding, so both sets cross as fixed-capacity arrays whose
 * capacity is the CEILING of the valves' own band, and no legal setting is ever truncated.
 *
 * There is no equality door. A C array is a TUPLE on the Swift side and a tuple that long has no
 * equality — but nothing over there compares two sequencers, and a door with no caller is a claim
 * about the boundary nobody can check. slopdesk_pacer_depth_eq, which HAS one, is the shape to copy
 * if that ever changes.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_GATE_MODE_OPEN         0u  /* the chain is intact — everything submits */
#define SLOPDESK_GATE_MODE_BROKEN_CHAIN 1u  /* a loss since the last anchor, session alive */
#define SLOPDESK_GATE_MODE_NEED_KEYFRAME 2u /* the session is gone — keyframe only */

/* Both proved against MAX_VALVE, which slopdesk_decode_sequencer_constants also reports. */
#define SLOPDESK_DECODE_HELD_CAPACITY 65   /* held ids, and the widest answer either list gives */
#define SLOPDESK_DECODE_LOST_CAPACITY 129  /* declared-lost ids ahead of the expectation */

typedef struct {
  bool     has_last_decoded;
  uint32_t last_decoded_frame_id;
} SlopDeskDecodeFrontier;

typedef struct {
  uint32_t mode;                 /* one of the SLOPDESK_GATE_MODE_* codes */
  bool     has_min_lost;
  uint32_t min_lost_frame_id;    /* the OLDEST loss: the chain is intact strictly before it */
  bool     has_max_lost;
  uint32_t max_lost_frame_id;    /* the NEWEST loss: an anchor must decode strictly past it */
} SlopDeskDecodeGate;

typedef struct {
  bool     has_next_expected;
  uint32_t next_expected;
  uint32_t held[SLOPDESK_DECODE_HELD_CAPACITY];       /* ascending, first held_len live */
  size_t   held_len;
  uint32_t lost_ahead[SLOPDESK_DECODE_LOST_CAPACITY]; /* ascending, first lost_len live */
  size_t   lost_len;
  size_t   max_held;             /* the held-count valve */
  int32_t  max_gap;              /* the id-span valve */
} SlopDeskDecodeSequencer;

typedef struct {
  SlopDeskDecodeSequencer sequencer;
  uint32_t released[SLOPDESK_DECODE_HELD_CAPACITY];   /* in RELEASE order, first released_len live */
  size_t   released_len;
  uint32_t dropped[SLOPDESK_DECODE_HELD_CAPACITY];    /* obsolete, honoured AFTER the releases */
  size_t   dropped_len;
} SlopDeskDecodeSequencerStep;

typedef struct {
  size_t  default_max_held;
  int32_t default_max_gap;
  size_t  max_valve;             /* the ceiling both valves clamp to */
  size_t  held_capacity;
  size_t  lost_capacity;
} SlopDeskDecodeSequencerConstants;

typedef struct {
  size_t pending_count;
  size_t pending_bytes;
  size_t max_pending_count;
  size_t max_pending_bytes;
} SlopDeskDecodeBudget;

typedef struct {
  SlopDeskDecodeBudget budget;
  bool                 admitted; /* false: drop before dispatch and arm recovery */
} SlopDeskDecodeBudgetAdmit;

SlopDeskDecodeFrontier slopdesk_decode_frontier_new(void);
SlopDeskDecodeFrontier slopdesk_decode_frontier_note_decoded(SlopDeskDecodeFrontier frontier,
                                                             uint32_t frame_id);
uint32_t               slopdesk_decode_frontier_wire_value(SlopDeskDecodeFrontier frontier);

SlopDeskDecodeGate slopdesk_decode_gate_new(void);
SlopDeskDecodeGate slopdesk_decode_gate_note_loss(SlopDeskDecodeGate gate, uint32_t frame_id);
SlopDeskDecodeGate slopdesk_decode_gate_note_hard_decode_failure(SlopDeskDecodeGate gate);
SlopDeskDecodeGate slopdesk_decode_gate_note_awaiting_keyframe(SlopDeskDecodeGate gate);
bool               slopdesk_decode_gate_submits(SlopDeskDecodeGate gate, uint32_t frame_id,
                                                bool keyframe, bool acked_anchored);
SlopDeskDecodeGate slopdesk_decode_gate_note_decode_succeeded(SlopDeskDecodeGate gate,
                                                              uint32_t frame_id, bool keyframe);

SlopDeskDecodeSequencerConstants slopdesk_decode_sequencer_constants(void);
SlopDeskDecodeSequencer slopdesk_decode_sequencer_new(size_t max_held, int32_t max_gap);
SlopDeskDecodeSequencerStep
slopdesk_decode_sequencer_note_completed(const SlopDeskDecodeSequencer *sequencer,
                                         uint32_t frame_id, bool keyframe);
SlopDeskDecodeSequencerStep
slopdesk_decode_sequencer_note_lost(const SlopDeskDecodeSequencer *sequencer, uint32_t frame_id);

SlopDeskDecodeBudget      slopdesk_decode_budget_default(void);
SlopDeskDecodeBudget      slopdesk_decode_budget_new(size_t max_pending_count,
                                                     size_t max_pending_bytes);
SlopDeskDecodeBudgetAdmit slopdesk_decode_budget_admit(SlopDeskDecodeBudget budget, size_t bytes);
SlopDeskDecodeBudget      slopdesk_decode_budget_complete(SlopDeskDecodeBudget budget, size_t bytes);

/* ---------------------------------------------------------------------------- *
 * The audio DECODER, and the PLAYER behind it.
 *
 * These two doors are the whole client audio path. What used to sit here was the jitter STAGE
 * alone — fifteen entry points that existed so Swift could drive a pump around it, with an
 * `AudioStreamDecoder`, an `AudioSampleRing`, an `AudioPlaybackPump` and an `AUHAL`/`RemoteIO`
 * render callback on the near side. None of that had to be Swift, so none of it is: the ring is
 * `rtrb`, the pump is arithmetic the stage already published, and the output unit is `cpal`.
 *
 * WHY THE DOOR MOVED UP. The stage's own boundary was mid-pipeline, which meant the ORDER of the
 * pieces — prime, pull, shed, starve, drop-oldest — was a law spelled on the near side out of
 * doors, and could be spelled wrong there without any door refusing. Now the near side says
 * "here is frame N" and "play", and there is no order left to get wrong.
 *
 * Exactly one _free per _new on each, and NULL is inert at every entry point — a failed new cannot
 * become a crash in deinit. No two calls on one handle may overlap: the mutators take the object
 * exclusively, so a concurrent call is aliasing rather than a lost update. The Swift owner confines
 * each to its serial audio queue, which is the discipline the Swift original documented.
 *
 * WHAT IS NOT HERE: the render thread. It holds the far half of a wait-free SPSC hand-off and
 * nothing else — it never reaches the stage, so there is no lock for a real-time deadline to miss.
 * ---------------------------------------------------------------------------- */

// One of the capture tap's three fixed numbers: 0 = sample rate (Hz), 1 = channel count,
// 2 = frames per wire block. 0 for an index this build does not know.
//
// A door rather than three Swift constants because the capture tap is CONFIGURED from these —
// SlopDeskCaptureDesc carries the rate and the channel count straight into ScreenCaptureKit — while
// the encoder's block cadence is derived from them on the far side. Two copies of a number that
// must agree is the one thing no test can catch.
size_t slopdesk_audio_source_constant(uint8_t index);

typedef struct SlopDeskAudioDecoder SlopDeskAudioDecoder;

// A decoder for one wire config. `format` is a SLOPDESK_AUDIO_FORMAT_* code and the cookie is the
// AAC magic cookie the host announced — empty for the PCM arm, which is a real answer rather than
// a missing one. NULL means REFUSED: a format this build does not speak, or a machine whose
// AudioToolbox declined to build the converter. A refusal does not become true a frame later, so
// the caller latches it and the lane stays silent instead of asking sixty times a second.
SlopDeskAudioDecoder *slopdesk_audio_decoder_new(uint8_t format, uint32_t sample_rate,
                                                 uint8_t channels, const uint8_t *cookie,
                                                 size_t cookie_len);
void slopdesk_audio_decoder_free(SlopDeskAudioDecoder *handle);

// One wire payload in, interleaved normalised floats out. Answers a SAMPLE count, not a byte
// count — `out` is `float *`, so bytes would be the wrong unit to compare `cap` against, and the
// one a caller would get wrong. 0 is §4's "no answer" and means DROP the frame. A return greater
// than `cap` leaves the destination untouched and reports the room needed.
size_t slopdesk_audio_decoder_decode(SlopDeskAudioDecoder *handle, const uint8_t *payload,
                                     size_t payload_len, float *out, size_t cap);

typedef struct SlopDeskAudioPlayer SlopDeskAudioPlayer;

// A player for one (rate, channels), silent until _start. Never NULL unless allocation itself
// failed: a machine with NO output device answers a player that works and stays mute — headless is
// the normal way to arrive there, not a fault — and _has_device is how a caller can tell.
//
// A config change that moves either number REBUILDS the player. The resampler's ratio, the
// hand-off's capacity and the device's own stream are all derived from the pair, and nothing here
// reconfigures in place.
SlopDeskAudioPlayer *slopdesk_audio_player_new(double sample_rate, size_t channels);
void slopdesk_audio_player_free(SlopDeskAudioPlayer *handle);

// Whether a real output device was found. false means this player is permanently MUTE, which is
// what a headless machine answers and is not a fault to report.
//
// The rate it settled on is deliberately not asked: it is the wire rate wherever the device offers
// it, and a difference is the producer-side resampler doing its job. `AUHAL` did that conversion
// itself; `cpal` does not, which is the one behaviour this port had to add rather than move.
bool slopdesk_audio_player_has_device(SlopDeskAudioPlayer *handle);

// One decoded frame, keyed by its wire sequence. The samples are COPIED — one memcpy of ten
// milliseconds of audio per push, under half a megabyte a second at the wire cadence, and there is
// no arrangement that avoids it without putting the ordering law back on the near side.
void slopdesk_audio_player_enqueue(SlopDeskAudioPlayer *handle, uint32_t seq,
                                   const float *samples, size_t samples_len);
// Drops everything buffered — the pane falls silent on the next render pass rather than after the
// hand-off drains, which is what "silent now" can honestly mean when the producer cannot take back
// what it already committed.
void slopdesk_audio_player_flush(SlopDeskAudioPlayer *handle);
// Both idempotent, which is what lets the host's ~1 s config re-send restart a stopped player
// without the caller tracking whether it is already running.
void slopdesk_audio_player_start(SlopDeskAudioPlayer *handle);
void slopdesk_audio_player_stop(SlopDeskAudioPlayer *handle);

/* ---------------------------------------------------------------------------- *
 * Which decoded frame this refresh shows, and when.
 *
 * The presentation policy is a fold the caller copies out, folds into and writes back, so it
 * crosses BY VALUE — the decoder admission's shape, for the decoder admission's reason. What is big
 * here is the queue of waiting frames, and the near side never reads it: it reads a handle to
 * present and a list of handles to let go of. Nothing in the law dereferences a handle, so the
 * decoder's image buffers stay exactly where they are.
 *
 * WHAT THE NEAR SIDE MUST HONOUR. One refresh answers with an outcome and a DROP LIST. The outcome
 * says what to put on screen; the list says which images the queue no longer refers to — the trim
 * homeostasis performed to reach the frame it chose. A queue of opaque handles owes its caller that
 * list: a count would say how many died and leave the caller inferring WHICH from an ordering it is
 * deliberately not keeping. A submission answers the same way for the hard cap's own eviction.
 *
 * TWO DEPTH DOORS, BECAUSE THERE ARE TWO CONTROLLERS. set_live_depth carries the promote rule — a
 * deeper buffer re-primes, or the slack frame it was asked for never gets built. adopt_live_depth
 * does not, and is the older arrival-jitter controller's door: that one recommends a depth on every
 * frame and every underrun, and re-priming that often would hold the picture where the user can see
 * it. The two controllers are mutually exclusive upstream, so the two doors never both apply.
 *
 * THE TICK RATIO CROSSES WITH THE QUEUE. The link ticks at the panel's rate and the content arrives
 * at the host's; every law that counts refreshes counts CONTENT SLOTS, one per ticks_per_frame
 * ticks, at any depth above one. A between-slot tick answers SLOPDESK_PRESENT_HOLD — the last frame
 * again, the slack kept, and not a hitch for the telemetry. A streamCadence rebase is one door.
 *
 * There is no equality door here either, for the reason the decode sequencer has none: nothing on
 * the Swift side compares two queues.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_PRESENT_PRIMING 0u  /* still filling — re-show last_shown, if any */
#define SLOPDESK_PRESENT_PRESENT 1u  /* put `frame` on screen */
#define SLOPDESK_PRESENT_RESHOW  2u  /* the producer fell behind — re-show last_shown */
#define SLOPDESK_PRESENT_HOLD    3u  /* between two content slots — re-show last_shown, keep the slack */

/* The deepest queue any configuration may ask for, which the crossing is sized for exactly. */
#define SLOPDESK_PRESENT_QUEUE_CAPACITY 16

typedef struct {
  uint64_t handle;       /* the caller's own handle; the law never looks inside it */
  double   submitted_at; /* the caller's monotonic seconds */
} SlopDeskQueuedFrame;

typedef struct {
  SlopDeskQueuedFrame queue[SLOPDESK_PRESENT_QUEUE_CAPACITY]; /* oldest first, first len live */
  size_t   len;
  uint64_t last_shown;   /* live only when has_last_shown */
  uint32_t max_depth;
  uint32_t live_depth;
  uint32_t underflow_run;   /* consecutive empty content slots */
  uint32_t ticks_per_frame; /* display ticks one content frame spans */
  uint32_t ticks_since_slot;
  bool     has_last_shown;
  bool     primed;
} SlopDeskPresentQueue;

typedef struct {
  SlopDeskPresentQueue queue;
  uint64_t evicted;      /* live only when has_evicted */
  bool     was_empty;    /* what the present-on-arrival gate reads, unrecoverable afterwards */
  bool     has_evicted;
} SlopDeskPresentSubmit;

typedef struct {
  SlopDeskPresentQueue queue;
  SlopDeskQueuedFrame  frame;  /* live only when kind is SLOPDESK_PRESENT_PRESENT */
  uint64_t dropped[SLOPDESK_PRESENT_QUEUE_CAPACITY]; /* oldest first, first dropped_len live */
  size_t   dropped_len;
  uint64_t last_shown;         /* live only when has_last_shown */
  uint32_t kind;               /* one of the SLOPDESK_PRESENT_* codes */
  bool     has_last_shown;
  bool     transient_dip;      /* a real starvation — the cue to grow the buffer */
  bool     re_primed;          /* also the cue to reset the jitter estimator */
} SlopDeskPresentStep;

typedef struct {
  double   playout_hard_ceiling_seconds;
  double   render_cap_slack_seconds;
  double   min_tick_hz;
  double   max_tick_hz;
  size_t   queue_capacity;
  uint32_t max_queue_depth;
  uint32_t playout_recompute_every;
} SlopDeskPresentConstants;

typedef struct {
  uint32_t next_samples;
  bool     due;
} SlopDeskPlayoutRecompute;

/* Chunked BLOB reassembly — app icons (kind 0, PNG) and window previews (kind 1, JPEG). A HANDLE,
 * for the reason the audio stage is one: the assembly's whole product IS the bytes, held across
 * many calls, so folding it through a record would copy the accumulator on every chunk. The
 * completed bytes come in two steps because the near side cannot know their length until the chunk
 * that finishes them: the fold reports it, one take copies them out. Everything else is pure. */

typedef struct SlopDeskBlobAssembler SlopDeskBlobAssembler;

typedef struct {
  uint8_t icon;
  uint8_t preview;
  size_t  max_partial_blobs;
} SlopDeskBlobKinds;

typedef struct {
  uint64_t id;
  size_t   len;      /* ready for one take */
  uint16_t meta_a;
  uint16_t meta_b;
  uint8_t  kind;
  bool     complete;
} SlopDeskBlobFold;

SlopDeskBlobKinds      slopdesk_blob_kinds(void);
size_t                 slopdesk_blob_max_bytes(uint8_t kind);
SlopDeskBlobAssembler *slopdesk_blob_assembler_new(void);
void                   slopdesk_blob_assembler_free(SlopDeskBlobAssembler *handle);
SlopDeskBlobFold       slopdesk_blob_assembler_fold(SlopDeskBlobAssembler *handle,
                                                    uint8_t kind, uint64_t id,
                                                    uint16_t meta_a, uint16_t meta_b,
                                                    uint8_t chunk_index, uint8_t chunk_count_of_blob,
                                                    const unsigned char *bytes, size_t len);
size_t                 slopdesk_blob_assembler_take(SlopDeskBlobAssembler *handle,
                                                    unsigned char *out, size_t cap);
void                   slopdesk_blob_assembler_reset(SlopDeskBlobAssembler *handle);
bool                   slopdesk_blob_validates(const unsigned char *bytes, size_t len, uint8_t kind);
bool                   slopdesk_blob_looks_like_png(const unsigned char *bytes, size_t len);
bool                   slopdesk_blob_looks_like_jpeg(const unsigned char *bytes, size_t len);
uint8_t                slopdesk_blob_chunk_count(uint8_t kind, size_t byte_count);
size_t                 slopdesk_blob_encoded_chunk(uint8_t kind, uint64_t id,
                                                   uint16_t meta_a, uint16_t meta_b,
                                                   const unsigned char *bytes, size_t len, uint8_t index,
                                                   unsigned char *out, size_t cap);
uint64_t               slopdesk_blob_id_of(const unsigned char *text, size_t len);


/* The scroll-hint reprojection law, one per pane. Seven scalars, so it crosses BY VALUE the way
 * the decode gate does: the near side holds the state inside a class it already owns, and the
 * reference is the pane's rather than this law's. An advance answers the state AND the offset,
 * because the offset is what the renderer takes and the state is what the next tick folds —
 * splitting them would mean two calls and a rule about their order. */

#define SLOPDESK_SCROLL_PHASE_ACTIVE   0u  /* finger on glass: track, no decay */
#define SLOPDESK_SCROLL_PHASE_MOMENTUM 1u  /* inertial coast: track, no decay */
#define SLOPDESK_SCROLL_PHASE_ENDED    2u  /* finished: arm the decay */

typedef struct {
  double max_band;       /* the per-axis clamp, in normalised units */
  double decay_seconds;  /* the decay time constant after a scroll ends */
  double offset_x;
  double offset_y;
  double velocity_x;     /* normalised units per second */
  double velocity_y;
  bool   decaying;
} SlopDeskScrollReprojector;

typedef struct {
  double x;
  double y;
} SlopDeskScrollOffset;

typedef struct {
  SlopDeskScrollReprojector reprojector;
  SlopDeskScrollOffset      offset;
} SlopDeskScrollAdvance;

typedef struct {
  double max_band;
  double decay_seconds;
} SlopDeskScrollDefaults;

SlopDeskScrollDefaults    slopdesk_scroll_reprojector_defaults(void);
SlopDeskScrollReprojector slopdesk_scroll_reprojector_new(double max_band, double decay_seconds);
SlopDeskScrollReprojector slopdesk_scroll_reprojector_note_velocity(SlopDeskScrollReprojector reprojector,
                                                                    double vx, double vy, uint32_t phase);
SlopDeskScrollAdvance     slopdesk_scroll_reprojector_advance(SlopDeskScrollReprojector reprojector,
                                                              double elapsed_seconds);
SlopDeskScrollReprojector slopdesk_scroll_reprojector_note_real_frame(SlopDeskScrollReprojector reprojector);
SlopDeskScrollReprojector slopdesk_scroll_reprojector_reset(SlopDeskScrollReprojector reprojector);

/* The phase the platform's two codes name together. `CGScrollPhase` is 1 began, 2 changed, 4 ended,
 * 8 cancelled; `CGMomentumScrollPhase` is 1 begin, 2 continue, 3 end. The momentum code is read
 * first: it is the later half of one gesture. */
uint32_t slopdesk_scroll_phase_of_platform(uint8_t scroll_phase, uint8_t momentum_phase);

/* One host-MEASURED per-frame scroll shift, as it crosses the wire: a signed shift in
 * TEN-THOUSANDTHS of the frame extent, plus the moving-content band in the same units. The host
 * measures the true pixel shift; the client never guesses one from local trackpad deltas, because
 * the host applies momentum, acceleration and clamping the client cannot know. Both halves of the
 * encoding live on the far side — a scale spelled on only one side is one the two ends drift on. */
typedef struct {
  int16_t  dx;           /* ten-thousandths of the frame width; the v1 host is vertical-only */
  int16_t  dy;           /* ten-thousandths of the frame height */
  uint16_t band_top;     /* the moving-content band, ten-thousandths of the height */
  uint16_t band_bottom;  /* exclusive edge; not above the top ⇒ no band */
} SlopDeskScrollHint;

typedef struct {
  double   vx;     /* normalised units per second */
  double   vy;
  uint32_t phase;  /* SLOPDESK_SCROLL_PHASE_* — a zero shift is the host saying the scroll stopped */
} SlopDeskScrollVelocity;

/* An absent band is a FLAG, not a sentinel: an empty span at the top of the frame is a degenerate
 * band, not "no band measured", and a caller holding an earlier one must keep it so a decay tick
 * eases out still masked. */
typedef struct {
  float top;
  float bottom;
  bool  present;
} SlopDeskScrollBand;

SlopDeskScrollHint     slopdesk_scroll_hint_measured(int32_t shift, uint32_t confidence_milli,
                                                     int32_t band_top_row, int32_t band_bottom_row,
                                                     size_t height);
SlopDeskScrollVelocity slopdesk_scroll_hint_velocity(SlopDeskScrollHint hint, double content_fps);
SlopDeskScrollBand     slopdesk_scroll_hint_band(SlopDeskScrollHint hint);

/* The SWIPE-NAV recogniser: which two-finger gesture becomes a history navigation. Sixteen scalars
 * and flags, by value — the host's injector and the client's peel planner each hold one, and both
 * must reach the SAME verdict over the same event stream, which is the whole argument for the law
 * existing once. The trace line is not state: it is recorded at a decision and popped straight
 * after, so it crosses as an ANSWER written into the caller's buffer by the ingest that made it. */

#define SLOPDESK_SWIPE_BACK    0u  /* fingers moved right — history back */
#define SLOPDESK_SWIPE_FORWARD 1u  /* fingers moved left — history forward */

typedef struct {
  double dominance;
  double slow_dominance;
  double slow_relaxed_dominance;
  double flick_max_duration;
  double slow_grace_max_duration;
  double refractory;
  double default_fire_travel;
} SlopDeskSwipeConstants;

typedef struct {
  double  fire_travel;          /* the threshold family, derived once at construction */
  double  arm_travel;
  double  confirm_travel;
  double  slow_fire_travel;
  double  slow_relaxed_travel;
  double  started_at;           /* the caller's arrival clock */
  double  coast_deadline;
  double  fired_at;             /* the refractory window's anchor */
  double  sum_x;
  double  sum_y;
  double  momentum_dx;          /* the last momentum event, for duplicate rejection */
  double  momentum_dy;
  uint8_t momentum_phase;
  bool    has_momentum;         /* presence, never a sentinel */
  bool    slow_swipe;
  bool    trace;
  bool    tracking;
  bool    coasting;
  bool    synthesised;
} SlopDeskSwipeRecognizer;

typedef struct {
  SlopDeskSwipeRecognizer recognizer;
  uint32_t                direction;  /* meaningful only when `fired` */
  bool                    fired;
  size_t                  trace_len;  /* past the capacity means nothing was written */
} SlopDeskSwipeIngest;

typedef struct {
  double   travel_x;
  double   progress;            /* 0..1 toward the LIVE tier's threshold */
  uint32_t direction;
  bool     would_fire_at_lift;  /* always false while coasting */
  bool     coasting;
} SlopDeskSwipeCandidate;

SlopDeskSwipeConstants  slopdesk_swipe_constants(void);
SlopDeskSwipeRecognizer slopdesk_swipe_recognizer_new(double fire_travel, bool slow_swipe, bool trace);
SlopDeskSwipeIngest     slopdesk_swipe_recognizer_ingest(SlopDeskSwipeRecognizer recognizer,
                                                         double dx, double dy,
                                                         uint8_t scroll_phase, uint8_t momentum_phase,
                                                         bool continuous, double now,
                                                         unsigned char *trace, size_t trace_cap);
bool                    slopdesk_swipe_live_candidate(SlopDeskSwipeRecognizer recognizer, double now,
                                                      SlopDeskSwipeCandidate *out);
bool                    slopdesk_swipe_slow_required_travel(double duration, double sum_x, double sum_y,
                                                            double fire_travel, double slow_fire_travel,
                                                            double slow_relaxed_travel, double *out);


SlopDeskPresentQueue slopdesk_present_queue_new(uint32_t live_depth, uint32_t max_depth,
                                                uint32_t ticks_per_frame);
uint32_t             slopdesk_present_ticks_per_frame(double tick_hz, double content_fps);
SlopDeskPresentQueue slopdesk_present_queue_set_ticks_per_frame(const SlopDeskPresentQueue *queue,
                                                                uint32_t ticks_per_frame);
SlopDeskPresentQueue slopdesk_present_queue_set_live_depth(const SlopDeskPresentQueue *queue,
                                                           uint32_t depth);
SlopDeskPresentQueue slopdesk_present_queue_adopt_live_depth(const SlopDeskPresentQueue *queue,
                                                             uint32_t depth);
SlopDeskPresentSubmit slopdesk_present_queue_submit(const SlopDeskPresentQueue *queue,
                                                    uint64_t handle, double submitted_at);
SlopDeskPresentStep  slopdesk_present_queue_step(const SlopDeskPresentQueue *queue);

/* The schedule — pure, so the near side spells none of it. */
double slopdesk_present_clamped_playout_seconds(double next_seconds);
SlopDeskPlayoutRecompute slopdesk_present_playout_recompute_due(uint32_t samples_since_last);
double slopdesk_present_deadline_for_arrival(double arrival, double last_deadline,
                                             double interval, double playout_delay);
bool   slopdesk_present_deadline_due(double deadline, double now, double half_tick);
bool   slopdesk_present_should_render(double now, double last_render, double max_frame_rate);
bool   slopdesk_present_should_present_on_arrival(bool enabled, bool queue_was_empty,
                                                  uint32_t queue_count, uint32_t live_depth);
/* A null pointer, an empty span, or bytes that are not a finite number all mean NO override. */
double slopdesk_present_resolve_tick_rate(const char *env_override, size_t env_override_len,
                                          uint32_t display_max_hz, double floor);


#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_VIDEO_CLIENT_H */
