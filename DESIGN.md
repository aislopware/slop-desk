---
name: SlopDesk
description: Low-latency remote-coding workspace for Apple platforms — the Dracula Pro colour world in the inverted-frame structure (light violet frame around dark terminal glass, and the reverse for Alucard); NATIVE semantic chrome standing on the frame; Slate token layer
colors:
  # CHROME is semantic — it has no hex of its own. These entries are the only fixed colours the app owns.
  accent: "#644AC9" # brand Dracula purple, light appearances (dark appearances use the Pro #9580FF)
  accent-deep: "#4B29A7" # fill/badge band (dark appearances #6B4BD6)
  glass-dracula: "#22212C" # default terminal profile — the Dracula Pro glass, verbatim
  glass-dracula-ink: "#F8F8F2"
  glass-dracula-edge: "#454158" # island-internal divider + selection fill (the Pro selection)
  glass-dracula-accent: "#9580FF" # on-glass accent (focus corner, drag line)
  frame-dracula: "#9993CD" # the inverted frame floor around the dark glass (5.6:1 vs the glass)
  frame-alucard: "#4C4869" # the inverted frame floor around Alucard's cream glass (8.3:1)
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
  island: "12px"
  pill: "20px"
spacing:
  space1: "4px"
  space2: "8px"
  space3: "12px"
  space4: "16px"
components:
  field:
    backgroundColor: "Slate.Surface.field — the PROFILE's authored FRAME floor, opposite polarity to the glass: Dracula → #9993CD, Alucard → #4C4869"
    note: "the ONE floor colour every column and divider gap paints; no materials, no vibrancy, no drawn seams. The frame is the measured Canario structure (their frame stands 8.9:1 off their tiles): an opposite-polarity tone in the glass's own hue family, so frame and glass read as one world while the island↔floor step is decisive (the derived same-polarity floors of earlier rounds sat at ~1.2–1.8:1 and the islands sank)"
  sidebar:
    backgroundColor: "the field (flat — no material)"
    textColor: "semantic label tiers"
  list-row:
    backgroundColor: "transparent"
    textColor: "secondaryLabelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  list-row-active:
    backgroundColor: "reverse video — the row flips its colorScheme environment, so the chip (controlBackgroundColor) and every ink inside resolve at the OPPOSITE pole: near-white chip + dark text on a dark floor, near-black chip + light text on a light floor"
    textColor: "labelColor (under the flipped scheme)"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  terminal-island:
    backgroundColor: "{colors.glass-dracula}"
    rounded: "{rounded.island}"
    margin: "{spacing.space2}"
    border: "none — separation is the field gap + radius (JetBrains Islands)"
    note: "full window height — no reserved titlebar band"
  panel-island:
    backgroundColor: "{colors.glass-dracula}"
    rounded: "{rounded.island}"
    margin: "{spacing.space2} top/bottom/trailing; NO leading margin — the terminal island's trailing margin is the shared channel"
    border: "none"
    note: "the right panel — its tab strip lives INSIDE the island, on the glass"
  panel-tab-chip:
    backgroundColor: "ghost (clear) at rest; raised wash on hover; selected = inverted micro-chip — glass INK fill with glass FACE text, the strip's reverse-video echo of the sidebar chip"
    rounded: "capsule"
    height: "24px"
---

# SlopDesk Design System — DRACULA / Inverted Frame

North star: **the frame is the theme's, the chrome is macOS's, the glass is Dracula's.** SlopDesk's
window is the measured Canario structure (round-8 verdict, user-directed 2026-08-07): a mid-light
violet FRAME floor on which native semantic chrome stands, framing dark glass islands that wear the
Dracula Pro palette verbatim — and the exact inverse for Alucard, the light theme (deep violet
frame around cream glass). The colour world is Dracula Pro's published set: glass `#22212C`, ink
`#F8F8F2`, selection `#454158`, comment `#7970A9`, and the normalized accent seven (S100/L75 —
red `#FF9580` through pink `#FF80BF`); only the frame floors and the deep accent band are derived,
all inside the Pro hue family (OKLCH H≈289). Chosen over three invented-hex chrome worlds AND the
warm FOUNDRY Ember world, which read as dated beside the modern references (Dracula Pro,
Catppuccin, Rosé Pine — all violet-band, accent-normalized).

