# Config File

## Summary

SlopDesk stores all settings in `~/.config/slopdesk/config.toml` — a lenient TOML file (flat `key = value` pairs, one per line, `#` comments). The Settings panel writes this same file, so panel edits and manual edits are always in sync. Editing the file directly is useful for version-control, cross-machine copying, commenting choices, or setting keys that only exist in the file and not in the GUI. The file is optional; SlopDesk runs on compiled defaults until it is created. Saving the file triggers an immediate hot-reload across every open window with no restart required.

---

## Behaviors

- **File location:** `~/.config/slopdesk/config.toml`. The file need not exist; SlopDesk runs on defaults until created.
- **Format:** TOML — flat `key = value` pairs, one assignment per line, `#` for comments.
- **Leniency:** Quotes around simple string values are optional. Unknown keys are silently ignored (typo-safe; newer configs load on older builds).
- **Whitespace:** Whitespace around `=` is optional.
- **Repeat keys for lists:** To add list entries (e.g. keybinds), repeat the same key on multiple lines. Example: `keybind = cmd+shift+t=new_tab` on successive lines.
- **Environment expansion:** `~` and `$VAR` expand inside string values. Example: `working-directory = ~/projects`.
- **Includes:** `include = <path>` pulls in another TOML file. Later includes win; the main file is read last. Useful for splitting config or sharing a base across machines.
- **Settings panel parity:** The Advanced tab's Config File section shows the exact path and an "Open Config File" button that opens the file in the system default editor, creating an empty file first if needed. All panel changes write through to this file.
- **Hot-reload:** SlopDesk watches the file with a file-system observer. Saving the file applies changes immediately to every open window — no restart, no SIGHUP.
- **Force reload:** After editing an `include`d file (which SlopDesk may not watch directly), use Settings → Advanced → Config File → Reload Config, or run the **Reload Config** command from the Command Palette.
- **Value types supported:** String (quoted or bare), Integer, Float, Boolean (`true`/`false` or `on`/`off`), Color (`#RRGGBB`, `#RRGGBBAA`, named), Enum (bare word), List (repeated keys).

---

## Keybindings

The `config-file` page itself defines no keybindings. The table below covers keybindings *related to accessing the config file* as described on this page.

| Action | Keys |
|---|---|
| Open Settings (to reach Config File section) | `⌘,` |
| Open Config File (GUI shortcut) | Settings → Advanced → Config File → Open Config File |
| Reload Config (GUI) | Settings → Advanced → Config File → Reload Config |
| Reload Config (Command Palette) | Open Command Palette → type "Reload Config" → Return |

---

## Config keys

The full configuration reference lives at `/reference/configuration`. Below is every key documented across the SlopDesk reference, with its default and effect.

### Font

| Key | Default | Effect |
|---|---|---|
| `font-family` | `JetBrains Mono` | Primary terminal font family |
| `font-family-fallback` | (none) | Extra fallback font families (repeatable) |
| `font-family-bold` | (none) | Override font family for bold cells |
| `font-family-italic` | (none) | Override font family for italic cells |
| `font-family-bold-italic` | (none) | Override font family for bold+italic cells |
| `font-family-fallback-bold` | (none) | Per-style fallback for bold |
| `font-family-fallback-italic` | (none) | Per-style fallback for italic |
| `font-family-fallback-bold-italic` | (none) | Per-style fallback for bold+italic |
| `font-size` | `13.0` | Font size in points |
| `font-blending` | `srgb-over` | Glyph alpha compositing method |
| `text-bold` | `auto` | How bold cells resolve (font weight vs color) |
| `text-italic` | `auto` | How italic cells resolve |
| `text-underline` | `true` | Render underline decoration |
| `text-blink` | `false` | Animate SGR-blink cells |
| `font-ligatures` | `dlig` | OpenType ligature level |
| `font-ligatures-alphabet` | `false` | Form ligatures inside letter runs |
| `font-thicken` | `false` | macOS stem darkening (subpixel thickening) |
| `arrow-box-drawing-join` | `true` | Align arrows to cell centerline |
| `adjust-cell-height` | (none) | Cell-height delta in pixels |
| `live-resize-sigwinch-delay-ms` | `50` | Grid stability delay after live-resize (ms) |

### Cursor

