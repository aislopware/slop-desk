# Privilege and Notifications

## Summary

Desktop notifications, bell behaviour, focus/attention requests, and the security toggles that gate what a program in the terminal is allowed to do. Programs can post macOS system notifications via OSC 9, OSC 777, or OSC 99. The bell (`BEL 0x07`) plays via `NSSound.beep()`. The Dock icon bounces when a notification fires while slopdesk is not the active app. A comprehensive set of per-pane toggles under Settings → Shell control when notifications fire; privilege toggles under Settings → Advanced and Settings → Controls gate risky escape sequences (clipboard read/write, title reporting, secure keyboard entry, IPC injection).

## Behaviors

- **OSC 9** (iTerm2 convention): `printf '\e]9;Build finished\a'` — body-only system notification.
- **OSC 777** (urxvt-style): `printf '\e]777;notify;Deploy;Production is live\a'` — title + body system notification.
- **OSC 99** (kitty notification protocol): `printf '\e]99;;Build finished\e\\'` — richer structured payload supporting urgency, base64 encoding, chunked transmission, replace-by-id, and capability query.
- All three OSC protocols map to native macOS notifications (UserNotifications framework).
- Notifications can be suppressed by disabling **Notification — Shell Controlled** (Settings → Shell).
- `BEL` (`0x07`) rings the system alert sound via `NSSound.beep()`. Controlled by **Sound — Shell Controlled** (Settings → Shell, on by default).
- **Sound on Error Exit** (Settings → Shell, off by default) beeps when a command exits with non-zero status; requires shell integration.
- SlopDesk does **not** implement a visual/flash bell — audio only.
- When a notification fires and slopdesk is not the active application, the Dock icon bounces via `NSApplication.requestUserAttention`. Controlled by **Bounce Dock Icon** (Settings → Shell, on by default).
- SlopDesk drives the dock bounce from notification OSCs (9 / 777 / 99), **not** from the bell — unlike Ghostty.
- By default macOS suppresses notification banners while slopdesk is the foreground app. **Notify While Foreground** overrides this with three states: `off` (default, system suppresses), `always` (always show banners even when frontmost), `tab-unfocused` (show banner only when notification comes from a tab that is not the active one).
- In the notification-setting screenshot, the actual rendered label for this dropdown is "Only when source tab is unfocused", indicating the UI uses human-readable labels rather than raw enum values.
- A **System Permission** status row (green dot = allowed, amber/red = blocked) is shown at the top of Settings → Shell → Notification section, with an **Open System Settings** button that deep-links to System Settings → Notifications → SlopDesk.
- All notification/privilege toggles are **per-pane defaults** — a new pane inherits the current values; shell-integration-dependent toggles require shell integration active.
- **Notify on Finish** (off by default): fires when any command exits with code 0.
- **Notify on Error** (on by default): fires when a command exits non-zero.
- **Notify on Watch Finish** (on by default): fires when an `slopdesk watch`-wrapped command finishes.
- **Code Agent — Notify When Task Completes** (on by default): fires via IPC when a coding agent (Claude Code, Codex, OpenCode) finishes a task and goes idle. Does NOT require shell integration.
- **Code Agent — Notify When Awaiting Input** (on by default): fires via IPC when a coding agent needs approval or input. Does NOT require shell integration.
- **Title Report** (off by default, Settings → Advanced): allows apps to read the window title back via `OSC 21` / XTWINOPS. Default off because a program that can both set and read the title can exfiltrate data through a pane.
- **Title — Shell Controlled** (on by default, Settings → Advanced): allows apps to change the tab/window title via `OSC 0` / `OSC 2`.
- **Clipboard — Shell Controlled** (on by default, Settings → Advanced): master switch for `OSC 52` clipboard access.
- **Clipboard Read** (`ask` by default, Settings → Advanced): controls `OSC 52` read (program pasting from your clipboard). Values: `ask` / `allow` / `deny`. Default `ask` because clipboard read is the larger exfiltration risk.
- **Clipboard Write** (`allow` by default, Settings → Advanced): controls `OSC 52` write (program copying to your clipboard). Values: `ask` / `allow` / `deny`.
- **Auto Secure Input** (on by default, Settings → Controls): automatically enables macOS Secure Keyboard Entry when the active session enters canonical-no-echo mode (the classic `sudo` / `ssh` / `login` password-prompt signature), preventing other apps from reading keystrokes.
- **Secure Input Indicator** (on by default, Settings → Controls): shows a pill badge in the title bar while Secure Keyboard Entry is active. The pill reads "SECURE INPUT" in uppercase white text on a solid blue (#1565C0-ish) background, positioned at the far right of the title bar, with a lock icon to its left.
- **IPC Allow Send Keys** (off by default, Settings → Advanced): allows IPC clients to inject keystrokes into sessions.
- **IPC Allow Sensitive Sessions** (off by default, Settings → Advanced): allows IPC send-keys / capture to reach SSH / sudo sessions.
- Toggles also appear in the **Privileges menu** and **command palette**, not only in Settings.

## Keybindings

No dedicated keybindings are documented on this page. All controls are accessible via the Privileges menu and command palette.

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

A macOS system notification banner (standard Notification Center style, rendered by the OS). The banner is a rounded-rectangle card (~740×130 pt visible area) with a light grey background (approx #F2F2F2), large corner radius (~16 pt), subtle drop shadow on a neutral grey desktop background.

Layout (left to right):
- **App icon** (left-aligned, vertically centred): the slopdesk app icon — a dark near-black circle (~50×50 pt) containing a `>_` prompt glyph in white/light grey. Positioned with ~16 pt leading inset from the card edge.
- **Text block** (right of icon, ~16 pt gap): two lines of text, left-aligned, vertically centred.
  - Line 1 — **title**: "Deploy" — system-default semibold or bold weight, ~15–16 pt, near-black (~#111111).
  - Line 2 — **body**: "Production is live" — system-default regular weight, ~13–14 pt, mid-grey (~#555555).
- No action buttons, close button, or expand chevron visible in this state (banner-style, not alert-style).

The notification is entirely OS-rendered; the app supplies only the title string, body string, and app icon. No custom UI from slopdesk.

### notification-setting.png — Settings → Shell → Notification panel

A standard macOS preferences window (light mode). Window chrome: traffic-light buttons (red/yellow/grey, yellow and grey are inactive/dimmed) at top-left of the window.

**Left sidebar** (~300 pt wide, light grey #F5F5F5 background):
- Search bar at top (rounded, placeholder "Search", grey magnifier icon).
- Navigation rows with icon + label, each ~44 pt tall, no dividers:
  - General (info circle icon)
  - **Shell** (prompt `>_` icon) — currently SELECTED, shown with a solid mid-grey fill (#D0D0D0 approx) rounded-rectangle highlight spanning the full sidebar width.
  - Controls (pointer/cursor icon)
  - Editor (document icon)
  - Agents (plug/lightning bolt icon)
  - Appearance (palette icon)
  - Recipes (book icon)
  - Key Bindings (lightning bolt icon)
  - Advanced (wrench/spanner icon)

**Right content area** (white background, ~880 pt wide):

**Section header "NOTIFICATION"** — all-caps small-caps spaced label in medium grey (~#999999), ~11 pt, no divider line above it, ~24 pt top padding.

Toggle rows under NOTIFICATION (each row: label left, control right, subtitle below label in grey):

1. **Allow App Notifications** — toggle ON (green, iOS-style rounded pill ~51×31 pt). Subtitle: "Allow shell apps to send system notifications".
2. **Notify on Command Finish** — toggle OFF (grey/white, same pill shape). Subtitle: "Notify when a background command finishes".
3. **Notify on Error Exit** — toggle ON (green). Subtitle: "Notify when a command fails".
4. **Notify on Watch Finish** — toggle ON (green). Subtitle: "Notify when an `slopdesk watch`-wrapped command finishes".
5. **Notify While Foreground** — no toggle; instead a dropdown/segmented control on the right showing "Only when source tab is unfocused ∨" (with a downward chevron). Subtitle: "Banner behavior while slopdesk is the foreground app". The dropdown has a light rounded-rectangle border (~1 pt stroke, ~#CCCCCC), white fill, system-default font ~13 pt.
6. **Bounce Dock Icon** — toggle ON (green). Subtitle: "Bounce the Dock icon when a notification arrives and slopdesk isn't focused".

**Section header "TAB BADGE"** — same all-caps grey label style, ~24 pt top padding below last Notification row.

Row under TAB BADGE:
7. **When Command Finishes** — toggle ON (green). Subtitle: "Show accent dot on tab when a command finishes".

**Row anatomy** (consistent across all rows):
- Label: ~15 pt system font, semibold, near-black (#111111).
- Subtitle: ~13 pt system font, regular, mid-grey (#777777).
- Toggle: iOS-style green (#34C759) when on, grey when off; approx 51×31 pt pill.
- Rows are separated by subtle 1 pt hairline dividers in very light grey (~#EEEEEE), inset from the left edge by ~16 pt.
- Row height: ~64 pt (label + subtitle stack).

### secure-input.png — Secure Input title-bar pill

A terminal window in light mode. Window chrome: traffic-light buttons (red/yellow/green, all active) at top-left. Title bar centre shows the window/tab title "sudo ls" in regular grey text.

**Secure Input pill** — far-right of the title bar, ~8 pt from the right edge:
- Solid fill: medium-blue (#1565C0 or similar saturated blue, approximately #1A6ECC).
- Shape: rounded rectangle/pill, ~120×24 pt, corner radius ~6 pt.
- Content: a lock/shield icon (white, ~14 pt) on the left, then "SECURE INPUT" in white all-caps bold ~11 pt text.
- The pill sits flush with the title bar height (vertically centred), no drop shadow.

Terminal content area: white background, monospace font. Two lines of terminal output visible: `~ > sudo ls` (with green prompt triangle `▷` glyph and tilde in cyan/teal) and `Password:` with a block cursor (black rectangle).

The secure-input indicator is entirely within slopdesk's window frame — it is NOT a system-level overlay. The active (all-green) traffic-light buttons confirm the window is focused.

## Screenshots

- `notification.png` — macOS system notification banner showing OSC 777 "Deploy / Production is live" example
- `notification-setting.png` — Settings → Shell panel showing the NOTIFICATION and TAB BADGE sections
- `secure-input.png` — Terminal window showing the "SECURE INPUT" blue pill in the title bar during `sudo` password prompt

## Implementation notes

### Straightforward

- **OSC 9 / 777 / 99 → native macOS notifications**: On the macOS client, these can be forwarded from the remote host PTY stream via the existing terminal mux. The client intercepts OSC sequences in the rendered stream and posts `UNUserNotificationContent` directly. This is straightforward since slopdesk's client runs on macOS and has full UserNotifications access.
- **Bell (`BEL 0x07`) → `NSSound.beep()`**: Trivial in the macOS client. The client intercepts `0x07` from the terminal stream and calls `NSSound.beep()`.
- **Bounce Dock Icon**: `NSApplication.requestUserAttention(.informationalRequest)` on the macOS client. Same trigger point as notifications.
- **Notify While Foreground / tab-unfocused**: The client already knows which pane/tab is active, so the `tab-unfocused` filtering is local client logic.
- **Per-pane toggle defaults**: Already aligned with slopdesk's per-pane preference model (PreferencesStore is injected).
- **Secure Input Indicator pill**: Client-side title-bar badge; slopdesk already has a title bar and can insert a SwiftUI overlay or NSTextField pill. Blue pill, white "SECURE INPUT" all-caps + lock icon. Position: far-right of title bar.
- **Auto Secure Input** (canonical-no-echo detection): Requires detecting when the remote PTY enters canonical no-echo mode. The host PTY layer can observe termios `c_lflag & ECHO == 0 && c_lflag & ICANON != 0` and send a control message to the client; the client then calls `enableSecureEventInput()`. The host needs to signal this state over the control channel (a new control message type), and the client must call the macOS API — not blocked, but requires a new wire event.
- **Clipboard — Shell Controlled / Clipboard Read / Write** (`OSC 52`): The remote host may generate `OSC 52` sequences. Because the clipboard lives on the client side, the client intercepts `OSC 52` from the terminal stream and applies the read/write policy locally. `ask` mode requires a client-side permission dialog.
- **Title — Shell Controlled** (`OSC 0` / `OSC 2`): Client intercepts from the terminal stream and updates the tab/window title. Already common in terminal emulators and straightforward.
- **Title Report** (`OSC 21` / XTWINOPS): Client intercepts the query, optionally returns the current title string back into the PTY input stream. Disabled by default — same conservative default.

### Needs care / caveats

- **Code Agent notifications via IPC** (Claude Code / Codex / OpenCode): The agent runs on the **remote host** in slopdesk's architecture. The `ClaudeStatus` / `ClaudePaneDetector` / `AgentControlListener` infrastructure already exists in slopdesk (per memory note 2026-06-21). The IPC path must be tunnelled over the existing control channel (TCP control connection) from host to client — it requires the host agent-detector to forward state events over the wire, and the client to fire local macOS notifications based on those events. **Flag: agent IPC state must transit the control channel.**
- **System Permission status row** (green/amber dot + "Open System Settings" button): On macOS client this is straightforward — query `UNUserNotificationCenter.current().getNotificationSettings` and deep-link to the preference pane. On **iOS client**, the deep-link to System Settings uses `UIApplication.open(URL(string: UIApplication.openSettingsURLString)!)` which opens the app's own settings, NOT the system notifications pane. The Notification settings pane is not directly deep-linkable on iOS. **Flag: iOS cannot deep-link to the OS notification settings panel for a specific app.**
- **IPC Allow Send Keys / IPC Allow Sensitive Sessions**: "IPC" from the client side travels over the authenticated control channel. The security model is the trusted WireGuard mesh (per CLAUDE.md design), not a local-process IPC threat model. These toggles are implemented as host-side guards on the agent-control socket (`SLOPDESK_AGENT_CONTROL=1` path). **Flag: semantics differ from a local-IPC threat model; implement as host-side agent-control guards.**
- **Sound on Error Exit**: Requires shell integration (OSC 133 marks). SlopDesk supports OSC 133 already (per workspace-ui-multiplexer memory). The host detects non-zero exit via the mark, sends a control event, and the client plays the sound. Feasible but depends on shell integration being active on the remote host shell.
- **Notify on Finish / Notify on Error**: Same dependency on OSC 133 shell integration on the remote shell. The host must forward the exit-code event over the control channel.
- **`slopdesk watch` / Notify on Watch Finish**: `slopdesk watch` would be a host-side CLI wrapper command that emits the same watch-tagged finish event. Not yet implemented. **Flag: requires an slopdesk-side watch command.**
- **Configuration key names** (`privilege-*`, `notification-*`, `title-report`, `clipboard-read`, `clipboard-write`, `auto-secure-input`): SlopDesk uses `SLOPDESK_*` env vars and `PreferencesStore` / `SettingsKey` (`Defaults` product) rather than a config file. Map each toggle to a `SettingsKey` in `PreferencesStore`. No config-file parser needed (per slopdesk architecture).
- **Privileges menu** (separate macOS menu): SlopDesk does not currently have a Privileges menu. These toggles should appear in the command palette and settings panel; a dedicated menu item group under the app menu may be added but is not architecturally required.
