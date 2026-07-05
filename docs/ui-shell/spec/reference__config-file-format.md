# Config File Format

## Summary

Syntax of `~/.config/slopdesk/config.toml` — the TOML-based flat config format used by SlopDesk. Syntax/format reference only; the key inventory lives in the Configuration Reference page. Format: a flat list of `key = value` pairs with lenient parsing, hot reload, environment expansion, and include directives.

## Behaviors

- **File location**: `~/.config/slopdesk/config.toml`
- **Format**: TOML — a flat list of `key = value` pairs, one per line, `#` for comments
- **Lenient reader**: quotes around simple string values are optional
- **Unknown keys silently ignored**: typos won't error; a config for a newer build stays loadable on an older one
- **One assignment per line**; multiple per line unsupported
- **Whitespace around `=` optional**: `key=value` and `key = value` both valid
- **Blank lines and `#` comments skipped**
- **String quoting**: TOML rules; quote values with spaces, commas, or special characters (e.g. `font-feature = "+liga, +calt"`)
- **Includes**: `include = <path>` splits config across files; later includes override earlier ones; the main file is read last and overrides everything
- **Environment expansion**: `~` and `$VAR` expand inside string values (e.g. `working-directory = ~/projects`, `shell-command = $HOMEBREW_PREFIX/bin/fish`)
- **Hot reload**: saving `config.toml` reapplies to every open window immediately — no restart, no signal
- **List values**: repeated keys on separate lines (e.g. multiple `keybind = ...`, multiple `include = ...`)
- **Colors**: `#RRGGBB`, `#RRGGBBAA` (alpha), or CSS named colors (`red`, `cornflowerblue`)
- **Booleans**: `true`/`false` or `on`/`off`
- **Enums**: bare unquoted identifiers matching documented values (e.g. `block`, `glass-dark`)
- **Most keys editable from Settings**: the in-app Settings UI writes the same file

## Keybindings

No keybindings are specific to this page. Keybindings are configured via the `keybind` key — see the Keybindings Reference for triggers and action names.

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

This page documents syntax, not individual keys; the full inventory is in the Configuration Reference. The complete documented key set from that reference, by section:

