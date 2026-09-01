// slopdesk_ffi_workspace.h — the workspace channel, the store's own decisions, and the client control socket
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_WORKSPACE_H
#define SLOPDESK_FFI_WORKSPACE_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * channel_run — which run of the workspace channel still speaks, and what it
 * still owns.
 *
 * The client end of channelClass 1 is a loop the connection layer restarts on
 * every link: open → await the ack → subscribe → apply → ack. Nearly all of it
 * is I/O and Task discipline and stays in Swift — the two ordered drains, the
 * bounded handshake race, the optimistic patch staged into the mirror. What is
 * here is the part that is neither: the four scalars three concurrent callers
 * read to decide whether their own work is still wanted.
 *
 * THE GENERATION.  stop() and a later start() both publish, while the run they
 * superseded is still unwinding behind an await. Every publish from inside a run
 * quotes the generation it was born under, and one that no longer matches says
 * nothing — without it a channel that reconnected in the same turn reports
 * itself closed a moment after going live, and nothing reopens it.
 *
 * THE SINGLE RELEASE.  Both stop() and the run's own exit path release the
 * channel by id, and a second release tears down a pooled connection a reconnect
 * has already rebuilt under the same key. Whoever CLAIMS the id first wins:
 * release_if_owned is that claim, and it clears the slot in the same step.
 *
 * THE MONOTONE CLOCK.  The host keeps the newest presence clock per subscriber
 * and ignores anything older, so a reversal leaves everyone else looking at the
 * view the user already left, permanently. Minting is monotone here; the ORDER
 * the updates reach the wire in is the single drain's job in Swift.
 *
 * A STATE IS A PAIR.  RunState is a tag plus the .live stateNum, and both cross:
 * collapsing to the tag alone would make .live(5) and .live(6) the same state
 * and swallow every document frame after the first.
 *
 * A DEAD HANDLE.  Reads idle, refuses every start, claims nothing and mints 0.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskChannelRun SlopDeskChannelRun;

#define SLOPDESK_CHANNEL_RUN_IDLE    0
#define SLOPDESK_CHANNEL_RUN_OPENING 1
#define SLOPDESK_CHANNEL_RUN_LIVE    2
#define SLOPDESK_CHANNEL_RUN_REFUSED 3
#define SLOPDESK_CHANNEL_RUN_CLOSED  4
/* No run was admitted. Generations start at 1, so zero is unambiguous. */
#define SLOPDESK_CHANNEL_RUN_START_REFUSED 0
/* What a finish leaves the caller to do. STALE is a superseded run, which owns nothing and touches
 * nothing; QUIET and NEWS both END the current run — retire its task slot, or the next start sees a
 * run in flight forever — and only NEWS announces. */
#define SLOPDESK_CHANNEL_RUN_FINISH_STALE 0
#define SLOPDESK_CHANNEL_RUN_FINISH_QUIET 1
#define SLOPDESK_CHANNEL_RUN_FINISH_NEWS  2

SlopDeskChannelRun *slopdesk_channel_run_new(void);
void slopdesk_channel_run_free(SlopDeskChannelRun *handle);
uint8_t slopdesk_channel_run_state(SlopDeskChannelRun *handle, int64_t *state_num);
bool slopdesk_channel_run_may_send_intent(SlopDeskChannelRun *handle);
uint64_t slopdesk_channel_run_start(SlopDeskChannelRun *handle, bool run_in_flight);
bool slopdesk_channel_run_stop(SlopDeskChannelRun *handle, uint32_t *release,
                               bool *has_release);
void slopdesk_channel_run_claim(SlopDeskChannelRun *handle, uint32_t channel);
bool slopdesk_channel_run_release_if_owned(SlopDeskChannelRun *handle, uint32_t channel);
uint8_t slopdesk_channel_run_finish(SlopDeskChannelRun *handle, uint8_t tag, int64_t state_num,
                                    uint64_t generation);
bool slopdesk_channel_run_publish(SlopDeskChannelRun *handle, uint8_t tag, int64_t state_num);
int64_t slopdesk_channel_run_mint_presence_clock(SlopDeskChannelRun *handle);

// ---- Which connect attempt owns the pane, and what a drop MEANS --------------------------------
//
// One pane's client is dialled from four places — the user's "Reconnect Pane", the leaf's
// connect-on-remount `.task`, the app-connection fan-out, and the reconnect campaign — while the
// host may end the same channel underneath for two entirely different reasons. Swift owns the
// tasks, the teardown and the OUT FIFO; these four scalars are what every path reads first.
//
// THE GENERATION. `connect()` quotes a number before its handshake `await` and re-checks it after.
// Without that, a teardown landing during the suspension lets the `do` branch paint a dead pane
// `.connected` and overwrite its session id — a green dot over a torn-down transport.
//
// THE TWO HOST CLOSES ARE NOT THE SAME CLOSE. A REAP deleted the pane, and the host answers
// `channelClose` first and the document frame second: in that window every AUTOMATIC dial would
// re-open a session the host no longer holds, which is a fresh SPAWN. So a reap gates them. An
// EVICTION dropped this subscriber from a pane that is still running, and nothing will ever remove
// that pane from this client's topology — gating the automatic paths on it strands the pane
// undiallable for the process lifetime, so it does NOT gate them. Both read `.disconnected` rather
// than `.reconnecting`: no campaign follows either, and a spinner for a retry nobody is making is
// the "frozen dot" this codebase keeps closing.
//
// A DEAD HANDLE dials nothing and campaigns for nothing: `may_auto_dial` and
// `reconnect_is_welcome` answer false, `disconnect_is_quiet` and `was_closed_deliberately` answer
// true.

typedef struct SlopDeskConnectRun SlopDeskConnectRun;

/* What the host said on a `.disconnected` edge. LINK latches nothing. */
#define SLOPDESK_CONNECT_CLOSE_LINK    0
#define SLOPDESK_CONNECT_CLOSE_RETIRED 1
#define SLOPDESK_CONNECT_CLOSE_EVICTED 2

SlopDeskConnectRun *slopdesk_connect_run_new(void);
void slopdesk_connect_run_free(SlopDeskConnectRun *handle);
uint64_t slopdesk_connect_run_begin(SlopDeskConnectRun *handle);
bool slopdesk_connect_run_is_current(SlopDeskConnectRun *handle, uint64_t generation);
void slopdesk_connect_run_close_deliberately(SlopDeskConnectRun *handle);
void slopdesk_connect_run_supersede(SlopDeskConnectRun *handle);
void slopdesk_connect_run_admit_without_dialling(SlopDeskConnectRun *handle);
void slopdesk_connect_run_note_host_close(SlopDeskConnectRun *handle, uint8_t cause);
bool slopdesk_connect_run_may_auto_dial(SlopDeskConnectRun *handle);
bool slopdesk_connect_run_disconnect_is_quiet(SlopDeskConnectRun *handle);
bool slopdesk_connect_run_reconnect_is_welcome(SlopDeskConnectRun *handle);
bool slopdesk_connect_run_was_closed_deliberately(SlopDeskConnectRun *handle);

// ---- What a whole set of leaves says, and what a ring keeps -------------------------------------
//
// `slopdesk_ws_pane_*` above answers what ONE status landing on ONE pane moves. These are the other
// half of the same store: the rules handed a whole COLUMN of per-leaf facts, or a whole ring, that
// answer one thing about it. The two by-value rollups take a NULL column with a zero length as the
// empty set, which is what an empty Swift array lends: `withUnsafeBufferPointer` hands over a null
// base address, and a workspace with no progress anywhere is the state the Dock tile is usually in.
//
// No identity crosses any of them, which is what lets ONE ring door serve four call sites. A
// session id, a pane id, a palette catalogue id and a clipboard text have nothing in common as data
// and one thing in common as policy, so what crosses is a ROLE per entry and what comes back names
// POSITIONS in the list the caller still holds.
typedef struct {
    uint8_t kind;     // 0 none · 1 determinate · 2 error · 3 indeterminate — the wire's own OSC 9;4
    uint8_t percent;  // what the two value-carrying kinds hold; meaningless for the other two
} SlopDeskWsLeafProgress;
// The ERROR-DOMINANT progress rollup: any error wins, at the FIRST failing leaf's percent — a later
// failure must not rewrite the number already on screen — else any determinate at the MAX percent,
// else any spinner. No leaf having one comes back as a `kind` of 0, which is a real answer rather
// than a refusal: the same byte the door already takes on the way in.
SlopDeskWsLeafProgress slopdesk_ws_aggregate_progress(const SlopDeskWsLeafProgress *states,
                                                      size_t len);
// The completion rollup: 2 if any leaf failed, else 1 if any succeeded, else 0. A badge byte this
// build cannot name reads as NO badge — inventing a failure for a pane that reported nothing is the
// one answer that interrupts somebody for no reason.
uint8_t slopdesk_ws_rollup_completion(const uint8_t *badges, size_t len);
// Where one entry of a pushed ring came from. `index` is meaningful only for kind 0; the other two
// name entries that are not in the caller's list at all, which is why this is a flag beside a value
// rather than a position with two reserved numbers in it.
typedef struct {
    uint32_t index;  // the position in the caller's existing ring
    uint8_t  kind;   // 0 keep `index` · 1 the incoming entry · 2 the seeded previous
} SlopDeskWsRingSlot;
// The one dedupe-to-front-and-cap every ring in the store runs — the session-retention LRU, the
// pane visit ring, the palette recents, the clipboard history. `roles` carries one byte per
// existing entry, in the ring's order: 1 the entry being pushed, 2 the outgoing entry to retain,
// anything else an ordinary one, which is the reading that cannot lose an entry. `has_previous`
// says there IS an outgoing entry; when no role names it, it is SEEDED as the second slot — the
// first-switch-away case, where nothing else would have put it in the ring. A `previous` equal to
// the pushed entry is not a previous, and the near side says so by passing false. Returns the count
// NEEDED; a short or null `out` is written nothing and told the length.
size_t slopdesk_ws_ring_push(const uint8_t *roles, size_t len, bool has_previous, size_t cap,
                             SlopDeskWsRingSlot *out, size_t capacity);
// The POSITION of the first ring entry that still survives, or -1 when none does. The ring is
// never pruned, so walking past ids nothing can focus is the normal case. -1 is outside the
// answer's range by construction, which is what keeps 0 — the most common landing a visit ring
// has — a real answer.
ptrdiff_t slopdesk_ws_most_recent_survivor(const bool *survives, size_t len);

// ---- What the preference surface decides about ITSELF -------------------------------------------
//
// The settings themselves are a FILE — every key, its domain, its default and the resolver that
// repairs a bad token live in `slopdesk-settings`, and nothing below knows a path or a default.
// What is left is the three decisions the app makes about its own preference surface, none of
// which a config file can state.
//
// No string crosses any of them. A suite name is the caller's own (one built from its pid, one read
// out of its environment) and a hint regex is the user's own text; the rules read one BIT of each,
// so what travels is that bit and what comes back names POSITIONS the caller reads its own arrays
// at — `slopdesk_ws_ring_push`'s convention, at two more call sites.
//
// Which `UserDefaults` suite this process binds its session STATE to: 0 the standard domain, 1 a
// per-process throwaway suite, 2 the one the environment names. The XCTest suite wins outright — a
// stray automation variable in a developer's shell must not put parallel workers back onto one
// shared domain. `(named, named_len)` is the VALUE, not the variable's name; a null pointer, a zero
// length and bytes that are not UTF-8 all read as no override: an unset variable and one set
// to the empty string are the same decision and a half-decoded name would bind a different domain
// silently.
uint8_t slopdesk_ws_state_suite_source(bool under_test, const uint8_t *named, size_t named_len);
// The size the terminal draws at: what the file states plus whatever ⌘± moved it by, held inside
// the 8..32 zoom band. That band is NOT `terminal.font-size`'s domain — the table owns 4.0..=96.0,
// which is what a reader may WRITE; this is the narrower one a key press may reach. NaN-faithful:
// `fmax`/`fmin` ordering, so a NaN takes a bound rather than reaching a font descriptor.
double slopdesk_ws_font_size_effective(double configured, double delta);
// The answer one zoom chord gives. `moved` is a flag beside the value rather than a sentinel inside
// it: a `delta` of 0.0 is exactly what ⌘0 lands on, so it is the most common REAL answer this door
// gives and no number could have meant "the press moved nothing".
typedef struct {
    double delta;  // the new runtime delta, in points from the size the file states
    bool   moved;  // read `delta` only when this is true
} SlopDeskWsFontZoom;
// The new runtime delta one press lands on. `press` is 0 ⌘+ · 1 ⌘- · 2 ⌘0; a byte this build cannot
// name is read as a RESET, the only reading that cannot leave the terminal at a size nobody asked
// for. A press against either edge of the band answers `moved` false, and so does ⌘0 at a delta of
// zero — the refusal is what stops a held key re-publishing an identical terminal configuration
// through a generation counter that bumps unconditionally.
SlopDeskWsFontZoom slopdesk_ws_font_zoom(double configured, double delta, uint8_t press);
// One surviving Hint Mode pattern, as a position in the caller's own list.
typedef struct {
    uint32_t pattern;     // which entry of the pattern list, never the position in this answer
    bool     has_action;  // whether the action list carries a template at that same index
} SlopDeskWsHintSlot;
// The zip of the two parallel Hint Mode lists. The file carries the regexes and actions as two
// arrays rather than an array of tables, so the pairing is this side's rule and it has three cases
// the file's shape cannot express: an empty PATTERN is dropped (an empty regex matches everything),
// an action list SHORTER than the pattern list leaves the trailing patterns without one, and an
// empty ACTION is no action exactly as an absent one is. Both inputs carry one EMPTINESS flag per
// entry, in the file's order. Returns the count NEEDED; a short or null `out` is written nothing
// and told the length.
size_t slopdesk_ws_hint_patterns(const bool *patterns_empty, size_t patterns_len,
                                 const bool *actions_empty, size_t actions_len,
                                 SlopDeskWsHintSlot *out, size_t capacity);

