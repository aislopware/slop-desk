# Fonts and Text Rendering

## Summary

Font configuration in slopdesk: install without Font Book, family selection (global / per-theme / fallback), size, line height (cell height), ligatures, bold/italic/underline/blink modes, sub-pixel glyph blending. Default bundled font: JetBrains Mono. Fonts load from `~/.config/slopdesk/fonts/` via CoreText at launch — no system install. Settings scope to Computed / Global / Light Theme / Dark Theme / Fallback tabs, written to global `config.toml` or per-theme TOML.

## Behaviors

- At launch, slopdesk registers all fonts in `~/.config/slopdesk/fonts/` with CoreText, making them available to the Font Family picker and `font-family` — no Font Book install needed.
- Accepted extensions: `.ttf`, `.otf`, `.ttc`, `.otc` (case-insensitive; others ignored).
- Install shortcut: Settings → Appearance → Font Family → "Open font folder" opens `~/.config/slopdesk/fonts/` in Finder. Or `open ~/.config/slopdesk/fonts`.
- CLI import: `slopdesk font import <font file path>`.
- After dropping a font while Settings is open, close and reopen Settings to rescan; the font then appears in the combobox.
- Font Family has three scope tabs: **Global** (writes `~/.config/slopdesk/config.toml`, applies everywhere), **Light Theme** / **Dark Theme** (writes active theme TOML, travels with the theme), **Fallback** (comma-separated fonts used when the primary lacks a glyph, e.g. CJK or icons).
- "Auto-match weight & style" ON (default): slopdesk auto-selects the real bold, italic, and bold-italic faces of the family.
- Auto-match OFF: four pickers appear — Font Family (regular), Bold, Italic, Bold Italic — each populated with all faces from installed and `~/.config/slopdesk/fonts/` fonts.
- Font size: Settings → Appearance → Text, the menu bar, or `⌘+`, `⌘-`, `⌘0` (reset).
- Line height (cell height) has four modes: **Default** (theme TOML value), **Compact** (1.0×), **Loose** (1.2×), **Custom** (user multiplier e.g. 1.0 or 1.5, or "Adjust Cell Height" to add/subtract fixed pixels).
- Ligatures have three modes: `off` (default), `calt` (standard + contextual alternates: `=>`, `!=`, `>=`, …), `dlig` (`calt` plus discretionary ligatures).
- `font-ligatures-alphabet = true` extends ligation to alphabetic sequences, not just symbols.
- Bold rendering has four modes: **Auto** (default — real bold face, borrow from fallback if needed), **Off** (ignore bold SGR, normal weight), **Primary Only** (bold face only if primary has one, never from fallback), **Synthetic** (algorithmic faux bold when no real face exists).
- Italic rendering has the same four modes: **Auto** (default), **Off**, **Primary Only**, **Synthetic** (faux italic via algorithmic slanting).
- Underline on by default. When off, underlined cells skip the decoration. Only SGR underlines are affected; link underlines (⌘-hover / OSC 8) and strikethrough are unaffected.
- Blink (SGR 5/6) off by default — accessibility concern, frequently emitted by accident. When enabled, affected cells blink at ~1 Hz.
- Font blending controls how glyph edges anti-alias onto the background, affecting perceived stroke weight (especially dark text on light themes). Leave on **Default** unless text looks too thin or too heavy.
- Blending modes: `Default` (defers to theme, which falls back to `srgb-over`), `srgb-over` (slopdesk baseline; stroke weight as designer intended), `macos-like` (macOS native, Display P3 path, closest to other Mac apps), `linear` (physically-correct linear-light; pure white stays pure but thin dark strokes come out ~15% lighter), `perceptual` (like `linear` but boosts thin dark text back toward intended weight).
- Blending is taste-driven and subtle; switch modes with text on screen and keep whichever looks crispest.

## Keybindings

