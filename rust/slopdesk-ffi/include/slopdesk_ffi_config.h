// slopdesk_ffi_config.h — the config file, the command palette, and the whole keybinding table
//
// One part of `slopdesk_ffi.h`, which includes it. That umbrella is the module header and the only
// one Swift ever names; every convention the doors here obey — (out, cap) -> needed, the handle
// rules, what a NULL pointer means — is stated there once and not restated per part.

#ifndef SLOPDESK_FFI_CONFIG_H
#define SLOPDESK_FFI_CONFIG_H

#include <TargetConditionals.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- The config FILE ----
//
// There is no settings window. Every setting has a best-by-default answer compiled into
// `slopdesk-settings::config::table`, and the only way to disagree with one is a line in
// `config.toml`. Three doors, all cold — one at launch, one per reload, one when the CLI is asked
// for the schema. None of them is called from a draw.
//
// The rules live over there; what is here is the marshalling PLUS the file read itself, which stays
// on the far side for the same reason every other effect does. The near side never opens the file,
// parses TOML, or holds a default of its own.

// The resolved config-file path. `explicit` is the caller's override — empty on macOS, and on iOS
// the app's own Documents directory, which is the only place the file can be reached from the Files
// app. When it is empty the real environment decides: `SLOPDESK_CONFIG_FILE`, then
// `XDG_CONFIG_HOME`, then `HOME`, then the lent `fallback` home.
size_t slopdesk_config_path(const uint8_t *explicit_path, size_t explicit_len,
                            const uint8_t *fallback, size_t fallback_len,
                            uint8_t *out, size_t cap);

// The whole resolved configuration as ONE JSON object, read from the file at `path`:
//
//   {"flag":{…},"int":{…},"float":{…},"text":{…},"list":{…},
//    "keybind":{…},"env":{…},"diagnostics":[…]}
//
// Five maps BY TYPE rather than a nested document, because the near side's reads are typed: a
// dotted key names a value whose Swift type is already known at the call site, so a tree would only
// be re-flattened there. Every declared key appears, defaults included — the near side holds no
// fallback of its own. A missing file resolves to the defaults with NO diagnostic; an install
// without a config file is the supported shape, not a lesser one.
size_t slopdesk_config_snapshot(const uint8_t *path, size_t path_len, uint8_t *out, size_t cap);

// The JSON Schema (draft 2020-12) for the config file, generated from the same table the snapshot
// resolves against. `additionalProperties: false` at every declared level, so a typo is an error
// where the user typed it. What `slopdesk config schema` prints, and what `docs/config.schema.json`
// is checked against.
size_t slopdesk_config_schema(uint8_t *out, size_t cap);

// Makes `path` openable: its directory, `config.schema.json` beside it, and a starter file if there
// is none. `true` when the starter was SEEDED — the rest is idempotent and says nothing.
//
// The reader's own file is never rewritten; the schema always is, because a schema from an older
// build completes keys the running one no longer has. The starter text is the far side's, not a
// literal on this one: what a fresh install SAYS is a policy about the table, and it says nothing
// about any key on purpose — a file pre-filled with defaults pins today's answers forever.
//
// Best-effort: a home that cannot be written leaves the caller exactly where it would have been.
bool slopdesk_config_prepare(const uint8_t *path, size_t path_len);

// The env var that overrides the config-file location, for the one caller that prints where the
// path came from. Everything else asks `slopdesk_config_path`, which has already applied it.
size_t slopdesk_config_env_key(uint8_t *out, size_t cap);

// ---- Which half lists a command-palette VERB ----
//
// The same "a platform gate is DATA" rule as the settings table below, applied to the one surface
// whose whole job is to tell the user what the app can do. Every actuator on the palette's
// coordinator defaults to an empty closure and a `.store` row's run arm may be a macOS-only `#if`
// with nothing in the else, so a row that is listed and INERT is indistinguishable from one that ran
// and had nothing to do. Three of the phone's rows were exactly that.
//
// `shown` rather than `platform` on purpose: the near side already knows which slice it is, and what
// it must never do is turn that back into an `#if` around a row. The count/index pair exists so a
// test can walk this table and prove it names the same verbs the Swift catalog does — an id declared
// on only one side is the failure that would put the hole back.
//
// An id no row declares is SHOWN. A typo must not delete a row without a word;
// `just lint-invariants` is what makes an undeclared id impossible.
bool slopdesk_palette_row_shown(const uint8_t *id, size_t len, bool mac);
size_t slopdesk_palette_row_count(void);
size_t slopdesk_palette_row_id(size_t index, uint8_t *out, size_t cap);

