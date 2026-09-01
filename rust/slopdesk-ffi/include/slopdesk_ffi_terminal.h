// slopdesk_ffi_terminal.h — the terminal surface: the engine, its fonts, its grid, and the blocks over it
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_TERMINAL_H
#define SLOPDESK_FFI_TERMINAL_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- the terminal surface: the engine, its fonts, its arithmetic and its GPU ------------ *
 *
 * `docs/68-terminal-surface-in-rust.md` is the argument. ONE handle joins four crates —
 * `slopdesk-vterm` (what the bytes did), `slopdesk-termrender` (where every pixel goes),
 * `slopdesk-apple-text` (what a glyph looks like), `slopdesk-apple-metal` (the draw) — because
 * they only exist together and the contents scale picks something in all four. See
 * `rust/slopdesk-ffi/src/terminal_surface/`'s header.
 *
 * ⚠️ MAIN THREAD, EVERY DOOR, and this one is not a convention. The engine's terminal is `!Send`
 * and `!Sync` with no lock upstream, a `CAMetalLayer` is main-thread-affine, and Core Text's font
 * objects are the same — so the handle carries no lock at all, because a second thread may not
 * have it. A feed from a background queue CORRUPTS the grid rather than tripping an assertion.
 *
 * NOT inside the TARGET_OS_OSX region below: every client draws a terminal and both slices draw
 * it the same way. Exactly one _free per _new, and NULL is inert at every entry point — a machine
 * with no Metal device answers NULL from _new and nothing after it crashes. */
typedef struct SlopDeskTerminalSurface SlopDeskTerminalSurface;

/* Every `[terminal]` font row, as the two doors that build a face stack take it.
 *
 * The four names are spans into ONE arena the caller lends beside the record, so no field makes the
 * caller own a lifetime — SlopDeskByteSpan's own convention. The two LISTS ride beside it as span
 * arrays into that same arena: the fallback families, and the `terminal.font-feature` settings as
 * the TEXT a user typed (`-calt`, `+ss01`, `cv01=2` — ghostty's syntax, parsed in Rust).
 *
 * An empty style name is not "no bold": it means the primary family's own cut, which is also what a
 * named family that the system does not have falls back to. `thicken_strength` is read only when
 * `thicken` is set, and 0 there is the LIGHTEST stroke rather than none. */
typedef struct {
  SlopDeskByteSpan family;
  SlopDeskByteSpan bold;
  SlopDeskByteSpan italic;
  SlopDeskByteSpan bold_italic;
  double point_size;
  double line_height;
  bool thicken;
  uint8_t thicken_strength;
} SlopDeskTermFontSpec;

/* Opens a surface, or NULL when this machine cannot draw one (no Metal device, pipelines that
 * will not build, a point size that is no sane number of device pixels). A refusal does not
 * become true a frame later, so the caller latches it. An UNKNOWN family is not a refusal —
 * Core Text answers Helvetica, and `slopdesk font list` is how the user finds out what to type.
 *
 * A NULL `spec` is the FACTORY font rather than a refusal: every row it carries has a compiled
 * default one layer down, in the settings table. */
SlopDeskTerminalSurface *slopdesk_term_surface_new(const SlopDeskTermFontSpec *spec,
                                                   const SlopDeskByteSpan *fallback,
                                                   size_t fallback_count,
                                                   const SlopDeskByteSpan *features,
                                                   size_t feature_count, const uint8_t *arena,
                                                   size_t arena_len, double scale,
                                                   double width_points, double height_points);
/* Teardown is TWO doors, and the split is load-bearing.
 *
 * _close takes the state — engine, atlas, layer, device — and leaves the handle valid and inert.
 * Call it the instant the view has let go of the LENT layer and not before: the layer's drawable
 * source dies here, so a view still hosting it afterwards is hosting a layer with nothing behind it.
 *
 * _free returns the allocation, and belongs in `deinit` and nowhere else — a handle freed anywhere
 * else is a claim about which threads are running (slopdesk-invariants' handle-freed-in-deinit).
 * `deinit` runs when the LAST reference goes, which may be after the view was asked to draw again,
 * which is exactly why the two cannot be one door.
 *
 * _close is idempotent, and every other door on a closed handle answers its inert value. */
void slopdesk_term_surface_close(SlopDeskTerminalSurface *handle);
void slopdesk_term_surface_free(SlopDeskTerminalSurface *handle);

/* The CAMetalLayer to host, LENT at +0 — the opposite of the decoder's pixels, which cross at +1.
 * Rust made it, Rust owns it for the handle's whole life, and the view only hosts it:
 * `Unmanaged<CAMetalLayer>.fromOpaque(_:).takeUnretainedValue()`, never released. Its
 * drawableSize and contentsScale belong to _set_geometry; a second writer is the drift the single
 * handle exists to prevent. */
void *slopdesk_term_surface_layer(SlopDeskTerminalSurface *handle);

/* Inbound PTY bytes. Never fails and never blocks. */
void slopdesk_term_surface_feed(SlopDeskTerminalSurface *handle, const uint8_t *bytes, size_t len);

/* Re-measures the view and answers the grid it now fits, packed `cols << 16 | rows` — ONE word
 * because the pair is one answer, and two reads could straddle a second resize and mirror the
 * host a grid that never existed. A scale change rebuilds the face stack and the atlas together. */
uint32_t slopdesk_term_surface_set_geometry(SlopDeskTerminalSurface *handle, double width_points,
                                            double height_points, double scale);

/* Draws one frame. false = there was nowhere to draw (a collapsed split, a window mid-resize, a
 * drawable the compositor declined). Not an error and needs no recovery. */
bool slopdesk_term_surface_draw(SlopDeskTerminalSurface *handle);

/* Workspace focus and the blink clock's phase, together because the cursor is the only thing
 * either changes and an unfocused surface has no cursor to blink. Focus drives the hollow cursor
 * and NOT render-liveness: an unfocused split sibling keeps repainting. */
void slopdesk_term_surface_set_focus(SlopDeskTerminalSurface *handle, bool focused,
                                     bool blink_visible);

/* The theme, as three 0x00RRGGBB words. One door because the background is BOTH the engine's
 * default colour and the pass's clear colour, and setting one without the other draws a
 * one-pixel border of the wrong colour around every glyph. */
void slopdesk_term_surface_set_theme(SlopDeskTerminalSurface *handle, uint32_t foreground,
                                     uint32_t background, uint32_t selection);

/* The ANSI palette, as a PREFIX of 0x00RRGGBB words from index 0. Apart from _set_theme because a
 * theme always states its three colours and a palette is optional: a config that names none leaves
 * the engine's own 256 standing, which is a different outcome from naming sixteen black ones. */
void slopdesk_term_surface_set_palette(SlopDeskTerminalSurface *handle, const uint32_t *entries,
                                       size_t count);

