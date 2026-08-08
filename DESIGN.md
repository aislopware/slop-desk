---
name: SlopDesk
description: Low-latency remote-coding workspace for Apple platforms — the Dracula Pro colour world in a FLAT tonal-ladder structure (three full-bleed columns split by 1px dividers; chrome is a darker rung of the glass's own hue, the reverse for Alucard); Slate token layer
colors:
  # The whole app is ONE hue family (OKLCH H≈289) at different lightness rungs. These are the only fixed colours.
  accent: "#644AC9" # brand Dracula purple, light appearances (dark appearances use the Pro #9580FF)
  accent-deep: "#4B29A7" # fill/badge band (dark appearances #6B4BD6)
  glass-dracula: "#22212C" # default terminal profile — the Dracula Pro glass, verbatim
  glass-dracula-ink: "#F8F8F2"
  glass-dracula-edge: "#454158" # in-glass split divider + selection fill (the Pro selection)
  glass-dracula-accent: "#9580FF" # on-glass accent (focus corner, drag line)
  chrome-dracula: "#1B1922" # sidebar/rail/panel-strip floor — the official Dracula chrome offset (−07/−08/−0A) off the Pro face
  chrome-dracula-line: "#312F37" # the 1px column divider — an INK TINT: 10% of the glass ink over the ground (lighter than both surfaces it separates)
  chrome-dracula-lift: "#2E2E3C" # hover/raised rung — the official rail offset (+0C/+0D/+10)
  chrome-alucard: "#F6F1DE" # the cream mirror of the same ladder
  chrome-alucard-line: "#D8D3C3" # 14.2% ink over the cream ground — unequal to the dark 10% ON PURPOSE: solved for the same perceived step (OKLab ΔL ≈ 0.09) because black into cream moves lightness slower than white into near-black
  chrome-alucard-lift: "#FFFDF4"
  secure-input-blue: "#2D6FE8" # fixed, never themed
  sync-input-amber: "#D97A1F" # fixed, never themed
typography:
  display:
    fontFamily: "SF Pro (system)"
    fontSize: "40px"
    fontWeight: 400
  title:
    fontFamily: "SF Pro (system)"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "13px"
    fontWeight: 400
  base:
    fontFamily: "SF Pro (system)"
    fontSize: "12px"
    fontWeight: 400
  footnote:
    fontFamily: "SF Pro (system)"
    fontSize: "11px"
    fontWeight: 400
  small:
    fontFamily: "SF Pro (system)"
    fontSize: "10px"
    fontWeight: 400
  instrument:
    fontFamily: "JetBrains Mono, SF Mono, monospace"
    fontSize: "12px"
    fontWeight: 400
    letterSpacing: "1.2px"
rounded:
  small: "4px"
  control: "6px"
  card: "8px"
  panel: "12px"
  pill: "20px"
spacing:
  space1: "4px"
  space2: "8px"
  space3: "12px"
  space4: "16px"
components:
  field:
    backgroundColor: "{colors.chrome-dracula} (Alucard: {colors.chrome-alucard}) — the OPAQUE chrome floor, one fixed colour per profile, painted at the window root"
    note: "no material, no gradient, no transparency — the flat round (user-directed 2026-08-08) retired the liquid-glass floor and the inverted lavender frame"
  column-divider:
    backgroundColor: "{colors.chrome-dracula-line} (Alucard: {colors.chrome-alucard-line})"
    width: "1px"
    note: "FlatDividerSplitView paints the divider AND the split-view backing layer in the chrome line colour — the only seam between the window's three flat columns"
  sidebar:
    backgroundColor: "the field (the chrome floor, full-bleed)"
    textColor: "semantic label tiers"
    note: "collapsing MINIMIZES to an 80pt RAIL, never hides (rail round): lights band, centered expand toggle, one muted folder chip per project group (attention roll-up on its corner), New Tab, compact ping readout"
  sidebar-search-field:
    backgroundColor: "Slate.Surface.chip + subtle hairline stroke"
    rounded: "{rounded.control}"
    height: "28px"
  panel-edge-handle:
    backgroundColor: "Slate.Surface.raised; lift on hover"
    rounded: "leading corners only ({rounded.card}) — a drawer pull fused to the window's trailing edge, vertically centered; reopens the collapsed right panel"
  list-row:
    backgroundColor: "transparent"
    textColor: "secondaryLabelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  list-row-active:
    backgroundColor: "reverse video — the row flips its colorScheme environment, so the chip (controlBackgroundColor) and every ink inside resolve at the OPPOSITE pole: near-white chip + dark text on the dark chrome, near-black chip + light text on the cream chrome"
    textColor: "labelColor (under the flipped scheme)"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  terminal-column:
    backgroundColor: "{colors.glass-dracula}"
    note: "full-bleed flat column — no card, no radius, no margin; splits inside are divided by the profile's terminalEdge line"
  panel-column:
    backgroundColor: "{colors.glass-dracula}"
    note: "the right column — its tab strip sits at the top of the same flat glass surface"
  panel-tab-chip:
    backgroundColor: "ghost (clear) at rest; raised wash on hover; selected = inverted micro-chip — glass INK fill with glass FACE text, the strip's reverse-video echo of the sidebar chip"
    rounded: "capsule"
    height: "24px"
---

# SlopDesk Design System — DRACULA FLAT

North star: **one hue family, a ladder of lightness, three flat columns.** SlopDesk's window is the
classic divider layout (flat round, user-directed 2026-08-08): sidebar | terminal | code panel,
each a full-bleed flat surface, separated by 1px dividers — no islands, no frame, no floating
cards, no transparency. The colour world is Dracula Pro's published set worn the way the official
Dracula editor themes wear it: the glass `#22212C` is the face, and the chrome around it is the
SAME hue a few lightness rungs darker (`#1B1922` floor, `#2E2E3C` lift) — the official Dracula
chrome's per-channel offsets transposed onto the Pro face — while the divider is an ink-tint
hairline (`#312F37`) that sits LIGHTER than both surfaces it separates, the modern border read. Alucard mirrors the
ladder into cream. Ink `#F8F8F2`, selection `#454158`, comment `#7970A9`, and the normalized
accent seven (S100/L75 — red `#FF9580` through pink `#FF80BF`) are the Pro palette verbatim.

This replaced the inverted lavender frame + liquid-glass islands (rounds 8–9), rejected as
hard-to-read kitsch (user-directed 2026-08-08 — five chrome worlds have now died: graphite, clay,
salmon, FOUNDRY ember, lavender frame). The surviving structure is the one every modern reference
uses — Zed, Linear, Raycast, and Dracula's own official chrome are all one-hue tonal ladders with
hairline dividers. Restraint is the register: no dot indicators beyond the attention roll-up, no
per-project identity hues on chrome, colour lives in the terminal's ANSI and the one accent.

## The two worlds — one polarity

| World | Where | Colour source |
|---|---|---|
| **Chrome** | the window field, sidebar/rail, dividers, the panel edge handle, overlays, Settings, empty states | Semantic system colours resolving under the profile's polarity, on the profile's chrome floor |
| **Glass** | the terminal column, the panel column (strip + surfaces), satellite pane windows, embedded workbench | The active **terminal profile** (`SlateTheme`) |

**Whole-app theme, ONE polarity per profile** (flat round): `chromeIsLight == isLight` — the
inverted frame and its two-ring appearance pin are retired. Dracula is dark end to end; Alucard is
light end to end. `ThemeStore.pinAppAppearance` pins `NSApp.appearance` from that one polarity;
windows and views carry NO pin of their own. The "System" choice follows the OS by resolving to
the pair (dark → Dracula, light → Alucard); a concrete choice ignores the OS. The embedded
workbench webviews are pinned per-webview to the same polarity and seeded to the matching
Dracula / Alucard workbench theme.

Nothing may straddle the chrome/glass boundary: a view is either ON the chrome (semantic tokens
over the chrome floor) or ON the glass (profile tokens, or semantic tokens under the forced glass
scheme). Because chrome and glass share one hue family, the boundary is a lightness step plus a
1px line — never a hue change.

## Chrome — the ladder

- **Floor** — `Slate.Surface.field` = the profile's `chrome` (`#1B1922` / `#F6F1DE`), OPAQUE and
  fixed per profile, painted once at the window root. No material, no gradient. (The fixed colour
  also keeps the CGColor-snapshot trap family dead — nothing dynamic reaches a layer.)
- **Dividers** — the profile's `chromeLine` (`#312F37` / `#D8D3C3`): the theme INK tinted over the
  chrome ground (divider round, user-directed 2026-08-08) — 10% dark / 14.2% light, the unequal
  pair that lands both themes on the same perceived step (OKLab ΔL ≈ 0.09 vs the ground; equal
  fractions read weaker in light because black into cream moves lightness slower). 1px, painted by
  `FlatDividerSplitView` in both `drawDivider(in:)` and the split view's backing layer (the layer
  shows through during live column drags). This is the ONLY seam between columns.
