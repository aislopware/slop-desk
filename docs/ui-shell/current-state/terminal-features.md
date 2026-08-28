# Terminal Features — Current Implementation State

> Area: Terminal features via libghostty surface
> Originally surveyed 2026-06-25 (E8 interaction-parity rows added 2026-06-26). Re-verified against
> the tree 2026-08-22: every row re-checked at a named `file:line`, and every row whose verdict
> changed says what changed it. Paths are repo-relative.

## Overview

SlopDesk renders the terminal with **libghostty** — no SwiftTerm fallback. The pin is no longer a
fork SHA: since the 2026-07-11 SLIM delta the tree carries **upstream `ghostty-org/ghostty` @ `v1.3.1`
plus one consolidated patch**, `ThirdParty/ghostty/slopdesk-libghostty-on-v1.3.1.patch` (17 files,
+1155/−341), built by `ThirdParty/ghostty/build-libghostty.sh` against Zig 0.15.2. The old
`21c717340b…` daiimus SHA survives only as historical provenance for the External-IO backend
(`ThirdParty/ghostty/README.md:92-96`). tmux control-mode and the iOS sync-search C API were dropped
from the delta in the same pass.

The seam is the `TerminalSurface` protocol (`Sources/SlopDeskTerminal/TerminalSurface.swift:21`);
the live conformer `GhosttySurface`
(`ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`) compiles only inside the GUI
app targets (macOS + iOS). **The embedder Swift lives under `ThirdParty/ghostty/`, not `Sources/`** —
a `Sources/`-only search reports the whole live paste / clipboard / selection cluster as deleted.

The optional capability extension `TerminalSurfaceActions` (`TerminalSurface.swift:68`) still carries
selection + clipboard + scrollback text, and **two further optional protocols joined it**:
`TerminalViewportSnapshotting` (`:184` — `viewportTextRows()`, `cellMetrics()`) and
`TerminalSelectionControl` (`:252` — `viewportInfo()`, `setSelection(anchor:head:rectangle:)`,
`clearSelection()`, `readScreenRow(_:)`, `lineRange(_:)`). The second is the Swift face of the fork
ABI extension that **lifted the copy-mode ceiling on 2026-07-14** (`docs/DECISIONS.md` ~line 815).

Two further structural shifts since the original survey:

- **Config emission moved to Rust.** `TerminalConfigBuilder` is now a marshalling shim
  (`Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift`, 241 lines, all record-packing);
  every libghostty `key = value` line is spelled once, in `rust/slopdesk-terminal/src/config.rs`
  (`docs/DECISIONS.md` "The terminal config text is emitted once, in Rust", 2026-08-15). Rows below
  cite the Rust line, because that is where the key lives.
- **Host-side OSC sniffing moved to superd.** `Sources/SlopDeskHost/HostOutputSniffer.swift` and
  `Sources/SlopDeskHost/CommandBlockSegmenter.swift` are **deleted**; the one pass over the outbound
  PTY stream is `rust/slopdesk-superd/src/sniffer.rs` (+ `commandblocks.rs`, `autoprogress.rs`).
  superd owns `read` on every PTY master, so there is exactly one reader.

libghostty is a full VT engine, so most text rendering below is handled transparently. This audit
covers what the **embedder** wired up, what is delegated to libghostty, and what is genuinely absent.

---

## Capability Matrix

