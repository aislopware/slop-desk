// slopdesk_ffi_mux.h — PATH-1: the terminal message codec, the client end, and every channel payload
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_MUX_H
#define SLOPDESK_FFI_MUX_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ----------------------------------------------------------------------------
 * The PATH-1 TERMINAL MESSAGE CODEC — `[uint8 message_type][body…]`, 30 types.
 *
 * The wire the product sits on: every keystroke, every byte of PTY output, every title, every
 * agent-status edge. One flat struct with a named field per wire scalar; a field is meaningful only
 * for the arms that carry it and zero otherwise.
 *
 * TWO ADDRESS SPACES, ON PURPOSE. `text_*` offsets are into the ARENA — short strings, which cannot
 * be spans because an arm may carry two and because an encode has to write them down somewhere.
 * `blob_*` offsets are into the DATAGRAM: the opaque byte run six arms end in is the one field big
 * enough for a copy to be felt, so decoding answers WHERE it is and encoding takes it as its own
 * argument. Neither direction copies it more than once.
 *
 * The BYTES doors are gone (docs/63 G.4): the client's live path takes this record straight through
 * slopdesk_mux_transport_send, so nothing asked for a frame any more. What is left is the size
 * question the flow control has to ask — bytes NEEDED for the COMPLETE frame, four-byte length
 * prefix included, and 0 for a message_type no arm claims. The SLOPDESK_WIRE_DECODE_* verdicts
 * below stay: the metadata and workspace payload doors answer with them.
 *
 * slopdesk_wire_constant: 0 the wire version, 1 a session id's bytes, 2 the frame payload ceiling,
 * 3/4/5 the PATH-1 TCP keepalive ladder — idle seconds, probe interval seconds, retry count. That
 * ladder is vended rather than written down on the Swift side because the listener and the dialler
 * are two programs, and a keepalive set on one end only is a half-open link neither end reports.
 * ---------------------------------------------------------------------------- */

#define SLOPDESK_WIRE_DECODE_OK 0u
#define SLOPDESK_WIRE_DECODE_TRUNCATED 1u
#define SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE 2u
#define SLOPDESK_WIRE_DECODE_MALFORMED 3u
#define SLOPDESK_WIRE_DECODE_AGAIN 4u

typedef struct {
  int64_t seq;
  int64_t last_received_seq;
  int64_t resume_from_seq;
  int64_t base_state_num;
  int64_t new_state_num;
  uint64_t timestamp_ms;
  int32_t exit_code;
  int32_t ahead;
  int32_t behind;
  int32_t stash_count;
  uint32_t index;
  uint32_t duration_ms;
  uint32_t output_len;
  uint32_t prompt_ordinal;
  uint32_t request_id;
  uint32_t request_seq;
  uint32_t staged;
  uint32_t modified;
  uint32_t untracked;
  uint32_t conflicted;
  uint32_t changed_count;
  uint32_t text_a_offset;
  uint32_t text_a_length;
  uint32_t text_b_offset;
  uint32_t text_b_length;
  uint32_t blob_offset;
  uint32_t blob_length;
  uint16_t protocol_version;
  uint16_t cols;
  uint16_t rows;
  uint16_t px_width;
  uint16_t px_height;
  uint8_t message_type;
  uint8_t command_status;
  uint8_t verb;
  uint8_t status;
  uint8_t state;
  uint8_t kind;
  uint8_t percent;
  bool returning_client;
  bool complete;
  bool enabled;
  bool has_exit_code;
  bool has_duration_ms;
  uint8_t session_id[16];
  uint8_t epoch[16];
} SlopDeskWireMessage;

size_t slopdesk_wire_message_byte_count(const SlopDeskWireMessage *message, const uint8_t *arena,
                                       size_t arena_len, size_t blob_len);

size_t slopdesk_wire_constant(uint32_t index);

// ---------------------------------------------------------------------------
// The flow-control constants (rust/slopdesk-ffi/src/mux_flow.rs).
//
// The seven numbers the mux is sized from, read from the environment ONCE and
// then fixed: 0 the initial window, 1 the input split cap, 2 the host queue
// bound, 3 the detached host queue bound, 4 the merge cap, 5 the provably-safe
// output payload cap, 6 the live channel cap. An index with no constant behind
// it answers 0.
//
// The three by-value policies that stood here — the send window, the receive
// accountant and the bounded producer queue, twelve doors between them — went
// with the Swift mux in docs/63 G.3. Each crossed because the SubChannel
// running the policy was Swift while the policy was Rust's; slopdesk-clientnet
// runs both, so the state never leaves the crate. A CONSTANT is the opposite
// case: its callers sit outside the mux and outlive it, and re-typing one where
// a door already exists is the shape docs/55 §8 catalogues.
// ---------------------------------------------------------------------------
int64_t slopdesk_mux_flow_constant(uint32_t index);

// ---------------------------------------------------------------------------
// PATH-1's CLIENT END (rust/slopdesk-ffi/src/mux_transport.rs).
//
// Two handles, and they are the sockets themselves — not a rule about them.
// Everything above this block is a pure fold Swift calls while owning the
// bytes; everything below owns the connection.
//
//   SlopDeskMuxPool       one per app. Dials, pools and reaps every PATH-1
//                         connection: every pane to one host rides ONE mux.
//   SlopDeskMuxTransport  one channel on a pooled connection, with both lanes.
//
// LANES. `input` rides DATA, which is flow-controlled; every other verb rides
// CONTROL, which is not. That is why there are two send doors rather than a
// lane argument — and why _send REFUSES an input rather than rerouting it.
//
// CREDIT AT CONSUMPTION. Call _note_consumed with what the wire spent
// (slopdesk_wire_message_byte_count), once the real consumer has drained the
// bytes — not when the callback returned. The sender debits per frame and the
// two must match exactly or the window leaks. CONTROL is never reported.
//
// THE CALLBACK CONTRACT, which is docs/55 §4b's:
//   1. `context` stays valid until _free RETURNS. _free joins both forwarder
//      threads, so a callback may still be running when it is entered.
//   2. Both callbacks run on a Rust thread, never concurrently with each other.
//      One lock serialises them, so an unsynchronised capture is safe.
//   3. Neither may re-enter _free — it joins the thread they run on. Sending
//      from inside on_inbound IS allowed and is what the ack gate does.
//   4. on_ended fires exactly ONCE and nothing follows it, including from the
//      other lane. There is no "why did it end" door: a caller that has to ask
//      is a caller that can ask too early.
//
// Every pointer in both callbacks is LENT for the call. `arena` and `blob` are
// two address spaces, as in SlopDeskWireMessage — but `blob_offset` is always
// 0 here, because the datagram it used to index is Rust's now. Read the run
// through the `blob` pointer, never through the record's offset.
// ---------------------------------------------------------------------------

