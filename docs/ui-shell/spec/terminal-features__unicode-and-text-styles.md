# Unicode and Text Styles

## Summary

SlopDesk renders text via GPU (Metal on macOS) with glyph caching. It supports the full Unicode range (U+0000–U+10FFFF): combining marks, wide East Asian characters, RTL/bidirectional text, color emoji with multi-codepoint ZWJ sequences, programming ligatures (for fonts that ship them), an embedded Nerd Font for Private Use Area icon glyphs, and the full SGR text-style set (bold, italic, dim, underline variants, blink, strikethrough, reverse). Color depth is 24-bit truecolor; 256-color and 16-color palettes are also advertised via `TERM`/`COLORTERM`.

## Behaviors

- Full range U+0000–U+10FFFF; combining marks stack over base glyphs.
- Wide East Asian characters (CJK ideographs, kana, full-width forms) each occupy two cells.
- RTL and bidirectional text is shaped correctly.
- Color emoji render using the system emoji font.
- Multi-codepoint emoji (ZWJ families, skin-tone modifier sequences, flag sequences) collapse into a single two-cell glyph.
- Variation selectors (VS-15 text, VS-16 emoji) switch between text and emoji presentation.
- Some Unicode blocks are "East-Asian-Ambiguous"; by default the enclosed-alphanumerics block widens to two cells. Additional blocks are configurable.
- Programming ligatures shaped for fonts that ship them (Fira Code, JetBrains Mono, Iosevka, Cascadia Code, …): `=>`, `!=`, `>=`, `->` join into one glyph. Ligature level is configurable (can be disabled or set to a level).
- Embedded Nerd Font used automatically for Private Use Area icon glyphs; no install needed. A custom patched Nerd Font can be added as fallback.
- SGR text styles: bold (real bold face), italic (real italic face), dim/faint (reduced intensity), underline (five shapes: single, double, curly/undercurl, dotted, dashed), blink (slow and rapid), strikethrough, reverse/inverse (fg↔bg swap), fg/bg color.
- Each underline variant has its own SGR shape code and can carry an independent underline color: SGR 58 sets a distinct underline color (separate from text fg), SGR 59 resets it. 256-color palette underline supported (SGR 58;5;N).
- 24-bit truecolor (16.7M colors) supported; advertised via `TERM` and `COLORTERM`.
- Synthetic styling (faux bold/italic/underline/blink for fonts lacking a real face) available in Settings.

## Keybindings

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| Settings → Appearance → Text (ligature level) | enabled (level unspecified) | Whether/at what level programming ligatures are shaped; can be disabled. |
| Settings → Appearance → Text (bold rendering) | real bold face | Real bold face vs synthetic bold. |
| Settings → Appearance → Text (italic rendering) | real italic face | Real italic face vs synthetic italic. |
| Settings → Appearance → Text (underline rendering) | system default | Underline style rendering options. |
| Settings → Appearance → Text (blink rendering) | system default | Blink rendering options. |
| Settings → Advanced → Widen East-Asian-Ambiguous Blocks | enclosed alphanumerics block widened to 2 cells | Which East-Asian-Ambiguous blocks are treated as two cells wide. |

## Visual spec

### emoji.png — Emoji rendering demo

Standard macOS window chrome (rounded corners, ~16 px radius; `#f5f5f5` bg). Traffic lights top-left: red `#ff5f57`, yellow `#ffbd2e`, green `#28c940`, ~14 px diameter, ~8 px gap. Centered title "abner@MacBook-Pro: ~" at ~50% gray (`#888`).

Terminal body: dark-on-light — off-white bg `#f8f8f8`, near-black text `#1a1a1a`. Monospaced (JetBrains Mono-like), ~14 pt, ~1.4× line spacing. Prompt: tilde `~` cyan/teal, right-pointing triangle `▷` green (`#28c940`-ish), cursor a solid black vertical block.

