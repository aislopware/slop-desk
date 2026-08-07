---
name: SlopDesk
description: Low-latency remote-coding workspace for Apple platforms — NATIVE chrome (semantic system colours + real materials) around one dark-glass terminal island; Slate token layer
colors:
  # CHROME is semantic — it has no hex of its own. These entries are the only fixed colours the app owns.
  accent: "#007272" # brand Ember teal, light appearances (dark appearances lift to #3DB8B8)
  accent-deep: "#005555" # fill/badge band (dark appearances #0E6B6B)
  glass-ember: "#27221E" # default terminal profile — cells / island ground
  glass-ember-ink: "#E6DED6"
  glass-ember-edge: "#3E3833" # island-internal divider + selection fill
  glass-ember-accent: "#66CCD1" # on-glass accent (focus corner, drag line)
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
    backgroundColor: "Slate.Surface.field — the PROFILE's derived floor: glass face blended toward the profile ink (22% dark / 17% light). Ember → #514B46, Ember Light → #DAD8D4"
    note: "the ONE floor colour every column and divider gap paints; no materials, no vibrancy, no drawn seams. Derived from the active profile, never authored hex: the floor shares the glass's temperature (Canario's frame/tile kinship) and stands a real step off the islands (1.83:1 dark / 1.37:1 light — the earlier windowBackground blend was neutral-against-warm at ~1.2:1 and read as close-but-clashing)"
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
    backgroundColor: "{colors.glass-ember}"
    rounded: "{rounded.island}"
    margin: "{spacing.space2}"
    border: "none — separation is the field gap + radius (JetBrains Islands)"
    note: "full window height — no reserved titlebar band"
  panel-island:
    backgroundColor: "{colors.glass-ember}"
    rounded: "{rounded.island}"
    margin: "{spacing.space2} top/bottom/trailing; NO leading margin — the terminal island's trailing margin is the shared channel"
    border: "none"
    note: "the right panel — its tab strip lives INSIDE the island, on the glass"
  panel-tab-chip:
    backgroundColor: "ghost (clear) at rest; raised wash on hover; selected = inverted micro-chip — glass INK fill with glass FACE text, the strip's reverse-video echo of the sidebar chip"
    rounded: "capsule"
    height: "24px"
---

# SlopDesk Design System — NATIVE / Islands

North star: **the chrome is macOS's; the terminal is ours.** SlopDesk's window is a native macOS
app — real sidebar material, semantic system colours, system hairlines, the OS light/dark switch —
wrapped around one deliberate object: the terminal, a single dark-glass island floating on the
system chrome. (Adopted 2026-08-07 after three invented-hex chrome worlds — dark graphite,
split-tone clay, sampled salmon — all read as generic. The verdict from that cycle: *native is a
dynamic system, not a palette.* Wallpaper tint, vibrancy, inactive-window dimming and the semantic
label tiers cannot be faked with static hex; the only static palette that survives is the one inside
the terminal glass, where fixed colour is the point.)

Reference points: Terminal.app / Ghostty (all chrome native, content deliberately dark — the Pages
pattern), Panic Nova (native materials with a full-bodied sidebar/panel presence — the chosen craft
bar), JetBrains Islands + Canario (ONE rounded card floating on flat chrome, full window height,
no title band; splits divided inside it; tabs as small rounded chips).

**One floor, two islands.** The whole window floor is ONE flat colour — `Slate.Surface.field`,
painted identically by all three columns and the divider gaps, with no materials, no vibrancy and
no drawn seams (user-directed 2026-08-07: a sidebar wearing its own material tone beside the flat
content field read as "a mess", not a floor). On that floor float exactly two glass islands: the
terminal (centre) and the right panel (whose tab strip lives INSIDE its island). Islands wear NO
border and NO shadow — JetBrains ships island borders equal to the island fill; the field gap and
the radius are the whole separation. The left sidebar stays FLAT; its one floating object is the
active row's solid chip (Canario's white active tab). The floor is the PROFILE's own derived tone
(contrast round, user-directed 2026-08-07): the glass face blended toward the profile ink — 22% on
dark profiles (Ember → `#514B46`, 1.83:1 against the glass), 17% on light (Ember Light →
`#DAD8D4`, 1.37:1). Two things the earlier `windowBackgroundColor` blend could not do: the floor
carries the glass's TEMPERATURE (Canario's frame reads as one world with its near-black tiles —
8.9:1 measured — because they share a hue family; a neutral system grey beside the warm glass read
as two worlds pushed together), and the island↔floor step is decisive instead of the reference's
~1.2:1 whisper, which vanished on these tones. Direction still follows JetBrains in both modes:
islands lighter than the floor in light, darker in dark.

