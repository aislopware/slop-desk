# Theme Format

## Summary

Theme files live at `~/.config/slopdesk/themes/<name>.slopdesktheme` and use **real TOML** format (unlike the main config file, which uses a custom flat format). Only the `[terminal]` section is required; all other sections are optional. Themes can inherit from other themes to allow partial overrides. Activated by setting `theme = <name>` in the main config.

## Behaviors

- Theme files are stored in `~/.config/slopdesk/themes/` with the `.slopdesktheme` extension and file name matching the theme name.
- Theme files use **TOML** format (real TOML, not the custom config format used by the main config file).
- Only `[terminal]` is required; `[ui]`, `[selection]`, `[cursor]`, and `[ghost]` are all optional.
- `[terminal].cursor` falls back to `foreground` color if omitted.
- `[terminal].selection-foreground` and `[terminal].selection-background` are legacy keys — the preferred way is the `[selection]` section.
- `[ui]` controls window frame, tab sidebar, and command palette tint via `title-bar-bg`, `tab-bar-bg`, `tab-active-bg`, `tab-active-fg`, and `sidebar-divider`.
- `[cursor].style` accepts exactly three values: `block`, `underline`, or `beam`.
- `[cursor].blink` is a boolean.
- `[ghost]` styles autocomplete ghost text (inline predictive completion) with a `foreground` color only.
- Theme inheritance: add `inherits = "<theme-name>"` at the top level to derive from a built-in or user theme; only keys explicitly present in the inheriting file override the parent — all others remain from the parent theme. Useful for tweaking a built-in theme without restating all 16 palette entries.
- To activate a theme, set `theme = <name>` (without the `.slopdesktheme` extension) in the main config file.
- `palette` is an array of exactly 16 ANSI color strings (indices 0–15): 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white, 8-15=bright variants of the same order.

## Keybindings

No keybindings are defined by the theme format reference. Theme selection/switching is done via the config file (`theme = <name>`), not via keyboard shortcuts on this page.

| Action | Keys |
|--------|------|
| (none defined on this page) | — |

## Config keys

### `[terminal]` — required

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | (required) | Default text colour for the terminal |
| `background` | (required) | Default background colour for the terminal |
| `palette` | (required) | Array of 16 ANSI color strings (indices 0–15) |
| `cursor` | falls back to `foreground` | Cursor block color |
| `cursor-text` | — | Foreground color while the cursor is active (text under cursor) |
| `selection-foreground` | — | Legacy: selection foreground color (prefer `[selection]` section) |
| `selection-background` | — | Legacy: selection background color (prefer `[selection]` section) |

### `[ui]` — optional, UI chrome

| Key | Default | Effect |
|-----|---------|--------|
| `title-bar-bg` | — | Background color of the title bar |
| `tab-bar-bg` | — | Background color of the tab/sidebar bar |
| `tab-active-bg` | — | Background color of the active tab |
| `tab-active-fg` | — | Foreground/text color of the active tab |
| `sidebar-divider` | — | Color of the divider line in the sidebar |

### `[selection]` — optional

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | — | Text color of selected content |
| `background` | — | Background color of selected content |

### `[cursor]` — optional

| Key | Default | Effect |
|-----|---------|--------|
| `color` | — | Cursor color |
| `style` | — | Cursor shape: `block`, `underline`, or `beam` |
| `blink` | — | Boolean; enables/disables cursor blinking |

### `[ghost]` — optional, autocomplete ghost text

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | — | Color of autocomplete ghost/suggestion text |

### Top-level inheritance key

| Key | Default | Effect |
|-----|---------|--------|
| `inherits` | — | Name of another theme to inherit from; only keys present in this file override the parent |

## Visual spec