/* Rebuilds the face stack at a whole font spec, answering the grid it now fits, packed
 * `cols << 16 | rows` exactly as _set_geometry does — a font change resizes the cell, so it reflows
 * the grid and the caller owes the host a resize. A family Core Text cannot resolve leaves the
 * current stack standing rather than refusing to draw.
 *
 * The WHOLE spec decides whether anything is rebuilt, not just the family and the size: a
 * `font-feature` line that turned ligatures off would otherwise be published and dropped.
 *
 * `line_height` is `terminal.line-height` as a MULTIPLE of the face's natural cell (1 for the
 * face's own). A taller cell centres its glyph in the space it gained and every offset the face
 * reported rides with the baseline, so an underline stays the same distance under its own glyph. */
uint32_t slopdesk_term_surface_set_font(SlopDeskTerminalSurface *handle,
                                        const SlopDeskTermFontSpec *spec,
                                        const SlopDeskByteSpan *fallback, size_t fallback_count,
                                        const SlopDeskByteSpan *features, size_t feature_count,
                                        const uint8_t *arena, size_t arena_len);

/* Scrolls the viewport: mode 0 by rows, 1 by PAGES, 2 to the bottom, 3 to the top. `lines` is
 * signed and negative reveals OLDER output. A page is converted against the grid the surface last
 * fitted, because a caller's own row count can be a resize stale. */
void slopdesk_term_surface_scroll(SlopDeskTerminalSurface *handle, uint8_t mode, int32_t lines);

/* Whether the Option key is Alt: 0 off, 1 both, 2 left, 3 right (`macos-option-as-alt`). */
void slopdesk_term_surface_set_option_as_alt(SlopDeskTerminalSurface *handle, uint8_t value);

/* Caps the scrollback at `lines` ROWS; zero or negative keeps none.
 *
 * Rows and not bytes, which is the whole reason this door replaced a config string: the engine's own
 * limit is a row count, so a user asking for 10 000 lines now gets 10 000 rather than whatever a
 * 256-byte-per-line estimate happened to buy them. The engine's SECOND cap, on bytes, is cleared
 * here — left standing it pruned a 10 000-line request down to 1065 rows. */
void slopdesk_term_surface_set_scrollback(SlopDeskTerminalSurface *handle, int64_t lines);

/* The quiet a scrollback must hold before a compression pass is worth starting, in milliseconds.
 *
 * Here so the caller's timer carries no number of its own: this is what it arms after a feed, and
 * every delay after that is what `slopdesk_term_surface_compress_step` answered. */
int64_t slopdesk_term_surface_compression_idle_ms(void);

/* Compresses a bounded slice of the retained scrollback; answers the milliseconds until the next
 * call, or a negative when there is nothing left to do.
 *
 * The caller owns one one-shot timer and no policy: arm it 250 ms after a feed, call this when it
 * fires, re-arm at whatever came back, stop on a negative. A compressed page decompresses the
 * moment anything reads it, so nothing else on this side changes. Same thread as every other door
 * on the handle — the engine requires compression to be serialized with reads and writes. */
int64_t slopdesk_term_surface_compress_step(SlopDeskTerminalSurface *handle);

/* The caret shape until a program asks for another: 0 block, 1 bar, 2 underline, 3 hollow block.
 * Anything else restores the engine's default.
 *
 * ⚠️ A DEFAULT, deliberately — DECSCUSR from a running program still wins, so a user who prefers a
 * bar keeps it in the shell and still sees vim's block in insert mode. Writing the LIVE shape would
 * erase what the program asked for, with nothing able to tell the two apart afterwards. */
void slopdesk_term_surface_set_cursor_style(SlopDeskTerminalSurface *handle, uint8_t style);

/* Whether the caret blinks until a program says otherwise: 1 on, 2 off, anything else the engine's
 * default. Three states rather than a bool because a user who has not chosen leaves it to DEC mode
 * 12, and a bool would have to invent an answer for them. */
void slopdesk_term_surface_set_cursor_blink(SlopDeskTerminalSurface *handle, uint8_t mode);

/* The caret colour until a program overrides it, packed 0x00RRGGBB. `present` false follows the
 * foreground, which is the engine's own default. A DEFAULT for the reason _set_cursor_style is:
 * OSC 12 still wins, which is what lets a program signal a mode by recolouring the caret. */
void slopdesk_term_surface_set_cursor_color(SlopDeskTerminalSurface *handle, uint32_t rgb,
                                            bool present);

/* How solid the caret is drawn, 0.0–1.0; zero hides it.
 *
 * The one cursor setting that never reaches the engine, because no escape sequence can express it —
 * OSC 12 carries a colour and DECSCUSR a shape, neither an alpha. The paint owns the caret rect, so
 * the paint owns this number. Out-of-range and NaN clamp where it is applied. */
void slopdesk_term_surface_set_cursor_opacity(SlopDeskTerminalSurface *handle, double opacity);

/* Whether inline images (the kitty graphics protocol) are DRAWN.
 *
 * A renderer setting and not an engine one, deliberately: the engine keeps its image storage either
 * way, so turning this back on redraws whatever is still on screen instead of waiting for a program
 * to retransmit. Off is a picture nobody sees, not a picture nobody has.
 *
 * This does NOT gate what the terminal ACCEPTS. The file and shared-memory transmission mediums are
 * closed permanently, because in this app the terminal is the CLIENT and a path a remote program
 * names would resolve on the user's own laptop — a refusal, not a preference. */
void slopdesk_term_surface_set_images(SlopDeskTerminalSurface *handle, bool enabled);

/* The colour the glyph under a filled caret takes, packed 0x00RRGGBB. `present` false keeps the
 * cell's own background, which is the reading that is always legible.
 *
 * A renderer setting for _set_cursor_opacity's reason: no escape names this colour, so unlike the
 * shape, the blink and the caret's own colour there is no engine default for a program to override
 * and nothing is lost by deciding it here. */
void slopdesk_term_surface_set_cursor_text_color(SlopDeskTerminalSurface *handle, uint32_t rgb,
                                                 bool present);

/* Whether a copy drops the blanks a terminal padded each short line with. */
void slopdesk_term_surface_set_trim_trailing(SlopDeskTerminalSurface *handle, bool trim);

/* Forgets any pointer button the encoder was tracking.
 *
 * What a surface calls when the pointer leaves mid-drag: without it the encoder still believes a
 * button is down and keeps reporting drag motion the user is no longer making. */
void slopdesk_term_surface_reset_pointer(SlopDeskTerminalSurface *handle);

/* Whether the selection stops exactly where the cursor stands.
 *
 * The question a CUT has to answer before it sends a single DEL: cutting from a terminal is not an
 * edit the terminal can perform, so the delete half is BACKSPACES, and those only remove the
 * selected text when the cursor sits immediately past it. Asked of the surface because the surface
 * is the only thing holding both the selection and the cursor. */
