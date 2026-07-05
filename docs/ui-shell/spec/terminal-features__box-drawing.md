# Box Drawing

## Summary

Pixel-perfect rendering of Unicode box-drawing, block, Braille, and Powerline glyphs — drawn analytically, not rasterized from a font. Beyond most terminals, SlopDesk treats arrows (← → ↑ ↓) and triangles (◀ ▶ ▲ ▼) as box-drawing participants: when one sits adjacent to a connecting box-drawing line, its stem extends to meet the rule, closing the gap other terminals leave. Flow diagrams and pipeline-style CLI output render seamlessly.

## Behaviors

- All box-drawing chars (U+2500–U+257F), block elements (U+2580–U+259F), Braille patterns, and Powerline glyphs render analytically (vector/pixel math), not from font outlines — sharp at any font size, DPI, or scale.
- Arrow glyphs (← → ↑ ↓, U+2190–U+2193) and triangles (◀ ▶ ▲ ▼) are box-drawing participants: adjacent to a box-drawing line, the stem extends to meet the rule so there is no gap.
- This "join arrows & triangles to box-drawing rules" behavior is ON by default.
- Disable via Settings → All Settings, search "Join arrows & triangles to box-drawing rules", toggle off. When off, arrows/triangles render standard (gap between arrowhead and adjacent line), matching Ghostty and most terminals.
- Rendering is font-independent — analytical rendering means glyphs don't depend on the selected font having box-drawing coverage.

## Keybindings

No keybindings are specific to box drawing.

| Action | Keys |
|--------|------|
| (none) | —    |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| Join arrows & triangles to box-drawing rules | On | Arrow/triangle glyphs adjacent to box-drawing lines have their stem extended to meet the rule, closing the gap. Disable to revert to standard behavior (gap visible, matching Ghostty/Terminal.app). Accessed via Settings → All Settings, search "Join arrows & triangles to box-drawing rules". |

## Visual spec

### box-drawing-otty.png — arrows join the rules

**Layout:** Light/cream background (~#F5F0E8). Two rows. Top: a shell prompt in green monospace (`$ ls -la | grep .rs 2>err.log | sort -u >out.txt`), full width. Below: a pipeline flow diagram in box-drawing and arrow glyphs.

**Flow diagram structure:**
- Row 1 (horizontal pipeline): Three rounded-rectangle boxes arranged horizontally, connected left-to-right by horizontal arrows. Box text: `ls -la` (left), `grep .rs` (center), `sort -u` (right). Connecting arrows are solid horizontal lines ending in a filled arrowhead (→). Critically, the arrow stem extends continuously and flush into the box border on both sides — NO gap. Seamless.
- Row 2 (vertical redirects): Below `grep .rs`, a downward arrow (↓) labeled `2>` connects to a box `err.log`. Below `sort -u`, a downward arrow (↓) labeled `>` connects to a box `out.txt`. Vertical arrow stems extend flush into the box border above and below — no gap.

**Typography:** Monospace (JetBrains Mono or similar), regular weight, ~14–16 px cell. Green prompt (~#4EC94E). Black/near-black diagram glyphs and box borders; borders are thin (1px stroke at pixel level).

**Key visual distinction:** Every arrow stem is visually merged with the adjacent box-drawing line — zero gap at the junction. Boxes have slightly rounded corners (corner box-drawing chars, not CSS rounding; analytical rendering keeps corners smooth). Reads like a clean vector illustration, not rasterized text.

---

### box-drawing-ghostty.png — Ghostty (comparison / baseline)

**Layout:** Same cream background, same shell command, same flow diagram structure (three boxes, two arrow levels).

**Key visual distinction:** VISIBLE GAP at every junction:
- Horizontal arrows (`→`) show the arrowhead as a separate glyph, not touching the box border. 1–2 cell gap between the horizontal line `─` and the `→`. Arrowhead does not merge with the box wall.
- Downward arrows (`↓`) sit one cell below the box border, visibly separated.

**Typography:** Same monospace style and green prompt. Box borders appear slightly thinner/lighter than otty (possibly font-rasterized vs analytical stroke weight).

**Purpose:** The BEFORE state — standard gap-present rendering.

---

### box-drawing-terminal.png — Terminal.app (comparison / baseline)

**Layout:** Same structure. Background medium gray (~#C8C8C8), darker than the other two. Same green command, same flow diagram.

**Key visual distinction:** Gaps similar to Ghostty — arrowheads separate from lines. Terminal.app's font differs (wider glyphs, possibly Monaco/Menlo), so gap proportions differ but are clearly present. Less polished; boxes look looser due to font-rasterized box-drawing.

**Background color:** Noticeably darker gray than the cream/light backgrounds above.

**Purpose:** Second BEFORE reference — baseline in macOS's built-in terminal.

## Screenshots

- `box-drawing-otty.png` — this design with arrow/triangle joining enabled (arrows join the rules)
- `box-drawing-ghostty.png` — Ghostty comparison (gap visible)
- `box-drawing-terminal.png` — Terminal.app comparison (gap visible, darker background)

## Implementation notes

SlopDesk uses libghostty (behind a `TerminalSurface` seam / `SlopDeskTerminal` + `TerminalRenderingView`) for terminal rendering.

1. **Analytical box-drawing — mostly free via libghostty.** libghostty already renders box-drawing analytically/pixel-perfect (Ghostty's own feature). Comparison screenshots confirm sharp corners, clean lines — but WITHOUT the stem-extension. SlopDesk inherits this quality for free.

2. **Arrow/triangle stem joining — NOT available via libghostty.** This distinguishing feature is not a Ghostty feature; it needs custom analytical glyph composition on top of the renderer. Options:
   - Patch libghostty (C/Zig) to add join logic — upstream work, breaks the "don't patch ghostty" boundary; OR
   - Post-process the rendered surface — impractical for a live terminal; OR
   - Intercept the character grid before rasterization and substitute extended glyphs — needs a custom font with pre-joined variants or a custom rendering layer.
   **Status:** Not implemented. Ship with libghostty's box-drawing (Ghostty-equivalent) until the join is built; note in Settings that "Join arrows & triangles to box-drawing rules" has no effect until then.

3. **Braille and Powerline glyphs.** Handled analytically by libghostty. No work needed.

4. **Block elements.** Rendered analytically by libghostty. Covered.

5. **Config key exposure.** The setting can't wire to any libghostty behavior since libghostty doesn't implement it. Once slopdesk adds its glyph-join layer, add the setting to `PreferencesStore` via the `Defaults` product (as established in the codebase). Default stays `true` per spec; a no-op stub until the join logic exists.

6. **Remote display path.** slopdesk streams video frames of the terminal surface over UDP (PATH 2), so any analytical rendering libghostty does server-side on the macOS host is preserved pixel-for-pixel (VT HEVC @ sufficient QP). Stem-joining, if implemented, is also server-side and equally preserved.

7. **iOS client.** Receives the same video stream; no platform-specific rendering difference.
