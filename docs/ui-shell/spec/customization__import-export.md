# Import / Export

## Summary

SlopDesk reads configs from other terminals (Ghostty, Kitty, Alacritty) and writes the current SlopDesk config back out in any of those formats — for trying SlopDesk alongside an existing setup, or sharing a config with someone who hasn't switched. Access: Settings → Advanced → Config File (two action rows), or CLI (`slopdesk import` / `slopdesk export`).

## Behaviors

- A classification engine sorts every source line into one of four buckets:
  - **Supported** — same key exists; value written as-is or auto value-translated.
  - **Conflict** — same key exists but value differs; user decides per-row (overwrite / keep).
  - **Similar** — close analog exists but not auto-imported; user decides manually.
  - **Source-only** — no SlopDesk equivalent; docs links provided.
- Supported sources: **Ghostty**, **Kitty**, **Alacritty** (TOML only; Alacritty YAML unsupported).
- Import is **preview-mode by default** — nothing written until confirmed (CLI: run without flags; GUI: review summary dialog before "Apply Import").
- GUI summary dialog surfaces all four buckets; conflict rows each have a per-row dropdown (Overwrite / Keep current) plus bulk-action buttons. All keys link to the config reference docs.
- Export output is a complete drop-in for the target terminal — every target-supported key is filled; unsupported SlopDesk-only keys go to a "dropped" list (stderr in text mode, JSON in `--json` mode).
- Kitty format is space-separated `key value` with underscores; adapter converts to SlopDesk's hyphenated format on import and back on export.
- Alacritty format is TOML with nested sections flattened to dotted paths; color sections transformed to the SlopDesk palette format.
- Value translations applied automatically where semantics differ (e.g. `mouse_hide_wait` seconds → boolean; `cursor_shape beam` → `cursor-style bar`; Alacritty startup modes → SlopDesk window sizing keywords).
- SlopDesk-only keys (font fallbacks, font rendering, ligatures, sidebar/panel controls, SSH integration, autocomplete, privilege/notification settings, quick terminal, recipes, editor settings, etc.) are silently dropped on export.

### Ghostty-specific behaviors
- Default path: `~/.config/ghostty/config` (macOS: `~/Library/Application Support/com.mitchellh.ghostty/config`).
- Format: line-based `key = value`.
- Similar mappings (manual review): `mouse-shift-capture` (polarity flip), `window-padding-x/y/balance` → `ui-padding`, `window-decoration` → `auto-hide-tab-bar`, `background-blur-radius` → `background-opacity`, `unfocused-split-opacity` → `faint-opacity`, `link-url` → `link-open-with`, `confirm-close-surface` → `confirm-close-tab`, `quit-after-last-window-closed-delay` → `quit-after-last-window-closed`, `shell-integration` (enum conversion), `shell-integration-features` → `shell-integration`.

### Kitty-specific behaviors
- Default path: `~/.config/kitty/kitty.conf`.
- Font renames: `bold_font` → `font-family-bold`, `italic_font` → `font-family-italic`, `bold_italic_font` → `font-family-bold-italic`.
- `shell` and `editor` both → `command`.
- `strip_trailing_spaces` → `clipboard-trim-trailing-spaces`.
- `color0`…`color15` → `palette` (ANSI as `palette = N=#hex`).
- `mouse_hide_wait` (seconds float) → `mouse-hide-while-typing` (boolean).
- `cursor_shape beam` → `cursor-style bar`.
- Similar mappings (manual review): `window_padding_width` → `ui-padding`, `active_tab_background` → `ui-active`, `inactive_tab_background` → `ui-panel-background`, `tab_bar_edge/style` → `auto-hide-tab-bar`/`window-layout`, `scrollback_pager` → `session-log-mode`, `shell_integration` (feature list conversion), `background_blur` → `background-opacity`, `include` → `theme`, `map` → `keybind` (parsed individually), `cursor_blink_interval` / `cursor_stop_blinking_after` → `cursor-style-blink`.

