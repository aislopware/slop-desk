---
name: SlopDesk
description: Low-latency remote-coding workspace for Apple platforms — ONE ISLAND: a single lifted terminal canvas floating in a cream ground that the navigator and the code panel sink into; the Dracula Pro colour world supplies the glass; Slate token layer
colors:
  # The whole app is ONE hue family (OKLCH H≈289) at different lightness rungs. These are the only fixed colours.
  accent: "#644AC9" # brand Dracula purple, light appearances (dark appearances use the Pro #9580FF)
  accent-deep: "#4B29A7" # fill/badge band (dark appearances #6B4BD6)
  glass-dracula: "#22212C" # THE terminal profile — the Dracula Pro glass, verbatim
  glass-dracula-ink: "#F8F8F2"
  glass-dracula-edge: "#454158" # in-glass split divider + selection fill (the Pro selection)
  glass-dracula-accent: "#9580FF" # on-glass accent (focus corner, drag line)
  ground: "#FFFBEB" # THE GROUND — Alucard's published face: the navigator, the code panel, the top band, the island's moat
  chrome-dracula-line: "#312F37" # the in-island pane seam — an INK TINT: 10% of the glass ink over the ground (lighter than both surfaces it separates)
  chrome-dracula-lift: "#2E2E3C" # hover/raised rung — the official rail offset (+0C/+0D/+10)
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
  compact-island: "10px"
  panel: "12px"
  pill: "20px"
  island: "26px"
spacing:
  space1: "4px"
  space2: "8px"
  space3: "12px"
  space4: "16px"
