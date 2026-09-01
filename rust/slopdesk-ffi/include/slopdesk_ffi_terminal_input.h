// slopdesk_ffi_terminal_input.h — what is typed at the terminal and what is found in it — the prompt, links, hints and blocks
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_TERMINAL_INPUT_H
#define SLOPDESK_FFI_TERMINAL_INPUT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------- *
 * mux_client — which panes share one flow, when that flow closes, and the two
 * loop policies both ends of the wire were spelling twice.
 *
 * The pool is a HANDLE: it holds a lane set per endpoint plus the allocator, and
 * the caller asks it one id at a time, never the whole map. The re-arm decision,
 * the backoff and the send-path mapping are questions about one integer, so they
 * cross as calls with nothing to own.
 *
 * The re-arm rule used to be written out twice in Swift, host and client, each
 * copy commented with the fact that the other existed — a contract kept by
 * reading. A datagram loop is a datagram loop; both sides call this now.
 *
 * The lane allocator's seed is the CALLER's: this side stays deterministic, so
 * the per-process random base is injected rather than drawn here. Its purpose is
 * to separate two clients' id RANGES, because the host's reply-flow maps are
 * keyed by the bare lane id and both clients used to start counting at one.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskVideoFlowPool SlopDeskVideoFlowPool;

#define SLOPDESK_LANE_UNKNOWN 0u
#define SLOPDESK_LANE_REMOVED 1u
#define SLOPDESK_LANE_FLOW_CLOSED 2u

SlopDeskVideoFlowPool *slopdesk_video_pool_new(uint32_t seed);
void slopdesk_video_pool_free(SlopDeskVideoFlowPool *handle);
size_t slopdesk_video_pool_shared_flow_count(SlopDeskVideoFlowPool *handle);
size_t slopdesk_video_pool_lane_count(SlopDeskVideoFlowPool *handle, const uint8_t *host,
                                      size_t host_len, uint16_t media_port, uint16_t cursor_port);
uint32_t slopdesk_video_pool_acquire(SlopDeskVideoFlowPool *handle, const uint8_t *host,
                                     size_t host_len, uint16_t media_port, uint16_t cursor_port,
                                     bool *out_created);
uint32_t slopdesk_video_pool_release(SlopDeskVideoFlowPool *handle, const uint8_t *host,
                                     size_t host_len, uint16_t media_port, uint16_t cursor_port,
                                     uint32_t channel_id);

/* The offsets, in seconds from the start, at which a one-shot request goes out. An interval of zero
 * or less is not a schedule but a spin, and answers with none. */
size_t slopdesk_video_request_send_offsets(double timeout_seconds, double retry_interval_seconds,
                                           double *out, size_t cap);

bool slopdesk_mux_should_rearm(bool connection_is_alive);
double slopdesk_mux_receive_backoff(uint32_t consecutive_errors);

/* ---------------------------------------------------------------------------- *
 * The flow the pool above refcounts: one media socket and one cursor socket to a host,
 * shared by every video pane pointed at it and demultiplexed by channel id.
 *
 * Plain UDP, not `NWConnection`, so three things the Swift flow could not say are said here: a
 * bring-up failure is answered by `open` instead of arriving through a state handler, a test can
 * drive the whole thing against a second socket, and there is no send-path STATE — viability is
 * the last send's answer, which is a strictly better signal because it reports the path the
 * datagrams actually took.
 *
 * FOUR obligations:
 *   1. `context` stays valid until `on_release` is called for it. This side calls it EXACTLY
 *      once per successful register, from whichever thread drops the lane's last reference —
 *      yours inside unregister/close/free, or a reader's if it was mid-delivery. Unregistering cannot
 *      join the reader that still serves the OTHER lanes, so `on_release` is the only promise
 *      this door can keep.
 *   2. The callbacks run on the flow's own reader threads, never yours. The media and cursor
 *      callbacks for the SAME lane can run CONCURRENTLY — two sockets, two threads.
 *   3. No callback may re-enter `slopdesk_video_flow_close` or `_free`. Both join those threads.
 *   4. Every pointer in every callback is LENT for that call. Keep nothing.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskVideoFlow SlopDeskVideoFlow;

// Opens the two sockets and starts both readers. NULL when `host` is not UTF-8, does not
// resolve, or either socket cannot be bound — no lane is registered then, so nothing to release.
SlopDeskVideoFlow *slopdesk_video_flow_open(const uint8_t *host, size_t host_len,
                                            uint16_t media_port, uint16_t cursor_port);
// Registers a lane's sinks under `channel_id` and PRIMES its cursor flow — the one datagram that
// has to go out for the lane to receive cursor updates at all, since the host accepts a cursor
// flow only on an inbound datagram. Re-registering an id replaces it: the old lane's
// `on_release` runs and the new one is primed. `false` only for a NULL handle.
bool slopdesk_video_flow_register_lane(SlopDeskVideoFlow *flow, uint32_t channel_id,
                                       void *context,
                                       void (*on_media)(void *context, uint8_t tag,
                                                        const uint8_t *bytes, size_t len),
                                       void (*on_cursor)(void *context, const uint8_t *bytes,
                                                         size_t len),
                                       void (*on_release)(void *context));
// Drops a lane's sinks. Datagrams for it are dropped from the next one on. An id that is not
// registered is a no-op.
void slopdesk_video_flow_unregister_lane(SlopDeskVideoFlow *flow, uint32_t channel_id);
// Sends one media datagram, tag-stamped, or one cursor datagram (the lane's re-prime). `false`
// when it did not leave.
bool slopdesk_video_flow_send_media(SlopDeskVideoFlow *flow, uint32_t channel_id, uint8_t tag,
                                    const uint8_t *payload, size_t payload_len);
bool slopdesk_video_flow_send_cursor(SlopDeskVideoFlow *flow, uint32_t channel_id,
                                     const uint8_t *payload, size_t payload_len);
// Whether the LAST media send reached the path. The session's PERIODIC producers skip their
// fire while this is false; sparse best-effort sends are not gated. `true` for NULL, the same
// optimism a fresh flow starts with.
bool slopdesk_video_flow_send_path_viable(const SlopDeskVideoFlow *flow);
// Tears both sockets down, leaving the handle VALID. JOINS both readers and runs every remaining
// lane's `on_release`, so no callback is running when this returns and none will be again; every
// later call on the handle is a cheap refusal. NULL, and a second close, are no-ops.
//
// This is how a flow ENDS; `_free` is how the handle does. They are two doors so the near side can
// hold its pointer for its whole object lifetime: a flow torn down under a thread that is inside a
// send answers false, where a flow FREED under it is a use-after-free no lock on that side can
// close — unregistering cannot join, so nothing it holds could span the call.
void slopdesk_video_flow_close(SlopDeskVideoFlow *flow);
// Releases the handle, closing it first if it is not closed already. NULL is a no-op. Carries every
// obligation the close does, plus one: no thread may be inside ANY door on this handle.
void slopdesk_video_flow_free(SlopDeskVideoFlow *flow);


/* ---------------------------------------------------------------------------- *
 * The terminal-mode tracker: which screen the host is presenting, and where the command
 * boundaries are.
 *
 * §4b's handle convention, because an escape sequence arrives in pieces — `ESC` at the end of one
 * read and `[` at the start of the next is the NORMAL case, so the parser must remember. One free
 * per new, and no two calls on one handle may overlap.
 *
 * consume() parks the marks it produced on the handle and answers how many; event() reads them out
 * one at a time. The slot holds until the next consume. One chunk can carry a prompt start, a
 * command start and a finish, and returning that run would mean either allocating across the
 * boundary or sizing a buffer for a count the caller cannot know.
 *
 * An index past the end — or a null handle — answers SLOPDESK_MODE_EVENT_NONE, and a null handle
 * reads as the shell prompt, so a caller that miscounts gets a defined non-answer, never a fault.
 * The exit code carries its own presence flag: a command that finished 0 and a `;D` mark that
 * carried nothing parsable are different facts, and only one of them means success.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskModeTracker SlopDeskModeTracker;

#define SLOPDESK_TERMINAL_MODE_SHELL_PROMPT 0u
#define SLOPDESK_TERMINAL_MODE_ALT_SCREEN 1u

#define SLOPDESK_MODE_EVENT_ENTERED_ALT_SCREEN 0u
#define SLOPDESK_MODE_EVENT_EXITED_ALT_SCREEN 1u
#define SLOPDESK_MODE_EVENT_PROMPT_START 2u
#define SLOPDESK_MODE_EVENT_COMMAND_START 3u
#define SLOPDESK_MODE_EVENT_COMMAND_STARTED 4u
#define SLOPDESK_MODE_EVENT_COMMAND_FINISHED 5u
#define SLOPDESK_MODE_EVENT_NONE 6u

typedef struct {
  uint32_t kind;
  bool     has_exit_code;
  int64_t  exit_code;
} SlopDeskModeEvent;

SlopDeskModeTracker *slopdesk_mode_tracker_new(void);
void   slopdesk_mode_tracker_free(SlopDeskModeTracker *handle);
void   slopdesk_mode_tracker_reset(SlopDeskModeTracker *handle);
size_t slopdesk_mode_tracker_consume(SlopDeskModeTracker *handle, const uint8_t *bytes, size_t len);
SlopDeskModeEvent slopdesk_mode_tracker_event(SlopDeskModeTracker *handle, size_t index);
uint32_t slopdesk_mode_tracker_mode(SlopDeskModeTracker *handle);
bool slopdesk_mode_tracker_bracketed_paste_active(SlopDeskModeTracker *handle);
bool slopdesk_mode_tracker_cursor_keys_application(SlopDeskModeTracker *handle);

/* ---------------------------------------------------------------------------- *
 * The external input surface: which box to offer, and which of the bytes coming back are merely
 * the PTY echoing what the compose box just typed.
 *
 * §4b's handle convention again, and one handle rather than two: the hold-and-confirm dedup ring
 * is reachable from nowhere but the model that owns it, and the alt-screen flip that switches the
 * box from A (a shell command line, where echo is supposed to show) to B1 (a compose overlay,
 * where it must not) is the same flip that clears a half-matched echo. The ring crosses as the
 * model's interior.
 *
 * ingest() parks the bytes to render AND the marks seen, and answers how many of each. The render
 * count cannot be known before the call — the ring may ADD bytes it had been holding on behalf of
 * an earlier chunk — so take_rendered() follows §4's sizing rule and writes nothing when the
 * answer exceeds `cap`. Neither slot is cleared by reading it; both hold until the next ingest.
 *
 * state() is one call rather than five getters because they answer the same question. A caller
 * reading them one at a time could interleave a chunk between two and render a mode from before
 * it beside an exit code from after.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskInputBox SlopDeskInputBox;

#define SLOPDESK_INPUT_AFFORDANCE_SHELL_COMMAND 0u
#define SLOPDESK_INPUT_AFFORDANCE_TUI_COMPOSE 1u

typedef struct {
  uint32_t mode;             /* SLOPDESK_TERMINAL_MODE_*    */
  uint32_t affordance;       /* SLOPDESK_INPUT_AFFORDANCE_* */
  bool     command_running;
  bool     has_exit_code;
  int64_t  exit_code;
} SlopDeskInputBoxState;