### Alacritty-specific behaviors
- Default path: `~/.config/alacritty/alacritty.toml` (TOML only; YAML unsupported).
- Nested TOML sections flattened to dotted paths for matching.
- `window.startup_mode`: `Maximized` → `frame`, `Fullscreen` → `remember`.
- `cursor.style.shape`: `Beam` → `bar`.
- `cursor.thickness` maps approximately to `cursor-opacity`.
- `colors.normal.*` and `colors.bright.*` collapse into the 16-entry `palette`.
- Similar mappings (manual review): `window.padding.x/y` → `ui-padding`, `window.dimensions.columns/lines` → `window-cols`/`window-rows` (with `window-size = grid`), `window.decorations` → `auto-hide-tab-bar`, `font.builtin_box_drawing` → `arrow-box-drawing-join`, `keyboard.bindings` → `keybind` (parsed individually), `hints.enabled` → `link-open-with`, `mouse.bindings` → `right-click-action`.

## Keybindings

No dedicated keybindings. Access via Settings GUI or CLI.

| Action | Keys |
|--------|------|
| (none documented) | — |

## Config keys

Import/export exposes no runtime config keys of its own. This table lists the SlopDesk keys that serve as mapping targets.

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | system mono | Primary font family used by the terminal |
| `font-family-bold` | derived | Font family for bold text |
| `font-family-italic` | derived | Font family for italic text |
| `font-family-bold-italic` | derived | Font family for bold-italic text |
| `font-size` | system default | Font size in points |
| `font-thicken` | `false` | Thicken font strokes (macOS only) |
| `adjust-cell-height` | `0` | Adjust cell height by N pixels |
| `command` | login shell | Shell or program to launch |
| `env` | (empty) | Environment variables to set |
| `working-directory` | `~` | Initial working directory |
| `term` | `xterm-256color` | Value of the TERM environment variable |
| `scrollback-limit` | (terminal default) | Maximum scrollback lines |
| `foreground` | theme default | Default foreground color |
| `background` | theme default | Default background color |
| `selection-foreground` | theme default | Color for selected text |
| `selection-background` | theme default | Color for selection background |
| `minimum-contrast` | `1` | Minimum contrast ratio for foreground/background |
| `cursor-style` | `block` | Cursor shape: `block`, `bar`, `underline` |
| `cursor-color` | theme default | Cursor fill color |
| `cursor-text` | theme default | Text color under the cursor |
| `cursor-opacity` | `1.0` | Cursor opacity (0.0–1.0) |
| `cursor-style-blink` | `false` | Whether the cursor blinks |
| `mouse-hide-while-typing` | `true` | Hide pointer while typing |
| `mouse-scroll-multiplier` | `1.0` | Scroll speed multiplier |
| `focus-follows-mouse` | `false` | Focus pane/window under mouse pointer |
| `macos-option-as-alt` | `false` | Treat Option key as Alt |
| `clipboard-read` | `ask` | Policy for OSC 52 clipboard read |
| `clipboard-write` | `ask` | Policy for OSC 52 clipboard write |
| `clipboard-trim-trailing-spaces` | `true` | Strip trailing spaces on copy |
| `copy-on-select` | `false` | Copy to clipboard on selection |
| `clipboard-paste-protection` | `true` | Warn before pasting multi-line into prompt |
| `theme` | Monokai Pro | Color theme name or path |
| `background-opacity` | `1.0` | Window background opacity (0.0–1.0) |
| `keybind` | (built-in defaults) | Key binding entries (repeatable) |
| `kitty-keyboard` | `false` | Enable Kitty keyboard protocol |
| `palette` | theme default | Override ANSI palette color: `palette = N=#hex` |
| `link-previews` | `true` | Show link hover previews |
| `ui-padding` | `8` | Unified window padding in points |
| `auto-hide-tab-bar` | `false` | Hide tab bar when only one tab is open |
| `faint-opacity` | `0.5` | Opacity multiplier for unfocused panes |
| `link-open-with` | system default | Application to open URLs |
| `confirm-close-tab` | `true` | Prompt before closing a tab with a running process |
| `quit-after-last-window-closed` | `true` | Quit the app when the last window closes |
| `shell-integration` | `detect` | Shell integration mode: `detect`, `fish`, `zsh`, `bash`, `none` |
| `mouse-shift-to-select` | `false` | Shift+click extends selection even when app captures mouse |
| `title-report` | `true` | Allow programs to set the window title |
| `scrollback-lines` | `10000` | Scrollback buffer size in lines |
| `session-log-mode` | `off` | Session transcript logging mode |
| `window-cols` | `80` | Initial window width in columns (when `window-size = grid`) |
| `window-rows` | `24` | Initial window height in rows (when `window-size = grid`) |
| `arrow-box-drawing-join` | `true` | Join arrow/box drawing characters at cell borders |
| `right-click-action` | `context-menu` | Behavior on right-click |
| `ui-active` | theme default | Active tab background color |
| `ui-panel-background` | theme default | Inactive tab / panel background color |
| `window-layout` | `tabs` | Window layout mode |

