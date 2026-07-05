# Box Drawing

## Summary

Pixel-perfect rendering of Unicode box-drawing, block, Braille, and Powerline glyphs — drawn analytically rather than rasterized from a font. Unlike most terminals, SlopDesk extends this to treat arrows (← → ↑ ↓) and triangles (◀ ▶ ▲ ▼) as part of the box-drawing system: when an arrow or triangle glyph sits adjacent to a connecting box-drawing line, the stem of the arrow/triangle extends to meet the rule, eliminating the visual gap that other terminals leave. This makes flow diagrams and pipeline-style CLI output render seamlessly.

## Behaviors

- All Unicode box-drawing characters (U+2500–U+257F), block elements (U+2580–U+259F), Braille patterns, and Powerline glyphs are rendered analytically (vector/pixel math), not rasterized from font outlines. This makes them sharp at any font size, DPI, or scaling factor.
- Arrow glyphs (← → ↑ ↓, U+2190–U+2193) and triangle glyphs (◀ ▶ ▲ ▼) are treated as box-drawing participants: when such a glyph is adjacent to a box-drawing line, SlopDesk extends the stem of the arrow/triangle to meet the rule so there is no gap.
- This "join arrows & triangles to box-drawing rules" behavior is ON by default.
- The behavior can be disabled: open Settings → All Settings, search for "Join arrows & triangles to box-drawing rules", and toggle it off. When off, arrows and triangles render in the standard way (with a gap between the arrowhead and any adjacent line), matching Ghostty and most other terminals.
- The box-drawing rendering is independent of font choice — analytical rendering means the glyphs do not depend on the currently selected font having box-drawing coverage.

## Keybindings

No keybindings are specific to box drawing.

| Action | Keys |
|--------|------|
| (none) | —    |

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| Join arrows & triangles to box-drawing rules | On | When enabled, arrow and triangle glyphs adjacent to box-drawing lines have their stem extended to meet the rule, closing the visual gap. Disable to revert to standard terminal behavior (gap visible, matching Ghostty/Terminal.app). Accessed via Settings → All Settings, search "Join arrows & triangles to box-drawing rules". |

## Visual spec

### box-drawing-otty.png — arrows join the rules