SlopDeskInputBox *slopdesk_input_box_new(void);
void   slopdesk_input_box_free(SlopDeskInputBox *handle);
void   slopdesk_input_box_reset(SlopDeskInputBox *handle);
SlopDeskInputBoxState slopdesk_input_box_state(SlopDeskInputBox *handle);
size_t slopdesk_input_box_ingest(SlopDeskInputBox *handle, const uint8_t *bytes, size_t len);
size_t slopdesk_input_box_take_rendered(SlopDeskInputBox *handle, uint8_t *out, size_t cap);
void   slopdesk_input_box_record_compose_sent(SlopDeskInputBox *handle, const uint8_t *bytes,
                                              size_t len);

/* ---------------------------------------------------------------------------- *
 * The editor-like command prompt — `rust/slopdesk-terminal`'s `prompt` module.
 *
 * ONE handle rather than a family, because the rules are coupled: typing has to abandon a history
 * walk, dismiss the completion list AND coalesce into the undo step together, and four handles
 * would put that wiring on this side in two languages. The buffer's motions, the undo stack, the
 * shell lexer that decides both the colours and whether Enter runs, the history, the reverse
 * search and the fzf ranking are all behind it.
 *
 * Derived answers (_spans, _candidates) are rebuilt per call rather than parked: they are pure
 * functions of the state, so an (out, cap) retry is byte-identical, and a cache would need
 * invalidating on thirty mutating doors.
 *
 * What stays outside: composition, key mapping, how the candidate list LOOKS, and where completion
 * candidates come from — the caller seeds paths, variables and commands.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskPrompt SlopDeskPrompt;

/* Caret motions, for _move / _extend / _delete. Every motion is also a deletion granularity. */
#define SLOPDESK_PROMPT_MOTION_GRAPHEME_BACKWARD 0u
#define SLOPDESK_PROMPT_MOTION_GRAPHEME_FORWARD 1u
#define SLOPDESK_PROMPT_MOTION_WORD_BACKWARD 2u
#define SLOPDESK_PROMPT_MOTION_WORD_FORWARD 3u
#define SLOPDESK_PROMPT_MOTION_LINE_START 4u
#define SLOPDESK_PROMPT_MOTION_LINE_END 5u
#define SLOPDESK_PROMPT_MOTION_LINE_UP 6u
#define SLOPDESK_PROMPT_MOTION_LINE_DOWN 7u
#define SLOPDESK_PROMPT_MOTION_DOC_START 8u
#define SLOPDESK_PROMPT_MOTION_DOC_END 9u

/* What a pointer gesture selects a whole one of, for _pointer_select. Named by the UNIT and not by
 * the click count: AppKit hands over an NSEvent.clickCount and the phone sends a double-tap
 * recogniser, so the gesture→unit mapping is the shell's and the unit itself is Rust's. An unknown
 * value places a caret rather than dropping the gesture. */
#define SLOPDESK_PROMPT_GRANULARITY_CARET 0u
#define SLOPDESK_PROMPT_GRANULARITY_WORD 1u
#define SLOPDESK_PROMPT_GRANULARITY_LINE 2u

/* What to paint a run as. About ROLE rather than syntax class: `main.rs` and `--verbose` are both
 * bare words to the shell, and painting them differently is the point of a rich prompt. */
#define SLOPDESK_PROMPT_TOKEN_COMMAND_NAME 0u
#define SLOPDESK_PROMPT_TOKEN_ARGUMENT 1u
#define SLOPDESK_PROMPT_TOKEN_FLAG 2u
#define SLOPDESK_PROMPT_TOKEN_PATH 3u
#define SLOPDESK_PROMPT_TOKEN_QUOTED 4u
#define SLOPDESK_PROMPT_TOKEN_VARIABLE 5u
#define SLOPDESK_PROMPT_TOKEN_OPERATOR 6u
#define SLOPDESK_PROMPT_TOKEN_REDIRECTION 7u
#define SLOPDESK_PROMPT_TOKEN_COMMENT 8u
/* A command name the user's shell could not find. NEVER produced by the lexer — it is applied from
 * a _set_word_verdicts answer, which is why it is a token kind and not a second parallel list. */
#define SLOPDESK_PROMPT_TOKEN_UNKNOWN_COMMAND 9u

/* The one construct the document left open, INNERMOST first — inside `$(echo '` the thing that
 * needs closing is the quote. NOTHING is what makes Enter run rather than continue. */
#define SLOPDESK_PROMPT_OPEN_NOTHING 0u
#define SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE 1u
#define SLOPDESK_PROMPT_OPEN_DOUBLE_QUOTE 2u
#define SLOPDESK_PROMPT_OPEN_BACKSLASH 3u
#define SLOPDESK_PROMPT_OPEN_SUBSTITUTION 4u
#define SLOPDESK_PROMPT_OPEN_BACKTICK 5u
#define SLOPDESK_PROMPT_OPEN_VARIABLE 6u
#define SLOPDESK_PROMPT_OPEN_GROUP 7u

/* What a completion candidate is. */
#define SLOPDESK_PROMPT_CANDIDATE_SUBCOMMAND 0u
#define SLOPDESK_PROMPT_CANDIDATE_FLAG 1u
#define SLOPDESK_PROMPT_CANDIDATE_DIRECTORY 2u
#define SLOPDESK_PROMPT_CANDIDATE_PATH 3u
#define SLOPDESK_PROMPT_CANDIDATE_VARIABLE 4u
#define SLOPDESK_PROMPT_CANDIDATE_HISTORY 5u

/* What _submit did. */
#define SLOPDESK_PROMPT_SUBMISSION_RUN 0u
#define SLOPDESK_PROMPT_SUBMISSION_CONTINUED 1u

/* What a Ctrl-letter does while the editor owns the command line. Four keys were never readline's
 * either — ^C, ^D on an empty line, ^Z, ^L — and an editor that swallowed them would leave the
 * terminal with no way out. */
#define SLOPDESK_PROMPT_CONTROL_EDITOR 0u
#define SLOPDESK_PROMPT_CONTROL_FORWARD 1u
#define SLOPDESK_PROMPT_CONTROL_FORWARD_AND_CLEAR 2u

/* letter is the LOWERCASE ASCII letter; anything else answers _EDITOR. */
uint8_t slopdesk_prompt_control_action(uint8_t letter, bool buffer_empty);

/* A key named without a hardware code — UIKit gives characters plus a handful of named keys, never
 * a position. _CHAR means "read the letter argument instead". */
#define SLOPDESK_PROMPT_KEY_CHAR 0u
#define SLOPDESK_PROMPT_KEY_LEFT 1u
#define SLOPDESK_PROMPT_KEY_RIGHT 2u
#define SLOPDESK_PROMPT_KEY_UP 3u
#define SLOPDESK_PROMPT_KEY_DOWN 4u
#define SLOPDESK_PROMPT_KEY_HOME 5u
#define SLOPDESK_PROMPT_KEY_END 6u
#define SLOPDESK_PROMPT_KEY_PAGE_UP 7u
#define SLOPDESK_PROMPT_KEY_PAGE_DOWN 8u
#define SLOPDESK_PROMPT_KEY_BACKSPACE 9u
#define SLOPDESK_PROMPT_KEY_DELETE 10u
#define SLOPDESK_PROMPT_KEY_TAB 11u
#define SLOPDESK_PROMPT_KEY_RETURN 12u
#define SLOPDESK_PROMPT_KEY_ESCAPE 13u

/* Which modifiers the press carried. */
#define SLOPDESK_PROMPT_MOD_SHIFT 1u
#define SLOPDESK_PROMPT_MOD_CONTROL 2u
#define SLOPDESK_PROMPT_MOD_OPTION 4u
#define SLOPDESK_PROMPT_MOD_COMMAND 8u

/* What one press does at an armed prompt. _NONE is the common answer: the press is TEXT and the
 * caller inserts its characters. */
#define SLOPDESK_PROMPT_ACTION_NONE 0u
#define SLOPDESK_PROMPT_ACTION_MOVE 1u
#define SLOPDESK_PROMPT_ACTION_DELETE 2u
#define SLOPDESK_PROMPT_ACTION_SCROLL_PAGES 3u
#define SLOPDESK_PROMPT_ACTION_HISTORY_PREVIOUS 4u
#define SLOPDESK_PROMPT_ACTION_HISTORY_NEXT 5u
#define SLOPDESK_PROMPT_ACTION_SUBMIT 6u
#define SLOPDESK_PROMPT_ACTION_INSERT_NEWLINE 7u
#define SLOPDESK_PROMPT_ACTION_COMPLETE_FORWARD 8u
#define SLOPDESK_PROMPT_ACTION_COMPLETE_BACKWARD 9u
#define SLOPDESK_PROMPT_ACTION_CANCEL 10u
#define SLOPDESK_PROMPT_ACTION_SELECT_ALL 11u
#define SLOPDESK_PROMPT_ACTION_PASTE 12u
#define SLOPDESK_PROMPT_ACTION_COPY 13u
#define SLOPDESK_PROMPT_ACTION_CUT 14u
#define SLOPDESK_PROMPT_ACTION_UNDO 15u
#define SLOPDESK_PROMPT_ACTION_REDO 16u
#define SLOPDESK_PROMPT_ACTION_SEARCH 17u
#define SLOPDESK_PROMPT_ACTION_FORWARD 18u
#define SLOPDESK_PROMPT_ACTION_FORWARD_AND_CLEAR 19u
#define SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION 20u
#define SLOPDESK_PROMPT_ACTION_ACCEPT_SUGGESTION_WORD 21u

typedef struct {
  uint8_t kind;                 /* SLOPDESK_PROMPT_ACTION_*  */
  uint8_t motion;               /* SLOPDESK_PROMPT_MOTION_*, for _MOVE and _DELETE */
  bool    extend;               /* for _MOVE: the anchor stays put */
  int32_t pages;                /* for _SCROLL_PAGES; negative reveals older output */
} SlopDeskPromptKeyAction;