// How a channel ended.
#define SLOPDESK_MUX_END_LOCAL 0u      /* this side, or the pool, closed it */
#define SLOPDESK_MUX_END_PEER 1u       /* the host did; close_reason is its byte */
#define SLOPDESK_MUX_END_LINK_DOWN 2u  /* the link died; says nothing about the channel */
#define SLOPDESK_MUX_END_DECODE 3u     /* this channel's inner framing faulted; detail is lent */

// What a send did.
#define SLOPDESK_MUX_SEND_OK 0
#define SLOPDESK_MUX_SEND_CLOSED 1   /* finished, reaped, or its link is gone */
#define SLOPDESK_MUX_SEND_LINK 2     /* the write failed; the link is dying */
#define SLOPDESK_MUX_SEND_REFUSED 3  /* null handle, unknown type, or an input on CONTROL */

typedef struct SlopDeskMuxPool SlopDeskMuxPool;
typedef struct SlopDeskMuxTransport SlopDeskMuxTransport;

typedef void (*SlopDeskMuxInboundFn)(void *context, const SlopDeskWireMessage *message,
                                     const uint8_t *arena, size_t arena_len, const uint8_t *blob,
                                     size_t blob_len);

// `detail_len` is 0 for every kind but SLOPDESK_MUX_END_DECODE. Check the
// LENGTH — the pointer is non-null even when there is nothing behind it.
typedef void (*SlopDeskMuxEndedFn)(void *context, uint32_t kind, unsigned char close_reason,
                                   const uint8_t *detail, size_t detail_len);

// Dials nothing until the first channel asks it to. `connect_timeout_ms` bounds
// each dial WHOLE — both sockets and every address a hostname resolves to.
SlopDeskMuxPool *slopdesk_mux_pool_new(uint64_t connect_timeout_ms);

// Closes every pooled connection and JOINS its receive loops, so no thread this
// module started outlives it. Free every transport first.
void slopdesk_mux_pool_free(SlopDeskMuxPool *handle);

bool slopdesk_mux_pool_is_alive(const SlopDeskMuxPool *handle, const uint8_t *host, size_t host_len,
                                uint16_t port);

// Holds a connection open with no channel on it — what a client about to
// re-open a pane wants, and what the pool would otherwise reap.
bool slopdesk_mux_pool_pin(const SlopDeskMuxPool *handle, const uint8_t *host, size_t host_len,
                           uint16_t port);

void slopdesk_mux_pool_unpin(const SlopDeskMuxPool *handle, const uint8_t *host, size_t host_len,
                             uint16_t port);

size_t slopdesk_mux_pool_channel_count(const SlopDeskMuxPool *handle, const uint8_t *host,
                                       size_t host_len, uint16_t port);

size_t slopdesk_mux_pool_connection_count(const SlopDeskMuxPool *handle);

// CLASS-GENERIC: `channel_class` is the raw channelOpen byte, so one door serves
// a pane and the workspace document alike. `session_id` is 16 raw bytes, all-zero
// for a new session. `initial_cwd` NULL/0 means "wherever the host would start" —
// which is NOT the same request as an empty string, and encodes two bytes shorter.
//
// The channel is usable the moment this returns: the responder opens on the first
// channelOpen, so the ack below is a verdict about RESUME, not permission to write.
//
// NULL if the dial failed, the connection refused a channel, or a forwarder
// could not start. On NULL neither callback has run or ever will, so `context`
// may be freed at once.
SlopDeskMuxTransport *slopdesk_mux_transport_open(
    const SlopDeskMuxPool *handle, const uint8_t *host, size_t host_len, uint16_t port,
    unsigned char channel_class, const uint8_t *session_id, int64_t last_received_seq,
    const uint8_t *initial_cwd, size_t initial_cwd_len, void *context,
    SlopDeskMuxInboundFn on_inbound, SlopDeskMuxEndedFn on_ended);

// Closes, joins both forwarders, frees. `context` may be released once this
// RETURNS, never before. Never call it from inside either callback.
void slopdesk_mux_transport_free(SlopDeskMuxTransport *handle);

uint32_t slopdesk_mux_transport_channel_id(const SlopDeskMuxTransport *handle);

// Answers whether the open was ACCEPTED, and writes the seq the host will resume
// from. A refusal covers refused, dead and timed-out alike: a pane that cannot be
// told where to resume from cannot resume, so the three are one answer.
bool slopdesk_mux_transport_await_open_ack(const SlopDeskMuxTransport *handle, uint64_t timeout_ms,
                                           int64_t *resume_from_seq_out);

// There is no send_input and no note_consumed on this handle. PTY input rides
// slopdesk_pane_driver_send_input and consumption credit is issued inside
// slopdesk_pane_driver_take_output (docs/63 §G.5) — what is left here is the WORKSPACE
// channel, which is channelClass 1 and speaks control alone.

// One message on CONTROL. The record and arena are the SlopDeskWireMessage pair above.
// REFUSES an input: CONTROL is unwindowed, and a paste on it would put a 16 MiB
// frame on the lane a Ctrl-C needs.
int slopdesk_mux_transport_send(const SlopDeskMuxTransport *handle,
                                const SlopDeskWireMessage *message, const uint8_t *arena,
                                size_t arena_len, const uint8_t *blob, size_t blob_len);