| Feature | Status | Evidence file(s)/symbol(s) |
|---|---|---|
| **Selection** (mouse drag) | done | `GhosttySurface.sendMouseButton` / `sendMousePos` forward AppKit events; libghostty owns selection; `mouseCaptured` gates drag-vs-select. `GhosttySurface.swift:657,666,680` |
| **Selection clipboard** (copy-on-select, SELECTION pasteboard) | done | `slopdeskPasteboard(for:)` maps `GHOSTTY_CLIPBOARD_SELECTION` to a private pasteboard so drag-select never clobbers the system clipboard. `GhosttyTerminalView.swift:96-97`, `write_clipboard_cb:570` |
| **Copy** (⌘C / context menu) | done | `performBindingAction("copy_to_clipboard")`; `TerminalContextMenu.Item.copy`. `GhosttyTerminalView.swift:2320,2549`, `Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift:14` |
| **Cut** (⌘X / context menu) | done — NEW since the survey | Pure `CutSelectionPolicy` decides `.none` / `.copyOnly` / `.copyAndDelete` from selection + screen state (alt-screen and read-only both force copy-only). `Sources/SlopDeskWorkspaceCore/Terminal/CutSelectionPolicy.swift:12-20`, `TerminalContextMenu.swift:15`, `GhosttyTerminalView.swift:2326-2351` |
| **Copy receipt chip** | done — NEW since the survey | Pure `CopyReceipt` counts lines vs. characters and formats the transient confirmation chip. `Sources/SlopDeskWorkspaceCore/Terminal/CopyReceipt.swift:1-14` |
| **Paste** (⌘V / context menu) | done | `performBindingAction("paste_from_clipboard")` + bracketed paste (DECSET 2004) applied by libghostty. `GhosttyTerminalView.swift:2380,3573`, `TerminalContextMenu.swift:16` |
| **Paste as keystrokes** | done | `TerminalContextMenu.Item.pasteAsKeystrokes` → `surface.text(_:)`, bypassing bracketed paste. `TerminalContextMenu.swift:17`, `GhosttySurface.swift:597` |
| **OSC 52 clipboard read/write** | done | READ honours live `clipboard-read` (Allow/Ask/Deny, default **Ask**) via `slopdeskConfirmClipboardRead` → `PasteProtectionSheet`; every completion uses `confirmed:true` (deny = empty reply) to dodge read-gate recursion. WRITE honours `clipboard-write` through pure `ClipboardWritePolicy`. `GhosttyTerminalView.swift:482` (`read_clipboard_cb`), `:538` (`confirm_read_clipboard_cb`), `:570` (`write_clipboard_cb`), `:243` (`slopdeskWriteClipboard`); `Sources/SlopDeskWorkspaceCore/Terminal/ClipboardWritePolicy.swift` |
| **Select All** | done | `performBindingAction("select_all")`. `TerminalContextMenu.swift:24`, `GhosttyTerminalView.swift:2439,2571` |
| **Scroll (wheel / trackpad)** | done | `sendMouseScroll(deltaX:deltaY:mods:)` → `ghostty_surface_mouse_scroll`; momentum bits packed per upstream. `GhosttySurface.swift:690`, `GhosttyTerminalView.swift:2143-2146` |
| **Scroll to top / bottom** | done | `performBindingAction("scroll_to_top" / "scroll_to_bottom")` from copy-mode + context menu. `Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift:1198` |
| **Scrollback buffer** | done — moved to Rust | `scrollback-limit` emitted from the line count × a per-line byte estimate; factory default 10,000 lines. `rust/slopdesk-terminal/src/config.rs:240` (`FACTORY_SCROLLBACK_LINES`), `:253-256`, `:279` (`scrollback_limit_bytes`); pref at `Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift:96` |
| **Cursor shape / blink** | done — moved to Rust | `cursor-style` (block / block_hollow / bar / underline) + a blink tri-state where `default` emits NO line and leaves DEC mode 12 in charge. `config.rs:413-422`, `TerminalPreferences.swift:69-94` |
| **Mouse modes (X10/1000/1002/1003/SGR)** | done | libghostty owns mouse-reporting mode; `mouseCaptured` gates the embedder drag. `GhosttySurface.swift:657` |
| **Mouse pressure / force-click** | done | `sendMousePressure(stage:pressure:)` → `ghostty_surface_mouse_pressure`. `GhosttySurface.swift:697`, `GhosttyTerminalView.swift:2168` |
| **Kitty keyboard protocol** | done | Keys via `ghostty_surface_key` (libghostty encodes kitty/DECCKM). A Ctrl+C0 fast path sends the raw control byte so Ctrl-C/Z/D reach non-kitty-aware remote programs. `GhosttySurface.swift:575`, `GhosttyTerminalView.swift:1414-1423` |
| **IME / CJK input (macOS)** | done | Full `NSTextInputClient` conformance (marked text, candidate anchoring, input-source-switch guard); `ghostty_surface_text` commits, `preedit` publishes the composing run. `GhosttyTerminalView.swift:1267-1280,2809`, `GhosttySurface.swift:597,617` |
| **IME / CJK input (iOS)** | done — **path moved** | `Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift` **no longer exists**. The phone's responder is `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift:1-35`, which reads a `UIKey` into a `PhoneKey.Press` and asks `rust/slopdesk-workspace/src/phone_key.rs` which of two paths it takes (raw encoder vs. the UIKit text-system proxy that composes and commits through `insertText`). Copy Mode / Hint Mode are asked ABOVE that split, via `TerminalViewModel.takeModalKey` (`TerminalViewModel.swift:711`). |
| **Unicode / text styles** (bold, italic, dim…) | done | libghostty renders all standard SGR attributes; no embedder involvement. Unicode 17 width tables ride the fork delta (`ThirdParty/ghostty/README.md:62-64`). |
| **True colour / 256-colour** | done | `COLORTERM=truecolor`. `Sources/SlopDeskHost/HostEnvironment.swift:96` |
| **Box-drawing / powerline glyphs** | done | libghostty handles natively (own glyph rasteriser/atlas). |
| **Font family, size, weight** | done — moved to Rust, and widened | Beyond family/size/style: fallback families, per-face bold/italic/bold-italic, synthetic-style suppression, an always-emitted `font-feature` line (so "ligatures off" actually says `-calt,-liga,-dlig`), blending and a cell-height percent. `config.rs:308-372`, `TerminalPreferences.swift:45-51,120-145` |
| **Theme / palette** | done for the SURFACE; the app-level theme picker is **removed by ruling** | The libghostty passthrough is intact: `theme` (empty ⇒ no line), explicit `background`/`foreground`, a 16-entry ANSI palette emitted whole-or-not-at-all, and `selection-background`. `config.rs:386-408`, `TerminalPreferences.swift:52-57`. What went is the CHOOSER: ONE APPEARANCE (user-directed 2026-08-08, `docs/DECISIONS.md` ~line 7393) deleted `ThemeStore`, `ThemeChoice`, the dual light/dark slots and the per-theme font map — `Sources/SlopDeskVideoProtocol/Settings/AppearancePreferences.swift:9-13` states it, and `density` is the only surviving field. |
| **$TERM** | done | Default `TERM=xterm-ghostty`; `xterm-256color` fallback when the host cannot resolve the entry (#54700). `HostEnvironment.defaultTerm`/`fallbackTerm`/`resolveTerm`, over `rust/slopdesk-probe`'s `terminfo` |
| **TERMINFO propagation** | done | `TERMINFO` / `TERMINFO_DIRS` mirrored to the child so ncurses finds the ghostty entry in a non-standard dir. `HostEnvironment.swift:68-88` |
| **OSC 0/2 window title** | done — **moved to Rust** | `SniffEvent::Title`. Swift `HostOutputSniffer.swift` is deleted. `rust/slopdesk-superd/src/sniffer.rs:82`; OSC 1 (icon name) is deliberately ignored (`sniffer.rs:9`). |
| **BEL / bell** | done — **moved to Rust** | `SniffEvent::Bell`, ground-state only (a DCS/SOS/PM/APC body emits nothing, so no program can embed a phantom bell). `sniffer.rs:84`, bounded-parser rules at `:21-27` |
| **Shell integration (OSC 133)** | done — **moved to Rust, both ends** | Host: `sniffer.rs:11` (`C` and `D[;exit]` with the measured duration) + `rust/slopdesk-superd/src/commandblocks.rs`. Client: `Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` is now a 102-line handle over `rust/slopdesk-terminal/src/tracker.rs` (`slopdesk_mode_tracker_*`, `TerminalModeTracker.swift:47-94`). |
| **OSC 7 working directory** | done — **NEW since the survey** | `SniffEvent::Cwd` (`sniffer.rs:12,88`), promoted to wire type 33 `cwd` and type 34 `projectKey` with a warm-up gate, a dedupe latch and a `proc_pidinfo` fallback for OSC-7-less shells (`docs/DECISIONS.md` ~lines 726,747). The original survey called this unwired; it is the backbone of cwd inheritance and By-Project bucketing now. |
| **OSC 133 prompt jump** | done | `performBindingAction("jump_to_prompt:±count")`, count-scalable from copy-mode, plus a landing flash overlay on both platforms. `TerminalViewModel.swift:1208-1214`, `GhosttyTerminalView.swift:2451-2458`, `Sources/SlopDeskMacUI/Pane/MacPromptJumpFlashOverlay.swift`, `Sources/SlopDeskPhoneUI/Pane/PromptJumpFlashOverlay.swift` |
| **Notifications (OSC 9 / 777 / 99)** | done — **moved to Rust**; OSC 99 is new | `sniffer.rs:13,90` parses all three; delivery is `PaneNotificationRouter` (`Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift:377`) wired from both app roots (`Sources/SlopDeskMacUI/SlopDeskMacApp.swift`, `Sources/SlopDeskPhoneUI/PhoneAppDelegate.swift`) through `Sources/SlopDeskClientCore/App/ClientNotificationSinks.swift`. Settings keys at `Sources/SlopDeskWorkspaceCore/Workspace/Store/SettingsKey.swift:145-177`. |
| **Long-command completion notifications** | done | `CommandNotificationPolicy` (`Sources/SlopDeskWorkspaceCore/Connection/CommandCompletionNotifier.swift`) + the `notifications.longCommand` key. `SettingsKey.swift:146,471-472` |
| **OSC 9;4 progress state** | **done** — was "missing (by design)"; the filter is GONE | The sniffer now tells notification from progress by SHAPE (`9;4` and `9;4;…` are progress, `9;42 tests passed` is a notification) and hands the body up unparsed. `sniffer.rs:96-102,537-541`. It rides CONTROL wire type 32, is re-validated client-side by `Sources/SlopDeskProtocol/ProgressState.swift:13-21` (unknown discriminants dropped), mirrored per-pane in `Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+Progress.swift`, and drawn as a tab badge + macOS Dock aggregate. `rust/slopdesk-superd/src/autoprogress.rs` also synthesises an indeterminate badge for known long commands. States 4 (paused) and 5 (finished) are deliberately not carried — 5 folds onto the existing `commandStatus(.idle(exitCode:))` path (`ProgressState.swift:23-26`). |
| **In-terminal search (⌘F)** | done — engine moved to Rust, and widened | `TerminalSearchController` now calls `slopdesk_find_matches` (`Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift:213`); the regex dialect is the `regex` crate's, so no pattern can hang the find bar (`docs/DECISIONS.md` "⌘F was the same hazard as Hint Mode", 2026-08-17). A **whole-word** toggle joined literal/regex/case. The bar is real on both platforms: `Sources/SlopDeskMacUI/Pane/MacTerminalFindBar.swift`, `Sources/SlopDeskPhoneUI/Pane/TerminalFindBar.swift`, over shared `Sources/SlopDeskClientCore/Pane/TerminalFindBarModel.swift`. A global (cross-pane) variant exists at `Sources/SlopDeskWorkspaceCore/Terminal/GlobalSearchController.swift`. |
| **Copy-mode** (vi-like keyboard scrollback nav) | done — substantially expanded | `TerminalViewModel.enterCopyMode()` (`:1311`) / `exitCopyMode()` (`:1326`) / `handleCopyModeKey(_:)` (`:753`), with a repeat-count, `⌘/` key hints (`:590`), and a `takeModalKey` seam (`:711`) so the Mac `keyDown` and the phone's `TerminalInputHost` drive ONE engine. Badge/overlay on both platforms (`MacViModeOverlay.swift`, `ViModeOverlay.swift`). |
| **Vi visual-char selection in copy-mode** | **done — the documented ceiling was LIFTED 2026-07-14** | The fork gained `ghostty_surface_set_selection` / `_clear_selection` / `_viewport_info` / `_padding` / `_line_range` (`ThirdParty/ghostty/README.md:65-81`), surfaced as `TerminalSurface.setSelection(anchor:head:rectangle:)` (`Sources/SlopDeskTerminal/TerminalSurface.swift:261`) and implemented at `GhosttySurface.swift:914`. Copy-mode now carries a REAL cursor in screen coordinates re-clamped against fresh `viewportInfo()` on every key, `VisualMode {none,char,line,block}` (`TerminalViewModel.swift:471-475`, `setVisualMode` `:1273`), a yank that copies the vi selection (`yankCursorLine` `:1242`), and a cursor overlay on both platforms (`MacViCursorOverlay.swift`, `ViCursorOverlay.swift`). Word/column motions are `rust/slopdesk-terminal/src/vimotion.rs` over the SAME grapheme clustering the link scanner uses, so cursor and hint badge name the same column on a CJK row (`docs/DECISIONS.md` 2026-08-17, "The cursor and the badge disagreed on a CJK row"). **Any row calling this impossible is stale.** |
| **Right-click context menu** | done — item list changed | 14 items: copy, cut, paste, paste-as-keystrokes, paste-selection, paste-file-base64, paste-escaped, paste-bracketed, select-all, clear, copy-output, split-right, split-down, find. `TerminalContextMenu.swift:13-47`. **`pasteToComposer` is gone** — the Composer / Prompt-Queue / Send-to-Chat vertical was deleted 2026-07-03 (`92472b0a`). |
| **Right-click action** | done — now a libghostty passthrough | The Swift `RightClickAction.effect(...)` dispatcher is gone; the token is emitted as libghostty's own `right-click-action` (`ignore`/`paste`/`copy`/`copy-or-paste`/`context-menu`, default `context-menu`) and the library dispatches. `config.rs:459`, `Sources/SlopDeskWorkspaceCore/Terminal/TerminalControls.swift:60`. The embedder keeps only the ⌃-right-always-menu override plus `Sources/SlopDeskWorkspaceCore/Terminal/RightClickPasteInterceptPolicy.swift` (the paste-safety pre-check on the bare-right-click paste arm). |
| **Copy-on-Select** | done | `copy-on-select = clipboard` / `false`; ON writes drag-select to the private SELECTION pasteboard only. Default off. `config.rs:426-434`, `TerminalControls.swift:290` |
| **Trim trailing spaces on copy** | done | `clipboard-trim-trailing-spaces`, default on. `config.rs:436`, `TerminalControls.swift:293` |
| **Clear selection on typing / on copy** | done | `selection-clear-on-typing` (default on) / `selection-clear-on-copy` (default off). `config.rs:437-438` |
| **Shift+Arrow select** | done | ON emits four `shift+<dir>=adjust_selection:<dir>` keybinds; OFF must emit `unbind`, because the vendored fork binds them by default. `config.rs:483-489` |
| **Paste Protection sheet** | done — analyzer moved to Rust | `PasteSafetyAnalyzer` is a face over `slopdesk_paste_dangers` / `slopdesk_paste_should_warn`, and every WORD the sheet prints comes from the same crate. `Sources/SlopDeskWorkspaceCore/Terminal/PasteSafetyAnalyzer.swift:15,61,80,120-129`; pre-check at `Sources/SlopDeskWorkspaceCore/Terminal/PastePrecheck.swift`. The surface is per-platform by LAYOUT only: `Sources/SlopDeskMacUI/Terminal/PasteProtectionSheet.swift` (Mac) and `Sources/SlopDeskPhoneUI/Overlays/ClipboardConfirmCard.swift` (phone), over shared `Sources/SlopDeskClientCore/Overlays/ClipboardConfirmPresentation.swift`. |
| **Paste as…** | done — minus one item | Pure `PasteTransform` (`.bracketed` / `.shellEscaped` / `.base64(ofFileBytes:)`) + the four `paste*` context-menu items. `Sources/SlopDeskWorkspaceCore/Terminal/PasteTransform.swift`, `TerminalContextMenu.swift:20-23`. The fifth route, `pasteToComposer`, died with the Composer (`92472b0a`, 2026-07-03). |
| **Hide mouse while typing** | done | `mouse-hide-while-typing` passthrough **+ embedder actuation**: `GHOSTTY_ACTION_MOUSE_VISIBILITY` → `MouseVisibilityMapping.isVisible(forRawValue:)` (a face over `slopdesk_pointer_mouse_visible`) → `NSCursor.setHiddenUntilMouseMoves(!visible)`. Config alone is inert. `config.rs:446-449`, `Sources/SlopDeskWorkspaceCore/Terminal/MouseVisibilityMapping.swift:20`, `GhosttyTerminalView.swift:418,2274` |
| **Allow-shift-with-click / mouse-reporting / click-to-move** | done | `mouse-shift-capture` / `mouse-reporting` / `cursor-click-to-move`. `config.rs:450-458` |
| **Scroll multiplier** | done | `mouse-scroll-multiplier = precision:<m>,discrete:<m×3>` — libghostty's own 1:3 ratio preserved, and a plain multiply, never fused. `config.rs:460-467` |
| **Option-as-Alt** | done — NEW since the survey | `macos-option-as-alt` (`false`/`true`/`left`/`right`). `config.rs:468`, `TerminalControls.swift:165` |
| **Mouse-over-to-focus** | done | `mouseEntered`/`mouseMoved` call `model.onRequestFocus` gated by `FocusFollowsMousePolicy` (a face over `slopdesk_term_focus_follows_mouse`) — slopdesk panes are separate surfaces, so libghostty's own `focus-follows-mouse` covers only its internal split tree. `Sources/SlopDeskWorkspaceCore/Terminal/FocusFollowsMousePolicy.swift:20`, `GhosttyTerminalView.swift:2070,2103` |
| **OSC-22 pointer shape** | done | `GHOSTTY_ACTION_MOUSE_SHAPE` → `PointerShapeMapping.token(forRawValue:)` (validate-then-drop over `slopdesk_pointer_shape_token`) → `NSCursor`. `Sources/SlopDeskWorkspaceCore/Terminal/PointerShapeMapping.swift:55`, `GhosttyTerminalView.swift:401,2230` |
| **Cursor colour / opacity / text** | done | `cursor-color` / `cursor-text` (empty ⇒ follow the theme) / `cursor-opacity` (a number, so always emitted). `config.rs:472-480`, `TerminalPreferences.swift:104-109`. Live preview on both platforms: `Sources/SlopDeskMacUI/Settings/MacCursorPreviewSurface.swift`, `Sources/SlopDeskPhoneUI/Settings/CursorPreviewView.swift`. |
| **Cursor smooth animation** | **removed** (was "omitted, no fork hook") | The forward-compat preference is gone too: `cursorAnimation` is a RETIRED key that decodes and is ignored — `Tests/SlopDeskVideoProtocolTests/Settings/TerminalPreferencesDecodeTests.swift:29-32` pins that. There is no `cursorAnimation` field in `TerminalPreferences` and no setting row. |
| **Scroll-past-last / first** | **removed 2026-07-30** (was "partial — rendering deferred") | Settings, `ScrollPastPolicy` and the alt-screen suppression gate were all deleted: "they were shipped ahead of their renderer — the fork exposes no overscroll-margin API, so the anchors computed a float nothing could draw." `GhosttyTerminalView.swift:2161-2165`. A repo-wide `grep -rIn -i scrollpast Sources rust/slopdesk-*/src` returns nothing. |
| **Smooth scroll** | **removed 2026-07-30** (was "partial") | Same ruling, same comment: no row-snap hook, so `smoothScroll` OFF rendered exactly like ON. `GhosttyTerminalView.swift:2161-2165`. `smoothScroll` appears nowhere in `Sources`, `Tests` or `rust/slopdesk-*/src`. |
| **Backspace-deletes-selection** | **removed — superseded** (was "not yet functional, default OFF") | `BackspaceSelectionPolicy` no longer exists anywhere in the tree. The capability it was a placeholder for is real now and reached by a better gesture: **Cut** (⌘X) via `CutSelectionPolicy`, which can only delete at an editable prompt and copies-only otherwise. |
| **Undo at prompt** | done (redo still omitted) — rule moved to Rust | `PromptEditPolicy.bytes(forUndo:redo:inPromptZone:)` is a face over `slopdesk_term_prompt_edit_byte`; the readline UNDO byte itself lives in `rust/slopdesk-terminal/src/surface.rs`. ⌘⇧Z/⌘Y still returns nil and falls through — there is no portable readline redo keystroke. `Sources/SlopDeskWorkspaceCore/Terminal/PromptEditPolicy.swift:8,23`, `GhosttyTerminalView.swift:1456-1478` |
| **Hyperlinks (OSC 8)** | done | libghostty owns OSC 8 hit-testing + click; `GHOSTTY_ACTION_OPEN_URL` forwards resolved URLs. `GhosttyTerminalView.swift:380-400` |
| **Plain-text link/path detection, ⌘-click, ⌘-hold highlight** | done — NEW since the survey | A regex detector independent of OSC 8, hit-tested per cell and actuated through one pure policy shared by ⌘-click, the context menu, Hint Mode and Jump-To. `Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkDetector.swift`, `TerminalLinkHitTest.swift`, `Sources/SlopDeskWorkspaceCore/Workspace/Domain/LinkActionPolicy.swift`, `GhosttyTerminalView.swift:817,1734,1868`; overlays `Sources/SlopDeskMacUI/Pane/MacLinkHighlightOverlay.swift`, `Sources/SlopDeskPhoneUI/Pane/LinkHighlightOverlay.swift`. libghostty's own regex matcher is disabled (`link-url = false`, `config.rs:260`) so only one underline is drawn. |
| **Bracketed paste (DECSET 2004)** | done | Applied by libghostty inside `paste_from_clipboard`; forced by the `pasteBracketed` menu item. `GhosttyTerminalView.swift:3573`, `TerminalContextMenu.swift:23` |
| **Resize / SIGWINCH propagation** | done | `resize_callback` → `onResize` → `WireMessage.resize` → host `TIOCSWINSZ`; the host receives cols/rows, never pixels. `GhosttySurface.swift:276-292,496,531` |
| **Live grid reflow on font change** | done | `ghostty_app_update_config` triggers reflow; `resize_callback` fires; the host PTY grid tracks the new metrics. `GhosttySurface.swift:279-292` |
| **Focus state** | done — behaviour CHANGED since the survey | The survey said `setFocus(true)` for every visible pane. It is now forwarded faithfully: an unfocused pane gets `setFocus(false)` so libghostty draws its HOLLOW non-blinking cursor exactly like ghostty's own splits, and idles its render thread. Unfocus does NOT freeze the pane — repaint runs on the content-driven path. The forward is COALESCED one runloop hop (last-writer-wins) because an unfocus+refocus landing in one mailbox drain strands the blink timer with the cursor invisible. `GhosttyTerminalView.swift:889-938`, `GhosttySurface.swift:1076` |
| **Kitty image protocol (inline images)** | na-remote | Handled inside libghostty if the host program emits it. No embedder code; nothing disables it. |
| **iTerm2 inline images** | na-remote | Same. |
| **Sixel graphics** | na-remote | libghostty renders sixel natively. No embedder toggle turns it off. |
| **Hint-mode** (URL / path hints, keyboard nav) | **done** — was "missing" | Three intents (open / copy / reveal) with stable per-session 2-letter Vimium labels. Scan is `slopdesk_hint_scan` (`Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift:111,215`); state is `TerminalViewModel.beginHint` (`:1596`) / `handleHintKey` (`:1660`) / `confirmHintTarget` (`:1684`) / `cancelHintMode` (`:1691`); actuation reuses `LinkActionPolicy` via `Sources/SlopDeskClientCore/Pane/TerminalHintActuator.swift`. Overlay on both platforms: `Sources/SlopDeskMacUI/Pane/MacHintModeOverlay.swift`, `Sources/SlopDeskPhoneUI/Pane/HintModeOverlay.swift` (the phone resolves a label by TAP as well as by key). **Ceiling:** OSC 8 hyperlink RUNS are not hintable — see Notes §2. |
| **Read-only mode** (block input to the PTY) | **done — client-side** — was "missing" | Per-pane LOCK: `TerminalViewModel.isReadOnly` (`:1350`) with an observable badge twin (`:1357`), `enterReadOnly()` / `exitReadOnly()` (`:1410`, `:1417`), a rate-limited beep on a blocked keystroke (`:1396-1403`), and `onReadOnlyChanged` keeping `WorkspaceStore.paneReadOnly` in sync (`Sources/SlopDeskWorkspaceCore/Workspace/Store/WorkspaceStore+ReadOnly.swift`). Pill on both platforms (`MacPaneStatusPills.swift`, `PaneStatusPills.swift`). Note this is **not** libghostty's toggle — see Notes §3. |
| **Vi-mode** (libghostty NATIVE vi-mode) | still not used | `ghostty_action_readonly_e` (`ThirdParty/ghostty/integration/CGhostty/ghostty.h:668-670`, `GHOSTTY_ACTION_READONLY` at `:961`) is declared and never called. slopdesk implements both vi-navigation and read-only itself, above the library — see Notes §3. |
| **Autocomplete** (shell completion overlay) | missing | No `CompletionProvider`, no autocomplete overlay, no inline-suggestion surface anywhere in `Sources`, `Tests`, `rust/slopdesk-*/src` or `ThirdParty/ghostty/integration`. The only hits for the word are shell-emitted noise the block segmenter filters out (`rust/slopdesk-superd/src/commandblocks.rs:142`). Spec doc `docs/ui-shell/spec/terminal-features__autocomplete.md` remains a gap placeholder. |

---

## Key Files

- `Sources/SlopDeskTerminal/TerminalSurface.swift` — the seam: `TerminalSurface`, `TerminalSurfaceActions`, `TerminalSelectionControl` (setSelection / viewportInfo / lineRange / readScreenRow), `FeedBackpressuring`
- `ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift` — `GhosttySurface` (@MainActor conformer, all C ABI wrapping)
- `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — the AppKit/UIKit view: key + mouse forwarding, clipboard callbacks, IME, link hit-testing (~3,990 lines)
- `ThirdParty/ghostty/integration/CGhostty/ghostty.h` — the vendored C ABI header (line refs cited throughout)
- `ThirdParty/ghostty/README.md` — the pin, the slim delta, the copy-mode ABI extension, the build recipe
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift` — copy-mode + vi cursor, hint mode, read-only, `TerminalSurfaceActions` consumer
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift` — right-click menu model + enablement rules
- `Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift` — the ⌘F engine's Swift face over `slopdesk_find_matches`
- `Sources/SlopDeskWorkspaceCore/Terminal/HintLabelAssigner.swift` — Hint Mode labels over `slopdesk_hint_scan`
- `Sources/SlopDeskWorkspaceCore/Terminal/` — the pure policies: `CutSelectionPolicy`, `CopyReceipt`, `PasteSafetyAnalyzer`, `PastePrecheck`, `PasteTransform`, `ClipboardWritePolicy`, `PromptEditPolicy`, `PointerShapeMapping`, `MouseVisibilityMapping`, `FocusFollowsMousePolicy`, `RightClickPasteInterceptPolicy`, `TerminalLinkDetector`, `TerminalLinkHitTest`, `ViLineMotion`, `ScrollbackWrapMapper`
- `Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift` — the user-facing render preferences (the value)
- `Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift` — the marshalling shim only
- `rust/slopdesk-terminal/src/config.rs` — **where every libghostty config key is spelled**
- `rust/slopdesk-terminal/src/` — `paste`, `pointer`, `surface`, `tracker`, `mode`, `link`, `link_hit`, `link_action`, `vimotion`, `wrap_map`, `blocks`, `keybind`, `inputbox`, `dedup`
- `rust/slopdesk-superd/src/sniffer.rs` — the ONE pass over the outbound PTY stream (title, bell, OSC 133, OSC 7, OSC 9/777/99, OSC 9;4)
- `rust/slopdesk-superd/src/commandblocks.rs`, `blocks.rs`, `autoprogress.rs`, `shellintegration.rs` — command blocks + the synthetic progress badge
- `Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` — the client-side OSC 133 / CSI 1049 handle over `slopdesk_mode_tracker_*`
- `Sources/SlopDeskHost/HostEnvironment.swift` — `$TERM` / `TERMINFO` / `COLORTERM` for the spawned PTY
- `Sources/SlopDeskHost/HostEnvironment.swift` — the two `TERM` names and the resolution door
- `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift` — the phone's key responder (replaces the deleted `SlopDeskWorkspaceCore/iOS/InputRouting.swift`)
- Per-platform terminal chrome — Mac: `Sources/SlopDeskMacUI/Pane/{MacTerminalLeafView,MacTerminalFindBar,MacHintModeOverlay,MacViCursorOverlay,MacViModeOverlay,MacLinkHighlightOverlay,MacPromptJumpFlashOverlay,MacPaneStatusPills}.swift`; phone: `Sources/SlopDeskPhoneUI/Pane/{TerminalLeafView,TerminalFindBar,HintModeOverlay,ViCursorOverlay,ViModeOverlay,LinkHighlightOverlay,PromptJumpFlashOverlay,PaneStatusPills,TerminalInputHost,TerminalLetterboxContainer}.swift`; shared: `Sources/SlopDeskClientCore/Pane/{TerminalFindBarModel,TerminalHintActuator,HintPresentation,FindBarPresentation,ViKeyHintPresentation,TerminalTouchSelection,TerminalLeafPolicy,TerminalPaneWiring}.swift`

---

## Notes

### Cross-platform parity

Every terminal capability in the matrix exists on **both** macOS and iOS. The client-UI split
(`docs/56-client-ui-split.md`, 2026-08-17) turned one `SlopDeskClientUI` target into `SlopDeskMacUI`
+ `SlopDeskPhoneUI` over shared `SlopDeskClientCore`, under the rule **"layout diverges; capability
does not"** (`docs/56-client-ui-split.md:144-145`). What differs here is arrangement and gesture, not
ability:

- Hint Mode resolves a label by keystroke on the Mac and additionally by TAP on the phone
  (`TerminalViewModel.confirmHintTarget`, `:1684`).
- The paste-protection confirmation is an `NSAlert`-class sheet on the Mac
  (`MacUI/Terminal/PasteProtectionSheet.swift`) and a card on the phone
  (`PhoneUI/Overlays/ClipboardConfirmCard.swift`), over one shared presentation model.
- Modal-key interception is `keyDown` on the Mac and `pressesBegan` on the phone, but both build the
  same abstract key and feed the same `TerminalViewModel.takeModalKey` (`:711`).

Two macOS-only behaviours are genuinely platform-shaped rather than gaps: `NSCursor`-based
mouse-hide/pointer-shape actuation and focus-follows-mouse both need a hardware pointer.

### Wiring gaps and dead seams

1. **In-surface search highlights** — libghostty's own search-result callbacks are still not plumbed
   through the C `action_cb`. `performBindingAction("start_search:<needle>")` is wired compile-only so
   the library highlights internally, but the count and next/prev UX are computed from the client-side
   text mirror via `slopdesk_find_matches`. The two are independent and can drift (e.g. on wrapped
   lines). `TerminalSearchController.swift:9-13`

2. **OSC 8 hyperlink runs are not hintable or jumpable** — an accepted ceiling
   (`docs/DECISIONS.md` ~line 332). `HintLabelAssigner` and Jump-To feed only the plain-text detector,
   so an OSC 8 link whose DISPLAY text is not itself a URL (`click here` → `https://…`) gets no label.
   The vendored `ghostty.h` exposes the OSC 8 URL only through `GHOSTTY_ACTION_MOUSE_OVER_LINK` — a
   hover callback for the single link under the mouse, not a viewport-grid enumeration. libghostty's
   hover underline and ⌘-click still open it for the MOUSE; only the keyboard surfaces miss it.
   Lifting this needs a new per-cell hyperlink read API in the fork.

3. **libghostty's native vi-mode / read-only toggle is still called by nothing.**
   `ghostty_action_readonly_e` (`ghostty.h:668-670`) and `GHOSTTY_ACTION_READONLY` (`:961`) are
   declared and unreferenced — but this is no longer a capability gap, it is a design choice with two
   reasons. slopdesk's read-only is a WORKSPACE fact (`WorkspaceStore.paneReadOnly`, mirrored to the
   sidebar lock indicator and re-asserted across a reattach), not a surface fact; and slopdesk's
   copy-mode cursor is client state in screen coordinates that must agree with the hint overlay's
   column arithmetic. Both would have to be re-derived from library state to use the native toggle.

