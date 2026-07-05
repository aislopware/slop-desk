# Themes

## Summary

Pick, switch, and write themes. SlopDesk ships a light/dark theme pair that follows OS appearance, supports custom `.slopdesktheme` TOML files, and imports from five terminal formats (SlopDesk, iTerm2, Kitty, Alacritty, Ghostty). Switching is live — no restart. Built-in defaults: Paper (light), Nord (dark).

## Behaviors

- Switch a theme from: Main menu → View → Themes; Command Palette (type "Theme" or a theme name); Settings Panel → Appearance → Themes; CLI (`slopdesk theme list` / `slopdesk theme set <theme>`); or a `theme = <theme>` row in `config.toml`.
- Auto light/dark switching is ON by default, applied live without restart.
- Two slots: `theme` (light, default Paper) and `theme-dark` (dark, default Nord).
- Settings Panel → Appearance → Themes shows a picker for the light slot; toggling "Use separated theme for dark mode" reveals a Dark Theme picker for the dark slot. With the toggle OFF, `theme` is used regardless of OS appearance.
- Add a custom theme by placing an `.slopdesktheme` file in `~/.config/slopdesk/themes/` on the client Mac — the same folder SlopDesk writes to when editing colors in the Settings Panel.
- File name = theme slug: display name lowercased, non-alphanumeric → `-` (e.g. "My Cool Theme" → `my-cool-theme.slopdesktheme`). Human-readable name goes in `[meta] name`.
- New files appear next time the theme list opens; relaunch if not visible. No build step.
- Activate with `theme = my-cool-theme` in config or via any switcher.
- Use `inherits` to extend a theme without restating every color (see Theme Format reference).
- Import a file directly — SlopDesk drops it in the themes folder, converting formats as needed.
- Supported import formats: SlopDesk `.slopdesktheme` (chrome styling preserved), iTerm2 `.itermcolors` (covers nearly every scheme online), Kitty `.conf` (`foreground #fff` / `color0 #000`), Alacritty `[colors.*]` `.toml`, Ghostty (`foreground = #fff` / `palette = 0=#000`).
- From Settings Panel: Appearance → Themes → "Import Theme..." dropdown, pick format, file dialog opens at that terminal's theme folder when available. Preview shows name, light/dark, color swatches. Tick "Switch to it now" to activate. Light/dark mode auto-detected from background color.
- From Finder: double-click `.slopdesktheme` or `open Nord.slopdesktheme`. SlopDesk prompts "Import" (add only) or "Import & Apply" (add and switch).
- From CLI: format auto-detected; accepts local path or `http(s)` URL. `.slopdesktheme`/`.itermcolors` may skip the `theme` subcommand.
  - `slopdesk import ~/Downloads/Nord.slopdesktheme` — add to themes
  - `slopdesk import ~/Downloads/Nord.slopdesktheme --activate` — add and switch
  - `slopdesk theme import ~/Downloads/Dracula.itermcolors` — explicit form, any supported format
  - `slopdesk theme import https://example.com/nord.toml` — import from a URL
  - `slopdesk theme import https://example.com/nord.toml --overwrite` — update existing
- Imported theme lands at `~/.config/slopdesk/themes/<slug>.slopdesktheme`. On slug collision SlopDesk appends `-1`, `-2`, etc.; `--overwrite` (CLI) updates in place.
- Theme files are real TOML; only `[terminal]` is required, everything else optional.
- `background = "none"` in `[terminal]` = transparent terminal background.
- `[token]` covers typography/shape: accent color, mono and UI font stacks, font size (pt), line height (`adjust-cell-height`).
- `[container]` styles the rounded card the terminal grid sits in: radius, shadow, border, padding (inner gutter), margin (inset from window edges). Values scalar or `[top, right, bottom, left]`.
- Additional optional sections: `[panel]`, `[sidebar]`, `[titlebar]`, `[tab]` (with `[tab.active]` / `[tab.hover]`), `[window]` (e.g. `material = "glass"`), `[cursor]`.
- Color sections cover the 16-color palette (ANSI 0–15), foreground, background, cursor, selection-background.
- Settings Panel shows "Duplicate", "Edit Selected Theme", and "Open Themes Folder" buttons below the color swatch grid.

## Keybindings

| Action | Keys |
|--------|------|
| Open theme switcher via command palette | Open command palette, then type "Theme" or filter by theme name |