// ---------------------------------------------------------------------------
// ONE PANE'S CLIENT SESSION (rust/slopdesk-ffi/src/pane_driver.rs).
//
// One handle over the whole of what SlopDeskClient.swift, ReconnectManager.swift
// and EventBroadcaster.swift decided between them: a supervisor thread, the dedup
// fold, the ack and ping tickers, the resume verdict and the retry campaign.
//
// THE POOL IS PASSED IN. _new takes a SlopDeskMuxPool rather than minting one:
// every pane to one host and the workspace document ride ONE mux, so a private
// pool would be a second TCP pair and a second client identity at the host. Make
// one pool per app and hand it to every driver. The pool must outlive them all.
//
// THREE CALLBACKS, because `event` carries two unlike things. A message crosses
// as the SlopDeskWireMessage pair above; the session's own lifecycle — a drop, a
// resume, an RTT reading, a campaign's progress — is not on the wire and crosses
// as SlopDeskPaneEvent. A wake carries NOTHING: it says the inbox is non-empty,
// and _take_output collects the bytes when the renderer is ready, which is what
// makes credit-at-consumption mean consumption.
//
// THE CALLBACK CONTRACT:
//   1. `context` stays valid until _free RETURNS. _free stops the supervisor and
//      joins every forwarder, so a callback may still be running when it is
//      entered, and none is once it answers.
//   2. All three run on a Rust thread and MAY OVERLAP — unlike the mux door's
//      pair above. Lifecycle events come from the supervisor, messages and wakes
//      from a forwarder, and the lock that would serialise them would sit on the
//      inbound byte path. Synchronise anything a callback shares.
//   3. No callback may re-enter _free: it joins the thread the callback runs on.
//      EVERYTHING ELSE IS ALLOWED and cannot deadlock. A connect or resume made
//      from inside a callback answers SLOPDESK_PANE_CONNECT_REENTRANT rather than
//      parking; a pause or close is queued and applied on the next turn of the
//      loop. Sends, readouts and drains are ordinary calls from anywhere.
//   4. Every pointer in every callback is LENT for that call. Keep nothing.
//
// _free vs _close, which is the whole detach story: _close retires the session at
// the HOST — a final ack, a clean bye — while _free leaves the host's shell and
// its replay buffer standing, which is what a client going away and coming back
// needs. Freeing without closing is DETACH, not a leak.
// ---------------------------------------------------------------------------

// Which lifecycle event a SlopDeskPaneEvent is. Every field but `kind` belongs to
// exactly one of these and is zero for the rest.
#define SLOPDESK_PANE_EVENT_ROUND_TRIP 0u   /* round_trip_ms */
#define SLOPDESK_PANE_EVENT_DISCONNECTED 1u /* the lent text */
#define SLOPDESK_PANE_EVENT_RECONNECTED 2u  /* session_id, resume_from_seq */
#define SLOPDESK_PANE_EVENT_RETRY 3u        /* attempt, delay_ms */
#define SLOPDESK_PANE_EVENT_GAVE_UP 4u      /* attempt = how many it made */
#define SLOPDESK_PANE_EVENT_LOG 5u          /* the lent text */

// What a connect or a resume did. Each is a different thing for the caller to do.
#define SLOPDESK_PANE_CONNECT_OK 0
#define SLOPDESK_PANE_CONNECT_REFUSED 1      /* closed, or the child exited. Permanent */
#define SLOPDESK_PANE_CONNECT_NO_ENDPOINT 2  /* a resume before the first connect */
#define SLOPDESK_PANE_CONNECT_OPEN 3         /* the dial failed. Retryable */
#define SLOPDESK_PANE_CONNECT_NO_VERDICT 4   /* refused, died, or timed out. Retryable */
#define SLOPDESK_PANE_CONNECT_SUPERSEDED 5   /* a close or pause landed mid-dial. STOP */
#define SLOPDESK_PANE_CONNECT_GONE 6         /* null handle, or the driver is being freed */
#define SLOPDESK_PANE_CONNECT_REENTRANT 7    /* called from inside a callback. Your bug */

// What a send did.
#define SLOPDESK_PANE_SEND_OK 0
#define SLOPDESK_PANE_SEND_CLOSED 1   /* nothing connected, or the session is finished */
#define SLOPDESK_PANE_SEND_LINK 2     /* the write failed; the link is dying */
#define SLOPDESK_PANE_SEND_REFUSED 3  /* null handle, unknown record, or an input on CONTROL */

typedef struct SlopDeskPaneDriver SlopDeskPaneDriver;

// One session-lifecycle event, flattened. `attempt` serves both RETRY and GAVE_UP
// because it is the same counter in both.
typedef struct {
    uint32_t kind;
    uint32_t attempt;
    uint64_t delay_ms;
    double round_trip_ms;
    uint8_t session_id[16];
    int64_t resume_from_seq;
} SlopDeskPaneEvent;

// How one driver is configured, fixed for its life. Both OPTIONAL parts carry an
// absence flag rather than a sentinel, because both have a legal zero: a backoff
// of zero nanoseconds is a legal schedule, and resume_last_seq == 0 is exactly
// what a cold launch presents in order to be replayed the WHOLE scrollback ring.
typedef struct {
    unsigned char channel_class;
    bool reconnects;
    bool has_resume_seed;
    uint64_t ack_interval_ms;
    uint64_t ping_interval_ms;
    uint64_t retry_initial_ns;
    uint64_t retry_maximum_ns;
    double retry_multiplier;
    uint8_t resume_session_id[16];
    int64_t resume_last_seq;
} SlopDeskPaneConfig;

// `blob_offset` in the record is always 0 here. Read the run through `blob`.
typedef void (*SlopDeskPaneMessageFn)(void *context, const SlopDeskWireMessage *message,
                                      const uint8_t *arena, size_t arena_len, const uint8_t *blob,
                                      size_t blob_len);

