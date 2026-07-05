# Configuration Reference

## Summary

SlopDesk stores all configuration in `~/.config/slopdesk/config.toml` as flat TOML `key = value` pairs (one per line, `#` for comments). The reader is lenient — quotes around simple strings are optional, and unknown keys are silently ignored (so a newer config loads on an older build). Most keys are also editable from the in-app Settings UI, which writes the same file. The page covers the complete set of config keys grouped by domain, built-in theme names, and an example config snippet.

No screenshots are embedded on this page; it is a pure text reference.

---

## Behaviors

- Config file location: `~/.config/slopdesk/config.toml`
- Format: TOML — flat list, no nested tables required for most keys
- Unknown keys silently ignored — forward-compatible loading
- Most keys editable in-app via Settings (writes same file)
- A handful are Settings-only or theme-only (noted inline)
- Transparency keys (`background-opacity`, `window-opacity`) apply at window-creation time; requires reopening to take effect
- Notification/badge `privilege-*` keys are defaults for new panes; most can be overridden per-pane at runtime
- `background-opacity` minimum enforced at 0.5; values below rejected
- `window-opacity` minimum enforced at 0.5
- `font-thicken` auto-enabled when `background-opacity < 1.0`
- `terminal-scroll-past-end` variants are always disabled on the alternate screen
- `keybind` key is repeatable (multiple bindings supported)
- `env` key is repeatable (one env line per variable)
- `open-with-app` is repeatable and Settings-managed
- `cli-alias` is repeatable and Settings-managed
- `zoxide-local-path` is Settings-hidden
- `omit-slopdesk-prefix` is live-toggleable at runtime (no restart required)
- `auto-theme-dark-mode = true` makes the terminal follow OS appearance — `theme` used for light, `theme-dark` for dark
- Custom theme `.toml` files dropped into `~/.config/slopdesk/themes/` are auto-discovered
- Themes can be imported from other terminals
- `on-device-learning` for autocomplete stays entirely local (never sent off device)
- `shell-integration = true` installs a managed shell-rc block that provides OSC 133, CWD reporting, and edit/view/jump wrappers
- `ssh-integration = true` forwards shell integration over SSH connections
- `progress-bar-commands` defaults include curl, git, npm, and other common tools that auto-emit OSC 9;4 progress
- `frecency-auto-record = true` records every CWD change to frecency table for Open Quickly
- `zoxide-enabled = true` syncs removals to external `zoxide` binary when present
- `dock-icon-error-badge`: clicking the tinted Dock icon focuses next error tab
- `quick-terminal-persist-session`: controls whether quick terminal session survives toggle dismissal
- `session-restore-multiplayer = true` reattaches tmux and other multiplexer sessions on restore
- `session-restore-processes`: can relaunch running commands on restore (`none` / `whitelist` / `all`)
- `live-resize-sigwinch-delay-ms = 0` disables mid-drag SIGWINCH entirely (drag-end still fires one)
- `auto-secure-input = true` auto-enables macOS Secure Keyboard Entry at password prompts
- `secure-input-indication = true` shows a title-bar pill while Secure Keyboard Entry is active

---

## Keybindings

Keybindings on this reference page are not independently listed — the page only documents the `keybind` config key type. See the Keybindings Reference page (`/reference/keybindings`) for the full default map.

| Action | Keys |
|--------|------|
| (See Keybindings Reference) | `keybind = trigger=action` in config.toml |

---

## Config keys

