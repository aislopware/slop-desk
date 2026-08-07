---
name: SlopDesk
description: Low-latency remote-coding workspace for Apple platforms — FOUNDRY design language, Foundry Ember theme, Slate token layer
colors:
  surface-void: "#171310"
  surface-ground: "#201B17"
  surface-face: "#27221E"
  surface-raised: "#322C29"
  surface-lift: "#3E3833"
  ink-primary: "#E6DED6"
  ink-secondary: "#ADA8A3"
  ink-tertiary: "#7C7874"
  accent: "#60CDCD"
  accent-deep: "#009898"
  chroma-red: "#FB939C"
  chroma-orange: "#F2A56F"
  chroma-amber: "#E5BD66"
  chroma-green: "#8DCD8E"
  chroma-cyan: "#66CCD1"
  chroma-blue: "#78BEEF"
  chroma-purple: "#BCAAF4"
  chroma-magenta: "#E399D3"
  identity-0: "#E7958E"
  identity-1: "#DD9F6B"
  identity-2: "#BDB062"
  identity-3: "#85BF86"
  identity-4: "#55C2BC"
  identity-5: "#6AB8E4"
  identity-6: "#9BA9ED"
  identity-7: "#CA99D6"
  secure-input-blue: "#2D6FE8"
  sync-input-amber: "#D97A1F"
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
  list-row:
    backgroundColor: "transparent"
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  list-row-active:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.ink-primary}"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  plate-icon-button:
    backgroundColor: "transparent"
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.control}"
    size: "24px"
  popover-row:
    backgroundColor: "transparent"
    textColor: "{colors.ink-primary}"
    rounded: "{rounded.control}"
    height: "24px"
    padding: "0 8px"
  toast-card:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.ink-primary}"
    rounded: "{rounded.panel}"
    width: "320px"
---

# Design System: SlopDesk (FOUNDRY / Foundry Ember)

## Overview

**Creative North Star: "The Foundry Floor"**

A machine hall at night. The housings are warm graphite — dark metal that has held heat all day — and light on the floor means exactly one thing: work in progress. Each machine (project) wears its own enamel tag colour on its frame; the material glows where an agent is working, holds an amber lamp where it needs a hand, and cools to drained gray the moment the work stops. Nothing on the floor is decorated; everything visible is either structure or state.

FOUNDRY replaces MERIDIAN (documented 2026-08-07, replaced same day by user direction). The predecessor's failure was vocabulary, not discipline: ~89 chrome surfaces shared three luminance rungs and one accent, so a fleet of concurrent agents across several projects read as undifferentiated gray. FOUNDRY keeps every purge law that earned its place — no at-rest ornament, depth by light, closed ladders, mono instrument voice — and widens the vocabulary where the product grew: five surface rungs instead of three, and chroma readmitted **as information only**, in three budgeted registers.

The theme is not hand-picked hexes. Every colour below is generated from an OKLCH seed by the theme engine (`scripts` design tooling; generator of record: theme-forge) and audited with APCA-W3. **Foundry Ember** is the default seed: warm graphite base (hue 55, chroma 0.010) with a teal accent (hue 195). Alternate seeds (Dusk — cool mauve/iris; Graphite — near-neutral/cyan) share the identical engine, so every theme has identical chrome geometry and identical contrast — only temperature and accent voice change.

**Key Characteristics:**
- Heat is life: working = colour, waiting = amber, past = drained gray. Chrome at rest is warm graphite structure.
- Three chroma registers with hard budgets: IDENTITY (8 equal-weight project hues, spine + wash duty), STATE (closed agent-state machine), HAZARD (one amber, one meaning).
- Five surface rungs (void → ground → face → raised → lift), seams of 1px, flat square panes — density, not card layouts.
- Moderate contrast by design: primary ink APCA Lc ≈ 85, in the gap every beloved dark theme overshoots.
- One engine, many seeds: themes are OKLCH seed swaps, never per-theme redesigns.

## Colors

All values are Foundry Ember, generated at pinned OKLCH lightness/chroma and gamut-clipped by chroma only (hue and lightness never bend). Contrast is audited against `surface-face` with APCA-W3.

