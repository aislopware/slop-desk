# Privilege and Notifications

## Summary

Desktop notifications, bell, focus/attention requests, and the security toggles gating what a program in the terminal may do. Programs post macOS notifications via OSC 9 / 777 / 99. Bell (`BEL 0x07`) plays `NSSound.beep()`. The Dock bounces when a notification fires while slopdesk is not frontmost. Per-pane toggles under Settings → Shell control notifications; privilege toggles under Settings → Advanced and Settings → Controls gate risky escape sequences (clipboard read/write, title reporting, secure keyboard entry, IPC injection).

## Behaviors

- **OSC 9** (iTerm2): `printf '\e]9;Build finished\a'` — body-only notification.
- **OSC 777** (urxvt): `printf '\e]777;notify;Deploy;Production is live\a'` — title + body.
- **OSC 99** (kitty): `printf '\e]99;;Build finished\e\\'` — structured payload with urgency, base64 encoding, chunked transmission, replace-by-id, capability query.
- All three map to native macOS notifications (UserNotifications framework). Suppressed by disabling **Notification — Shell Controlled** (Settings → Shell).
- `BEL` (`0x07`) rings the system alert via `NSSound.beep()`. Controlled by **Sound — Shell Controlled** (Settings → Shell, on by default). No visual/flash bell — audio only.
- **Sound on Error Exit** (Settings → Shell, off by default) beeps on non-zero exit; requires shell integration.
- When a notification fires and slopdesk is not frontmost, the Dock bounces via `NSApplication.requestUserAttention`. Controlled by **Bounce Dock Icon** (Settings → Shell, on by default). Driven from notification OSCs (9 / 777 / 99), **not** the bell — unlike Ghostty.
- macOS suppresses banners while slopdesk is foreground by default. **Notify While Foreground** overrides with three states: `off` (default, system suppresses), `always` (show even when frontmost), `tab-unfocused` (show only when notification comes from a non-active tab). The rendered dropdown label for `tab-unfocused` is "Only when source tab is unfocused" — UI uses human-readable labels, not raw enum values.
- A **System Permission** status row (green = allowed, amber/red = blocked) sits atop Settings → Shell → Notification, with an **Open System Settings** button deep-linking to System Settings → Notifications → SlopDesk.
- All notification/privilege toggles are **per-pane defaults**; a new pane inherits current values. Shell-integration-dependent toggles require shell integration active.
- **Notify on Finish** (off): fires when any command exits code 0.
- **Notify on Error** (on): fires on non-zero exit.
- **Notify on Watch Finish** (on): fires when an `slopdesk watch`-wrapped command finishes.
- **Code Agent — Notify When Task Completes** (on): fires via IPC when a coding agent (Claude Code, Codex, OpenCode) finishes a task and goes idle. Does NOT require shell integration.
- **Code Agent — Notify When Awaiting Input** (on): fires via IPC when a coding agent needs approval/input. Does NOT require shell integration.
- **Title Report** (off, Settings → Advanced): allows apps to read the window title via `OSC 21` / XTWINOPS. Off by default because a program that can both set and read the title can exfiltrate data through a pane.
- **Title — Shell Controlled** (on, Settings → Advanced): allows apps to change the tab/window title via `OSC 0` / `OSC 2`.
- **Clipboard — Shell Controlled** (on, Settings → Advanced): master switch for `OSC 52` clipboard access.
- **Clipboard Read** (`ask` by default, Settings → Advanced): `OSC 52` read (program pasting from your clipboard). `ask` / `allow` / `deny`. Default `ask` because read is the larger exfiltration risk.
- **Clipboard Write** (`allow` by default, Settings → Advanced): `OSC 52` write. `ask` / `allow` / `deny`.
- **Auto Secure Input** (on, Settings → Controls): auto-enables macOS Secure Keyboard Entry when the active session enters canonical-no-echo mode (the `sudo` / `ssh` / `login` password-prompt signature), preventing other apps from reading keystrokes.
- **Secure Input Indicator** (on, Settings → Controls): shows a title-bar pill while Secure Keyboard Entry is active — "SECURE INPUT" uppercase white on solid blue (~#1565C0), far right of the title bar, lock icon to its left.
- **IPC Allow Send Keys** (off, Settings → Advanced): allows IPC clients to inject keystrokes.
- **IPC Allow Sensitive Sessions** (off, Settings → Advanced): allows IPC send-keys / capture to reach SSH / sudo sessions.
- Toggles also appear in the **Privileges menu** and **command palette**, not only in Settings.

## Keybindings

No dedicated keybindings on this page; all controls are in the Privileges menu and command palette.

| Action | Keys |
|--------|------|
| (none documented) | — |

## Config keys

All toggles live under Settings → Shell, Settings → Advanced, or Settings → Controls as noted.

| Key (UI label) | Default | Effect |
|---|---|---|
| Notification — Shell Controlled (Allow App Notifications) | on | Allow shell apps to post notifications via OSC 9 / 777 / 99 |
| Notify on Finish (Notify on Command Finish) | off | Notify when any command exits with code 0 |
| Notify on Error (Notify on Error Exit) | on | Notify when a command exits non-zero |
| Notify on Watch Finish | on | Notify when an `slopdesk watch`-wrapped command finishes |
| Notify While Foreground | off / `tab-unfocused` | Banner policy while slopdesk is frontmost: `off` (suppress), `always`, `tab-unfocused` |
| Bounce Dock Icon | on | Bounce Dock icon when notification arrives and slopdesk is not focused |
| Sound — Shell Controlled | on | Allow shell apps to ring `BEL` (plays `NSSound.beep()`) |
| Sound on Error Exit | off | Beep when a command exits with non-zero status (requires shell integration) |
| Code Agent — Notify When Task Completes | on | Notification via IPC when coding agent finishes and goes idle |
| Code Agent — Notify When Awaiting Input | on | Notification via IPC when coding agent awaits approval/input |
| Title Report | off | Allow apps to read the window title back via `OSC 21` / XTWINOPS |
| Title — Shell Controlled | on | Allow apps to set the tab/window title via `OSC 0` / `OSC 2` |
| Clipboard — Shell Controlled | on | Master switch for `OSC 52` clipboard access |
| Clipboard Read | ask | `OSC 52` clipboard read: `ask` / `allow` / `deny` |
| Clipboard Write | allow | `OSC 52` clipboard write: `ask` / `allow` / `deny` |
| Auto Secure Input | on | Auto-enable macOS Secure Keyboard Entry on canonical-no-echo mode |
| Secure Input Indicator | on | Show a title-bar pill badge while Secure Keyboard Entry is active |
| IPC Allow Send Keys | off | Allow IPC clients to inject keystrokes into sessions |
| IPC Allow Sensitive Sessions | off | Allow IPC send-keys / capture to reach SSH / sudo sessions |

## Visual spec

### notification.png — System notification banner

Standard macOS Notification Center banner, OS-rendered. Rounded-rectangle card (~740×130 pt), light grey background (~#F2F2F2), corner radius ~16 pt, subtle drop shadow on a neutral grey desktop.

Layout (left to right):
- **App icon** (left, vertically centred): the slopdesk icon — dark near-black circle (~50×50 pt) with a white/light-grey `>_` glyph. ~16 pt leading inset.
- **Text block** (~16 pt gap right of icon), two lines, left-aligned, vertically centred:
  - Line 1 — **title**: "Deploy" — semibold/bold, ~15–16 pt, near-black (~#111111).
  - Line 2 — **body**: "Production is live" — regular, ~13–14 pt, mid-grey (~#555555).
- No action/close/expand controls (banner-style, not alert-style).

OS-rendered entirely; the app supplies only title string, body string, and app icon. No custom slopdesk UI.

### notification-setting.png — Settings → Shell → Notification panel

Standard macOS preferences window (light mode). Traffic-light buttons (red/yellow/grey; yellow and grey dimmed) at top-left.

**Left sidebar** (~300 pt, light grey #F5F5F5):
- Search bar at top (rounded, "Search" placeholder, grey magnifier).
- Navigation rows, icon + label, ~44 pt tall, no dividers:
  - General (info circle)
  - **Shell** (`>_` icon) — SELECTED, solid mid-grey fill (~#D0D0D0) rounded-rect highlight full sidebar width.
  - Controls (pointer/cursor icon)
  - Editor (document icon)
  - Agents (plug/lightning-bolt icon)
  - Appearance (palette icon)
  - Recipes (book icon)
  - Key Bindings (lightning-bolt icon)
  - Advanced (wrench icon)

**Right content area** (white, ~880 pt wide):

**Section header "NOTIFICATION"** — all-caps spaced label, medium grey (~#999999), ~11 pt, no divider above, ~24 pt top padding.

Toggle rows (label left, control right, grey subtitle below label):

1. **Allow App Notifications** — ON (green iOS-style pill ~51×31 pt). "Allow shell apps to send system notifications".
2. **Notify on Command Finish** — OFF. "Notify when a background command finishes".
3. **Notify on Error Exit** — ON. "Notify when a command fails".
4. **Notify on Watch Finish** — ON. "Notify when an `slopdesk watch`-wrapped command finishes".
5. **Notify While Foreground** — dropdown (not toggle) showing "Only when source tab is unfocused ∨". "Banner behavior while slopdesk is the foreground app". Light rounded-rect border (~1 pt, ~#CCCCCC), white fill, ~13 pt.
6. **Bounce Dock Icon** — ON. "Bounce the Dock icon when a notification arrives and slopdesk isn't focused".

**Section header "TAB BADGE"** — same style, ~24 pt top padding below last Notification row.

7. **When Command Finishes** — ON. "Show accent dot on tab when a command finishes".

**Row anatomy** (consistent):
- Label: ~15 pt system, semibold, near-black (#111111).
- Subtitle: ~13 pt system, regular, mid-grey (#777777).
- Toggle: iOS-style green (#34C759) on, grey off; ~51×31 pt pill.
- Rows separated by 1 pt hairline dividers, very light grey (~#EEEEEE), inset ~16 pt from left.
- Row height: ~64 pt (label + subtitle stack).

### secure-input.png — Secure Input title-bar pill

Terminal window, light mode. Traffic-light buttons (red/yellow/green, all active) top-left. Title bar centre shows "sudo ls" in regular grey.

**Secure Input pill** — far-right of the title bar, ~8 pt from the right edge:
- Solid medium-blue fill (~#1565C0, approx #1A6ECC).
- Rounded pill, ~120×24 pt, corner radius ~6 pt.
- White lock/shield icon (~14 pt) left, then "SECURE INPUT" white all-caps bold ~11 pt.
- Flush with title-bar height (vertically centred), no drop shadow.

Content area: white, monospace. Two lines: `~ > sudo ls` (green prompt `▷`, tilde in cyan/teal) and `Password:` with a black block cursor.

The indicator lives entirely within slopdesk's window frame — NOT a system-level overlay. All-green traffic lights confirm the window is focused.

## Screenshots

- `notification.png` — macOS notification banner, OSC 777 "Deploy / Production is live" example
- `notification-setting.png` — Settings → Shell panel, NOTIFICATION and TAB BADGE sections
- `secure-input.png` — Terminal window showing the "SECURE INPUT" blue pill during a `sudo` password prompt

## Implementation notes

### Straightforward

- **OSC 9 / 777 / 99 → native macOS notifications**: forwarded from the remote host PTY stream via the existing terminal mux. The client intercepts OSC sequences in the rendered stream and posts `UNUserNotificationContent` directly. Straightforward — slopdesk's client is macOS with full UserNotifications access.
- **Bell (`BEL 0x07`) → `NSSound.beep()`**: client intercepts `0x07` and calls `NSSound.beep()`.
- **Bounce Dock Icon**: `NSApplication.requestUserAttention(.informationalRequest)` on the client; same trigger point as notifications.
- **Notify While Foreground / tab-unfocused**: client knows the active pane/tab, so `tab-unfocused` filtering is local client logic.
- **Per-pane toggle defaults**: aligned with slopdesk's per-pane preference model (PreferencesStore injected).
- **Secure Input Indicator pill**: client-side title-bar badge (SwiftUI overlay or NSTextField). Blue pill, white "SECURE INPUT" all-caps + lock icon, far-right of title bar.
- **Auto Secure Input** (canonical-no-echo detection): host PTY layer observes termios `c_lflag & ECHO == 0 && c_lflag & ICANON != 0` and sends a control message; the client then calls `enableSecureEventInput()`. Requires a new control message type / wire event.
- **Clipboard — Shell Controlled / Read / Write** (`OSC 52`): clipboard lives client-side, so the client intercepts `OSC 52` and applies read/write policy locally. `ask` requires a client-side permission dialog.
- **Title — Shell Controlled** (`OSC 0` / `OSC 2`): client intercepts and updates the tab/window title. Common and straightforward.
- **Title Report** (`OSC 21` / XTWINOPS): client intercepts the query, optionally returns the current title into the PTY input stream. Disabled by default.

### Needs care / caveats

- **Code Agent notifications via IPC** (Claude Code / Codex / OpenCode): the agent runs on the **remote host**. The `ClaudeStatus` / `ClaudePaneDetector` / `AgentControlListener` infra already exists (memory 2026-06-21). The IPC path must tunnel over the existing TCP control channel: host agent-detector forwards state events, client fires local macOS notifications. **Flag: agent IPC state must transit the control channel.**
- **System Permission status row** (dot + "Open System Settings"): on macOS, query `UNUserNotificationCenter.current().getNotificationSettings` and deep-link to the preference pane. On **iOS**, `UIApplication.open(URL(string: UIApplication.openSettingsURLString)!)` opens the app's own settings, NOT the system notifications pane, which is not directly deep-linkable. **Flag: iOS cannot deep-link to the OS notification settings panel for a specific app.**
- **IPC Allow Send Keys / Sensitive Sessions**: "IPC" travels over the authenticated control channel; the security model is the trusted WireGuard mesh (per CLAUDE.md), not a local-process IPC threat model. Implemented as host-side guards on the agent-control socket (`SLOPDESK_AGENT_CONTROL=1` path). **Flag: semantics differ from a local-IPC threat model; implement as host-side agent-control guards.**
- **Sound on Error Exit**: requires shell integration (OSC 133 marks; slopdesk supports OSC 133 per workspace-ui-multiplexer memory). Host detects non-zero exit via the mark, sends a control event, client plays the sound. Depends on shell integration active on the remote shell.
- **Notify on Finish / Notify on Error**: same OSC 133 dependency; host must forward the exit-code event over the control channel.
- **`slopdesk watch` / Notify on Watch Finish**: `slopdesk watch` would be a host-side CLI wrapper emitting a watch-tagged finish event. Not yet implemented. **Flag: requires an slopdesk-side watch command.**
- **Configuration key names** (`privilege-*`, `notification-*`, `title-report`, `clipboard-read`, `clipboard-write`, `auto-secure-input`): slopdesk uses `SLOPDESK_*` env vars and `PreferencesStore` / `SettingsKey` (`Defaults` product), not a config file. Map each toggle to a `SettingsKey`; no config-file parser needed.
- **Privileges menu**: slopdesk has none currently. Toggles should appear in the command palette and settings panel; a dedicated app-menu group may be added but is not architecturally required.