**Layout:** Light/cream background (#F5F0E8 approximate). Two rows of content. Top row: a shell prompt line in green monospace text (`$ ls -la | grep .rs 2>err.log | sort -u >out.txt`) spanning the full width. Below it: a pipeline flow diagram rendered entirely in terminal box-drawing and arrow glyphs.

**Flow diagram structure:**
- Row 1 (horizontal pipeline): Three rounded-rectangle boxes arranged horizontally with horizontal arrows connecting them left-to-right. Boxes contain monospace text: `ls -la` (left), `grep .rs` (center), `sort -u` (right). The connecting horizontal arrows between the boxes are rendered as solid horizontal lines terminating in a filled arrowhead (→). Critically, the arrowhead's left stem extends continuously and flush into the box border on both its left and right sides — there is NO gap between the box border and the arrow stem. The connection is seamless.
- Row 2 (vertical redirects): Below `grep .rs` there is a downward arrow (↓) with the label `2>` to its left; it connects to a box containing `err.log`. Below `sort -u` there is a downward arrow (↓) with the label `>` to its left; it connects to a box containing `out.txt`. The vertical arrows similarly have their stem extended flush into both the box border above and below — no gap.

**Typography:** Monospace font (appears to be a JetBrains Mono or similar coding font), regular weight, approximately 14–16 px cell size. Green color for the prompt line (approx #4EC94E). Black/near-black for diagram glyphs and box borders. Box border lines are thin (1px stroke weight rendered at pixel level).

**Key visual distinction:** Every arrow glyph has its stem visually merged with the adjacent box-drawing line — there is zero gap at the junction. The boxes have slightly rounded corners (box-drawing with corner characters, not CSS rounding, but the analytical rendering makes corners smooth). Overall the diagram looks like a clean vector illustration rather than rasterized text.

---

### box-drawing-ghostty.png — Ghostty (comparison / baseline)

**Layout:** Same cream/light background and identical shell command at top. Same pipeline flow diagram with identical structure (three boxes, two levels of arrows).

**Key visual distinction:** The arrow glyphs and the box-drawing lines have a VISIBLE GAP at every junction. Specifically:
- The horizontal arrows between boxes (`→`) show the arrowhead character as a separate glyph, not touching the box border line. There is a 1–2 character-cell gap between the end of the horizontal line `─` and the `→` arrow glyph. The arrowhead does not visually merge with the box wall.
- The downward arrows (`↓`) below the boxes similarly have a gap — the arrow sits one character below the box border, visibly separated.

**Typography:** Same monospace font style, same green prompt color. Box border lines appear slightly thinner/lighter than in the reference screenshot above (possibly a different stroke weight from font-rasterized vs analytical rendering).

**Purpose in documentation:** This screenshot demonstrates the BEFORE state — standard (gap-present) rendering. The gap is clearly visible compared to the reference screenshot above.

---

### box-drawing-terminal.png — Terminal.app (comparison / baseline)

**Layout:** Same overall structure. Background is a medium gray (approximately #C8C8C8), darker than the other two screenshots. Same shell command in green at top, same pipeline flow diagram.

**Key visual distinction:** Arrow glyphs show gaps similar to Ghostty — arrowheads are separate from box-drawing lines. The font used in Terminal.app appears slightly different (wider glyphs, potentially Monaco or Menlo), making the gaps appear somewhat different in proportion but still clearly present. The overall appearance is less polished — boxes look looser due to the rasterized box-drawing characters from the font.

**Background color:** Noticeably darker gray background compared to the creamy/light backgrounds of the reference and Ghostty screenshots.

**Purpose in documentation:** Second BEFORE reference, showing the baseline behavior in macOS's built-in terminal for additional context.

## Screenshots

- `box-drawing-otty.png` — this design's rendering with arrow/triangle joining enabled (arrows join the rules)
- `box-drawing-ghostty.png` — Ghostty rendering for comparison (gap visible between arrow and line)
- `box-drawing-terminal.png` — Terminal.app rendering for comparison (gap visible, different background)

## Implementation notes

SlopDesk uses libghostty (behind a `TerminalSurface` seam / `SlopDeskTerminal` + `TerminalRenderingView`) for terminal rendering. The relevant implementation considerations are:

1. **Analytical box-drawing rendering — mostly free via libghostty.** libghostty already performs analytical/pixel-perfect rendering of Unicode box-drawing characters (that is Ghostty's own feature). The comparison screenshot confirms that Ghostty renders box-drawing analytically (sharp corners, clean lines) but WITHOUT the arrow/triangle stem-extension behavior. SlopDesk inherits Ghostty's box-drawing quality for free through libghostty.

2. **Arrow/triangle stem joining — NOT available via libghostty.** This distinguishing feature — extending arrow/triangle stems to meet adjacent box-drawing rules — is NOT a libghostty/Ghostty feature; it requires custom analytical glyph composition on top of the renderer. Implementing it in slopdesk requires either:
   - Patching libghostty (C/Zig layer) to add the join logic, which is upstream work and breaks the "don't patch ghostty" boundary; OR
   - Post-processing the rendered surface (impractical for a live terminal); OR
   - Intercepting the character grid before libghostty rasterization and substituting extended glyphs (would require a custom font with pre-joined variants or a custom rendering layer).
   **Status:** Not yet implemented. Ship with libghostty's existing box-drawing (Ghostty-equivalent quality) until the stem-extension join is built, and note in Settings that "Join arrows & triangles to box-drawing rules" has no effect until then.

3. **Braille and Powerline glyphs.** libghostty already handles these analytically. No additional work needed — this is already covered.

4. **Block elements.** libghostty renders block elements analytically. Already covered.

5. **Config key exposure.** The "Join arrows & triangles to box-drawing rules" setting cannot be wired to any libghostty behavior because libghostty does not implement this. Once slopdesk adds its own glyph-join layer, this setting can be added to `PreferencesStore` via the `Defaults` product (as established in the codebase). Default should remain `true` to match the design spec's default, but the implementation will be a no-op stub until the join logic is built.

6. **Remote display path.** Since slopdesk streams video frames of the terminal surface over UDP (PATH 2), any analytical rendering done server-side by libghostty on the macOS host is preserved pixel-for-pixel in the video stream. The analytical quality is NOT degraded by the video path in normal operation (VT HEVC @ sufficient QP). The stem-joining feature, if ever implemented, would also be server-side (in libghostty on the host) and thus equally preserved.

7. **iOS client.** The iOS client receives the same video stream; no platform-specific rendering difference applies here.