// ---- The WHOLE keybinding table (docs/64) ----
//
// This used to be three doors carrying ONE column of a row — which half lists it — while the other
// six lived in a Swift array literal that `just lint-invariants` held equal to the Rust one with a
// regex on each side. That is a join maintained by hand across a language boundary, so the whole row
// crosses now and the Swift side has no table to drift from.
//
// The platform column is still the load-bearing one, and the reason is unchanged: the registry is
// not one list — it is the cheat sheet, the keybindings editor, the `ctl` verb list, and the CHORD
// TABLE the dispatcher resolves against. That last one is why a listed-and-inert binding is worse
// than a listed-and-inert palette row: a bound chord does not reach the terminal, so ⌥⌘P was taken
// away from the PTY to run a macOS-only `#if` with nothing in its else. Dropping the row drops the
// chord, and the key falls through to the pane the way an unbound chord should.
//
// A SECOND table rather than one shared with the palette because these are two id spaces over two
// vocabularies with partial overlap in both directions (`pane.detach` here is `action.detachPane`
// there; ~45 rows here have no palette entry at all).
//
// THREE doors answer the whole table in one crossing each, because the registry walks them once
// building a `static let` and never again — and nothing on the per-keystroke path comes through
// here at all (the chord lookup is a Swift hash over the assembled table). The scalars cross as
// records; the four strings per row cross as one length-prefixed blob in row order, cut by `wsRuns`.
typedef struct {
    uint16_t action;           // the WorkspaceAction tag — its case POSITION
    int16_t  chord_named;      // the named-key index, or -1 for a printable key
    int32_t  arg;              // the action's payload, or 0; only selectPane uses it
    uint32_t chord_char;       // the printable key's scalar; meaningless unless chord_named is -1
    uint8_t  category;         // 0 panes · 1 tabs · 2 focus · 3 view
    uint8_t  chord_modifiers;  // shift 1 · control 2 · option 4 · command 8
    uint8_t  kind;             // 0 a declared row · 1 the collapsed ⌘1…⌘9 representative
    bool     has_chord;
    bool     shown;            // does the half that ASKED list this row
} SlopDeskWsBindingRow;

// A second chord that fires an existing action without minting a display row.
typedef struct {
    uint16_t action;
    int16_t  chord_named;
    uint32_t chord_char;
    uint8_t  chord_modifiers;
} SlopDeskWsBindingAlias;

size_t slopdesk_ws_binding_count(void);
size_t slopdesk_ws_binding_rows(bool mac, SlopDeskWsBindingRow *out, size_t cap);
size_t slopdesk_ws_binding_text(uint8_t *out, size_t cap);
size_t slopdesk_ws_binding_aliases(SlopDeskWsBindingAlias *out, size_t cap);
// A tag this build does not know answers false — the palette LISTS such a row rather than hiding it.
bool slopdesk_ws_action_requires_active_pane(uint16_t action);

// ---- The keybindings editor's search filter ----
//
// The editor filters the whole registry on every keystroke, and until this entry existed it did so
// with `lowercased().contains(_:)` per field per row. That is the wrong primitive and Swift has no
// cheap one: measured against the shipped xcframework, `lowercased()` is 94ns and the `contains`
// over its result is 825ns for a 35-byte title and 1,652ns for a 70-byte keyword run — grapheme-
// aware search over text that is ASCII. The same containment as a byte scan is 29ns and 53ns.
// Four spellings across eighty-five rows came to 415us per keystroke.
//
// The ROWS are lent rather than held on the far side, which is the one thing here that is not the
// settings table's shape. A binding's title and keywords are written beside the `WorkspaceAction`
// case the row routes to; moving them across would put a crossing in front of every cheat-sheet,
// menu and palette row that reads a title today. So the caller marshals its four spellings per row
// into one blob and this answers which rows a query keeps.
//
// `records` is `[u32 count]`, then `count` records, each `[u8 field_count]` then that many
// `[u32 len][len bytes]` fields, little-endian. A binding lends four: title, keyword run, chord
// glyph, chord canonical — the last two empty for a row with no chord. The answer is POSITIONS in
// that list, the way the settings filter answers positions in its own table.
//
// `needed > cap` means nothing was written; ask again at that size. `0` is no row matched, which is
// also what a non-UTF-8 query and a torn record list answer — all three end at an empty list, and
// the near side writes the list itself, so a fourth reading would be a distinction no caller could
// act on.
size_t slopdesk_ws_binding_row_matches(const uint8_t *query, size_t query_len,
                                       const uint8_t *records, size_t records_len,
                                       size_t *out, size_t cap);

