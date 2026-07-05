# Config File Format

## Summary

This page documents the syntax of `~/.config/slopdesk/config.toml` — the TOML-based flat config format used by SlopDesk. It is a pure syntax/format reference, not a key inventory; the key inventory lives in the Configuration Reference page. The format is deliberately simple: a flat list of `key = value` pairs with lenient parsing, hot reload, environment expansion, and include directives.

## Behaviors

- **File location**: `~/.config/slopdesk/config.toml`
- **Format**: TOML — a flat list of `key = value` pairs, one per line, with `#` for comments
- **Lenient reader**: SlopDesk's parser is lenient — quotes around simple string values are optional
- **Unknown keys are silently ignored**: typos won't error; a config written for a newer SlopDesk build stays loadable on an older one
- **One assignment per line**: multiple assignments on one line are not supported
- **Whitespace around `=` is optional**: `key=value` and `key = value` are both valid
- **Blank lines and `#` comments are skipped**
- **String quoting**: follows TOML string quoting rules; use quotes when a value contains spaces, commas, or other special characters (e.g. `font-feature = "+liga, +calt"`)
- **Includes**: use `include = <path>` to split config across multiple files; later includes override earlier ones; the main file is read last and overrides everything
- **Environment expansion**: `~` and `$VAR` expand inside string values (e.g. `working-directory = ~/projects`, `shell-command = $HOMEBREW_PREFIX/bin/fish`)
- **Hot reload**: saving `config.toml` reapplies changes immediately to every open window — no restart, no signal required
- **List values**: expressed as repeated keys on separate lines (e.g. multiple `keybind = ...` lines, multiple `include = ...` lines)
- **Colors**: accepted as `#RRGGBB`, `#RRGGBBAA` (with alpha), or CSS named colors (`red`, `cornflowerblue`)
- **Booleans**: `true` / `false` or `on` / `off`
- **Enums**: bare unquoted identifiers matching documented values (e.g. `block`, `glass-dark`)
- **Most keys are also editable from Settings**: the in-app Settings UI writes the same file

## Keybindings

No keybindings are specific to the config-file-format page. Keybindings are configured via the `keybind` key in the config file itself — see the Keybindings Reference for triggers and action names.

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

The config-file-format page documents syntax, not individual keys. The full key inventory is in the Configuration Reference. Below is the complete documented key set from that reference, organized by section.

