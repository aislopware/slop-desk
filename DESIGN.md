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
  sidebar:
    backgroundColor: "NSVisualEffectView .sidebar material (behind-window)"
    textColor: "semantic label tiers"
  list-row:
    backgroundColor: "transparent"
    textColor: "secondaryLabelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  list-row-active:
    backgroundColor: "{colors.accent} @ 15%"
    textColor: "labelColor"
    rounded: "{rounded.control}"
    height: "32px"
    padding: "0 12px"
  terminal-island:
    backgroundColor: "{colors.glass-ember}"
    rounded: "{rounded.island}"
    margin: "{spacing.space2}"
    border: "separatorColor hairline"
    note: "full window height — no reserved titlebar band; the ONLY island in the window"
  panel-tab-chip:
    backgroundColor: "quaternarySystemFill at rest; {colors.accent} @ 15% selected"
    rounded: "capsule"
    height: "24px"
---

# SlopDesk Design System — NATIVE / Terminal Island

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

**One island.** The terminal card is the only floating object in the window (user-directed
2026-08-07 after a two-island round: "too many islands is ugly"). Both flanking columns are FLAT
chrome fields; nothing else gets the island treatment, and no hard divider lines separate the
columns — the island's margins and the material change ARE the seams.

## The two worlds

| World | Where | Colour source | Follows OS appearance? |
|---|---|---|---|
| **Chrome** | sidebar, hover titlebar, right panel (strip + surfaces), overlays, Settings, empty states | Semantic system colours + system materials | **Yes** — light/dark, vibrancy, active/inactive |
| **Glass** | the terminal island, satellite pane windows, embedded workbench | The active **terminal profile** (`SlateTheme`) | **No** — the glass keeps its own polarity (Pages pattern) |

Nothing may straddle the boundary: a view is either ON the chrome (semantic tokens) or ON the glass
(profile tokens, or semantic tokens under the island's forced colour scheme — see below). The three
dead chrome rounds died precisely because chrome and glass shared one invented palette.

## Chrome — the system's, verbatim

- **Sidebar** = a real `NSVisualEffectView` (`.sidebar`, behind-window, follows-window-active)
  behind a transparent hosting view (`SidebarMaterialController`). No painted ground. Wallpaper
  tint, vibrancy and inactive dimming come from the OS.
- **Surfaces** (`Slate.Surface`): `void`/`ground` → `underPageBackgroundColor`, `face` →
  `windowBackgroundColor`, `raised` → `quaternarySystemFill`, `lift` → `tertiarySystemFill`.
- **Text** (`Slate.Text`): the semantic label tiers (`labelColor` → `tertiaryLabelColor`). Never a
  custom RGB for chrome text — it silently opts the label out of vibrancy.
- **Lines** (`Slate.Line`): `separatorColor`, INSIDE surfaces only. Between the window's columns
  there is NO drawn seam (`FlatDividerSplitView` fills the divider gap with plain
  `windowBackgroundColor`): the sidebar material simply ends where the content field begins — hard
  hairlines between chrome regions would cut the window back into boxes around the island.
- **Status** (`Slate.Status`): `systemGreen` / `systemOrange` / `systemRed`; info rides the accent.
- **Identity** (`Slate.Identity`): the 8 system hues (red → purple), FNV-1a keyed per project — the
  Finder-tag dialect. Spent as spines/washes only, never row plates or text recolouring.
- **No forced appearance anywhere**: no `.preferredColorScheme`, no `NSWindow.appearance` pin, no
  per-control appearance pin. Semantic colours resolve per-appearance at draw time, which also
  dissolves the old D3 cross-`NSHostingController` repaint problem for chrome.

## The one brand colour

**Ember teal**, fixed (user-directed over the system accent): light `#007272`, dark `#3DB8B8`
(`Slate.State.accent`, an appearance-dynamic pair); deep fill band `#005555`/`#0E6B6B`
(`Slate.Accent.deep`). Spent ONLY on: selection wash (15%), active tab, focus corner, divider drag
line, link highlight, find-bar caret/toggles, info status. Everything else interactive is the
system's.

## Glass — the terminal island

- The WHOLE split tree of the content column is **one rounded glass card** (`radiusIsland` 12pt
  continuous, `islandMargin` 8pt of system chrome around it, one `separatorColor` hairline ring)
  running the FULL window height — there is no reserved titlebar band (Canario); the hover-reveal
  titlebar floats OVER the island's top edge and shows NOTHING at rest (title, cluster and reopen
  plates all fade in on strip hover, under the forced glass scheme while the island is up).
  Panes are FLUSH inside it; splits are divided by the profile's `terminalEdge` line — a subtle line
  ON the glass (JetBrains Islands), never a chrome-coloured gap, never per-pane cards or shadows.
- The island subtree runs under `.environment(\.colorScheme, Slate.glassColorScheme)` — the
  profile's own polarity — so every semantic colour used inside (status line, chips, overlays, drop
  washes) resolves against the glass, not the OS appearance. Satellite pane windows are glass
  edge-to-edge and adopt the same forced scheme.
- Divider at rest: `terminalEdge` hairline; while dragging: accent 2px + the live ratio readout.
- Focus = the small filled accent corner triangle (top-left, split tabs only). No dimming siblings.

## Terminal profiles (`SlateTheme`)

A profile is Terminal.app-style: cells bg/fg, 16-slot ANSI, selection, caret, edge line, on-glass
ink tiers and an on-glass accent. Chrome is untouched by profile switches. Built-ins (ids keep the
historic `foundry-` prefix so persisted choices resolve):

| Profile | Glass | Ink | Edge | On-glass accent |
|---|---|---|---|---|
| **Ember** (default) | `#27221E` | `#E6DED6` | `#3E3833` | `#66CCD1` |
| Ember Light | `#F6F0ED` | `#36312C` | `#E3DCD7` | `#007272` |
| Dusk | `#242129` | `#E5DCE9` | `#36343C` | `#B3B1FC` |
| Graphite | `#222325` | `#DFDFE3` | `#343537` | `#61C9E7` |

The Settings gallery ("Terminal Theme") previews each profile as a miniature of its own terminal.
The default is Ember under BOTH OS appearances — the glass does not follow the OS; Ember Light is an
explicit choice (or the dark-mode dual-slot). The FIXED pills (secure blue `#2D6FE8`, sync amber
`#D97A1F`) sit outside every palette, system and profile alike.

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
- DON'T add a second island (the right panel had one for an hour and it read as two competing
  systems); DON'T draw separator hairlines between the window's columns.
- DON'T force a colour scheme on chrome; DON'T let OS-appearance semantics leak INSIDE the island
  (use the forced glass scheme).
- DON'T touch the fixed pills (secure blue / sync amber) or route them through anything.
