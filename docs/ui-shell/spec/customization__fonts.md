# Fonts and Text Rendering

## Summary

This page covers every dimension of font configuration in slopdesk: font installation without system Font Book, font family selection (global vs per-theme vs fallback), font size, line height (cell height), ligatures, bold/italic/underline/blink rendering modes, and sub-pixel glyph blending. The bundled default is JetBrains Mono. Fonts are loaded from `~/.config/slopdesk/fonts/` via CoreText at launch — no system-wide install required. Settings are scoped to Computed / Global / Light Theme / Dark Theme / Fallback tabs, and can be written to either global `config.toml` or per-theme TOML files.

## Behaviors

- At launch, slopdesk registers all font files found in `~/.config/slopdesk/fonts/` with CoreText so they are immediately available to the Font Family picker and `font-family` config key — no Font Book or system installation needed.
- Accepted font file extensions: `.ttf`, `.otf`, `.ttc`, `.otc` (case-insensitive; all other extensions ignored).
- Font installation shortcut: Settings → Appearance → Font Family → "Open font folder" button opens `~/.config/slopdesk/fonts/` in Finder. Alternatively, `open ~/.config/slopdesk/fonts` from a shell.
- CLI font import: `slopdesk font import <font file path>`.
- After dropping a font file into the folder while Settings is open, close and reopen Settings to trigger a rescan; the font then appears in the Font Family combobox.
- Font Family setting has three scope tabs: **Global** (writes to `~/.config/slopdesk/config.toml`, applies everywhere), **Light Theme** / **Dark Theme** (writes to the active theme TOML, travels with the theme), and **Fallback** (comma-separated list of fonts used when the primary font lacks a glyph, e.g. for CJK or icon characters).
- When "Auto-match weight & style" toggle is ON (default), slopdesk automatically selects the real bold, italic, and bold-italic faces of the chosen font family without user intervention.
- When "Auto-match weight & style" toggle is OFF, four separate pickers appear for Font Family (regular), Font Family (Bold), Font Family (Italic), and Font Family (Bold Italic), each populated with all available faces from all installed and `~/.config/slopdesk/fonts/` fonts.
- Font size is adjustable via Settings → Appearance → Text, via the menu bar, or via keyboard shortcuts `⌘+`, `⌘-`, `⌘0` (reset).
- Line height (cell height) has four modes: **Default** (uses what theme TOML defines), **Compact** (1.0 multiplier), **Loose** (1.2 multiplier), **Custom** (user-supplied multiplier e.g. 1.0 or 1.5, or "Adjust Cell Height" to add/subtract fixed pixels).
- Ligatures have three modes: `off` (no ligation, default), `calt` (standard + contextual alternates: `=>`, `!=`, `>=`, …), `dlig` (everything in `calt` plus discretionary ligatures).
- The `font-ligatures-alphabet = true` config key extends ligation to alphabetic sequences, not just symbol sequences.
- Bold rendering has four modes: **Auto** (default — use real bold face, borrow from fallback if needed), **Off** (ignore bold SGR, render at normal weight), **Primary Only** (bold face only if primary font has one, never pull from fallback), **Synthetic** (fake bold via algorithmic thickening / faux bold when no real face exists).
- Italic rendering has the same four modes as bold: **Auto** (default), **Off**, **Primary Only**, **Synthetic** (faux italic via algorithmic slanting).
- Underline is on by default. When off, underlined cells skip drawing the underline decoration. Note: only SGR underlines are affected; link underlines (⌘-hover / OSC 8) and strikethrough are unaffected regardless of this setting.
- Blink (SGR 5/6) is off by default because it is an accessibility concern and is frequently emitted by accident. When enabled, affected cells blink at approximately 1 Hz.
- Font blending controls how glyph edges are anti-aliased onto the background, affecting perceived stroke weight especially for dark text on light themes. The recommendation is to leave it on **Default** unless text appears too thin or too heavy.
- Blending modes: `Default` (defers to active theme, which falls back to `srgb-over`), `srgb-over` (slopdesk baseline; stroke weight lands where font designer intended), `macos-like` (matches macOS native blending, Display P3 path, closest to other Mac apps), `linear` (physically-correct linear-light blend; pure white stays pure white but thin dark strokes come out ~15% lighter), `perceptual` (like `linear` but boosts thin dark text back toward intended weight).
- Blending is a taste-driven, subtle setting; the guidance is to switch between modes with text on screen and keep whichever looks crispest.

