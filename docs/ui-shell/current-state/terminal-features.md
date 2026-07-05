# Terminal Features — Current Implementation State

> Area: Terminal features via libghostty surface
> Date: 2026-06-25 (E8 interaction-parity rows added 2026-06-26)
> Auditor: Ariadne (Sonnet 4.6); E8 housekeeping per [ui-shell/plans/E8.md](../plans/E8.md)

## Overview

SlopDesk uses **libghostty** (vendored fork, SHA `21c717340b62349d67124446c2447bf38796540b`, pinned
Ghostty v1.3.1) as its sole terminal renderer — no SwiftTerm fallback. The seam is the
`TerminalSurface` protocol (`Sources/SlopDeskTerminal/TerminalSurface.swift`); live conformer
`GhosttySurface` (`ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`) compiles only
inside the GUI app targets (macOS + iOS). Optional capability extension `TerminalSurfaceActions`
exposes selection, clipboard actions, and scrollback text to the workspace layer without importing
CGhostty.

libghostty is a full VT engine (it powers upstream Ghostty), so most text-rendering below is handled
transparently. This audit covers what the **embedder** wired up, what is delegated to libghostty, and
what is genuinely absent.

---

## Capability Matrix

| Feature | Status | Evidence file(s)/symbol(s) |
|---|---|---|
| **Selection** (mouse drag) | done | `GhosttySurface.sendMouseButton/sendMousePos` forward AppKit events; libghostty owns selection. `mouseCaptured` gates drag-vs-select. `GhosttySurface.swift:564-611` |
| **Selection clipboard** (copy-on-select, SELECTION pasteboard) | done | `slopdeskPasteboard(for:)` maps `GHOSTTY_CLIPBOARD_SELECTION` to a private pasteboard so drag-select does NOT clobber the system clipboard. `GhosttyTerminalView.swift:92-97`, `write_clipboard_cb:293-325` |
| **Copy** (Cmd-C / context menu) | done | `performBindingAction("copy_to_clipboard")` via `TerminalSurfaceActions`; `TerminalContextMenu.Item.copy` in `GhosttyLayerBackedView.menu(for:)`. `GhosttySurface.swift:662-675`, `TerminalContextMenu.swift:15-38` |
| **Paste** (Cmd-V / context menu) | done | `performBindingAction("paste_from_clipboard")` + bracketed-paste (DECSET 2004) applied by libghostty. `GhosttyTerminalView.swift:257-275`, `TerminalContextMenu.swift:18` |
| **Paste as keystrokes** (context menu) | done | `TerminalContextMenu.Item.pasteAsKeystrokes` → `surface.text(_:)`, bypassing bracketed-paste. `TerminalContextMenu.swift:18`, `GhosttySurface.swift:543-551` |
| **OSC 52 clipboard read/write** | done | `read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` wired in `GhosttyApp.init`. **E8 replaces the blanket auto-approve.** READ honours live `clipboard-read` access (Allow/Ask/Deny, default **Ask**) via `slopdeskConfirmClipboardRead` → `PasteProtectionSheet`; every completion uses `confirmed:true` (deny = empty reply) to dodge read-gate recursion. WRITE now honours `clipboard-write`: `write_clipboard_cb` reads the libghostty `confirm` flag (set for `clipboard-write = ask`) and routes through pure `ClipboardWritePolicy` → `PasteProtectionSheet(kind: .clipboardWrite)`, writing only on approve (was: ignored `confirm`, wrote unconditionally, so "Ask" behaved like "Allow"). `GhosttyTerminalView.swift` (`write_clipboard_cb`, `slopdeskWriteClipboard`), `ClipboardWritePolicy.swift` |
| **Select All** | done | `performBindingAction("select_all")` in context menu. `TerminalContextMenu.swift:19` |
| **Scroll (wheel / trackpad)** | done | `GhosttySurface.sendMouseScroll(deltaX:deltaY:mods:)` → `ghostty_surface_mouse_scroll`; momentum bits packed per upstream. `GhosttySurface.swift:596-604` |
| **Scroll to top / bottom** | done | `performBindingAction("scroll_to_top")` / `scroll_to_bottom"` via copy-mode + context menu. `TerminalViewModel.swift:330-333` |
| **Scrollback buffer** | done | `scrollback-limit` via `TerminalConfigBuilder`; default 10,000 lines (×256 B estimate); live-reload via `ghostty_app_update_config`. `TerminalPreferences.swift:39`, `TerminalConfigBuilder.swift:24-31` |
| **Cursor shape / blink** | done | `cursor-style` (block/bar/underline) + `cursor-style-blink` emitted by `TerminalConfigBuilder`, applied live. `TerminalPreferences.swift:28-37`, `TerminalConfigBuilder.swift:73-74` |
| **Mouse modes (X10/1000/1002/1003/SGR)** | done | libghostty owns mouse-reporting mode; `mouseCaptured` gates embedder drag. `GhosttySurface.swift:564-570` |
| **Mouse pressure / force-click** | done | `sendMousePressure(stage:pressure:)` → `ghostty_surface_mouse_pressure`. `GhosttySurface.swift:606-611` |
| **Kitty keyboard protocol** | done | Keys via `ghostty_surface_key` (libghostty encodes kitty/DECCKM). Ctrl+C0 fast-path in `GhosttyLayerBackedView.keyDown` sends raw byte to preserve Ctrl-C/Z/D for non-kitty-aware remote programs. `GhosttyTerminalView.swift:832-853` |
| **IME / CJK input (macOS)** | done | `ghostty_surface_text` for composed text; keys via `ghostty_surface_key`. `GhosttySurface.swift:538-551` |
| **IME / CJK input (iOS)** | done | Hidden `UITextView` proxy funnels committed text; physical Ctrl/Alt bypass via `ghostty_surface_key`. `Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift:3-61`, `GhosttyTerminalView.swift:1361-1563` |
| **Unicode / text styles** (bold, italic, dim, etc.) | done | libghostty renders all standard SGR attributes; no embedder involvement. |
| **True colour / 256-colour** | done | `COLORTERM=truecolor` in `HostEnvironment.curated()`; libghostty renders all depths. `HostEnvironment.swift:73` |
| **Box-drawing / powerline glyphs** | done | libghostty handles natively (own glyph rasteriser/atlas). |
| **Font family, size, weight** | done | `font-family`, `font-size`, `font-style` in `TerminalConfigBuilder`; live-reload. `TerminalPreferences.swift:12-18`, `TerminalConfigBuilder.swift:58-62` |
| **Theme / palette** | done | `theme` + explicit `background`/`foreground` override (Monokai Pro flat). `TerminalConfigBuilder.swift:63-71`, `TerminalPreferences.swift:19-26` |
| **$TERM** | done | Default `TERM=xterm-ghostty` (native ghostty terminfo); fallback `xterm-256color` toggle (#54700). `HostEnvironment.swift:19`, `ClaudeCodeProfile.swift:20-25` |
| **TERMINFO propagation** | done | `TERMINFO` / `TERMINFO_DIRS` forwarded to child so ncurses finds the ghostty entry in a non-standard dir. `HostEnvironment.swift:55-67` |
| **OSC 0/2 window title** | done | `HostOutputSniffer` parses OSC 0/2 → `WireMessage.title`; dedup on identical titles. `HostOutputSniffer.swift:351-366` |
| **BEL / bell** | done | `HostOutputSniffer` emits `WireMessage.bell` on ground-state BEL. `HostOutputSniffer.swift:215-217` |
| **Shell integration (OSC 133)** | done | A/B/C/D parsed. Host sniffer emits `commandStatus(.running/.idle(exitCode:durationMS:))`. Client `TerminalModeTracker` also parses A-D. `HostOutputSniffer.swift:368-395`, `TerminalModeTracker.swift:321-344` |
| **OSC 133 prompt jump** | done | `performBindingAction("jump_to_prompt:-1")` / `jump_to_prompt:1"` in copy-mode + context-menu find. `TerminalViewModel.swift:335-337` |
| **Notifications (OSC 9 / OSC 777)** | done | Parsed in `HostOutputSniffer`; wired to `UNUserNotificationCenter` via `PaneNotificationRouter`; Settings toggle. `HostOutputSniffer.swift:397-424`, `SettingsView.swift:159` |
| **Long-command completion notifications** | done | `CommandNotificationPolicy` + `longCommandNotifications` Setting. `SettingsKey.swift:22,45-46` |
| **OSC 9;4 progress state** | missing (by design) | `HostOutputSniffer.swift:406-411` filters out `9;4` (progress-bar) payloads to avoid flooding alerts with raw winget/build output. No badge/progress-bar in client UI. |
| **In-terminal search (⌘F)** | done | `TerminalSearchController` pure engine (literal + regex, case toggle, next/prev/wrap), driven by libghostty `start_search:<needle>` binding. `TerminalSearchController.swift:1-194` |
| **Copy-mode** (vi-like keyboard scrollback nav) | done | `TerminalViewModel.isCopyMode`, `handleCopyModeKey(_:)` dispatches j/k/d/u/g/G/[/]/n/N/y/Enter/q/Esc to libghostty binding actions. `TerminalViewModel.swift:221-389` |
| **Vi visual-char selection in copy-mode** | missing (documented ceiling) | `TerminalViewModel.swift:303-308`: libghostty fork exposes NO programmatic cursor-move/set-selection action. `y`/Enter copies the mouse-made selection or full scrollback. |
| **Right-click context menu** | done | `TerminalContextMenu` model (copy/paste/paste-as-keystrokes/select-all/clear/copy-output/split/find **+ E8 Paste-as items**) with enablement rules; built as `NSMenu` in `GhosttyLayerBackedView.menu(for:)`. `TerminalContextMenu.swift:12-123`, `GhosttyTerminalView.swift:1174-1203` |
| **Right-click action** (H7/H8, E8) | done | `rightMouseDown` branches on pure `RightClickAction.effect(controlHeld:hasSelection:)` (contextMenu/copy/paste/copyOrPaste/ignore); ⌃-right always shows menu. Read live off `Defaults`. `GhosttyTerminalView.swift:1242` |
| **Copy-on-Select** (I4, E8) | done | `copy-on-select = clipboard/false` passthrough; ON writes drag-select to private SELECTION pasteboard (system clipboard untouched until ⌘C). Default off. `TerminalConfigBuilder.swift:110`, `TerminalControls.swift` |
| **Trim trailing spaces on copy** (I5, E8) | done | `clipboard-trim-trailing-spaces` passthrough (default on). `TerminalConfigBuilder.swift:111` |
| **Clear selection on typing / on copy** (I6, E8) | done | `selection-clear-on-typing` (default on) / `selection-clear-on-copy` (default off) passthrough. `TerminalConfigBuilder.swift:112-113` |
| **Shift+Arrow select** (I2, E8) | done | ON emits four `shift+<dir>=adjust_selection:<dir>` keybinds; OFF emits `unbind` (⇧+arrow forwards to program). `TerminalConfigBuilder.swift:136-141` |
| **Paste Protection sheet** (I9, E8) | done | Pure `PasteSafetyAnalyzer` (multi-line / trailing-newline / `sudo`/`su` / control-char) gates `PasteProtectionSheet` in `slopdeskConfirmUnsafePaste`, replacing auto-approve. Cancel completes with EMPTY data (no gate re-trip). `clipboard-paste-protection` / `clipboard-paste-bracketed-safe` keys. `GhosttyTerminalView.swift:99-155`, `PasteSafetyAnalyzer.swift` |
| **Paste as…** (I10, E8) | done | Pure `PasteTransform` (`.bracketed` / `.shellEscaped` / `.base64(ofFileBytes:)`) + `TerminalContextMenu` items (pasteSelection / pasteFileBase64 / pasteEscaped / pasteBracketed / pasteToComposer) routed in `contextMenuAction` via `surface.text(_:)` / `NSOpenPanel` / `model.onPasteToComposer`. `PasteTransform.swift`, `GhosttyTerminalView.swift:1561,1627` |
| **Hide mouse while typing** (H9, E8) | done | `mouse-hide-while-typing` passthrough (libghostty DECIDES) **+ embedder ACTUATION**: `action_cb` `GHOSTTY_ACTION_MOUSE_VISIBILITY` → pure `MouseVisibilityMapping.isVisible(forRawValue:)` ({0,1}-guarded; unknown int fails safe to visible) → `applyMouseVisibility` → `NSCursor.setHiddenUntilMouseMoves(!visible)` (mirrors ghostty `setCursorVisibility`; auto-shows on next move). Config alone is inert — libghostty delegates the hide to this action. `TerminalConfigBuilder.swift:121`, `GhosttyTerminalView.swift:356,1508`, `MouseVisibilityMapping.swift` |
| **Allow-shift-with-click / mouse-reporting / click-to-move** (E8) | done | `mouse-shift-capture` / `mouse-reporting` (allow-mouse-capture) / `cursor-click-to-move` passthrough. `TerminalConfigBuilder.swift:122-124` |
| **Scroll multiplier** (E8) | done | `mouse-scroll-multiplier = precision:<m>,discrete:<m>` passthrough. `TerminalConfigBuilder.swift:128` |
| **Mouse-over-to-focus** (H6, E8) | done | `mouseEntered`/`mouseMoved` call `model.onRequestFocus` gated by pure `FocusFollowsMousePolicy` + live `Defaults` (slopdesk panes are separate surfaces; libghostty's own `focus-follows-mouse` covers only its internal split tree). `GhosttyTerminalView.swift:1296-1312`, `FocusFollowsMousePolicy.swift` |
| **OSC-22 pointer shape** (H14, E8) | done | `action_cb` `GHOSTTY_ACTION_MOUSE_SHAPE` → pure `PointerShapeMapping.token(forRawValue:)` (validate-then-drop on unknown raw int) → `NSCursor`; reset to arrow on `default`. `GhosttyTerminalView.swift:333,1453`, `PointerShapeMapping.swift` |
| **Cursor color / opacity / text** (H4/H5, E8) | done | `cursor-color` / `cursor-text` / `cursor-opacity` from `TerminalPreferences` (empty colours skipped); live preview in `CursorPreviewView` (Appearance → Cursor). `TerminalConfigBuilder.swift:132-135`, `TerminalPreferences.swift:57-93` |
| **Cursor smooth animation** (H3, E8) | omitted (no fork hook) | Pinned fork exposes no cursor-animation key. `TerminalPreferences.cursorAnimation` (off/smooth) persists + surfaces for forward-compat but emits no config line. `TerminalPreferences.swift:42-93` |
| **Scroll-past-last / first** (I14/I15, E8) | **partial (rendering deferred)** | Settings persist + pure `ScrollPastPolicy.targetTopRow(...)` anchor + alt-screen suppression gate exist, BUT the policy is NOT yet called from `Sources/` (dormant anchor) and blank-overscroll RENDERING is deferred (no libghostty viewport hook). Settings rows relabelled "Preference saved; overscroll rendering deferred" so the UI does not imply an absent behavior. `ScrollPastPolicy.swift`, `GhosttyTerminalView.swift` (scrollWheel) |
| **Smooth scroll** (I15, E8) | **partial (rendering deferred)** | `smoothScroll` persists; scrolling already runs at pixel granularity, but the whole-row snap when OFF is deferred (pinned fork has no `smooth-scroll` / row-snap hook). Settings row relabelled accordingly. `SettingsKey.swift` |
| **Backspace-deletes-selection** (I7, E8) | **not yet functional (default OFF)** | Pure `BackspaceSelectionPolicy` exists, but the pinned fork exposes no set-selection / cursor-geometry C API, so a faithful whole-run delete is impossible (a blind DEL run deletes the WRONG chars = data loss). With toggle ON the effect is indistinguishable from OFF (one char deleted), so `Defaults` default is now **OFF** and Settings rows relabelled "not yet functional" — behavior is ABSENT, not degraded. Policy stays wired for a future geometry API. `BackspaceSelectionPolicy.swift`, `SettingsKey.swift` |
| **Undo at prompt** (I18, E8) | done (redo omitted) | Pure `PromptEditPolicy` maps ⌘Z at an editable prompt → readline UNDO `0x1F`; ⌘⇧Z/⌘Y returns nil + falls through (no portable readline redo). `PromptEditPolicy.swift`, `GhosttyTerminalView.swift:1072-1101` |
| **Hyperlinks (OSC 8)** | done | libghostty owns OSC 8 hit-testing + click; `action_cb` `GHOSTTY_ACTION_OPEN_URL` forwards resolved URLs to `NSWorkspace.open` / `UIApplication.open`. `GhosttyTerminalView.swift:214-231` |
| **Bracketed paste (DECSET 2004)** | done | Applied by libghostty inside `paste_from_clipboard`. `GhosttySurface.swift:665-666` |
| **Resize / SIGWINCH propagation** | done | `resize_callback` → `onResize` → `sendResize(cols:rows:)` → `WireMessage.resize` → host `TIOCSWINSZ`. `GhosttySurface.swift:279-292`, `GhosttyTerminalView.swift:718-778` |
| **Live grid reflow on font change** | done | `ghostty_app_update_config` triggers reflow; `resize_callback` fires; host PTY grid tracks new metrics. `GhosttyTerminalView.swift:387-394`, `GhosttyApp.applyTerminalConfig:143-155` |
| **Focus state** | done | `surface.setFocus(true)` for ALL visible panes (unfocused siblings kept alive); keyboard first-responder gated by `isFocusedPane`. `GhosttyTerminalView.swift:456-483`, `attach:618` |
| **Kitty image protocol (inline images)** | na-remote | Handled inside libghostty if the host program emits it. No embedder code; no evidence it is disabled. |
| **iTerm2 inline images** | na-remote | Same: libghostty handles if present. |
| **Sixel graphics** | na-remote | libghostty renders sixel natively if enabled. No embedder code toggles it off. |
| **Hint-mode** (URL / path hints keyboard nav) | missing | No hint-mode overlay or keyboard-driven URL-picking. OSC 8 links open on click only; no hint-mode binding action wired. `GhosttyTerminalView.swift:214-231` |
| **Vi-mode** (libghostty native vi-mode) | missing | `GHOSTTY_READONLY_OFF/ON` enum in `ghostty.h:643-647` but never called in the embedder; no binding action wires `toggle_readonly`. |
| **Read-only mode** (block all input to PTY) | missing | Same: `ghostty_action_readonly_e` declared in the C header but never called. |
| **Autocomplete** (shell completion overlay) | missing | No `CompletionProvider`, no autocomplete overlay in `Sources/`. Spec doc `docs/ui-shell/spec/terminal-features__autocomplete.md` exists as a gap placeholder. |

---

## Key Files

- `/Users/dev/slop-desk/Sources/SlopDeskTerminal/TerminalSurface.swift` — seam protocol + `TerminalSurfaceActions` + `FeedBackpressuring`
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift` — `GhosttySurface` (@MainActor conformer, all C ABI wrapping)
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — `GhosttyTerminalView` (SwiftUI/AppKit view, key/mouse forwarding, clipboard callbacks)
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Terminal/TerminalViewModel.swift` — copy-mode logic, `TerminalSurfaceActions` consumer, pasteboard write
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Terminal/TerminalContextMenu.swift` — right-click menu model + enablement rules
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/Terminal/TerminalSearchController.swift` — pure ⌘F find engine (literal + regex)
- `/Users/dev/slop-desk/Sources/SlopDeskHost/HostOutputSniffer.swift` — OSC 0/2/9/133/777 + BEL sniffer (host-side)
- `/Users/dev/slop-desk/Sources/SlopDeskClaudeCode/TerminalModeTracker.swift` — OSC 133 A/B/C/D + CSI 1049h/l mode tracker (client-side)
- `/Users/dev/slop-desk/Sources/SlopDeskHost/CommandBlockSegmenter.swift` — OSC 133 A→D block segmenter for Blocks feature
- `/Users/dev/slop-desk/Sources/SlopDeskVideoProtocol/Settings/TerminalPreferences.swift` — user-facing terminal render preferences
- `/Users/dev/slop-desk/Sources/SlopDeskVideoProtocol/Settings/TerminalConfigBuilder.swift` — `TerminalPreferences` → libghostty config string builder
- `/Users/dev/slop-desk/Sources/SlopDeskHost/HostEnvironment.swift` — `$TERM` / `TERMINFO` / `COLORTERM` for spawned PTY
- `/Users/dev/slop-desk/Sources/SlopDeskHost/ClaudeCodeProfile.swift` — `TERM` enum (xterm-ghostty vs xterm-256color)
- `/Users/dev/slop-desk/Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift` — iOS IME routing decision
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/CGhostty/ghostty.h` — C ABI header (line refs cited throughout)

---

## Notes

### Wiring gaps and dead seams

1. **OSC 9;4 progress state** — filtered at `HostOutputSniffer.swift:406-411` (skips any OSC 9 payload starting `4`/`4;`) to avoid surfacing winget/MSBuild progress lines as desktop alerts. No progress-bar widget or Dock badge anywhere. To surface progress, replace this filter with a wire message type + client-side consumer.

2. **Hint-mode** — the `GHOSTTY_ACTION_OPEN_URL` path (`GhosttyTerminalView.swift:218-232`) only opens URLs libghostty resolves via OSC 8 hit-test. No keyboard "hint overlay" scanning the screen for URLs/paths with single-key labels. Would require a libghostty binding action (if one exists) or a client-side overlay scanning `scrollbackTextLines()`.

3. **Vi-mode / read-only** — `GHOSTTY_READONLY_OFF/ON` (`ghostty.h:643-647`) is the C enum for libghostty's read-only toggle, but the embedder never calls `performBindingAction("toggle_readonly")` or equivalent. Exists in the library, wired to nothing.

4. **Vi visual-char selection in copy-mode** — documented ceiling (`TerminalViewModel.swift:303-308`). Pinned fork exposes no programmatic cursor-move / set-selection C API, so client-side character-range selection is impossible without a library change.

5. **In-surface search highlights** — `TerminalSearchController.swift:9-12`: libghostty's search-result callbacks are not plumbed through the C `action_cb` yet. `performBindingAction("start_search:<needle>")` is called (libghostty highlights internally), but count/navigation UX is computed from the client-side text mirror (`scrollbackTextLines()`). The two are independent and can drift if libghostty's result set differs (e.g. on wrapped lines).

6. **Autocomplete** — entirely absent. Spec placeholder `docs/ui-shell/spec/terminal-features__autocomplete.md` confirms planned-but-not-started.

### E8 interaction-parity (2026-06-26) — ceilings & omissions

E8 added the selection/copy/paste/scroll/mouse/cursor controls above. It is **wholly client-side** — every
OSC-52 / OSC-22 sequence already lands in the client's libghostty over the existing PATH-1 byte stream, so
**no wire / golden / version change** (new fire-time `Defaults` keys stay off the `EnvConfig` overlay +
`video-prefs.json` sidecar; `scripts/golden-check.sh` stays zero-diff). The bulk is config-passthrough
through the existing live-reload pipeline (`TerminalControls` → `TerminalConfigBuilder` →
`PreferencesStore.applyTerminal()` / `refreshTerminalControls()`). Honestly-stated limits:

1. **Cursor "Smooth" animation (H3) — omitted.** Pinned fork exposes no cursor-animation key/hook. The
   `cursorAnimation` preference (off/smooth) persists + surfaces in Appearance → Cursor for forward-compat,
   but no `cursor-animation` line is emitted (there is none).

2. **Undo "redo" at prompt (I18) — omitted.** ⌘Z → readline UNDO (`0x1F`) at an editable prompt; ⌘⇧Z/⌘Y
   returns nil and falls through — no portable readline redo keystroke.

3. **Scroll-past overscroll + smooth-scroll (I14/I15) — PARTIAL, rendering deferred (ceiling).** Client
   libghostty owns the viewport and the pinned fork exposes no overscroll-margin / sub-row-render /
   `smooth-scroll` API. Settings persist, pure `ScrollPastPolicy` anchor arithmetic exists, alt-screen
   suppression gate is computed; BUT the policy is not yet called from `Sources/` (dormant anchor) and
   blank-overscroll rendering + pixel-snap-on-gesture-end are deferred pending a libghostty viewport hook.
   ES-E8-5 is a documented PARTIAL. Settings rows relabelled "Preference saved; overscroll rendering
   deferred"; no overscroll is faked.

4. **Backspace-deletes-selection (I7) — NOT YET FUNCTIONAL, default OFF (ceiling).** No set-selection /
   cursor-geometry C API in the pinned fork, so the embedder cannot prove a selection ends at the cursor; a
   blind DEL run for a mid-line selection deletes the WRONG characters (data loss), so the GUI pre-sends
   nothing and the effect with the toggle ON is indistinguishable from OFF (one char deleted). Rather than
   ship a default-ON toggle that does nothing, `Defaults` default is now **OFF** and Settings rows relabelled
   "not yet functional" — behavior is ABSENT, not degraded. Pure `BackspaceSelectionPolicy` (+
   `selectionEndsAtCursor` seam) stays wired for a future geometry API.

See [docs/DECISIONS.md](../../DECISIONS.md) "## E8 terminal interaction parity" for the full decision log.

### Architecture note on "na-remote" items

Inline images (Kitty, iTerm2), sixel, and box-drawing are rendered by libghostty itself from the PTY byte
stream. Under PATH 1 (raw VT bytes host PTY → client `feed()` → `ghostty_surface_write_output`) the host
program can emit any VT sequence and libghostty renders it — the embedder needs no parse/proxy; they work to
the extent libghostty supports them (v1.3.1 supports all three).
