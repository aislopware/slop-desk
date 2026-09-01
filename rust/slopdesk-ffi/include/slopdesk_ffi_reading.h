// slopdesk_ffi_reading.h — the HEVC decoder, and what ten presentation families say and show
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_READING_H
#define SLOPDESK_FFI_READING_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- The HEVC decoder ---------------------------------------------------------------
//
// OUTSIDE the region above, and it is the only VideoToolbox door that is. The two halves
// of that framework have opposite audiences: only the host COMPRESSES, and every client
// DECOMPRESSES. So the encoder is macOS-only and this ships on every slice.
//
// THE SECOND DOOR THAT CALLS BACK, on the same third convention the encoder's block
// above describes — with ONE term inverted, and it is the term that matters:
//
//   * The callback is handed the CVImageBufferRef at +1. THE CALLEE OWNS IT and must
//     release it: Unmanaged<CVImageBuffer>.fromOpaque(_:).takeRetainedValue() IS that
//     release. The encoder's (avcc, len) is borrowed and must be copied; this is not.
//     The reason is the consumer — a display-link pacer holds the buffer until the next
//     vsync, which is always after the call returns, so a borrow would be a
//     use-after-free on the first frame and a copy would be a full NV12 memcpy per frame.
//   * It is registered once, at _new, and never changed.
//   * The context must outlive the handle. Free the handle first.
//   * UNLIKE the encoder's, it runs on the CALLING thread: the decode is synchronous, so
//     the callback has already run by the time _decode returns.
//
// Behind it: the session (slopdesk-apple-vt) and every decision that drives it
// (slopdesk_video::decoder_state) — when a keyframe is worth rebuilding for, what an
// empty frame means, and how the decode wall folds into the stats HUD's average.
//
// COPIES: exactly one, and it is not removable. Core Media owns a sample buffer's bytes,
// so the AVCC run is copied into a block the framework allocated; the alternative
// references the caller's bytes without retaining them, while the sample buffer outlives
// the call. Everything after it is zero-copy — the decoded surface reaches Metal as the
// IOSurface the decoder wrote.
typedef struct SlopDeskVideoDecoder SlopDeskVideoDecoder;

// One decoded frame. image_buffer is a CVImageBufferRef at +1 — see above.
typedef void (*SlopDeskDecodedFrameFn)(void *context, void *image_buffer);

// The four outcomes of a decode, each asking the caller for something DIFFERENT. A caller
// that collapsed any two would get a visible fault: dropping what should re-anchor freezes
// the pane, and re-anchoring what should be dropped costs a keyframe per corrupt fragment.
#define SLOPDESK_DECODE_DELIVERED 0      // pixels went to the callback
#define SLOPDESK_DECODE_DROPPED 1        // an empty delta; drop it and say nothing
#define SLOPDESK_DECODE_NEEDS_KEYFRAME 2 // ask the host, but do NOT invalidate
#define SLOPDESK_DECODE_FAILED 3         // invalidate, then ask; status_out has the OSStatus

// Creates a decoder. It has no session until the first keyframe gives it one — lazily by
// necessity, not by choice: the host streams parameter sets inline ahead of every IDR and
// none out of band, so there is nothing to build a session FROM before one arrives.
SlopDeskVideoDecoder *slopdesk_video_decoder_new(void *context, SlopDeskDecodedFrameFn deliver);

// Tears down. No drain, unlike the encoder's free: the decode is synchronous, so nothing
// is ever in flight when this is called.
void slopdesk_video_decoder_free(SlopDeskVideoDecoder *handle);

// Requests the FULL-RANGE NV12 output variant rather than the video-range one. Set from
// the stream's negotiated helloAck before any media arrives. The two have identical plane
// layouts, so what differs is the range — and therefore which shader coefficients the
// renderer must pair with it. Read at every configure, so a later change lands on the
// next session rather than never.
void slopdesk_video_decoder_set_full_range(SlopDeskVideoDecoder *handle, bool full_range);

// One reassembled AVCC frame. Answers one of the four SLOPDESK_DECODE_* codes above;
// status_out takes the framework's OSStatus on _FAILED and is untouched otherwise.
//
// Self-configuring: a keyframe carries its VPS/SPS/PPS inline, and one whose sets DIFFER
// from the running session's rebuilds before decoding. One whose sets MATCH does not —
// the heartbeat IDR arrives about once a second, and a teardown that often is a stall on
// an otherwise healthy stream.
int32_t slopdesk_video_decoder_decode(SlopDeskVideoDecoder *handle, const uint8_t *avcc,
                                      size_t len, bool keyframe, int32_t *status_out);

// Tears the live session down so the NEXT keyframe rebuilds, even a byte-identical one.
// Call it on _FAILED before asking the host for an anchor: on a fixed-capture-size stream
// the recovery IDR carries the SAME parameter sets, so without this the same malfunctioning
// session is reused forever and the pane freezes on the last good frame.
void slopdesk_video_decoder_invalidate(SlopDeskVideoDecoder *handle);

// The decode-wall average in milliseconds, 0 when nothing has decoded yet. The stats HUD's
// client-local decode axis, read at ~2 Hz from a different thread than the one decoding.
double slopdesk_video_decoder_millis_ewma(SlopDeskVideoDecoder *handle);

// ---- The code panel's DRESSING ----
//
// The embedded code-server workbench is a page the app does not own, and six jobs the host-side
// settings seed cannot do are done by injecting strings into it: the terminal's mono and the nerd
// font as @font-face rules (a WebContent process cannot see fonts registered with CTFontManager),
// the Slate softening, the slopcat letterpress, the recommendation-tips graft code-server's server
// never forwards, the clipboard bridge WebKit's async API drops, and the subframe canvas that
// otherwise resolves to WHITE. Every one of them is a pure string builder, so every one of them is
// `slopdesk-codepanel`'s; what stays in Swift is the WebKit seam that installs them.
//
// _text serves the TEN fixed texts under the codes below — ten symbols for one lookup would be ten
// header lines and ten wrappers — and answers 0 for a code this artifact does not know, which the
// Swift face reads as "not installed" rather than dressing a page with a fragment.
//
// _dressing_script is the one door that takes arguments: three `slopdesk-font:` URLs, each NULL for
// a face this bundle has no resource for (the sheet then omits it rather than naming a URL the
// scheme handler would 404). It composes the stylesheet AND its user script on this side, because
// handing several kilobytes of CSS out only to have them handed back to be wrapped would copy the
// whole sheet across the boundary twice.

#define SLOPDESK_CODE_PANEL_STYLE_ELEMENT_ID       0  /* the dressing style tag's DOM id */
#define SLOPDESK_CODE_PANEL_CLIPBOARD_HANDLER      1  /* the WKScriptMessageHandler name */
#define SLOPDESK_CODE_PANEL_CANVAS_ELEMENT_ID      2  /* the webview-canvas style tag's DOM id */
#define SLOPDESK_CODE_PANEL_CONFIGURATION_META_ID  3  /* the workbench boot-configuration meta tag */
#define SLOPDESK_CODE_PANEL_FOCUS_SYNC_NAME        4  /* the window hook the focus script publishes */
#define SLOPDESK_CODE_PANEL_FOCUS_SYNC_CALL        5  /* that hook as a call inert on an undressed page */
#define SLOPDESK_CODE_PANEL_FOCUS_TRUTH_SCRIPT     6  /* document START, main frame */
#define SLOPDESK_CODE_PANEL_CANVAS_SCRIPT          7  /* document START, ALL frames */
#define SLOPDESK_CODE_PANEL_CLIPBOARD_SCRIPT       8  /* document START, ALL frames */
#define SLOPDESK_CODE_PANEL_TIPS_SCRIPT            9  /* document START, main frame */
#define SLOPDESK_CODE_PANEL_NERD_FONT_FAMILY      10  /* gated against codeseed, never shared */
#define SLOPDESK_CODE_PANEL_MONO_FONT_FAMILY      11  /* gated against codeseed, never shared */

