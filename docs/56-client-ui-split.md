# 56 — The client UI splits in two: AppKit on macOS, SwiftUI on iOS

> Read with [`DESIGN.md`](../DESIGN.md) (the visual language, unchanged by this split) and
> [`22-workspace-architecture.md`](22-workspace-architecture.md) (the store the two halves share).

`SlopDeskClientUI` was ONE SwiftUI target serving two products that have almost nothing in common.
This doc records the measurement that ended it, the two targets that replace it, and the boundary
that keeps them from growing back together.

## 1. The measurement

Taken on the tree at `287a3ba4`, over `Sources/SlopDeskClientUI` (183 files, 48 410 lines):

| | files | lines the compiler keeps |
| --- | --- | --- |
| whole target | 183 | 48 410 raw |
| macOS slice | 111 gated `#if os(macOS)` | 27 037 |
| iOS slice | 10 gated `#if os(iOS)` | 16 840 |
| compiles to NOTHING on iOS | 72 | — |

So the "shared" target was already two targets wearing one coat: 72 of its 183 files vanish on iOS,
and the halves overlap by far less than the file count suggests. Worse, the overlap that *does*
exist is mostly accidental — `CodeSidebarRecommendationTips` (838 lines), `WorkspaceControlBackend`
(308), `PaneDragCoordinator` (246) and `ClientControlServer` (171) all compile into the iOS app for
a code panel, a control socket and a pane-drag gesture that iOS does not have and will not get.

Two more facts decided the framework question for the macOS half:

- **The escape hatch is the norm, not the exception.** 53 files already `import AppKit`, with 19
  `NSView`/`NSViewController` subclasses, 13 `NSViewRepresentable`, 4 `NSViewControllerRepresentable`,
  21 `NSHostingView`/`NSHostingController` mount points and **32 `swiftui-introspect` call sites** —
  each one a place SwiftUI did not expose what the workspace needed. Every hard interaction in this
  app has already fallen out of SwiftUI and landed in AppKit: the divider drag
  (`FlatDividerSplitView`), the rail drag-and-drop (`HostWindowRowDragSource` +
  `HostWindowDropCatcher`, AppKit end-to-end after both SwiftUI DnD sides failed), the satellite
  windows (`SatellitePaneWindowController`, "NEVER a second SwiftUI `WindowGroup`"), and the split
  shell itself — the 2026-07-03 "Shell = pure SwiftUI `NavigationSplitView`" ruling was reverted in
  practice, and macOS runs `SlopDeskSplitViewController` today.
- **SwiftUI's development-speed argument is not being collected.** `grep '#Preview\|PreviewProvider'`
  over `Sources/` and `Tests/` returns **0**. The design loop here is pixel-verify against a
  screenshot (see the `build-verify` recipes), which AppKit runs identically.

And the usual reason not to rewrite a view layer does not apply: of 114 `SlopDeskClientUITests`
files (21 558 lines) only **11** import SwiftUI and **4** touch a `body`. The logic already lives
outside the views — that is the "pure decision + actuator" split this repo has been applying for a
year — so the suite survives a view-layer rewrite nearly intact.

## 2. The layers, and the one rule that makes them work

```
Sources/SlopDeskWorkspaceModel   value types                        — BOTH
Sources/SlopDeskWorkspaceCore    the DOMAIN: store, connection,     — BOTH
                                 terminal, agent
Sources/SlopDeskDevicePanels     the simulator + Android panels'    — BOTH
                                 domain (docs 47, 48)
Sources/SlopDeskClientCore       PRESENTATION LOGIC: palette, rail, — BOTH
                                 overlays, settings catalog, chrome
                                 + the COMPOSITION ROOT
Sources/SlopDeskClientUI         the DRAINING FLOOR (transitional)  — BOTH
Sources/SlopDeskMacUI            AppKit + Metal + CoreAnimation     — macOS only
Sources/SlopDeskPhoneUI          SwiftUI                            — iOS only
```

The `SlopDeskClientUI` row is scaffolding with an end date, not a layer: it is what the old single
target became once the two shells were lifted off it, and stage D drains it upward one surface at a
time (§3.5). When the last macOS surface leaves it, what remains is the phone's, and the target is
renamed rather than emptied.