components:
  field:
    backgroundColor: "{colors.ground} — the OPAQUE ground, painted at the window root and under all three columns"
    note: "no material, no gradient, no transparency. Because the ground is light the CHROME polarity is light (the app pins `.aqua`); the glass opts out locally via `Slate.glassColorScheme`"
  column-divider:
    backgroundColor: "{colors.ground} — GROUND, not a seam"
    width: "1px"
    note: "FlatDividerSplitView paints the divider AND the split-view backing layer in the ground colour, so the three columns read as one continuous sunken field; the only boundary the window draws is the island's own edge
  island:
    backgroundColor: "{colors.glass-dracula}"
    rounded: "{rounded.island} — a WINDOW-scale corner for a window-scale surface: 26 is what macOS 26 Tahoe puts on a full-chrome window (measured on this OS). The island sits ~230px clear of the frame's own corners, so nothing constrains it to stay under the window's 16 (user-directed 2026-08-08)"
    inset: "12px on ALL FOUR sides, so the island's top edge rises INTO the band, just under the traffic lights' own top edge (user-directed 2026-08-09). The one exception: while the navigator is hidden the band's own tab strip moves over this column, and the top opens to the full band so the tinted project beds keep their ground. The trailing side gives way to the panel's rail when the panel is collapsed"
    border: "1px Slate.Line.divider, inset-stroked inside the clip"
    note: "THE ONE ISLAND (user-directed 2026-08-08) — the terminal canvas, the window's only lifted surface. `View.slateIsland()` is its single call site; a second one is the many-islands clutter coming back. Panes tile it edge-to-edge, parted by the PaneDivider hairline, never by a channel"
  sidebar:
    backgroundColor: "the field (the ground, full-bleed — the navigator SINKS, it is not an island)"
    textColor: "semantic label tiers"
    note: "collapsing HIDES the column (chrome revert, user-directed 2026-08-08). ONE toggle, at WINDOW level beside the traffic lights (`WindowSidebarToggle`, user-directed 2026-08-09) — the old hide-twin-in-the-column + reveal-twin-in-the-titlebar pair rode the collapse slide and crawled under the lights; a control that must not move cannot live in a container that does. Its whole click feedback is the plate fill plus a symbol bounce"
  sidebar-search-field:
    backgroundColor: "Slate.State.hover wash, no stroke — a recess in the column, not an island (restored user-directed 2026-08-08)"
    rounded: "{rounded.control}"
    height: "28px"
  titlebar:
    backgroundColor: "transparent — an overlay riding the content column's top strip (40px = one 24px control with a grid step above and below, so the row's centres sit on the traffic lights' centre)"
    note: "EMPTY at rest and no longer a band across the window (user-directed 2026-08-08): the centred pane title and its menu are deleted, and the island rises into this row, so the traffic lights stand on the NAVIGATOR's ground with the island beside them. Nothing of the panel's lives here any more — the collapsed panel keeps its own rail (user-directed 2026-08-09), so no chrome plate has to stand on the island"
  list-row:
    backgroundColor: "transparent"
    textColor: "secondaryLabelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  list-row-active:
    backgroundColor: "Slate.Surface.raised translucent wash + Line.card hairline border — the overlay card, NOT a solid fill (restored user-directed 2026-08-08; both the reverse-video flip and the solid chip plate are retired)"
    textColor: "labelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  terminal-column:
    backgroundColor: "the field (the ground) — the glass belongs to the ISLAND it hosts, not to the column"
    note: "the column paints ground end-to-end and lifts the pane canvas off it as the one island; splits inside the island are divided by the profile's terminalEdge line"
  panel-column:
    backgroundColor: "the field (the ground) behind the strip; the workbench/device surfaces fill below a divider hairline"
    note: "the right column SINKS like the navigator. The embedded workbench is seeded with `workbench.colorCustomizations` painting every VS Code surface {colors.ground}, and its webview is pinned to the CHROME polarity — panel and ground read as one continuous field (user-directed 2026-08-08)"
  device-panel:
    backgroundColor: "the field (the ground), all three bands — the list, the header, the stage and the console"
    note: "the Simulators / Emulators surfaces sink like every other column: no lit stage, no second tone. Bands are told apart by hairlines; the DEVICE is the lit object and arrives already drawn as one. A placeholder plate behind a picture that has not landed is `Surface.raised` — a translucent tint of the cream, never an opaque grey"
  overlay-card:
    backgroundColor: "{colors.ground} — PAPER: the ground's own cream, opaque"
    rounded: "{rounded.island} for a summoned panel; {rounded.compact-island} for a row-scale notification"
    note: "SlatePaperCard. Hairline + the palette shadow rung carry it against the cream at its edges; ~13:1 against the island it covers. It was Liquid Glass until 2026-08-08 — a card lands centred, which is exactly where the dark island already is, so the glass repeated was invisible. Ink stays SlateOverlayInk (system-semantic, neutral)"
  keycap:
    backgroundColor: "SlateOverlayInk.plate + hairline"
    rounded: "{rounded.small}"
    note: "the ONE instrument-voice readout set in the SYSTEM face: ⇧ ⌘ ⌥ ⌃ are symbol glyphs and a monospaced cell advances them narrower than they draw, so a chord collides into one smear. Measured across three faces at 3x"
  panel-tab-chip:
    backgroundColor: "transparent at rest; State.hover wash on hover; SELECTED = a compact island — the island fill + a divider hairline, ink flipped to the glass polarity (user-directed 2026-08-08)"
    rounded: "{rounded.compact-island}"
    height: "24px"
  command-ladder:
    textColor: "status inks only — running = accent, clean = Status.ok, failed = Status.err; never a new hue"
    note: "the terminal pane's trailing-edge tick rail (round 14): one 6x2 tick per OSC-133 command block, evenly pitched (10pt, compressing to a 4pt floor, then dropping oldest), newest at the bottom; muted at rest, full ink under the pointer; click = the navigator's own re-anchor jump + landed flash. Evenly pitched ON PURPOSE — blocks carry prompt ordinals, not rows, and a proportional minimap would be a drawing of a guess (absent-never-wrong)"
  no-results-line:
    textColor: "Slate.Text.tertiary (overlay cards: SlateOverlayInk.tertiary)"
    note: "SlateNoResultsLine — the ONE zero-state voice for list surfaces (palette, search, popover rows): a single centred body line, text-only, no illustration, no glyph. Full-pane emptiness is SlateEmptyState."
---

# SlopDesk Design System — ONE ISLAND