bool slopdesk_term_surface_selection_ends_at_cursor(SlopDeskTerminalSurface *handle);

/* The `mods` word the key and mouse doors take, built from what the platform says is held.
 *
 * ⚠️ This door exists so that no modifier BIT is ever spelled in Swift. The bits are libghostty's
 * `key::Mods`, upstream's to renumber; a client that hard-coded them would hold a second copy of a
 * layout it does not own, and the failure mode is silent — ⌃C encoding as ⌥C rather than as an
 * error. The client passes what it actually knows (which physical keys AppKit or UIKit reported)
 * and gets back the one word the encoder wants.
 *
 * The right_* flags say which SIDE a held modifier is on and mean nothing without their held flag.
 * Only `macos-option-as-alt = left|right` reads one, but all four cross on every press: a mods word
 * that depended on a config value would be one the caller could build differently from the one the
 * encoder resolves against. Pure — no handle, no state; nothing held is 0. */
uint16_t slopdesk_term_mods(bool shift, bool alt, bool ctrl, bool command, bool caps_lock,
                            bool num_lock, bool right_shift, bool right_alt, bool right_ctrl,
                            bool right_command);

/* Which adjust_selection edge a shift+arrow press names (0 up, 1 down, 2 left, 3 right), or -1 for
 * a press that names none — `controls.shift-arrow-select`'s recognition step. `keycode` and `mods`
 * are the pair _surface_key already takes.
 *
 * The rule is HERE and not in the client because the modifier test is subtle: a right-shift press
 * carries SHIFT|RIGHT_SHIFT and Caps Lock and Num Lock ride along on every press while they are
 * on, so the lock and side bits are masked before the comparison. A client's own copy would refuse
 * a right-handed typist and everyone with Caps Lock on. Alt, Ctrl and Command are NOT masked —
 * shift+alt+arrow is a word-wise selection the program still gets. Pure; no handle, no state. */
int32_t slopdesk_term_shift_arrow_edge(uint16_t keycode, uint16_t mods);

/* The bytes that walk the shell's cursor to a clicked cell, or 0 for a click this may not answer —
 * `controls.click-to-move`. `column`/`row` are the clicked CELL as slopdesk_link_hit_cell resolves
 * one, `row` being a row of the VIEWPORT. Answers §4's byte count; 0 is a refusal and the caller
 * sends nothing.
 *
 * The presses are arrows because a shell's line editor owns its cursor and nothing can place it,
 * and they are LEFT/RIGHT only: at a prompt up/down are HISTORY, so crossing rows would replace
 * the half-typed command the user clicked into. Counted in GLYPHS — a wide character is two cells
 * and one press — and encoded through the engine, so DECCKM picks `ESC [ C` vs `ESC O C`. Refused
 * on the alternate screen, under a mouse-reporting program, and off the cursor's own row. Whether
 * the shell is at an EDITABLE prompt is deliberately NOT asked here: that reading is OSC 133 plus a
 * live connection, which the client already holds. */
size_t slopdesk_term_surface_click_to_move(SlopDeskTerminalSurface *handle, uint16_t column,
                                           uint16_t row, uint8_t *out, size_t cap);

/* One key press, encoded to the bytes the far side expects. `keycode` is an AppKit
 * NSEvent.keyCode — a POSITION, which the engine's own table turns into the KEY its encoder needs
 * — and 0xFFFF means "no key at all", which is an IME commit where `text` is the whole event. iOS
 * passes 0xFFFF for every press: a UIKey carries characters, not a hardware position.
 * `action` 0 press / 1 release / 2 repeat. Answers §4's byte count; 0 is a press that encodes to
 * nothing (a bare modifier, or a press while composing). */
size_t slopdesk_term_surface_key(SlopDeskTerminalSurface *handle, uint16_t keycode, uint8_t action,
                                 uint16_t mods, uint16_t consumed_mods, const uint8_t *text,
                                 size_t text_len, bool composing, uint8_t *out, size_t cap);

/* One pointer event, or 0 when the far side is not tracking the mouse — which the caller reads as
 * "this gesture is mine", and falls through to the selection doors below. `action` 0 press /
 * 1 release / 2 motion; `button` 0 left / 1 right / 2 middle / 255 none / n>2 the nth button.
 * x and y are the view's POINTS, top-left origin: the surface scales them, because the scale it
 * would use is the one it drew with and a caller's copy can be a frame stale. */
size_t slopdesk_term_surface_mouse(SlopDeskTerminalSurface *handle, uint8_t action, uint8_t button,
                                   uint16_t mods, double x, double y, uint8_t *out, size_t cap);

/* Pointer selection, over the ENGINE's own gesture state machine — the click ladder (single a
 * cell, double a word, triple a line) is a rule about a gesture's HISTORY, so it is not
 * re-derived on this side. The three time/slop numbers are the platform's own
 * (NSEvent.doubleClickInterval, and the slop a finger is allowed); milliseconds and points.
 * Each answers whether the selection CHANGED. */
bool slopdesk_term_surface_select_press(SlopDeskTerminalSurface *handle, double x, double y,
                                        double time_ms, double repeat_interval_ms,
                                        double repeat_distance);
bool slopdesk_term_surface_select_drag(SlopDeskTerminalSurface *handle, double x, double y,
                                       bool rectangle);
void slopdesk_term_surface_select_release(SlopDeskTerminalSurface *handle, double x, double y);

/* Which way a live drag wants the viewport to move — 0 nowhere, 1 up, 2 down — and one tick of it.
 * Two doors because the tick needs the pointer's CURRENT position and only the view has it;
 * folding them would make the engine keep a copy a mouse-up could strand. */
uint8_t slopdesk_term_surface_autoscroll_direction(SlopDeskTerminalSurface *handle);
bool slopdesk_term_surface_select_autoscroll(SlopDeskTerminalSurface *handle, double x, double y,
                                             bool rectangle);

/* The selection verbs that take no pointer: 0 clear, 1 select all, 2 ask. Each answers whether
 * anything is selected AFTERWARDS, so a menu item's enablement is the same read after all three. */
bool slopdesk_term_surface_selection_verb(SlopDeskTerminalSurface *handle, uint8_t verb);

/* The selection as text: 0 plain, 1 with its SGR escapes, 2 as HTML. §4's byte count; 0 = nothing
 * selected. Soft-wrapped lines are UNWRAPPED and trailing blanks trimmed — a copied command that
 * pastes back as two broken ones is the failure that settles it. */
size_t slopdesk_term_surface_selection_text(SlopDeskTerminalSurface *handle, uint8_t format,
                                            uint8_t *out, size_t cap);