// ---- What one gesture moved, and what one launch asks for --------------------------------------
//
// The store's SHAPE questions. Two of them compare two flattenings of the same trees — which
// divider the drag moved, which pane the swap put where — and the rest are the launch seam: what
// the automation environment describes, and what the four named scrolls fire.
//
// No identity crosses. A split id and a pane id are UUIDs, so the near side mints a dense TOKEN per
// distinct id, one table spanning BOTH snapshots of a comparison, and the answers come back as
// POSITIONS into the list the caller still holds. A split's children are the maximal RUN of slots
// carrying its token, which is what a depth-first flattening already produces.
typedef struct {
    double   weight;   // the slot's own weight; meaningless when `is_flex` is false
    uint32_t split;    // the token of the split this slot is a child of
    bool     is_flex;  // false => a fixed child, which owns no share of the divider
} SlopDeskWsWeightSlot;
// The leading child's share of `split`'s divider at `index`, or false when that slot is not a flex
// child of that split. A null `out` asks only whether there is an answer.
bool slopdesk_ws_leading_weight(const SlopDeskWsWeightSlot *rows, size_t len, uint32_t split,
                                size_t index, double *out);
// The one weight that differs between two flattenings, as the split it belongs to plus the POSITION
// of the changed child. `found` false => nothing moved, which is the ordinary answer for every
// gesture that was not a divider drag.
typedef struct {
    double   weight;
    size_t   index;
    uint32_t split;
    bool     found;   // false => ignore every field above
} SlopDeskWsWeightChange;
// A gesture moves ONE divider, so the first difference in emission order IS the difference. Two
// moved weights answer the first, where the Swift walked a dictionary and answered an arbitrary
// one — no caller stages two.
SlopDeskWsWeightChange slopdesk_ws_changed_divider_weight(const SlopDeskWsWeightSlot *before,
                                                          size_t before_len,
                                                          const SlopDeskWsWeightSlot *after,
                                                          size_t after_len);
// The POSITION in `before` of the pane a swap moved `active` out of the way of, or -1 when the two
// flattenings do not describe one swap. -1 is outside the answer's range by construction, so 0 —
// swapping with the first pane — stays a real answer.
ptrdiff_t slopdesk_ws_swap_partner(const uint32_t *before, size_t before_len, const uint32_t *after,
                                   size_t after_len, uint32_t active);
// The BYTE offset of the `=` in a `SLOPDESK_…=value` launch argument, or -1 when the argument is not
// one. An offset rather than two strings because nothing needs to be allocated to split at it, and
// both halves either side of a `=` are whole UTF-8 by construction.
ptrdiff_t slopdesk_ws_automation_override(const uint8_t *argument, size_t len);
// Whether the terminal-autoconnect vars describe a target at all, and what port they name. An unset
// var and one set to nothing are the same answer, so both arrive as bytes and the empty case is not
// branched on twice.
bool slopdesk_ws_terminal_target_port(const uint8_t *host, size_t host_len, const uint8_t *port,
                                      size_t port_len, uint16_t *out);
// Which layout one set of automation inputs describes: 0 the default workspace, 1 the terminal
// autoconnect, 2 the video one. Video takes precedence. Only the MINTING stays on the near side,
// because a tree carries pane ids and those never cross.
uint8_t slopdesk_ws_bootstrap_kind(bool has_video, bool has_terminal);
// The inspector's second channel, one port above the terminal's (docs/16, docs/20 §0), or -1 when
// there is no room above it. The offset and the arithmetic that applies it are ONE decision, so
// neither is spelled on the near side; -1 can never collide with a `uint16_t` answer.
int32_t slopdesk_ws_inspector_port(uint16_t terminal);
// The libghostty named binding action one of the four viewport scrolls fires — 0 page up, 1 page
// down, 2 top, 3 bottom. Two conventions live in those strings and neither survives being written
// twice: the SIGN (negative is up, toward older scrollback) and the FRACTION (0.9 ≈ a page minus a
// sliver of overlap, deliberately not copy mode's half page). Returns the bytes NEEDED; a short or
// null `out` is written nothing and told the length.
size_t slopdesk_ws_scroll_action(uint8_t code, uint8_t *out, size_t cap);
// One tab of the flattened workspace, carrying only the four facts a device focus reads.
typedef struct {
    uint32_t session;         // the token of the session this tab belongs to
    bool     holds_pane;      // the focused pane is in this tab
    bool     is_focus_tab;    // this is the tab the device focus names
    bool     zoom_is_target;  // this tab's zoom is showing that same pane
} SlopDeskWsFocusTab;
// Where a device focus lands, as a POSITION into the flat tab list the caller built.
typedef struct {
    size_t tab;
    bool   resolved;      // false => the tab or pane is gone; host truth shows through
    bool   focuses_pane;  // also write the pane, not just the tab
    bool   clears_zoom;   // the zoom-exit rule fired: focus must not land on a hidden pane
} SlopDeskWsFocusLanding;
// The device-focus overlay, run through the SAME `focus_pane` op the intent applier uses — over a
// skeleton built from the facts above, so the zoom-exit rule is not spelled a second time.
SlopDeskWsFocusLanding slopdesk_ws_device_focus_landing(const SlopDeskWsFocusTab *tabs, size_t len,
                                                        bool has_pane);

// ---- The connect gate --------------------------------------------------------------------------
//
// The app-global link's six decisions: what one drained OUT batch is actually sent as, what the
// recent-hosts menu becomes after a connect, what a thrown error says, what the form's four fields
// parse to, and what a reconnect callback does to the status it lands on.
//
// The first of those is the only one on the keystroke path, and it takes no keystrokes. The rule
// reads LENGTHS — merging two adjacent inputs is addition, splitting an oversized one is division,
// and the barrier is the event's kind — so what crosses is one record per buffered event and what
// comes back names `(offset, length)` slices of the caller's OWN concatenated blob. A pasted
// megabyte crosses as the same handful of records a single keystroke does. The form's parse answers
// its host the same way and for the same reason: trimming is the only thing it did to it.
typedef struct {
    size_t   length;  // input only: how many bytes this event puts in the batch's blob
    uint16_t cols;    // resize only
    uint16_t rows;    // resize only
    uint8_t  kind;    // 0 input · 1 resize — anything else contributes nothing and is DROPPED
} SlopDeskWsOutEvent;
typedef struct {
    size_t   offset;  // input only: where in the caller's blob this frame starts
    size_t   length;  // input only: how far it runs — never 0
    uint16_t cols;    // resize only
    uint16_t rows;    // resize only
    uint8_t  kind;    // 0 input · 1 resize
} SlopDeskWsOutFrame;
// The frames one drained OUT batch should be sent as, in send order: resizes coalesced LATEST-WINS
// with input as a hard barrier, then adjacent input payloads merged and oversized ones split at
// `max_input_frame_bytes`. The last resize of every batch always survives — the trailing-edge
// guarantee, which is what makes the final drag size reach the PTY by construction rather than by a
// timer that could be dropped. A ceiling of 0 is clamped to 1 rather than refused. Returns the count
// NEEDED; the bound worth lending is one frame per event plus
// ceil(total_input_bytes / max_input_frame_bytes).
size_t slopdesk_ws_out_batch_plan(const SlopDeskWsOutEvent *events, size_t count,
                                  size_t max_input_frame_bytes, SlopDeskWsOutFrame *out,
                                  size_t capacity);
// One entry in the gate's recent-hosts menu. The host and the mux port are the entry's IDENTITY; the
// video ports are settings, which is why a re-connect that changed only those REPLACES its entry.
typedef struct {
    SlopDeskWsSpan host;
    uint16_t       port;
} SlopDeskWsRecentTarget;
// The menu after one successful connect, as positions into a VIRTUAL list where 0 is the candidate
// and i + 1 is `entries[i]`. The virtual index is what lets one answer carry the dedupe, the
// push-front and the cap at once — and why an entry the candidate replaced comes back as the NEW
// target's ports rather than the stale ones it matched on. A span that does not resolve reads as an
// empty host, which is the reading that cannot silently match a real one. Returns the count NEEDED,
// which is at most `limit`.
size_t slopdesk_ws_recent_targets_push(SlopDeskWsSpan host, uint16_t port,
                                       const SlopDeskWsRecentTarget *entries, size_t count,
                                       const uint8_t *blob, size_t blob_len, size_t limit,
                                       uint32_t *out, size_t capacity);
// The user-facing reason for a thrown connect error: the localized description when it has WORDS,
// else the readable payload behind it. An `Error` cannot cross a C ABI, so what crosses is what the
// near side can get out of one. A description that is present but blank has told the user nothing,
// which is why empty and absent are deliberately ONE case here and not two.
size_t slopdesk_ws_failure_reason(const uint8_t *localized, size_t localized_len,
                                  const uint8_t *fallback, size_t fallback_len, uint8_t *out,
                                  size_t cap);
// The target the connect form's four fields parse to, or the refusal they earn. `hint` is the guard:
// non-zero => every other field is meaningless, and the refused case is zeroed rather than
// undefined, so a near side that forgets the guard dials nothing instead of something arbitrary.
typedef struct {
    size_t   host_offset;  // the TRIMMED host, into the `host` bytes the caller lent
    size_t   host_length;
    uint16_t port;
    uint16_t media_port;
    uint16_t cursor_port;
    uint8_t  hint;         // 0 => the fields parse; else the code the door below turns into words
} SlopDeskWsConnectTarget;
// ONE verdict for both readings the gate needs — whether Connect is live, and what the hint under it
// says — because they are one fact: `hint == 0` IS `canConnect`. Every field is trimmed, and the trim
// is Unicode White_Space, so a host pasted with a trailing newline is accepted rather than refused. A
// port of 0 earns the same refusal a non-numeric one does: it is the kernel's "pick one for me",
// which a client dialling OUT cannot use.
SlopDeskWsConnectTarget slopdesk_ws_connect_gate_parse(const uint8_t *host, size_t host_len,
                                                       const uint8_t *port, size_t port_len,
                                                       const uint8_t *media_port,
                                                       size_t media_port_len,
                                                       const uint8_t *cursor_port,
                                                       size_t cursor_port_len);
// What a refusal code says. 0 — no refusal — delivers nothing, which is the ABI's own "no answer",
// and so does a code this build cannot name: a hint with no words is a hint the near side does not
// draw, and inventing one would put a second vocabulary beside the rule's.
size_t slopdesk_ws_connect_gate_hint(uint8_t code, uint8_t *out, size_t cap);
// What one reconnect-campaign callback does to the status it lands on: 0 leave it alone, 1 adopt
// reconnecting, 2 adopt unreachable. `status` is a SLOPDESK_CONNECTION_STATUS_* code — the same
// vocabulary every other connection door takes. The attempt count and the next-retry instant
// deliberately do not cross: they are the caller's payload for the status it adopts, and the rule
// reads neither. `gave_up` picks which of the two callbacks this is, and both read the same two
// states, which is why they are one door.
uint8_t slopdesk_ws_reconnect_fold(uint32_t status, bool deliberately_closed, bool gave_up);