North star: **one ground, one island.** SlopDesk's window holds exactly two tones. The GROUND is
Alucard's published cream `#FFFBEB`: the navigator, the code panel, the top band and the moat all
stand on it, flush, un-rounded, with no seam between them — they SINK. Lifted off that ground is
exactly ONE surface: the terminal canvas, wearing the Dracula Pro glass, rounded at 26pt, floating in a
moat that is the same on all four sides, so its top edge lands on the band's TOP LINE — the one line
the window keeps straight, level with the traffic lights and the panel's tabs, so all three columns
begin together (user-directed 2026-08-09). Inside the island, panes tile edge-to-edge and are parted by a
hairline, never by a channel — one lift, one vocabulary. SELECTION is the island's only echo: the
chosen tab is a COMPACT island, the same material at row scale, so the window says "this one" in the
one material it already speaks.

This is the third structure of 2026-08-08 and it was set by the user twice. The first ask was the
Rio-Canario / JetBrains-Islands read; the literal answer — every column and every pane its own
island — came back **too busy**, and the correction named the shape precisely: one big island in
the middle for the terminal, splits parted by a divider, both side panels sunk into the background,
the VS Code background matching that background, and the background itself the Alucard theme's own
bg. Everything below follows from those five sentences. Later the same day the theme PICKER went
too — see **ONE appearance**.

The colour world is still Dracula Pro's published set, but it now lives entirely on the GLASS: face
`#22212C`, ink `#F8F8F2`, selection `#454158`, comment `#7970A9`, and the normalized accent seven
(S100/L75 — red `#FF9580` through pink `#FF80BF`) verbatim. Restraint is the register: no dot
indicators beyond the attention roll-up, no per-project identity hues on chrome, colour lives in the
terminal's ANSI and the one accent.

### Why a light ground under a dark terminal

Arithmetic, not taste. A DARKER ground under the Pro face `#22212C` cannot separate: even at pure
black the ratio is 1.32:1, so the entire dark half of the axis is unusable for a lift. A light
ground gives ~13:1 — the Canario read, a bright frame carrying a dark canvas.

### ONE appearance

There is no theme picker (user-directed 2026-08-08: *one theme — the background always white, the
terminal dark*). The app ships a single appearance — Alucard's cream ground carrying Dracula Pro's
glass — and the machinery that used to choose between two is gone: no light/dark slots, no
follow-OS resolution, no per-theme font map, no runtime `ThemeStore`, no `theme` CLI noun or config
key, no first-launch theme step. `Slate.theme` is a constant.

The second profile had already lost its reason to exist: law 4 put the SAME cream ground under both,
so picking "Alucard" only flattened the one contrast this design is built on — a cream frame around
a dark canvas — leaving a window with no island in it. What survives of the old machinery is the
app-level LIGHT pin (`SlateAppearancePin`), which the cream ground still requires.

### TWO TONES, and nothing is allowed to be a third

The law is not "two tones in the window frame" — it is two tones **everywhere**, and that is what
the 2026-08-08 sweep across the remaining surfaces enforced. Two kinds of drift had survived the
first round, both of them invisible until the ground turned cream:

**A third grey.** The device panels (Simulators, Emulators) and the first-launch window painted
themselves from `underPageBackgroundColor` and `windowBackgroundColor` — the SYSTEM's aux backdrop
and window ground. Those are correct semantic choices in an app that stands in the system's own
tones; this one does not. Sampled live, the panel column was `#A1A09F` against the sidebar's
`#FFFBEB`, so the panel visibly did not belong to the window it was in. Every one of those surfaces
is now `Slate.Surface.field`. Where something genuinely must lift off the ground inside a panel — a
placeholder plate behind a picture that has not arrived, a console strip, a first-launch card — it
uses `Surface.raised`, which is TRANSLUCENT and therefore tints the cream instead of replacing it.
That is the general rule: **a region of a surface is a translucent lift of it, never a second opaque
tone.**

**A third material.** The floating family (palette, Open Quickly, global search, cheat sheet,
connect, pane switcher, notifications) was Liquid Glass. Glass earns its keep by refracting what
varies behind it, and after ONE ISLAND there are exactly two flat opaque tones back there, so the
effect degraded to a grey slab that also flipped relationship halfway across itself — light-over-cream
at the card's edges, light-over-glass in its middle. Apple's own guidance points the same way (do not
stack glass; apply the material once, at the top). The family is now PAPER: `Surface.field`, opaque,
cut at the island's 26, hairline-edged, on the `palette` shadow rung. Rendered side by side at true
size the choice was not close — a dark card lands centred, which is exactly where the dark island
already is, so it disappeared; the cream one reads as a sheet laid on the canvas at ~13:1. The card
takes `Surface.field` and NOT the island's glass for that reason, and it keeps the neutral
system-semantic ink it always had.

