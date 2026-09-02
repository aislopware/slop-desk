// slopdesk_ffi_text.h — the smallest readings: a pane's text, what a paste would do, and which agent is at the prompt
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_TEXT_H
#define SLOPDESK_FFI_TEXT_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The escape sequence that re-opens an alt-screen segment beheaded by a front truncation.
//
// `dropped` is the prefix a ring or journal cut away; `kept_head` is the start of what survived.
// Returns 0 when the cut did not land inside an alt-screen segment — the common case.
size_t slopdesk_altscreen_reopen(const uint8_t *dropped, size_t dropped_len,
                                 const uint8_t *kept_head, size_t kept_head_len,
                                 uint8_t *out, size_t cap);

// The Unicode private-use ranges, as [u32 low][u32 high] pairs, big-endian, inclusive.
//
// A TABLE where every other door here answers a QUESTION, and deliberately: the plaintext strip
// DROPS these codepoints while the chrome SPLICES the bundled Nerd face over exactly them, so it is one
// set used two ways. It was typed on both sides until 2026-08-26 and the copies disagreed about
// plane 16, which is where the material-design icons live. Classification is per-scalar on a title
// redrawn every keystroke, so the caller reads this ONCE into a static and asks it locally.
size_t slopdesk_private_use_ranges(uint8_t *out, size_t cap);
// The sync-input fan-out's mirror: client→host bytes with everything a KEYBOARD did not
// produce removed — replies, mouse reports, focus events. The other direction from the replay
// transform, which drops the QUERIES rather than the answers and runs inside hostd, not here.
size_t slopdesk_sync_input_keyboard_only(const uint8_t *bytes, size_t len, uint8_t *out,
                                        size_t cap);

// The STYLED reading — the clipboard's and the preview's, columns rewritten and colours kept.
// Answer: [u32 BE lines] ( [u32 BE runs] ( [u8 flags][u8 fg][3] [u8 bg][3] [u32 BE len][text] )* )*
// flags: bold 1, dim 2, italic 4, underline 8, inverse 16. A colour is [kind, a, b, c] with kind
// 0 absent, 1 palette (a = slot), 2 direct (a,b,c = r,g,b). An absent colour is the surface's own.
size_t slopdesk_styled_lines(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);

/* ---- paste protection: what a clipboard payload would do at a prompt ---------------------
 * The mask is multi-line 1, trailing newline 2, sudo/su 4, control characters 8. A mask of 0 is
 * an ANSWER — nothing dangerous — not the refusal `0` means for the (out, cap) entries above.  */
uint32_t slopdesk_paste_dangers(const uint8_t *text, size_t len);
bool slopdesk_paste_should_warn(const uint8_t *text, size_t len, bool protection_on,
                                bool bracketed_safe, bool program_advertised_bracketed,
                                bool is_alternate_screen);
// The confirmation's WHOLE text, in one crossing. `ask` is 0 unsafe paste, 1 OSC-52 read, 2 OSC-52
// write; an index no ask has answers 0, because a dialog is whole or it is nothing.
//
// Answer: [u32 BE bullets] then SLOPDESK_PASTE_CONFIRMATION_FIXED_RUNS runs — heading, affirmative,
// reason, preview, one-string body — then that many bullet runs.
//
// The bullets are the mask SAID OUT LOUD, in bit order; the reason is what the body prints INSTEAD
// when the mask is empty, so exactly one of the two is ever non-empty and a renderer draws whichever
// it was handed. The preview caps the payload and renders every control character in caret notation,
// so the escape being warned about cannot run inside the warning. The body is the AppKit join, for
// an NSAlert's informativeText; a renderer that lays the parts out reads the runs and ignores it.
#define SLOPDESK_PASTE_CONFIRMATION_FIXED_RUNS 5
size_t slopdesk_paste_confirmation(uint8_t ask, uint32_t mask, const uint8_t *text, size_t len,
                                   uint8_t *out, size_t cap);

/* ---- what a gesture at the terminal surface MEANS, before anything is sent ----------------
 * Every answer is a boolean, a case index or a count, so none of these takes the (out, cap)
 * shape and none can come up short. Two facts run through all of them: a mouse-reporting
 * program owns the pointer, and a full-screen program owns the screen — where either holds,
 * the local rule steps aside.                                                                */

// 0 write it now · 1 confirm first (`clipboard-write = ask`) · 2 nothing to write.
uint8_t slopdesk_term_clipboard_write(bool confirm_requested, const uint8_t *payload,
                                      size_t payload_len);
// 0 nothing selected · 1 copy only · 2 copy and delete.
uint8_t slopdesk_term_cut_action(bool has_selection, bool alternate_screen, bool prompt_zone);
// How many DEL bytes the delete half sends; 0 degrades the cut to a copy.
size_t slopdesk_term_cut_delete_count(const uint8_t *selection, size_t selection_len,
                                      bool selection_ends_at_cursor);
bool slopdesk_term_focus_follows_mouse(bool setting, bool already_focused);
// The byte an undo/redo gesture sends, or -1 for none. A one-byte answer is 0..=255, so the
// sentinel is outside the range by construction.
int32_t slopdesk_term_prompt_edit_byte(bool undo, bool redo, bool in_prompt_zone);
// What a bare right-click does: 0 forward · 1 paste · 2 copy · 3 menu · 4 ignore. `action` is the
// CONFIG TOKEN ("paste", "copy-or-paste", …), the spelling the config file carries, so there is no
// second vocabulary. An unrecognised token answers the menu, the token's own repair.
uint8_t slopdesk_term_right_click(const uint8_t *action, size_t action_len, bool has_selection,
                                  bool mouse_captured);