| Key | Default | Effect |
|---|---|---|
| `cursor-style` | `block` | Cursor shape (`block`, `bar`, `underline`) |
| `cursor-style-blink` | (app default) | Whether the cursor blinks |
| `cursor-color` | (from theme) | Cursor fill color |
| `cursor-text` | (from theme) | Text color rendered under cursor |
| `cursor-opacity` | `1.0` | Cursor opacity (0.0–1.0) |
| `cursor-animation` | `off` | Cursor motion animation style |

### Shell & Environment

| Key | Default | Effect |
|---|---|---|
| `command` | `$SHELL` (else `/bin/zsh`) | Shell or command to run in each pane |
| `env` | (none) | Set environment variables (repeatable: `env = KEY=VALUE`) |
| `term` | `auto` | Value of `$TERM` exported to the shell |
| `working-directory` | `inherit` | Initial working directory |
| `window-working-directory` | `home` | Working directory for new windows |
| `tab-working-directory` | `inherit` | Working directory for new tabs |
| `split-working-directory` | `inherit` | Working directory for new splits |
| `login-greeting` | `false` | Run shell as a login shell |

### Terminal Identity & VT

| Key | Default | Effect |
|---|---|---|
| `enquiry-response` | (empty) | Reply string for ENQ (^E) character |
| `osc-color-report-format` | `16-bit` | OSC 4/10/11 color-query response format |
| `title-report` | `false` | Allow window title queries via CSI |
| `vt-kam-allowed` | `true` | Allow keyboard action mode (KAM) |
| `vt-keypad-app-allowed` | `true` | Allow application keypad mode |
| `kitty-keyboard` | `true` | Support Kitty keyboard protocol |
| `widen-ambiguous` | (empty) | Unicode blocks to render at width 2 |

### Scrollback & Session Log

| Key | Default | Effect |
|---|---|---|
| `scrollback-lines` | `10000` | Maximum scrollback lines per pane |
| `scrollback-limit` | (none) | Byte-budget alternative (e.g. `32mb`) |
| `session-log-size-mb` | `5` | Max per-session log size in MB |
| `session-log-mode` | `redacted` | Session log capture method |
| `freeze-inactive-tab` | `false` | Release inactive tabs' GPU surfaces |

### Session Restore

| Key | Default | Effect |
|---|---|---|
| `session-restore-banner` | `true` | Show restore banners after crash/quit |
| `session-restore-multiplayer` | `true` | Reattach multiplexer sessions (tmux/screen) |
| `session-restore-processes` | `none` | Which commands to relaunch on restore |
| `session-restore-process-allowlist` | (none) | Command prefixes eligible for relaunch |

### Window

| Key | Default | Effect |
|---|---|---|
| `window-size` | `remember` | How initial window size is decided |
| `window-width-px` | `1000` | Initial window width in pixels |
| `window-height-px` | `600` | Initial window height in pixels |
| `window-cols` | `80` | Initial terminal columns |
| `window-rows` | `24` | Initial terminal rows |
| `window-layout` | `sidebar-left` | Tab placement mode |
| `auto-hide-tab-bar` | `default` | Auto-hide for inline tab bar |
| `auto-hide-tabs-panel` | `default` | Auto-hide for sidebar tabs panel |
| `sidebar-visible` | `true` | Show sidebar on startup |
| `sidebar-width` | `220` | Sidebar width in pixels |
| `details-panel-width` | `220` | Details panel width in pixels |

### Transparency

| Key | Default | Effect |
|---|---|---|
| `background-opacity` | `1.0` | Terminal background opacity (0.0–1.0) |
| `window-opacity` | `1.0` | Window-level opacity (0.0–1.0) |

### Terminal Colors

| Key | Default | Effect |
|---|---|---|
| `foreground` | `#d4d4d4` | Default text (foreground) color |
| `background` | `#1e1e1e` | Terminal background color |
| `palette-0` … `palette-15` | (Dracula-based) | ANSI 16-color palette entries |
| `palette` | (none) | Per-index color syntax (`palette = N=#RRGGBB`) |
| `bold-color` | `none` | Bold text color override |
| `faint-opacity` | `0.5` | Opacity for dim (SGR 2) text |
| `selection-foreground` | (none) | Text color inside selections |
| `selection-background` | (none) | Selection highlight background |
| `minimum-contrast` | `1.0` | Minimum fg/bg contrast ratio |