4. **Autocomplete is entirely absent** — never built, not removed. The spec placeholder
   `docs/ui-shell/spec/terminal-features__autocomplete.md` still describes a feature with no code.

### What was REMOVED since the 2026-06-25/26 survey

Each of these shipped or was scaffolded and is now gone. None was quietly dropped from the matrix
above; each has a row saying so.

- **Cursor "Smooth" animation (H3)** — the forward-compat `cursorAnimation` preference went with the
  feature. Retired-key decode pinned at `Tests/SlopDeskVideoProtocolTests/Settings/TerminalPreferencesDecodeTests.swift:29-32`.
- **Scroll-past-first/last (I14) and Smooth scroll (I15)** — deleted 2026-07-30 with
  `ScrollPastPolicy`. "They were shipped ahead of their renderer… add the settings back with the
  viewport hook that actuates them, not before." (`GhosttyTerminalView.swift:2161-2165`)
- **Backspace-deletes-selection (I7)** — `BackspaceSelectionPolicy` deleted; **Cut** (⌘X) is the
  capability, reached by the gesture that can actually be made safe.
- **`pasteToComposer`** — deleted with the Composer / Prompt-Queue / Send-to-Chat / Fork / agent-footer
  vertical (`92472b0a`, 2026-07-03).
- **The theme picker, catalogue, dual light/dark slots and per-theme fonts** — ONE APPEARANCE,
  user-directed 2026-08-08 (`docs/DECISIONS.md` ~line 7393). The libghostty theme/palette passthrough
  survives; only the chooser is gone.