// `text_len` is 0 for every kind but DISCONNECTED and LOG. Check the LENGTH —
// the pointer is non-null even when there is nothing behind it.
typedef void (*SlopDeskPaneEventFn)(void *context, const SlopDeskPaneEvent *event,
                                    const uint8_t *text, size_t text_len);

// Output is waiting. LEVEL-triggered, not edge: it fires once per accepted
// `output`, so ten in a burst are ten calls whether or not you drained between
// them. Coalesce on your side — a one-slot wake whose pending value is REPLACED,
// never queued. Only that side can see whether a consumer is parked.
typedef void (*SlopDeskPaneWakeFn)(void *context);

typedef void (*SlopDeskPaneChunkFn)(void *context, const uint8_t *bytes, size_t len);

// Starts the supervisor thread. Dials nothing until _connect asks it to, so no
// callback can run for a session that has not connected.
//
// NULL if `pool` or `config` was NULL, or the thread could not start. On NULL no
// callback has run or ever will, so `context` may be freed at once.
SlopDeskPaneDriver *slopdesk_pane_driver_new(const SlopDeskMuxPool *pool,
                                             const SlopDeskPaneConfig *config, void *context,
                                             SlopDeskPaneMessageFn on_message,
                                             SlopDeskPaneEventFn on_event,
                                             SlopDeskPaneWakeFn on_wake);

// Stops the supervisor, joins every forwarder, frees the handle. `context` may be
// released once this RETURNS, never before. Never call it from inside a callback.
// Does NOT close the session at the host — see _close, and the detach note above.
void slopdesk_pane_driver_free(SlopDeskPaneDriver *handle);

// The cwd a FRESH host shell starts in, re-sent on every open. A host-side
// reattach ignores it; only a respawn reads it. NULL/0 clears it.
void slopdesk_pane_driver_set_initial_cwd(const SlopDeskPaneDriver *handle, const uint8_t *cwd,
                                          size_t cwd_len);

// BLOCKS until the dial and the handshake resolve, bounded by handshake_timeout_ms.
//
// The code says WHICH of seven things happened; `reason` says which host and why, as
// UTF-8, with `*reason_len` set to the bytes written (0 on OK, and on every arm when
// `reason` is NULL). TRUNCATED on a char boundary rather than asking for a length —
// it is a diagnostic beside a code that already carries the decision, so 256 bytes is
// generous and a second call for the tail of a log line would not be.
int slopdesk_pane_driver_connect(const SlopDeskPaneDriver *handle, const uint8_t *host,
                                 size_t host_len, uint16_t port, uint64_t handshake_timeout_ms,
                                 uint8_t *reason, size_t reason_cap, size_t *reason_len);

// Backgrounded: acks what is held, says a clean bye, tears the transport down. The
// host KEEPS the shell and its replay buffer. Idempotent.
void slopdesk_pane_driver_pause(const SlopDeskPaneDriver *handle);

// Foregrounded: reconnects with the preserved session id and seq. A no-op unless
// paused. Answers as _connect, plus NO_ENDPOINT if nothing was ever connected, and
// fills `reason` on the same terms.
int slopdesk_pane_driver_resume(const SlopDeskPaneDriver *handle, uint64_t handshake_timeout_ms,
                                uint8_t *reason, size_t reason_cap, size_t *reason_len);

// Permanently retires the session: a final ack, a clean bye, a teardown. Idempotent.
void slopdesk_pane_driver_close(const SlopDeskPaneDriver *handle);

// PTY input on DATA, split across frames at the flow-control cap. BLOCKS while the
// credit window is empty — that IS the backpressure, and it is why a stdin reader
// needs no queue of its own.
int slopdesk_pane_driver_send_input(const SlopDeskPaneDriver *handle, const uint8_t *bytes,
                                    size_t len);

// REMEMBERED, so every later connection re-asserts it — including when the send
// itself fails, which is exactly the resize the next connection must assert.
int slopdesk_pane_driver_send_resize(const SlopDeskPaneDriver *handle, uint16_t cols, uint16_t rows,
                                     uint16_t px_width, uint16_t px_height);

// One message on CONTROL. REFUSES an input: CONTROL is unwindowed, and a paste on
// it would put a 16 MiB frame on the lane a Ctrl-C needs.
int slopdesk_pane_driver_send_control(const SlopDeskPaneDriver *handle,
                                      const SlopDeskWireMessage *message, const uint8_t *arena,
                                      size_t arena_len, const uint8_t *blob, size_t blob_len);

void slopdesk_pane_driver_flush_ack(const SlopDeskPaneDriver *handle);

// Takes the WHOLE backlog in order and credits its wire bytes back. Answers how
// many payloads were handed over. A NULL on_chunk still drains and still credits.
size_t slopdesk_pane_driver_take_output(const SlopDeskPaneDriver *handle, void *context,
                                        SlopDeskPaneChunkFn on_chunk);

// Writes 16 bytes into `out`; false before the first handshake, leaving it untouched.
bool slopdesk_pane_driver_session_id(const SlopDeskPaneDriver *handle, uint8_t *out);

// What is acked, and what the next open presents.
int64_t slopdesk_pane_driver_highest_contiguous_seq(const SlopDeskPaneDriver *handle);

// One of the SLOPDESK_WS_RESUME_* bytes declared further down — the same three
// values, not a second spelling, because this readout feeds straight into
// slopdesk_ws_toast_session_resume. It gates a surface WIPE, so UNDETERMINED must
// not be read as "fresh": a stream that has produced nothing has established
// nothing.
unsigned char slopdesk_pane_driver_resume_outcome(const SlopDeskPaneDriver *handle);

// False before the first pong, leaving `out` untouched.
bool slopdesk_pane_driver_smoothed_rtt_ms(const SlopDeskPaneDriver *handle, double *out);

bool slopdesk_pane_driver_is_paused(const SlopDeskPaneDriver *handle);

// A NULL handle reads as CLOSED — the safe reading, since a caller holding
// nothing holds nothing live.
bool slopdesk_pane_driver_is_closed(const SlopDeskPaneDriver *handle);