// ---------------------------------------------------------------------------
// Agent detection — rust/slopdesk-agent.
//
// The Swift side keeps AgentKind and ClaudeStatus as native enums, because a SwiftUI switch needs
// one and marshalling would buy nothing. They carry no rules. The discriminants below are therefore
// a CONTRACT between the two languages, pinned by `just lint-invariants`: a Swift enum that reorders
// its cases fails the gate rather than quietly reporting `working` for `blocked`.
//
// Those two are ALL that is left of the vocabulary. `AgentScreenState`, `AgentScreenDetection` and
// `ClaudeSignal` were the host's, not a view's, and went with the Swift host (docs/60 F.9) — the
// last two are barred from coming back by the same gate.
//
// Every string a signal carries lives in ONE buffer, addressed by (offset, len, present) triples.
// Six separate (ptr, len) pairs would mean six nested withUnsafeBytes per call on the Swift side;
// one buffer means one pointer, one lifetime, one scope. Out-of-range spans read as absent, because
// a hook body is untrusted input.
// ---------------------------------------------------------------------------

typedef struct {
  bool agent_while_processing;    /* the agent's thinking spinner */
  bool agent_when_complete;       /* an agent's finished turn */
  bool agent_when_awaiting_input; /* the hand when an agent is blocked on a human */
  bool command_when_finishes;     /* a plain command's clean exit */
  bool command_when_fails;        /* a plain command's non-zero exit */
} SlopDeskAgentBadgeGates;

// Pure — §4's convention, nothing remembered between calls.
int32_t slopdesk_agent_kind_identify(const uint8_t *bytes, size_t len);   // -1 = no agent
bool    slopdesk_agent_kind_is_generic(const uint8_t *bytes, size_t len);
size_t  slopdesk_agent_process_basename(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
size_t  slopdesk_agent_canonical_name(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
bool    slopdesk_agent_is_sensitive(const uint8_t *bytes, size_t len);
/* Every badge shown — the baseline a caller with no preferences to apply passes to the tab-badge
 * entry below. NOT the shipped global default: the thinking spinner ships off, which is a settings
 * resolution and stays one. */
SlopDeskAgentBadgeGates slopdesk_agent_badge_gates_default(void);
// The five gates are the user's badge toggles, true = shown, and each silences ONLY its own
// family's signal: an agent's spinner/finish/hand, or a plain command's clean/failed exit. A
// program's own busy bit and its OSC 9;4 progress have no opt-out and are never masked, so a
// silenced agent still lets the shell speak. All five true is the ungated ladder exactly.
int8_t  slopdesk_agent_tab_badge(uint8_t agent, int8_t completion, bool is_busy,
                                 const uint8_t *foreground, size_t foreground_len, bool fresh,
                                 int8_t progress, bool unseen_agent_done,
                                 bool agent_while_processing, bool agent_when_complete,
                                 bool agent_when_awaiting_input, bool command_when_finishes,
                                 bool command_when_fails);
bool    slopdesk_agent_badge_needs_attention(uint8_t badge);
bool    slopdesk_agent_badge_is_busy_tier(uint8_t badge);
// What a badge SAYS and which of the three attention roles it carries. The word is the row title's
// accessibility value and the roll-up's spoken label; three surfaces read it, and a word spelled
// twice is a state VoiceOver reads two ways on two devices. The roles are 1 awaiting, 2 failed,
// 3 finished, and 0 is reserved for "no role at all" — which is what BUSY answers, because a
// spinning agent is not waiting on anyone. `_urgent` is the subset loud enough to take a whole row
// title: a FINISH is deliberately absent, so the two alarming roles keep something louder to be.
// Any byte past the last discriminant names no badge: it says nothing and raises nothing.
#define SLOPDESK_AGENT_BADGE_NONE 0xFF
size_t  slopdesk_agent_badge_label(uint8_t badge, uint8_t *out, size_t cap);  // 1 run, 0 for none
uint8_t slopdesk_agent_badge_attention(uint8_t badge);
uint8_t slopdesk_agent_badge_urgent(uint8_t badge);
// The strongest role among a collapsed group's hidden rows — one byte per row, with
// SLOPDESK_AGENT_BADGE_NONE for a row wearing none. 0 when nothing inside waits, so folding a
// group never hides an agent that needs the eye.
uint8_t slopdesk_agent_badge_rollup(const uint8_t *badges, size_t len);
// Whether a badge is a COMMAND's outcome (1 succeeded, 2 failed) or neither (0). `badge` is -1 for
// an all-clear row. `agent_finish` decides the one fork the fused finish tiers force: the agent's
// turn ending is the mark column's check, a command's exit is the trailing slot's.
uint8_t slopdesk_agent_badge_command_outcome(int8_t badge, bool agent_finish);
uint8_t slopdesk_agent_status_rollup(const uint8_t *statuses, size_t len);
// What mints one FINISHED TURN (`pane/completionEpoch`): the hook-less finish above, plus
// ENTERING done, where a Stop hook announces the finish itself. The `Done -> Idle` decay that
// follows mints nothing, so one turn is counted once on a host with hooks and on one without.
bool    slopdesk_agent_finished_turn(uint8_t previous, uint8_t current);
// The POSITION of the oldest pane needing attention in the caller's own order, or -1 for none:
// blocked outranks finished wherever it sits, and within a bucket the earliest pane has waited
// longest. A position, not an identity — the caller holds the panes.
ptrdiff_t slopdesk_agent_attention_oldest(const uint8_t *statuses, size_t len);
// One press of the jump walk over a queue of `len` entries, `visited` flagging the ones already
// stepped onto: >= 0 advance to that position, -1 pop back to the origin, -2 nowhere to pop to.
ptrdiff_t slopdesk_agent_attention_walk(const bool *visited, size_t len, bool origin_is_live);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_TEXT_H */