## The two worlds — one polarity

| World | Where | Colour source |
|---|---|---|
| **Chrome** | the window field, sidebar, hover titlebar (empty state), overlays, Settings, empty states | Semantic system colours, resolved under the app's pinned appearance |
| **Glass** | the terminal island, the panel island (strip + surfaces), satellite pane windows, embedded workbench | The active **terminal profile** (`SlateTheme`) |

**Whole-app theme** (user-directed 2026-08-07, polish round): the theme choice drives the ENTIRE
window. `ThemeStore` pins `NSApp.appearance` to the active theme's polarity, so a dark theme is an
all-dark app and a light theme an all-light one — never half-and-half. The "System" choice follows
the OS by resolving to the per-OS Ember pair (dark → Ember, light → Ember Light); a concrete choice
ignores the OS. The embedded workbench follows the same pin: the webview inherits the app
appearance and the seeded `window.autoDetectColorScheme` + preferred-theme pair map it to
Foundry Ember / Foundry Ember Light per client.

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
- **Surfaces** (`Slate.Surface`): `field` → the profile's derived floor (see above — the ONE
  chrome colour that reads the theme, and it is derived, not authored), `void`/`ground` →
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
  from the active theme's polarity (the whole-app theme); windows carry NO pin of their own and
  inherit it. No other `.preferredColorScheme` / per-control pin exists. Semantic colours still
  resolve per-appearance at draw time — but the appearance they resolve under is the theme's.
  Trap: a `CGColor` assigned from a dynamic `NSColor` is a snapshot — resolve it inside
  `effectiveAppearance.performAsCurrentDrawingAppearance` and re-resolve in
  `viewDidChangeEffectiveAppearance`, or a theme flip leaves stale-pole pixels (the divider-gap
  line). The floor itself no longer carries this risk — it is a fixed colour per profile — but any
  OTHER dynamic `NSColor` reaching a layer does.

## The one brand colour

**Ember teal**, fixed (user-directed over the system accent): light `#007272`, dark `#3DB8B8`
(`Slate.State.accent`, an appearance-dynamic pair); deep fill band `#005555`/`#0E6B6B`
(`Slate.Accent.deep`). Spent ONLY on: selection wash (15%), active tab, focus corner, divider drag
line, link highlight, find-bar caret/toggles, info status. Everything else interactive is the
system's.

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
ink tiers and an on-glass accent. Chrome is untouched by profile switches. Built-ins (ids keep the
historic `foundry-` prefix so persisted choices resolve):

| Profile | Glass | Ink | Edge | On-glass accent |
|---|---|---|---|---|
| **Ember** (default) | `#27221E` | `#E6DED6` | `#3E3833` | `#66CCD1` |
| Ember Light | `#FCFAF7` | `#36312C` | `#E9E2DC` | `#007272` |
| Dusk | `#242129` | `#E5DCE9` | `#36343C` | `#B3B1FC` |
| Graphite | `#222325` | `#DFDFE3` | `#343537` | `#61C9E7` |

The Settings gallery ("Terminal Theme") previews each profile as a miniature of its own terminal.
A profile choice is a WHOLE-APP choice (polish round): its `isLight` polarity pins the app
appearance, so picking Ember darkens the entire window and picking Ember Light lightens it. The
"System" choice (and the fresh-install default) follows the OS through the Ember pair — OS dark →
Ember, OS light → Ember Light — flipping live on an OS switch. Every profile also DERIVES the
chrome floor the app stands on (`SlateTheme.floorHexValue` — face blended toward ink), so a
profile switch retunes the whole window's ground without any authored chrome colour. Ember Light's
glass is NEAR-WHITE, a step LIGHTER than its derived floor (the JetBrains light relationship:
white islands on grey). The FIXED pills (secure blue `#2D6FE8`, sync amber `#D97A1F`) sit outside every palette,
system and profile alike.

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
- DON'T invent chrome hex. The three dead worlds (dark graphite, clay `#EFD0C2`, salmon `#C59B8B`)
  are the anti-reference: any future "give the chrome a palette" proposal repeats a documented
  failure.
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