// The remote child exited. Terminal: a later connect is REFUSED.
bool slopdesk_pane_driver_is_exited(const SlopDeskPaneDriver *handle);

// Why the HOST closed this pane's channel, as its raw byte. The gate above asks
// only WHETHER, but the reason decides what may be built next: Retired says the
// pane is gone, SubscriberEvicted says only this attachment was.
bool slopdesk_pane_driver_host_close_reason(const SlopDeskPaneDriver *handle, uint8_t *out);

// ---------------------------------------------------------------------------
// The host metadata RPC's payloads (rust/slopdesk-ffi/src/metadata.rs).
//
// Each payload crosses as a record — a LIST of them where the payload is a
// list — plus one ARENA holding every text field, each named by an
// (offset, length) pair into it.
//
// A decode takes NO probing call: the payload bounds both buffers. No arena can
// exceed the payload's own length, and no list can hold more entries than
// payload_len / fixed_bytes_per_entry, so the caller sizes from the bytes it is
// already holding and calls once. Under-sizing anyway writes NOTHING and
// answers SLOPDESK_WIRE_DECODE_AGAIN with the count a retry needs in *out_count.
//
// An encode is the §4 convention: the return is the byte count NEEDED.
// ---------------------------------------------------------------------------

typedef struct SlopDeskMetadataText {
  uint32_t offset;
  uint32_t length;
} SlopDeskMetadataText;

typedef struct SlopDeskMetadataProcess {
  uint32_t pid;
  uint32_t uptime_sec;
  SlopDeskMetadataText name;
} SlopDeskMetadataProcess;

typedef struct SlopDeskMetadataPort {
  SlopDeskMetadataText proc_name;
  uint16_t port;
  uint8_t proto;
} SlopDeskMetadataPort;

typedef struct SlopDeskMetadataDirEntry {
  SlopDeskMetadataText name;
  bool is_dir;
} SlopDeskMetadataDirEntry;

typedef struct SlopDeskMetadataGitFile {
  SlopDeskMetadataText path;
  uint8_t status_code;
} SlopDeskMetadataGitFile;

typedef struct SlopDeskMetadataGitStatus {
  SlopDeskMetadataText branch;
  SlopDeskMetadataText remote_url;
  SlopDeskMetadataText repo_root;
  int32_t ahead;
  int32_t behind;
  int32_t stash_count;
  uint32_t file_count;
  bool has_repo;
} SlopDeskMetadataGitStatus;

typedef struct SlopDeskMetadataGitCounts {
  uint32_t staged;
  uint32_t modified;
  uint32_t untracked;
  uint32_t conflicted;
} SlopDeskMetadataGitCounts;

typedef struct SlopDeskMetadataAgentSession {
  int64_t mtime_ms;
  SlopDeskMetadataText id;
  SlopDeskMetadataText title;
  SlopDeskMetadataText cwd;
  uint8_t agent_kind;
} SlopDeskMetadataAgentSession;

typedef struct SlopDeskMetadataClip {
  SlopDeskMetadataText content;
  uint8_t kind;
  bool present;
} SlopDeskMetadataClip;

typedef struct SlopDeskMetadataVitals {
  uint32_t disk_free_mib;
  uint8_t cpu_percent;
  uint8_t memory_percent;
  uint8_t pressure;
  bool has_disk;
} SlopDeskMetadataVitals;

typedef struct SlopDeskMetadataEndpoint {
  uint16_t port;
  uint8_t state;
} SlopDeskMetadataEndpoint;

/* Two flags, never folded into one: an installed hook with no bound listener exits silently, so the
 * card must be able to say installed-but-INACTIVE rather than paint a green that means nothing. */
typedef struct SlopDeskMetadataHookStatus {
  bool installed;
  bool listener_active;
} SlopDeskMetadataHookStatus;

typedef struct SlopDeskMetadataFontSpec {
  uint64_t size_bits;
  uint64_t line_height_bits;
  SlopDeskMetadataText family;
} SlopDeskMetadataFontSpec;

uint32_t slopdesk_metadata_decode_processes(const unsigned char *payload, size_t payload_len,
                                            SlopDeskMetadataProcess *records, size_t records_cap,
                                            unsigned char *arena, size_t arena_cap,
                                            size_t *out_count);

uint32_t slopdesk_metadata_decode_ports(const unsigned char *payload, size_t payload_len,
                                        SlopDeskMetadataPort *records, size_t records_cap,
                                        unsigned char *arena, size_t arena_cap, size_t *out_count);

uint32_t slopdesk_metadata_decode_dir_listing(const unsigned char *payload, size_t payload_len,
                                              SlopDeskMetadataDirEntry *records, size_t records_cap,
                                              unsigned char *arena, size_t arena_cap,
                                              size_t *out_count);

uint32_t slopdesk_metadata_decode_agent_sessions(const unsigned char *payload, size_t payload_len,
                                                 SlopDeskMetadataAgentSession *records,
                                                 size_t records_cap, unsigned char *arena,
                                                 size_t arena_cap, size_t *out_count);

uint32_t slopdesk_metadata_decode_git_status(const unsigned char *payload, size_t payload_len,
                                             SlopDeskMetadataGitStatus *out,
                                             SlopDeskMetadataGitFile *records, size_t records_cap,
                                             unsigned char *arena, size_t arena_cap,
                                             size_t *out_count);

// The fold takes the CODES, not the records: a caller folds far more often
// than it decodes — once per render of a pane's summary — and one byte per file
// is the whole input.
void slopdesk_metadata_fold_git_codes(const unsigned char *codes, size_t count,
                                      SlopDeskMetadataGitCounts *out);

// The clipboard is the one payload that ELIDES: a decode leaves the content in
// the payload and only says WHERE it is, because a clip runs to 12 MiB and the
// caller is holding those bytes already. So `out.content` names a range in the
// PAYLOAD on decode, and a range in the caller's own arena on encode.
size_t slopdesk_metadata_encode_clipboard_set(const SlopDeskMetadataClip *clip,
                                              const unsigned char *arena, size_t arena_len,
                                              unsigned char *out, size_t cap);

