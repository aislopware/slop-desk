# Configuration Reference

## Summary

SlopDesk stores config in `~/.config/slopdesk/config.toml` as flat TOML `key = value` pairs (one per line, `#` comments). The reader is lenient: quotes around simple strings are optional and unknown keys are silently ignored (so a newer config loads on an older build). Most keys are also editable in-app via Settings, which writes the same file. This page lists every config key grouped by domain, built-in theme names, and the default palette. Pure text reference — no screenshots.

---

## Behaviors

Per-key behavior is documented inline in the tables below. Cross-cutting rules:

- Some keys are Settings-only or theme-only (noted inline).
- Transparency (`background-opacity`, `window-opacity`) applies at window creation; reopen to take effect. Minimum enforced at 0.5; lower values rejected.
- `font-thicken` auto-enables when `background-opacity < 1.0`.
- `privilege-*` notification/badge keys are defaults for new panes; most per-pane overridable at runtime.
- `terminal-scroll-past-end*` variants are always disabled on the alternate screen.
- `auto-theme-dark-mode = true` makes the terminal follow OS appearance — `theme` for light, `theme-dark` for dark.
- Repeatable keys: `keybind`, `env`, `open-with-app`, `cli-alias`. `open-with-app`/`cli-alias` are Settings-managed; `zoxide-local-path` is Settings-hidden.
- `omit-slopdesk-prefix` is live-toggleable (no restart).
- Custom theme `.toml` files in `~/.config/slopdesk/themes/` are auto-discovered; themes can also be imported from other terminals.
- `autocomplete-on-device-learning` stays entirely local (never sent off device).

---

## Keybindings

Individual keybindings are not listed here — this page documents only the `keybind` config key. Format: `keybind = trigger=action` (repeatable). See the Keybindings Reference (`/reference/keybindings`) for the full default map.

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

Pure text/table page — no screenshots; the only image is the app reference icon (`otty-icon.png`). Standard docs template:

- Left sidebar: full nav tree (Getting Started, User Interface, Workflows, Terminal Features, Working with Agents, Customization, Terminal API/VT, Reference, About).
- Right sidebar: "On this page" anchor list.
- Center: title, intro, then domain-grouped config tables (Key | Type | Default | Description; 4 columns, one key per row).
- Footer: copyright, Previous/Next links.

---

## Screenshots

None — no embedded images beyond the site logo.

---

## Implementation notes

### Direct implementation

- **`font-family`, `font-size`, `font-blending`, `font-ligatures`, `font-thicken`** → libghostty `TerminalConfigBuilder` font/rendering settings. Theme colors already route through `resolveTerminalColors`; font config follows the same path.
- **`cursor-style`, `cursor-style-blink`, `cursor-color`, `cursor-opacity`, `cursor-animation`** → direct libghostty cursor config via `TerminalConfigBuilder`.
- **`theme`, `theme-dark`, `auto-theme-dark-mode`** → existing `ThemeStore` (Monokai Pro default). Built-in names resolve to `ThemeStore` entries; auto mode follows OS appearance.
- **`ui-panel-*`, `ui-text-*`, `ui-hover`, `ui-active`, `ui-accent`** → already approximated by `SlateDesign` tokens; these keys allow per-user override.
- **`font-size`, `adjust-cell-height`** → libghostty cell sizing. `adjust-cell-height` uses Ghostty-compatible syntax — directly passable.
- **`foreground`, `background`, `palette-0`–`palette-15`** → already via `resolveTerminalColors` → `TerminalConfigBuilder`.
- **`scrollback-lines`** → libghostty scrollback config.
- **`text-bold`, `text-italic`, `text-underline`, `text-blink`** → libghostty text rendering options.
- **`mouse-reporting`, `mouse-scroll-multiplier`, `macos-option-as-alt`** → libghostty / NSEvent input handling.
- **`kitty-keyboard`** → libghostty passthrough.
- **`minimum-contrast`, `bold-color`, `faint-opacity`, `selection-foreground`, `selection-background`** → libghostty renderer config passthrough.
- **`shell-integration`** → OSC 133 / CWD detection exists; key controls whether the managed shell-rc block installs.
- **`live-resize-sigwinch-delay-ms`** → maps to existing `onResizeSettled` / deferred-SIGWINCH delay constant.
- **`terminal-scroll-smooth`** → user toggle over existing smooth scrollback.
- **`window-layout`** → sidebar-left exists; `tabs-top`/`tabs-bottom` are additional modes to implement.
- **`sidebar-visible`, `sidebar-width`, `details-panel-width`** → direct config; sidebar toggle exists.
- **`autocomplete-*`** → SlopDesk's own autocomplete engine; `autocomplete-on-device-learning` gates local history learning only.
- **`privilege-badge-*`, `privilege-notify-*`** → agent monitoring (`ClaudeStatus`/`ClaudePaneDetector`) events; keys opt-in/out per signal.
- **`privilege-caffeinate-agent-processing`** → `IOPMAssertion` / `caffeinate` while Claude processing.
- **`privilege-resume-agent-session`** → ties to `session-restore-multiplayer` + agent session state on restore.