// ---- What the phone's keyboard sends ----
//
// A touch device is forced to split physical input in two: the keys a terminal needs raw, and
// anything a multi-stage composition could be part of. Every door below is one side or the other of
// that split, and none of them holds the terminal's mode — the caller reads that off the live model
// per press, because the program that set it is on the far side of the PTY.
//
// The flag word IS `KeyChord.Modifiers`' own bits 0-3, so a chord's modifiers cross back out
// untranslated. Nothing above them is a modifier: which keys are special is a rule, and it is
// answered on the far side from `hid_usage`.
#define SLOPDESK_PHONE_KEY_SHIFT   (1u << 0)
#define SLOPDESK_PHONE_KEY_CONTROL (1u << 1)
#define SLOPDESK_PHONE_KEY_OPTION  (1u << 2)
#define SLOPDESK_PHONE_KEY_COMMAND (1u << 3)
// Bits 4-5 are the one thing in this word that is not a modifier: `controls.optionAsAlt`, which is a
// property of the KEYBOARD rather than of the press, and the only setting either encoding door
// reads. It rides the word that already crossed because a new parameter would change the signature
// of two doors for a value neither caller computes per-press.
//
// BOTH is ZERO on purpose, and it is the one value here that is not free to be reordered: these bits
// EXTEND a word that had four, so an absent pair has to read as what the doors did before the pair
// existed, which was to treat the Option key as Alt/Meta unconditionally. Making OFF the zero would
// silently withdraw Alt from any caller that had not yet learnt to set the bits.
//
// A phone reads LEFT and RIGHT the same way it reads BOTH: `UIKey.modifierFlags` carries one
// `.alternate` bit and no side, so a side-specific choice cannot be honoured, and reading it as OFF
// would take away the meta the reader asked for while reading it as BOTH costs only the accented
// character on the side they left free.
#define SLOPDESK_PHONE_KEY_OPTION_AS_ALT_MASK  (3u << 4)
#define SLOPDESK_PHONE_KEY_OPTION_AS_ALT_BOTH  (0u << 4)
#define SLOPDESK_PHONE_KEY_OPTION_AS_ALT_OFF   (1u << 4)
#define SLOPDESK_PHONE_KEY_OPTION_AS_ALT_LEFT  (2u << 4)
#define SLOPDESK_PHONE_KEY_OPTION_AS_ALT_RIGHT (3u << 4)
// The `named` a chord writes when its key is the printable scalar in `character` instead.
#define SLOPDESK_PHONE_KEY_NAMED_NONE ((uint8_t)0xFF)
// A key a MODE reads as a command rather than as input — Copy Mode and Hint Mode, the two places a
// pane answers keys instead of forwarding them. Six of the twenty-six special keys carry a meaning
// there; everything else, special or not, reaches the mode as its CHARACTER, which is what
// SLOPDESK_PHONE_MODAL_NONE says.
#define SLOPDESK_PHONE_MODAL_ESCAPE    ((uint8_t)0)
#define SLOPDESK_PHONE_MODAL_ENTER     ((uint8_t)1)
#define SLOPDESK_PHONE_MODAL_BACKSPACE ((uint8_t)2)
#define SLOPDESK_PHONE_MODAL_UP        ((uint8_t)3)
#define SLOPDESK_PHONE_MODAL_DOWN      ((uint8_t)4)
#define SLOPDESK_PHONE_MODAL_LEFT      ((uint8_t)5)
#define SLOPDESK_PHONE_MODAL_RIGHT     ((uint8_t)6)
#define SLOPDESK_PHONE_MODAL_NONE      ((uint8_t)0xFF)

// One `UIKey`: which key (`UIKey.keyCode`, a USB HID keyboard usage — the only signal that means the
// same thing under every layout and input method) and what that key produces under this layout
// (`base` = `charactersIgnoringModifiers`, which is what a ⌃ fold and a binding lookup are about).
// What the key COMMITTED is deliberately absent — for a special key it is noise, and for a printable
// one the proxy inserts it.
typedef struct {
    const uint8_t *base;
    size_t         base_len;
    uint16_t       hid_usage;  // 0 = none
    uint32_t       flags;      // SLOPDESK_PHONE_KEY_*
} SlopDeskPhoneKeyPress;

