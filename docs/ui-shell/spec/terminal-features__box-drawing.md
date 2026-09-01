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

**Rewritten 2026-09-02 — every paragraph below used to describe libghostty as the renderer.** It is
not one any more: the engine is `rust/slopdesk-vterm` and the renderer is `rust/slopdesk-termrender`,
both ours, so the ceiling this section recorded ("would require a ghostty patch") went with the fork.
The sprite face is `rust/slopdesk-termrender/src/sprite/`.

1. **Analytical box-drawing — ours, not inherited.** `sprite/box_drawing.rs` covers U+2500…257F,
   ported from Ghostty's `box.zig` (MIT) including `linesChar`'s junction arithmetic, the arcs and
   the dash divisions. The freeness the old note claimed left with the fork; what replaced it is a
   `Canvas` over alpha8 (`sprite/canvas.rs`) with a nonzero-winding polygon filler and a stroker,
   which is the same technique Ghostty uses and the reason a corner is sharp.

2. **Arrow/triangle stem joining — built.** `sprite/arrow.rs`, and it is OURS rather than a port:
   Ghostty draws no arrows or triangles as sprites at all. U+2190…2193 and U+25B2/B6/BC/C0 are drawn
   here ONLY when a box rule actually arrives at one of the cell's four edges — `sprite::faces` asks
   each neighbour whether it runs a rule to the shared boundary, and `paint.rs`'s `join_mask` reads
   across rows as well as within one, so `│` stacked over `↓` joins. An empty mask draws nothing and
   the character falls through to the font, which is what keeps `→` in a sentence a typeface's arrow.

3. **Braille and Powerline glyphs.** `sprite/braille.rs` (U+2800…28FF, including the six-stage dot
   fitting) and `sprite/powerline.rs` (U+E0B0…E0BF, E0D2, E0D4). Both ported. The Powerline module's
   header records why a private-use range is drawn at all: a separator must bleed to the cell edge or
   a hairline of background shows through the prompt, and no font can promise that.

4. **Block elements.** `sprite/block_elements.rs`, U+2580…259F.

5. **Config key exposure.** `terminal.arrow-box-drawing-join`, default ON, in
   `rust/slopdesk-settings/src/config/table.rs`. It reaches `PaintStyle::arrow_box_drawing_join`
   through `slopdesk_term_surface_set_arrow_box_drawing_join` and `SettingsKey`. It is no longer a
   stub, and it is the ONLY sprite family a setting reaches — the other four are drawn from the cell
   whatever the config says, because a font's box rule is fitted to the font's own advance and gaps
   against its neighbour. That is a bug, not a preference.

6. **Remote display path.** Unchanged in kind: the surface is rendered on the macOS host and streamed
   as video, so the sprites are preserved pixel-for-pixel at sufficient QP.

7. **iOS client.** Receives the same video stream; no platform-specific rendering difference.
