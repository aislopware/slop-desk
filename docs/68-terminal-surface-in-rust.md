# 68 — The terminal surface becomes ours

The client stops embedding a terminal *application* and starts driving a terminal *engine*. libghostty's
surface API — which owns its own Metal renderer, its own IO thread and its own grid layout — is
replaced by `libghostty-vt`, the renderer-agnostic half, through the MIT Rust bindings. The pixels
become this repo's, and with them the one thing an opaque surface can never give up: **layout**.

Read `docs/20-wire-protocol.md` (unchanged by this document — see §7), `docs/55-ffi-boundary.md` for
the artifact rule, `docs/57-apple-frameworks-in-rust.md` §2 for what `slopdesk-apple-*` may do, and
`ThirdParty/ghostty/README.md` for the fork this deletes.

## 1. What this supersedes

`DECISIONS.md:7` fixes "Renderer = **libghostty** (full surface) … No fallback paths to maintain",
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

We now build on a fork of it, `trancong12102/libghostty-rs` @ `519649e`, and only for soundness.
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

   **UIKit is NOT done.** `PhoneTerminalRendererView` conforms to no text-input protocol at all — it
   reads a hardware keyboard through `pressesBegan` — so the phone has no composition and no
   software keyboard in the terminal. That is a pre-existing shape, not a regression of this work,
   and closing it is a `UITextInput` conformance rather than more renderer work: the preedit pass
   above is already shared.
9. scrollbar geometry, replacing `ghostty_surface_viewport_info` and the `SCROLLBAR` action
10. padding, content scale, resize → cols·rows, which `rust/slopdesk-terminal/src/geometry.rs`
    already computes

Kitty-graphics *rendering* is **out of the bar**: `TerminalConfigBuilder` enables no image token
today, so nothing regresses by not drawing them. vt keeps the state if that changes.

The renderer's home is Rust. `rust/slopdesk-apple-text` already declares itself "the whole of the Core
Text area slopdesk touches" and is in the `slopdesk-apple-*` family, so shaping extends an audited
crate rather than opening a new `unsafe` boundary — no fourth hand-written-`unsafe` crate is proposed
and none is needed.

### 5.2 Search

vt exposes no search. The parity cost is smaller than that sounds, because the expensive half is
already ours: `TerminalFindBarModel.swift` records that libghostty's in-surface search is "a LITERAL
substring matcher with NO regex engine", so regex mode is driven entirely from
`slopdesk_workspace::find_bar`'s match positions and never arms `search:`. What has to be written is
the literal matcher over the grid — the case libghostty was covering.

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

`rust/slopdesk-ffi/src/terminal_surface.rs` carries it across: `slopdesk_term_surface_blocks` hands
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

The one thing a header still cannot show for a scrolled-back block is its **exit code and
duration**. Those live in the command-block ring keyed by `index`/`prompt_ordinal`, which the host's
segmenter assigns; the client's engine exposes only a per-row OSC 133 `A` flag, so nothing ties a
`PlacedBlock` back to a ring entry. `slopdesk_term_surface_block_text` answers what a header can
always know — the prompt rows as rendered. Closing the gap means carrying the ordinal in the mark
itself (`OSC 133;A` with an id the engine surfaces per row), which is a shell-integration change,
not a rendering one.

### 5.4 The editor-like prompt

Built, and it is `rust/slopdesk-terminal/src/prompt/` (4 571 lines): a `TextBuffer` with
grapheme/word/line motions and a goal column, a coalescing `UndoStack`, a shell lexer that decides
both the colours and whether Enter runs, a `CommandHistory` with a walk and a reverse search, and
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
(`Sources/SlopDeskTerminal/MacTerminalPromptView.swift`), reached through a new
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
`⌃L`. Three chords the binding table does not name are read on the Swift side instead: `⌃R` (reverse
search) and ⌘Z / ⇧⌘Z / ⌘Y, which drive the editor's own history rather than
`controls.undo-at-prompt`'s readline byte — while the editor holds the line there is no shell to
send that byte to. `controls.command-prompt` (default on) is the one setting that hands the line back
to the shell.

A reverse search never touches the buffer — cancelling has to give the draft back exactly — so the
band's `(reverse-i-search)` row is the ONLY place its match can appear, and it needs two doors rather
than one: `slopdesk_prompt_search_query` and `slopdesk_prompt_search_hit`. Shipping only the query
plus a `search_has_hit` bool is a search that shows no result, which is what the first pixel render
of the band caught and no test would have.

Three verbs the editor SHADOWS while it is armed, each decided in `docs/DECISIONS.md`: paste goes
into the editor at the driver's single funnel; copy and cut are the editor's only when the grid has
no selection; and PageUp/PageDown/document-edge SCROLLING stays the viewport's, so mounting an editor
cannot take scrollback away.

`InputBarModel.compose` went in the same change — it was the second line editor, and the rule allows
one. `docs/DECISIONS.md` records why the band beat the inline reading `prompt/mod.rs`'s header used
to describe.

Not done: the phone. `PhoneTerminalRendererView` conforms to no text-input protocol, so
`promptView` is `nil` there and the shell's own `readline` is still the editor on iOS — the same
`UITextInput` gap §5.1 already names.

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
falls back to the detector, so the ranking is decided once rather than at each call site. The
engine flags the link per CELL and shares one URI across the run, so the SPAN a menu names is
recovered by walking outwards while the answer stays the same; that walk runs only when the pointer
is already over a link.

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
in the same change. `docs/DECISIONS.md` §"The rows that survived their reader" argues it and names
the two rows that were WIRED instead.

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