### Font

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `JetBrains Mono` | Primary terminal font. Accepts inline array `["A","B"]` for fallbacks tried in order. |
| `font-family-fallback` | (none) | Extra fallback families tried before the OS system cascade. Comma-separated list. |
| `font-family-bold` | (none) | Override family for bold cells. Empty = reuse primary with synthesis. |
| `font-family-italic` | (none) | Override family for italic cells. |
| `font-family-bold-italic` | (none) | Override family for bold+italic cells. |
| `font-family-fallback-bold` | (none) | Per-style fallback chain for bold cells. |
| `font-family-fallback-italic` | (none) | Per-style fallback chain for italic cells. |
| `font-family-fallback-bold-italic` | (none) | Per-style fallback chain for bold+italic cells. |
| `font-size` | `13.0` | Font size in points. |
| `font-blending` | `srgb-over` | Glyph alpha compositing mode. `srgb-over` = gamma-encoded framebuffer (classic look). `macos-like` = OS-native non-linear blending (Ghostty native). `linear` = linear-light space (physically correct, can thin strokes). `perceptual` = boosts alpha for thin strokes to preserve stem weight. Aliases: `font-smooth`, `font-antialiased`. |
| `text-bold` | `auto` | Bold resolution when no bold face exists. Values: `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-bold`. |
| `text-italic` | `auto` | Italic resolution when no italic face exists. Values: `off`, `auto`, `primary-only`, `synthetic`. Alias: `font-italic`. |
| `text-underline` | `true` | Render SGR-underline decoration. Alias: `font-underline`. |
| `text-blink` | `false` | Animate SGR-blink (codes 5/6). Off renders steady (accessibility). Alias: `font-blink`. |
| `font-ligatures` | `dlig` | OpenType ligature level. `off` disables, `calt` enables standard/contextual, `dlig` also enables discretionary ligatures. Alias: `ligatures`. |
| `font-ligatures-alphabet` | `false` | Also form ligatures inside runs of letters/digits/CJK. Off keeps fi/fl-style letter ligatures from collapsing cells. |
| `font-thicken` | `false` | macOS only. Force GUI-style stem darkening regardless of blending mode. Auto-enabled when `background-opacity < 1.0`. |
| `arrow-box-drawing-join` | `true` | Render arrows/solid triangles aligned to cell centerline when adjacent to connecting box-drawing rules, so they butt flush instead of leaving a gap. Standalone glyphs in prose/TUIs unaffected. |
| `adjust-cell-height` | (none) | Ghostty-compatible cell-height delta. `Npx`/bare `N` add logical points, `N%` scales by 1+N/100. Negative compacts; glyphs stay vertically centered. |
| `live-resize-sigwinch-delay-ms` | `50` | Milliseconds grid must stay stable during live drag before a mid-drag SIGWINCH fires. `0` disables mid-drag signal (drag-end still fires one). |

### Cursor

| Key | Default | Effect |
|-----|---------|--------|
| `cursor-style` | `block` | Cursor shape. Values: `block`, `bar`, `underline`, `block_hollow` (alias `block-hollow`). |
| `cursor-style-blink` | (app default) | Whether cursor blinks. Unset follows the application's own request. |
| `cursor-color` | (theme) | Cursor fill color. |
| `cursor-text` | (theme) | Text color under the cursor. |
| `cursor-opacity` | `1.0` | Cursor opacity (0.0–1.0). |
| `cursor-animation` | `off` | Cursor motion animation. Values: `off`, `smooth`. |

### Shell & Environment