### Font

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `JetBrains Mono` | Primary terminal font. Accepts a string or inline array `["A", "B"]` where the rest are fallbacks tried in order. |
| `font-family-fallback` | (none) | Extra fallback families tried in order before the OS system cascade. Comma-separated. |
| `font-family-bold` | (none) | Override family for bold cells. Empty = reuse `font-family` and synthesize. |
| `font-family-italic` | (none) | Override family for italic cells. |
| `font-family-bold-italic` | (none) | Override family for bold+italic cells. |
| `font-family-fallback-bold` | (none) | Per-style fallback chain for bold cells. |
| `font-family-fallback-italic` | (none) | Per-style fallback chain for italic cells. |
| `font-family-fallback-bold-italic` | (none) | Per-style fallback chain for bold+italic cells. |
| `font-size` | `13.0` | Font size in points. |
| `font-blending` | `srgb-over` | Glyph alpha compositing. Values: `srgb-over` (classic gamma-encoded), `macos-like` (OS-native non-linear, Ghostty's native), `linear` (physically correct linear-light), `perceptual` (boosts alpha for thin strokes). Aliases: `font-smooth`, `font-antialiased`. |
| `text-bold` | `auto` | How bold cells resolve when no bold face exists. Values: `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-bold`. |
| `text-italic` | `auto` | How italic cells resolve when no italic face exists. Values: `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-italic`. |
| `text-underline` | `true` | Render SGR-underline cells' underline decoration. Alias: `font-underline`. |
| `text-blink` | `false` | Animate SGR-blink (SGR 5/6) cells. Off renders them steady (accessibility). Alias: `font-blink`. |
| `font-ligatures` | `dlig` | OpenType ligature level. Values: `off` (disables programming ligatures), `calt` (standard/contextual set), `dlig` (also enables discretionary ligatures). Alias: `ligatures`. |
| `font-ligatures-alphabet` | `false` | Also form ligatures inside runs of letters/digits/CJK. Off keeps fi/fl-style letter ligatures from collapsing cells. |
| `font-thicken` | `false` | macOS only. Force GUI-style stem darkening regardless of `font-blending`. Auto-enabled when `background-opacity < 1.0`. Mirrors Ghostty's `font-thicken`. |
| `arrow-box-drawing-join` | `true` | Render arrows ← → ↑ ↓ and solid triangles ◀ ▶ ▲ ▼ aligned to the cell centerline when adjacent to a connecting rule. Standalone glyphs in prose/TUIs are unaffected. |
| `adjust-cell-height` | (none) | Ghostty-compatible cell-height delta. `Npx` / bare `N` add logical points; `N%` scales by `1 + N/100`. Negative compacts; glyphs stay vertically centered. |
| `live-resize-sigwinch-delay-ms` | `50` | Milliseconds the grid must stay stable during a live drag before a single mid-drag SIGWINCH fires. `0` disables the mid-drag signal (drag-end still fires one). |

### Cursor

| Key | Default | Effect |
|-----|---------|--------|
| `cursor-style` | `block` | Cursor shape. Values: `block`, `bar`, `underline`, `block_hollow` (also `block-hollow`). |
| `cursor-style-blink` | (app default) | Whether the cursor blinks. Unset follows the application's request. |
| `cursor-color` | (theme) | Cursor fill color. |
| `cursor-text` | (theme) | Text color under the cursor. |
| `cursor-opacity` | `1.0` | Cursor opacity (0.0–1.0). |
| `cursor-animation` | `off` | Cursor motion animation. Values: `off`, `smooth`. |

### Shell & Environment

| Key | Default | Effect |
|-----|---------|--------|
| `command` | `$SHELL` (else `/bin/zsh`) | Shell/command to run. Alias: `shell`. |
| `env` | (none) | Set an environment variable. Repeatable (one `env` line each). Format: `KEY=VALUE`. |
| `term` | `auto` | Value of `$TERM`. `auto` picks the best-supported value for SlopDesk. |
| `working-directory` | `inherit` | Initial directory. Values: `inherit`, `home`, or an absolute path (`~/` allowed). |
| `window-working-directory` | `home` | Directory for a brand-new window's first pane. |
| `tab-working-directory` | `inherit` | Directory for a new tab (inherits the active pane's CWD). |
| `split-working-directory` | `inherit` | Directory for a new split. |

### Terminal Identity & VT

| Key | Default | Effect |
|-----|---------|--------|
| `enquiry-response` | (empty) | Reply string for the ENQ (0x05) control character. |
| `osc-color-report-format` | `16-bit` | OSC 4/10/11 color-query response format. Values: `none`, `8-bit`, `16-bit`. |
| `title-report` | `false` | Allow apps to query the window title (XTWINOPS). Off by default (security). |
| `vt-kam-allowed` | `true` | Allow the KAM (keyboard action mode) escape sequence. |
| `vt-keypad-app-allowed` | `true` | Allow application keypad mode (DECKPAM, ESC =). When off, the keypad always sends literal digits. |
| `kitty-keyboard` | `true` | Support the Kitty keyboard protocol (disambiguated/extended key reporting). |
| `widen-ambiguous` | (empty) | Unicode blocks whose East-Asian-Ambiguous codepoints render width-2. Values: `enclosed-alphanumerics`, `number-forms`, `math-operators`, `misc-technical`, `misc-symbols`, `dingbats`, `arrows`, `geometric-shapes`. |
| `login-greeting` | `false` | Run the login shell as a login shell so the system greeting/MOTD prints. |

### Scrollback & Session Log

| Key | Default | Effect |
|-----|---------|--------|
| `scrollback-lines` | `10000` | Maximum scrollback lines retained per pane. |
| `scrollback-limit` | (none) | Alternative byte-budget form (divided by 80 to derive lines). Mirrors Ghostty. |
| `session-log-size-mb` | `5` | Max per-session log size (MB) used for recover & the scrollback pager. |
| `session-log-mode` | `redacted` | Session log capture. Values: `plain` (raw output), `redacted` (masks detected secrets with equal-width asterisks). |
| `freeze-inactive-tab` | `false` | Release inactive tabs' GPU surfaces to save memory; recreate on switch. Off keeps tab switches smooth. |

### Session Restore

| Key | Default | Effect |
|-----|---------|--------|
| `session-restore-banner` | `true` | Show "Closed at" / "Restored at" banners on restore. |
| `session-restore-multiplayer` | `true` | Reattach multiplexer sessions (currently tmux) on restore. |
| `session-restore-processes` | `none` | Which still-running pane commands to relaunch. Values: `none`, `whitelist`, `all`. |
| `session-restore-process-allowlist` | (none) | Command prefixes eligible for relaunch when `session-restore-processes = whitelist`. Matched as whitespace-delimited prefixes. |

### Window

| Key | Default | Effect |
|-----|---------|--------|
| `window-size` | `remember` | How initial window size is decided. Values: `remember` (restores last size), `frame` (pixel dimensions), `grid` (cell counts). |
| `window-width-px` | `1000` | Initial window width in pixels (`frame` mode). |
| `window-height-px` | `600` | Initial window height in pixels (`frame` mode). |
| `window-cols` | `80` | Initial columns (`grid` mode). |
| `window-rows` | `24` | Initial rows (`grid` mode). |

### Transparency

Applied at window creation; editing the value requires reopening the window.

| Key | Default | Effect |
|-----|---------|--------|
| `background-opacity` | `1.0` | Terminal background opacity (0.5–1.0). Values below 0.5 are rejected for readability. |
| `window-opacity` | `1.0` | Window-level opacity (0.5–1.0). |

### Terminal Colors

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | `#d4d4d4` | Default text color (when no theme is set). |
| `background` | `#1e1e1e` | Terminal background color (when no theme is set). |
| `palette-0` .. `palette-15` | (Dracula-based) | ANSI palette. 0–7 normal, 8–15 bright. |
| `palette` | (none) | Alternative per-index syntax: `palette = 1=#ff5555`. |
| `bold-color` | `none` | Bold text color. Values: `none`, `bright` (use bright palette variant), or `#rrggbb` hex. |
| `faint-opacity` | `0.5` | Opacity multiplier for faint/dim text (0.0–1.0). |
| `selection-foreground` | (none) | Text color in selections. Unset keeps the fg↔bg swap default; `auto` keeps each cell's original foreground. |
| `selection-background` | (none) | Selection background. Accepts 8-digit `#rrggbbaa` for a translucent selection. Unset uses the default foreground. |
| `minimum-contrast` | `1.0` | Minimum fg/bg contrast ratio (1.0–21.0). `1.0` disables adjustment. |

Fallback palette (Dracula-based, active when no theme is set):

| Index | Color | Name | Index | Color | Name |
|-------|-------|------|-------|-------|------|
| 0 | `#282a36` | Black | 8 | `#6272a4` | Bright Black |
| 1 | `#ff5555` | Red | 9 | `#ff6e6e` | Bright Red |
| 2 | `#50fa7b` | Green | 10 | `#69ff94` | Bright Green |
| 3 | `#f1fa8c` | Yellow | 11 | `#ffffa5` | Bright Yellow |
| 4 | `#bd93f9` | Blue | 12 | `#d6acff` | Bright Blue |
| 5 | `#ff79c6` | Magenta | 13 | `#ff92df` | Bright Magenta |
| 6 | `#8be9fd` | Cyan | 14 | `#a4ffff` | Bright Cyan |
| 7 | `#f8f8f2` | White | 15 | `#ffffff` | Bright White |

### Theme

| Key | Default | Effect |
|-----|---------|--------|
| `theme` | `Paper` | Active theme (light slot). Overrides `foreground`, `background`, and `palette`. |
| `theme-dark` | `Nord` | Theme used when the OS is in dark mode and `auto-theme-dark-mode` is on. |
| `auto-theme-dark-mode` | `true` | Follow the OS appearance: `theme` for light, `theme-dark` for dark. |

Built-in themes (case-insensitive): April, Ayu Dark, Ayu Light, Catppuccin Mocha, Dracula, Floating Card, Glass Dark, Glass Light, Gruvbox Dark, Monokai Classic, Newsprint, Night, Nord, One Dark, One Light, Owl, Paper, Pastel, Pink, Rosé Pine, Seafoam, Solarized Dark, Solarized Light, Tokyo Night.

### UI Chrome Colors

All optional; auto-derived from terminal foreground/background when unset.

| Key | Default | Effect |
|-----|---------|--------|
| `ui-panel-background` | (auto) | Chrome frame behind the terminal grid. |
| `ui-panel-surface` | (auto) | Surface/card background. |
| `ui-panel-border` | (auto) | Panel border. Accepts 8-digit `#rrggbbaa` for translucent border. |
| `ui-border-subtle` | (auto) | Subtle/secondary border. |
| `ui-text-primary` | (auto) | Primary UI text. |
| `ui-text-secondary` | (auto) | Secondary UI text. |
| `ui-text-tertiary` | (auto) | Tertiary/muted UI text. |
| `ui-hover` | (auto) | Hover highlight. |
| `ui-active` | (auto) | Active/pressed highlight. |
| `ui-accent` | (auto) | Accent color (defaults to blue). |

### UI Font

| Key | Default | Effect |
|-----|---------|--------|
| `ui-font-family` | (system) | Font family for UI chrome text. |
| `ui-font-size` | `13.0` | Font size for UI chrome text in points. |

### Mouse & Input

| Key | Default | Effect |
|-----|---------|--------|
| `mouse-reporting` | `true` | Forward mouse events to the terminal application. |
| `mouse-hide-while-typing` | `false` | Hide the mouse cursor while typing. |
| `mouse-scroll-multiplier` | `3.0` | Scroll speed. Single number sets both; compound form `discrete:3.0,precision:1.0`. |
| `focus-follows-mouse` | `false` | Focus the pane under the mouse without clicking. |
| `macos-option-as-alt` | `false` | Treat Option as Alt. Values: `true`, `false`, `left`, `right`. |
| `shift-arrow-select` | `true` | Enable Shift+Arrow text selection. |
| `mouse-shift-to-select` | `true` | Holding Shift always does local selection even when the app has mouse reporting on. |
| `cursor-click-to-move` | `true` | Click on the active prompt line emits arrow keys to move the shell cursor to the click target. |
| `right-click-action` | `context-menu` | What right-click does. Values: `context-menu`, `copy`, `paste`, `copy-or-paste`, `ignore`. |
| `scroll-to-bottom` | `keystroke,no-output` | When to auto-scroll to bottom. Comma-separated: `keystroke`/`no-keystroke`, `output`/`no-output`. |

### Links & Open With

| Key | Default | Effect |
|-----|---------|--------|
| `link-open-with` | `browser` | Where to open a clicked URL. Values: `browser`, `slopdesk`. |
| `file-open-with` | `default-app` | Where to open a clicked file path. Values: `default-app`, `slopdesk`. |
| `folder-open-with` | `default-app` | Where to open a clicked folder path. Values: `default-app`, `slopdesk`. |
| `link-schemes` | `all` | Which extra URL schemes are auto-detected. Values: `all` (any `scheme://`), `custom` (only the allowlist). http(s)/file/mailto always detected. |
| `link-scheme-allowlist` | (none) | Extra schemes to detect when `link-schemes = custom`. Bare names, no `://`. |
| `link-previews` | `true` | Show the corner pill with the hovered link's full URL on Cmd-hover. |
| `open-with-app` | (none) | Add an external app to "Open in" submenus. Repeatable. Settings-managed. |
| `default-git-client` | (auto) | Bundle ID of the preferred git GUI client for "Open in <App>". Empty = first installed. |

### Clipboard & Selection

| Key | Default | Effect |
|-----|---------|--------|
| `clipboard-read` | `ask` | OSC 52 clipboard read access. Values: `ask`, `allow`, `deny`. |
| `clipboard-write` | `allow` | OSC 52 clipboard write access. Values: `ask`, `allow`, `deny`. |
| `clipboard-trim-trailing-spaces` | `false` | Trim trailing whitespace when copying. |
| `copy-on-select` | `false` | Automatically copy on selection. |
| `clipboard-paste-protection` | `true` | Warn before pasting potentially dangerous content. |
| `clipboard-paste-bracketed-safe` | `true` | Sanitize bracketed-paste sequences inside pasted content. |
| `selection-clear-on-typing` | `true` | Clear the active selection when typing. |
| `selection-clear-on-copy` | `false` | Clear the selection after an explicit copy (does not apply to `copy-on-select`). |
| `selection-backspace-deletes` | `true` | Backspace deletes a selection on the prompt line instead of one character at the cursor. |

### Sidebar & Layout

| Key | Default | Effect |
|-----|---------|--------|
| `window-layout` | `sidebar-left` | Tab placement. Values: `sidebar-left`, `tabs-top`, `tabs-bottom`. |
| `auto-hide-tab-bar` | `default` | Auto-hide policy for the inline tab bar (`tabs-top`/`tabs-bottom`). Values: `always`, `default`, `auto`. Alias: `window-show-tab-bar`. |
| `auto-hide-tabs-panel` | `default` | Auto-hide policy for the sidebar tabs panel (`sidebar-left`). Same values. |
| `sidebar-visible` | `true` | Show the sidebar on startup. |
| `sidebar-width` | `220` | Sidebar width in pixels. |
| `details-panel-width` | `220` | Details panel width in pixels. |

### Shell Integration & CLI

| Key | Default | Effect |
|-----|---------|--------|
| `shell-integration` | `true` | Install the managed shell-rc block (OSC 133 marks, CWD reporting, edit/view/jump wrappers, custom aliases). |
| `ssh-integration` | `true` | Forward SlopDesk's shell integration over SSH to remote hosts. |
| `omit-slopdesk-prefix` | `false` | Install edit/view/watch shell functions so the `slopdesk` prefix can be dropped. Live-toggleable. |
| `cli-allow-overwrite` | `false` | Let omit-prefix/custom-alias wrappers replace names the user already defined. |
| `cli-alias` | (none) | User CLI alias: installs a shell function `<name>` running `slopdesk <command>`. Repeatable. Settings-managed. |
| `progress-bar-commands` | (built-in set) | Command prefixes the shell integration auto-emits OSC 9;4 progress for (curl, git push, npm install, …). Matched as whitespace-delimited prefixes. |

### App Behavior

| Key | Default | Effect |
|-----|---------|--------|
| `language` | `system` | UI language. Values: `system`, `english`, `chinese`. |
| `on-launch` | `restore_session` | What happens at launch. Values: `new_window`, `restore_session`. |
| `quit-after-last-window-closed` | `false` | Quit SlopDesk when the last window closes. |
| `confirm-close-tab` | `process` | Confirm closing a tab. Values: `always`, `process` (only with a running process). |
| `confirm-close-window` | `process` | Confirm closing a window. Values: `always`, `process`, `multiple_tabs`. |
| `new-tab-position` | `auto` | Where a new tab opens. Values: `end`, `auto`, `after-current`. |

### Autocomplete

| Key | Default | Effect |
|-----|---------|--------|
| `autocomplete-shortcut` | `tab` | Key that accepts a suggestion. Values: `tab`, `tab+right-arrow`, `ctrl+space`, `disable`. |
| `autocomplete-show-candidates` | `escape` | Key that reveals the candidate panel. Values: `disable`, `auto`, `escape`, `option-escape`. |
| `autocomplete-inline-suggestion` | `true` | Show a faded inline preview when there's a single suggestion. |
| `autocomplete-on-device-learning` | `true` | Allow on-device learning (history, --help probes, README extraction). Privacy gate; everything stays local. |
| `autocomplete-history-ignore` | (none) | Glob patterns for commands never recorded (e.g. `ssh *`, `export *TOKEN*`). |
| `autocomplete-description-language` | `system` | Language for spec descriptions. Values: `system`, `english`, `chinese`. |

### Notifications, Sounds & Badges

Defaults for new panes. Most are per-pane overridable at runtime.

| Key | Default | Effect |
|-----|---------|--------|
| `notification-foreground` | `off` | Banner behavior while SlopDesk is foreground. Values: `off`, `always`, `tab-unfocused`. |
| `privilege-sound-on-error` | `false` | Play a sound on a non-zero command exit. |
| `privilege-sound-shell` | `true` | Let shell-integration commands trigger sounds. |
| `privilege-notification-on-finish` | `false` | Notify when a long command finishes. |
| `privilege-notification-on-error` | `true` | Notify when a command errors. |
| `privilege-notification-on-watch-finish` | `true` | Notify when a watched command finishes. |
| `privilege-notification-shell` | `true` | Let shell-integration commands post notifications. |
| `privilege-badge-exit-status` | `true` | Show an exit-status badge on the tab. |
| `privilege-badge-activity` | `true` | Show an activity badge for background output. |
| `privilege-badge-agent-processing` | `true` | Badge while an agent is processing. |
| `privilege-badge-agent-task-complete` | `true` | Badge when an agent finishes a task. |
| `privilege-badge-agent-awaiting-input` | `true` | Badge when an agent awaits input. |
| `privilege-notify-agent-task-complete` | `true` | System notification when an agent finishes a task. |
| `privilege-notify-agent-awaiting-input` | `true` | System notification when an agent awaits approval/input. |
| `privilege-caffeinate-agent-processing` | `false` | Keep the Mac awake while an agent is processing. |
| `privilege-resume-agent-session` | `true` | Offer to resume agent sessions on restore. |
| `privilege-mouse-shell` | `true` | Let the shell control mouse reporting. |
| `privilege-title-shell` | `true` | Let the shell set the window/tab title. |
| `privilege-clipboard-shell` | `true` | Let the shell drive clipboard (OSC 52) operations. |

### Auto Approve & IPC Security

| Key | Default | Effect |
|-----|---------|--------|
| `show-auto-approve` | `false` | Surface the (deprecated) Auto Approve feature in the UI. |
| `auto-approve-enabled` | `false` | Enable Auto Approve. |
| `hide-auto-approve-pill` | `false` | Hide the Auto Approve toolbar pill. |
| `ipc-allow-send-keys` | `false` | Allow the send-keys IPC command. |
| `ipc-allow-sensitive-sessions` | `false` | Allow send-keys/capture on SSH/sudo sessions. |

### Secure Input (macOS)

| Key | Default | Effect |
|-----|---------|--------|
| `auto-secure-input` | `true` | Auto-enable macOS Secure Keyboard Entry at password-style prompts. |
| `secure-input-indication` | `true` | Show the title-bar pill while Secure Keyboard Entry is active. |

### Quick Terminal

| Key | Default | Effect |
|-----|---------|--------|
| `quick-terminal-persist-session` | `false` | Keep the quick-terminal session alive between toggles. |
| `quick-terminal-cwd` | `current-pane` | Working directory for the quick terminal. Values: `last-used`, `current-pane`. |

### Recipes

| Key | Default | Effect |
|-----|---------|--------|
| `recipe-replay-saved` | `ask_once` | Command replay for internally-saved recipes. Values: `auto`, `ask_once`, `manually`. |
| `recipe-replay-file` | `manually` | Command replay for external `.slopdeskrecipe` files. Same values. |

### Open Quickly, Frecency & Jump

| Key | Default | Effect |
|-----|---------|--------|
| `open-quickly-folders-limit` | `12` | Max frecency-ranked folders surfaced in Open Quickly. Alias: `open-quickly-zoxide-limit`. |
| `frecency-auto-record` | `true` | Record every CWD change into the frecency table (powers the Folders tab and `slopdesk jump`). |
| `zoxide-enabled` | `true` | Sync removals to the external zoxide binary when present. |
| `zoxide-local-path` | (auto) | Explicit path to the zoxide binary. Empty = auto-detect. Settings-hidden. |

### Editor (File Pane)

Apply to SlopDesk's non-terminal text surfaces (file panes, previews).

| Key | Default | Effect |
|-----|---------|--------|
| `editor-line-wrap` | `true` | Soft-wrap long lines instead of horizontal scrolling. |
| `editor-tab-size` | `4` | Visual width of a tab character, in columns. |
| `editor-visible-whitespace` | `false` | Render whitespace as glyphs. |
| `editor-show-line-numbers` | `true` | Show the line-number gutter. |
| `editor-default-to-preview-readonly` | `true` | Open preview-capable formats (.md, .svg, .html…) in read-only preview mode. |
| `editor-scroll-past-end` | `true` | Allow scrolling past the last line (VS Code's `scrollBeyondLastLine`). |

### Terminal Scrolling

| Key | Default | Effect |
|-----|---------|--------|
| `terminal-scroll-past-end` | `disabled` | Scroll past the last line in the terminal. Values: `disabled`, `last-line-with-content`, `last-line-in-middle`, `cursor-line`. Always off on the alternate screen. |
| `terminal-scroll-past-first-line` | `disabled` | Scroll past the first scrollback line. Values: `disabled`, `same-as-last-line`, `first-line-with-content`, `first-line-in-middle`. |
| `terminal-scroll-past-end-sticky` | `false` | Keep the past-end offset sticky instead of draining it as new output arrives. |
| `terminal-scroll-smooth` | `true` | Pixel-granular scrollback navigation; snaps to the nearest row on idle. |

### Dock Icon (macOS)

| Key | Default | Effect |
|-----|---------|--------|
| `dock-icon-animate-progress` | `false` | Animate the Dock icon while any session emits OSC 9;4 progress. |
| `dock-icon-error-badge` | `true` | Tint the Dock icon red on a non-zero exit / OSC 9;4;2 error; clicking focuses the next error tab. |

### Keybindings

| Key | Default | Effect |
|-----|---------|--------|
| `keybind` | (built-in) | Bind a key chord to an action. Repeatable. See Keybindings Reference for triggers and action names. |

## Visual spec

### No content-specific screenshots on this page

The config-file-format page is a pure text documentation page (VitePress-based site). It contains no content screenshots — only the site logo appears as the sole image.

**App icon (otty-icon.png)**

A rounded-square macOS-style app icon approximately 128×128 (displayed smaller in the nav). Background: near-black dark charcoal circle (`~#3a3c42`) on a very light warm grey square background (`~#f0eeec`) with a large corner radius. Inside the circle: two white glyph elements — a `>_` prompt symbol on the left and a `*` asterisk on the right, both in a bold sans/monospace style with a `-` hyphen/dash below the `>_`. The overall aesthetic is minimal, dark, terminal-themed with a hint of personality (the `*` and `-` evoke a smiley face). Corner radius of the outer square is approximately 22% of width.

**Doc site chrome visual standard (inferred from page structure)**

The docs site uses VitePress v1.6.4. Layout: fixed sidebar navigation on the left (~260px), main content area in the center with comfortable line-width (~740px max), and an on-page TOC on the right. Background is white in light mode. The content area uses a clean sans-serif body font (Inter) for prose and a monospace font for code snippets. Code blocks have a light grey background with syntax highlighting. Tables use subtle row borders. Navigation items are flat text links with hover states. The page footer reads "Copyright © 2026-present SlopDesk".

## Screenshots

- `otty-icon.png` — app icon (navigation logo only; no content screenshots on this page)

## Implementation notes

### Straightforward

- **`font-*` / `text-*` keys**: All of these pass through to libghostty's `TerminalConfigBuilder`. SlopDesk's `TerminalConfigBuilder` override pattern (used for Monokai Pro theme adoption) is exactly the right seam. Map `font-family`, `font-size`, `font-ligatures`, `cursor-style`, `cursor-style-blink`, `cursor-color`, `cursor-text`, `cursor-opacity`, `text-bold`, `text-italic`, `text-underline`, `text-blink`, `font-blending`, `font-thicken`, `arrow-box-drawing-join`, `adjust-cell-height` directly.

- **`scrollback-lines`**: Maps to the libghostty scrollback config. SlopDesk's `ReplayBuffer` (64 MiB ceiling) is a separate concern for reconnect replay; the two can coexist independently.

- **`foreground` / `background` / `palette-*` / `bold-color` / `selection-*`**: All libghostty terminal color config. Direct map via `TerminalConfigBuilder`.

- **`theme` / `theme-dark` / `auto-theme-dark-mode`**: SlopDesk already has `ThemeStore` + Monokai Pro multi-seed factory. Map `theme` to the `ThemeStore` active theme selection; `auto-theme-dark-mode` maps to OS appearance observation already in `ThemeStore` (posts on `id` not `isLight`). The built-in theme list (Paper, Nord, Dracula, etc.) would need to be implemented or mapped to existing SlopDesk themes.

- **`ui-panel-*` / `ui-text-*` / `ui-hover` / `ui-active` / `ui-accent`**: Maps to SlopDesk's `SlateDesign` token system. These are the exact tokens already in the design system. Auto-derivation from terminal fg/bg is what SlopDesk's `ThemeStore` already computes via `resolveTerminalColors`.

- **`cursor-style` / `cursor-style-blink`**: Direct libghostty passthrough.

- **`macos-option-as-alt`**: libghostty config; direct map.

- **`window-layout`**: Maps to SlopDesk's `WorkspaceStore` `window-layout` concept. `sidebar-left` = current SlopDesk default with sidebar. `tabs-top`/`tabs-bottom` would require a layout mode switch in the pane multiplexer.

- **`sidebar-visible` / `sidebar-width` / `details-panel-width`**: Maps to `WorkspaceStore` sidebar toggle and `NSSplitView` divider position. The sidebar toggle behavior already exists (b83ef78 commit).

- **`keybind`**: Maps to SlopDesk's `WorkspaceBindingRegistry`. The trigger+action format is already the design direction.

- **`session-restore-*`**: Maps to SlopDesk's `DetachedSessionStore` + `SLOPDESK_DETACH_ENABLED`. `session-restore-multiplayer` (tmux reattach) aligns well.

- **`shell-integration`**: OSC 133 marks and CWD reporting are already in SlopDesk via shell integration. Direct map.

- **`privilege-badge-*` / `privilege-notify-*`**: Tab badges and notifications already exist in SlopDesk (agent processing/task-complete/awaiting-input badges — see `privilege-badge-agent-*` keys). Direct map.

- **Hot reload**: SlopDesk uses `Defaults`/`PreferencesStore` injection. A file-watcher on `~/.config/slopdesk/config.toml` that re-applies settings would replicate this. This is achievable with `DispatchSource.makeFileSystemObjectSource`.

- **Include directives**: Pure file-merging at parse time. No slopdesk-specific complications.

### Constraints from the remote-host architecture

- **`working-directory` / `tab-working-directory` / `split-working-directory`**: These depend on reading the **host-side** CWD from the remote process. In SlopDesk's remote architecture, the CWD is only known on the host via OSC 7 / shell integration CWD reports. The client config can express a *preference* (e.g. `inherit`, `home`, `~/projects`), but resolution must happen on the host side where the PTY is spawned. The host must read these keys and apply them at session/pane creation time.

- **`window-working-directory`**: Same as above — this is a host-side path that must be resolved on the macOS host. A remote client cannot directly set a host-side directory to an iOS-local path.

- **`command` (shell command)**: The host-side shell command. SlopDesk's host daemon already sets the shell from `$SHELL`; this key could be forwarded as a host config preference but cannot be a client-local override.

- **`env` (environment variables)**: Must be applied on the host when spawning the PTY, not on the client. Config needs to be transmitted to the host's session manager.

- **`background-opacity` / `window-opacity`**: On macOS client, `background-opacity` maps to libghostty's background alpha (already gated at the `TerminalConfigBuilder` seam). On iOS, window-level opacity has no equivalent (UIKit has no window compositor API). `background-opacity` is still achievable on iOS via the terminal view's background color alpha.

- **`font-thicken`**: macOS-only (GUI-style stem darkening via Core Text). Not applicable on iOS. Gate with `#if os(macOS)`.

- **`auto-secure-input` / `secure-input-indication`**: macOS Secure Keyboard Entry is a macOS-only API (`CGSSetSecureInputMode`). Not applicable to the iOS client. On macOS slopdesk client, the `SLOPDESK_SYSTEM_DIALOG_PANES` feature already handles secure input scenarios.

- **`dock-icon-animate-progress` / `dock-icon-error-badge`**: macOS-only (NSDockTile API). iOS has no dock icon. Gate with `#if os(macOS)`.

- **`quick-terminal-persist-session` / `quick-terminal-cwd`**: Quick Terminal is a system-wide hotkey drop-down terminal (similar to Quake-style terminals). SlopDesk does not have this concept currently; it would need a new system-wide hotkey handler and separate window type.

- **`frecency-auto-record` / `zoxide-enabled` / `zoxide-local-path` / `open-quickly-folders-limit`**: The frecency/zoxide system tracks host-side directories. CWD tracking in SlopDesk is already done via OSC 7 shell integration reports. Frecency persistence would live on the host. The iOS client cannot run a local zoxide binary.

- **`ssh-integration`**: SlopDesk IS already a remote terminal; SSH-forwarding shell integration is a different concept from SlopDesk's native remote protocol. This key would only be relevant if users run `ssh` from within an SlopDesk pane.

- **`link-open-with = slopdesk`**: Opening a URL in SlopDesk's own built-in browser pane. SlopDesk has a `web-browser` pane type (`web-broswer.png` screenshot already captured). This is possible but requires the `WebPane` or equivalent to be wired up.

- **`file-open-with = slopdesk` / `folder-open-with = slopdesk`**: Opening files/folders in SlopDesk's own editor/file pane. SlopDesk has `editor-pane`, `file-panel`, `folder-pane` concepts (screenshots show these pane types). Achievable but requires pane-type routing logic.

- **`ipc-allow-send-keys` / `ipc-allow-sensitive-sessions`**: SlopDesk has its own IPC model via AF_UNIX NDJSON + `slopdesk-ctl`. The `ipc-allow-send-keys` concept maps to `SLOPDESK_AGENT_CONTROL`'s send-keys capability.

- **`language`**: UI language switching (system/english/chinese). SlopDesk currently has no localization infrastructure; this would require adding `NSLocalizedString` / SwiftUI `LocalizedStringKey` support across the chrome.

- **`freeze-inactive-tab`**: GPU surface management for inactive tabs. SlopDesk already keeps all tabs mounted at `opacity(0)` to avoid tearing down the libghostty surface — `freeze-inactive-tab = false` (default) is already the effective behavior. `freeze-inactive-tab = true` would require implementing GPU surface teardown/recreate on tab switch, which is a significant libghostty lifecycle change.

- **`session-log-mode = redacted`**: Secret masking in the session log. SlopDesk's `ReplayBuffer` stores raw bytes with no redaction. Implementing secret detection + masking would be a new capability.

- **`autocomplete-*`**: SlopDesk does not currently implement shell autocomplete. This is a significant feature gap relative to the design spec. The `autocomplete-on-device-learning` privacy gate (everything stays local) is a design constraint to respect when implementing.

- **`recipes`**: The recipe system (`.slopdeskrecipe` files, command replay). SlopDesk has no implementation yet; this would be a new feature area.