No dedicated shortcut for theme switching; access is via menu, palette, or settings.

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `theme` | `paper` | Active theme in light mode (or always, if dark-mode separation is off) |
| `theme-dark` | `nord` | Active theme in dark mode (only when "Use separated theme for dark mode" is on) |
| `[meta] name` | _(file slug)_ | Human-readable display name |
| `[meta] mode` | _(none)_ | `"dark"` or `"light"` — drives auto light/dark slot assignment |
| `[meta] author` | _(none)_ | Optional author string |
| `[meta] description` | _(none)_ | Optional description string |
| `[terminal] foreground` | _(required)_ | Terminal foreground color (hex) |
| `[terminal] background` | _(required)_ | Terminal background color (hex); `"none"` = transparent |
| `[terminal] palette` | _(required)_ | 16-element array of hex strings, ANSI colors 0–15 |
| `[terminal] cursor` | _(foreground fallback)_ | Cursor color; falls back to foreground if omitted |
| `[terminal] selection-background` | _(none)_ | Selection highlight color |
| `[token] accent` | _(none)_ | Focus/selection accent color |
| `[token] font-mono` | _(system mono)_ | Terminal grid font — name or fallback array, e.g. `["JetBrains Mono", "Menlo"]` |
| `[token] font-ui` | _(system UI)_ | Window-chrome font — e.g. `["-apple-system", "SF Pro"]` |
| `[token] font-size` | `13` | Terminal font size in points |
| `[token] adjust-cell-height` | `"20%"` | Line height: `"Npx"`, `"N"`, `"N%"`, or `"0"` (natural) |
| `[container] radius` | `15` | Corner radius of the terminal card (px) |
| `[container] shadow` | `"0 1.5px 6px rgba(0,0,0,0.18)"` | Drop shadow (CSS box-shadow syntax) |
| `[container] border` | `"1px solid #2A2E45"` | Border of the terminal card (CSS border syntax) |
| `[container] padding` | `[8, 16, 8, 16]` | Inner grid gutter — scalar or `[top, right, bottom, left]` |
| `[container] margin` | `[0, 16, 16, 0]` | Inset of the card from window edges — scalar or `[top, right, bottom, left]` |

## Visual spec

### dark-mode-theme.png — Settings Panel, Appearance tab, Themes section

**Overall layout:** macOS settings window, rounded corners, drop shadow on white. Two columns: left sidebar (~310px) and right content area.

**Left sidebar:**
- macOS traffic-light controls (red/yellow/green) at top-left.
- Search field: magnifier icon, placeholder "Search", full-width rounded rectangle, light gray fill.
- Vertical nav list (icon+label): General (clock), Shell (`>_`), Controls (cursor/pointer), Editor (document), Agents (plug), **Appearance** (palette/circle, selected — bold, darker background pill), Recipes (book), Key Bindings (lightning bolt), Advanced (wrench).

**Right content area (Appearance → Themes):**
- Top strip: partial terminal preview showing `ls -l` output with colored columns (permissions gray, sizes orange/red, user "slopdesk" green, date blue, filename light gray) — a live mini-preview of the selected theme.
- Color swatch grid (two rows):
  - Row 1 (8): large foreground/background swatches on the left (filled black + empty white rectangle), then 8 ANSI dots — black, dark red, dark green, orange, steel blue, dark purple/navy, teal, light gray. Circles ~24px.
  - Row 2 (8): bright/lighter variants — medium gray, muted pink/rose, muted green, light orange, muted blue, light purple, light cyan, off-white. Slightly smaller or same ~24px.
- Chrome region labels (pill label groups, each followed by small color swatch squares):
  - "Window" — 1 rounded square swatch (light gray)
  - "Container" — 2 squares (one outlined, one filled): bg + border
  - "Panel" — 3 squares (light gray variants)
  - "Sidebar" — 3: empty square, filled black, outlined
  - "Titlebar" — 2: hatched/pattern square (transparency/blur), gray
  - "Tabbar" — 2: hatched square, outlined
  - "Tab" — 5: hatched, dark gray, white/light, black filled, black filled, outlined rectangle (tab shape)
  - "Accents" — 6: dark green, black, dark gray, medium gray, light gray, lighter gray (accent gradient)
  - "Cursor" — 2: black filled, outlined rectangle (cursor shape)
  - "Selection" — 2: black filled, black filled (selection fg/bg)
- Action buttons row (below swatch grid, above toggle): three outlined medium-weight rounded-rectangle buttons — **Duplicate**, **Edit Selected Theme**, **Open Themes Folder**.
- Horizontal divider separating action buttons from the dark-mode toggle section.
- Toggle row: label "Use separated theme for dark mode" (bold, ~17px), subtitle "Follow the system color scheme: theme above is used in light mode, the dark theme below in dark mode." Toggle at far right — green/ON.

**Typography:** SF Pro / system sans-serif. Section labels (Window, Container, etc.) small all-caps or regular ~13px. Button text ~14px medium. Body ~14–15px regular.