The shadow is the one token that had to grow: `State.overlayShadow` (0.30) is twice `State.shadow`,
because a panel over the dark island is separated by tone while a paper card is the ground's own
cream lifted off the ground, and nothing but the cast tells them apart at the card's edges.

### Geometry

Window 16, moat **12 on all four sides**, island **26**, compact island (selected tab) **10**.

The band is **40** = one 24pt control with a grid step above and below, and everything in it —
lights, toggle, the collapsed-state tab beds, the panel's surface tabs and its action plates — sits
on ONE ROW OF CENTRES at 20 (user-directed 2026-08-09). The island's top edge lands at 12, inside
that row rather than under it: the moat is uniform, so the glass rises to just under the lights.
40 is also where every column's SECOND row starts — the search field, the editor tabs, and (only
while the navigator is hidden, when the band's tab strip moves over the middle column) the island.

Hanging the island BELOW the whole band was tried at 40 and again at 32 and rejected both times:
the middle column read as starting a row lower than the two beside it. Hanging every control from
the island's own line was rejected next: a 16pt disc and a 24pt plate sharing a top edge do not
share a centre, and the lights read high. The lights are AppKit's to place and the system offers
exactly one lever — the declared titlebar height (`.unifiedCompact` on an empty toolbar). Nudging
their frames instead FLICKERS on every window re-title.

macOS 26 Tahoe gives a window the corner its titlebar asks for. Measured on this OS, one `NSWindow`
per configuration, reading the alpha profile of the corner: **no toolbar 16** (what this app gets —
it runs `.hiddenTitleBar`), **`.unifiedCompact` toolbar 21**, **`.unified` toolbar 26** (Finder and
System Settings both land there). The same method on Tahoe's smaller surfaces: a grouped content card
≈ 11, a selected sidebar row ≈ 8.

The island wears **26** — the top of that scale, the corner the OS puts on a full-chrome window —
because the island IS a window-scale surface (~880 × 775pt), and one wearing a window's corner reads
as a window floating inside the window, which is the metaphor. The earlier 8, then 14, came from a
concentricity rule (inner = outer − inset) that does not apply: the island lives in the CENTRE
column, ~230pt clear of the frame's own corners, so the two are never seen side by side and nothing
holds the island under 16. Its neighbours are flat dividers and bare ground. JetBrains' `Island.arc`
and Canario's ≈7.5 are small because their islands tile a window edge to edge; ours is one card in
the middle of a field.

The compact island is not that number scaled down — a corner is read against the surface it cuts, not
as a ratio. 10 is one rung above Tahoe's own selected-row 8: clearly a rounded island, still clear of
the pill a 32pt row reaches at 16.

## The two worlds — one chrome polarity

| World | Where | Colour source |
|---|---|---|
| **Chrome** | the ground, sidebar, dividers, the band, the panel tab strip and its rail, the embedded workbench, overlays, Settings, empty states | Semantic system colours resolving LIGHT, on the one cream ground |
| **Glass** | the terminal island, the device streams, satellite pane windows | The one **terminal profile** (`SlateTheme.app`) |

**One chrome polarity, always light.** That is a CONSEQUENCE of the ground, not a second decision —
semantic ink pinned dark would draw white on cream in the navigator. `SlateAppearancePin` pins
`NSApp.appearance` to `.aqua` once at launch, so every auxiliary window matches the workspace chrome
and nothing is half-and-half; the glass is the one surface outside that pin, opting out locally via
`Slate.glassColorScheme` (a constant `.dark`). The app does not follow the OS appearance at all.
The embedded workbench webviews are pinned per-webview to the chrome polarity and
seeded to the Monokai Pro / Monokai Pro Light pair with `window.autoDetectColorScheme`, plus a
`workbench.colorCustomizations` block that repaints every VS Code surface — editor, gutter, sidebar,
activity bar, tab strip, panel, status bar, title bar — in the ground cream and zeroes their borders,
so the panel is indistinguishable from the field it sits in (user-directed 2026-08-08; the generated
Dracula/Alucard workbench extension is still actively swept from seeded hosts).