Content rows (top to bottom):
1. Command: `~ ▷  slopdesk features emoji` — prompt + command in default fg.
2. Section header: `▶ emoji — colorful and multi-codepoint emojis (ZWJ, flags, skin tones)` — `▶` filled triangle in prompt green; regular weight.
3. `single:` + 8 color emoji, each two cells: 🎉 ✨ 🚀 🔥 💡 🦀 🐙 🎨.
4. `skin tones:` + 6 thumbs-up variants across the skin-tone scale (light → dark), each a distinct two-cell colored glyph.
5. `ZWJ family:` + 4 ZWJ-sequence emoji (family/person groups, multi-codepoint rendered as one wide glyph).
6. `flags (ZWJ):` + 8 flag emoji (pride, pirate, checkered, US, Japan, China, Germany, France, South Korea), each one wide glyph.
7. `presentation:` — variation selectors: text star `✲` vs emoji sun `🌤`, text heart `♥` vs emoji heart `❤`, text check `✓` vs emoji check `✔` — side-by-side pairs of the same codepoint in each presentation.
8. `wide + text:` — `Hello 🎉  world 🦀  rust` — emoji inline with ASCII, confirming two-cell spacing without reflow.
9. Trailing empty prompt line.

Colors/type: bg `#f8f8f8`, body `#1a1a1a`, prompt tilde cyan ~`#56b6c2`, prompt arrow green ~`#28c940`, section label near-black. No sidebar/tabs/toolbar beyond window chrome.

### ligature.png — Programming ligature rendering demo

Same window chrome/layout as emoji.png. Bg `#f8f8f8`, text `#1a1a1a`, monospaced.

Content rows:
1. `~ ▷  slopdesk features ligature`.
2. `▶ ligature — programming ligatures (→, ⇒, ≠, ≥, …)` — header; parenthesized examples already rendered as joined ligature glyphs.
3. `arrows:` — 7 arrows `→` `←` `⇒` `⇐` `⟶` `⟵` `↔` from `->`, `<-`, `=>`, `<=`, `-->`, `<--`, `<->`.
4. `compare:` — 6 comparisons `=` `≠` `≤` `≥` `≡` `≢` from `=`, `!=`, `<=`, `>=`, `===`, `!==`.
5. `logic:` — `&&` `||` `??` `!!` as joined double-character ligatures.
6. `haskell:` — `>>=` `==>` `<$>` `<*>` `<|>` Haskell/FP ligatures.
7. `scope:` — `::` `++` `..` `...` scope/range ligatures.
8. `examples:` — inline snippet: `let f = x ⇒ x + 1;   if (a ≠ b) a → b;   xs ▷ map(f)`.
9. Lighter-text note (wraps to two lines): `(if your font has no ligatures these render as separate glyphs — that's fine.)`.
10. Trailing prompt.

Ligature glyphs appear as single unified symbols at the same cap-height as regular characters, not stacked. Arrows/comparisons/logic each occupy the same cell width as their source ASCII (no width change, purely visual joining).

### text-styles.png — Text styles showcase

Same window chrome, lower resolution/zoom, DARK terminal theme (~`#1e1e1e` bg, light text `#d4d4d4`). Traffic lights still top-left (small, dark). Title: `abner@MacBook-AB: ~` muted gray.

Two-column table rendered in the terminal: left = style name/demo, right (after `|`) = style applied to sample text.

Header row: `▶ styles — bold / italic / underline / strike / reverse`

| Left label / demo | Pipe | Right sample text |
|---|---|---|
| `regular` | `\|` | `plain text` (normal weight/color) |
| `bold` | `\|` | **`bold text`** (heavier weight) |
| `dim` | `\|` | `dim text` (faint, ~60% opacity of normal) |
| `italic` | `\|` | *`italic text`* (slanted) |
| `underline` (single underline on label) | `\|` | `underlined text` (single underline) |
| `double-under` (double underline on label) | `\|` | `double-underlined` (two lines, visible gap) |
| `curly-under` (curly underline on label) | `\|` | `curly underline` (sinusoidal wave, spell-check style) |
| `dotted-under` (dotted underline on label) | `\|` | `dotted underline` |
| `dashed-under` (dashed underline on label) | `\|` | `dashed underline` |
| `strike` | `\|` | ~~`strikethrough`~~ (line through middle) |
| `reverse` (label INVERSE VIDEO: white text on filled black bg) | `\|` | `reverse video` (same inverse — filled black bg, white text) |
| `blink` | `\|` | `blinking` (static in screenshot) |
| `combined` | `\|` | `bold italic underline orange` — all attributes at once: orange, bold, italic, underlined |