The cut between the third row and the fourth is the one worth stating, because it is the one that
would otherwise blur: **`SlopDeskWorkspaceCore` is the domain, `SlopDeskClientCore` is what a UI asks
the domain for.** A pane, a connection, an agent's state are domain. A rail ROW, a palette RANKING,
which overlay is up, what a settings option is CALLED are not — they are a presentation of the
domain, and they would have grown inside the domain target one view model at a time had they not been
given their own floor. Nothing in either target draws; both are reachable from a phone and from a
Mac.

`Apps/ClientApp-macOS` links `SlopDeskMacUI`; `Apps/ClientApp-iOS` links `SlopDeskPhoneUI`. Neither
app links the other's UI target, and `Apps/Shared/AppMain.swift` — the last file that pretended one
`@main` could serve both — has forked into `Apps/ClientApp-macOS/AppMain.swift` and
`Apps/ClientApp-iOS/AppMain.swift`. What is left in `Apps/Shared` is the asset catalogue, which
genuinely is shared.

**The two halves ship the SAME product.** iOS is not a reduced macOS: every feature the desktop has,
the phone and the iPad have. What differs is LAYOUT — a 6" screen and a touch pointer want a
different arrangement of the same capabilities, not fewer of them. The code panel, the simulator and
Android panels, splits, the palette, the rail: all of it exists on both, laid out for the device.

**That parity is exactly why the split cannot be a copy.** Two SwiftUI/AppKit halves that each carry
their own `SimulatorSidebarModel` (731 lines), `AndroidSidebarModel` (833), `PaletteDataSource`,
`RailRowsBuilder` and `OverlayCoordinator` would be the same product implemented twice — the failure
mode `CLAUDE.md` bans by name. So the split has a PRECONDITION, and it is stage one of the work:

> **Everything in the client that is not a view moves out of the UI target first.**

A UI target may hold view types and nothing else. Every model, reducer, socket client, wire codec,
policy, formatter and cache leaves for the shared logic target, where both halves — and, per §4,
eventually Rust — reach it. After that evacuation the two UI targets hold layout and actuation only,
so "the same feature, laid out differently" costs a view, not a subsystem.

**macOS = AppKit.** `NSWindow`, `NSSplitViewController`, `NSView` subclasses, `CALayer`,
`NSCollectionView`/`NSOutlineView` where a list is a list. Motion is CoreAnimation, not
`withAnimation` — the 118 `withAnimation`/`.animation(` sites and the 3 `matchedGeometryEffect`
morphs are the real work of the port, and they land as explicit `CAAnimation`/`NSAnimationContext`
so the pixel-verify loop measures what the code says.

**iOS = SwiftUI.** At phone/tablet scale, with one pane on screen at a time and a system that hands
you the keyboard, sheet and navigation behaviours for free, SwiftUI reaches the ceiling this product
needs. The limitations that pushed macOS out — divider drags, cross-hosting-view drag-and-drop,
secondary windows, a 40-row rail under a mouse — are macOS-shaped problems.

## 3. The boundary

- **A view type never crosses.** `SlopDeskMacUI` and `SlopDeskPhoneUI` do not import each other and
  have no common view ancestor. If both halves want the same behaviour, the *decision* lives below
  the UI as a pure function and each half actuates it in its own framework. This is the same seam the
  store already uses; it is not a new idea, only a new place to apply it.
- **A framework call is not a view; a `some View` is.** Three files in `SlopDeskClientCore` name
  AppKit, Carbon or WebKit — `EnableSecureEventInput`, the app-frontmost notification edge, a
  `WKScriptMessageHandler`, `NSFontManager` for `font list`. They are actuators, and an actuator that
  draws nothing belongs with the logic it actuates for. Drawing them out into the UI targets would
  have made both halves carry the same three seams.
- **A UI target holds views only.** Anything that would compile without a view framework belongs in
  the shared logic target. This is what keeps feature parity from becoming duplicate code.
- **`#if os(...)` inside a UI target is a smell, not a tool.** A platform gate in a
  platform-specific target means the file is in the wrong target. The one allowed use is the
  whole-file guard that declares `SlopDeskPhoneUI`'s iOS-only nature to `swift build`, which
  compiles every SwiftPM target on the host triple.
- **Layout diverges; capability does not.** A feature landing on one platform is owed to the other,
  laid out for it. What is NOT owed is the same arrangement.

