# Terminal Features — Current Implementation State

> Area: Terminal features via libghostty surface
> Date: 2026-06-25 (E8 interaction-parity rows added 2026-06-26)
> Auditor: Ariadne (Sonnet 4.6); E8 housekeeping per [ui-shell/plans/E8.md](../plans/E8.md)

## Overview

SlopDesk uses **libghostty** (vendored fork, SHA `21c717340b62349d67124446c2447bf38796540b`, pinned
Ghostty v1.3.1) as its sole terminal renderer — there is no SwiftTerm fallback. The seam is
`TerminalSurface` protocol (`Sources/SlopDeskTerminal/TerminalSurface.swift`), with the live
conformer `GhosttySurface` (`ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift`)
compiled only inside the GUI app targets (macOS + iOS). The optional capability extension
`TerminalSurfaceActions` exposes selection, clipboard actions, and scrollback text to the workspace
layer without importing CGhostty.

Because libghostty is a full VT/terminal engine (it powers the upstream Ghostty terminal emulator),
most text-rendering capabilities below are handled transparently by the library. The audit focuses on
what the **embedder** has wired up, what is intentionally delegated to libghostty, and what is
genuinely absent.

---

## Capability Matrix

| Feature | Status | Evidence file(s)/symbol(s) |
|---|---|---|
| **Selection** (mouse drag to select text) | done | `GhosttySurface.sendMouseButton/sendMousePos` forward AppKit events; libghostty owns selection. `mouseCaptured` gates drag-vs-select. `GhosttySurface.swift:564-611` |
| **Selection clipboard** (copy-on-select, SELECTION pasteboard) | done | `slopdeskPasteboard(for:)` maps `GHOSTTY_CLIPBOARD_SELECTION` to a private pasteboard so drag-select does NOT clobber the system clipboard. `GhosttyTerminalView.swift:92-97`, `write_clipboard_cb:293-325` |
| **Copy** (Cmd-C / context menu) | done | `performBindingAction("copy_to_clipboard")` via `TerminalSurfaceActions`; `TerminalContextMenu.Item.copy` wired in `GhosttyLayerBackedView.menu(for:)`. `GhosttySurface.swift:662-675`, `TerminalContextMenu.swift:15-38` |
| **Paste** (Cmd-V / context menu) | done | `performBindingAction("paste_from_clipboard")` + bracketed-paste (DECSET 2004) applied by libghostty. `GhosttyTerminalView.swift:257-275`, `TerminalContextMenu.swift:18` |
| **Paste as keystrokes** (context menu) | done | `TerminalContextMenu.Item.pasteAsKeystrokes` — routed to `surface.text(_:)` bypassing bracketed-paste. `TerminalContextMenu.swift:18`, `GhosttySurface.swift:543-551` |
| **OSC 52 clipboard read/write** | done | `read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` wired in `GhosttyApp.init`. **E8: the blanket auto-approve is replaced** — OSC-52 READ honours the live `clipboard-read` access (Allow / Ask / Deny, default **Ask**) via `slopdeskConfirmClipboardRead` → `PasteProtectionSheet`; every completion uses `confirmed:true` (deny = empty reply) to dodge the read-gate recursion. **OSC-52 WRITE now honours `clipboard-write` too:** `write_clipboard_cb` reads the libghostty `confirm` flag (set for `clipboard-write = ask`) and routes through the pure `ClipboardWritePolicy` → `PasteProtectionSheet(kind: .clipboardWrite)`, writing only on approve (was: ignored `confirm` and wrote unconditionally, so "Ask" behaved like "Allow"). `GhosttyTerminalView.swift` (`write_clipboard_cb`, `slopdeskWriteClipboard`), `ClipboardWritePolicy.swift` |
| **Select All** | done | `performBindingAction("select_all")` in context menu. `TerminalContextMenu.swift:19` |
| **Scroll (mouse wheel / trackpad)** | done | `GhosttySurface.sendMouseScroll(deltaX:deltaY:mods:)` → `ghostty_surface_mouse_scroll`. Scroll-momentum bits packed per upstream. `GhosttySurface.swift:596-604` |
| **Scroll to top / bottom** | done | `performBindingAction("scroll_to_top")` / `scroll_to_bottom"` exposed via copy-mode and context menu paths. `TerminalViewModel.swift:330-333` |
| **Scrollback buffer** | done | `scrollback-limit` config key via `TerminalConfigBuilder`; default 10,000 lines (×256 B estimate). Live-reload via `ghostty_app_update_config`. `TerminalPreferences.swift:39`, `TerminalConfigBuilder.swift:24-31` |
| **Cursor shape / blink** | done | `cursor-style` (block/bar/underline) and `cursor-style-blink` emitted by `TerminalConfigBuilder`, applied live. `TerminalPreferences.swift:28-37`, `TerminalConfigBuilder.swift:73-74` |
| **Mouse modes (X10/1000/1002/1003/SGR)** | done | libghostty owns mouse-reporting mode internally; `mouseCaptured` gates embedder drag behaviour. `GhosttySurface.swift:564-570` |
| **Mouse pressure / force-click** | done | `sendMousePressure(stage:pressure:)` → `ghostty_surface_mouse_pressure`. `GhosttySurface.swift:606-611` |
| **Kitty keyboard protocol** | done | Keys routed via `ghostty_surface_key` (libghostty encodes kitty/DECCKM transparently). Ctrl+C0 fast-path in `GhosttyLayerBackedView.keyDown` sends raw byte to preserve Ctrl-C/Z/D for non-kitty-aware remote programs. `GhosttyTerminalView.swift:832-853` |
| **IME / CJK input (macOS)** | done | `ghostty_surface_text` path for composed text; keys via `ghostty_surface_key`. `GhosttySurface.swift:538-551` |
| **IME / CJK input (iOS)** | done | Hidden `UITextView` proxy funnels committed text; physical Ctrl/Alt keys bypass via `ghostty_surface_key`. `Sources/SlopDeskWorkspaceCore/iOS/InputRouting.swift:3-61`, `GhosttyTerminalView.swift:1361-1563` |
| **Unicode / text styles** (bold, italic, dim, etc.) | done | libghostty renders all standard SGR attributes; no embedder involvement needed. |
| **True colour / 256-colour** | done | `COLORTERM=truecolor` set in `HostEnvironment.curated()`; libghostty renders all colour depths. `HostEnvironment.swift:73` |
| **Box-drawing / powerline glyphs** | done | libghostty handles these natively (its own glyph rasteriser/atlas). No embedder code needed. |
| **Font family, size, weight** | done | `font-family`, `font-size`, `font-style` in `TerminalConfigBuilder`; live-reload on settings change. `TerminalPreferences.swift:12-18`, `TerminalConfigBuilder.swift:58-62` |
| **Theme / palette** | done | `theme` + explicit `background`/`foreground` override (Monokai Pro flat). `TerminalConfigBuilder.swift:63-71`, `TerminalPreferences.swift:19-26` |
| **$TERM** | done | Default `TERM=xterm-ghostty` (native ghostty terminfo); fallback `xterm-256color` toggle (#54700). `HostEnvironment.swift:19`, `ClaudeCodeProfile.swift:20-25` |
| **TERMINFO propagation** | done | `TERMINFO` / `TERMINFO_DIRS` forwarded to child so ncurses finds the ghostty entry when it was in a non-standard dir. `HostEnvironment.swift:55-67` |
| **OSC 0/2 window title** | done | `HostOutputSniffer` parses OSC 0/2; emits `WireMessage.title`. Dedup on identical titles. `HostOutputSniffer.swift:351-366` |
| **BEL / bell** | done | `HostOutputSniffer` emits `WireMessage.bell` on ground-state BEL. `HostOutputSniffer.swift:215-217` |
| **Shell integration (OSC 133)** | done | A/B/C/D all parsed. Host sniffer emits `commandStatus(.running/.idle(exitCode:durationMS:))`. Client-side `TerminalModeTracker` also parses A-D for mode tracking. `HostOutputSniffer.swift:368-395`, `TerminalModeTracker.swift:321-344` |
| **OSC 133 prompt jump** | done | `performBindingAction("jump_to_prompt:-1")` / `jump_to_prompt:1"` wired in copy-mode and context-menu find paths. `TerminalViewModel.swift:335-337` |
| **Notifications (OSC 9 / OSC 777)** | done | Parsed in `HostOutputSniffer`; wired to `UNUserNotificationCenter` via `PaneNotificationRouter`. User toggle in Settings. `HostOutputSniffer.swift:397-424`, `SettingsView.swift:159` |
| **Long-command completion notifications** | done | `CommandNotificationPolicy` + `longCommandNotifications` Setting. `SettingsKey.swift:22,45-46` |
| **OSC 9;4 progress state** | missing (by design) | `HostOutputSniffer.swift:406-411` explicitly filters out `9;4` (progress-bar) payloads to avoid flooding alerts with raw winget/build output. No badge/progress-bar in the client UI. |
| **In-terminal search (⌘F)** | done | `TerminalSearchController` pure engine (literal + regex, case toggle, next/prev/wrap). Driven by libghostty `start_search:<needle>` binding. `TerminalSearchController.swift:1-194` |
| **Copy-mode** (vi-like keyboard scrollback nav) | done | `TerminalViewModel.isCopyMode`, `handleCopyModeKey(_:)` dispatches j/k/d/u/g/G/[/]/n/N/y/Enter/q/Esc to libghostty binding actions. `TerminalViewModel.swift:221-389` |
| **Vi visual-char selection in copy-mode** | missing (documented ceiling) | `TerminalViewModel.swift:303-308` documents: libghostty fork exposes NO programmatic cursor-move/set-selection action. `y`/Enter copies the mouse-made selection or full scrollback. |
| **Right-click context menu** | done | `TerminalContextMenu` model (copy/paste/paste-as-keystrokes/select-all/clear/copy-output/split/find **+ the E8 Paste-as items**) with enablement rules. Built as `NSMenu` in `GhosttyLayerBackedView.menu(for:)`. `TerminalContextMenu.swift:12-123`, `GhosttyTerminalView.swift:1174-1203` |
| **Right-click action** (H7/H8, E8) | done | `rightMouseDown` branches on the pure `RightClickAction.effect(controlHeld:hasSelection:)` (contextMenu / copy / paste / copyOrPaste / ignore); ⌃-right always shows the menu. Read live off `Defaults`. `GhosttyTerminalView.swift:1242` |
| **Copy-on-Select** (I4, E8) | done | `copy-on-select = clipboard/false` config passthrough; ON writes drag-select to the private SELECTION pasteboard (system clipboard untouched until ⌘C). Default off. `TerminalConfigBuilder.swift:110`, `TerminalControls.swift` |
| **Trim trailing spaces on copy** (I5, E8) | done | `clipboard-trim-trailing-spaces` config passthrough (default on). `TerminalConfigBuilder.swift:111` |
| **Clear selection on typing / on copy** (I6, E8) | done | `selection-clear-on-typing` (default on) / `selection-clear-on-copy` (default off) config passthrough. `TerminalConfigBuilder.swift:112-113` |
| **Shift+Arrow select** (I2, E8) | done | ON emits four `shift+<dir>=adjust_selection:<dir>` keybinds; OFF emits `unbind` (⇧+arrow forwards to the program). `TerminalConfigBuilder.swift:136-141` |
| **Paste Protection sheet** (I9, E8) | done | Pure `PasteSafetyAnalyzer` (multi-line / trailing-newline / `sudo`/`su` / control-char) gates `PasteProtectionSheet` in `slopdeskConfirmUnsafePaste`, replacing the auto-approve. Cancel completes with EMPTY data (no gate re-trip). `clipboard-paste-protection` / `clipboard-paste-bracketed-safe` config keys. `GhosttyTerminalView.swift:99-155`, `PasteSafetyAnalyzer.swift` |
| **Paste as…** (I10, E8) | done | Pure `PasteTransform` (`.bracketed` / `.shellEscaped` / `.base64(ofFileBytes:)`) + `TerminalContextMenu` items (pasteSelection / pasteFileBase64 / pasteEscaped / pasteBracketed / pasteToComposer) routed in `contextMenuAction` via `surface.text(_:)` / `NSOpenPanel` / `model.onPasteToComposer`. `PasteTransform.swift`, `GhosttyTerminalView.swift:1561,1627` |
| **Hide mouse while typing** (H9, E8) | done | `mouse-hide-while-typing` config passthrough (libghostty DECIDES) **+ embedder ACTUATION**: `action_cb` `GHOSTTY_ACTION_MOUSE_VISIBILITY` → pure `MouseVisibilityMapping.isVisible(forRawValue:)` ({0,1}-guarded; unknown int fails safe to visible) → `applyMouseVisibility` → `NSCursor.setHiddenUntilMouseMoves(!visible)` (mirrors ghostty `setCursorVisibility`; auto-shows on next move). The config alone is inert — libghostty delegates the hide to this action. `TerminalConfigBuilder.swift:121`, `GhosttyTerminalView.swift:356,1508`, `MouseVisibilityMapping.swift` |
| **Allow-shift-with-click / mouse-reporting / click-to-move** (E8) | done | `mouse-shift-capture` / `mouse-reporting` (allow-mouse-capture) / `cursor-click-to-move` config passthrough. `TerminalConfigBuilder.swift:122-124` |
| **Scroll multiplier** (E8) | done | `mouse-scroll-multiplier = precision:<m>,discrete:<m>` config passthrough. `TerminalConfigBuilder.swift:128` |
| **Mouse-over-to-focus** (H6, E8) | done | `mouseEntered`/`mouseMoved` call `model.onRequestFocus` gated by the pure `FocusFollowsMousePolicy` + live `Defaults` (slopdesk panes are separate surfaces; libghostty's own `focus-follows-mouse` covers only its internal split tree). `GhosttyTerminalView.swift:1296-1312`, `FocusFollowsMousePolicy.swift` |
| **OSC-22 pointer shape** (H14, E8) | done | `action_cb` `GHOSTTY_ACTION_MOUSE_SHAPE` → pure `PointerShapeMapping.token(forRawValue:)` (validate-then-drop on unknown raw int) → `NSCursor`; reset to arrow on `default`. `GhosttyTerminalView.swift:333,1453`, `PointerShapeMapping.swift` |
| **Cursor color / opacity / text** (H4/H5, E8) | done | `cursor-color` / `cursor-text` / `cursor-opacity` emitted from `TerminalPreferences` (empty colours skipped); live preview in `CursorPreviewView` (Appearance → Cursor). `TerminalConfigBuilder.swift:132-135`, `TerminalPreferences.swift:57-93` |
| **Cursor smooth animation** (H3, E8) | omitted (no fork hook) | The pinned libghostty fork exposes no cursor-animation key. `TerminalPreferences.cursorAnimation` (off/smooth) persists + surfaces for forward-compat but emits no config line. `TerminalPreferences.swift:42-93` |
| **Scroll-past-last / first** (I14/I15, E8) | **partial (rendering deferred)** | Settings persist + pure `ScrollPastPolicy.targetTopRow(...)` anchor + alt-screen suppression gate exist, BUT the policy is NOT yet called from `Sources/` (dormant anchor) and the blank-overscroll RENDERING is deferred (no libghostty viewport hook). Settings rows relabelled "Preference saved; overscroll rendering deferred" so the UI does not imply a behavior that does not occur. `ScrollPastPolicy.swift`, `GhosttyTerminalView.swift` (scrollWheel) |
| **Smooth scroll** (I15, E8) | **partial (rendering deferred)** | `smoothScroll` setting persists; scrolling already runs at pixel granularity, but the whole-row snap when OFF is deferred (the pinned fork has no `smooth-scroll` / row-snap hook). Settings row relabelled accordingly. `SettingsKey.swift` |
| **Backspace-deletes-selection** (I7, E8) | **not yet functional (default OFF)** | Pure `BackspaceSelectionPolicy` decision exists, but the pinned fork exposes no set-selection / cursor-geometry C API, so a faithful whole-run delete is impossible (a blind DEL run would delete the WRONG chars = data loss). With the toggle ON the effect is indistinguishable from OFF (one char deleted), so the `Defaults` default is now **OFF** and the Settings rows are relabelled "not yet functional" — the behavior is ABSENT, not degraded. Policy stays wired for a future geometry API. `BackspaceSelectionPolicy.swift`, `SettingsKey.swift` |
| **Undo at prompt** (I18, E8) | done (redo omitted) | Pure `PromptEditPolicy` maps ⌘Z at an editable prompt → readline UNDO `0x1F`; ⌘⇧Z/⌘Y returns nil + falls through (no portable readline redo). `PromptEditPolicy.swift`, `GhosttyTerminalView.swift:1072-1101` |
| **Hyperlinks (OSC 8)** | done | libghostty owns OSC 8 hit-testing and click internally; `action_cb` with `GHOSTTY_ACTION_OPEN_URL` forwards resolved URLs to `NSWorkspace.open` / `UIApplication.open`. `GhosttyTerminalView.swift:214-231` |
| **Bracketed paste (DECSET 2004)** | done | Applied by libghostty inside `paste_from_clipboard` binding action. `GhosttySurface.swift:665-666` |
| **Resize / SIGWINCH propagation** | done | `resize_callback` → `onResize` → `sendResize(cols:rows:)` → `WireMessage.resize` → host `TIOCSWINSZ`. `GhosttySurface.swift:279-292`, `GhosttyTerminalView.swift:718-778` |
| **Live grid reflow on font change** | done | `ghostty_app_update_config` triggers reflow; `resize_callback` fires; host PTY grid tracks new metrics. `GhosttyTerminalView.swift:387-394`, `GhosttyApp.applyTerminalConfig:143-155` |
| **Focus state** | done | `surface.setFocus(true)` called for ALL visible panes (unfocused siblings kept alive). Keyboard first-responder gated by `isFocusedPane`. `GhosttyTerminalView.swift:456-483`, `attach:618` |
| **Kitty image protocol (inline images)** | na-remote | Handled inside libghostty if the host program emits the protocol. No embedder code needed; no explicit evidence it is disabled. |
| **iTerm2 inline images** | na-remote | Same: libghostty handles if present. |
| **Sixel graphics** | na-remote | libghostty renders sixel natively if enabled. No embedder code toggles it off. |
| **Hint-mode** (URL / path hints keyboard nav) | missing | No hint-mode overlay or keyboard-driven URL-picking is implemented. OSC 8 links open on click only; no hint-mode binding action is wired. `GhosttyTerminalView.swift:214-231` |
| **Vi-mode** (libghostty native vi-mode) | missing | `GHOSTTY_READONLY_OFF/ON` enum exists in `ghostty.h:643-647` but is not called anywhere in the embedder. No binding action wires `toggle_readonly`. |
| **Read-only mode** (block all input to PTY) | missing | Same: `ghostty_action_readonly_e` is declared in the C header but the embedder never calls it. |
| **Autocomplete** (shell completion overlay) | missing | No `CompletionProvider`, no autocomplete overlay anywhere in `Sources/`. The spec doc at `docs/ui-shell/spec/terminal-features__autocomplete.md` exists as a gap placeholder. |

---

## Key Files

- `/Users/dev/slop-desk/Sources/SlopDeskTerminal/TerminalSurface.swift` — seam protocol + `TerminalSurfaceActions` + `FeedBackpressuring`
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/GhosttySurface/GhosttySurface.swift` — `GhosttySurface` (@MainActor conformer, all C ABI wrapping)
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift` — `GhosttyTerminalView` (SwiftUI/AppKit rendering view, key/mouse forwarding, clipboard callbacks)
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
- `/Users/dev/slop-desk/ThirdParty/ghostty/integration/CGhostty/ghostty.h` — C ABI header (line references cited throughout)

---

## Notes

### Wiring gaps and dead seams

1. **OSC 9;4 progress state** — explicitly filtered at `HostOutputSniffer.swift:406-411`. The sniffer skips any OSC 9 payload that starts with `4` or `4;` to avoid surfacing winget/MSBuild progress lines as desktop alerts. There is no progress-bar widget or Dock badge wired anywhere in the client. If a progress indicator is wanted, this filter must be replaced with a wire message type and a client-side consumer.

2. **Hint-mode** — the `GHOSTTY_ACTION_OPEN_URL` path in `GhosttyTerminalView.swift:218-232` only opens URLs that libghostty resolves via OSC 8 hyperlink hit-test. There is no keyboard-driven "hint overlay" that scans the visible screen for URLs/paths and assigns single-key labels. This is a new surface-level feature that would require either a libghostty binding action (if one exists) or a client-side overlay scanning `scrollbackTextLines()`.

3. **Vi-mode / read-only** — `GHOSTTY_READONLY_OFF/ON` (`ghostty.h:643-647`) is the C enum for libghostty's read-only surface toggle, but the embedder never calls `performBindingAction("toggle_readonly")` or any equivalent. The feature exists in the library but is wired to nothing.

4. **Vi visual-char selection in copy-mode** — documented ceiling at `TerminalViewModel.swift:303-308`. The pinned libghostty fork does not expose a programmatic cursor-move or set-selection C API, so client-side character-range selection is impossible without a library change.

5. **In-surface search highlights** — `TerminalSearchController.swift:9-12` notes that libghostty's search-result callbacks are not plumbed through the C `action_cb` yet. `performBindingAction("start_search:<needle>")` is called (so libghostty internally highlights), but the count/navigation UX is computed from the client-side text mirror (`scrollbackTextLines()`). The two are independent and can drift if libghostty's search result set differs from the text mirror (e.g. on wrapped lines).

6. **Autocomplete** — entirely absent from the codebase. The spec placeholder doc (`docs/ui-shell/spec/terminal-features__autocomplete.md`) confirms it is planned but not started.

### E8 interaction-parity (2026-06-26) — ceilings & omissions

E8 added the selection / copy / paste / scroll / mouse / cursor controls documented below. It is **wholly client-side** —
every OSC-52 / OSC-22 sequence already lands in the client's libghostty over the existing PATH-1 byte
stream, so there is **no wire / golden / version change** (the new fire-time `Defaults` keys stay off the
`EnvConfig` overlay + `video-prefs.json` sidecar; `scripts/golden-check.sh` stays zero-diff). The bulk is a
config-passthrough job through the existing live-reload pipeline (`TerminalControls` → `TerminalConfigBuilder`
→ `PreferencesStore.applyTerminal()` / `refreshTerminalControls()`). The honestly-stated limits:

1. **Cursor "Smooth" animation (H3) — omitted.** The pinned libghostty fork exposes no cursor-animation
   config key or hook. The `cursorAnimation` preference (off/smooth) persists + surfaces in Appearance →
   Cursor for forward-compatibility, but no `cursor-animation` line is emitted (there is none).

2. **Undo "redo" at the prompt (I18) — omitted.** ⌘Z → readline UNDO (`0x1F`) at an editable prompt;
   ⌘⇧Z/⌘Y returns nil and falls through because there is no portable readline redo keystroke.

3. **Scroll-past overscroll + smooth-scroll (I14/I15) — PARTIAL, rendering deferred (ceiling).** The client
   libghostty owns the viewport and the pinned fork exposes no overscroll-margin / sub-row-render /
   `smooth-scroll` API. The settings persist, the pure `ScrollPastPolicy` anchor arithmetic exists, and the
   alt-screen suppression gate is computed; BUT the policy is not yet called from `Sources/` (dormant anchor)
   and the blank-overscroll rendering + pixel-snap-on-gesture-end are deferred pending a libghostty viewport
   hook. ES-E8-5 is a documented PARTIAL. The Settings rows are relabelled "Preference saved; overscroll
   rendering deferred" so the UI does not imply a behavior that does not occur. No fake overscroll is faked.

4. **Backspace-deletes-selection (I7) — NOT YET FUNCTIONAL, default OFF (ceiling).** No set-selection /
   cursor-geometry C API in the pinned fork, so the embedder cannot prove a selection ends at the cursor; a
   blind DEL run for a mid-line selection would delete the WRONG characters (data loss), so the GUI pre-sends
   nothing and the effect with the toggle ON is indistinguishable from OFF (one character deleted). Rather
   than ship a default-ON toggle that does nothing, the `Defaults` default is now **OFF** and the Settings
   rows are relabelled "not yet functional" — the behavior is ABSENT, not degraded. The pure
   `BackspaceSelectionPolicy` (+ the `selectionEndsAtCursor` seam) stays wired for a future geometry API.

See [docs/DECISIONS.md](../../DECISIONS.md) "## E8 terminal interaction parity" for the full decision log.

### Architecture note on "na-remote" items

Inline images (Kitty, iTerm2), sixel graphics, and box-drawing are all rendered by libghostty itself from the PTY byte stream. The remote architecture (PATH 1 = raw VT bytes forwarded from host PTY → client `feed()` → `ghostty_surface_write_output`) means the host program can emit any VT sequence and libghostty will render it. The embedder does not need to parse or proxy these; they work to the extent libghostty supports them (and libghostty v1.3.1 / ghostty's feature set supports all three).