### Font

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `JetBrains Mono` | Primary terminal font. String or inline array `["A", "B"]` (rest are fallbacks tried in order). |
| `font-family-fallback` | (none) | Extra fallback families tried before the OS system cascade. Comma-separated. |
| `font-family-bold` | (none) | Override family for bold cells. Empty = reuse `font-family` and synthesize. |
| `font-family-italic` | (none) | Override family for italic cells. |
| `font-family-bold-italic` | (none) | Override family for bold+italic cells. |
| `font-family-fallback-bold` | (none) | Per-style fallback chain for bold cells. |
| `font-family-fallback-italic` | (none) | Per-style fallback chain for italic cells. |
| `font-family-fallback-bold-italic` | (none) | Per-style fallback chain for bold+italic cells. |
| `font-size` | `13.0` | Font size in points. |
| `font-blending` | `srgb-over` | Glyph alpha compositing. `srgb-over` (classic gamma-encoded), `macos-like` (OS-native non-linear, Ghostty's native), `linear` (physically correct linear-light), `perceptual` (boosts alpha for thin strokes). Aliases: `font-smooth`, `font-antialiased`. |
| `text-bold` | `auto` | Bold-cell resolution when no bold face exists. `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-bold`. |
| `text-italic` | `auto` | Italic-cell resolution when no italic face exists. `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-italic`. |
| `text-underline` | `true` | Render SGR-underline decoration. Alias: `font-underline`. |
| `text-blink` | `false` | Animate SGR-blink (SGR 5/6) cells. Off renders steady (accessibility). Alias: `font-blink`. |
| `font-ligatures` | `dlig` | OpenType ligature level. `off` (disables programming ligatures), `calt` (standard/contextual), `dlig` (also discretionary). Alias: `ligatures`. |
| `font-ligatures-alphabet` | `false` | Also form ligatures inside runs of letters/digits/CJK. Off keeps fi/fl-style letter ligatures from collapsing cells. |
| `font-thicken` | `false` | macOS only. Force GUI-style stem darkening regardless of `font-blending`. Auto-enabled when `background-opacity < 1.0`. Mirrors Ghostty's `font-thicken`. |
| `arrow-box-drawing-join` | `true` | Render arrows ← → ↑ ↓ and triangles ◀ ▶ ▲ ▼ aligned to the cell centerline when adjacent to a connecting rule. Standalone glyphs in prose/TUIs unaffected. |
| `adjust-cell-height` | (none) | Ghostty-compatible cell-height delta. `Npx`/bare `N` add logical points; `N%` scales by `1 + N/100`. Negative compacts; glyphs stay vertically centered. |
| `live-resize-sigwinch-delay-ms` | `50` | Ms the grid must stay stable during a live drag before one mid-drag SIGWINCH fires. `0` disables the mid-drag signal (drag-end still fires one). |

### Cursor

| Key | Default | Effect |
|-----|---------|--------|
| `cursor-style` | `block` | Cursor shape. `block`, `bar`, `underline`, `block_hollow` (also `block-hollow`). |
| `cursor-style-blink` | (app default) | Whether the cursor blinks. Unset follows the app's request. |
| `cursor-color` | (theme) | Cursor fill color. |
| `cursor-text` | (theme) | Text color under the cursor. |
| `cursor-opacity` | `1.0` | Cursor opacity (0.0–1.0). |
| `cursor-animation` | `off` | Cursor motion. `off`, `smooth`. |

### Shell & Environment

| Key | Default | Effect |
|-----|---------|--------|
| `command` | `$SHELL` (else `/bin/zsh`) | Shell/command to run. Alias: `shell`. |
| `env` | (none) | Set an env var. Repeatable (one `env` line each). Format: `KEY=VALUE`. |
| `term` | `auto` | Value of `$TERM`. `auto` picks the best-supported value for SlopDesk. |
| `working-directory` | `inherit` | Initial directory. `inherit`, `home`, or an absolute path (`~/` allowed). |
| `window-working-directory` | `home` | Directory for a brand-new window's first pane. |
| `tab-working-directory` | `inherit` | Directory for a new tab (inherits the active pane's CWD). |
| `split-working-directory` | `inherit` | Directory for a new split. |

### Terminal Identity & VT

| Key | Default | Effect |
|-----|---------|--------|
| `enquiry-response` | (empty) | Reply string for the ENQ (0x05) control character. |
| `osc-color-report-format` | `16-bit` | OSC 4/10/11 color-query response format. `none`, `8-bit`, `16-bit`. |
| `title-report` | `false` | Allow apps to query the window title (XTWINOPS). Off by default (security). |
| `vt-kam-allowed` | `true` | Allow the KAM (keyboard action mode) escape sequence. |
| `vt-keypad-app-allowed` | `true` | Allow application keypad mode (DECKPAM, ESC =). Off = keypad always sends literal digits. |
| `kitty-keyboard` | `true` | Support the Kitty keyboard protocol (disambiguated/extended key reporting). |
| `widen-ambiguous` | (empty) | Unicode blocks whose East-Asian-Ambiguous codepoints render width-2. `enclosed-alphanumerics`, `number-forms`, `math-operators`, `misc-technical`, `misc-symbols`, `dingbats`, `arrows`, `geometric-shapes`. |
| `login-greeting` | `false` | Run the login shell as a login shell so the system greeting/MOTD prints. |

### Scrollback & Session Log

| Key | Default | Effect |
|-----|---------|--------|
| `scrollback-lines` | `10000` | Max scrollback lines retained per pane. |
| `scrollback-limit` | (none) | Alternative byte-budget form (÷80 to derive lines). Mirrors Ghostty. |
| `session-log-size-mb` | `5` | Max per-session log size (MB) for recover & the scrollback pager. |
| `session-log-mode` | `redacted` | Session log capture. `plain` (raw), `redacted` (masks detected secrets with equal-width asterisks). |
| `freeze-inactive-tab` | `false` | Release inactive tabs' GPU surfaces to save memory; recreate on switch. Off keeps switches smooth. |

### Session Restore

| Key | Default | Effect |
|-----|---------|--------|
| `session-restore-banner` | `true` | Show "Closed at" / "Restored at" banners on restore. |
| `session-restore-multiplayer` | `true` | Reattach multiplexer sessions (currently tmux) on restore. |
| `session-restore-processes` | `none` | Which still-running pane commands to relaunch. `none`, `whitelist`, `all`. |
| `session-restore-process-allowlist` | (none) | Command prefixes eligible for relaunch when `session-restore-processes = whitelist`. Matched as whitespace-delimited prefixes. |

### Window

| Key | Default | Effect |
|-----|---------|--------|
| `window-size` | `remember` | How initial size is decided. `remember` (restores last), `frame` (pixel dims), `grid` (cell counts). |
| `window-width-px` | `1000` | Initial width in pixels (`frame` mode). |
| `window-height-px` | `600` | Initial height in pixels (`frame` mode). |
| `window-cols` | `80` | Initial columns (`grid` mode). |
| `window-rows` | `24` | Initial rows (`grid` mode). |

### Transparency

Applied at window creation; editing the value requires reopening the window.

| Key | Default | Effect |
|-----|---------|--------|
| `background-opacity` | `1.0` | Terminal background opacity (0.5–1.0). Below 0.5 rejected for readability. |
| `window-opacity` | `1.0` | Window-level opacity (0.5–1.0). |

### Terminal Colors

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | `#d4d4d4` | Default text color (when no theme is set). |
| `background` | `#1e1e1e` | Terminal background color (when no theme is set). |
| `palette-0` .. `palette-15` | (Dracula-based) | ANSI palette. 0–7 normal, 8–15 bright. |
| `palette` | (none) | Alternative per-index syntax: `palette = 1=#ff5555`. |
| `bold-color` | `none` | Bold text color. `none`, `bright` (use bright palette variant), or `#rrggbb`. |
| `faint-opacity` | `0.5` | Opacity multiplier for faint/dim text (0.0–1.0). |
| `selection-foreground` | (none) | Text color in selections. Unset keeps the fg↔bg swap default; `auto` keeps each cell's original foreground. |
| `selection-background` | (none) | Selection background. 8-digit `#rrggbbaa` for a translucent selection. Unset uses the default foreground. |
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
| `theme` | `Paper` | Active theme (light slot). Overrides `foreground`, `background`, `palette`. |
| `theme-dark` | `Nord` | Theme used in OS dark mode when `auto-theme-dark-mode` is on. |
| `auto-theme-dark-mode` | `true` | Follow OS appearance: `theme` for light, `theme-dark` for dark. |

Built-in themes (case-insensitive): April, Ayu Dark, Ayu Light, Catppuccin Mocha, Dracula, Floating Card, Glass Dark, Glass Light, Gruvbox Dark, Monokai Classic, Newsprint, Night, Nord, One Dark, One Light, Owl, Paper, Pastel, Pink, Rosé Pine, Seafoam, Solarized Dark, Solarized Light, Tokyo Night.

### UI Chrome Colors

All optional; auto-derived from terminal foreground/background when unset.

| Key | Default | Effect |
|-----|---------|--------|
| `ui-panel-background` | (auto) | Chrome frame behind the terminal grid. |
| `ui-panel-surface` | (auto) | Surface/card background. |
| `ui-panel-border` | (auto) | Panel border. 8-digit `#rrggbbaa` for translucent border. |
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
| `macos-option-as-alt` | `false` | Treat Option as Alt. `true`, `false`, `left`, `right`. |
| `shift-arrow-select` | `true` | Enable Shift+Arrow text selection. |
| `mouse-shift-to-select` | `true` | Holding Shift always does local selection even when the app has mouse reporting on. |
| `cursor-click-to-move` | `true` | Click on the active prompt line emits arrow keys to move the shell cursor to the click target. |
| `right-click-action` | `context-menu` | Right-click action. `context-menu`, `copy`, `paste`, `copy-or-paste`, `ignore`. |
| `scroll-to-bottom` | `keystroke,no-output` | When to auto-scroll to bottom. Comma-separated: `keystroke`/`no-keystroke`, `output`/`no-output`. |

### Links & Open With

| Key | Default | Effect |
|-----|---------|--------|
| `link-open-with` | `browser` | Where to open a clicked URL. `browser`, `slopdesk`. |
| `file-open-with` | `default-app` | Where to open a clicked file path. `default-app`, `slopdesk`. |
| `folder-open-with` | `default-app` | Where to open a clicked folder path. `default-app`, `slopdesk`. |
| `link-schemes` | `all` | Which extra URL schemes are auto-detected. `all` (any `scheme://`), `custom` (only the allowlist). http(s)/file/mailto always detected. |
| `link-scheme-allowlist` | (none) | Extra schemes to detect when `link-schemes = custom`. Bare names, no `://`. |
| `link-previews` | `true` | Show the corner pill with the hovered link's full URL on Cmd-hover. |
| `open-with-app` | (none) | Add an external app to "Open in" submenus. Repeatable. Settings-managed. |
| `default-git-client` | (auto) | Bundle ID of the preferred git GUI client for "Open in <App>". Empty = first installed. |

### Clipboard & Selection

| Key | Default | Effect |
|-----|---------|--------|
| `clipboard-read` | `ask` | OSC 52 clipboard read access. `ask`, `allow`, `deny`. |
| `clipboard-write` | `allow` | OSC 52 clipboard write access. `ask`, `allow`, `deny`. |
| `clipboard-trim-trailing-spaces` | `false` | Trim trailing whitespace when copying. |
| `copy-on-select` | `false` | Automatically copy on selection. |
| `clipboard-paste-protection` | `true` | Warn before pasting potentially dangerous content. |
| `clipboard-paste-bracketed-safe` | `true` | Sanitize bracketed-paste sequences inside pasted content. |
| `selection-clear-on-typing` | `true` | Clear the active selection when typing. |
| `selection-clear-on-copy` | `false` | Clear the selection after an explicit copy (not for `copy-on-select`). |
| `selection-backspace-deletes` | `true` | Backspace deletes a selection on the prompt line instead of one character at the cursor. |

### Sidebar & Layout

| Key | Default | Effect |
|-----|---------|--------|
| `window-layout` | `sidebar-left` | Tab placement. `sidebar-left`, `tabs-top`, `tabs-bottom`. |
| `auto-hide-tab-bar` | `default` | Auto-hide policy for the inline tab bar (`tabs-top`/`tabs-bottom`). `always`, `default`, `auto`. Alias: `window-show-tab-bar`. |
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
| `language` | `system` | UI language. `system`, `english`, `chinese`. |
| `on-launch` | `restore_session` | What happens at launch. `new_window`, `restore_session`. |
| `quit-after-last-window-closed` | `false` | Quit SlopDesk when the last window closes. |
| `confirm-close-tab` | `process` | Confirm closing a tab. `always`, `process` (only with a running process). |
| `confirm-close-window` | `process` | Confirm closing a window. `always`, `process`, `multiple_tabs`. |
| `new-tab-position` | `auto` | Where a new tab opens. `end`, `auto`, `after-current`. |

### Autocomplete

| Key | Default | Effect |
|-----|---------|--------|
| `autocomplete-shortcut` | `tab` | Key that accepts a suggestion. `tab`, `tab+right-arrow`, `ctrl+space`, `disable`. |
| `autocomplete-show-candidates` | `escape` | Key that reveals the candidate panel. `disable`, `auto`, `escape`, `option-escape`. |
| `autocomplete-inline-suggestion` | `true` | Show a faded inline preview when there's a single suggestion. |
| `autocomplete-on-device-learning` | `true` | Allow on-device learning (history, --help probes, README extraction). Privacy gate; everything stays local. |
| `autocomplete-history-ignore` | (none) | Glob patterns for commands never recorded (e.g. `ssh *`, `export *TOKEN*`). |
| `autocomplete-description-language` | `system` | Language for spec descriptions. `system`, `english`, `chinese`. |

### Notifications, Sounds & Badges

Defaults for new panes. Most are per-pane overridable at runtime.

| Key | Default | Effect |
|-----|---------|--------|
| `notification-foreground` | `off` | Banner behavior while SlopDesk is foreground. `off`, `always`, `tab-unfocused`. |
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
| `quick-terminal-cwd` | `current-pane` | Working directory for the quick terminal. `last-used`, `current-pane`. |

### Recipes

| Key | Default | Effect |
|-----|---------|--------|
| `recipe-replay-saved` | `ask_once` | Command replay for internally-saved recipes. `auto`, `ask_once`, `manually`. |
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
| `terminal-scroll-past-end` | `disabled` | Scroll past the last line. `disabled`, `last-line-with-content`, `last-line-in-middle`, `cursor-line`. Always off on the alternate screen. |
| `terminal-scroll-past-first-line` | `disabled` | Scroll past the first scrollback line. `disabled`, `same-as-last-line`, `first-line-with-content`, `first-line-in-middle`. |
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

A pure text documentation page (VitePress-based). No content screenshots — only the site logo appears.

**App icon (otty-icon.png)**

Rounded-square macOS-style app icon ~128×128 (displayed smaller in nav). Background: near-black dark charcoal circle (`~#3a3c42`) on a very light warm grey square (`~#f0eeec`) with a large corner radius. Inside the circle: two white glyph elements — a `>_` prompt on the left and a `*` asterisk on the right, bold sans/monospace, with a `-` below the `>_`. Minimal, dark, terminal-themed (the `*` and `-` evoke a smiley face). Outer-square corner radius ~22% of width.

**Doc site chrome visual standard (inferred from page structure)**

VitePress v1.6.4. Layout: fixed left sidebar (~260px), center content (~740px max width), right on-page TOC. White background in light mode. Sans-serif body font (Inter) for prose, monospace for code. Code blocks: light grey background with syntax highlighting. Tables use subtle row borders. Nav items are flat text links with hover states. Footer: "Copyright © 2026-present SlopDesk".

## Screenshots

- `otty-icon.png` — app icon (navigation logo only; no content screenshots on this page)

## Implementation notes

### Straightforward

- **`font-*` / `text-*` keys**: Pass through to libghostty's `TerminalConfigBuilder`. SlopDesk's `TerminalConfigBuilder` override pattern (used for Monokai Pro theme adoption) is the seam. Map `font-family`, `font-size`, `font-ligatures`, `cursor-style`, `cursor-style-blink`, `cursor-color`, `cursor-text`, `cursor-opacity`, `text-bold`, `text-italic`, `text-underline`, `text-blink`, `font-blending`, `font-thicken`, `arrow-box-drawing-join`, `adjust-cell-height` directly.
- **`scrollback-lines`**: Maps to libghostty scrollback config. SlopDesk's `ReplayBuffer` (64 MiB ceiling) is a separate reconnect-replay concern; the two coexist independently.
- **`foreground` / `background` / `palette-*` / `bold-color` / `selection-*`**: All libghostty terminal color config. Direct map via `TerminalConfigBuilder`.
- **`theme` / `theme-dark` / `auto-theme-dark-mode`**: SlopDesk has `ThemeStore` + Monokai Pro multi-seed factory. `theme` → `ThemeStore` active theme; `auto-theme-dark-mode` → OS appearance observation already in `ThemeStore` (posts on `id`, not `isLight`). The built-in theme list (Paper, Nord, Dracula, etc.) needs implementing or mapping to existing themes.
- **`ui-panel-*` / `ui-text-*` / `ui-hover` / `ui-active` / `ui-accent`**: Map to SlopDesk's `SlateDesign` token system — the exact tokens already present. Auto-derivation from terminal fg/bg is what `ThemeStore` already computes via `resolveTerminalColors`.
- **`cursor-style` / `cursor-style-blink`**: Direct libghostty passthrough.
- **`macos-option-as-alt`**: libghostty config; direct map.
- **`window-layout`**: Maps to `WorkspaceStore` `window-layout`. `sidebar-left` = current default. `tabs-top`/`tabs-bottom` require a layout-mode switch in the pane multiplexer.
- **`sidebar-visible` / `sidebar-width` / `details-panel-width`**: Map to `WorkspaceStore` sidebar toggle and `NSSplitView` divider position. Sidebar toggle already exists (b83ef78).
- **`keybind`**: Maps to `WorkspaceBindingRegistry`. The trigger+action format is already the design direction.
- **`session-restore-*`**: Maps to `DetachedSessionStore` + `SLOPDESK_DETACH_ENABLED`. `session-restore-multiplayer` (tmux reattach) aligns well.
- **`shell-integration`**: OSC 133 marks and CWD reporting already in SlopDesk. Direct map.
- **`privilege-badge-*` / `privilege-notify-*`**: Tab badges and notifications already exist (agent processing/task-complete/awaiting-input — see `privilege-badge-agent-*`). Direct map.
- **Hot reload**: SlopDesk uses `Defaults`/`PreferencesStore` injection. A file-watcher on `~/.config/slopdesk/config.toml` re-applying settings replicates this — achievable with `DispatchSource.makeFileSystemObjectSource`.
- **Include directives**: Pure file-merging at parse time. No slopdesk-specific complications.

### Constraints from the remote-host architecture

- **`working-directory` / `tab-working-directory` / `split-working-directory`**: Depend on the **host-side** CWD, known only on the host via OSC 7 / shell-integration CWD reports. The client config expresses a *preference* (`inherit`, `home`, `~/projects`), but resolution happens host-side where the PTY spawns. The host reads these keys and applies them at session/pane creation.
- **`window-working-directory`**: Same — a host-side path resolved on the macOS host. A remote client cannot set a host-side directory to an iOS-local path.
- **`command` (shell command)**: Host-side. The host daemon already sets the shell from `$SHELL`; this key could be forwarded as a host config preference but cannot be a client-local override.
- **`env`**: Must be applied on the host when spawning the PTY, not the client. Config must be transmitted to the host's session manager.
- **`background-opacity` / `window-opacity`**: On macOS, `background-opacity` maps to libghostty's background alpha (gated at the `TerminalConfigBuilder` seam). On iOS, window-level opacity has no equivalent (UIKit has no window compositor API); `background-opacity` is still achievable via the terminal view's background color alpha.
- **`font-thicken`**: macOS-only (GUI-style stem darkening via Core Text). Not on iOS. Gate with `#if os(macOS)`.
- **`auto-secure-input` / `secure-input-indication`**: macOS Secure Keyboard Entry is macOS-only (`CGSSetSecureInputMode`). Not on iOS. On macOS, the `SLOPDESK_SYSTEM_DIALOG_PANES` feature already handles secure-input scenarios.
- **`dock-icon-animate-progress` / `dock-icon-error-badge`**: macOS-only (NSDockTile API). iOS has no dock icon. Gate with `#if os(macOS)`.
- **`quick-terminal-persist-session` / `quick-terminal-cwd`**: Quick Terminal = a system-wide hotkey drop-down (Quake-style). SlopDesk lacks this; needs a new system-wide hotkey handler and separate window type.
- **`frecency-auto-record` / `zoxide-enabled` / `zoxide-local-path` / `open-quickly-folders-limit`**: Track host-side directories. CWD tracking already done via OSC 7. Frecency persistence lives on the host. The iOS client cannot run a local zoxide binary.
- **`ssh-integration`**: SlopDesk is already a remote terminal; SSH-forwarding shell integration is distinct from SlopDesk's native remote protocol. Only relevant if users run `ssh` from within a pane.
- **`link-open-with = slopdesk`**: Open a URL in SlopDesk's built-in browser pane. A `web-browser` pane type exists (`web-broswer.png` captured); possible but requires the `WebPane` wired up.
- **`file-open-with = slopdesk` / `folder-open-with = slopdesk`**: Open files/folders in SlopDesk's own editor/file pane. `editor-pane`, `file-panel`, `folder-pane` concepts exist (screenshots); achievable but requires pane-type routing.
- **`ipc-allow-send-keys` / `ipc-allow-sensitive-sessions`**: SlopDesk has its own IPC via AF_UNIX NDJSON + `slopdesk-ctl`. `ipc-allow-send-keys` maps to `SLOPDESK_AGENT_CONTROL`'s send-keys capability.
- **`language`**: UI language switching (system/english/chinese). No localization infrastructure yet; requires `NSLocalizedString` / SwiftUI `LocalizedStringKey` across the chrome.
- **`freeze-inactive-tab`**: GPU surface management for inactive tabs. SlopDesk already keeps all tabs mounted at `opacity(0)` to avoid tearing down the libghostty surface — `freeze-inactive-tab = false` (default) is the effective behavior. `= true` requires GPU surface teardown/recreate on switch, a significant libghostty lifecycle change.
- **`session-log-mode = redacted`**: Secret masking in the session log. `ReplayBuffer` stores raw bytes with no redaction; secret detection + masking is a new capability.
- **`autocomplete-*`**: No shell autocomplete yet — a significant feature gap vs the spec. Respect the `autocomplete-on-device-learning` privacy gate (everything stays local) when implementing.
- **`recipes`**: Recipe system (`.slopdeskrecipe` files, command replay). No implementation yet; a new feature area.