Reference points: Dracula PRO (the palette itself and its normalize-the-accents method), Canario
(the inverted frame: a mid-light frame around near-black tiles, measured 8.9:1 — the "daring"
structure the safe one-polarity floors lacked), JetBrains Islands (ONE rounded card floating on
flat chrome, full window height, no title band; splits divided inside it; tabs as small rounded
chips), Terminal.app / Ghostty (semantic chrome, content deliberately fixed-palette).

**One frame, two islands.** The whole window floor is ONE flat colour — `Slate.Surface.field`,
painted identically by all three columns and the divider gaps, with no materials, no vibrancy and
no drawn seams. On that floor float exactly two glass islands: the terminal (centre) and the right
panel (whose tab strip lives INSIDE its island). Islands wear NO border and NO shadow — the field
gap and the radius are the whole separation. The left sidebar stays FLAT; its one floating object
is the active row's solid chip. The floor is the profile's authored FRAME, opposite polarity to
the glass: Dracula stands its dark glass in `#9993CD` (5.6:1 against the glass — the trial's paler
`#AFACD2` was rejected as washed), Alucard stands its cream glass in `#4C4869` (8.3:1). The frame
shares the glass's hue family, so frame and glass read as one world while the island↔floor step is
decisive — the same-polarity derived floors of earlier rounds (1.2–1.8:1) sank the islands.

## The two worlds — one polarity

| World | Where | Colour source |
|---|---|---|
| **Chrome** | the window field, sidebar, hover titlebar (empty state), overlays, Settings, empty states | Semantic system colours, resolved under the app's pinned CHROME polarity |
| **Glass** | the terminal island, the panel island (strip + surfaces), satellite pane windows, embedded workbench | The active **terminal profile** (`SlateTheme`) |

**Whole-app theme, TWO polarities per profile** (round 8): a profile carries `isLight` (the GLASS's
polarity — drives `Slate.glassColorScheme` and the webview appearance) and `chromeIsLight` (the
CHROME's — what `ThemeStore.pinAppAppearance` pins `NSApp.appearance` to). Both shipped profiles
are INVERTED: `chromeIsLight = !isLight`, so Dracula runs light chrome on its mid-light frame
around dark glass, and Alucard dark chrome on its deep frame around cream glass. The "System"
choice follows the OS by resolving to the pair (dark → Dracula, light → Alucard); a concrete
choice ignores the OS. The embedded workbench follows the GLASS polarity: the client pins each
webview's appearance to the glass, and the seeded `window.autoDetectColorScheme` + preferred-theme
pair map it to Dracula / Alucard per webview.

Nothing may straddle the chrome/glass boundary: a view is either ON the chrome (semantic tokens)
or ON the glass (profile tokens, or semantic tokens under the island's forced colour scheme — see
below). The three dead chrome rounds died precisely because chrome and glass shared one invented
palette.

## Chrome — the system's, verbatim

- **Sidebar** = FLAT on the shared window field — no material, no vibrancy (the `.sidebar`
  `NSVisualEffectView` round gave the column its own tone and a visible seam; removed 2026-08-07).
  The active row is the column's one raised object, and it is **reverse video** (polish round,
  user-directed 2026-08-07): the row flips its `colorScheme` environment, so the chip fill
  (`Slate.Surface.chip` → `controlBackgroundColor`) and every semantic ink inside re-resolve at
  the opposite pole — a light chip with dark text on the dark floor, a dark chip with light text
  on the light floor. Selection is stated by INVERSION (the ANSI reverse-video / Canario
  contrast-flip gesture), still entirely semantic — no invented hex.
- **Surfaces** (`Slate.Surface`): `field` → the profile's authored frame floor (see above — the
  ONE chrome colour that reads the theme; fixed hex per profile), `void`/`ground` →
  `underPageBackgroundColor`, `face` → `windowBackgroundColor`, `raised` → `quaternarySystemFill`,
  `lift` → `tertiarySystemFill`, `chip` → `controlBackgroundColor`.
- **Text** (`Slate.Text`): the semantic label tiers (`labelColor` → `tertiaryLabelColor`). Never a
  custom RGB for chrome text — it silently opts the label out of vibrancy.