Three of these four are RATCHETED, in `scripts/check-supervisor.sh` (`make lint`): every file in a UI
target must name a view framework, `SlopDeskMacUI` may not carry a platform gate (and `SlopDeskPhoneUI`
may carry only its own), and neither half may import the other or the draining floor import upward.
Each of the three fails silently rather than loudly if it slips — a frameworkless file compiles, a dead
`#if` reads as a live rule, and the import that would give the two halves a common view ancestor is a
one-line edit.

## 3.5 The stages, and where they stand

The split lands incrementally, and the constraint on every increment is that the tree stays green and
nothing is ever implemented twice. No stage copies a file: a surface either moves, or it waits.

- **A — evacuate the logic (DONE).** Every model, socket client, wire codec, policy, formatter and
  cache that was sitting in the view target left for `SlopDeskClientCore` / `SlopDeskDevicePanels`,
  with its tests. What remains in the old target genuinely needs a view framework, which is what made
  the rest of this possible.
- **B — evacuate the composition root (DONE).** `SlopDeskClientApp.init()` was 300 lines of "what the
  app IS" — the store, the connection, the preferences, the overlay coordinator, the folder frecency,
  the agent hooks, the chrome and every seam between them — sitting inside a SwiftUI `App`. It is now
  `ClientComposition` (`SlopDeskClientCore/App/ClientComposition.swift`), which both shells hold as
  their single `@State`. **The platform seams are SINKS, not `#if`s:** the composition publishes
  `backgroundNoticeSink`, `longCommandSink` and `agentAttentionSink`, the Mac shell fills them with
  `UNUserNotificationCenter` + `NSSound`, and the phone leaves them nil because its in-app toast —
  pushed by the composition on both platforms — is its whole notification surface.
- **C — fork the shell (DONE).** `SlopDeskMacApp` (`SlopDeskMacUI`) and `SlopDeskPhoneApp`
  (`SlopDeskPhoneUI`) are two `@main` scenes with two app targets and no `#if os(...)` between them,
  where there used to be one scene with seventeen. The Mac's window actuators, termination drain,
  close gate and quit policy moved with it, and so did their tests (`Tests/SlopDeskMacUITests`).
