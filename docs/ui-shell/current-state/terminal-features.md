# Terminal Features — Current Implementation State

> Area: Terminal features via the Rust-owned terminal surface
> Originally surveyed 2026-06-25 (E8 interaction-parity rows added 2026-06-26). Re-verified against
> the tree 2026-08-22 for the vendored-fork era, then **re-verified again 2026-08-31 after
> `docs/68-terminal-surface-in-rust.md` landed** (`744e80ab`): the fork this doc used to survey —
> `ThirdParty/ghostty/`, `GhosttyTerminalView.swift`, `GhosttySurface.swift`, the xcframework — is
> **deleted**, and every row below is checked against the tree that replaced it. Paths are
> repo-relative.

## Overview

The client no longer embeds a terminal *application*; it drives a terminal *engine* and draws the
pixels itself. `libghostty-vt` — the renderer-agnostic half of upstream ghostty, reached through the
MIT `aislopware/libghostty-rs @ 519649e` Rust bindings — replaces the deleted fork's full surface
API. That is an org-hosted mirror of `Uzaaft/libghostty-rs @ f4c72b9` carrying one soundness commit
and nothing else; `docs/68` §4 says which UB it closes and why the pin goes home when upstream's issue #75 does.
The pin is a git commit, not a tarball: `ThirdParty/tools/tools.lock`'s `ghostty` record materialises
`ghostty-org/ghostty @ 22d13172cde98a0a4dda05d3d6a3fcb0dd8ed018` into
`ThirdParty/tools/.prefix/ghostty/22d13172`, and `rust/.cargo/config.toml:14` exports
`GHOSTTY_SOURCE_DIR` at it so `libghostty-vt-sys`'s `build.rs` compiles from that tree instead of
cloning at build time. `docs/68-terminal-surface-in-rust.md` is the design doc this whole rewrite is
checked against; read its §4 and §10 before doubting a row below.

**Four new Rust crates meet at one FFI file.** `rust/slopdesk-vterm` wraps `libghostty-vt` itself
(parse, grid, scrollback, selection, key/mouse encoding — no rendering). `rust/slopdesk-termrender`
(`forbid(unsafe_code)`) is the glyph atlas, cell→quad layout and paint passes. `rust/slopdesk-apple-text`
and `rust/slopdesk-apple-metal` are the two audited `slopdesk-apple-*` crates that touch Core Text and
`CAMetalLayer` through `objc2`. All four meet at `rust/slopdesk-ffi/src/terminal_surface/`.

**The FFI boundary is PULL-ONLY — no callbacks cross the C boundary.** `slopdesk-vterm` fills two
bounded sinks during `feed`, and the view drains both after every feed and every resize:
`slopdesk_term_surface_take_pty_replies` (device-status/version replies the terminal owes the pty —
`CSI 6n`, `CSI c`, in-band size reports) and `slopdesk_term_surface_take_clipboard_writes` (OSC 52
writes a program asked for, policy-gated — see the clipboard row below for what changed). Everything
else a program might push — the bell, OSC 9/777/99, OSC 0/2 title, OSC 7 cwd — already arrives as its
own wire message from the host's `superd` sniffer and is deliberately **not** duplicated inside the
engine: one pane can have several attached clients (`docs/45`), and `attachSurface` replays the
retained output ring into a rebuilt surface, which would re-fire every OLD bell, notification and
progress report on every remount if the engine also drained them. Docs/68 §4.1 is the source for this
split.

**The seam is unchanged in shape and address.** `TerminalSurface`
(`Sources/SlopDeskWorkspaceCore/Terminal/TerminalSurface.swift`) is still the protocol — it did **not**
move into `Sources/SlopDeskTerminal/` as an earlier draft of this document claimed. Its live conformers
are `MacTerminalRendererView` and `PhoneTerminalRendererView`
(`Sources/SlopDeskTerminal/{MacTerminalRendererView,PhoneTerminalRendererView}.swift`) — thin
AppKit/UIKit event-plumbing views, in the sense `docs/68` §10 argues: "an `NSView` that receives
`keyDown` and forwards it is the same view before and after; what changed is the C ABI it forwards
INTO." Both hold a framework-neutral `TerminalSurfaceDriver` (`Sources/SlopDeskTerminal/TerminalSurfaceDriver.swift`),
which wraps `TerminalRendererSurface` (`Sources/SlopDeskTerminal/TerminalRendererSurface.swift`), the
one Swift type that owns the Rust handle. Registration is
`Sources/SlopDeskTerminal/TerminalRendererInstall.swift`, called once by each `AppMain.swift`;
`slopdesk-ops enable-renderer` is gone, because the conformer now compiles inside the SwiftPM package.

**The config-file TEXT is gone, and with it the settings that only ever reached it.** A previous
survey of this tree found that most of `rust/slopdesk-terminal/src/config.rs`'s "ghostty
`key = value`" text was dead code nothing read: it used to be handed to the deleted fork's
`ghostty_config_load_string`, and `TerminalConfigBroadcaster.configString` said so in the tree itself.
That emitter, its 507-line FFI face, `TerminalConfigBuilder.swift` and the `TerminalControls` bundle
were **deleted** on 2026-09-01. Every setting the renderer honours now crosses as a typed door, and
every row that had no door left was either given one or removed:

- `slopdesk_term_surface_new(spec, fallback, features, arena, scale, width, height)` — the whole
  `[terminal]` font spec at surface construction: the primary family, the three style families, the
  fallback list, the OpenType features, the size, the cell-height multiplier and thickening.
- `slopdesk_term_surface_set_font(handle, spec, fallback, features, arena)` — the same spec, LIVE.
  Answers the grid the new cell size fits, packed `cols << 16 | rows`, because a font change reflows.
  The WHOLE spec decides whether anything is rebuilt: a `font-feature` line that turned ligatures off
  would otherwise be published and dropped.
- `slopdesk_term_surface_set_theme(handle, foreground, background, selection)` — three colours.
- `slopdesk_term_surface_set_palette(handle, entries, count)` — the ANSI palette, as a prefix.
- `slopdesk_term_surface_set_scrollback(handle, lines)` — the retention depth, in ROWS. The old text
  spelled a byte estimate at 256 bytes a line; the engine's own limit is a row count, so
  `scrollback-limit = 10000` now means ten thousand rows. ⚠️ Only since 2026-09-01 does it MEASURE
  that way: the engine's second cap, on bytes, defaults to 10 000 and prunes first, so the shipped
  10 000-line default kept **1065 rows**. `VtSession::set_scrollback_rows` clears it — 9930 kept —
  and two tests pin the row count and the absence of the byte cap.
- `slopdesk_term_surface_compress_step(handle)` / `_compression_idle_ms()` — ghostty's idle
  scrollback compression, hardwired ON. The step answers the milliseconds until the next call, or a
  negative when the pass is done; `TerminalSurfaceDriver` arms one cancellable task after a feed and
  re-arms at whatever came back. Both intervals are ghostty's and both live in
  `rust/slopdesk-vterm/src/compression.rs` — the Swift side carries no number.
- `slopdesk_term_surface_set_cursor_style/_blink/_color` — each sets the engine's DEFAULT, so a
  `DECSCUSR` or `OSC 12` from a running program still wins. That is what makes them safe to push.
- `slopdesk_term_surface_set_cursor_opacity` / `_set_cursor_text_color` — RENDERER settings, not
  engine ones: no escape names either, so there is no default for a program to override and the paint
  owns them outright.
- `slopdesk_term_surface_set_option_as_alt(handle, value)`.
- `slopdesk_term_right_click(action, has_selection, mouse_captured)` — the whole bare-right-click
  dispatch, not just its paste arm.

The live-reload path is `TerminalSurfaceDriver.applySettings()`, armed on
`TerminalConfigBroadcaster.generation` through `ObservationFollow`: the deleted fork re-parsed a config
STRING, so "the settings changed" is now spelled as those calls. A setting that grows a door and is not
added there is a setting the user can only change by reopening the pane.

