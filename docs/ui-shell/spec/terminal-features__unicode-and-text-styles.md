# Unicode and Text Styles

## Summary

SlopDesk renders text via GPU (Metal on macOS) with glyph caching. It supports
the full Unicode range (U+0000–U+10FFFF) including combining marks, wide East Asian characters,
right-to-left/bidirectional text, color emoji with multi-codepoint ZWJ sequences, programming
ligatures for supporting fonts, an embedded Nerd Font for Private Use Area icon glyphs, and the
full set of SGR text-style attributes (bold, italic, dim, underline variants, blink, strikethrough,
reverse video). Color depth is 24-bit truecolor; 256-color and 16-color palettes are also
advertised via `TERM`/`COLORTERM`.

## Behaviors

- Full Unicode range U+0000–U+10FFFF rendered; combining marks stack over base glyphs.
- Wide East Asian characters (CJK ideographs, kana, full-width forms) each occupy two terminal cells.
- Right-to-left and bidirectional text is shaped correctly.
- Color emoji render using the system emoji font.
- Multi-codepoint emoji sequences (ZWJ families, skin-tone modifier sequences, flag sequences) collapse into a single two-cell glyph.
- Variation selectors (VS-15 text, VS-16 emoji) are honored to switch between text and emoji presentation.
- A handful of Unicode blocks are classified "East-Asian-Ambiguous"; by default the enclosed alphanumerics block widens to two cells. Additional blocks are configurable.
- Programming ligatures are shaped for fonts that ship them (Fira Code, JetBrains Mono, Iosevka, Cascadia Code, …): sequences like `=>`, `!=`, `>=`, `->` join into a single glyph.
- Ligature level is configurable: can be disabled or set to a specific level.
- An embedded Nerd Font is used automatically for Private Use Area icon glyphs; no extra installation required. A custom patched Nerd Font can be added as a fallback.
- SGR text styles supported: bold (real bold face), italic (real italic face), dim/faint (reduced intensity), underline (five shapes: single, double, curly/undercurl, dotted, dashed), blink (slow and rapid), strikethrough, reverse/inverse (fg↔bg swap), foreground/background color.
- Each underline variant has its own SGR shape code and can carry an independent underline color (SGR 58) separate from the text foreground.
- Underline color is independent of the foreground color: SGR 58 sets a distinct underline color; SGR 59 resets it.
- 256-color palette underline color is supported (SGR 58;5;N).
- 24-bit truecolor (16.7 million colors) is supported; support is advertised via `TERM` and `COLORTERM` environment variables.
- Synthetic styling options (e.g. faux bold/italic for fonts that lack a real bold/italic face) are available for bold, italic, underline, and blink in Settings.

## Keybindings

| Action | Keys |
|--------|------|
| (none documented on this page) | — |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| Settings → Appearance → Text (ligature level) | enabled (level unspecified) | Controls whether programming ligatures are shaped and at what level; can be disabled. |
| Settings → Appearance → Text (bold rendering) | real bold face | Toggles between using the font's real bold face or synthetic bold. |
| Settings → Appearance → Text (italic rendering) | real italic face | Toggles between using the font's real italic face or synthetic italic. |
| Settings → Appearance → Text (underline rendering) | system default | Controls underline style rendering options. |
| Settings → Appearance → Text (blink rendering) | system default | Controls blink rendering options. |
| Settings → Advanced → Widen East-Asian-Ambiguous Blocks | enclosed alphanumerics block widened to 2 cells | Selects which East-Asian-Ambiguous Unicode blocks are treated as two cells wide. |

## Visual spec

### emoji.png — Emoji rendering demo

Overall layout: standard macOS window chrome (rounded corners, ~16 px radius; light gray/white
`#f5f5f5` background). Traffic-light window controls top-left: red (`#ff5f57`), yellow (`#ffbd2e`),
green (`#28c940`), all ~14 px diameter with ~8 px gap. Window title centered in gray text
"abner@MacBook-Pro: ~" at approximately 50% gray (`#888`).

Terminal body: dark-on-light — off-white background (`#f8f8f8`), text in near-black (`#1a1a1a`).
Monospaced font (looks like JetBrains Mono or similar), approximately 14 pt, generous line spacing
(~1.4×). Prompt indicators visible: tilde `~` in cyan/teal, right-pointing triangle `▷` in green
(`#28c940`-ish), cursor as a solid black vertical block.

Content rows (from top):
1. Command line: `~ ▷  slopdesk features emoji` — prompt + command in the default foreground.
2. Section header: `▶ emoji — colorful and multi-codepoint emojis (ZWJ, flags, skin tones)` — the
   `▶` is a filled triangle in the same green as the prompt arrow; text is regular weight.
3. `single:` label followed by 8 color emoji glyphs in a horizontal row, each occupying two cells:
   🎉 ✨ 🚀 🔥 💡 🦀 🐙 🎨 — full system emoji rendering with color.
4. `skin tones:` label followed by 6 thumbs-up emoji variants across the skin tone modifier scale
   (light → dark), each rendered as a distinct two-cell colored glyph.