Nothing may straddle the chrome/glass boundary: a view is either ON the chrome (semantic tokens over
the ground) or ON the glass (profile tokens, or semantic tokens under the forced glass scheme). The
boundary is exactly one edge in the whole window — the island's.

## Chrome — the ladder

- **Ground** — `Slate.Surface.field` = the profile's `ground` (`#FFFBEB`, the same in both),
  OPAQUE and fixed, painted at the window root, under all three columns, and as the window's own
  `backgroundColor`. No material, no gradient. (The fixed colour also keeps the CGColor-snapshot
  trap family dead — nothing dynamic reaches a layer.)
- **Column dividers** — GROUND, not a seam. `FlatDividerSplitView` fills both `drawDivider(in:)`
  and the split view's backing layer with the ground tone, so the three columns read as one
  continuous sunken field. The ONE edge the window draws is the island's.
- **Rules** — the profile's `chromeLine` `#312F37`: the ink tinted 10% over the ground
  (user-directed 2026-08-08), for pane seams inside the island and section rules on the ground.
- **Lift** — the profile's `chromeLift` `#2E2E3C` is the hover/raised rung for chrome objects that
  need a step up from the ground.
- **Sidebar** = flat on the ground, with a 40pt traffic-light reserve at its top — bare ground now,
  since the collapse toggle moved to window level. Collapsing HIDES the column (chrome revert, user-directed
  2026-08-08 — the 80pt rail is retired with the islands layout it belonged to); the toggle that
  brings it back stands at window level beside the traffic lights and never moves, and the band
  fills with the horizontal tab strip while the column is hidden.
  The active row is the column's one raised object: the translucent overlay card — a
  `Slate.Surface.raised` wash plus the `Line.card` hairline border. The wash TINTS the chrome
  floor and stays in its hue family; a solid fill does not (the system `chip` plate read as
  off-family neutral grey and is retired, as is the reverse-video colour-scheme flip of the
  2026-08-07 polish round — both user-directed 2026-08-08). Do not reintroduce either.
  Rows are one 32pt register: title, marks, and the trailing glyph slot — the round-14
  instrument readouts (cwd second line, turn clock, ages) left with the chrome revert.
- **Titlebar** — a transparent overlay on the content column's top strip (`SlateTitlebar`): while
  the sidebar is hidden it carries that column's tab list turned horizontal, and nothing else.
  The hover-reveal reopen plates it used to hold are both gone (user-directed 2026-08-09) — the
  navigator's toggle is a permanent window-level control and the panel leaves a rail behind — so no
  chrome object has to appear, or has to stand on the glass. No bar, no material: the chrome is the
  plates themselves.
- **Surfaces** (`Slate.Surface`): `field` → THE GROUND (above), `island` → the glass, `void`/`ground` →
  `underPageBackgroundColor`, `face` → `windowBackgroundColor`, `raised` → `quaternarySystemFill`,
  `lift` → `tertiarySystemFill`, `chip` → `controlBackgroundColor`.
- **Text** (`Slate.Text`): the semantic label tiers (`labelColor` → `tertiaryLabelColor`). Never a
  custom RGB for chrome text.
- **Lines** (`Slate.Line`): `separatorColor` — inside surfaces, and the island's own edge stroke.
  The column seams draw NOTHING: they are ground.
- **Status** (`Slate.Status`): `systemGreen` / `systemOrange` / `systemRed`; info rides the accent.
  Status dots are budgeted: the attention roll-up is the only dot the sidebar wears.

## The one brand colour

**Dracula purple**, fixed (user-directed over the system accent): light `#644AC9` (Alucard's
purple), dark `#9580FF` (the Pro purple) — `Slate.State.accent`, an appearance-dynamic pair; deep
fill band `#4B29A7`/`#6B4BD6` (`Slate.Accent.deep`, derived in-family). Spent ONLY on: selection
wash (15%), active tab, focus corner, divider drag line, link highlight, find-bar caret/toggles,
info status. Everything else interactive is the system's.

