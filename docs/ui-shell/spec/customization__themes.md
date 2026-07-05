# Themes

## Summary

How to pick, switch, and write themes. SlopDesk supports a light/dark theme pair that follows the OS appearance, custom `.slopdesktheme` TOML files, and import from five terminal formats (SlopDesk, iTerm2, Kitty, Alacritty, Ghostty). Theme switching is live — no restart required. Built-in themes include Paper (light default) and Nord (dark default).

## Behaviors

- Theme can be switched from: Main menu → View → Themes; Command Palette (type "Theme" or filter by theme name directly); Settings Panel → Appearance → Themes; CLI (`slopdesk theme list` / `slopdesk theme set <theme>`); direct `config.toml` edit (`theme = <theme>` row).
- Auto light/dark switching is ON by default and applied live without restart.
- Two theme slots: `theme` (light, default: Paper) and `theme-dark` (dark, default: Nord).
- Settings Panel → Appearance → Themes shows a main theme picker for the light slot; toggling "Use separated theme for dark mode" reveals a Dark Theme picker below for the dark slot.
- With the toggle OFF, `theme` is used regardless of OS appearance.
- Custom themes are added by placing an `.slopdesktheme` file in `~/.config/slopdesk/themes/` on the client Mac — the same folder SlopDesk writes to when editing colors in the Settings Panel.
- The file name is the theme slug: display name lowercased, non-alphanumeric characters become `-`. Example: "My Cool Theme" → `my-cool-theme.slopdesktheme`. Human-readable name goes in `[meta] name`.
- New theme files appear next time the theme list opens; relaunch SlopDesk if not visible. No build step required.
- Activate custom theme with `theme = my-cool-theme` in config or via any switcher.
- Use `inherits` to extend an existing theme without restating every color (see Theme Format reference).
- Import a theme file directly — SlopDesk drops it in the themes folder, converting from other formats as needed.
- Supported import formats: SlopDesk `.slopdesktheme` (chrome styling preserved), iTerm2 `.itermcolors` (covers nearly every scheme online), Kitty color `.conf` (`foreground #fff` / `color0 #000`), Alacritty `[colors.*]` `.toml`, Ghostty theme files (`foreground = #fff` / `palette = 0=#000`).
- From Settings Panel: Appearance → Themes → "Import Theme..." dropdown, pick format, file dialog opens at that terminal's theme folder when available. Preview shows name, light/dark, color swatches. Tick "Switch to it now" to activate immediately. Light/dark mode auto-detected from background color.
- From Finder: double-click `.slopdesktheme` or run `open Nord.slopdesktheme`. SlopDesk prompts: "Import" (add only) or "Import & Apply" (add and switch).
- From CLI: format auto-detected; accepts local path or `http(s)` URL. Can skip `theme` subcommand for `.slopdesktheme` or `.itermcolors`.
  - `slopdesk import ~/Downloads/Nord.slopdesktheme` — add to themes
  - `slopdesk import ~/Downloads/Nord.slopdesktheme --activate` — add and switch
  - `slopdesk theme import ~/Downloads/Dracula.itermcolors` — explicit form, any supported format
  - `slopdesk theme import https://example.com/nord.toml` — import from a URL
  - `slopdesk theme import https://example.com/nord.toml --overwrite` — update existing
- Imported theme lands at `~/.config/slopdesk/themes/<slug>.slopdesktheme`. If slug exists, SlopDesk appends `-1`, `-2`, etc. Use `--overwrite` (CLI) to update in place.
- Theme TOML files are real TOML; only `[terminal]` section is required, everything else optional.
- `background = "none"` in `[terminal]` gives a transparent terminal background.
- The `[token]` section covers typography and shape: accent color, font stacks for mono and UI, font size (pt), and line height (`adjust-cell-height`).
- The `[container]` section styles the rounded card the terminal grid sits in: radius, shadow, border, padding (inner gutter), margin (inset from window edges). Values are scalar or `[top, right, bottom, left]`.
- Additional optional sections: `[panel]`, `[sidebar]`, `[titlebar]`, `[tab]` (with `[tab.active]` / `[tab.hover]`), `[window]` (e.g. `material = "glass"`), `[cursor]`.
- Theme color sections cover 16-color palette (ANSI 0–15), foreground, background, cursor, selection-background.
- In Settings Panel: "Duplicate", "Edit Selected Theme", and "Open Themes Folder" action buttons are shown below the color swatch grid.

## Keybindings

| Action | Keys |
|--------|------|
| Open theme switcher via command palette | Open command palette, then type "Theme" or filter by theme name |

(No dedicated keyboard shortcut for theme switching is specified; all access is via menu, palette, or settings.)

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `theme` | `paper` | Active theme in light mode (or always, if dark-mode separation is off) |
| `theme-dark` | `nord` | Active theme in dark mode (only used when "Use separated theme for dark mode" is on) |
| `[meta] name` | _(file slug)_ | Human-readable display name of the theme |
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