## Visual spec

### settings-import-export.png

**Overall layout:** Standard macOS two-column preferences window, white/light-gray background, rounded corners, outer drop shadow. Traffic-light controls top-left (red, gray, gray — minimize gray not yellow, likely inactive).

**Left sidebar (nav column, ~310 pt wide):**
- Search field at top: rounded rectangle, light gray fill (#EBEBEB approx.), magnifying glass icon, gray "Search" placeholder.
- Nav items below, vertically stacked, left-aligned icon + label, no separators:
  - General (clock/timer), Shell (`>_`), Controls (cursor/arrow), Editor (document), Agents (plug/lightning), Appearance (palette/color wheel), Recipes (book), Key Bindings (lightning bolt).
  - **Advanced** (wrench) — selected, medium-gray rounded-rect highlight spanning full row width.
- All nav items: system-weight (~regular) SF Pro, ~13–14 pt.

**Right content area (detail column):**
- Section header "CONFIG FILE" — small-caps gray uppercase (~11 pt, ~#8A8A8E), top-left.
- White card/list group, rows separated by hairline dividers:
  - **Path**: label left; value `~/.config/slopdesk/config.toml` right, gray.
  - **Open Config File**: label left; "Open Config File" button right (gray ~#EBEBEB, dark text, ~6 pt radius, standard macOS style).
  - **Reload Config**: label left; "Reload Config" button right, same style.
  - **Import from another terminal**: label left; pill "Import" with chevron-down (▾) right — a **split/menu button** (button + dropdown).
  - **Export to another terminal**: label left; (Export button partially obscured by open dropdown).
- Import/Export section highlighted with a **red rounded-rect border** (~2 pt stroke, rounded corners matching card, #FF3B30 or similar) — a docs callout/annotation, not real UI state.
- **Import dropdown menu** open, floating below "Import ▾" — standard macOS popover, white background, hairline border:
  - Three items vertical: "Ghostty", "Kitty", "Alacritty" — regular ~13 pt dark text, no icons, ~22–24 pt row height. None highlighted.
- **DEBUG section** below (partially occluded by menu):
  - Header "DEBUG", same small-caps gray.
  - **Debug Mode**: label left; toggle right, **ON** (green #34C759, thumb right).
  - **Debug Log**: label left; "Open Log File" button right.
- **ALL SETTINGS section** at bottom:
  - Header "ALL SETTINGS", same small-caps gray.
  - Full-width search field, gray "Search" placeholder.

**Typography:**
- Row labels: SF Pro, ~13–14 pt, near-black (#1C1C1E).
- Section headers: SF Pro, ~11 pt, gray (#8A8A8E), uppercase, letter-spaced.
- Value text (e.g. path): SF Pro, ~13 pt, gray (#636366).
- Buttons: SF Pro, ~13 pt, dark text on light-gray.

**Spacing:**
- Row height: ~44 pt (standard macOS preferences).
- Horizontal padding within rows: ~16–20 pt from content edge.
- Section header to first row: ~8 pt. Between sections: ~16–20 pt.

**Color palette:**
- Window background: #F5F5F5. Content card: #FFFFFF.
- Selected nav highlight: #D1D1D6. Toggle on-state: #34C759.
- Red annotation border: #FF3B30 (docs callout only). Button backgrounds: #EBEBEB.

## Screenshots

- `settings-import-export.png`

## SlopDesk mapping notes

### Maps cleanly (1:1)

- **Settings UI location:** The two-row group (Import / Export) with a source picker dropdown maps directly to a macOS SwiftUI `Form`/`List` section in Settings → Advanced.
- **Classification engine:** The four-bucket engine is pure logic, no platform dependency; implement in `SlopDeskWorkspaceCore` or a dedicated `ConfigImportEngine` type.
- **CLI commands:** `slopdesk import` / `slopdesk export`, flags `--overwrite`, `--keep`, `--json`, `-o`. `--json` follows slopdesk's structured output conventions.
- **Ghostty format:** Line-based `key = value` parsing is straightforward Swift; the default path (`~/Library/Application Support/com.mitchellh.ghostty/config`) is readable on macOS without extra entitlements.
- **Kitty / Alacritty parsing:** Space-separated and TOML respectively; Alacritty needs a TOML parser (e.g. `TOMLKit` SPM). Both are local reads.
- **Value translation table:** All translations (seconds→boolean, shape enums, startup modes) are pure value mapping, no OS dependency.
- **Export drop list:** stderr (text) or JSON — maps to `FileHandle.standardError` / structured JSON.
- **Conflict resolution UI:** Summary sheet/modal with per-row Overwrite/Keep dropdowns + bulk actions = standard SwiftUI `List` + `Picker`.

### Requires adaptation

- **`working-directory` on remote host:** SlopDesk sessions run on a REMOTE macOS host; the value is a HOST path, not the local client. On import, UI should clarify host interpretation. The config file lives on the client (or synced); directory resolution is remote.
- **`command` / `shell`:** Launched on the remote host. A local-only binary path silently fails on the remote — surface a warning in "Similar" or "Source-only" when importing.
- **`background-opacity` / `background-blur-radius`:** Window opacity/blur apply to the CLIENT window, not remote host content; map to client-side rendering (`TerminalRenderingView`), not over the wire. Apply to CLIENT config; summary dialog should note "applied locally."
- **`link-open-with` / `link-previews`:** Link opening is client-side (client machine opens URLs), so imported value applies locally. Consistent, but worth noting.
- **`macos-option-as-alt`:** macOS-only; maps to client-side key event translation. Not applicable on iOS — mark client-platform-conditional.
- **`font-*` keys:** Font rendering is by libghostty on the CLIENT (via `TerminalSurface`). Importing from Ghostty is highest-fidelity since slopdesk uses libghostty. Imported font names must exist on the CLIENT.
- **`theme`:** SlopDesk uses `ThemeStore`, default Monokai Pro. Ghostty theme names aren't directly compatible; only `palette` (16 ANSI colors) and named color keys import faithfully. Mark `theme` as "Similar" (manual review), not "Supported".
- **`kitty-keyboard`:** PTY/mux layer must propagate the flag to the host PTY — a wire-level feature. Flag as "Similar / manual" until confirmed in the slopdesk mux.
- **`clipboard-read` / `clipboard-write` (OSC 52):** OSC 52 in a remote terminal needs explicit proxying. SlopDesk's clipboard policy is client-side; mapping is valid but semantics differ (CLIENT permission, not host). Note in docs.
- **`scrollback-limit` / `scrollback-lines`:** The slopdesk replay buffer (64 MiB ceiling) and libghostty scrollback are separate. Imported value applies to libghostty scrollback on the CLIENT. Clarify in summary dialog.
- **iOS client:** macOS-only keys with no iOS equivalent — `macos-option-as-alt`, `background-blur-radius` (no window blur on iOS), `focus-follows-mouse`, `mouse-*` — should be "Source-only" or suppressed in iOS Settings. Surface Import/Export in macOS Settings only (or per-platform filtering).
- **Config file location:** SlopDesk's config is at `~/.config/slopdesk/config.toml` (per screenshot), on the CLIENT. The Config File section (Path, Open Config File, Reload Config) is part of this same screen.
- **No SSH badge / remote indicator:** Ghostty, Kitty, Alacritty are local; slopdesk sessions are remote. The UI needs no remote-specific badge, but error states (e.g. "command path not found on host") should distinguish client-side vs host-side resolution failures.
