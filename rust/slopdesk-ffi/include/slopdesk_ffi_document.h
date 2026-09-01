// slopdesk_ffi_document.h — the key-repeat cadence, the workspace state file, and the document's canonical order
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_DOCUMENT_H
#define SLOPDESK_FFI_DOCUMENT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- The key-repeat cadence (SlopDeskKeyRepeat) ------------------------------------------------
//
// A held key's CADENCE is a state machine — which key is latched, which generation of timer is
// live, initial wait vs. repeat wait — and it outlives every individual call, which is why this is
// the handle convention. The `DispatchSourceTimer` stays Swift; only the DECISION crosses.
//
// SECOND declared exception to "no two calls on one handle may overlap", after
// SlopDeskCursorSampler: the main thread presses and releases while a timer queue asks what an
// elapsed generation should do, BY DESIGN. This handle carries its own lock for exactly that.
// Exactly one _free per _new; a NULL handle is inert on every door.
//
// The KEY crosses as opaque bytes the caller chooses — for a generic Swift key that is its
// `hashValue`, the one encoding that follows the type's OWN `==`.
typedef struct SlopDeskKeyRepeat SlopDeskKeyRepeat;

// The standard wait before the first repeat, and the standard wait between repeats, in ms.
uint32_t slopdesk_key_repeat_default_initial_delay_ms(void);
uint32_t slopdesk_key_repeat_default_repeat_interval_ms(void);

// A repeater with nothing held, at this cadence. Never null.
SlopDeskKeyRepeat *slopdesk_key_repeat_new(uint32_t initial_delay_ms,
                                           uint32_t repeat_interval_ms);
void slopdesk_key_repeat_free(SlopDeskKeyRepeat *handle);

// A key went down. `true` = cancel any armed timer, emit the key ONCE now, and arm a one-shot
// `after_ms` from now quoting `generation`. `false` = this key is already held and the press is a
// hardware auto-repeat; do nothing, the cadence is already running.
bool slopdesk_key_repeat_down(const SlopDeskKeyRepeat *handle,
                              const uint8_t *identity, size_t len,
                              uint64_t *generation, uint32_t *after_ms);
// A key went up. `true` = it was the held one; cancel the timer. `false` = a stale release (another
// key took the latch), which must NOT stop the live repeat.
bool slopdesk_key_repeat_up(const SlopDeskKeyRepeat *handle, const uint8_t *identity, size_t len);
// Drop whatever is held. `true` if something was.
bool slopdesk_key_repeat_stop(const SlopDeskKeyRepeat *handle);

// A timer armed under `generation` just elapsed. `stage` is 0 for the initial one-shot, 1 for a
// repeat tick:
#define SLOPDESK_KEY_REPEAT_STALE                0  /* the latch moved; emit nothing              */
#define SLOPDESK_KEY_REPEAT_FIRE                 1  /* emit once; the repeating timer keeps going */
#define SLOPDESK_KEY_REPEAT_FIRE_AND_ARM         2  /* emit once and start it at `*every_ms`      */
uint8_t slopdesk_key_repeat_elapsed(const SlopDeskKeyRepeat *handle, uint8_t stage,
                                    uint64_t generation, uint32_t *every_ms);
// Whether `generation` is still the live one — asked before ADOPTING a handle that was armed while
// a release could have landed.
bool slopdesk_key_repeat_is_current(const SlopDeskKeyRepeat *handle, uint64_t generation);
// Whether any key is currently held (the repeat is running).
bool slopdesk_key_repeat_is_held(const SlopDeskKeyRepeat *handle);

// MARK: The split tree's own operations
//
// Each of these ANSWERS a tree, written as the same pre-order walk they read. A count of SIZE_MAX
// means the op did not APPLY — a different answer from a tree of zero nodes, which would erase an
// arrangement the caller only meant to leave alone. Otherwise the §4 convention holds: the return is
// the node count needed, and nothing is written when it exceeds `cap`.

/// Where a pane sits relative to the nearest enclosing split on an axis.
typedef struct {
  SlopDeskWsUuid split;
  size_t child_index;
  size_t child_count;
} SlopDeskWsEnclosing;