**Overall layout:** macOS settings window with rounded corners, drop shadow on a white background. Two-column layout: left sidebar (~310px wide) and right content area.

**Left sidebar:**
- macOS traffic-light controls (red/yellow/green circles) at top-left.
- Search field with magnifier icon, placeholder "Search", full-width rounded rectangle, light gray fill.
- Vertical nav list with icon+label items: General (clock icon), Shell (terminal `>_` icon), Controls (cursor/pointer icon), Editor (document icon), Agents (plug icon), **Appearance** (palette/circle icon, currently selected — bold text, slightly darker background pill highlighting the row), Recipes (book icon), Key Bindings (lightning bolt icon), Advanced (wrench icon).

**Right content area (Appearance → Themes):**
- Top strip: partial terminal preview at top showing `ls -l` output with colored columns (file permissions in gray, sizes in orange/red, user "slopdesk" in green, date in blue, filename in light gray). This is a live mini-preview of the selected theme applied to a terminal surface.
- Color swatch grid (two rows):
  - Row 1 (8 swatches): large foreground/background swatches on the left (filled black rectangle + empty white rectangle), then 8 ANSI color dots — black, dark red, dark green, orange, steel blue, dark purple/navy, teal, light gray. All circles ~24px diameter.
  - Row 2 (8 swatches): 8 bright/lighter variants — medium gray, muted pink/rose, muted green, light orange, muted blue, light purple, light cyan, off-white. Slightly smaller diameter than row 1 (or same ~24px).
- Chrome region labels (pill-shaped label groups, each followed by small color swatch squares):
  - "Window" — 1 small rounded square swatch (light gray)
  - "Container" — 2 small square swatches (one outlined, one filled), indicating bg + border
  - "Panel" — 3 small square swatches (light gray variants)
  - "Sidebar" — 3 swatches: empty square, filled black square, outlined square
  - "Titlebar" — 2 swatches: hatched/pattern square (indicating transparency/blur), gray square
  - "Tabbar" — 2 swatches: hatched square, outlined square
  - "Tab" — 5 swatches: hatched, dark gray, white/light, black filled, black filled, outlined rectangle (tab shape)
  - "Accents" — 6 swatches: dark green, black, dark gray, medium gray, light gray, lighter gray (gradient of accent tones)
  - "Cursor" — 2 swatches: black filled, outlined rectangle (cursor shape)
  - "Selection" — 2 swatches: black filled, black filled (selection fg/bg)
- Action buttons row (below swatch grid, above toggle): three rounded-rectangle buttons —
  - **Duplicate** (outlined, medium weight)
  - **Edit Selected Theme** (outlined, medium weight)
  - **Open Themes Folder** (outlined, medium weight)
- Horizontal divider line separating action buttons from the dark-mode toggle section.
- Toggle row: label "Use separated theme for dark mode" (bold, ~17px) with subtitle "Follow the system color scheme: theme above is used in light mode, the dark theme below in dark mode." Toggle switch on the far right — green/ON state (green pill with white circle shifted right).

**Typography:** SF Pro or system sans-serif. Section labels (Window, Container, etc.) in small all-caps or regular weight ~13px. Button text ~14px medium weight. Body ~14–15px regular.