- **Lift** — the profile's `chromeLift` (`#2E2E3C` / `#FFFDF4`) is the hover/raised rung for
  chrome objects that need a step up from the floor.
- **Sidebar** = flat on the floor. Collapsing MINIMIZES it to the 80pt RAIL (rail round) — the
  window controls always keep a floor; the column never fully hides. Rail anatomy top→bottom:
  clear lights band (the lights own nearly the full 80pt — no control shares it), centered expand
  toggle, one folder chip per project group (44pt, MUTED glyph — identity hues are retired from
  chrome, flat round), New Tab, compact connection readout. The expanded strip keeps its collapse
  toggle permanent at top-trailing; the right panel's reopen is the `PanelEdgeHandle` drawer pull.
  There is NO titlebar of any kind.
  The active row is the column's one raised object, and it is **reverse video** (kept from the
  polish round): the row flips its `colorScheme` environment, so the chip fill (`Slate.Surface.chip`
  → `controlBackgroundColor`) and every semantic ink inside re-resolve at the opposite pole — a
  near-white chip with dark text on the dark chrome. Selection is stated by INVERSION, still
  entirely semantic.
- **Surfaces** (`Slate.Surface`): `field` → the chrome floor (above), `void`/`ground` →
  `underPageBackgroundColor`, `face` → `windowBackgroundColor`, `raised` → `quaternarySystemFill`,
  `lift` → `tertiarySystemFill`, `chip` → `controlBackgroundColor`.