size_t slopdesk_ws_tree_splitting(const SlopDeskWsTreeNode *nodes, size_t count,
                                  SlopDeskWsUuid target, uint8_t axis, SlopDeskWsUuid new_leaf,
                                  bool before, SlopDeskWsUuid fresh_split,
                                  SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_inserting_beside(const SlopDeskWsTreeNode *nodes, size_t count,
                                         SlopDeskWsUuid leaf, SlopDeskWsUuid target, uint8_t axis,
                                         bool before, SlopDeskWsUuid fresh_split,
                                         SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_inserting_at_root(const SlopDeskWsTreeNode *nodes, size_t count,
                                          SlopDeskWsUuid leaf, uint8_t axis, bool before,
                                          SlopDeskWsUuid fresh_split, SlopDeskWsTreeNode *out,
                                          size_t cap);
size_t slopdesk_ws_tree_removing(const SlopDeskWsTreeNode *nodes, size_t count,
                                 SlopDeskWsUuid target, SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_resizing_divider(const SlopDeskWsTreeNode *nodes, size_t count,
                                         SlopDeskWsUuid split, size_t leading_index, double delta,
                                         SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_evening_divider(const SlopDeskWsTreeNode *nodes, size_t count,
                                        SlopDeskWsUuid split, size_t leading_index,
                                        SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_setting_divider_weight(const SlopDeskWsTreeNode *nodes, size_t count,
                                               SlopDeskWsUuid split, size_t leading_index,
                                               double leading_weight, SlopDeskWsTreeNode *out,
                                               size_t cap);
size_t slopdesk_ws_tree_swapping(const SlopDeskWsTreeNode *nodes, size_t count, SlopDeskWsUuid a,
                                 SlopDeskWsUuid b, SlopDeskWsTreeNode *out, size_t cap);
size_t slopdesk_ws_tree_rebalanced(const SlopDeskWsTreeNode *nodes, size_t count,
                                   SlopDeskWsTreeNode *out, size_t cap);
bool slopdesk_ws_tree_enclosing_split(const SlopDeskWsTreeNode *nodes, size_t count,
                                      SlopDeskWsUuid pane, uint8_t axis,
                                      SlopDeskWsEnclosing *answer);
bool slopdesk_ws_tree_first_leaf(const SlopDeskWsTreeNode *nodes, size_t count,
                                 SlopDeskWsUuid *answer);
bool slopdesk_ws_tree_structurally_equal(const SlopDeskWsTreeNode *left, size_t left_count,
                                         const SlopDeskWsTreeNode *right, size_t right_count);


// MARK: The re-tile layouts
//
// The leaf ORDER in, the tree out. `layout` is LayoutPreset's case index: evenHorizontal,
// evenVertical, mainVertical, mainHorizontal, tiled — and the main-* layouts take the FIRST leaf as
// the large one, so the caller decides what "active" means. `splits` is the identity pool the crate
// draws split ids from (it mints nothing of its own); `count + 1` entries is always enough. SIZE_MAX
// for fewer than two leaves, where a one-child split would violate the tree's arity rule.
size_t slopdesk_ws_retile(const SlopDeskWsUuid *leaves, size_t count, uint8_t layout,
                          const SlopDeskWsUuid *splits, size_t split_count,
                          SlopDeskWsTreeNode *out, size_t cap);


// MARK: The document's scalar field codec
//
// The leaves of the multiclient state protocol (docs/45). Every decoder is STRICT about width — a
// value of the wrong length answers false rather than a lenient prefix read — because these bytes
// came off a socket and a mis-numbered field must FAIL rather than succeed into something plausible.
//
// The out-parameter shape rather than a return value, because every one has to be able to say "these
// bytes are not a value of this kind" without a sentinel that could also be data: a lastExitCode of
// -1 is a real exit code, and 0xFFFFFFFF is its encoding.

// A one-byte field, and the same byte read as a BOOL. The bool reading is a door of its own
// rather than a `!= 0` composed by the caller: both of a bool's values are real answers, so the
// width refusal has to ride the return, and a side that read the byte as `== 1` instead would
// answer false for every non-canonical byte a peer sends without either side failing a decode.
bool slopdesk_ws_decode_bool(const uint8_t *bytes, size_t len, bool *out);
bool slopdesk_ws_decode_u8(const uint8_t *bytes, size_t len, uint8_t *out);
bool slopdesk_ws_decode_u8_pair(const uint8_t *bytes, size_t len, uint8_t *first, uint8_t *second);
bool slopdesk_ws_decode_u16_pair(const uint8_t *bytes, size_t len, uint16_t *first,
                                 uint16_t *second);
bool slopdesk_ws_decode_u32(const uint8_t *bytes, size_t len, uint32_t *out);
bool slopdesk_ws_decode_i32(const uint8_t *bytes, size_t len, int32_t *out);
bool slopdesk_ws_decode_i64(const uint8_t *bytes, size_t len, int64_t *out);
// SIZE_MAX when the count and the bytes disagree — a REFUSAL, not the empty list a well-formed zero
// count is.
size_t slopdesk_ws_decode_uuid_list(const uint8_t *bytes, size_t len, SlopDeskWsUuid *out,
                                    size_t cap);
size_t slopdesk_ws_encode_uuid_list(const SlopDeskWsUuid *ids, size_t count, uint8_t *out,
                                    size_t cap);
size_t slopdesk_ws_encode_string(const uint8_t *bytes, size_t len, size_t max_bytes,
                                 uint8_t *out, size_t cap);


// MARK: The snapshot and the diff
//
// The highest-risk parsing in the document: a count and a length, both chosen by whoever is on the
// other end of the socket. Every bound is checked against the bytes ACTUALLY remaining before any
// capacity is reserved, so a hostile 0xFFFFFFFF costs a comparison rather than four gigabytes.
//
// A decoded value is a SPAN into the caller's own input buffer, never a copy — the caller still
// holds the buffer, so the spans are live for exactly as long as they are useful.

size_t slopdesk_ws_max_entry_count(void);

/// One document entry: a key, and where its value sits in the buffer. `value.present` is false for a
/// DELETE, which is a key with no value.
typedef struct {
  uint8_t kind;
  uint8_t field;
  SlopDeskWsUuid object;
  SlopDeskWsSpan value;
} SlopDeskWsEntry;

// SIZE_MAX on malformed bytes — a REFUSAL, not the empty snapshot a well-formed zero count is.
size_t slopdesk_ws_decode_snapshot(const uint8_t *bytes, size_t len, SlopDeskWsEntry *out,
                                   size_t cap);
// Both counts are written even when a buffer was too small, so one call sizes both halves.
bool slopdesk_ws_decode_diff(const uint8_t *bytes, size_t len, SlopDeskWsEntry *sets_out,
                             size_t sets_cap, SlopDeskWsEntry *deletes_out, size_t deletes_cap,
                             size_t *sets_needed, size_t *deletes_needed);
size_t slopdesk_ws_encode_snapshot(const SlopDeskWsEntry *entries, size_t count,
                                   const uint8_t *blob, size_t blob_len, uint8_t *out, size_t cap);
size_t slopdesk_ws_encode_diff(const SlopDeskWsEntry *sets, size_t set_count,
                               const SlopDeskWsEntry *deletes, size_t delete_count,
                               const uint8_t *blob, size_t blob_len, uint8_t *out, size_t cap);


// MARK: The intent applier
//
// One client's requested topology change, decided here and nowhere else — the host runs it to
// decide what the document becomes and the client runs the SAME call for its optimistic overlay,
// so the two cannot disagree about what a split does.
//
// A topology is a split tree, which does not flatten into a struct without inventing a second
// grammar for it — and does not have to, because it already HAS one. The document goes in as the
// flat cells `slopdesk_ws_encode_snapshot` takes, and the result comes back as an encoded snapshot
// the caller reads with `slopdesk_ws_decode_snapshot`.

typedef struct {
    SlopDeskWsUuid id;
    SlopDeskWsSpan key;
} SlopDeskWsKeyedPane;

// The identity pool one intent can spend. Sized here rather than at the call site: a pool one short
// REPEATS an identity rather than failing, and two tabs sharing an id surfaces days later.
size_t slopdesk_ws_minted_ids_per_intent(void);

// The topology's two RING caps, by index: 0 the closed-tab ring, 1 the per-session focus MRU. An
// unknown index answers 0. These are REAPING thresholds the host applies, so a client holding a
// different number renders a ring whose tail the host already deleted, with no error anywhere.
size_t slopdesk_ws_topology_ring_cap(uint8_t index);

// Whether a (kind, field) pair is in the TOPOLOGY half — what a wholesale topology write REAPS by.
// A pane splits by FIELD: its `title` is topology and its `liveTitle` is not, one byte apart under
// the same object id. Two answers do not conflict, they silently delete or silently strand a cell.
bool slopdesk_ws_key_is_topology(uint8_t kind, uint8_t field);

// An intent argument cap the HOST validates against before it allocates: 0 a name's bytes,
// 1 a reorderTabs list, 2 a sub-payload blob. Unknown index answers 0, refusing everything.
size_t slopdesk_ws_intent_limit(uint8_t index);

// The wire size of one document key. Fixed, and the reason a truncated snapshot is rejected by
// arithmetic rather than by trial decoding.
size_t slopdesk_ws_key_encoded_size(void);

// One HALF of the pane field vocabulary: 0 the liveness fields, 1 the topology fields. §4-shaped.
// The two PARTITION the vocabulary — a field in neither is written and reaped by nobody, one in
// both makes a liveness recapture silently delete a persisted title.
size_t slopdesk_ws_pane_fields(uint8_t half, uint8_t *out, size_t cap);

// The `root` field numbers a topology write must NOT reap — reserved for config that does not
// cross (docs/45 §5.3). §4-shaped, so a caller sizes from the answer.
size_t slopdesk_ws_reserved_root_fields(uint8_t *out, size_t cap);

// The status byte for one outcome, by arm order: applied, stale, invalid, not-found, unknown-op.
// Exported because the numbering is the WIRE's and therefore golden-pinned — a caller that wrote it
// down beside this would be a second copy of a frozen number.
uint8_t slopdesk_ws_intent_status(uint8_t index);

// `project_keys` span the SAME `blob` the entries do. `status` receives the intent-status byte on
// every path including the refusals, so a caller that only wants the verdict passes a null `out`.
// A refusal answers 0 bytes — not the four an empty snapshot encodes to.
size_t slopdesk_ws_apply_intent(uint8_t op, const uint8_t *args, size_t args_len,
                                const SlopDeskWsEntry *entries, size_t entry_count,
                                const SlopDeskWsKeyedPane *project_keys, size_t project_key_count,
                                const uint8_t *blob, size_t blob_len,
                                const SlopDeskWsUuid *minted, size_t minted_count, bool pristine,
                                uint8_t *status, uint8_t *out, size_t cap);


// MARK: The pane's LIVENESS half — what is true about its process, and what happens when it stops
//
// The other side of the line `slopdesk_ws_key_is_topology` draws. Topology is what the person
// ARRANGED and survives a restart; liveness is derived from a running process, republished after
// every restart and never persisted. Three decisions live here and none of them FAILS when it is
// answered twice — they render, which is why they are asked:
//
//   * a merge is CLEAR-then-write, so a fact that stopped being true disappears rather than
//     latching (the finished command, the agent that exited);
//   * marking a pane dead keeps exactly the two fields that describe a PLACE — its directory and
//     the project that directory belongs to — and drops every claim about a process;
//   * the reconciler's reap is THREE-way, and its two-way ancestor deleted the person's layout on
//     every host restart, since a just-restarted host has a full layout and no processes at all.
//
// The document rides its own encoding, as the intent applier's and the state file's do: cells in as
// the flat `SlopDeskWsEntry` pairs `slopdesk_ws_encode_snapshot` takes, the result back as an
// encoded snapshot read with `slopdesk_ws_decode_snapshot`. A liveness RECORD is the one thing on
// this path with no encoding of its own to borrow — it is what the host builds from a live PTY
// session before any of it has reached a cell — so it crosses as the struct below, its seven
// strings SPANS into the same blob the entries span. Every optional non-string carries a presence
// flag beside it rather than reserving a value to mean absent: a 0×0 grid and a pane whose size was
// never observed are different states, and `liveTitle` absent (never asserted) versus present and
// empty (RETIRED by the agent that owned it) is the same distinction one step sharper.

typedef struct {
    SlopDeskWsUuid id;
    SlopDeskWsSpan live_title;
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan project_key;
    SlopDeskWsSpan foreground_process;
    SlopDeskWsSpan running_command;
    SlopDeskWsSpan agent_label;
    SlopDeskWsSpan agent_intent;
    int64_t  last_activity_ms;   // 0 = never observed; it needs no flag, the field says so itself
    uint32_t completion_epoch;
    uint32_t last_duration_ms;   // read only when has_last_duration_ms
    int32_t  last_exit_code;     // read only when has_last_exit_code
    uint16_t grid_cols;          // read only when has_grid
    uint16_t grid_rows;          // read only when has_grid
    uint8_t  liveness;           // always meaningful: its presence IS the pane's existence
    uint8_t  agent_state;        // read only when has_agent
    uint8_t  agent_kind;         // read only when has_agent
    uint8_t  progress_state;     // read only when has_progress
    uint8_t  progress_percent;   // read only when has_progress
    bool     title_fresh;
    bool     command_running;
    bool     has_agent;
    bool     has_progress;
    bool     has_last_exit_code;
    bool     has_last_duration_ms;
    bool     has_grid;
} SlopDeskWsPaneLiveness;

// One record's cells, as an encoded snapshot. The PROJECTION rule, not a serialization: a field is
// emitted only when it carries a non-default value, with exactly one exception — the liveness state
// is always emitted, so a pane's presence in the document is never ambiguous. Never 0 for a record
// that is there, since the existence marker alone is a cell; `0` is the null record.
size_t slopdesk_ws_pane_liveness_entries(const SlopDeskWsPaneLiveness *record,
                                         const uint8_t *blob, size_t blob_len,
                                         uint8_t *out, size_t cap);

// One pane's record read back OUT of a document's cells. Every field decodes independently and a
// malformed one falls back to its default rather than failing the record: these bytes came off a
// socket, and one bad grid must not blank a pane's title.
//
// `found` is written on EVERY path, including the one where the answer did not fit, so a caller
// sizing with `(NULL, 0)` learns from the same call whether there is a pane here at all. The return
// is how many bytes of STRINGS the answer needs, §4-shaped, and `record`'s spans index `out` — so
// both are written together or neither is. A found record with no strings answers 0, which is why
// the existence question is `found` and not the return.
size_t slopdesk_ws_pane_liveness_read(const SlopDeskWsEntry *entries, size_t count,
                                      const uint8_t *blob, size_t blob_len,
                                      const SlopDeskWsUuid *pane, bool *found,
                                      SlopDeskWsPaneLiveness *record, uint8_t *out, size_t cap);

// Replaces the liveness half of every named pane, leaving their topology fields untouched. Panes
// the document holds but `records` does not name are LEFT ALONE — reaping is the next door down.
// That is why these are two entry points and not one with a flag: the wrong value of the flag is
// the whole workspace of a host that restarted and has captured nothing yet.
//
// `records` span the SAME `blob` the entries do. `changed` is written on every path and is what a
// caller versions by — every bump costs every subscriber a frame, so a no-op recapture must not
// move a version number.
//
// A document that did NOT move answers 0 and is not encoded at all. Read `changed` first: there is
// no new document to hand back, and the caller was going to discard the bytes. The three folding
// doors here (merge, mark-dead, reconcile) all share that contract, and it is what makes the idle
// backstop cheap — a settled reconcile of a 24-pane workspace measures ~69 us against ~84 us for
// one that moved, on an M-series host.
size_t slopdesk_ws_merge_pane_liveness(const SlopDeskWsEntry *entries, size_t count,
                                       const SlopDeskWsPaneLiveness *records, size_t record_count,
                                       const uint8_t *blob, size_t blob_len,
                                       bool *changed, uint8_t *out, size_t cap);

// Declares that one pane has no process — the detached store's TTL eviction. A pane the document
// has never heard of is MINTED as a dead one rather than ignored, because the existence marker is
// always written: absent is what the reaper below reads as "nothing owns this" one tick later.
size_t slopdesk_ws_mark_pane_dead(const SlopDeskWsEntry *entries, size_t count,
                                  const uint8_t *blob, size_t blob_len,
                                  const SlopDeskWsUuid *pane, bool *changed,
                                  uint8_t *out, size_t cap);

// One reconciler pass, the three-way rule: captured panes take what the capture said, panes the
// topology still names but nothing captured go STALE rather than being deleted, and panes in
// neither are reaped whole because nothing owns them. A captured pane the topology has never heard
// of is NOT reaped — a pane spawned between the last topology write and this tick would otherwise
// be deleted by the tick that first saw it. Same `blob` and same `changed` contract as the merge;
// this one runs on a 500 ms backstop, so an idle host reconciling to the same answer costs nothing.
size_t slopdesk_ws_reconcile_panes(const SlopDeskWsEntry *entries, size_t count,
                                   const SlopDeskWsPaneLiveness *records, size_t record_count,
                                   const uint8_t *blob, size_t blob_len,
                                   bool *changed, uint8_t *out, size_t cap);


// MARK: The repair pass a loader runs
//
// A hand-edited or partially-written workspace must come back rather than be refused, so every
// degenerate shape has a defined repair: an orphan spec is dropped, a spec-less pane is re-seeded,
// an out-of-range selection is clamped, an empty workspace is minted from scratch, and a persisted
// video pane is dropped rather than re-docked because a remote desktop never restores.
//
// This ran in BOTH languages until 2026-08-20 and the two did not shadow each other — the Swift
// copy fired on file load, this one on every intent — so launch-time and gesture-time repair
// reached different trees for the same input (docs/55 §8).
//
// It rides the document's own bytes, as the intent applier does: the cells go in as the flat
// `SlopDeskWsEntry` pairs `slopdesk_ws_encode_snapshot` takes, and the repaired tree comes back as
// an encoded snapshot read with `slopdesk_ws_decode_snapshot`. One shape cannot make that trip: a
// session with NO usable tab is dropped by the document ingest on both sides, rightly, since a host
// push naming one describes nothing — so the caller repairs that single case before encoding, and
// `just lint-invariants` pins it to stay that one case.

// The identity pool one repair can spend over a workspace of that shape. Sized here rather than at
// the call site: a pool one short REPEATS an identity rather than failing, and two tabs born with
// one id surfaces days later as a tab that will not close.
size_t slopdesk_ws_normalize_minted_ids(size_t sessions, size_t detached);

// How many repair passes there are, so a caller can neither name one this build lacks nor miss one
// it grew.
size_t slopdesk_ws_normalize_pass_count(void);

// `pass` is the arm order: 0 the spec table, 1 the selections, 2 both in the order a load applies
// them (specs first, so the selection repair sees a consistent set of panes), 3 the whole launch
// restore — video panes dropped, detached panes re-docked, the persisted selection preserved.
// A byte naming no pass answers 0, which is the ONLY 0: every pass over every document answers a
// workspace, because a document with none in it is answered with the re-seeded default.
size_t slopdesk_ws_normalize(uint8_t pass, const SlopDeskWsEntry *entries, size_t entry_count,
                             const uint8_t *blob, size_t blob_len,
                             const SlopDeskWsUuid *minted, size_t minted_count,
                             uint8_t *out, size_t cap);

// Whether a `pane/kind` byte names a VIDEO pane — the predicate the launch restore DROPS by. A
// second spelling of it is the exact drift docs/55 §8 records: `kind == .desktop` and
// `PaneKind::is_video` select the same panes today and stop agreeing the day a third video-ish kind
// lands on one side only. An unknown byte reads as a terminal, so it is a degraded pane rather than
// a stream opened for a window that will never exist.
bool slopdesk_ws_pane_kind_is_video(uint8_t kind);

// How many pane kinds there are, so a caller can WALK the vocabulary rather than name its members.
size_t slopdesk_ws_pane_kind_count(void);

// Whether a `pane/kind` byte names a pane text can be TYPED into — the recipient set for broadcast,
// or synchronized, input. It is the other half of the classification the video predicate above
// makes, and it is a door for that predicate's reason one register up: asking for one of a pair and
// transcribing the other is the shape docs/55 §8 catalogues, and it had already happened here — the
// Swift side spelled `self == .terminal` beside a `PaneKind::can_receive_text` in the crate that no
// Rust caller had ever reached. A third kind that both streams a display and takes typed text would
// have split the broadcast recipient set from the restore filter with both suites green.
//
// An unknown byte reads as a terminal and so DOES take text. Failing OPEN, the way the video
// predicate does: a broadcast line delivered to a pane that renders it is a better worst case than a
// keystroke silently dropped for the pane the person is looking at.
bool slopdesk_ws_pane_kind_can_receive_text(uint8_t kind);

// Which pane kind a persisted DISCRIMINATOR names. The workspace FILE's string form is read on the
// Rust side of its own door; the one file whose decoder is still Foundation's is `device-prefs.json`,
// whose captured session templates carry a `PaneKind` per leaf. The five retired names — claudeCode,
// web, chooser, remoteGUI, systemDialog — fold to `terminal` here rather than being spelled a second
// time in Swift: `DevicePreferences` decodes as one synthesized whole, so a kind that THROWS resets
// the template library, the latched video modes and the per-host connection targets together, and
// nothing logs it.
//
// `-1` is "a name this build has never had" — corruption rather than age. It is signed for the reason
// `slopdesk_fuzzy_rank` is: 0 is the most common REAL answer (it is `terminal`, which is what every
// folded retired name becomes), so `size_t` has no room for a refusal. Bytes that are not valid UTF-8
// refuse too; a discriminator is one of a closed set of ASCII names.
int32_t slopdesk_ws_pane_kind_from_raw(const uint8_t *raw, size_t len);
// One pane kind's presentation row — what the kind is CALLED, the SF Symbol name that draws it, its
// single-key mnemonic, and whether it is a video pane. All four in ONE delivery rather than four
// doors: a surface that read the title from one call and the symbol from another could draw a row
// for two different kinds if the kind byte changed between them.
//
//   [u8 is_video]
//   3 × [u32 BE length][UTF-8 bytes]   -- title, SF Symbol name, mnemonic
//
// The mnemonic rides as TEXT, not as a byte: every one of them is ASCII today, and a `uint8_t` would
// make the first non-ASCII mnemonic a silent truncation rather than a wider field. `is_video` is the
// KIND's own answer read through the table, which is the duplication the Swift value type this
// replaces admitted to in the word "mirrors".
//
// TOTAL over the vocabulary: an unknown byte draws the terminal row, so 0 is unreachable — every row
// names something.
size_t slopdesk_ws_pane_kind_option(uint8_t kind, uint8_t *out, size_t cap);

// Whether a pane's TITLE is still describing what is running in it. A title stamped before the
// command that is running now is stale — it names the last command, and a rail that prints it says
// the wrong thing for as long as the current one runs. A pane that is not live keeps its last title
// either way: there is nothing newer to be stale against.
//
// Both timestamps carry a presence FLAG rather than a sentinel, §4b's rule, and here the sentinel has
// three separate ways to be wrong: 0.0 is a real instant (the epoch), a negative is a real instant on
// a stepped clock, and a NaN compares false against everything, so "no stamp" would silently read as
// "fresh". The flag says absent once and says it in the type.
bool slopdesk_ws_pane_title_fresh(bool has_title_stamp, double title_stamped_at,
                                  bool has_command_stamp, double command_started_at,
                                  uint8_t liveness);

// MARK: Where a jump LANDED
//
// A teleport focus — the ⌘⇧U attention walk, a palette or Open Quickly row, a Global Search hit, a
// notification click — can swap the whole viewport to a different tab, or a different session, in
// one frame with no cue of where you landed. These two decide the notice chip's text. What did NOT
// cross is the lookup: which pane in the tab to ask, and what the mirror says its live title is. A
// live tree and a closure are not rules and do not cross a C boundary.

// What a tab is CALLED: an explicit rename wins; else the resolved pane's live shell title; else its
// spec title; else the "Tab" placeholder. Never empty — the chip must name something — so 0 cannot
// happen.
//
// The two optional titles cross under DIFFERENT conventions, and swapping them changes the answer.
// `has_spec` is a real presence flag, because "this pane has no spec" and "this pane's spec title is
// blank" are different facts here: with no spec the live title is not consulted at all. `live_title`
// has no flag, because an absent live title and an empty one take the same rung — a flag there would
// be a bit the caller could set two ways for one meaning.
size_t slopdesk_ws_tab_display_title(const uint8_t *tab_title, size_t tab_title_len,
                                     bool has_spec,
                                     const uint8_t *spec_title, size_t spec_title_len,
                                     const uint8_t *live_title, size_t live_title_len,
                                     uint8_t *out, size_t cap);

// The breadcrumb line itself: "<session> \xE2\x96\xB8 <tab>" when the workspace has several sessions
// and the session name is worth printing, else the tab title alone. An empty session name degrades
// to the tab-only form rather than printing a leading separator.
//
// 0 means the line is EMPTY, which exactly one input reaches: an unqualified breadcrumb over a tab
// whose title is empty. A caller that resolved the title through `slopdesk_ws_tab_display_title`
// first cannot get there.
size_t slopdesk_ws_jump_breadcrumb(const uint8_t *session_name, size_t session_name_len,
                                   const uint8_t *tab_title, size_t tab_title_len,
                                   bool include_session, uint8_t *out, size_t cap);


// The title a re-seeded pane takes, and the name a fresh workspace's first session takes. §4-shaped
// and asked for rather than transcribed: a caller comparing against its own copy passes on a
// default this crate stopped producing, and the fresh-workspace shape test IS that comparison.
size_t slopdesk_ws_default_pane_title(uint8_t *out, size_t cap);
size_t slopdesk_ws_default_session_name(uint8_t *out, size_t cap);
size_t slopdesk_ws_default_desktop_pane_title(uint8_t *out, size_t cap);


// MARK: The things that SPAWN panes — a template's layout, and the shipped tables
//
// These are the one family here whose Swift original could NOT be deleted in the same change.
// `SessionTemplate` is `Codable` and is the currency of the device-preferences file, so its Swift
// decoder is how a person's saved layouts actually come back; deleting it would delete the store's
// ability to read its own file. docs/55 §7 step 6 names that case and says what is owed instead —
// PIN it: same inputs to both sides, assert the same output. These doors exist so
// `SessionTemplateRepairDifferentialTests` can, and they are the whole reason
// `slopdesk_workspace::templates` stopped being thirteen unit tests with no caller.
//
// A layout crosses as a PRE-ORDER byte stream, the shape `slopdesk_ws_solve_layout` already uses
// for the split tree — a tag, its payload, then its children. The encoding, written down once:
//
//   text     := u32 BE length, then that many UTF-8 bytes
//   opt-text := u8 present (0 or 1), then text when present
//   uuid     := 16 bytes, canonical UUID order
//   node     := 0x00 u8:kind text:title opt-text:cwd opt-text:command      -- a pane
//             | 0x01 u8:axis u32:child_count  node × child_count           -- a split, visual order
//   template := uuid:id text:name text:symbol u8:is_built_in node:layout
//   preset   := uuid:id text:name text:command opt-text:working_directory
//               u8:has_split [u8:axis text:secondary_command when has_split]
//               text:symbol u8:is_built_in
//   table    := u32 BE count, then that many records
//
// The lengths are u32 rather than the wire's u16 because `put_length_prefixed_str` CLAMPS at 64 KiB,
// and a differential that agrees because both sides truncated the same title is worse than none.
// A present empty string and an absent one are different answers, §4b's presence rule per field.
//
// The walk is the contract: nothing is seekable, the reader goes forward once, and a stream it
// cannot consume EXACTLY — truncated, with a trailing byte, with a tag or presence byte that is
// neither of its two values — answers 0. That refusal is a shape disagreement between two encoders,
// never a degenerate template: a degenerate template has a defined repair and always answers one.

// The repair a persisted layout runs: a childless split becomes a plain terminal, a one-child split
// collapses into its child, and anything nested past `slopdesk_ws_max_depth` collapses to its first
// pane. Repaired, never rejected — the input is a file a person can edit. `0` is the stream refusal
// above and nothing else; the shortest layout there is encodes to seven bytes.
size_t slopdesk_ws_template_repair(const uint8_t *layout, size_t len, uint8_t *out, size_t cap);

// The tables a fresh workspace ships with. They cross because a shipped row's IDENTITY is fixed
// rather than minted — so that a re-seed or a settings reset MATCHES the existing row instead of
// appending a second copy of it — which makes each table a set of constants written in two
// languages, where a drift of one byte in sixteen surfaces as a duplicated menu row weeks later
// with nothing in any log.
size_t slopdesk_ws_built_in_templates(uint8_t *out, size_t cap);
size_t slopdesk_ws_built_in_launch_presets(uint8_t *out, size_t cap);
// A template EXPANDED into a session, and a live tab CAPTURED back into one. The layout goes in and
// the capture comes back as the `node` stream above — but neither direction can round-trip through
// it alone: `node` has nowhere to put a minted identity, an equal share, or the order the panes must
// be launched in, and nowhere to say that a live leaf has no spec at all. So each direction has its
// own stream, and both are written down here once:
//
//   weight    := u8 is_fixed, then u64 BE of the double's raw bit pattern
//   expanded  := 0x00 uuid:pane u8:kind text:title opt-text:cwd opt-text:command
//              | 0x01 uuid:split u8:axis u32:child_count (weight expanded) × child_count
//   captured  := 0x00 u8:has_spec [u8:kind text:title when has_spec]
//              | 0x01 u8:axis u32:child_count captured × child_count
//
// The share crosses as the BIT PATTERN, never as a decimal anyone re-parses: two sibling panes must
// be equal to the last bit or the seam drifts a pixel per restore. The launch order is the stream's
// own DFS — the caller reads the panes out in the order it must start them, and the first one is the
// active pane, so nobody re-derives either.
//
// The refusal rule is the section's: a stream that cannot be consumed EXACTLY answers 0.

// The identity pool one expansion will spend, for a layout of that shape. Sized here rather than at
// the call site: a pool one short REPEATS an identity rather than failing, and two panes born with
// one id surfaces days later as a pane that will not close. 0 is the stream refusal — ask again with
// a layout this build can read.
size_t slopdesk_ws_template_minted_ids(const uint8_t *layout, size_t len);

// The template's layout, expanded into a split tree with fresh identities and equal shares. The
// crate holds no entropy, so the identities are the caller's: bring at least
// `slopdesk_ws_template_minted_ids` of them, in any order. A pool that runs dry repeats its last
// entry rather than trapping — which is precisely the outcome the sizing door exists to prevent.
size_t slopdesk_ws_template_expand(const uint8_t *layout, size_t len,
                                   const SlopDeskWsUuid *minted, size_t minted_count,
                                   uint8_t *out, size_t cap);

// The inverse: a live tab, flattened back into a layout worth saving. Answers the `node` stream
// above, so the result is a template's layout directly. `has_tab` is false for "there is no tab to
// capture", which still answers a layout — the one-terminal default — because a template with no
// layout is not a thing the store can hold.
size_t slopdesk_ws_template_capture(const uint8_t *tab, size_t len, bool has_tab,
                                    uint8_t *out, size_t cap);


// MARK: The workspace state FILE
//
// What of the document survives a host restart, and in what shape on disk. The JSON is the boring
// half; the FILTER is not. Persisting the entry map wholesale would restore `commandRunning = 1`,
// `agentState = working` and a liveness of `attached` for a pane whose child exited weeks ago —
// a workspace of fake-live rows, busy dots spinning for nothing — so a second answer to "may this
// cell touch the disk" does not conflict with the first, it RENDERS.
//
// Both directions ride the document's own encoding, as the intent applier's do: the cells go in as
// the flat `SlopDeskWsEntry` pairs `slopdesk_ws_encode_snapshot` takes, and a decoded file comes
// back as an encoded snapshot read with `slopdesk_ws_decode_snapshot`.

// Whether one cell survives a restart. A KIND and a FIELD are all the rule reads — a pane splits by
// field, its `title` surviving where its `liveness` must not — so the caller's filter loop is a
// loop and not a decision. A kind this build does not know answers false: bytes nothing can read
// and nothing can reap would leave ghost objects with nothing able to remove them.
bool slopdesk_ws_state_file_is_persisted(uint8_t kind, uint8_t field);

// The file's bytes for a document, §4-shaped. UTF-8 JSON, sorted keys, canonical entry order, so
// two saves of one value are byte-identical. The cells are taken as given — what belongs on disk is
// the caller's own pass through `slopdesk_ws_state_file_is_persisted`. Encoding cannot fail.
size_t slopdesk_ws_state_file_encode(const SlopDeskWsEntry *entries, size_t count,
                                     const uint8_t *blob, size_t blob_len,
                                     uint8_t *out, size_t cap);

// Reads a file back, answering the surviving cells as an encoded SNAPSHOT. `status` receives the
// refusal byte on EVERY path — index 0 of `slopdesk_ws_state_file_status` when the load worked — so
// a caller wanting only the verdict passes a null `out`. `version` receives the version the file
// CLAIMED and is written on the version-mismatch path ONLY: every int64 is a version a hand edit
// can type, so none of them could have meant "not about a version". A refusal answers 0 bytes,
// which is not the four an empty document encodes to.
size_t slopdesk_ws_state_file_decode(const uint8_t *bytes, size_t len, uint8_t *status,
                                     int64_t *version, uint8_t *out, size_t cap);

// The refusal byte for one outcome, by index: 0 the load that worked, then the arms — 1 malformed
// (not our file), 2 version mismatch (our file, another shape of the store), 3 malformed row. An
// index past the last answers the malformed byte, which refuses rather than admits. Exported
// because a transcribed copy that drifted on one arm would turn a corrupt row into a
// mint-the-default, and the old file would not be kept aside.
uint8_t slopdesk_ws_state_file_status(uint8_t index);

// ---- The document's canonical order ----
//
// The wire's emission order is ascending kind, then the object id's BYTES, then field — and on the
// far side it is not a sort at all: the document is a `BTreeMap` whose key order IS that order, so
// nothing there can drift from the encoder. A caller whose document is an unordered map has to
// DERIVE it, and deriving it a second time is the pair docs/55 §8 catalogues in its nastiest form:
// two orders never disagree loudly, they RE-EMIT. A snapshot stops being byte-deterministic and a
// diff churns on map iteration order, which reads downstream exactly like a real change.
//
// The answer is a PERMUTATION, not the sorted keys: the caller already holds them and is asking
// where they GO, so handing eighteen bytes per cell back to say what an index says would copy a
// whole snapshot's keys for nothing.

typedef struct {
    uint8_t        kind;
    uint8_t        field;
    SlopDeskWsUuid object;
} SlopDeskWsDocKey;

// `out[i]` is the index, into `keys`, of the key that places `i`-th. Returns how many places there
// ARE, which is always `count` — every key comes back exactly once, so a caller rebuilds its array
// from the answer without checking for a hole. A short `cap` leaves `out` untouched and reports the
// same number, which is the §4 retry at a size the caller derives rather than guesses.
size_t slopdesk_ws_key_order(const SlopDeskWsDocKey *keys, size_t count, uint32_t *out, size_t cap);


// MARK: The client's workspace FILE
//
// The other file: the CLIENT's `workspace.json`, the arrangement a launch restores. Its decoder is
// a repairing one because the file is a person's to edit and a half-typed one still has to open,
// and the repairs are the reason it had to stop being written twice. Swift's decoder named an
// id-less split `?? SplitNodeID()` — a fresh uuid every load — where the Rust one DERIVES the name
// from the divider's place in the tree, so a `splitNode/<id>/weight` cell written before a relaunch
// was orphaned after it and every divider a person had dragged snapped back with nothing logged.
// docs/55 §8's `derived_split_id` row is what this closes.
//
// Both directions ride the document's own encoding, as the state file's and the intent applier's
// do: cells in as the flat `SlopDeskWsEntry` pairs `slopdesk_ws_encode_snapshot` takes, a decoded
// file back as an encoded snapshot read with `slopdesk_ws_decode_snapshot`. The decode REPAIRS
// before it answers, which is forced rather than chosen — a session with no tab and a leaf with no
// spec are both spellable in the file and neither is spellable in a cell, so the shape the crossing
// cannot carry never reaches it.

// The identities a decode of THESE bytes can spend, asked of the file because the shape is what the
// caller does not know yet. Sized here for the reason every pool here is: one short repeats an
// identity, and two panes sharing one is a pane that reattaches to a process it never opened.
size_t slopdesk_ws_workspace_file_minted_ids(const uint8_t *bytes, size_t len);

// Whether THESE bytes are the throwaway default a `New Window` launch autosaves — one session named
// `slopdesk_ws_default_session_name`, one tab, one terminal titled `slopdesk_ws_default_pane_title`,
// no video. The file goes in rather than a decoded shape so the two seed names are never spelled a
// second time on the caller's side. `false` is "not PROVABLY the default": unreadable bytes, a
// foreign schemaVersion and an over-large file all land there, so a file this build cannot read is
// preserved aside rather than skipped.
bool slopdesk_ws_workspace_file_is_default_shape(const uint8_t *bytes, size_t len);

// The file's bytes for a workspace, §4-shaped. UTF-8 JSON, sorted keys, trailing newline, so two
// saves of one arrangement are byte-identical. Only the topology half of the cells is read — the
// file is a LAYOUT, and liveness has no business on a disk that outlives the process it describes.
// Encoding cannot fail, so there is no status; a document with no workspace in it writes an empty
// one rather than nothing, because the file has to be a file.
//
// `schema_version` travels BESIDE the cells because the document has no cell for it: it is a
// property of this FILE and not of the shape, and the topology names it as a deliberate omission.
// The value written is the CALLER's, never this build's — a door that defaulted it would make every
// file the app saved claim the version the app reads, and the decode's version-mismatch arm would be
// reachable only from a file somebody hand-edited.
size_t slopdesk_ws_workspace_file_encode(const SlopDeskWsEntry *entries, size_t count,
                                         const uint8_t *blob, size_t blob_len,
                                         int64_t schema_version,
                                         uint8_t *out, size_t cap);

// Reads a file back, answering the REPAIRED workspace as an encoded snapshot. `minted` is the pool
// `slopdesk_ws_workspace_file_minted_ids` sized over these same bytes — panes are minted from it,
// dividers are derived inside and cost nothing. `status` receives the refusal byte on EVERY path —
// index 0 of `slopdesk_ws_workspace_file_status` when the load worked — so a caller wanting only
// the verdict passes a null `out`. `version` receives the version the file CLAIMED and is written
// on the version-mismatch path ONLY. A refusal answers 0 bytes and nothing else does: the repair
// re-seeds a workspace that named nothing, so a load past the refusal always has a session to say.
size_t slopdesk_ws_workspace_file_decode(const uint8_t *bytes, size_t len,
                                         const SlopDeskWsUuid *minted, size_t minted_count,
                                         uint8_t *status, int64_t *version,
                                         uint8_t *out, size_t cap);

// The refusal byte for one outcome, by index: 0 the load that worked, then the arms — 1 malformed
// (not a workspace file), 2 version mismatch (a workspace file of another shape), 3 more panes than
// a launch can hold. An index past the last answers the malformed byte, which refuses rather than
// admits. Exported because a transcribed copy that drifted on one arm would write over the file a
// person's whole arrangement is in instead of keeping it aside.
uint8_t slopdesk_ws_workspace_file_status(uint8_t index);

// How many panes one file may name before the decode refuses it with status index 3. Asked for
// rather than spelled twice, like every other in-process cap here — and this one is a REFUSAL
// threshold, so a drifted second copy does not read as a disagreement: the near side would build a
// file it believes fits, the far side would refuse it, and the user would meet a workspace reset to
// the default with nothing anywhere saying why.
size_t slopdesk_ws_workspace_file_max_panes(void);


// MARK: The layout structure and the split weights
//
// The layout decoder is ITERATIVE where a recursive one would need a depth cap to stay safe: it
// walks a flat array with an explicit frame stack, so a hostile nesting depth cannot overflow a
// stack that is never used. SIZE_MAX when the bytes do not decode — an unknown tag, a truncated
// node, a split claiming more children than it carries, trailing bytes, or a tree past the depth
// cap. `depth_exceeded` says which: only the last of those sets it, because a too-deep tree is a
// well-formed document this build declines to hold where the rest are a bug or an attack.

/// One node of the layout structure, in a pre-order walk.
typedef struct {
  uint8_t kind;
  uint8_t axis;
  uint8_t child_count;
  SlopDeskWsUuid id;
} SlopDeskWsLayoutNode;

size_t slopdesk_ws_decode_layout(const uint8_t *bytes, size_t len, SlopDeskWsLayoutNode *out,
                                 size_t cap, bool *depth_exceeded);
size_t slopdesk_ws_encode_layout(const SlopDeskWsLayoutNode *walk, size_t count, uint8_t *out,
                                 size_t cap);
size_t slopdesk_ws_decode_weights(const uint8_t *bytes, size_t len, SlopDeskWsShare *out,
                                  size_t cap);
size_t slopdesk_ws_encode_weights(const SlopDeskWsShare *shares, size_t count, uint8_t *out,
                                  size_t cap);

// The fixed-width ENCODERS, and the one decoder the key layer still needed. These carry no retry:
// the answer's width is known before the call, so a caller sizes its buffer once.
bool slopdesk_ws_decode_uuid(const uint8_t *bytes, size_t len, SlopDeskWsUuid *out);
size_t slopdesk_ws_encode_key(uint8_t kind, SlopDeskWsUuid object, uint8_t field_tag, uint8_t *out,
                              size_t cap);
size_t slopdesk_ws_encode_u32(uint32_t value, uint8_t *out, size_t cap);
// pane/lastExitCode, four bytes big-endian carrying the u32 bit pattern — so a signal-killed
// child's negative code survives with no sign convention for either end to get wrong. Beside the
// unsigned door rather than composed from it: the bit pattern IS the convention, and the decode
// half of that round trip was already being chosen on this side of the boundary.
size_t slopdesk_ws_encode_i32(int32_t value, uint8_t *out, size_t cap);
size_t slopdesk_ws_encode_i64(int64_t value, uint8_t *out, size_t cap);

// MARK: - The two composite field values (docs/55 §6)
//
// `session/detachedPanes` and `pane/videoTarget` are the last two field values that were parsed in
// Swift. Both came off a socket, so both are decoded by `rust/slopdesk-workspace`'s `state_codec`
// under the same rule as every other field: a count or a length that disagrees with the bytes is a
// DROP, never a lenient prefix read.
//
// Absence is a flag in both. The wire spells "no origin tab" as the all-zero uuid because the pair
// is fixed-width, and it spells "not on a display" as a presence byte because display 0 is the main
// display — neither sentinel survives the crossing.

/// A detached pane and the tab it came from, if that is still known.
typedef struct {
  SlopDeskWsUuid pane;
  SlopDeskWsUuid origin;
  bool has_origin;
} SlopDeskWsDetachedPane;

/// A pane's video source. `title` and `app_name` span the bytes the CALLER lent to the decode, so
/// they are meaningful only while that buffer is alive.
typedef struct {
  uint32_t window_id;
  uint32_t display_id;
  bool has_display;
  SlopDeskWsSpan title;
  SlopDeskWsSpan app_name;
} SlopDeskWsVideoTarget;

size_t slopdesk_ws_decode_detached_panes(const uint8_t *bytes, size_t len,
                                         SlopDeskWsDetachedPane *out, size_t cap);
size_t slopdesk_ws_encode_detached_panes(const SlopDeskWsDetachedPane *panes, size_t count,
                                         uint8_t *out, size_t cap);
bool slopdesk_ws_decode_video_target(const uint8_t *bytes, size_t len, SlopDeskWsVideoTarget *out);
size_t slopdesk_ws_encode_video_target(uint32_t window_id, uint32_t display_id, bool has_display,
                                       const uint8_t *blob, size_t blob_len, SlopDeskWsSpan title,
                                       SlopDeskWsSpan app_name, uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_DOCUMENT_H */