/* The visible rows as text, for the link-underline and Hint Mode overlays:
 *   [u32 row_count] row_count × [u32 length][UTF-8 bytes]
 * From the same frame the painter drew, never a second scan: an underline placed against a row the
 * surface has since scrolled is an underline under the wrong text. */
size_t slopdesk_term_surface_viewport_rows(SlopDeskTerminalSurface *handle, uint8_t *out,
                                           size_t cap);

/* The live cell geometry, in POINTS, as TerminalCellMetrics reads it:
 *   [f64 cell_width][f64 cell_height][u32 cols][u32 rows][f64 origin_x][f64 origin_y]
 * The ONE door that converts back out of device pixels. An overlay is a view laid out in points,
 * and handing it pixels would put a second contents-scale division in the client. */
size_t slopdesk_term_surface_cell_metrics(SlopDeskTerminalSurface *handle, uint8_t *out,
                                          size_t cap);

/* The four flags the client's policy layers ask about, as bits: 1 alternate screen, 2 mouse
 * tracking, 4 viewport at the bottom, 8 DEC bracketed paste (?2004h). One door because all four are
 * read on the SAME events, and four reads is four chances to act on a mixed state — forwarding a
 * scroll as a mouse report because tracking was read before the alt-screen flip, or skipping the
 * paste-protection sheet on a ?2004h the program has since turned off. */
uint8_t slopdesk_term_surface_modes(SlopDeskTerminalSurface *handle);

/* The exact bytes a paste of (bytes, len) should put on the pty.
 *
 * A paste is not "write these bytes". The engine scrubs the control bytes a payload must never
 * carry into a prompt (NUL, ESC, DEL), turns newlines into carriage returns when the paste is NOT
 * bracketed, and strips any embedded ESC [ 201 ~ before wrapping — the bracketed-paste breakout,
 * where a clipboard that smuggled an end marker closes the block early and injects its tail as live
 * input. All three are rules about the FAR side's parser, so they belong to the engine that owns it;
 * a Swift "\e[200~" + text would be a second, worse paste implementation.
 *
 * `bracketed` is the caller's on purpose: ordinary Paste passes bit 8 of _modes, Bracketed Paste
 * forces true, and Paste as Keystrokes forces false so the payload arrives as if typed.
 *
 * This door writes nothing and consults no setting — the paste-protection decision (PastePrecheck)
 * happens BEFORE these bytes are asked for. Non-UTF-8 input answers 0. */
size_t slopdesk_term_surface_encode_paste(SlopDeskTerminalSurface *handle, const uint8_t *bytes,
                                          size_t len, bool bracketed, uint8_t *out, size_t cap);

/* ---- screen coordinates: where the viewport sits, and what is on a row ------------------- */

/* Where the viewport sits in the SCREEN coordinate space, and where the cursor is in it:
 *   [u32 total_rows][u32 viewport_top_row][u32 viewport_rows][u32 cols][u32 cur_col][u32 cur_row]
 * One door for six numbers because copy mode reads them together, and any two of them from
 * different moments describe a grid that never existed. The cursor is in SCREEN rows, not viewport
 * rows: mixing one viewport-relative number into a screen-space blob is the kind of seam that
 * reads correct until the user scrolls. No visible cursor answers the viewport's top-left. */
size_t slopdesk_term_surface_viewport_info(SlopDeskTerminalSurface *handle, uint8_t *out,
                                           size_t cap);

/* Selects from one SCREEN coordinate to another, replacing whatever was selected. Both ends are
 * inclusive and either order; `rectangle` selects a block. `false` means an endpoint has scrolled
 * out of the buffer — an ordinary outcome for a coordinate the caller held across time. */
bool slopdesk_term_surface_set_selection(SlopDeskTerminalSurface *handle, uint32_t anchor_col,
                                         uint32_t anchor_row, uint32_t head_col, uint32_t head_row,
                                         bool rectangle);

/* One SCREEN row's text, trailing padding trimmed. 0 for a row no longer retained AND for a blank
 * one — the same answer to "what text is there". A caller that must tell them apart asks
 * slopdesk_term_surface_viewport_info for the extent. */
size_t slopdesk_term_surface_screen_row(SlopDeskTerminalSurface *handle, uint32_t row, uint8_t *out,
                                        size_t cap);

/* The inclusive SCREEN row range of the logical line containing `row`:
 *   [u32 first][u32 last]
 * 0 for a row no longer retained. An unwrapped row answers `row, row`, so the caller never needs a
 * separate "is this wrapped" question. */
size_t slopdesk_term_surface_line_range(SlopDeskTerminalSurface *handle, uint32_t row, uint8_t *out,
                                        size_t cap);

/* The whole scrollback unwrapped, each entry carrying the rows it occupies:
 *   [u32 count] count × [u32 first_row][u32 last_row][u32 length][UTF-8 bytes]
 * The rows travel WITH the text because a match is somewhere to scroll, and a line's index is not
 * its row — one wrapped line is several rows. Leaving that mapping to the client would put the
 * arithmetic in Swift, which is the wrong side of the boundary for arithmetic.
 *
 * ⚠️ This reads the entire scrollback and allocates its text. It is a GESTURE door — the find
 * bar's row-driven modes and the block extractor — and must never be called per frame. */
size_t slopdesk_term_surface_logical_lines(SlopDeskTerminalSurface *handle, uint8_t *out,
                                           size_t cap);

/* Performs one keybinding action, spelled by slopdesk_ws_binding_action or the surface grammar.
 *
 * ⚠️ The client never parses this string and never composes one by hand. A spelling this door does
 * not recognise is answered by doing NOTHING and returning false, because there is no sound way to
 * guess what a typo meant — which is also why the answer is a bool and not void: a keystroke that
 * quietly did nothing is the failure this seam exists to make visible.
 *
 * false ALSO means the action was understood and had nothing to do — no prompt in that direction,
 * no selection to adjust, no hit to navigate to. The caller wants the same thing either way: leave
 * the key unhandled so something else can have it. */
bool slopdesk_term_surface_binding_action(SlopDeskTerminalSurface *handle, const uint8_t *action,
                                          size_t action_len);

/* Runs the find bar's query over the whole retained buffer; answers the hit count.
 *
 * ⚠️ This exists because the find bar has four modes and `search:` carries one. The keybinding verb
 * is a needle and nothing else — a user writing `search:TODO` wants the plain find — so
 * case-sensitivity, whole-word and regex had no way across, and the bar answered them with a SECOND
 * scan of its own over a flat text mirror. Two scans of one buffer meant the `N of M` it printed and
 * the cells the surface lit could disagree. Both routes end at one engine now.
 *
 * The count is the answer rather than a bool for the same reason: the bar needs it, and a binding
 * action could only ever say whether something happened.
 *
 * An empty needle, or a regex that does not compile, answers 0 and clears the highlight — the two
 * states a find field passes through on the way to a real query, which are not errors. */