5. `ZWJ family:` label followed by 4 ZWJ-sequence emoji (family/person group glyphs, each multi-
   codepoint but rendered as one wide glyph).
6. `flags (ZWJ):` label followed by 8 flag emoji including pride flag, pirate flag, checkered flag,
   US, Japan, China, Germany, France, South Korea — each a single wide glyph.
7. `presentation:` label demonstrating variation selectors: text-presentation star `✲` vs
   emoji-presentation sun `🌤`, text heart `♥` vs emoji heart `❤`, text checkmark `✓` vs emoji
   checkmark `✔` — side-by-side pairs showing the same codepoint in each presentation.
8. `wide + text:` label showing `Hello 🎉  world 🦀  rust` — emoji inline with regular ASCII text,
   confirming correct two-cell wide spacing without reflow.
9. Trailing empty prompt line.

Colors/typography: background `#f8f8f8`, body text `#1a1a1a`, prompt tilde cyan ~`#56b6c2`, prompt
arrow green ~`#28c940`, section label text same near-black. No sidebar, no tabs, no toolbar beyond
window chrome.

### ligature.png — Programming ligature rendering demo

Same window chrome and layout as emoji.png. Background `#f8f8f8`, text `#1a1a1a`, monospaced font.

Content rows:
1. `~ ▷  slopdesk features ligature` — command line.
2. `▶ ligature — programming ligatures (→, ⇒, ≠, ≥, …)` — section header; the parenthesized
   examples are already rendered as ligature glyphs (single joined symbols).
3. `arrows:` — 7 ligature arrows: `→` `←` `⇒` `⇐` `⟶` `⟵` `↔` — all shaped as joined single
   glyphs from `->`, `<-`, `=>`, `<=`, `-->`, `<--`, `<->` source sequences.
4. `compare:` — 6 comparison ligatures: `=` `≠` `≤` `≥` `≡` `≢` — from `=`, `!=`, `<=`, `>=`,
   `===`, `!==`.
5. `logic:` — `&&` `||` `??` `!!` — rendered as joined double-character ligatures.
6. `haskell:` — `>>=` `==>` `<$>` `<*>` `<|>` — Haskell/FP ligatures.
7. `scope:` — `::` `++` `..` `...` — scope and range ligatures.
8. `examples:` — full code snippet using ligatures inline:
   `let f = x ⇒ x + 1;   if (a ≠ b) a → b;   xs ▷ map(f)` — demonstrates real-world use.
9. Explanatory note in lighter text: `(if your font has no ligatures these render as separate
   glyphs — that's fine.)` — wraps to two lines.
10. Trailing prompt.

All ligature glyphs appear as single unified symbols at the same cap-height as regular characters,
not stacked. The arrows, comparisons, and logic operators each occupy the same cell width as their
source ASCII characters (no width change, purely visual joining).

### text-styles.png — Text styles showcase

Window chrome same as other screenshots but rendered at lower resolution/zoom (darker background
visible — this window appears to use a DARK terminal theme, approximately `#1e1e1e` background
with light text `#d4d4d4`). The macOS traffic lights are still visible top-left (small, dark theme
context). Title bar: `abner@MacBook-AB: ~` in muted gray.

Content: a two-column table layout rendered entirely in the terminal. Left column is the style
name/demo, right column after `|` pipe character is the style applied to the sample text. Rows
(top to bottom):

Header row: `▶ styles — bold / italic / underline / strike / reverse`

| Left label / demo | Pipe | Right sample text |
|---|---|---|
| `regular` | `\|` | `plain text` (normal weight, normal color) |
| `bold` | `\|` | **`bold text`** (visibly heavier weight) |
| `dim` | `\|` | `dim text` (visibly lower contrast / faint, ~60% opacity of normal) |
| `italic` | `\|` | *`italic text`* (slanted) |
| `underline` (with single underline on the label itself) | `\|` | `underlined text` (single underline drawn under the baseline) |
| `double-under` (double underline on label) | `\|` | `double-underlined` (two underline lines, visible gap between them) |
| `curly-under` (curly/wavy underline on label) | `\|` | `curly underline` (sinusoidal wave under text, as used for spell-check) |
| `dotted-under` (dotted underline on label) | `\|` | `dotted underline` |
| `dashed-under` (dashed underline on label) | `\|` | `dashed underline` |
| `strike` | `\|` | ~~`strikethrough`~~ (horizontal line through middle of glyphs) |
| `reverse` (label has INVERSE VIDEO: white text on black bg block, fully filled cell background) | `\|` | `reverse video` (same inverse — black bg filled block, white text) |
| `blink` | `\|` | `blinking` (shown in static screenshot as normal text) |
| `combined` | `\|` | `bold italic underline orange` — all three attributes simultaneously; text is rendered in orange color, bold weight, italic slant, with underline |

Below the style table, a section for colored underlines labeled:
`colored underlines (SGR 58 — underline color independent of fg):`

