# 68 — The terminal surface becomes ours

The client stops embedding a terminal *application* and starts driving a terminal *engine*. libghostty's
surface API — which owns its own Metal renderer, its own IO thread and its own grid layout — is
replaced by `libghostty-vt`, the renderer-agnostic half, through the MIT Rust bindings. The pixels
become this repo's, and with them the one thing an opaque surface can never give up: **layout**.

Read `docs/20-wire-protocol.md` (unchanged by this document — see §7), `docs/55-ffi-boundary.md` for
the artifact rule, `docs/57-apple-frameworks-in-rust.md` §2 for what `slopdesk-apple-*` may do, and
`ThirdParty/ghostty/README.md` for the fork this deletes.

## 1. What this supersedes

`DECISIONS.md` fixes "Renderer = **libghostty** (full surface) … No fallback paths to maintain",
`docs/17:40` picks the external-IO surface as the way to get it, and
`Sources/SlopDeskWorkspaceCore/Terminal/TerminalRendererSeam.swift:56` restates it at the seam. That
ruling stands for the *engine* and is strengthened here: ghostty still parses every byte. What it no
longer covers is the *renderer*, because the renderer is what has to go for the product to reach the
surface it wants.

`docs/17:59` is the one nearby ruling that could be misread as reversed, and is not. It rejects a
**second** VT parser — a shadow framebuffer beside libghostty's, kept for latency prediction, whose
cost was desync between two parsers. Nothing here adds a parser: `libghostty-vt` *replaces* the
fork's, one engine before and one after, and no prediction is built on it.

Two memory rulings are folded in and neither is reversed:

- **"Underline by the cell's ANSI colour", rejected because "no C ABI exposes cell colour."** The
  technical half was falsified 2026-08-28 and is now falsified in the tree: `libghostty-vt`'s
  `style.rs` carries `Style { fg_color, bg_color, underline_color, … }` with
  `StyleColor::{None, Palette, Rgb}`. Whether the design still wants it is a separate question this
  document does not answer.