## Keybindings

| Action | Keys |
|--------|------|
| Increase font size | `⌘+` |
| Decrease font size | `⌘-` |
| Reset font size to default | `⌘0` |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `"JetBrains Mono"` (bundled) | Primary monospace font family name, used for all normal text. |
| `font-family-fallback` | `""` (none) | Comma-separated list of fallback font families; used when primary font lacks a glyph (CJK, Nerd Font icons, etc.). |
| `font-size` | (theme-defined or 13) | Font size in points. |
| `font-ligatures` | `off` | Ligature mode: `off`, `calt`, or `dlig`. |
| `font-ligatures-alphabet` | `false` | When `true`, applies ligation rules to alphabetic sequences in addition to symbol sequences. |
| `font-bold` | `auto` | Bold face mode: `auto`, `off`, `primary-only`, `synthetic`. |
| `font-italic` | `auto` | Italic face mode: `auto`, `off`, `primary-only`, `synthetic`. |
| `font-underline` | `true` (on) | Whether underlined cells (SGR) draw the underline decoration. Does not affect OSC 8 link underlines or strikethrough. |
| `font-blink` | `false` (off) | Whether SGR 5/6 blink is rendered (~1 Hz). Off by default; accessibility concern. |
| `font-blending` | `default` | Glyph anti-aliasing blend mode: `default`, `srgb-over`, `macos-like`, `linear`, `perceptual`. |
| `line-height` | `default` | Cell height mode: `default`, `compact` (1.0×), `loose` (1.2×), or a custom numeric multiplier. |

## Visual spec

### font-setting.png — Font Family Settings Panel (Auto-match ON, Light Theme tab selected)