size_t slopdesk_term_surface_find(SlopDeskTerminalSurface *handle, const uint8_t *needle,
                                  size_t needle_len, bool case_sensitive, bool whole_word,
                                  bool regex);

/* The current hit's position, as the `3 of 17` a find bar prints — one-based.
 *
 * false when nothing is current (no query, or a query with no hits), and neither output is written
 * in that case, so a caller that ignores the answer keeps what it had rather than reading a zero as
 * "hit 0 of 0". A PULL after the navigation verb, which answers only whether it moved. */
bool slopdesk_term_surface_find_position(SlopDeskTerminalSurface *handle, size_t *current,
                                         size_t *total);

/* What the terminal owes the pty: the reply to CSI 6n, CSI c, CSI > q, OSC 10/11/4 ?, and the
 * in-band size report. Raw bytes, written back to the shell verbatim and in order.
 *
 * ⚠️ The caller must poll this after every slopdesk_term_surface_feed AND after every
 * slopdesk_term_surface_set_geometry — a resize can emit an in-band size report. It is not
 * optional and not a feature: a dropped device-status reply is a vim that never finishes
 * starting. Two attempts, never a loop; the queue is held until a call actually writes it, so a
 * retry cannot lose the reply the first call refused to truncate.
 *
 * ⚠️ Drain and DISCARD once after a replay. `TerminalViewModel.attachSurface` re-feeds the
 * retained output ring into a rebuilt surface, and those bytes contain the OLD CSI 6n / CSI c
 * queries — forwarding the fresh engine's answers to them types escape garbage at a live prompt. */
size_t slopdesk_term_surface_take_pty_replies(SlopDeskTerminalSurface *handle, uint8_t *out,
                                              size_t cap);

/* The clipboard writes running programs asked for over OSC 52 (and iTerm2's OSC 1337 Copy):
 *   [u16 count] × [u8 target: 0 standard · 1 selection · 2 primary][u32 len][UTF-8]
 * 0 on the common day, which is one call and no allocation.
 *
 * The other things the engine sees and this door does NOT carry — the bell, the OSC-9/777
 * notification, the OSC-9;4 progress report, the OSC 0/2 title, the OSC-7 working directory — all
 * arrive as their own wire messages from the host, which is the only owner that survives
 * multiclient and the only one that does not re-fire on a replay. A clipboard is per-CLIENT, so it
 * is the one push with nowhere else to come from.
 *
 * ⚠️ A write here has NOT been applied. The frame says what a program ASKED for, and
 * slopdesk_term_clipboard_write decides whether it happens. Pasting from this frame directly would
 * make the "Ask" policy behave as "Allow". Replay applies here too: drain and discard once. */
size_t slopdesk_term_surface_take_clipboard_writes(SlopDeskTerminalSurface *handle, uint8_t *out,
                                                   size_t cap);

/* ---- the block list: Warp-shaped chrome over the same grid ---------------------------------- *
 *
 * `rust/slopdesk-termrender`'s segmenter cuts the frame on OSC 133 `A` and places every block, and
 * `chrome.rs` DRAWS the furniture — gutter, divider, collapse mark, scrollbar — in the same pass as
 * the glyphs. What crosses is the DESIGN, not the drawing: _set_chrome_style states the colours and
 * thicknesses once, and the client never has to keep a layer in step with a scroll it does not own.
 *
 * The rects still cross, because a hit test, a context menu and a copy-block verb are all questions
 * asked between frames. They are in POINTS — the unit every other pointer door on this surface
 * takes — already offset by the insets and by the list's scroll, so a caller places a view at them
 * knowing neither. A block whose `visible` is false was laid out and culled — the caller keeps its
 * view off-screen rather than recomputing what the layout already decided. */

typedef struct {
  double  x, y, width, height;                      /* the whole block, chrome included      */
  double  header_x, header_y, header_width, header_height;
  double  body_x, body_y, body_width, body_height;  /* the rows, without the header          */
  bool    has_header;                               /* false for an ORPHAN — output with no prompt */
  bool    collapsed;
  bool    visible;                                  /* survived viewport culling             */
  uint16_t first_row;                               /* the frame rows this block spans       */
  uint16_t end_row;
  uint16_t prompt_rows;                             /* how many of them the prompt occupies  */
} SlopDeskTerminalBlock;

/* Where the block list sits, for a scrollbar. `content_height` exceeds `viewport_height` by exactly
 * the chrome the headers and gaps added: the GRID is sized from the drawable alone, so a prompt
 * appearing never resizes the PTY. */
typedef struct {
  double scroll_y;
  double content_height;
  double viewport_height;
  bool   following;        /* pinned to the bottom as output arrives */
} SlopDeskTerminalBlockScroll;

/* Every block the last draw placed, §4's record count. Positional: the index a caller reads here is
 * the index every other block door takes. */
size_t slopdesk_term_surface_blocks(SlopDeskTerminalSurface *handle, SlopDeskTerminalBlock *out,
                                    size_t cap);

SlopDeskTerminalBlockScroll slopdesk_term_surface_block_scroll(SlopDeskTerminalSurface *handle);

/* The block under a point in surface POINTS, or -1 for none. */
int64_t slopdesk_term_surface_block_at_point(SlopDeskTerminalSurface *handle, double x, double y);

/* What a right-click found under it: which block, and what a menu may offer for it. `hit` false means
 * the point landed in no block and every other field is meaningless. */
typedef struct {
  bool     hit;
  uint32_t ordinal;   /* the 1-based PROMPT-CYCLE ordinal, or 0 when it joined no host record */
  bool     foldable;  /* it has prompt rows of its own, so a fold leaves something behind      */
  bool     collapsed; /* it is folded RIGHT NOW, which the fold verb's own label reads off     */
} SlopDeskTerminalBlockTarget;

/* _block_at_point answers the LAYOUT position, which a click on a header spends immediately; this
 * answers the JOIN key plus the two state bits a menu needs, which a right-click spends seconds
 * later. Two doors because a hover and a menu want different halves of the same hit, and folding
 * them would make the cheap one pay the join. In POINTS, like every other pointer door. */
SlopDeskTerminalBlockTarget slopdesk_term_surface_block_target(SlopDeskTerminalSurface *handle,
                                                               double x, double y);

/* What the furniture is drawn with. Colours are 0xAARRGGBB — the one place on this surface where the
 * high byte IS alpha, because a hover wash and a thumb are translucent by design where a cell's ink
 * never is. Lengths are POINTS and are scaled inside, so a display change costs the client nothing.
 * An all-zero struct is a complete design that draws nothing, which is what an uninstalled
 * appearance looks like. */