size_t slopdesk_metadata_encode_clipboard_read_request(int64_t last_seen_change_count,
                                                       unsigned char *out, size_t cap);

/* Verb 23's request: `[u32 cursor][utf8 buffer]`. The caret is CHARACTERS, not bytes — it is handed
 * to a shell, whose own caret is measured in characters. The working directory is deliberately NOT
 * here; it comes from the pane, exactly as `gitStatus`'s does, so the request names no host path.
 * There is no matching RESPONSE decoder: those bytes go straight into
 * `slopdesk_prompt_set_shell_candidates`, which reads them beside every other candidate source. */
size_t slopdesk_metadata_encode_shell_complete_request(uint32_t cursor,
                                                       const unsigned char *buffer,
                                                       size_t buffer_len, unsigned char *out,
                                                       size_t cap);

uint32_t slopdesk_metadata_decode_clipboard_read_response(const unsigned char *payload,
                                                          size_t payload_len, int64_t *count_out,
                                                          SlopDeskMetadataClip *out);

uint32_t slopdesk_metadata_decode_host_vitals(const unsigned char *payload, size_t payload_len,
                                              SlopDeskMetadataVitals *out);

uint32_t slopdesk_metadata_decode_service_endpoint(const unsigned char *payload,
                                                   size_t payload_len,
                                                   SlopDeskMetadataEndpoint *out);

/* Verb 13. A flag is true for the byte 1 and nothing else, and a MISSING second byte — a reply
 * predating the listener flag — reads INACTIVE. An EMPTY body is not a status and decodes as an
 * error, which is what lets the card say "connect a session" instead of a false "not installed". */
uint32_t slopdesk_metadata_decode_agent_hook_status(const unsigned char *payload,
                                                    size_t payload_len,
                                                    SlopDeskMetadataHookStatus *out);

uint32_t slopdesk_metadata_decode_code_open_disposition(const unsigned char *payload,
                                                        size_t payload_len, unsigned char *out);

/* The two vitals/endpoint bytes that are LEVELS rather than numbers cross RAW, because the field is
 * the wire's and a re-encode has to put back exactly what came in. What each byte MEANS — which
 * value is which level, and what an unrecognised one is — is a decision, and these two doors are
 * where it is asked. Both are TOTAL over every uint8_t and answer only a byte the corresponding
 * table names, so no caller needs a fallback of its own: an uninterpretable pressure level reads
 * NORMAL (never light an alarm ink this build cannot justify) and an uninterpretable service state
 * reads STARTING (keep polling; the install hint is the one surface no further poll would correct).
 * Contrast `decode_code_open_disposition` just above, which normalises inside the decode because
 * that byte has no raw field to preserve. */
uint8_t slopdesk_metadata_memory_pressure(uint8_t pressure_byte);
uint8_t slopdesk_metadata_service_state(uint8_t state_byte);

size_t slopdesk_metadata_encode_code_font_spec(const SlopDeskMetadataFontSpec *spec,
                                               const unsigned char *arena, size_t arena_len,
                                               unsigned char *out, size_t cap);

// 0 the per-clip content cap, 1 the clipboard baseline probe, 2 the
// unreadable-disk value, then the FIXED bytes one entry of each list occupies:
// 3 a process, 4 a port, 5 a directory entry, 6 a changed file, 7 an agent
// session. Those five are what lets a caller size a decode with no probing
// call — a list holds no more entries than payload_len / fixed.
int64_t slopdesk_metadata_constant(uint32_t index);

// ---------------------------------------------------------------------------
// The workspace CHANNEL payloads — what rides inside workspaceRequest (17) and
// workspaceEvent (37). The DOCUMENT entries are the slopdesk_ws_* block above;
// these are subscribe, presence, intent and the roster.
//
// Three shapes: by value where the payload is fixed-size, record-plus-arena
// where it carries text, and ELIDING for an intent's arguments, whose offsets
// are into the caller's PAYLOAD rather than any arena.
//
// A roster is panes each holding attachments, which cannot cross as a nest
// without a pointer per pane. The attachments are ONE flat array and each pane
// names its run into it.
//
// Sizing takes no probing call: every count is bounded by payload_len divided
// by the smallest a record of that kind can be, and no arena can exceed the
// payload. slopdesk_workspace_constant vends those divisors.
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t offset;
    uint32_t length;
} SlopDeskWorkspaceText;

typedef struct {
    uint32_t offset;
    uint32_t count;
} SlopDeskWorkspaceRun;

typedef struct {
    SlopDeskWsUuid client_instance_id;
    SlopDeskWsUuid known_epoch;
    int64_t known_state_num;
    SlopDeskWorkspaceText label;
    uint8_t client_kind;
    uint8_t flags;
} SlopDeskWorkspaceSubscribe;

typedef struct {
    int64_t presence_clock;
    SlopDeskWsUuid viewing_tab_id;
    SlopDeskWsUuid viewing_pane_id;
    uint16_t cols;
    uint16_t rows;
    uint8_t flags;
} SlopDeskWorkspacePresence;

typedef struct {
    SlopDeskWsUuid intent_id;
    uint8_t status;
} SlopDeskWorkspaceIntentResult;

typedef struct {
    SlopDeskWsUuid client_instance_id;
    SlopDeskWsUuid viewing_tab_id;
    SlopDeskWsUuid viewing_pane_id;
    SlopDeskWorkspaceText label;
    uint16_t cols;
    uint16_t rows;
    uint8_t client_kind;
    uint8_t flags;
} SlopDeskWorkspaceRosterClient;

typedef struct {
    SlopDeskWsUuid client_instance_id;
    uint16_t cols;
    uint16_t rows;
    bool contributes;
} SlopDeskWorkspaceRosterAttachment;

typedef struct {
    SlopDeskWsUuid pane_id;
    SlopDeskWorkspaceRun attachments;
    uint16_t resolved_cols;
    uint16_t resolved_rows;
} SlopDeskWorkspaceRosterPane;