/* The Mac never calls this: AppKit's key-binding table names every editing chord and delivers it as
 * a selector, so that view maps SELECTORS. UIKit has no counterpart, so the phone names its keys
 * here rather than keeping a Swift table of decisions Rust already owns. */
SlopDeskPromptKeyAction slopdesk_prompt_key_action(
    uint8_t key, uint8_t letter, uint8_t mods, bool buffer_empty, bool has_suggestion);

/* Which accept a non-extending MOTION becomes while a ghost is live — _ACCEPT_SUGGESTION,
 * _ACCEPT_SUGGESTION_WORD, or _NONE for a motion the ghost does not claim. The MAC's half of the
 * same rule: it never sees a key, because AppKit already turned the press into a selector and the
 * view turned that into a motion, so it asks one step further along. Both answers come out of one
 * function in Rust, which is what makes ->, End, ^F, cmd-> and a user's own DefaultKeyBinding.dict
 * entry behave alike. */
uint8_t slopdesk_prompt_suggestion_accept_for_motion(uint8_t motion);

/* Everything a view binds, in ONE record — so a keystroke cannot interleave between two reads and
 * pair a cursor from before it with a selection from after. Offsets are BYTES into _text. */
typedef struct {
  size_t   text_len;
  size_t   cursor;
  size_t   selection_anchor;
  size_t   selection_head;
  bool     has_selection;
  uint32_t unterminated;        /* SLOPDESK_PROMPT_OPEN_*    */
  bool     would_run;           /* Enter runs rather than continues */
  bool     walking_history;
  bool     searching;           /* the ⌃R panel's ROWS are candidate_count/selected_candidate */
  size_t   search_matches;      /* what the ⌃R query matched, INCLUDING what did not fit; 0 idle */
  bool     can_undo;
  bool     can_redo;
  size_t   span_count;
  size_t   candidate_count;
  size_t   selected_candidate;
  size_t   history_count;
  size_t   suggestion_len;      /* bytes _suggestion would answer; 0 = no ghost */
  uint64_t verdict_generation;  /* quote when asking _whence_request; hand back to _set_word_verdicts */
} SlopDeskPromptState;

/* One coloured run, as a byte range into _text. */
typedef struct {
  uint32_t start;
  uint32_t end;
  uint32_t kind;                /* SLOPDESK_PROMPT_TOKEN_*   */
} SlopDeskPromptSpan;

/* One thing that could go at the caret. `text` is what the list SHOWS and what `positions` indexes;
 * `insert` is what accepting it puts in, which differs whenever a path needs quoting. The three
 * spans index _candidate_arena; `positions` indexes _candidate_positions, which is the matched
 * character offsets of every candidate concatenated. */
typedef struct {
  SlopDeskByteSpan text;
  SlopDeskByteSpan insert;
  SlopDeskByteSpan detail;
  bool             has_detail;
  uint32_t         kind;        /* SLOPDESK_PROMPT_CANDIDATE_* */
  uint32_t         replace_start;
  uint32_t         replace_end;
  SlopDeskByteSpan positions;
} SlopDeskPromptCandidate;

SlopDeskPrompt *slopdesk_prompt_new(void);
void   slopdesk_prompt_free(SlopDeskPrompt *handle);
SlopDeskPromptState slopdesk_prompt_state(SlopDeskPrompt *handle);
size_t slopdesk_prompt_text(SlopDeskPrompt *handle, uint8_t *out, size_t cap);
size_t slopdesk_prompt_spans(SlopDeskPrompt *handle, SlopDeskPromptSpan *out, size_t cap);

/* Command validity — the one colour the lexer cannot derive from the text.
 * _whence_request answers the verb-24 request BODY for the command words nothing has answered for
 * yet (0 = nothing to ask); send it, then hand the answer body back with the `verdict_generation`
 * read when it was SENT. An answer quoting an older generation is dropped: running a command is
 * what empties the table, and one still in flight across that run would refill it with verdicts the
 * run had just made false. */
size_t slopdesk_prompt_whence_request(SlopDeskPrompt *handle, uint8_t *out, size_t cap);
void   slopdesk_prompt_set_word_verdicts(SlopDeskPrompt *handle, const uint8_t *payload,
                                         size_t payload_len, uint64_t generation);

/* Editing. _insert is one typed run; _paste is a whole clipboard, whose newlines CONTINUE the
 * document rather than submitting it. */
void   slopdesk_prompt_insert(SlopDeskPrompt *handle, const uint8_t *bytes, size_t len);
void   slopdesk_prompt_insert_newline(SlopDeskPrompt *handle);
void   slopdesk_prompt_paste(SlopDeskPrompt *handle, const uint8_t *bytes, size_t len);
void   slopdesk_prompt_delete(SlopDeskPrompt *handle, uint8_t motion);
void   slopdesk_prompt_replace_range(SlopDeskPrompt *handle, size_t start, size_t end,
                                     const uint8_t *bytes, size_t len);
void   slopdesk_prompt_clear(SlopDeskPrompt *handle);

/* The caret and the selection. _move collapses a selection, _extend grows one. */
void   slopdesk_prompt_move(SlopDeskPrompt *handle, uint8_t motion);
void   slopdesk_prompt_extend(SlopDeskPrompt *handle, uint8_t motion);
void   slopdesk_prompt_select_all(SlopDeskPrompt *handle);
/* Every pointer gesture, through one door: `anchor` is where the press landed, `head` is where the
 * pointer is now, so a click is the two equal. Each end is expanded to its own unit and the union
 * taken, which is what keeps the pressed word whole when the drag goes back past it.
 *
 * ⚠️ A word is the SHELL's word and not UAX #29's: double-clicking `--oneline` takes the flag, and
 * double-clicking inside `"two words"` takes the quoted argument. The lex that colours those runs
 * decides, so there is no "word characters" preference to configure.
 *
 * ⚠️ This is the DOCUMENT's door and CANCELS an open ⌃R session — fish's rule, since the document
 * under a search is the draft rather than the row being read. A click on a candidate ROW is
 * _select_candidate below and must not come through here. */
void   slopdesk_prompt_pointer_select(SlopDeskPrompt *handle, size_t anchor, size_t head,
                                      uint8_t granularity);

/* Copy and cut PARK the text and answer its byte length; _take_clipboard reads it under §4. Two
 * doors because the near side puts it on NSPasteboard, and a length of 0 means there was no
 * selection to take. */
size_t slopdesk_prompt_copy(SlopDeskPrompt *handle);
size_t slopdesk_prompt_cut(SlopDeskPrompt *handle);
size_t slopdesk_prompt_take_clipboard(SlopDeskPrompt *handle, uint8_t *out, size_t cap);

bool   slopdesk_prompt_undo(SlopDeskPrompt *handle);
bool   slopdesk_prompt_redo(SlopDeskPrompt *handle);

/* The history walk. _record is what a session restore replays, oldest first; an empty or
 * whitespace-only command is not recorded. */
bool   slopdesk_prompt_history_previous(SlopDeskPrompt *handle);
bool   slopdesk_prompt_history_next(SlopDeskPrompt *handle);
void   slopdesk_prompt_history_record(SlopDeskPrompt *handle, const uint8_t *bytes, size_t len);
size_t slopdesk_prompt_history_entry(SlopDeskPrompt *handle, size_t index, uint8_t *out, size_t cap);

/* Reverse search (⌃R) — a RANKED PANEL, whose rows cross through the CANDIDATE doors below rather
 * than through any of its own: a ⌃R row and a completion candidate are the same record, so a
 * second set would be the same shape twice. _again/_back move the selection down/up (wrapping,
 * `fish`'s pager ⌃R/⌃S); _accept puts the selected row on the command line and closes the search
 * WITHOUT running it; _cancel leaves the draft exactly as it was. */
void   slopdesk_prompt_search_begin(SlopDeskPrompt *handle);
void   slopdesk_prompt_search_type(SlopDeskPrompt *handle, const uint8_t *bytes, size_t len);
void   slopdesk_prompt_search_backspace(SlopDeskPrompt *handle);
bool   slopdesk_prompt_search_again(SlopDeskPrompt *handle);
bool   slopdesk_prompt_search_back(SlopDeskPrompt *handle);
bool   slopdesk_prompt_search_accept(SlopDeskPrompt *handle);
void   slopdesk_prompt_search_cancel(SlopDeskPrompt *handle);
size_t slopdesk_prompt_search_query(SlopDeskPrompt *handle, uint8_t *out, size_t cap);

/* What completion may offer. The crate does no I/O and reads no PATH: the caller seeds the
 * directory it listed, the environment it holds, and the command specs it knows, each as spans into
 * one arena — §4c's convention on the way IN. Seeding replaces what was seeded before. */
void   slopdesk_prompt_set_paths(SlopDeskPrompt *handle, const uint8_t *base, size_t base_len,
                                 const SlopDeskByteSpan *names, const bool *directories,
                                 size_t count, const uint8_t *arena, size_t arena_len);
void   slopdesk_prompt_set_variables(SlopDeskPrompt *handle, const SlopDeskByteSpan *names,
                                     size_t count, const uint8_t *arena, size_t arena_len);
void   slopdesk_prompt_add_command(SlopDeskPrompt *handle, const uint8_t *name, size_t name_len,
                                   const SlopDeskByteSpan *subcommands, size_t subcommand_count,
                                   const SlopDeskByteSpan *flags, size_t flag_count,
                                   const uint8_t *arena, size_t arena_len);

/* The fourth source, and the only one that is not a list the client already holds: what the USER's
 * OWN shell completion would offer, as verb 23's raw response payload. The bytes go straight
 * through — they are already a wire body, and spanning three levels of nesting into the arena above
 * would invent a second framing for a shape `slopdesk-wire` already frames. The answer is
 * asynchronous, so the local sources rank on their own until it lands and this door merges it in; a
 * body that will not decode CLEARS the source rather than leaving a stale list under a new caret. */
void   slopdesk_prompt_set_shell_candidates(SlopDeskPrompt *handle, const uint8_t *payload,
                                            size_t payload_len);

/* Ranks the word under the caret, answering how many candidates there are (at most `limit`). The
 * three readers below are one answer in three deliveries and must be read together. */
size_t slopdesk_prompt_complete(SlopDeskPrompt *handle, size_t limit);
size_t slopdesk_prompt_candidates(SlopDeskPrompt *handle, SlopDeskPromptCandidate *out, size_t cap);
size_t slopdesk_prompt_candidate_arena(SlopDeskPrompt *handle, uint8_t *out, size_t cap);
size_t slopdesk_prompt_candidate_positions(SlopDeskPrompt *handle, uint32_t *out, size_t cap);