- **`Sources/SlopDeskHost/HostOutputSniffer.swift` and `CommandBlockSegmenter.swift`** — ported to
  `rust/slopdesk-superd/src/{sniffer,commandblocks}.rs` and deleted in the same change (the
  one-implementation rule).
- **`Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift`** — replaced by
  `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift` over `rust/.../phone_key.rs`.
- **The E8 "partial" and "not yet functional" labels themselves** — no terminal setting in the tree
  now persists a preference nothing actuates. That was the point of the 2026-07-30 sweep.

### What was LIFTED since the survey

- **The copy-mode ceiling (2026-07-14).** The "no programmatic char-select" limit was an ABI gap, not
  a design truth. A fork ABI extension (`ghostty_surface_set_selection` and four companions) gave
  copy-mode a real vi cursor, keyboard-started char/line/block selection, an `o` swap-ends that does
  something, and a `y` that yanks the vi selection rather than falling back to the whole scrollback.
  `docs/DECISIONS.md` ~line 815; `ThirdParty/ghostty/README.md:65-81`.
- **Hint Mode** — built (E10 WI-9), on both platforms.
- **Read-only mode** — built as a per-pane LOCK, on both platforms.
- **OSC 9;4 progress state** — the "missing by design" filter is gone; progress is a first-class wire
  message (type 32) with a tab badge and a Dock aggregate.
- **OSC 7 working directory** — sniffed, host-derived and pushed as wire types 33/34.

### Architecture note on "na-remote" items

Inline images (Kitty, iTerm2), sixel and box-drawing are rendered by libghostty itself from the PTY
byte stream. Under PATH 1 (raw VT bytes: host PTY → client `feed()` → `ghostty_surface_write_output`)
the host program can emit any VT sequence and libghostty renders it — the embedder needs no
parse/proxy. They work to the extent libghostty v1.3.1 supports them, which is all three.