// ---- A video pane's readout --------------------------------------------------------------------
//
// What the chrome over a live desktop stream SAYS: five telemetry rows, three number formatters, a
// stall caption, the cap-gated placeholder, the two quality-choice labels and the marks an upload
// wears. It lived in a Swift enum one floor under two renderers and named no view type anywhere.
//
// EVERY READING IS ABSENT, NEVER WRONG. A stat with no sample prints an em dash and not `0`; a
// stall with no epoch prints `RECONNECTING` and no age. That is why the sample below is ten values
// with ten presence FLAGS beside them: a measured zero and a stream nothing has sampled yet are
// different facts, and no number could have carried the difference.
//
// The formatters are printf's — `%.1f` and `%.0f`, exact conversion with ties broken to even.
typedef struct {
    double  stats_fps;                     // the ~2 Hz mirror's received rate
    double  stats_fec_per_sec;
    double  stats_unrecovered_per_sec;
    double  stats_rtt_ms;
    double  stats_encode_ms;
    double  stats_decode_ms;
    int64_t stream_fps;                    // host-announced cadence
    int64_t stream_kbps;                   // client-measured payload bitrate
    int64_t stats_pacer_depth;
    int64_t stats_hold_ms;
    bool    has_stats_fps;                 // one flag per value, IN THE SAME ORDER
    bool    has_stats_fec_per_sec;
    bool    has_stats_unrecovered_per_sec;
    bool    has_stats_rtt_ms;
    bool    has_stats_encode_ms;
    bool    has_stats_decode_ms;
    bool    has_stream_fps;
    bool    has_stream_kbps;
    bool    has_stats_pacer_depth;
    bool    has_stats_hold_ms;
} SlopDeskWsGuiTelemetry;
size_t slopdesk_ws_gui_stat_rows(SlopDeskWsGuiTelemetry stats, uint8_t *out, size_t cap);  // 5 runs
// The three formatters, each on its own so a caller holding ONE number need not build a sample.
// A false `has_*` answers the absent form: an em dash, or `—/S` for a rate, still reading as one.
size_t slopdesk_ws_gui_mbps_label(bool has_kbps, int64_t kbps, uint8_t *out, size_t cap);
size_t slopdesk_ws_gui_per_sec_label(bool has_value, double value, uint8_t *out, size_t cap);
size_t slopdesk_ws_gui_ms_label(bool has_value, double value, uint8_t *out, size_t cap);
// `RECONNECTING`, plus a floored, zero-clamped age once the stall's epoch is known. `elapsed` is
// SECONDS and not an instant: the caller owns the clock, exactly as `slopdesk_ws_settle_step`
// has it, so the rule can be asked about a chosen moment.
size_t slopdesk_ws_gui_stall_caption(bool has_since, double elapsed, uint8_t *out, size_t cap);
// What the non-live placeholder says, for a display of 0 live, 1 entry form, 2 cap-gated. The gated
// state names its own CAUSE; a code this build cannot name answers the neutral word instead of
// accusing a cap that may not be saturated.
size_t slopdesk_ws_gui_placeholder_label(uint8_t display, uint8_t *out, size_t cap);
// The two quality labels. `0` is not a quantity on either axis — it is the ABSENCE of a cap, so
// both print "Auto" rather than a digit that would read as "cap the stream at zero frames".
size_t slopdesk_ws_gui_fps_choice_label(int64_t fps, uint8_t *out, size_t cap);
size_t slopdesk_ws_gui_mbps_choice_label(int64_t mbps, uint8_t *out, size_t cap);
// Mbps at the surface, bps on the model and the wire. The first TRUNCATES, because the picker has
// no fractional row to land on; the second SATURATES, because a panic here aborts the process. `0`
// stays `0` through both, which is Auto on either side.
int64_t slopdesk_ws_gui_mbps_from_bps(int64_t bps);
int64_t slopdesk_ws_gui_bps_from_mbps(int64_t mbps);
// Whether any LATCHED mode is engaged — what the control bar tints and the collapsed chip inherits,
// so folding the bar away never hides a status light. Both caps are `!= 0`, because `0` is Auto and
// a negative cap is a corrupt setting that is still not Auto.
bool slopdesk_ws_gui_has_latched_mode(bool immersive, bool viewport_locked, bool audio_enabled,
                                      int64_t stream_fps_cap, int64_t stream_bitrate_ceiling_bps);
// The video activation task's identity, as `hash:generation:visible`. Three components because a
// pane returning to screen is never remounted: a key that ignored visibility would leave it waiting
// for a remount that never comes.
size_t slopdesk_ws_gui_activation_key(int64_t pane_hash, int64_t promotion_generation,
                                      bool is_visible, uint8_t *out, size_t cap);
// The upload row's SF Symbol name and its TONE (0 the resting icon tone, 1 the accent), for a phase
// of 0 sending, 1 completed, 2 failed. A colour never crosses — only the branch does. A code this
// build cannot name reads as still-sending, because the other two claim the transfer SETTLED.
size_t  slopdesk_ws_gui_upload_glyph(uint8_t phase, uint8_t *out, size_t cap);
uint8_t slopdesk_ws_gui_upload_tint(uint8_t phase);
// A `double` that lands on the Swift BIT: the fraction is ONE division of two `u64`s widened to
// `f64` — no accumulation, no `fma`, no reassociation — so IEEE-754 gives both languages the
// identical bit pattern for the identical pair. A zero total answers 0.0 rather than a NaN the bar
// would render as a blank.
double  slopdesk_ws_gui_upload_fraction(uint8_t phase_code,
                                        uint64_t sent_bytes, uint64_t total_bytes);
// Whether the upload has SETTLED — completed or failed — the cue its row's dismissal is scheduled
// on. Failure settles as surely as success does.
bool    slopdesk_ws_gui_upload_is_settled(uint8_t phase_code);

// ---- What a live video pane admits --------------------------------------------------------------
//
// The other half of `slopdesk_ws_gui_*` above, and they do not overlap: that one RENDERS a reading,
// these decide whether the reading is a reading at all. They were nine guards inside a Swift
// `@Observable` class, each sitting in front of the property write it protected; the writes stayed
// there and the guards came here.
//
// A ZERO IS NOT ONE THING, and deliberately not uniform. A cadence of 0 is nonsense, so it is
// dropped and the last good announcement stands. A bitrate of 0 is what an idle stream measures, so
// it is kept. A latency of 0 is the ABSENCE of a reading — an old host, telemetry off, a window
// still filling — so it becomes a false `has_*` and the readout draws a dash.
typedef struct {
    double  fps;                  // frames per second received
    double  fec_per_sec;
    double  unrecovered_per_sec;
    double  rtt_ms;               // 0 on these three means NOT REPORTED, not a link with no delay
    double  encode_ms;
    double  decode_ms;
    int64_t hold_ms;
    int64_t pacer_depth;
} SlopDeskWsStreamSample;
typedef struct {
    double  fps;
    double  fec_per_sec;
    double  unrecovered_per_sec;
    double  rtt_ms;               // meaningless when `has_rtt_ms` is false
    double  encode_ms;
    double  decode_ms;
    int64_t hold_ms;
    int64_t pacer_depth;
    bool    admitted;             // false => the sample was refused; every field above is junk
    bool    has_rtt_ms;
    bool    has_encode_ms;
    bool    has_decode_ms;
} SlopDeskWsStreamReading;
// One ~2 Hz sample as a reading. ALL OR NOTHING: a negative or a NaN on ANY axis refuses the whole
// window rather than mixing a trustworthy frame rate with a garbage loss count. `admitted` is a
// flag and not a zeroed struct because an all-zero sample is a perfectly legal reading — an idle
// stream measures exactly that — so "refused" and "every axis read zero" had to be different words.
SlopDeskWsStreamReading slopdesk_ws_stream_network(SlopDeskWsStreamSample sample);
// The two admission gates that are one number each, and they disagree about zero on purpose.
bool slopdesk_ws_stream_admits_fps(int64_t fps);
bool slopdesk_ws_stream_admits_kbps(int64_t kbps);
typedef struct {
    double current_width;         // meaningless when `has_current` is false
    double current_height;
    double max_width;             // meaningless when `has_max` is false
    double max_height;
    bool   has_current;
    bool   has_max;
} SlopDeskWsStreamGeometry;
// What one geometry push writes: each size is admitted only when BOTH its axes are positive, and
// the two are judged apart — a host that has reported its window but not yet its display bounds
// sends a real current size beside a zero max. A false `has_max` does NOT mean there is no maximum;
// it means this push carried none, and the near side leaves the cap it already knows standing.
SlopDeskWsStreamGeometry slopdesk_ws_stream_geometry(double current_width, double current_height,
                                                     double max_width, double max_height);
typedef struct {
    bool desired;                 // the latched wish after the fold — always what was asked
    bool fullscreen_override;     // the fullscreen auto-arm after the fold
    bool notifies;                // whether the wish MOVED, and so whether the spec is rewritten
} SlopDeskWsStreamImmersive;
// The immersive toggle's fold. An explicit OFF drops the fullscreen auto-arm with it, BEFORE the
// redundant-set dedup: fullscreen arms system-key capture on its own, so without that clause a user
// in fullscreen who turns immersive off would watch the keyboard stay captured with no in-stream
// way out — the failure `docs/DECISIONS.md` records as the Moonlight lesson.
SlopDeskWsStreamImmersive slopdesk_ws_stream_immersive(bool on, bool desired,
                                                       bool fullscreen_override);
typedef struct {
    int64_t fps_cap;              // 0 is Auto
    int64_t bitrate_ceiling_bps;  // 0 is Auto
} SlopDeskWsStreamCaps;
// A restored mode snapshot's two overrides, floored at 0 — which is Auto, the value a fresh session
// already holds. A negative cap in a hand-edited workspace file must not travel to the host as a
// request, and refusing the whole restore over one bad number would lose the three modes beside it.
SlopDeskWsStreamCaps slopdesk_ws_stream_seeded_caps(int64_t fps_cap, int64_t bitrate_ceiling_bps);
// The window id an entry field holds, or false. A flag beside an out-parameter rather than a
// sentinel: every uint32_t is a legal CGWindowID, including 0, so nothing was left over to mean
// "not a number". A null `out` asks only whether there is an answer.
//
// This is Swift's UInt32(_:) over Swift's CharacterSet.whitespaces, spelled out, because Rust's
// trim/parse disagree twice and both are reachable by pasting into the field: Rust's trim also eats
// the line breaks (so "42\n" would OPEN where Swift refused), and Rust's parse rejects "-0" where
// Swift accepts it as 0. Measured against the Swift runtime, not remembered.
bool slopdesk_ws_stream_window_id(const uint8_t *entered, size_t len, uint32_t *out);
// What the opened descriptor is CALLED: the bound title, or `window <id>` when it has none. The id
// crosses as DISPLAY DATA, the way slopdesk_ws_gui_activation_key's pane hash does — it is not
// compared, resolved or handed back, and a window with no title has nothing else to be called.
size_t slopdesk_ws_stream_title(const uint8_t *title, size_t len, uint32_t window_id, uint8_t *out,
                                size_t cap);
// What the placeholder says when the host REFUSES the session — the target is gone on the host, or
// the two halves disagree about the protocol. Quoted typographically when there is a title, named
// generically when there is not, so it reads as a sentence either way. Neither door here has an
// empty arm, so §4's 0 never collides with a real answer at either.
size_t slopdesk_ws_stream_rejection(const uint8_t *title, size_t len, uint8_t *out, size_t cap);

// ---- The host-windows rail's fold ---------------------------------------------------------------
//
// `docs/45` §1 names the UX in one word: STABILITY. The host re-sends its whole window list twice a
// second, so a rail that followed the snapshot's order would shuffle rows under the pointer on
// every focus flip and title change. The fold FREEZES positions instead — a window that survives
// keeps the place it had, and only a genuinely new one is appended.
//
// NO WINDOW CROSSES, ONLY POSITIONS. A CGWindowID and a bundle id are identity, so the near side
// mints one dense TOKEN per distinct window across BOTH lists — one table spanning the comparison,
// the shape `slopdesk_ws_weight_change` already uses for two flattenings — and the answer names
// positions in the two arrays the caller still holds. The bundle id, the app name and the title
// never travel at all.
typedef struct {
    uint32_t index;   // a position in the existing structure, or in the snapshot
    bool     is_new;  // false => `index` is into the structure; true => into the snapshot
} SlopDeskWsFeedFoldSlot;
// The structure after one snapshot: survivors in the order they already had, then the newcomers in
// the order the host sent them. Nothing is ever reordered, which is why this is a plan and not a
// sort. A snapshot naming the same window TWICE appends it twice — the "already known" set is
// computed once, before the append pass, exactly as the Swift did; the host emits no duplicates and
// quietly changing what a malformed one produces would be a behaviour change hiding inside a port.
// Returns the count NEEDED; a short or null `out` is written nothing and told the length. The near
// side lends structure + snapshot, which is the arithmetic bound, so the retry is never travelled.
size_t slopdesk_ws_feed_structure_plan(const uint32_t *structure, size_t structure_len,
                                       const uint32_t *snapshot, size_t snapshot_len,
                                       SlopDeskWsFeedFoldSlot *out, size_t capacity);
// The POSITION of the host's focused window in the snapshot, or -1 when none is focused. At most
// one window per snapshot carries the flag, so the first is the answer. -1 is outside a position's
// range by construction — the slopdesk_ws_most_recent_survivor precedent — which keeps 0 a real
// answer, and the frontmost window is often first in z-order.
ptrdiff_t slopdesk_ws_feed_frontmost(const bool *focused, size_t len);
// The rail's display title: the window's own, or the app's name when the window has none. A great
// many windows are untitled and a blank row is unclickable, while the app name is always there.
// This is the one door in the two sections whose EMPTY answer is REAL — an untitled window
// belonging to an unnamed app — so its caller maps §4's 0 to "" rather than to a refusal.
size_t slopdesk_ws_feed_display_title(const uint8_t *title, size_t title_len,
                                      const uint8_t *app_name, size_t app_len, uint8_t *out,
                                      size_t cap);