void   slopdesk_prompt_select_next_candidate(SlopDeskPrompt *handle);
void   slopdesk_prompt_select_previous_candidate(SlopDeskPrompt *handle);
/* Highlights a row by index — a click on the panel, whichever panel it is. One door for both
 * because there is one list: a ⌃R session's rows ARE the candidate list. It does not accept; the
 * caller follows with _accept_completion or _search_accept by the `searching` flag it already
 * reads. False when there is no such row, which is what a stale hit test lands on. */
bool   slopdesk_prompt_select_candidate(SlopDeskPrompt *handle, size_t index);
bool   slopdesk_prompt_accept_completion(SlopDeskPrompt *handle);
void   slopdesk_prompt_dismiss_completion(SlopDeskPrompt *handle);

/* The inline autosuggestion: what the newest matching history entry would ADD past the caret, and
 * the two accepts. zsh-autosuggestions' `history` strategy, with fish's rule that the accept
 * belongs to the forward MOTION rather than to one key. _suggestion answers 0 in the five states
 * the editor suppresses on (a running search, an open candidate list, a selection, a caret away
 * from the end, a multi-line document), and the accepts answer false in the same five — which is
 * what lets a caller try the accept first and fall through to the motion the key otherwise means. */
size_t slopdesk_prompt_suggestion(SlopDeskPrompt *handle, uint8_t *out, size_t cap);
bool   slopdesk_prompt_accept_suggestion(SlopDeskPrompt *handle);
bool   slopdesk_prompt_accept_suggestion_word(SlopDeskPrompt *handle);

/* Enter. Answers SLOPDESK_PROMPT_SUBMISSION_RUN when the document is closed — it is then emptied,
 * recorded in the history, and readable once through _take_submitted — or _CONTINUED when an open
 * quote, backslash or substitution means the line kept going, which _state's `unterminated` names. */
uint8_t slopdesk_prompt_submit(SlopDeskPrompt *handle);
size_t  slopdesk_prompt_take_submitted(SlopDeskPrompt *handle, uint8_t *out, size_t cap);

/* ---------------------------------------------------------------------------- *
 * Paths, `path:line:col` diagnostics and URLs, found in the rows of the terminal grid — the one
 * scan behind the ⌘-hold underline, Jump-To and Hint Mode.
 *
 * A pure function whose ANSWER does not fit in one value: a variable-length list of records each
 * carrying up to two strings, with neither the count nor the total text length knowable before the
 * scan runs. So it crosses as an ARENA behind a handle. scan() takes every input at once and hands
 * back an owned result; counts() says how much there is; link() reads one record; take_arena()
 * copies the strings out under §4's sizing rule; free() ends it. The handle holds no policy and no
 * history — a second scan is a second handle — so the caller stays a free function with nothing
 * for two overlays to race on.
 *
 * Rows arrive as one flat UTF-8 blob plus a byte length per row, not an array of pointers: the
 * caller has to build something contiguous for the boundary either way, and one buffer means one
 * allocation and one bounds rule instead of row_count of each. Same shape for the custom scheme
 * list, which is read only under SLOPDESK_LINK_SCHEMES_CUSTOM.
 *
 * The two width entries are the same law reached two ways. text_cells() answers for a string;
 * scalar_cells() answers for one Unicode scalar the caller already holds, because the callers that
 * walk a line cell by cell would otherwise allocate a one-character string per column to ask about
 * a scalar in hand.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskLinkScan SlopDeskLinkScan;

#define SLOPDESK_LINK_KIND_ABSOLUTE_PATH 0u
#define SLOPDESK_LINK_KIND_TILDE_PATH 1u
#define SLOPDESK_LINK_KIND_RELATIVE_PATH 2u
#define SLOPDESK_LINK_KIND_PATH_LINE_COL 3u
#define SLOPDESK_LINK_KIND_URL 4u
#define SLOPDESK_LINK_KIND_FILE_URL 5u
#define SLOPDESK_LINK_KIND_NONE 6u

#define SLOPDESK_LINK_SCHEMES_ALL 0u
#define SLOPDESK_LINK_SCHEMES_CUSTOM 1u

typedef struct {
  size_t   row;              /* index into the rows scanned, NOT a scrollback line */
  size_t   col_start;        /* display CELLS, so the geometry seam just multiplies */
  size_t   col_end;
  uint32_t kind;             /* SLOPDESK_LINK_KIND_* */
  size_t   raw_offset;       /* into the arena */
  size_t   raw_length;
  bool     has_resolved;
  size_t   resolved_offset;  /* into the arena; read only when has_resolved */
  size_t   resolved_length;
} SlopDeskDetectedLink;

typedef struct {
  size_t link_count;
  size_t arena_length;
} SlopDeskLinkCounts;

SlopDeskLinkScan *slopdesk_link_scan(const uint8_t *rows, size_t rows_len,
                                     const size_t *row_lengths, size_t row_count,
                                     const uint8_t *cwd, size_t cwd_len,
                                     uint32_t scheme_mode,
                                     const uint8_t *schemes, size_t schemes_len,
                                     const size_t *scheme_lengths, size_t scheme_count,
                                     size_t max_scan_columns);
void   slopdesk_link_scan_free(SlopDeskLinkScan *handle);
SlopDeskLinkCounts slopdesk_link_scan_counts(SlopDeskLinkScan *handle);
SlopDeskDetectedLink slopdesk_link_scan_link(SlopDeskLinkScan *handle, size_t index);
size_t slopdesk_link_scan_take_arena(SlopDeskLinkScan *handle, uint8_t *out, size_t cap);

/* ---- which of those spans a point landed ON ----------------------------------------------
 * The scan above says what a span IS and the table below says what happens to it; this is the
 * question between them, asked once for a cursor and for a fingertip. It is the shortest trip in
 * this header, because the thing being asked about never travels: the caller is holding the
 * DetectedLinks the scan just handed it, so what crosses is the three numbers per span the rule
 * measures — row, first cell, one past the last — and what comes back is an INDEX into the array
 * the caller already has. No record is rebuilt and no string is copied.
 *
 * Spans arrive as one flat array of size_t triples, (row, col_start, col_end) in that order, for
 * the scan's own reason: the caller has to build something contiguous either way, so one buffer is
 * one pointer, one lifetime and one bounds rule. span_count counts SPANS rather than values — the
 * door reads exactly three times as many and never the tail of a longer buffer, and a count whose
 * triples would wrap is refused before anything is read.
 *
 * Only ONE of the two answers gets a sentinel, and which one is not a style choice. An index into
 * the caller's own array is 0..span_count by construction, so -1 cannot collide with one, the way
 * an fzf score's -1 cannot. A CELL cannot borrow that argument: (0, 0) is the most ordinary landing
 * a point has, so 0 is a real answer on both axes and the pair crosses with a FLAG beside it. `hit`
 * is read first; `row` and `column` are untouched when it is false.
 *
 * slop is how far off a span the point may be and still count, in points. 0 is the exact cell
 * hit-test a pointer wants and is what the Mac passes; the phone passes its own touch number,
 * because a fingertip is a contact patch and gets one shot at the question. The exact pass runs
 * first whatever the slop, so a slop can only ever ADD an answer where there was none.       */

typedef struct {
  size_t row;                /* 0-based, down from the viewport's top edge; read only when hit */
  size_t column;             /* 0-based display CELL, right from the viewport's left edge */
  bool   hit;                /* false for a zero cell size, a point before the origin, or a
                                non-finite ratio — three refusals a caller treats as one */
} SlopDeskLinkCell;

#define SLOPDESK_LINK_HIT_NONE ((intptr_t)-1)

SlopDeskLinkCell slopdesk_link_hit_cell(double cell_width, double cell_height,
                                        double origin_x, double origin_y,
                                        double point_x, double point_y);
intptr_t slopdesk_link_hit_span(const size_t *spans, size_t span_count,
                                double cell_width, double cell_height,
                                double origin_x, double origin_y,
                                double point_x, double point_y, double slop);

/* ---- What a gesture DOES to a link ------------------------------------------------------
 * The scan above says what a span IS; this says what happens to it. One table for all four
 * actuators (⌘click, ⌘⇧click, the context menu, hint-to-open / the jump row's return), because
 * per-actuator copies drift and each one looks right on its own.
 *
 * The answer has two halves — the verb and what it acts on — so the verb is the RETURN and the
 * payload rides the usual (out, cap) pair with `needed` carrying the retry number. A verb with an
 * empty payload is a real answer, which is why the length cannot double as the verb.
 */
#define SLOPDESK_LINK_TRIGGER_PLAIN_CLICK 0u
#define SLOPDESK_LINK_TRIGGER_COMMAND_CLICK 1u
#define SLOPDESK_LINK_TRIGGER_COMMAND_SHIFT_CLICK 2u
#define SLOPDESK_LINK_TRIGGER_OPEN 3u
#define SLOPDESK_LINK_TRIGGER_COPY_PATH 4u
#define SLOPDESK_LINK_TRIGGER_REVEAL_IN_FINDER 5u
#define SLOPDESK_LINK_TRIGGER_CHANGE_DIRECTORY 6u

#define SLOPDESK_LINK_CMD_CLICK_OPEN 0u
#define SLOPDESK_LINK_CMD_CLICK_COPY 1u
#define SLOPDESK_LINK_CMD_CLICK_NOTHING 2u

#define SLOPDESK_LINK_CMD_SHIFT_CLICK_REVEAL_FINDER 0u
#define SLOPDESK_LINK_CMD_SHIFT_CLICK_OPEN_SYSTEM_DEFAULT 1u

/* Each verb names WHERE it actuates: the file is on the host, the pasteboard and a URL are the
 * client's. An actuator routes on this without re-deriving intent. */
#define SLOPDESK_LINK_ACTION_NOTHING 0u
#define SLOPDESK_LINK_ACTION_COPY_PATH_CLIENT 1u
#define SLOPDESK_LINK_ACTION_CHANGE_DIRECTORY_PTY 2u
#define SLOPDESK_LINK_ACTION_OPEN_CODE_HOST 3u
#define SLOPDESK_LINK_ACTION_OPEN_HOST 4u
#define SLOPDESK_LINK_ACTION_REVEAL_HOST 5u
#define SLOPDESK_LINK_ACTION_OPEN_URL_CLIENT 6u

