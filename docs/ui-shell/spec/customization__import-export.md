# Import / Export

## Summary

SlopDesk can read configs from other terminals (Ghostty, Kitty, Alacritty) and write the current SlopDesk config back out in any of those formats. Useful when trying SlopDesk alongside an existing setup, or when sharing a configuration with someone who has not switched. Access is via Settings → Advanced → Config File (two action rows) or via the CLI (`slopdesk import` / `slopdesk export`).

## Behaviors

- A classification engine categorises every line in the source config into one of four buckets:
  - **Supported** — SlopDesk has the same key; value written as-is or value-translated automatically.
  - **Conflict** — Same key exists in SlopDesk but the current value differs; user decides per-row whether to overwrite or keep.
  - **Similar** — SlopDesk has a close analog but it is not auto-imported; user decides manually.
  - **Source-only** — Source terminal feature with no SlopDesk equivalent; docs links are provided.
- Three source terminals are supported: **Ghostty**, **Kitty**, **Alacritty** (TOML only; Alacritty YAML not supported).
- Import operates in **preview mode by default** — no changes are written until the user confirms (CLI: running without flags; GUI: reviewing the summary dialog before tapping "Apply Import").
- In the GUI flow the summary dialog surfaces all four buckets; conflict rows each have a per-row dropdown (Overwrite / Keep current) plus bulk-action buttons.
- All keys in the summary dialog include links to the configuration reference docs.
- On export, the output file is a complete drop-in for the target terminal — SlopDesk fills every key the target supports; unsupported SlopDesk-only keys go into a "dropped" list (printed to stderr in text mode, returned as JSON in `--json` mode).
- Kitty format uses space-separated `key value` with underscores; the adapter converts to SlopDesk's hyphenated format on import and back on export.
- Alacritty format is TOML with nested sections flattened to dotted paths; color sections are transformed to the SlopDesk palette format.
- Value translations are performed automatically where semantics differ (e.g. `mouse_hide_wait` seconds → boolean; `cursor_shape beam` → `cursor-style bar`; Alacritty startup modes → SlopDesk window sizing keywords).
- SlopDesk-only keys (font fallbacks, font rendering, ligatures, sidebar/panel controls, SSH integration, autocomplete, privilege/notification settings, quick terminal, recipes, editor settings, etc.) are silently dropped on export to any external terminal.

### Ghostty-specific behaviors
- Default path: `~/.config/ghostty/config` (macOS: `~/Library/Application Support/com.mitchellh.ghostty/config`).
- Format: line-based `key = value`.
- Similar mappings that require manual review: `mouse-shift-capture` (polarity flip), `window-padding-x/y/balance` → `ui-padding`, `window-decoration` → `auto-hide-tab-bar`, `background-blur-radius` → `background-opacity`, `unfocused-split-opacity` → `faint-opacity`, `link-url` → `link-open-with`, `confirm-close-surface` → `confirm-close-tab`, `quit-after-last-window-closed-delay` → `quit-after-last-window-closed`, `shell-integration` (enum conversion), `shell-integration-features` → `shell-integration`.

### Kitty-specific behaviors
- Default path: `~/.config/kitty/kitty.conf`.
- Font key renames: `bold_font` → `font-family-bold`, `italic_font` → `font-family-italic`, `bold_italic_font` → `font-family-bold-italic`.
- `shell` and `editor` both map to `command`.
- `strip_trailing_spaces` → `clipboard-trim-trailing-spaces`.
- `color0`…`color15` → `palette` (ANSI colors as `palette = N=#hex`).
- `mouse_hide_wait` (seconds float) is translated to `mouse-hide-while-typing` (boolean).
- `cursor_shape beam` → `cursor-style bar`.
- Similar mappings requiring manual review include: `window_padding_width` → `ui-padding`, `active_tab_background` → `ui-active`, `inactive_tab_background` → `ui-panel-background`, `tab_bar_edge/style` → `auto-hide-tab-bar`/`window-layout`, `scrollback_pager` → `session-log-mode`, `shell_integration` (feature list conversion), `background_blur` → `background-opacity`, `include` → `theme`, `map` → `keybind` (parsed individually), `cursor_blink_interval` / `cursor_stop_blinking_after` → `cursor-style-blink`.

### Alacritty-specific behaviors
- Default path: `~/.config/alacritty/alacritty.toml` (TOML only; YAML not supported).
- Nested TOML sections are flattened to dotted paths for matching.
- `window.startup_mode`: `Maximized` → `frame`, `Fullscreen` → `remember`.
- `cursor.style.shape`: `Beam` → `bar`.
- `cursor.thickness` maps approximately to `cursor-opacity`.
- `colors.normal.*` and `colors.bright.*` collapse into the 16-entry `palette`.
- Similar mappings requiring manual review: `window.padding.x/y` → `ui-padding`, `window.dimensions.columns/lines` → `window-cols`/`window-rows` (with `window-size = grid`), `window.decorations` → `auto-hide-tab-bar`, `font.builtin_box_drawing` → `arrow-box-drawing-join`, `keyboard.bindings` → `keybind` (parsed individually), `hints.enabled` → `link-open-with`, `mouse.bindings` → `right-click-action`.