- **"Zig 0.16, rejected — pinned 0.15.2."** That rejection was about porting *our fork* to 0.16: a
  462-file breaking migration (`std.ArrayList` unmanaged, Writergate, `EnvMap`) that upstream itself
  has not done on macOS (upstream issue #12726). It is untouched. This document deletes the thing
  that needs 0.15.2 rather than porting it, and Zig 0.16.0 is already the machine's `zig`.

## 2. Why the surface API cannot reach the product

The goal is a block-based, editor-like terminal. The discriminating fact is not performance and not
feature coverage — it is **who owns layout**.

An overlay over an opaque surface can do **decoration**, and this tree already does:
`DecorationPromptFlash` paints row-anchored rects from `PromptJumpFlashGeometry` over the
`IOSurfaceLayer` libghostty installs. That is the ceiling of the technique — a flash, a highlight, an
underline.

Blocks are **layout**, not decoration: collapsing a command's output, padding between blocks, rows of
differing height, a native action bar between two blocks, a sticky header. The surface's grid layout
is a function of terminal state the embedder does not own, and `ghostty_surface_draw` composites the
whole grid into one layer. There is no seam to insert a view into, at any price.

With `libghostty-vt` the client holds the grid and draws it, so a block is an ordinary AppKit/UIKit
layout problem. That is the whole argument; everything below is cost.

## 3. Verifications taken before anything was deleted

**V1 — the iOS slices build. PASS, and this was the gate on the entire design.** Today's fork ships
macos-arm64 + ios-arm64 + ios-arm64-simulator out of `build-libghostty.sh` (641 lines, an `xcrun` SDK
shim, a pinned toolchain download). The question was whether `libghostty-vt-sys` cross-builds, or
whether that recipe has to be written again.

```
cargo build --target aarch64-apple-ios       → Finished in 3m 55s
cargo build --target aarch64-apple-ios-sim   → Finished in 56s
lipo -info …/ghostty-install/lib/libghostty-vt.a
    → architecture: arm64
otool -l  …/libghostty-vt.a
    → LC_BUILD_VERSION  platform 2 (iOS)  minos 13.0
```

`build.rs` drives Zig itself, emits `cargo:rustc-link-lib=static=ghostty-vt`, and brings `libsimdutf.a`
and `libhighway.a` with it. **No build recipe is ours to write.** The 641-line script, the SDK shim
and the `.toolchain/` download all go.

**V2 — the build must not touch the network.** `libghostty-vt-sys/build.rs` clones ghostty at a pinned
commit at compile time, which is incompatible with the content-stamped gates (`slopdesk-gate ffi`) and
with a reproducible release. The escape hatch is authoritative and short-circuits the fetch:

```rust
if env::var_os("GHOSTTY_SOURCE_DIR").is_some() { build_vendored(link_mode); return; }
```

So the fetch becomes ours. **LANDED**, and not as a recipe: the pin joined the file that already
pins every other third-party dependency, and the export joined the file cargo already reads.

- `ThirdParty/tools/tools.lock` gains a fourth kind, `git` — a SOURCE tree cloned at a pinned
  commit, with no binary and no `.prefix/bin` symlink, because a source tree is not a program. Its
  digest field is the 40-hex COMMIT rather than a SHA-256, which is the stronger pin: git is
  content-addressed over the whole tree, and GitHub's generated archives are explicitly not
  guaranteed byte-stable, so a tarball digest is the one thing this must NOT be. `slopdesk-provision`
  clones with `init` + `fetch --depth 1 <sha>` + `checkout FETCH_HEAD` and then asks the clone what
  commit it is actually at.
- `rust/.cargo/config.toml` exports `GHOSTTY_SOURCE_DIR` through cargo's own `[env]` with
  `relative = true`. **Not a `just` recipe**: a recipe can only export into the command it launches,
  and these crates are built by bare `cargo` as often as by `just` — an env var that is only right
  under one entry point is exactly the shape that produces a build nobody else can reproduce.
- `GHOSTTY_ZIG_SYSTEM_DIR` is left unset. It overrides Zig's own system package directory and there
  is nothing to override: the machine's `zig` is already 0.16.0, which is what this pin needs.

The two files are held in step by `just lint-invariants` → `engine-source-read-at-its-pin`, because
nothing else does and the drift is silent: bump the lock without the config and `just provision`
fetches the new tree while every build keeps compiling the previous one still on disk — same
directory, same `build.zig`, same successful link, wrong sources. That is
`slopdesk-gate ffi --check`'s failure shape one layer down.

`build.rs` also returns early under `CARGO_CFG_MIRI`, so `just check`'s Miri gate keeps working
without a native library.

**V3 — baselines, measured before the old renderer is deletable. PARTIAL, and the shortfall is
ruled on.** A measured regression is the only veto (`CLAUDE.md`). Parse throughput is measurable on
both engines and is in §6; the live fork's **key→render-feed latency is pinned in §6.3** by a gate
that re-runs unchanged on the new renderer. Draw cadence is **not** baselined — §6.3 says what
blocked it and why resurrecting the fork later is the wrong answer. The demolition proceeds on that
reading.

## 4. What ships free, and what is ours

Verified against `Uzaaft/libghostty-rs` @ `a0b5a46`, MIT, pinning ghostty `22d13172`.

We now build on an org-hosted mirror of it, `aislopware/libghostty-rs` @ `519649e`, and the single
divergence is soundness.
Upstream's `ClipboardContent` handed over a `&str` built with `from_utf8_unchecked` over an OSC 52
payload, and `ClipboardWrite::contents` sliced a null pointer for the "clear the clipboard" shape —
both reachable by any program on the pty, both tracked by upstream's own issue #75, and both
reproduced by the two `cfg(miri)` tests their PR #76 added, which FAIL at `f4c72b9`. The fork is
`f4c72b9` plus one commit that flips them to pass: a null-guarding `String::to_bytes`,
`ClipboardContent::data` typed `&[u8]`, and a validated `mime`. `slopdesk_vterm::events::preferred_text`
is where those bytes become a `String` or are declined. The commit is upstreamable as it stands and
the pin goes home when #75 closes; the bindings are still generated against ghostty `22d13172`, so
no engine bump rode along.

| | |
| --- | --- |
| **Dissolves** | `ghostty_app_new/tick/free`, `ghostty_init`, the `surface_new/free` lifecycle, `write_callback`/`resize_callback` and the whole `ghosttyOnMainActor` thread-hop, the `External.zig` backend (a fork-only patch upstream closed unmerged), the 2 347-line consolidated patch, `build-libghostty.sh`, the xcframework recipe, the `.toolchain/` download, the `xcrun` SDK shim, and upstream bug #13021 (iOS Metal-teardown UAF) — a renderer bug we stop having |
| **vt already has** | parse + grid + scrollback · per-cell `Style`/`sgr` · **selection, richer than what we call today** · `RenderState` with per-row damage bits · cursor visible/blinking/visual-style/password/colour/viewport · `colors()` · `KeyEncoder`/`MouseEncoder` · `osc.rs` (OSC 22 pointer, OSC 52 clipboard) · bracketed `paste.rs` · `focus.rs` · kitty graphics state · `unicode.rs` widths · `compress()` (upstream PR #13264's 70–90 % scrollback savings, which our v1.3.1 pin cannot reach) · `continuation_*` session serialisation |
| **Ours to build** | the glyph renderer (§5) · grid search (§5.2) · the config/keybind layer that `ghostty_config_*` and `ghostty_surface_binding_action` used to answer |

**Selection is a gain, not a gap.** The six selection doors we call today (`set`/`has`/`clear`/
`read_selection`, `read_text`, `selection_s`) map onto a richer model: `Gesture` for click-drag,
`select_word`, `select_line`, `select_output`, `select_word_between`, rectangle selection, `adjust`,
and `format_selection` with `unwrap`/`trim`. `SelectLineOptions::with_semantic_prompt_boundary` is
OSC 133-aware — the same boundary `rust/slopdesk-terminal/src/blocks.rs` derives by re-parsing.

### 4.1 The two pushes the surface drains, and the three that are the host's

Five things the far side does are not about the grid and vanish when the parser moves on: the reply
the terminal owes the pty (`CSI 6n`, `CSI c`, `CSI > q`, `OSC 10/11/4 ?`, the in-band size report),
an OSC-52 clipboard write, the bell, an OSC-777 notification, an OSC-9;4 progress report. A pull-only
door cannot ask for them after the fact, because by then they are gone.

**Only the first two are drained here, and the split is not arbitrary.** The bell, the notification,
the progress report — and the OSC 0/2 title and the OSC-7 cwd, which the engine also sees — already
arrive as their own wire messages from the host sniffer, and `TerminalViewModel.handle(_:)` folds
each one. Draining them here as well would be a second implementation of the same fact, which this
tree forbids, and it would be the WORSE one for two reasons the client cannot fix locally:

- **Multiclient.** One pane can have several clients attached (`docs/45`). The host's detection is
  one verdict all of them share; client-side detection is N verdicts that drift.
- **Replay.** `TerminalViewModel.attachSurface` re-feeds the retained output ring into a rebuilt
  surface so it repaints. Those bytes carry the OLD bells, the OLD progress report and the OLD
  notification, so engine-side handlers would re-beep, re-post and re-spin everything that already
  happened, on every remount. The wire path replays nothing.

A clipboard is per-CLIENT, so it is the one push with nowhere else to come from — and the pty reply
is the client's by definition, because the client is the emulator.

**The pushes that survived are NOT callback doors.** `slopdesk-vterm`'s two engine handlers fill a
bounded Rust-side sink during `feed`, and the view drains it through ordinary two-attempt doors —
`slopdesk_term_surface_take_pty_replies` and `_take_clipboard_writes`. Nothing crosses the C boundary
except an answer to a question the caller asked. Each queue's ceiling matches what the thing IS: a
pty reply is dropped WHOLE rather than split, because half an escape sequence at the far side's
parser is worse than silence; clipboard writes evict oldest, because a person wants the most recent.

**The pty drain is not optional.** A caller that feeds without draining is a caller whose vim, tmux
and prompt negotiation hang waiting for a reply that was written and thrown away. Drain after every
feed batch AND after every resize — a resize can emit an in-band size report.

**The replay hazard bites both survivors, and the conformer answers it rather than dodging it.** A
replayed `CSI 6n` makes the fresh engine compose a reply that would type `^[[3;7R` at a live prompt,
and a replayed OSC 52 under an "Allow" policy would silently overwrite the pasteboard on remount. So
the attach path drains BOTH doors and DISCARDS the result before wiring the live drain. That is
deterministic rather than racy because `attachSurface` replays synchronously.

**A clipboard write is REPORTED, never applied.** The door says what a program asked for;
`ClipboardWritePolicy` decides. Writing straight from the frame would make "Ask" behave as "Allow".

### 4.2 Paste, and why the framing could not stay in Swift

A paste looks like the one operation the client could do itself — put these bytes on the pty — and
it is not. `slopdesk_term_surface_encode_paste` exists because three of the rules are the far side's
parser's, not ours:

* **The control-byte scrub.** NUL, ESC and DEL in a clipboard payload are an escape-injection
  vector; the engine replaces them.
* **The newline rewrite.** An UNBRACKETED paste sends CR where the text had LF, because that is what
  a shell reads as Return. A bracketed one does not.
* **The end-marker strip.** A payload carrying its own `ESC [ 201 ~` would close the bracketed block
  early and inject its tail as live input. The encoder removes it before wrapping.

Swift held a `"\u{1b}[200~" + text + "\u{1b}[201~"` (`PasteTransform.bracketed`) that did the third
and neither of the first two. It is deleted. What stays this side is what is genuinely the client's:
which TEXT (clipboard, selection, or a picked file's bytes), what SHAPE (`PasteTransform.base64` /
`.shellEscaped`, the latter already a face over Rust's `ShellQuoting`), and whether the payload is
dangerous enough to ask about (`PastePrecheck`). Only the framing crossed.

`bracketed` is the caller's argument rather than something the door reads, because three menu items
disagree on purpose: **Paste** takes the live `?2004h` (bit `8` of `_modes`, read from the engine
that parsed the DECSET — the client no longer runs a second parser for it), **Bracketed Paste**
forces it, and **Paste as Keystrokes** suppresses it.

### 4.3 Close and free are two doors

`slopdesk_term_surface_close` takes the state; `_free` returns the allocation. The split is the
lent `CAMetalLayer`: the view must drop the layer before the state that draws into it dies, and
`deinit` cannot express that ordering because it runs when the LAST reference goes — which may be
after the view was asked to draw again. A closed handle stays valid and answers every door its inert
value, so a teardown that races a runloop turn is ordinary rather than a crash. `_free` in `deinit`
and nowhere else is `slopdesk-invariants`' `handle-freed-in-deinit`.

## 5. The build list

### 5.1 The glyph renderer

The dominant item, and the only one whose absence is load-bearing: `libghostty-vt` "leaves
pixel-pushing to the host application."

1. Core Text font stack and fallback chain
2. shaping and ligatures — vt gives cell widths through `unicode.rs`; shaping stays Core Text's
3. glyph atlas and the Metal pipeline under one `NSView`/`UIView`
4. damage-driven redraw — **cheaper than it looks**: `RenderState::dirty()` and per-row `dirty()`
   already hand over exactly which rows changed
5. cursor: block / bar / underline, blink, hollow when unfocused
6. underline variants and underline colour
7. selection highlight
8. **marked-text (preedit) drawing in the grid — BUILT.** `NSTextInputClient` comes free with
   AppKit — that is the argument that decided the framework — but drawing marked text in a terminal
   grid is renderer work, and Telex is the reason it was on the critical path. `paint.rs`'s
   `Preedit` draws the composition over the cells the cursor stands on: an opaque bed so the shell's
   own echo cannot read through, the underline every platform puts under uncommitted text, and a BAR
   caret at the offset the input method reported — replacing the terminal's own caret rather than
   joining it, and drawn through the dark half of the blink. It is measured in cells by
   `slopdesk_vterm::text_cells`, which is the ENGINE's segmenter: a base plus its combining tone
   marks is one cluster in one cell, and a second width table would place the caret three cells too
   far right on exactly the sequences a Telex preedit is made of.

   **The composition never reaches the engine.** An input method may replace the whole run on the
   next keystroke, and text fed to the engine is on the grid for good. So it crosses as
   `slopdesk_term_surface_set_marked_text` and is drawn, never fed; the commit arrives through the
   ordinary key door. `slopdesk_term_surface_caret_rect` answers where the candidate window hangs,
   in points, off the LAYOUT — with blocks a row's y is not `row × cellHeight`, and a cursor
   scrolled back under a stack of headers is where the two disagree.

   ⚠️ **`macos-option-as-alt` and the input method are exclusive, and the setting decides.** A press
   handed to `interpretKeyEvents` under that setting comes back as the layout's composed character
   with the Option already spent — the meta prefix the setting exists to produce, gone. So an Option
   the user has given to Alt skips the input context entirely; with the setting off, a
   US-International dead key still composes.

   **UIKit is done too, 2026-09-01, and it needed no renderer work at all** — the preedit pass above
   was already shared, which is exactly what this paragraph predicted when it read "UIKit is NOT
   done". `Sources/SlopDeskPhoneUI/Pane/TerminalTextInput.swift` conforms `TerminalInputHostView` to
   `UITextInput`, and it is the same *deliberately-not-a-text-view* shape as the Mac's
   `NSTextInputClient`: the document IS the composition and nothing else, so every position is a
   UTF-16 offset into the marked run, and the questions that would need a real document —
   `closestPosition(to:)`, `characterRange(at:)`, `selectionRects(for:)` — answer the honest empty
   value rather than a guess at what the grid says.

   Three things the phone had to spell that AppKit answers for free. **The two views are not one:**
   the text client is the responder, `TerminalInputHostView`, and the pixels are its sibling — so the
   composition crosses back over `TerminalSurfaceHosting.setComposition(_:selection:)` and the host
   does NOT decide who draws it. The band-or-grid fork is the conformer's, written once per platform,
   because a host deciding it would be a second copy of the rule and two preedit runs on screen the
   first time the two copies disagreed. **The caret moves between views:** `caretAnchor` answers the
   rect AND the view it is in — the band while the editor owns the line, the grid otherwise — and the
   host converts, so a candidate bar cannot hang off the grid's stale cursor while the letters appear
   a band's height below. **Every trait is off:** adopting `UITextInput` opts a view into
   autocorrection, smart quotes and autocapitalisation that `UIKeyInput` alone never offered, and
   `"` for `"` on a shell line is a corruption the user cannot see coming.

   It also ends `FloatingCursor`'s wait: UIKit hands a space-bar drag only to a text input.
   The accumulator was built, tested and caller-less; `beginFloatingCursor`/`update`/`end` now drive
   it, with `slopdesk_phone_floating_cursor_steps` as the second rendering of the SAME `feed` — a
   signed count for the drag whose cursor is the app's own line editor, where there is no shell to
   send `ESC [ C` to and the travel has to arrive as the editing verb an arrow press does.

   **And the preedit is verified in PIXELS, which this doc twice called blocked.** The block is real
   for the grid — `slopdesk-apple-metal` sets `framebufferOnly = true`, so the drawable cannot be
   read back — and does not reach the BAND, which is `CGContext` end to end and photographs
   off-screen through the phone's own `HostedRaster`. Since the band is where the preedit goes
   whenever the editor owns the line, that is the case the feature was built for, and
   `Apps/ClientApp-iOS/Tests/TerminalPreeditPixelsOnIOSTests` renders it: one pin that the marked run
   draws its underline, one that the caret the band REPORTS is the caret it DRAWS. The second failed
   on arrival — `caretRect` took no composition, so with a conversion in flight it reported the
   editor's cursor 48 pt away from the bar on screen, and a candidate window hangs off the reported
   one. Fixed by measuring both off the same `CTLine` (`compositionCaret`), on both platforms at
   once, because the band is one implementation.

   **The GRID's half of the preedit is verified where it is DECIDED, not where it is blitted.**
   `slopdesk_termrender::paint` holds six pins on it — the bed under the run, an underline across
   every cell it takes, the composition REPLACING the terminal caret rather than joining it, drawing
   through the dark half of the blink, and nothing at all when no cursor is on screen. Those are the
   whole of what a composition looks like on the grid. What `setFramebufferOnly(true)` gives up is a
   readback of the finished drawable, which would only re-check that Metal blits quads it already
   blits for every glyph in the terminal. So there is no verification gap here to close: the two
   places a preedit can be drawn are each pinned in the layer that decides them, and the one thing
   genuinely out of reach is whether a real input method STARTS a composition — a keyboard-process
   behaviour no off-screen rig on either platform can observe.

   **The composition's LIFETIME is pinned on the PHONE, and cannot be on the Mac.**
   `TerminalCompositionSeamOnIOSTests` pins all three events — a mark starts, a COMMIT ends it, a
   RESIGNATION ends it. The last two are the ones worth a test: either left standing leaves an
   underlined run over text the input method has already forgotten, with no keystroke and no frame
   coming to repaint it away, and no test of the TEXT can see it because the text is right either
   way. It can do this because `TerminalInputHostView.surface` is injectable and the responder is not
   the renderer.

   The Mac's is the same rule at the same seam (`resignFirstResponder` → `clearMarkedText`,
   `insertText` → `clearMarkedText`) and is **blocked, measured, not assumed**:
   `MacTerminalRendererView` cannot be constructed inside a SwiftPM test bundle at all. A probe took
   it apart step by step — `TerminalSurfaceDriver` opens a real `CAMetalLayer`, `wantsLayer`, the
   layer hand-off, `setFocus` and `bind` all run clean on a bare `NSView` subclass — and what dies is
   the class's own `super.init`, on `-[NSView _setIgnoreFocusEngine:]: unrecognized selector`, an
   AppKit internal the `xctest` host does not install. Not a Metal problem, and not ours to fix. A
   stand-in for the driver would close it and must not be written: on the Mac the responder IS the
   renderer, so the stand-in would be a second implementation of the surface.
9. scrollbar geometry, replacing `ghostty_surface_viewport_info` and the `SCROLLBAR` action
10. padding, content scale, resize → cols·rows, which `rust/slopdesk-terminal/src/geometry.rs`
    already computes

Kitty-graphics *rendering* was scoped out here and is **now in** — §5.7 is the change, and the
sentence it replaces ("out of the bar: `TerminalConfigBuilder` enables no image token today, so
nothing regresses by not drawing them") is left recorded because its premise died with the emitter
that made it true.

The renderer's home is Rust. `rust/slopdesk-apple-text` already declares itself "the whole of the Core
Text area slopdesk touches" and is in the `slopdesk-apple-*` family, so shaping extends an audited
crate rather than opening a new `unsafe` boundary — no fourth hand-written-`unsafe` crate is proposed
and none is needed.

### 5.2 Search

vt exposes no search, so the whole matcher is `rust/slopdesk-vterm/src/search.rs` — and ALL FOUR
MODES are, which is the part that changed after the first cut. It was written as the literal matcher
libghostty had been covering, on the reasoning that the expensive half was already ours: the find bar
drove regex, case-sensitivity and whole-word from `slopdesk_workspace::find_bar`'s own match
positions and never armed `search:` for them.

That reasoning was wrong, and the shape it produced was gap 4. The bar counted in one engine
(`slopdesk-rowscan::find`, over a flat text mirror addressed by LINE INDEX) while the surface lit
cells from another (this one, over the grid, addressed by CELL) — so `N of M` and the highlights were
two answers to one question, and the modes the surface could not express had to scroll the viewport
by row instead of stepping a cursor. `Matcher` closes it: the query carries `regex` beside
`case_sensitive` and `whole_word`, the pattern is compiled once per query and used as the per-line
prefilter, and `slopdesk_term_surface_find` / `_find_position` carry all four modes in and the count
back. The row-driven branch, its two doors and the bar's match list are DELETED rather than bypassed.

⚠️ **A second matcher remains, and it is not this one's twin.** ⇧⌘F cross-tab search mirrors every
open pane's scrollback once and re-scans that snapshot per keystroke (`ScrollbackMatcher.swift` over
`slopdesk-rowscan::find`), because routing it through each pane's live engine would cross the FFI
seam per pane per character. One addresses cells in a live buffer, the other line indices in a
snapshot; neither can take the other's shape.

### 5.3 Blocks

The data layer exists and is already Warp-shaped. `rust/slopdesk-terminal/src/blocks.rs` (890 lines):
the host segments the byte stream and pushes **metadata only** — index, command text, exit code,
duration, output length — while captured output stays on the host until something asks for it, behind
a request registry, a 64-entry ring and a coalescing rule. Today that model drives only
`MacCommandNavigator` / `PhoneCommandNavigator`: a list you jump through.

Both halves are now built. `rust/slopdesk-termrender/src/block.rs` segments the frame on OSC 133
`A` and places every block with variable height, collapse state and viewport virtualisation; the
**alt-screen escape hatch** is `LayoutMode::Grid` plus `Chrome::NONE`, so vim and htop get the flat
grid and no chrome is drawn over a program that owns its rows.

`rust/slopdesk-ffi/src/terminal_surface/` carries it across: `slopdesk_term_surface_blocks` hands
back each block's screen rects, `_block_at_point` hit-tests one, `_set_block_collapsed` /
`_toggle_block_collapsed` / `_expand_all_blocks` fold them, and `_block_scroll` /
`_scroll_points` drive the list.

**The furniture is DRAWN in Rust.** `rust/slopdesk-termrender/src/chrome.rs` fills the gutter, the
divider, the collapse mark and the scrollbar into the same `DrawList` as the glyphs, one pass after
`paint.rs`. The earlier ruling — that the client fills the rects itself, in its own design language —
was a boundary statement rather than a measurement, and the two ways to honour it both cost more than
it saved: an `AppKit`/`UIKit` layer over the Metal layer lags the present by a frame during a scroll
(the drift `on_screen` exists to kill) and puts one appearance in two platform views, while streaming
instances back per frame is the marshalling `WorkspaceMarshalBenchTests` already measured and
rejected. What separates is not who draws but who **decides**: `_set_chrome_style` carries
`SlopDeskTerminalChromeStyle` — six `0xAARRGGBB` colours and five point lengths, built in
`TerminalChromeAppearance` from the on-glass Slate tokens — and `_set_hover` carries where the
pointer is. That is the same seam `PaintStyle` and `SelectionColors` already sit on, and it keeps ONE
chrome for both platforms. An all-zero style is a complete design that draws nothing, which is the
pre-install state.

The alternate screen does not use it. `Surface::draw` skips the chrome pass entirely rather than
handing it `ChromeStyle::NONE`, because the two are the same picture and not the same claim: the
frame the branch would build hit-tests the pointer and asks the engine for its viewport, and both
answers go in the bin. `LayoutMode::for_screen` gives a full-screen program ONE headerless block, so
a style that survived the branch would draw a gutter down `vim`'s left column and accent it — the
cursor is inside block zero by definition.

`_set_hover` answers whether the next frame would DIFFER, and the client presents only on `true`. A
pointer gliding inside one block delivers a move per sample and changes no pixel; presenting on each
would buy a full render — engine frame, layout, both paint passes, GPU — for the picture already up.
The test is a hit test against the last draw's layout, which is the picture that would be
re-presented, so it belongs on this side of the door rather than in an index the client holds.

The block rects still cross, because a hit test, a context menu and a copy-block verb are questions
asked between frames.

The rules the block list settled, all in the surface rather than the layout:

- **Chrome overflow rides `scroll_y`, never the row count.** `grid_size` sizes the grid from the
  drawable alone, so headers and gaps make the list taller than the viewport. Shrinking the grid to
  make room would make the PTY's height depend on how many prompts happen to be visible — a
  `SIGWINCH` per command.
- **The list is pinned to its bottom by default.** An upward scroll drops the pin; reaching the
  bottom takes it back. Once the list is at its top, further scrolling spills into the engine's
  scrollback in whole rows, because `segment` only ever sees the viewport frame.
- **One flick, one sign.** The block list absorbs "older" by DECREASING `scroll_y`, so what spills
  out the top is a NEGATIVE pixel count — and `Scroll::Delta` spells older negative too. `spill_rows`
  therefore does not negate: a negation would make a single continuous gesture reverse direction the
  moment the chrome ran out of offset to give. Nothing negates anywhere along the chain, because both
  platforms already hand up a POSITIVE number for "reveal older" (`NSEvent.scrollingDeltaY`, a
  downward `UIPanGestureRecognizer` translation) and `..._scroll_points` reads positive the same way
  — the one inversion lives in `wanted = scroll_y - delta`, and `spill_rows`' test pins the rest.

- **Points at the boundary, device pixels inside.** `Surface.geometry` is device pixels because the
  atlas is, but every pointer door speaks POINTS — `_mouse`, `_select_press`, `_link_hit`, and now
  the block rects, `_block_scroll` and `_scroll_points`. The scale divide lives in `on_screen` and
  the multiply in `_scroll_points`, so no caller ever holds a `CGRect` in one unit and a click in
  another. The macOS wheel converts too, in the other direction: `scrollingDeltaY` is only points
  when `hasPreciseScrollingDeltas`, and a notched wheel's LINES are multiplied by the cell height
  before they cross.

- **The scrollbar measures PIXELS, because two things scroll.** `layout::scrollbar` takes lengths
  rather than row counts: what moves under the viewport is the engine's scrollback *plus* the chrome
  the layout spends above each command. A row-counting thumb answers `None` for the case a short
  session hits every day — no scrollback at all, headers alone pushing the list past its own height —
  so the unit has to be the one the overflow is measured in. `Surface::thumb` adds the rows above the
  viewport (never laid out, so plain `rows × cell_height`) to `BlockLayout::content_height` (laid
  out, chrome included) and asks once.

A header shows a scrolled-back block's **exit code and duration**, right-aligned, and how it does
that is the interesting part.

This section used to say it could not, and that closing the gap meant "carrying the ordinal in the
mark itself (`OSC 133;A` with an id the engine surfaces per row), which is a shell-integration
change, not a rendering one". That was wrong on both counts, and it is recorded rather than quietly
deleted because the failure mode generalises: **it declared a gap upstream without checking what
this tree already had.** Wire type 28 has always carried `exitCode`, `durationMS` and
`promptOrdinal` to the client, per block. Nothing needed to be added to the mark, to the engine or
to the shell — the two halves were already on the same machine, and only the join was missing.

The join is `rust/slopdesk-termrender/src/blockjoin.rs`, and it is one question asked once: which
ordinal does the LAST prompt-bearing block hold? Every other block counts backwards from it.
Per-block text matching is not used, because a session that runs `ls` three times ties three ways;
ordinals are unique, so the anchor is the only ambiguity worth resolving.

The anchor cannot simply be the newest record. A prompt row is born from PTY bytes while its record
arrives as a control message, and those do not order against each other — the same race
`DECISIONS.md` exists for. In the window between a shell printing its prompt and the
host reporting the block, the frame holds one more prompt than the records account for, and an
anchor of "newest record" would slide every header up one and print the previous command's exit code
under this one. So the anchor is guessed (offset 0, then 1 — the host cannot fall two behind) and
then VERIFIED against the recorded command text, and **a frame that cannot be verified prints
nothing.** Four states degrade that way on purpose: the race window, records evicted past the ring's
64, `prompt_ordinal == 0` mid-stream joins, and the leading orphan block whose command scrolled off.

`slopdesk_term_surface_note_block` is the door the client feeds records through, upserted by ordinal
because a block arrives once running and again finished. `slopdesk_term_surface_block_text` still
answers what a header can know without any of this — the prompt rows as rendered.

Verification is ONE-SIDED — an unmatched prompt proves nothing, only a contradiction fails — and
that leaves exactly one shape the join cannot refuse: records from a shell that DIED. The fresh
shell counts from ordinal 1 while the surface still holds the dead session's forties, so the anchor
is stale, and because everyday commands repeat (`ls`, `just quick`) the text check confirms the
wrong anchor instead of rejecting it. No evidence inside the join's own input separates that case
from a correct one, so the guard is a door rather than a rule:
`slopdesk_term_surface_forget_blocks`, called from the same edge in `TerminalViewModel` that already
drops the client's block list on a fresh session — and never on a reattach that RESUMED the shell.
`blockjoin`'s `stale_records_from_a_dead_session_confirm_a_wrong_anchor` asserts the wrong answer on
purpose, so the reason the door exists cannot be deleted by someone reading only the join.

The second false positive is closed in the painter, not the join: the ACTIVE block never prints a
status even when handed one, because it is by definition the block whose command has not finished.
Retype a command the newest record already holds and the join would otherwise map the live prompt
onto the previous run and print its `✗ 1` under a command not yet entered. A running block's label
is empty either way, so the skip costs nothing.

**A failure IS red, since 2026-09-01** — this paragraph used to say it was not, and gave the reason
as "a token chosen on the Rust side of a design system that lives in Swift". That reason was wrong
about the design system: `Slate.Native.Terminal.err` is the PROFILE's own ANSI red, published for
exactly this — anything drawn inside the island that has to say "failed" — so nothing had to be
invented, only read. `ChromeStyle::status_err` carries it through the one appearance door the chrome
already has (`_set_chrome_style`, now seven colours), and `TerminalChromeAppearance` fills it from
`terminalErrHex` rather than from `Slate.Status.err`, which is the SYSTEM palette and lands out of
family beside the glass.

Only the `✗ <code>` wears it; the duration next to it keeps `label`, because a slow command is not a
broken one and a status that were red end to end would come to mean "finished". That is why the two
are separate shaped runs — `chrome::status_parts` splits the words where they are CHOSEN, so the
painter never has to find a `✗` in a string and count glyphs back to it. `status_label` stays as the
joined form, and it is the one thing the right-alignment is measured from: a width taken from a
differently-joined string would align the column against a length nothing on the row occupies. The
pinned head (§5.3's band) prints the same status through the same `chrome::status_columns`, so the
head and the header cannot disagree about the column or about which half is red.

### 5.4 The editor-like prompt

Built, and it is `rust/slopdesk-terminal/src/prompt/` (4 571 lines): a `TextBuffer` with
grapheme/word/line motions and a goal column, a coalescing `UndoStack`, a shell lexer that decides
both the colours and whether Enter runs, a `CommandHistory` with a walk and a ranked ⌃R panel, and
fzf-ranked completion over caller-seeded sources. It crosses through
`rust/slopdesk-ffi/src/prompt.rs` as ONE handle — the editor's own header says why: typing has to
abandon a history walk, dismiss the completion list and coalesce into the undo step together, and
four handles would put that wiring on the far side in two languages.

`inputbox.rs` stays where it was, doing the other job: which box to OFFER (`ShellCommand` at a
prompt versus `TuiCompose` under a fullscreen TUI) and which echoed bytes to swallow. The prompt is
what goes inside the box; the affordance is which box it is.

`Sources/SlopDeskWorkspaceCore/Terminal/CommandPrompt.swift` is the near side. Composition
(`NSTextInputClient` / `UITextInput`), key mapping and the candidate list's appearance stay in the
view per §10: a motion crosses as a case, never as a key.

**MOUNTED on macOS, 2026-09-01.** The box is a band along the pane's bottom edge
(`Sources/SlopDeskTerminal/TerminalPromptBand.swift`, drawn into by a small `NSView` shell), reached
through a new
`TerminalSurfaceHosting.promptView` so the leaf mounts it without naming the renderer. The band is a
SIBLING of the grid, not a subview: `surfaceView` is layer-hosting and AppKit does not promise a
subview of one of those a layer of its own — so the grid gives up the rows the band takes, which is
the honest arrangement anyway. The four decoration overlays are pinned to the GRID's rect rather than
the pane's, or a link underline would sit a band's height off.

The band takes **no keyboard focus**. `MacTerminalRendererView` stays the pane's one first responder
and routes into the editor from `keyDown` (`editsPrompt(_:)`), above the input method and below copy
mode. That keeps the focus region the tab owns undivided, and it means the whole IME stack — Telex,
marked text, `consumed_mods` — is written once and serves the grid and the editor both. A composition
over the editor's line is DRAWN by the band and never enters the buffer.

Every editing chord arrives as an AppKit **selector** through `interpretKeyEvents`, so the standard
key-binding table supplies ⌥←, ⌃A, ⇧⌘→ and the rest for free. Four control keys are carved out in
Rust (`prompt::keys`) because `readline` never owned them either: `⌃C`, `⌃D` on an empty line, `⌃Z`,
`⌃L`. Three chords the binding table does not name are read on the Swift side instead: `⌃R` (the
history panel) and ⌘Z / ⇧⌘Z / ⌘Y, which drive the editor's own history rather than
`controls.undo-at-prompt`'s readline byte — while the editor holds the line there is no shell to
send that byte to. `controls.command-prompt` (default on) is the one setting that hands the line back
to the shell.

A reverse search never touches the buffer — cancelling has to give the draft back exactly — so
whatever it found has to be drawn somewhere other than the line.

**⌃R is a RANKED PANEL, since 2026-09-01, and the bash-style single hit it replaced is deleted.**
This paragraph used to end "it needs two doors rather than one: `slopdesk_prompt_search_query` and
`slopdesk_prompt_search_hit` — shipping only the query plus a `search_has_hit` bool is a search that
shows no result", which was the right fix for a search that could only ever find ONE thing. The
finding stands and the shape does not: ⌃R now ranks the whole history with the same `slopdesk-fuzzy`
scorer completion uses, and every match is on screen.

Two prior questions it settles, each with the reason written where the code is:

- **Why ranked at all.** The old refusal (`prompt/history.rs`'s own header) was that a fuzzy re-rank
  reorders the walk between two presses of the same key. That is fatal behind a one-line
  `(reverse-i-search)`, where the neighbours are invisible, and empty in front of a panel — the
  ranking moves when the QUERY moves and at no other time. `fzf`'s ⌃R, `atuin` and `fish`'s own
  pager (3.6.0; its 4.0 `git*HEAD` glob is out-of-order matching by another name) all rank.
- **What Enter does.** It puts the row on the command line and does NOT run it — `fish`'s pager, not
  `atuin`'s, whose own docs ship a `enter = return-selection` rebinding for the people it surprises.
  `slopdesk-zshcomplete`'s header already states the tie-break this side of the app takes: "a
  missing candidate costs a completion, and a wrong one writes the user's command line for them".
  A wrong one RUN is strictly worse than a wrong one written. On a query that matched NOTHING it
  still closes the session and reports that it wrote nothing: a key that visibly does nothing reads
  as a wedged prompt, and an empty panel has already said everything it can.

**The query is `fzf`'s EXTENDED-SEARCH syntax, since 2026-09-01.** `git !push ^g` reads as it looks:
space-separated terms are ANDed, `|` ORs, a leading `'` demands a substring, `^` and `$` anchor, `!`
excludes. `slopdesk-fuzzy`'s `pattern` module is a port of `pattern.go`'s `parseTerms` and
`extendedMatch` plus the four non-fuzzy matchers and `calculateScore` out of `algo.go` — the same
faithfulness discipline and the same attribution as the `FuzzyMatchV2` port beside it, because the
precedence is not guessable (a bare `$` is a term, `'` FLIPS exactness rather than setting it, and
`^…$` is an equality rather than a prefix).

**It is deliberately confined to the SEARCH FIELD.** A ⌃R query is a place to write a query; a Tab
completion's query is real shell text, in which `^`, `$`, `!` and `|` already mean four other things
— `$HOME` is a variable, `!!` a history expansion, `|` a pipe. So `search_history` parses a
`Pattern` and `complete` calls the plain `slopdesk_fuzzy::score`, and each has a test saying so.
This is also the answer to "why not shell out to the `fzf` binary": we already run its algorithm, on
the right side of the wire, without a full-screen TUI taking the alternate screen the block UI
exists to avoid, and without a process per keystroke.

**It cost doors rather than adding them, because a ⌃R row and a completion candidate are the same
record.** Text, what it inserts, the whole range it replaces, and the scalar positions the underline
draws — all four already crossed for the candidate list, so the panel's rows ARE
`slopdesk_prompt_candidates`/`_candidate_arena`/`_candidate_positions` and the band draws them with
the code that draws a completion. `slopdesk_prompt_search_hit` and the `search_has_hit` flag are
gone; `slopdesk_prompt_search_back` (⌃S / ↑, one row up) is the one door that replaced them, because
what the panel is missing is not a way to READ the hit but a way to move through the ones on screen.
`CommandEditor::complete` refuses outright while a session is up — the search owns that list, and
both platforms recomplete on a redraw.

The single exception is `search_matches`, one `size_t` on the state record, and it is exactly what
the shared rows CANNOT carry: they carry what FITS. Two caps stand between the history and the
screen — `complete::LIMIT` before the records cross, the band's six before they are drawn — so a
count taken from the rows reports the nearer cap as if it were the answer, and the query row's
`6 of N` is the one number a reader has no way to check.

**It also wired a door that had been inert since the candidate records landed.** `positions` crossed
from the first day and nothing drew it. On a prefix list that was survivable — the match is the head
of every row — and on a fuzzy panel it is not, since a row can be offered for two letters at either
end of it. The underline is drawn for both lists now, from the one place.

Three verbs the editor SHADOWS while it is armed, each decided in `docs/DECISIONS.md`: paste goes
into the editor at the driver's single funnel; copy and cut are the editor's only when the grid has
no selection; and PageUp/PageDown/document-edge SCROLLING stays the viewport's, so mounting an editor
cannot take scrollback away.

`InputBarModel.compose` went in the same change — it was the second line editor, and the rule allows
one. `docs/DECISIONS.md` records why the band beat the inline reading `prompt/mod.rs`'s header used
to describe.

**MOUNTED on iOS, 2026-09-01**, in the same shape and with one implementation, not two. Three things
had to move for that.

*The band became platform-neutral.* `Sources/SlopDeskTerminal/TerminalPromptBand.swift` is now the
whole band — wrapping, the UTF-8→UTF-16 conversion, the selection, the caret, the accessory rows'
precedence, the syntax ink — and imports neither AppKit nor UIKit. It can: `CTFont` is toll-free
bridged to both `NSFont` and `UIFont`, the Core Text attribute keys take `CTFont`/`CGColor`, and
`SlateNativeColor` was already a platform typealias. What is left on each side is a ~100-line view
shell that answers `intrinsicContentSize` and hands a `CGContext` in. The alternative — a phone clone
of a 495-line Mac view — is the cross-language mirror in one language, and the arithmetic tests
(`TerminalPromptBandTests`) unfenced with the extraction rather than staying macOS-only.

*The pane collapsed onto ONE responder.* `PhoneTerminalRendererView` used to claim first responder
too, a sibling of `TerminalInputHostView` rather than an ancestor, so the loser's `pressesBegan` was
never called at all and the software keyboard flickered on every pane focus. It is not a responder
any more. `TerminalInputHostView` — the `UIKeyInput` that already held the repeater, the accessory
row and the ⌃⇥ walk — carries the prompt rung too, in the same position the Mac's `keyDown` puts it:
below the workspace chords, above anything that talks to a shell. `terminal-features.md` gap 9 has
the whole finding.

*The chords crossed as a door.* ⚠️ `slopdesk_prompt_key_action` TAKES A KEY, and that is not this
section's rule being broken — the rule is about the MUTATING doors, and a motion still crosses as
`SLOPDESK_PROMPT_MOTION_*`. Deciding WHICH verb a press names is the other half of §10's split, and
it is Rust's: `slopdesk_terminal::prompt::keys::edit_action` owns the table, and the phone view does
only the naming §10 assigns it — `PhoneKey.promptKey(_:)`, the USB HID keyboard page, no framework
type. The Mac never calls the door, because AppKit's binding table answers the same question in
selectors and a second Swift table would be the mirror again.

Four seam members came with it, all for the same reason — on iOS the responder is not the surface,
so what the editor does not own has to cross back. `promptDidChange()` redraws and re-measures the
band after an edit the host did not make; `scrollPages(_:)` sends PageUp to the viewport;
`setComposition(_:selection:)` reports what an input method is composing and `caretAnchor` answers
where the caret is and in which view. All four default to no-ops or `nil`, which is true of every
host that answers `nil` for `promptView`.

**The inline autosuggestion, 2026-09-01** — the second of the two things a `zsh` user installs a
plugin for (the first, syntax highlighting, shipped with the band). The prior art was read before it
was written and two of its rulings are taken verbatim. `zsh-autosuggestions` ships three strategies
and defaults to `history` (the most recent entry that extends the line); `CommandHistory::suggestion`
is that one, and its `completion` strategy would be a second reading of `prompt::complete`, which
already draws its own inline preview — so the band's ghost is the completion candidate when a list is
open and the history suggestion when it is not, never both. `fish` puts the accept on the input
FUNCTION rather than on a key — "`forward-char`: move one character to the right; or if at the end of
the commandline, accept a single char from the current autosuggestion" — which is why
`prompt::keys::over_suggestion` translates a **`Motion`, not a keystroke**: `→`, `End`, `⌃E`, `⌃F`,
`⌘→` and whatever the user bound in their own `DefaultKeyBinding.dict` all inherit the accept without
one of them being named anywhere, and ⌥→ takes a word.

Five things suppress it, and a history WALK is deliberately not one of them: a ⌃R search is open, the
candidate list is open, there is a selection, the caret is not at the end, or the line has a newline.

⚠️ Two traps, both paid for. The accept goes through `replace_range` and NOT `insert_text` — typed
insertions COALESCE into the burst (`prompt::undo`), so an accept spelled as an insertion merged into
the typing that summoned it and the ⌘Z that should have taken back thirteen borrowed characters
emptied the line instead; a test pins it. And the length guard runs BEFORE the byte comparison, which
is why there is no `ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE` to configure or to get wrong: an entry shorter
than the line loses on one `usize` compare, so a 10 MB paste costs one comparison per entry rather
than one per byte.

The two platforms ask the same Rust rule from different distances. The phone gets the verb from
`slopdesk_prompt_key_action`, which grew a `has_suggestion` flag beside `buffer_empty` (they cross as
one `KeyContext`). The Mac never sees a key, so it asks one step further along, in motions:
`slopdesk_prompt_suggestion_accept_for_motion` answers "does this motion claim the ghost" and
`MacTerminalRendererView` falls through to moving the caret when it does not. There is no Swift list
of forward keys on either side.

The INLINE preedit CLOSED 2026-09-01 with that conformance (§5.1 item 8) — the band draws the
composition it is handed, the grid draws the ones the editor does not own, and never both. What was
never broken and is worth restating: typing Vietnamese and Chinese at this prompt worked before it,
because an input method shows its candidates in the keyboard's own bar and commits the settled
string through `insertText`. The conformance adds the underline and the space-bar-drag caret; it did
not add the language support, and nothing about the editor was the gap.

One live defect fell out of writing it, on the same seam and not in the new code: the phone's
`insertText` had no `isSearching` fork, so a soft-keyboard character typed into an open ⌃R was
inserted into the LINE instead of the query — the Mac has had that fork since the band landed. Fixed
in the same change.

### 5.5 OSC 8 hyperlinks

The engine carries them and we now read them. `CellFlags::HYPERLINK` marks every cell of a link's
run — the flag only, because one URI is shared by the whole run and carrying it per cell would
allocate a URL per character per frame. `VtSession::hyperlink_at` reads the URI for the one cell
somebody pointed at, and `slopdesk_term_surface_hyperlink_at` is its door; the door checks the
frame's flag FIRST, so a pointer crossing ordinary text never reaches the engine.

This is the AUTHORED link, and it is a different question from the DETECTED one
`rust/slopdesk-terminal/src/link.rs` answers by scanning plain text for URLs. A cell can have both.
The authored URI wins, because the program said what it meant.

**One door ranks them**, `TerminalSurfaceDriver.link(at:cwd:slop:)`, and both platforms call it —
the Mac's context menu and ⌘-hover, the phone's long press. It asks the authored question first and
falls back to the detector, so the ranking is decided once rather than at each call site.

**There are two authored-link doors, and the split is one cell wide (2026-09-01).**
`slopdesk_term_surface_hyperlink_spans` walks the frame's flag and answers COLUMNS, which is what an
underline redrawn every frame needs and why it costs no engine call; two different links that abut
with no character between them arrive as one span, and one stroke across both is the same picture.
`slopdesk_term_surface_hyperlink_runs` splits at the URI and answers a CLASSIFIED link per run —
`VtSession::hyperlink_runs` asks the engine per LINKED cell — which is what anything that ACTUATES a
link needs, because merging two links there opens the wrong one. It is an on-demand door: a click, a
hint scan. Nothing calls it per frame.

`slopdesk_terminal::link::authored` is the one classification both actuating paths run, and it
replaced a `URL(string:)`-based twin in `TerminalSurfaceDriver` along with the outward per-cell walk
that used to recover the span in Swift. What is left on that side is a hit test against runs the
engine already split.

**Hint Mode reaches them too, since the same date.** `HintLabelAssigner.targets` takes the runs as
an input and `slopdesk_rowscan::hint::targets` accepts them BEFORE it detects anything, so the
overlap rule that was already there drops a detector's guess laid over a declared link. That closes
the ceiling this section's neighbour recorded: an `OSC 8` link whose display text is not itself a
URL was clickable and unhintable, because a scan of the row's TEXT is the one thing that cannot find
it. Its columns cross untouched — they are the engine's cells, and `text_cells` must not re-derive
them from a display text that stands for something else entirely.

**Link detection's setting does not gate the authored path.** "Auto-Detect Link Schemes" is a rule
about GUESSING — how eagerly to read a URL out of ordinary text — and a program that emitted `OSC 8`
did not guess. Turning detection off silences the heuristic, not the terminal's own protocol.

### 5.6 Settings: typed doors, and the rows that had none

`ghostty_config_load_string` took a whole `key = value` TEXT and the fork re-parsed itself from it.
There is no such door on `libghostty-vt`, so every setting the renderer honours is its own call, and
`TerminalSurfaceDriver.applySettings()` — armed on `TerminalConfigBroadcaster.generation` — is the
whole live-reload path. A setting that grows a door and is not added there is a setting the user can
only change by reopening the pane.

The emitter is DELETED rather than left standing: `rust/slopdesk-terminal/src/config.rs` went 883 →
~115 lines, its FFI face 507 → ~90, and `TerminalConfigBuilder.swift`, the `TerminalControls` bundle
and the two `slopdesk-invariants` rules keyed on the emitter went with it. What survives is what had
a second reader all along — the `FACTORY_*` constants the settings table publishes as each row's
default, and `number_text`, which spells a number the way a user types one.

**Two of the doors set a DEFAULT, and that distinction is the whole design.** `set_cursor_style`,
`_blink` and `_color` move the ENGINE's default, so a `DECSCUSR` or `OSC 12` from a running program
still wins — which is what makes a user's cursor preference safe to push at all. `_cursor_opacity`
and `_cursor_text_color` are the opposite case: no escape sequence expresses either, so there is no
default for a program to override and the RENDERER owns them outright. A door that cannot say which
of the two it is has not been thought about yet.

**A row with no door was deleted, not left to resolve silently.** Twelve went — `font-weight`, the
four explicit face families, `auto-match-weight-style`, `ligatures`, `ligatures-alphabet`, `bold`,
`italic`, `blending`, `theme`. They worked under the fork, which parsed the text, so this is a
regression being codified rather than a feature that never landed; each returns with its actuation,
in the same change. Six have (§5.11): the three style families, a fallback list, ligature control
and thickening. `docs/DECISIONS.md` §"The rows that survived their reader" argues it and names
the two rows that were WIRED instead.

**The four that were wired rather than deleted (2026-09-01).** `terminal.line-height` is the third
input to `set_font` — it belongs in the FONT STACK, where the taller cell centres its glyph and every
offset the face reported rides with the baseline, not downstream where each decoration would need its
own correction. The other three are gesture settings and stay on the embedder's side of the door,
where the paragraph above already puts them: ⇧+arrow runs the existing `adjust_selection:<dir>`
binding once `slopdesk_term_shift_arrow_edge` recognises the chord, and ⇧+click withholds a click
from `slopdesk_term_surface_mouse` the way `allow-mouse-capture` already does. Only click-to-move
needed a new door — `slopdesk_term_surface_click_to_move` — because the three things it must know
(where the cursor is, how many GLYPHS away the click is, and whether DECCKM wants `ESC [ C` or
`ESC O C`) are all the engine's. It answers the `←`/`→` presses a user would have made, never `↑`/`↓`:
at a prompt those are HISTORY, so crossing rows would replace the command being typed.
### 5.7 Inline images (2026-09-01)

The one Warp-class capability §5.1 scoped out, closed. The reason it was scoped out was the deleted
`TerminalConfigBuilder` — no image token, so nothing to draw — and once that emitter went the premise
went with it. Nothing upstream had to change: the pinned bindings already publish the whole kitty
graphics surface (storage, placements, z, `PlacementRenderInfo`, and a PNG hook), which is exactly
the bet "owning the grid" was placed on.

**Five decisions worth not re-litigating.**

1. **The file and shared-memory transmission mediums are CLOSED, permanently.** The kitty protocol
   lets a program transmit an image by naming a PATH (`t=f`, `t=t`) or a POSIX shared-memory object
   (`t=s`). In every other terminal the program and the terminal share a filesystem and that is a
   feature. Here they do not: the terminal is the CLIENT and the program is on a REMOTE host, so a
   path the far side names resolves against the USER'S OWN LAPTOP — an arbitrary local file read
   driven by whatever is running on the other end of the pty. Only the direct medium (`t=d`,
   base64 inside the APC) is accepted. This is a refusal, not a setting, and `terminal.images` does
   not reopen it. `docs/DECISIONS.md` carries the same entry.
2. **The engine's default storage limit is LARGE and had to be written back down.** The bindings'
   documentation says images are stored "only once a non-zero storage limit has been set", which
   reads as "nothing is stored by default". It is wrong — measured, not inferred: with a probe test,
   a fresh session accepts and stores a transmission before anything sets a limit. So
   `seal_image_transmission` writes the explicit zero as well as closing the mediums, and the test
   that guards it asserts on `image_meta`, because `graphics_generation` moves even when nothing is
   stored.
3. **A placement is clipped to its own BLOCK, not to the viewport alone.** Nothing in the protocol
   stops a placement's rows from running past the command that emitted them. Under a flat grid that
   is harmless; under block layout the next thing down is the next command's HEADER, and an image
   over it would describe the wrong command. So the destination is intersected with the block body
   and the source rectangle is narrowed by the same fraction — a crop, not a squash — and the same
   intersection handles a placement scrolled off the top for free, which is why the engine's
   negative row needs no second code path.
4. **Three z bands, interleaved into the existing pass.** The protocol splits z at `0` and at
   `i32::MIN / 2`, so the frame is `images → backgrounds → images → glyphs → images → overlays`. The
   overlays stay LAST so a cursor and a selection survive over a picture. One instance array visited
   three times rather than three arrays: `DrawList::image_runs` is what says where each band starts,
   and `drawPrimitives(…, baseInstance:)` is Metal's own way to draw a slice.
5. **A VIRTUAL placement is read out of the CELLS, with ghostty's arithmetic to the digit.** The
   protocol has a second way to position an image: `U=1` places nothing itself and lets unicode
   PLACEHOLDER characters (`U+10EEEE`) in the grid say where the image goes, cell by cell, so a
   scrolling pager moves it for free. The engine parses and stores such a placement but reports no
   viewport position for it, because there is none to report — which image, which fragment of it, and
   where the run starts are encoded in each cell's foreground colour, underline colour and combining
   diacritics. So the scan has to be ours, and it is: `slopdesk-vterm/src/placeholder.rs` decodes runs
   during the frame fill, where the RAW style colours and the cluster's diacritics are already in
   hand, and caches them on the row — which is what makes it correct under the dirty-row skip, since a
   clean row keeps its cells and therefore keeps the runs those cells spelled. `graphics.rs` then
   joins each run to the placement whose grid it names.

   The **aspect fit is ported from ghostty rather than derived**, function for function from
   `src/terminal/kitty/graphics_unicode.zig` at the pinned `22d13172`. The protocol says an image is
   "scaled to fit" its grid and stops there; every real difference — whether the leftover is centred
   or flushed, whether a fragment falling inside the blank band draws nothing or draws the nearest row
   of pixels — is the terminal's own decision, and every program that emits these sequences was tested
   against kitty and ghostty. Deriving our own would put an off-by-a-pixel seam between adjacent
   fragments of one image, which is what a tiled image is made of. The placeholder cell itself draws
   no glyph, unconditionally: `U+10EEEE` is private-use, no font has it, and a cell that kept its text
   would put a `.notdef` box in every cell of every virtually placed image.

**The rule the fifth decision is an instance of.** *The core follows ghostty; the app layer is
ours.* Parsing, grid semantics, protocol arithmetic and every place where a specification is
underdetermined take ghostty `main`'s answer, because the programs on the far end of the pty were
tested against it and because its author has spent longer in this problem than we will. Blocks,
prompts, layout and everything a user would call a feature are ours to take from wherever they are
best — kitty, Warp, rio, VS Code's terminal, `otty.sh`. The two halves meet at
`slopdesk-vterm`'s boundary: the engine wrapper does not innovate, and nothing above it is
constrained by what ghostty happens to draw. `docs/DECISIONS.md` carries this as a standing rule.

**What it costs a frame with no images**, which is every ordinary frame: one `u64` comparison.
`Surface::place_images` returns on `graphics_generation() == 0` before it touches the store or the
placement iterator, and each of the three encode passes returns on an empty run list before it
touches the encoder.

**Where it lives.** `slopdesk-vterm/src/graphics.rs` flattens the engine's storage into owned pixels
and placements (and installs the PNG decoder the bindings publish a hook for — their own bundled
`RustPngDecoder` cannot be used, it hands `next_frame` a `Vec` with capacity but no length).
`slopdesk-termrender/src/image.rs` holds the pixel cache and does the block-layout placement.
`slopdesk-apple-metal/src/images.rs` mirrors one `MTLTexture` per image, and `shaders.metal` grows an
`image_vertex`/`image_fragment` pair — the only `linear` sampler in the file, because an image is
resampled and a glyph never is. `terminal.images` is the row; the engine keeps its storage when it is
off, so the toggle is live in both directions.

**How it is verified without pixels.** Six links, each pinned where it lives: the engine test feeds a
real `a=T` APC and asserts the placement's `width_px`/`height_px`/`cols`/`rows`, because a zero in any
of them would be dropped as a zero-area quad and draw nothing while every other test passed; a second
engine test feeds a real `U=1` placement AND the placeholder cells that position it, and asserts the
two runs that come back — the join is invisible from either side alone, since a virtual placement on
its own is unplaceable and a decoded run on its own names a grid nobody declared; `placeholder.rs`
pins the diacritic table's sortedness (a binary search over an unsorted table answers `Err` for
entries that ARE there, silently misplacing a fragment), the run-continuation rule in both its
abbreviated and fully spelled spellings, and the band arithmetic on a wide image where the numbers are
hand-checkable; `image.rs` pins the block-relative arithmetic, the crop, the cell offsets and the
three bands; `quad.rs` pins the run batching; and `tests/device.rs` builds a real `Renderer`, which
compiles `shaders.metal` through the Metal front end and builds all three pipeline states — so a typo
in `image_fragment` is a test failure rather than a black pane.

**Sixel and iTerm2 (OSC 1337) are NON-GOALS, not gaps.** Both are transmission formats that would
land in the same store and draw through the same pass, so neither needs a second renderer — each
needs a decoder, and the engine does not parse them. That is exactly the point: ghostty `main` does
not support them either, and per the rule above the core does what ghostty does. Sixel in particular
is a 1987 format that carries a palette-indexed bitmap with no alpha and no way to say where it
belongs, and every program that emits it emits kitty graphics when the terminal advertises them.
Adding either would mean a decoder we maintain alone, a second path through the store, and a second
class of security question about payloads the far end chose — for pictures the kitty path already
draws. Do not re-open.

**The Glyph Protocol is the rule's first COST, and it is refused rather than struck.** Kitty graphics
is not the only APC protocol ghostty `main` carries: `ESC _ 25a1 ; …` registers a program's own glyph
outlines with the terminal, so a TUI can draw icons without the user installing a patched font.
`libghostty-vt` implements the wire half, and `apc.zig` arms every APC protocol by default
(`initFull()`) — which meant this terminal answered the support query with `fmt=glyf` and then drew
tofu, because the C ABI exposes a setter and no glossary READER, and Core Text rasterizes installed
fonts rather than `glyf`/COLR tables arriving on a pty. Claiming the protocol is worse than declining
it: the program's fallback is a Nerd Font glyph out of the user's own family, and the claim displaces
it. `VtSession::refuse_glyph_protocol` turns it off at construction, beside the image seal and for
the same reason — the engine's default assumes an embedder that draws. Unlike sixel this is a gap
that is OWED work: it returns when the bindings expose the glossary and the renderer can rasterize a
transmitted outline. `docs/DECISIONS.md` carries the argument.

### 5.8 Scrollback: the depth the settings promise, and what makes it affordable (2026-09-01)

`slopdesk_term_surface_set_scrollback` takes LINES because that is what a user states, and the door
was added to replace a 256-byte-per-line estimate into ghostty's byte-only `scrollback-limit`. It was
still not what a user got. The engine keeps TWO caps — bytes and lines — and prunes at whichever is
reached first, and its byte cap ships at 10 000 bytes, which is one page. MEASURED at 80 columns with
the shipped factory default of 10 000 lines: **1065 rows kept**, against **9930** once the byte cap
is cleared. `VtSession::set_scrollback_rows` clears it, and dropped the `Option` that let a caller
ask for the engine's default rather than state a depth. Two tests pin it — the ratio, and the
structural fact that no byte cap is left underneath — because a bindings bump is exactly the event
that would restore the default without anything failing.

Deeper history is what makes ghostty's **idle scrollback compression** worth taking, so it landed in
the same pass. The engine compresses fully historical pages and restores them transparently on the
next read; ghostty's own configuration puts text-heavy history at 10–30% of its uncompressed page
memory. `slopdesk_vterm::compression` holds ghostty's two intervals (250 ms of quiet before a pass,
1 ms between the bounded steps of one already running) and the engine's activity token;
`VtSession::compress_step` answers the caller a delay in milliseconds. `TerminalSurfaceDriver` owns
one cancellable task, arms it after a feed only when nothing is armed, and re-arms at whatever came
back — no interval and no policy on the Swift side. ⚠️ A display-link tick was the tempting carrier
and is wrong: it stops when the view leaves the window, which is exactly the pane worth compressing.

### 5.9 The doors the far side does not get (2026-09-01)

Three refusals now share one argument, and it is worth stating once rather than three times: **the
program is on the REMOTE host and the terminal is on the user's own machine**, so any protocol
feature that lets the pty reach back across that line is a different feature here than it is in a
local terminal.

- **Kitty's `t=f`/`t=t`/`t=s` transmission mediums** — a path the remote names is opened locally.
  Closed in `graphics::seal_image_transmission`; only `t=d` (bytes in the APC) is accepted, §5.7.
- **The window-title report (`CSI 21 t`)** — `OSC 2` sets a string, `CSI 21 t` reads it back into the
  pty's INPUT, and a newline in it is a line executed at the shell. The engine ships the report OFF
  and this crate never turns it on; `a_program_cannot_read_its_own_title_back_into_the_pty` is the
  pin, because the default living in the bindings is exactly the kind of fact a version bump moves.
  The title itself is read and displayed as before — the refusal is the REPORT.
- **The Glyph Protocol** — refused for a different reason (nothing here can rasterize the outlines),
  §5.7, and with a date on it.

⚠️ `set_apc_max_bytes` is deliberately NOT called: the engine carries a built-in cap already, and a
number invented here would be a divergence from ghostty in the one place ghostty has real traffic to
tune against. The question that mattered was whether APC buffering is unbounded. It is not.

### 5.10 The per-block context menu, and why it is keyed by an ordinal (2026-09-01)

Right-clicking inside a command block now offers that block's own verbs — Copy Command, Copy Output,
Re-Run Command, Collapse/Expand, Bookmark — prepended above the standard menu, which is Warp's shape.
The rules are `slopdesk_terminal::context_menu`'s `BlockItem`/`BlockContext`, the words and the
enablement cross at `slopdesk_term_menu_block_items` / `_block_item` / `_block_enabled`, and both
shells render the same table: an `NSMenu` section on the Mac, an inline `UIMenu` group on the phone.

**The pane-global `Item::CopyOutput` stays.** It acts on the LATEST block because it is also the
keyboard verb, and a keystroke has no pointer. Warp keeps both for the same reason.

Three things about the shape are load-bearing:

- **The menu stashes the prompt ORDINAL, never the layout index.** A menu stays open for seconds, and
  output arriving meanwhile re-segments the block list — the layout is a positional vector and so is
  the fold state. An index captured at build time can therefore fold or copy a block the user never
  clicked. `slopdesk_term_surface_block_target` answers the ordinal (with `foldable`/`collapsed` in
  the same crossing, so a right-click pays one call), and
  `slopdesk_term_surface_toggle_block_collapsed_at_ordinal` resolves the index again at ACTION time.
  Both spend `Surface::joined_ordinals`, factored out of `statuses` so the header's exit code and the
  menu's aim cannot come to disagree about which block is which.
- **It acts on the CLICKED pane's model.** `WorkspaceStore`'s `copyBlockOutputInActivePane` /
  `reRunCommandInActivePane` resolve `activeTerminalModel`, and a right-click on macOS does not
  necessarily focus the pane it lands in — those would copy from, or type into, a different pane than
  the one under the pointer. They stay for the keyboard and palette callers that genuinely mean "the
  focused pane"; the menu goes through `TerminalSurfaceDriver.run(_:ordinal:)`, which holds the
  pane's own model.
- **⚠️ Re-Run writes to the pty, so the read-only lock reaches it twice.** `TerminalViewModel`
  `sendInput(_:)` drops the bytes at the single outbound seam — that is the enforcement — and the
  menu greys the row, which is the affordance agreeing with it. An item that looked live and then
  beeped would teach the user that the per-pane lock is advisory. `reRunCommand(_:)` is now the one
  re-run implementation all three callers share, so `BlockReRunEncoder`'s verbatim-UTF-8 rule (never
  `SendKeysParser`) is spelled once.

A block the surface cannot NAME draws no section at all. The ordinal is the only handle the menu
holds, so a zero one — a mid-stream attach the host could not count, or an alt-screen program with no
prompt rows, where every slot in the join is `None` — leaves nothing for any verb to resolve at action
time, the fold included, since the fold resolves an ordinal too. `blockTarget(at:)` refuses it there,
one guard, rather than letting five rows draw of which four grey and the fifth would look live and do
nothing. A block that IS named but whose record the client ring no longer holds is the other case, and
that one keeps its fold: the clean command line and the ring index are both the record's, but the
layout still knows where the block is.

### 5.11 The widened face settings, and the one value they cross as (2026-09-01)

§5.6 deleted the four explicit face families with the promise that each returns with its actuation.
Six rows land here: `terminal.font-family-bold`, `-italic`, `-bold-italic`, a
`font-family-fallback` list, `font-feature`, and `font-thicken` with its `-strength`. The syntax of
the feature row is `ghostty`'s to the letter — `feat`, `+feat`, `-feat`, `feat=2`, `feat on`,
`feat off`, quoted names, comma-separated lists, invalid entries ignored — because a line that works
in a `~/.config/ghostty/config` should paste in here, and because it is also the CSS
`font-feature-settings` grammar. `-calt, -liga, -dlig` is how ligatures go away.

**The feature row reaches an ASCII cell, and a face probe is what gets it there (2026-09-01).**
§5.1's fast path — `shape_monospace`, one `CTFontGetGlyphsForCharacters` over the run — reads the
cmap, which maps a character to its default glyph and runs NO substitution table. Every feature is a
`GSUB`/`GPOS` lookup, so on a run of plain ASCII the cmap answer is simply wrong for any family that
ligates. The fix is not to delete the fast path, whose 6× is measured, but to stop ASSUMING it
applies: `substitutes_over_ascii` shapes every ordered pair of printable ASCII through `CTLine` once,
at `FontStack::new`, compares the result against the cmap, and records the answer on `Style`. A face
that agrees keeps the fast path; a face that substitutes sends its ASCII through `CTLine` too. The
probe wears the face's own descriptor, so it answers the CONFIGURED font: the same family reads as
substituting by default and as literal under `-calt, -liga, -dlig`, and the fast path comes back with
it. **No feature name is parsed by the shaper** — the comparison is the whole test, which is why
`ss01=2` and a `!=` ligature need no separate handling.

*Measured*, release, macOS 26, best of 30: `FontStack::new` 0.07 ms → **1.46 ms** for `Menlo` and
**2.77 ms** for `Helvetica` (four cuts, whole corpus), paid once per stack rather than per frame.
Two traps the implementation pins: Core Text stops applying substitution to a `CTLine` somewhere
between 10 000 and 12 000 characters and silently hands back the cmap, so the corpus is shaped in
2 048-character chunks with one character of overlap — a single long line would have made every face
on the system read as literal; and the positive test needs no vendored font, because `Helvetica` is
on every macOS and fuses `f`+`i` under the default `liga`, which is the same `GSUB` substitution a
programming family performs on `!=`.

**Where each half is decided.** The TEXT is parsed in `slopdesk_terminal::config`, which reaches no
framework and can test every spelling; `slopdesk-apple-text` is handed `(tag, value)` pairs and never
a string it has to interpret. That is the same split §5.1 makes for the renderer: the crate holding
the `unsafe` holds as little judgement as possible.

**The fallback families are Core Text's cascade list, not a `Vec<Face>`.** The crate's own header
already argues why the chain is the RESULT of Core Text's walk rather than a copy of the ~40-entry
default cascade; the user's families go in the same place, as the `kCTFontCascadeListAttribute`
PREFIX on the descriptor every face in the stack is copied against. So a named fallback resolves no
face until a character actually needs one, exactly like the system's own, and
`fallback_families_and_features_change_no_metric_and_resolve_no_face` is the test that says so. This
is also what keeps `PreferencesStore`'s promise true — only a font SIZE change reflows the remote
grid; a fallback family, a feature setting and a stroke move no cell.

**A named style family is taken at its word; a mistyped one is not.** `cut()` reads the traits back
off Core Text's answer because Core Text will approximate a trait REQUEST, and a family the user
NAMED is not a request. The one check that survives is ghostty's own rule: `CTFontCreateWithName`
answers Helvetica rather than NULL, so the family and PostScript names are read back, and a face that
is neither falls through to the primary family's own cut rather than putting a proportional face in
the middle of a grid.

**Thickening is the synthetic bold's mechanism at a lighter weight**, not a second one: the stroke
`font-thicken-strength` interpolates rides the STACK rather than the glyph key, because a settings
write rebuilds the stack and empties the cache anyway, and a faked bold's own stroke REPLACES it so
the two never stack.

**One spec crosses, and the door compares the whole of it.** The eight rows plus the size and the
line height travel as a `SlopDeskTermFontSpec` of arena spans with two span arrays beside it — the
shape `slopdesk_prompt_add_command` already speaks — and the surface stashes the whole `FontSpec` it
last drew with. That is the load-bearing part: the publish fires on EVERY settings write, so a door
that compared only the family and the size would read a new `font-feature` line, publish it and drop
it. There is nothing left to forget to add to the comparison, on either side of the boundary.

### 5.12 The pinned command head, and the coordinate bug it found (2026-09-01)

Scroll into a long command's output and the command that produced it leaves the screen, which is
the one question a reader has while looking at output: *what produced this?* `slopdesk-termrender`'s
new `pin` module answers it by keeping that block's HEAD — its header band and its prompt rows — at
the top of the content box while its output scrolls underneath. Warp's shape, and Rio's, and every
code viewer's sticky section header.

**A prompt can be off the top of two different things, and only one of them is a scroll.** When it
has scrolled out of the LIST — the header band and gap above it pushed it past the content box —
the rows are still in the frame, and the pass runs `Painter::paint_row` over them at a new y: same
cells, same runs, same selection, same coalescing, by construction rather than by a second
implementation. The row on screen is the SHELL's rendering — the prompt, its colours, the git
branch, the user's own theme — and nothing else can stand in for it.

**⚠️ The first version could only draw that case, which is the narrow one.** `segment` reads
`VtSession::frame()`, and the frame is ONE SCREENFUL; `settled_scroll` caps `scroll_y` at the block
list's chrome overhead, because history is the ENGINE's scroll (`spill_rows` hands a flick's
leftover to `Scroll::Delta`). So the pinned head as first shipped fired only inside the few dozen
pixels of header-and-gap slack — and a command whose output is taller than the grid leaves a
viewport with no prompt row in it at all, which `block` calls an ORPHAN and gives no header, so
`head_height` was zero and the band never came up. That is the flagship case, not an edge: a band
that appears and then drops out mid-gesture is worse than no band. Pixel-verified on the real app
before it was believed — `seq 1 400` under a live hostd showed block chrome and no head.

**The fix reads the prompt out of the scrollback.** `VtSession::prompt_span_above_viewport` walks
back from `viewport_top_row` to the nearest `RowSemantic::Prompt` row and counts its `k=c`
continuations; the surface reads those rows as text and hands them to `pin` as `Recovered`. Plain
text, not cells — no colours, no attributes — because recovering cells would mean a second
frame-scan path over the scrollback for a one-line band. The height is the same either way
(`Recovered::header_height` is the header that block will wear once its prompt scrolls in), so the
two paths hand over without the band resizing.

**⚠️ The walk is memoised, and both invalidations are ordinary.** It costs one C call per row
stepped over and the rows it steps over are the output being read — as long as the scrollback allows,
in exactly the case the feature exists for. `carry_orphan` re-confirms instead: it scans only the
rows that crossed the top edge since the last frame for a newer prompt, and re-reads the held row's
text, because screen rows are offsets from the oldest RETAINED row and eviction shifts every index
under a viewport that has not moved. A backwards scroll or a jump re-walks rather than guessing.

**⚠️ A LONE orphan gets a command but no outcome, and that refusal is load-bearing.** The orphan
joins through `blockjoin` by having its recovered prompt prepended to the frame's prompt list —
ordinals count one per prompt cycle and a cycle draws one prompt row, so it slots in at its own
position. But with NO other prompt in the frame there is nothing positional left: the join would
anchor its one entry on the newest record, and everyday commands repeat. Read the middle of an old
`cargo build` while a newer `cargo build` is the latest record and the text check CONFIRMS the wrong
one, printing a stale exit code over someone's output. Deep in an output the answer is genuinely
unknowable, so the band shows the command alone.

**⚠️ A test fixture that stops at `OSC 133;A` measures a prompt as tall as the block.** Rows between
`A` and `C` are the shell's INPUT region and the engine reports them as `PromptContinuation`, not as
output — which is what makes a two-line PS1 one place to jump to. A real shell always closes the
region. Two fixtures written without the `C` sent the continuation count to the end of the buffer;
`screen_row_semantic`'s doc carries the warning.

**It never slides, and that is a renderer fact rather than a taste.** The obvious polish is the
shove: push the pinned head up and out as the next block's arrives. `slopdesk-apple-metal`'s
`encode` is six fixed passes with no `setScissorRect` anywhere, so a band moved above the content
box would spill its glyphs into the drawable's top inset, and a glyph cannot be clipped after the
fact the way `image.rs` clips a placement on the CPU. It costs nothing, because the swap has
somewhere better to happen: the head is dropped the moment the NEXT block's own header reaches the
band, and what the reader sees in its place is that real header arriving.

**Z ordering replaces the clip.** `DrawList` gained a pinned background/glyph/overlay trio and a
`Mark`; the pass takes a mark, draws through the ordinary `push_*` doors so the row painter is
reused verbatim, and `lift_pinned` moves everything since into the pinned buffers. `renderer::encode`
draws those three last. Three no-op encodes on a frame with no head, which is most of them.

**⚠️ Building it surfaced a live drawing bug.** `block::lay_out` measures CONTENT — from the top of
the first block, at x zero, knowing neither the drawable's insets nor the scroll. The paint pass adds
both back for every row (`content_origin_y + row_y`, `origin_x + body.x`). `chrome::paint` added
NEITHER: it emitted `block.frame` and `block.body` verbatim, so the gutter, the divider, the hover
wash and the header status drew a top inset low at rest and a WHOLE SCROLL OFFSET low once anyone
scrolled. It shipped because every test in that module ran at the origin, the one offset where the
two spaces coincide. The origin story is in this file's own history: the fill used to be Swift's,
consuming `Surface::on_screen` rects, and when it moved into Rust the transform stayed behind. The
fix is `PlacedBlock::translated`, applied once at the top of the chrome loop, pinned by
`the_furniture_lands_on_the_rows_it_decorates` — nonzero inset AND nonzero scroll, on both axes.
`ChromeFrame::viewport` and the scrollbar thumb are drawable-space already and are NOT translated.

**And the same transform, applied TWICE, was the second bug.** `pin::paint` built its row geometry
as `origin_x + head.block.body.x` — the shape `crate::paint` uses over UNtranslated layout blocks —
but `head` has already been through `translated`, which is where its `origin_x` went. The pinned
line therefore sat one left inset to the right of the line it stands in for. `body.x` alone is the
fix, and both band tests now assert the leftmost pinned glyph's x — it got past the suite because no
test asserted one. Both bugs are the same mistake in opposite directions, and the lesson is the one
the chrome comment now states at the top of its loop: translate ONCE, at the boundary, and write
everything past it against drawable space.

**No new design door.** The band's bed is `frame.colors.background`, the colour the render pass
clears to, for the reason the preedit bed is; its hairline is the divider the block list already
draws; its status is the label ink. `SlopDeskTerminalChromeStyle` is unchanged.

## 6. Measured

`libghostty-vt` parse throughput, release, this Mac Studio, 256 MiB per shape through `vt_write`
(warmed, single-threaded, no renderer attached):

| shape | throughput |
| --- | --- |
| ASCII lines, 80×24 | 427.9 MB/s |
| ASCII lines, 200×50 | 494.8 MB/s |
| SGR-heavy build log, 200×50 | 108.8 MB/s |
| full-screen TUI repaint, 200×50 | 128.5 MB/s |
| CJK + Vietnamese diacritics + emoji, 200×50 | 231.2 MB/s |

Two things to read carefully. **This is not a comparison** — measuring the fork the same way needs a
live surface and a renderer, so the before/after pair belongs to the demolition pass, not here. What
it does settle is that the pinned commit carries the parser upstream landed after our v1.3.1 tag
(PRs #13220 / #13226, which `ThirdParty/ghostty/README.md` lists as unreachable from the pin): 495 MB/s
on ASCII is the post-rewrite parser, not the one the fork compiles.

The SGR row is the one that matters for this product — a colourised agent log is what the panes
actually carry — and 108.8 MB/s is far above any rate a remote PTY can deliver over the mesh. Parsing
is not where the budget goes; drawing is, which is why §5.1 is the risk and this table is not.

### 6.1 Which platform the veto is measured on

**macOS.** The before-numbers are taken on the deployed macOS client, and a regression there is the
veto. iOS ships without a before-number, and that is a decision rather than a gap: the probe is
portable (§6.2) but a simulator number measures the host's GPU, not the phone's, and the fork will
be gone before a device run can be repeated. Two things make the asymmetry acceptable — the two
`renderTick` paths in `GhosttyTerminalView.swift` (macOS at 1115, iOS at 3705) present through the
same gated-`presentTicks` design, so a macOS regression and an iOS one have the same shape; and
upstream bug #13021, the iOS Metal-teardown use-after-free the fork carries, is a defect the
demolition removes rather than risks.

### 6.2 The harness

The table above came from a scratch crate against `libghostty-vt` alone. It is reproduced here rather
than left on disk, because the same five shapes are what the after-numbers must be taken over, and a
number nobody can re-run is not a baseline. `Cargo.toml` is one dependency —
`libghostty-vt = { git = "https://github.com/Uzaaft/libghostty-rs", rev = "a0b5a46" }` — built
`--release`. That is the rev the numbers were TAKEN at and it stays written that way; the tree's
live pin is the fork named in §4, which changes two clipboard signatures and nothing the harness
touches.

```rust
use std::time::Instant;

use libghostty_vt::Terminal;

/// Feed `payload` repeatedly until `total` bytes have gone through, and report MB/s.
fn bench(name: &str, cols: u16, rows: u16, payload: &[u8], total: usize) {
    let mut term = Terminal::new(cols, rows).expect("terminal");
    let reps = total / payload.len();

    // Warm the parser and the page allocator before the timed run.
    for _ in 0..(reps / 20).max(1) {
        term.vt_write(payload);
    }

    let started = Instant::now();
    for _ in 0..reps {
        term.vt_write(payload);
    }
    let elapsed = started.elapsed();

    let mb = (reps * payload.len()) as f64 / (1024.0 * 1024.0);
    println!(
        "{name:<28} {:>8.1} MB/s   ({mb:.0} MiB in {:.2}s)",
        mb / elapsed.as_secs_f64(),
        elapsed.as_secs_f64()
    );
}

fn main() {
    const TOTAL: usize = 256 * 1024 * 1024;

    // Plain ASCII lines — `cat` of a large log, the commonest remote-PTY shape.
    let ascii: Vec<u8> = (0..64)
        .flat_map(|_| {
            let mut line = b"the quick brown fox jumps over the lazy dog 0123456789".to_vec();
            line.push(b'\n');
            line
        })
        .collect();

    // SGR-heavy output — a colourised build log, which is what an agent pane actually carries.
    let sgr: Vec<u8> = (0..64)
        .flat_map(|i| {
            format!("\x1b[38;5;{}m▎\x1b[0m compiling \x1b[1mcrate-{i}\x1b[0m v0.1.0\r\n", i % 256)
                .into_bytes()
        })
        .collect();

    // A full-screen TUI repaint: absolute cursor moves plus erases, the alt-screen shape.
    let tui: Vec<u8> = (0..48)
        .flat_map(|row| format!("\x1b[{row};1H\x1b[K row {row} of a redrawn frame").into_bytes())
        .collect();

    // Wide/CJK plus combining marks — the grapheme path, and Telex's own alphabet.
    let unicode: Vec<u8> = (0..64)
        .flat_map(|_| "日本語テキスト tiếng Việt có dấu 🎉 combining\r\n".as_bytes().to_vec())
        .collect();

    bench("ascii lines 80x24", 80, 24, &ascii, TOTAL);
    bench("ascii lines 200x50", 200, 50, &ascii, TOTAL);
    bench("sgr build log 200x50", 200, 50, &sgr, TOTAL);
    bench("tui repaint 200x50", 200, 50, &tui, TOTAL);
    bench("unicode/cjk 200x50", 200, 50, &unicode, TOTAL);
}
```

### 6.3 The live-app baseline, and the one number it does not have

Taken 2026-08-31 on the deployed macOS client with the fork still rendering, through
`slopdesk-guigate macos --connect` — which builds the app, starts a real `slopdesk-hostd`, dials it,
and types a COMPUTED marker so an echo of the literal keystrokes cannot satisfy it:

```
client↔host session ESTABLISHED on :47420
OUT-path PROVEN: keystrokes → host PTY → shell EXECUTED (computed 42 → SLOPDESK_OUT_…_42_END)
echo latency (n=1): median 1.4 ms, p95 1.4 ms   (key→render-feed, loopback)
```

`.work/macos-verify/macos-shot.png` is the picture the gate's own PASS criterion asks for: libghostty
painting a live remote shell — prompt, ANSI colour, the sidebar's session rows. **That is the number
the after-side must beat, and the gate that produces it is not ours to write** — the same invocation
re-runs on the new renderer unchanged, which is why it is the baseline rather than a bespoke probe.

Read what it measures precisely: **key→render-feed**, not glass-to-glass. It ends where the bytes are
handed to the surface, so it prices the wire and the PTY round trip and *excludes* draw. That makes it
the right veto for §5.1 in one direction only — a renderer that regresses drawing will not show up
here — and §5.1 is exactly where the risk was already located.

**The cadence and scroll histograms are deliberately not in this document.** `slopdesk-framewatch`
was built and its capture path verified (`--list` enumerates on-screen windows, so SCK and the
Screen-Recording grant are live), but a frame-cadence p99 needs the app held open under a sustained
workload, and `--connect` tears it down after its assertions. Both gaps were reached on a box under
load average 33 — a cadence percentile measured there prices contention, not the renderer, which is
the same failure mode `perf-tests-load-flaky` records.

So the veto is asymmetric, and stated rather than hidden: **key→render-feed is pinned and binding;
draw cadence is not baselined.** The fork is recoverable — it is in git history — but recovering it is
not `git show`: it is an old-tree checkout that must build and run, which means the 0.15.2 toolchain
download, the `xcrun` SDK shim, an Xcode that has since moved and a cold `.build`. Hours, and not
certain. If §5.1 lands and drawing feels worse, the honest move is to measure the NEW renderer's
cadence on a quiet box against the 60 Hz ceiling directly, not to resurrect the fork.

## 7. What this does NOT touch

- **The wire.** Blocks already ship as metadata push plus on-demand output fetch. No new verb, no
  golden re-pin. `docs/20` is unchanged and `golden/golden_vectors.json` is not regenerated.
- **Security.** No pairing, no tokens; the WireGuard mesh is still the boundary.
- **The framework ruling.** AppKit/UIKit for the view layer, chosen 2026-08-31 and not reopened here.
  GPUI is not in this tree and does not enter it.

## 8. Risks

- **`libghostty-vt` is alpha with no API-stability promise**, pinned to a main-branch commit rather
  than a tag. Betting the client's primary surface on it is a larger exposure than a like-for-like
  swap would be. The mitigation is that vt is the half upstream built for embedders, and that we pin
  the commit ourselves (§3, V2) so churn arrives when we choose it.
- **The bindings' `unsafe` is not audited by us, and "audited" is per-commit.** `slopdesk-vterm` is
  `forbid(unsafe_code)` and every `unsafe` under it is the bindings'. The clipboard path proved that
  is a claim about one revision rather than a property: two UB sites, both reachable from any
  program on the pty, both found by upstream's own Miri run. The mitigation is the pin — we choose
  the revision, so a fix is a rev bump we can make ourselves, which is what §4's fork is. The
  residual risk is the sites nobody has run Miri over yet; the OSC 9/777 notification title and body
  reach the same `to_str`, and we do not register those handlers.
- **Concurrency changes owner.** `terminal.rs:511` — "the caller must serialize it with writes,
  rendering, searches". libghostty ran its own IO and renderer threads; afterwards that is ours.
  `superd` still owns `read` on every PTY master, so the discipline is unchanged in kind.
- **Perf is a veto, not a worry.** Throughput, input latency and scroll all get numbers before and
  after, per §3.

## 9. Blast radius

390 files name ghostty; **42 are real coupling** — a `ghostty_*` symbol, `import CGhostty`, or the
renderer wiring. The rest is prose. The coupled set is `ThirdParty/ghostty/` (the fork, the 5 039-line
`GhosttySurface`/`GhosttyTerminalView` embedder, `CGhostty/ghostty.h` and its modulemap), the two app
specs and their `AppMain.swift`, `Sources/SlopDeskTerminal/`, the `Sources/SlopDeskWorkspaceCore/Terminal/`
policy files, `rust/slopdesk-devtools/src/ops/renderer.rs` (`slopdesk-ops enable-renderer`) with its
`stamp.rs` and `release/pack.rs` edges, and the `pointer`/`surface`/`wrap_map` modules that name
libghostty tokens.

Per `CLAUDE.md`, this lands as ONE pass — the fork and the embedder go first, the tree is red in the
middle, and it is green once at the end.

## 10. Where each responsibility lands

Written before the cut, not after it. `GhosttyTerminalView.swift` is 3 954 lines across seventeen
`MARK:` sections and `GhosttySurface.swift` another 1 085; deleting that much at once is how a
behaviour disappears without anyone deciding it should. Every section below is one of those
sections, and every row names its new owner. `git show` recovers the file for reading, but a file
you have to go read is not a plan.

The reframing that makes the number smaller than it looks: **most of this Swift is event plumbing,
and event plumbing stays Swift.** An `NSView` that receives `keyDown` and forwards it is the same
view before and after — what changes is the C ABI it forwards INTO. The lines that actually die are
the ones that exist because libghostty owned a surface, a thread and a config.

| Section | Lands |
| --- | --- |
| process-wide `GhosttyApp`, `ghostty_init`/`app_new`/`tick`, config build | **deleted.** There is no app object: a surface is a `slopdesk-vterm` handle, and config is `slopdesk_config`'s already |
| `write_callback` / `resize_callback` / the `ghosttyOnMainActor` hop | **deleted as callbacks, kept as a drain.** The hop existed to get off libghostty's IO thread; the feed is a direct FFI write under the surface's own lock (§8). What the terminal owes the pty still exists and is now PULLED — see §4.1 |
| resize → grid | **Rust.** `rust/slopdesk-terminal/src/geometry.rs` already computes cols·rows; the door resizes the vterm |
| key input encoding | **Rust.** vt ships `KeyEncoder`; the view forwards the event's fields |
| IME / `NSTextInputClient` / `UITextInput`, marked text | **Swift view, and it must be.** Composition state is the platform's. Only the DRAWING of preedit crosses (§5.1 item 8) |
| mouse / scroll forwarding, tracking area, hover | **Swift view** for the events, **Rust** for the encoding — vt ships `MouseEncoder` |
| OSC-22 pointer shape | **dropped.** `osc.rs` parses it into `CommandType::MouseShape`, but `Terminal` exposes no handler for it, so there is no observation point at any price — recorded in `DECISIONS.md` |
| mouse-hide-while-typing, focus-follows-mouse, pointer shield | **Swift view.** Pure AppKit/UIKit policy, no engine edge |
| clipboard responder selectors, OSC 52 | **Rust** reports the write and decides the policy (`ClipboardWritePolicy`); the view drains it, asks if the policy says ask, and calls the pasteboard. OSC-52 *reads* are dropped upstream and never forwarded, so there is no read gate to build |
| link highlight, link click, hit-test | **already Rust** — `TerminalLinkDetector`/`TerminalLinkHitTest` are policy files, and the grid text they need is what the new surface hands over |
| jump-to-prompt, context menu, edit menu | **already Rust** for the table; the view renders it |
| pan-to-scroll, tap-to-mouse, long-press-select, gesture arbitration (iOS) | **Swift view.** UIKit gesture recognisers, one framework the rule keeps |
| keyboard-focus reclaim (iOS) | **Swift view** |
| `renderTick` / `presentTicks` / `IOSurfaceLayer` | **Rust.** A `CAMetalLayer` the view creates and Rust draws into, on a display link |
| scrollbar geometry (`ghostty_surface_viewport_info`) | **Rust.** §5.1 item 9 |
| the `TerminalSurfaceHosting` conformance | **Swift view**, unchanged — three members, same three |

**The seam itself survives, and the factory with it.** Collapsing `TerminalRendererFactory` into a
direct reference was considered and rejected: its `nil` path is what lets every canvas test mount a
leaf without a renderer (`LeafSeamSlotTests`), and a canvas naming the view directly would create a
Metal device under `swift test`. What DOES change is where the conformer is compiled — the new view
has no clang-module dependency on a fork, only on `CSlopDeskFFI`, which `Sources/SlopDeskTerminal`
already links. So it moves into the package, `swift build` compiles it, `swift test` can reach it,
and `slopdesk-ops enable-renderer` goes away. The registration call moves from an Xcode-only file to
a `public func` the two `AppMain.swift`s call.

### 10.1 The crates

Four, split by what may hold `unsafe` (`CLAUDE.md`, `docs/57` §2):

- **`rust/slopdesk-vterm`** — the engine, wrapped. Landed (`744e80ab`). Grows the grid snapshot,
  the key/mouse encoders, and the literal search of §5.2.
- **`rust/slopdesk-apple-metal`** — NEW, `slopdesk-apple-*` family: one framework area (Metal, and
  the `CAMetalLayer` that presents it), through `objc2`. Its one gated admission is `Retained::retain`
  on the layer Swift hands over.
- **`rust/slopdesk-apple-text`** — EXTENDED: glyph rasterisation and shaping. Already declares
  itself "the whole of the Core Text area slopdesk touches", so this opens no new boundary.
- **`rust/slopdesk-termrender`** — NEW, `forbid(unsafe_code)`: the atlas allocator, cell→quad
  building, block layout, cursor/selection/underline geometry. Every DECISION lives here; the two
  Apple crates above turn its output into an effect and make none of their own.

### 10.2 The stamp, and the two files outside the graph

`slopdesk-gate ffi` derives its inputs from the shim's `path = "../…"` edges, so making
`slopdesk-vterm` a path dependency of `slopdesk-ffi` covers its sources AND its `Cargo.toml` — which
is where the bindings `rev` lives. `rust/slopdesk-ffi/Cargo.lock` is already an input and records the
resolved commit, so the bindings pin is doubly covered.

Two inputs are NOT in that graph and must be added to `SELF_FILES`' neighbourhood by name, because
they decide what the artifact is compiled from and no path edge reaches them:
`ThirdParty/tools/tools.lock` (the engine commit) and `rust/.cargo/config.toml` (the
`GHOSTTY_SOURCE_DIR` that selects the tree). Bump either and today's stamp stays warm over an
xcframework built from different Zig sources — the exact silence the gate exists to end.

## 11. The shell-completion bridge — verb 23, zsh only

Every other terminal that has built a rich prompt input answered "what would the shell complete
here?" with a **spec database of its own**: a curated set of descriptions for a few hundred
commands, shipped in the app. That is why each of them also silently breaks the completions its
users actually installed — the plugin manager's, the company's internal CLI's, the ones a package
dropped into `site-functions`. The user refused that trade by name: *"Tôi không muốn đạp đổ shell
completion như thằng warp."* So this half does the other thing — it **runs the user's own
completion, unmodified, and reads what it produces**.

### Why it cannot be done by reading anything

zsh's completions are not data. A completion function is program text that runs inside `zle`,
reaches for the shell's own dynamic scope, and reports what it found by CALLING `compadd` — whose
`-a`/`-k`/`-d` flags name **arrays that exist only in that function's frame at that instant**. There
is no file to parse and no process to query. An index built ahead of time is not a smaller version
of this; it is a different, worse answer.

So the bridge is a **captive interactive zsh** with `compadd` overridden to report and fall through.
The split falls at the first newline:

| Layer | Where | What it decides |
| --- | --- | --- |
| capture | `slopdesk-zshcomplete::setup` (a Rust `const`, not a script) | nothing — it reports what zsh decided, as flat lines |
| reader | `slopdesk-zshcomplete::parse` | pure; records → candidates + the text they replace |
| lifecycle | `slopdesk-zshcomplete::session` | one warm shell per host, file in, file out, deadline, respawn |
| verb | `MetadataVerb::ShellComplete = 23` → `Performer::Builder` | `[u32 cursor][utf8 buffer]` in, groups out |
| ranking | `slopdesk_terminal::prompt::complete::ShellProvider` | ranks the answer beside the local sources |

### Five decisions worth not re-litigating

1. **One warm shell per HOST, never per pane, and never the pane's own.** `CLAUDE.md`'s superd rule
   is the hard constraint — a second reader on a pane PTY steals bytes rather than observing them.
   The drive widget takes the working directory as a per-request argument and `cd`s to it, so a pane
   contributes nothing a request cannot carry.
2. **The answer carries a PREFIX, not an offset.** The round trip is 11–92 ms and the user types
   through it. An offset computed against the buffer the host was asked about would land somewhere
   else in the buffer now on screen and delete characters typed since. `ShellProvider` re-derives
   the range against the LIVE document and offers nothing when the prefix no longer matches.
3. **Every ambiguity resolves one-sidedly.** An unknown `compadd` flag makes the call report
   NOTHING; `-U` matches — which zsh never compared against the line — are dropped rather than
   offered against an invented range; `compadd` ALWAYS reaches the builtin so its caller reads the
   real status. A missing candidate costs a completion; a wrong one writes the user's command line
   for them.
4. **Three answers, not two.** `ok` + groups (possibly empty), `error` for "not warm yet / missed
   the deadline" (transient — ask again), and `notFound` for "this host's shell is not zsh"
   (permanent — stop asking). A client that could not tell the last two apart would either poll for
   ever or abandon a shell that was about to answer.
5. **The zsh text is a `const`, not a file.** `docs/60` deleted this tree's shell scripts because
   each was LOGIC in a second language. This is the opposite: a protocol adapter for zsh, in the
   only language zsh runs, with exactly one caller. As a file it would be sourceable, editable and
   greppable as "a shell script we still have"; as a constant it cannot be edited without a rebuild,
   and its record format is pinned by `parse`'s tests on the other side of the same crate. It is
   written to the session's temp dir and `source`d only because a pty in canonical mode truncates an
   input line at `MAX_CANON` (~1024 bytes).

### Measured, against a real `~/.zshrc`

| request | result |
| --- | --- |
| warm-up (once, on a thread) | 3.9 s — the user's own plugins, and the whole point is that they run unchanged |
| `git com` | 1 candidate + "record changes to the repository", 92 ms cold / 20–25 ms warm |
| `cd rust/slopdesk-w` | 2, hidden prefix `rust/` composed into the insert, 21 ms |
| `git --git-dir=ru` | `IPREFIX=--git-dir=`, `PREFIX=ru` — an exact range the client's own lexer would not find, 24 ms |
| `ls --` | 68 candidates, 26 ms |
| `git checkout ` | 27 refs, 62 ms |

The 400 ms deadline is ~4× the worst observed answer. It is a latency budget, not a correctness one:
the local sources answer instantly either way, and the shell's candidates merge in when they land.

### What presses it, on the client

Tab, and nothing else. Not a keystroke — a completion function is arbitrary shell that runs the
user's plugins, and asking on every character would run it dozens of times per word for an answer
only the last one could use.

`TerminalViewModel.completeCommandPrompt(forward:didChange:)` is the ONE implementation of the rule;
both renderers press the same key into it (the macOS `insertTab:` selector and the phone's
`PromptKeyAction.completeForward`), and each supplies only its own band-redraw. It fires the local
sources and the shell **in parallel**: the local answer is on screen before the key is released, and
the shell's merges in 20–92 ms later.

Four things about that are worth not re-deriving:

1. **The outright accept moves to the reply.** "Exactly one candidate applies without asking" is what
   makes Tab worth pressing, but *exactly one* counted off the local sources alone is a claim the
   client cannot make while a shell request is out. On `git checkout ma` the local path source finds
   one file called `main.rs` and zsh is about to name 27 refs. So the rule is applied by whoever
   knows the whole list — and only then.
2. **The accept is withheld from a line that MOVED.** The buffer and caret are captured before the
   `await` and compared on the reply. The merge still happens (decision 2 — `ShellProvider`
   re-derives its range against the LIVE document, and offers nothing once the prefix stops
   matching), but accepting into a line the user kept typing writes over what they meant.
3. **Nothing at all lands on a question the user ENDED.** A line that moved still wants the merge; a
   line that is over wants none of it, and three keys end one inside the window: Enter runs it, ⌃C
   abandons it, ⎋ puts the panel away. The text cannot report any of them — after Enter the document
   is empty, and merging into it would rank the whole history against an empty prefix and hang a
   panel on the fresh prompt, where the user's *next* Enter would accept a candidate instead of
   running what they typed. `CommandPrompt.completionEpoch` is bumped by those three and by nothing
   else, captured with the buffer, and checked before the merge rather than beside the accept. It is
   bumped inside `CommandPrompt` rather than at the six view call sites, so no key has to remember.
4. **`noShell` latches for the connection; `notReady` never does.** The latch is a fact about the
   HOST, so it is taken even from an answer whose line is gone. A generation counter drops an older
   answer that lands after a newer one, which two Tabs in quick succession will produce.

The wiring is `TerminalPaneWiring.wireShellCompletion(live:)`, in the same weak-provider shape as the
host path actions: the `MetadataClient` façade is replaced on every reconnect, so anything that
stored one would keep asking a dead one. Disconnected reads as `notReady`, so being offline never
spends the latch.

### Scope

**zsh only**, by the user's own sequencing: *"cứ hoàn thiện zsh đi đã, sau này mở rộng sang shell
khác sau."* `docs/DECISIONS.md`'s item (6) ⛔ still stands for bash and fish, and this does not
weaken it — bash's `complete -F` and fish's `complete` report through entirely different mechanisms,
so either would be a second capture half, not a flag on this one.
