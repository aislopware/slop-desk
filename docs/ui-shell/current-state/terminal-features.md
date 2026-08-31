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
MIT `Uzaaft/libghostty-rs @ a0b5a46` Rust bindings — replaces the deleted fork's full surface API.
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
`CAMetalLayer` through `objc2`. All four meet at `rust/slopdesk-ffi/src/terminal_surface.rs`.

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

**The single biggest fact this re-verification turned up: most of `rust/slopdesk-terminal/src/config.rs`'s
"ghostty `key = value`" text is dead code that nothing reads.** That text used to be handed to the
deleted fork's `ghostty_config_load_string`; `TerminalConfigBroadcaster.configString`
(`Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore.swift:332`) says so in the tree
itself: **"NOTHING SHIPPING READS THIS ANY MORE."** The live renderer takes settings through a small,
specific set of typed FFI doors instead — and only those doors are live:

- `slopdesk_term_surface_new(family, point_size, scale, width, height)` — font family + point size,
  read **once**, at surface construction.
- `slopdesk_term_surface_set_theme(handle, foreground, background, selection)` — three colours.
- `slopdesk_term_surface_set_option_as_alt(handle, value)`.
- `slopdesk_term_right_click_intercepts_as_paste(action, has_selection, mouse_captured)`.

Every other setting `config.rs` still spells into that string — scrollback limit, cursor style/blink/
colour/opacity, font fallback chain/weight/per-face bold-italic/ligatures/blending, the 16-entry ANSI
palette, copy-on-select, trim-trailing-spaces-on-copy, clear-selection-on-typing/copy, shift-arrow-select,
mouse-shift-capture, click-to-move, allow-mouse-capture, scroll-multiplier — builds real text that is
published and then silently discarded. Individual rows below say so; this paragraph is here so the
same discovery isn't made eleven times. Two settings are the sole exceptions with a genuine typed
door: **Option-as-Alt** and the **right-click paste intercept token** (though the intercept policy
that reads the token is itself unwired — see that row).

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
| **Selection** (mouse drag) | done — moved | `MacTerminalRendererView.mouseDown/mouseDragged/mouseUp` (`Sources/SlopDeskTerminal/MacTerminalRendererView.swift:257-301`) call `driver.selectPress/selectDrag/selectRelease` (`TerminalSurfaceDriver.swift:297-317`) → `TerminalRendererSurface.swift:248-270` → FFI `slopdesk_term_surface_select_press/_drag/_release` (`rust/slopdesk-ffi/src/terminal_surface.rs:905-1015`) → `rust/slopdesk-vterm/src/selection.rs`, which wraps `libghostty-vt`'s own `selection::gesture` (click-count word/line granularity, drag-past-edge autoscroll, reversal-flips-anchor all live in the engine now). A mouse-reporting program gets first refusal via `sendMouse`'s boolean return. |
| **Selection clipboard** (SELECTION pasteboard) | n/a — permanent, not a migration gap | `TerminalSurfaceDriver.apply(_:)` (`TerminalSurfaceDriver.swift:190-204`) only actuates `TerminalClipboardTarget.standard`: "Apple has no selection clipboard, so a write aimed at one has no destination to land in." The engine still reports `.selection`/`.primary` clipboard-write requests (`rust/slopdesk-vterm/src/events.rs`); they are dropped by design on every Apple platform, exactly as the old fork also dropped them — not something this migration removed. |
| **Copy** (⌘C / context menu) | done — mechanism changed | `TerminalContextMenu.Item.copy` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift:22`) → `TerminalSurfaceDriver.run(_:)` case `.copy, .cut` (`Sources/SlopDeskTerminal/TerminalSurfaceDriver.swift:370-381`): reads `selectionText(.plain)`, runs `ClipboardWritePolicy.decide(confirmRequested:false, text:)`, writes via `ClientPasteboard.shared.write`. `TerminalContextMenu.swift:9-11`'s own doc comment still claims routing "to libghostty-vt (`copy_to_clipboard`…)" — that comment is stale; no such binding-action call exists in the live path. |
| **Cut** (⌘X / context menu) | done, but degraded — **real bug** | `TerminalSurfaceDriver.run(_:)`'s `.cut` case is the SAME branch as `.copy` (`TerminalSurfaceDriver.swift:370-373`, comment: "there is no editable buffer this side to delete from"). The engine meant to make Cut actually delete at an editable prompt — `CutSelectionPolicy` / `CutAction` (`Sources/SlopDeskWorkspaceCore/Terminal/CutSelectionPolicy.swift`, wrapping `slopdesk_term_cut_action` / `slopdesk_term_cut_delete_count`) — is pure, tested, and has **zero production callers** anywhere in `Sources/` (a repo-wide grep for `CutSelectionPolicy.` outside its own file returns nothing). Its own doc comment claims "the GUI surface… is the thin actuator" for it; that actuator was never written. Cut is copy-only in production today. |
| **Copy receipt chip** | done — unchanged | `CopyReceipt.swift` (`Sources/SlopDeskWorkspaceCore/Terminal/CopyReceipt.swift`) is still a pure struct over `slopdesk_copy_receipt`, no framework import. |
| **Paste** (⌘V / context menu) | done — moved | `TerminalContextMenu.Item.paste` → `TerminalSurfaceDriver.run(_:)` case `.paste` (`TerminalSurfaceDriver.swift:394-395`) → private `paste(_:bracketing:)` (`:448-475`) → `PastePrecheck.decide` → `surface.encodePaste(text, bracketed:)` (`TerminalRendererSurface.swift:445-456`) → FFI `slopdesk_term_surface_encode_paste` (`rust/slopdesk-ffi/src/terminal_surface.rs:1654-1675`) → `libghostty_vt::paste::encode`. Framing (control-byte scrub, LF→CR rewrite when unbracketed, embedded end-marker strip) is the engine's — `docs/68` §4.2. |
| **Paste as keystrokes** | done | Same `paste(_:bracketing:)` path as Paste, with `PasteBracketing.suppress` (`TerminalSurfaceDriver.swift:398-401, 434-437`), which forces `bracketed: false` at the `send(_:bracketing:modes:)` call regardless of the program's own DECSET. No separate raw-text bypass exists any more — it is the same paste door with a different argument. |
| **OSC 52 clipboard read/write** | write done; **read DROPPED** | Write: `TerminalSurfaceDriver.drain()` (`:171-180`) → `apply(_:)` (`:190-204`) → `ClipboardWritePolicy.decide(access:text:)` gated by `SettingsKey.clipboardWrite` → confirm sheet or direct `ClientPasteboard` write. Read: `docs/DECISIONS.md:18386-18391`, "Dropped: the OSC-52 clipboard READ gate… `libghostty-vt` documents that OSC-52 read requests (`?`) are 'always ignored and never forwarded', so no program can ask and there is nothing to gate." `PasteSafetyAnalyzer.Ask.clipboardRead` / `TerminalControls.clipboardRead` remain in the settings model with zero call sites in `Sources/SlopDeskTerminal` — a dormant row over a door that can never fire. (A separate, still-live "metadata clipboard-read" channel the host answers is untouched — a different feature.) |
| **Select All** | done | `TerminalContextMenu.Item.selectAll` → `TerminalSurfaceDriver.run(_:)` case `.selectAll` (`TerminalSurfaceDriver.swift:382-385`): `surface?.selection(.all)`. |
| **Scroll (wheel / trackpad)** | done — moved | `MacTerminalRendererView.scrollWheel(_:)` (`MacTerminalRendererView.swift:321-337`): ⌥-scroll diverts to canvas pan; otherwise `driver.sendMouse(action:2, button:4,…)` is tried first so a mouse-reporting full-screen program (vim) can consume the wheel as a report, and only on refusal does `driver.scroll(.rows(rows))` (`TerminalSurfaceDriver.swift:247-251`) move the viewport. |
| **Scroll to top / bottom** | done — moved | `TerminalViewModel.applyAbsoluteJump(_:toTop:)` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:1238-1240`) → `performBindingAction(.scrollToTop/.scrollToBottom.wire)`, wire spellings at `rust/slopdesk-terminal/src/surface_action.rs:157-158,202-203,268-269`. |
| **Scrollback buffer** | **gap** — was "done, moved to Rust" | `rust/slopdesk-terminal/src/config.rs:260` (`scrollback-limit = …`) and `FACTORY_SCROLLBACK_LINES` (`config.rs:~245`) still compute a byte limit — into the dead `configString`. No `slopdesk_term_surface_set_scrollback_*` FFI door exists (checked against the FFI file's complete door list); `rust/slopdesk-vterm` has no consumer for the setting. The user's configured scrollback limit is not actuated — the engine runs whatever retention `libghostty-vt` defaults to. |
| **Cursor shape / blink** | **gap** — was "done, moved to Rust" | `config.rs:421,425-426` (`cursor-style`, `cursor-style-blink`) still emit into the dead `configString`; no `set_cursor_style`/`set_cursor_blink` FFI door exists. The user's cursor-shape/blink preference is not actuated. |
| **Mouse modes (X10/1000/1002/1003/SGR)** | done — now wholly the engine's | Swift carries no reporting-mode state at all any more: every pointer handler calls `driver.sendMouse(...)` and branches on the **boolean return** (`false` = "not tracking", fall back to the view's own gesture). FFI `slopdesk_term_surface_mouse` (`rust/slopdesk-ffi/src/terminal_surface.rs:797`) defers to `rust/slopdesk-vterm/src/input.rs`'s `MouseEncoder` over `libghostty_vt::mouse::Encoder`, which owns mode selection from the DECSET the program sent. |
| **Mouse pressure / force-click** | **dropped — undocumented** | No `pressure` symbol anywhere in `Sources/SlopDeskTerminal`, `rust/slopdesk-vterm`, or `rust/slopdesk-ffi/src/terminal_surface.rs`; no `NSEvent` pressure override in `MacTerminalRendererView.swift`. Unlike OSC-22 pointer shape (`docs/DECISIONS.md:18393-18397`), this drop has **no `DECISIONS.md` entry** — a documentation gap on top of the feature gap. |
| **Kitty keyboard protocol** | done — moved | Encoding: `rust/slopdesk-vterm/src/input.rs` (`Keyboard::encode`) + `keycode.rs` (`key_from_macos_keycode`), reached via `slopdesk_term_surface_key` (`rust/slopdesk-ffi/src/terminal_surface.rs:745-782`). Swift call site `MacTerminalRendererView.send(_:action:)` (`:200-211`) → `TerminalRendererSurface.encodeKey` (`:206-225`). The old "Ctrl+C0 fast path" special case is gone — `libghostty-vt`'s own encoder does ctrl-letter→C0 translation uniformly now. |
| **IME / CJK input (macOS)** | **gap — real regression**, was "done" | No `NSTextInputClient` conformance exists anywhere in `Sources/` (checked `MacTerminalRendererView.swift` and `MacTerminalLeafView.swift`, the only two candidates — zero hits). `keyDown` always calls `send(event, action:)` with `composing: false` hardcoded (`MacTerminalRendererView.swift:169-211`). `docs/68-terminal-surface-in-rust.md` §5.1 item 8 lists "marked-text (preedit) drawing in the grid" as still-to-build. **CJK/dead-key composition on the Mac terminal surface does not work today** — there is no conformer to receive it. |
| **IME / CJK input (iOS)** | done — **path moved, ceiling narrower** | `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift` does not exist. The real responder is `TerminalInputHostView: UIView, UIKeyInput`, nested in `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift` (~904-966), which reads a `UIKey` into `PhoneKey.Press` and asks `rust/slopdesk-workspace/src/phone_key.rs::route` which of two paths it takes — raw encoder vs. the UIKit text-system proxy that commits via `insertText`. Copy Mode / Hint Mode are asked ABOVE that split via `TerminalViewModel.takeModalKey` (`TerminalViewModel.swift:752`). The file's own comment: **"What is NOT here yet: `UITextInput` — marked text and the floating cursor."** CJK typing works (the system keyboard's own candidate bar commits through `insertText`), but there is no inline preedit drawn in the grid and no space-bar-drag floating cursor. |
| **Unicode / text styles** (bold, italic, dim…) | done — moved | SGR attribute rendering is `rust/slopdesk-termrender/src/paint.rs` (`PaintStyle`, `DecorationKey`, ~41-111) using glyphs from `glyph.rs` (`Synthetic{bold,italic}`). No embedder involvement, same delegation model, different renderer. |
| **True colour / 256-colour** | done — moved | `COLORTERM=truecolor` now set in `rust/slopdesk-muxsession/src/spawn_env.rs` (`curated()`, ~line 145, tested ~229). `Sources/SlopDeskHost/HostEnvironment.swift` is deleted. |
| **Box-drawing / powerline glyphs** | done — moved | No dedicated code: ordinary glyphs shaped by Core Text through `rust/slopdesk-apple-text/src/shape.rs`, rasterized/cached by `slopdesk-termrender`'s glyph atlas — the same delegation the old fork used, over this repo's renderer instead of libghostty's. |
| **Font family, size, weight** | **gap, narrower than claimed — real regression**, was "done, moved to Rust, widened" | `config.rs`'s widened `FontSettings` (fallback chain, per-face bold/italic/bold-italic, ligature token, blending, cell-height percent) all builds into the dead `configString`. The only LIVE path is `slopdesk_term_surface_new(family, point_size, scale, width, height)` (`rust/slopdesk-ffi/src/terminal_surface.rs:463-477`), consumed by `rust/slopdesk-apple-text/src/font.rs`'s `FontStack::new(family, point_size, contents_scale)` — three parameters, read **once** at surface construction (`MacTerminalRendererView.swift:52-56`, `PhoneTerminalRendererView.swift:45-49`) from `TerminalConfigBroadcaster.shared.{fontFamily,fontSize}`. Bold/italic are synthesized automatically from the one family via `CTFontSymbolicTraits` (`font.rs:161-206`), not chosen from separately configured face names. Fallback family list, explicit bold/italic/bold-italic families, ligature suppression and glyph blending are configurable in `config.toml` but never reach the renderer. |
| **Theme / palette** | **gap, narrower than claimed — real regression**, was "done for the surface" | Only three colours have a live door at all: `slopdesk_term_surface_set_theme(handle, foreground, background, selection)` (`rust/slopdesk-ffi/src/terminal_surface.rs:658`, Swift `TerminalRendererSurface.swift:157-161`) — **and even that door has zero callers**: `TerminalSurfaceDriver.setTheme(foreground:background:selection:)` (`TerminalSurfaceDriver.swift:234-238`) is defined but a repo-wide grep for `.setTheme(` outside its own definition returns nothing. The user's 16-entry ANSI palette has no FFI door at all — `config.rs`'s `append_colors` (~389-417) still emits it into the dead `configString`. **Theme/palette customization is entirely unwired today; the renderer draws whatever default colours the engine starts with.** The "ONE APPEARANCE" ruling (ChooseR removed 2026-08-08) still stands, but `AppearancePreferences.swift` is gone — the ruling is now a comment at `Sources/SlopDeskSlate/SlateDesign.swift:44` — and the Settings GUI it would have lived in was deleted 2026-08-24 (`docs/58-configuration.md`). |
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
| **In-terminal search (⌘F)** | done — engine moved, **two-engine split confirmed** | `TerminalSearchController.swift:211` (drifted from `:213`) calls `slopdesk_find_matches` (`rust/slopdesk-ffi/src/find_matches.rs:48`), which wraps a **separate crate**, `rust/slopdesk-rowscan/` — not `slopdesk-vterm`'s own `find.rs`/`search.rs`. The find bar's counter/nav (N of M, regex, whole-word) runs over a text snapshot Swift pushes into `slopdesk-rowscan`; the live on-screen highlight is a SEPARATE engine, `rust/slopdesk-vterm/src/find.rs` (`search()`/`navigate_search()`) reached via `SurfaceAction::Search`/`NavigateSearch` (`rust/slopdesk-ffi/src/terminal_surface.rs:1445-1446`) — a literal, case-insensitive scan only. `MacTerminalFindBar.swift` documents the split as deliberate. Phone file is `Sources/SlopDeskPhoneUI/Pane/TerminalFindBarView.swift` (not `TerminalFindBar.swift`). |
| **Copy-mode** (vi-like keyboard scrollback nav) | done — unchanged mechanism, lines drifted +~40-45 | `TerminalViewModel.swift`: `enterCopyMode()` `:1353` (was 1311), `exitCopyMode()` `:1368` (was 1326), `handleCopyModeKey(_:)` `:794` (was 753), `takeModalKey` `:752` (was 711). `MacViModeOverlay.swift` confirmed; phone file is `ViModeOverlayView.swift` (not `ViModeOverlay.swift`). |
| **Vi visual-char selection in copy-mode** | done — mechanism moved, a real gain | `TerminalSurface.setSelection(anchor:head:rectangle:)` still declared in `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSurface.swift` (~line 317, NOT moved to `SlopDeskTerminal`); implemented at `TerminalRendererSurface.setSelection` (`Sources/SlopDeskTerminal/TerminalRendererSurface.swift:493-503`) → `slopdesk_term_surface_set_selection` → `rust/slopdesk-vterm/src/selection.rs`, which wraps `libghostty-vt`'s own `selection::gesture` module — `docs/68` §4 calls this "a gain, not a gap": click/select_word/select_line/select_output/rectangle/adjust/format are all richer than what the fork exposed. `rust/slopdesk-terminal/src/vimotion.rs` (word/column motions) is unchanged. `MacViCursorOverlay.swift` confirmed; phone file is `ViCursorOverlayView.swift`. |
| **Right-click context menu** | done — item list unchanged (14 items), citation moved | `TerminalContextMenu.Item` enum now at `TerminalContextMenu.swift:18-37` (was `:13-47`): copy, cut, paste, pasteAsKeystrokes, pasteSelection, pasteFileBase64, pasteEscaped, pasteBracketed, selectAll, clear, copyOutput, splitRight, splitDown, find. `pasteToComposer` confirmed still gone repo-wide. |
| **Right-click action** | **gap — real mechanism change AND an unwired door**, was "done, now a libghostty passthrough" | The old "hand the token to libghostty and let it dispatch end to end" model died with the fork — `rust/slopdesk-terminal/src/controls.rs`'s own doc comment (~134-141) says so: "The fork is gone, but the same token is what `crate::surface::right_click_intercepts_as_paste` reads directly now." That function (`rust/slopdesk-terminal/src/surface.rs:182-193`) decides in-process whether a bare right-click should be intercepted as a paste (routed through the four-danger `PastePrecheck` analysis) instead of dispatched to a library. Its Swift face, `RightClickPasteInterceptPolicy` (`Sources/SlopDeskWorkspaceCore/Terminal/RightClickPasteInterceptPolicy.swift`), wraps `slopdesk_term_right_click_intercepts_as_paste` — but **has zero callers anywhere in `Sources/`** (a repo-wide grep for `RightClickPasteInterceptPolicy.` outside its own file returns nothing). `MacTerminalRendererView.rightMouseDown` (`MacTerminalRendererView.swift:313-319`) only forwards the click to a mouse-reporting program or falls through to AppKit's own default context menu — it never reads `controls.right-click-action` or consults this policy. The `ignore`/`copy`/`copy-or-paste` arms have no actuator at all today; a bare right click just opens the standard menu. |
| **Copy-on-Select** | **gap**, was "done" | `config.rs:433-440` (`copy-on-select = …`) is dead text — zero references to `copy_on_select` in `rust/slopdesk-vterm`, `rust/slopdesk-termrender`, or `rust/slopdesk-ffi/src/terminal_surface.rs`. The toggle persists and serializes but has no effect on drag-select behaviour. |
| **Trim trailing spaces on copy** | **gap**, was "done" | `config.rs:443` (`clipboard-trim-trailing-spaces`) is dead text; no live consumer. |
| **Clear selection on typing / on copy** | **gap**, was "done" | `config.rs:444-445` (`selection-clear-on-typing`/`selection-clear-on-copy`) is dead text; no live consumer. |
| **Shift+Arrow select** | **gap**, was "done" | The four `keybind = shift+<dir>=adjust_selection:<dir>` lines (`config.rs:489-497`) are dead text. Copy-mode's own `adjust_selection`/`SelectionAdjust` machinery IS real and live (`rust/slopdesk-vterm/src/screen.rs`, `rust/slopdesk-ffi/src/terminal_surface.rs:~1482-1489`) but is unconditional and belongs to copy-mode's vi-visual selection — unrelated to this outside-copy-mode toggle. |
| **Paste Protection sheet** | done — analyzer unchanged, location moved | `PasteSafetyAnalyzer.swift` / `PastePrecheck.swift` unchanged in role. The sheet itself moved: `Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift` → `Sources/SlopDeskTerminal/PasteProtectionSheet.swift`; phone card is `Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCardView.swift` (drifted from `ClipboardConfirmCard.swift`), over shared `Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift`. Presented from `MacTerminalRendererView.confirm(_:preview:dangers:_:)` (`:346-355`) and `PhoneTerminalRendererView`'s static `confirm(...)` (`:296-306`, via the `ClipboardConfirmRequests` mailbox — UIKit cannot present synchronously mid-drain). |
| **Paste as…** | done — minus one item, mechanism moved | `PasteTransform.swift:9-19` confirms `.bracketed` deleted (framing moved to the engine, `docs/68` §4.2); `.shellEscaped`/`.base64(ofFileBytes:)` remain. `pasteToComposer` still dead (Composer deleted `92472b0a`, 2026-07-03). |
| **Hide mouse while typing** | done — corrects a stale claim made earlier in this same rewrite pass | `MacTerminalRendererView.keyDown` (`MacTerminalRendererView.swift:169-178`) reads `SettingsKey.mouseHideWhileTypingEnabled` live and calls `NSCursor.setHiddenUntilMouseMoves(true)` **before** the chord interceptor runs, "so a swallowed chord still hides the pointer." `docs/DECISIONS.md:18409-18413`: "Not dropped, and never needed an engine… It lives in the view, costs no door and no vterm change." |
| **Allow-shift-with-click / mouse-reporting / click-to-move** | **gap**, was "done" | `config.rs:450-458` (`mouse-shift-capture`, `cursor-click-to-move`, `mouse-reporting`) is dead text; no FFI door reads any of the three. |
| **Scroll multiplier** | **gap**, was "done" | `config.rs:471-473` (`mouse-scroll-multiplier`) is dead text. `MacTerminalRendererView.scrollWheel(_:)` (`:321-337`) uses the raw `event.scrollingDeltaY` — no multiplier is applied anywhere in the live path. |
| **Option-as-Alt** | done — one of the two live typed doors | `macos-option-as-alt` is ALSO emitted into the dead `configString` (`config.rs:475`), but this one has a real consumer: `TerminalSurfaceDriver.applyOptionAsAlt()` (`TerminalSurfaceDriver.swift:241-243`) reads `SettingsKey.optionAsAlt.surfaceCode` and calls `surface.setOptionAsAlt(_:)` → FFI `slopdesk_term_surface_set_option_as_alt` (`terminal_surface.rs:871`), invoked from `TerminalSurfaceDriver.bind(to:)` on every attach. |
| **Mouse-over-to-focus** | **gap — real bug**, was "done" | `FocusFollowsMousePolicy.swift` (`Sources/SlopDeskWorkspaceCore/Terminal/FocusFollowsMousePolicy.swift`) exists and wraps `slopdesk_term_focus_follows_mouse`; its own doc comment claims "the GUI view… its `mouseEntered`/`mouseMoved` consult this." **That is false of the current code** — `MacTerminalRendererView` has no `mouseEntered` override at all, and `mouseMoved` (`MacTerminalRendererView.swift:303-311`) only forwards the pointer position to `driver.sendMouse`; it never calls this policy or `model.onRequestFocus`. A repo-wide grep for `FocusFollowsMousePolicy.` outside its own file returns nothing. Hovering a pane no longer claims workspace focus, regardless of the setting. |
| **OSC-22 pointer shape** | dropped | `docs/DECISIONS.md:18393-18397`: `libghostty-vt` parses OSC 22 but `Terminal` exposes no handler. `rust/slopdesk-terminal/src/pointer.rs`, `rust/slopdesk-ffi/src/pointer_shape.rs`, `PointerShapeMapping.swift`, `MouseVisibilityMapping.swift` and their test suites are all deleted, along with the `pointer-tables-one-table` invariant. |
| **Cursor colour / opacity / text** | **gap**, was "done" | `config.rs:481,485,487` (`cursor-color`, `cursor-text`, `cursor-opacity`) are dead text; no `set_cursor_*` FFI door exists. The old live-preview surfaces are also gone entirely — `find Sources -iname "*CursorPreview*"` returns nothing — because the whole Settings GUI that hosted them was deleted 2026-08-24 (`docs/58-configuration.md`). Cursor colour/opacity/text is authored in `config.toml`, previewed nowhere, and not actuated. |
| **Cursor smooth animation** | removed — citation now fully dead, not just stale | `Tests/SlopDeskVideoProtocolTests/Settings/TerminalPreferencesDecodeTests.swift` no longer exists; that directory holds only `KeybindConfigLoaderTests.swift`/`KeybindGrammarTests.swift`. `cursorAnimation` appears nowhere in Swift or Rust. The regression test that pinned "the retired key decodes and is ignored" is gone along with `TerminalPreferences`'s `Codable` conformance (removed with the settings GUI, `docs/58`). The underlying claim — no field, no setting row — still holds; nothing pins it any more. |
| **Scroll-past-last / first** | removed 2026-07-30 — confirmed clean | `grep -rIn -i scrollpast Sources rust/slopdesk-*/src` still returns nothing. |
| **Smooth scroll** | removed 2026-07-30 — confirmed clean | `grep -rIn -i smoothScroll Sources rust/slopdesk-*/src` still returns nothing. |
| **Backspace-deletes-selection** | removed — its replacement claim is now FALSE | `BackspaceSelectionPolicy` confirmed still absent. But the prior verdict's replacement claim — "reached by ⌘X via `CutSelectionPolicy`" — no longer holds: per the Cut row above, `CutSelectionPolicy`/`CutAction` has zero production callers, so Cut never actually deletes at a prompt today. Backspace-deletes-selection is correctly gone; its stated successor is a dead door, not a shipped gesture. |
| **Undo at prompt** | done on iOS **only — real Mac gap**, was "done (redo still omitted)" | `PromptEditPolicy.swift` (`:12,22`) wraps `slopdesk_term_prompt_edit_byte` (`rust/slopdesk-terminal/src/surface.rs::prompt_edit_byte`, ~line 164). Its **only** call site in `Sources/` is `Sources/SlopDeskPhoneUI/Pane/TerminalLeafView.swift:1223-1239` — the phone. `MacTerminalRendererView.keyDown` (`:169-193`) has no reference to `PromptEditPolicy` or the FFI door at all. Three separate doc comments assert Mac parity that the code does not have: `PromptEditPolicy.swift`'s own header, `TerminalLeafView.swift:1214-1215` ("the SAME function the Mac's terminal-surface `keyDown` calls"), and `SettingsKey.swift:497-498` ("Read live by the terminal surface's `keyDown`"). ⌘Z at an editable prompt does nothing on the Mac client today; it works only on the phone. Redo is still deliberately unanswered on both (no portable readline redo keystroke). |
| **Hyperlinks (OSC 8)** | **gap — real regression**, was "done" | No OSC-8/hyperlink handling exists anywhere in `rust/slopdesk-vterm`, `rust/slopdesk-terminal`, or `Sources/SlopDeskTerminal` (grepped for "osc.*8"/"hyperlink" across all three — zero hits; `config.rs`'s one nearby comment, ~265-267, only notes slopdesk's own plain-text detector doesn't touch OSC 8, on the apparent assumption something else does — nothing does). The vendored `libghostty-vt` crate does track OSC-8 state per cell internally, but `slopdesk-vterm` never reads it, and the old fork's dispatch (`GHOSTTY_ACTION_OPEN_URL`, an `action_cb` callback) belonged to a C-callback system this pull-only FFI does not have. `docs/68-terminal-surface-in-rust.md` never mentions OSC 8. An OSC-8 link whose display text is not itself a URL gets no underline and no click-to-open today, on either platform — larger than the old Notes §2 ceiling, which only conceded the keyboard/Hint-Mode side. |
| **Plain-text link/path detection, ⌘-click, ⌘-hold highlight** | done — one filename correction | `TerminalLinkDetector.swift`/`TerminalLinkHitTest.swift` confirmed live at their stated paths; `LinkActionPolicy.swift` confirmed at `Sources/SlopDeskWorkspaceCore/Workspace/Domain/LinkActionPolicy.swift`. `MacLinkHighlightOverlay.swift` confirmed; phone overlay is `Sources/SlopDeskPhoneUI/Pane/LinkHighlightOverlayView.swift` (not `LinkHighlightOverlay.swift`). `link-url = false` (`config.rs:267`) is emitted into the dead `configString` — vestigial now, since `libghostty-vt` has no "own regex matcher" to disable in the first place (that was the old FULL ghostty fork's feature). |
| **Bracketed paste (DECSET 2004)** | done — mechanism moved | `pasteBracketed` still a live `TerminalContextMenu.Item` case, forced through `TerminalSurfaceDriver.PasteBracketing.force` (`:432-435`) → `surface.encodePaste(text, bracketed: true)`. `PasteTransform.bracketed` confirmed deleted — `PasteTransform.swift:9-19` documents the move to the engine (`docs/68` §4.2). |
| **Resize / SIGWINCH propagation** | done — moved | `TerminalSurfaceDriver.setGeometry(size:scale:)` (`:215-226`) → `surface.setGeometry` → drains pty replies (a resize can emit an in-band size report) → `setSize(cols:rows:)` → `model?.sendResize(cols:rows:)` (`:157`), the SIGWINCH-equivalent to the host. Called from `MacTerminalRendererView.layout()`/`viewDidMoveToWindow()` (`:97-111`) and `PhoneTerminalRendererView.layoutSubviews()`/`didMoveToWindow()` (`:84-103`). |
| **Live grid reflow on font change** | done — moved | Same `setGeometry` path; a font-size change alters the cell metrics `setGeometry` re-measures against on the next layout pass, so the grid follows without a separate config-reload step. |
| **Focus state** | done — unchanged behaviour, hollow cursor implemented and tested | `TerminalSurfaceDriver.setFocus(_:blinkVisible:)` (`:229-232`) → FFI `slopdesk_term_surface_set_focus` (`terminal_surface.rs:632-641`, "Drives the hollow cursor and nothing else"), called from `becomeFirstResponder`/`resignFirstResponder` on both platforms. Hollow-cursor-on-unfocus: `rust/slopdesk-termrender/src/layout.rs:550-553`, `paint.rs:897-914`, `RectStyle::Hollow` (`quad.rs:99`). |
| **Kitty image protocol (inline images)** | **gap**, was "na-remote" | `libghostty-vt` parses and tracks kitty graphics state (`docs/68` §4, "vt already has… kitty graphics state") but rendering is explicitly out of scope: `docs/68:231-232`, "Kitty-graphics rendering is out of the bar… nothing regresses by not drawing them." Confirmed independently: `rust/slopdesk-termrender/src/paint.rs` has exactly four passes — background, decoration, text, cursor — no image pass exists. State is parsed; nothing draws it. |
| **iTerm2 inline images** | **gap**, was "na-remote" | No `OSC 1337 File=` handling anywhere. The vendored `libghostty-vt` bindings implement only two other OSC 1337 subcommands (`CurrentDir`, treated like OSC 7; `Copy`, treated like OSC 52) — the image-carrying subcommand is absent. Not implemented at any layer. |
| **Sixel graphics** | **gap**, was "na-remote" | Only a Device-Attributes capability-flag constant exists in the vendored crate (self-identification only) — no sixel decoding/parsing code exists anywhere. `paint.rs`'s four passes confirm no image rendering regardless of what is parsed. |
| **Hint-mode** (URL / path hints, keyboard nav) | done — unchanged, lines drifted +~50 | `HintLabelAssigner.swift`: `slopdesk_hint_scan` still at line 215 (the one citation that didn't drift). `TerminalViewModel.swift`: `beginHint` `:1646` (was 1596), `handleHintKey` `:1710` (was 1660), `confirmHintTarget` `:1734` (was 1684), `cancelHintMode` `:1741` (was 1691). `TerminalHintActuator.swift` confirmed at `Sources/SlopDeskClientCore/Pane/`. `MacHintModeOverlay.swift` confirmed; phone file is `HintModeOverlayView.swift` (not `HintModeOverlay.swift`). **Ceiling:** OSC 8 hyperlink runs are still not hintable, and are now ALSO not clickable — see the Hyperlinks row above, which supersedes Notes §2 below. |
| **Read-only mode** (block input to the PTY) | done — client-side, unchanged, lines drifted +~42-43 | `TerminalViewModel.isReadOnly` `:1392` (was 1350), `enterReadOnly()` `:1453` (was 1410), `exitReadOnly()` `:1460` (was 1417), `onReadOnlyChanged` `:1409`. `WorkspaceStore+ReadOnly.swift` confirmed present. `MacPaneStatusPills.swift` confirmed; phone file is `PaneStatusPillsView.swift` (not `PaneStatusPills.swift`). |
| **Vi-mode** (libghostty NATIVE vi-mode) | n/a — the old comparison has no subject any more | `ghostty_action_readonly_e`/`GHOSTTY_ACTION_READONLY` belonged to the deleted embedder's whole C-callback/action system. `libghostty-vt` has no action/callback concept for vi-mode or readonly at all — it is a pull-only Rust library. There is nothing left to compare "declared and never called" against. slopdesk's own copy-mode engine (`rust/slopdesk-terminal/src/vimotion.rs`, reached from the modal branch in `MacTerminalRendererView.keyDown:186-191`) is the current vi-flavoured feature — see Copy-mode and Vi visual-char selection above — and it is not a port of libghostty's anything. |
| **Autocomplete** (shell completion overlay) | missing — unchanged | No `CompletionProvider`, no autocomplete overlay, no inline-suggestion surface anywhere in `Sources`, `Tests`, `rust/slopdesk-*/src`. `docs/DECISIONS.md` records this as a deliberate non-build. Spec placeholder `docs/ui-shell/spec/terminal-features__autocomplete.md` still exists as a gap placeholder. |

---

## Key Files

- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSurface.swift` — the seam: `TerminalSurface`, `TerminalSurfaceActions`, `TerminalViewportSnapshotting`, `TerminalSelectionControl`. **Did not move** despite an earlier draft of this doc claiming it did.
- `Sources/SlopDeskTerminal/MacTerminalRendererView.swift` — the AppKit conformer: key/mouse/scroll forwarding, hide-mouse-while-typing, the clipboard-write and paste-protection sheet presenters, the display link.
- `Sources/SlopDeskTerminal/PhoneTerminalRendererView.swift` — the UIKit conformer: hardware-key presses, pan/long-press/tap gestures, the clipboard confirmation mailbox.
- `Sources/SlopDeskTerminal/TerminalSurfaceDriver.swift` — the framework-neutral half: binds the pane, drains the two pull-only sinks, runs context-menu items, forwards every gesture door.
- `Sources/SlopDeskTerminal/TerminalRendererSurface.swift` — the one Swift type that owns the Rust handle; every member is a direct FFI call.
- `Sources/SlopDeskTerminal/TerminalRendererInstall.swift` — the one call that registers the renderer factory; replaces the deleted `slopdesk-ops enable-renderer`.
- `Sources/SlopDeskTerminal/PasteProtectionSheet.swift` — moved here from `Sources/SlopDeskMacUI/Terminal/`.
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift` — copy-mode + vi cursor, hint mode, read-only, `TerminalSurfaceActions` consumer.
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift` — right-click menu model + enablement rules (its own header comment about routing to "libghostty-vt binding actions" is stale prose, not live behaviour).
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift` — the ⌘F counter/nav engine's Swift face over `slopdesk_find_matches` (`rust/slopdesk-rowscan`, NOT `slopdesk-vterm`).
- `Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift` — Hint Mode labels over `slopdesk_hint_scan`.
- `Sources/SlopDeskWorkspaceCore/Terminal/` — the pure policies, several now confirmed UNWIRED (see matrix rows above for which): `CutSelectionPolicy` (unwired), `CopyReceipt`, `PasteSafetyAnalyzer`, `PastePrecheck`, `PasteTransform`, `ClipboardWritePolicy`, `PromptEditPolicy` (phone-only), `FocusFollowsMousePolicy` (unwired), `RightClickPasteInterceptPolicy` (unwired), `TerminalLinkDetector`, `TerminalLinkHitTest`, `ViLineMotion`. `PointerShapeMapping`, `MouseVisibilityMapping` and `ScrollbackWrapMapper` are DELETED, not merely moved — do not cite them.
- `Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift` — the user-facing render preferences (no longer `Codable`; the settings GUI that edited it is gone).
- `Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift` — builds the now-mostly-dead `configString`; still the sole source of `fontFamily`/`fontSize`, which ARE live.
- `rust/slopdesk-vterm/src/` — the engine wrapper: `selection.rs`, `input.rs` (key/mouse encoders), `find.rs`/`search.rs` (live-highlight search, separate from the find bar's counter), `screen.rs`, `session.rs`, `events.rs`, `frame.rs`, `keycode.rs`.
- `rust/slopdesk-termrender/src/` — the renderer: `paint.rs` (four passes: background, decoration, text, cursor — no image pass), `layout.rs`, `glyph.rs`, `atlas.rs`, `quad.rs`, `block.rs`.
- `rust/slopdesk-terminal/src/config.rs` — **spells the legacy `ghostty` config text; almost none of it is read any more** — see the Overview.
- `rust/slopdesk-terminal/src/` — `paste`, `surface` (undo byte + right-click-intercept, both partly/fully unwired on the Swift side), `tracker`, `mode`, `link`, `link_hit`, `link_action`, `vimotion`, `blocks`, `keybind`, `inputbox`, `dedup`, `prompt_flash`, `surface_action`, `controls`, `context_menu`, `copy_receipt`, `geometry`. **No `pointer.rs`, no `wrap_map.rs`** — both deleted.
- `rust/slopdesk-ffi/src/terminal_surface.rs` — the complete FFI door list; if a setting isn't reachable from here, it is not live, whatever `config.rs` says.
- `rust/slopdesk-ffi/src/surface_gesture.rs` — `slopdesk_term_right_click_intercepts_as_paste` and its neighbours.
- `rust/slopdesk-ffi/src/find_matches.rs` — the ⌘F counter/nav door, over `slopdesk-rowscan` (a separate crate from the engine).
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
That is **false today** for at least one row: **Undo at prompt** is phone-only (`PromptEditPolicy` has
no Mac call site — see the matrix row). Two more rows are effectively absent on BOTH platforms rather
than divergent (**Mouse-over-to-focus**, **Right-click action**'s paste-intercept arm), so they are not
parity breaks so much as universal gaps. What genuinely still differs by LAYOUT rather than capability:

- Hint Mode resolves a label by keystroke on the Mac and additionally by TAP on the phone
  (`TerminalViewModel.confirmHintTarget`, `:1734`).
- The paste-protection confirmation is a sheet-class presenter on the Mac
  (`Sources/SlopDeskTerminal/PasteProtectionSheet.swift`) and a mailbox-filed card on the phone
  (`Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCardView.swift`), over one shared presentation
  model.
- Modal-key interception is `keyDown` on the Mac and `pressesBegan` on the phone, but both build the
  same abstract key and feed the same `TerminalViewModel.takeModalKey` (`:752`).

Two macOS-only behaviours are genuinely platform-shaped rather than gaps: `NSCursor`-based
mouse-hide/pointer-shape actuation needs a hardware pointer the phone doesn't have (pointer-shape
itself is dropped, see the matrix). Everything else marked "gap" above is a real cross-platform or
universal absence, not a platform choice — see the matrix for which.

### Wiring gaps and dead seams — expanded substantially by this re-verification

The prior survey listed four. This pass found several more; all are also flagged inline in the matrix,
collected here for one read:

1. **`config.rs`'s legacy `ghostty` config text is dead almost everywhere it is spelled.**
   `TerminalConfigBroadcaster.configString` has no parser on the other end
   (`Sources/SlopDeskWorkspaceCore/Workspace/Store/PreferencesStore.swift:332`). Scrollback limit,
   cursor style/blink/colour/opacity/text, the font fallback chain and per-face styles, the 16-entry
   palette, copy-on-select, trim-trailing-on-copy, clear-selection-on-typing/copy, shift-arrow-select,
   mouse-shift-capture, click-to-move, and scroll-multiplier are all authored in `config.toml`,
   serialized into this string, published, and never read again. Only `fontFamily`/`fontSize` (crossed
   as separate typed fields) and the two genuinely doored settings below actually reach the renderer.

2. **`FocusFollowsMousePolicy` and `RightClickPasteInterceptPolicy` are both fully unwired.** Each
   file's own doc comment describes a Mac view actuator ("its `mouseEntered`/`mouseMoved` consult
   this") that does not exist in the current `MacTerminalRendererView.swift`. Neither policy has a
   caller anywhere in `Sources/`.

3. **`CutSelectionPolicy`/`CutAction` is unwired.** Cut (⌘X) is copy-only in production; the
   delete-at-an-editable-prompt half of the policy this doc previously said superseded
   Backspace-deletes-selection has never had a caller written for it.

4. **`PromptEditPolicy` (Undo at prompt) has a phone call site and no Mac one**, despite three
   separate comments (in the policy file, in the phone's own call site, and in `SettingsKey.swift`)
   asserting both platforms are wired.

5. **`TerminalSurfaceDriver.setTheme` has no caller.** The one live typed colour door
   (foreground/background/selection) that theoretically survives the `config.rs` deprecation is itself
   never invoked from the preferences pipeline.

6. **OSC 8 hyperlinks have no handling at all**, mouse or keyboard — a strictly larger gap than the
   prior "not hintable" ceiling, because the mouse-side hover/click path the fork provided has no
   replacement either (see the Hyperlinks matrix row; this supersedes the old §2 below).

7. **In-surface search highlights are still a second engine from the find bar's counter/nav** — not
   plumbed through a shared implementation, `TerminalSearchController.swift:9-13`'s divergence warning
   still applies, now between `slopdesk-rowscan` (counter/nav) and `slopdesk-vterm/find.rs`
   (highlight) rather than between the client mirror and libghostty's C search.

8. **Mouse pressure / force-click is dropped with no `DECISIONS.md` record**, unlike every other
   deliberate drop in this rewrite (OSC-22 pointer shape, OSC-52 read) which got one.

9. **`libghostty-vt`'s native vi-mode / readonly action system no longer exists as an API surface at
   all** — not merely unused. slopdesk's own copy-mode/read-only engines were never a port of it and
   need no reconciliation with it; see the Vi-mode matrix row.

10. **Autocomplete is entirely absent** — never built, not removed. The spec placeholder
    `docs/ui-shell/spec/terminal-features__autocomplete.md` still describes a feature with no code.

### What was REMOVED since the 2026-06-25/26 survey (unaffected by the terminal-surface rewrite)

- **Cursor "Smooth" animation (H3)** — the forward-compat `cursorAnimation` preference is gone, and so
  is the test that used to pin its retired-key decode (the test file itself no longer exists).
- **Scroll-past-first/last (I14) and Smooth scroll (I15)** — deleted 2026-07-30, confirmed still clean.
- **Backspace-deletes-selection (I7)** — `BackspaceSelectionPolicy` deleted; its claimed successor
  (Cut/`CutSelectionPolicy`) is confirmed unwired by this pass — see Wiring gaps §3.
- **`pasteToComposer`** — deleted with the Composer / Prompt-Queue / Send-to-Chat / Fork / agent-footer
  vertical (`92472b0a`, 2026-07-03).
- **The theme picker, catalogue, dual light/dark slots and per-theme fonts** — ONE APPEARANCE,
  user-directed 2026-08-08. `AppearancePreferences.swift` itself is now also gone; the ruling survives
  as a comment at `Sources/SlopDeskSlate/SlateDesign.swift:44`. The underlying palette PASSTHROUGH this
  ruling left intact is, separately, now unwired end to end — see the Theme/palette matrix row.
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
  shape is dropped (`docs/DECISIONS.md:18393-18407`); mouse-hide-while-typing needed no engine and moved
  straight into `MacTerminalRendererView.keyDown`.
- **`PasteTransform.bracketed`** — bracketed-paste framing moved into the engine (`slopdesk_term_surface_encode_paste`).
- **OSC-52 clipboard READ** — dropped; `libghostty-vt` never forwards a read request (`docs/DECISIONS.md:18386-18391`).

### What was LIFTED since the original 2026-06-25/26 survey (unaffected by the terminal-surface rewrite)

- **The copy-mode ceiling (2026-07-14).** Superseded again, in the SAME direction: the fork's ABI
  extension that first lifted it is gone, but its replacement — `libghostty-vt`'s own richer
  `selection::gesture` module — lifts it further still (`docs/68` §4, "a gain, not a gap").
- **Hint Mode** — built (E10 WI-9), on both platforms, unaffected by the rewrite.
- **Read-only mode** — built as a per-pane LOCK, on both platforms, unaffected by the rewrite.
- **OSC 9;4 progress state** and **OSC 7 working directory** — both superd-side and unaffected.

### Architecture note on the former "na-remote" items — **this section's premise no longer holds**

The prior survey marked Kitty images, iTerm2 images and Sixel graphics "na-remote": libghostty rendered
them from the raw PTY byte stream with no embedder involvement, so they "worked to the extent libghostty
v1.3.1 supported them, which was all three." **That premise is gone with the renderer it described.**
`libghostty-vt` is explicitly parse-only — `docs/68`: "`libghostty-vt` leaves pixel-pushing to the host
application" — and `rust/slopdesk-termrender/src/paint.rs`'s four passes (background, decoration, text,
cursor) contain no image-drawing code. Kitty graphics state is parsed and retained by the engine but
never drawn (`docs/68:231-232`, a deliberate scope cut, not a bug); iTerm2 inline images and sixel have
no parsing support at all in the vendored bindings. All three are genuine gaps now, not transparent
capability — see the matrix rows above, which replace this note's old verdict.