- **D — move the macOS surfaces (IN FLIGHT).** The floor came first: every colour token now has ONE
  value, `Slate.Native`, in the platform's own colour type, and the SwiftUI rung is a wrapper over it
  — an `NSView` fills with an `NSColor`, so without that the AppKit half would have grown a second
  palette, which is the duplicate implementation this whole doc exists to prevent. Then the ROOT, and
  it moves TOP-DOWN for a structural reason: `SlopDeskMacUI` sits ABOVE the draining floor, so a view
  that has already moved can never be mounted by one that has not. `MacWorkspaceRootView` is the
  macOS window root — the split shell, the pinned sidebar toggle, the agent rollup, the overlay layer,
  the chrome wiring and the window title — and `WorkspaceRootView` is what is left: the phone's
  `NavigationSplitView` and its toolbar, under the one whole-file `#if os(iOS)` this doc allows.
  The split shell itself followed the root: `SlopDeskSplitViewController` (535 lines of pure AppKit)
  now lives beside it, and the three columns it hosts are handed over as view controllers by
  `WorkspaceColumnHosts` — a factory per column that dies with the column when that column is
  rewritten, rather than a `package` widening of three whole view structs that would outlive its
  reason. Each surface below them is then rewritten in AppKit inside `SlopDeskMacUI`
  and its SwiftUI original is DELETED in the same change — never a fallback, never a mirror. The 118
  `withAnimation`/`.animation(` sites and the 3 `matchedGeometryEffect` morphs are the real work.
  When the last one moves, `SlopDeskClientUI` holds only what the phone renders and is renamed
  `SlopDeskPhoneUI`.
  **The order inside stage D is settled by a measurement, not by taste.** An `NSHostingView` claims
  every hit inside its own bounds — a full-bleed one over `Color.clear` returns ITSELF from
  `hitTest(_:)`, not `nil` (measured 2026-08-17 with a two-view window: the corner of an empty hosted
  layer over a plain `NSView` resolved to the hosting view). So the root's floating-overlay layer
  cannot become an AppKit sibling of the split while the overlays inside it are still SwiftUI: the
  window would go click-dead everywhere the palette is not. The same arithmetic applies to any small
  chrome mount whose hosted frame is larger than its ink. What that means for the order:
  - a SURFACE is ported whole (a hosted column and its subtree), never one shared leaf at a time —
    a half-ported component kit would be the same button in two languages, which `CLAUDE.md` bans;
  - the overlays become their own windows/views (an `NSPanel` for the palette, explicit frames for
    the toasts) rather than a transparent layer over everything, which is what removes the last
    SwiftUI mount from the window root;
  - until then the root stays a SwiftUI composition over the AppKit shell, which is what it is today.

  **The first surface across is the ⌘/ cheat sheet, and the panel it rides on is the point.**
  `MacOverlayPanel` is the reusable half — a `.borderless` `NSPanel` added as a CHILD window of the
  workspace window, so it travels with a move, a Space change and a close for free; `MacCheatSheetView`
  is the cheat sheet drawn into it. The panel buys back three things the in-window `ZStack` was
  hand-rolling: the dismiss floor is the panel (opaque to hits by construction, so no `SlateClickTarget`
  standing in for a clear rectangle and no hit barrier on the card to stop the floor being reachable
  through it), Esc is the responder chain's `cancelOperation(_:)` rather than a backdrop modifier, and
  ordering the panel out restores the parent window's first responder by itself. It is driven from the
  scene by `MacOverlayPanels`, which diffs `coordinator.cheatSheetVisible` into a panel exactly the way
  `SatelliteWindowsCoordinator` diffs `detachedPanes` into windows — the flag stays the single truth, and
  a dismissal inside the panel flips the flag rather than tearing itself down, so the two cannot disagree.
  The cheat sheet left `OverlayHostView` in the same change; the phone presents it as a native `.sheet`
  from its own root. What the two halves share they share BELOW the view layer — `CheatSheetContent`
  (`SlopDeskClientCore`) carries the rows, the glyph gating and the column deal, the last over
  `slopdesk_cheat_sheet_columns` — and the LAYOUT is the only divergence: two columns on the Mac's 640pt
  of paper, one on a hand-held sheet, from the same `dealt(_:into:)`. `check-supervisor.sh` gates both
  failure modes: either half reaching past `CheatSheetContent` to the registry, and the shared host
  mounting the card again.

  **The second surface across is the notification corner, and it is the one that pays the stage off.**
  The cheat sheet is summoned — it exists for the second it is up — but `ToastStackView` was ALWAYS
  MOUNTED: a full-bleed `NSHostingView` over the whole workspace at all times, so an arriving card
  could animate in without a parent re-mount. That is the mount the bullet above is about, and the
  SwiftUI half could only survive it by toggling `.allowsHitTesting(!coordinator.toasts.isEmpty)` —
  one flag standing between the AppKit split and the mouse. `MacToastStack` makes the question go
  away instead of answering it: the panel is sized TO THE COLUMN and parked in the workspace's
  bottom-trailing corner, so the region that takes hits is exactly the cards and there is no flag to
  keep honest. It differs from the summoned panel in three ways it had to: it never becomes key (a
  card arriving mid-command must not swallow a keystroke), it is not a dismiss floor, and it orders
  itself out the moment the stack empties. It is ambient, so the scene drives it off the LIST rather
  than off a flag — `syncToasts`, not `setCheatSheet`. What the two halves share is
  `ToastPresentation` (`SlopDeskClientCore`): the headline over `slopdesk_ws_notify_toast_headline`
  (resolved from speaker + flavour together — the same flavour is "is done" for an agent and
  "finished" for a command), the spine budget, the mark's rung and glyph, and the dwell length. Each
  half keeps only its LAYOUT and its own view of the ink ladder — four lines mapping a named rung to
  `Color` on the phone, to `NSColor` on the Mac. `check-supervisor.sh` gates the three decays: either
  half dropping `ToastPresentation`, either half re-deriving the phrase from `(source, flavor)`, and
  the shared host mounting the column again.
- **E — the Rust port (§4).**

## 4. What moves to Rust

The split makes a second question answerable: with the view layer split by platform, everything left
that is neither AppKit nor SwiftUI is pure logic, and this repo's standing rule is that pure logic is
Rust (`CLAUDE.md`: "Rust is the default; perf parity is enough to move existing Swift. Only
SwiftUI/AppKit justifies staying in Swift"). The port list and its order live in §5 of this doc as
each stage lands.