| Key | Default | Effect |
|-----|---------|--------|
| `command` | `$SHELL` (else `/bin/zsh`) | Shell/command to run. Alias: `shell`. |
| `env` | (none) | Set an environment variable (KEY=VALUE). Repeatable — one `env` line per variable. |
| `term` | `auto` | Value of `$TERM`. `auto` picks the best-supported value for SlopDesk. |
| `working-directory` | `inherit` | Initial directory. `inherit`, `home`, or absolute path (`~/` allowed). |
| `window-working-directory` | `home` | Directory for a brand-new window's first pane. |
| `tab-working-directory` | `inherit` | Directory for a new tab (inherits the active pane's CWD). |
| `split-working-directory` | `inherit` | Directory for a new split. |

### Terminal Identity & VT

| Key | Default | Effect |
|-----|---------|--------|
| `enquiry-response` | (empty) | Reply string for the ENQ (0x05) control character. |
| `osc-color-report-format` | `16-bit` | OSC 4/10/11 color-query response format. Values: `none`, `8-bit`, `16-bit`. |
| `title-report` | `false` | Allow apps to query the window title (XTWINOPS). Off by default for security. |
| `vt-kam-allowed` | `true` | Allow keyboard action mode (KAM) escape sequence. |
| `vt-keypad-app-allowed` | `true` | Allow application keypad mode (DECKPAM, `ESC =`). |
| `kitty-keyboard` | `true` | Support Kitty keyboard protocol. |
| `widen-ambiguous` | (empty) | Unicode blocks to treat East-Asian-Ambiguous as width-2. Values: `enclosed-alphanumerics`, `number-forms`, `math-operators`, `misc-technical`, `misc-symbols`, `dingbats`, `arrows`, `geometric-shapes`. |
| `login-greeting` | `false` | Run shell as login shell so greeting/MOTD prints. |

### Scrollback & Session Log

| Key | Default | Effect |
|-----|---------|--------|
| `scrollback-lines` | `10000` | Max scrollback lines per pane. |
| `scrollback-limit` | (none) | Alternative byte-budget; divided by 80 for lines. |
| `session-log-size-mb` | `5` | Max per-session log size in MB (for recovery and pager). |
| `session-log-mode` | `redacted` | Capture mode. `plain` = verbatim. `redacted` = masks secrets. |
| `freeze-inactive-tab` | `false` | Release GPU surfaces on inactive tabs to save memory. |

### Session Restore

| Key | Default | Effect |
|-----|---------|--------|
| `session-restore-banner` | `true` | Show closed/restored banners. |
| `session-restore-multiplayer` | `true` | Reattach multiplexer sessions (tmux) on restore. |
| `session-restore-processes` | `none` | Relaunch running commands: `none`, `whitelist`, `all`. |
| `session-restore-process-allowlist` | (none) | Command prefixes eligible for relaunch (whitelist mode). |

### Window

| Key | Default | Effect |
|-----|---------|--------|
| `window-size` | `remember` | Initial sizing mode. `remember` = last known size. `frame` = pixels. `grid` = cells. |
| `window-width-px` | `1000` | Initial width in pixels (frame mode). |
| `window-height-px` | `600` | Initial height in pixels (frame mode). |
| `window-cols` | `80` | Initial columns (grid mode). |
| `window-rows` | `24` | Initial rows (grid mode). |

### Transparency

*Applied at window creation; requires reopening to take effect.*

| Key | Default | Effect |
|-----|---------|--------|
| `background-opacity` | `1.0` | Terminal background opacity (0.5–1.0). Values below 0.5 rejected. |
| `window-opacity` | `1.0` | Window-level opacity (0.5–1.0). |

### Terminal Colors

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | `#d4d4d4` | Default text color (when no theme active). |
| `background` | `#1e1e1e` | Terminal background (when no theme active). |
| `palette-0` to `palette-15` | (Dracula-based) | ANSI palette: indices 0–7 normal, 8–15 bright. |
| `palette` | (none) | Per-index syntax alternative: `palette = N=#rrggbb`. |
| `bold-color` | `none` | Bold text color: `none`, `bright` (uses bright palette variant), or `#rrggbb` hex. |
| `faint-opacity` | `0.5` | Opacity multiplier for SGR-faint/dim text (0.0–1.0). |
| `selection-foreground` | (none) | Text color in selections. `auto` = keep original foreground. Unset = swap fg↔bg. |
| `selection-background` | (none) | Selection background. Accepts 8-digit `#rrggbbaa` for translucency. |
| `minimum-contrast` | `1.0` | Minimum fg/bg contrast ratio (1.0–21.0). `1.0` disables. |

**Default palette (when no theme active) — Dracula-based:**

| Index | Hex | Name | Index | Hex | Name |
|-------|-----|------|-------|-----|------|
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
| `theme` | `Paper` | Active theme (light slot). Overrides `foreground`, `background`, and `palette`. Case-insensitive. |
| `theme-dark` | `Nord` | Theme used in OS dark mode when `auto-theme-dark-mode` is on. |
| `auto-theme-dark-mode` | `true` | Follow OS appearance automatically. |

**Available built-in themes (case-insensitive):**
April, April Dark, Ayu Dark, Ayu Light, Catppuccin Mocha, Dracula, Floating Card, Glass Dark, Glass Light, Gruvbox Dark, Monokai Classic, Newsprint, Night, Nord, One Dark, One Light, Owl, Paper, Pink, Rosé Pine, Seafoam Pastel, Solarized Dark, Solarized Light, Tokyo Night

Custom themes: drop `.toml` files into `~/.config/slopdesk/themes/` or import from other terminals.

### UI Chrome Colors

*Optional; auto-derived from terminal colors when unset. Override the active theme's `[panel].*` values.*

| Key | Default | Effect |
|-----|---------|--------|
| `ui-panel-background` | (auto) | Chrome frame behind the terminal grid. |
| `ui-panel-surface` | (auto) | Surface/card background. |
| `ui-panel-border` | (auto) | Panel border color. Accepts `#rrggbbaa`. |
| `ui-border-subtle` | (auto) | Subtle/secondary border. |
| `ui-text-primary` | (auto) | Primary UI text color. |
| `ui-text-secondary` | (auto) | Secondary UI text color. |
| `ui-text-tertiary` | (auto) | Tertiary/muted UI text color. |
| `ui-hover` | (auto) | Hover highlight color. |
| `ui-active` | (auto) | Active/pressed highlight color. |
| `ui-accent` | (auto) | Accent color (defaults to blue). |

### UI Font

| Key | Default | Effect |
|-----|---------|--------|
| `ui-font-family` | (system) | Font family for UI chrome text. |
| `ui-font-size` | `13.0` | Chrome font size in points. |

### Mouse & Input

| Key | Default | Effect |
|-----|---------|--------|
| `mouse-reporting` | `true` | Forward mouse events to the running application. |
| `mouse-hide-while-typing` | `false` | Hide mouse cursor while typing. |
| `mouse-scroll-multiplier` | `3.0` | Scroll speed multiplier. Compound form: `discrete:3.0,precision:1.0`. |
| `focus-follows-mouse` | `false` | Focus the pane under the mouse pointer without clicking. |
| `macos-option-as-alt` | `false` | Treat Option key as Alt. Values: `true`, `false`, `left`, `right`. |
| `shift-arrow-select` | `true` | Enable Shift+Arrow text selection. |
| `mouse-shift-to-select` | `true` | Shift always performs local selection even when mouse reporting is active. |
| `cursor-click-to-move` | `true` | Click on the prompt line emits arrow keys to move the shell cursor. |
| `right-click-action` | `context-menu` | Right-click behavior. Values: `context-menu`, `copy`, `paste`, `copy-or-paste`, `ignore`. |
| `scroll-to-bottom` | `keystroke,no-output` | Auto-scroll triggers (comma-separated flags): `keystroke`/`no-keystroke`, `output`/`no-output`. |

### Links & Open With

| Key | Default | Effect |
|-----|---------|--------|
| `link-open-with` | `browser` | Clicked URL destination: `browser` or `slopdesk`. |
| `file-open-with` | `default-app` | Clicked file: `default-app` or `slopdesk`. |
| `folder-open-with` | `default-app` | Clicked folder: `default-app` or `slopdesk`. |
| `link-schemes` | `all` | Extra URL schemes: `all` (any `scheme://`) or `custom` (allowlist only). `http(s)`, `file`, `mailto` always detected. |
| `link-scheme-allowlist` | (none) | Extra schemes for `custom` mode (bare names). |
| `link-previews` | `true` | Show corner pill with hovered link URL on Cmd-hover. |
| `open-with-app` | (none) | Add external app to Open submenus. Repeatable, Settings-managed. Accepts name or bundle ID. |
| `default-git-client` | (auto) | Git GUI bundle ID. Empty = first installed. |

### Clipboard & Selection

| Key | Default | Effect |
|-----|---------|--------|
| `clipboard-read` | `ask` | OSC 52 read access: `ask`, `allow`, `deny`. |
| `clipboard-write` | `allow` | OSC 52 write access: `ask`, `allow`, `deny`. |
| `clipboard-trim-trailing-spaces` | `false` | Trim trailing whitespace when copying. |
| `copy-on-select` | `false` | Auto-copy text to clipboard on selection. |
| `clipboard-paste-protection` | `true` | Warn before pasting potentially dangerous content. |
| `clipboard-paste-bracketed-safe` | `true` | Sanitize bracketed-paste content when pasting. |
| `selection-clear-on-typing` | `true` | Clear selection when typing. |
| `selection-clear-on-copy` | `false` | Clear selection after explicit copy (not copy-on-select). |
| `selection-backspace-deletes` | `true` | Backspace deletes selection on the prompt line. |

### Sidebar & Layout

| Key | Default | Effect |
|-----|---------|--------|
| `window-layout` | `sidebar-left` | Tab placement. Values: `sidebar-left`, `tabs-top`, `tabs-bottom`. |
| `auto-hide-tab-bar` | `default` | Tab bar auto-hide for inline tab layouts. Values: `always`, `default`, `auto`. Alias: `window-show-tab-bar`. |
| `auto-hide-tabs-panel` | `default` | Sidebar tabs panel auto-hide. Values: `always`, `default`, `auto`. |
| `sidebar-visible` | `true` | Show sidebar on startup. |
| `sidebar-width` | `220` | Sidebar width in pixels. |
| `details-panel-width` | `220` | Details panel width in pixels. |

### Shell Integration & CLI

| Key | Default | Effect |
|-----|---------|--------|
| `shell-integration` | `true` | Install managed shell-rc block (OSC 133, CWD reporting, edit/view/jump wrappers). |
| `ssh-integration` | `true` | Forward shell integration over SSH. |
| `omit-slopdesk-prefix` | `false` | Install edit/view/watch functions without the `slopdesk` prefix. Live-toggleable. |
| `cli-allow-overwrite` | `false` | Allow CLI wrappers to replace user-defined function names. |
| `cli-alias` | (none) | User CLI alias (name=cmd). Installs a shell function. Repeatable, Settings-managed. |
| `progress-bar-commands` | (built-in) | Command prefixes that auto-emit OSC 9;4 progress (curl, git, npm, etc.). |

### App Behavior

| Key | Default | Effect |
|-----|---------|--------|
| `language` | `system` | UI language. Values: `system`, `english`, `chinese`. |
| `on-launch` | `restore_session` | Launch action. Values: `new_window`, `restore_session`. |
| `quit-after-last-window-closed` | `false` | Quit when the last window closes. |
| `confirm-close-tab` | `process` | Confirm tab close. Values: `always`, `process` (only when a command is running). |
| `confirm-close-window` | `process` | Confirm window close. Values: `always`, `process`, `multiple_tabs`. |
| `new-tab-position` | `auto` | New tab placement. Values: `end`, `auto`, `after-current`. |

### Autocomplete

| Key | Default | Effect |
|-----|---------|--------|
| `autocomplete-shortcut` | `tab` | Suggestion accept key. Values: `tab`, `tab+right-arrow`, `ctrl+space`, `disable`. |
| `autocomplete-show-candidates` | `escape` | Candidate panel reveal. Values: `disable`, `auto`, `escape`, `option-escape`. |
| `autocomplete-inline-suggestion` | `true` | Show faded inline preview for a single suggestion. |
| `autocomplete-on-device-learning` | `true` | Allow on-device learning (history, help probes, README extraction). Stays entirely local. |
| `autocomplete-history-ignore` | (none) | Glob patterns for commands never recorded (e.g., `ssh *`, `export *TOKEN*`). |
| `autocomplete-description-language` | `system` | Spec description language. Values: `system`, `english`, `chinese`. |

### Notifications, Sounds & Badges

*Defaults for new panes; most per-pane overridable at runtime.*

| Key | Default | Effect |
|-----|---------|--------|
| `notification-foreground` | `off` | Show banner while SlopDesk is in the foreground. Values: `off`, `always`, `tab-unfocused`. |
| `privilege-sound-on-error` | `false` | Play sound on non-zero exit code. |
| `privilege-sound-shell` | `true` | Allow shell-integration commands to trigger sounds. |
| `privilege-notification-on-finish` | `false` | Notify when a long command finishes. |
| `privilege-notification-on-error` | `true` | Notify on command error (non-zero exit). |
| `privilege-notification-on-watch-finish` | `true` | Notify when a watched command finishes. |
| `privilege-notification-shell` | `true` | Allow shell-integration to post system notifications. |
| `privilege-badge-exit-status` | `true` | Show exit-status badge on the tab. |
| `privilege-badge-activity` | `true` | Show activity badge for background output. |
| `privilege-badge-agent-processing` | `true` | Show badge while an agent is processing. |
| `privilege-badge-agent-task-complete` | `true` | Show badge when an agent task finishes. |
| `privilege-badge-agent-awaiting-input` | `true` | Show badge when an agent is awaiting input. |
| `privilege-notify-agent-task-complete` | `true` | System notification on agent task completion. |
| `privilege-notify-agent-awaiting-input` | `true` | System notification when agent needs approval/input. |
| `privilege-caffeinate-agent-processing` | `false` | Keep Mac awake while agent is processing. |
| `privilege-resume-agent-session` | `true` | Offer resume option on agent session restore. |
| `privilege-mouse-shell` | `true` | Allow shell to control mouse reporting. |
| `privilege-title-shell` | `true` | Allow shell to set window/tab title. |
| `privilege-clipboard-shell` | `true` | Allow shell to drive clipboard (OSC 52). |

### Auto Approve & IPC Security

| Key | Default | Effect |
|-----|---------|--------|
| `show-auto-approve` | `false` | Surface the deprecated Auto Approve feature in UI. |
| `auto-approve-enabled` | `false` | Enable Auto Approve. |
| `hide-auto-approve-pill` | `false` | Hide the Auto Approve toolbar pill. |
| `ipc-allow-send-keys` | `false` | Allow the send-keys IPC command. |
| `ipc-allow-sensitive-sessions` | `false` | Allow send-keys/capture on SSH/sudo sessions. |

### Secure Input (macOS)

| Key | Default | Effect |
|-----|---------|--------|
| `auto-secure-input` | `true` | Auto-enable macOS Secure Keyboard Entry at password prompts. |
| `secure-input-indication` | `true` | Show title-bar pill indicator while Secure Keyboard Entry is active. |

### Quick Terminal

| Key | Default | Effect |
|-----|---------|--------|
| `quick-terminal-persist-session` | `false` | Keep quick-terminal session alive between toggle dismissals. |
| `quick-terminal-cwd` | `current-pane` | Quick-terminal working directory. Values: `last-used`, `current-pane`. |

### Recipes

| Key | Default | Effect |
|-----|---------|--------|
| `recipe-replay-saved` | `ask_once` | Command replay for internal recipes. Values: `auto`, `ask_once`, `manually`. |
| `recipe-replay-file` | `manually` | Command replay for external `.slopdeskrecipe` files. Same values as above. |

### Open Quickly, Frecency & Jump

| Key | Default | Effect |
|-----|---------|--------|
| `open-quickly-folders-limit` | `12` | Max frecency-ranked folders shown in Open Quickly. Alias: `open-quickly-zoxide-limit`. |
| `frecency-auto-record` | `true` | Record every CWD change to the frecency table. |
| `zoxide-enabled` | `true` | Sync removals to external `zoxide` binary when present. |
| `zoxide-local-path` | (auto) | Explicit path to `zoxide`. Empty = auto-detect. Settings-hidden. |

### Editor (File Pane)

*Applies to non-terminal text surfaces — file panes and previews.*

| Key | Default | Effect |
|-----|---------|--------|
| `editor-line-wrap` | `true` | Soft-wrap long lines vs. horizontal scrolling. |
| `editor-tab-size` | `4` | Visual tab character width in columns. |
| `editor-visible-whitespace` | `false` | Render whitespace as visible glyphs. |
| `editor-show-line-numbers` | `true` | Show line-number gutter. |
| `editor-default-to-preview-readonly` | `true` | Open preview-capable formats (.md, .svg, .html) in read-only mode. |
| `editor-scroll-past-end` | `true` | Allow scrolling past the last line. |

### Terminal Scrolling

| Key | Default | Effect |
|-----|---------|--------|
| `terminal-scroll-past-end` | `disabled` | Past-end scrolling behavior. Values: `disabled`, `last-line-with-content`, `last-line-in-middle`, `cursor-line`. Always disabled on alt screen. |
| `terminal-scroll-past-first-line` | `disabled` | Past-first-line scrolling. Values: `disabled`, `same-as-last-line`, `first-line-with-content`, `first-line-in-middle`. |
| `terminal-scroll-past-end-sticky` | `false` | Keep past-end offset sticky (vs. drain as new output arrives). |
| `terminal-scroll-smooth` | `true` | Pixel-granular scrollback scrolling. Snaps to row boundary on idle. |

### Dock Icon (macOS)

| Key | Default | Effect |
|-----|---------|--------|
| `dock-icon-animate-progress` | `false` | Animate the Dock icon during OSC 9;4 progress. |
| `dock-icon-error-badge` | `true` | Tint Dock icon red on non-zero exit or OSC 9;4;2 error. Clicking the tinted icon focuses the next error tab. |

### Keybindings

| Key | Default | Effect |
|-----|---------|--------|
| `keybind` | (built-in map) | Bind a key chord to an action. Repeatable. See Keybindings Reference for full default map. Format: `keybind = trigger=action`. |

---

## Visual spec

This reference page contains no screenshots. It is a pure text/table documentation page. The only image present is the app's reference icon asset (`otty-icon.png`).

The page layout follows the standard docs template used across this spec:
- Left sidebar: full navigation tree (Getting Started, User Interface, Workflows, Terminal Features, Working with Agents, Customization, Terminal API/VT, Reference, About)
- Right sidebar: "On this page" anchor list of section headings
- Center: page title, intro paragraph, then grouped config tables (Key | Type | Default | Description columns)
- Tables use 4 columns; rows are dense, one config key per row
- Section headings divide the table by domain (Font, Cursor, Shell & Environment, etc.)
- Footer: Copyright notice, Previous/Next navigation links

---

## Screenshots

No screenshots were captured for this page — it contains no embedded images beyond the site logo.

---

## Implementation notes

### Direct implementation

- **`font-family`, `font-size`, `font-blending`, `font-ligatures`, `font-thicken`** — these route through libghostty's `TerminalConfigBuilder` font/rendering settings. SlopDesk already routes theme colors through `resolveTerminalColors`; font config should follow the same path.
- **`cursor-style`, `cursor-style-blink`, `cursor-color`, `cursor-opacity`, `cursor-animation`** — direct libghostty cursor config. Pass through `TerminalConfigBuilder` or equivalent ghostty config key.
- **`theme`, `theme-dark`, `auto-theme-dark-mode`** — SlopDesk already has `ThemeStore` and Monokai Pro as default. Built-in theme names resolve to `ThemeStore` entries; `auto-theme-dark-mode` follows OS appearance.
- **`ui-panel-*`, `ui-text-*`, `ui-hover`, `ui-active`, `ui-accent`** — already approximated by SlopDesk's `SlateDesign` token system. These config keys would allow per-user override of design tokens.
- **`font-size`, `adjust-cell-height`** — route to libghostty cell sizing config. `adjust-cell-height` uses Ghostty-compatible syntax — directly passable.
- **`foreground`, `background`, `palette-0`–`palette-15`** — already handled via `resolveTerminalColors` → `TerminalConfigBuilder` in SlopDesk.
- **`scrollback-lines`** — routes to libghostty scrollback config.
- **`text-bold`, `text-italic`, `text-underline`, `text-blink`** — route to libghostty text rendering options.
- **`mouse-reporting`, `mouse-scroll-multiplier`, `macos-option-as-alt`** — route to libghostty / NSEvent input handling.
- **`kitty-keyboard`** — libghostty supports Kitty keyboard protocol; pass through.
- **`minimum-contrast`, `bold-color`, `faint-opacity`, `selection-foreground`, `selection-background`** — libghostty renderer config; pass through.
- **`shell-integration`** — SlopDesk already has OSC 133 / CWD detection. This key controls whether the managed shell-rc block is installed.
- **`live-resize-sigwinch-delay-ms`** — SlopDesk already implements `onResizeSettled` / deferred SIGWINCH. Maps to that delay constant.
- **`terminal-scroll-smooth`** — SlopDesk already has smooth scrollback; this is a user toggle.
- **`window-layout`** — SlopDesk has sidebar-left layout currently. `tabs-top`/`tabs-bottom` are additional layout modes to implement.
- **`sidebar-visible`, `sidebar-width`, `details-panel-width`** — direct sidebar visibility/sizing config; SlopDesk already has sidebar toggle.
- **`autocomplete-*`** — SlopDesk's own autocomplete engine; these config keys define its behavior surface. `autocomplete-on-device-learning` gates local history learning only.
- **`privilege-badge-*`**, **`privilege-notify-*`** — SlopDesk's agent monitoring (`ClaudeStatus`/`ClaudePaneDetector`) produces these events. These keys control opt-in/opt-out per signal type.
- **`privilege-caffeinate-agent-processing`** — routes to `IOPMAssertion` / `caffeinate` while Claude is processing. Worth implementing.
- **`privilege-resume-agent-session`** — ties to `session-restore-multiplayer` + agent session state on restore.

### Remote-architecture constraints

- **`working-directory`, `window-working-directory`, `tab-working-directory`, `split-working-directory`** — in SlopDesk the CWD is always on the **host machine** (remote). The client cannot set CWD to a local path. Only `inherit` semantics make sense client-side; the initial directory must be configured on the host. Flag in Settings as "host-side only".
- **`command`, `shell`** — the shell runs on the **host** (`slopdesk-hostd`), not locally. This config key belongs in host configuration, not the client config file.
- **`env`** — environment variables are set on the host process. Client cannot inject env vars into the remote shell. Host-side config only.
- **`ssh-integration`** — SlopDesk IS the remote transport; SSH integration inside the terminal would be SSH-over-slopdesk. Lower priority; flag as N/A unless the remote session itself then SSHes onward.
- **`login-greeting`** — host-side only (controls remote shell startup mode).
- **`quick-terminal-*`** — Quick Terminal is a macOS-global hotkey drop-down terminal. Applies on macOS client. Does not apply to iOS client.
- **`dock-icon-*`** — macOS Dock only; not applicable on iOS client.
- **`auto-secure-input`, `secure-input-indication`** — macOS Secure Keyboard Entry applies locally on the client machine. Since the remote end is `slopdesk-hostd` on a different Mac, "secure input" semantics are local to the client keyboard. The indication pill can still be shown on the macOS client. Not applicable on iOS (iOS has its own secure field handling).
- **`window-opacity`** — window-level translucency requires a local NSWindow. On iOS client, not applicable. On macOS client, maps to the local app window opacity.
- **`background-opacity`** — same as above; local NSWindow blending. On iOS, UIKit compositing has no direct equivalent.
- **`font-thicken`** — macOS only per the docs. Applicable on macOS client; skip on iOS.
- **`macos-option-as-alt`** — macOS only; not applicable on iOS (no hardware Option key in general).
- **`open-with-app`, `default-git-client`, `file-open-with`, `folder-open-with`** — "open in app" semantics require opening local files. On slopdesk, files are remote. Only `link-open-with = browser` (opening URLs) maps cleanly since URLs are scheme-based and can be forwarded to the client browser.
- **`zoxide-enabled`, `zoxide-local-path`** — `zoxide` runs on the host. frecency sync with a local `zoxide` binary doesn't apply on the client. The slopdesk client has its own frecency table (Open Quickly uses it per the existing implementation).
- **`session-log-mode = redacted`** — secret masking is a host-side concern since the raw PTY stream passes through `slopdesk-hostd`. Client-side session log would only capture what arrives over the wire.
- **`ipc-allow-send-keys`, `ipc-allow-sensitive-sessions`** — slopdesk's IPC security model runs on the `slopdesk-ctl` NDJSON control channel — these concepts map to `SLOPDESK_AGENT_CONTROL` permission gating.
- **`recipe-replay-*`** — recipe files (`.slopdeskrecipe`) are a local file format. File paths would be local to the client machine, while execution happens on the host.
- **`progress-bar-commands`** — the progress injection wraps host-side commands via shell integration. Client-side config would need to be forwarded to the host shell-rc block. Treat as host-side config.
- **`session-restore-multiplayer` (tmux reattach)** — SlopDesk has its own detach/reattach via `DetachedSessionStore`. tmux reattach in the remote shell is an orthogonal concern; can be supported via `SLOPDESK_DETACH_ENABLED` + custom session restore logic.

### Implementation priority order

1. Font config keys → `TerminalConfigBuilder` (highest impact, most visible)
2. Color/theme config keys → already partially done; complete palette override
3. Cursor config keys → libghostty passthrough
4. `sidebar-visible`, `sidebar-width`, `window-layout` → already partially done
5. Mouse/input config keys → NSEvent / libghostty
6. Scrollback/scroll config keys → libghostty
7. `autocomplete-*` → slopdesk autocomplete engine
8. `privilege-badge-*` / `privilege-notify-*` → agent monitoring integration
9. Session restore keys → `DetachedSessionStore` + agent resume
10. Transparency keys → macOS client only