**Color palette:** Light gray sidebar background (~#F2F2F2), white content area, medium gray dividers, black text, green toggle (#34C759 or similar system green). Swatch circles use the theme's actual palette colors.

### import-theme.png — Settings Panel, Appearance tab, Import Theme dropdown open

**Overall layout:** Same macOS settings window (same sidebar showing Appearance selected). Right content area scrolled down slightly — the top terminal preview and foreground/palette swatches are no longer visible; starts from the chrome region labels (Window / Container / Panel row).

**Right content area visible sections:**
- Chrome region label rows (Window, Container, Panel / Sidebar, Titlebar, Tabbar / Tab / Accents, Cursor, Selection) — identical swatch pattern to dark-mode-theme.png.
- Action buttons row: two visible buttons —
  - **Duplicate** (outlined rounded rectangle)
  - **Edit Selected Theme** (outlined rounded rectangle)
  - **Open Themes Folder** (outlined rounded rectangle, now on a second row)
  - **Import Theme...** (outlined rounded rectangle with a dropdown caret `v` on its right side) — this button is active/open.
- **Dropdown menu open** from "Import Theme..." button, floating panel with rounded corners and subtle shadow, white background. Five menu items listed vertically with ~14px text, ~32px row height:
  - **SlopDesk** (normal weight)
  - **iTerm2** (highlighted — slightly darker background row, indicating hover/focus)
  - **Kitty** (normal weight)
  - **Alacritty** (normal weight)
  - **Ghostty** (normal weight)
- Below the buttons section: "Use separated theme for dark mode" toggle row (same as dark-mode-theme.png) partially visible, with green toggle ON.
- Below the toggle: "DARK THEME" section header in small caps/uppercase gray label (~11–12px, medium gray, #8E8E93 or similar).
- Bottom strip: four theme preview cards (mini-thumbnails), each ~120px wide, showing a small colored circle (dot indicating theme accent/cursor color — green, blue, dark, blue) and two horizontal lines of text-like stripes representing terminal content. These are the theme picker cards for the dark theme slot.

**Dropdown styling:** White background, 1px light gray border, 8px corner radius, gentle drop shadow. Row height ~32–34px, left-padded text. Active hover row has a light gray (#F0F0F0) fill. No icons in the dropdown rows — text only.

**Typography and spacing:** Consistent with dark-mode-theme.png. "DARK THEME" label in uppercase ~11px gray, acting as a section separator. Theme preview cards spaced ~8px apart.

## Screenshots

- `dark-mode-theme.png`
- `import-theme.png`

## SlopDesk mapping notes

**Maps cleanly (1:1 or near-1:1):**

- `[terminal]` color values (foreground, background, 16-color palette, cursor, selection-background) map directly to libghostty's `TerminalConfigBuilder` color overrides used by slopdesk's `resolveTerminalColors` path. SlopDesk already overrides terminal colors per theme (confirmed by Monokai Pro implementation).
- `[token] font-mono`, `font-size`, `adjust-cell-height` map to libghostty font configuration passed through `TerminalConfigBuilder`. Font family and size are already threaded through slopdesk's theme system.
- `[container] radius`, `border`, `shadow`, `padding`, `margin` map to SwiftUI styling on the container view wrapping `TerminalRenderingView`. SlopDesk already has radius=0 flat panes (Monokai Pro flat); restoring non-zero radius and shadow is straightforward SwiftUI.
- `[token] accent` maps to SwiftUI `tint` / `accentColor` for focus rings, selection, and interactive controls in the client UI.
- `theme` / `theme-dark` config keys map to `ThemeStore` (which slopdesk already has), keyed on light/dark appearance. `ThemeStore` already posts on `id` change.
- Auto light/dark switching maps to SwiftUI `@Environment(\.colorScheme)` observed in `ThemeStore`; slopdesk already does theme-switching live without restart.
- `[meta] mode` (dark/light) for import slot assignment is straightforward: infer from background luminance (same heuristic the import preview uses).
- Theme file discovery is a user themes directory that `PreferencesStore` / `ThemeStore` can scan: `~/.config/slopdesk/themes/` on the CLIENT (macOS) side.
- "Duplicate", "Edit Selected Theme", "Open Themes Folder" actions all operate on the CLIENT machine's filesystem — clean mapping.

**Requires adaptation:**

- **Settings Panel UI** (the two-column macOS settings window with sidebar nav): slopdesk's settings surface uses a different UI shell. The color-swatch grid editor and theme picker thumbnails need to be built in SwiftUI for slopdesk's client settings pane. The visual design (swatch circles, chrome label groups, pill buttons) can be replicated in SwiftUI.
- **`[panel]`, `[sidebar]`, `[titlebar]`, `[tab]`, `[window]`, `[cursor]`** optional sections: these style the app's own chrome. In slopdesk, the equivalent chrome regions are `WorkspaceView` sidebar, titlebar, tab strip, and pane dividers. The token names differ but the concept maps. `material = "glass"` under `[window]` maps to SwiftUI `.background(.ultraThinMaterial)` — feasible on macOS.
- **iOS client**: iOS has no `~/.config/` directory. Theme files must be bundled, synced via slopdesk's Data Sync mechanism, or managed through the in-app settings UI. The Settings Panel import flow needs an iOS-adapted UI (document picker instead of Finder double-click; no CLI).
- **CLI import (`slopdesk theme import`)**: theme management is purely client-side in slopdesk's architecture; the host-side `slopdesk-ctl` is not involved.
- **Import from a URL**: requires client-side networking. Feasible but needs a dedicated UI affordance, and a theme-gallery URL convention of slopdesk's own choosing (or accepting the same `.slopdesktheme` / `.itermcolors` URL pattern from arbitrary URLs).
- **`background = "none"` (transparent terminal)**: libghostty supports transparent backgrounds, but compositing transparency over the remote video stream (slopdesk PATH 2) is undefined — this should be flagged as unsupported for remote panes. For local panes it may work.
- **`[token] font-ui`** (window-chrome font): in slopdesk the chrome is SwiftUI; font is controlled via SwiftUI `.font()` modifiers. This can be threaded through the client's design-system tokens (`SlateDesign`) but requires care to not break layout.
- **Theme slug collision handling** (append `-1`, `-2`): small implementation detail, no architecture blocker.
- **Finder double-click / `open` integration** (`.slopdesktheme` UTI registration): requires a macOS UTI declaration in the app bundle. Low priority; CLI or Settings Panel import is sufficient for v1.