### Theme

| Key | Default | Effect |
|---|---|---|
| `theme` | `Paper` | Active theme name (light/default) |
| `theme-dark` | `Nord` | Theme used in dark (system) mode |
| `auto-theme-dark-mode` | `true` | Follow OS light/dark appearance |

Built-in themes: April, April Dark, Ayu Dark, Ayu Light, Catppuccin Mocha, Dracula, Floating Card, Glass Dark, Glass Light, Gruvbox Dark, Monokai Classic, Newsprint, Night, Nord, One Dark, One Light, Owl, Paper, Pink, Rosé Pine, Seafoam Pastel, Solarized Dark, Solarized Light, Tokyo Night.

### UI Chrome Colors

| Key | Default | Effect |
|---|---|---|
| `ui-panel-background` | (auto from theme) | Chrome frame background color |
| `ui-panel-surface` | (auto) | Surface/card background color |
| `ui-panel-border` | (auto) | Panel border color |
| `ui-border-subtle` | (auto) | Subtle/secondary border color |
| `ui-text-primary` | (auto) | Primary UI text color |
| `ui-text-secondary` | (auto) | Secondary UI text color |
| `ui-text-tertiary` | (auto) | Tertiary/muted UI text color |
| `ui-hover` | (auto) | Hover highlight color |
| `ui-active` | (auto) | Active/pressed highlight color |
| `ui-accent` | (auto) | Accent color |
| `ui-font-family` | (system) | Font family for UI chrome elements |
| `ui-font-size` | `13.0` | Font size for UI chrome (points) |

### Mouse & Input

| Key | Default | Effect |
|---|---|---|
| `mouse-reporting` | `true` | Forward mouse events to the terminal |
| `mouse-hide-while-typing` | `false` | Hide mouse cursor while typing |
| `mouse-scroll-multiplier` | `3.0` | Scroll speed multiplier |
| `focus-follows-mouse` | `false` | Focus the pane under the mouse pointer |
| `macos-option-as-alt` | `false` | Treat Option key as Alt (sends ESC prefix) |
| `shift-arrow-select` | `true` | Shift+Arrow extends selection |
| `mouse-shift-to-select` | `true` | Shift forces local selection even with mouse reporting |
| `cursor-click-to-move` | `true` | Click moves shell cursor via ANSI sequences |
| `right-click-action` | `context-menu` | What a right-click does |
| `scroll-to-bottom` | `keystroke,no-output` | Triggers that auto-scroll to bottom |

### Links & Open With

| Key | Default | Effect |
|---|---|---|
| `link-open-with` | `browser` | Where to open URLs (browser, etc.) |
| `file-open-with` | `default-app` | Where to open file paths |
| `folder-open-with` | `default-app` | Where to open folder paths |
| `link-schemes` | `all` | Which URL schemes are detected as links |
| `link-scheme-allowlist` | (none) | Extra schemes to detect as links |
| `link-previews` | `true` | Show URL preview pill on hover |
| `open-with-app` | (none) | Register external apps for Open With (repeatable) |
| `default-git-client` | (auto) | Preferred git GUI client |

### Clipboard & Selection

| Key | Default | Effect |
|---|---|---|
| `clipboard-read` | `ask` | OSC 52 clipboard read permission |
| `clipboard-write` | `allow` | OSC 52 clipboard write permission |
| `clipboard-trim-trailing-spaces` | `false` | Trim trailing spaces when copying |
| `copy-on-select` | `false` | Auto-copy text on selection |
| `clipboard-paste-protection` | `true` | Warn before pasting dangerous content |
| `clipboard-paste-bracketed-safe` | `true` | Sanitize bracketed-paste content |
| `selection-clear-on-typing` | `true` | Clear selection when typing resumes |
| `selection-clear-on-copy` | `false` | Clear selection after explicit copy |
| `selection-backspace-deletes` | `true` | Backspace deletes the current selection |

### Shell Integration & CLI