// Whether this press is encoded here rather than passed on to the text input path. A special key — every key
// with no printable output, Esc/Tab/Return/Delete and the whole nav and function block — or any of
// ⌃⌥⌘ is encoded; everything else is typing, ⇧ and a bare space included.
bool slopdesk_phone_key_routes_to_encoding(const SlopDeskPhoneKeyPress *press);
// Which PHYSICAL key this press names, as one opaque token — what the key-repeat latch holds.
//
// NOT the press. UIKit samples the modifier flags separately for pressesBegan and pressesEnded, so a
// user who holds ⌃L and lifts ⌃ first releases an L whose control bit is already clear. Latch the whole
// press and that release matches nothing, the repeat is never cancelled, and the pane takes ⌃L at 20 Hz
// until another key is pressed. A usage is a physical key under every layout and answers alone; a key
// UIKit gives no usage for hashes its layout-independent characters with the top bit set, above every
// 16-bit usage there is. `0` only for a null record.
uint64_t slopdesk_phone_key_press_identity(const SlopDeskPhoneKeyPress *press);
// The bytes this press sends, through `(out, cap)`. `0` means it sends nothing — bare typing, which
// is the proxy's, or a ⌘ combination, which is an app shortcut. No key this encoder resolves sends
// zero bytes, so the length is unambiguous. `application_cursor_keys` is the live DECCKM bit, which
// picks SS3 over CSI for the cursor block (the four arrows, Home and End) and nothing else.
size_t slopdesk_phone_key_encode(const SlopDeskPhoneKeyPress *press, bool application_cursor_keys,
                                 uint8_t *out, size_t cap);
// The chord this press makes, for the SAME user-overridable binding table the Mac's dispatcher
// reads. `named` is a `KeyChord.Key` case index or SLOPDESK_PHONE_KEY_NAMED_NONE, `character` the
// printable scalar in that case, `modifiers` bits 0-3. `false` leaves all three untouched: every
// field of a chord is a legitimate zero, so a length could not have said "not a chord".
bool slopdesk_phone_key_chord(const SlopDeskPhoneKeyPress *press, uint8_t *named,
                              uint32_t *character, uint8_t *modifiers);
// The modal key one HID usage is — a SLOPDESK_PHONE_MODAL_* value. A USAGE rather than a whole
// press, because nothing about this answer reads the layout or the modifiers: `⌃v` in copy mode is
// the visual-block key, not an Escape, so the modes take the modifier state off the press
// themselves and ask this only "which key is it".
uint8_t slopdesk_phone_modal_key(uint16_t hid_usage);
// The accessory bar's armed ⌃ folding a soft-keyboard commit: the first scalar's control byte
// through `code`, the byte offset its remainder starts at through `rest`. `false` for empty text.
bool slopdesk_phone_key_fold_control(const uint8_t *text, size_t len, uint8_t *code, size_t *rest);

// The keyboard height at which the on-screen keyboard is the SOFTWARE one — a hardware keyboard
// leaves only a thin shortcut bar, and the ⌃/Esc/Tab/arrow row is only worth its space above this.
double slopdesk_phone_accessory_threshold(void);
bool slopdesk_phone_shows_accessory_bar(double keyboard_height, double threshold);

// The floating cursor: long-pressing the space bar and dragging, which on a phone with no hardware
// keyboard is the ONLY way to move the terminal cursor. `accumulated` is read AND written — the
// sub-threshold remainder is what makes a slow drag of many small deltas total correctly.
double slopdesk_phone_floating_cursor_threshold(void);
// The most bytes one feed can answer with — the arrow cap times the escape width, both of which are
// this side's to tune. A caller sizes its buffer at this rather than multiplying them out itself.
size_t slopdesk_phone_floating_cursor_run_capacity(void);
size_t slopdesk_phone_floating_cursor_feed(double *accumulated, double threshold, double delta_x,
                                           bool application_cursor_keys, uint8_t *out, size_t cap);