### Surfaces — the five-rung ladder
- **Void** (#171310): deepest chrome — tab strip, status bar, the 1px seams between panes, aux-window backdrops.
- **Ground** (#201B17): sidebar housing and panel housings. One step below the pane.
- **Face** (#27221E): the lit pane — terminal cells, content columns, popover grounds. libghostty's background is pinned to this hex so cells and chrome are one flat field.
- **Raised** (#322C29): cards, popovers, active rows, inset controls (search, kbd chips).
- **Lift** (#3E3833): hover/pressed on raised, selection fills, ANSI slot 0.

### Ink tiers
- **Primary Ink** (#E6DED6, Lc 85): content, titles, values. Deliberately below pure white — never #FFFFFF.
- **Secondary Ink** (#ADA8A3, Lc 53): labels, prose chrome; icons ride here.
- **Tertiary Ink** (#7C7874, Lc 29): captions, placeholders, drained/past state. The floor — nothing readable sits below it.
- Inks drift one hue-step warmer than the surfaces (hue 70 vs 55) so the page never reads as tinted text on neutral ground.
- Hairlines are primary ink at low opacity: divider 10%, card border 7%, subtle border 6%, active border 15%, hover plate 5%, selection 9%.

### Accent
- **Ember Teal** (#60CDCD, Lc 64; deep band #009898 for fills/badges): the single interaction accent — focused-pane corner mark, active divider on drag, selected controls, the working agent's spinner. Teal is chosen to sit maximally far from the amber hazard register. Never decoration, never headers.

### Chromatic set — text-sized, equal-loudness
Eight hues at per-hue tuned lightness (Helmholtz–Kohlrausch corrected: amber rides higher L than red so all eight read equally loud): red #FB939C (Lc 58), orange #F2A56F (61), amber #E5BD66 (67), green #8DCD8E (65), cyan #66CCD1 (64), blue #78BEEF (61), purple #BCAAF4 (60), magenta #E399D3 (58). These are the only hues syntax, diffs, git readouts, and status words may spend. Semantic constants: err → red, ok → green, hazard → amber, info → accent.

### Identity register — 8 project hues
#E7958E · #DD9F6B · #BDB062 · #85BF86 · #55C2BC · #6AB8E4 · #9BA9ED · #CA99D6 — one lightness (OKLCH 0.750), one chroma (0.100), hues spaced off the ANSI traps. A project keeps its hue for life (assigned round-robin at creation).

### Terminal ANSI-16
Slot 0 = lift; slot 7/15 = secondary/primary ink; slot 8 = tertiary ink; slots 1–6 = the chromatic set with blue leaned toward cyan (hue 225) for dark-bg readability; brights = same hue at +0.08 L. The theme pins libghostty to exactly these hexes.

### Fixed mode pills (theme-independent, never re-routed through the theme)
Secure-Input royal blue (#2D6FE8) and Sync-Input amber (#D97A1F) — modes that must read identically on every seed and never collapse into the theme accent.

### Named Rules
**The Heat-Is-Life Rule.** Colour is state, temperature is structure. A surface at rest is warm graphite; it takes on chroma only while something is alive on it, and drains to the tertiary-ink gray the moment the signal stops (stalled video desaturates in place; a disconnected project's spine drops to 28% opacity at the same luminance).
**The Three-Registers Rule.** Chroma is spent from exactly three budgets. IDENTITY: a project's hue appears as a 2px spine on its region plus at most a 3–5% wash on its active row — never per-row plates, never text recolouring. STATE: the closed agent-state machine (working → accent pulse mark, awaiting → amber ●, done → drained ✓ set only by the Stop hook, idle → tertiary ·). HAZARD: one amber, one meaning — an agent needs you; nothing else may borrow it.
**The Seeded-Engine Rule.** No hand-picked hexes. Every colour is generated from the OKLCH seed at pinned L/C and audited with APCA (ink ≥ 84, secondary ≥ 52, chromatics ≥ 57, placeholder ≥ 28 on face). A new theme is a new seed through the same engine; a colour the engine cannot generate does not ship.
**The Moderate-Contrast Rule.** Primary ink targets Lc ≈ 85 — above APCA's 75 bronze floor, deliberately below the 90 "preferred" — because this app is stared at for hours. No pure black surfaces (halation), no pure white text. Raising contrast to "fix" readability is a bug; fix the size or weight instead.

## Typography

**Display Font:** SF Pro (system)
**Body Font:** SF Pro (system)
**Label/Mono Font:** JetBrains Mono (falls back to SF Mono / system monospaced)

**Character:** Quiet system prose around an engraved mono instrument face. The mono family is the same one libghostty renders in the terminal, so the chrome's technical voice IS the pane's voice. (Carried unchanged from the predecessor — type was never the problem.)

### Hierarchy
- **Display** (400, 40px): empty-state and placeholder glyphs only.
- **Title** (600, 15px): a floating card's title — the only overlay size that outranks its content.
- **Body** (400, 13px): primary content and command input fields.
- **Base** (400, 12px): default UI labels.
- **Footnote** (400, 11px): secondary labels, chips, pills, tab titles.
- **Small** (400, 10px): captions, kbd hints, tab subtext.
- **Instrument** (mono, any size above): every number, caps micro-label, keycap, cwd/git/telemetry line, and the whole sidebar rail. Caps in the instrument voice track at 1.2px ("engraving"); system-face caps headers track at 0.6px.

### Named Rules
**The Instrument-Voice Rule.** Data speaks mono; prose speaks system. If a string is a measurement, a path, a chord, or a status word, it renders in the instrument face — sentences and menus never do.
**The Closed-Scale Rule.** No raw `.font(.system(size:))` in view code — every size is a named rung (lint-enforced).

## Layout

An 8px grid (spacing scale 4/8/12/16) under a closed height ladder — every vertical rhythm is a named rung, all multiples of 4: control 24, bar 28, row 32, section-header 24, strip (titlebar) 40, row-tall 44, row-stacked/input 48, drawer 180. Chrome dimensions are aliases into the ladder, never new literals.

Structure: left sidebar 220px (ground tone; the fleet roster groups tab rows by project under each project's identity spine), content column lit end-to-end, right panel with tab strip (Code / Simulators / Emulators / Desktop) that steps down through three label densities via ViewThatFits. Split panes are separated by a 1px void seam inside a 16px grab band (hover/drag: 2px, accent). Floating cards inset from the window by `cardMargin` (4 top / 16 sides and bottom).

**Density registers.** Every surface declares which of three registers it serves, and takes its rhythm from that, not from taste: **glance** (roster rows, status bar — 32px rows, marks + names only), **work** (panes, editors — content edge-to-edge, chrome recedes to hairlines), **supervise** (inspector, device cards — 44–48px rows, two text registers, room for a decision). A surface may not mix registers.

**The Fixed-Width Rule.** Recurring surfaces have one width each, decided by role, not content: popovers 260, toasts 320, form cards 460, settings option cards 116, device cards 180.

## Elevation & Depth

Depth by light, not lines or shadows: surfaces separate by ladder rung with no divider between. Dark seeds cast **no at-rest shadows anywhere** — a dark-on-dark shadow reads as a smudged edge, not lift. Light seeds allow exactly one: the active tab card's `black 4%, r2, y1`.

Floating overlays (switcher, palette, connect, toasts) ride a shared glass material card with one cast shadow vocabulary (radius 12, y 4, black 40% dark / 12% light) — every overlay at the same depth.

### Named Rules
**The Depth-By-Light Rule.** Surfaces separate by luminance rung, never by border-plus-shadow stacks.
**The One-Altitude Rule.** All floating cards hover at the same height; only the glass family floats at all.

## Shapes

Panes are flat, square, and edge-to-edge: no corner radius, no card, no gap — the workspace is a solid field cut by 1px void seams (the anti-Canario stance: the charm of coloured identity chrome without the shadow + radius + backdrop looseness). Radius exists only on chrome objects riding a closed family: 4 (small inner plates), 6 (tabs/controls/rows), 8 (inset cards), 12 (floating panels/toasts), 20 (pills). Focus is a small filled accent triangle (12px legs) in the focused pane's top-left corner — never a box, underline, or dimming of idle panes. The state mark is sized under a footnote's x-height so it reads as punctuation, not a badge.

## Components

### Fleet Row (`SlateListRow`, `SlateTabRow`)
- **Character:** typographic rows under a regional identity spine — the 2px project-hue bar runs the row's left edge; the row itself stays type.
- **Shape:** 32px height, 6px radius, 12px inset; active = raised fill + primary ink + identity wash at 5% (no shadow); drained (done/disconnected) = spine at 28% opacity + tertiary ink.
- **Slots:** generic leading/title/trailing; trailing builder receives live hover (meta ↔ close swap).
- **Agent mark column:** resting `·` (tertiary) · working pulse `· ✢ ✳ ✶ ✻ ✽` (accent) · awaiting `●` (amber) · done `✓` (drained, set only by the agent's Stop hook). The mark column belongs to agents exclusively.

### Plate Icon Button (`PlateIconButton`)
- 24px square plate, 6px radius, 13px glyph; hover = 5% plate; latched = ink and weight, never accent.

### Popovers (`SlatePopoverSection/Row/Divider`)
- 260px wide, raised ground; caps micro-label section headers (instrument voice); 24px rows with icon / title / subtitle / trailing checkmark-or-chord.

### Glass Overlay Card (`SlateOverlayCard` family)
- The one floating material: glass card, 12px radius, shared shadow (12/4). Hosts switcher (48px two-register MRU rows), palette/search (48px input strip), connect form (460px), cheat sheet, peek reply. Overlays are always-mounted `.overlay`s, never `.sheet`s. Cards swallow clicks and return the keyboard on dismiss.

### Toast Cards (`ToastStackView`)
- 320px uniform width, bottom-trailing column; glass card with leading mark (state-register tinted), headline voice; newest 2 show detail; dwell pauses on hover; close is hover-only. No progress bars, no countdowns.

### Connection Cluster (`ConnectionCluster`)
- Pure text instrument: hostname + status word + machine-pulse line (CPU/mem/disk) in the sidebar footer; no lamp, no dot. Health is brightness/weight, not hue.

### Empty States (`SlateEmptyState`)
- Typed causes with pinned copy (never-connected / link-down / no-tabs / connect-failed); 40px display glyph; at most one action; link-down offers none (it redials itself).

## Do's and Don'ts

### Do:
- **Do** pick a rung from the closed ladders (height, radius, type, spacing) — `make lint` fails raw `.font(.system(size:))`, `cornerRadius:`, and `.frame(height:)` literals under `Sources/SlopDeskClientUI`.
- **Do** route every animation through `Slate.Anim`'s cubic-bezier tokens (0.12–0.28s); the "needle" settle (0.24s, fast attack, no overshoot) is reserved for the connect handshake — the one orchestrated moment. No springs anywhere.
- **Do** drain, don't hide: anything not live desaturates in place (stalled video with a "RECONNECTING · Ns" age caption; done agents' spines dim to 28%).
- **Do** spend identity from the register: a new project surface gets its spine and wash from the project hue — and nothing else gets recoloured.
- **Do** keep the terminal and chrome one flat field: the theme pins libghostty's background/foreground/ANSI-16 to the same generated hexes.
- **Do** run any new colour through the engine and its APCA audit before it ships — if it can't be expressed as seed + pinned L/C, it doesn't exist.

### Don't:
- **Don't** add at-rest ornament: no grain, no gradients, no glow, no springs, no at-rest motion, no dark-theme shadows. Everything that ever died in this system was at-rest ornament.
- **Don't** animate text, ever (marks may pulse; glyph strings may not move).
- **Don't** let identity leak past its budget: no per-row colour plates, no recoloured titles, no identity-tinted icons — spine + wash only.
- **Don't** borrow the hazard amber for anything but "an agent needs you" — warnings that aren't that are ink weight, not hue.
- **Don't** give a command outcome a mark; the mark column is the agent's. Outcomes are word colour only.
- **Don't** use `.sheet` for overlays or vary a floating card's shadow — one glass family, one altitude.
- **Don't** hand-tune a hex or push contrast past the moderate stance (no #FFFFFF text, no #000000 surfaces, no "just a bit brighter" fixes).