typedef struct {
  uint32_t divider;                /* the hairline between one block and the next */
  uint32_t gutter;                 /* the bar down a block's leading edge         */
  uint32_t gutter_active;          /* the same bar on the block holding the cursor */
  uint32_t hover;                  /* the wash over the block under the pointer   */
  uint32_t label;                  /* the collapse mark and its folded-row count  */
  uint32_t status_err;             /* the `✗ <code>` on a failed block's header   */
  uint32_t scrollbar;              /* the thumb                                   */
  double   divider_thickness;
  double   gutter_thickness;
  double   scrollbar_thickness;
  double   scrollbar_min_height;   /* the grabbable floor in a long scrollback    */
  double   scrollbar_inset;        /* the gap to the trailing edge                */
} SlopDeskTerminalChromeStyle;

/* One door for the whole design, for _set_theme's reason: a divider colour paired with last frame's
 * gutter thickness is a state the client never described. */
void slopdesk_term_surface_set_chrome_style(SlopDeskTerminalSurface *handle,
                                            SlopDeskTerminalChromeStyle style);

/* Where the pointer is, in POINTS, so the block under it takes the hover wash. `inside` is how
 * "nowhere" is spelled — (0, 0) is a real point inside the first block. A POSITION and not an index,
 * because an index the client held would light the wrong block the moment output re-laid the list.
 * Answers whether the next frame would DIFFER: a pointer gliding inside one block sends a move per
 * sample and changes no pixel, and presenting on each would pay a full render for the picture
 * already on screen. Present only on true. */
bool slopdesk_term_surface_set_hover(SlopDeskTerminalSurface *handle, double x, double y,
                                     bool inside);

/* Folds one block. An index past the end, or an ORPHAN with no header to click, is ignored —
 * _toggle answers the state it left behind. */
void slopdesk_term_surface_set_block_collapsed(SlopDeskTerminalSurface *handle, size_t index,
                                               bool collapsed);
bool slopdesk_term_surface_toggle_block_collapsed(SlopDeskTerminalSurface *handle, size_t index);
/* The ordinal-keyed sibling, and the one a MENU uses: the fold vector is POSITIONAL, a menu stays
 * open for seconds, and output arriving meanwhile re-segments the list — so the layout index is
 * resolved HERE at action time rather than stashed when the menu was built. false for an ordinal no
 * block wears. */
bool slopdesk_term_surface_toggle_block_collapsed_at_ordinal(SlopDeskTerminalSurface *handle,
                                                             uint32_t ordinal);
void slopdesk_term_surface_expand_all_blocks(SlopDeskTerminalSurface *handle);

/* The wheel and the trackpad, in POINTS, spending the block chrome before the scrollback. A
 * positive delta reveals OLDER output — the same direction slopdesk_term_surface_scroll spells
 * negative, because that door counts engine rows and this one counts the gesture. What the chrome
 * cannot absorb spills into the engine as whole rows. */
void slopdesk_term_surface_scroll_points(SlopDeskTerminalSurface *handle, double delta);

/* One command-block record from the host (wire type 28), so the block's HEADER can print its exit
 * code and duration once the rows have scrolled back. Upserted by `ordinal` — a block arrives once
 * running and again finished, and the second replaces the first. An `ordinal` of 0 is a mid-stream
 * attach that names no position and is DROPPED. `exit_code`/`duration_ms` are read only when their
 * `has_` flag is set, because a running command has neither and every sentinel collides with a real
 * value. `command_text` confirms the join and is never displayed. */
void slopdesk_term_surface_note_block(SlopDeskTerminalSurface *handle, uint32_t ordinal,
                                      const uint8_t *text, size_t text_len, bool has_exit_code,
                                      int32_t exit_code, bool has_duration, uint32_t duration_ms);

/* Drops every record noted above, for a pane whose shell DIED and came back fresh. The fresh shell
 * counts its prompts from 1 while the surface still holds the dead session's forties, so the join
 * would anchor on a stale ordinal — and repeated everyday commands can make the text check CONFIRM
 * that wrong anchor. Call it wherever the client drops its own block list; NOT on a reattach that
 * resumed the same shell, whose blocks are still the ones on screen. */
void slopdesk_term_surface_forget_blocks(SlopDeskTerminalSurface *handle);

/* One block's prompt rows as RENDERED, soft wraps rejoined — what a header prints. Not the bare
 * command: OSC 133 `B` does not cross the engine's per-row API, so a shell that decorates its
 * prompt sends that decoration too. The exit code and duration come from
 * slopdesk_term_surface_note_block instead, joined to this block by prompt ordinal. */
size_t slopdesk_term_surface_block_text(SlopDeskTerminalSurface *handle, size_t index, uint8_t *out,
                                        size_t cap);

/* The OSC 8 URI on one cell, or 0 bytes when that cell carries no authored link. The FLAG is in the
 * frame and the URI is not, because one URI is shared by a whole run of cells: this reads it for
 * the one cell a pointer is over, and answers 0 without touching the engine when the frame says
 * there is nothing there. An AUTHORED link wins over a DETECTED one — the program said so. */
size_t slopdesk_term_surface_hyperlink_at(SlopDeskTerminalSurface *handle, uint16_t column,
                                          uint16_t row, uint8_t *out, size_t cap);

/* One run of cells a program declared as an OSC 8 hyperlink. */
typedef struct SlopDeskTerminalLinkSpan {
  uint16_t row;   /* viewport row, from the top */
  uint16_t start; /* first linked column */
  uint16_t end;   /* one past the last linked column */
} SlopDeskTerminalLinkSpan;

/* Every authored hyperlink run in the viewport, answering the count NEEDED.
 *
 * A LIST door rather than the per-cell _hyperlink_at because the hover underline draws every link at
 * once: asking cell by cell would be rows × cols crossings for a picture that changes every frame.
 * This walks the frame's HYPERLINK flags once. Two different links that touch with no character
 * between them arrive as ONE span, which is the same underline either way. */
size_t slopdesk_term_surface_hyperlink_spans(SlopDeskTerminalSurface *handle,
                                             SlopDeskTerminalLinkSpan *out, size_t cap);

/* One OSC 8 run, split where the URI changes, with the link it classifies to. The strings name
 * (offset, length) into the arena the door below fills. */
typedef struct SlopDeskTerminalLinkRun {
  uint16_t row;             /* viewport row, from the top */
  uint16_t start;           /* first linked column */
  uint16_t end;             /* one past the last linked column */
  uint32_t kind;            /* SLOPDESK_LINK_KIND_*; URL unless the URI is a file:// one */
  size_t   uri_offset;      /* into the arena */
  size_t   uri_length;
  bool     has_resolved;
  size_t   resolved_offset; /* into the arena; read only when has_resolved */
  size_t   resolved_length;
} SlopDeskTerminalLinkRun;

