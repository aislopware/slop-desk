// slopdesk_ffi_video_transport.h — the cursor side-channel, the control channel, and the two datagram paths
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_VIDEO_TRANSPORT_H
#define SLOPDESK_FFI_VIDEO_TRANSPORT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * The cursor side-channel, and the AVCC NAL-unit split.
 *
 * Two wires in one block because both answer a SPAN into the buffer you passed in, and neither is
 * big enough to earn its own. They are otherwise unrelated.
 *
 * The cursor socket carries the pointer separately from the video, so pointer latency is RTT: an
 * update at ~120 Hz (type 1, 36 bytes) referencing a shape id, and the bitmap for that id sent once
 * (type 2). Coordinates are finite-checked at decode for the same reason geometry's are. The shape
 * arm reports bitmap_offset/bitmap_length rather than copying the PNG; the third type on this
 * socket, the swipe-nav status, is above. The verdict vocabulary is SLOPDESK_CURSOR_DECODE_*.
 *
 * slopdesk_nal_split answers where each length-prefixed NAL unit sits, under §4's convention on a
 * SlopDeskNalSpan array: a ragged tail ends the walk rather than failing it. slopdesk_nal_join
 * takes the units as a §4d blob list (the FEC boundary's shape) because a run of separate payloads
 * cannot cross as one span; an absence in that list answers 0, since a missing NAL unit is a frame
 * that cannot be built.
 *
 * slopdesk_cursor_constant: 0 the update's type, 1 its encoded size, 2 the shape's type, 3 the
 * shape's fixed header. slopdesk_nal_constant: 0 the length-prefix width.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_CURSOR_DECODE_OK 0u
#define SLOPDESK_CURSOR_DECODE_TRUNCATED 1u
#define SLOPDESK_CURSOR_DECODE_MALFORMED 2u

typedef struct {
  double x;
  double y;
  double hotspot_x;
  double hotspot_y;
  double width;
  double height;
  uint32_t bitmap_offset;
  uint32_t bitmap_length;
  uint16_t shape_id;
  uint8_t message_type;
  bool visible;
} SlopDeskCursorMessage;

uint32_t slopdesk_cursor_decode(const uint8_t *bytes, size_t len, SlopDeskCursorMessage *out);
size_t slopdesk_cursor_encode(SlopDeskCursorMessage message, const uint8_t *bitmap,
                              size_t bitmap_len, uint8_t *out, size_t cap);
size_t slopdesk_cursor_constant(uint8_t index);

typedef struct {
  uint32_t offset;
  uint32_t length;
} SlopDeskNalSpan;

size_t slopdesk_nal_split(const uint8_t *avcc, size_t len, SlopDeskNalSpan *out, size_t cap);
size_t slopdesk_nal_join(const uint8_t *list, size_t list_len, uint8_t *out, size_t cap);
size_t slopdesk_nal_constant(uint8_t index);

/* ---------------------------------------------------------------------------- *
 * The control channel: session bring-up, discovery, the host-window feed, the live knobs.
 *
 * Twenty-eight message types, five of which carry a LIST of records, and every record carries text.
 * That is why this wire uses an ARENA where the others used an offset into the datagram: there is no
 * single span to point at, and a title off the wire is decoded LOSSILY — one mangled byte becomes
 * U+FFFD, which is bytes that are not in the datagram.
 *
 * So both directions share one flat byte buffer. Decode writes every string into `arena` and each
 * field names its (offset, length) inside it; encode reads them back out the same way. Symmetric,
 * and the lossy repair happens once, in rust/slopdesk-video.
 *
 * SlopDeskVideoControl holds every scalar any arm carries — `message_type` says which are live —
 * and SlopDeskControlRecord does the same for the five list arms. Flat, not a union: a union would
 * have to be kept in step with the Rust enum by hand on both sides, which is the drift this removes.
 *
 * Decode answers a VERDICT (SLOPDESK_CONTROL_DECODE_*). AGAIN means the datagram parsed and the
 * record array or the arena was too small: nothing was written to either, but `record_count` and
 * `arena_length` were, so size from those and ask again. The parse is pure, so it cannot disagree.
 * Encode answers bytes NEEDED under §4, and 0 for a message_type no arm claims.
 *
 * slopdesk_video_control_constant: 0 a blob chunk's data bytes, 1 the icon blob cap, 2 the preview
 * blob cap, 3 a feed chunk's record budget, 4 the feed title cap, then the five window-state bits —
 * 5 on-screen, 6 minimized, 7 app-hidden, 8 frontmost-app, 9 focused-window.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_CONTROL_DECODE_OK 0u
#define SLOPDESK_CONTROL_DECODE_TRUNCATED 1u
#define SLOPDESK_CONTROL_DECODE_MALFORMED 2u
#define SLOPDESK_CONTROL_DECODE_AGAIN 3u

typedef struct {
  double viewport_width;
  double viewport_height;
  double bounds_x;
  double bounds_y;
  double bounds_width;
  double bounds_height;
  uint64_t blob_id;
  uint32_t requested_id;
  uint32_t stream_id;
  uint32_t epoch;
  uint32_t generation;
  uint32_t bitrate_ceiling_bps;
  uint32_t span_offset;
  uint32_t span_length;
  uint32_t record_count;
  uint32_t arena_length;
  uint16_t protocol_version;
  uint16_t capture_width;
  uint16_t capture_height;
  uint16_t fps;
  int16_t scroll_dx;
  int16_t scroll_dy;
  uint16_t band_top;
  uint16_t band_bottom;
  uint16_t display_max_width;
  uint16_t display_max_height;
  uint16_t meta_a;
  uint16_t meta_b;
  uint16_t size_px;
  uint16_t max_width_px;
  uint16_t rtt_tenths_millis;
  uint16_t encode_tenths_millis;
  uint8_t message_type;
  uint8_t chunk_index;
  uint8_t chunk_count;
  uint8_t blob_kind;
  uint8_t fps_cap;
  bool accepted;
  bool full_range;
  bool enabled;
} SlopDeskVideoControl;

typedef struct {
  uint32_t id;
  uint32_t name_offset;
  uint32_t name_length;
  uint32_t title_offset;
  uint32_t title_length;
  uint32_t bundle_offset;
  uint32_t bundle_length;
  uint16_t width;
  uint16_t height;
  uint16_t x;
  uint16_t y;
  uint8_t flags;
  uint8_t display_index;
  bool is_main;
  bool is_secure;
} SlopDeskControlRecord;

/* ---------------------------------------------------------------------------- *
 * window_feed_host — what to list, how to pack it, who to push it to, and when.
 *
 * The cache and the subscriber table are HANDLES: the cache holds a record list
 * AND its encoded chunks, and the near side reads one reply out of it per
 * subscribe. The push policy is two optional timestamps and folds BY VALUE. The
 * inclusion verdict, the snapshot build and the chunk packing are functions of
 * their inputs.
 *
 * The records cross in the shape the control codec already answers in —
 * SlopDeskControlRecord rows naming (offset, length) spans in one arena — so
 * there is no second record type anywhere.
 *
 * The pure builders answer TWICE: the call reports the shape it would write, and
 * a second call with big enough buffers writes it. They are pure, so recomputing
 * costs a pass over at most sixty-four rows, four times a second at the very most.
 * The subscriber reap does NOT: it consumes what it reports, so lend at the
 * table's own size.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskFeedCache SlopDeskFeedCache;
typedef struct SlopDeskFeedSubscribers SlopDeskFeedSubscribers;

#define SLOPDESK_FEED_CHANGE_NONE 0u
#define SLOPDESK_FEED_CHANGE_STRUCTURAL 1u
#define SLOPDESK_FEED_CHANGE_VOLATILE 2u
#define SLOPDESK_FEED_CHANGE_VOLATILE_TITLE 3u

typedef struct {
  size_t max_records;
  size_t bundle_id_max_bytes;
  size_t app_name_max_bytes;
  int32_t min_dimension_pt;
  double idle_tick;
  double burst_tick;
  double burst_window;
  double title_coalesce;
  double focus_coalesce;
} SlopDeskFeedConstants;

typedef struct {
  uint32_t          window_id;
  SlopDeskByteSpan  owner;
  SlopDeskByteSpan  bundle;
  SlopDeskByteSpan  title;
  int32_t           layer;
  int32_t           width_pt;
  int32_t           height_pt;
  uint8_t           display_index;
  bool              is_on_screen;
  bool              is_app_hidden;
  bool              is_frontmost_app;
  bool              is_minimized;
  bool              is_ax_listed;
} SlopDeskFeedSource;

typedef struct {
  size_t count;
  size_t arena_len;
} SlopDeskFeedShape;

typedef struct {
  double burst_until;
  double last_volatile_fold;
  bool   has_burst;
  bool   has_volatile_fold;
} SlopDeskFeedPushPolicy;





uint32_t slopdesk_video_control_decode(const uint8_t *bytes, size_t len, SlopDeskVideoControl *out,
                                       SlopDeskControlRecord *records, size_t records_cap,
                                       uint8_t *arena, size_t arena_cap);
size_t slopdesk_video_control_encode(SlopDeskVideoControl message,
                                     const SlopDeskControlRecord *records, size_t record_count,
                                     const uint8_t *arena, size_t arena_len, uint8_t *out,
                                     size_t cap);
size_t slopdesk_video_control_constant(uint8_t index);

/* The window-feed snapshot reassembly. A handle for the same reason the blob one is: the
 * accumulator is a list of records with three strings each, held across chunks and up to four
 * generations at once. The records cross in the shape the control decode just above already answers
 * in — flat rows naming spans in one arena — so a fold costs the near side the marshalling an
 * encode already does, and no second record type exists. */

typedef struct SlopDeskWindowFeed SlopDeskWindowFeed;

typedef struct {
  size_t max_partial_generations;
  size_t max_records_per_generation;
} SlopDeskWindowFeedBounds;

typedef struct {
  uint32_t generation;
  size_t   record_count;  /* ready for one take */
  size_t   arena_len;
  bool     complete;
} SlopDeskWindowFeedFold;

typedef struct {
  size_t record_count;  /* reported whether or not it fit */
  size_t arena_len;
  bool   copied;        /* false leaves the snapshot in place for a bigger retry */
} SlopDeskWindowFeedTake;

SlopDeskWindowFeedBounds slopdesk_window_feed_bounds(void);
SlopDeskWindowFeed      *slopdesk_window_feed_new(void);
void                     slopdesk_window_feed_free(SlopDeskWindowFeed *handle);
SlopDeskWindowFeedFold   slopdesk_window_feed_fold(SlopDeskWindowFeed *handle, uint32_t generation,
                                                   uint8_t chunk_index, uint8_t chunk_count,
                                                   const SlopDeskControlRecord *records, size_t record_count,
                                                   const unsigned char *arena, size_t arena_len);
SlopDeskWindowFeedTake   slopdesk_window_feed_take(SlopDeskWindowFeed *handle,
                                                   SlopDeskControlRecord *records, size_t record_cap,
                                                   unsigned char *arena, size_t arena_cap);
void                     slopdesk_window_feed_reset(SlopDeskWindowFeed *handle);

/* ---------------------------------------------------------------------------- *
 * The host send path: an encoded frame becoming wire datagrams.
 *
 * The MTU split, the tier ladder's per-frame FEC shape, the parity, the optional interleave and the
 * 19-byte header stamp are all one call. A HANDLE (§4b) rather than a function, because two counters
 * outlive it: streamSeq advances per datagram and frameID per frame, and the host reads frameID
 * BEFORE packetizing so it can record the frame's LTR token against the id it is about to carry.
 *
 * The answer is HELD, not returned inline, because its size is exactly what the call decides — how
 * many parity fragments a tier adds is the logic being asked for. So `raw` packetizes, parks the
 * flattened list, and returns its length; `answer` copies it out under §4's convention. Calling
 * `answer` twice, or with too small a buffer, does not packetize the frame again: the counters
 * advance once per `raw`.
 *
 * The parked answer is a blob list in send order — data fragments then parity, or the interleaved
 * order when FLAG_INTERLEAVE was set — with every blob present.
 *
 * `flags` is a bitfield, and its bits are ASKED FOR rather than transcribed:
 * `slopdesk_video_packetizer_flag` vends them by index — 0 keyframe, 1 crisp, 2 isLTR,
 * 3 ackedAnchored, 4 interleave — because a position the two sides disagree about is a keyframe
 * encoded as a delta, with no error anywhere. An unknown index answers 0, which is no bit at all.
 * `parity_count == 0` builds a packetizer with no FEC at all. `new` answers NULL for a shape the
 * code cannot exist in (k + m > 255, or a zero group size).
 * ---------------------------------------------------------------------------- */

uint32_t slopdesk_video_packetizer_flag(uint32_t index);

typedef struct SlopDeskVideoPacketizer SlopDeskVideoPacketizer;

SlopDeskVideoPacketizer *slopdesk_video_packetizer_new(size_t group_size, size_t parity_count);
void slopdesk_video_packetizer_free(SlopDeskVideoPacketizer *handle);
uint32_t slopdesk_video_packetizer_peek_frame_id(SlopDeskVideoPacketizer *handle);
uint32_t slopdesk_video_packetizer_peek_stream_seq(SlopDeskVideoPacketizer *handle);
size_t slopdesk_video_packetizer_raw(SlopDeskVideoPacketizer *handle, const uint8_t *frame,
                                     size_t frame_len, uint32_t host_send_ts_millis,
                                     uint8_t fec_tier, uint32_t flags);
size_t slopdesk_video_packetizer_answer(SlopDeskVideoPacketizer *handle, uint8_t *out, size_t cap);

/* ---------------------------------------------------------------------------- *
 * The client receive path: datagrams becoming frames.
 *
 * Fragment buffering, the data/parity boundary inversion, the m-aware FEC recovery, the NACK hold,
 * the hopeless-frame sweep and every hostile-input guard are one call. A HANDLE (§4b) because the
 * state IS the answer: a frame is declared lost only once a NEWER frame arrives while it still has
 * a hole the code cannot fill, so the reassembler has to remember what it was shown, and copying
 * that per datagram would copy the frame under construction once per fragment.
 *
 * The header arrives as its seven fields, not as the 19 bytes they were parsed from: the client's
 * router already reads frameID and hostSendTsMillis off every datagram for the one-way-delay
 * telemetry, so passing the bytes would decode them twice. `payload` is what follows the header.
 *
 * `ingest` answers one SLOPDESK_REASSEMBLE_* verdict, defined below rather than described here so
 * a caller switches on the same numbering the crate returns. The detail is parked —
 * `frame_id` / `frame_flags` / `frame_avcc` for a completed or dropped frame, held until the next
 * ingest completes another one. `frame_flags` is a bitfield whose bits are ASKED FOR rather than
 * transcribed: `slopdesk_video_reassembler_frame_flag` vends them by index — 0 keyframe, 1 crisp,
 * 2 recoveredViaFEC, 3 isLTR, 4 ackedAnchored. An unknown index answers 0, which is no bit at all.
 *
 * `next_needs_retransmit` parks a selective-ARQ request and answers how many fragments it names; 0
 * is the absence, since a request naming nothing is not one. `next_dropped_frame` writes through an
 * out param and answers false when there is none, because every uint32_t is a legal frame id and no
 * value could have meant "none". `parity_count == 0` builds a reassembler with no FEC at all.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_REASSEMBLE_INCOMPLETE 0u
#define SLOPDESK_REASSEMBLE_COMPLETED 1u
#define SLOPDESK_REASSEMBLE_DROPPED 2u
#define SLOPDESK_REASSEMBLE_STALE 3u

uint32_t slopdesk_video_reassembler_frame_flag(uint32_t index);

typedef struct SlopDeskVideoReassembler SlopDeskVideoReassembler;

SlopDeskVideoReassembler *slopdesk_video_reassembler_new(size_t group_size, size_t parity_count,
                                                         int32_t fec_reorder_grace);
void slopdesk_video_reassembler_free(SlopDeskVideoReassembler *handle);
void slopdesk_video_reassembler_enable_retransmit(SlopDeskVideoReassembler *handle, int32_t grace,
                                                  size_t max_frags);
uint32_t slopdesk_video_reassembler_ingest(SlopDeskVideoReassembler *handle, uint32_t stream_seq,
                                           uint32_t frame_id, uint16_t frag_index,
                                           uint16_t frag_count, uint8_t flags,
                                           uint32_t host_send_ts_millis, const uint8_t *payload,
                                           size_t payload_len);
uint32_t slopdesk_video_reassembler_frame_id(SlopDeskVideoReassembler *handle);
uint32_t slopdesk_video_reassembler_frame_flags(SlopDeskVideoReassembler *handle);
size_t slopdesk_video_reassembler_frame_avcc(SlopDeskVideoReassembler *handle, uint8_t *out,
                                             size_t cap);
size_t slopdesk_video_reassembler_next_needs_retransmit(SlopDeskVideoReassembler *handle);
uint32_t slopdesk_video_reassembler_retransmit_frame_id(SlopDeskVideoReassembler *handle);
size_t slopdesk_video_reassembler_retransmit_frags(SlopDeskVideoReassembler *handle, uint16_t *out,
                                                   size_t cap);
bool slopdesk_video_reassembler_next_dropped_frame(SlopDeskVideoReassembler *handle, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_VIDEO_TRANSPORT_H */