**Twelve `[terminal]` rows were deleted rather than doored**, because nothing in this pass was going to
actuate them and a row that resolves silently and changes nothing is worse than a key that does not
exist: `font-weight`, `font-family-fallback` / `-bold` / `-italic` / `-bold-italic`,
`auto-match-weight-style`, `ligatures`, `ligatures-alphabet`, `bold`, `italic`, `blending`, `theme`.
They WORKED under the fork, which parsed the text — this is a regression being codified, not a feature
that never landed. Each comes back with its actuation, in the same change. **Five have (2026-09-01):**
`font-family-fallback` / `-bold` / `-italic` / `-bold-italic` are declared and doored again, and
ligature control returned as `terminal.font-feature` — ghostty's own row and syntax (`-calt, -liga,
-dlig`), which subsumes both `ligatures` and `ligatures-alphabet` without inventing a spelling. New
beside them: `terminal.font-thicken` and `-strength`. The feature row reaches every cell, including a
plain-ASCII one: `Shaper::shape_monospace` would answer such a run out of the cmap, which performs no
substitution, so `substitutes_over_ascii` probes each cut once at `FontStack::new` — every ordered
pair of printable ASCII through `CTLine`, compared against the cmap — and a face that ligates loses
the fast path for its ASCII. The probe reads the CONFIGURED descriptor, so `-calt, -liga, -dlig` hands
the fast path back on the same family. `docs/68` §5.11 has the measurement and the two traps.
`docs/DECISIONS.md`
§"The rows that survived their reader" argues it, and names the two rows that were kept and wired
instead (`terminal.background` / `terminal.foreground`, whose consumer is the headless fallback the
`AppearanceApplier` seam already promised).

The **gesture** settings — copy-on-select, clear-selection-on-typing/copy, allow-mouse-capture,
scroll-multiplier, right-click-action, focus-follows-mouse, trim-trailing-spaces-on-copy — never needed
a door: they are decided on THIS side, read live from `SettingsKey` at the moment of the gesture.
`shift-arrow-select`, `shift-click` and `click-to-move` joined them (2026-09-01) — the first two on
this side, the third through one engine door because only the engine knows where the shell's cursor
is — and `line-height` now stretches the terminal's own cells as well as the code panel's, so no
`controls.*` or `terminal.*` row in the table is unactuated. One HALF of one row still is, and says
so: `shift-click`'s `always`/`never` cannot differ from `enabled`/`disabled` until `libghostty-vt`
exposes a reading of DEC mode 1029.

**The settings GUI is also gone.** `docs/58-configuration.md` (2026-08-24) records the deletion of
every `Settings/` view on both platforms and all onboarding — 82 files. Configuration is file-only now
(`config.toml`), and `TerminalPreferences` is no longer `Codable`. This is why several rows below say
"no live preview exists" independent of whether the underlying value reaches the renderer: there is no
view left to host one.

**Host-side OSC sniffing is unaffected by any of this** — it was already Rust and stays superd-side:
`rust/slopdesk-superd/src/sniffer.rs` (+ `commandblocks.rs`, `blocks.rs`, `autoprogress.rs`,
`shellintegration.rs`). `Sources/SlopDeskHost/HostOutputSniffer.swift` and `CommandBlockSegmenter.swift`
stay deleted from the prior rewrite. **`Sources/SlopDeskHost/HostEnvironment.swift` is now ALSO
deleted** — its `$TERM`/`TERMINFO`/`COLORTERM` job moved to `rust/slopdesk-muxsession/src/spawn_env.rs`
(the curated child environment) and `rust/slopdesk-hostserver/src/gates.rs` (`DEFAULT_TERM`/
`FALLBACK_TERM`), resolving against `rust/slopdesk-probe/src/terminfo.rs`.

This audit covers what the embedder wires up, what the engine/renderer does transparently, and what is
genuinely absent or unwired.

---

## Capability Matrix

| Feature | Status | Evidence file(s)/symbol(s) |
|---|---|---|
| **Selection** (mouse drag) | done — moved | `MacTerminalRendererView.mouseDown/mouseDragged/mouseUp` (`Sources/SlopDeskTerminal/MacTerminalRendererView.swift:257-301`) call `driver.selectPress/selectDrag/selectRelease` (`TerminalSurfaceDriver.swift:297-317`) → `TerminalRendererSurface.swift:248-270` → FFI `slopdesk_term_surface_select_press/_drag/_release` (`rust/slopdesk-ffi/src/terminal_surface/pointer.rs:60-190`) → `rust/slopdesk-vterm/src/selection.rs`, which wraps `libghostty-vt`'s own `selection::gesture` (click-count word/line granularity, drag-past-edge autoscroll, reversal-flips-anchor all live in the engine now). A mouse-reporting program gets first refusal via `sendMouse`'s boolean return. |
| **Selection clipboard** (SELECTION pasteboard) | n/a — permanent, not a migration gap | `TerminalSurfaceDriver.apply(_:)` (`TerminalSurfaceDriver.swift:190-204`) only actuates `TerminalClipboardTarget.standard`: "Apple has no selection clipboard, so a write aimed at one has no destination to land in." The engine still reports `.selection`/`.primary` clipboard-write requests (`rust/slopdesk-vterm/src/events.rs`); they are dropped by design on every Apple platform, exactly as the old fork also dropped them — not something this migration removed. |
| **Copy** (⌘C / context menu) | done — mechanism changed | `TerminalContextMenu.Item.copy` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift:22`) → `TerminalSurfaceDriver.run(_:)` case `.copy, .cut` (`Sources/SlopDeskTerminal/TerminalSurfaceDriver.swift:370-381`): reads `selectionText(.plain)`, runs `ClipboardWritePolicy.decide(confirmRequested:false, text:)`, writes via `ClientPasteboard.shared.write`. `TerminalContextMenu.swift:9-11`'s own doc comment still claims routing "to libghostty-vt (`copy_to_clipboard`…)" — that comment is stale; no such binding-action call exists in the live path. ⚠️ THE ⌘C IN THIS ROW'S TITLE WAS FICTION until 2026-09-01: `MacTerminalRendererView` implemented no `copy:` at all, so the Edit menu's key equivalent walked the responder chain and fell off the end. The context menu worked and the chord did not, which is why three passes of this audit called the row done. It now implements `copy:`/`cut:`/`paste:` and overrides `selectAll:`, each one line into the same `driver.run(_:)`. See the Wiring-gaps note. |
| **Cut** (⌘X / context menu) | done — both halves | `.cut` is its own branch in `TerminalSurfaceDriver.run(_:)`: it asks `CutSelectionPolicy.action(hasSelection:isAlternateScreen:isPromptZone:)`, copies for any non-`.none` answer, and on `.copyAndDelete` sends `CutSelectionPolicy.deleteCount(...)` DEL (`0x7F`) bytes. The prompt-zone term is `TerminalViewModel.isAtEditablePrompt`, the one derivation both platforms read. ⚠️ **The old "delete half counts zero because the GUI passes `selectionEndsAtCursor: false`" reading was stale and is void** (re-checked 2026-09-01): the driver asks the surface — `TerminalRendererSurface.selectionEndsAtCursor()` → `slopdesk_term_surface_selection_ends_at_cursor` → `Frame::selection_ends_at_cursor`, tested in `rust/slopdesk-vterm/src/frame.rs` — and both shells pass that answer. It reads the last DRAWN frame, so a cut fired between a programmatic selection and the next present sees the older geometry and refuses, deleting nothing and degrading to a copy: the safe direction of the two. See note 2 below, which recorded the closure the rows had not caught up with. |
| **Copy receipt chip** | done — the ⌘C path now lights it too | `CopyReceipt.swift` (`Sources/SlopDeskWorkspaceCore/Terminal/CopyReceipt.swift`) is still a pure struct over `slopdesk_copy_receipt`, no framework import. Every driver-side copy goes through one `copyToPasteboard(_:)` that writes AND calls `model?.noteClipboardCopy(text)` — before this pass the driver wrote the pasteboard directly, so the pane's COPIED chip never lit on ⌘C despite the model's own doc claiming it did. |
| **Paste** (⌘V / context menu) | done — moved | `TerminalContextMenu.Item.paste` → `TerminalSurfaceDriver.run(_:)` case `.paste` (`TerminalSurfaceDriver.swift:394-395`) → private `paste(_:bracketing:)` (`:448-475`) → `PastePrecheck.decide` → `surface.encodePaste(text, bracketed:)` (`TerminalRendererSurface.swift:445-456`) → FFI `slopdesk_term_surface_encode_paste` (`rust/slopdesk-ffi/src/terminal_surface/reading.rs:366`) → `libghostty_vt::paste::encode`. Framing (control-byte scrub, LF→CR rewrite when unbracketed, embedded end-marker strip) is the engine's — `docs/68` §4.2. ⚠️ Same correction as the Copy row: the ⌘V was fiction until the `paste:` responder landed 2026-09-01; right-click, middle-click and the context menu were the only ways in. The new responder enters at the same `run(.paste)`, so the precheck and the framing are unchanged — and a paste while the command prompt is armed is redirected INTO the editor at `paste(_:bracketing:)`'s own guard, ahead of the protection sheet. |
| **Paste as keystrokes** | done | Same `paste(_:bracketing:)` path as Paste, with `PasteBracketing.suppress` (`TerminalSurfaceDriver.swift:398-401, 434-437`), which forces `bracketed: false` at the `send(_:bracketing:modes:)` call regardless of the program's own DECSET. No separate raw-text bypass exists any more — it is the same paste door with a different argument. |
| **OSC 52 clipboard read/write** | write done; **read DROPPED** | Write: `TerminalSurfaceDriver.drain()` (`:171-180`) → `apply(_:)` (`:190-204`) → `ClipboardWritePolicy.decide(access:text:)` gated by `SettingsKey.clipboardWrite` → confirm sheet or direct `ClientPasteboard` write. Read: `docs/DECISIONS.md`, "Dropped: the OSC-52 clipboard READ gate… `libghostty-vt` documents that OSC-52 read requests (`?`) are 'always ignored and never forwarded', so no program can ask and there is nothing to gate." `PasteSafetyAnalyzer.Ask.clipboardRead` / `TerminalControls.clipboardRead` remain in the settings model with zero call sites in `Sources/SlopDeskTerminal` — a dormant row over a door that can never fire. (A separate, still-live "metadata clipboard-read" channel the host answers is untouched — a different feature.) |
| **Select All** | done | `TerminalContextMenu.Item.selectAll` → `TerminalSurfaceDriver.run(_:)` case `.selectAll` (`TerminalSurfaceDriver.swift:382-385`): `surface?.selection(.all)`. ⌘A reached it for the first time on 2026-09-01, and it is the one of the four whose ANSWER depends on the arming: `MacTerminalRendererView.selectAll(_:)` selects the LINE BEING TYPED while the editor holds it, the scrollback otherwise. |
| **Scroll (wheel / trackpad)** | done — moved | `MacTerminalRendererView.scrollWheel(_:)` (`MacTerminalRendererView.swift:321-337`): ⌥-scroll diverts to canvas pan; otherwise `driver.sendMouse(action:2, button:4,…)` is tried first so a mouse-reporting full-screen program (vim) can consume the wheel as a report, and only on refusal does `driver.scroll(.rows(rows))` (`TerminalSurfaceDriver.swift:247-251`) move the viewport. |
| **Scroll to top / bottom** | done — moved | `TerminalViewModel.applyAbsoluteJump(_:toTop:)` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:1238-1240`) → `performBindingAction(.scrollToTop/.scrollToBottom.wire)`, wire spellings at `rust/slopdesk-terminal/src/surface_action.rs:157-158,202-203,268-269`. |
| **Scrollback buffer** | done — a live typed door, and the unit changed | `slopdesk_term_surface_set_scrollback(handle, lines)`, pushed from `TerminalSurfaceDriver.applySettings()`. The byte estimate the old text spelled (256 bytes a line) is gone: the engine's limit is a ROW count, so `scrollback-limit = 10000` now buys ten thousand rows rather than whatever that estimate happened to work out to. `FACTORY_SCROLLBACK_LINES` is still the one default, published by the settings table. ⚠️ It only became TRUE on 2026-09-01: the engine keeps a second cap, on BYTES, defaulting to 10 000 and pruning first, so the shipped ten-thousand-line default was keeping **1065 rows** — measured, at 80 columns, against **9930** with that cap cleared. `VtSession::set_scrollback_rows` clears it and no longer takes an `Option`; `the_configured_depth_is_the_depth_the_session_keeps` and `setting_a_depth_leaves_no_byte_cap_underneath_it` pin both halves. |
| **Idle scrollback compression** | done — hardwired on, no setting | ghostty's, taken whole: the engine compresses fully historical pages and restores them transparently on the next read (10–30% of uncompressed page memory, per ghostty's own configuration). `rust/slopdesk-vterm/src/compression.rs` holds ghostty's two intervals (250 ms of quiet, 1 ms between steps) and the engine's activity token; `VtSession::compress_step` answers a delay in milliseconds through `slopdesk_term_surface_compress_step`, and `TerminalSurfaceDriver.scheduleCompression(after:)` owns one cancellable task, armed after a feed only when nothing is armed. ⚠️ NOT the display link, which stops when the view leaves the window — the background pane taking output nobody is watching is exactly the one worth compressing. No setting: it changes storage and never contents, so there is no behaviour to prefer; the knob is the DEPTH, which already exists. |
| **Cursor shape / blink / colour / opacity** | done — four live typed doors, and the DEFAULT/LIVE split is the point | `set_cursor_style`, `_blink` and `_color` set the engine's DEFAULT, so a program's `DECSCUSR` or `OSC 12` still wins — which is what makes a user setting safe to push at all. `_cursor_opacity` and `_cursor_text_color` are RENDERER settings by contrast: no escape expresses either, so there is no engine default for a program to override and the paint owns them. All five ride `applySettings()`. |
| **Mouse modes (X10/1000/1002/1003/SGR)** | done — now wholly the engine's | Swift carries no reporting-mode state at all any more: every pointer handler calls `driver.sendMouse(...)` and branches on the **boolean return** (`false` = "not tracking", fall back to the view's own gesture). FFI `slopdesk_term_surface_mouse` (`rust/slopdesk-ffi/src/terminal_surface/doors.rs:567`) defers to `rust/slopdesk-vterm/src/input.rs`'s `MouseEncoder` over `libghostty_vt::mouse::Encoder`, which owns mode selection from the DECSET the program sent. |
| **Mouse pressure / force-click** | **dropped — undocumented** | No `pressure` symbol anywhere in `Sources/SlopDeskTerminal`, `rust/slopdesk-vterm`, or `rust/slopdesk-ffi/src/terminal_surface/`; no `NSEvent` pressure override in `MacTerminalRendererView.swift`. Unlike OSC-22 pointer shape (`docs/DECISIONS.md`), it has no entry of its OWN — but the drop is not undocumented, and this row said it was until 2026-09-01: the trackpad gesture audit already struck it by name ("❌ **Rotate, force-click/pressure, Quick Look**: dropped (no universal equivalent / not faithfully synthesisable)", `docs/DECISIONS.md`). That ruling is about forwarding a pressure gesture to the HOST, and a terminal pane has no second reading of the same event to make: there is no escape sequence for stage-2 force and no program that could receive one. So the feature gap is real and the documentation gap is not. |
| **Kitty keyboard protocol** | done — moved | Encoding: `rust/slopdesk-vterm/src/input.rs` (`Keyboard::encode`) + `keycode.rs` (`key_from_macos_keycode`), reached via `slopdesk_term_surface_key` (`rust/slopdesk-ffi/src/terminal_surface/doors.rs:515`). Swift call site `MacTerminalRendererView.send(_:action:composing:)` → `TerminalRendererSurface.encodeKey` (`:206-225`). The old "Ctrl+C0 fast path" special case is gone — `libghostty-vt`'s own encoder does ctrl-letter→C0 translation uniformly now. |
| **IME / CJK input (macOS)** | done — closed 2026-08-31 | `MacTerminalRendererView` conforms to `NSTextInputClient`. `keyDown` offers the press to `interpretKeyEvents` FIRST and encodes only what the input method declines; a commit arrives through `insertText`, a composition through `setMarkedText`, and a press the composition consumed (⎋ cancelling a half-typed syllable) is sent flagged `composing` so the engine reports it and encodes nothing. `firstRect(forCharacterRange:)` answers off `slopdesk_term_surface_caret_rect`, so the candidate window hangs under the real cell rather than under `row × cellHeight` — with blocks those differ. The preedit is DRAWN, not fed to the engine: `slopdesk_term_surface_set_marked_text` → `slopdesk-termrender`'s `Preedit` pass, measured in cells by the engine's own segmenter (`slopdesk_vterm::text_cells`). ⚠️ An Option the user gave to Alt skips the input context entirely — see `docs/68` §5.1 item 8 for why the two are exclusive. |
| **IME / CJK input (iOS)** | done — **path moved** | `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift` does not exist. The real responder is `TerminalInputHostView: UIView, UIKeyInput`, nested in `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift`, which reads a `UIKey` into `PhoneKey.Press` and asks `rust/slopdesk-workspace/src/phone_key.rs::route` which of two paths it takes — raw encoder vs. the UIKit text-system proxy that commits via `insertText`. Copy Mode / Hint Mode are asked ABOVE that split via `TerminalViewModel.takeModalKey` (`TerminalViewModel.swift:752`). The `UITextInput` half — marked text and the space-bar floating cursor — landed 2026-09-01 in `Sources/SlopDeskPhoneUI/Pane/TerminalTextInput.swift`: the composition crosses the seam as `setComposition(_:selection:)`, the caret comes back as `caretAnchor` (band or grid, since the two views are siblings on this platform), and the drag reads `slopdesk_phone_floating_cursor_steps` when the app's own line editor owns the prompt so a drag arrives as the editing verb an arrow press does. Every text trait is turned off explicitly — adopting `UITextInput` otherwise opts a shell line into smart quotes and smart dashes. Verified in PIXELS by `Apps/ClientApp-iOS/Tests/TerminalPreeditPixelsOnIOSTests` — the band is `CGContext`, so only the Metal GRID needs the readback this tree cannot do. |
| **Unicode / text styles** (bold, italic, dim…) | done — moved | SGR attribute rendering is `rust/slopdesk-termrender/src/paint.rs` (`PaintStyle`, `DecorationKey`, ~41-111) using glyphs from `glyph.rs` (`Synthetic{bold,italic}`). No embedder involvement, same delegation model, different renderer. |
| **True colour / 256-colour** | done — moved | `COLORTERM=truecolor` now set in `rust/slopdesk-muxsession/src/spawn_env.rs` (`curated()`, ~line 145, tested ~229). `Sources/SlopDeskHost/HostEnvironment.swift` is deleted. |
| **Box-drawing / powerline glyphs** | done — moved | No dedicated code: ordinary glyphs shaped by Core Text through `rust/slopdesk-apple-text/src/shape.rs`, rasterized/cached by `slopdesk-termrender`'s glyph atlas — the same delegation the old fork used, over this repo's renderer instead of libghostty's. |
| **Font family, size, weight** | done and LIVE, faces included | `slopdesk_term_surface_set_font(handle, spec, fallback, features, arena)` rebuilds the face stack on any `TerminalConfigBroadcaster` generation, through `TerminalSurfaceDriver.applySettings()`. It answers the grid the new cell size fits (packed `cols << 16 | rows`), so a font change reflows and mirrors a resize to the host like a layout pass does; a family Core Text cannot resolve leaves the current stack standing rather than refusing to draw. ⚠️ It deliberately does NOT settle before the first layout — `bind` applies settings synchronously, so settling there would mirror the placeholder frame's grid to the host as a spurious SIGWINCH. Construction reads the same spec through `slopdesk_term_surface_new`. Bold/italic are synthesized via `CTFontSymbolicTraits` only where the family HAS no cut and the user named no face for it: `terminal.font-family-bold` / `-italic` / `-bold-italic` are taken at their word, a name the system does not have falls back to the primary's own cut (ghostty's rule), `terminal.font-family-fallback` prefixes Core Text's cascade list, `terminal.font-feature` carries ghostty's syntax for ligature control, and `terminal.font-thicken` strokes every glyph. Glyph BLENDING remains undoored — it is a renderer decision rather than a face one. See `docs/68` §5.11. |
| **Theme / palette** | done — both doors live, and the hex round-trip is bypassed | `slopdesk_term_surface_set_theme(handle, foreground, background, selection)` plus `slopdesk_term_surface_set_palette(handle, entries, count)` (the ANSI palette as a PREFIX of `0x00RRGGBB` words from index 0 — apart from `_set_theme` because a theme always states its three colours while a palette is optional, and a config naming none must leave the engine's own 256 standing). Both are pushed from `TerminalSurfaceDriver.applySettings()`. The colours travel as packed `UInt32` words: `ResolvedTerminalTheme` carries the same numbers `SlateTheme` holds natively, which `ClientTerminalPalette` fills straight from the profile's literals. The 6-hex twin that used to ride alongside was always a `hex6` OF these numbers for the deleted fork's parser, and it went with the parser. ⚠️ Install order matters and both shells already have it: `ClientTerminalPalette.install()` runs BEFORE the composition builds `PreferencesStore`, or the first config a pane sees resolves against an unfilled closure. The engine's own damage tracking counts CELLS and a theme change touches none, so `slopdesk-vterm`'s session sets a `refill` flag in both colour doors — without it a theme change would sit invisible until the user happened to type. The "ONE APPEARANCE" ruling (ChooseR removed 2026-08-08) still stands as a comment at `Sources/SlopDeskSlate/SlateDesign.swift:44`. |
| **$TERM** | done — moved | `rust/slopdesk-hostserver/src/gates.rs`: `DEFAULT_TERM = "xterm-ghostty"` (~line 38), `FALLBACK_TERM = "xterm-256color"` (~line 45). Resolution: `rust/slopdesk-probe/src/terminfo.rs`. `Sources/SlopDeskHost/HostEnvironment.swift` is deleted. `xterm-ghostty` stays the advertised entry even with the fork gone — the client still renders through `libghostty-vt`, so the kitty-keyboard/DEC2026-capable terminfo entry is still the right target. |
| **TERMINFO propagation** | done — moved | `rust/slopdesk-muxsession/src/spawn_env.rs`: `MIRRORED_KEYS` (~37-47) mirrors `TERMINFO`/`TERMINFO_DIRS` to the child, tested at ~261-290. |
| **OSC 0/2 window title** | done — moved, superd-side, unaffected by the terminal-surface rewrite | `SniffEvent::Title` at `rust/slopdesk-superd/src/sniffer.rs:399` (drifted from the old `:82`). OSC 1 (icon name) still deliberately ignored. |
| **BEL / bell** | done — moved, superd-side | `SniffEvent::Bell` at `sniffer.rs:260`, ground-state only. |
| **Shell integration (OSC 133)** | done — moved on both ends; client tracker deliberately stays independent of the engine | Host: `sniffer.rs:426,436` (`CommandStatus::Idle{…}`) + `rust/slopdesk-superd/src/commandblocks.rs`. Client: `Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` (confirmed 102 lines) over `rust/slopdesk-terminal/src/tracker.rs`. The tracker's module doc states explicitly it does **not** delegate to `slopdesk-vterm`'s own screen state even now that libghostty-vt is the engine — there is no engine handle to query from a pure policy crate, and `CutSelectionPolicy` and friends need mode state independent of any live render session (`docs/68` §5.3 is cited as the standing plan). |
| **OSC 7 working directory** | done — moved, superd-side | `SniffEvent::Cwd` at `sniffer.rs:373`. |
| **OSC 133 prompt jump** | done — mechanism fully moved to Rust | `SurfaceAction::JumpToPrompt` (`rust/slopdesk-terminal/src/surface_action.rs:160-333`); landing-flash geometry `rust/slopdesk-terminal/src/prompt_flash.rs` (`anchor_rows`, ~line 60, 10 unit tests incl. wrapped prompts and starship spacer rows). Overlays: `Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift`, `Sources/SlopDeskPhoneUI/Pane/PromptJumpFlashOverlayView.swift` (phone file carries a `View` suffix now), shared `Sources/SlopDeskClientCore/Pane/PromptJumpFlashGeometry.swift`. |
| **Notifications (OSC 9 / 777 / 99)** | done — moved, superd-side; client chain unchanged | `SniffEvent::Notification` at `sniffer.rs:463,486,539`. Delivery: `PaneNotificationRouter` (`Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift:377`, exact match), wired from `Sources/SlopDeskMacUI/SlopDeskMacApp.swift` and `Sources/SlopDeskPhoneUI/PhoneAppDelegate.swift:159`, through `Sources/SlopDeskClientCore/App/ClientNotificationSinks.swift`. |
| **Long-command completion notifications** | done | `CommandNotificationPolicy` in the same `CommandCompletionNotifier.swift`; `longRunningThresholdMS` is now FFI-backed (`CommandCompletionNotifier.swift:17`). `SettingsKey.longCommandNotificationsEnabled` now at `SettingsKey.swift:201` (line drifted from the old `:146`). |
| **OSC 9;4 progress state** | done — unchanged mechanism, superd-side | `SniffEvent::ProgressBody` at `sniffer.rs:460`. `rust/slopdesk-superd/src/autoprogress.rs`, `Sources/SlopDeskProtocol/ProgressState.swift`, `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Progress.swift` all confirmed present and unchanged. |
| **In-terminal search (⌘F)** | done — ONE engine, the two-engine split is CLOSED | `TerminalFindBarModel` holds no matcher: `slopdesk_term_surface_find(needle, caseSensitive, wholeWord, regex)` runs all four modes in `rust/slopdesk-vterm/src/search.rs` (`Matcher`, compiled once per query) and answers a count; `slopdesk_term_surface_find_position` reads back the cursor for `N of M`; `navigate_search:` steps it. The old row-driven branch — the bar scanning `slopdesk-rowscan` itself and scrolling by `scroll_to_row:` whenever the surface could not express a mode — is deleted along with `slopdesk_ws_find_bar_row_driven`, `_find_reanchor` and `_find_step`. `slopdesk-rowscan::find` survives as ⇧⌘F's cross-pane scan only (`ScrollbackMatcher.swift`), which is a snapshot over line indices rather than a second answer about the live grid. Phone file is `Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift`. |
| **Copy-mode** (vi-like keyboard scrollback nav) | done — unchanged mechanism, lines drifted +~40-45 | `TerminalViewModel.swift`: `enterCopyMode()` `:1353` (was 1311), `exitCopyMode()` `:1368` (was 1326), `handleCopyModeKey(_:)` `:794` (was 753), `takeModalKey` `:752` (was 711). `MacViModeOverlay.swift` confirmed; phone file is `ViModeOverlayView.swift` (not `ViModeOverlay.swift`). |
| **Vi visual-char selection in copy-mode** | done — mechanism moved, a real gain | `TerminalSurface.setSelection(anchor:head:rectangle:)` still declared in `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSurface.swift` (~line 317, NOT moved to `SlopDeskTerminal`); implemented at `TerminalRendererSurface.setSelection` (`Sources/SlopDeskTerminal/TerminalRendererSurface.swift:493-503`) → `slopdesk_term_surface_set_selection` → `rust/slopdesk-vterm/src/selection.rs`, which wraps `libghostty-vt`'s own `selection::gesture` module — `docs/68` §4 calls this "a gain, not a gap": click/select_word/select_line/select_output/rectangle/adjust/format are all richer than what the fork exposed. `rust/slopdesk-terminal/src/vimotion.rs` (word/column motions) is unchanged. `MacViCursorOverlay.swift` confirmed; phone file is `ViCursorOverlayView.swift`. |
| **Right-click context menu** | done — the menu itself is built again, item list unchanged (14 items) | `TerminalContextMenu.Item` (`TerminalContextMenu.swift:18-37`): copy, cut, paste, pasteAsKeystrokes, pasteSelection, pasteFileBase64, pasteEscaped, pasteBracketed, selectAll, clear, copyOutput, splitRight, splitDown, find. The fork's deletion took the actual `NSMenu` with it; `MacTerminalRendererView.menu(for:)` builds it from the model again (`autoenablesItems = false`, enablement from `TerminalContextMenu.isEnabled`, "Paste as…" as a submenu, a detected link's own actions when the click lands on one). The phone's twin is a `UIEditMenuInteraction` presented on long-press release. `pasteToComposer` confirmed still gone repo-wide. |
| **Per-block context menu** (right-click IN a block) | done — added 2026-09-01, Warp parity | `TerminalContextMenu.BlockItem`: Copy Command · Copy Output · Re-Run Command ‖ Collapse/Expand Block · Bookmark/Remove Bookmark, prepended with a separator when the click landed inside a laid-out block. The gap it closes: `Item.copyOutput` acts on the LATEST block, because it is also the keyboard verb and a keystroke has no pointer; Warp acts on the block under the pointer. Both stay. Rules in `slopdesk_terminal::context_menu` (`BlockItem`/`BlockContext`, seven gates), words and enablement across `slopdesk_term_menu_block_items` / `_block_item` / `_block_enabled`, the hit-test in `slopdesk_term_surface_block_target`, and one dispatcher — `TerminalSurfaceDriver.run(_:ordinal:)` — for both shells. ⚠️ Two rules the shape turns on: the menu stashes the **prompt ORDINAL**, never the layout index, because output arriving while a menu is open re-segments the list (the fold resolves the index again at action time, `_toggle_block_collapsed_at_ordinal`); and it acts on the **clicked pane's** model rather than `WorkspaceStore`'s active-pane conveniences, since a right-click does not necessarily focus a pane. Re-Run greys under the read-only lock as well as being refused at `sendInput`. |
| **Right-click action** | done — the WHOLE dispatch is one Rust decision now | `slopdesk_terminal::surface::right_click(action, has_selection, mouse_captured)` answers `Forward · Paste · Copy · Menu · Ignore`; `RightClickPolicy` (`Sources/SlopDeskWorkspaceCore/Terminal/RightClickPolicy.swift`) is its face and `MacTerminalRendererView.rightMouseDown` the actuator. It replaced a boolean (`right_click_intercepts_as_paste`) that answered only the paste arm — which is why `copy`, `copy-or-paste`'s copy half and `ignore` were all silently the menu: a drawn, persisted setting with three dead values. A mouse-reporting program outranks every arm, including `ignore`, which would otherwise eat a click the program is waiting for; ⌃-right still short-circuits to the menu before the policy is asked, because the modifier is the user overriding their own default. The paste arm exists so a right-click paste passes the four-danger `PastePrecheck` a dispatch inside the engine could never reach, and the selection is read BEFORE the click is forwarded so it is the genuine pre-click one. |
| **Copy-on-Select** | done — decided on THIS side, so it never needed a door | `TerminalSurfaceDriver.selectRelease(...)` reads `SettingsKey.copyOnSelectEnabled` live and copies the finished selection. `config.rs:433-440`'s `copy-on-select` line stays dead text, but it was never the path: the engine has no clipboard, so who copies a completed drag is the embedder's question by construction. |
| **Trim trailing spaces on copy** | **done** — the gap verdict was stale | Live end to end: `controls.trim-trailing-spaces` → `SettingsKey.trimTrailingSpacesOnCopyEnabled` → `TerminalSurfaceDriver.applySettings` (`:348`) → `TerminalRendererSurface.setTrimTrailing` (`:340`) → `slopdesk_term_surface_set_trim_trailing` (`rust/slopdesk-ffi/src/terminal_surface/doors.rs:920`) → `VtSession::set_trim_selection`, read by `selection.rs`'s two `with_trim` call sites. The dead `config.rs:443` text this row cited went with the emitter (`docs/68` §5.6); the door replaced it rather than dying with it. |
| **Clear selection on typing / on copy** | done — both live, both this side's | `SettingsKey.clearSelectionOnTypingEnabled` is read in `TerminalSurfaceDriver.sendKey`, gated on the key actually producing bytes so a bare modifier does not drop the selection; `clearSelectionOnCopyEnabled` is folded into the one `copySelection()` every copy path goes through. `config.rs:444-445` stays dead text for the same reason copy-on-select's line is. |
| **Shift+Arrow select** (`controls.shift-arrow-select`) | done — the toggle drives copy-mode's own machinery | `TerminalSurfaceDriver.sendKey` reads the setting live and asks `TerminalBindingAction.Edge.shiftArrow(keyCode:mods:)` — a face over `slopdesk_term_shift_arrow_edge`, which is where the modifier rule lives so the lock and side bits are masked in ONE language (a right-shift press carries `SHIFT \| RIGHT_SHIFT`, and Caps Lock rides along on every press). A recognised edge runs the existing `adjust_selection:<dir>` binding; the engine REFUSES it when nothing is selected (`rust/slopdesk-vterm/src/screen.rs` — inventing a selection from the cursor would select in a pane the user never clicked), and that refusal is the fall-through, so a TUI that binds ⇧→ still receives it. |
| **Paste Protection sheet** | done — analyzer unchanged, location moved | `PasteSafetyAnalyzer.swift` / `PastePrecheck.swift` unchanged in role. The sheet itself moved: `Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift` → `Sources/SlopDeskTerminal/PasteProtectionSheet.swift`; phone card is `Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCardView.swift` (drifted from `ClipboardConfirmCard.swift`), over shared `Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift`. Presented from `MacTerminalRendererView.confirm(_:preview:dangers:_:)` (`:346-355`) and `PhoneTerminalRendererView`'s static `confirm(...)` (`:296-306`, via the `ClipboardConfirmRequests` mailbox — UIKit cannot present synchronously mid-drain). |
| **Paste as…** | done — minus one item, mechanism moved | `PasteTransform.swift:9-19` confirms `.bracketed` deleted (framing moved to the engine, `docs/68` §4.2); `.shellEscaped`/`.base64(ofFileBytes:)` remain. `pasteToComposer` still dead (Composer deleted `92472b0a`, 2026-07-03). |
| **Hide mouse while typing** | done — corrects a stale claim made earlier in this same rewrite pass | `MacTerminalRendererView.keyDown` (`MacTerminalRendererView.swift:169-178`) reads `SettingsKey.mouseHideWhileTypingEnabled` live and calls `NSCursor.setHiddenUntilMouseMoves(true)` **before** the chord interceptor runs, "so a swallowed chord still hides the pointer." `docs/DECISIONS.md`: "Not dropped, and never needed an engine… It lives in the view, costs no door and no vterm change." |
| **Allow-mouse-capture** | done — this side's veto over the engine's encoder | `TerminalSurfaceDriver.sendMouse` refuses before it reaches `slopdesk_term_surface_mouse` unless `SettingsKey.allowMouseCaptureEnabled`, so a program that asked for the pointer is denied it at the embedder rather than in the engine — which is the only place the answer can be a user setting. |
| **Allow-shift-with-click** (`controls.shift-click`) | done — this side's second veto over the engine's encoder | `MacTerminalRendererView.mouseDown` takes the click BACK off a mouse-reporting program when ⇧ is held and `SettingsKey.allowShiftClick.extendsSelection` says so — which is how a selection is made over a full-screen TUI at all. The stored value is four-way and the reading is binary by RULE (`MouseShiftCapture.extendsSelection`, so a stale `always` cannot read OFF), and one half is honestly not actuated: a program's ability to OVERRIDE the bypass (DEC mode 1029) has no reading in `libghostty-vt`, so `always`/`enabled` behave alike, as do `never`/`disabled`. |
| **Click to move the cursor** (`controls.click-to-move`) | done — one engine door, because only the engine knows where the cursor is | `VtSession::click_to_move(column:row:)` (`rust/slopdesk-vterm/src/session.rs`) answers the `←`/`→` presses that walk the shell's cursor to a clicked cell, through the key encoder so DECCKM picks `ESC [ C` vs `ESC O C`. Counted in GLYPHS, not columns — a wide character is two cells and one press. Refused on the alternate screen, under a mouse-reporting program, and for any row but the cursor's: `↑`/`↓` are HISTORY at a prompt, so crossing rows would replace the half-typed command the user clicked into. The client adds the one question the engine must not answer twice — `TerminalSurfaceDriver.isPromptZone`, the same OSC-133-plus-live-connection reading ⌘Z uses. Actuated from `MacTerminalRendererView.mouseUp` (only when the gesture selected nothing) and `PhoneTerminalRendererView.handleTap`. |
| **Scroll multiplier** | done | `MacTerminalRendererView.scrollWheel(_:)` multiplies `event.scrollingDeltaY` by `SettingsKey.scrollMultiplierValue` BEFORE rounding to rows, so a fractional multiplier still moves the viewport instead of rounding away. `config.rs:471-473`'s line stays dead text; the viewport is the embedder's, so this was never a door. |
| **Option-as-Alt** | done — a live typed door | `TerminalSurfaceDriver.applyOptionAsAlt()` reads `SettingsKey.optionAsAlt.surfaceCode` and calls `surface.setOptionAsAlt(_:)` → FFI `slopdesk_term_surface_set_option_as_alt` (`terminal_surface/doors.rs:641`). It is re-pushed on every `applySettings()`, not only on attach, so the setting live-reloads. |
| **Mouse-over-to-focus** | done — actuator written | `MacTerminalRendererView.mouseMoved` and a `mouseEntered` override both call `requestFocusFollowsMouseIfNeeded()`, which asks `FocusFollowsMousePolicy.shouldRequestFocus(focusFollowsMouse:isAlreadyFocused:)` with the setting read LIVE — so a Settings toggle takes effect on the next hover rather than the next mount — and calls `model?.onRequestFocus?()`. `isAlreadyFocused` comes from a view-local mirror written by exactly one method (`pushFocus(_:)`, called from `init`, `becomeFirstResponder`, `resignFirstResponder`, `setPaneFocused`): the model has no `isFocusedPane` of its own, despite five files' prose naming one. |
| **OSC-22 pointer shape** | dropped | `docs/DECISIONS.md`: `libghostty-vt` parses OSC 22 but `Terminal` exposes no handler. `rust/slopdesk-terminal/src/pointer.rs`, `rust/slopdesk-ffi/src/pointer_shape.rs`, `PointerShapeMapping.swift`, `MouseVisibilityMapping.swift` and their test suites are all deleted, along with the `pointer-tables-one-table` invariant. |
| **Cursor colour / opacity / text** | done — this row read "**gap**, was done" until 2026-09-01 and was STALE: it cited a `config.rs` that no longer exists and a missing door that does | The whole path is live and each hop is named above: `rust/slopdesk-settings/src/config/table.rs:682,687,692` (`terminal.cursor-color`, `terminal.cursor-text-color`, `terminal.cursor-opacity`) → `TerminalPreferences.cursorColorWord` / `.cursorTextColorWord` / `.cursorOpacity` → `PreferencesStore.applyTerminal()` (`:154-156`) → `TerminalSurfaceDriver.applySettings()` (`:342-344`) → `slopdesk_term_surface_set_cursor_color` / `_set_cursor_text_color` / `_set_cursor_opacity`. See the "Cursor shape / blink / colour / opacity" row for the DEFAULT-vs-RENDERER split that makes each safe to push. What IS gone is the live preview — `find Sources -iname "*CursorPreview*"` returns nothing, because the Settings GUI that hosted it was deleted 2026-08-24 (`docs/58-configuration.md`). Authored in `config.toml`, previewed nowhere, actuated on every attach. |
| **Cursor smooth animation** | removed — citation now fully dead, not just stale | `Tests/SlopDeskVideoProtocolTests/Settings/TerminalPreferencesDecodeTests.swift` no longer exists; that directory holds only `KeybindConfigLoaderTests.swift`/`KeybindGrammarTests.swift`. `cursorAnimation` appears nowhere in Swift or Rust. The regression test that pinned "the retired key decodes and is ignored" is gone along with `TerminalPreferences`'s `Codable` conformance (removed with the settings GUI, `docs/58`). The underlying claim — no field, no setting row — still holds; nothing pins it any more. |
| **Scroll-past-last / first** | removed 2026-07-30 — confirmed clean | `grep -rIn -i scrollpast Sources rust/slopdesk-*/src` still returns nothing. |
| **Smooth scroll** | removed 2026-07-30 — confirmed clean | `grep -rIn -i smoothScroll Sources rust/slopdesk-*/src` still returns nothing. |
| **Backspace-deletes-selection** | removed — its successor is wired and counts | `BackspaceSelectionPolicy` confirmed still absent. The stated successor (⌘X via `CutSelectionPolicy`) has both the actuator the older audit found missing and the `selectionEndsAtCursor` answer the one after it thought was still hardcoded — see the Cut row. |
| **Editor-like command prompt** (Warp-class) | done on both, with one implementation | MOUNTED 2026-09-01 on macOS and iOS. `rust/slopdesk-terminal/src/prompt/` (buffer, undo with coalescing, shell lexer, history with ⌃R, fzf completion) → 47 doors in `rust/slopdesk-ffi/src/prompt.rs` → `Sources/SlopDeskWorkspaceCore/Terminal/CommandPrompt.swift` → drawn by `Sources/SlopDeskTerminal/TerminalPromptBand.swift`, a BAND along the pane bottom reached through the new `TerminalSurfaceHosting.promptView`. It takes no keyboard focus: `MacTerminalRendererView` stays the pane's one responder and routes from `keyDown` via `editsPrompt(_:)`, above the input method and below copy mode, so the focus region and the whole IME stack are untouched. Every editing chord arrives as an AppKit SELECTOR through `interpretKeyEvents`, which is what supplies ⌥←, ⌃A and ⇧⌘→ without a chord table. Four control keys are carved out in Rust (`prompt::keys`): ⌃C, ⌃D on an empty line, ⌃Z, ⌃L. Enter runs only a SYNTACTICALLY CLOSED document — an unclosed quote adds a line and the band names what is open. Gated by `controls.command-prompt` (default on), the one setting that hands the line back to the shell. Three chords the binding table does not name are read on the Swift side: ⌃R, and ⌘Z / ⇧⌘Z / ⌘Y for the editor's own history. Three verbs it SHADOWS while armed — paste (into the editor, at the driver's one funnel, ahead of the protection sheet), copy/cut (the editor's only when the grid has no selection), and PageUp/PageDown/document-edge scrolling, which stay the VIEWPORT's so mounting an editor cannot take scrollback away. `InputBarModel.compose` was deleted in the same change: one line editor, not two. ⚠️ First PIXEL-VERIFIED 2026-09-01 (five off-screen renders — plain line, selection, candidates, ⌃R, continuation), which found one defect no test could: the ⌃R row printed the query and stopped, because only a `search_has_hit` BOOL crossed the FFI. `slopdesk_prompt_search_hit` now carries the matched entry and the row reads `` `query': hit`` like bash's; `TerminalPromptBand.searchRow(query:hit:)` is pure so `testTheSearchRowShowsTheHitItWouldAccept` pins it. ⚠️ The PHONE landed the same day and is not a port: `TerminalPromptBand` is the whole band on both platforms — Core Text, `CGContext` and `SlateNativeColor`, no AppKit and no UIKit — with a ~100-line view shell each side. The phone gets its chords from `slopdesk_prompt_key_action`, because UIKit has no key-binding table and a Swift one would be the decision leaving Rust; the view only NAMES the key, off the USB HID keyboard page (`PhoneKey.promptKey(_:)`). Mounting it also collapsed the pane onto ONE first responder — see wiring gap 9. ⚠️ The phone's last open item CLOSED 2026-09-01: `Sources/SlopDeskPhoneUI/Pane/TerminalTextInput.swift` conforms the responder to `UITextInput`, so the inline preedit underline is drawn on both platforms now — by the SAME `TerminalPromptBand`, since the drawing was never the gap. Two seam members carry it (`setComposition(_:selection:)`, `caretAnchor`) because the phone's text client is a SIBLING of the pixels, and the conformer picks band-or-grid so that fork is written once per platform. It also ended `FloatingCursor`'s wait — UIKit hands a space-bar drag only to a text input — and turned up one live defect on the same seam: the phone's `insertText` had no `isSearching` fork, so a soft-keyboard character typed into an open ⌃R went into the LINE instead of the query. |
| **Undo at prompt** | done on BOTH — the Mac gap is closed | `PromptEditPolicy` wraps `slopdesk_term_prompt_edit_byte`. `MacTerminalRendererView.keyDown` asks `takesPromptEdit(event)` right after `editsPrompt(_:)` and, when the policy answers a byte, sends it and returns; the phone's call site in `TerminalLeafView.swift` is unchanged. Both read the prompt zone from the SAME derivation — `TerminalViewModel.isAtEditablePrompt` (connected AND OSC-133 idle AND not the alternate screen) — rather than spelling three ANDs out twice, which is what the second call site made worth extracting. ⚠️ THE ORDER IS NOW LOAD-BEARING: while the app's editor is armed `editsPrompt` shadows this row entirely and ⌘Z / ⇧⌘Z / ⌘Y drive the editor's OWN history instead, ungated by `controls.undo-at-prompt` — that setting is about emitting a readline byte, and there is no shell holding the line to emit it to. This row therefore describes what happens when the editor is NOT armed. Redo stays unanswered on the BYTE path on both platforms: readline binds `C-_` to undo and exposes no inverse, so there is no portable keystroke to send. |
| **Hyperlinks (OSC 8)** | done — closed 2026-08-31 | ⚠️ This row read "gap — real regression, zero hits" until 2026-08-31 and was STALE from the moment the engine landed: `CellFlags::HYPERLINK` (`frame.rs`), `VtSession::hyperlink_at` (`screen.rs`) and `slopdesk_term_surface_hyperlink_at` all arrived with `744e80ab` and the doc was not re-run. What was genuinely missing was the UI: the door had zero callers. It now has one — `TerminalSurfaceDriver.link(at:cwd:slop:)` asks the AUTHORED question first and falls back to `TerminalLinkDetector`, and both the Mac's context menu / ⌘-hover and the phone's long press go through it, so the ranking is decided once. The span a menu names comes from `slopdesk_term_surface_hyperlink_runs`, added 2026-09-01: `VtSession::hyperlink_runs` splits the frame's flag runs wherever the URI changes and classifies each through `slopdesk_terminal::link::authored`. That deleted two Swift spellings in `TerminalSurfaceDriver` — the outward per-cell walk that used to recover the span, and a `URL(string:)`-based twin of the `file://` classification — leaving a hit test against runs the engine already split. `_hyperlink_spans` stays for the UNDERLINE: flag-only, no engine call, and two abutting links merged into one stroke is the same picture, which is exactly the merge an actuating caller must not take. "Auto-Detect Link Schemes" deliberately does NOT gate the authored path — see `docs/68` §5.5. |
| **Plain-text link/path detection, ⌘-click, ⌘-hold highlight** | done — one filename correction | `TerminalLinkDetector.swift`/`TerminalLinkHitTest.swift` confirmed live at their stated paths; `LinkActionPolicy.swift` confirmed at `Sources/SlopDeskWorkspaceCore/Workspace/Domain/LinkActionPolicy.swift`. `MacLinkHighlightOverlay.swift` confirmed; phone overlay is `Sources/SlopDeskPhoneUI/Pane/LinkHighlightOverlayView.swift` (not `LinkHighlightOverlay.swift`). The old `link-url = false` line is gone with the config text — vestigial anyway, since `libghostty-vt` has no "own regex matcher" to disable (that was the FULL ghostty fork's feature). ⚠️ `SettingsKey.linkDetectionEnabled` now gates the DETECTOR alone: an `OSC 8` span the program authored is read either way and underlined through `LinkUnderlineGeometry.strokes(authored:detected:metrics:)`, which drops a detected guess that overlaps a declared one. |
| **Bracketed paste (DECSET 2004)** | done — mechanism moved | `pasteBracketed` still a live `TerminalContextMenu.Item` case, forced through `TerminalSurfaceDriver.PasteBracketing.force` (`:432-435`) → `surface.encodePaste(text, bracketed: true)`. `PasteTransform.bracketed` confirmed deleted — `PasteTransform.swift:9-19` documents the move to the engine (`docs/68` §4.2). |
| **Resize / SIGWINCH propagation** | done — moved | `TerminalSurfaceDriver.setGeometry(size:scale:)` (`:215-226`) → `surface.setGeometry` → drains pty replies (a resize can emit an in-band size report) → `setSize(cols:rows:)` → `model?.sendResize(cols:rows:)` (`:157`), the SIGWINCH-equivalent to the host. Called from `MacTerminalRendererView.layout()`/`viewDidMoveToWindow()` (`:97-111`) and `PhoneTerminalRendererView.layoutSubviews()`/`didMoveToWindow()` (`:84-103`). |
| **Live grid reflow on font change** | done — its own door, not the next layout pass | `slopdesk_term_surface_set_font` answers the grid the new cell size fits, and the driver settles it exactly as a layout pass does: mirror the size to the host, then present. The present is unconditional rather than settle's, because a font change invalidates every glyph in the atlas whether or not the grid moved — a family swap at the same metrics is precisely the case where it does not. |
| **Focus state** | done — and it stopped being only the painter's on 2026-09-01 | `TerminalSurfaceDriver.setFocus(_:blinkVisible:)` → FFI `slopdesk_term_surface_set_focus`, called from `becomeFirstResponder`/`resignFirstResponder` on both platforms. Hollow-cursor-on-unfocus: `rust/slopdesk-termrender/src/layout.rs:550-553`, `paint.rs:897-914`, `RectStyle::Hollow` (`quad.rs:99`). |
| **Focus reporting** (DEC mode 1004) | **done** (2026-09-01) — was a silent gap, and the door's own doc said so | The door above used to read "Drives the hollow cursor and nothing else", which was literally true and a real absence: a program that set DEC 1004 wants `CSI I` on focus and `CSI O` on blur — vim's `FocusGained`/`FocusLost` (what makes `autoread` notice another window's write), tmux's `focus-events`, every full-screen picker that dims when the user looks away — and nothing here ever sent one, because focus reached the RENDERER and never the engine. `VtSession::set_focused` asks `Mode::FOCUS_EVENT` and encodes through `libghostty_vt::focus::Event`, pushing into the same queue a device-status reply uses; it detects the EDGE itself (a view pushes its focus from `didMoveToWindow` and every layout pass, so an unconditional report would put one `CSI I` per pass on the program's input) and `TerminalSurfaceDriver.setFocus` drains afterwards. ⚠️ The mode is ASKED, never assumed: `CSI I` on a parser not looking for it is a bare `I` typed into the line it was reading. ⚠️ The FLAG lives in the session, not on the caller, so `feed` can answer the protocol's second half — ghostty replies at the moment 1004 is turned ON, with the focus already held, which is how a program that enables reporting mid-run learns where it stands without waiting for the user to click away and back. Granularity is the feed rather than the sequence, so `1004l`+`1004h` in one write cancel; the function says so. Pinned by `a_focus_change_is_reported_only_to_a_program_that_asked_for_one` (whose silent half is the half almost every program sees) and `arming_focus_reporting_answers_with_the_focus_already_held`. |
| **Kitty image protocol (inline images)** | **done** (2026-09-01) | Engine side `rust/slopdesk-vterm/src/graphics.rs` (images, placements, the PNG hook the bindings publish); placement and pixel cache `rust/slopdesk-termrender/src/image.rs`; textures and shaders `rust/slopdesk-apple-metal/src/images.rs` + `image_vertex`/`image_fragment`; wired at `Surface::place_images` in `rust/slopdesk-ffi/src/terminal_surface/mod.rs`. Three z bands interleaved into the existing pass, clipped to the BLOCK. Row `terminal.images` (default ON) gates drawing only. The protocol is COMPLETE, including the VIRTUAL (`U=1`, unicode-placeholder) form: the engine reports no position for one because the position is in the CELLS, so `rust/slopdesk-vterm/src/placeholder.rs` decodes the placeholder runs during the frame fill and caches them on the row, and `graphics.rs` joins each run to the placement whose grid it names. The aspect fit is ported from ghostty `22d13172`'s `graphics_unicode.zig` function for function — the specification is underdetermined there and every emitting program was tested against kitty/ghostty. ⚠️ The `t=f`/`t=t`/`t=s` file and shared-memory transmission mediums are CLOSED and no setting reopens them — see `docs/68` §5.7 and `docs/DECISIONS.md`. |
| **iTerm2 inline images** | **non-goal** — ghostty `main` has none either | No `OSC 1337 File=` handling anywhere. The vendored `libghostty-vt` bindings implement only two other OSC 1337 subcommands (`CurrentDir`, treated like OSC 7; `Copy`, treated like OSC 52) — the image-carrying subcommand is absent. The RENDER half is not what is missing — an image that reached `ImageStore` would draw through the kitty pass unchanged. What is missing is a transmission format the engine does not parse, and that is a DECISION: the core follows ghostty `main`, which does not parse it either. See `docs/DECISIONS.md`. |
| **Sixel graphics** | **non-goal** — struck 2026-09-01 by the user | Only a Device-Attributes capability-flag constant exists in the vendored crate (self-identification only) — no sixel decoding/parsing code anywhere, and none is wanted. ghostty `main` does not support Sixel; the core follows ghostty. Sixel is a 1987 palette-indexed bitmap with no alpha and no way to say where it belongs, and every program that emits it emits kitty graphics when the terminal advertises them. See `docs/DECISIONS.md` — do not re-open. |
| **Glyph Protocol** (ghostty APC `25a1`, runtime glyph registration) | **refused — with a date on it, not a non-goal** | ghostty `main`'s second APC protocol: a TUI registers its own glyph OUTLINES so icons draw without a patched font. `libghostty-vt` implements the wire half and `apc.zig` enables every APC protocol by default (`initFull()`), so this terminal ANSWERED the support query until 2026-09-01 — a probe got `ESC _ 25a1 ; s ; fmt=glyf ESC \` out of a fresh session. Nothing here can keep that promise: the C ABI has `set_glyph_protocol_enabled` and **no glossary reader** (disabling is documented to CLEAR it), and `slopdesk-apple-text` rasterizes INSTALLED fonts through Core Text, not `glyf`/COLR tables off a pty. Claiming it displaces the Nerd Font fallback with tofu, so `VtSession::refuse_glyph_protocol` turns it off at construction beside the image seal, and the protocol's own "no reply means unsupported" rule spells the refusal as silence. Pinned by `the_glyph_protocol_support_query_goes_unanswered`. Comes back when the bindings expose the glossary AND the renderer can rasterize an outline — see `docs/DECISIONS.md`. |
| **Window-title report** (`CSI 21 t`) | **refused — and now pinned** (2026-09-01) | `libghostty-vt` ships `set_title_report_enabled` OFF and states the reason: a program SETS a title (`OSC 2`) and ASKS for it back, which lands a string the program chose in the pty's INPUT, where a newline is a line executed at the shell. This crate never enables it, and as of this date `a_program_cannot_read_its_own_title_back_into_the_pty` asserts the empty pty queue so a bindings bump that flipped the default cannot pass. The refusal weighs more here than in a local terminal — the program is REMOTE and the shell it would type at is the user's own machine, the same argument that closed kitty's `t=f`/`t=t`/`t=s`. The title string is untouched: `VtSession::title` reads it and the tab shows it. |
| **Evaluated, not taken** (`set_apc_max_bytes`, the `GHOSTSNP` snapshot module, the continuation APIs, `set_default_mode`) | **deliberate, with a reason each** (2026-09-01) | `docs/DECISIONS.md` carries the four. Short form: the APC cap is ghostty's tuned built-in and this crate does not invent a number for it; the snapshot format is the right shape for a mid-session ATTACH but declares itself "version 1 … work in progress" with no compatibility guarantee, and this wire is golden-pinned; the continuation APIs are the snapshot's parts, worth nothing on their own until it lands; `set_default_mode` would impose a post-`RIS` default ghostty does not. |
| **Hint-mode** (URL / path hints, keyboard nav) | done — unchanged, lines drifted +~50 | `HintLabelAssigner.swift`: `slopdesk_hint_scan` still at line 215 (the one citation that didn't drift). `TerminalViewModel.swift`: `beginHint` `:1646` (was 1596), `handleHintKey` `:1710` (was 1660), `confirmHintTarget` `:1734` (was 1684), `cancelHintMode` `:1741` (was 1691). `TerminalHintActuator.swift` confirmed at `Sources/SlopDeskClientCore/Pane/`. `MacHintModeOverlay.swift` confirmed; phone file is `HintModeOverlayView.swift` (not `HintModeOverlay.swift`). ⚠️ **The OSC 8 ceiling CLOSED 2026-09-01.** An authored link whose display text is not itself a URL is hintable now: `HintLabelAssigner.targets` takes an `authored:` list off the new `TerminalViewportSnapshotting.authoredLinkRuns()`, and `slopdesk_rowscan::hint::targets` accepts those runs BEFORE it detects anything, so the per-row overlap rule that was already there drops a detector's guess laid over a declared link. The scan could never have found them — a declared link's display text is whatever the program wrote — so the fix was an input, not a better pattern. Their columns cross untouched: they are the ENGINE's cells, and re-deriving them with `text_cells` from a display text that stands for something else would move the badge off the link. |
| **Read-only mode** (block input to the PTY) | done — client-side, unchanged, lines drifted +~42-43 | `TerminalViewModel.isReadOnly` `:1392` (was 1350), `enterReadOnly()` `:1453` (was 1410), `exitReadOnly()` `:1460` (was 1417), `onReadOnlyChanged` `:1409`. `WorkspaceStore+ReadOnly.swift` confirmed present. `MacPaneStatusPills.swift` confirmed; phone file is `PaneStatusPillsView.swift` (not `PaneStatusPills.swift`). |
| **Vi-mode** (libghostty NATIVE vi-mode) | n/a — the old comparison has no subject any more | `ghostty_action_readonly_e`/`GHOSTTY_ACTION_READONLY` belonged to the deleted embedder's whole C-callback/action system. `libghostty-vt` has no action/callback concept for vi-mode or readonly at all — it is a pull-only Rust library. There is nothing left to compare "declared and never called" against. slopdesk's own copy-mode engine (`rust/slopdesk-terminal/src/vimotion.rs`, reached from the modal branch in `MacTerminalRendererView.keyDown:186-191`) is the current vi-flavoured feature — see Copy-mode and Vi visual-char selection above — and it is not a port of libghostty's anything. |
| **Autocomplete** (shell completion overlay) | **built** — this row was stale | Ranked completion is `rust/slopdesk-terminal/src/prompt/complete.rs` (subcommands, flags, paths, directories, variables, history), driven by `CommandEditor::complete` and stepped by `select_next_candidate`/`select_previous_candidate`, accepted by `accept_completion`. It crosses on the prompt handle (`slopdesk_prompt_complete`, `_candidates`, `_candidate_arena`, `_candidate_positions`, `_accept_completion`, `_dismiss_completion`) and is wired on BOTH platforms — `MacTerminalRendererView.swift:586-619`, `TerminalLeafView.swift:1483-1566`. The panel is drawn by `TerminalPromptBand.drawAccessory` (six rows, detail column, matched-scalar underline, selection in `accent`), the inline GHOST by `TerminalPromptBand.ghost`. ⚠️ That ghost has a SECOND source since 2026-09-01: with no list open it prints the **history autosuggestion** instead — `zsh-autosuggestions`' default `history` strategy, in-house. `CommandHistory::suggestion` is a plain function of (store, line) and holds no state, which is why it can be shown unasked; `CommandEditor::suggestion` suppresses it on five conditions (⌃R open, candidates open, a selection, caret not at the end, a newline in the line) but NOT during a history walk. The accept follows `fish`'s rule — it belongs to the input FUNCTION, not to a key — so `prompt::keys::over_suggestion` translates a `Motion`: `→`/`End`/`⌃E`/`⌃F`/`⌘→` take the whole suggestion, ⌥→ takes a word, and a `DefaultKeyBinding.dict` entry the user invented inherits it. The Mac asks in motions (`slopdesk_prompt_suggestion_accept_for_motion`, because AppKit hands it a selector and never a key), the phone in keys (`slopdesk_prompt_key_action`'s new `has_suggestion` flag); the rule itself is Rust's on both. ⚠️ The accept goes through `replace_range`, never `insert_text` — typed insertions coalesce, so an insert-spelled accept merged into the burst that summoned it and one ⌘Z emptied the line. What is genuinely not built is the **Fig-style bundled spec DB** — the providers are the ones the host can answer from itself. |

---

## Key Files

- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSurface.swift` — the seam: `TerminalSurface`, `TerminalSurfaceActions`, `TerminalViewportSnapshotting`, `TerminalSelectionControl`. **Did not move** despite an earlier draft of this doc claiming it did.
- `Sources/SlopDeskTerminal/MacTerminalRendererView.swift` — the AppKit conformer: key/mouse/scroll forwarding, hide-mouse-while-typing, the clipboard-write and paste-protection sheet presenters, the display link.
- `Sources/SlopDeskTerminal/PhoneTerminalRendererView.swift` — the UIKit conformer: hardware-key presses, pan/long-press/tap gestures, the clipboard confirmation mailbox.
- `Sources/SlopDeskTerminal/TerminalSurfaceDriver.swift` — the framework-neutral half: binds the pane, drains the two pull-only sinks, runs context-menu items, forwards every gesture door, and holds `applySettings()` — the whole live-reload path, armed on `TerminalConfigBroadcaster.generation`.
- `Sources/SlopDeskTerminal/TerminalRendererSurface.swift` — the one Swift type that owns the Rust handle; every member is a direct FFI call.
- `Sources/SlopDeskTerminal/TerminalRendererInstall.swift` — the one call that registers the renderer factory; replaces the deleted `slopdesk-ops enable-renderer`.
- `Sources/SlopDeskTerminal/PasteProtectionSheet.swift` — moved here from `Sources/SlopDeskMacUI/Terminal/`.
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift` — copy-mode + vi cursor, hint mode, read-only, `TerminalSurfaceActions` consumer.
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift` — right-click menu model + enablement rules (its own header comment about routing to "libghostty-vt binding actions" is stale prose, not live behaviour).
- `Sources/SlopDeskWorkspaceCore/Terminal/ScrollbackMatcher.swift` — ⇧⌘F's cross-pane scan over `slopdesk_find_matches` (`rust/slopdesk-rowscan`). ⌘F is NOT a caller: the in-pane bar asks the surface.
- `Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift` — Hint Mode labels over `slopdesk_hint_scan`.
- `Sources/SlopDeskWorkspaceCore/Terminal/` — the pure policies, **all now wired** (the previous audit found four of them doorless; see the matrix rows for what each actuator turned out to be): `CutSelectionPolicy`, `CopyReceipt`, `PasteSafetyAnalyzer`, `PastePrecheck`, `PasteTransform`, `ClipboardWritePolicy`, `PromptEditPolicy`, `FocusFollowsMousePolicy`, `RightClickPolicy`, `TerminalLinkDetector`, `TerminalLinkHitTest`, `ViLineMotion`. `PointerShapeMapping`, `MouseVisibilityMapping` and `ScrollbackWrapMapper` are DELETED, not merely moved — do not cite them.
- `Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift` — the user-facing render preferences (no longer `Codable`; the settings GUI that edited it is gone).
- `rust/slopdesk-vterm/src/` — the engine wrapper: `selection.rs`, `input.rs` (key/mouse encoders), `find.rs`/`search.rs` (the ONE ⌘F matcher: literal + regex + case + whole-word, and the bar's counter reads its cursor), `screen.rs`, `session.rs`, `events.rs`, `frame.rs`, `keycode.rs`.
- `rust/slopdesk-termrender/src/` — the renderer: `paint.rs` (four passes: background, decoration, text, cursor — no image pass), `layout.rs`, `glyph.rs`, `atlas.rs`, `quad.rs`, `block.rs`.
- `rust/slopdesk-terminal/src/config.rs` — **spells the legacy `ghostty` config text; almost none of it is read any more** — see the Overview.
- `rust/slopdesk-terminal/src/` — `paste`, `surface` (the five gesture decisions: clipboard write, cut, the undo byte, focus-follows-mouse, the right-click dispatch), `tracker`, `mode`, `link`, `link_hit`, `link_action`, `vimotion`, `blocks`, `keybind`, `inputbox`, `dedup`, `prompt_flash`, `surface_action`, `controls`, `context_menu`, `copy_receipt`, `geometry`. **No `pointer.rs`, no `wrap_map.rs`** — both deleted.
- `rust/slopdesk-ffi/src/terminal_surface/` — the complete FFI door list; if a setting isn't reachable from here, it is not live, whatever `config.rs` says.
- `rust/slopdesk-ffi/src/surface_gesture.rs` — `slopdesk_term_right_click` and its neighbours.
- `rust/slopdesk-ffi/src/find_matches.rs` — the ⇧⌘F cross-pane scan door, over `slopdesk-rowscan`. The ⌘F doors are `slopdesk_term_surface_find` / `_find_position` in `terminal_surface/reading.rs`.
- `rust/slopdesk-superd/src/sniffer.rs` — the ONE pass over the outbound PTY stream (title, bell, OSC 133, OSC 7, OSC 9/777/99, OSC 9;4) — unaffected by the terminal-surface rewrite.
- `rust/slopdesk-superd/src/commandblocks.rs`, `blocks.rs`, `autoprogress.rs`, `shellintegration.rs` — command blocks + the synthetic progress badge.
- `Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` — the client-side OSC 133 / CSI 1049 handle over `slopdesk_mode_tracker_*`, deliberately independent of the vt engine.
- `rust/slopdesk-muxsession/src/spawn_env.rs` — `$TERM`/`TERMINFO`/`COLORTERM`, replacing the deleted `Sources/SlopDeskHost/HostEnvironment.swift`.
- `rust/slopdesk-hostserver/src/gates.rs` — `DEFAULT_TERM`/`FALLBACK_TERM`.
- `rust/slopdesk-probe/src/terminfo.rs` — the terminfo search/resolution logic.
- `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift` — the phone's real key/IME responder (`TerminalInputHostView`, nested class), replacing the never-built-as-cited `TerminalInputHost.swift`.
- Per-platform terminal chrome — Mac: `Sources/SlopDeskMacUI/Pane/{MacTerminalLeafView,MacTerminalFindBar,MacHintModeOverlay,MacViCursorOverlay,MacViModeOverlay,MacLinkHighlightOverlay,MacPromptJumpFlashOverlay,MacPaneStatusPills}.swift`; phone: `Sources/SlopDeskPhoneUI/Pane/{TerminalLeafView,TerminalFindBarView,HintModeOverlayView,ViCursorOverlayView,ViModeOverlayView,LinkHighlightOverlayView,PromptJumpFlashOverlayView,PaneStatusPillsView}.swift` — note every phone overlay now carries a `View` suffix the Mac ones don't; shared: `Sources/SlopDeskClientCore/Pane/{TerminalFindBarModel,TerminalHintActuator,HintPresentation,FindBarPresentation,ViKeyHintPresentation,TerminalTouchSelection,TerminalLeafPolicy,TerminalPaneWiring,PromptJumpFlashGeometry}.swift`.

---

## Notes

### Cross-platform parity — **no longer accurate as a blanket claim**

The prior survey's Notes said "every terminal capability in the matrix exists on both macOS and iOS."
The one row that was a true parity break — **Undo at prompt**, phone-only — is closed: the Mac's
`keyDown` asks the same policy against the same `isAtEditablePrompt`. The two others the last pass
listed beside it, **Mouse-over-to-focus** and **Right-click action**, were unwired everywhere and are
wired now, but they are macOS-shaped rather than parity breaks: both need a hardware pointer. Their
phone counterparts are the tap that focuses a pane and the long-press edit menu. What differs by
LAYOUT rather than capability:

- Hint Mode resolves a label by keystroke on the Mac and additionally by TAP on the phone
  (`TerminalViewModel.confirmHintTarget`, `:1734`).
- The paste-protection confirmation is a sheet-class presenter on the Mac
  (`Sources/SlopDeskTerminal/PasteProtectionSheet.swift`) and a mailbox-filed card on the phone
  (`Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCardView.swift`), over one shared presentation
  model.
- Modal-key interception is `keyDown` on the Mac and `pressesBegan` on the phone, but both build the
  same abstract key and feed the same `TerminalViewModel.takeModalKey` (`:752`).

A parity break opened and CLOSED on 2026-09-01: the **editor-like command prompt** landed on macOS
in the morning and on iOS the same day, and the phone is not a port of the Mac. `TerminalPromptBand`
is the band on both — Core Text, `CGContext` and `SlateNativeColor`, no AppKit and no UIKit — with a
~100-line view shell each side, so there is one wrapping rule, one caret and one accessory
precedence. The two remaining differences are both real and both named: the phone reads its chords
through `slopdesk_prompt_key_action` where the Mac gets them as AppKit selectors (UIKit has no
binding table, and the decision stays in Rust either way) — and that is now the only one. The
INLINE preedit closed 2026-09-01: `TerminalInputHostView` conforms to `UITextInput` in
`Sources/SlopDeskPhoneUI/Pane/TerminalTextInput.swift`, so marked text crosses the seam through
`setComposition(_:selection:)` and the band or the grid draws it, never both. `docs/68` §5.4.

Two macOS-only behaviours are genuinely platform-shaped rather than gaps: `NSCursor`-based
mouse-hide/pointer-shape actuation needs a hardware pointer the phone doesn't have (pointer-shape
itself is dropped, see the matrix). Everything else marked "gap" above is a real cross-platform or
universal absence, not a platform choice — see the matrix for which.

### Wiring gaps and dead seams — expanded substantially by this re-verification

The prior pass listed ten. Five of them — the four unwired policies (§2–§4) and the callerless theme
door (§5) — were closed by the wiring pass that followed it; what those actuators turned out to be is
in the matrix rows. Ten are listed below, renumbered: the seven that survived that pass, plus §6, §9
and §10, which this pass FOUND rather than inherited.

1. **CLOSED 2026-09-01 — the config text is deleted, not merely dead.** `config.rs` went 883 → ~115
   lines (the `FACTORY_*` constants and `number_text`, both of which had a second reader all along),
   its FFI face 507 → ~90, and `TerminalConfigBuilder.swift`, the `TerminalControls` bundle, the two
   `slopdesk-invariants` rules keyed on the emitter and `SlateTheme`'s six hex string fields went with
   it. Everything the renderer honours crosses as a typed door; twelve rows with no door and no
   actuation plan were deleted from the key table rather than left to resolve silently. See the
   settings section above and `docs/DECISIONS.md` §"The rows that survived their reader".

2. **CLOSED — ⌘X's delete half counts for real.** The GUI no longer hardcodes
   `selectionEndsAtCursor: false`: `TerminalSurfaceDriver` asks the surface, which holds both the
   selection and the cursor, through `selectionEndsAtCursor()`. It reads the last DRAWN frame, so a cut
   fired between a programmatic selection and the next present sees the older geometry and refuses —
   which deletes nothing and degrades to a copy, the safe direction of the two.

3. ~~**OSC 8 hyperlinks have no handling at all**~~ — **CLOSED 2026-08-31, and this entry was STALE
   from the day it was written**: it contradicted its own matrix row. The engine half arrived with
   `744e80ab` (`CellFlags::HYPERLINK`, `VtSession::hyperlink_at`); what was actually missing was a
   caller, and `TerminalSurfaceDriver.link(at:cwd:slop:)` is it, serving the Mac's ⌘-hover and
   context menu and the phone's long press from one ranking. The keyboard half followed on
   2026-09-01 — `HintLabelAssigner.targets` takes an `authored:` list, so a declared link whose
   display text is not a URL is hintable. ⚠️ The lesson is the audit's, not the code's: a gap
   asserted in prose that the same document's matrix denies is a re-run that never happened.

4. ~~**In-surface search highlights are still a second engine from the find bar's counter/nav**~~ —
   **CLOSED.** All four modes moved into `slopdesk-vterm`'s `Matcher`, the bar reads its count and
   cursor back through `slopdesk_term_surface_find` / `_find_position`, and the row-driven fallback
   is deleted rather than bypassed. What remains is ⇧⌘F's snapshot scan, which is a different
   question over a different address space — see `docs/68` §5.2.

5. ~~**Mouse pressure / force-click is dropped with no `DECISIONS.md` record**~~ — **CLOSED
   2026-09-01: there was a record, under another name.** The trackpad gesture audit struck it by
   name ("❌ Rotate, force-click/pressure, Quick Look: dropped"), and that ruling covers this pane
   too — a terminal has no second reading of a pressure event to make, since no escape sequence
   carries stage-2 force and no program could receive one. The FEATURE gap is real; the
   documentation gap was the audit looking for a heading rather than the sentence.

6. **CLOSED 2026-09-01 — ⌘C / ⌘X / ⌘V / ⌘A were dead in the terminal pane**, and this audit had
   called all four done for three passes because it traced the CONTEXT MENU's route and stopped
   there. `MacTerminalRendererView` implemented none of `copy:`/`cut:`/`paste:`/`selectAll:`, and no
   other layer could have caught them: `WorkspaceCommands` puts the four on the Edit menu as key
   EQUIVALENTS (it must — an `NSTextField` in this process gets its ⌘V from nowhere else), and AppKit
   resolves a key equivalent against the responder chain BEFORE any application key monitor runs, so
   `WorkspaceKeyDispatcher` never saw them either. The chain simply ran out at the pane. ⚠️ The
   generalisation worth keeping: **a verb reachable from a menu is not evidence its chord works**, and
   in this app the two routes share nothing above `TerminalSurfaceDriver.run(_:)`. The fix is four
   methods, each one line into that dispatcher, plus an `NSMenuItemValidation` conformance so Copy and
   Cut grey out with nothing selected.

   ⚠️ **And closing it broke the key-release balance until that was inverted too**, which is the part
   worth reading before wiring any other menu verb here. `keyUp` used to forward every release the app
   had not recorded as swallowed — a NEGATIVE set, filled in `keyDown`. Making the Edit menu's items
   answerable made their key equivalents match, and a matched equivalent means `keyDown` is never
   called at all, while the RELEASE still arrives at the first responder. So each ⌘C would have sent
   the engine a release for a press it never saw — a reported key-up for a key that was never down,
   under the kitty protocol. `pressedKeys` is now the POSITIVE set, written at the single place a
   press can reach the engine (`send(_:action:composing:)`, plus the IME-commit branch that bypasses
   it), so any future route that swallows a press before the view defaults to silence instead of to a
   phantom release.

7. **`libghostty-vt`'s native vi-mode / readonly action system no longer exists as an API surface at
   all** — not merely unused. slopdesk's own copy-mode/read-only engines were never a port of it and
   need no reconciliation with it; see the Vi-mode matrix row.

8. ~~**Autocomplete is entirely absent**~~ — **this was false and is struck.** The engine
   (`prompt/complete.rs`), the doors, the key wiring on both platforms, the candidate panel and the
   inline ghost all exist; see the Autocomplete row above. What the spec placeholder
   `docs/ui-shell/spec/terminal-features__autocomplete.md` still describes with no code is the
   **Fig-style bundled spec DB** (715+ tools) and the frecency/auto-correction layer over it — a data
   problem, not a surface one.

9. **CLOSED 2026-09-01 — the phone pane had TWO first responders, and the newer one was unreachable.**
   ⚠️ This item previously read "every copy-mode motion ran TWICE on the phone", diagnosed from
   `PhoneTerminalRendererView.handle(_:action:)` routing both `pressesBegan` and `pressesEnded` into a
   phase-free `handleCopyModeKey(_:)`. **That reading was wrong and the entry is corrected rather than
   extended**: the funnel it describes was never called in production, so nothing ran twice.

   What was actually there: `PhoneTerminalRendererView` (added `cf06ae4d`) claimed first responder
   synchronously from `setPaneFocused(_:)`, while `TerminalInputHostView` — the pane's ratcheted
   `UIKeyInput` responder since `3955de12`, holding the repeater, the accessory row, the ⌃⇥ walk and
   the coordinator registration — claimed it one runloop hop later, because
   `PaneFocusCoordinator.scheduleBecome` defers `becomeFocus()` to `DispatchQueue.main.async` (UIKit
   takes a synchronous claim made inside a touch or a layout straight back). The two are SIBLINGS
   inside `surfaceArea`, not one inside the other, so the loser's `pressesBegan` was not called at all
   — and the loser was always the renderer. The visible symptom was not a double motion but a software
   keyboard that flickered down and up on every pane focus: the renderer conforms to no text-input
   protocol, and UIKit raises the keyboard only for one that does.

   The fix is a collapse, not a patch: the renderer stopped being a responder (~90 lines deleted) and
   the pane has exactly one. Nothing was given up — the four ⌘ chords already reached the surface as
   `UIKeyCommand`s on the input host, which hands each to `onRequestMenuItem`. ⚠️ The generalisation:
   **two responders in one pane is not a race you tune, it is a second implementation** — and a
   sibling pair makes it silent, because the loser's handlers simply never run rather than running
   late. The `pressedKeys` edge the old entry closed with was an edge of a path that did not exist.

10. ~~**A scrolled-back block header cannot show its exit code or duration.**~~ **CLOSED, and the
    entry was wrong twice over.** A header now prints both, right-aligned, joined by
    `rust/slopdesk-termrender/src/blockjoin.rs` and fed through
    `slopdesk_term_surface_note_block`.

    The old entry said this needed an id in `OSC 133;A` plus a Zig-side `libghostty-vt` change. It
    needed neither: **wire type 28 already carries `exitCode`, `durationMS` and `promptOrdinal` to
    the client, per block.** Both halves were on the same machine the whole time. The lesson is not
    about terminals — it is that the entry declared a dependency on someone else's release without
    checking what this tree already sent itself.

    It also closed with "Do NOT close it by re-deriving the ordinal on the client from row counts:
    scrollback eviction makes that wrong exactly when the header is scrolled back." That objection is
    real and does not apply, for two independent reasons. It describes counting FORWARD from the top
    of the retained buffer, where an eviction silently changes the origin; the join counts BACKWARDS
    from the newest block, and eviction takes from the old end, which a backwards count never reads.
    And the count is not trusted on its own — the anchor is confirmed against the command text the
    host recorded, and an unconfirmed frame prints nothing at all. What eviction actually costs is
    one `None` for a block whose record has aged out of the 64-entry ring, which degrades to exactly
    the header this entry described as the permanent state.

    Two ways the join could be confidently WRONG are closed outside it, because its verification is
    one-sided and cannot see either from its own input. A dead shell's records would anchor the
    fresh shell's blocks (which restart at ordinal 1) and repeated commands would confirm it — so
    `slopdesk_term_surface_forget_blocks` drops them at the same edge `TerminalViewModel` drops its
    own block list. And the ACTIVE block never prints a status even when handed one, since a command
    that has not finished has no outcome; that kills the retyped-command case where a live prompt
    would wear the previous run's `✗ 1`.

    ⚠️ The one thing this entry left open — "a failed block is marked `✗ <code>` rather than
    coloured red" — **closed 2026-09-01, and its stated reason was wrong**. It read "a token chosen
    on the Rust side of a design system that lives in Swift", but `Slate.Native.Terminal.err` is the
    PROFILE's own ANSI red and exists for precisely this; nothing had to be invented. `ChromeStyle`
    gained `status_err`, fed through the existing `_set_chrome_style` door from
    `SlateTheme.terminalErrHex` (never `Slate.Status.err`, which is the system palette and out of
    family on the glass). Only the `✗ <code>` takes it — the duration keeps `label`, because a slow
    command is not a broken one — which is why `chrome::status_parts` splits the two halves where
    the words are chosen and `chrome::status_columns` draws them as two runs for the header AND the
    pinned head. Written up at `docs/68` §5.3.

### What was REMOVED since the 2026-06-25/26 survey (unaffected by the terminal-surface rewrite)

- **Cursor "Smooth" animation (H3)** — the forward-compat `cursorAnimation` preference is gone, and so
  is the test that used to pin its retired-key decode (the test file itself no longer exists).
- **Scroll-past-first/last (I14) and Smooth scroll (I15)** — deleted 2026-07-30, confirmed still clean.
- **Backspace-deletes-selection (I7)** — `BackspaceSelectionPolicy` deleted; its claimed successor
  (Cut/`CutSelectionPolicy`) is wired now, though its delete half still counts zero — see Wiring gaps §2.
- **`pasteToComposer`** — deleted with the Composer / Prompt-Queue / Send-to-Chat / Fork / agent-footer
  vertical (`92472b0a`, 2026-07-03).
- **The theme picker, catalogue, dual light/dark slots and per-theme fonts** — ONE APPEARANCE,
  user-directed 2026-08-08. `AppearancePreferences.swift` itself is now also gone; the ruling survives
  as a comment at `Sources/SlopDeskSlate/SlateDesign.swift:44`. The underlying palette PASSTHROUGH this
  ruling left intact is, separately, live again end to end — see the Theme/palette matrix row.
- **`Sources/SlopDeskHost/HostOutputSniffer.swift` and `CommandBlockSegmenter.swift`** — ported to
  `rust/slopdesk-superd/src/{sniffer,commandblocks}.rs`, unaffected by this rewrite.
- **`Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift`** — replaced by
  `TerminalInputHostView` inside `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift`.

### What was REMOVED by the terminal-surface rewrite (`docs/68`, `744e80ab`)

- **The entire vendored fork**: `ThirdParty/ghostty/`, `GhosttySurface.swift`, `GhosttyTerminalView.swift`,
  `GhosttyLayerBackedView.swift`, `CGhostty`, the xcframework, `build-libghostty.sh`, the `.toolchain/`
  download, the `xcrun` SDK shim, `slopdesk-ops enable-renderer` (`rust/slopdesk-devtools/src/ops/renderer.rs`).
- **`Sources/SlopDeskHost/HostEnvironment.swift`** — split across `rust/slopdesk-muxsession/src/spawn_env.rs`
  and `rust/slopdesk-hostserver/src/gates.rs`.
- **`rust/slopdesk_terminal::pointer`, `rust/slopdesk-ffi/src/pointer_shape.rs`, `PointerShapeMapping.swift`,
  `MouseVisibilityMapping.swift`, `ScrollbackWrapMapper.swift`** and their test suites — OSC-22 pointer
  shape is dropped (`docs/DECISIONS.md`); mouse-hide-while-typing needed no engine and moved
  straight into `MacTerminalRendererView.keyDown`.
- **`PasteTransform.bracketed`** — bracketed-paste framing moved into the engine (`slopdesk_term_surface_encode_paste`).
- **OSC-52 clipboard READ** — dropped; `libghostty-vt` never forwards a read request (`docs/DECISIONS.md`).

### What was LIFTED since the original 2026-06-25/26 survey (unaffected by the terminal-surface rewrite)

- **The copy-mode ceiling (2026-07-14).** Superseded again, in the SAME direction: the fork's ABI
  extension that first lifted it is gone, but its replacement — `libghostty-vt`'s own richer
  `selection::gesture` module — lifts it further still (`docs/68` §4, "a gain, not a gap").
- **Hint Mode** — built (E10 WI-9), on both platforms, unaffected by the rewrite.
- **Read-only mode** — built as a per-pane LOCK, on both platforms, unaffected by the rewrite.
- **OSC 9;4 progress state** and **OSC 7 working directory** — both superd-side and unaffected.

### Architecture note on the former "na-remote" items — **twice superseded**

The prior survey marked Kitty images, iTerm2 images and Sixel graphics "na-remote": libghostty rendered
them from the raw PTY byte stream with no embedder involvement, so they "worked to the extent libghostty
v1.3.1 supported them, which was all three." That premise died with the renderer it described, and this
note recorded all three as genuine gaps.

**One of the three is now closed and the other two changed shape (2026-09-01).** `slopdesk-termrender`
grew an image pass, so the missing piece is no longer a renderer — it is a DECODER, one per
transmission format. Kitty has one; iTerm2's `OSC 1337 File=` and sixel do not, and they are the whole
remaining gap. The matrix rows above are authoritative; `docs/68` §5.7 is the argument.