/* Every authored hyperlink run in the viewport, SPLIT where the URI changes and already classified.
 *
 * The ACTUATION door, where _hyperlink_spans is the DRAWING one: an underline does not care that two
 * different links abut with no character between them, and a click or a hint label cares about
 * nothing else. This asks the engine per LINKED cell, so it is called when a pointer lands or Hint
 * Mode arms — never per frame. No scheme policy is consulted: that setting governs GUESSING, and a
 * program that emitted OSC 8 did not guess.
 *
 * Returns the run COUNT always and writes arena_len always, so one call with both caps at 0 sizes
 * both buffers and a second fills them. Nothing is written unless BOTH are large enough — a record
 * set delivered against an arena that did not fit would name bytes nobody wrote. */
size_t slopdesk_term_surface_hyperlink_runs(SlopDeskTerminalSurface *handle,
                                            SlopDeskTerminalLinkRun *out, size_t cap,
                                            uint8_t *arena, size_t arena_cap, size_t *arena_len);

/* What an input method is composing over the cursor, or nothing at all for len 0.
 *
 * The composition NEVER reaches the engine: an input method may replace the whole run on the next
 * keystroke — Telex turns `Tieengs` into `Tiếng` by rewriting what it already showed — and text fed
 * to the engine is on the grid for good. The surface DRAWS it over the cells the cursor stands on
 * instead, and the grid never changes; the commit arrives through the ordinary key door.
 *
 * cursor_bytes is the composition's own caret as a UTF-8 offset into text. A BYTE offset because
 * measuring CELLS is this side's job — an offset that is not a character boundary, or is past the
 * end, reads as a caret after everything composed so far.
 *
 * Answers whether the next frame would DIFFER, _set_hover's convention: an input method re-reports
 * an unchanged composition on every arrow key. Present only on true. */
bool slopdesk_term_surface_set_marked_text(SlopDeskTerminalSurface *handle, const uint8_t *text,
                                           size_t len, size_t cursor_bytes);

/* The caret's CELL in POINTS — x, y, width, height, in that order — for an input method's candidate
 * window. false, and out untouched, when no cursor is on screen; the caller then lets the platform
 * place the window itself.
 *
 * The cell's rect rather than the caret's drawn shape: a bar cursor's two-pixel sliver would hang
 * the candidate list under the character rather than under the insertion point. */
bool slopdesk_term_surface_caret_rect(SlopDeskTerminalSurface *handle, double *out);

/* One binding action WITH an argument, spelled by the grammar's only speller.
 *
 * ⚠️ This door exists so that no String naming an action is ever built in Swift. The executor at
 * the other end (slopdesk_term_surface_binding_action) answers an unrecognised spelling by doing
 * NOTHING — a typo does not raise, it makes a keystroke quietly stop working. So the client knows
 * the verbs as NUMBERS, which a compiler checks, and asks here for the one string it then carries.
 *
 *   code 1 scroll_page_lines        signed rows
 *   code 2 scroll_page_fractional   signed THOUSANDTHS of a page (-900 is -0.9)
 *   code 3 jump_to_prompt           signed prompts
 *   code 4 adjust_selection         0 up · 1 down · 2 left · 3 right
 *   code 5 scroll_to_top            argument ignored
 *   code 6 scroll_to_bottom         argument ignored
 *   code 7 scroll_to_row            the screen row
 *
 * Thousandths rather than a double for code 2 because the fraction is one of two design constants
 * (0.5 for ⌃d, 0.9 for ⌃f) and an integer cannot arrive as a NaN — the one input the grammar
 * refuses. 0 for a code this build does not know, and for an argument outside its verb's range. */
size_t slopdesk_ws_binding_action(uint8_t code, int64_t argument, uint8_t *out, size_t cap);

/* The text a SLOPDESK_* number is written with — the same rule the config text writes its own
 * numbers by, at the limit an env value reaches. The limit is not a thing the near side spells. */
size_t slopdesk_settings_env_number_text(double value, uint8_t *out, size_t cap);

/* The one directory every SlopDesk sidecar lands in, inside the lent Application-Support BASE —
 * or the directory SLOPDESK_APP_SUPPORT_DIR names, which moves the whole container. The base
 * crosses because only the app process can ask Foundation for it: HOME does not move Application
 * Support, and a base derived from HOME would hand a redirected client the real container. An
 * empty base with no override answers 0 — there is nowhere to put the file. */
size_t slopdesk_app_support_dir(const uint8_t *base, size_t base_len, uint8_t *out, size_t cap);

/* ---- folders: the frecency ranking, and the `jump` target it resolves ------------------- */

/* Recency buckets, for `slopdesk_folder_weight`. */
#define SLOPDESK_FOLDER_WEIGHT_HOUR 0u
#define SLOPDESK_FOLDER_WEIGHT_DAY 1u
#define SLOPDESK_FOLDER_WEIGHT_WEEK 2u
#define SLOPDESK_FOLDER_WEIGHT_MONTH 3u
#define SLOPDESK_FOLDER_WEIGHT_STALE 4u

/* The store's limits, for `slopdesk_folder_limit`: the ceiling on stored entries, and the longest
 * storable path in Unicode scalars. An unknown code answers 0. */
#define SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES 0u
#define SLOPDESK_FOLDER_LIMIT_PATH_SCALARS 1u

/* One folder record: a path naming bytes in the arena lent alongside, plus the two scored terms. */
typedef struct {
  SlopDeskByteSpan path;
  int64_t          access_count;
  double           last_access;
} SlopDeskFolderEntry;

/* A resolved `slopdesk jump`: where to go, and the toggle source to persist. */
typedef struct {
  SlopDeskByteSpan path;
  SlopDeskByteSpan source;
  bool             resolved;
  bool             has_source;
} SlopDeskJumpResolution;

int64_t slopdesk_folder_weight(uint32_t bucket);
int64_t slopdesk_folder_recency_weight(double now, double last_access);
int64_t slopdesk_folder_score(int64_t access_count, double last_access, double now);
size_t slopdesk_folder_ranked(const SlopDeskFolderEntry *entries, size_t count,
                              const uint8_t *arena, size_t arena_len, double now, int64_t limit,
                              uint32_t *order, size_t order_cap);
size_t slopdesk_folder_limit(uint32_t limit);
bool slopdesk_folder_path_is_valid(const uint8_t *path, size_t len);
size_t slopdesk_folder_sanitized(const SlopDeskFolderEntry *entries, size_t count,
                                 const uint8_t *arena, size_t arena_len, size_t max_entries,
                                 uint32_t *order, size_t order_cap);
size_t slopdesk_jump_resolve(const uint8_t *query, size_t query_len,
                             const SlopDeskFolderEntry *entries, size_t count,
                             const uint8_t *entry_arena, size_t entry_arena_len, double now,
                             const uint8_t *home, size_t home_len, const uint8_t *cwd,
                             size_t cwd_len, const uint8_t *source, size_t source_len,
                             bool change_directory, SlopDeskJumpResolution *out, uint8_t *arena,
                             size_t arena_cap);