- **Text** (`Slate.Text`): the semantic label tiers (`labelColor` → `tertiaryLabelColor`). Never a
  custom RGB for chrome text.
- **Lines** (`Slate.Line`): `separatorColor`, INSIDE surfaces only; the column seams belong to
  `chromeLine`.
- **Status** (`Slate.Status`): `systemGreen` / `systemOrange` / `systemRed`; info rides the accent.
  Status dots are budgeted: the attention roll-up is the only dot the sidebar wears.

## The one brand colour

**Dracula purple**, fixed (user-directed over the system accent): light `#644AC9` (Alucard's
purple), dark `#9580FF` (the Pro purple) — `Slate.State.accent`, an appearance-dynamic pair; deep
fill band `#4B29A7`/`#6B4BD6` (`Slate.Accent.deep`, derived in-family). Spent ONLY on: selection
wash (15%), active tab, focus corner, divider drag line, link highlight, find-bar caret/toggles,
info status. Everything else interactive is the system's.

## Glass — the columns

- The content column is the glass FLAT and full-bleed: no card, no radius, no margin, no ring, no
  shadow. Panes are flush inside it; splits are divided by the profile's `terminalEdge` line — a
  subtle line ON the glass, never a chrome-coloured gap, never per-pane cards.
- The column subtree runs under `.environment(\.colorScheme, Slate.glassColorScheme)` — the
  profile's own polarity — so every semantic colour used inside resolves against the glass.
  Satellite pane windows are glass edge-to-edge and adopt the same forced scheme.
- Divider at rest: `terminalEdge` hairline; while dragging: accent 2px + the live ratio readout.
- Focus = the small filled accent corner triangle (top-left, split tabs only). NO dimming — of
  panes or columns, in any strength (removed 2026-08-07); focus is the corner mark alone.