uint8_t slopdesk_link_action(uint8_t trigger, uint8_t cmd_click, uint8_t cmd_shift_click,
                             uint32_t kind, const uint8_t *raw, size_t raw_len,
                             const uint8_t *resolved, size_t resolved_len, bool resolved_present,
                             uint8_t *out, size_t cap, size_t *needed);
size_t slopdesk_link_code_open_target(const uint8_t *raw, size_t raw_len,
                                      const uint8_t *resolved, size_t resolved_len,
                                      bool resolved_present, uint8_t *out, size_t cap);
size_t slopdesk_link_line_col_suffix(const uint8_t *text, size_t len, uint8_t *out, size_t cap);
size_t slopdesk_link_posix_parent(const uint8_t *text, size_t len, uint8_t *out, size_t cap);
size_t slopdesk_link_cd_command_line(const uint8_t *text, size_t len, uint8_t *out, size_t cap);

/* ---- What a DROP does, once the pasteboard is classified and a zone is under the pointer ----
 * The same two-part answer as the link table above, for the same reason: an action with an empty
 * payload is a real answer, so the length cannot double as the verb. A dead cell answers NOTHING,
 * and the overlay reads that same answer to render the zone muted — what is offered and what would
 * happen are one number, so they cannot drift. The split side rides the VERB rather than a
 * companion flag. Nothing here can mint a video pane: that comes from the picker alone.          */
#define SLOPDESK_DROP_ZONE_NEW_TAB       0u
#define SLOPDESK_DROP_ZONE_INSERT_PATH   1u
#define SLOPDESK_DROP_ZONE_OPEN_IN_PLACE 2u
#define SLOPDESK_DROP_ZONE_SPLIT_LEFT    3u
#define SLOPDESK_DROP_ZONE_SPLIT_RIGHT   4u

#define SLOPDESK_DROP_CONTENT_FOLDER 0u
#define SLOPDESK_DROP_CONTENT_FILE   1u
#define SLOPDESK_DROP_CONTENT_URL    2u
#define SLOPDESK_DROP_CONTENT_TEXT   3u

#define SLOPDESK_DROP_ACTION_NOTHING        0u
#define SLOPDESK_DROP_ACTION_INJECT_TEXT    1u
#define SLOPDESK_DROP_ACTION_NEW_TAB_CD     2u
#define SLOPDESK_DROP_ACTION_HOST_OPEN      3u
#define SLOPDESK_DROP_ACTION_SPLIT_LEADING  4u
#define SLOPDESK_DROP_ACTION_SPLIT_TRAILING 5u

uint8_t slopdesk_drop_action(uint8_t zone, uint8_t content_kind, const uint8_t *value,
                             size_t value_len, uint8_t *out, size_t cap, size_t *needed);

/* WHICH of a drag's items IS the drop — the step before the table, on the same content codes.
 *
 * The platform layer reads the pasteboard, because AppKit and UIKit disagree about everything up to
 * the value and about nothing after it: a file URL with an `isDirectory` resource value, a web URL,
 * a plain string. What crosses is that errand's RESULT, and precedence over it — file, then url,
 * then text — is decided here. A Finder file drag also publishes its own path as text, so a reader
 * that took text first would paste every file drop instead of opening it.
 *
 * A code plus a presence flag, for `slopdesk_drop_zone_at`'s reason: `0` is a real content kind, and
 * "nothing supported was in the drag" is a real answer. `false` leaves `*kind` and `*out` untouched.
 * `*kind` lands whether or not the value fits, so a caller that only asks "is this actionable" never
 * sizes a buffer. `has_text` is separate from `text` because an EMPTY published text and no published
 * text at all classify the same but are not the same fact.                                        */
typedef struct { const uint8_t *bytes; size_t len; } SlopDeskDropText;
typedef struct { SlopDeskDropText path; bool is_directory; } SlopDeskDropFile;

bool slopdesk_drop_classify(const SlopDeskDropFile *files, size_t files_count,
                            const SlopDeskDropText *urls, size_t urls_count,
                            SlopDeskDropText text, bool has_text, uint8_t *kind,
                            uint8_t *out, size_t cap, size_t *needed);

/* WHERE the five zones are, on the same codes. The overlay asks for a zone's ellipse to draw it and
 * the receiver asks which zone a point is in, so the drawn blob and the hit region are one function
 * and a `.contentShape`-after-`.position` mistake cannot move one without the other.
 *
 * Every number inside is a fraction of the pane box, so a sidebar-sized pane and a full-screen one
 * get the same layout. `slopdesk_drop_zone_at` answers a code plus a presence flag rather than a
 * sentinel code: `0` is a real zone (New Tab), and a point in the gap between the blobs is a real
 * answer. A miss leaves `*out` untouched.                                                        */
typedef struct { SlopDeskWsPoint center; double radius_x, radius_y; } SlopDeskDropZoneShape;

SlopDeskDropZoneShape slopdesk_drop_zone_shape(uint8_t zone, double width, double height);
bool slopdesk_drop_zone_at(SlopDeskWsPoint point, double width, double height, uint8_t *out);

/* WHAT a blob is drawn with, in two answers split the way the two questions are asked. WHERE it and
 * its word go is a function of the pane box alone, so a resize asks for it and a hover does not; HOW
 * it is inked turns on `(active, allowed)`, and those three verdicts come together because a
 * renderer asking separately would be free to ask with a stale pair — a lit blob under a faded word.
 *
 * The two rungs are NAMED codes, never colours: this side holds no design tokens and each half
 * resolves the rung through its own view of the one ladder (`Slate.Status.ok` / `Slate.State.accent`
 * in SwiftUI, `Slate.Native.*` in AppKit).
 *
 * `stroke_opacity` is `0` on every zone but the hovered one, so the ring is one number rather than a
 * branch each renderer writes out, and the blob size is clamped away from the negative dimensions a
 * pane mid-layout answers with. `slopdesk_drop_zone_label` is the wording both halves draw.        */
#define SLOPDESK_DROP_ZONE_INK_OK            0u
#define SLOPDESK_DROP_ZONE_INK_ACCENT        1u
#define SLOPDESK_DROP_ZONE_INK_ACCENT_MUTED  2u

#define SLOPDESK_DROP_ZONE_LABEL_INK_PRIMARY   0u
#define SLOPDESK_DROP_ZONE_LABEL_INK_SECONDARY 1u
#define SLOPDESK_DROP_ZONE_LABEL_INK_TERTIARY  2u

typedef struct {
  double blob_width, blob_height;
  SlopDeskWsPoint label_center;
} SlopDeskDropZoneMarks;

typedef struct {
  double opacity, stroke_opacity;
  uint8_t ink, label_ink;
} SlopDeskDropZoneWash;

SlopDeskDropZoneMarks slopdesk_drop_zone_marks(uint8_t zone, double width, double height);
SlopDeskDropZoneWash slopdesk_drop_zone_wash(uint8_t zone, bool active, bool allowed);
size_t slopdesk_drop_zone_label(uint8_t zone, uint8_t *out, size_t cap);

/* ---- The OTHER drop: a dragged PANE over another pane ------------------------------------
 * The five blobs above resolve a FILE. These resolve a pane: a central swap box, four edge bands,
 * and an outer dock gutter around the whole container. Different shapes because they are different
 * questions, so they are separate rules rather than one parameterised one.
 *
 * Four callers and none may disagree. The point-to-answer half is asked by the canvas's live in-tab
 * resolution (which excludes the dragged pane's own rect) and by the cross-window INSERT resolution
 * (which has no pane in this tab to exclude). The answer-to-rects half — slab, seam, rail — is
 * asked by SlopDeskMacUI in AppKit and by SlopDeskPhoneUI in SwiftUI, and that pair is what forced
 * the move: two frameworks re-deriving a slab's half by eye is how one half draws a promise the
 * shared resolver never commits.
 *
 * The vocabulary is the video path's point/size/rect above, the same words the device panel already
 * borrows. A second rect struct with identical fields would only mean a Swift face converting
 * between two shapes for no reason.
 *
 * An edge is a CODE here and not the wire's own byte. That byte is total — every value names an
 * edge — because a peer that garbles a dock should still leave the pane on screen. This door has to
 * carry a fifth answer the wire never does: EDGE_NONE, the cursor being in no gutter at all.
 * Folding that into the byte space would make "no dock" indistinguishable from a corrupt one.
 *
 * The six tuned numbers come through a door too. They could have been six #defines here, and that
 * is exactly the failure this avoids: a literal in the header is a SECOND place the affordance is
 * written down, free to drift from the Rust the resolver runs.                                   */
#define SLOPDESK_PANE_DROP_EDGE_LEFT   0u
#define SLOPDESK_PANE_DROP_EDGE_RIGHT  1u
#define SLOPDESK_PANE_DROP_EDGE_TOP    2u
#define SLOPDESK_PANE_DROP_EDGE_BOTTOM 3u
#define SLOPDESK_PANE_DROP_EDGE_NONE   4u

#define SLOPDESK_PANE_DROP_METRIC_EDGE_BAND_FRACTION        0u
#define SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_FRACTION 1u
#define SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_MAX      2u
#define SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_FRACTION        3u
#define SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_MAX             4u
#define SLOPDESK_PANE_DROP_METRIC_RESPLIT_SEAM_THICKNESS    5u

double slopdesk_pane_drop_metric(uint32_t metric);
/* `source` is read only when `has_source`: the live drag passes the dragged pane's own rect so an
 * edge it already fully spans is skipped (docking there is a no-op), and the INSERT drag passes
 * false because every edge is meaningful when the pane is not in this tab yet. */
uint32_t slopdesk_pane_drop_container_edge(SlopDeskVideoPoint location, SlopDeskVideoRect container,
                                           SlopDeskVideoRect source, bool has_source);
bool slopdesk_pane_drop_source_spans(SlopDeskVideoRect rect, uint32_t edge,
                                     SlopDeskVideoRect container);
/* Always an edge — this one never answers EDGE_NONE. */
uint32_t slopdesk_pane_drop_dominant_edge(double u, double v, double band);
SlopDeskVideoRect slopdesk_pane_drop_slab_rect(SlopDeskVideoRect rect, uint32_t edge);
SlopDeskVideoSize slopdesk_pane_drop_seam_size(SlopDeskVideoRect slab, uint32_t edge);
SlopDeskVideoPoint slopdesk_pane_drop_seam_center(SlopDeskVideoRect slab, uint32_t edge);
SlopDeskVideoRect slopdesk_pane_drop_rail_rect(SlopDeskVideoRect container, uint32_t edge);