## Keybindings

No dedicated keybindings are documented for this feature. All access is via the Settings GUI or the CLI.

| Action | Keys |
|--------|------|
| (none documented) | — |

## Config keys

The import/export feature does not expose runtime config keys of its own. The table below captures the keys relevant to interoperability — specifically the SlopDesk keys that serve as the mapping targets.

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

**Overall layout:** Standard macOS two-column preferences window with a white/light-gray background and rounded corners. A drop shadow is visible on the outer window. Traffic-light window controls (red, gray, gray — minimize is gray not yellow, likely already inactive) appear top-left.

**Left sidebar (navigation column, ~310 pt wide):**
- Search field at the top: rounded rectangle, light gray fill (#EBEBEB approx.), magnifying glass icon, placeholder text "Search" in gray.
- Navigation items below in a vertically stacked list with left-aligned icon + label pairs, no separator lines:
  - General (clock/timer icon)
  - Shell (prompt `>_` icon)
  - Controls (cursor/arrow icon)
  - Editor (document icon)
  - Agents (plug/lightning bolt icon)
  - Appearance (palette/color wheel icon)
  - Recipes (book icon)
  - Key Bindings (lightning bolt icon)
  - **Advanced** (wrench icon) — currently selected, shown with a medium-gray rounded-rectangle highlight spanning the full row width.
- All nav items use system-weight (~regular) SF Pro text, approximately 13–14 pt.

**Right content area (detail column):**
- Section header "CONFIG FILE" in small-caps gray uppercase label (~11 pt, color approx. #8A8A8E) at the top, left-aligned.
- Below the header, a white card/list group with individual rows separated by hairline dividers:
  - **Path** row: label "Path" left-aligned; value `~/.config/slopdesk/config.toml` right-aligned in gray text.
  - **Open Config File** row: label "Open Config File" left-aligned; a rounded-rectangle button "Open Config File" right-aligned (gray background, ~#EBEBEB, dark text, ~6 pt radius, standard macOS button style).
  - **Reload Config** row: label "Reload Config" left-aligned; "Reload Config" button right-aligned, same button style.
  - **Import from another terminal** row: label left-aligned; a pill/button labeled "Import" with a chevron-down (▾) right-aligned — this is a **split button or menu button** (the button + dropdown together).
  - **Export to another terminal** row: label left-aligned; (Export button partially obscured by the open dropdown).
- The Import/Export section is visually highlighted with a **red rounded-rectangle border** (approx. 2 pt stroke, rounded corners matching the card, color #FF3B30 or similar red) — this appears to be a documentation callout/annotation added to the screenshot, not a real UI state.
- The **Import dropdown menu** is open and floating below the "Import ▾" button. The dropdown is a standard macOS popover/menu with a white background and a hairline border:
  - Three items listed vertically: "Ghostty", "Kitty", "Alacritty" — each in regular weight ~13 pt dark text, no icons, standard menu row height (~22–24 pt).
  - No item is highlighted/selected in this screenshot state.
- **DEBUG section** is visible below (partially occluded by the menu):
  - Section header "DEBUG" in same small-caps gray style.
  - **Debug Mode** row: label left-aligned; a toggle switch right-aligned, currently **ON** (green fill, thumb to the right — standard iOS/macOS toggle style, green #34C759).
  - **Debug Log** row: label left-aligned; "Open Log File" button right-aligned.
- **ALL SETTINGS section** at the bottom:
  - Section header "ALL SETTINGS" in same small-caps gray.
  - A search field spanning the full width, placeholder text "Search" in gray.

**Typography:**
- Row labels: SF Pro, ~13–14 pt, near-black (#1C1C1E or similar).
- Section headers: SF Pro, ~11 pt, gray (#8A8A8E), uppercase, letter-spaced.
- Value text (e.g. path): SF Pro, ~13 pt, gray (#636366).
- Buttons: SF Pro, ~13 pt, dark text on light-gray background.

**Spacing:**
- Row height: approximately 44 pt each (standard macOS preferences row height).
- Horizontal padding within rows: ~16–20 pt from edge of content area.
- Section header to first row gap: ~8 pt.
- Between sections: ~16–20 pt.

**Color palette visible:**
- Window background: #F5F5F5 (light gray system background).
- Content card background: #FFFFFF.
- Selected nav item highlight: medium gray #D1D1D6 rounded rectangle.
- Toggle on-state: #34C759 (system green).
- Red annotation border: #FF3B30 (system red) — docs callout only.
- Button backgrounds: #EBEBEB.

## Screenshots

- `settings-import-export.png`

## SlopDesk mapping notes

### Maps cleanly (1:1)

- **Settings UI location:** SlopDesk's Settings → Advanced (or equivalent) panel can host Import/Export rows exactly as shown. The two-row group (Import from another terminal / Export to another terminal) with a source picker dropdown maps directly to a macOS SwiftUI `Form`/`List` section.
- **Classification engine:** The four-bucket engine (Supported / Conflict / Similar / Source-only) is pure logic with no platform dependency; implement in `SlopDeskWorkspaceCore` or a dedicated `ConfigImportEngine` type.
- **CLI commands:** `slopdesk import` / `slopdesk export` subcommands, with flags `--overwrite`, `--keep`, `--json`, `-o`. The `--json` mode follows slopdesk's existing structured output conventions.
- **Ghostty config format:** Line-based `key = value` parsing is straightforward Swift; the default Ghostty path (`~/Library/Application Support/com.mitchellh.ghostty/config`) is accessible on macOS without entitlements beyond file read.
- **Kitty / Alacritty config parsing:** Space-separated and TOML formats respectively; a TOML parser (e.g. via `TOMLKit` SPM package) is needed for Alacritty. Both files are local reads.
- **Value translation table:** All translations documented (seconds→boolean, shape enums, startup modes) are pure value mapping with no OS dependencies.
- **Export drop list:** Printed to stderr (text mode) or included in JSON — maps directly to Swift's `FileHandle.standardError` / structured JSON output.
- **Conflict resolution UI:** A summary sheet/modal with per-row Overwrite/Keep dropdowns and bulk actions is a standard SwiftUI `List` + `Picker` composition.

### Requires adaptation

- **`working-directory` on a remote host:** SlopDesk sessions run on a REMOTE macOS host; the `working-directory` key's value is a path on the HOST, not the local client machine. On import, the UI should clarify that this path is interpreted on the host. The config file itself lives on the client (or synced), but the directory resolution happens remotely.
- **`command` / `shell` key:** The shell or program launched is on the remote host. If the imported config references a local-only binary path, it will silently fail on the remote. A warning should be surfaced in the "Similar" or "Source-only" bucket when importing this key.
- **`background-opacity` / `background-blur-radius`:** Window-level opacity and blur on macOS are applied to the client window, not the remote host terminal content. These map to slopdesk client-side rendering properties (via `TerminalRenderingView`), not to anything sent over the wire. The imported value should be applied to the CLIENT config, and the summary dialog should note "applied locally."
- **`link-open-with` / `link-previews`:** Link opening is a client-side action (the client machine opens URLs), so the imported value applies to the local client. This is consistent but worth noting in the mapping notes.
- **`macos-option-as-alt`:** macOS-only; maps to the client-side key event translation layer (slopdesk's input handling). Not applicable on the iOS client — mark as client-platform-conditional.
- **`font-*` keys:** Font rendering is performed by libghostty on the CLIENT side (via `TerminalSurface`). Importing font keys from Ghostty's own config is the highest-fidelity mapping since slopdesk uses libghostty. The imported font names must be available on the CLIENT machine.
- **`theme` key:** SlopDesk uses `ThemeStore` with Monokai Pro as default. Ghostty theme names are not directly compatible; only the `palette` (16 ANSI colors) and named color keys can be faithfully imported. Mark `theme` as "Similar" (manual review) rather than "Supported" in the slopdesk import engine.
- **`kitty-keyboard` protocol:** SlopDesk's PTY/mux layer would need to propagate the Kitty keyboard protocol flag to the host PTY. This is a wire-level feature — flag as "Similar / manual" until the protocol is confirmed supported in the slopdesk terminal mux.
- **`clipboard-read` / `clipboard-write` (OSC 52):** OSC 52 clipboard access in a remote terminal requires explicit proxying. SlopDesk's clipboard policy lives client-side; the mapping is valid but the behavior semantics differ (it is a CLIENT permission, not a host permission). Note in docs.
- **`scrollback-limit` / `scrollback-lines`:** The slopdesk replay buffer (64 MiB ceiling) and the libghostty scrollback are separate. The imported value applies to the libghostty scrollback on the CLIENT rendering side. Clarify in the summary dialog.
- **iOS client:** Several keys are macOS-only and have no iOS equivalent: `macos-option-as-alt`, `background-blur-radius` (no window blur on iOS), `focus-follows-mouse`, `mouse-*` keys. These should be marked "Source-only" or suppressed in the iOS Settings UI. The Import/Export GUI should be surfaced in the macOS Settings only (or with per-platform filtering).
- **Config file location:** SlopDesk's own config file is at `~/.config/slopdesk/config.toml` (per the screenshot). This lives on the CLIENT machine. The Settings → Advanced → Config File section with Path, Open Config File, Reload Config rows is part of this same screen.
- **No SSH badge / remote indicator:** Ghostty, Kitty, and Alacritty are all local terminals; slopdesk sessions are remote. The Import/Export UI itself needs no remote-specific badge, but error states (e.g. "command path not found on host") should distinguish client-side vs host-side resolution failures.
