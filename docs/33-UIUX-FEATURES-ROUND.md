# 33 — UI/UX + unique-features round (2026-06-12/13)

> **Historical session log (2026-06-12/13). Records work as of that date, not the current architecture. See [00-overview.md](00-overview.md) and [19-implementation-plan.md](19-implementation-plan.md) for current state.**

**Status: DONE — 25 features across 2 research rounds + 2 adversarial self-reviews, all shipped to `main` with headless tests. Full suite 1972/0. Several runtime FEELs are HW-pending (no 2-machine rig from automation).**

Base `faedc76` → HEAD `dac9813`. Each item is its own commit. Two ranked backlogs (5-agent research, then 22-agent review+research), implemented one-per-commit; two adversarial review passes (16 + 14 raw findings → 9 confirmed, all low-severity, all fixed).

## What shipped

### Round 1 (14)
| # | Feature | Key symbols |
|---|---|---|
| A1 | Reopen Closed Pane ⇧⌘T + busy-shell close guard | `WorkspaceStore.recentlyClosed`/`pendingClose`, `PaneSessionHandle.isShellBusy` |
| A2 | ⌘N default-kind pane, per-kind ⇧⌘N/⌥⌘N, Duplicate ⌘D | `WorkspaceCommand.newPaneDefault`/`duplicatePane`, `defaultChords(for:)` |
| A3 | Sidebar live titles + ⌘R reveals collapsed sidebar | `PanePresentation.displayTitle`, `pendingRename` |
| A4 | Connection-gate human errors + recent-hosts MRU + fade | `ConnectionPresenter`, `AppConnection.recentTargets` |
| A5 | Remote-window picker: filter, Change Window…, manual reveal | `RemoteWindowModel.filtered` |
| A6 | Viewport bookmarks ⇧⌘1–9 save / ⌘1–9 recall | `CanvasBookmark` (schema 6) |
| B1 | **Paste as Keystrokes** (type clipboard into secure fields) | `KeystrokeReplay`, `RemoteWindowModel.keyInjector`, `RemotePaneContext.onKeyInjectorReady` |
| B2 | **OSC 9/777 notifications** → local notification, click→pane | wire msg type 25, `HostOutputSniffer`, `PaneNotificationRouter` |
| B3 | Off-screen beacons + pulsing dialog beacons + respawn fix | `CanvasGeometry.offscreenBeacons`, `SystemDialogMonitor` suppression |
| B4 | ⌘K palette host-window section + `>`/`@`/`#` scopes | `CommandPaletteView.parseScope`, `addRemoteWindowPane` |
| B5 | **Settings scene ⌘,** (retires env gates) | `SettingsKey`, `SettingsView` |
| B6 | Overview ⌘\ (fit-all Mission Control, static cards) | `CanvasGeometry.overviewLayout`, `overviewActive` |
| B7 | Named layout presets (save/switch) | `LayoutPreset` (schema 7) |
| B8 | Lifecycle animations (pane in/out, Recenter fade) | item-id-keyed `.animation`, scoped off the camera offset |

### Round 2 (6)
| # | Feature | Key symbols |
|---|---|---|
| C1 | Align + distribute panes (Figma-style) | `Canvas.aligning(_:to:)`/`distributing(_:horizontal:)`, Pane▸Arrange |
| C2 | Multi-select (shift-click) + group-drag move-together + live preview | `selectedPanes`, `moveSelection`, `groupDragLive` |
| C3 | **Auto-switch layout on host app launch** | `LayoutPreset.triggerAppName` (schema 8), `AppLaunchMonitor` |
| C4 | Clipboard history ring + Paste Recent | `clipboardRing`, `ClipboardMonitor` |
| C5 | Resize to Native Stream Size | `nativeFrameSize` cache, `resizeToNativeSize` |
| C6 | Command-palette recents (recorded at the `apply()` chokepoint) | `recentCommands`, `WorkspaceCommand.isRecentsWorthy` |

Schemas advanced 5→8 (single-user no-backcompat: stale data resets).

## Design notes worth keeping
- **Paste-as-Keystrokes** is the unique payoff of the virtual-HID work ([[../docs]] efa8407): `KeystrokeReplay` maps the clipboard to US-QWERTY key strokes; the host's `postKey` routes per-event to virtual HID under Secure Event Input, so it types into SecurityAgent/sudo fields where `keyboardSetUnicodeString` is OS-dropped. Payload is never logged/persisted; rate-limited (`NotificationRateLimiter` for OSC, paced injection for keystrokes).
- **Overview is static cards, not `scaleEffect`** — transforming live CAMetalLayer/libghostty surfaces under SwiftUI scale tears/blanks; the static-card overview avoids it entirely and exits with no surface rebuild.
- **Lifecycle + group-drag animations are value-scoped and applied OUTSIDE the camera `.offset`** so a live pan/drag is never animated (the BUG-1/BUG-2 freeze class) and `@GestureState` resets stay instant.
- **New monitors** (`SystemDialogMonitor`, `ClipboardMonitor`, `AppLaunchMonitor`) follow one pattern: a scene `.task { await monitor.run() }`, poll loop ends on cancel, inert under automation / when nothing to do.

## ⚠️ HW-pending (verify on the real 2-machine rig)
None of these are headless-failures — every one is green in `swift test`. What needs a real keyboard + the deployed host:
1. **Paste-as-Keystrokes into a real password field** — needs the deployed `slopdesk-hid-bridge` (root) on the Studio; assert the field fills.
2. **OSC 9/777 notification** end-to-end (`printf '\e]9;done\e\\'` on the host → banner → click focuses the pane).
3. **Overview ⌘\** visual + the **B8 scale-on-insert** over live Metal/libghostty surfaces.
4. **Multi-select**: shift-click feel (`NSEvent.modifierFlags` read at commit) + the live group-drag preview.
5. **Off-screen beacon** pulse + click-to-reveal; **App-launch auto-switch** firing on a real host app launch.

## Deferred ideas (HW-feel, not built — next session with the rig)
QR/Handoff Mac↔iPad; drag-a-beacon-to-reveal (pan as you drag inward); overview live thumbnails (Metal snapshot per pane); a bookmark strip inside the overview; double-click-pill to maximize.