**Color palette:** Light gray sidebar (~#F2F2F2), white content, medium gray dividers, black text, green toggle (#34C759 or similar). Swatch circles use the theme's actual palette colors.

### import-theme.png — Settings Panel, Appearance tab, Import Theme dropdown open

**Overall layout:** Same settings window (Appearance selected). Right content scrolled down slightly — top terminal preview and foreground/palette swatches no longer visible; starts from the chrome region labels (Window / Container / Panel row).

**Right content area visible sections:**
- Chrome region label rows (Window, Container, Panel / Sidebar, Titlebar, Tabbar / Tab / Accents, Cursor, Selection) — same swatch pattern as dark-mode-theme.png.
- Action buttons: **Duplicate**, **Edit Selected Theme** (outlined rounded rectangles), **Open Themes Folder** (now on a second row), **Import Theme...** (outlined, with a dropdown caret `v` on its right) — this button is active/open.
- **Dropdown menu open** from "Import Theme...", floating panel with rounded corners, subtle shadow, white background. Five items vertically, ~14px text, ~32px rows: **SlopDesk**, **iTerm2** (highlighted — darker background, hover/focus), **Kitty**, **Alacritty**, **Ghostty**.
- Below the buttons: "Use separated theme for dark mode" toggle row (as dark-mode-theme.png), partially visible, green ON.
- Below the toggle: "DARK THEME" section header in small-caps/uppercase gray (~11–12px, #8E8E93 or similar).
- Bottom strip: four theme preview cards (~120px wide), each with a small colored dot (accent/cursor — green, blue, dark, blue) and two horizontal text-like stripes. These are the dark-slot theme picker cards.

**Dropdown styling:** White background, 1px light gray border, 8px corner radius, gentle drop shadow. Rows ~32–34px, left-padded text. Active hover row light gray (#F0F0F0) fill. No icons — text only.

**Typography and spacing:** Consistent with dark-mode-theme.png. "DARK THEME" label uppercase ~11px gray, acting as a section separator. Preview cards spaced ~8px apart.

## Screenshots

- `dark-mode-theme.png`
- `import-theme.png`

## SlopDesk mapping notes

**Maps cleanly (1:1 or near-1:1):**

- `[terminal]` colors (foreground, background, 16-color palette, cursor, selection-background) → libghostty `TerminalConfigBuilder` color overrides via slopdesk's `resolveTerminalColors`. SlopDesk already overrides terminal colors per theme (confirmed by Monokai Pro).
- `[token] font-mono`, `font-size`, `adjust-cell-height` → libghostty font config through `TerminalConfigBuilder`. Font family/size already threaded through slopdesk's theme system.
- `[container] radius`, `border`, `shadow`, `padding`, `margin` → SwiftUI styling on the container view wrapping `TerminalRenderingView`. SlopDesk has radius=0 flat panes (Monokai Pro flat); restoring non-zero radius/shadow is straightforward SwiftUI.
- `[token] accent` → SwiftUI `tint` / `accentColor` for focus rings, selection, interactive controls.
- `theme` / `theme-dark` → `ThemeStore` (already present), keyed on light/dark appearance; it already posts on `id` change.
- Auto light/dark → SwiftUI `@Environment(\.colorScheme)` observed in `ThemeStore`; slopdesk already switches live without restart.
- `[meta] mode` for import slot assignment: infer from background luminance (same heuristic the import preview uses).
- Theme discovery: a user themes directory `PreferencesStore` / `ThemeStore` can scan — `~/.config/slopdesk/themes/` on the CLIENT (macOS).
- "Duplicate", "Edit Selected Theme", "Open Themes Folder" all operate on the CLIENT filesystem — clean mapping.

**Requires adaptation:**

- **Settings Panel UI** (two-column macOS settings window with sidebar nav): slopdesk's settings surface uses a different shell. The swatch-grid editor and picker thumbnails must be built in SwiftUI for the client settings pane; the visual design (swatch circles, chrome label groups, pill buttons) can be replicated.
- **`[panel]`, `[sidebar]`, `[titlebar]`, `[tab]`, `[window]`, `[cursor]`** (app chrome): slopdesk equivalents are `WorkspaceView` sidebar, titlebar, tab strip, pane dividers. Token names differ but the concept maps. `material = "glass"` under `[window]` → SwiftUI `.background(.ultraThinMaterial)`, feasible on macOS.
- **iOS client**: no `~/.config/`. Theme files must be bundled, synced via slopdesk's Data Sync, or managed in-app. Import flow needs an iOS UI (document picker instead of Finder double-click; no CLI).
- **CLI import (`slopdesk theme import`)**: theme management is purely client-side; host-side `slopdesk-ctl` is not involved.
- **Import from a URL**: needs client-side networking. Feasible but requires a dedicated UI affordance and a theme-gallery URL convention of slopdesk's own (or accepting `.slopdesktheme` / `.itermcolors` from arbitrary URLs).
- **`background = "none"` (transparent terminal)**: libghostty supports it, but compositing transparency over the remote video stream (PATH 2) is undefined — flag as unsupported for remote panes; may work for local panes.
- **`[token] font-ui`** (chrome font): slopdesk chrome is SwiftUI, controlled via `.font()`. Can be threaded through the client's design-system tokens (`SlateDesign`) but requires care not to break layout.
- **Theme slug collision** (append `-1`, `-2`): small implementation detail, no blocker.
- **Finder double-click / `open`** (`.slopdesktheme` UTI): requires a macOS UTI declaration in the app bundle. Low priority; CLI or Settings Panel import suffices for v1.