| Key | Default | Effect |
|---|---|---|
| `shell-integration` | `true` | Install managed shell-rc integration block |
| `ssh-integration` | `true` | Forward shell integration over SSH |
| `omit-slopdesk-prefix` | `false` | Install CLI functions without the `slopdesk` command prefix |
| `cli-allow-overwrite` | `false` | Allow replacing user-defined shell functions |
| `cli-alias` | (none) | User CLI aliases (repeatable) |
| `progress-bar-commands` | (built-in set) | Command prefixes that show progress bar |

### App Behavior

| Key | Default | Effect |
|---|---|---|
| `language` | `system` | UI language setting |
| `on-launch` | `restore_session` | What happens at app launch |
| `quit-after-last-window-closed` | `false` | Quit app when last window closes |
| `confirm-close-tab` | `process` | When to confirm closing a tab |
| `confirm-close-window` | `process` | When to confirm closing a window |
| `new-tab-position` | `auto` | Where new tabs open in the tab bar |

### Autocomplete

| Key | Default | Effect |
|---|---|---|
| `autocomplete-shortcut` | `tab` | Key accepting inline suggestions |
| `autocomplete-show-candidates` | `escape` | Key revealing candidate list |
| `autocomplete-inline-suggestion` | `true` | Show inline ghost-text preview |
| `autocomplete-on-device-learning` | `true` | Allow on-device learning from history |
| `autocomplete-history-ignore` | (none) | Glob patterns to exclude from history |
| `autocomplete-description-language` | `system` | Language for inline spec descriptions |

### Notifications, Sounds & Badges

| Key | Default | Effect |
|---|---|---|
| `notification-foreground` | `off` | Banner behavior when app is foreground |
| `privilege-sound-on-error` | `false` | Play sound on command exit error |
| `privilege-sound-shell` | `true` | Allow shell to trigger sounds |
| `privilege-notification-on-finish` | `false` | Notify on long-running command finish |
| `privilege-notification-on-error` | `true` | Notify on command error |
| `privilege-notification-on-watch-finish` | `true` | Notify on watch command finish |
| `privilege-notification-shell` | `true` | Allow shell to post notifications |
| `privilege-badge-exit-status` | `true` | Show exit-status badge on tab/dock |
| `privilege-badge-activity` | `true` | Show activity badge |
| `privilege-badge-agent-processing` | `true` | Badge while agent is processing |
| `privilege-badge-agent-task-complete` | `true` | Badge when agent task completes |
| `privilege-badge-agent-awaiting-input` | `true` | Badge when agent is awaiting input |
| `privilege-notify-agent-task-complete` | `true` | Notify when agent task completes |
| `privilege-notify-agent-awaiting-input` | `true` | Notify when agent is awaiting input |
| `privilege-caffeinate-agent-processing` | `false` | Keep Mac awake while agent processes |
| `privilege-resume-agent-session` | `true` | Offer to resume interrupted agent sessions |
| `privilege-mouse-shell` | `true` | Allow shell to control mouse reporting |
| `privilege-title-shell` | `true` | Allow shell to set window title |
| `privilege-clipboard-shell` | `true` | Allow shell to drive clipboard via OSC 52 |

### Auto Approve & IPC Security

| Key | Default | Effect |
|---|---|---|
| `show-auto-approve` | `false` | Surface Auto Approve feature in UI |
| `auto-approve-enabled` | `false` | Enable Auto Approve for agent tool calls |
| `hide-auto-approve-pill` | `false` | Hide the Auto Approve toolbar pill |
| `ipc-allow-send-keys` | `false` | Allow send-keys IPC command |
| `ipc-allow-sensitive-sessions` | `false` | Allow IPC on SSH/sudo sessions |

### Secure Input (macOS)

| Key | Default | Effect |
|---|---|---|
| `auto-secure-input` | `true` | Auto-enable secure input at password prompts |
| `secure-input-indication` | `true` | Show active secure-input indicator pill |

### Quick Terminal

| Key | Default | Effect |
|---|---|---|
| `quick-terminal-persist-session` | `false` | Keep session alive between quick-terminal toggles |
| `quick-terminal-cwd` | `current-pane` | Working directory for quick terminal |

### Recipes

| Key | Default | Effect |
|---|---|---|
| `recipe-replay-saved` | `ask_once` | Command replay behavior for saved recipes |
| `recipe-replay-file` | `manually` | Command replay behavior for `.slopdeskrecipe` files |

### Open Quickly, Frecency & Jump