// Whether a "you are current" ack may mark the feed LIVE — only when it names the generation this
// client actually holds. A stale or duplicated datagram acking an older generation is not
// confirmation of what we have, and UDP delivers both.
bool slopdesk_ws_feed_ack_marks_live(bool is_live, uint32_t acked, uint32_t known);
// Whether the renewal interval that just elapsed makes the feed stale: no answer, reply or push,
// for two full renewal gaps plus the first-answer gap. UDP weather loses single datagrams, not
// multi-second stretches, so one missed reply must not dim a rail that is fine. `has_elapsed` false
// means nothing has ever answered, which is not staleness — it is the state before any interval has
// been timed. Durations are NANOSECONDS and the grace SATURATES: a panic here aborts the process.
bool slopdesk_ws_feed_goes_stale(bool is_live, bool answered_since_open, bool has_elapsed,
                                 int64_t elapsed_ns, int64_t renewal_ns, int64_t first_answer_ns);
// How long to wait before the next renewal, in NANOSECONDS: the fast retransmit gap until the FIRST
// answer lands on a freshly opened lane, the ordinary gap after that. A collapsed rail never gets
// this at all — it releases the lane and idles at 0 Hz.
int64_t slopdesk_ws_feed_renewal_wait_ns(bool answered_since_open, int64_t renewal_ns,
                                         int64_t first_answer_ns);

// ---- The live-video admission ledger ------------------------------------------------------------
//
// The concurrent live-video ceiling of docs/22 §7: each video pane owns a decompression session, a
// display link and a Metal renderer, so the cap bounds decode + composite cost — the part a shared
// UDP flow between same-host panes does not make cheaper.
//
// A HANDLE, because three sets of facts outlive every call — the ceiling, who is decoding, who has
// closed but not finished letting go — and the store mutates them from four contexts.
//
// IDENTITY DOES NOT CROSS. A `PaneID` is a UUID; the near side mints a dense `uint32_t` per pane and
// lends that. The door's only claim about a token is that two equal tokens name one pane.
//
// Every reading OFF a live pane crosses as an ARGUMENT — is this a video pane, is it decoding right
// now, did the activation take. The ledger never flips a pane on; it is told what happened and
// answers what may happen next. The promotion generation it returns moves ONLY on the transitions
// that actually free a slot, which is what a cap-gated placeholder re-reads to un-gate itself.

typedef struct SlopDeskWsVideoSlots SlopDeskWsVideoSlots;

// A ledger with a ceiling of `cap` concurrent decoding panes. A cap of 0 admits nothing.
SlopDeskWsVideoSlots *slopdesk_ws_video_slots_new(size_t cap);
void slopdesk_ws_video_slots_free(SlopDeskWsVideoSlots *handle);
// The verdict on a request to make `token` decode: 0 refuse (no slot, or not a video pane at all),
// 1 already live (report success, re-activate nothing), 2 proceed (activate, then report back with
// `note_live` what the pane ACTUALLY did). `is_video` and `already_live` are read off the live pane
// handle the far side has never seen.
uint8_t slopdesk_ws_video_slots_admit(SlopDeskWsVideoSlots *handle, uint32_t token, bool is_video,
                                      bool already_live);
// Whether a slot is free FOR `token` right now — the pure read, no mutation. Self-excluding and
// releasing-aware, so it agrees with what an `admit` this same tick would decide. This is what tells
// a gated pane's two reasons apart: the cap is full, versus this pane simply is not on.
bool slopdesk_ws_video_slots_admits(SlopDeskWsVideoSlots *handle, uint32_t token);
// Records what `token`'s pane actually IS after something flipped it: the confirm-read after an
// activation, and the resync after a pause or a resume moved the flag directly.
void slopdesk_ws_video_slots_note_live(SlopDeskWsVideoSlots *handle, uint32_t token, bool live);
// `token` stops decoding while staying OPEN. `was_live` is the reading taken before the pane was
// stood down. Returns the promotion generation to publish.
int64_t slopdesk_ws_video_slots_stand_down(SlopDeskWsVideoSlots *handle, uint32_t token,
                                           bool was_live);
// `token` CLOSED. `holds_stack` is the reading taken before teardown nils it: a video pane that was
// really decoding keeps its slot booked until `release`, because the session is still being torn
// down and a pane promoted into that slot would contend with it. Returns the generation to publish.
int64_t slopdesk_ws_video_slots_orphan(SlopDeskWsVideoSlots *handle, uint32_t token,
                                       bool holds_stack);
// Whether `token`'s decode stack is still letting go — the guard on the caller's settle sleep.
bool slopdesk_ws_video_slots_is_releasing(SlopDeskWsVideoSlots *handle, uint32_t token);
// `token`'s decode stack is released. A token that was not booked freed nothing and the generation
// does not move. Returns the generation to publish.
int64_t slopdesk_ws_video_slots_release(SlopDeskWsVideoSlots *handle, uint32_t token);
// Forgets every releasing token, for a caller that has drained every teardown it spawned. Silent by
// design: a repair does not announce a slot as newly free.
void slopdesk_ws_video_slots_clear_releasing(SlopDeskWsVideoSlots *handle);
// The promotion generation as it stands.
int64_t slopdesk_ws_video_slots_generation(SlopDeskWsVideoSlots *handle);

// ---- The workspace store's own decisions --------------------------------------------------------
//
// Whether a pane may dial, which of two racing writes of the layout wins, whose picture the document
// cache holds, and the revision every projection of the document is keyed on.
//
// A HANDLE for the same reason the ledger above is one: state that outlives every call, mutated from
// a dozen sites, living exactly as long as the store. The revision is why the four subjects share
// ONE handle — it is both the projection cache's key and the Observation shadow every reader of the
// tree binds to, and a counter with two owners is a layout that either repaints for nothing or
// freezes.
//
// THE EDGES ARE RETURNED, NOT OBSERVED. Every mutating door answers what the caller now owes the
// world — arm or cancel the backstop timer, fan the re-dials out, write the file. The near side
// holds the tasks and walks its own panes; it is never asked to decide whether to.
//
// IDENTITY DOES NOT CROSS. A pane, a tab and a session are UUIDs the near side owns and none appears
// here. The one string that does is a `host:port`, which is a VALUE the store prints and persists.

typedef struct SlopDeskWsCore SlopDeskWsCore;

// The near-side facts the gate cannot know on its own, handed in on every call rather than pushed
// and remembered: each lives on an object the far side has never seen, and a remembered copy goes
// stale between the write that moves it and the call that pushes it.
//
// `channel`: 0 none, 1 refused, 2 an in-process document, 3 a real host channel in ANY live state —
// `closed` included, because a dead subscription says nothing about whose ids these are, and reading
// it as an answer is what made a host switch churn.
typedef struct {
    uint8_t channel;
    bool bootstrap_armed;
    bool offer_pending;
} SlopDeskWsCoreInputs;

// What one gate recomputation asks the caller to do. `backstop`: 0 leave the timer alone, 1 arm it,
// 2 cancel it. `opened` is the RELEASING edge — dial everything the hold was holding, which is a
// store-level fan-out because a pane in a satellite window has no arm of its own to wake.
typedef struct {
    bool changed;
    bool opened;
    uint8_t backstop;
} SlopDeskWsCoreGateEdge;

// What one folded document frame asks for, past the effects the caller already ran.
typedef struct {
    SlopDeskWsCoreGateEdge gate;
    bool provenance_stamped;
    bool redial_booking_fired;
} SlopDeskWsCoreFrameEdge;

// A core for a store whose cache was seeded from the `host_key_len` bytes at `host_key` (empty for
// the headless and test paths, which never touch disk).
SlopDeskWsCore *slopdesk_ws_core_new(const uint8_t *host_key, size_t host_key_len);
void slopdesk_ws_core_free(SlopDeskWsCore *handle);
// The projection key as it stands, and the door that moves it. The two LOCAL overlays that touch no
// document — the divider drag preview and this device's own focus — bump it themselves, because a
// frame that skipped it would neither repaint nor invalidate.
uint64_t slopdesk_ws_core_revision(SlopDeskWsCore *handle);
uint64_t slopdesk_ws_core_bump_revision(SlopDeskWsCore *handle);
// Whether the panes on screen may open their host channels. The rule is PROVENANCE: a pane may dial
// an id at the host that named it and nowhere else, because the host spawns a fresh shell for any
// session id it does not know. A NULL core dials — no core is no channel, which waits for nothing.
bool slopdesk_ws_core_panes_may_dial(SlopDeskWsCore *handle);
// Recomputes the gate against `inputs` — the ONE door for every site that moves a near-side fact
// without folding a frame: the channel's own state changes, the launch offer going out and coming
// back, the automation bootstrap taking over the launch.
SlopDeskWsCoreGateEdge slopdesk_ws_core_refresh_dial_gate(SlopDeskWsCore *handle,
                                                          SlopDeskWsCoreInputs inputs);
// The backstop ran out with no answer of any kind. A hold with no release is a window of panes that
// never connect, which is strictly worse than the churn it prevents.
SlopDeskWsCoreGateEdge slopdesk_ws_core_note_backstop_expired(SlopDeskWsCore *handle,
                                                              SlopDeskWsCoreInputs inputs);
// A connect committed the `host_key_len` bytes at `host_key` as this run's target. A DIFFERENT host
// is a new hold with its own full window, and it also retires the cached picture for the rest of the
// run: the facts in it are absolute paths on ONE machine, so a mix of two belongs to neither.
SlopDeskWsCoreGateEdge slopdesk_ws_core_commit_connection_target(SlopDeskWsCore *handle,
                                                                 SlopDeskWsCoreInputs inputs,
                                                                 const uint8_t *host_key,
                                                                 size_t host_key_len);
// Books the establish fan-out a second run on the first document frame the attached host folds — the
// missing edge for an establish that finds the mirror already empty.
void slopdesk_ws_core_arm_redial_on_document(SlopDeskWsCore *handle);
// A document frame folded. Gated on the FRAME COUNT rather than on being called: a patch, a fast-path
// push and a presence roster all announce themselves through the same hook, and one landing after a
// new target is committed would stamp the previous host's layout with the new host's name.
// `epoch_is_seed` is the mirror's own reading: the store's seed is the QUESTION, never a host's
// answer, so a frame carrying it stamps no provenance.
SlopDeskWsCoreFrameEdge slopdesk_ws_core_note_document_frame(SlopDeskWsCore *handle,
                                                             SlopDeskWsCoreInputs inputs,
                                                             uint64_t frames_applied,
                                                             bool epoch_is_seed);
// Whether the armed launch offer may go out now. The seed IS the tree the offer carries, so offering
// it back to a document that already adopted it spends the host's one pristine chance on a no-op.
// A pure fold: every input is the caller's, so no core is asked for.
bool slopdesk_ws_core_launch_offer_ready(SlopDeskWsCoreInputs inputs, bool known_epoch_is_seed,
                                         bool can_mutate);
// Arms the debounced write, after the construction reconcile that would otherwise re-write a
// just-loaded file with its own bytes.
void slopdesk_ws_core_enable_saving(SlopDeskWsCore *handle);
// Claims a generation for a debounced write into `out`, answering false while writes are disarmed.
// The write re-checks it before touching the file, because cancellation cannot stop a task already
// past its sleep — so a superseded one may neither clobber the file nor strand the newest handle.
bool slopdesk_ws_core_begin_save(SlopDeskWsCore *handle, uint64_t *out);
// Claims a generation for a write happening RIGHT NOW, whatever is in flight — the backgrounding
// path, which has already decided it is writing.
uint64_t slopdesk_ws_core_supersede_save(SlopDeskWsCore *handle);
bool slopdesk_ws_core_is_current_save_generation(SlopDeskWsCore *handle, uint64_t generation);
// The live generation as a VALUE — what an observer asks to see whether a mutation moved the guard at
// all, which the predicate above cannot answer without also claiming.
uint64_t slopdesk_ws_core_save_generation(SlopDeskWsCore *handle);
bool slopdesk_ws_core_saving_enabled(SlopDeskWsCore *handle);
// The `host:port` the cached picture is written under, as UTF-8. Answers the byte count NEEDED, so an
// under-sized `cap` writes nothing and asks again; ZERO means the cache may not be written at all.
size_t slopdesk_ws_core_cache_host_key(SlopDeskWsCore *handle, uint8_t *out, size_t cap);