Below the table, colored underlines section: `colored underlines (SGR 58 — underline color independent of fg):`. Five rows, each the shape name left-aligned (space-padded) then pangram "The quick brown fox jumps over the lazy dog" underlined in the color; fg stays white/default:
- `single_red....` — single underline, red
- `double_green...` — double underline, green
- `curly__blue....` — curly underline, blue
- `dashed_orange..` — dashed underline, orange
- `curly__indexed.` — curly underline, indexed 256-color (`SGR 58;5;196` = xterm color 196, bright red)

Trailing note `(SGR 58;5;196 — 256-color palette)` in smaller/dimmer parenthetical. Cursor visible as a blinking block at end.

Color: dark theme. Bg ~`#1e1e2e` (very dark blue-black), default fg ~`#cdd6f4` (light lavender-white). Underlines saturated: red, green, blue, orange, bright-red indexed. `reverse` label fills full cell bg white, renders label black — solid inverse block, no partial fill. `dim` text noticeably lower luminance. `combined` text orange + bold + italic + underlined.

## Screenshots

- `emoji.png`
- `ligature.png`
- `text-styles.png`

## SlopDesk mapping notes

### Maps 1:1

- **Full Unicode (U+0000–U+10FFFF), combining marks, wide CJK, BiDi**: libghostty handles natively — no slopdesk-layer work. The `TerminalSurface` / `TerminalRenderingView` seam passes cell grids through directly.
- **Color emoji, ZWJ sequences, variation selectors, skin-tone modifiers**: libghostty uses the system emoji font (Apple Color Emoji on macOS/iOS) and collapses multi-codepoint at the shaper level. No slopdesk-layer work.
- **SGR text styles (bold, italic, dim, underline variants, blink, strikethrough, reverse, color)**: standard VT/xterm, handled by libghostty's PTY parser and renderer. SlopDesk's wire codec passes them through the terminal data channel unchanged. `TerminalConfigBuilder` can control bold/italic face selection (already used for theme color overrides).
- **Underline color (SGR 58/59) and shape (single/double/curly/dotted/dashed)**: libghostty supports all five shapes + SGR 58 color. Wire codec carries raw bytes; no transformation.
- **24-bit truecolor + 256-color + 16-color**: libghostty advertises and renders all three. `TERM`/`COLORTERM` set by libghostty/Ghostty at PTY spawn.
- **Programming ligatures**: libghostty supports shaping for fonts that ship them. Ligature level maps to a config key passed via `TerminalConfigBuilder`; client exposes it as a preference feeding the libghostty config.
- **Nerd Font / Private Use Area glyphs**: Ghostty embeds Nerd Font glyphs; libghostty handles PUA icons automatically. User may supply a custom patched font as fallback (Settings → Appearance).
- **East-Asian-Ambiguous block width**: libghostty/Ghostty has ambiguous-width config. Map to `TerminalConfigBuilder` / `GhosttyConfig` key.
- **Synthetic bold/italic (faux styling)**: libghostty supports it. Expose as a preference in Settings → Appearance → Text.

### Requires attention

- **Settings → Appearance → Text (ligature level UI)**: needs a per-level ligature selector round-tripping to a libghostty config key. The Ghostty key is `font-feature` or `grapheme-width-method`; verify against libghostty's public config API before wiring.
- **Settings → Advanced → Widen East-Asian-Ambiguous Blocks (per-block selector)**: Ghostty has a single `grapheme-width-method` / `adjust-cell-width` config, not per-block. Fine-grained per-block control may not be achievable with libghostty as-is; a coarser "widen all ambiguous" toggle is the achievable approximation. Flag as a fidelity gap.
- **Remote host `TERM`/`COLORTERM` propagation**: on a remote SSH session (slopdesk's primary use case) the PTY is HOST-side and inherits `TERM`/`COLORTERM` from the slopdesk-hostd environment, not the client. Ensure slopdesk-hostd sets `TERM=xterm-256color` and `COLORTERM=truecolor` (or `TERM=ghostty` if shipping a terminfo entry) at PTY spawn so remote programs detect truecolor. Host-side plumbing, not client rendering.
- **Blink rendering**: libghostty supports slow/rapid blink. The animation loop runs in the CLIENT renderer via a display-link timer — no remote-side work — but ensure the client render loop is not suppressed when idle (idle-skip must not freeze blink).
- **GPU renderer (Metal) and ligature shaping on iOS**: libghostty's Metal renderer works on iOS (same GPU path); ligature shaping uses Core Text as on macOS. No divergence expected, but verify with `bash scripts/check-ios.sh` after any font/config change.