## Glass — the island

- The content column paints GROUND and lifts ONE island off it: `View.slateIsland()` — the glass,
  a 26pt continuous corner, a 12pt moat on all four sides (the band's row of controls is centred
  just below that top edge), and a 1px
  inset `Line.divider` stroke so the boundary survives the light profile where ground and glass are
  the same cream. Panes are flush INSIDE the island; splits are divided by the profile's
  `terminalEdge` line — a subtle line ON the glass, never a channel, never per-pane cards. There is
  exactly one call site; a second is the many-islands clutter coming back.
- **The command LADDER** (round 14) rides each terminal pane's trailing edge: one short tick per
  OSC-133 command block, oldest→newest top→down, in the status inks only (running = accent,
  clean = ok, failed = err). Muted at rest, full ink under the pointer; a tick click is the
  navigator's own re-anchor jump, confirmed by the existing landed flash. Ticks are EVENLY
  pitched, never scroll-proportional — blocks carry prompt ordinals, not rows, and this house
  draws what it knows (absent-never-wrong). An ordinal-less tick (mid-stream join) dims and
  goes inert.
- The column subtree runs under `.environment(\.colorScheme, Slate.glassColorScheme)` — the
  profile's own polarity — so every semantic colour used inside resolves against the glass.
  Satellite pane windows are glass edge-to-edge and adopt the same forced scheme.
- Divider at rest: `terminalEdge` hairline; while dragging: accent 2px + the live ratio readout.
- Focus = the small filled accent corner triangle (top-left, split tabs only). NO dimming — of
  panes or columns, in any strength (removed 2026-08-07); focus is the corner mark alone.
- **The band carries no title, and everything in it shares ONE row of centres.** The centred pane
  title and its menu are deleted (user-directed 2026-08-08); the top row is ground carrying the
  traffic lights, the sidebar toggle, the collapsed-state tab strip and the panel's surface tabs,
  every one of them centred at 20 (user-directed 2026-08-09) — a 24pt plate hangs from 8, a 16pt
  disc from 12, and the two read level because their CENTRES agree, not their top edges. The band is
  40 and every column's second row starts there; the island's top edge lands at 12, inside the row.
  NO chrome object stands on the glass any more: the panel's old reopen plate had to clear the 26pt
  corner to stay readable, and it was replaced by the rail (see below). Nothing was lost with the
  title: split / move / close keep their chords, and the cwd readout and Copy Path live in the
  palette's DIRECTORY section.
- **The panel column** (right) SINKS: it carries the workbench / device surfaces below a TAB
  STRIP band standing on the ground, closed by a `Line.divider` hairline. Its chips are ghost at rest, the hover wash under the
  pointer, and the SELECTED chip is a COMPACT ISLAND (island fill + hairline, ink on the glass) —
  the SAME chip the sidebar tab rows wear, because both are tabs answering the same question.
  **Collapsing it does not delete it — it narrows it to a RAIL** (`PanelRail`, user-directed
  2026-08-09): one plate wide, carrying the toggle at the band's control line (at exactly the x the
  open panel's own hide toggle stands at, so the target never moves) and the four surface tabs under
  it, turned a quarter turn to run down the rail. Same tabs, same selection, same plate — only the
  axis changed, which is the move the tab strip already makes when the LEFT column collapses. A rail
  tab EXPANDS the panel onto its surface, because a railed panel has no surface to show.
  The PLATE turns; the MARK DOES NOT (user-directed 2026-08-09). A word on its side is still a word,
  but a glyph on its side is a different glyph, and being recognised before it is read is the whole
  job of a mark — so the rail hands its angle to the tab and the mark takes it back out.
  **The rail arrives and leaves; it does not appear.** Collapsing, it waits out most of the column's
  exit and then slides in from the window's trailing edge, landing in ground the panel has already
  vacated (measured: the island settles at ~270ms, the rail lands at ~470ms). Expanding, it clears
  first — no delay, quick out — so the returning panel never has to shove it aside. The panel's own
  CONTENT leaves ahead of its width for the same reason: a workbench re-laid-out at every
  intermediate width is what made the collapse read as rough, so the content fades and the empty
  ground rides the rest of the slide. One gesture, one clock — the same arrive-on-land contract the
  horizontal tab strip keeps with the navigator, off the same `columnSlide` token.