/* ---- clipboard: the client's own board, and what may leave the device ------------------- */

/* `rust/slopdesk-apple-pasteboard` is the board — `NSPasteboard` on one slice, `UIPasteboard` on the
 * other — and `rust/slopdesk-clipboard` is the four rules over it, which the HOST reads out of the
 * same crate. Declared OUTSIDE the macOS-only region below on purpose: every client has a board, so
 * unlike the encoder there is no half that must be absent on a slice.
 *
 * Every door takes a board NAME, empty for the machine's own. The name exists because a Swift suite
 * runs against a per-process board — the general one is machine-global shared state, and a parallel
 * test worker or the developer's own copy clobbers what it asserts on. Which board, and whether to
 * ask for a private one, is a fact about the Swift test harness and stays there. */

/* Whether an UNATTENDED read of a board's CONTENT is free of a user-visible consequence: true on
 * macOS, false on iOS, where since iOS 16 it raises a modal "Allow Paste?" alert. The probes below
 * — the change count, syncability, "is there text" — never raise it on either platform. WHEN to
 * read is still the caller's question; this answers only what the platform allows. */
bool slopdesk_clipboard_unattended_read_is_permitted(void);

/* The UTI a password manager marks a concealed clip with — the one door with no shipping caller. A
 * Swift suite proving the refusal has to SEED a concealed board, and the only other way to spell
 * that is a literal in Swift, which `one-pasteboard-clip` bans precisely because this exists. */
size_t slopdesk_clipboard_concealed_type(uint8_t *out, size_t cap);

/* The board's change counter, which advances on every write by anybody. The whole of a clipboard
 * poll, and the half of it iOS still permits unattended. */
int64_t slopdesk_clipboard_change_count(const uint8_t *name, size_t name_len);

/* Whether this board's content may leave the device: not a CONCEALED clip (a password manager's
 * `org.nspasteboard.ConcealedType`) and not a FILE copy (a path means nothing on the other
 * machine). Answered from the DECLARED types, so it costs no content read and raises no alert. */
bool slopdesk_clipboard_is_syncable(const uint8_t *name, size_t name_len);

/* Whether the board holds plain text AT ALL, without reading it — the ENABLEMENT question, safe to
 * ask on every render. The paste itself asks `slopdesk_clipboard_read_text`. */
bool slopdesk_clipboard_has_text(const uint8_t *name, size_t name_len);

/* The board's current shippable clip as `[kind byte][content]` — one call for the size, one for the
 * bytes. The kind is the wire's own (1 text, 2 PNG); 0 bytes means nothing to ship, which a clip
 * cannot be mistaken for since a clip is at least two. 0 for an empty board, a file copy, an
 * over-cap clip, an image that will not transcode, and — when `skipping_concealed` — a concealed
 * one. CONTENT read. */
size_t slopdesk_clipboard_read(const uint8_t *name, size_t name_len, bool skipping_concealed,
                               uint8_t *out, size_t cap);

/* The board's plain-text head as UTF-8, 0 bytes when it holds something else. No cap and no
 * refusals: this is the read behind a paste, not behind a push. CONTENT read. */
size_t slopdesk_clipboard_read_text(const uint8_t *name, size_t name_len, uint8_t *out, size_t cap);

/* Whether text the caller ALREADY HOLDS is a clip the wire will carry. The attended door: a
 * platform that refuses an unattended read hands its push half the text on the paste the user
 * asked for, and re-reading the board would spend a permission already spent. */
bool slopdesk_clipboard_text_is_shippable(const uint8_t *text, size_t text_len);

/* Writes a wire clip onto the board; false — board UNTOUCHED — for non-UTF-8 text, PNG bytes that
 * will not decode, or an unknown future kind. Every refusal happens BEFORE anything is cleared. */
bool slopdesk_clipboard_write(const uint8_t *name, size_t name_len, uint8_t kind,
                              const uint8_t *bytes, size_t bytes_len);

/* The client's one "copy" funnel: replace the board with `text`. false — board UNTOUCHED — for
 * empty text. Carries no kind byte and owes no cap: nothing is shipping it anywhere. */
bool slopdesk_clipboard_write_text(const uint8_t *name, size_t name_len, const uint8_t *text,
                                   size_t text_len);

/* The same funnel for a captured FRAME, in any format the system decoder reads — the two device
 * panels hand it PNG and JPEG. false — board UNTOUCHED — for bytes that are not an image, which is
 * how a caller tells a truncated capture from a successful copy. */
bool slopdesk_clipboard_write_image(const uint8_t *name, size_t name_len, const uint8_t *bytes,
                                    size_t bytes_len);

/* Drops everything on the board. One caller: a suite opening its per-process board, because a pid
 * the system reused hands back whatever the LAST run of that pid left there. */
void slopdesk_clipboard_clear(const uint8_t *name, size_t name_len);

/* ---- fuzzy: how a typed query ranks against one candidate ------------------------------- */

/* fzf's `FuzzyMatchV2` (`rust/slopdesk-fuzzy`). The answer is `[int32 BE score][uint32 BE pos]*`
 * over the candidate's Unicode scalars — one call for the size, one for the bytes. 0 means the
 * candidate does not carry the query in order; an empty query is a 4-byte match with score 0. */
size_t slopdesk_fuzzy_score(const uint8_t *query, size_t query_len, const uint8_t *candidate,
                            size_t candidate_len, uint8_t *out, size_t cap);

/* The same ranking without the positions — for a list that sorts by score and underlines only the
 * rows it draws. Skips fzf's phase 4, so there is no buffer, no second call and no allocation on
 * either side. `-1` is "no match"; a score is never negative, so the two cannot collide. */
int64_t slopdesk_fuzzy_rank(const uint8_t *query, size_t query_len, const uint8_t *candidate,
                            size_t candidate_len);

/* ---- watch: what the host and the client READ back out of what it printed --------------- */

/* The DECISION and the BYTES both left with the wrapper: `slopdesk watch` is Rust and calls
 * slopdesk-agent::watch and slopdesk-wire::osc directly, so eleven doors that existed only for the
 * Swift face are gone. What crosses is the READING half — the host's byte reader parses a progress
 * body, and the client's notification router recognises the finish sentinel. */
bool slopdesk_osc_parse_progress(const uint8_t *body, size_t body_len, uint8_t *state,
                                 uint8_t *percent);
size_t slopdesk_watch_notification_marker(uint8_t *out, size_t cap);
// The parse-back of the builder above: whether a notification's title IS that sentinel, which is
// what routes the banner to the watch toggle rather than the master switch.
bool   slopdesk_watch_notification_is_marked(const uint8_t *title, size_t title_len);

typedef struct {
  size_t datagram_count;
  size_t total_len;
} SlopDeskRetransmitSelection;





#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_TERMINAL_H */
