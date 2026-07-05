# Theme Format

## Summary

Theme files live at `~/.config/slopdesk/themes/<name>.slopdesktheme` and use **real TOML** (unlike the main config's custom flat format). Only `[terminal]` is required; all other sections are optional. Themes can `inherit` to allow partial overrides. Activate by setting `theme = <name>` in the main config.

## Behaviors

- Stored in `~/.config/slopdesk/themes/`, `.slopdesktheme` extension, file name = theme name.
- Real **TOML** format (not the main config's custom format).
- Required: `[terminal]`. Optional: `[ui]`, `[selection]`, `[cursor]`, `[ghost]`.
- `[terminal].cursor` falls back to `foreground` if omitted.
- `[terminal].selection-foreground` / `selection-background` are legacy — prefer the `[selection]` section.
- `[ui]` controls window frame, tab sidebar, and command-palette tint via `title-bar-bg`, `tab-bar-bg`, `tab-active-bg`, `tab-active-fg`, `sidebar-divider`.
- `[cursor].style` accepts exactly: `block`, `underline`, `beam`. `[cursor].blink` is boolean.
- `[ghost]` styles autocomplete ghost text (inline predictive completion) — `foreground` only.
- Inheritance: top-level `inherits = "<theme-name>"` derives from a built-in or user theme; only keys present in the child override the parent (rest inherited). Lets you tweak a built-in without restating all 16 palette entries.
- Activate: `theme = <name>` (no `.slopdesktheme` extension) in the main config.
- `palette` = exactly 16 ANSI color strings (0–15): 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white, 8–15=bright variants in the same order.

## Keybindings

None. Theme selection/switching is via the config file (`theme = <name>`), not keyboard shortcuts.

| Action | Keys |
|--------|------|
| (none defined on this page) | — |

## Config keys

### `[terminal]` — required

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | (required) | Default text colour |
| `background` | (required) | Default background colour |
| `palette` | (required) | Array of 16 ANSI color strings (0–15) |
| `cursor` | falls back to `foreground` | Cursor block color |
| `cursor-text` | — | Foreground of text under the cursor |
| `selection-foreground` | — | Legacy: selection foreground (prefer `[selection]`) |
| `selection-background` | — | Legacy: selection background (prefer `[selection]`) |

### `[ui]` — optional, UI chrome

| Key | Default | Effect |
|-----|---------|--------|
| `title-bar-bg` | — | Title bar background |
| `tab-bar-bg` | — | Tab/sidebar bar background |
| `tab-active-bg` | — | Active tab background |
| `tab-active-fg` | — | Active tab text |
| `sidebar-divider` | — | Sidebar divider line color |

### `[selection]` — optional

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | — | Selected text color |
| `background` | — | Selected background color |

### `[cursor]` — optional

| Key | Default | Effect |
|-----|---------|--------|
| `color` | — | Cursor color |
| `style` | — | Shape: `block`, `underline`, or `beam` |
| `blink` | — | Boolean; enable/disable blinking |

### `[ghost]` — optional, autocomplete ghost text

| Key | Default | Effect |
|-----|---------|--------|
| `foreground` | — | Autocomplete ghost/suggestion text color |

### Top-level inheritance key

| Key | Default | Effect |
|-----|---------|--------|
| `inherits` | — | Theme to inherit from; only keys present in this file override the parent |

## Visual spec

No screenshots — pure TOML schema reference, code blocks only. Only image is the site logo (`otty-icon.png`). No UI states, layout diagrams, or color swatches.

The minimal example (`midnight.slopdesktheme`) shows the palette style: 8 dark/normal + 8 bright colors as hex `"#rrggbb"`, dark indigo/navy aesthetic (background `#0a0a14`, foreground `#e0e0ff`), matching the Monokai Pro / dark terminal look.

## Screenshots

(none)

## Implementation notes

### Direct implementation

- **`[terminal].foreground` / `background` / `palette`**: map to libghostty color config (`foreground`, `background`, `palette = N=<hex>`). `TerminalConfigBuilder` in `SlopDeskTerminal` forwards all 16 palette entries + fg/bg on theme select. Partially implemented via `resolveTerminalColors` (Monokai Pro work).
- **`[terminal].cursor` / `cursor-text`**: map to ghostty `cursor-color` / `cursor-text` via `TerminalConfigBuilder`.
- **`[cursor].style` / `blink`**: ghostty `cursor-style = block|underline|bar` and `cursor-style-blink = true|false`. Spec's `beam` maps to ghostty `bar`.
- **`[selection].foreground` / `background`**: map to ghostty `selection-foreground` / `selection-background`.
- **`[ghost].foreground`**: maps to ghostty `unfocused-split-opacity` or custom ghost-text styling; ghostty has native suggestion/ghost-text foreground support.

### UI chrome keys (`[ui]`)

- **`title-bar-bg`**: macOS title bar is `NSWindowAppearance` + SwiftUI chrome; approximate via window background + `titlebarAppearsTransparent`. Mappable by `SlateDesign`'s `ThemeStore`.
- **`tab-bar-bg` / `tab-active-bg` / `tab-active-fg`**: map to `SlopDeskClientUI` sidebar/tab-bar styling; `ThemeStore` + `SlateDesign` already handle sidebar background — `tab-bar-bg` → sidebar background, `tab-active-bg` → active pane highlight, `tab-active-fg` → active pane label.
- **`sidebar-divider`**: maps to the `NSSplitView` divider / `DividerHandle` stroke already present — the faint split divider from recent theme-aware work.

### Inheritance

- **`inherits`**: needs a two-pass load in `ThemeStore` — load parent, overlay child keys. SlopDesk currently ships fixed built-in Monokai Pro filters via `monokai(MonokaiSeed)`; inheritance is only needed once user-custom themes are supported. For now, hardcoding the 6 Monokai seeds with full palettes suffices — no inheritance chain yet.

### Constraints from the remote-host architecture

- **File location**: SlopDesk is remote — host config/theme files live on the macOS host, but the terminal UI renders on the client. Theme config is resolved client-side via `ThemeStore` + `PreferencesStore`. User-custom `.slopdesktheme` files should be stored on the **client** (`~/Library/Application Support/SlopDesk/themes/` on macOS, or in-app bundle on iOS), not the remote host — host-side theme files would require syncing over the wire, out of scope for now.
- **TOML parsing**: SlopDesk has no TOML parser. Supporting user-authored theme files needs `swift-toml` or a vendored TOML lib. Baking themes as Swift structs (as done for Monokai Pro seeds) avoids the dependency for now.
- **iOS**: no title bar (`title-bar-bg` N/A); tab/sidebar differ (iOS uses a different pane-chooser). `[ui]` keys need platform-conditional handling.
- **`[ghost].foreground` on iOS**: rendered by libghostty, which is in the iOS build, so it should work — verify after the ghostty xcframework iOS build.