// ---- The git line's cadence, and the keys it files a reply under --------------------------------
//
// Which project section a pane's git line belongs to, when that line is stale enough to re-fetch,
// and which keys ONE reply is booked under. Nothing here holds state: the store still owns the four
// tables, and every door is a question about the strings and instants it already has.
//
// TIME CROSSES AS AN ELAPSED `double`, NOT AN INSTANT. `Date` has no C ABI, and "seconds since we
// last heard" is the only shape of the fact the rule reads. NEVER is `INFINITY` — not a sentinel,
// the literal reading, which lands on the same branch a very old fetch does.
//
// A text argument that is empty or not UTF-8 reads as ABSENT. For these keys the two are one fact:
// a blank project key has told the caller nothing, which is exactly what a missing one says.
typedef struct {
    double stale;       // the ordinary re-fetch window, in seconds
    double active;      // the shorter window the ACTIVE project earns
    double push_grace;  // how long a host push suppresses the client's own fetch
} SlopDeskWsGitWindows;
// The three windows, so the near side reads one vocabulary rather than typing three constants.
SlopDeskWsGitWindows slopdesk_ws_git_windows(void);
// Whether the snapshot edge should re-fetch this project's git line. A fetch already in flight never
// starts a second. A push inside the grace window suppresses a fetch the age alone would have earned
// — the host has just told us, and asking again would only cost a round trip to be told the same.
bool slopdesk_ws_git_refresh_due(bool in_flight, double since_fetch, double since_push,
                                 bool active_project);
// The section a pane's git line is filed under: the host's pushed key when it has one, else the
// pane's own directory. Returns the byte count NEEDED; 0 means the pane sections nowhere.
size_t slopdesk_ws_git_section_key(const uint8_t *key, size_t key_len, const uint8_t *cwd,
                                   size_t cwd_len, uint8_t *out, size_t cap);
// The host's pushed key alone, with no directory fallback — the reading that tells "the host has
// spoken about this pane" from "we are guessing from its directory". Returns the count NEEDED.
size_t slopdesk_ws_git_host_key(const uint8_t *key, size_t key_len, uint8_t *out, size_t cap);
// The SECOND key a fetch's reply should also be booked under, or nothing. A pane already sectioned
// by a host push has no alias — the push is the answer. Returns the count NEEDED.
size_t slopdesk_ws_git_alias_candidate(const uint8_t *key, size_t key_len, const uint8_t *cwd,
                                       size_t cwd_len, uint8_t *out, size_t cap);
typedef struct {
    bool   booked;   // false => this reply is filed nowhere; `primary` and `alias` mean nothing
    bool   alias;    // also book the fallback key, which is STRICTLY under the primary
    size_t primary;  // the byte count NEEDED for the primary key, written into `out`
} SlopDeskWsGitBooking;
// Where one git reply is filed: under the repository root it reported, or — when it reported none —
// under the key the caller asked about. The alias leg is a STRICT subtree test, so a pane sitting in
// a repository subdirectory keeps its own section header alive while the repo-wide line lands too,
// and a fallback equal to the primary never books the same answer twice.
SlopDeskWsGitBooking slopdesk_ws_git_booking(const uint8_t *toplevel, size_t toplevel_len,
                                             const uint8_t *fallback, size_t fallback_len,
                                             uint8_t *out, size_t cap);
// The key an unsolicited host push about a repository root is filed under. Returns the count NEEDED;
// 0 means the push names nothing worth filing.
size_t slopdesk_ws_git_pushed_key(const uint8_t *repo_root, size_t len, uint8_t *out, size_t cap);

// ---- What a new pane inherits, and which readings the store keeps -------------------------------
//
// Two facts follow a pane everywhere it is drawn: where its shell is, and which project section it
// belongs to. A split, a new tab and a new window each mint a pane that has neither yet, and the
// surfaces that name it draw on the FIRST frame — long before the host's answer for the child's PTY
// round-trips. So both are seeded from the pane the gesture was made on.
//
// The seeds and the write gates are ONE guard read from two ends. A plugin manager that steps into
// its cache directory to source a plugin makes the kernel's answer to "where is this shell" briefly
// true and completely useless; never inherit such a reading, and never store one. Three
// transcriptions of that guard is how one of them ends up missing.
//
// `has_current` is the gates' only subtlety: a value NEVER recorded and one recorded BLANK are
// different facts to a dirty guard, and no string could have carried the difference.

// The parent's working directory sanitized as an inherit source, or nothing. Returns the byte count
// NEEDED; 0 means the caller's own working-directory policy resolves the host default from here.
size_t slopdesk_ws_seed_inheritable_cwd(const uint8_t *cwd, size_t len, uint8_t *out, size_t cap);
// The parent's project key seeded onto the child, or nothing. Guarded three ways, each a different
// way of being wrong: a blank or plugin-cache key is not a project; a parent still on its own
// directory fallback seeds NOTHING, because the child's identical fallback already sections it
// beside the parent; and a key that does not cover the inherited directory is not this child's
// project. Returns the count NEEDED.
size_t slopdesk_ws_seed_inheritable_project_key(const uint8_t *key, size_t key_len,
                                                const uint8_t *cwd, size_t cwd_len, uint8_t *out,
                                                size_t cap);
// Whether a freshly-observed working directory is worth writing: the plugin-cache guard read from
// the WRITE end, plus the dirty guard — an unchanged value is not a visit, and writing it would
// spend a document save and a frecency record on a re-focus that moved nothing.
bool slopdesk_ws_seed_accepts_cwd(const uint8_t *candidate, size_t candidate_len,
                                  const uint8_t *current, size_t current_len, bool has_current);
// Whether a host-pushed project key is worth writing: the same two guards, plus blankness — a blank
// key is not an answer, and the host's resolver races a plugin manager's `cd` exactly as a
// client-side probe does.
bool slopdesk_ws_seed_accepts_project_key(const uint8_t *candidate, size_t candidate_len,
                                          const uint8_t *current, size_t current_len,
                                          bool has_current);

// ---- The Android sidebar's list rules, clocks and words -----------------------------------------
//
// `slopdesk_devicepanel::android_sidebar`. A device key and a device serial are strings the near
// side holds, and NEITHER TRAVELS. The list crosses as one three-flag record per row saying which
// rows the question is ABOUT, and the lookup answers a POSITION into the array the caller still
// has — `slopdesk_ws_most_recent_survivor`'s shape, where the comparison belongs to whoever owns
// the values and the fold over its results belongs to the crate.
//
// The three selector families below are the ONLY numbers the near side types: a report kind, a
// notice position in the packed delivery, and an index into the measure table. Each is the code the
// crate's own enum answers, so a name added there and not here reads as a door this build cannot
// name rather than as a silently different value.
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_BOOT_NEVER_SURFACED    0
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_SHUTDOWN_NEVER_LANDED  1
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_NO_LONGER_RUNNING      2
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_NO_VIDEO               3
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_NEVER_FINISHED_STARTING 4
#define SLOPDESK_ANDROID_SIDEBAR_REPORT_SCREENSHOT_UNREADABLE  5
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREEN_ON         0
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREEN_OFF        1
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_PASTED            2
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_COPIED            3
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_SCREENSHOT_COPIED 4
#define SLOPDESK_ANDROID_SIDEBAR_LOG_CAPACITY                 0u
#define SLOPDESK_ANDROID_SIDEBAR_STREAM_MAX_SIZE              1u
#define SLOPDESK_ANDROID_SIDEBAR_FIRST_FRAME_DEADLINE_MS      2u
#define SLOPDESK_ANDROID_SIDEBAR_DEVICE_GRACE_MS              3u
#define SLOPDESK_ANDROID_SIDEBAR_REATTEMPT_PAUSE_MS           4u
#define SLOPDESK_ANDROID_SIDEBAR_BOOT_VISIBLE_DEADLINE_MS     5u
#define SLOPDESK_ANDROID_SIDEBAR_SHUTDOWN_VISIBLE_DEADLINE_MS 6u
#define SLOPDESK_ANDROID_SIDEBAR_NOTICE_LIFETIME_MS           7u
#define SLOPDESK_ANDROID_SIDEBAR_ENSURE_POLL_MS               8u
#define SLOPDESK_ANDROID_SIDEBAR_DEVICE_WATCH_MS              9u
#define SLOPDESK_ANDROID_SIDEBAR_PENDING_HOLD_MS              10u
typedef struct {
    bool matches_key;     // this row is the one the caller's key names
    bool matches_serial;  // this row carries the serial the caller asked about
    bool has_serial;      // the row has a serial at all
} SlopDeskAndroidSidebarRow;
// Which row the question is about, or -1 for none. -1 is outside a position's range by
// construction, which keeps 0 — the first row, and the common answer — a real one.
ptrdiff_t slopdesk_android_sidebar_row_position(const SlopDeskAndroidSidebarRow *rows, size_t len);
// Whether the boot and shutdown verbs may be offered over this list.
bool slopdesk_android_sidebar_boot_is_visible(const SlopDeskAndroidSidebarRow *rows, size_t len);
bool slopdesk_android_sidebar_shutdown_is_visible(const SlopDeskAndroidSidebarRow *rows, size_t len);
// How many log lines to drop to bring a buffer of `count` back under its cap. 0 keeps everything.
size_t slopdesk_android_sidebar_log_overflow(size_t count);
// Whether a freshly measured stream size is NEWS — a size nobody has published yet. `has_current`
// false is the state before any size has been measured, which is not the same as measuring zero.
bool slopdesk_android_sidebar_stream_size_is_news(bool has_current, double current_width,
                                                  double current_height, double width,
                                                  double height);
// Whether an elapsed reading still sits inside the settle grace. `has_elapsed` false means nothing
// has been timed yet, which is not "zero elapsed" — the first is inside the grace, the second is a
// measurement.
bool slopdesk_android_sidebar_within_grace(bool has_elapsed, uint64_t elapsed_ms);
// One of the six REPORTS, with the device name interpolated. `kind` selects; a byte this build
// cannot name writes nothing. A failure is rare enough that the allocation `docs/55`'s cost table
// warns about is not on any path that repeats.
size_t slopdesk_android_sidebar_report(uint8_t kind, const unsigned char *name, size_t name_len,
                                       unsigned char *out, size_t cap);
// The five NOTICES as one delivery — a fixed table, read once into a Swift `static let`.
size_t slopdesk_android_sidebar_notices(unsigned char *out, size_t cap);
// Eleven measures — two counts and nine durations — through ONE indexed door rather than eleven
// entry points, the argument `docs/55` makes about the constant door. An index no build wrote
// answers 0, which no member of the family can be.
uint64_t slopdesk_android_sidebar_measure(uint32_t index);

// ---- The Android bridge's request/response grammar ----------------------------------------------
//
// The panel's end of the object `slopdesk_androidd::protocol` already decodes. What used to be a
// dictionary literal and a `JSONSerialization` call per operation is one door that either builds
// the line or answers 0, so the near side has ONE failure arm where it had seven.

#define SLOPDESK_ANDROID_BRIDGE_OP_LIST 0u
#define SLOPDESK_ANDROID_BRIDGE_OP_BOOT 1u
#define SLOPDESK_ANDROID_BRIDGE_OP_SHUTDOWN 2u
#define SLOPDESK_ANDROID_BRIDGE_OP_CONSOLE 3u
#define SLOPDESK_ANDROID_BRIDGE_OP_SCREENSHOT 4u
#define SLOPDESK_ANDROID_BRIDGE_OP_LOGCAT 5u
#define SLOPDESK_ANDROID_BRIDGE_OP_OPEN 6u

// One bridge request line, NEWLINE INCLUDED. 0 means the line could not be built at all — an
// unknown op, or a required field that was empty — and it cannot collide with a real answer,
// because every line this writes carries at least `{"op":…}` and a terminator.
size_t slopdesk_android_bridge_request(uint8_t op,
                                       const unsigned char *serial, size_t serial_len,
                                       const unsigned char *argument, size_t argument_len,
                                       int64_t max_size,
                                       unsigned char *out, size_t cap);
// Why the host refused this reply line, IN ITS OWN WORDS. 0 means the host acked, which is why an
// `error` key present but empty reads as a refusal rather than as a blank sentence.
size_t slopdesk_android_bridge_reply_failure(const unsigned char *line, size_t line_len,
                                             unsigned char *out, size_t cap);
// What one console command printed. 0 is an EMPTY answer, not an absent one.
size_t slopdesk_android_bridge_console_output(const unsigned char *line, size_t line_len,
                                              unsigned char *out, size_t cap);