| Key | Default | Effect |
|---|---|---|
| `open-quickly-folders-limit` | `12` | Max frecency-ranked folders shown |
| `frecency-auto-record` | `true` | Record every CWD change automatically |
| `zoxide-enabled` | `true` | Sync folder removals to zoxide |
| `zoxide-local-path` | (auto) | Explicit path to zoxide binary |

### Editor (File Pane)

| Key | Default | Effect |
|---|---|---|
| `editor-line-wrap` | `true` | Soft-wrap long lines in file pane |
| `editor-tab-size` | `4` | Visual width of tab character in file pane |
| `editor-visible-whitespace` | `false` | Render whitespace characters as visible glyphs |
| `editor-show-line-numbers` | `true` | Show line-number gutter |
| `editor-default-to-preview-readonly` | `true` | Open file previews read-only |
| `editor-scroll-past-end` | `true` | Allow scrolling past the last line |

### Terminal Scrolling

| Key | Default | Effect |
|---|---|---|
| `terminal-scroll-past-end` | `disabled` | Allow scrolling past last output line |
| `terminal-scroll-past-first-line` | `disabled` | Allow scrolling past first output line |
| `terminal-scroll-past-end-sticky` | `false` | Keep scroll-past-end offset sticky |
| `terminal-scroll-smooth` | `true` | Pixel-granular (smooth) scrolling |

### Dock Icon (macOS)

| Key | Default | Effect |
|---|---|---|
| `dock-icon-animate-progress` | `false` | Animate dock icon during progress |
| `dock-icon-error-badge` | `true` | Show red tint on dock icon on exit error |

### Keybindings

| Key | Default | Effect |
|---|---|---|
| `keybind` | (built-in set) | Bind a key chord to an action. Repeatable — one `keybind = chord=action` per line. |

---

## Visual spec

### Site Icon (`otty-icon.png`)

The reference app icon (`otty-icon.png`) is a dark, near-black circular disk (charcoal, approximately `#3a3a3c`) on a white/light-grey rounded-square background (macOS-style app icon shape). On the dark disk, three white glyphs form a terminal prompt motif: `>_` at upper-left and `*` at upper-right, with a short horizontal dash (`-`) below them, centered. The rendering is clean, flat, and high-contrast. Typography is monospace-style, stroke weight is medium-bold. The icon conveys a terminal with an agent/automation asterisk.

The **config-file** page itself contains no screenshots — it is a purely textual reference/how-to page. The only image present is the reference icon described above.

---

## Screenshots

- `otty-icon.png` — Reference app icon (dark disk with `>_*` terminal motif on white macOS rounded-square background)

---

## Client/host implementation notes

### Architecture context
SlopDesk is a remote coding tool: a Swift macOS host runs `slopdesk-hostd` (PTY, screen capture, video encode/FEC), and macOS/iOS clients render the remote terminal via libghostty behind a `TerminalSurface` seam. This config file is the CLIENT-SIDE UX layer; because slopdesk splits a session across a client and a host, some keys resolve entirely on the client while others must round-trip to the host.

### Straightforward client-side keys

| Key / behavior | Implementation seam |
|---|---|
| `font-family`, `font-size`, `font-*` | Pass through to `TerminalConfigBuilder` / libghostty config before surface creation |
| `background-opacity` | Rendered locally in `TerminalRenderingView`; no remote involvement |
| `theme` / `theme-dark` / `auto-theme-dark-mode` | `ThemeStore` drives `MonokaiSeed` selection |
| `cursor-style`, `cursor-color`, `cursor-opacity` | libghostty cursor config passed at session init |
| `scrollback-lines` | libghostty scrollback config |
| `window-layout`, `sidebar-visible`, `sidebar-width` | `WorkspaceStore` sidebar tokens |
| `keybind` | `WorkspaceBindingRegistry` — client-side key dispatch |
| `autocomplete-*` | Client-side inline suggestion UI |
| `clipboard-*` | Client-side clipboard handling via OSC 52 |
| `ui-*` colors | Theme token overrides / `ThemeStore` |
| Config hot-reload | `PreferencesStore` + `Defaults`, plus a file-watcher on `~/.config/slopdesk/config.toml` |
| `include = <path>` | Config parser |
| `$VAR` and `~` expansion | String-value parser |

### Keys that resolve on the HOST, not the client