// ---- When a repo's git line is worth re-reading (SlopDeskRepoWatch) -----------------------------
//
// One handle per watcher, the convention at the top of this file: exactly one _free per _new, and NO
// TWO CALLS ON ONE HANDLE MAY OVERLAP. That last one is free rather than a burden here — every call
// is made from the watcher's own serial queue, which is what let the Swift original hold this state
// without a lock too.
//
// What crosses is a verdict per edge: which stream to start or cancel, which armed debounce is still
// the live one, whether a reading may start at all, and whether the reading that returned is news.
// FSEvents, the two dispatch queues, the clock the debounce is measured on and the filesystem walk
// all stay in Swift.
//
// THE THREE MUTATORS DO NOT TAKE (out, cap). §1's length protocol — ask small, grow, ask again — is
// sound only for a PURE answer, and these three CHANGE the fold. So each returns the size of its
// answer and holds it, and slopdesk_repo_watch_answer delivers it as often as asked; it is the
// packetizer's shape, for the same reason. A door that acted twice would cancel a stream it had
// already cancelled, or skip creating one it had already created.
typedef struct SlopDeskRepoWatch SlopDeskRepoWatch;

// The debounce armed at `generation` expired. `has_audience` is "is any client attached", read one
// step earlier than the reading it gates — a boolean the caller already holds, weighed against a
// filesystem walk it may not have to make at all:
#define SLOPDESK_REPO_WATCH_STALE                0  /* a newer edge won, the repo was released, or stopped */
#define SLOPDESK_REPO_WATCH_NO_AUDIENCE          1  /* nobody to tell — the reconnect pull catches up      */
#define SLOPDESK_REPO_WATCH_DEFERRED             2  /* one is in flight; ONE follow-up is now armed        */
#define SLOPDESK_REPO_WATCH_PROBE                3  /* read the status now                                 */

typedef struct {
    bool     push;          /* the dirty guard: an identical reading wakes nobody      */
    bool     has_rearm;     /* whether a follow-up debounce is owed                    */
    uint64_t rearm;         /* the generation that follow-up must carry back           */
} SlopDeskRepoWatchFinish;

size_t slopdesk_code_panel_text(uint8_t kind, uint8_t *out, size_t cap);

size_t slopdesk_code_panel_dressing_script(const uint8_t *nerd, size_t nerd_len,
                                           const uint8_t *mono_upright, size_t mono_upright_len,
                                           const uint8_t *mono_italic, size_t mono_italic_len,
                                           uint8_t *out, size_t cap);

// ---- The reading layer: what ten presentation families SAY and SHOW ------------
//
// Ten families that were Swift `enum`s and `static let`s until this batch, and are now one Rust
// rule each with a door in front of it. Every one of them follows docs/55 §6's two shapes:
//
//   · a CLASSIFIER crosses as a SCALAR — a bitmask in, a bitmask or a discriminant out;
//   · a family's WORDS cross as a GROUP — one delivery under §4's ask/size/ask-again, laid out as
//     an optional fixed header followed by N × `[u32 BE length][UTF-8 bytes]` runs.
//
// The group framing is big-endian because a target-width prefix is a bug waiting for a 32-bit
// build, and a reader PADS a short delivery with empties rather than trusting the length — a
// delivery that came up short means the two sides disagree about the layout, and the alternative is
// every run after the gap silently wearing its neighbour's words.
//
// Nothing here crosses as a colour or a loaded image. What crosses is a semantic KIND, and which
// entry of the palette or which glyph stands for it is the renderer's own business.

// ---- Pane status chips ----------------------------------------------------------
//
// `conditions` packs six gates low bit first: read-only, copy mode, hint mode, secure input, the
// secure-input setting, sync input. The answer is a bitmask over the chip's own index, low bit
// first, which IS the top-down stacking order.
#define SLOPDESK_WS_STATUS_PILL_READ_ONLY     0
#define SLOPDESK_WS_STATUS_PILL_SECURE_INPUT  1
#define SLOPDESK_WS_STATUS_PILL_SYNC_INPUT    2

uint8_t slopdesk_ws_status_pills(uint8_t conditions);
// The two chips outside that stack: bit 0 the vi/copy-mode pill, bit 1 the key-hint bar. One door
// rather than two, so a caller cannot ask one and forget the other.
uint8_t slopdesk_ws_status_pill_gates(uint8_t conditions, bool hints_toggled);
// The plate a chip stands on: 0 the chrome plate, 1 the fixed security tone, 2 the fixed sync tone.
// UINT8_MAX — outside every real answer — for an index no chip has.
uint8_t slopdesk_ws_status_pill_fill(uint8_t pill);
// `[u8 is_dismissible]` then 4 runs: label, accessibility label, accessibility hint, dismiss help.
size_t slopdesk_ws_status_pill_words(uint8_t pill, uint8_t *out, size_t cap);

// ---- The vi / copy-mode reference card ------------------------------------------
//
// One door per COLUMN, because a column is the unit the caller draws: twenty rows across three
// columns is sixty-eight strings, and a door per string is sixty-eight crossings inside a view body
// that re-runs whenever the card's width changes.
//
// A row's key chips ride as ONE run joined by U+001F rather than as a count and n runs. Nothing in
// these tables can contain a control character — they are single keys and two-character chords — so
// the separator cannot collide with the data, and a fixed two runs per row keeps the walk flat.
#define SLOPDESK_WS_VI_COLUMN_MOTION     0
#define SLOPDESK_WS_VI_COLUMN_SELECTION  1
#define SLOPDESK_WS_VI_COLUMN_SEARCH     2

// `[u16 BE rows]` then rows × 2 runs: the chips joined by U+001F, then the label.
size_t slopdesk_ws_vi_hint_column(uint8_t column, uint8_t *out, size_t cap);
// 6 runs: the range token, the exit help, the card's accessibility label, then the three headings.
size_t slopdesk_ws_vi_hint_words(uint8_t *out, size_t cap);

// The width ladder, as arithmetic: the renderer MEASURES (only it can ask its own type) and this
// side DECIDES. The three widths are each column at its intrinsic width, in drawn order.
#define SLOPDESK_WS_VI_LAYOUT_THREE_COLUMNS       0
#define SLOPDESK_WS_VI_LAYOUT_MOTION_BESIDE_STACK 1
#define SLOPDESK_WS_VI_LAYOUT_ONE_COLUMN          2

uint8_t slopdesk_ws_vi_hint_layout(double available, double gap, double motion, double selection,
                                   double search);
// `[u8 groups]` then groups × (`[u8 columns]` columns × `[u8 column]`). One group is one horizontal
// slot; the columns inside it stack. Bytes rather than runs, because every value is a small index.
size_t slopdesk_ws_vi_hint_groups(uint8_t layout, uint8_t *out, size_t cap);
// 2 runs: the mode pill's word, then the announcement built from it. Both, because a caller that
// asked separately could print a label the announcement does not match. `count` is read only when
// `has_count` is set — a repeat count of zero is a real count.
size_t slopdesk_ws_vi_mode_words(uint8_t mode, uint32_t count, bool has_count, uint8_t *out,
                                 size_t cap);

// ---- The side panel's tab strip --------------------------------------------------
//
// A MARK is a kind, not a glyph: code 0 is a symbol whose name is the first run, code 1 the Android
// silhouette the client draws itself and whose name run is therefore empty.
#define SLOPDESK_WS_PANEL_TAB_CODE        0
#define SLOPDESK_WS_PANEL_TAB_SIMULATORS  1
#define SLOPDESK_WS_PANEL_TAB_ANDROID     2
#define SLOPDESK_WS_PANEL_TAB_DESKTOP     3

// `[u8 mark]` then 4 runs: symbol name, label, help, accessibility hint. The accessibility LABEL is
// the label — a fifth run repeating it could drift from the first.
size_t slopdesk_ws_panel_tab(uint8_t index, uint8_t *out, size_t cap);

// `named` is the renderer's measurement of each tab WITH its name, in the order above; `cell` is a
// bare tab and `gap` what sits between two. Entries past the fourth are ignored.
#define SLOPDESK_WS_PANEL_TAB_LABELLING_ALL            0
#define SLOPDESK_WS_PANEL_TAB_LABELLING_SELECTED_ONLY  1
#define SLOPDESK_WS_PANEL_TAB_LABELLING_NONE           2

uint8_t slopdesk_ws_panel_tab_labelling(double available, double cell, double gap,
                                        const double *named, size_t count, uint8_t selected);
// Asked once per tab against a rung asked once per strip: the expensive question happens on layout,
// the cheap one where the answer is used.
bool slopdesk_ws_panel_tab_names(uint8_t rung, uint8_t surface, uint8_t selected);