Five demo rows, each showing the underline shape name left-aligned (padded with spaces) then the
pangram sentence "The quick brown fox jumps over the lazy dog" with the underline in the specified
color; text foreground stays white/default:
- `single_red....` — single underline in red
- `double_green...` — double underline in green
- `curly__blue....` — curly underline in blue
- `dashed_orange..` — dashed underline in orange
- `curly__indexed.` — curly underline in an indexed 256-color palette color (noted `SGR 58;5;196`
  — that is xterm color 196, a bright red)

The trailing note `(SGR 58;5;196 — 256-color palette)` appears in smaller/dimmer text as a
parenthetical.

Terminal cursor visible as a blinking block at the end.

Color treatment of this screenshot: dark theme. Background ~`#1e1e2e` (very dark blue-black).
Default text foreground ~`#cdd6f4` (light lavender-white). Colored underlines are saturated:
red, green, blue, orange, bright-red indexed. The `reverse` row's label fills the full cell
background with white and renders the label in black — solid inverse-video block, no partial fill.
The `dim` row's text is noticeably lower luminance than regular. The `combined` row's text is
visibly orange, bold, italic, underlined simultaneously.

## Screenshots

- `emoji.png`
- `ligature.png`
- `text-styles.png`

## SlopDesk mapping notes

### Maps 1:1

- **Full Unicode rendering (U+0000–U+10FFFF), combining marks, wide CJK, BiDi**: libghostty
  (Ghostty renderer) handles all of this natively — no slopdesk-layer work needed. The
  `TerminalSurface` / `TerminalRenderingView` seam passes cell grids through directly.

- **Color emoji with ZWJ sequences, variation selectors, skin-tone modifiers**: libghostty uses
  the system emoji font (Apple Color Emoji on macOS/iOS) and handles multi-codepoint collapsing
  at the shaper level. No slopdesk-layer work needed.

- **SGR text styles (bold, italic, dim, underline variants, blink, strikethrough, reverse, color)**:
  All SGR attributes are part of the standard VT/xterm protocol that libghostty's PTY parser and
  renderer handle. SlopDesk's wire codec passes them through the terminal data channel unchanged.
  `TerminalConfigBuilder` can control bold/italic face selection (already used for theme color
  overrides).

- **Underline color (SGR 58/59) and underline shape (single/double/curly/dotted/dashed)**:
  libghostty supports all five underline shapes and SGR 58 underline color. The wire codec carries
  the raw bytes; no transformation needed.

- **24-bit truecolor + 256-color + 16-color**: libghostty advertises and renders all three. The
  `TERM`/`COLORTERM` env vars are set by libghostty/Ghostty at PTY spawn time.

- **Programming ligatures**: libghostty supports ligature shaping for fonts that ship them. The
  ligature level setting maps to a config key in the terminal configuration passed via
  `TerminalConfigBuilder`. The slopdesk client can expose this as a preference that feeds into
  the libghostty config.

- **Nerd Font / Private Use Area glyphs**: Ghostty embeds Nerd Font glyphs; libghostty will
  handle PUA icons automatically. The user may also supply a custom patched font as a fallback
  (preference exposed in client Settings → Appearance).

- **East-Asian-Ambiguous block width**: libghostty/Ghostty has config for ambiguous-width
  handling. Map to `TerminalConfigBuilder` / `GhosttyConfig` key.

- **Synthetic bold/italic (faux styling)**: libghostty supports this. Expose as a user preference
  in client Settings → Appearance → Text.

### Requires attention

- **Settings → Appearance → Text (ligature level UI)**: SlopDesk's preferences UI needs to
  expose a per-level ligature selector that round-trips to a libghostty config key. The exact
  Ghostty config key is `font-feature` or `grapheme-width-method`; verify against libghostty's
  public config API before wiring.

- **Settings → Advanced → Widen East-Asian-Ambiguous Blocks (per-block selector)**: Ghostty has
  a single `grapheme-width-method` / `adjust-cell-width` config rather than a per-block selector.
  Fine-grained per-block control of ambiguous-width blocks may not be achievable with libghostty
  as-is; a coarser "widen all ambiguous" toggle is the achievable approximation. Flag this as a
  fidelity gap.

- **Remote host `TERM`/`COLORTERM` propagation**: On a remote SSH session (slopdesk's primary
  use case) the PTY is on the HOST side. The host's PTY inherits `TERM`/`COLORTERM` from the
  slopdesk-hostd environment, not from the client. Ensure slopdesk-hostd sets `TERM=xterm-256color`
  and `COLORTERM=truecolor` (or `TERM=ghostty` if shipping a terminfo entry) when spawning the
  PTY so that remote programs correctly detect truecolor. This is host-side plumbing, not a
  client rendering issue.

- **Blink rendering**: libghostty supports blink (slow and rapid). The blink animation loop runs
  in the renderer on the CLIENT side, driven by a display-link timer. No remote-side work needed,
  but ensure the client's render loop is not suppressed when the terminal is not actively receiving
  data (idle-skip must not freeze the blink animation).

- **GPU renderer (Metal) and ligature shaping on iOS**: libghostty's Metal renderer works on
  iOS (same GPU path). Ligature shaping on iOS uses Core Text, same as macOS. No divergence
  expected, but verify with `bash scripts/check-ios.sh` after any font/config change.