// How many PNG bytes follow this ack. ONE answer for all three refusals — no count, a non-positive
// one, and one past the 16 MiB ceiling — because the near side does the same thing with each.
size_t slopdesk_android_bridge_screenshot_bytes(const unsigned char *line, size_t line_len);
// The panel's OWN six refusals as one delivery: [u32 BE length][UTF-8 bytes] per sentence, in the
// order the selectors below give, read once into a Swift `static let`. These are the failures the
// HOST never saw — the request did not leave, or its answer was refused on this side — so they are
// worded here rather than forwarded. Every other sentence on this path is the host's, verbatim.
//
// The selectors are the crate enum's own codes, the sidebar notice family's arrangement: a name
// added there and not here reads as a sentence this build cannot ask for rather than as a silently
// different one.
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_NO_ENDPOINT           0
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNBUILDABLE_REQUEST   1
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNBUILDABLE_LOGCAT    2
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNREADABLE_DEVICE_LIST 3
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_UNREADABLE_SCREENSHOT 4
#define SLOPDESK_ANDROID_BRIDGE_REFUSAL_TRUNCATED_SCREENSHOT  5
size_t slopdesk_android_bridge_refusals(unsigned char *out, size_t cap);
// The device set one `list` ack carries. 0 refuses the ENVELOPE — not an object, not `ok`, or no
// `devices` array — which is distinct from an empty set, since a host with no device attached still
// answers, and the panel must show an empty rail rather than the last one it saw. A single row that
// carries no identity is DROPPED and the rest of the set still lands, because one unparseable
// emulator must not cost the rail every phone beside it.
// Layout: [u32 BE count], then per device: key, name, serial, avd (each a run), state (a run),
//         [u8 is_emulator], manufacturer, model, release, [u8 present][i64 BE api], abi,
//         [u8 present][i64 BE width], [u8 present][i64 BE height], [u8 present][i64 BE density],
//         form factor. An absent number writes its eight bytes as zero, so the walk is fixed-width
//         either way and the flag is the only thing that decides.
size_t slopdesk_android_device_list(const unsigned char *line, size_t line_len,
                                    unsigned char *out, size_t cap);

// ---------------------------------------------------------------------------
// The device panels' two SOCKETS. `slopdesk-devicelink` behind them: RFC 6455
// framing and reassembly for the simulator's two lanes, and the line-then-stream
// split for the Android bridge. `docs/63` §6 named these lanes and deferred
// them; this is that campaign, and `SimulatorWebSocketLane.swift`,
// `SimulatorLogConnection.swift` and the socket half of
// `SimulatorStreamConnection.swift` and `AndroidBridgeSocket.swift` are gone
// with it.
//
// FOUR OBLIGATIONS, the pane driver's four, for both families:
//   1. `context` stays valid until the matching `_free` RETURNS, not until it is
//      entered. `_free` tears the socket down and JOINS the reader.
//   2. The callback runs on the socket's OWN thread — never the caller's, and
//      never concurrently with itself. Synchronise anything it shares.
//   3. No callback may re-enter `_free`: it joins the thread the callback is on.
//   4. Every pointer in every callback is LENT for that call. Keep nothing.
//
// An empty payload crosses as a NULL pointer and a zero length, this crate's
// convention everywhere. The LENGTH decides, never the pointer.
// ---------------------------------------------------------------------------

// What a websocket event is. Every field is the payload's meaning.
#define SLOPDESK_DEVICE_WS_CONNECTED 0u /* the handshake completed. No payload */
#define SLOPDESK_DEVICE_WS_TEXT      1u /* a whole text message, NOT validated as UTF-8 */
#define SLOPDESK_DEVICE_WS_BINARY    2u /* a whole binary message, reassembled */
#define SLOPDESK_DEVICE_WS_ENDED     3u /* over. The payload is why, EMPTY for a clean close */

typedef struct SlopDeskDeviceWs SlopDeskDeviceWs;

// Opens one `ws://` URL and starts reading it. Returns AT ONCE — the dial happens
// on the socket's own thread, so the first thing the callback says is either
// CONNECTED or ENDED.
//
// A URL this client will not open — anything that is not `ws://` (there is no TLS
// on the mesh, by the security invariant), or an authority it cannot dial — ends
// through the callback rather than answering NULL, so the near side has ONE
// failure path instead of two. NULL only when `url` is not UTF-8, and then no
// callback has run or ever will, so `context` may be freed at once.
SlopDeskDeviceWs *slopdesk_device_ws_open(const uint8_t *url, size_t url_len,
                                          void *context,
                                          void (*on_event)(void *context, uint32_t kind,
                                                           const uint8_t *bytes, size_t len));
// Sends one text message. `false` when the socket is not up, which is a DROP and
// not a queue: a gesture delivered late replays a tap the user has moved on from.
bool slopdesk_device_ws_send_text(SlopDeskDeviceWs *lane, const uint8_t *text, size_t text_len);
// Closes the socket and releases the handle. Joins the reader, so no callback is
// running when this returns and none ever will be again. NULL is a no-op.
void slopdesk_device_ws_free(SlopDeskDeviceWs *lane);

// What a bridge-call event is.
#define SLOPDESK_DEVICE_BRIDGE_REPLY 0u /* the ack line, without its newline. At most once */
#define SLOPDESK_DEVICE_BRIDGE_BYTES 1u /* bytes after the ack. `logcat` and `open` only */
#define SLOPDESK_DEVICE_BRIDGE_ENDED 2u /* over. The payload is why, EMPTY for a clean close */

typedef struct SlopDeskDeviceBridge SlopDeskDeviceBridge;

// Dials the Android bridge and writes one request line. `request` is a WHOLE
// line, newline included — `slopdesk_android_bridge_request` built it and is the
// only thing that can refuse to. Returns at once, as the websocket does.
//
// A call whose socket dies before the host acks still answers through REPLY, with
// the panel's own sentence: a caller awaiting a reply must not wait forever for a
// connection that is already gone. NULL only when `host` is not UTF-8.
SlopDeskDeviceBridge *slopdesk_device_bridge_open(const uint8_t *host, size_t host_len,
                                                  uint16_t port,
                                                  const uint8_t *request, size_t request_len,
                                                  void *context,
                                                  void (*on_event)(void *context, uint32_t kind,
                                                                   const uint8_t *bytes, size_t len));
// Sends bytes upstream — `open`'s control channel, and nothing else uses it.
// `false` when the socket is not up, for the websocket send's reason.
bool slopdesk_device_bridge_send(SlopDeskDeviceBridge *call, const uint8_t *bytes, size_t bytes_len);
// Closes the call and releases the handle. Joins, as the websocket's free does.
// NULL is a no-op.
void slopdesk_device_bridge_free(SlopDeskDeviceBridge *call);

typedef struct SlopDeskAndroidLogLines SlopDeskAndroidLogLines;

// A console line splitter at the head of a fresh `logcat` subscription. There is no `_reset`: a
// re-opened subscription drops the handle and builds another.
SlopDeskAndroidLogLines *slopdesk_android_log_lines_new(void);
// Frees a splitter. NULL is a no-op; exactly one `_free` per `_new`.
void slopdesk_android_log_lines_free(SlopDeskAndroidLogLines *handle);
// Folds a chunk in and PARKS the lines it completed; answers the bytes `_answer` needs. This is the
// park-then-read shape rather than `docs/55` §4's measure-then-fill, because a push CONSUMES the
// chunk and asking twice would double-feed it. 0 means no line completed.
size_t slopdesk_android_log_lines_push(SlopDeskAndroidLogLines *handle,
                                       const unsigned char *chunk, size_t chunk_len);
// Copies the lines the last push parked: [u32 count] then count × ([u32 length][UTF-8 bytes]), all
// big-endian. Nothing is consumed here, so a short buffer costs a call and never a line.
size_t slopdesk_android_log_lines_answer(SlopDeskAndroidLogLines *handle,
                                         unsigned char *out, size_t cap);

// ---- The client control socket ------------------------------------------------------------------
//
// `slopdesk_clientctl`, whole: the listener, the accept loop, the NDJSON framing, the size cap, the
// decode, the validation, the twenty refusal sentences and the reply encoder. The CLI links the same
// crate, so the two ends of this socket agree by CONSTRUCTION — there is no second spelling of a
// method name or a token anywhere, and none may be written down again.
//
// What used to be here was that vocabulary as five reader doors, because a Swift dispatcher held the
// other half: it read the method table into a `static let`, switched on the STRING, read
// `[String: Any]` params and built a `[String: Any]` result. None of that crosses now. What crosses
// is a VERB INDEX with its already-validated params in one direction, and a typed outcome in the
// other, and the near side's only job is reaching the `@MainActor` stores — the one thing that was
// ever Swift's.
//
// THE CALLBACK IS THE SHAPE. A request arrives on a connection thread the crate owns; the near side
// hops to its actor, reads the request, fills the reply, and returns. Both handles are live for
// exactly that call. A callback that fills nothing leaves the request refused as an unknown method,
// which is the honest answer for a verb this build does not serve.

// The socket, and the callback it runs each decoded request through.
typedef struct SlopDeskClientCtl SlopDeskClientCtl;
// One decoded request. Nothing on it can be malformed — every line that was is already refused.
typedef struct SlopDeskCtlRequest SlopDeskCtlRequest;
// Where one answer is written. Exactly one `_answer_*` or `_refuse`, plus any number of `_push_*`.
typedef struct SlopDeskCtlReply SlopDeskCtlReply;
// Runs one request. `context` is whatever `_serve` was given; both handles die when this returns.
typedef void (*SlopDeskCtlRunFn)(void *context, const SlopDeskCtlRequest *request,
                                 SlopDeskCtlReply *reply);

// One borrowed run of UTF-8, live for the call that carries it. A pair rather than a C string: the
// producer's text is a Swift `String`, which has a length and no terminator, and asking it for one
// would be a copy per field for nothing. The LENGTH decides — a zero length may carry any pointer.
typedef struct {
    const unsigned char *bytes;
    size_t len;
} SlopDeskCtlText;
// One row of a `windows` listing.
typedef struct {
    SlopDeskCtlText id;
    SlopDeskCtlText title;
    int64_t tab_count;
    bool focused;
} SlopDeskCtlWindow;
// One row of a `tabs` listing. `badge` is a position in the `TabBadge` ladder — the same byte
// `TabBadgeKind.ffiByte` already carries — or negative for a tab wearing nothing.
typedef struct {
    SlopDeskCtlText id;
    SlopDeskCtlText window_id;
    SlopDeskCtlText title;
    int64_t pane_count;
    bool focused;
    int32_t badge;
} SlopDeskCtlTab;
// One row of a `panes` listing. An EMPTY cwd and an UNKNOWN one are different answers — the first
// prints a blank, the second omits the key — so the flag decides whether `cwd` is read at all.
typedef struct {
    SlopDeskCtlText id;
    SlopDeskCtlText tab_id;
    SlopDeskCtlText title;
    SlopDeskCtlText kind;
    bool focused;
    SlopDeskCtlText cwd;
    bool has_cwd;
} SlopDeskCtlPane;
// One row of a `font-list`.
typedef struct {
    SlopDeskCtlText family;
    bool monospace;
    bool system;
} SlopDeskCtlFont;
// One row of a `keybind-list`.
typedef struct {
    SlopDeskCtlText action;
    SlopDeskCtlText keys;
} SlopDeskCtlKeybind;

// The verbs, as positions in the method table. `view` and `edit` are two indices over ONE shape:
// they differ only in SLOPDESK_CTL_FLAG_EDITABLE, so a face reads the flag rather than writing the
// same body twice.
#define SLOPDESK_CTL_VERB_WINDOWS 0
#define SLOPDESK_CTL_VERB_TABS 1
#define SLOPDESK_CTL_VERB_PANES 2
#define SLOPDESK_CTL_VERB_TAB_BADGE 3
#define SLOPDESK_CTL_VERB_JUMP 4
#define SLOPDESK_CTL_VERB_LEARN 5
#define SLOPDESK_CTL_VERB_IGNORE 6
#define SLOPDESK_CTL_VERB_VIEW 7
#define SLOPDESK_CTL_VERB_EDIT 8
#define SLOPDESK_CTL_VERB_FONT_LIST 9
#define SLOPDESK_CTL_VERB_KEYBIND_LIST 10
#define SLOPDESK_CTL_VERB_PANE_CAPTURE 11
#define SLOPDESK_CTL_VERB_PANE_SEND_KEYS 12
#define SLOPDESK_CTL_VERB_AGENT_STATUS 13

// The text fields a request may carry, each named by the verbs that carry it.
#define SLOPDESK_CTL_FIELD_WINDOW_ID 0
#define SLOPDESK_CTL_FIELD_TAB_ID 1
#define SLOPDESK_CTL_FIELD_PANE_ID 2
#define SLOPDESK_CTL_FIELD_QUERY 3
#define SLOPDESK_CTL_FIELD_PATH 4
#define SLOPDESK_CTL_FIELD_TARGET 5
#define SLOPDESK_CTL_FIELD_FAMILY 6
#define SLOPDESK_CTL_FIELD_ACTION 7
#define SLOPDESK_CTL_FIELD_TEXT 8
#define SLOPDESK_CTL_FIELD_ID 9

// The flags. Each is false for a verb that does not carry it, which is every flag's default.
#define SLOPDESK_CTL_FLAG_CHANGE_DIRECTORY 0
#define SLOPDESK_CTL_FLAG_MONOSPACE 1
#define SLOPDESK_CTL_FLAG_EDITABLE 2

// The numbers. Every one a verb DOES carry is non-negative, so -1 cannot be read as an answer.
#define SLOPDESK_CTL_NUMBER_LINES 0
#define SLOPDESK_CTL_NUMBER_BADGE 1
#define SLOPDESK_CTL_NUMBER_PLACEMENT 2
#define SLOPDESK_CTL_NUMBER_SCOPE 3