- **Lines** (`Slate.Line`): `separatorColor`, INSIDE surfaces only. Between the window's columns
  there is NO drawn seam (`FlatDividerSplitView` fills the divider gap with the same field tone
  every column paints): the floor is one uninterrupted colour — hard hairlines between chrome
  regions would cut the window back into boxes around the islands.
- **Status** (`Slate.Status`): `systemGreen` / `systemOrange` / `systemRed`; info rides the accent.
- **Identity** (`Slate.Identity`): the 8 system hues (red → purple), FNV-1a keyed per project — the
  Finder-tag dialect. Spent as spines/washes only, never row plates or text recolouring.
- **One appearance pin, owned by the theme**: `ThemeStore.pinAppAppearance` sets `NSApp.appearance`
  from the active theme's CHROME polarity (`chromeIsLight`); windows carry NO pin of their own and
  inherit it. The pooled workbench webviews carry the one exception — a per-webview pin to the
  GLASS polarity, because they live inside an island. No other `.preferredColorScheme` /
  per-control pin exists. Semantic colours still
  resolve per-appearance at draw time — but the appearance they resolve under is the theme's.
  Trap: a `CGColor` assigned from a dynamic `NSColor` is a snapshot — resolve it inside
  `effectiveAppearance.performAsCurrentDrawingAppearance` and re-resolve in
  `viewDidChangeEffectiveAppearance`, or a theme flip leaves stale-pole pixels (the divider-gap
  line). The floor itself no longer carries this risk — it is a fixed colour per profile — but any
  OTHER dynamic `NSColor` reaching a layer does.

## The one brand colour

**Dracula purple**, fixed (user-directed over the system accent): light `#644AC9` (Alucard's
purple), dark `#9580FF` (the Pro purple) — `Slate.State.accent`, an appearance-dynamic pair; deep
fill band `#4B29A7`/`#6B4BD6` (`Slate.Accent.deep`, derived in-family). Spent ONLY on: selection
wash (15%), active tab, focus corner, divider drag line, link highlight, find-bar caret/toggles,
info status. Everything else interactive is the system's.

## Glass — the islands

- The WHOLE split tree of the content column is **one rounded glass card** (`radiusIsland` 12pt
  continuous, `islandMargin` 8pt of field around it, NO ring, NO shadow)
  running the FULL window height — there is no reserved titlebar band (Canario); the titlebar
  floats OVER the island's top edge. The column REOPEN plates are ALWAYS visible while their
  column is collapsed (Canario's small permanent titlebar toggles — hover-reveal toggles failed
  discoverability, user-directed 2026-08-07 polish round); only the connection cluster stays
  hover-reveal. The centred title menu was REMOVED — the sidebar's active row names the pane
  (user-directed 2026-08-07).
  Panes are FLUSH inside it; splits are divided by the profile's `terminalEdge` line — a subtle line
  ON the glass (JetBrains Islands), never a chrome-coloured gap, never per-pane cards or shadows.
- The island subtree runs under `.environment(\.colorScheme, Slate.glassColorScheme)` — the
  profile's own polarity — so every semantic colour used inside (status line, chips, overlays, drop
  washes) resolves against the glass, not the OS appearance. Satellite pane windows are glass
  edge-to-edge and adopt the same forced scheme.