// ---- What a pane drop would commit ------------------------------------------------
//
// Both doors answer a MARK and a SENTENCE in ONE delivery, and that is a correctness argument as
// well as a grouping one: the canvas destination's label is deliberately EMPTY (the in-canvas
// overlay is the affordance there), so a words-only door would answer §4's `0` for it and be
// indistinguishable from "no such destination". With the mark byte in front, `0` keeps one meaning.
#define SLOPDESK_WS_DROP_MARK_CANCEL      0
#define SLOPDESK_WS_DROP_MARK_SWAP        1
#define SLOPDESK_WS_DROP_MARK_SPLIT_H     2
#define SLOPDESK_WS_DROP_MARK_SPLIT_V     3
#define SLOPDESK_WS_DROP_MARK_BESIDE      4
#define SLOPDESK_WS_DROP_MARK_NEW_TAB     5
#define SLOPDESK_WS_DROP_MARK_NEW_WINDOW  6

// `kind`: 1 swap, 2 re-split, 3 dock, anything else the cancel. `edge` is read only by the two
// split kinds. `title` is the DRAGGED pane's. `[u8 mark]` then 1 run.
size_t slopdesk_ws_drop_zone(uint8_t kind, uint8_t edge, const uint8_t *title, size_t title_len,
                             bool has_title, uint8_t *out, size_t cap);
// `kind`: 0 canvas, 1 a sidebar row, 2 a new tab, 3 a tear-off, anything else the cancel. `title`
// is the pane the cursor is OVER — off the canvas the sentence is about where the pane is GOING.
// `detached` picks "merge beside" over "move beside". `[u8 mark]` then 1 run.
size_t slopdesk_ws_drop_destination(uint8_t kind, bool detached, const uint8_t *title,
                                    size_t title_len, bool has_title, uint8_t *out, size_t cap);

// ---- The in-pane find bar ----------------------------------------------------------

typedef struct {
    double plate;        // the control plate's side, in points
    double icon_size;    // the glyph inside it
    double field_width;  // the query field
} SlopDeskWsFindBarRung;

// 5 runs: placeholder, previous-match help, next-match help, search-all-tabs help, close help.
size_t slopdesk_ws_find_bar_words(uint8_t *out, size_t cap);
// 1 run, or §4's `0` when there is nothing to count. The query crosses too, because an empty query
// has no counter while a query with no matches has one that says so.
size_t slopdesk_ws_find_bar_counter(bool has_position, uint32_t position, uint32_t total,
                                    const uint8_t *query, size_t query_len, uint8_t *out,
                                    size_t cap);
// By value: three numbers with no interior, and a caller that asked one at a time could pair a
// touch plate with a pointer field.
SlopDeskWsFindBarRung slopdesk_ws_find_bar_rung(bool touch);

// ON outranks HOVER — a pill that is both must not read as merely hovered, because the hover tone
// is the weaker of the two and the state the user set is the one they need to see.
#define SLOPDESK_WS_FIND_TOGGLE_IDLE      0
#define SLOPDESK_WS_FIND_TOGGLE_HOVERING  1
#define SLOPDESK_WS_FIND_TOGGLE_ON        2

uint8_t slopdesk_ws_find_toggle_appearance(bool is_on, bool hovering);

// The five binding actions the bar sends its surface. The kind names the action; only the argument
// that kind reads is looked at — `needle` for SEARCH, `forward` for NAVIGATE, `row` for
// SCROLL_TO_ROW. A kind outside this table delivers NOTHING, so the caller sends nothing rather
// than a string libghostty would reject.
#define SLOPDESK_WS_FIND_ACTION_SEARCH         0
#define SLOPDESK_WS_FIND_ACTION_NAVIGATE       1
#define SLOPDESK_WS_FIND_ACTION_END            2
#define SLOPDESK_WS_FIND_ACTION_SCROLL_TO_ROW  3

// 1 BARE run of UTF-8 (no length prefix) — the whole binding-action string, needle included. The
// grammar is libghostty's own and lives nowhere else: a door answering `"search:"` for the caller
// to append to would put one protocol in two languages.
size_t slopdesk_ws_find_bar_wire(uint32_t kind, bool forward, uint32_t row, const uint8_t *needle,
                                 size_t needle_len, uint8_t *out, size_t cap);

// What arming the search does. The mode flags used to cross here beside a `_row_driven` companion
// that said whether the surface's matcher could express them; `slopdesk_term_surface_find` carries
// all four modes now, so the empty field is the whole decision.
#define SLOPDESK_WS_FIND_ARM_END     0
#define SLOPDESK_WS_FIND_ARM_SEARCH  1

uint8_t slopdesk_ws_find_bar_arming(bool query_empty);

// Which way vi's `n` / `N` steps: set `repeat_same_way` for `n`, clear it for `N`. vim's rule is
// "`n` repeats in its ORIGINAL direction", so a `?`-opened search inverts both.
bool slopdesk_ws_find_bar_nav_forward(bool repeat_same_way, bool search_backward);

// ---- The cross-tab search overlay ---------------------------------------------------

typedef struct {
    double width;
    double height;
} SlopDeskWsSearchPanelSize;

#define SLOPDESK_WS_FIND_MODE_CASE_SENSITIVE  0
#define SLOPDESK_WS_FIND_MODE_WHOLE_WORD      1
#define SLOPDESK_WS_FIND_MODE_REGEX           2

// `[u8 underlined]` then 2 runs: the pill's glyph text, then its tooltip.
size_t slopdesk_ws_find_mode_pill(uint8_t index, uint8_t *out, size_t cap);
// A bitmask over the SHARED index space, so one list of pills serves both surfaces: the overlay
// drops whole-word, the in-pane bar keeps all three.
uint8_t slopdesk_ws_find_mode_pills(bool global);
SlopDeskWsSearchPanelSize slopdesk_ws_global_search_panel_size(void);
// 3 runs: the query prompt, then the collapsed and expanded disclosure chevrons. Both states ride
// together — asking again mid-animation is a crossing per frame.
size_t slopdesk_ws_global_search_words(uint8_t *out, size_t cap);
// 1 run. A blank query and a query with no hits say different things, which is why the text crosses
// at all rather than the caller branching on emptiness itself.
size_t slopdesk_ws_global_search_empty_line(const uint8_t *query, size_t query_len, uint8_t *out,
                                            size_t cap);
// 1 run, or `0` when there is nothing to summarise. `counted` says the search FINISHED; a partial
// total is a number that goes DOWN as more arrives.
size_t slopdesk_ws_global_search_summary(bool counted, uint32_t total_matches, uint32_t tab_count,
                                         const uint8_t *query, size_t query_len, uint8_t *out,
                                         size_t cap);

// Where a UTF-16 hit range lands in the excerpt's own BYTES. The near side counts UTF-16 code units
// and Rust counts UTF-8 bytes, so returning three substrings would copy the excerpt twice and hand
// back a slice the caller did not cut. OFFSETS are one crossing and no copy.
//
// A range whose endpoint falls INSIDE a surrogate pair — one that would cut an emoji in half — is
// not a range: this answers false and writes NEITHER out-parameter, and the caller draws the flat
// excerpt, which is what a highlight that cannot be placed should degrade to.
bool slopdesk_ws_global_search_excerpt(const uint8_t *excerpt, size_t excerpt_len, size_t low,
                                       size_t high, size_t *out_low, size_t *out_high);

// ---- The command palette's card ------------------------------------------------------
//
// The width is deliberately NOT the window's: a palette that stretched with a full-screen workspace
// would put its keycap column a screen away from its titles.
typedef struct {
    double panel_width;
    double results_max_height;
} SlopDeskWsPaletteCard;

SlopDeskWsPaletteCard slopdesk_ws_palette_card(void);
// One ⇞/⇟ stride, derived from the SAME number that sizes the viewport — re-tuning the card
// re-tunes the page. A row height that is not a positive, finite measurement still answers a stride
// that MOVES, because a page key that does nothing reads as a dropped keystroke.
uint32_t slopdesk_ws_palette_page_stride(double row_height);

// ---- What a transient window-level cue SAYS ---------------------------------------------
//
// A notice reads `label · detail`, with a chord drawn between them as a KEYCAP rather than as text.
// ONE door for both answers, because the spoken form is built from the CUT detail: two doors would
// let the chip draw a clipped sentence while the screen reader spoke the whole one.
//
// Exactly SLOPDESK_WS_CHIP_NOTICE_SPANS spans, in the door's own order — label, keycap, detail. A
// wrong count answers 0: the three are positional, and printing the keycap where the label goes
// would be a sentence nobody wrote. The keycap is ABSENT rather than empty for a notice that offers
// nothing to press, which is what stops the separator being left hanging.
//
// Two runs back: the detail as the chip may draw it (cut to 48 grapheme CLUSTERS with the ellipsis
// taking one of those positions, so it is never LONGER than the cap), then the whole notice as one
// string for the reader that has no keycap.
#define SLOPDESK_WS_CHIP_NOTICE_SPANS 3
size_t slopdesk_ws_chip_notice(const unsigned char *blob, size_t blob_len,
                               const SlopDeskWsSpan *spans, size_t span_count,
                               unsigned char *out, size_t cap);

