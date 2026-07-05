# Copy and Paste

> Section: terminal-features | Slug: copy-and-paste

## Summary

How slopdesk moves text between the terminal and the system clipboard, plus the paste safety net. Configured entirely in the GUI — no config file. Core actions: ⌘C (copy), ⌘V (paste), ⌘X (cut). Bracketed paste is automatic. A paste-protection dialog warns before risky pastes. "Paste as…" offers clipboard transforms. Programs access the clipboard via OSC 52 with per-direction (read/write) permissions.

## Behaviors

### Copy

- Select text (see Selection page), then copy via ⌘C, Edit ▸ Copy, or the right-click menu.
- **Copy on Select** (off by default): every selection drops straight into the clipboard — no ⌘C needed.
- **Clipboard Trim Trailing Spaces** (off by default): strips trailing spaces from each copied line at copy time.
- **Clear Selection on Copy** (off by default): drops the highlight after an explicit ⌘C (not on Copy on Select). See Selection page.
- Cut (copy + delete) is ⌘X — see Input.

### Paste

- Paste via ⌘V, Edit ▸ Paste, or the right-click menu.
- **Bracketed paste** is automatic: programs that advertise support (shell line editors, editors, REPLs) receive pasted text as a single inert block; newlines are NOT interpreted as Enter.
- A plain right-click can be configured to paste (or copy) directly instead of opening the context menu — see Right Click Action in Cursor and Mouse.

### Paste Protection

- **On by default** (Settings → Controls).
- Shows a confirmation dialog previewing the clipboard content and flags these dangers:
  - **Multi-line text** — earlier lines execute the moment they paste (newline = Enter in a shell).
  - **Trailing newline** — the command runs on paste, before the user can review it.
  - **`sudo` / `su`** — the paste may run with elevated privileges.
  - **Control characters** — possible terminal-escape injection hidden in the text.
- User chooses **Paste Anyway** or **Cancel**.
- **Skipped** inside full-screen TUIs (vim, less, etc.) — those receive the paste inertly.
- Also **skipped** when **Paste Bracketed Safe** (on by default) is enabled AND the program advertised bracketed-paste support — the paste is sent as an inert block anyway, so the danger doesn't apply.

### Paste as…

Via **Edit ▸ Paste as**. Each variant transforms the clipboard before it reaches the shell:

| Variant | What it sends |
|---|---|
| Paste Selection | Pastes the current text selection instead of the clipboard (the X11 middle-click convention). |
| Paste File Base64-Encoded… | Base64-encodes a chosen file to ferry binary content over a plain text session. |
| Paste Escaping Special Characters | Shell-escapes text so spaces/special chars land as literals — ideal for a pasted file path. |
| Bracketed Paste | Forces bracketed-paste markers even if the program didn't ask. |
| Paste and continue in Composer | Appends the clipboard to the Composer draft instead of sending it to the prompt. |

### Clipboard Access from Programs (OSC 52)

- Programs read/write the system clipboard via the **OSC 52** escape sequence (tmux, vim with a clipboard plugin, SSH sessions).
- Controlled per-direction under **Settings → Advanced → All Settings**. Each direction: **Allow**, **Ask** (prompt every time), or **Deny**.
- **Clipboard Write** defaults to **Allow** — a program copying TO your clipboard.
- **Clipboard Read** defaults to **Ask** — a program reading FROM your clipboard; Ask because silent remote clipboard reads are the riskier direction.

## Keybindings

| Action | Keys |
|---|---|
| Copy selection | ⌘C |
| Cut (copy + delete) | ⌘X |
| Paste clipboard | ⌘V |
| Copy (menu) | Edit ▸ Copy |
| Paste (menu) | Edit ▸ Paste |
| Paste as… (submenu) | Edit ▸ Paste as |
| Copy (right-click) | Right-click menu |
| Paste (right-click) | Right-click menu (or bare right-click if Right Click Action is set) |

## Config Keys

All settings are GUI-only (Settings app); no config file keys for this page.