### Remote-architecture constraints

- **`working-directory`, `window-working-directory`, `tab-working-directory`, `split-working-directory`** → CWD is always on the host; client cannot set a local path. Only `inherit` makes sense client-side; initial dir configured on host. Flag "host-side only".
- **`command`, `shell`** → shell runs on the host (`slopdesk-hostd`); host config, not client.
- **`env`** → set on the host process; client cannot inject. Host-side only.
- **`ssh-integration`** → SlopDesk IS the remote transport, so this is SSH-over-slopdesk. Low priority / N/A unless the remote session SSHes onward.
- **`login-greeting`** → host-side only (remote shell startup mode).
- **`quick-terminal-*`** → macOS-global hotkey drop-down; macOS client only, not iOS.
- **`dock-icon-*`** → macOS Dock only; not iOS.
- **`auto-secure-input`, `secure-input-indication`** → macOS Secure Keyboard Entry is local to the client keyboard (remote end is a separate `slopdesk-hostd`); pill can show on macOS client; not iOS (own secure-field handling).
- **`window-opacity`** → needs a local NSWindow; macOS client only, N/A iOS.
- **`background-opacity`** → local NSWindow blending; N/A iOS (UIKit has no equivalent).
- **`font-thicken`** → macOS only; skip iOS.
- **`macos-option-as-alt`** → macOS only; N/A iOS.
- **`open-with-app`, `default-git-client`, `file-open-with`, `folder-open-with`** → "open in app" needs local files but files are remote; only `link-open-with = browser` maps cleanly (URLs forwarded to client browser).
- **`zoxide-enabled`, `zoxide-local-path`** → `zoxide` runs on the host; local-binary sync N/A on client. Client has its own frecency table (Open Quickly uses it).
- **`session-log-mode = redacted`** → secret masking is host-side (raw PTY passes through `slopdesk-hostd`); client log captures only what arrives over the wire.
- **`ipc-allow-send-keys`, `ipc-allow-sensitive-sessions`** → IPC security runs on the `slopdesk-ctl` NDJSON control channel; map to `SLOPDESK_AGENT_CONTROL` permission gating.
- **`recipe-replay-*`** → `.slopdeskrecipe` files are local; paths local to client, execution on host.
- **`progress-bar-commands`** → progress injection wraps host commands via shell integration; client config must be forwarded to the host shell-rc block. Treat as host-side.
- **`session-restore-multiplayer` (tmux reattach)** → SlopDesk has its own detach/reattach via `DetachedSessionStore`; tmux reattach is orthogonal, supportable via `SLOPDESK_DETACH_ENABLED` + custom restore logic.

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