// ---- What just landed on the clipboard ---------------------------------------------------
//
// A copy is the highest-frequency INVISIBLE action in a terminal, so the receipt answers the one
// real doubt — "did I get the whole thing?" — with whichever number answers it: LINES for a
// multi-line grab (which may extend past the viewport), CHARACTERS for a single line (where
// truncation is the failure mode). Never "1 line".
//
// Answer: [u32 BE characters][u32 BE lines] then two runs — the count half ("1,204 characters") and
// the whole sentence ("Copied · 1,204 characters"). Characters are grapheme CLUSTERS, so a family
// emoji is one. A single trailing newline is NOT a second line: `"foo\n"` is one line, but `"a\n\n"`
// really does end with a blank one. The grouping is the app's own and never the machine's locale, so
// the label reads identically everywhere. Never 0 — an empty copy still has a receipt, because the
// chip is shown BECAUSE a copy happened and a silent one would read as a copy that failed.
#define SLOPDESK_COPY_RECEIPT_HEAD_BYTES 8
size_t slopdesk_copy_receipt(const unsigned char *text, size_t len,
                             unsigned char *out, size_t cap);

// ---- The prompt-jump landed flash ------------------------------------------------------
//
// Only the CELL walk crosses: turning an anchored `(row, cell_count)` into a rectangle needs the
// surface's own metrics, and the alt-screen gate is a decision about the pane's MODE and not about
// the grid. Both stay with whichever half is drawing.
//
// `[u32 anchor_count]` then that many `[u32 row][u32 cell_count]`, or 0 for an all-blank landing or
// a torn-down surface — absent, never wrong. The rule caps the walk at four rows, so the first lend
// is always big enough and the retry never fires here. `cell_count` is a GRAPHEME count: it
// under-measures a wide glyph's span, which stops the flash a few cells early on a CJK-heavy prompt
// rather than over-painting it.
//
// A span that cannot be read crosses as a BLANK row, never as a missing one — the walk is
// positional, and dropping a row would shift every anchor below it onto the wrong line.
size_t slopdesk_prompt_flash_anchors(const SlopDeskWsSpan *rows, size_t row_count,
                                     const uint8_t *blob, size_t blob_len, size_t cols,
                                     uint8_t *out, size_t cap);

// ---- The terminal's context menu ------------------------------------------------------
//
// The ORDER crosses separately from the WORDS. A menu is built twice for two reasons — once from a
// list of indices in display order, once per item for its title and glyph — and folding them would
// resend every word on every right-click.
#define SLOPDESK_TERM_MENU_CONTEXT_HAS_SELECTION       (1u << 0)
#define SLOPDESK_TERM_MENU_CONTEXT_CLIPBOARD_HAS_TEXT  (1u << 1)
#define SLOPDESK_TERM_MENU_CONTEXT_PANE_CONNECTED      (1u << 2)
#define SLOPDESK_TERM_MENU_CONTEXT_HAS_COMMAND_OUTPUT  (1u << 3)

// items × `[u8 index]`, in display order. `paste_as` asks for the submenu's four instead of ten.
size_t slopdesk_term_menu_items(bool paste_as, uint8_t *out, size_t cap);
// `[u8 separator_before]` then 2 runs: the title, then the symbol name. The separator belongs to the
// ITEM, not to its position — which is what stops a reordering from silently moving a rule.
size_t slopdesk_term_menu_item(uint8_t index, uint8_t *out, size_t cap);
bool slopdesk_term_menu_enabled(uint8_t index, uint8_t context);
// 1 run: the paste-as submenu's title.
size_t slopdesk_term_menu_words(uint8_t *out, size_t cap);

// The link verbs, keyed by the SLOPDESK_LINK_KIND_* constant the detector already answers with — so
// a caller that scanned a row hands the kind straight through without a second vocabulary.
#define SLOPDESK_TERM_LINK_ITEM_OPEN                  0
#define SLOPDESK_TERM_LINK_ITEM_COPY_PATH             1
#define SLOPDESK_TERM_LINK_ITEM_REVEAL_IN_FINDER      2
#define SLOPDESK_TERM_LINK_ITEM_CHANGE_DIRECTORY      3

// verbs × `[u8 index]`, in display order. A code no kind has offers nothing.
size_t slopdesk_term_link_items(uint32_t kind, uint8_t *out, size_t cap);
// 2 runs: the title, then the symbol name. The title depends on the KIND — "Open Link" against a
// URL is "Open File" against a path — which is why the kind crosses here too.
size_t slopdesk_term_link_item(uint8_t index, uint32_t kind, uint8_t *out, size_t cap);

// The BLOCK verbs — a right-click that landed IN one command block, which is Warp's shape. Kept apart
// from the standard items for the link verbs' reason and one more: SLOPDESK_TERM_MENU_ITEM's copy of
// the output acts on the LATEST block, because it is also the keyboard verb and a keystroke has no
// pointer. Both stay — the pane-global one is the chord, this section is the aim.
#define SLOPDESK_TERM_BLOCK_ITEM_COPY_COMMAND   0
#define SLOPDESK_TERM_BLOCK_ITEM_COPY_OUTPUT    1
#define SLOPDESK_TERM_BLOCK_ITEM_RE_RUN         2
#define SLOPDESK_TERM_BLOCK_ITEM_COLLAPSE       3
#define SLOPDESK_TERM_BLOCK_ITEM_BOOKMARK       4

// The seven gates, low bit first. READ_ONLY is the one that must not be dropped: Re-Run WRITES to the
// pty, so the per-pane lock reaches the affordance as well as the outbound seam.
#define SLOPDESK_TERM_BLOCK_CONTEXT_JOINED          (1u << 0)
#define SLOPDESK_TERM_BLOCK_CONTEXT_COMPLETE        (1u << 1)
#define SLOPDESK_TERM_BLOCK_CONTEXT_FOLDABLE        (1u << 2)
#define SLOPDESK_TERM_BLOCK_CONTEXT_COLLAPSED       (1u << 3)
#define SLOPDESK_TERM_BLOCK_CONTEXT_BOOKMARKED      (1u << 4)
#define SLOPDESK_TERM_BLOCK_CONTEXT_PANE_CONNECTED  (1u << 5)
#define SLOPDESK_TERM_BLOCK_CONTEXT_READ_ONLY       (1u << 6)

// verbs × `[u8 index]`, in display order. No context: which verbs EXIST never varies with the block,
// only which are live — a section that shrank would move the rows under the pointer between two
// right-clicks on neighbouring blocks.
size_t slopdesk_term_menu_block_items(uint8_t *out, size_t cap);
// `[u8 separator_before]` then 2 runs: the title, then the symbol name. The CONTEXT crosses because
// two of the five are toggles whose words read off the block's own state — "Collapse Block" against
// "Expand Block" — and it is the same byte _block_enabled takes.
size_t slopdesk_term_menu_block_item(uint8_t index, uint8_t context, uint8_t *out, size_t cap);
bool slopdesk_term_menu_block_enabled(uint8_t index, uint8_t context);

// ---- The three toast factories ----------------------------------------------------------
//
// All three answer ONE layout, so all three share one reader:
//
//     [u8 flavor][u8 source][u8 flags] then 4 runs: id, title, body, headline
//
// `flags` bit 0 is "the body is present", bit 1 "the headline is present". An absent line and an
// empty one are DIFFERENT — Some("") draws a blank second row and None draws none — and a length
// prefix alone cannot tell them apart.
//
// The remote's own text (an OSC title, a pane title) is masked on the RUST side when `redact` is
// set. A near side that masked first would be a second implementation of the one rule.
#define SLOPDESK_WS_TOAST_SOURCE_AGENT    0
#define SLOPDESK_WS_TOAST_SOURCE_COMMAND  1

#define SLOPDESK_WS_TOAST_FLAVOR_DEFAULT    0
#define SLOPDESK_WS_TOAST_FLAVOR_SUCCESS    1
#define SLOPDESK_WS_TOAST_FLAVOR_ERROR      2
#define SLOPDESK_WS_TOAST_FLAVOR_ATTENTION  3

