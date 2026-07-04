# UI restructure blueprint — 2026-07-04

Research-driven blueprint for the comprehensive visual restructure of the client shell.
Trigger: user assessment of the current (card-canvas / region-rhythm, `5772cd5..bddf9a9`) UI —
pane margins waste space, layout is ad hoc, the header is unremarkable, and components are
rough (the centred connection pill's inner content overflows its own background).
Goal: *"the most beautiful, most ergonomic, most elegant dev workspace on macOS."*

Four parallel research passes feed this doc: (a) codebase inventory of the current UI,
(b) best-designed macOS apps (Ghostty/Zed/Warp/Nova/Linear/Raycast/Arc/Things/Tailscale/VS Code,
numbers pulled from Ghostty `Config.zig` and Zed `default.json` sources directly),
(c) HIG macOS 26/27 + design-craft writing (Linear quality essay, Rauno Freiberg, Emil Kowalski,
density research), (d) SwiftUI/macOS-26 implementation techniques.

---

## 1. Research verdicts (what the evidence says)

### 1.1 Pane margins & the card-canvas
- **2026 consensus in top terminals/editors is content-maximising, not floating cards.**
  Ghostty defaults: `window-padding = 2pt`, hairline theme-derived `split-divider-color`,
  focus shown by **dimming unfocused splits to 0.7 opacity** (overlay rect), no borders.
  Zed defaults: `active_pane_modifiers.border_size = 0.0`, `inactive_opacity = 1.0` —
  no border, no dimming; divider + cursor state carry focus.
- **macOS 27 "Golden Gate" itself walks back the floating-bubble look**: sidebars return
  edge-to-edge ("no unnecessary sidebar shadowing that just takes up space"), uniform
  toolbars, one window corner radius (~20pt reported, down from 26pt) instead of Tahoe's
  five-plus variable radii. Apple is correcting toward flat/uniform; per-pane floating
  cards with shadows swim against that current.
- Current implementation cost: 8pt inter-pane gap + 4pt outer margin (`Slate.Metric.paneGap`,
  halved per layer in `ContentColumn`/`SplitContainer`) + 1–2pt border + shadow, and the
  card-vs-margin tones are nearly indistinguishable in several Monokai filters
  (`0x2D2A2E` vs `0x221F22`) — we pay the full space tax of "floating cards" without
  getting the depth read.

### 1.2 Connection status
- **No best-in-class app centres a status pill with embedded buttons.** VS Code: bottom-left
  status-bar chip. Linear: tiny top-corner ambient badge, banner only during incidents.
  Tailscale: "should feel nearly invisible when it's connecting you" — icon state only,
  detail in an on-demand panel. Screen Sharing: a menu, no persistent indicator.
- Shared pattern: **healthy state collapses to a glyph; degraded state earns the space**;
  actions (retry, metrics) live in a click-popover, never as always-visible buttons.
- The overflow bug root cause (codebase pass): `TitlebarConnectionCluster` fixes
  `frame(height: 24)` but `.background(_, in:)` does not clip; there is no `.clipShape`,
  so scaled text/dot spill past the 24pt fill. Correct modifier order is
  **padding → background(shape) → clipShape(same shape)**. Separately, macOS and iOS ship
  two unrelated pill implementations (rounded-rect/tint vs Capsule/material).

### 1.3 Header/toolbar
- HIG three-zone model: leading = sidebar toggle + title; centre = *most common controls*
  (not ambient status); trailing = inspector/search/overflow. Symbols over text; no bezels;
  every toolbar action must also exist as a menu-bar command.
- `NSWindow.ToolbarStyle.unifiedCompact` is the sanctioned way to reclaim vertical space
  when the title text is hidden; Ghostty's default titlebar style is `transparent`
  (content color bleeds into the titlebar, proxy icon kept).

### 1.4 Craft rules that bind this redesign
- Hierarchy via **weight, not size** (HIG "Emphasized" column bumps weight only).
- **Density matches expertise**: expert daily-driver tools should err dense; the canvas gets
  maximum content-to-chrome ratio, chrome density rides the system sidebar size setting.
- Dark elevation = **lightness steps (~4–8% per level), not shadows** (shadows are invisible
  on near-black).
- Motion: ≤300ms, exits ~20% faster, ease-out for user-triggered, **zero animation on
  keyboard-driven high-frequency actions** (tab switch, palette), animate transform/opacity
  only, honour Reduce Motion.
- Concentricity formula (Liquid Glass): `childRadius = parentRadius − padding`; macOS 26
  ships `ConcentricRectangle` / `.rect(corners: .concentric)` for this.
- Glass is chrome-layer only — never over content (already our doctrine for the Metal canvas).

---

## 2. Target design

### 2.1 Canvas: flat, hairline, content-first (replaces card-canvas)
The Ghostty/Zed school, adapted:

- **Panes are edge-to-edge inside the detail area.** Outer margin: 0pt against sidebar and
  toolbar edges; the canvas surface *is* the detail background (kill the separate
  `Slate.Surface.margin` backdrop band; one surface, `Slate.Surface.card == theme background`).
- **1pt hairline dividers** between panes, color = theme hairline (the existing
  `Slate.Line.cardBorder` derivation, ~0.08 fg-hue). Divider hit-band stays wide (existing
  `PaneDivider` 2pt hover affordance); accent line only while dragging (already true).
- **Focus = content dim, not chrome**: unfocused panes render a theme-background overlay at
  ~0.12–0.18 strength (Ghostty dims to 0.7; we go gentler since GUI-video panes shouldn't
  look "broken"). Focused pane gets **no border by default**. Keep a 2pt `strokeBorder`
  accent ring only for the transient "focus just moved via keyboard" flash if wanted.
- **Window-level rounding only**: theme background applied via `.containerBackground` /
  full-bleed so the window's own (uniform, macOS 27) corner radius does the rounding.
  No per-pane `paneCornerRadius`, no per-pane shadow. Delete `panelShadow` use on panes.
- Terminal content keeps a small **content inset inside its pane: 6–8pt** (Ghostty ships 2pt
  but community configs converge on 8–16; 6–8 balances our block decorations) — this is
  *inside* the pane, not workspace chrome.

Net reclaim vs today: ~8pt per split axis + 8pt around the canvas + shadow bleed, and the
canvas reads as one calm surface (the macOS 27 direction) instead of near-identical tones
fighting at 10pt radii.

### 2.2 Connection status: ambient glyph + popover (replaces centred pill)
- **Healthy/connected**: a single small status element at the toolbar **trailing** edge —
  status dot (6pt) + host name in `.subheadline`, no fill, no border, no buttons. Optionally
  dot-only once hover-expand feels right.
- **Click → popover**: host, RTT/FPS/bitrate metrics (`.monospacedDigit()` +
  `.contentTransition(.numericText())`), replay/FEC state, Retry and Disconnect actions.
  This is where the old pill's buttons go.
- **Degraded/reconnecting**: the element earns space and color — amber/red dot with
  `symbolEffect(.pulse)` or the existing Pow glow, label swaps to the state
  ("Reconnecting…"), and Retry surfaces inline. Stall scrim on the affected pane remains
  the pane-level signal (keep `StallScrimLatch` semantics).
- **One implementation** for macOS + iOS: capsule geometry driven by padding
  (`.padding(.horizontal, 10).padding(.vertical, 3)`) — never a fixed frame height with
  unclipped background. If any filled state remains, modifier order is
  padding → `background(.regularMaterial, in: Capsule())` → `clipShape(Capsule())` →
  `contentShape(Capsule())`. Delete `ConnectionStatusPill` (iOS) and
  `TitlebarConnectionCluster` in favour of the shared view.
- Titlebar `.principal` slot is thereby freed (see 2.3).

### 2.3 Header: quiet, three-zone, informative
- Leading: sidebar toggle (system) + `.navigationTitle` = active tab title,
  `.navigationSubtitle` = host or cwd (weight/secondary-color hierarchy, no size games).
- Centre (`.principal`): empty by default — the calmest headers (Zed, Nova, Things) don't
  centre anything. (Future option: a compact tab strip if in-titlebar tabs return.)
- Trailing: status element (2.2) · Pane Actions "⋯" `Menu` · Windows-panel toggle,
  as one `ToolbarItemGroup` with a `ToolbarSpacer` before the status element.
  Symbols only, no bezels, every action mirrored in the menu bar.
- Adopt `.unifiedCompact(showsTitle: true)`; evaluate `toolbarBackgroundVisibility(.hidden)`
  + theme bleed (Ghostty `transparent` style) as a follow-up experiment — but only after
  the flat canvas lands, so the bleed has one surface to bleed into.
- Window dimming on deactivate: key off `@Environment(\.appearsActive)` — mute the status
  dot and dim the hairlines when the window isn't key.

### 2.4 Token consolidation (one scale, one shadow, one scrim)
- `Slate.Metric` becomes the single geometry scale: spacing {2,4,6,8,12,16}, radius
  {small 4, control 6, container derived-concentric}, hairline 1. Kill hand-typed radii
  (4/6/10 today) at call sites.
- **One shadow spec** (only overlays/popovers keep shadows now; panes lose theirs) and
  **one scrim spec**: theme `terminalBackground.opacity(0.6)` for both resize and stall
  scrims (`StreamStallScrim` currently hardcodes `Color.black`).
- Fix stale doctrine comments (`SlateDesign.swift:176` "FLAT by construction",
  `PaneStatusPills.swift:3` "no persistent titlebar") — they mislead future passes; after
  this restructure the FLAT comment becomes true again and should say *why*.
- `check-ds-leaks.sh` baseline will move (Slate refs drop); update in the same commit.

### 2.5 Motion & micro-polish pass
- Tab switch, palette, pane focus moves: **no transition** (keyboard-frequency rule).
- Metrics text: `.contentTransition(.numericText())`; status icon swaps:
  `.contentTransition(.symbolEffect(.replace))`.
- Any entrance/exit ≤ 250ms ease-out; exits faster than entrances; Reduce Motion honoured
  (Pow effects already gate; verify).
- Sidebar: keep native `List(.sidebar)`; rows adopt the system small/medium/large density
  tiers rather than custom padding; "Windows" section keeps real app icons (good already).

---

## 3. Implementation plan (each phase independently shippable)

**P1 — component correctness (small, immediate)**
Fix the pill overflow (shared capsule component, correct modifier order), unify the two
pill implementations, unify scrim colors, sweep hand-typed radii onto the token scale.

**P2 — status restructure**
Ambient trailing status element + popover with metrics/actions; free the `.principal` slot;
degraded-state expansion; `appearsActive` muting.

**P3 — flat canvas**
Remove per-pane card chrome (radius/border/shadow) and the margin backdrop; hairline
dividers; unfocused-pane dim; content inset 6–8pt; delete dead `Slate` tokens; ds-leaks
baseline update; golden/goldens untouched (pure view-layer).

**P4 — header polish + experiments**
`unifiedCompact`, title/subtitle hierarchy, toolbar grouping; then the transparent-titlebar
bleed experiment behind a quick A/B.

Verification: `make check` per phase; `bash scripts/check-macos.sh` + screenshot pixel
check for P2–P4 (needs unlocked GUI session); HW A/B on macbook via
`.work/deploy-client.sh` for the canvas feel (dim strength, inset) — those two numbers are
taste constants to tune live, not derivable from research.

**Alternative retained (not recommended):** if the floating-card identity must stay,
tighten instead of flatten — gap 8→4pt, outer margin 4→0pt, radius 10→8pt concentric,
drop shadow, +6–10% lightness separation between `card` and `margin` per filter (dark-mode
elevation via lightness). This halves the space tax but keeps chrome the 2026-era leaders
have abandoned; the flat direction (2.1) is the primary recommendation.