// The listings. Opening one is separate from pushing into it so an EMPTY listing is expressible: a
// `windows` that found none must still answer `[]`, because the CLI prints "no windows" from an
// empty array and an error from a missing key.
#define SLOPDESK_CTL_LIST_WINDOWS 0
#define SLOPDESK_CTL_LIST_TABS 1
#define SLOPDESK_CTL_LIST_PANES 2
#define SLOPDESK_CTL_LIST_FONTS 3
#define SLOPDESK_CTL_LIST_KEYBINDS 4
#define SLOPDESK_CTL_LIST_LINES 5

// The refusals. The SENTENCE each prints never crosses — a face names the refusal and hands over the
// token the request supplied, which is what keeps `invalid placement 'x'` from becoming
// `invalid placement "x"` on one of the two ends that print it. Only the seven marked OUTCOME are a
// face's to answer; the rest are the decoder's, refused before the callback is ever reached.
#define SLOPDESK_CTL_REFUSAL_TOO_LARGE 1
#define SLOPDESK_CTL_REFUSAL_MALFORMED 2
#define SLOPDESK_CTL_REFUSAL_UNKNOWN_METHOD 3
#define SLOPDESK_CTL_REFUSAL_MISSING_BADGE_KIND 4
#define SLOPDESK_CTL_REFUSAL_INVALID_BADGE_KIND 5
#define SLOPDESK_CTL_REFUSAL_TAB_NOT_FOUND 6        // OUTCOME
#define SLOPDESK_CTL_REFUSAL_NO_JUMP_TARGET 7       // OUTCOME
#define SLOPDESK_CTL_REFUSAL_NOTHING_TO_LEARN 8     // OUTCOME
#define SLOPDESK_CTL_REFUSAL_MISSING_PATH 9
#define SLOPDESK_CTL_REFUSAL_COULD_NOT_IGNORE 10    // OUTCOME
#define SLOPDESK_CTL_REFUSAL_MISSING_TARGET 11
#define SLOPDESK_CTL_REFUSAL_INVALID_PLACEMENT 12
#define SLOPDESK_CTL_REFUSAL_COULD_NOT_OPEN 13      // OUTCOME
#define SLOPDESK_CTL_REFUSAL_INVALID_SCOPE 14
#define SLOPDESK_CTL_REFUSAL_CAPTURE_LINES 15
#define SLOPDESK_CTL_REFUSAL_PANE_NOT_FOUND 16      // OUTCOME
#define SLOPDESK_CTL_REFUSAL_KEYS_NOT_AN_ARRAY 17
#define SLOPDESK_CTL_REFUSAL_NOTHING_TO_SEND 18
#define SLOPDESK_CTL_REFUSAL_UNKNOWN_KEY 19         // OUTCOME
#define SLOPDESK_CTL_REFUSAL_MISSING_ID 20

// Where the socket lives: the SLOPDESK_CLIENT_SOCKET override, else `cli-control.sock` inside the
// container the caller names. The CONTAINER is the caller's because Application Support is a platform
// lookup; every rule ABOUT the path is this side's, which is how the CLI reaches the same answer.
size_t slopdesk_client_ctl_socket_path(const unsigned char *container, size_t container_len,
                                       unsigned char *out, size_t cap);
// Binds at `path` (0600) and begins accepting. NULL on a bind that failed, in which case nothing was
// started and `context` is the caller's again at once. On non-NULL, `run` must stay callable and
// `context` valid for the LIFE OF THE PROCESS: _free cannot join the connection threads (see it),
// so one may still be inside the callback after the handle is gone.
SlopDeskClientCtl *slopdesk_client_ctl_serve(const unsigned char *path, size_t path_len,
                                             void *context, SlopDeskCtlRunFn run);
// Stops the listener, unlinks the socket file, frees the handle. Does NOT join the connection
// threads: one may be parked inside the callback waiting on the caller's main actor, and a free
// called from that actor would then wait on a thread waiting on it. So `context` is never given
// back — bind once per process and keep it.
void slopdesk_client_ctl_free(SlopDeskClientCtl *handle);

// Which verb, as a SLOPDESK_CTL_VERB_* position. -1 for a NULL handle.
int32_t slopdesk_client_ctl_verb(const SlopDeskCtlRequest *request);
// One text field. `present` tells an ABSENT field from an EMPTY one, which several verbs branch on:
// a `learn` with no `path` takes the focused pane's cwd. `docs/55` §4 size-then-take.
size_t slopdesk_client_ctl_text(const SlopDeskCtlRequest *request, uint8_t field,
                                unsigned char *out, size_t cap, bool *present);
// One flag. False for a verb that does not carry it.
bool slopdesk_client_ctl_flag(const SlopDeskCtlRequest *request, uint8_t flag);
// One number, or -1 for a verb that does not carry it.
int64_t slopdesk_client_ctl_number(const SlopDeskCtlRequest *request, uint8_t number);
// How many named keys a `pane-send-keys` carries. 0 for every other verb.
size_t slopdesk_client_ctl_key_count(const SlopDeskCtlRequest *request);
// One named key by position. Past the end writes nothing.
size_t slopdesk_client_ctl_key(const SlopDeskCtlRequest *request, size_t index,
                               unsigned char *out, size_t cap);

// The verb landed and has nothing to report.
void slopdesk_client_ctl_answer_done(SlopDeskCtlReply *reply);
// Opens an EMPTY listing of `kind`. Every _push_* below appends to whichever one is open, and a push
// with no matching listing open is a no-op rather than a wrong answer.
void slopdesk_client_ctl_answer_list(SlopDeskCtlReply *reply, uint8_t kind);
void slopdesk_client_ctl_push_window(SlopDeskCtlReply *reply, SlopDeskCtlWindow row);
void slopdesk_client_ctl_push_tab(SlopDeskCtlReply *reply, SlopDeskCtlTab row);
void slopdesk_client_ctl_push_pane(SlopDeskCtlReply *reply, SlopDeskCtlPane row);
void slopdesk_client_ctl_push_font(SlopDeskCtlReply *reply, SlopDeskCtlFont row);
void slopdesk_client_ctl_push_keybind(SlopDeskCtlReply *reply, SlopDeskCtlKeybind row);
void slopdesk_client_ctl_push_line(SlopDeskCtlReply *reply, SlopDeskCtlText text);
// A `tab-badge` that landed, echoing the badge the tab now wears by its ladder position.
void slopdesk_client_ctl_answer_badge(SlopDeskCtlReply *reply, int32_t badge);
// A `jump` that resolved. `changed` is false when `--no-cd` only printed the path.
void slopdesk_client_ctl_answer_jump(SlopDeskCtlReply *reply, SlopDeskCtlText path, bool changed);
// A `learn` or `ignore` that landed, echoing the path it acted on.
void slopdesk_client_ctl_answer_path(SlopDeskCtlReply *reply, SlopDeskCtlText path);
// An `agent-status` reading. `seen` false is an id that resolves to NO pane (`watch:claude` exits 4);
// `seen` true with no status is the agent-startup window, which keeps the watch polling.
void slopdesk_client_ctl_answer_agent(SlopDeskCtlReply *reply, bool seen, bool has_status,
                                      uint8_t status);
// The verb could not be served, in the socket's own words. `detail` is the token a person mistyped;
// the refusals that name none ignore it.
void slopdesk_client_ctl_refuse(SlopDeskCtlReply *reply, uint8_t refusal, SlopDeskCtlText detail);

// ---- The inspector CLIENT's store fold ----------------------------------------------------------
//
// `slopdesk_inspectord::store`. The `slopdesk_inspector_*` doors above are the DAEMON's frame and
// share nothing with these: that one is what the wire delivers, this one is the fold the read-only
// client applies to what the frame delivered. The two prefixes are `slopdesk_inspector_` and
// `slopdesk_inspector_store_` for exactly that reason.
//
// THE STATE IS THE STORE'S, WHICH IS WHY THERE ARE NO ARGUMENTS. This used to be five doors
// answering one decision each — a ring's ceiling, its overflow, the empty-state gate, the agent
// tree — while the values they decided about sat in a Swift class beside a second declaration of
// the whole event taxonomy and a second JSON decoder for it. Every read lent state ACROSS the
// boundary so a rule could be told about it. Now the store holds the values, so the tree walks real
// ids, the scent reads the list it already has, and the caps apply where the collections live.
// See docs/66.

typedef struct SlopDeskInspectorStore SlopDeskInspectorStore;

// One store per pane, built with the pane's session and freed with it. Freeing null is a no-op.
SlopDeskInspectorStore *slopdesk_inspector_store_new(void);
void slopdesk_inspector_store_free(SlopDeskInspectorStore *handle);

// Folds one event's JSON body in. false = the body did not decode and nothing changed, which is
// this wire's resilience contract rather than an error: a rogue event costs that event, never the
// feed. A null handle folds nothing and answers false.
bool slopdesk_inspector_store_apply(SlopDeskInspectorStore *handle, const unsigned char *body,
                                    size_t len);

// Undoes what a replay from sequence zero would double — the monotonic counters and the message
// log — and NOTHING else. Deliberately not a clear: the cards a re-subscribe is about to be told
// about again must not blank the panel in the meantime.
void slopdesk_inspector_store_reset(SlopDeskInspectorStore *handle);

// The counter a reader diffs against to learn that anything at all changed. 0 for a null handle.
uint64_t slopdesk_inspector_store_revision(SlopDeskInspectorStore *handle);

// Whether the inspector has anything to show at all — the zero-state gate. The subagent half of it
// is the TREE's emptiness, never the raw agent map's, so one malformed agent cannot suppress the
// placeholder while rendering nothing.
bool slopdesk_inspector_store_has_activity(SlopDeskInspectorStore *handle);

// The pending-tool line: the newest still-waiting card's NAME, then its input SUMMARY, then its
// full input DISPLAY, as three length-prefixed fields — the collapsed row draws the first two in
// two weights, the expanded one draws the third. 0 out when nothing is in flight — unambiguous,
// since a real answer carries three four-byte prefixes and so is never shorter than twelve bytes.
size_t slopdesk_inspector_store_pending_line(SlopDeskInspectorStore *handle, unsigned char *out,
                                             size_t cap);

// The "i/n · activeForm" line for the todos in flight; 0 out when nothing is. No list is lent to
// it — the todos are the store's own, which is the whole difference from the door this replaces.
size_t slopdesk_inspector_store_todo_scent(SlopDeskInspectorStore *handle, unsigned char *out,
                                           size_t cap);

// ---- What a live pane may do next ---------------------------------------------------------------
//
// `slopdesk_workspace::pane_session`. NOTHING THAT IS ALIVE CROSSES: a connection, an inspector
// client, a video window and the `Task` that drives any of them are the near side's, and none of
// them appears here. Every door takes the FACTS a decision reads — three or four booleans, a status
// byte, a count — and answers what to do about them: a step, an effect, a route. The near side does
// the doing, which is the half that is not a rule.
typedef struct {
    unsigned char urgency;  // the wire's own byte, carried through unchanged
    unsigned char effect;   // what the landing does to the pane
    bool          changed;  // whether this landing moved anything at all
} SlopDeskWsStatusFold;
// THE STATUS BYTE IS THE WIRE'S OWN. `docs/20` type 27 carries an urgency byte, not an enum, and
// the fold takes and answers that same byte — so the five-case status is spelled once, in
// `slopdesk-agent`, and the client's forward-tolerance for a future value is that crate's rather
// than a second guess here.
SlopDeskWsStatusFold slopdesk_ws_session_status_fold(bool detectable, unsigned char current,
                                                     unsigned char wire_state);
// Whether a foreground process name is one the pane should NAME — the shell itself is not news.
bool slopdesk_ws_session_names_foreground(const unsigned char *name, size_t len);
typedef struct {
    bool agent_present;  // an agent is running in this pane
    bool has_model;      // the pane has an inspector model to bind
    bool has_client;     // a client is already attached
} SlopDeskWsInspectorFacts;
// Whether the inspector may attach to this pane under `gate`.
bool slopdesk_ws_session_inspector_gate(unsigned char gate, SlopDeskWsInspectorFacts facts);
typedef struct {
    bool is_video;  // the pane is a video pane at all
    bool has_model;
    bool is_open;   // its window is open right now
    bool can_open;  // it is allowed to open one
} SlopDeskWsVideoFacts;
// What to do about a video pane's window next: the step, as a byte the near side dispatches on.
unsigned char slopdesk_ws_session_video_step(SlopDeskWsVideoFacts facts, bool active);
// Whether a resumed session re-opens its video window, and whether a teardown closes one. The two
// are separate doors because they read different facts: a resume asks what the pane WAS, a teardown
// asks what it still HOLDS.
bool slopdesk_ws_session_resume_reopens_video(bool is_video, bool was_active);
bool slopdesk_ws_session_teardown_closes_video(bool is_active, bool has_descriptor);
// What a video pane mounts on: a window id crosses as DISPLAY DATA, never compared or handed back.
unsigned char slopdesk_ws_session_video_mount(bool has_video_spec, bool has_display_id,
                                              uint32_t window_id);