| Action | Keys |
|--------|------|
| Increase font size | `⌘+` |
| Decrease font size | `⌘-` |
| Reset font size to default | `⌘0` |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `font-family` | `"JetBrains Mono"` (bundled) | Primary monospace font family, all normal text. |
| `font-family-fallback` | `""` (none) | Comma-separated fallback families; used when primary lacks a glyph (CJK, Nerd Font icons, etc.). |
| `font-size` | (theme-defined or 13) | Font size in points. |
| `font-ligatures` | `off` | Ligature mode: `off`, `calt`, `dlig`. |
| `font-ligatures-alphabet` | `false` | When `true`, applies ligation to alphabetic sequences too. |
| `font-bold` | `auto` | Bold mode: `auto`, `off`, `primary-only`, `synthetic`. |
| `font-italic` | `auto` | Italic mode: `auto`, `off`, `primary-only`, `synthetic`. |
| `font-underline` | `true` (on) | Whether SGR underlined cells draw the underline. Does not affect OSC 8 link underlines or strikethrough. |
| `font-blink` | `false` (off) | Whether SGR 5/6 blink renders (~1 Hz). Off by default; accessibility concern. |
| `font-blending` | `default` | Glyph anti-aliasing blend: `default`, `srgb-over`, `macos-like`, `linear`, `perceptual`. |
| `line-height` | `default` | Cell height: `default`, `compact` (1.0×), `loose` (1.2×), or a custom numeric multiplier. |

## Visual spec

### font-setting.png — Font Family Settings Panel (Auto-match ON, Light Theme tab selected)