// The same answer as a SIGNED COUNT — negative leftward — for the caller whose cursor is not behind
// a PTY: while the app's own line editor owns the prompt there is no shell to send `ESC [ C` to, and
// the drag has to arrive as the editing verb an arrow PRESS does. Exactly one of the two doors is
// called per delta; each CONSUMES the travel it reports.
int32_t slopdesk_phone_floating_cursor_steps(double *accumulated, double threshold, double delta_x);

// The tiled tree, as its PRE-ORDER walk rather than as its persisted JSON. Both languages already
// agree on that JSON, and reusing it here would have been two lines — but `solve` runs on every
// layout pass, and a parse plus an allocation per frame is the kind of regression that vetoes a
// port. One array, one pass, no parse; the persisted codec stays what it is for, which is disk.
//
// Each node says how many DIRECT children follow it. A well-formed array is consumed exactly; a
// `child_count` that overruns, or a truncated tail, stops the walk and answers nothing rather than
// reading past the end — which matters here because a tree can arrive from a peer.
typedef struct {
    uint8_t        kind;  // 0 leaf · 1 split (anything else reads as a leaf)
    SlopDeskWsUuid id;    // a leaf's pane id, or a split's divider-group id
    uint8_t        axis;  // 0 horizontal (columns) · 1 vertical (rows)
    bool           weight_is_fixed;
    uint32_t       child_count;
    double         weight;  // this node's share WITHIN its parent; the root's is ignored
} SlopDeskWsTreeNode;

// One child's share, as the weights codec reads and writes it.
typedef struct {
    bool   is_fixed;
    double value;
} SlopDeskWsShare;

// The default floor on a solved leaf, as (width, height).
SlopDeskWsPoint slopdesk_ws_min_leaf(void);

// 0 = a tree the walk could not rebuild, which is the same answer an empty tree gives.
size_t slopdesk_ws_solve_layout(const SlopDeskWsTreeNode *nodes, size_t count,
                                SlopDeskWsRect rect, double min_width, double min_height,
                                SlopDeskWsFrame *out, size_t cap);
// One draggable seam. The rect is what is drawn and hit; everything after it is what a DRAG needs
// — the span it converts pixels against, the flex sum it converts them into, and the pair of
// weights it moves between. A `0` weight is a FIXED child, which is not draggable at all.
typedef struct {
    SlopDeskWsUuid split;
    uint32_t       child_index;  // the LEADING child: the seam is between it and the next
    uint8_t        axis;         // 0 horizontal (a column seam, dragged left/right) · 1 vertical
    SlopDeskWsRect rect;
    double         parent_span;  // a NESTED split's own length, so the drag tracks the cursor 1:1
    double         flex_sum;
    double         leading_weight;
    double         trailing_weight;
} SlopDeskWsDivider;

// The band a seam is drawn and hit with — wide enough to grab, so the drawn hairline can be thinner.
double slopdesk_ws_divider_thickness(void);
// Every seam of the tree, in pre-order. 0 = a tree the walk could not rebuild, which is the same
// answer a lone leaf gives: nothing to drag.
size_t slopdesk_ws_dividers(const SlopDeskWsTreeNode *nodes, size_t count, SlopDeskWsRect rect,
                            double thickness, SlopDeskWsDivider *out, size_t cap);
// The hover cursor's one-way-vs-two-way answer, from the same pixel floor the drag clamps at — so
// the arrow the person sees and the seam they get can never disagree.
bool   slopdesk_ws_divider_can_move(SlopDeskWsDivider handle, bool toward_leading);
// A live drag's proposed leading weight, clamped so BOTH panes keep that floor. Sum-preserving,
// and a pair too tight for two floors can only be dragged toward balance.
double slopdesk_ws_divider_clamped_weight(SlopDeskWsDivider handle, double proposed);
// One incremental pixel drag along the seam's axis, as the weight delta to offset from:
// `Δpixel / parent_span * flex_sum`, the inverse of a flex child's `extent = weight/flex_sum*span`.
// The span and the flex sum come out of the HANDLE, so one split's span can never be paired with
// another's partition — drop the flex-sum factor and a 50/50 seam trails the cursor at half speed.
// A handle without geometry answers 0, and the drag then sends nothing.
double slopdesk_ws_divider_weight_delta(SlopDeskWsDivider handle, double pixel_increment);
// The live drag's ratio readout, as whole percentages that sum to exactly 100. False is a
// degenerate pair — a fixed side reports weight 0 — and then neither out-param is touched: the cue
// is ABSENT rather than wrong. Both numbers cross, so no caller rounds the complement itself.
bool   slopdesk_ws_divider_percents(SlopDeskWsDivider handle, uint32_t *leading, uint32_t *trailing);