// Where a capture of `count` lines starts in a buffer of `available`, or -1 to refuse. -1 rather
// than 0 because 0 is the whole buffer, which is the most common real answer.
ptrdiff_t slopdesk_ws_session_capture_start(int64_t count, size_t available);
// Which surface a dismissed pill routes to.
unsigned char slopdesk_ws_session_dismiss_route(unsigned char pill);

// ---- The pane switcher -------------------------------------------------------------------------
//
// Two width rungs, not one: NEITHER desktop bound survives the move to a phone, which is arithmetic
// rather than taste — the 400pt floor is wider than a 390pt screen, and the 0.66 ceiling would spend
// a third of that screen on ground whose only job is to be not-the-card.
typedef struct {
    bool   forward;
    size_t steps;
} SlopDeskWsSwitcherWalk;
size_t slopdesk_ws_pane_switcher_words(uint8_t *out, size_t cap);  // 5 runs
size_t slopdesk_ws_pane_switcher_highest_shortcut(void);
double slopdesk_ws_pane_switcher_width(double container);
double slopdesk_ws_pane_switcher_compact_width(double container);
// An unmeasured container has NO ceiling — infinity — because a first layout pass must not clamp
// the card to zero.
double slopdesk_ws_pane_switcher_max_height(double container);
double slopdesk_ws_pane_switcher_list_height(size_t rows, double row_height, double container);
SlopDeskWsSwitcherWalk slopdesk_ws_pane_switcher_walk(size_t from, size_t to, size_t count);
// 4 runs: the title AS DRAWN, the project, the note, and the two joined into a place line. An EMPTY
// run is "there is none", which cannot collide with a real answer: the rules never write a blank
// project or note. One crossing per ROW because a card of ten redraws all four on every press.
size_t slopdesk_ws_pane_switcher_row(SlopDeskWsSpan title, SlopDeskWsSpan project_key,
                                     SlopDeskWsSpan cwd, SlopDeskWsSpan process_label,
                                     const uint8_t *blob, size_t blob_len, uint8_t *out, size_t cap);

// ---- One sidebar row ---------------------------------------------------------------------------
//
// `badge` is what `slopdesk_agent_tab_badge` answered, -1 for an all-clear row.
//
// The title door packs the INK in the low byte and the WEIGHT in the next: both are asked on every
// redraw of every row, they share every input, and two doors would let a row take an urgent hue at
// a resting weight. The ink's own byte carries its kind in the high nibble — 0x00 secondary, 0x01
// primary, 0x1<role> urgent — and the weight is 0 resting, 1 active, 2 attention.
uint16_t slopdesk_ws_sidebar_row_title(int8_t badge, bool active, bool working);
// 1 run, or 0 when the row says nothing. A row whose only news is that it is BUSY says nothing.
size_t   slopdesk_ws_sidebar_row_spoken_state(int8_t badge, bool working, uint8_t *out, size_t cap);
// `[u32 line_count]`, that many presence lines, then the joined presence sentence and the whole
// tooltip — each EMPTY for none. `names` is viewers first for viewer_count entries, holders after.
// The lines are a CUT of the tooltip and not a second reading, which is exactly why they cross
// together: a door per spender would be the drift the rule exists to prevent.
size_t   slopdesk_ws_sidebar_row_hover(SlopDeskWsSpan cwd, SlopDeskWsSpan detail,
                                       SlopDeskWsSpan last_command, const SlopDeskWsSpan *names,
                                       size_t viewer_count, size_t holder_count,
                                       const uint8_t *blob, size_t blob_len, uint8_t *out,
                                       size_t cap);
// 1 run, or 0 for a block with none of the three parts.
size_t   slopdesk_ws_sidebar_row_command_line(SlopDeskWsSpan command, SlopDeskWsSpan duration_label,
                                              SlopDeskWsSpan status_label, const uint8_t *blob,
                                              size_t blob_len, uint8_t *out, size_t cap);
// `[u32 count]` then one byte per entry, kind in the high nibble: 0x00 separator, 0x1x a verb,
// 0x2x a toggle. A byte per entry rather than a record, because a menu opening under a finger must
// not cost a crossing per row.
size_t   slopdesk_ws_sidebar_row_menu(uint8_t *out, size_t cap);
size_t   slopdesk_ws_sidebar_row_menu_titles(uint8_t *out, size_t cap);  // 5 runs: 2 verbs, 3 switches
uint8_t  slopdesk_ws_sidebar_row_separator_code(void);
// The row's ONE live-detail line: 1 run, or 0 for a row with nothing happening — the resting state,
// never an error. Exactly SLOPDESK_WS_SIDEBAR_ROW_DETAIL_SPANS spans, in PRECEDENCE order:
//
//   0 question   1 scent   2 working label   3 done line
//   4 the failed block's command text   5 the running command   6 the row's title
//
// `present` marks a rung LIT rather than merely empty — the caller gates the prose rungs on state
// this side cannot see. Any other span count answers 0: a layout disagreement loses the whole line
// rather than shifting the ladder by one rung. The TEXT crosses and not the winning index because
// the error rung's answer is span 4 TRIMMED, and an index would leave Swift re-spelling the trim.
// `has_exit_code` is all this side needs about the failure — the code rides the badge one line up.
#define SLOPDESK_WS_SIDEBAR_ROW_DETAIL_SPANS 7
size_t   slopdesk_ws_sidebar_row_detail(const uint8_t *blob, size_t blob_len,
                                        const SlopDeskWsSpan *spans, size_t span_count,
                                        bool has_exit_code, uint8_t *out, size_t cap);

// ---- The Open Quickly picker -------------------------------------------------------------------
//
// The ROWS never cross. `_draw_order` takes section SIZES and answers the interleave; `_row_actions`
// takes a row's four facts and answers verbs. What a row IS stays in the caller's own storage.
typedef struct {
    double panel_width;
    double results_max_height;
    double subtitle_max_width;
    double actions_width;
} SlopDeskWsPickerMetrics;
// A header carries only its section; a row carries both index spaces, which differ because the
// drawn list interleaves headers while the selection counts only rows a user can land on.
typedef struct {
    bool   is_header;
    size_t section;
    size_t item;
    size_t selectable;
} SlopDeskWsPickerLine;
SlopDeskWsPickerMetrics slopdesk_ws_open_quickly_metrics(void);
size_t slopdesk_ws_open_quickly_page_stride(double row_height);
size_t slopdesk_ws_open_quickly_words(uint8_t *out, size_t cap);  // 8 runs
// `[u8 chord key]` then 4 runs: the pill's label, its section header, its symbol, its empty message.
size_t slopdesk_ws_open_quickly_pill(uint8_t code, uint8_t *out, size_t cap);
// Two bitmasks over the pill's own code: the low 16 bits are the pill row, the high 16 the section
// headers. They differ by exactly one member — All is a pill and heads nothing.
uint32_t slopdesk_ws_open_quickly_pill_sets(void);
// `[u8 jump-to code]` then 3 runs: the kind's badge, its symbol, the default action label it earns.
size_t slopdesk_ws_open_quickly_kind(uint8_t code, uint8_t *out, size_t cap);
size_t slopdesk_ws_open_quickly_default_action(uint8_t *out, size_t cap);  // 1 run, for NO kind
size_t slopdesk_ws_open_quickly_verbs(uint8_t *out, size_t cap);  // 30 runs: title, symbol, ×15
// 1 run. Three answers in one, and the ORDER keeps each honest: a typed query blames the query, an
// in-flight Agents fetch says loading rather than none, everything else is the source's own line.
size_t slopdesk_ws_open_quickly_empty_message(const uint8_t *query, size_t query_len, uint8_t filter,
                                              bool agents_loading, uint8_t *out, size_t cap);
// The ⌘-chord a UNICODE SCALAR names: 0 none, 0x1<digit> quick-pick, 0x20 toggle actions,
// 0x3<code> a pill chord.
uint8_t slopdesk_ws_open_quickly_chord(uint32_t character);
// The line count; the lines are written only when they fit, the way the row filters answer.
size_t slopdesk_ws_open_quickly_draw_order(const size_t *sizes, size_t size_count, uint8_t filter,
                                           SlopDeskWsPickerLine *out, size_t cap);
// `[u32 count]` then one verb code each. A count of 1 whose byte is this sentinel means the row
// defers to the SHARED jump-to table the near side already owns — which is not the same answer as
// offering nothing, and only one of the two draws a sheet.
#define SLOPDESK_WS_PICKER_SHARED_JUMP_TO 0xFF
size_t slopdesk_ws_open_quickly_row_actions(uint8_t act, uint8_t kind, bool has_subtitle,
                                            bool cwd_empty, bool folders_backed, uint8_t *out,
                                            size_t cap);

// ---- The ⌘J Jump-To panel ----------------------------------------------------------------------
//
// Which of the caller's own detections and blocks earn a row, and what each is called — the collapse
// of four path forms into one badge, the dedup of a path a build log printed forty times, the
// ceiling on a pathological scrollback, the skip of a block still being captured. ORDER crosses, not
// TEXT: the answer is indices INTO the arrays the caller already holds, so no scrollback string
// makes a second trip to be handed back unchanged. The kinds are the picker's own, so a Jump-To row
// and its Open-Quickly twin cannot badge differently.
//
// `[u32 link count]`, then that many `[u32 index][u32 kind]` pairs, then one `[u32 index]` per
// surviving block. `link_kinds` and `link_spans` are POSITIONAL: a length disagreement, or a code no
// kind answers to, loses the whole reading rather than badging a detection with its neighbour's kind
// or shifting every later index by one.
#define SLOPDESK_WS_JUMP_TO_HEAD_BYTES     4
#define SLOPDESK_WS_JUMP_TO_MAX_LINK_ITEMS 200
size_t slopdesk_ws_jump_to_rows(const uint32_t *link_kinds, size_t link_kind_count,
                                const uint8_t *blob, size_t blob_len,
                                const SlopDeskWsSpan *link_spans, size_t link_span_count,
                                const SlopDeskWsSpan *block_spans, size_t block_span_count,
                                uint8_t *out, size_t cap);

// ---- The pane's eight stored control vocabularies ----------------------------------------------
//
// Each is a small closed set with a stored spelling per case and a repair for a token this build
// does not know, so each crosses twice: one delivery of the whole table in ALL order, read once per
// process, and one door that repairs an arbitrary token to a code. A door per case would be forty
// crossings for sets both sides know at compile time.
//
// Two tables deliver a PAIR per case — the stored token, then the value written into the terminal's
// own config — and that pair is the point: the config spelling is inverted (`disabled` writes
// "true"), which is exactly the transcription nobody reproduces correctly twice.
size_t  slopdesk_terminal_clipboard_tokens(uint8_t *out, size_t cap);            // 3 runs
uint8_t slopdesk_terminal_clipboard_from_token(const uint8_t *token, size_t len);
// 1 run, or 0 when the read must be refused OR asked about — the caller raises its own dialog
// either way, which is a near-side act. A present but EMPTY answer is a silent read of an empty
// clipboard.
size_t  slopdesk_terminal_clipboard_silent_read(uint8_t access, const uint8_t *text, size_t len,
                                                uint8_t *out, size_t cap);
// Both gates once the shell's master switch has had its say: read in the low byte, write in the
// next. One answer, because a master switch honoured in one direction and not the other is the
// failure the rule exists to rule out.
uint16_t slopdesk_terminal_clipboard_gates(bool shell_controlled, uint8_t read, uint8_t write);
size_t  slopdesk_terminal_right_click_tokens(uint8_t *out, size_t cap);          // 5 runs
uint8_t slopdesk_terminal_right_click_from_token(const uint8_t *token, size_t len);
size_t  slopdesk_terminal_mouse_shift_tokens(uint8_t *out, size_t cap);          // 4 runs
// The code in the low byte, "does it extend a selection" in bit 8: a stored token is resolved
// exactly when a shift-drag has to be routed, so both are read at the same moment.
uint16_t slopdesk_terminal_mouse_shift_from_token(const uint8_t *token, size_t len);
size_t  slopdesk_terminal_option_as_alt_tokens(uint8_t *out, size_t cap);        // 4 runs
uint8_t slopdesk_terminal_option_as_alt_from_token(const uint8_t *token, size_t len);
// The POLICY itself does not cross: it is consumed by the detector, which is already Rust's.
size_t  slopdesk_terminal_scheme_detection_tokens(uint8_t *out, size_t cap);     // 2 runs
uint8_t slopdesk_terminal_scheme_detection_from_token(const uint8_t *token, size_t len);
// 5 runs: ⌘-click's three, then ⌘⇧-click's two. One delivery because the two settings are drawn as
// one pair of rows and neither is read alone.
size_t  slopdesk_terminal_link_click_tokens(uint8_t *out, size_t cap);
uint8_t slopdesk_terminal_cmd_click_from_token(const uint8_t *token, size_t len);
uint8_t slopdesk_terminal_cmd_shift_click_from_token(const uint8_t *token, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_WORKSPACE_H */