## The terminal profile (`SlateTheme.app`)

The profile is Terminal.app-style: cells bg/fg, 16-slot ANSI, selection, caret, edge line, on-glass
ink tiers, an on-glass accent — plus the chrome ladder. The island tone is not a rung at all: it IS
the glass face, so the island can never ship in a tone the terminal does not wear. There is exactly
ONE:

| Glass = island | Ink | Edge (selection) | On-glass accent | Ground / line / lift |
|---|---|---|---|---|
| `#22212C` | `#F8F8F2` | `#454158` | `#9580FF` | `#FFFBEB` / `#312F37` / `#2E2E3C` |

ANSI: the Pro accent seven verbatim (no blue — the blue slot carries the purple, Dracula's own
terminal convention); brights REPEAT the bases; bright-black = the comment tone. The FIXED pills
(secure blue `#2D6FE8`, sync amber `#D97A1F`) sit outside the palette.

## Structure, type, motion (closed ladders)

- **Metrics**: 8pt grid; closed height ladder (`heightControl` 24 → `heightDrawer` 180); closed
  radius family; `check-ds-leaks.sh` enforces no raw font/radius/height literals in
  `Sources/SlopDeskClientUI`.
- **Alpha** (`Slate.Opacity`, round 13): the closed translucency scale — `faint` 0.12 (accent
  muted wash) / `wash` 0.15 (selection dose) / `dim` 0.35 (de-emphasised ink on a plate) /
  `muted` 0.6 (soft hairlines, secondary badge ink) / `scrim` 0.88 (HUD backdrop over live
  content). Chrome code picks a rung, never a raw `.opacity(N)`.
- **Elevation** (`Slate.Elevation` via `.slateShadow`, round 13): the closed shadow ladder —
  `card` 2/1 (the active card's whisper, `cardShadow` colour) / `chip` 4/1 (pills, mode badges,
  instrument chips) / `ghost` 8/2 (a pane mid-drag) / `panel` 12/4 (find bar, overlay cards) /
  `palette` 30/12 (the command palette, the deepest float). Radius/y never appear at a call site.
- **Type**: system face for prose; **JetBrains Mono instrument voice** for readouts,
  numbers, caps micro-labels — the terminal's own register bleeding into the chrome. This, not
  colour, is where the product's character lives. Three tracking rungs: `instrumentTracking` 1.2
  (mono engraving), `capsTracking` 0.6 (sidebar caps), `pillTracking` 0.5 (caps on a pill plate —
  measured off the system secure-input pill).
- **Pinned-fill inks**: `Text.onAccent` (white) on the saturated fill band (secure blue, sync
  amber, `Accent.deep`); `Text.onWarn` (black) on the warn/hazard plate (hint badges). Both
  appearance-independent because the fills they sit on are pinned.
- **Motion**: cubic-bezier only, no springs; one orchestrated moment (the connect handshake
  needle). Timing tokens in `Slate.Anim`; `pulse` is the ONE repeating shape and lives only in a
  preview that demonstrates blinking — the at-rest-motion purge stands.
- **THE ACKNOWLEDGEMENT** — `View.slateGlyphAck(_:)`, one definition for the whole app
  (user-directed 2026-08-09): a short DOWNWARD symbol bounce, and nothing else. It was the sidebar
  toggle's private effect; every chrome button now gives it, because a click deserves the same
  answer wherever it lands. A plain verb fires on the press (its real effect is a round trip away);
  a LATCHING control fires on the flag it lands on, so a chord or a menu row is indistinguishable
  from a click on the plate. Nothing translates and nothing resizes — the control is a landmark and
  what changed is the thing it acts on. `SlatePlateStyle` plays it for every plate automatically,
  so no call site has to remember to ask; tabs opt in on the tab that WINS the selection.
- **Interaction states**: rest / hover / selected everywhere; a true PRESSED fill exists only on
  the plate idiom (`SlatePlateStyle`, whose press previews the latch it lands on) — rows and tabs
  act instantly, so they do not carry one. Do not add pressed fills to instant-action rows.
