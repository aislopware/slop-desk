// slopdesk_ffi_chrome.h — what the window's chrome, its sidebar and its rail show around the panes
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_CHROME_H
#define SLOPDESK_FFI_CHROME_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Peek & Reply: the same ordering with one clause in front of it -------------
//
// The card ANSWERS a blocked pane in place instead of jumping to it, so a focused pane that is
// itself blocked is taken first. `answered` is the advance-to-next exclusion: a pane replied to a
// moment ago keeps reporting blocked until the host re-reports, so without it the card would hand
// back the pane it had only just finished with.

// `is_focused` names the FOCUSED pane rather than a position, because that pane need not appear in
// `statuses` at all. `present == false` is "nothing waiting", which is not position 0.
typedef struct {
    bool   present;
    bool   is_focused;
    size_t position;
} SlopDeskPeekTarget;

// `present == false` is "no queue worth counting" — a total under two, where the calm static
// caption stays. Never a sentinel: "1 of 1" and "no queue" are different things to draw.
typedef struct {
    bool     present;
    uint32_t position;
    uint32_t total;
} SlopDeskPeekQueue;

SlopDeskPeekTarget slopdesk_agent_peek_target(bool has_focused, uint8_t focused_status,
                                              bool focused_answered, const uint8_t *statuses,
                                              const bool *answered, size_t len);
// `answered_count` is how many panes this run has already advanced past, and is NOT counted out of
// `answered`: a pane can be answered and then closed, which takes it out of the list without taking
// back the fact that it was answered — a total counted from the flags would shrink as it was worked.
SlopDeskPeekQueue  slopdesk_agent_peek_queue(const uint8_t *statuses, const bool *answered,
                                             size_t len, size_t answered_count);

// The rollup RANK — the wire's type-27 state byte — which is deliberately not the case order:
// none(0) < idle(1) < done(2) < working(3) < needsPermission(4). from_urgency degrades unknown to
// none, so a newer host's datagram cannot trap an older client.
uint8_t slopdesk_agent_status_urgency(uint8_t status);
uint8_t slopdesk_agent_status_from_urgency(uint8_t urgency);
size_t  slopdesk_agent_status_display_label(uint8_t status, uint8_t *out, size_t cap);

// The TEMPORAL LAYER has no doors here at all, and `docs/60` F.9 is why.
//
// It had a handle apiece for the scan and the detector, and thirty-odd entries between them: a
// two-call tick (plan, then finish) over `SlopDeskPaneScan`, five `repr(C)` shapes to carry the
// halves — a tick, a plan, a verdict, an answer and the `SlopDeskAgentDetection` all four passed
// around — and, on the detector, a `reestablish`, six read-only observers and six text slots drained
// through a four-bit EMIT mask. Below them, `slopdesk_agent_hold_constant` handed the six tuning
// numbers over one index at a time, so a Swift test could name the interval a scanner had tightened
// to without typing it a second time.
//
// Every one of them existed because a SWIFT host drove the crate's clock: the socket had to stay on
// the near side, so the tick was split in two, and the emission had to come back one slot at a time
// because a C boundary cannot hand over a Rust enum. F.9 deleted that host.
//
// `rust/slopdesk-hostsession` LINKS `slopdesk-agentdetect` and calls `PaneScan` and `PaneDetector`
// directly (`docs/50`), so the bitmask-then-drain dance — a second wire format nobody asked for — is
// gone, so are the two discriminant maps that existed only to survive the crossing, and the six
// constants are read as constants.

// The foreground JOB has no doors here. It used to have six plus a resolver callback, so Swift
// could hand over a process group it had probed itself; both halves live in Rust now and the
// question is asked once, as slopdesk_pty_foreground_agent below (macOS only, like the probe).

// The prevent-sleep POLICY has no door here either. Asking it separately meant Swift held the
// working-pane set and the IOPMAssertion beside it and could apply a verdict computed against a set
// another thread had already moved; both live behind one macOS-only handle now, further down.

// MARK: - The workspace document's solvers (`rust/slopdesk-workspace`)
//
// The document's VALUE TYPES stay in Swift — 262 files import them, and a `SplitNode` is what
// SwiftUI diffs. What crosses is the half that decides: where focus lands, what order the sidebar's
// sections come in, which tab survives a close. Everything is flat: an array of `(id, rect)` in, an
// answer out, and no state owned between calls.

// A UUID in its own byte order, so a sort by id agrees on both sides.
typedef struct { uint8_t bytes[16]; } SlopDeskWsUuid;

// Laid out exactly as Swift's `CGRect` reads it.
typedef struct { double x, y, width, height; } SlopDeskWsRect;
typedef struct { double x, y; } SlopDeskWsPoint;

typedef struct {
    SlopDeskWsUuid id;
    SlopDeskWsRect rect;
} SlopDeskWsFrame;

// A slice of the caller's strings blob. `present == false` is Swift's `nil`; a present span of
// length 0 is an empty string, which is not the same question.
typedef struct {
    size_t offset;
    size_t len;
    bool   present;
} SlopDeskWsSpan;

typedef struct {
    SlopDeskWsUuid id;
    SlopDeskWsSpan key;
} SlopDeskWsKeyedTab;