size_t slopdesk_workspace_encode_subscribe(const SlopDeskWorkspaceSubscribe *record,
                                           const unsigned char *arena, size_t arena_len,
                                           unsigned char *out, size_t cap);

size_t slopdesk_workspace_encode_presence(const SlopDeskWorkspacePresence *record,
                                          unsigned char *out, size_t cap);

size_t slopdesk_workspace_encode_intent(const SlopDeskWsUuid *intent_id, uint8_t op,
                                        const unsigned char *args, size_t args_len,
                                        unsigned char *out, size_t cap);

size_t slopdesk_workspace_encode_intent_result(const SlopDeskWorkspaceIntentResult *record,
                                               unsigned char *out, size_t cap);

uint32_t slopdesk_workspace_decode_intent_result(const unsigned char *payload, size_t payload_len,
                                                 SlopDeskWorkspaceIntentResult *out);

// Every count is written before any array is filled, so a caller that
// under-sized is told all three sizes at once rather than one per retry.
uint32_t slopdesk_workspace_decode_roster(const unsigned char *payload, size_t payload_len,
                                          SlopDeskWorkspaceRosterClient *clients,
                                          size_t clients_cap, size_t *out_client_count,
                                          SlopDeskWorkspaceRosterPane *panes,
                                          size_t panes_cap, size_t *out_pane_count,
                                          SlopDeskWorkspaceRosterAttachment *attachments,
                                          size_t attachments_cap, size_t *out_attachment_count,
                                          unsigned char *arena, size_t arena_cap);

// 0 the label cap, 1 the per-list record cap, 2 the smallest a roster client
// record can be, 3 the smallest a roster pane record can be, 4 the exact size
// of a roster attachment record, 5 subscribe's CONTRIBUTES-SIZE flag bit,
// 6 its FOLLOWS-FOCUS bit. The last two are a MASK rather than a length, and
// they cross for the same reason: a bit position a peer disagrees about is a
// client that silently stops counting toward the PTY size fold.
// An unknown index answers -1.
int64_t slopdesk_workspace_constant(uint32_t index);
// ---------------------------------------------------------------------------
// ONE workspace subscriber's document-sync ladder — docs/59 step 10, docs/45's
// diff-against-the-ACKED-base rule. Verdicts, never the document: the tree stays
// in hostd, filed under the SLOT this door mints, and only epochs, state
// numbers and one snapshot-or-diff bit cross.
//
// Serialized by WorkspaceChannelSession's own `lock`. One _free per _new; a NULL
// or freed handle is inert (holds every offer, frees nothing, refuses presence);
// no two calls may overlap.
//
// Every call that can drop a retained state answers WHICH SLOTS stopped being
// reachable, into a caller-lent uint32_t array. Lend index 1 of
// slopdesk_workspace_sync_constant of them — the widest any single call can be —
// and the write always fits. A NULL array still answers the count, which strands
// the payloads it named.
//
// _plan and _commit are two calls because the caller computes the diff and
// awaits the channel write between them, and an NSLock cannot be held across a
// suspension. An empty diff and a dead link are then the same thing: no commit,
// so nothing moved.
// ---------------------------------------------------------------------------
// PATH 4's CLIENT end — the whole upload, behind ONE door.
// rust/slopdesk-dropd's `upload` module owns the sequence and its `client`
// module owns every layout, so the round trip is a test in that crate.
//
// It used to be eight doors with a Swift driver above them holding the socket
// and the ORDER. Every answer was right alone and nothing could check the order
// they were assembled in; with the socket in Rust there is no order left on
// this side to get wrong.
//
// slopdesk_drop_upload BLOCKS for the whole batch and reports through a
// callback — docs/55 §4b's inversion, with nothing outliving the call, so there
// is no handle and no _free. Three obligations: `context` stays valid until the
// call RETURNS; the callback runs on the CALLING thread, never concurrently and
// never afterwards; `text` is lent for one callback and a keeper copies it.
// ---------------------------------------------------------------------------

// The file was opened and offered: total_bytes is its size, text its name.
#define SLOPDESK_DROP_PROGRESS_STARTED   0u
// A chunk went out: sent_bytes and total_bytes carry it, text is empty.
#define SLOPDESK_DROP_PROGRESS_ADVANCED  1u
// The host wrote the whole body and moved it into place.
#define SLOPDESK_DROP_PROGRESS_COMPLETED 2u
// This transfer is over and the file did not land; text says why.
#define SLOPDESK_DROP_PROGRESS_FAILED    3u

typedef void (*SlopDeskDropProgressFn)(void *context, uint32_t kind, uint32_t transfer_id,
                                       uint64_t sent_bytes, uint64_t total_bytes,
                                       const unsigned char *text, size_t text_len);

// `paths` is one NUL-separated run of UTF-8 paths — `find -print0`'s separator,
// for its reason: a POSIX path holds every byte but 0, so the face needs no
// length prefix and writes no framing of its own. A file is offered under its
// INDEX, which is the transfer_id every report carries. Answers how many files
// the batch named; 0 when it named none or a path was not UTF-8, in which case
// nothing was dialled. The batch is never silent: an unreachable host fails
// every file by name.
size_t slopdesk_drop_upload(const unsigned char *host, size_t host_len, uint16_t port,
                            const unsigned char *paths, size_t paths_len,
                            uint64_t connect_timeout_ms,
                            void *context, SlopDeskDropProgressFn on_progress);


// ---------------------------------------------------------------------------
// The INSPECTOR channel's client end. rust/slopdesk-inspectord's `wire` module
// owns the frame: the 4-byte big-endian prefix, the 16 MiB cap, the three tags,
// the cursor-and-compact splitter.
//
// An event's BODY does not cross as a value: it is JSON the client parses into
// its own model, so a decode answers WHERE the body sits and the bytes stay in
// the caller's buffer.
// ---------------------------------------------------------------------------