This page contains no screenshots. It is a pure TOML schema reference page with code blocks only. The only images on the page are the site logo (`otty-icon.png`, the app's reference icon asset). No UI visual states, no layout diagrams, no color swatches shown.

The minimal example code block (`midnight.slopdesktheme`) reveals the expected color palette style: 8 dark/normal colors followed by 8 bright colors, expressed as hex strings `"#rrggbb"`. The example palette uses a dark indigo/navy aesthetic (background `#0a0a14`, foreground `#e0e0ff`), which matches the Monokai Pro / dark terminal aesthetic.

## Screenshots

(none — this reference page has no screenshots)

## Implementation notes

### Direct implementation

- **`[terminal].foreground` / `background` / `palette`**: Map directly to libghostty's terminal color configuration. Ghostty's config accepts these as `foreground`, `background`, and `palette = N=<hex>` entries. The `TerminalConfigBuilder` override path in `SlopDeskTerminal` should forward all 16 palette entries plus fg/bg when the user selects a theme. Already partially implemented per `resolveTerminalColors` in the Monokai Pro work.
- **`[terminal].cursor` / `cursor-text`**: Map to ghostty's `cursor-color` and `cursor-text` config keys. Pass through `TerminalConfigBuilder`.
- **`[terminal].cursor` + `[cursor].style` / `blink`**: ghostty supports `cursor-style = block|underline|bar` and `cursor-style-blink = true|false`. The `beam` style in this spec maps to `bar` in ghostty.
- **`[selection].foreground` / `background`**: Map to ghostty's `selection-foreground` and `selection-background` config keys.
- **`[ghost].foreground`**: Maps to ghostty's `unfocused-split-opacity` or custom ghost-text styling. Ghostty has native support for suggestion/ghost text foreground color.

### UI chrome keys (`[ui]`)

- **`title-bar-bg`**: In slopdesk, the macOS title bar background is controlled by `NSWindowAppearance` and SwiftUI window chrome. Can be approximated by setting window background + `titlebarAppearsTransparent`. The `SlateDesign` token `ThemeStore` can map this value.
- **`tab-bar-bg`** / **`tab-active-bg`** / **`tab-active-fg`**: Map to slopdesk's sidebar/tab-bar styling in the `SlopDeskClientUI` SwiftUI layer. The `ThemeStore` and `SlateDesign` token system already handles sidebar background — `tab-bar-bg` → sidebar background color, `tab-active-bg` → active pane highlight background, `tab-active-fg` → active pane label color.
- **`sidebar-divider`**: Maps to the `NSSplitView` divider / `DividerHandle` stroke color already present in the slopdesk workspace. The faint split divider introduced in the recent theme-aware work is exactly this key.

### Inheritance

- **`inherits`**: SlopDesk's `ThemeStore` would need to implement a two-pass load: first load the parent theme, then overlay the child's keys. Since slopdesk currently ships a fixed set of built-in Monokai Pro filters via `monokai(MonokaiSeed)`, inheritance is primarily needed if user-custom themes are supported in a future iteration. For now, hardcoding the 6 Monokai seeds with their full palettes is sufficient — no inheritance chain needed yet.

### Constraints from the remote-host architecture

- **File location `~/.config/slopdesk/themes/`**: SlopDesk is a remote tool. The host's config/theme files live on the macOS host, but the terminal UI is rendered on the client. Theme config is currently resolved client-side via `ThemeStore` + `PreferencesStore`. If user-custom `.slopdesktheme` files are supported, they should be stored on the **client** device (e.g. `~/Library/Application Support/SlopDesk/themes/` on macOS, or in-app bundle on iOS), not on the remote host. Remote-host theme files would require syncing over the slopdesk wire, which is out of scope for now.
- **`.slopdesktheme` TOML files**: SlopDesk currently has no TOML parser. Adding `swift-toml` or a vendored TOML library would be needed to support user-authored theme files. Baking themes as Swift structs (as done for the Monokai Pro seeds) avoids this dependency for now.
- **iOS**: iOS has no title bar (`title-bar-bg` does not apply). Tab/sidebar concepts differ — iOS uses a different pane-chooser UI. The `[ui]` chrome keys need platform-conditional handling.
- **`[ghost].foreground` on iOS**: Ghost/autocomplete text in the terminal is rendered by libghostty; the iOS build includes libghostty so this should work, but must be verified after the ghostty xcframework iOS build.