Standard macOS preferences panel, rounded-rect chrome (traffic lights top-left, no titlebar text). Narrow left sidebar, nav items with ~16pt icon glyphs: General, Shell, Controls, Editor, Agents, Appearance (selected, bold/highlighted system-blue or dark-teal), Recipes, Key Bindings, Advanced. Sidebar background light warm gray (~#F5F5F4).

Main content white. Top: all-caps "FONT FAMILY" section header (gray, ~11pt, tracked). Below: "Settings for" label preceding pill toggle tabs: "Computed", "Global", "Light Theme" (selected — filled dark, white text), "Dark Theme", "Fallback". Inactive tabs are outlined/ghost pills.

Below tabs: contextual note "Saved into the light theme's TOML" (muted gray). Then a green toggle (ON) labeled "Auto-match weight & style".

Form has four left-aligned bold labels, two-column: "Font Family", "Font Family (Bold)", "Font Family (Italic)", "Font Family (Bold Italic)". In Auto-match mode only the primary row has an active combobox ("JetBrains Mono" + disclosure chevron); Bold/Italic/Bold Italic rows are grayed/disabled.

Open Font Family dropdown: scrollable list grouped alphabetically with single-letter headers (F, G, I, J). Each row has a "Aa" specimen in the font (~13pt) then the name. Selected item (JetBrains Mono) has a checkmark; highlighted row (GoogleSansCode-Regular) has a blue/teal hover background. Visible names: Fira Code, GoogleSansCode-Regular, IBM Plex Mono, Iosevka Term Slab, JetBrains Mono (checked).

Below pickers, two side-by-side borderless rounded-rect buttons: "Install font" and "Open font fol[der]" (truncated). Bottom of view: next section header "CURSOR" begins.

### font-setting-bold.png — Font Family Settings Panel (Auto-match OFF, Global tab selected)

Same layout, "Global" tab selected. A red/orange banner replaces the muted note: "Overrides theme; takes priority everywhere". "Auto-match weight & style" is OFF (gray/unchecked, red outline for override context).

With Auto-match OFF the Font Family combobox shows "Unset" (grayed placeholder). Open dropdown lists all IBM Plex Mono face variants, each a separate "Aa" row: Bold, Bold Italic, ExtraLight, ExtraLight Italic, Italic, Light, Light Italic, Medium — every face surfaced separately for manual assignment.

### font-JetBrainsMono.png — JetBrains Mono terminal sample (light theme)

Rounded-rect macOS terminal, white/off-white background, colored traffic lights (red/yellow/green filled). Title "vi CreDITS.md" centered gray (~12pt). Content: vim editing markdown. JetBrains Mono: slightly rounded letterforms, medium x-height, moderate stroke contrast. Syntax colors: section headers muted blue-purple (`## Built-in Themes`), list dashes orange-red, bold Markdown bold monospace, hyperlinks orange, plain text near-black. Status line bottom-right "129,69-67   91%" gray monospace. Line spacing default (~1.1–1.15×).

### font-Menlo.png — Menlo terminal sample (light theme, unfocused / background)

Same structure, gray traffic lights (unfocused — all three gray). Title "vi CreDITS.md", white background. Menlo: taller x-height, wider glyphs, softer curves, classic macOS system monospace. Same syntax colors.

### font-IBMPlexMono.png — IBM Plex Mono terminal sample (light theme, unfocused)

Gray traffic lights. IBM Plex Mono: geometric, slightly humanist, noticeable ink traps at junctions, clean terminations, prominent serifs on some glyphs, wider apparent width than JetBrains Mono. Same syntax colors, white background.

### font-Cousine.png — Cousine terminal sample (light theme, colored traffic lights)

Colored (active) traffic lights. Cousine: metric-compatible with Courier New, slightly narrower than Courier, clean stroke ends, typewriter feel, low-contrast strokes. White background, same syntax colors, vim.

### line-height-1.png — Compact line height (1.0×)

Small compact terminal, `git log` output, colored traffic lights, title "git log". **Dark** background (~#2D2D2D). Commit hashes orange/amber; Author/Date lines light gray near-white; message text off-white. Line spacing tight — ~cap-height with nearly no leading. Compact (1.0×).

### line-height-1.2.png — Loose line height (1.2×)

Same `git log` content, slightly taller window, same dark background/colors, colored traffic lights. Clearly larger gaps between hash / Author / Date / message lines, easier to scan. Loose (1.2×).

### text-styles.png — Text styles showcase (dark theme, small window)

Small dark terminal (gray traffic lights, unfocused). Title "abner@MacBook-AB: ~". Table-formatted SGR demo: left column style names, right column styled text. Rows: `regular`, `bold` (heavier strokes), `dim` (muted), `italic` (slanted), `underline`, `double-under`, `curly-under` (wavy), `dotted-under`, `dashed-under`, `strike`, `reverse` (inverted fg/bg), `blink`, `combined` (bold+italic+underline+orange). Second section "colored underlines (SGR 58 — underline color independent of fg)" rows: `single_red`, `double_green`, `curly_blue`, `dotted_orange`, `dashed_magenta`, `curly_indexed` — each "The quick brown fox jumps over the lazy dog" with the named underline/color. Small monospace, dark background (~#2B2B2B), thin red status line at bottom.

### blending-srgb-over-dark.png — srgb-over blending, dark theme

Large rounded-rect terminal, very dark gray-slate background (~#282C34), colored traffic lights, title "git log" medium gray. `git log`: hashes golden-orange (#E5C07B range), bold "HEAD → main" teal/cyan, Author/Date off-white, message off-white monospace. Stroke weight moderate and balanced — the reference/baseline; crisp and properly weighted for dark background.

### blending-srgb-over-light.png — srgb-over blending, light theme

Same `git log` on white/near-white, colored traffic lights. Hashes orange-brown, "HEAD → main" bold teal, plain text near-black. Stroke weight well-balanced — as the designer intended on light backgrounds.

### blending-macos-like-dark.png — macos-like blending, dark theme

Very similar to srgb-over-dark; subtle difference is slightly different thin-stroke weight (Display P3 path). Closely matches other macOS apps. On a non-P3 screenshot the difference from srgb-over is minimal.

### blending-macos-like-light.png — macos-like blending, light theme

Same `git log` on white, macOS native Display P3 blend path. Slightly different sub-pixel treatment on thin stroke terminals — most visible on 'l', 'i', 't'. Thin blinking bar cursor bottom-left.

### blending-linear-dark.png — linear blending, dark theme

Same dark background/content. Dark-on-dark differences are subtle; thin dark strokes are ~15% lighter than srgb-over, manifesting as very slightly less-bold-feeling text.

### blending-perceptual-light.png — perceptual blending, light theme

Same light background. perceptual compensates for linear's tendency to make thin dark text too faint on light themes. Stroke weight similar to or slightly heavier than linear. Thin bar cursor bottom-left. Recommended for users who prefer linear but find text too faint.

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
- **Needs a host-side seam.** The `~/.config/slopdesk/fonts/` + CoreText flow assumes a local install, but SlopDesk renders (libghostty) on the remote HOST. Font install must happen on the host, not the client; the client Settings UI configures font names only. `slopdesk font import` must be a host-side operation (e.g. via the slopdesk-ctl agent socket or a dedicated protocol message). Initial client: expose font family as a text entry (no local discovery); note that fonts install on the host.
- Ghostty (libghostty) has its own font loading. Map `font-family` / `font-family-fallback` / `font-size` to Ghostty config keys passed to `TerminalConfigBuilder`. Ghostty supports `.ttf`/`.otf` system and user fonts.

### Font Family scope tabs (Computed / Global / Light Theme / Dark Theme / Fallback)
- SlopDesk's ThemeStore has light/dark variants, so per-theme font storage maps onto the Light/Dark split; Global writes the top-level PreferencesStore/config. Implement as a scope selector (Global / Light Theme / Dark Theme / Fallback) above the Font Family combobox in Appearance, writing to the appropriate config layer.

### Auto-match weight & style toggle
- **Maps.** Ghostty supports separate bold/italic face specification. ON: pass only `font-family`; Ghostty picks bold/italic automatically. OFF: surface `font-family-bold`, `font-family-italic`, `font-family-bold-italic` (map to Ghostty's keys).

### Font size shortcuts (⌘+/⌘-/⌘0)
- **Maps.** In SlopDeskClientUI, window-level keybindings that adjust the font-size preference and trigger a TerminalConfigBuilder rebuild + libghostty `updateConfiguration`. A font-SIZE change changes cell pixel size, so for a fixed pane viewport the cell COUNT changes → SIGWINCH/PTY reflow (same as a line-height change; coordinate with the existing resize debounce). Only a font FAMILY/STYLE change is grid-preserving (cell box unchanged). The earlier "size is reflow-free" note was wrong; see `PreferencesStore.increaseFontSize()`.

### Line height
- **Maps via Ghostty.** Ghostty has `cell-height` / line-height config. Map Default/Compact/Loose/Custom to Ghostty values via TerminalConfigBuilder. Changing line height changes cell pixel dimensions → SIGWINCH/resize; coordinate with the resize debounce.

### Ligatures
- **Maps.** Ghostty supports `font-feature`. Map `off` → no features, `calt` → `+calt`, `dlig` → `+calt +dlig`. `font-ligatures-alphabet` has no direct Ghostty equivalent; may need a custom feature list.

### Bold/Italic/Underline/Blink modes
- **Maps.** Ghostty has `font-style-bold`, `font-style-italic` accepting `auto`/`off` etc. Four-mode mapping: Auto → Ghostty default, Off → `off`, Primary Only → `false` for fallback, Synthetic → Ghostty's faux-bold/faux-italic flags. Underline on/off → Ghostty's `underline` key. Blink: Ghostty supports SGR blink — expose a toggle wired to libghostty config.

### Font blending
- **Maps to Ghostty's `font-thicken` / blending config.** Ghostty has `font-thicken` (boolean macOS-style subpixel thickening) and its own blending pipeline. The five modes don't map 1:1. Recommended: `Default` → Ghostty default, `macos-like` → enable `font-thicken`, others best-effort. Document as a known deviation; expose only Default/macOS-like in the initial client.

### Remote rendering boundary
- All font rendering happens on the HOST inside libghostty. The client sees only HEVC video frames over the slopdesk video path. Font config changes transmit to the host and take effect on the next frame. No local client-side font rendering — blending differences are encoded by the HOST's libghostty, not the client GPU.

### iOS client
- Font size `⌘+`/`⌘-` map to iOS equivalents (pinch-to-zoom or Settings) — no software-keyboard shortcut path. Expose font size as a stepper in iOS Appearance.
- Font installation is entirely host-side; no font picker on iOS beyond a text field for the family name.