/* ---- The link island: one reading of the connection, drawn by two chromes ------------------
 * What the status dot, its figures and its prose SAY, for every mount that draws them: the Mac's
 * titlebar island, the phone's compact bar, the gate card that appears when the link is down, and
 * the toolbar's one-word form. Four surfaces reading one state is what forced the move — the ping
 * threshold, the disk floor and the "Reconnecting 2/5" phrasing had each been written twice.
 *
 * Two classifications feed everything else and are asked FIRST, because every other door takes one
 * of their codes back: `health` (the round trip alone) and `led` (the link's state FUSED with that
 * round trip, so a stale sample can never brighten a link that is down). The alarm doors then read
 * the LED code, not the raw status — an alarm is about what is drawn, not about what the socket is
 * doing.
 *
 * MEMORY's alarm is the one reading that does not come from a number. It comes from the kernel's own
 * verdict byte, which arrives on the wire; the percent beside it is a FIGURE, and classifying it
 * here would be this side inventing a threshold the kernel already decided. The byte's four values
 * are the wire's, restated in `SlopDeskHostPulse` rather than shared, because the rules crate sits
 * below the wire crate and an edge upward would invert the layering.
 *
 * Three doors deliver GROUPS, and each is one crossing for a set of strings that are always wanted
 * together: `words` (headline, compact label, plain state name), `pulse_prose` (spoken, tooltip),
 * and `metric_runs` (the drawn rows). The alternative — a door per string — was measured too
 * expensive inside a SwiftUI body, which is the same retreat the Settings catalogue already made.
 *
 * `max_attempts` is an ARGUMENT to every door that phrases a retry. The ceiling belongs to the
 * client's reconnect supervisor; a copy of it here would be a second place to change it.
 *
 * `has_raw_detail` answers a yes/no about the payload the caller passed IN, and never hands it
 * back. The caller is holding that string already; a copy made only to be compared with the one it
 * came from is the crossing the device panel's charter names.                                    */
#define SLOPDESK_CONNECTION_STATUS_DISCONNECTED 0u
#define SLOPDESK_CONNECTION_STATUS_CONNECTING   1u
#define SLOPDESK_CONNECTION_STATUS_CONNECTED    2u
#define SLOPDESK_CONNECTION_STATUS_RECONNECTING 3u
#define SLOPDESK_CONNECTION_STATUS_UNREACHABLE  4u
#define SLOPDESK_CONNECTION_STATUS_FAILED       5u

/* WHY the pane area is empty, and WHAT IT SAYS. A reading of the CONNECTION rather than a fact about
 * either drawing: "connected but no tabs" and "the link is down and the supervisor is redialing" are
 * different sentences the user needs to hear, and a canvas rewritten in AppKit must say the same
 * four things the SwiftUI one does.
 *
 * The CAUSE is resolved once when the connection changes and carried around as the branch a
 * renderer's action button switches on; the COPY is asked for at draw time with the host and the
 * failure reason the caller already holds, and answers `[u32 has_action]` then four `[u32 len][UTF-8]`
 * runs — the SF Symbol NAME, the title, the caption, the action label. The flag is what separates a
 * cause with NO action (a redial, which the supervisor is already driving) from one whose label
 * happens to be empty. Spans are `[host, reason]` and POSITIONAL: a wrong count answers 0 rather than
 * captioning the pane with the host.                                                               */
#define SLOPDESK_WS_PANE_EMPTY_NEVER_CONNECTED 0u
#define SLOPDESK_WS_PANE_EMPTY_LINK_DOWN       1u
#define SLOPDESK_WS_PANE_EMPTY_NO_TABS         2u
#define SLOPDESK_WS_PANE_EMPTY_CONNECT_FAILED  3u

#define SLOPDESK_WS_PANE_EMPTY_SPANS      2
#define SLOPDESK_WS_PANE_EMPTY_HEAD_BYTES 4

uint8_t slopdesk_ws_pane_empty_cause(uint32_t status_code);
size_t slopdesk_ws_pane_empty_copy(uint8_t cause, const uint8_t *blob, size_t blob_len,
                                   const SlopDeskWsSpan *spans, size_t span_count,
                                   uint8_t *out, size_t cap);

#define SLOPDESK_CONNECTION_HEALTH_OFFLINE 0u
#define SLOPDESK_CONNECTION_HEALTH_GOOD    1u
#define SLOPDESK_CONNECTION_HEALTH_SLOW    2u
#define SLOPDESK_CONNECTION_HEALTH_BAD     3u

#define SLOPDESK_CONNECTION_LED_DIM     0u
#define SLOPDESK_CONNECTION_LED_DIALING 1u
#define SLOPDESK_CONNECTION_LED_GOOD    2u
#define SLOPDESK_CONNECTION_LED_SLOW    3u
#define SLOPDESK_CONNECTION_LED_BAD     4u

#define SLOPDESK_CONNECTION_ALARM_QUIET  0u
#define SLOPDESK_CONNECTION_ALARM_RAISED 1u
#define SLOPDESK_CONNECTION_ALARM_LOUD   2u

/* Where the reading is drawn: the bedded island has room for a figure, the compact bar does not. */
#define SLOPDESK_CONNECTION_MOUNT_BEDDED  0u
#define SLOPDESK_CONNECTION_MOUNT_COMPACT 1u

/* A SOURCE, not the text: the two sources want different payloads and the caller holds both. */
#define SLOPDESK_CONNECTION_TRAILING_ABSENT      0u
#define SLOPDESK_CONNECTION_TRAILING_PING        1u
#define SLOPDESK_CONNECTION_TRAILING_STATUS_WORD 2u

#define SLOPDESK_CONNECTION_METRIC_CPU    0u
#define SLOPDESK_CONNECTION_METRIC_MEMORY 1u
#define SLOPDESK_CONNECTION_METRIC_DISK   2u

/* One host sample. `memory_pressure` is the kernel's verdict byte, not a percent; `disk_free_mib`
 * is read only when `has_disk`, because an unreadable volume is silence and not zero bytes left. */
typedef struct {
  uint32_t cpu_percent;
  uint32_t memory_percent;
  uint8_t  memory_pressure;
  uint32_t disk_free_mib;
  bool     has_disk;
} SlopDeskHostPulse;

/* `ping_ms` is read only when `has_ping`. Connected-with-no-sample is GOOD, not a fourth state. */
uint32_t slopdesk_connection_health(bool is_connected, bool has_ping, double ping_ms);
uint32_t slopdesk_connection_led(uint32_t status, bool has_ping, double ping_ms);
uint32_t slopdesk_connection_link_alarm(uint32_t led);
uint32_t slopdesk_connection_memory_alarm(uint8_t pressure);
uint32_t slopdesk_connection_disk_alarm(bool has_disk, uint32_t free_mib);
uint32_t slopdesk_connection_detail_alarm(uint32_t trailing_slot, uint32_t led);
bool     slopdesk_connection_shows_retry(uint32_t status);
uint32_t slopdesk_connection_trailing_slot(uint32_t status, bool has_ping, uint32_t mount);

/* Figures. Each is §4's plain shape: the return is the byte count the answer NEEDS. */
size_t slopdesk_connection_ping_label(double ping_ms, unsigned char *out, size_t cap);
size_t slopdesk_connection_bitrate_label(int64_t kbps, unsigned char *out, size_t cap);
size_t slopdesk_connection_disk_label(uint32_t free_mib, unsigned char *out, size_t cap);
size_t slopdesk_connection_tooltip_detail(bool has_fps, int64_t fps, bool has_kbps, int64_t kbps,
                                          unsigned char *out, size_t cap);

/* Three runs — headline, compact label, plain state name — as
 * `[uint32_t big-endian length][UTF-8 bytes]` each, in that order. `raw` is the transport's own
 * failure payload, read only for the failed status. */
size_t slopdesk_connection_words(uint32_t status, uint32_t attempt, uint32_t max_attempts,
                                 const unsigned char *raw, size_t raw_len,
                                 unsigned char *out, size_t cap);
bool slopdesk_connection_has_raw_detail(uint32_t status, const unsigned char *raw, size_t raw_len);

/* `[uint16_t big-endian count]` then count × `[uint8_t metric][uint8_t alarm][uint32_t big-endian
 * length][UTF-8 value]`. `promoted_only` is the compact mount's gate: it keeps only the runs that
 * have earned a place, and says nothing at all while the host is calm. A pulse with no runs still
 * delivers its two-byte header, so a `0` return keeps §4's literal meaning. */
size_t slopdesk_connection_metric_runs(SlopDeskHostPulse pulse, bool promoted_only,
                                       unsigned char *out, size_t cap);
/* Two runs, length-prefixed as above: spoken, then tooltip. */
size_t slopdesk_connection_pulse_prose(SlopDeskHostPulse pulse, unsigned char *out, size_t cap);
/* The pulse the footer should DRAW, given the one it is drawing and the sample that just landed.
 * Each PERCENT holds its shown figure until the sample is at least three points away, then snaps to
 * the sample exactly — the rail has no animation by design, and a percent that twitches 31 → 29 → 33
 * on an idle machine pulls the eye for nothing. Never a midpoint: the row only ever shows a number
 * the host really reported. `has_previous` is false on the first sample, which is shown as it
 * arrived — a presence flag rather than a sentinel pulse, since every field has a real reading a
 * sentinel would collide with. Pressure and free disk are exempt and pass straight through: a
 * pressure LEVEL change is a state change, and the disk figure's coarse format is its own deadband. */
SlopDeskHostPulse slopdesk_connection_pulse_settled(bool has_previous, SlopDeskHostPulse previous,
                                                    SlopDeskHostPulse sample);
/* An SF Symbol NAME, so each framework resolves it through its own image type. */
size_t slopdesk_connection_metric_symbol(uint32_t metric, unsigned char *out, size_t cap);

/* ---- What the chrome CALLS the connected host --------------------------------------------
 * A typed hostname is cut to its first DNS label (`mac-studio.local` → `mac-studio`); a typed IP
 * literal passes through WHOLE, because its dots separate octets rather than labels.
 *
 * `_is_ip_literal` answers what Darwin's `inet_pton` answers and NOT what `std::net`'s parser does.
 * The two disagree on things people type — `010.0.0.1` (padded decimal octets, accepted), and
 * `fe80::1%en0` (the zone a link-local address is useless without) — and the disagreement surfaces
 * as a WRONG LABEL rather than an error. The rule module carries the measured table.
 *
 * `_short_label` answers RAW UTF-8, not a length-prefixed run: it is one string with no second
 * field to keep it apart from. `0` means an empty label, which only an empty host produces. */