#define SLOPDESK_WS_TOAST_FLAG_HAS_BODY      (1u << 0)
#define SLOPDESK_WS_TOAST_FLAG_HAS_HEADLINE  (1u << 1)

size_t slopdesk_ws_toast_explicit_osc(const uint8_t *pane_key, size_t pane_key_len,
                                      const uint8_t *title, size_t title_len,
                                      const uint8_t *body, size_t body_len, bool has_body,
                                      bool redact, uint8_t *out, size_t cap);
// `exit_code` is read only when `has_exit` is set; a command whose status never arrived prints "?"
// and counts as a clean exit — a red card about a result nobody has is a lie in the louder
// direction.
size_t slopdesk_ws_toast_long_command(const uint8_t *pane_key, size_t pane_key_len,
                                      const uint8_t *pane_title, size_t pane_title_len,
                                      int32_t exit_code, bool has_exit, uint32_t duration_ms,
                                      bool redact, uint8_t *out, size_t cap);

// `0` for an UNDETERMINED reconnect: the toast exists to say the session survived or did not, and a
// shrug is neither of those.
#define SLOPDESK_WS_RESUME_UNDETERMINED    0
#define SLOPDESK_WS_RESUME_FRESH_SHELL     1
#define SLOPDESK_WS_RESUME_RESUMED_SESSION 2

size_t slopdesk_ws_toast_session_resume(const uint8_t *pane_key, size_t pane_key_len,
                                        uint8_t outcome, uint8_t *out, size_t cap);

// The STACK the cards stand in: which of the standing ones survive one push, as positions in the
// stack the caller handed over. `standing` is one NUL-separated run of the ids, oldest first; an
// empty stack is a null pointer or a zero length, never a blob with one empty run. The answer is
// one byte per survivor, in order, and the pushed card is deliberately absent — it is always last.
size_t slopdesk_ws_toast_push(const uint8_t *standing, size_t standing_len,
                              const uint8_t *incoming, size_t incoming_len,
                              uint8_t *out, size_t cap);

// ---- The agent status readout ---------------------------------------------------------------
//
// The READING and the INK are separate doors on purpose: they answer different questions about the
// same status — what shape is drawn, and what tone it wears — and a caller can need one without the
// other. `status` is the SLOPDESK_AGENT_STATUS_* byte the detector already answers with.
#define SLOPDESK_AGENT_READING_NONE      0  /* draw nothing — no agent in this pane */
#define SLOPDESK_AGENT_READING_RESTING   1
#define SLOPDESK_AGENT_READING_WORKING   2
#define SLOPDESK_AGENT_READING_AWAITING  3
#define SLOPDESK_AGENT_READING_DONE      4

#define SLOPDESK_AGENT_INK_MUTED     0
#define SLOPDESK_AGENT_INK_THINKING  1
#define SLOPDESK_AGENT_INK_DONE      2
#define SLOPDESK_AGENT_INK_AWAITING  3

uint8_t slopdesk_agent_reading(uint8_t status);
// Every status has a tone, including the one that draws no glyph — a caller tinting a row's chrome
// asks this without asking whether a glyph is up.
uint8_t slopdesk_agent_ink(uint8_t status);
double  slopdesk_agent_glyph_box(void);
// 1 run. `scent` is APPENDED to the status label rather than replacing it, so a caption never says
// only what the agent is doing without saying what state it is in.
size_t slopdesk_agent_caption(uint8_t status, const uint8_t *scent, size_t scent_len,
                              bool has_scent, uint8_t *out, size_t cap);

// ---- The code panel's three surfaces ------------------------------------------------------
//
// The workbench and the two device surfaces answer the SAME layout, because they are the same
// four-state question asked about three subjects:
//
//     [u8 kind][u8 detail_is_command] then 3 runs: the waiting label OR the empty title,
//                                                  the system image, the detail
//
// A caller reads exactly as many as `kind` says it has; the runs that do not apply are EMPTY rather
// than absent, which keeps the reader a straight line.
#define SLOPDESK_CODE_SURFACE_GATE     0  /* workbench only — offer the gate, mount nothing */
#define SLOPDESK_CODE_SURFACE_CONTENT  1  /* mount the workbench, or show the device list */
#define SLOPDESK_CODE_SURFACE_WAITING  2  /* a spinner and the first run */
#define SLOPDESK_CODE_SURFACE_EMPTY    3  /* nothing to show, and why — all three runs */

// The four gates are separate arguments in the order the RULE asks them, and that order is the
// rule: the project gate first (a project the user never opened must cost nothing at all — no
// ensure poll, no proxy bind, no webview), then the root, then the brief wait while the host's
// project-key push is in flight, and only then the no-project placeholder. A caller that re-asks
// any of them elsewhere is asking one decision twice, which is how a panel boots an editor it was
// gated out of.
size_t slopdesk_code_workbench(uint8_t phase, bool has_root, bool root_is_opened,
                               bool ready_is_this_root, bool awaiting_project_key, uint8_t *out,
                               size_t cap);
// One door for both device surfaces: they differ in three strings and in nothing else, and a second
// door would be a second place for the shared fold to drift.
size_t slopdesk_code_device_surface(uint8_t phase, bool android, uint8_t *out, size_t cap);
// The announced-but-empty fourth surface. No phase — the TAB is real (selecting it parks the
// workbench and cancels the ensure poll) and only the content is a placeholder — so it always
// answers SLOPDESK_CODE_SURFACE_EMPTY, in the shared layout, so the near side has one reader.
size_t slopdesk_code_desktop_surface(uint8_t *out, size_t cap);
// 7 runs: the provision command, the gate's system image, the gate's title, the two device toast
// ids, and the two device fallback subjects.
size_t slopdesk_code_panel_words(uint8_t *out, size_t cap);

// The two ANIMATION keys, and the difference between them IS the rule. `phase_key` deliberately
// DROPS the ready payload — a service that respawns on a new port is the same surface and must not
// blink — while `ready_key` keeps it, because that is exactly when a mounted webview must be torn
// down. Both answer 1 run.
size_t slopdesk_code_phase_key(uint8_t phase, uint8_t *out, size_t cap);
size_t slopdesk_code_ready_key(uint8_t phase, const uint8_t *host, size_t host_len, uint16_t port,
                               uint8_t *out, size_t cap);
// 1 run: the project root's last component, or the whole path when it has none to take.
size_t slopdesk_code_gate_title(const uint8_t *root, size_t root_len, uint8_t *out, size_t cap);
double slopdesk_code_clipped_title_bar_height(void);

// ---- Peek & Reply, the words half -----------------------------------------------------------
//
// The three doors above answer TEXT as a BARE run each, because each is one string whose size the
// caller cannot predict. These are constants and a counter, always wanted together, so they take
// the group framing the other three do not.

// 3 runs: the card title, the empty-state line, the missing-question line.
size_t slopdesk_ws_peek_words(uint8_t *out, size_t cap);
// 1 run, or `0` when there is nothing to count.
size_t slopdesk_ws_peek_counter(bool has_position, uint32_t position, uint32_t total, uint8_t *out,
                                size_t cap);
double slopdesk_ws_peek_scroll_max_height(void);
// `[u8 is_placeholder]` then 1 run. The flag exists because an agent that happened to ask the
// placeholder's exact sentence must still be drawn as having ASKED it: the near side dims a
// placeholder, and dimming a real question would hide what the card is for.
size_t slopdesk_ws_peek_question(const uint8_t *question, size_t question_len, bool has_question,
                                 uint8_t *out, size_t cap);

// ---- Ten more reading faces -------------------------------------------------------------------
//
// The same two shapes as the ten above, over the last of the Swift `enum`-and-`static let` faces:
// the connect sheet, the close prompt, the Outline gutter, the hint overlay, the Command Navigator,
// the pane switcher, one sidebar row, the tab badge, the Open Quickly picker and the pane's eight
// stored control vocabularies.
//
// Two framings recur and are worth naming once. A door whose answer is a LIST leads its blob with
// `[u32 BE count]`, because an empty list is a real answer where a bare 0 return is §4's "ask
// again". A door whose inputs are a list of STRINGS takes them as `SlopDeskWsSpan`s over one arena,
// the way the rail planner already does — an absent span is Swift's nil, and a present empty one is
// an empty string, which is not the same question.