- Divider at rest: `terminalEdge` hairline; while dragging: accent 2px + the live ratio readout.
- Focus = the small filled accent corner triangle (top-left, split tabs only). NO dimming — not of
  sibling panes, and not of the other island: the unfocused-island veil shipped in the polish round
  and was REMOVED the same day (user-directed 2026-08-07, contrast round — "drop the island
  dimming"). Do not reintroduce island dimming/veiling in any strength; focus is stated by the
  corner mark alone.
- **The panel island** (the right column) is the second glass card, same anatomy: glass fill,
  forced glass scheme, island radius, no ring — but NO leading margin (the terminal island's
  trailing margin is the shared inter-island channel; two margins there read as "too far apart",
  user-directed 2026-08-07 — every field gutter in the window is ONE margin wide). Its TAB STRIP
  sits INSIDE the island — the capsule chips, reload plate and hide toggle all resolve on the
  glass — and the surfaces below (workbench webview, simulator/emulator stages, placeholders) fill
  the card to its clipped corners. The SELECTED strip chip is the **inverted micro-chip** (polish
  round): glass-ink fill with glass-face text — the same reverse-video language as the sidebar
  chip, so the whole app has ONE way of saying "selected". At rest a tab is a ghost (no plate);
  hover is the raised wash.

## Terminal profiles (`SlateTheme`)

A profile is Terminal.app-style: cells bg/fg, 16-slot ANSI, selection, caret, edge line, on-glass
ink tiers, an on-glass accent — and, since round 8, the authored FRAME floor. Exactly TWO
built-ins (round-8 verdict: "just dark and light, no variant zoo"):

| Profile | Glass | Ink | Edge (selection) | On-glass accent | Frame |
|---|---|---|---|---|---|
| **Dracula** (default, dark glass) | `#22212C` | `#F8F8F2` | `#454158` | `#9580FF` | `#9993CD` |
| Alucard (light glass) | `#FFFBEB` | `#1F1F1F` | `#CFCFDE` | `#644AC9` | `#4C4869` |

ANSI: the Pro accent seven verbatim (no blue — the blue slot carries the purple, Dracula's own
terminal convention); brights REPEAT the bases (the Pro accents are already lightness-normalized
at the top of the band — a +L derivation only washes them); bright-black = the comment tone.
The Settings gallery previews each profile as a miniature of its own terminal. A profile choice is
a WHOLE-APP choice: glass polarity forces the island scheme, chrome polarity pins the app
appearance (inverted — see above). The "System" choice (and the fresh-install default) follows the
OS through the pair — OS dark → Dracula, OS light → Alucard — flipping live on an OS switch. The
FIXED pills (secure blue `#2D6FE8`, sync amber `#D97A1F`) sit outside every palette, system and
profile alike.

## Structure, type, motion (unchanged ladders)

- **Metrics**: 8pt grid; closed height ladder (`heightControl` 24 → `heightDrawer` 180); closed
  radius family; `check-ds-leaks.sh` enforces no raw font/radius/height literals in
  `Sources/SlopDeskClientUI`.
- **Type**: system face for prose; **JetBrains Mono instrument voice** for the rail, readouts,
  numbers, caps micro-labels — the terminal's own register bleeding into the chrome. This, not
  colour, is where the product's character lives now.
- **Motion**: cubic-bezier only, no springs; one orchestrated moment (the connect handshake
  needle). Timing tokens in `Slate.Anim`.
- **Overlays**: `SlateOverlayCard` glass/material + `Color.primary` ink — already native, the
  pattern the rest of the app now matches. Settings stays pure system semantics (`SettingsInk`).

## Do / Don't

- DO add new chrome colour needs as SEMANTIC system colours; if none fits, the design is wrong.
- DO put profile-dependent colour behind `SlateTheme` / `Slate.Terminal.*` and keep it inside the
  island.
- DON'T invent chrome hex beyond the profile's frame floor. The three dead hex worlds (dark
  graphite, clay `#EFD0C2`, salmon `#C59B8B`) and the warm FOUNDRY Ember world are the
  anti-reference: any future "give the chrome its own palette" proposal repeats a documented
  failure. New fixed colour enters ONLY as a `SlateTheme` field, derived in the Pro hue family.
- DON'T float per-pane cards, add pane shadows, or re-tint the island per project.
- DON'T add a THIRD island, and don't island the left sidebar — the composition is two glass
  islands on one flat floor, with the sidebar's active chip as the only other raised object.
  DON'T draw separator hairlines between the window's columns, and DON'T give any island a
  border ring or shadow.
- DON'T give any column its own material or background tone — the floor is ONE colour
  (`Slate.Surface.field`) or the composition collapses back into boxes.
- DON'T add appearance pins beyond the ONE `ThemeStore` app-level pin (no per-window, no
  per-control); DON'T let OS-appearance semantics leak INSIDE the island (use the forced glass
  scheme).
- DON'T introduce a second selection language: selected = reverse-video inversion (sidebar chip,
  strip micro-chip). No accent-tinted plates, no underlines for selection.
- DON'T dim, veil, or fade an island (or any column) to state focus — tried and removed
  2026-08-07; focus is the accent corner mark only.
- DON'T touch the fixed pills (secure blue / sync amber) or route them through anything.