// ---- What a split tab draws once zoom has had its say ------------------------------------------
//
// The partition is already `slopdesk_ws_frames` / `slopdesk_ws_dividers`. What crosses here is the
// layer above: whether a zoom is IN EFFECT, and what the frame looks like while one is. A zoom
// naming a pane that has since been closed is IGNORED — honouring it collapses the tab onto a pane
// that does not exist.

// One placed pane, and whether the zoom is hiding it. The hidden ones are the point: a pane the
// renderer stops emitting is a pane the view unmounts, and unmounting one dismantles the terminal
// surface or video stream behind it. So EVERY pane of the tab comes back on every layout and this
// flag is what the view draws at `opacity 0` instead.
typedef struct {
    SlopDeskWsFrame frame;
    bool            hidden;  // mounted and laid out at its UN-zoomed rect, not drawn
} SlopDeskWsRenderLeaf;

// Whether the tab is zoomed: `zoomed` is named AND is a leaf of this tree.
bool   slopdesk_ws_zoom_is_active(const SlopDeskWsTreeNode *nodes, size_t count,
                                  bool has_zoom, SlopDeskWsUuid zoomed);
// Every pane of the tab, zoom applied: the zoomed leaf at full bounds and its siblings at their
// solved rects flagged `hidden`, or the plain tiled solve when no zoom is in effect.
size_t slopdesk_ws_render_leaves(const SlopDeskWsTreeNode *nodes, size_t count,
                                 SlopDeskWsRect rect, double min_width, double min_height,
                                 bool has_zoom, SlopDeskWsUuid zoomed,
                                 SlopDeskWsRenderLeaf *out, size_t cap);
// The seams — none at all while a zoom is active. The gate lives HERE rather than at the call site,
// because a renderer deciding it for itself would be a second copy of the zoom verdict sitting
// where nobody would look when the first copy changed.
size_t slopdesk_ws_render_dividers(const SlopDeskWsTreeNode *nodes, size_t count,
                                   SlopDeskWsRect rect, double thickness,
                                   bool has_zoom, SlopDeskWsUuid zoomed,
                                   SlopDeskWsDivider *out, size_t cap);

// ---- The GUI pane's clipboard affordances ------------------------------------------------------
//
// The MASK and the LIMITS cross; the CLIP never does. A row carries the full text so it can be
// typed and a masked label so it can be drawn — the ring is the caller's OWN clipboard history, so
// sending the clips back would hand somebody their own secrets for nothing. The caller zips the
// labels against the prefix it asked about.
//
// A row is `[flag byte][label UTF-8]` inside one length-prefixed run, so the verdict and the label
// are ONE classification: two doors could disagree and draw a masked row that pasted as ordinary
// text.

// Max characters of a non-secret preview before it is ellipsized.
size_t slopdesk_ws_paste_preview_limit(void);
// How many recent clips the ring submenu lists.
size_t slopdesk_ws_paste_row_limit(void);
// One clip's preview: `[u32 BE length][flag byte][label UTF-8]`. Never 0 — the flag byte is always
// there, so a length of 1 is an EMPTY label (a whitespace-only clip) rather than an absent answer.
size_t slopdesk_ws_paste_preview(const uint8_t *bytes, size_t len, uint8_t *out, size_t cap);
// Every row of the submenu, in ring order. `ring` is `count` length-prefixed clips
// (`[u32 BE length][UTF-8]` each); the answer is `min(count, limit)` runs of the same
// `[u32 BE length][flag byte][label]` shape.
size_t slopdesk_ws_paste_rows(const uint8_t *ring, size_t ring_len, size_t count, size_t limit,
                              uint8_t *out, size_t cap);
// Whether "Paste as Keystrokes" is enabled. A BOOL, not the content: on iOS, reading the clipboard
// from a renderer raises the modal "Allow Paste?" alert, so enablement must be answerable without
// it.
bool   slopdesk_ws_paste_can_paste(bool can_paste_keystrokes, bool clipboard_has_text);
// Whether a clip already in hand is worth typing: present, and not only whitespace. A null pair and
// an empty one both answer false — an absent clipboard and an empty one are the same nothing to
// this question.
bool   slopdesk_ws_paste_is_pastable(const uint8_t *bytes, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* SLOPDESK_FFI_CONFIG_H */