#define SLOPDESK_INSPECTOR_OK 0u
#define SLOPDESK_INSPECTOR_PENDING 1u
#define SLOPDESK_INSPECTOR_TRUNCATED 2u
#define SLOPDESK_INSPECTOR_UNKNOWN_TYPE 3u
#define SLOPDESK_INSPECTOR_FRAME_TOO_LARGE 4u
// The body buffer was too small; `detail` says how much was needed and
// NOTHING was consumed — grow and call again.
#define SLOPDESK_INSPECTOR_AGAIN 5u

typedef struct {
    uint32_t body_offset;
    uint32_t body_length;
    // The wire type byte: 1 event, 2 keep-alive.
    uint8_t tag;
    // The offending tag, or a frame length over the cap.
    uint64_t detail;
} SlopDeskInspectorFrame;

typedef struct SlopDeskInspectorDecoder SlopDeskInspectorDecoder;

size_t slopdesk_inspector_encode_subscribe(int64_t from_seq, unsigned char *out, size_t cap);

uint32_t slopdesk_inspector_decode_payload(const unsigned char *payload, size_t payload_len,
                                           SlopDeskInspectorFrame *out);

SlopDeskInspectorDecoder *slopdesk_inspector_decoder_new(void);
void slopdesk_inspector_decoder_free(SlopDeskInspectorDecoder *handle);
void slopdesk_inspector_decoder_append(SlopDeskInspectorDecoder *handle,
                                       const unsigned char *chunk, size_t chunk_len);
uint32_t slopdesk_inspector_decoder_next(SlopDeskInspectorDecoder *handle,
                                         SlopDeskInspectorFrame *out,
                                         unsigned char *body, size_t body_cap);

// 0 the frame payload cap, 1 the length prefix's width, 2 the client's outbound
// tag. An unknown index answers -1.
int64_t slopdesk_inspector_constant(uint32_t index);


/* What a client video session says to the host, and what it does with the answers.
 *
 * The machine is six scalars and two rectangles, ALL of them read by the caller, so it crosses BY
 * VALUE — §4b — rather than as a handle a Swift `struct` copy would silently alias. A transition
 * mutates, so it steps a COPY and writes the machine back only once every lent buffer is big
 * enough: a call that did not fit is NOT a transition, and calling again with the reported shape
 * repeats the same one. A control message crosses as the encoded datagram the runtime sends. */
#define SLOPDESK_VIDEO_CLIENT_IDLE 0u
#define SLOPDESK_VIDEO_CLIENT_CONNECTING 1u
#define SLOPDESK_VIDEO_CLIENT_STREAMING 2u
#define SLOPDESK_VIDEO_CLIENT_REJECTED 3u
#define SLOPDESK_VIDEO_CLIENT_STOPPED 4u

#define SLOPDESK_VIDEO_TARGET_WINDOW 0u
#define SLOPDESK_VIDEO_TARGET_DISPLAY 1u

#define SLOPDESK_CLIENT_EFFECT_SEND_CONTROL 0u
#define SLOPDESK_CLIENT_EFFECT_PRIME_CURSOR_FLOW 1u
#define SLOPDESK_CLIENT_EFFECT_START_DECODE_PIPELINE 2u
#define SLOPDESK_CLIENT_EFFECT_STOP_DECODE_PIPELINE 3u
#define SLOPDESK_CLIENT_EFFECT_UPDATE_CAPTURE_SIZE 4u
#define SLOPDESK_CLIENT_EFFECT_APPLY_STREAM_CADENCE 5u
#define SLOPDESK_CLIENT_EFFECT_APPLY_SCROLL_OFFSET 6u
#define SLOPDESK_CLIENT_EFFECT_APPLY_CONTENT_MASK 7u
#define SLOPDESK_CLIENT_EFFECT_APPLY_DISPLAY_MAX 8u
#define SLOPDESK_CLIENT_EFFECT_APPLY_HOST_STATS 9u
#define SLOPDESK_CLIENT_EFFECT_SESSION_ENDED_BY_HOST 10u
#define SLOPDESK_CLIENT_EFFECT_SESSION_REJECTED_BY_HOST 11u

/* The scrim did not flip, so the view is not notified. */
#define SLOPDESK_SCRIM_UNCHANGED (-1)
#define SLOPDESK_SCRIM_HIDDEN 0
#define SLOPDESK_SCRIM_SHOWN 1

typedef struct {
  uint32_t state;
  uint32_t target_kind;
  uint32_t target_id;
  uint32_t stream_id;
  SlopDeskVideoSize viewport;
  SlopDeskVideoSize capture_size;
  SlopDeskVideoRect window_bounds_cg;
} SlopDeskVideoClientMachine;

/* One opaque-content rectangle, in capture pixels. */
typedef struct {
  uint16_t x;
  uint16_t y;
  uint16_t width;
  uint16_t height;
} SlopDeskVideoMaskRect;

/* One side effect. Which fields mean anything is decided by `kind`; the rest stay zero. */
typedef struct {
  uint32_t kind;
  /* SEND_CONTROL: the encoded datagram, as a run of the answer arena. */
  SlopDeskByteSpan control;
  /* START_DECODE_PIPELINE / UPDATE_CAPTURE_SIZE / APPLY_DISPLAY_MAX. */
  SlopDeskVideoSize size;
  /* START_DECODE_PIPELINE. */
  SlopDeskVideoRect bounds;
  /* APPLY_SCROLL_OFFSET. */
  int32_t dx;
  int32_t dy;
  /* The cadence, the round-trip tenths, or the band's top. */
  uint32_t first;
  /* The encode tenths, or the band's bottom. */
  uint32_t second;
  /* APPLY_CONTENT_MASK: a run of the lent rectangles. */
  uint32_t mask_offset;
  uint32_t mask_count;
  bool full_range;
} SlopDeskVideoClientEffect;

/* What one transition needs the caller to lend. */
typedef struct {
  size_t effects;
  size_t masks;
  size_t arena;
} SlopDeskVideoClientShape;

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_MUX_H */