- **The panel column** (right) is the second glass surface, same anatomy. Its TAB STRIP sits at
  its top, on the glass. The SELECTED strip chip is the **inverted micro-chip**: glass-ink fill
  with glass-face text — the same reverse-video language as the sidebar chip, so the whole app has
  ONE way of saying "selected". At rest a tab is a ghost (no plate); hover is the raised wash.

## Terminal profiles (`SlateTheme`)

A profile is Terminal.app-style: cells bg/fg, 16-slot ANSI, selection, caret, edge line, on-glass
ink tiers, an on-glass accent — and, since the flat round, the authored CHROME ladder
(ground/line/lift). Exactly TWO built-ins:

| Profile | Glass | Ink | Edge (selection) | On-glass accent | Chrome ground / line / lift |
|---|---|---|---|---|---|
| **Dracula** (default, dark) | `#22212C` | `#F8F8F2` | `#454158` | `#9580FF` | `#1B1922` / `#312F37` / `#2E2E3C` |
| Alucard (light) | `#FFFBEB` | `#1F1F1F` | `#CFCFDE` | `#644AC9` | `#F6F1DE` / `#D8D3C3` / `#FFFDF4` |

ANSI: the Pro accent seven verbatim (no blue — the blue slot carries the purple, Dracula's own
terminal convention); brights REPEAT the bases; bright-black = the comment tone. The Settings
gallery previews each profile as a miniature of its own terminal. A profile choice is a WHOLE-APP
choice: one polarity pins the app appearance and forces the glass scheme. The "System" choice (and
the fresh-install default) follows the OS through the pair — OS dark → Dracula, OS light → Alucard
— flipping live on an OS switch. The FIXED pills (secure blue `#2D6FE8`, sync amber `#D97A1F`) sit
outside every palette.

## Structure, type, motion (unchanged ladders)

- **Metrics**: 8pt grid; closed height ladder (`heightControl` 24 → `heightDrawer` 180); closed
  radius family; `check-ds-leaks.sh` enforces no raw font/radius/height literals in
  `Sources/SlopDeskClientUI`.
- **Type**: system face for prose; **JetBrains Mono instrument voice** for the rail, readouts,
  numbers, caps micro-labels — the terminal's own register bleeding into the chrome. This, not
  colour, is where the product's character lives.
- **Motion**: cubic-bezier only, no springs; one orchestrated moment (the connect handshake
  needle). Timing tokens in `Slate.Anim`.
- **Overlays**: `SlateOverlayCard` glass/material + `Color.primary` ink. Settings stays pure
  system semantics (`SettingsInk`).

## Do / Don't

- DO add new chrome colour needs as SEMANTIC system colours; if none fits, the design is wrong.
- DO put profile-dependent colour behind `SlateTheme` / `Slate.Terminal.*`. New fixed colour
  enters ONLY as a `SlateTheme` field, derived in the Pro hue family as a lightness rung.
- DON'T bring back islands, floating cards, the inverted frame, the liquid-glass floor, or any
  translucent window material — the flat divider layout is the round-10 verdict. Five chrome
  worlds are the anti-reference now: dark graphite, clay `#EFD0C2`, salmon `#C59B8B`, FOUNDRY
  ember, and the lavender frame `#B0A2EA`.
- DON'T change hue to separate regions — separation is a lightness rung + the 1px `chromeLine`.
- DON'T add dot indicators, badges, or per-project identity hues to chrome (`Slate.Identity` is
  deleted). The attention roll-up dot is the entire dot budget.
- DON'T float per-pane cards, add pane shadows, or tint any column per project.
- DON'T give any column its own material — the floor is one opaque colour per profile.
- DON'T add appearance pins beyond the ONE `ThemeStore` app-level pin (no per-window, no
  per-control except the workbench webviews); DON'T let OS-appearance semantics leak into the
  glass (use the forced glass scheme).
- DON'T introduce a second selection language: selected = reverse-video inversion (sidebar chip,
  strip micro-chip). No accent-tinted plates, no underlines for selection.
- DON'T dim, veil, or fade a column to state focus — the accent corner mark only.
- DON'T touch the fixed pills (secure blue / sync amber) or route them through anything.