bool   slopdesk_ws_host_is_ip_literal(const unsigned char *text, size_t len);
size_t slopdesk_ws_host_short_label(const unsigned char *text, size_t len,
                                    unsigned char *out, size_t cap);

/* ---- Is anything wrong across the workspace's panes -----------------------------------------
 * The collapsed sidebar hides every per-pane surface, so a dropped or reconnecting pane would have
 * nowhere to say so until the sidebar is re-opened. This is the always-on chip's whole reading.
 *
 * `codes` are SLOPDESK_CONNECTION_STATUS_* bytes in the caller's own STABLE order — the store passes
 * tree DFS order. Only three of the six raise the chip at all: a first dial, a deliberate disconnect
 * and a live link are not alarms.
 *
 * Answer: [u32 BE unhealthy count][u32 BE worst severity][u32 BE worst index] then ONE run, the
 * chip's label. `0` is the healthy workspace, which is why the count LEADS the answer: a delivery of
 * zero length and one describing zero panes would otherwise be the same bytes. Severity ascends
 * 0 reconnecting, 1 failed, 2 unreachable; the index is the FIRST pane at the worst severity, so a
 * tie keeps the earlier pane and a click lands somewhere stable across a redraw.                */
#define SLOPDESK_WS_CONNECTION_ALERT_HEAD_BYTES 12
size_t slopdesk_ws_connection_alert(const unsigned char *codes, size_t count,
                                    unsigned char *out, size_t cap);

/* ---- The keyboard reference sheet: which column each run of shortcuts belongs in ----------
 * Balanced by RENDERED HEIGHT (a section costs its rows plus its own header line), not by section
 * count — three short categories beside one long one is the case that makes a halve-the-list split
 * look broken. Greedy: each section joins whichever column is currently shortest, so the registry's
 * declared order still reads down the page.
 *
 * Row COUNTS in, column INDICES out, against the caller's own section order — nothing about a
 * binding or a glyph crosses, which is why the Mac's two-column panel and the phone's single column
 * are the same rule asked twice. §4's plain shape at the width of a `uint32_t`: the return is how
 * many indices the answer NEEDS (always `count`), and nothing is written unless they all fit.     */
size_t slopdesk_cheat_sheet_columns(const uint32_t *row_counts, size_t count, uint32_t columns,
                                    uint32_t *out, size_t cap);

/* ---- grid geometry: where a cell span draws, and where a grid the client did not choose goes ----
 * `slopdesk_terminal::geometry` owns both. They cross together because they moved together: the
 * span rect had a live Rust twin in `link_hit::span_rect` and was left open as docs/55 §8 drift
 * because facing two multiplies would have put this header into a target that linked nothing. The
 * letterbox beside it made one dependency buy a cluster, and the pair closed on the way.
 *
 * Rows and columns cross as int64_t — Swift's `Int`. A span starting left of the viewport is a bug,
 * but reading it unsigned would draw the decoration a screen away instead of off the near edge
 * where it can be SEEN to be wrong.
 *
 * §4's value-plus-flag rather than a sentinel: a rect at the origin with no extent and a letterbox
 * with no scale are both ordinary answers, so there is no number outside the range to spend on
 * "no answer". Read `present` FIRST; the coordinates are untouched when it is false.             */

typedef struct {
  double x;
  double y;
  double width;               /* may be negative for a span whose end precedes its start */
  double height;              /* always one cell */
  bool   present;
} SlopDeskGridRect;

typedef struct {
  double content_x;
  double content_y;
  double content_width;
  double content_height;
  double scale;               /* never above 1 — a magnified glyph grid is blur */
  double natural_width;       /* 0 from slopdesk_grid_fit, which does not answer it */
  double natural_height;
  bool   present;
} SlopDeskGridPlacement;

/* Always present: an unclamped span has a rect whatever its numbers are.                        */
SlopDeskGridRect slopdesk_grid_rect(double cell_width, double cell_height,
                                    double origin_x, double origin_y,
                                    int64_t row, int64_t col_start, int64_t col_end);
/* Absent for no columns, a start at or past the last visible column, or a clamped end that does
 * not follow its start — three refusals the caller treats as one.                               */
SlopDeskGridRect slopdesk_grid_clamped_rect(double cell_width, double cell_height,
                                            double origin_x, double origin_y, int64_t cols,
                                            int64_t row, int64_t col_start, int64_t col_end);
/* The fit PLUS the natural size the surface must be framed at — only correct together.          */
SlopDeskGridPlacement slopdesk_grid_placement(int64_t cols, int64_t rows,
                                              double cell_width, double cell_height,
                                              double container_width, double container_height);
/* The fit alone, for a caller that only wants the frame. `natural_*` come back 0.               */
SlopDeskGridPlacement slopdesk_grid_fit(int64_t cols, int64_t rows,
                                        double cell_width, double cell_height,
                                        double container_width, double container_height);
/* A QUESTION about a placement the caller already holds, not a field beside it: a stored answer
 * is a second thing to keep in step, and an exact fit that grew a hairline is that drift.       */
bool slopdesk_grid_is_letterboxed(double content_x, double content_y);

/* ---- Hint Mode: every span in the viewport a two-letter label can pin to -----------------
 * The same handle-over-arena shape as the link scan above, because the answer is the same shape:
 * a variable list of records each carrying up to three strings. A LINK target carries the whole
 * detected link so the actuator routes through the ONE link policy the cmd-click path uses.
 *
 * `patterns` and `actions` are two parallel blobs under one `pattern_count`: entry i of `actions`
 * is pattern i's `{0}` template, and a length of 0 there means the pattern carries none.
 *
 * The LABELS are not here. Assigning and filtering two-letter labels is list arithmetic over 26
 * letters with no text and no untrusted input — it stays in Swift beside the overlay.            */

typedef struct SlopDeskHintScan SlopDeskHintScan;

#define SLOPDESK_HINT_KIND_LINK 0u
#define SLOPDESK_HINT_KIND_GIT_HASH 1u
#define SLOPDESK_HINT_KIND_IP_ADDRESS 2u
#define SLOPDESK_HINT_KIND_CUSTOM 3u
#define SLOPDESK_HINT_KIND_NONE 4u

typedef struct {
  size_t   row;              /* index into the rows scanned, NOT a scrollback line */
  size_t   col_start;        /* display CELLS, the same clustering the link scan reports in */
  size_t   col_end;
  uint32_t kind;             /* SLOPDESK_HINT_KIND_* */
  size_t   raw_offset;       /* into the arena */
  size_t   raw_length;
  uint32_t link_kind;        /* SLOPDESK_LINK_KIND_*; NONE unless kind is LINK */
  bool     has_resolved;
  size_t   resolved_offset;  /* into the arena; read only when has_resolved */
  size_t   resolved_length;
  bool     has_action;
  size_t   action_offset;    /* into the arena; read only when has_action */
  size_t   action_length;
} SlopDeskHintTarget;

typedef struct {
  size_t target_count;
  size_t arena_length;
} SlopDeskHintCounts;

SlopDeskHintScan *slopdesk_hint_scan(const uint8_t *rows, size_t rows_len,
                                     const size_t *row_lengths, size_t row_count,
                                     const uint8_t *cwd, size_t cwd_len,
                                     uint32_t scheme_mode,
                                     const uint8_t *schemes, size_t schemes_len,
                                     const size_t *scheme_lengths, size_t scheme_count,
                                     const uint8_t *patterns, size_t patterns_len,
                                     const size_t *pattern_lengths,
                                     const uint8_t *actions, size_t actions_len,
                                     const size_t *action_lengths,
                                     size_t pattern_count,
                                     /* The OSC 8 runs the program DECLARED, off
                                      * _hyperlink_runs: three parallel index tables beside one
                                      * URI blob. Not scanned for, not bounded by
                                      * max_scan_columns, and their columns are the ENGINE's
                                      * cells — a declared link's display text is not what it
                                      * points at, so re-clustering the row would move the badge
                                      * off the link. */
                                     const size_t *authored_rows,
                                     const size_t *authored_starts,
                                     const size_t *authored_ends,
                                     const uint8_t *uris, size_t uris_len,
                                     const size_t *uri_lengths, size_t authored_count,
                                     size_t max_scan_columns);
void   slopdesk_hint_scan_free(SlopDeskHintScan *handle);
SlopDeskHintCounts slopdesk_hint_scan_counts(SlopDeskHintScan *handle);
SlopDeskHintTarget slopdesk_hint_scan_target(SlopDeskHintScan *handle, size_t index);
size_t slopdesk_hint_scan_take_arena(SlopDeskHintScan *handle, uint8_t *out, size_t cap);

/* ---- copy mode: where a vi motion lands on ONE row, in display CELL columns --------------
 * Same grapheme clustering as the link scan above, on purpose: a cursor landed by `w` and a hint
 * badge claimed by the overlay must name the same column on a CJK row.
 *
 * The answer is an intptr_t because half these motions can fail to land — `w` off the last word,
 * `b` at the row's start — and that is a WRAP to the neighbouring row, not an error. -1 is that
 * wrap; every other answer is a real column, INCLUDING 0. The four that always land never
 * return -1.                                                                                  */
#define SLOPDESK_VI_NO_LANDING ((intptr_t)-1)
intptr_t slopdesk_vi_first_non_blank(const uint8_t *line, size_t len);
intptr_t slopdesk_vi_last_non_blank(const uint8_t *line, size_t len);
intptr_t slopdesk_vi_next_word_start(const uint8_t *line, size_t len, size_t col);
intptr_t slopdesk_vi_prev_word_start(const uint8_t *line, size_t len, size_t col);
intptr_t slopdesk_vi_word_end(const uint8_t *line, size_t len, size_t col);
intptr_t slopdesk_vi_last_word_start(const uint8_t *line, size_t len);
intptr_t slopdesk_vi_column_step(const uint8_t *line, size_t len, size_t col, intptr_t delta);
intptr_t slopdesk_vi_snap_to_cell(const uint8_t *line, size_t len, size_t col);
intptr_t slopdesk_vi_cell_width(const uint8_t *line, size_t len, size_t col);