| Key / behavior | Why it's host-side |
|---|---|
| `working-directory` | CWD is the HOST's filesystem, not the client's. `working-directory = ~/projects` is resolved on the host and communicated at session open via the wire protocol. The value lives in client config but applies on the host. |
| `tab-working-directory` / `split-working-directory` | Same HOST-side resolution. On new tab/split, the CWD is inherited from the host-side PTY, not the client's local filesystem. |
| `window-working-directory` | `home` default means the HOST's home directory. |
| `command` | The command runs on the HOST (in `slopdesk-hostd`). Client config stores a preferred command sent over the wire at session-open, but cannot enforce it after launch. |
| `env` | Environment variables apply on the HOST side in the PTY. Client stores them and sends them at session open. |
| `ssh-integration` | SlopDesk IS the transport — this is "integration forwarding" over the slopdesk mux channel, not a secondary SSH hop. |
| `session-restore-*` | Session restore uses `DetachedSessionStore` (`SLOPDESK_DETACH_ENABLED`), aligned with the host-side detach mechanism rather than a purely client-side session log. |
| `shell-integration` | Shell integration RC block must be injected on the HOST shell (not client). Host manages this; client config controls whether to request it at session open. |

### Platform-specific or deferred keys

| Key / behavior | Constraint |
|---|---|
| `quick-terminal-*` (Quick Terminal) | A system-wide dropdown terminal (like Visor). SlopDesk's client is a full windowed app; there is no OS-level overlay mechanism to implement this without a separate helper app or Accessibility API. Deferred. |
| `dock-icon-*` | Dock icon badges and animations are macOS-only and client-local. Implementable on the macOS client (`SlopDeskClientUI`) but not on iOS. |
| `auto-secure-input` / `secure-input-indication` | Secure input (IOHIDSetSecureInput) applies to the CLIENT's event stream. Since slopdesk injects input events via the host, "secure input" on the client does not protect the host shell from interception — the semantics differ fundamentally from a local terminal. N/A for remote sessions. |
| `freeze-inactive-tab` | For a local terminal this would release a local GPU Metal surface. In slopdesk the video decode surface is always "remote" — inactive panes can suspend the video stream (already possible via the FEC/packetizer path) but libghostty surface management differs. Needs host-side stream-pause integration. |
| `link-open-with`, `file-open-with`, `folder-open-with` | Paths detected in terminal output are HOST filesystem paths. Opening them requires routing the open-request back through the wire to the host, then having the host open the file in its local app — not a pure client operation. |
| `progress-bar-commands` | Progress detection requires parsing shell output; since the shell runs on the host, OSC 133 (already tracked by slopdesk's `Blocks/OSC-133` integration) is the correct seam for progress signaling. |
| `window-opacity` (window-level blur/transparency) | macOS vibrancy/window translucency is client-local and feasible on macOS. On iOS, background blur behind the terminal view requires a different API. Platform-specific. |
| `notification-foreground`, `privilege-*` (notifications) | Notifications are delivered to the CLIENT device. For iOS remote clients, notifications require APNS push tokens — not just local `UNUserNotificationCenter`. iOS-specific complexity. |
| `ipc-allow-send-keys` / `ipc-allow-sensitive-sessions` | For a local terminal, IPC refers to a local Unix-socket IPC between processes on the same Mac. In slopdesk, the equivalent is the host-side agent-control socket (`SLOPDESK_AGENT_CONTROL=1`, AF_UNIX NDJSON). The client config key guards client exposure; maps to `AgentControlListener` access policy on the host. |
| Config file format — `include` | Not yet implemented in the config stack; on the parser backlog. |

### Implementation order

1. **Config file path:** `~/.config/slopdesk/config.toml`.
2. **Parser:** TOML, lenient, `~`/`$VAR` expansion, `include` support, silent unknown-key handling.
3. **Hot-reload:** File-system watcher posting to `PreferencesStore` / `Defaults`.
4. **Key groups by priority:** Font → Theme → Cursor → Scrollback → Keybinds → Clipboard → UI chrome.
5. **Settings panel bridge:** Advanced tab showing path + "Open Config File" + "Reload Config".
6. **Host-side keys** (`working-directory`, `command`, `env`, `shell-integration`): send at session open via the slopdesk wire protocol session-init message.