| Key / Setting Name | Default | Effect |
|---|---|---|
| Copy on Select | Off | Every selection goes straight to clipboard; no ⌘C required. |
| Clipboard Trim Trailing Spaces | Off | Strip trailing spaces from each copied line at copy time. |
| Clear Selection on Copy | Off | Drop the highlight after an explicit ⌘C. Not applied when Copy on Select fires. |
| Paste Protection | On | Confirmation dialog before pasting dangerous content (multi-line, trailing newline, sudo/su, control characters). |
| Paste Bracketed Safe | On | Skip the paste-protection dialog when the receiving program advertised bracketed-paste support (safe: paste received inertly). |
| Clipboard Write (OSC 52) | Allow | Program copying TO the system clipboard. Options: Allow / Ask / Deny. |
| Clipboard Read (OSC 52) | Ask | Program reading FROM the system clipboard. Options: Allow / Ask / Deny. |

**Setting locations:**
- Copy on Select, Clipboard Trim Trailing Spaces, Clear Selection on Copy, Paste Protection, Paste Bracketed Safe → **Settings → Controls**
- Clipboard Write, Clipboard Read → **Settings → Advanced → All Settings**

## Visual Spec

No content screenshots — the page is prose + tables only.

## Screenshots

*(No content screenshots on this page.)*

## Implementation Notes

### Straightforward

- **⌘C / ⌘V / ⌘X keybindings** — standard macOS; wire through to the NSView / libghostty surface as-is. libghostty already handles copy/paste events via its `ghostty_app_action` / key binding layer.
- **Bracketed paste** — libghostty handles DEC `?2004h`/`?2004l` tracking and injects `\e[200~…\e[201~` wrapping automatically. No extra work.
- **Copy on Select** — a `SelectionStore` observer: when the selection range becomes non-empty, write to `NSPasteboard.general`. Toggle in Preferences.
- **Clipboard Trim Trailing Spaces** — in the copy action: split on `\n`, `trimmingCharacters(.whitespaces)` each line, rejoin.
- **Clear Selection on Copy** — after explicit ⌘C, call `surface.clearSelection()` if this pref is on.
- **Paste Protection dialog** — SwiftUI sheet / `NSAlert` shown before forwarding the paste string to libghostty. Inspect for: `\n` count > 1, trailing `\n`, `/sudo /` or `/su /` tokens, ASCII control codes (bytes < 0x20 excluding `\t\n\r`). Skip when the surface is in full-screen TUI mode (via OSC 133 / shell integration state or the `?2004h` advertised flag) OR when Paste Bracketed Safe is on and `?2004h` is active.
- **Paste as… variants** — all client-side transforms before calling the paste action:
  - *Paste Selection*: read `surface.selectedText` (X11 primary-selection) instead of `NSPasteboard.general`.
  - *Paste File Base64-Encoded…*: `NSOpenPanel`, base64-encode the file bytes, inject.
  - *Paste Escaping Special Characters*: `shlex`-style escaping in Swift.
  - *Bracketed Paste*: force-wrap with `\e[200~…\e[201~` regardless of program state.
  - *Paste and continue in Composer*: append to the local Composer text buffer instead of the PTY.

### Requires special handling

- **OSC 52 Clipboard Write/Read over a remote session**: the PTY runs on the macOS HOST but the clipboard lives on the CLIENT. OSC 52 sequences from a remote program (e.g. vim over SSH in the hosted terminal) reach HOST-side libghostty. The host must forward OSC 52 write payloads over the slopdesk wire to the CLIENT's `NSPasteboard.general`; read requests must be forwarded to the client, which returns clipboard content over the wire for injection into the PTY. Non-trivial wire extension — define a new `ClipboardWrite` / `ClipboardRead` control-channel message pair. The Ask/Allow/Deny gate must live on the CLIENT (where the user sits), not the host.
- **Right Click Action (paste-on-right-click)**: the right-click context menu is a CLIENT-side `NSMenu`. Bare-right-click-to-paste is a client gesture-recogniser change (`TerminalSurface` / `TerminalRendererFactory` view), not a host change. No wire needed.
- **Paste as… → Paste and continue in Composer**: the Composer is a CLIENT-side UI element (`WorkspaceStore` / Composer pane). Pure client state — no wire.
- **Full-screen TUI detection for paste-protection skip**: libghostty tracks the alternate screen (`?1049h`), a reliable proxy for "full-screen TUI active." Read this from the libghostty surface config before deciding to show the dialog.
- **iOS client**: the clipboard API is `UIPasteboard.general`. OSC 52 forwarding needs the same wire extension as macOS. The right-click menu becomes a long-press context menu; the Paste as… submenu maps to a share/action sheet.