/* ---- find in terminal: every occurrence of what the user typed --------------------------
 * A §4 blob rather than the hint scan's handle, because a match carries no strings — three
 * numbers per record, so the whole answer has a size before the scan runs and the ordinary
 * size-then-read retry is enough.
 *
 *   [uint32 count] ( [uint32 line][uint32 column][uint32 length] ) * count       all big-endian
 *
 * The count leads the blob so that ZERO matches is 4 bytes and not 0: a §4 return of 0 means "no
 * answer", and a find bar is at zero matches on most keystrokes. Columns and lengths are UTF-16
 * CODE UNITS, which is what the highlighting surface indexes in.
 *
 * The regex is the `regex` crate's — linear in the line, no lookaround, no backreferences. A
 * pattern using either does not compile and answers zero matches, the same validate-then-drop an
 * unfinished pattern always had.                                                              */
size_t slopdesk_find_matches(const uint8_t *rows, size_t rows_len,
                             const size_t *row_lengths, size_t row_count,
                             const uint8_t *query, size_t query_len,
                             bool case_sensitive, bool is_regex, bool whole_word,
                             uint8_t *out, size_t cap);

/* ---------------------------------------------------------------------------- *
 * The per-pane command blocks: one record per command the shell ran.
 *
 * The ring, the bookmark set with its FIFO cap, the jump-to-failed walk and the output-request
 * registry. What stays on the far side is what cannot cross: the CALLBACKS a resolved request fans
 * out to, and the symbol/label strings a row displays. A second copy of a UI string is drift.
 *
 * ONE handle for the ring and the registry, because a reset touches both in an order that matters:
 * the blocks die and every in-flight request has to be answered "unavailable" or a continuation is
 * left parked forever. reset() does both and PARKS the stranded indices for take_stranded() —
 * a slot, not the usual size-then-fill pair, because the reset is destructive and a sizing call
 * would drain the pending set and hand back an empty list on the second call.
 *
 * status(), duration_label() and adjacent_failed() take FIELDS rather than a handle. is_failed is
 * read per row per render, and the jump walk runs over whatever list the caller projected — so
 * neither needs the store, and making them need it would mean a test could not ask the question
 * without building one.
 *
 * project() writes every row and the one arena their command texts live in, in a single pass,
 * under §4's rule on BOTH buffers: nothing is written unless both fit, and the counts NEEDED come
 * back either way. The reader is an observed array rebuilt whole after any mutation, so a row at a
 * time would be 64 crossings for one answer.
 * ---------------------------------------------------------------------------- */

typedef struct SlopDeskBlockStore SlopDeskBlockStore;

#define SLOPDESK_BLOCK_STATUS_RUNNING 0u
#define SLOPDESK_BLOCK_STATUS_SUCCEEDED 1u
#define SLOPDESK_BLOCK_STATUS_FAILED 2u

#define SLOPDESK_BLOCK_FILTER_ALL 0u
#define SLOPDESK_BLOCK_FILTER_FAILED 1u
#define SLOPDESK_BLOCK_FILTER_BOOKMARKED 2u

typedef struct {
  uint32_t index;             /* the upsert key AND the output-request key */
  bool     has_exit_code;
  int32_t  exit_code;         /* read only when has_exit_code */
  bool     has_duration_ms;
  uint32_t duration_ms;       /* read only when has_duration_ms */
  bool     complete;
  uint32_t output_len;
  uint32_t prompt_ordinal;    /* 1-based; 0 means unknown, and such a block is not jumped to */
} SlopDeskBlockFields;

typedef struct {
  SlopDeskBlockFields fields;
  size_t command_offset;      /* into the projection's arena */
  size_t command_length;
} SlopDeskBlockRow;

typedef struct {
  uint32_t kind;              /* SLOPDESK_BLOCK_STATUS_* */
  int32_t  code;              /* meaningful only under _FAILED */
} SlopDeskBlockStatus;

typedef struct {
  size_t row_count;
  size_t arena_length;
} SlopDeskBlockCounts;

typedef struct {
  bool   replaced;            /* a known index replaced its slot; the ring did not move */
  size_t position;            /* which slot, oldest-first — meaningful only when `replaced` */
} SlopDeskBlockUpsert;

typedef struct {
  bool     send;              /* false = it coalesced onto one already in flight; send nothing */
  uint64_t generation;        /* the token a timeout has to quote back */
} SlopDeskBlockRequest;

typedef struct {
  bool     has_value;
  uint64_t value;
} SlopDeskBlockGeneration;

typedef struct {
  bool    has_value;
  int64_t value;
} SlopDeskBlockFirstSeen;

SlopDeskBlockStatus slopdesk_block_status(SlopDeskBlockFields fields);

// The status of EVERY block in one crossing, in the order given.
//
// Answers how many statuses there ARE, which is always `count`, and writes nothing unless all of
// them fit — §4's retry, at record width. The caller sizes at the length of the list it just handed
// over, so the retry is unreachable rather than merely rare.
//
// The single-field door above stays and is the one a ROW asks: it is about itself. This is for a
// caller holding the whole ring contiguous — the peek overlay's transcript derived every block's
// status inside a map, on every render pass of the overlay, and then flattened the strings it built
// back into a blob for the very next crossing. Same rule behind both; one of them is not a loop.
size_t slopdesk_block_statuses(const SlopDeskBlockFields *blocks, size_t count,
                               SlopDeskBlockStatus *out, size_t cap);
size_t slopdesk_block_duration_label(SlopDeskBlockFields fields, uint8_t *out, size_t cap);
bool   slopdesk_block_adjacent_failed(const SlopDeskBlockFields *newest_first, size_t count,
                                      bool has_from, uint32_t from_index, bool forward,
                                      uint32_t *out_index);
// Landing the viewport on an ABSOLUTE prompt ordinal out of a RELATIVE binding: scroll to the bottom,
// reach back by the re-anchor delta past every prompt there could be, then count forward by the hops.
// The delta is a constant rather than a literal on each side because the two must agree — an anchor
// that does not out-reach the scrollback leaves every jump landing short.
//
// `slopdesk_block_jump_plan` answers false when the ordinal names no position at all (a mid-stream
// join, for which the host stamped no ordinal), which is NOT the empty plan of ordinal 1, where the
// re-anchor has already landed. Otherwise it reports the hop count in `*out_count` and writes them
// when `cap` allows, the usual counted-door contract.
uint32_t slopdesk_block_jump_re_anchor_delta(void);
// The largest single forward hop the binding accepts, for a caller ASSERTING the bound rather than
// planning against it — the plan door already chunks to it.
uint32_t slopdesk_block_jump_max_step(void);
bool   slopdesk_block_jump_plan(uint32_t ordinal, uint32_t *out, size_t cap, size_t *out_count);

SlopDeskBlockStore *slopdesk_block_store_new(void);
void   slopdesk_block_store_free(SlopDeskBlockStore *handle);
SlopDeskBlockUpsert slopdesk_block_store_upsert(SlopDeskBlockStore *handle,
                                                SlopDeskBlockFields fields, const uint8_t *text,
                                                size_t text_len, int64_t now);
SlopDeskBlockCounts slopdesk_block_store_project(SlopDeskBlockStore *handle,
                                                 SlopDeskBlockRow *rows, size_t row_cap,
                                                 uint8_t *arena, size_t arena_cap);
SlopDeskBlockFirstSeen slopdesk_block_store_first_seen(SlopDeskBlockStore *handle, uint32_t index);
/* The RING INDEX of the block whose 1-based PROMPT ordinal is `ordinal`, or -1 for none — the one hop
 * between the two keys a block wears. A pointer hit-test answers an ORDINAL (the join key, stable
 * while the layout under it re-flows); everything that ACTS on a block is keyed by the ring index.
 * Ordinal 0 is "the host attached mid-stream and could not count prompts", which several blocks can
 * wear, so it resolves to nothing; a duplicate resolves to the NEWEST index, still on screen. */
int64_t slopdesk_block_store_index_of_prompt_ordinal(SlopDeskBlockStore *handle, uint32_t ordinal);
size_t slopdesk_block_store_filtered(SlopDeskBlockStore *handle, uint32_t filter,
                                     uint32_t *out, size_t cap);
bool   slopdesk_block_store_is_bookmarked(SlopDeskBlockStore *handle, uint32_t index);
void   slopdesk_block_store_toggle_bookmark(SlopDeskBlockStore *handle, uint32_t index);
void   slopdesk_block_store_set_bookmarks(SlopDeskBlockStore *handle, const uint32_t *indices,
                                          size_t count);
size_t slopdesk_block_store_bookmarks(SlopDeskBlockStore *handle, uint32_t *out, size_t cap);
SlopDeskBlockRequest slopdesk_block_store_request(SlopDeskBlockStore *handle, uint32_t index);
bool   slopdesk_block_store_is_pending(SlopDeskBlockStore *handle, uint32_t index);
SlopDeskBlockGeneration slopdesk_block_store_current_generation(SlopDeskBlockStore *handle,
                                                                uint32_t index);
bool   slopdesk_block_store_resolve(SlopDeskBlockStore *handle, uint32_t index);
bool   slopdesk_block_store_time_out(SlopDeskBlockStore *handle, uint32_t index,
                                     bool has_generation, uint64_t generation);
size_t slopdesk_block_store_reset(SlopDeskBlockStore *handle);
size_t slopdesk_block_store_take_stranded(SlopDeskBlockStore *handle, uint32_t *out, size_t cap);

/* ---------------------------------------------------------------------------- *
 * Re-running a captured command: the exact bytes to inject into the pane's shell so the host sees a
 * person typing (wire type 3, `.input`). No host and no wire change.
 *
 * The command crosses VERBATIM as its own UTF-8 and comes back as bytes, and that is the security
 * rule rather than a convenience. A captured command may literally contain the substring `<Enter>`
 * — `echo "<Enter>"` is a command a person runs — so routing it through the send-keys token parser
 * the way a user-authored launch preset is routed would turn that text into a control byte and
 * replay something other than what ran. The text is also downstream of host output, therefore
 * attacker-influenced. Nothing is parsed, nothing is escaped, nothing is interpreted.
 *
 * A return of 0 means SEND NOTHING — the command was empty or whitespace-only, and a bare newline
 * at a prompt only redraws the prompt. §4's "0 is no answer" is admissible here for a property of
 * the rule rather than a convention: a command that IS encoded always ends in the 0x0A that
 * executes it, so a real answer can never be empty and can never be mistaken for the refusal. The
 * wrapped crate's suite pins that over a corpus, on the side that can see it.
 *
 * Sizing is arithmetic rather than a guess: the answer is the command minus its trailing CR/LF run
 * plus one newline, so `command_len + 1` is an upper bound and the §4 retry never runs.
 * ---------------------------------------------------------------------------- */

size_t slopdesk_block_rerun_bytes(const uint8_t *command, size_t command_len, uint8_t *out,
                                  size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_TERMINAL_INPUT_H */