// ---- The connect sheet -----------------------------------------------------------------------
//
// The three PORT prompts are deliberately absent: they are `ConnectionTarget.default`'s own numbers
// rendered as text, and a door for them would be a second spelling of a default the near side holds.
size_t slopdesk_ws_connect_form_words(uint8_t *out, size_t cap);  // 8 runs
bool   slopdesk_ws_connect_form_closes_after(bool failed);

// ---- What a close prompt promises before it takes something away -----------------------------
//
// `scope` is 0 pane, anything else tab — a window closes like a tab as far as the wording goes, and
// a stale code over-warns rather than under-warns. `policy` is 0 a running process, 1 the ask-every-
// time preference, 2 a window holding several tabs; an unrecognised one reads as the process line,
// which names a consequence rather than asking a bare question.
//
// Both sentences ride in ONE delivery because an alert is raised with both or not at all, and two
// doors would give a caller a way to pair a headline about a pane with a body about a tab.
size_t slopdesk_ws_close_confirm_copy(uint8_t scope, bool policy_gated, uint8_t policy,
                                      SlopDeskWsSpan pane_title, SlopDeskWsSpan project_name,
                                      const uint8_t *blob, size_t blob_len, uint8_t *out,
                                      size_t cap);  // 2 runs: the headline, then the body

// ---- The Outline row's age line and its gutter -----------------------------------------------
//
// The CLOCK stays on the near side — a door that read one would answer differently for the same
// inputs, which is not a rule. The caller subtracts its own two dates; a negative difference is a
// clock that went backwards and floors at "just now" rather than printing a future.
size_t  slopdesk_ws_outline_relative_time(int64_t seconds_ago, uint8_t *out, size_t cap);  // 1 run
// 0 running, 1 succeeded, 2 failed. A status that did not survive the crossing reads as the neutral
// running dot: claiming an outcome for a block that never reported one is the one wrong answer.
uint8_t slopdesk_ws_outline_gutter(uint8_t status);

// ---- The hint overlay ------------------------------------------------------------------------
//
// The ASSIGNMENT is `slopdesk_ws_hint_*` above; this is only what the badges then SAY and how they
// are drawn.
size_t slopdesk_ws_hint_overlay_words(uint8_t *out, size_t cap);  // 3 runs
bool   slopdesk_ws_hint_overlay_is_armed(bool armed, double cell_width, double cell_height);
bool   slopdesk_ws_hint_overlay_is_faded(size_t offset, const uint8_t *typed, size_t typed_len);
// Whether the typed prefix ruled this label out. Ruled-out badges are DIMMED rather than removed:
// a label that vanished would let the eye think a target had gone away.
bool   slopdesk_ws_hint_overlay_dimmed(const uint8_t *label, size_t label_len,
                                       const SlopDeskWsSpan *matched, size_t matched_count,
                                       const uint8_t *blob, size_t blob_len);
// 3 runs: the label as drawn, what VoiceOver calls the badge, what it calls the mode badge.
size_t slopdesk_ws_hint_overlay_badge(const uint8_t *label, size_t label_len, const uint8_t *intent,
                                      size_t intent_len, uint8_t *out, size_t cap);

// ---- The Command Navigator card --------------------------------------------------------------
//
// `filter` is 0 all, 1 failed, 2 bookmarked; an unrecognised one reads as the widest, because a
// zero state naming the wrong segment is worse than one naming the whole pane. The frame takes the
// search overlay's own record: it is the same two numbers about the same kind of thing.
SlopDeskWsSearchPanelSize slopdesk_ws_command_navigator_metrics(void);
size_t slopdesk_ws_command_navigator_words(uint8_t *out, size_t cap);  // 11 runs
// 1 run, and `has_blocks` is the whole fork: a query that matched nothing blames the QUERY, an
// empty segment names the segment.
size_t slopdesk_ws_command_navigator_empty_line(uint8_t filter, bool has_blocks, uint8_t *out,
                                                size_t cap);

// ---- A pane's supervision facts ----------------------------------------------------------------
//
// `slopdesk_agent_attention_*` above answers the three EDGE questions one at a time. This is what
// the store actually asks: given all three plus the coalescing memory, WHICH of the pane's facts
// move. The verdict is applied verbatim on the near side — six writes, no branch of its own.
//
// No pane identity crosses. The commit takes three statuses; the queue order takes badges and
// instants and answers POSITIONS in the list it was handed.
typedef struct {
    bool changed;             // false => ignore every field below
    bool notify_edge;         // latch the new status as last-notified, and park a notification
    bool rearm_notified;      // forget last-notified: the pane left the attention bucket
    bool schedule_completion; // park a notification for a HOOK-LESS finish
    bool stamp_completed;     // stamp the finish, arm the flash decay, bump this client's counter
    bool mark_seen;           // the agent moved on: the previous turn's marker is stale news
    bool stamp_working;       // anchor the turn clock; false RETIRES it
} SlopDeskWsPaneStatusCommit;
// `last_notified` is the coalescing MEMORY, not the previous status: `done -> working -> done`
// re-enters a state already announced and stays quiet. `quiet` is the host's bookkeeping
// qualification (today only `/compact`) — it vetoes rings and nothing else, not even the re-arm.
SlopDeskWsPaneStatusCommit slopdesk_ws_pane_status_commit(uint8_t previous, uint8_t last_notified,
                                                          uint8_t next, bool quiet);
// What a pane's unread-finish marker becomes: 0 clear, 1 clear AND record it seen, 2 mark unread.
// `has_seen` separates "never recorded" from "recorded zero" — the first can never match a live
// counter, the second is every pane's state before the document arrives.
uint8_t slopdesk_ws_pane_unseen_done(uint32_t epoch, bool has_seen, uint32_t seen, bool is_visible);
// What a read of the mirror's document identity does to this device's seen-map: 0 nothing, 1 file the
// map under it, 2 EMPTY the map first and then file it. `identity` is 0 unanswered (no document, or
// the store's own seed) · 1 the document the map is already filed under · 2 a real host document that
// is not. The UUIDs behind that reading never cross — the caller owns them, and this asks only
// whether the answer is real and whether it is the same one.
uint8_t slopdesk_ws_pane_seen_document(uint8_t identity, bool has_stored);
// One pane in the unseen-attention queue. `since` is a flag plus a value because the absent case is
// REAL — a manual badge override carries no age evidence — and a sentinel would sort as itself.
typedef struct {
    uint8_t badge;
    bool    has_since;
    double  since;
} SlopDeskWsWaitingPane;
// The order the queue is walked in, as POSITIONS into `entries`: rank first (a waiting question,
// then a failure, then an unread finish), then longest-waiting, then the caller's own traversal as
// the tie. A dated entry outranks an undated one at the same rank. Returns the count NEEDED; a
// short or null `out` is written nothing and told the length.
size_t slopdesk_ws_attention_order(const SlopDeskWsWaitingPane *entries, size_t len, uint32_t *out,
                                   size_t capacity);

// ---- The watch on the pane under the user's eyes -----------------------------------------------
//
// `slopdesk_ws_pane_*` above answers what one status LANDING moves. This is the other half of the
// same cockpit: the fold that runs over every pane a dwell clock is (or should be) ticking on, the
// candidacy test it is written against, and the two one-line policies that stood beside it.
//
// No pane identity crosses. The fold takes the UNION of "a clock runs here" and "a clock may run
// here" as ROWS, in whatever order the caller built them, and answers one verdict per row in that
// same order. Two separate loops were how a pane fell out of one and stayed in the other.
typedef struct {
    bool   watching;  // a dwell clock is already running on this pane
    bool   candidate; // the pane is one a watch may run on right now
    double watched;   // how long that clock has run; read only when `watching`
} SlopDeskWsSettleWatch;
// One verdict byte per row: 0 hold, 1 start a clock, 2 drop one, 3 the window elapsed under an
// unbroken watch — acknowledge the pane. `arms` is written whatever the buffer does: it is the
// fold's second conclusion (did ANY row start a clock, so must the one-shot be armed), and a caller
// re-deriving it by scanning the bytes would be the third place the rule lived. Returns the count
// NEEDED; a short or null `out` is written nothing and told the length.
size_t slopdesk_ws_settle_step(const SlopDeskWsSettleWatch *rows, size_t len, double window,
                               uint8_t *out, size_t capacity, bool *arms);