- **Overlays**: `SlatePaperCard` — the ground's cream, opaque, at the island's corner — plus
  `Color.primary` ink (`SlateOverlayInk`). No material anywhere in the family. Settings stays pure
  system semantics (`SettingsInk` — a deliberate second world; do not route it through `Slate`).

## Do / Don't

- DO add new chrome colour needs as SEMANTIC system colours; if none fits, the design is wrong.
- DO put profile-dependent colour behind `SlateTheme` / `Slate.Terminal.*`. New fixed colour
  enters ONLY as a `SlateTheme` field, derived in the Pro hue family as a lightness rung.
- DON'T make a second island SURFACE. The archipelago — every column and every pane on its own card,
  parted by channels of ground — was built and rejected as too busy (user-directed 2026-08-08).
  `slateIsland()` has one call site. Also still dead: floating per-PANE cards (the summoned overlay
  card is a different thing and lives on paper, not glass), the liquid-glass floor and
  any translucent window material, plus five chrome worlds that are now the anti-reference — dark
  graphite, clay `#EFD0C2`, salmon `#C59B8B`, FOUNDRY ember, and the lavender frame `#B0A2EA`.
- DON'T change hue to separate regions — the only separations are the island's edge and the
  1px `chromeLine` rule.
- DON'T add dot indicators, badges, or per-project identity hues to chrome (`Slate.Identity` is
  deleted). The attention roll-up dot is the entire dot budget.
- DON'T float per-pane cards, add pane shadows, or tint any column per project.
- DON'T give any column its own material, tone or rounding — the ground is one opaque colour and
  the columns sink into it; only the terminal canvas is lifted.
- DON'T reach for `Surface.ground` / `Surface.face` / `Surface.void` in chrome. Those are the
  SYSTEM's aux-window tones and they sample a third grey next to the cream; chrome paints
  `Surface.field`. They stay legal only INSIDE the island, where the forced glass scheme resolves
  them against the glass, and in `GuiLeafView`'s scrim.
- DON'T lift a region of a surface with a second opaque tone — a lift is `Surface.raised`, which is
  translucent and tints the ground it stands on.
- DON'T put a MATERIAL on a floating card. The overlay family is paper (`slatePaperCard`); glass
  over two flat opaque tones has nothing to refract and reads as a grey slab.
- DON'T set a chord ("⇧⌘W") in the instrument voice — a monospaced cell collides the modifier
  symbols. `SlateKeycap` is the system face on purpose.
- DON'T add appearance pins beyond the ONE `SlateAppearancePin` app-level pin (no per-window, no
  per-control except the workbench webviews); DON'T let OS-appearance semantics leak into the
  glass (use the forced glass scheme).
- **Selection is a COMPACT ISLAND** (user-directed 2026-08-08) — the selected TAB, in the sidebar
  list and on the panel strip alike, is stamped out of the island's own material: island fill +
  divider hairline at `{rounded.compact-island}`, with the row's colour scheme flipped to the glass
  polarity so every ink on it resolves against the plate it stands on: a real invert — a dark chip on
  the cream ground. This REVERSES the 2026-08-07 "no reverse-video,
  no solid chip" verdict, which was written when the chrome ground was dark and a solid plate meant
  an off-family grey; on the cream ground the plate is the island tone, in family by construction.
  Still dead: accent tint or accent edge on the row, and underlines. `SlateListRow` (settings,
  popovers, generic lists) keeps the semantic raised card — this is a TAB gesture, not a list one.
- DON'T dim, veil, or fade a column to state focus — the accent corner mark only.
- DON'T touch the fixed pills (secure blue / sync amber) or route them through anything.
- DON'T write a raw `.opacity(N)`, shadow radius/y, or tracking literal in chrome code — pick a
  rung of `Slate.Opacity` / `Slate.Elevation` / the tracking trio, or the ladder needs a rung.
- DON'T draw the command ladder proportionally to scrollback rows, and don't give it hues
  beyond the status trio — the even pitch is the honesty contract; the fill is the vocabulary.
- DON'T hand-roll a zero-state: list surfaces speak `SlateNoResultsLine`, panes speak
  `SlateEmptyState` — text-only, never an illustration, never a decorative glyph.