// `<Token>`-marked text as the bytes a PTY receives.
size_t slopdesk_ws_send_keys(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
bool slopdesk_ws_key_token(const uint8_t *name, size_t len, uint8_t *out, size_t cap,
                           size_t *needed);
size_t slopdesk_ws_shell_quote(const uint8_t *bytes, size_t len, bool bare_if_safe, uint8_t *out,
                               size_t cap);
size_t slopdesk_ws_redact_secrets(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);

// The placeholder a masked credential collapses to. §4-shaped. Asked for because it is what a
// caller ASSERTS against, and a transcribed copy passes on a mask the redactor stopped producing.
size_t slopdesk_ws_secret_mask(uint8_t *out, size_t cap);
bool   slopdesk_ws_looks_secret(const uint8_t *bytes, size_t len);
// The pane-directory classifier and the leaf a row shows. `slopdesk_ws_cwd_display_name` answers 0
// for "no name to show" — an absent, blank or all-slashes path — which a real name can never be.
bool   slopdesk_ws_transient_plugin_cwd(const uint8_t *bytes, size_t len);
size_t slopdesk_ws_cwd_display_name(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
// The WHOLE directory, as a badge prints it: a `/Users/<name>` or `/home/<name>` prefix collapsed to
// `~`, and a trailing `/` marking it a directory. Matched by SHAPE, never against this machine's own
// home — the path came off the remote host. `0` here means the path was empty.
size_t slopdesk_ws_cwd_badge_path(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
uint8_t slopdesk_ws_paste_risk(const uint8_t *bytes, size_t len, bool target_is_secure,
                               size_t max_length);

// ---- A clipboard as the KEYS that type it --------------------------------------
//
// macOS drops synthetic UNICODE events at a secure field, and takes synthetic KEY events, so the
// only paste a `sudo` prompt accepts is the text spelled back out as US-QWERTY presses. The unit
// walked is the grapheme CLUSTER, never the scalar: a decomposed "é" walked as scalars would type
// a bare "e" into a password field and report one skip, which is a DIFFERENT password accepted
// with nothing on screen to say so.

// The largest clipboard, in CLUSTERS, that will be replayed. Also the ceiling
// `slopdesk_ws_paste_risk` refuses past — one number, asked for at both sites.
#define SLOPDESK_KEYSTROKE_MAX_LENGTH 4096

// `[u32 BE skipped][u32 BE count]` then `count` × `[u16 BE key_code][u8 shift]`. Never 0: an empty
// clipboard is the eight header bytes with both counts zero, which is not §4's refusal. `skipped`
// counts a cluster with no key AND every cluster past the cap — in both cases the field will not
// hold what the clipboard did, and the caller has one banner to say so with.
size_t slopdesk_keystroke_replay(const uint8_t *text, size_t text_len, uint8_t *out, size_t cap);

// ---- The same keys, asked for by POSITION ---------------------------------------
//
// A hardware keyboard driving a remote DESKTOP sends the layout-level KEYCODE, so the HOST's layout
// and input method interpret it server-side — a key sent as a pre-baked character is invisible to a
// keycode-driven IME composer, and Vietnamese Telex would never compose. The USB HID usage is the
// one thing a key event carries that names POSITION rather than meaning.
//
// Its printable run is the table above, read by index instead of by character: the same 47
// `kVK_ANSI_*` numbers, resolved through the character the key types, so they exist once. What the
// module adds is the run that has no character — escape, backspace, F1…F12, the navigation cluster,
// the keypad, the two ISO extras and both sides of every modifier.
//
// The answer is a value plus a FLAG and not a keycode alone, because `kVK_ANSI_A` is `0` and `a` is
// the commonest key on the board: a sentinel here would make "the letter a" and "this key has no
// macOS equivalent" the same answer, and the second one must send NOTHING.
typedef struct {
  uint16_t key_code;
  bool     mapped;
} SlopDeskHidVirtualKey;

SlopDeskHidVirtualKey slopdesk_hid_virtual_key(uint16_t hid_usage);
// Either side of ⌘⇧⌃⌥, or Caps Lock. The caller latches these so a focus change that swallows the
// release can synthesize the missing key-up.
bool                  slopdesk_hid_is_modifier(uint16_t hid_usage);

// ---- A device panel's hardware key -------------------------------------------
//
// The Android panel and the simulator panel ask one question in one order — does this key have a
// character of its own? — and differ only at the last step, where one wants a `KeyEvent` keycode
// and the other a `KeyboardEvent.code` string. `hid` picks the NUMBERING: a Mac reports a virtual
// keycode, an iPad a USB HID usage. That is one bit, so it rides as one rather than doubling every
// door with a per-numbering twin.
//
// The HID side is DERIVED from `slopdesk_hid_virtual_key` above, not tabulated. Four Swift maps
// became two here, because two of them were that composition written out — and a written-out join
// drifts from the thing it joins.

// The simulator server's `KeyboardEvent.code`, or `0` for a key that types text and belongs on the
// `type` envelope instead. `0` is safe as "no code" where it was not for the keycode door above:
// every name this vocabulary answers is non-empty, so an empty delivery is outside the answer's
// range rather than colliding with a real one.
size_t slopdesk_panel_simulator_key_code(uint16_t code, bool hid, uint8_t *out, size_t cap);

// What the Android panel should do about one key-down, TAGGED by its first byte.
#define SLOPDESK_ANDROID_KEY_NOTHING 0
#define SLOPDESK_ANDROID_KEY_KEYCODE 1
#define SLOPDESK_ANDROID_KEY_TEXT    2
// `NOTHING` is the whole answer. `KEYCODE` is followed by the `KeyEvent` keycode and the meta state
// as four big-endian bytes each. `TEXT` is followed by the UTF-8 to type. A return larger than
// `cap` means nothing was written — ask again at that size.
//
// One blob rather than a "which case" door plus a conditional second call: the caller cannot know
// the shape until the rule has run, and two crossings for one question is a window in which they
// could disagree.
//
// `characters` is what the near side's layout produced; `bare` is the same press with the layout's
// modifier handling stripped. Each carries a PRESENT flag beside its pair, because absent and empty
// are different answers here — absent falls back to `bare`, empty means the press produced nothing
// — and a null pointer standing for both would silently turn the second into the first.
size_t slopdesk_panel_android_key_resolve(uint16_t code, bool hid, const uint8_t *characters,
                                          size_t characters_len, bool characters_present,
                                          const uint8_t *bare, size_t bare_len, bool bare_present,
                                          uint8_t modifiers, uint8_t *out, size_t cap);

// Android's `META_*` bitmask for a set of held modifiers. SHIFT is deliberately not in it: the near
// side has already applied it — the characters arriving with the event are already upper case — so
// folding it in would ask the device to apply it twice. Exported beside the door above because the
// panel's toolbar presses a keycode with no key event behind it.
uint32_t slopdesk_panel_android_meta_state(uint8_t modifiers);

// ---- Peek & Reply: what the card sends, and the tail it shows -------------------
//
// Which PANE it answers is `slopdesk_agent_peek_*` above. Every reply carries its own single
// trailing newline; `0` means send NOTHING, which is an empty, whitespace-only or bare-`!` field.
size_t slopdesk_ws_peek_reply_text(const uint8_t *field, size_t field_len, uint8_t *out, size_t cap);
// A quick-answer digit typed into an empty field. `0` for anything outside 1–9.
size_t slopdesk_ws_peek_quick_answer(int32_t digit, uint8_t *out, size_t cap);
// The `limit` newest blocks as one line each, oldest-first, from two PARALLEL flat blobs under one
// count. `[u32 BE lines]`, then that many `[u32 BE length]` words, then the bytes back to back —
// the count leads so "this pane has no blocks yet" is not §4's "ask again".
size_t slopdesk_ws_peek_recent_lines(const uint8_t *commands, size_t commands_len,
                                     const size_t *command_lengths, const uint8_t *statuses,
                                     size_t statuses_len, const size_t *status_lengths,
                                     size_t count, size_t limit, uint8_t *out, size_t cap);

// What a preset or a template types into the pane it just opened: a literal `cd` line when a
// directory is set, then the command through the token parser. A null or empty `cwd` is "no
// directory". The `cd` line never reaches the parser — a `<Enter>` inside a path would otherwise
// end the quoted line early and run the rest as its own command.
size_t slopdesk_ws_launch_keystrokes(const uint8_t *command, size_t command_len,
                                     const uint8_t *cwd, size_t cwd_len,
                                     uint8_t *out, size_t cap);

// What to tell the operator when the host cannot listen. Both questions are here because a bind
// conflict can arrive as a FAILURE or hide inside the framework's retryable waiting state, and both
// spell it in text. The RANGE question that used to lead this block went with
// `Sources/SlopDeskTransport/PortValidation.swift` in `docs/63` G.3 — nothing in Swift validates a
// port any more, because nothing in Swift dials one.
bool    slopdesk_ws_listen_detail_is_address_in_use(const uint8_t *bytes, size_t len);
bool    slopdesk_ws_listen_waiting_errno_is_fatal(int32_t posix_errno);

// The port a host binds, and a client dials, when nobody says otherwise. NOT behind the macOS gate
// with the rest of hostd's command line, because this is the one fact in that domain BOTH ends
// need: the client's connect gate prefills it and the menu-bar app seeds the host it starts with
// it. Three halves once spelled it separately and two disagreed — the menu-bar app stored 7779
// while the client dialled 7420 — so all three ask here instead.
uint16_t slopdesk_hostd_default_port(void);

// Direction: 0 left · 1 right · 2 up · 3 down · 4 next · 5 previous.
bool slopdesk_ws_focus_neighbor(const SlopDeskWsFrame *frames, size_t count,
                                SlopDeskWsUuid pane, uint8_t direction, SlopDeskWsUuid *answer);
bool slopdesk_ws_focus_cycle(const SlopDeskWsUuid *panes, size_t count,
                             SlopDeskWsUuid from, bool forward, SlopDeskWsUuid *answer);

// 0 bytes = absent. A present key is never empty, so the two never collide.
size_t slopdesk_ws_project_key(const uint8_t *bytes, size_t len, bool present,
                               uint8_t *out, size_t cap);
size_t slopdesk_ws_section_header(const uint8_t *bytes, size_t len, bool present,
                                  uint8_t *out, size_t cap);
bool   slopdesk_ws_section_precedes(const uint8_t *left, size_t left_len, bool left_present,
                                    const uint8_t *right, size_t right_len, bool right_present);

// `tabs` is the display order and still CONTAINS `closing`; each entry carries the project key the
// caller's closure answered, spanning into `strings`.
bool slopdesk_ws_successor_after_close(SlopDeskWsUuid closing,
                                       const SlopDeskWsKeyedTab *tabs, size_t tab_count,
                                       const uint8_t *strings, size_t strings_len,
                                       const SlopDeskWsUuid *history, size_t history_count,
                                       SlopDeskWsUuid *answer);

// Where a newly opened tab lands in the tab bar, under the `new-tab-position` policy `position`
// names: `auto`, `end` or `after-current`. Those spellings are the client's persisted setting and
// the settings catalog's own option tokens for this group, so both sides were already holding them
// — which is why the policy crosses as its spelling rather than as the intent wire's byte, a byte
// here being a third map from the same three cases to the same three numbers. A spelling this build
// has never had places the tab where the DEFAULT does rather than refusing, and that fallback is the
// crate's, so it is one answer and not one per reader.
//
// Both counts are signed because the caller's are: a tab list is counted in `Int`, and an active
// index read out of a restored document can name a tab that has since closed. A negative count is
// no tabs, a negative active index is the first one, and the answer is always a valid insertion
// index in 0..=max(tab_count, 0). There is no refusal in it — every policy places every list — and 0
// is a real answer, being where a tab lands in an empty bar, which is why this is not §4-shaped.
int64_t slopdesk_ws_new_tab_index(const uint8_t *position, size_t position_len,
                                  int64_t active_index, int64_t tab_count);

// What a pane is CALLED, in the one precedence every surface that names one shares — the rail row,
// the tab strip, the pane switcher, the window title. Each `0` below is documented per door: for
// the name and mark doors it is "no answer, keep your own rung"; for the two TITLE doors it
// is the EMPTY title, which the at-root idle shell yields on purpose so the live chain can speak.
size_t slopdesk_ws_slot_process_name(const uint8_t *bytes, size_t len, bool present,
                                     uint8_t *out, size_t cap);
size_t slopdesk_ws_process_display_name(const uint8_t *bytes, size_t len, bool present,
                                        uint8_t *out, size_t cap);
bool   slopdesk_ws_slot_label_is_command(const uint8_t *bytes, size_t len, bool present);
bool   slopdesk_ws_is_agent_session(bool has_agent_status, const uint8_t *bytes, size_t len,
                                    bool present);
// Asked for rather than transcribed: a copy pinned to a different presentation would draw a
// different glyph beside the same rows.
size_t slopdesk_ws_agent_title_mark(uint8_t *out, size_t cap);
uint32_t slopdesk_ws_command_title_min_duration_ms(void);
size_t slopdesk_ws_agent_marked_title(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
size_t slopdesk_ws_normalized_program_title(const uint8_t *bytes, size_t len, bool present,
                                            uint8_t *out, size_t cap);

// The two composite inputs. Every string is a span into the ONE `strings` blob passed alongside —
// one pointer, one lifetime, one scope, where a `(ptr, len)` per field would mean seven nested
// borrows per row per frame. `kind` is a PaneKind byte: 0 terminal, 1 desktop.
typedef struct {
    uint8_t        kind;
    SlopDeskWsSpan spec_title;
    bool           user_renamed;
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan live_title;
    SlopDeskWsSpan process_label;
    SlopDeskWsSpan project_key;
} SlopDeskWsRowTitle;

// Line two. `spec_title` absent is a pane with no spec, which has no second line at all;
// `project_key` absent is a surface with no section headers, where the full path is the only place
// the location can be shown.
typedef struct {
    uint8_t        kind;
    SlopDeskWsSpan spec_title;
    bool           video_present;
    SlopDeskWsSpan video_app_name;
    SlopDeskWsSpan video_title;
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan live_title;
    SlopDeskWsSpan project_key;
} SlopDeskWsSubtitle;

typedef struct {
    SlopDeskWsSpan structural_title;
    bool           user_renamed;
    bool           is_agent;
    SlopDeskWsSpan intent;
    SlopDeskWsSpan running_command;
    SlopDeskWsSpan program_title;
    SlopDeskWsSpan process_title;
    uint8_t        kind;
    SlopDeskWsSpan cwd_title;
    SlopDeskWsSpan fallback;
} SlopDeskWsLiveRowTitle;

// `has_duration == false` is a block still RUNNING, which is a different fact from one that
// finished instantly — the title rule skips both, but for different reasons.
typedef struct {
    SlopDeskWsSpan text;
    bool           has_duration;
    uint32_t       duration_ms;
} SlopDeskWsCommandTitleBlock;

size_t slopdesk_ws_row_title(SlopDeskWsRowTitle inputs, const uint8_t *strings,
                             size_t strings_len, uint8_t *out, size_t cap);
// `0` = no second line, which is a single-line row.
size_t slopdesk_ws_pane_subtitle(SlopDeskWsSubtitle inputs, const uint8_t *strings,
                                 size_t strings_len, uint8_t *out, size_t cap);
size_t slopdesk_ws_last_command_title(const SlopDeskWsCommandTitleBlock *blocks, size_t count,
                                      const uint8_t *strings, size_t strings_len,
                                      uint8_t *out, size_t cap);
size_t slopdesk_ws_live_row_title(SlopDeskWsLiveRowTitle inputs,
                                  const SlopDeskWsCommandTitleBlock *blocks, size_t count,
                                  const uint8_t *strings, size_t strings_len,
                                  uint8_t *out, size_t cap);

// ---- The one ranking every search field asks for ----
//
// A candidate's fields ride as spans into the strings blob, `stride` of them per candidate in
// PRIORITY order, so one searchable field and three are the same door with a different number. The
// first field that matches decides both the score and the tier, and a lower tier always wins: the
// row CALLED Read Only outranks the row that merely mentions locking, whatever they scored.

typedef struct {
    size_t candidate_count;
    size_t stride;              // fields per candidate; 0 answers nothing
    bool   positions_wanted;    // false skips every backtrace
    size_t positions_tier;      // the ONE field the caller underlines
} SlopDeskWsSearchRankInputs;

typedef struct {
    size_t  candidate;
    size_t  tier;
    int32_t score;
    size_t  position_offset;    // into the `positions` array
    size_t  position_count;     // 0 for a row nothing underlines
} SlopDeskWsSearchRanked;

// Returns how many rows matched. A `cap` or `positions_cap` too small leaves BOTH buffers untouched
// and still reports both sizes, so one retry with the two numbers is always enough.
size_t slopdesk_ws_search_rank(SlopDeskWsSearchRankInputs inputs, const SlopDeskWsSpan *fields,
                               const uint8_t *strings, size_t strings_len,
                               const uint8_t *query, size_t query_len,
                               SlopDeskWsSearchRanked *out, size_t cap,
                               uint32_t *positions, size_t positions_cap,
                               size_t *positions_needed);
// Asked for rather than transcribed: a drifted copy lets one surface build rows the one beside it
// capped away.
size_t slopdesk_ws_max_search_results(void);

// ---- When the app is allowed to SPEAK ----
//
// Both enums cross as their CASE INDEX. A byte neither map below names reads as the quiet case —
// the system's own foreground behaviour, no cue — so a disagreement costs a notification rather
// than producing one nobody asked for.

typedef struct {
    uint8_t kind;         // 0 explicit OSC · 1 command finish · 2 watch finish
                          // · 3 agent task complete · 4 agent await input
    int32_t exit;         // the code, when `kind` is a command finish
    bool    exit_present; // false reads as a clean exit, whatever `exit` holds
} SlopDeskWsNotifyEvent;

typedef struct {
    bool    app_notifications_enabled;
    bool    notify_on_finish;
    bool    notify_on_error;
    bool    notify_on_watch_finish;
    uint8_t foreground;   // 0 off · 1 always · 2 only while the source tab is unfocused
    bool    agent_notify_task_complete;
    bool    agent_notify_await_input;
} SlopDeskWsNotifySettings;

// A token bucket, crossing by value in both directions.
typedef struct {
    double capacity;
    double refill_per_second;
    double tokens;
    double last_refill;
} SlopDeskWsNotifyRateLimiter;

bool     slopdesk_ws_notify_should_deliver(SlopDeskWsNotifyEvent event, bool app_active,
                                           bool source_pane_visible,
                                           SlopDeskWsNotifySettings settings);
uint32_t slopdesk_ws_notify_long_threshold_ms(void);
bool     slopdesk_ws_notify_is_long_running(uint32_t duration_ms);
// 0 no badge · 1 success · 2 failure
uint8_t  slopdesk_ws_notify_badge(int32_t exit, bool exit_present, uint32_t duration_ms,
                                  bool pane_focused, uint32_t long_threshold_ms);
bool     slopdesk_ws_notify_should_notify_completion(uint32_t duration_ms, bool pane_focused,
                                                     bool enabled, uint32_t long_threshold_ms);
// 0 silence · 1 task complete · 2 awaiting input
uint8_t  slopdesk_ws_notify_agent_sound(bool needs_input, bool sound_task_complete,
                                        bool sound_await_input);
bool     slopdesk_ws_notify_should_ring_bell(bool sound_shell_controlled);
bool     slopdesk_ws_notify_should_beep_on_error(int32_t exit, bool exit_present,
                                                 bool sound_on_error);
// The banner's title and body, written back to back; `title_len` says where the split is, so a
// title that contains any byte a separator could use is still read back whole.
size_t   slopdesk_ws_notify_explicit_content(const uint8_t *pane_title, size_t pane_title_len,
                                             const uint8_t *explicit_title, size_t explicit_title_len,
                                             const uint8_t *body, size_t body_len,
                                             uint8_t *out, size_t cap, size_t *title_len);
// The phrase an in-app card leads with, resolved from WHO spoke and WHAT happened together — the
// same flavour is "is done" for an agent and "finished" for a command.
// speaker: 0 agent · 1 command      flavour: 0 notice · 1 success · 2 failure · 3 attention
// A command's notice and its attention are returned VERBATIM: those two already carry their own
// wording, and an unrecognised byte on either axis lands on that pair.
size_t   slopdesk_ws_notify_toast_headline(uint8_t speaker, uint8_t flavour,
                                           const uint8_t *subject, size_t subject_len,
                                           uint8_t *out, size_t cap);
// Spends a token if there is one, writing the refilled bucket back through `limiter`.
bool     slopdesk_ws_notify_rate_limit_allow(SlopDeskWsNotifyRateLimiter *limiter, double now);
// Where a bucket comes FROM. The spend door above hands the bucket back by value, so the caller
// owns the four doubles between calls — which left one thing on this side of the boundary that
// is not an assignment: what a NEW bucket holds. A bucket that rests FULL delivers the first
// explicit notification after an attach; one that rests empty swallows it while it fills, which
// is a rate limiter behaving like a defect. `now` starts its clock.
SlopDeskWsNotifyRateLimiter slopdesk_ws_notify_rate_limiter(double capacity,
                                                            double refill_per_second, double now);
// The bucket the explicit OSC 9/777 path ships with. Its burst and its refill rate are the
// crate's, not a caller's default argument: those two numbers ARE the anti-flood policy, and a
// second spelling of them is a second opinion about how much a hostile shell may post — of which
// the looser one is always the one that runs.
SlopDeskWsNotifyRateLimiter slopdesk_ws_notify_explicit_rate_limiter(double now);

// ---- What the window's CHROME shows around the panes ----
//
// Two of these have a rung that means NO OPINION, and each says so in the way its own answer allows:
// the sidebar's is -1 beside the booleans 0 and 1, the Dock's is a `present` flag beside its
// fraction. A refusal has to sit outside the range of every real answer, or it is read as one.
// Every enum here crosses as a case index, and an unrecognised byte reads as the quiet case.

typedef struct {
    bool collapsed;
    bool manual_override;    // the user's own ⌘⇧L or swipe put it where it is
    bool last_auto;          // read only when `last_auto_present`
    bool last_auto_present;  // false is the first application — which counts as a regime edge
} SlopDeskWsSidebarState;

typedef struct {
    bool   tinted;
    bool   animates;
    double fraction;         // read only when `fraction_present`
    bool   fraction_present; // false is the indeterminate spinner
} SlopDeskWsDockTile;

// `mode` is 0 never auto-hide · 1 always shown · 2 auto; anything else is quiet.
// The flags the chrome should hold afterwards. Actuation is gated on the 1↔>1 tab-count EDGE, so a
// manual collapse survives an unrelated tab opening within the same regime.
SlopDeskWsSidebarState slopdesk_ws_sidebar_apply_auto_hide(uint8_t mode, size_t tab_count,
                                                           SlopDeskWsSidebarState state);
// `policy` is 0 while a process runs · 1 always · 2 more than one tab.
bool slopdesk_ws_close_should_confirm(uint8_t policy, bool is_busy, size_t tab_count);
// `rollup` is the WIRE's own OSC 9;4 discriminant — 1 in progress · 2 error · 3 indeterminate;
// 0 (clear) and anything else is the absence of a rollup.
SlopDeskWsDockTile slopdesk_ws_dock_tile(uint8_t rollup, uint8_t percent, bool any_failure,
                                         bool animate_enabled, bool error_badge_enabled);

/* Who owns the TOP EDGE in borderless fullscreen — the dwell-gated Parallels model, recorded in
 * docs/DECISIONS.md 2026-07-22. In a fullscreen remote desktop the pointer at the very top must
 * reach the REMOTE menu bar first, but macOS's own auto-hide reveals the LOCAL one on a bare touch
 * and steals the click. So a passing touch stays remote; holding the edge for the dwell is the
 * deliberate "I want my Mac's menu bar" gesture.
 *
 * The gate crosses BY VALUE both ways: it is five numbers with no interior, and a fold that returns
 * the next gate cannot leave a stale one behind for a later pointer move to read. `pointer_y_from_
 * top` is DISTANCE FROM THE SCREEN'S TOP EDGE in points (0 = pressed against it), so the one
 * coordinate flip stays with the window layer that owns the screen; the clock is an argument, so
 * nothing behind the door reads one.
 *
 * Fold on every pointer move AND once at `slopdesk_ws_dwell_deadline` — a motionless pointer emits
 * no further moves, so the dwell can only complete on a timer re-feeding the last position.        */
#define SLOPDESK_WS_DWELL_HIDDEN   0u
#define SLOPDESK_WS_DWELL_ARMING   1u
#define SLOPDESK_WS_DWELL_REVEALED 2u

typedef struct {
    uint8_t phase;                // one of SLOPDESK_WS_DWELL_*
    double  since;                // when the running dwell started — read only while ARMING
    double  dwell_seconds;        // the hold this gate demands
    double  reveal_zone_points;   // the arming zone, from the top edge
    double  conceal_zone_points;  // the conceal zone — wider, so the revealed bar does not flicker
} SlopDeskWsDwellGate;

SlopDeskWsDwellGate slopdesk_ws_dwell_gate(void);
SlopDeskWsDwellGate slopdesk_ws_dwell_update(SlopDeskWsDwellGate gate, double pointer_y_from_top,
                                             double now);
// False means nothing is arming — no timer to schedule — and then `*out` is untouched.
bool slopdesk_ws_dwell_deadline(SlopDeskWsDwellGate gate, double *out);

// ---- What the sidebar SHOWS, in what order, under which labels ----
//
// Both list doors answer in the CALLER's indices: a rail row is an id, a kind, a badge, a selection
// flag and half a dozen strings, almost none of which decides where it goes, so the answer names
// rows and the near side reorders the array it already holds.

typedef struct {
    SlopDeskWsSpan title;
    SlopDeskWsSpan subtitle;
    // Never drawn, always searchable: a git-repo row shows its git line where its path would be, so
    // without the raw cwd it could not be found by path at all.
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan process_label;
} SlopDeskWsRailRowFields;

// `tab_rank` is where the row's tab sits in the display order; SIZE_MAX for a tab absent from it,
// which sorts last without dropping the row.
typedef struct {
    SlopDeskWsSpan project_key;
    size_t         tab_rank;
} SlopDeskWsRailPlanRow;

typedef struct {
    size_t row_index;
    size_t section;
} SlopDeskWsRailPlacement;

// A label that may collide with an identical one, and the path it was derived from — a row's title
// and its cwd, or a section's header and its project key. ONE rule breaks both.
typedef struct {
    SlopDeskWsSpan text;
    SlopDeskWsSpan source;
} SlopDeskWsRailLabel;

bool slopdesk_ws_rail_row_matches(SlopDeskWsRailRowFields fields, const uint8_t *strings,
                                  size_t strings_len, const uint8_t *query, size_t query_len);
// Returns how many placements there ARE, which is always `count`. A short `cap` writes nothing and
// returns the same number, so the retry is §4's.
size_t slopdesk_ws_rail_plan(const SlopDeskWsRailPlanRow *rows, size_t count,
                             const uint8_t *strings, size_t strings_len,
                             SlopDeskWsRailPlacement *out, size_t cap);
// What every item should be CALLED once identical labels have been told apart, for the WHOLE list
// in one delivery: `count` entries in list order, each a four-byte big-endian length then that many
// UTF-8 bytes. A zero length is "keep the label you have" — a qualified label is never empty, so
// the two never collide. A return larger than `cap` means nothing was written; ask again at that
// size.
//
// A collision is a fact about the LIST, so answering for one member needs the whole list in hand: a
// per-index face would take this same array and this same blob and throw the rest of the answer
// away, which is what the caller used to pay for, rebuilding the list on every index — `n` label
// arrays and `n` copies of every title's bytes to answer `n` questions that share one input.
size_t slopdesk_ws_rail_disambiguated_labels(const SlopDeskWsRailLabel *items, size_t count,
                                             const uint8_t *strings, size_t strings_len,
                                             uint8_t *out, size_t cap);
// ---- The rail's structural FINGERPRINT ----
//
// The sidebar memoizes its row model against a fingerprint of the workspace's structure, and the
// fingerprint is evaluated on EVERY render pass and every keystroke — hit or miss, because
// comparing it is what decides which. So its walk is the walk the memo pays for itself, and per
// pane it asked two questions that are each several rules deep: the By-Project key's
// transient-plugin guard, and whether the title chain would come off the pane's foreground process.
//
// The crossings were never the cost — a bare door is about a nanosecond. The MARSHALLING was:
// asking per pane meant a heap allocation per string per question, the cwd lent twice to two
// different doors and each answer copied out through a scratch buffer into a `String` nobody keeps.
// The list door lends every string once, out of one blob, and answers all of it in one buffer.

// The fields that pick a pane's title RUNG, with the project key ALREADY RESOLVED.
//
// Deliberately not `SlopDeskWsRailStructurePane` though the layout matches: that one carries the
// key the HOST pushed, before the precedence runs, and this one carries the key the pane was FILED
// under. A surface with no section headers passes none at all and gets the folder name, which is
// the same rule with nothing to subtract — and a struct that let the two be passed for each other
// would make an at-root pane out of every pane on that surface, with nothing but a comment to
// catch it.
typedef struct {
    uint8_t        kind;
    SlopDeskWsSpan spec_title;
    bool           user_renamed;
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan project_key;
} SlopDeskWsRailTitleShape;

// One pane as the fingerprint reads it. `host_project_key` is what the host pushed, BEFORE the
// precedence runs; `spec_title` absent is a pane with no spec at all, which is a different fact
// from a spec whose title is blank.
typedef struct {
    uint8_t        kind;
    SlopDeskWsSpan spec_title;
    bool           user_renamed;
    SlopDeskWsSpan cwd;
    SlopDeskWsSpan host_project_key;
} SlopDeskWsRailStructurePane;

// Whether this pane's structural title would come off its foreground PROCESS. The near side reads
// its volatile process dictionary only where this is true, so the answer decides an Observation
// dependency and not just a string. Kept for the three callers that genuinely want ONE answer —
// the window title and the two Open-Quickly pickers, which ask about the pane under the cursor.
bool slopdesk_ws_rail_titles_by_process(SlopDeskWsRailTitleShape shape, const uint8_t *strings,
                                        size_t strings_len);
// Both fingerprint answers for every pane, in one delivery: `count` entries in the caller's order,
// each a titles-by-process flag byte, a key-PRESENCE byte, a four-byte big-endian length and that
// many UTF-8 bytes. A return larger than `cap` means nothing was written; ask again at that size.
//
// The presence byte is §4b's rule and it is load-bearing here — a pane whose cwd is the empty
// string resolves to a project key that is present and blank, which buckets differently from a
// pane with no key at all, and a length alone could not say which.
size_t slopdesk_ws_rail_structure_keys(const SlopDeskWsRailStructurePane *panes, size_t count,
                                       const uint8_t *strings, size_t strings_len,
                                       uint8_t *out, size_t cap);

// The minimum flex weight a divider may take, from the crate that enforces it — `repaired()`
// clamps to this number, so a transcribed copy would describe a rule the client does not share.
double slopdesk_ws_min_weight(void);

// The deepest nesting a layout may KEEP. Its neighbour above was asked for through a door while
// this one was written down again on the Swift side as a bare 12, which docs/55 §8 names as the
// anti-pattern it is: two numbers with one meaning, the second right only until somebody tunes the
// first. Three rules clamp to it — the persisted split tree's decode, the template layout's repair,
// and the solver recursion both feed.
size_t slopdesk_ws_max_depth(void);

// The schema version the persisted workspace shape writes, and the one a load compares against.
// There is no migration behind that comparison, so two spellings of it agree right up until one is
// bumped alone — after which one side sets aside every file the other just wrote.
int64_t slopdesk_ws_schema_version(void);

// The longest a string field may be. `slopdesk_ws_encode_string` takes the bound as an argument,
// because a field's own limit is not always the protocol's — a renameTab name is clamped tighter
// than a title — so a caller with no tighter limit asks for the protocol's here.
size_t slopdesk_ws_max_string_bytes(void);

// ---- The project header's git DIALECT — `slopdesk_workspace::git_line` ----
//
// `main ↑2 ↓1 +3 !4 ?5 ~1 $2` is a language, not a label: the branch first, then only the NON-ZERO
// sigils in a fixed order, each with a role that decides its ink and its weight, and a shedding
// ladder for the widths a real sidebar column actually offers.
//
// No TEXT crosses. A run is a role, one glyph and a number, so the near side spells `↑` beside `2`
// where it is already laying out glyphs — but it never CHOOSES the glyph. A dead second Swift
// renderer once spelled a conflict `=` against this dialect's `~`, and both compiled for months.
//
// The branch is the one run with no sigil: it is a NAME, which is why it truncates rather than
// compacting, and why its text is the caller's own string. `detached` on that run says the far side
// had no branch to name.

// The most runs one line can have — the branch plus one per non-zero count.
#define SLOPDESK_GIT_MAX_RUNS 8
#define SLOPDESK_GIT_INK_BRANCH 0
#define SLOPDESK_GIT_INK_DIVERGENCE 1
#define SLOPDESK_GIT_INK_STAGED 2
#define SLOPDESK_GIT_INK_MODIFIED 3
#define SLOPDESK_GIT_INK_UNTRACKED 4
#define SLOPDESK_GIT_INK_CONFLICTED 5
#define SLOPDESK_GIT_INK_STASH 6
#define SLOPDESK_GIT_WEIGHT_REGULAR 0
#define SLOPDESK_GIT_WEIGHT_SEMIBOLD 1
#define SLOPDESK_GIT_WEIGHT_BOLD 2
// What `sigil` holds for the branch. Tested BEFORE any decode: NUL is a scalar like any other, so a
// `UnicodeScalar(0)` is a real character and would spell the branch as a blank.
#define SLOPDESK_GIT_NO_SIGIL 0

typedef struct {
    bool     has_repo;
    bool     detached;
    uint32_t ahead;
    uint32_t behind;
    uint32_t staged;
    uint32_t modified;
    uint32_t untracked;
    uint32_t conflicted;
    uint32_t stash;
} SlopDeskGitCounts;

typedef struct {
    uint8_t  ink;
    // Carried alongside the role so a caller laying out one run never asks twice about it.
    uint8_t  weight;
    uint32_t sigil;
    uint32_t count;
    bool     detached;
} SlopDeskGitRun;

// Both doors write at most `cap` runs and return how many the line HAS — §4's protocol at a size
// that never needs the retry, since `SLOPDESK_GIT_MAX_RUNS` bounds it structurally.
size_t slopdesk_git_line_runs(const SlopDeskGitCounts *counts, SlopDeskGitRun *out, size_t cap);
// The READOUT alone — the branch dropped — after giving up `level` rungs of the shed ladder. Folded
// from the same counts rather than from a run array handed back: the counts are three words the
// caller already holds, and a returned array would have to be validated field by field to be
// trusted.
size_t slopdesk_git_line_shed(const SlopDeskGitCounts *counts, size_t level, SlopDeskGitRun *out,
                              size_t cap);

// ---- Where the highlight goes — `slopdesk_workspace::list_nav` ----
//
// The rows never cross: each rule reads a COUNT and answers an INDEX into the list the caller
// already holds. Three overlays — the picker, the command navigator and the palette — each carried
// their own copy of the clamp, which is why it is one door.
//
// A LIST clamps and a RING wraps: arrowing past the last row leaves the highlight there, the way
// every macOS list behaves, while Tab through the filter pills comes back around because a ring has
// no ends to sit against.

// Moved by `delta`, clamped to [0, count - 1]. Any count <= 0 answers 0 — the index every one of
// those surfaces stores while it has nothing selected. The add saturates, so a page key over a
// two-row list, and an i64 extreme from a caller, both stay indices.
int64_t slopdesk_list_clamped_selection(int64_t current, int64_t delta, int64_t count);
// The 0-based row a ⌘1–9 chord names. -1 for ⌘0 (a filter chord, never a pick), for a chord above
// nine, and for a chord past the rows on screen.
int64_t slopdesk_list_quick_pick(int64_t one_based, size_t row_count);
// `delta` steps around a ring of `count`, wrapping at both ends. -1 for an empty ring, and for a
// starting index that is not in it — there is nothing to step from, and inventing a first entry
// would move a selection nobody asked to move.
int64_t slopdesk_list_wrapped_index(size_t index, int64_t delta, size_t count);

// ---- Which projection the app draws, and where a new pane starts ----
//
// `window_width` is read only when `window_width_present`: the outer window and the detail column
// are compared against DIFFERENT thresholds, so an absent window is not a window of the detail's
// width. Collapse the two and the macOS floor window resolves compact for one frame on every launch.
bool slopdesk_ws_is_compact(bool size_class_compact, double detail_width,
                            double window_width, bool window_width_present);
// 0 phone · 1 pad · 2 mac. A compact size class forces the phone tier even on a pad idiom.
uint8_t slopdesk_ws_video_device_class(bool is_mac, bool size_class_compact, bool idiom_pad);
// How many live video panes that class decodes at once. An unrecognised class is the phone floor.
size_t slopdesk_ws_video_cap(uint8_t device_class);

// The `working-directory` config: 0 inherit · 1 home · 2 a path, with the TRIMMED path written to
// `(out, cap)` and its length reported in `needed`. The kind is the return because two of the three
// answers name no path at all, which §4's `0` could not tell apart from a refusal.
uint8_t slopdesk_ws_workdir_parse(const uint8_t *raw, size_t len,
                                  uint8_t *out, size_t cap, size_t *needed);
// The parse door's inverse: the stored config string for kind 0 or 1, `0` for kind 2 — a path's
// config string is the path the caller already holds. The keywords live on one side only.
size_t slopdesk_ws_workdir_keyword(uint8_t kind, uint8_t *out, size_t cap);
// Which string the new pane's cwd comes from: 0 neither · 1 the configured path · 2 the active
// pane's cwd. `kind` is the parse door's answer; anything else reads as home, which names no
// directory. Nothing is copied back — every caller already holds both strings.
uint8_t slopdesk_ws_workdir_source(uint8_t kind, bool active_cwd_known);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_CHROME_H */