// Whether a watch may run on a pane at all: focused in an ACTIVE app — a key satellite counts as
// focused, but only while the app itself is frontmost — and carrying a finished-turn marker. A live
// `working`/`needsPermission` is never unread OUTPUT, so the settle can never silence a gate.
bool slopdesk_ws_settle_candidate(bool app_active, bool focused, bool finished, bool unseen_finish);
// Whether a walk in progress must be abandoned: one is running, and the focus it last set moved
// under it. `walking` is false before the first step, when there is nothing to compare against.
bool slopdesk_ws_walk_interrupted(bool walking, bool focus_held);
// Whether an explicit acknowledge may settle this status to idle. Only a finished turn — a live
// state, and above all an approval gate, is deliberately left alone.
bool slopdesk_ws_badge_clear_settles(uint8_t status);
// Text with nothing in it, as the ABSENCE of a value — the store's one normalization for every
// host-pushed label. 0 is the answer the caller REMOVES its key on, so the row falls back down its
// own chain instead of titling itself with a blank. The answer is never longer than the input, so a
// buffer of that size is the arithmetic bound and the retry path is never travelled.
size_t slopdesk_ws_normalized_text(const uint8_t *text, size_t len, uint8_t *out, size_t capacity);

// ---- The replica of the document itself ---------------------------------------------------------
//
// One client's whole copy: host truth (`entries`), the control-push overlay (`fastPath`) it is read
// under, and the optimistic patches ahead of both. Reads funnel through the same precedence —
// pending, then host truth, then the overlay — so the order lives in exactly one place.
//
// A cell holding a ZERO-LENGTH value is RETIRED, which this wire gives a meaning distinct from
// missing all the way to the UI. So the byte doors need a third answer beyond §4's retry, and
// SLOPDESK_WS_MIRROR_ABSENT is it: 0 means "held, and empty", not "not there".
//
// The presence ROSTER did NOT come with it. It is never diffed, never versioned, and its lifetime
// is the connection rather than the document, so the near side decodes it and holds it beside this
// handle. The two frame kinds that carry it and an intent's verdict are routed on the near side
// too; a kind this door does not fold answers DROPPED, which is the forward-tolerance rule stated
// once rather than in two languages.
typedef struct SlopDeskWorkspaceMirror SlopDeskWorkspaceMirror;
#define SLOPDESK_WS_MIRROR_APPLIED            0
#define SLOPDESK_WS_MIRROR_IGNORED            1
#define SLOPDESK_WS_MIRROR_NEEDS_RESUBSCRIBE  2
#define SLOPDESK_WS_MIRROR_DROPPED            3
#define SLOPDESK_WS_MIRROR_RESET              4
#define SLOPDESK_WS_MIRROR_ABSENT             SIZE_MAX
// A replica that has never been spoken to; NULL if the allocation fails.
SlopDeskWorkspaceMirror *slopdesk_ws_mirror_new(void);
// Frees one. NULL is a no-op; the same pointer must not be freed twice.
void slopdesk_ws_mirror_free(SlopDeskWorkspaceMirror *handle);
// Folds one type-37 DOCUMENT frame — snapshot, diff or reset. `state_num` receives the state to ACK
// on APPLIED and 0 on every other verdict, which is the "I know nothing" sentinel and never a state
// anything acks. `epoch` is sixteen bytes.
uint8_t slopdesk_ws_mirror_apply(SlopDeskWorkspaceMirror *handle, uint8_t kind,
                                 const uint8_t *epoch, int64_t base_state_num,
                                 int64_t new_state_num, const uint8_t *payload, size_t payload_len,
                                 int64_t *state_num);
// Forgets everything, host truth included — what the workspace channel does when it STOPS. Distinct
// from a reset frame, which keeps the overlay because the pane channels are still painting it.
void slopdesk_ws_mirror_forget(SlopDeskWorkspaceMirror *handle);
// Records a value pushed on a pane's own control channel, answering whether the overlay MOVED — so
// the caller repaints only when it did. `key` is 18 bytes: [kind][16B objectID][field]. `has_value`
// false RETIRES the entry, which stays distinct from a push of zero bytes. Ignored where host truth
// already holds the key: the document is authoritative, and a push that raced a diff must not win.
bool slopdesk_ws_mirror_write_fast_path(SlopDeskWorkspaceMirror *handle, const uint8_t *key,
                                        const uint8_t *value, size_t value_len, bool has_value);
// Whether the OVERLAY holds one cell — NOT the full chain. The caller re-evaluating a verdict it
// computed itself must only do so where it has something to re-evaluate; asking the chain instead
// would read host truth and put this client's guess beside the host's own.
bool slopdesk_ws_mirror_fast_path_holds(SlopDeskWorkspaceMirror *handle, const uint8_t *key);
// Drops every overlay entry for one pane — what a client does when that pane's channel closes.
void slopdesk_ws_mirror_clear_fast_path(SlopDeskWorkspaceMirror *handle, const uint8_t *pane);
// Stages one intent's optimistic effect, answering whether anything was staged. false means do NOT
// send it: this client can already see the host will refuse — a round trip and a rollback for
// nothing. An intent that changes no cell still stages and still goes out; taking ownership of a
// pristine document is an effect no cell on this side carries. The patch is the two TOPOLOGY
// projections diffed, never
// the resolved documents: sweeping liveness or overlay cells in would have host truth erase entries
// the patch then re-asserts. `minted` is the identity pool; a client PROPOSES object ids.
bool slopdesk_ws_mirror_stage_intent(SlopDeskWorkspaceMirror *handle, const uint8_t *intent_id,
                                     uint8_t op, const uint8_t *args, size_t args_len,
                                     const uint8_t *minted, size_t minted_count,
                                     double issued_at);
// Folds the host's verdict on one intent, answering whether a patch was found and moved. A refusal
// snaps the layout back NOW — the anti-flicker rule the useful way round, since it is the one case
// where waiting shows the user something the host has already denied. An acceptance only ARMS the
// patch: it retires at the next document frame, which provably already carries its effect.
bool slopdesk_ws_mirror_note_intent_result(SlopDeskWorkspaceMirror *handle,
                                           const uint8_t *intent_id, bool applied);
// Drops patches the host never answered, answering whether anything went. The caller owns the clock
// — the replica only compares.
bool slopdesk_ws_mirror_expire_pending(SlopDeskWorkspaceMirror *handle, double now, double timeout);
// How long an unanswered patch may stand, in seconds. Asked for so the near side never spells it.
double slopdesk_ws_mirror_pending_timeout(void);
// Drops ONE staged patch outright — a send that never left the machine needs no grace period.
bool slopdesk_ws_mirror_drop_pending(SlopDeskWorkspaceMirror *handle, const uint8_t *intent_id);
// How many optimistic patches are standing, and whether one particular intent's is.
size_t slopdesk_ws_mirror_pending_count(SlopDeskWorkspaceMirror *handle);
bool slopdesk_ws_mirror_is_pending(SlopDeskWorkspaceMirror *handle, const uint8_t *intent_id);
// One cell's bytes, through the full precedence chain. SLOPDESK_WS_MIRROR_ABSENT for a cell no
// layer holds; 0 for one holding a retired value; otherwise §4's retry count.
size_t slopdesk_ws_mirror_value(SlopDeskWorkspaceMirror *handle, const uint8_t *key, uint8_t *out,
                                size_t capacity);
// The whole replica as an encoded SNAPSHOT — host truth with the overlay and this client's
// unanswered intents already on it. The wire's own encoding rather than a marshalled cell array:
// it already exists, it is golden-pinned, and the caller already holds its decoder.
size_t slopdesk_ws_mirror_resolved(SlopDeskWorkspaceMirror *handle, uint8_t *out, size_t capacity);
// HOST TRUTH alone, as an encoded snapshot — no overlay, no pending. The one caller is the
// in-process document, which ADOPTS what a store seeded and must not adopt this client's own
// guesses along with it: the fast path is a lane a real host's document never holds.
size_t slopdesk_ws_mirror_host_truth(SlopDeskWorkspaceMirror *handle, uint8_t *out, size_t capacity);
// The version of host truth as HELD, whatever the epoch says — which is not what subscribe declares.
int64_t slopdesk_ws_mirror_state_num(SlopDeskWorkspaceMirror *handle);
// Every pane the DOCUMENT knows about, sixteen bytes each, in canonical order. Membership is the
// liveness field: a pane with only overlay values is not a document pane and must not be
// enumerated as one.
size_t slopdesk_ws_mirror_pane_ids(SlopDeskWorkspaceMirror *handle, uint8_t *out, size_t capacity);
// Every pane with an OVERLAY entry, which is the other question.
size_t slopdesk_ws_mirror_fast_path_pane_ids(SlopDeskWorkspaceMirror *handle, uint8_t *out,
                                             size_t capacity);