The Settings window is a standard macOS preferences panel with a rounded-rect window chrome (traffic-light buttons top-left, no titlebar text visible). A narrow left sidebar lists navigation items with icon glyphs at ~16pt: General, Shell, Controls, Editor, Agents, Appearance (selected, bold/highlighted in the sidebar with a solid system-blue or dark-teal tint), Recipes, Key Bindings, Advanced. The sidebar background is a light warm gray (~#F5F5F4).

The main content area is white. At the top, a large all-caps label "FONT FAMILY" acts as a section header (gray, ~11pt, tracked). Below it, a smaller label "Settings for" precedes a horizontal row of pill-shaped toggle tabs: "Computed", "Global", "Light Theme" (selected — filled dark background, white text), "Dark Theme", "Fallback". The selected tab uses a visually solid dark fill distinguishing it from the inactive tabs which have an outlined/ghost style with the same pill shape.

Below the tab row is a contextual note "Saved into the light theme's TOML" in small muted gray text. Immediately below that is a row with a green toggle switch (ON state) labeled "Auto-match weight & style" in regular body text.

The form below has four left-aligned bold labels in a two-column layout: "Font Family", "Font Family (Bold)", "Font Family (Italic)", "Font Family (Bold Italic)". In Auto-match mode, only the primary "Font Family" row has an active combobox (showing "JetBrains Mono" with a trailing disclosure chevron); the Bold/Italic/Bold Italic rows appear grayed out / disabled.

An open dropdown from the Font Family combobox is visible, showing a scrollable list of font options grouped alphabetically with single-letter section headers (F, G, I, J). Each row has a small "Aa" specimen label in the font itself at ~13pt on the left, then the font name. The selected item (JetBrains Mono) has a checkmark on the right. The highlighted row (GoogleSansCode-Regular) has a blue/teal hover background. Font names visible: Fira Code, GoogleSansCode-Regular, IBM Plex Mono, Iosevka Term Slab, JetBrains Mono (checked).

Below the font pickers, two buttons sit side by side: "Install font" and "Open font fol[der]" (truncated). These appear as standard macOS borderless buttons with rounded rect outlines.

At the bottom of the visible area, the next section header "CURSOR" begins.

### font-setting-bold.png — Font Family Settings Panel (Auto-match OFF, Global tab selected)

Same layout as above but with the "Global" tab selected. A prominent red/orange-tinted banner replaces the muted note: "Overrides theme; takes priority everywhere" — indicating the Global scope overrides per-theme settings. The toggle "Auto-match weight & style" is now OFF (gray/unchecked state, shown in red outline to indicate override context).

With Auto-match OFF, the Font Family combobox shows "Unset" (grayed placeholder text). An open dropdown list is visible showing all font face variants of IBM Plex Mono, each as a separate row with "Aa" specimen: IBM Plex Mono Bold, IBM Plex Mono Bold Italic, IBM Plex Mono ExtraLight, IBM Plex Mono ExtraLight Italic, IBM Plex Mono Italic, IBM Plex Mono Light, IBM Plex Mono Light Italic, IBM Plex Mono Medium — demonstrating that when auto-match is off, every individual face is surfaced separately for manual assignment.

### font-JetBrainsMono.png — JetBrains Mono terminal sample (light theme)

A rounded-rect macOS terminal window with white/off-white background. Traffic-light buttons (red filled, yellow filled, green filled) top-left. Title "vi CreDITS.md" centered in gray at ~12pt. The terminal content shows vim editing a markdown file. Font is JetBrains Mono: distinctive slightly rounded monospace letterforms, medium x-height, moderate stroke contrast. Syntax-colored text: section headers in muted blue-purple (`## Built-in Themes`), list dashes in orange-red, bold Markdown text in bold monospace, hyperlinks in orange, plain text in near-black. Status line bottom-right shows "129,69-67   91%" in gray monospace. The terminal background is pure white; text color is very dark near-black. Line spacing appears default (approximately 1.1–1.15×).

### font-Menlo.png — Menlo terminal sample (light theme, unfocused / background)

Same window structure but traffic-light buttons are gray (unfocused window state — all three circles are gray, not colored). Title "vi CreDITS.md". Terminal background white. Menlo font: taller x-height, slightly wider glyph widths, softer curves, classic macOS system monospace. Same syntax colors as JetBrains sample. The unfocused window traffic lights (all gray) make this clearly a backgrounded/inactive window screenshot.

### font-IBMPlexMono.png — IBM Plex Mono terminal sample (light theme, unfocused)

Gray traffic-light buttons (unfocused). IBM Plex Mono: geometric, slightly humanist, noticeable ink traps at stroke junctions, clean stroke terminations, prominent serifs on some glyphs. Wider apparent glyph width than JetBrains Mono. Same syntax coloring. Background white.

### font-Cousine.png — Cousine terminal sample (light theme, colored traffic lights)

Colored (active) traffic lights. Cousine font: metric-compatible with Courier New, slightly narrower than Courier, clean stroke ends, traditional typewriter feel, low contrast strokes. Background white. Same syntax coloring in vim.

### line-height-1.png — Compact line height (1.0×)

A small, compact terminal window showing `git log` output. Window has colored traffic lights (red/yellow/green), title "git log" centered. The background is **dark** (~#2D2D2D dark gray). Commit hash lines are in orange/amber. Author and Date lines are in light gray near-white. Commit message text is plain off-white. Line spacing is noticeably tight: lines are packed with minimal vertical gap, approximately equal to cap-height with nearly no leading. This is the compact (1.0×) presentation.

### line-height-1.2.png — Loose line height (1.2×)

Identical content to line-height-1.png (`git log`) but in a slightly taller window. The same dark background, same color scheme, colored traffic lights. Visibly more breathing room between lines: the gaps between the commit hash / Author / Date / message lines are clearly larger, making the text easier to scan. This is the loose (1.2×) presentation.

### text-styles.png — Text styles showcase (dark theme, small window)

A small, dark-background terminal window (gray traffic lights — unfocused). Title "abner@MacBook-AB: ~". The content is a table-formatted demo of SGR text attributes, rendered in the terminal. Left column has style names, right column shows the styled text. Rows visible: `regular` (plain), `bold` (visually thicker/heavier strokes), `dim` (faint/muted), `italic` (slanted), `underline` (single underline), `double-under` (double underline), `curly-under` (wavy underline), `dotted-under` (dotted underline), `dashed-under` (dashed underline), `strike` (strikethrough), `reverse` (inverted foreground/background — white text on dark block becomes dark text on white block), `blink` ("blinking" label), `combined` (multiple attributes at once: bold, italic, underline, orange color). A second section shows "colored underlines (SGR 58 — underline color independent of fg)" with rows: `single_red`, `double_green`, `curly_blue`, `dotted_orange`, `dashed_magenta`, `curly_indexed` — each showing "The quick brown fox jumps over the lazy dog" with the described underline style in the specified color. The font is small monospace, dark background (~#2B2B2B), with a thin horizontal red status line at bottom.

### blending-srgb-over-dark.png — srgb-over blending, dark theme

Full-size rounded-rect terminal window, large. Background: very dark gray-slate (~#282C34 or similar). Traffic lights colored (active). Title "git log" in medium gray. Content: `git log` output with commit hashes in golden-orange (#E5C07B range), bold "HEAD → main" in teal/cyan, Author/Date lines in off-white, commit message body in off-white monospace. Stroke weight of the monospace font feels moderate and well-balanced — this is the reference/baseline blending. The text appears crisp and properly weighted for a dark background.

### blending-srgb-over-light.png — srgb-over blending, light theme

Same `git log` content on white/near-white background. Colored traffic lights. Commit hashes in orange-brown, "HEAD → main" bold in teal, plain text in near-black. Text stroke weight is perceptibly well-balanced — comparable to how the font designer intended it to look on light backgrounds.

### blending-macos-like-dark.png — macos-like blending, dark theme

Visually very similar to srgb-over-dark; the subtle difference is that the stroke weight of thin characters is slightly different (Display P3 color path). The overall appearance closely matches other macOS apps rendering the same font. To the untrained eye on a non-P3 screenshot, differences from srgb-over are minimal.

### blending-macos-like-light.png — macos-like blending, light theme

Same `git log` on white background. The text rendering uses the macOS native Display P3 blending path. Slightly different sub-pixel treatment on thin stroke terminals — most visible on lowercase letters like 'l', 'i', 't'. Cursor is a thin blinking bar visible at bottom-left of content area.

### blending-linear-dark.png — linear blending, dark theme

Same dark background, same content. With linear blending, dark text on dark background differences are subtle. The effect is described as thin dark strokes being ~15% lighter than srgb-over, but on a dark-background terminal this manifests as very slightly less-bold-feeling text.

### blending-perceptual-light.png — perceptual blending, light theme

Same light background. perceptual blending compensates for linear's tendency to make thin dark text appear too faint on light themes. Stroke weight appears similar to or slightly heavier than linear. The cursor (thin bar) is visible bottom-left of content. This mode is recommended for users who prefer linear but find text too faint.

## Screenshots

- font-JetBrainsMono.png
- font-Menlo.png
- font-IBMPlexMono.png
- font-GoggleSansCode.png
- font-UbuntuSansMono.png
- font-Cousine.png
- font-setting.png
- font-setting-bold.png
- line-height-1.png
- line-height-1.2.png
- text-styles.png
- blending-srgb-over-dark.png
- blending-srgb-over-light.png
- blending-macos-like-dark.png
- blending-macos-like-light.png
- blending-linear-dark.png
- blending-linear-light.png
- blending-perceptual-dark.png
- blending-perceptual-light.png

## SlopDesk mapping notes

### Font installation
- **Needs a host-side seam.** The `~/.config/slopdesk/fonts/` + CoreText-registration flow described above assumes a local install. SlopDesk runs a remote macOS host; the terminal rendering (libghostty) executes on the HOST. Font installation must happen on the host machine, not the client. The client Settings UI can only configure font names, not install font files to the host. The `slopdesk font import` CLI command would need to be a host-side operation (e.g. via the slopdesk-ctl agent socket or a dedicated protocol message). For the initial client, expose the font family field as a text entry (no local discovery); show a note that fonts must be installed on the host.
- Ghostty (libghostty) has its own font loading mechanism. Map `font-family` / `font-family-fallback` / `font-size` to the corresponding Ghostty config keys passed to `TerminalConfigBuilder`. Ghostty supports `.ttf`/`.otf` system fonts and user fonts.

### Font Family scope tabs (Computed / Global / Light Theme / Dark Theme / Fallback)
- SlopDesk has a ThemeStore with light/dark variants, so the per-theme font storage described above maps onto the existing Light Theme / Dark Theme split. Global writes to the top-level PreferencesStore/config. Implement as: a scope selector (Global / Light Theme / Dark Theme / Fallback) above the Font Family combobox in Appearance settings, writing to the appropriate config layer.

### Auto-match weight & style toggle
- **Maps.** Ghostty supports separate bold/italic font face specification. When auto-match is ON, pass only `font-family`; Ghostty selects bold/italic faces automatically. When OFF, surface `font-family-bold`, `font-family-italic`, `font-family-bold-italic` fields (map to Ghostty's equivalent config keys).

### Font size shortcuts (⌘+/⌘-/⌘0)
- **Maps.** Implement in SlopDeskClientUI as window-level keybindings that increment/decrement the font size preference and trigger a TerminalConfigBuilder rebuild + libghostty `updateConfiguration`. Note: a font-SIZE change DOES change the cell pixel size, so for a fixed pane viewport the cell COUNT changes → a SIGWINCH/PTY reflow (the same as a line-height change; coordinate with the existing resize debounce path). This is correct — only a font FAMILY/STYLE change is grid-preserving (cell box unchanged). The earlier "size is reflow-free" note was wrong; see `PreferencesStore.increaseFontSize()`.

### Line height
- **Maps via Ghostty.** Ghostty has `cell-height` / line-height config. Map Default/Compact/Loose/Custom to the appropriate Ghostty values passed through TerminalConfigBuilder. Note: changing line height changes cell pixel dimensions, which triggers a SIGWINCH/resize; coordinate with the existing resize debounce path.

### Ligatures
- **Maps.** Ghostty supports `font-feature` configuration. Map `off` → no features, `calt` → `+calt`, `dlig` → `+calt +dlig`. The `font-ligatures-alphabet` key has no direct Ghostty equivalent; may need to be a custom feature list.

### Bold/Italic/Underline/Blink modes
- **Maps.** Ghostty has `font-style-bold`, `font-style-italic` config accepting `auto`/`off` and similar values. The four-mode system (Auto/Off/Primary Only/Synthetic) maps approximately: Auto → Ghostty default, Off → `off`, Primary Only → `false` for fallback, Synthetic → Ghostty's faux-bold/faux-italic flags. Underline on/off maps to Ghostty's `underline` config key. Blink: Ghostty supports SGR blink — expose as a toggle; wire to the libghostty config.

### Font blending
- **Maps to Ghostty's `font-thicken` / blending config.** Ghostty has `font-thicken` (a boolean for macOS-style subpixel thickening) and its own blending/anti-aliasing pipeline. The five blending modes described above do not map 1:1 onto Ghostty's options. Recommended mapping: `Default` → Ghostty default, `macos-like` → enable `font-thicken`, others as best-effort. Document this as a known deviation; expose only Default/macOS-like in the initial client.

### Remote rendering boundary
- All font rendering happens on the HOST inside libghostty. The client sees only HEVC video frames over the slopdesk video path. Font config changes are transmitted to the host as config updates and take effect on the next frame. There is no local client-side font rendering — the visual blending differences between modes are encoded by the HOST's libghostty, not the client's GPU.

### iOS client
- Font size increase/decrease shortcuts (`⌘+`/`⌘-`) need to map to iOS equivalents (pinch-to-zoom or Settings UI). No keyboard shortcut path on a software keyboard. Expose font size as a stepper in iOS Appearance settings.
- Font installation is entirely host-side; no font picker UI needed on iOS beyond a text field for the font family name.