// The document identity actually HELD, false when none is — which the subscribe pair cannot say,
// since it reports a fresh identity for "snapshot me". `out` takes sixteen bytes.
bool slopdesk_ws_mirror_epoch(SlopDeskWorkspaceMirror *handle, uint8_t *out);
// What `subscribe` declares as the state it holds. All-or-nothing with the epoch: a state number
// with no document behind it reads as "I know nothing", which is what makes a snapshot the answer.
int64_t slopdesk_ws_mirror_known_state_num(SlopDeskWorkspaceMirror *handle);
// How many document frames have been folded. Back to zero after a forget, so a caller can tell a
// fold from every other reason its observers fire.
uint64_t slopdesk_ws_mirror_frames_applied(SlopDeskWorkspaceMirror *handle);

// ---- The replica of the document, and what the near side still asks about it -------------------
//
// The replica ITSELF is `slopdesk_wire::document::mirror` now: host truth, the control-push overlay
// it is read under, and the optimistic patches for intents the host has not answered — one handle,
// below. What stays here is the handful of folds the near side asks OUTSIDE it: the roster joins
// (the roster is not a layer of the replica), the running-command chain, the grid predicate, the
// reconcile admission and the spec-intent choice.
//
// No identity crosses in either direction. The two roster joins see clients as dense tokens the
// caller minted and answer POSITIONS into the array it still holds, so the join decides WHICH label
// and the caller reads it. A label's text never crosses.
// Which candidate names the command a pane is RUNNING, and its text. `source` is written whatever
// the buffer does: 0 nothing, 1 the host's own open block, 2 this client's newest one, 3 the
// caller's process label. 3 and 0 write no text — the process label is the caller's own string,
// already cleaned up on the near side. Neither trimmed answer can outgrow its own input.
size_t slopdesk_ws_mirror_running_command(const uint8_t *hosted, size_t hosted_len,
                                          const uint8_t *open, size_t open_len,
                                          bool has_process_label, uint8_t *source, uint8_t *out,
                                          size_t capacity);
// Whether the host has actually RESOLVED a grid. Both axes, or neither: a zero on either is the
// roster's "not published yet", and letterboxing against it places a pane behind a fiction.
bool slopdesk_ws_mirror_grid_published(uint32_t cols, uint32_t rows);
// Whether a document change may reconcile the registry against the layout it produced. Four
// refusals, each a race with a layout about to be replaced: a pass already in flight owns the diff;
// the ABSENCE of a projection is not an empty one; an armed bootstrap is a layout this client has
// not had a channel to publish yet; and an outstanding launch adopt is the same race on the
// ordinary path — unless the replica holds this client's own SEED, which IS the tree on offer.
bool slopdesk_ws_mirror_reconcile_admitted(bool reconciling, bool projected, bool bootstrap_armed,
                                           bool adopt_pending, bool epoch_is_seed);
// Which intent a spec edit becomes: 0 none (named in the debug log, never dropped silently), 1 the
// video binding, 2 an authored rename. The binding is checked first and exclusively — a re-point
// that also moved the DERIVED title is one gesture, and sending that as a rename would set the
// authorship flag and make the next re-pick unable to update it.
uint8_t slopdesk_ws_mirror_spec_intent(bool video_moved, bool user_renamed, bool title_moved,
                                       bool was_user_renamed);
// One roster client, as both presence joins see it.
typedef struct {
    uint32_t token;    // the dense token the caller minted for this client's instance id
    bool     labelled; // the client published a label anybody can read
    bool     viewing;  // the client is looking at the pane being asked about
} SlopDeskWsPresenceClient;
// The other clients currently LOOKING at a pane, as POSITIONS into `clients`. An unlabelled viewer
// is dropped — there is nothing to print — which is exactly where this differs from the holders.
size_t slopdesk_ws_mirror_viewers(const SlopDeskWsPresenceClient *clients, size_t len, bool has_own,
                                  uint32_t own, uint32_t *out, size_t capacity);
// The other clients HOLDING a channel on a pane: one answer per surviving attachment, in
// `attachments` order. Each is a POSITION into `clients`, or -1 for an attachment no roster client
// names — a real client holding a real pane that nothing can label, REPORTED rather than dropped,
// or the pane would read as unheld and the resolved grid's arithmetic would be unexplainable.
size_t slopdesk_ws_mirror_holders(const uint32_t *attachments, size_t attachments_len,
                                  const SlopDeskWsPresenceClient *clients, size_t clients_len,
                                  bool has_own, uint32_t own, ptrdiff_t *out, size_t capacity);

/* ---- grid readout: what a pane says about a grid it did not choose (docs/45 §8.3 rule 7) ----
 *
 * The roster's THIRD join, and the only one that ends in a sentence. The join itself crosses the
 * way the two above do — tokens in, a POSITION out, no UUID and no roster of labels — and the
 * printing is a second door that takes exactly ONE label, the one the join already picked. Folding
 * them together would mean crossing every client's label to print one of them.
 */
// One attachment's standing offer, as the join sees it. The size is what the client ASKED for, not
// what the host resolved: only a CONTRIBUTING offer can be the reason the grid came out where it did.
typedef struct {
    uint32_t token;       // the dense token the caller minted for this attachment's client
    uint32_t cols;        // the columns this attachment stands for
    uint32_t rows;        // the rows this attachment stands for
    bool     contributes; // the attachment votes in the pane's `min` fold at all
} SlopDeskWsGridOffer;
// Who the resolved grid is attributed to: 0 the host has published none · 1 the grid alone · 2 the
// client at the position written to `position` · 3 a client nothing names. `position` is written for
// 2 ALONE, so a caller reading it on any other code reads whatever it left there. The clamping
// contributor is the FIRST contributing offer whose standing size equals the resolved grid — the
// roster's own order decides, so tied clients do not flicker on every presence frame. This client's
// own clamp answers 1: a client that chose the grid needs no explanation of it.
uint8_t slopdesk_ws_grid_clamped_by(uint32_t resolved_cols, uint32_t resolved_rows,
                                    const SlopDeskWsGridOffer *offers, size_t offers_len,
                                    const SlopDeskWsPresenceClient *clients, size_t clients_len,
                                    bool has_own, uint32_t own, uint32_t *position);
// The sentence — `120×40 · sized by MacBook Pro`. `attribution` is the code above and `label` is
// read for 2 alone; an empty label under 2 prints the unnamed word rather than trailing off. Returns
// 0 only when the host has resolved no grid, which cannot collide with a real answer because a
// published grid always prints at least `1×1`.
size_t slopdesk_ws_grid_readout(uint32_t cols, uint32_t rows, uint8_t attribution,
                                const unsigned char *label, size_t label_len, unsigned char *out,
                                size_t capacity);

/* ---- the reconnect SCHEDULE, and the two numbers a near side names ---------------------------
 *
 * What used to be here was eighteen doors: the client session's marks crossing by value, the
 * deliver/ack/adopt/stream-ended that stepped them in place, four gates, a round-trip fold and the
 * whole ladder. Their caller was the SWIFT pane session, and docs/63 §G.5 replaced it with
 * rust/slopdesk-clientdriver, which calls slopdesk_clientsession as a CRATE. Sixteen of the
 * eighteen lost their only caller in that one change.
 *
 * The two below are not a session at all: they are a CONFIGURATION and a piece of UI copy, and
 * both are asked BEFORE any driver exists.
 *
 * NANOSECONDS, because the near side's duration type carries attoseconds and milliseconds would
 * silently round a schedule configured in fractions of one.
 */
typedef struct {
    uint64_t initial_ns; // the wait before the first retry
    uint64_t maximum_ns; // the ceiling every later wait saturates at
    double   multiplier; // what each step multiplies by
} SlopDeskPaneBackoff;

// The shipped ladder. Read once by SlopDeskClient.Backoff, presented as its three defaults, and
// handed straight back across slopdesk_pane_driver_new's config — the schedule is BUILT on the Rust
// side from those numbers. A literal 250ms/2s/2.0 in Swift would be the copy a caller edits.
SlopDeskPaneBackoff slopdesk_pane_backoff_default(void);
// The give-up ceiling. The near side needs it for a reason the driver cannot serve: the chrome
// renders "attempt N of M" WHILE a campaign is running, so M has to be readable before the GaveUp
// event that would report it. One source, so the two can never diverge into "attempt 25 of 20".
uint32_t slopdesk_pane_backoff_max_attempts(void);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_READING_H */
