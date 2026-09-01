# 56 — The client UI splits in two: AppKit on macOS, UIKit on iOS

> ⚠️ **The iOS half of this doc's ruling was REVERSED.** The split itself stands — two targets, one
> per framework — but the phone's framework is UIKit, not SwiftUI: `62-phone-uikit.md` measured that
> and carried it out. SwiftUI is gone from the tree entirely (zero `import SwiftUI`). Read every
> "SwiftUI on iOS" below as history of the intermediate state.
>
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
exist is mostly accidental — `CodeSidebarRecommendationTips` (838 lines, since crossed to
`rust/slopdesk-codepanel`), `WorkspaceControlBackend`
(308), `PaneDragCoordinator` (246) and the client control socket's face all compile into the iOS app for
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
Sources/SlopDeskSlate            the DESIGN FLOOR: the token ladder — BOTH
                                 in both spellings, the status mark's
                                 geometry + cadence, the artwork
Sources/SlopDeskMacUI            AppKit + Metal + CoreAnimation     — macOS only
Sources/SlopDeskPhoneUI          SwiftUI                            — iOS only
```

**There is no draining floor any more (increment 63).** For most of this document's life the stack
carried a sixth row above `SlopDeskSlate` — `Sources/SlopDeskClientUI`, marked BOTH — which was
scaffolding with an end date rather than a layer: what the old single target became once the two
shells were lifted off it, drained upward one surface at a time by stage D (§3.5). The last macOS
surface left in increment 61, what remained was the phone's, and the target was RENAMED rather than
emptied. Read the two-renderer bottom of this stack as the finished shape; the increments below narrate
how it got there and still name the old target throughout, because that is what it was called then.

`SlopDeskSlate` is what that rename could not take with it. The tokens lived inside the draining target
for as long as there was one UI target to compile them into; the Mac reads ~200 of them, so on the day
`SlopDeskClientUI` became `SlopDeskPhoneUI` an AppKit target would have been importing the phone's — exactly
the common view ancestor §3 forbids. The line the floor holds is **a value, never a drawing**: `Slate`
in both its `NSColor`/`UIColor` and its `Color` spelling, `StatusDot`/`StatusMark`/`StatusDotStyle`,
`AgentSpinner`'s wandering tempo and `BrailleCell`'s walk, `SVGPath`/`VectorIcon`/`OttyIcon`, the
nerd-font splice's AppKit half, the chrome field's jump-free configuration, and `StatusPresentation`
— which is a palette ANSWER rather than a drawing. Every mark that has two renderers keeps them one
floor up, one per framework (`StatusDotView` / `MacStatusMarkView`, `VectorIconView` /
`MacVectorIconView`), and `slopdesk-invariants` fails the build if a `some View` appears in the floor.

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

  ⚠️ ASCENDING IS ONE OF TWO FIXES, AND THE WRONG ONE FOR A SEAM'S PAYLOAD. The rule catches a
  frameworkless FILE, which is not the same claim as "this type is shared logic". A per-platform
  seam's payload — the plain value one half's mount takes — is frameworkless and yet deliberately
  NOT shared: `VideoPaneSpec` omits `onSystemKeyInjectorReady` because its producer is a `CGEventTap`
  that does not exist on iOS, so hoisting it into the shared target would force one signature onto
  two platforms that genuinely disagree, which is the duplication this rule exists to prevent
  wearing the shape of the fix for it. The second fix is to put the value in the file that MOUNTS it,
  under that file's view-framework import: `MacVideoPaneSpec` sits in `MacVideoPaneView.swift` beside
  `MacVideoPaneControls`, and `VideoPaneSpec` sits in `VideoSurfaceHost.swift` beside
  `VideoPaneControls`, for the same reason. Ascend when the type would be spelled IDENTICALLY in both
  halves; fold when the halves are asymmetric on purpose.
- **`#if os(...)` inside a UI target is a smell, not a tool.** A platform gate in a
  platform-specific target means the file is in the wrong target. The one allowed use is the
  whole-file guard that declares `SlopDeskPhoneUI`'s iOS-only nature to `swift build`, which
  compiles every SwiftPM target on the host triple.
- **Layout diverges; capability does not.** A feature landing on one platform is owed to the other,
  laid out for it. What is NOT owed is the same arrangement.

Three of these four are RATCHETED, in `rust/slopdesk-invariants` (`just lint`): every file in a UI
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
- **C — fork the shell (DONE).** `SlopDeskMacApp` (`SlopDeskMacUI`) and — since docs/62 stage A
  rewrote the phone's half as `PhoneAppDelegate` — `PhoneAppDelegate` (`SlopDeskPhoneUI`) are two
  `@main` entry points with two app targets and no `#if os(...)` between them,
  where there used to be one scene with seventeen. The Mac's window actuators, termination drain,
  close gate and quit policy moved with it, and so did their tests (`Tests/SlopDeskMacUITests`).
- **D — move the macOS surfaces (DONE, increment 61; the fold that ended it landed in 63).** The floor came first: every colour token now has ONE
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
  The last one moved in increment 61, and increment 63 spent what that bought: `SlopDeskClientUI`
  held only what the phone renders, and was renamed `SlopDeskPhoneUI` rather than emptied.
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
  of paper, one on a hand-held sheet, from the same `dealt(_:into:)`. `slopdesk-invariants` gates both
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
  `Color` on the phone, to `NSColor` on the Mac. `slopdesk-invariants` gates the three decays: either
  half dropping `ToastPresentation`, either half re-deriving the phrase from `(source, flavor)`, and
  the shared host mounting the column again.

  **The third is the ⌃⇥ readout, and it closes the ambient layer.** `MacPaneSwitcher` is an `NSPanel`
  that `ignoresMouseEvents` outright — the readout's whole gesture lives on the keyboard, so a click
  during it belongs to the workspace — and it never becomes key, because stealing focus mid-gesture
  would break the `flagsChanged` release that COMMITS the switch. Its rows and its measurements were
  already below the view (`PaneSwitcherRowsBuilder`, `PaneSwitcherMetrics` in `SlopDeskClientCore`),
  so the port is the drawing and nothing else. It read as ONE half rather than two for a while, on the
  argument that the phone has no modifier stream to open ⌃⇥ with — see increment 74 for why that was
  about the opening CHORD and never about the surface. Both halves exist.

  **The fourth is the ⌘⇧P palette, and it is the first MODAL surface across.** The three before it
  were a reference card and two readouts; none had a text field or a list you steer, and this one has
  both — so what it settles it settles for Open Quickly, the global search and the peek reply behind
  it. Three things it answers that a readout never had to. THE KEYBOARD BELONGS TO THE FIELD, and the
  list is steered *through* it: the field editor is first responder for the card's whole life (it has
  to be, or typing would stop reaching the query), so ↑/↓/⇞/⇟/↩ arrive as editing COMMANDS and
  `control(_:textView:doCommandBy:)` is where the list reads them — which is also why ⌃P/⌃N cost
  nothing, the text system already binds them to `moveUp:`/`moveDown:`. The two chords that are not
  editing commands, ⌘↑/⌘↓ and ⌘↩, come through `performKeyEquivalent(with:)` instead. IT REDRAWS OFF
  OBSERVATION rather than off its own edits, because ⌘↩ runs a verb and keeps the card up, so the ✓
  gutter of the row just toggled has to flip under the pointer: `withObservationTracking` re-arms on
  every render. AND IT SIZES ITSELF TO ITS RESULTS — the card is fixed-width and variable-height, so
  `MacOverlayPanelController` grew a `resize(to:)` and a query that narrows to two rows gets a two-row
  card. What the halves share is `PalettePresentation` + `PaletteMetrics` (`SlopDeskClientCore`): the
  measurements, the pairing of ranked rows with the keyboard's index (a separator takes a LINE but not
  a selection — the one thing every half gets one off by hand), the ✓ predicate, and the WORKING
  DIRECTORY badge over `slopdesk_ws_cwd_badge_path`. That last is a stage-E move riding along: the
  home collapse was a Swift `CwdDisplay` sitting inside the view target, and it is now
  `PaneSpec::cwd_badge_path` in Rust — matched by SHAPE (`/Users/<name>`, `/home/<name>`) and never
  against the client's own `$HOME`, because the path came off the remote host.

  **The fifth is the ⌘⌥J peek card, and it is the first surface whose CONTENT moves under it.** The
  palette settled the shape of a card you type into and steer; what this one adds is that a reply
  ADVANCES the queue — the pane is answered, the target changes, and the card is re-cut for the next
  blocked pane without the panel ever going away. Three consequences. It redraws off observation for
  a stronger reason than the palette's: the advance is the *coordinator's*, so a card that only
  redrew on its own keystrokes would keep showing the pane it just answered. A new target CROSSFADES
  — without the beat, question / recent / pending-tool all mutate in one frame and it reads as the
  same pane changing rather than as the next one arriving; the phone gets that from `.id(target)` +
  a transition, the Mac from the family's short curve on the card's alpha, fired on the target edge
  and nowhere else. And one key is taken OFF the field: a bare 1–9 while the field is empty is the
  quick-answer shortcut, which has to be read before the field inserts the character, so it is
  answered in `performKeyEquivalent(with:)` — the door every key-down passes through, which is why a
  plain Return can drive a default button. Everything else stays the field's.

  What the halves share is `PeekReplyPresentation` (`SlopDeskClientCore`): the header caption and the
  order its parts truncate in, the "N of M" counter's hard cut, the note a pane with no reported
  question gets, the zero-state line. Behaviour was already below the view before this port existed
  — `PeekReplyTarget`, `PeekReplyFormatter`, the inspector store — which is most of why the card is
  a renderer on both sides.

  This is also the first DESIGN-SYSTEM LEAF to cross rather than a whole surface, and the terms are
  worth stating because the rule is "a surface is ported whole, never one shared leaf at a time".
  What crossed is a RENDERER, not a decision: `AgentReadout` (`SlopDeskClientCore`) maps a
  `ClaudeStatus` to a reading and an ink, `Slate.agentInk` / `Slate.Native.agentInk` are the two
  spellings of one ladder lookup, and the braille spinner's whole cadence — the wandering tempo, its
  closed-form integral, the walk's clockwise order — is *called* out of the shared design system by
  `MacAgentSpinnerView` rather than rewritten in it. Two renderers, one mark: a pane thinking in the
  sidebar and the same pane thinking in a peek card are the same hole at the same point of the same
  lap, because both read the same wall clock through the same integral. The only genuinely new line
  is that the AppKit view is FLIPPED — `BrailleCell.position` numbers rows top-down because SwiftUI's
  coordinate space does, and an unflipped `NSView` would turn the mark anticlockwise.

  **The sixth is the ⇧⌘F cross-tab results panel, and it is the first whose shared piece is a READING
  rather than a wording.** The surface itself is the palette's shape with one thing taken away and one
  added: there is no keyboard cursor down the list — the POINTER is the selection, which is why hover
  lifts a row onto the same plate a palette's keyboard selection takes — and the list is two levels
  deep, a collapsible group per tab over its own hit rows, flattened into one column because that is
  what it is (headings over a continuous run, not nested containers) and because a folded group then
  costs exactly the rows it hides. It is also the first FIXED-SIZE card. The palette and the peek card
  are measured by their content; this one may not be, because the query re-runs on every keystroke and
  a panel that grew and shrank with the match count would move under the pointer that is doing the
  selecting.

  What the halves share is `GlobalSearchPresentation` + `GlobalSearchMetrics` + `FindModePill`
  (`SlopDeskClientCore`): the two zero-state lines (a hint before anything is typed, a verdict once
  something was — "no results" under an empty field reports a failure nobody asked for), the summary
  line's gate on the QUERY rather than on the results, the panel's dimensions, and the mode pills as
  VALUES. The pills had to move: "the find bar and the global-search query bar render the pills
  identically" is a locked invariant, and it could not survive one of the two becoming an `NSView`
  while the labels, the help strings and the whole-word underline were spelled at three call sites.

  The piece that matters most is the one that looks like layout and is not. `excerptSlices` cuts a
  hit's excerpt into before / match / after, and the highlight arrives as a UTF-16 range over a Swift
  `String` — a mapping that can FAIL, because a boundary inside a surrogate pair has no
  `String.Index`. The rule is to degrade to a flat excerpt, never to trap and never to guess a run,
  and unlike a copy string it drifts SILENTLY: a half that re-derived it would look right until the
  one line in a scrollback that contains an emoji. So the cut is one function with the emoji cases
  pinned in full, and each framework is left only the INK — SwiftUI's `AttributedString`, AppKit's
  `NSAttributedString`, three strings apiece.

  **The seventh is the ⌘⇧O / ⌘J picker, and it is the LAST card off the floor.** It is the palette's
  shape with three things added — a pill ring between the query and the list, a two-level list under
  the ALL pill (a caps header per non-empty source over its rows, flattened into one column because
  the headers are headings rather than containers), and a searchable ⌘K action sheet on the selected
  row. That last one is where the two frameworks genuinely part, and the reason is mechanical: the
  phone draws it as a `.popover`, and a popover is its own WINDOW whose filter field has to be first
  responder to be typed into — which a popover hung off a `.nonactivatingPanel` does not reliably
  become. The Mac draws the same thing as a plate INSIDE the card, anchored at its row by a
  constraint instead of a beak, in a window that is already key.

  What the halves share is the largest shared piece of the whole stage: `OpenQuicklyPresentation` +
  `OpenQuicklyMetrics` (measurements, the ⇞/⇟ stride, the flattening of sections into draw order and
  with it the selectable index the keyboard counts by, the honest zero state, the ↩ verb, the footer
  hints, the ⌘ chord table) and `OpenQuicklyActions` — the whole VERB TABLE, both the one ↩ runs and
  the one ⌘K opens. The verb table is why the file exists. A copy string drifts loudly; a verb table
  does not. One half quietly grows an action the other has not got, and nothing is red until a user
  notices their phone's picker is different from their Mac's. Only the ⌘ table of the keyboard is
  shared, not the arrows: those arrive as a `KeyPress` on the phone and as a field editor's editing
  command (`moveUp:`, `scrollPageDown:`, `insertNewline:`) on the Mac, and one enum over two event
  shapes that different would be a translation layer pretending to be a decision.

  Riding along: the fzf mark is now cut in ONE place for all four surfaces that draw one — the
  palette and the picker, each drawn twice. `FuzzyMatcher.runs(of:ranges:)` returns alternating
  unmatched/matched runs and each renderer supplies its own ink, which is the same "one value, two
  views" split `Slate.Native` and `AgentReadout` already are.

  A modal card leaving raised a question an ambient one did not: the shared host still presented the
  ones behind it, and it could not present one the Mac had already taken. The answer was a `draws`
  set on `OverlayHostView` — TRANSITIONAL and shrink-only, the Mac's ledger of what stage D had
  lifted — so a card that had moved was drawn by AppKit and one that had not was still drawn there,
  with no `#if` choosing between them and never two live implementations of one card. **The ledger is
  now empty and gone**: the host's whole card machinery is `#if os(iOS)`, and `slopdesk-invariants`
  fails the build if `draws` comes back.

  What did NOT leave, and never will, is the two surfaces that were never cards. Connect-to-Host is a
  native `.sheet` and the pane/tab close confirmation a native `.alert`, on both platforms — a form
  you fill in and commit, and an alert — so `MacWorkspaceRootView` still mounts `OverlayHostView` for
  exactly those two and nothing else. With no card in it the host has no full-bleed body, so the
  hit-claim hazard that shaped the whole file is gone as well as the cards.

  With both ambient tenants in their own windows, `OverlayHostView` is a modal presenter and nothing
  else, and the hazard it was written around is gone with them: the host used to be a ZStack of an
  ambient chain carrying `allowsHitTesting(false)` — which suppresses hits for *everything* composed
  into it, including overlays attached further down, so a modal hung off the same chain took no
  clicks at all — and the modal as its sibling. `slopdesk-invariants` gates the regression directly:
  no `allowsHitTesting` may reappear in that file. (It banned `PaneSwitcherOverlay` by name too, until
  increment 74 showed the ban was the reason the phone veiled its panes and drew nothing.)
  **The eighth is the NAVIGATOR COLUMN — the first COLUMN, and the first surface whose case rests on
  a cost that recurs rather than on a framework's shape.** A card is drawn once and dismissed; the
  sidebar is forty rows under a mouse, each carrying a hover swap, a drop ring, a context menu, an
  inline rename field and a status mark that ticks at display rate. That is precisely where "the body
  is a function of state" costs a whole-list diff per pane heartbeat and AppKit costs one leaf's
  `needsDisplay`. So `MacNavigatorColumn` + `MacSidebarIslandView` + `MacSidebarHeaderView` +
  `MacSidebarRowView` are `NSView`s, `NavigatorColumn` became `#if os(iOS)`, and the shared
  `SlateTabRow` was DELETED rather than kept for either — the Mac's row is `MacSidebarRowView`, the
  phone's is `IOSSidebarLiveRow`, and a third would be the mirror the one-implementation rule bans.

  Everything the two frameworks could disagree about was lifted to `SlopDeskClientCore` FIRST, and it
  is more than any card moved: `SidebarRowReading` — the row's ENTIRE appearance as one value (title
  and its ink rung and its weight rung, the agent marker, the mark, the slot's process label or a
  finished command's receipt, the lock, the sync arming, the rename flag, the ⌘ hint, the tooltip and
  the spoken state) — plus `SidebarGitLine` (the dialect), `SidebarSections` (the By-Project
  grouping and its collapse keys), `SidebarRowMenu` (the verb and switch table) and `SidebarSelection`
  (the click path with its badge auto-clear). What is left in either column is drawing and events.

  Three things the AppKit half owns that nothing below could. **The travelling plate**: selection is
  ONE `CALayer` that moves between the rows of a project island and IGNITES in place when it arrives
  from another — the same rule SwiftUI stated as a per-island `matchedGeometryEffect` namespace, said
  directly. **The bed deal**: a group whose basename hashes onto the island above it is re-dealt, so
  only something holding the whole ordered run can decide it (`Slate.ProjectTint.Deal`), and a
  headerless section deals as KEYLESS — it draws no bed, so it must neither consume an identity nor
  constrain the group under it. **The modal pointer shield**: AppKit tracking areas are rect-based and
  keep firing under a floating card, so the rows lit their hover plates while the pointer was on the
  palette; the column goes hit-test deaf while a modal is up, which is the same occlusion the card's
  dismiss floor already imposes on clicks.

  The GIT DIALECT is the one piece with no SwiftUI twin at all — the phone's grouped list has no git
  line — so only `Slate.Native.gitInk` was added and nothing was drawn twice. The STATUS MARK is the
  opposite: it is drawn by AppKit rows and by SwiftUI's `StatusDotView` for the strip and the band
  rollup, on the `FindModePill` terms — one shared value, one shared geometry, one shared spinner
  phase (`AgentSpinner`, `StatusDot`), two renderers — and the SwiftUI half dies with the strip.

  What moved with the column is its PIXEL VERIFICATION. Four probes in `SlateSnapshotRender` mounted
  the deleted views; they are now `MacChromeSnapshotRender` in `SlopDeskMacUITests`, mounting the
  real `NSView`s through an offscreen borderless window and `CALayer.render(in:)`. Two things the
  AppKit rig gets wrong if copied carelessly, both now spelled in that file's header: the window must
  be pinned `.aqua` (the app pins LIGHT app-wide — `Slate.glassColorScheme` names the terminal
  GLASS's dark opt-out, and following it resolves every dynamic ink near-white on the cream), and the
  bitmap context from `NSGraphicsContext(bitmapImageRep:)` is ALREADY top-left-down, so the usual
  y-flip photographs the sheet upside down. The port paid for itself immediately: the first grouped
  render showed the selection plate hugging the row's title instead of spanning the island, because
  a row is the stack's child rather than the island's and its frame at the island's `layout()` time is
  the previous pass's. Nothing about that was visible in any value.

  **The ninth is the TITLEBAR BAND — the chrome the window has instead of a toolbar.** The window runs
  `.hiddenTitleBar`, so there is no system unified toolbar and this band IS the chrome: the horizontal
  tab strip (`MacTabStrip`) on the leading side, the connection island (`MacConnectionIsland`) on the
  trailing one, and a deliberately empty centre — with the terminal lifted as an island, the band above
  it is that island's top moat. `SlateTitlebar.swift` and `WorkspaceTabStrip.swift` are DELETED.

  The band is a SIBLING of the hosted canvas inside the new `MacContentColumn`, not an overlay on it,
  and that is the whole reason it moved. As a SwiftUI overlay it had to be full-bleed to reach both
  window edges, so it claimed the entire top strip and had to be handed `allowsHitTesting` back a
  layer at a time. An `NSView` refuses a point it does not occupy for free: `hitTest(_:)` returns
  `nil` for the band itself and for its row, and everything else falls through to the terminal.

  The CONNECTION ISLAND crossed in BOTH of its Mac mounts in one change, deliberately. It is one
  component seen on two axes — `stacked` at the navigator's foot while the tabs are vertical,
  `inline` across the band while they are horizontal — and porting one would have left the other's
  identical ink ladder spelled a second time in SwiftUI, which is the duplicate the one-implementation
  rule bans. Everything the island SAYS went down to `SlopDeskClientCore` as `ConnectionReading`: the
  labels, the health thresholds, the LED, the retry rule, and the alarm ladder with the rule about
  which readings may climb at all (the link on its round trip, memory on the kernel's pressure
  verdict, disk on an absolute byte floor; CPU never). What is left in either renderer is the palette
  the rungs resolve to. The phone keeps `ConnectionPill` — the link line alone, bedless, in a
  navigation toolbar — which is the other platform's surface rather than a twin, and reads the same
  values.

  The tab CHIP got no reading of its own. Its inputs are a strict subset of the navigator row's, so
  `MacTabChipView` calls `SidebarRowPresentation.reading(...)` directly — one answer to "what is this
  pane called", and only one of the strip and the column is ever mounted, so the shared call costs
  nothing. What the chip deliberately does NOT take from the row is the urgent HUE: a band control is
  ink and weight only.

  Two AppKit traps, both now spelled where they bit. The band's two halves TRAVEL in from their own
  edges when the column collapses, and an animated `frame` on an Auto-Layout-managed view snaps back
  the moment anything relays out — the travel is a `CATransform3DMakeTranslation` inside a
  `CATransaction`, which composes on top of whatever layout resolved. And the island's live read is
  split from its drawing (`refresh()` resolves a `Reading`, `paintInks()` resolves the `CGColor`s),
  because `updateLayer()` calling back into `apply` recursed forever — the same seam that lets the
  snapshot rig mount a DETACHED island and photograph `.critical` memory pressure without arranging
  for a host to be in it. `MacChromeSnapshotRender` gained both probes; the island's renders BOTH
  layouts side by side, which the SwiftUI probe it replaces could not.

  **The tenth is the RIGHT PANEL'S CHROME — its strip, its rail, and the four tabs both of them
  draw.** `MacPanelStrip` carries the tabs, the showing surface's reload plate and the hide toggle;
  `MacPanelRail` is what the collapsed panel narrows to, one plate wide, carrying the reopen toggle
  and the same four tabs turned a quarter turn. `MacCodePanelColumn` is the column that holds them.
  `PanelRail.swift`, `PanelTabPlate` and `AndroidRobotMark.swift` are DELETED.

  The SURFACES did NOT cross, and that is a scope line rather than an exception. Three of the four
  are already AppKit under a thin SwiftUI wrapper — a `WKWebView` for the workbench, an
  `AVSampleBufferDisplayLayer` for each device stage — so a port would remove the wrapper, not a
  framework choice; and the phone will want the same four surfaces on its own layout, which is what
  makes them surfaces rather than chrome (§3.5: a surface crosses whole). `CodeSidebarColumn` was
  renamed to `CodePanelSurfaces` to say exactly that, and the three panel models moved UP to the
  column controller: the strip's reload plate now stands outside the SwiftUI tree, so the thing it
  reloads has to outlive the view that draws it. That also states plainly what the `park()`/`resume()`
  rules already relied on.

  The four TABS went down to `SlopDeskClientCore` as `PanelTabs` — mark, word and help each — because
  they were written twice, once across the strip and once down the rail, and the two lists had to
  agree. Its WIDTH LADDER went with them, and stopped being a `ViewThatFits`: SwiftUI could only ask
  "which rung fits" by building all three candidates, which cost a NAMESPACE PER RUNG (every
  candidate is built, so one namespace would put three copies of the travelling plate's geometry on
  screen at once). Said as arithmetic — `PanelTabs.labelling(available:cell:gap:named:selected:)` —
  it is one answer, both frameworks can ask it, and `PanelTabsTests` pins the rung BOUNDARIES without
  mounting anything. The Android head went down the same way, as `AndroidMarkPath`.

  Three AppKit traps, all measured here. `frameCenterRotation` does NOT turn a layer-backed view
  about its frame's centre — it pivots on the layer's anchor point, which is the frame's corner — and
  a quarter turn threw every rail tab a whole tab-length out of the rail; the tab now stands in its
  own footprint and turns its CONTENT, which is also what keeps its hit area from lying across both
  neighbours. A mark's counter-turn cannot be a layer transform either: every layout pass re-syncs
  the layer's geometry from the solved frame and resets `transform`, so each mark bakes its turn into
  `draw(_:)`. And a hand-framed subview must be taken OUT of the engine
  (`translatesAutoresizingMaskIntoConstraints = false`, no constraints of its own), or Auto Layout
  re-imposes the `width == 0` autoresizing constraint it minted when the view was still `.zero` — the
  Android mark carried that pair for its whole life and photographed as nothing at all.

  **The eleventh is not a port at all — it is the DEVICE-PANEL FLOOR becoming the phone's too.** Every
  one of the forty-one files in `SlopDeskDevicePanels` was wrapped whole in `#if os(macOS)`. None of
  them needed to be: the module imports Foundation, CoreGraphics, CoreMedia and Network, and the phone
  has all four. The gates were inherited from the days the panels were a Mac-only surface, and they
  were invisible because a build of forty-one EMPTY files is a green build — `just check-ios` was
  compiling nothing and reporting success. Removing them is the whole change; the module built for the
  iOS triple on the first try, which is the measurement that says the gap was never technical.

  One file had a real dependency, and its fix is the pattern for anything else in that position.
  `SimulatorKeyMap` imported `Carbon.HIToolbox` for its `kVK_` constants, and `Carbon` does not exist
  on iOS. Its own sibling already had the answer: `AndroidKeyMap.functionalKeys` spells the same
  virtual key codes as literals. So `SimulatorKeyMap` does now too, and the constants it gave up are
  PINNED by `SimulatorKeyMapTests` — a `#if canImport(Carbon)` suite that asserts every row against
  the SDK's own value. The table stays one implementation, buildable everywhere, and a typo in it
  fails a build rather than swallowing an arrow key on a device someone is typing into.

  **The twelfth crosses two of the four SURFACES: Simulators and Emulators.** Both are the phone's
  now. Fifteen of their seventeen files turned out to need nothing but the gate removed — a device
  list, a console, a header, a bezel and two stages are plain SwiftUI, and they were Mac-only for the
  same inherited reason the floor was. The two that hold a video stage carry both halves in one file
  (`#if os(macOS)` … `#elseif os(iOS)`), which is the shape `VideoWindowView` already used.

  THE PHONE'S INPUT HALF IS SHORTER, not a port of the Mac's. A finger on the mirror IS the finger,
  so the three machines the Mac needs to SYNTHESIZE one — `SimulatorScrollGesture`/`AndroidScrollGesture`,
  the classic wheel's idle timer, and the magnify-gesture-to-two-contacts translation — have nothing
  to do on iOS and are absent rather than reimplemented. What survives is everything that is about the
  DEVICE rather than about the pointer: the clamped drag (a drag that leaves the frame is still a
  drag), the edge bands, the pinch's rate limit (25 ms of server time a `touch2-move` on the simulator
  side, one pair per display refresh on the Android side), and Android's pointer-index discipline —
  the second finger takes `POINTER_DOWN`/`POINTER_UP` while the first takes plain `DOWN`/`UP`. A
  CANCELLED touch is LIFTED rather than forgotten, which the Mac never had to think about: iOS takes
  touches away for its own gestures, and a forgotten one strands a finger on the device.

  Three small seams came out of it, each cut once. `Image.decoded(_:)` is the client's only mention of
  `NSImage` or `UIImage` — the bezel artwork and the running card's screenshot both decode through it,
  and the decoded value is a SwiftUI `Image`, so no consumer is platform-shaped. `SlateSearchField`
  gained a real second implementation, and that one IS justified: the AppKit original exists to dodge
  a macOS-only 11pt rendering split between the field cell and the window's shared field editor, and
  UIKit has neither, so the phone's half is the plain SwiftUI field the Mac cannot use. And the key
  maps became TWO NUMBERINGS OVER ONE VOCABULARY: a Mac reports a virtual key code, an iPad a USB HID
  usage, so `SimulatorKeyMap.FunctionalKey` and `AndroidKeyMap.resolve(functional:…)` hold the names
  and the rule while each platform supplies only its own table. `SimulatorKeyMapTests` and
  `AndroidKeycodeTests` assert the two tables cover the same SET, which is the thing that could drift.

  The CODE surface did not cross with them, and that is a size call rather than a design one:
  `CodeSidebarWebView.swift` is a thousand lines of which the larger half is a first-responder duel
  that has no iOS analogue at all (the click-to-focus rule, the reserved-chord refusal, the per-tab
  focus region, the orphan repair). The pool, the dressing and the mount underneath it are already
  platform-neutral. Splitting those apart is the next increment, and it is what unblocks the phone's
  own layout for all four surfaces.

  **Increment 13 — the code surface crosses, and only its keyboard stays behind.** The thousand-line
  file is three files now, and the cut is the one the previous increment predicted. `CodeSidebarFocusPolicy`
  holds the DECISIONS — click-to-focus, the reserved-chord refusal, the per-tab focus region, the
  eviction victim — and is pure, so it was already testable and is now also platform-neutral, with only
  the three rules that take an `NSEvent` left under a `#if canImport(AppKit)` at its foot.
  `CodeSidebarWebViewPool` holds the PROJECTS and their warm pages: the mint, the five user scripts,
  the LRU and its cap, the veil state and the reload are one law for both platforms, and the Mac's
  keyboard machine — the key-window observers, the focus memory, the claim/resign seam, the ⌥⌘R toggle
  and the orphan repair — is walled off at the bottom of the class behind the only `#if` that survives.
  `CodeSidebarWebView` holds the MOUNT: a clipping container and a representable per platform, and the
  `CodeSidebarWKWebView` subclass under a macOS gate, because that subclass IS the responder seam. The
  phone mints a plain `WKWebView`, and slopdesk-invariants keeps the subclass's name out of every file but
  those two.

  A REMOUNT IS TWO THINGS AND THEY CAME APART HERE. It is a USE — what keeps a project ahead of the
  ones the user stopped visiting in the eviction queue — and on the Mac it may also owe the keyboard
  back. The old `noteRemount` did both in one body, which is precisely why the pool could not cross;
  the new one touches the recency list on both platforms and calls `restoreKeyboardOnRemount` only
  where a keyboard can be owed.

  Two files under it turned out to be gated for no reason whatsoever. `CodeSidebarProxy` is Foundation
  and Network, and both reasons it exists — loopback is a secure context, and a fixed FNV-1a port keeps
  the workbench's per-origin storage across respawns — are the phone's problems too.
  `CodeSidebarFontSchemeHandler` is a `WKURLSchemeHandler`, and WebKit is WebKit. Neither gate was ever
  a dependency; both were inherited from the days the surface above them was Mac-only, and that is the
  same accident increment 11 found forty-one times in `SlopDeskDevicePanels`.

  What genuinely differs is four lines, and each is a SPELLING rather than a decision. The theme
  backdrop is `SlateNativeColor` on both. The chrome polarity is `NSAppearance(named: .aqua)` against
  `overrideUserInterfaceStyle = .light`. WebKit's white base canvas is killed by the long-standing KVC
  `drawsBackground` key on the Mac and honestly, through the view's own opacity, on the phone. And the
  clipping container overrides `hitTest` on the Mac only — the overhang would otherwise sit under the
  panel's AppKit strip and eat its clicks, whereas `clipsToBounds` already stops UIKit delivering
  touches outside the container. With that, all four panel surfaces draw on both platforms, and the
  phone's own layout is the next increment.

  **Increment 14 — the phone's panel is a layout, and nothing else.** The four surfaces existed on iOS
  after increment 13 and were unreachable: there is no third split column on a phone, no ⌥⌘B, and no
  rail to click. `PhonePanelSheet` is the layout that reaches them — a FULL-SCREEN COVER over the
  workspace, because a workbench or a device mirror is a place you go to rather than a column you
  glance at, with its own bar carrying the four tabs, the showing surface's reload and a close plate.
  Under the bar it mounts `CodePanelSurfaces`, unchanged, with the same three models the Mac's column
  owns and for the same reason: a panel dismissed and re-opened must not re-list every device and
  re-boot every stream, so `PhonePanelModels` lives on the root view, which lives as long as the app.

  THE PRESENTATION IS THE SHARED FLAG, and that is the part worth copying next time. The cover is bound
  to `chrome.codeSidebarCollapsed` inverted — a panel that is not collapsed is a panel that is up —
  rather than to a `@State` of its own. Three things fall out for free: a phone and a Mac driving one
  session agree about whether the panel is open and which surface it shows; `revealCodeSidebar()`, the
  open-this-file-in-the-workbench actuation, reaches the phone without a line of new wiring; and the
  workstyle choice persists on both, because every dismissal routes through the new
  `collapseCodeSidebar()` — the mirror of the reveal that already existed.

  The bar is the phone's own and the tabs are not. `PanelTabs.all` is the same four readings the Mac's
  strip and rail draw, and the WIDTH LADDER is the same arithmetic, asked with this renderer's own
  measurement (`UIFont` — the ladder is arithmetic precisely so nobody has to build three candidate
  rows to compare them). The android head is `AndroidMarkPath`, stroked and filled in a SwiftUI
  `Canvas` instead of a `CGContext`, so the two platforms draw one robot. What the phone's bar does NOT
  carry is a hide toggle: a cover that is not presented is already hidden, so the Mac's hide-inside /
  reopen-outside split collapses into one close plate here. That is the whole of the difference.

  Mounting the panel turned up a class of gap worth naming, because it dies quietly: A COORDINATOR HOOK
  BOUND ON ONE PLATFORM IS A DEAD ROW ON THE OTHER. Every actuator on `OverlayCoordinator` defaults to
  an empty closure, and only the Mac's root ever bound `toggleSidebar`, `toggleCodeSidebar` and
  `focusCodePanel` — so the phone's command palette listed three View actions that ran and did nothing,
  which is indistinguishable from an action that ran and had nothing to do. The same held for the
  Settings row (`openSettingsAction`, bound on the Mac to the `Settings` scene) and for the hardware
  chords: ⌘⇧L and ⌘⇧R reach the focused terminal surface first on iOS, so both died at a `nil` toggle
  in `WorkspaceOverlayKeyToggles`, which carried overlays only. All of it is bound now, slopdesk-invariants
  pairs the three hooks across the two roots, and `togglePinWindow` stays deliberately absent — a phone
  has one window and no window level. An action that is ABSENT on a platform is fine; an action that is
  listed and inert is not.

  The cover carries a second `ToastStackView` for the same reason: the surfaces under it SPEAK, and the
  workspace's stack is mounted on the root the cover sits on top of, so every report the panel made
  while it was up would have been filed behind the thing that filed it. The palette deliberately does
  not follow — a phone shows one place at a time, and the panel's own bar is its command surface.
- **E — the Rust port (§4).**

## 4. What moves to Rust

The split makes a second question answerable: with the view layer split by platform, everything left
that is neither AppKit nor SwiftUI is pure logic, and this repo's standing rule is that pure logic is
Rust (`CLAUDE.md`: "Rust is the default; perf parity is enough to move existing Swift. Only
SwiftUI/AppKit justifies staying in Swift"). The port list and its order live in §5 of this doc as
each stage lands.


The ledger itself is one file per increment range — each is a self-contained read, and no
increment is split across two:

**[Increments 15–33 — Settings, and the Mac's first AppKit windows](client-ui-split/inc-15-33.md)**

- [Increment 15 — the phone's key path](client-ui-split/inc-15-33.md#increment-15-the-phones-key-path)
- [Increment 16 — the responder, and the identity the rules were keyed by](client-ui-split/inc-15-33.md#increment-16-the-responder-and-the-identity-the-rules-were-keyed-by)
- [Increment 17 — what Settings offers, once](client-ui-split/inc-15-33.md#increment-17-what-settings-offers-once)
- [Increment 18 — a setting is named once](client-ui-split/inc-15-33.md#increment-18-a-setting-is-named-once)
- [Increment 19 — a platform gate is data](client-ui-split/inc-15-33.md#increment-19-a-platform-gate-is-data)
- [Increment 20 — the Shell, Controls and Appearance pages](client-ui-split/inc-15-33.md#increment-20-the-shell-controls-and-appearance-pages)
- [Increment 21 — the Agents and Advanced pages](client-ui-split/inc-15-33.md#increment-21-the-agents-and-advanced-pages)
- [Increment 22 — the last two pages, and where a timing chip belongs](client-ui-split/inc-15-33.md#increment-22-the-last-two-pages-and-where-a-timing-chip-belongs)
- [Increment 23 — the font surface stops being one bespoke block](client-ui-split/inc-15-33.md#increment-23-the-font-surface-stops-being-one-bespoke-block)
- [Increment 24 — the Mac's Settings window is AppKit](client-ui-split/inc-15-33.md#increment-24-the-macs-settings-window-is-appkit)
- [Increment 25 — the first-launch checklist, and a card that was written twice](client-ui-split/inc-15-33.md#increment-25-the-first-launch-checklist-and-a-card-that-was-written-twice)
- [Increment 26 — the two surfaces that were never cards](client-ui-split/inc-15-33.md#increment-26-the-two-surfaces-that-were-never-cards)
- [Increment 27 — one chord editor, drawn twice, and only one half records](client-ui-split/inc-15-33.md#increment-27-one-chord-editor-drawn-twice-and-only-one-half-records)
- [Increment 28 — the design floor stops riding the draining target](client-ui-split/inc-15-33.md#increment-28-the-design-floor-stops-riding-the-draining-target)
- [Increment 29 — the caret section was never AppKit](client-ui-split/inc-15-33.md#increment-29-the-caret-section-was-never-appkit)
- [Increment 30 — the phone records a chord, and a section stops being macOS-only](client-ui-split/inc-15-33.md#increment-30-the-phone-records-a-chord-and-a-section-stops-being-macos-only)
- [Increment 31 — the video flags stop being a surface](client-ui-split/inc-15-33.md#increment-31-the-video-flags-stop-being-a-surface)
- [Increment 32 — the menu bar goes home, and the port's leftovers go](client-ui-split/inc-15-33.md#increment-32-the-menu-bar-goes-home-and-the-ports-leftovers-go)
- [Increment 33 — the paste confirmation's words move to Rust, its alert moves to AppKit](client-ui-split/inc-15-33.md#increment-33-the-paste-confirmations-words-move-to-rust-its-alert-moves-to-appkit)

**[Increments 34–49 — the platform gates become data](client-ui-split/inc-34-49.md)**

- [Increment 34 — a file called SettingsView that had not held a SettingsView since increment 24](client-ui-split/inc-34-49.md#increment-34-a-file-called-settingsview-that-had-not-held-a-settingsview-since-increment-24)
- [Increment 35 — the phone gets the file drop it was never actually barred from](client-ui-split/inc-34-49.md#increment-35-the-phone-gets-the-file-drop-it-was-never-actually-barred-from)
- [Increment 36 — a whole-file `#if os(macOS)`, taken at its word](client-ui-split/inc-34-49.md#increment-36-a-whole-file-if-osmacos-taken-at-its-word)
- [Increment 37 — the cancel key, spelled once](client-ui-split/inc-34-49.md#increment-37-the-cancel-key-spelled-once)
- [Increment 38 — a palette verb declares its platform, in Rust](client-ui-split/inc-34-49.md#increment-38-a-palette-verb-declares-its-platform-in-rust)
- [Increment 39 — the other half of it: a keybinding names its platform too](client-ui-split/inc-34-49.md#increment-39-the-other-half-of-it-a-keybinding-names-its-platform-too)
- [Increment 40 — one CGEventTap gate instead of seven, and the pane's last gate is data](client-ui-split/inc-34-49.md#increment-40-one-cgeventtap-gate-instead-of-seven-and-the-panes-last-gate-is-data)
- [Increment 41 — the drag block: fourteen spellings of two facts](client-ui-split/inc-34-49.md#increment-41-the-drag-block-fourteen-spellings-of-two-facts)
- [Increment 42 — the code sidebar's keyboard duel goes up where it belongs](client-ui-split/inc-34-49.md#increment-42-the-code-sidebars-keyboard-duel-goes-up-where-it-belongs)
- [Increment 43 — the pool takes the last two gates off, and neither was a choice](client-ui-split/inc-34-49.md#increment-43-the-pool-takes-the-last-two-gates-off-and-neither-was-a-choice)
- [Increment 44 — the iPad gets its escape-to-cancel, which increment 41 recorded as owed](client-ui-split/inc-34-49.md#increment-44-the-ipad-gets-its-escape-to-cancel-which-increment-41-recorded-as-owed)
- [Increment 45 — the pool goes down, and takes the page with it](client-ui-split/inc-34-49.md#increment-45-the-pool-goes-down-and-takes-the-page-with-it)
- [Increment 45b — a second git-line renderer, kept alive by its own tests](client-ui-split/inc-34-49.md#increment-45b-a-second-git-line-renderer-kept-alive-by-its-own-tests)
- [Increment 46 — the band's marks cross, and the Mac stops drawing anything in SwiftUI](client-ui-split/inc-34-49.md#increment-46-the-bands-marks-cross-and-the-mac-stops-drawing-anything-in-swiftui)
- [Increment 47 — the checklist's two shared steps cross, and the words go down instead](client-ui-split/inc-34-49.md#increment-47-the-checklists-two-shared-steps-cross-and-the-words-go-down-instead)
- [Increment 48 — the git dialect goes to Rust, and only the writing stays](client-ui-split/inc-34-49.md#increment-48-the-git-dialect-goes-to-rust-and-only-the-writing-stays)
- [Increment 49 — the bespoke settings surfaces, and four labels that had already drifted](client-ui-split/inc-34-49.md#increment-49-the-bespoke-settings-surfaces-and-four-labels-that-had-already-drifted)

**[Increments 50–57d — the shared surfaces cross, and wave P](client-ui-split/inc-50-57.md)**

- [Increment 50 — the pointer tables, and the mirror that was a third copy](client-ui-split/inc-50-57.md#increment-50-the-pointer-tables-and-the-mirror-that-was-a-third-copy)
- [Increment 51 — the panel's four surfaces, and a ledger row that was counting one file](client-ui-split/inc-50-57.md#increment-51-the-panels-four-surfaces-and-a-ledger-row-that-was-counting-one-file)
- [Increment 52 — the device panels cross, and one seam closes instead of narrowing](client-ui-split/inc-50-57.md#increment-52-the-device-panels-cross-and-one-seam-closes-instead-of-narrowing)
- [Increment 53 — the eleven shells merge, and the follow-up 52 deferred is paid](client-ui-split/inc-50-57.md#increment-53-the-eleven-shells-merge-and-the-follow-up-52-deferred-is-paid)
- [Increment 54 — kind 2 was not finished, and the canvas was where it hid](client-ui-split/inc-50-57.md#increment-54-kind-2-was-not-finished-and-the-canvas-was-where-it-hid)
- [Increment 55 — one engraved caps heading, six copies](client-ui-split/inc-50-57.md#increment-55-one-engraved-caps-heading-six-copies)
- [Increment 56a — an import that had been dead for three increments](client-ui-split/inc-50-57.md#increment-56a-an-import-that-had-been-dead-for-three-increments)
- [Increment 56b — the window's sidebar toggle, and the second import falls](client-ui-split/inc-50-57.md#increment-56b-the-windows-sidebar-toggle-and-the-second-import-falls)
- [Increment 56c — the canvas's last kind 2, before a line of AppKit is written](client-ui-split/inc-50-57.md#increment-56c-the-canvass-last-kind-2-before-a-line-of-appkit-is-written)
- [Increment 56d — `staticMirror`, a dead branch deleted before it could be ported](client-ui-split/inc-50-57.md#increment-56d-staticmirror-a-dead-branch-deleted-before-it-could-be-ported)
- [Increment 56e — the cursor-following chip, and a table that had to move to survive](client-ui-split/inc-50-57.md#increment-56e-the-cursor-following-chip-and-a-table-that-had-to-move-to-survive)
- [Increment 56f — five environment injections nobody reads](client-ui-split/inc-50-57.md#increment-56f-five-environment-injections-nobody-reads)
- [Increment 57a — an injection in the wrong file, and the third import](client-ui-split/inc-50-57.md#increment-57a-an-injection-in-the-wrong-file-and-the-third-import)
- [Increment 57b — `enabled:`, and two ratchets 56c was owed](client-ui-split/inc-50-57.md#increment-57b-enabled-and-two-ratchets-56c-was-owed)
- [Increment 57c — wave P's first three, and an amendment 56c owes itself](client-ui-split/inc-50-57.md#increment-57c-wave-ps-first-three-and-an-amendment-56c-owes-itself)
- [Increment 57d — wave P's last three, and the kind-3 row that was never geometry](client-ui-split/inc-50-57.md#increment-57d-wave-ps-last-three-and-the-kind-3-row-that-was-never-geometry)

**[Increments 58–72 — wave R, the fold, and what the phone could not do](client-ui-split/inc-58-72.md)**

- [Increment 58 — wave R's first eight, and three things the fan-out found that no batch owned](client-ui-split/inc-58-72.md#increment-58-wave-rs-first-eight-and-three-things-the-fan-out-found-that-no-batch-owned)
- [Increment 59 — the lint's own hang, and why the fold was scheduled to trigger it](client-ui-split/inc-58-72.md#increment-59-the-lints-own-hang-and-why-the-fold-was-scheduled-to-trigger-it)
- [Increment 60 — the terminal leaf, and risk 3 was never about visibility](client-ui-split/inc-58-72.md#increment-60-the-terminal-leaf-and-risk-3-was-never-about-visibility)
- [Increment 61 — the GUI leaf, the canvas, and the last hosted view](client-ui-split/inc-58-72.md#increment-61-the-gui-leaf-the-canvas-and-the-last-hosted-view)
- [Increment 62 — F3, and a debt ledger that named its symbols and went stale](client-ui-split/inc-58-72.md#increment-62-f3-and-a-debt-ledger-that-named-its-symbols-and-went-stale)
- [Increment 63 — the fold lands, and five gates that agreed for the wrong reason](client-ui-split/inc-58-72.md#increment-63-the-fold-lands-and-five-gates-that-agreed-for-the-wrong-reason)
- [Increment 64 — the palette listed 33 of 77, and only a phone could tell](client-ui-split/inc-58-72.md#increment-64-the-palette-listed-33-of-77-and-only-a-phone-could-tell)
- [Increment 65 — three clipboard questions the phone answered on the user's behalf](client-ui-split/inc-58-72.md#increment-65-three-clipboard-questions-the-phone-answered-on-the-users-behalf)
- [Increment 66 — ⌃⌘O flipped a `Bool` nobody drew](client-ui-split/inc-58-72.md#increment-66-o-flipped-a-bool-nobody-drew)
- [Increment 67 — the rename walked through forty thousand lines of comment](client-ui-split/inc-58-72.md#increment-67-the-rename-walked-through-forty-thousand-lines-of-comment)
- [Increment 68 — the phone had one notification surface because a `#if` said so](client-ui-split/inc-58-72.md#increment-68-the-phone-had-one-notification-surface-because-a-if-said-so)
- [Increment 69 — the numbers both languages knew, and the gate that could not see them](client-ui-split/inc-58-72.md#increment-69-the-numbers-both-languages-knew-and-the-gate-that-could-not-see-them)
- [Increment 70 — the phone drew a VI pill over a dispatch with no caller](client-ui-split/inc-58-72.md#increment-70-the-phone-drew-a-vi-pill-over-a-dispatch-with-no-caller)
- [Increment 71 — the settings index advertised every key on both halves](client-ui-split/inc-58-72.md#increment-71-the-settings-index-advertised-every-key-on-both-halves)
- [Increment 72 — the phone could read the terminal and take nothing out of it](client-ui-split/inc-58-72.md#increment-72-the-phone-could-read-the-terminal-and-take-nothing-out-of-it)

**[Increments 73–87 — the last one-sided surfaces, and the host's own Swift](client-ui-split/inc-73-87.md)**

- [Increment 73 — three hooks the overlays stopped listening to, and nobody said so](client-ui-split/inc-73-87.md#increment-73-three-hooks-the-overlays-stopped-listening-to-and-nobody-said-so)
- [Increment 74 — the phone veiled every pane and drew nothing over them](client-ui-split/inc-73-87.md#increment-74-the-phone-veiled-every-pane-and-drew-nothing-over-them)
- [Increment 75 — the clipboard ring the phone could see but never fill](client-ui-split/inc-73-87.md#increment-75-the-clipboard-ring-the-phone-could-see-but-never-fill)
- [Increment 76 — the one double implementation that stays, pinned instead of deleted](client-ui-split/inc-73-87.md#increment-76-the-one-double-implementation-that-stays-pinned-instead-of-deleted)
- [Increment 77 — every divider you dragged was renamed on the next launch](client-ui-split/inc-73-87.md#increment-77-every-divider-you-dragged-was-renamed-on-the-next-launch)
- [Increment 78 — the footer asked the clipboard a question it could only answer with an alert](client-ui-split/inc-73-87.md#increment-78-the-footer-asked-the-clipboard-a-question-it-could-only-answer-with-an-alert)
- [Increment 79 — the phone could see a path in the terminal and had nothing to do with it](client-ui-split/inc-73-87.md#increment-79-the-phone-could-see-a-path-in-the-terminal-and-had-nothing-to-do-with-it)
- [Increment 80 — the phone streamed the swipe and drew none of the feedback](client-ui-split/inc-73-87.md#increment-80-the-phone-streamed-the-swipe-and-drew-none-of-the-feedback)
- [Increment 81 — an iPad had a trackpad the whole time and the pane could not see it](client-ui-split/inc-73-87.md#increment-81-an-ipad-had-a-trackpad-the-whole-time-and-the-pane-could-not-see-it)
- [Increment 82 — two frameworks, each with its own reading of "pure rect math"](client-ui-split/inc-73-87.md#increment-82-two-frameworks-each-with-its-own-reading-of-pure-rect-math)
- [Increment 87 — Settings is a file, so increments 17–24 are history](client-ui-split/inc-73-87.md#increment-87-settings-is-a-file-so-increments-1724-are-history)
- [Increment 86 — the capture region stops being CoreGraphics algebra written in Swift](client-ui-split/inc-73-87.md#increment-86-the-capture-region-stops-being-coregraphics-algebra-written-in-swift)
- [Increment 85 — the host stops decoding window records, and the WindowServer's read side becomes two crates](client-ui-split/inc-73-87.md#increment-85-the-host-stops-decoding-window-records-and-the-windowservers-read-side-becomes-two-crates)
- [Increment 84 — the host stops synthesising events, and the unsafe gate opens for exactly one reason](client-ui-split/inc-73-87.md#increment-84-the-host-stops-synthesising-events-and-the-unsafe-gate-opens-for-exactly-one-reason)
- [Increment 83 — the link island, and the difference between one copy and one home](client-ui-split/inc-73-87.md#increment-83-the-link-island-and-the-difference-between-one-copy-and-one-home)

## Stage D ledger — what the rename actually costs

`SlopDeskClientUI` cannot fold into `SlopDeskPhoneUI` while `SlopDeskMacUI` still imports it. That is
the whole test, and it is countable — but see the boxed warning under kind 1 before reading any number
on this page as a quantity of work, and step 5 before reading "fold" as a rename. The count is a
gate condition, not a burndown. It was **13 files** when this ledger was written; it is **0** after
increments 45, 46, 47, 49, 52, 54, the 56/57 waves and wave R, and each one named what it took in the
comment on the import line. The last two were `MacContentColumn` and `SatellitePaneWindows` — both a
mount of the pane canvas or of a column that hosts it, which is to say the fold blocked on exactly one
thing, and R11/R12 closed both halves of it (increment 61). **The gate condition is met, and the edge is cut in the
manifest rather than only in the imports: `SlopDeskMacUI` no longer *depends on* `SlopDeskClientUI`
at all.** That distinction is the whole difference between a convention and a fact — a dependency the
graph still contains is an import one keystroke away and a build that will not complain. Both halves
are ratcheted, because they fail at different moments. What remains is the fold itself — F2 through F5
below — which is a rename plus the platform directives, not a port.

Wave 56 took two of them (`SlopDeskSplitViewController`, `MacWorkspaceRootView`) and **neither cost an
AppKit rewrite of anything the canvas depends on**: one was a stale import, one was a 47-line button no
other caller had. That is the pattern increments 51 and 54 established from opposite directions — the
count can stand still while real work lands, and it can fall while nothing hard happens. Read it as
progress on the RENAME, never as progress on the port.

`SlopDeskMacApp`'s import was held by **one call** — `.overlayCoordinator(…)` on the satellite root,
which `PaneContainer` genuinely reads — after 56f removed the other five injections as dead. Increment
57a took that one too, by moving the injection into the target that declares the key. So both surviving
edges are now the same edge, the pane canvas, reached two ways: hosted in the content column and hosted
in a satellite window. **There is no cheap one left; 58 onward is the canvas or nothing.** Every
increment from 56a to 57b was a stale import, a dead branch, a button, or an injection in the wrong
file — five edges' worth of debt that had accumulated *behind* the expensive row and cost no AppKit at
all to clear.

Increment 51 did not move the count — it moved one import, from `MacCodePanelColumn` to
`MacCodePanelSurfaces`, and NARROWED what it names from a whole column to two device surfaces. A
count that only falls would have called that increment worthless; increment 52 then closed the seam
it had narrowed, and the narrowing is what made the remaining debt nameable in the first place.
Grouped, they are three kinds of debt, not one — and only the first kind needs an AppKit rewrite.

### The ruling first

There is **no shared SwiftUI-view target below the two halves, and there must not be one.**
`SlopDeskSlate` imports SwiftUI in four files but declares zero `View` types — it is tokens and
modifiers. `SlopDeskClientCore` imports SwiftUI nowhere at all. That is not an omission to fix by
adding a `SlopDeskSurfaces` target: the mandate is two separate implementations, and the ratchets
already encode the alternative — *"one cheat sheet, drawn twice and spelled once"*, *"one palette,
drawn twice and spelled once"*, *"one design floor, two renderers, and the floor never draws"*. The
DECISION is shared and lives below; the DRAWING is per-half and never is. A surface currently "drawn
once" for both halves is therefore not a category needing a home — it is unfinished Stage D.

### Kind 1 — hosted SwiftUI that must be rewritten in AppKit

The expensive kind, and the only one that is.

| What | Lines | Taken by |
| --- | --- | --- |
| the pane canvas (`Pane/`, 23 files) | 5492 | `MacContentColumn`, `SatellitePaneWindows` |
| ~~the device panels (`Simulator/` 9 files, `Android/` 6)~~ | ~~4154~~ | ✅ increment 52 — two AppKit surfaces, two `NSView`s descended |
| ~~`CodePanelSurfaces`~~ | ~~632~~ | ✅ increment 51 — four AppKit surfaces, one vocabulary below |
| ~~`SettingsBespokeSurface`~~ | ~~325~~ | ✅ increment 49 — five AppKit surfaces, four faces below |
| ~~`FirstLaunchStepSurface`~~ | ~~286~~ | ✅ increment 47 — the sheet draws both shared steps itself |
| ~~`StatusDotView`~~ | ~~225~~ | ✅ increment 46 — `RailStatusRollup` draws `MacStatusMarkView`s |
| `SatellitePaneHost` | 13 | `SatellitePaneWindows` |
| `WorkspaceColumnHosts` (the factory seam) | 62 | `MacContentColumn` |

> **⚠️ READ THE STRIKETHROUGHS CORRECTLY — they do not mean what this section's title implies, and
> that is the single most misleading thing on this page.**
>
> **Not one struck row was deleted.** `Simulator/` is 1,986 lines today, `Android/` 1,358,
> `CodeSidebar/` 631, `Settings/` 4,231, `FirstLaunch/` 298, and `StatusDotView.swift` is still in
> `DesignSystem/`. Every one of them is alive in `SlopDeskClientUI` right now. What each increment
> actually did was give the **Mac** an AppKit renderer so the Mac stopped importing the SwiftUI one.
> The SwiftUI one stayed, because the phone still draws it — which was always the plan, and is exactly
> the mandate: *two separate implementations, the decision shared below, the drawing never.*
>
> So a strikethrough means **"this no longer holds a `SlopDeskMacUI` import edge"**, not "this is
> gone", and the `Lines` column is the size of the AppKit rewrite that was PAID, not of a debt that
> was retired. The rename's cost is untouched by all six rows.
>
> The heading "what the rename actually costs" is therefore answered by neither column. The rename
> moves **every** file in the target — 101 files, 21,085 lines as of increment 57 — and it moves them
> whether or not the Mac ever imported them. `Pane/`'s 5,492 lines are 26% of it. The other 74% has no
> row in this table at all, has never had one, and needs no work: it is already phone-only in effect
> and simply travels.
>
> Both readings are useful; they are answers to different questions. **Which import edges remain?** —
> the table, and the answer is the canvas. **What does the fold move?** — the whole target, and the
> table is silent. Increment 54's lesson was that an import count measures the rename and not kind 2.
> This is its twin: a struck row measures the Mac's independence and not the phone's inventory.

The canvas is the whole of what is left *of the import edges*. The device panels were the second bulk
— a row this table did not have until increment 51, because `CodePanelSurfaces`' 632 lines had been
counted as the whole debt when the four surfaces they draw host ~4,100 lines more — and they crossed in
increment 52. `StatusDotView` was the cheapest and went first, then the first-launch checklist, then
the bespoke settings pages, then the panel's own body, then the device panels. `SatellitePaneHost` and
`WorkspaceColumnHosts` are both held by the canvas — the first hosts it in a satellite window, the
second is the factory seam that mounts it — so nothing here is independently schedulable any more.

Two of this table's numbers were also simply wrong, and both were wrong in the direction that flatters
the ledger. `SatellitePaneHost` was carried at 170 lines; it is a `package enum` with one static
factory at `SatellitePaneContent.swift:152`, and it is **13**. The 170 was the whole file, most of which
is the `NSWindow` subclass's content view and its comments. `WorkspaceColumnHosts` was carried at 79 and
is **62**. Neither error changes a decision — both were already "held by the canvas" — but a ledger
whose cheap rows are inflated is a ledger that makes the expensive row look proportionally smaller than
it is.

### Kind 2 — not views at all, and in a UI target by accident — ✅ DONE (increments 45 and 54)

`CodeSidebarWebViewPool` (410 lines) manages warm `WKWebView`s keyed by project. It is a RESOURCE
manager: no `View` type, no layout, no design token. It went down to `SlopDeskClientCore` in
increment 45, with `CodeSidebarFocusPolicy` and the page mint, and **no AppKit rewrite at all**.

It removed **two** of the thirteen imports rather than the three estimated here: of the three MacUI
files that reach the pool, only `WorkspaceKeyDispatcher` and `MacCodeSidebarKeyboard` reached it
alone. `MacCodePanelColumn` also takes `CodePanelSurfaces`, `SlopDeskMacApp` also takes the SwiftUI
mounts, and both are kind 1.

**This was NOT the whole of kind 2, and the claim that it was survived nine increments.** Eleven
imports remained after 45 — ten after 46, nine after 47 — and the sentence that used to stand here
concluded "from here on Stage D is AppKit rewrites and the canvas".

Increment 54 disproved it with ~2,900 lines. The error was in the TEST, not the sweep: kind 2 was being
counted by import edges, and the canvas is ONE edge no matter how much non-view logic is inside it. So
"kind 2 is finished" only ever meant "no remaining *file* both is non-view and is the sole reason for
an import" — which is a much smaller claim than the words. §3's own test is per-DECLARATION: a `some
View` is a view, and nothing else in a UI target is.

The rule that falls out, and it is why this section now names two increments: **an import count is a
measure of the RENAME's progress, never of kind 2's.** Increment 51 already showed the count can stand
still while real work lands; 54 shows the reverse — the count can be right while the category behind it
is wrong.

### Kind 3 — blocked on a geometry fact, not on effort — ✅ EMPTY (increments 54 and 57d)

`PaneDragCoordinator` (723 lines) was taken by `MacSidebarRow`, `MacNavigatorColumn` and
`MacContentColumn`, and this section said it could not ascend for the reason increment 41 recorded:
`DropTargetFrameReader` reads the compositor rect, which differs from the hosting view's frame by the
island moat, and by a differently-animating amount during a collapse.

> **Resolved, increment 54 — and the resolution is that the question was mis-asked.** Every word above
> is still true of `DropTargetFrameReader`, which is ~40 lines and a genuine kind 3. It was never true
> of the other 683: a spring-load latch, a drop resolver, a chip sink and a rendezvous of weak refs
> read no geometry at all. The coordinator DESCENDED to `SlopDeskClientCore/Pane/`, the reader stayed in
> `SlopDeskClientUI` (in `PaneDragChrome.swift`, riding under the canvas as kind 1 — 56e then gave it a
> file of its own and deleted `PaneDragChrome.swift`), and the chip —
> an `NSHostingView` over a SwiftUI card, one floor UP — reaches the coordinator through a
> `PaneDragChipSink` protocol, which is stage B's pattern.
>
> **The lesson generalises past this row.** "Blocked on a geometry fact" was a property of one member,
> and it was allowed to describe the whole file because the file was the unit of the ledger. Two of
> the three imports it was blocking dissolved the moment the split was made, with no AppKit written.
> Before writing "not independently schedulable", check whether the blocker is the file or one
> declaration in it.

> **Closed, increment 57d — and the remaining ~40 lines were not geometry either.** `DropTargetFrameReader`
> was the last kind 3 on this page and it is deleted, not ported. The moat that made the compositor rect
> and the hosting view's frame differ is `MacContentColumn`'s constraints now, the difference is zero,
> and the AppKit view registers its own rect. **The blocker was a fact about where a modifier had been
> applied, phrased as a fact about geometry** — so the sentence above, "check whether the blocker is the
> file or one declaration in it", now has a second half: check whether the blocker is geometry at all, or
> a layering choice wearing geometry's words. This category is empty; nothing in the canvas is blocked on
> a measurement.

### So the order is

1. ~~Kind 2 — the pool goes down.~~ ✅ increment 45 (two imports, no rewrite) and ✅ increment 54 (the
   canvas's ~2,900 lines of decision, two more imports, still no rewrite).
2. Kind 1's small surfaces — ~~`StatusDotView`~~ (✅ increment 46), ~~the first-launch checklist~~
   (✅ increment 47), ~~the bespoke settings pages~~ (✅ increment 49), ~~the panel's four surfaces~~
   (✅ increment 51). Each a contained AppKit rewrite, and each cost one import except the last,
   which narrowed one instead.
3. ~~The device panels.~~ ✅ increment 52. `SimulatorScreenNSView` and `AndroidScreenNSView` were
   indeed kind 2 in disguise — 693 lines that moved verbatim, deleting an import edge — and
   `DeviceKeyEvent` turned out to be a third.
4. The canvas. Increment 54 emptied it of everything that was not a drawing — ~2,900 lines down,
   3,850 in `SlopDeskClientCore/Pane/` (3,617 at the time; 56c and 57b added 233), and kind 3 dissolved on the way (see the amendment above). What
   is left in `Sources/SlopDeskClientUI/Pane/` is **5,485 lines across 23 files**. That is the AppKit
   rewrite's core, and it is the only thing between here and **two** remaining import edges — both a
   mount of the canvas or of a column that hosts it. (`WorkspaceColumnHosts` is in `App/`, not `Pane/`;
   the five-file claim this step used to make was stale by three increments.)

   **`Pane/` is not the canvas, though, and reading it as the scope under-counts by a fifth.** Six
   files outside the directory are inside the mount closure and no ledger row names them:
   `Overlays/CommandNavigatorView` (491), `Overlays/IslandChipStack` (150),
   `DesignSystem/SlateIsland` (138 — the moat, and therefore the kind-3 blocker), `Columns/ContentColumn`
   (133), `DesignSystem/SlateEmptyState` (109), `App/WorkspaceColumnHosts` (62). **+1,083, so the real
   figure is 6,568 across 29 files.** This is increment 51's finding one row down — `CodePanelSurfaces`
   was carried at 632 while the surfaces it draws host ~4,100 more — and `CommandNavigatorView` is filed
   `Platform::Both` at `binding_rows.rs:131`, so it is a second renderer, never a deletion.

   **This is a SECOND renderer, not a port-and-delete.**

   > ⚠️ **The first version of this paragraph, written 2026-08-20, said the nine `#if os(` files carry
   > "the macOS branches, and they are what the AppKit rewrite *replaces*". That is FALSE for five of
   > the nine and it is the most dangerous sentence this page has carried**, because it is an
   > instruction. Only four carry a macOS arm: `SplitContainer` (×1), `PaneMoveAffordance` (×2),
   > `DropTargetFrameReader` and `SatellitePaneContent` (whole-file). The other five carry **iOS** arms
   > or are whole-file iOS — `TerminalLeafView` (2), `TerminalFindBar` (1), `TerminalInputHost`,
   > `PaneMoveEscapeResponder`, `TerminalLetterboxContainer` (whole-file each). **716 lines of `Pane/`
   > are code the AppKit rewrite must not read, not touch and not translate.** An agent handed "replace
   > the macOS arms" against `TerminalInputHost.swift` would delete the phone's only keyboard.
   >
   > The count was wrong too — nine, not eight. `TerminalLetterboxContainer` gates on
   > `#if canImport(SwiftUI) && os(iOS)`, which a `#if os(` grep does not match. That is 56a's
   > *"capitalised"* failure one form down: the census was keyed on a **spelling**, not on the property
   > it was meant to test, and a spelling census reports a clean miss as a clean pass.

   So the rewrite deletes the four macOS arms and **nothing else** in `Pane/`; the 716 iOS-only lines
   and every ungated shared file stay exactly where they are, because the phone still draws them.

   Doing the evacuation first was not a detour. A 7,123-line canvas ported to AppKit with the decisions
   still inside it would have been ~2,900 lines of logic rewritten by hand into a second language, and
   the "one implementation, never two" rule would have been broken in the same commit that claimed to
   honour it — because the phone would still be reading the SwiftUI copy.

5. The fold — **and it is a merge into a target that already exists, not a rename.** Every version of
   this step until now read *"`SlopDeskClientUI` → `SlopDeskPhoneUI`"*, which describes moving a name
   onto empty ground. `Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift` has been there since stage A:
   155 lines, declared at `Package.swift`, and it `import SlopDeskClientUI` like any other consumer.
   The fold is the draining target's 101 files landing on top of an occupied target whose own app
   entry point is one of its consumers. That is a different operation with a different failure mode —
   two `@main`s, two roots, and a `WorkspaceRootView` that has to reconcile with `SlopDeskPhoneApp`'s
   scene — and none of it is a `git mv`.

   Three more facts this step never recorded:

   - **"whole-file `#if os(iOS)`" is not what happens to most of it.** 40 of the 101 files already
     carry an internal `#if os(macOS)`/`#if os(iOS)`. Those are not wrapped — they are *resolved*, the
     macOS arm deleted, because by then the Mac has its own renderer and the gate has one live side.
     The supervisor's "one allowed gate" rule (`slopdesk-invariants`, the `SlopDeskPhoneUI` whole-file
     exemption) is the shape the target must be left in, not the shape it is in now.
   - **Two test files cross the halves and no ratchet sees them.** `ui_edges` in
     `slopdesk-invariants` globs `Sources/…` only, so `Tests/SlopDeskMacUITests/MacRailStatusRollupRender.swift:31`
     and `MacChromeSnapshotRender.swift:44` both `@testable import SlopDeskClientUI` unopposed. They
     take `SlateProjectIsland`, `SlateSearchField`, `SlatePlateStyle` and `StatusDotView` — the SwiftUI
     design-system halves — into the **Mac's** snapshot harness. That is the same edge the gate exists
     to forbid, wearing a `Tests/` prefix, and it blocks the fold exactly as a source edge would.
     **Done in increment 57b** — the gate covers `Tests/` across both spellings and all four edges,
     with those two files in a subset-checked allowlist so a third crossing is red immediately.
     **Paid in increment 62**, where the four-symbol list above turned out to be one symbol and one
     modifier: the allowlist is gone, the ban is flat, and the manifest edge is cut too.
   - **A `Platform::Both` binding is a second renderer, not a port.** `CommandNavigatorView` was read
     as port-and-delete work; `binding_rows.rs` files its verb as `Both`, which means the phone needs
     it too and the Mac's AppKit version joins it rather than replacing it. Check the Rust table before
     scheduling any surface as a deletion — the table is the authority on which platforms want it, and
     it is generated from the same rows the supervisor pins.

## Stage F — the canvas plan

Audited 2026-08-20 against the tree, not against this page. Where the two disagreed the tree won, and
the corrections are folded in above rather than listed here. Two waves: **P** moves what is not a
drawing and is not AppKit at all; **R** writes the second renderer. Batches own disjoint files because
that is how they are dispatched.

### The canvas is 6,568 lines across 29 files

`Pane/` is 5,485 of it (23 files). **716 of those are iOS-only and must not be read by the AppKit
work**: `TerminalInputHost` (395), `PaneMoveEscapeResponder` (221), `TerminalLetterboxContainer` (100)
are whole-file iOS, and `TerminalLeafView`/`TerminalFindBar` carry three more iOS arms between them.
Only four files carry a macOS arm at all. The other 1,083 lines are the six files outside the directory
listed in §3.5 step 4.

### Wave P — before a line of AppKit

Increment 54 asked "what in here is not a drawing" and found ~2,900 lines. Asked again after the port
was scheduled, the answer is **~445 more**. A second sweep finding a tail is expected; the point is
that every line of it would otherwise be hand-translated into a second language by the batch that
claims not to do that.

| | Moves | Why it is not a drawing |
| --- | --- | --- |
| **P1** | `TerminalLeafView`'s six `wire*`/`clear*` pairs + four lifecycle methods → `ClientCore/Pane/TerminalPaneWiring` | ~250 lines of retain-cycle discipline, teardown ordering and `EnableSecureEventInput` reference balance. None of it reads a token or names a view |
| **P2** | `SplitContainer`'s drag orchestration → `ClientCore/Pane/PaneCanvasDragController` | ~120 lines. `commitDestination`'s ordering — record placement *before* `detachPaneToWindow`, because `detachedPanes` mutates synchronously — is currently pinned only by a comment |
| **P3** | `PaneMoveAffordance`'s `PaneMoveEscapeMonitor` → `ClientCore/Input/` | ~75 lines: an `NSEvent` monitor and an FFI call behind a representable returning a bare `NSView()`. 54 already ruled on this exact shape for `SystemKeyCaptureController` |
| **P4** | `nativeShared` on both leaf factories | See risk 2 |
| **P5** | The island moat into `MacContentColumn`; delete `DropTargetFrameReader` | See risk 1 |
| **P6** | The grab pill and the pill glyphs → `SlopDeskSlate`; mint `Slate.Metric.glyphPlate` and `Slate.Opacity.accentRing` | 56e's ruling: when both renderers need the same *artwork*, it goes to the floor rather than into a gate |
| **P7** | Three missing pair-ratchets | Below |

P1–P4 are fully parallel. P5 follows P2 (both edit `SplitContainer`), P6 follows P3, P7 follows P6.

**Wave P is DONE — all seven landed 2026-08-20** (P1, P2, P3 and P7 in increment 57c; P4, P5, P6 in
57d). P7 came early rather than last: its three rows are ratchets, not code, and the table above had
already identified all three, so there was nothing for P6 to hand it. Its stated dependency was an
artefact of listing it last — the same scheduling accident this page flagged for P5 one paragraph down,
and the reason both notes are kept below rather than deleted on completion.

**P5 was the highest-leverage item on this page and the ledger scheduled it last by accident.** Kind 3
— *"the compositor rect differs from the hosting view's frame by the island moat"* — is a statement
about SwiftUI. Moving the moat up made the difference **zero**: the hosting view's frame *is* the
canvas, `DropTargetFrameReader` was deleted rather than ported, two of the nine platform gates collapse,
and registration is the three lines `MacNavigatorColumn` already uses. It was available the whole time,
before any leaf was drawn — which is the argument for re-reading a dependency order before trusting it,
not for trusting this one.

### Three ink tables are ungated, and one has both renderers shipping today

The pair-ratchet exists because a `Color`-returning table cannot descend below `SlopDeskSlate`, which
sits *above* `SlopDeskClientCore` — so each renderer resolves it and the halves are pinned as a pair.
Three are gated (`PaneStatusPillInk`, `DropZoneInk`, `GuiUploadTint`). Three are not:

| Table | SwiftUI half | AppKit half |
| --- | --- | --- |
| `FindTogglePillAppearance` | `TerminalFindBar.swift` ×3 | **`MacGlobalSearch.swift:395` — SHIPPING** |
| `PaneStatusPillFill` | `PaneStatusPills.swift` ×5 | none yet |
| `DropZoneLabelInk` | `PaneDropOverlay.swift` | none yet |

The first is not a future risk — **it is 56c's stated failure, already realised.** Its own header says
the invariant it exists for is *"the find bar and the global-search query bar render the pills
identically"*, both halves are live, and nothing checks it. 56c's sentence has now gone unapplied to
its siblings twice (57b caught two, this catches three), which is enough repetition to stop calling it
an oversight: **a table that resolves to a `Color` is a pair the day it is written, and the ratchet
belongs in the same commit as the table.**

### The three risks, decided — all three landed (1 and 2 in increment 57d, 3 in increment 60)

1. **`DropTargetFrameReader`.** Resolved by P5's relocation, but the hazard changes shape rather than
   vanishing: SwiftUI's `GeometryReader` reports the *interpolated* rect every frame, while AppKit's
   `convert(bounds, to: nil)` reports the **model** frame, which jumps to the final value the instant
   the animation opens. During the island settle a drop would resolve against where the canvas *will
   be*. **Take the model frame** — a drop resolves to a layout that is committing anyway, and the
   alternative reads `layer.presentation()`, which is `nil` outside an animation and resolves against a
   rect the pointer has already left. Write the choice into the registration closure's doc comment: it
   is the one place the two halves genuinely answer differently, and nothing fails if it regresses.
2. **The terminal leaf is layer-hosted, and `swift build` never compiles its embedder.** Both leaf
   pixel seams already cross as `AnyView` (`TerminalRendererFactory`, `VideoWindowFactory`) over views
   that are *already* `NSView`s — `GhosttyLayerBackedView` and `MetalLayerBackedView` — which neither
   UI target can reach. Widen the seam with a `nativeShared` slot returning the platform view. The
   alternative, an `NSHostingView` over the `AnyView`, reintroduces the full-bleed hit-claim the split
   spent five increments removing, at the one surface that must take every keystroke. Two traps ride
   along: `GhosttyTerminalView.body` carries the `TerminalConfigBroadcaster` observation that is the
   only path from a Settings edit to a surface reflow — skip the SwiftUI wrapper and you skip it — and
   anything touched under `ThirdParty/ghostty/` is verified **only** by the manual
   `slopdesk-ops enable-renderer macos` + `xcodebuild` recipe, so P4 lands as its own commit with that recipe in
   the message. Corollary, and increment 45b's lesson again: **any dead-code claim in this port greps
   `ThirdParty/` too.**

   > **Landed, increment 57d — and the config trap was answered structurally, not by remembering it.**
   > `followTerminalConfig` no longer rides `GhosttyTerminalView.body`: it is armed from `GhosttyApp`'s
   > `init`, once per process, in the one object that owns `ghostty_app_update_config`. So the native
   > mount cannot skip it by skipping the SwiftUI wrapper — there is no longer a wrapper to skip. **A
   > trap that survives only if every future caller remembers it has not been answered.** The end-to-end
   > proof is still manual and still cannot be automated: open Settings ▸ Terminal on a renderer build
   > and change the font size TWICE — once proves the arm, twice proves the re-arm.
3. **Hide/collapse.** `alphaValue = 0` is what ships and is correct; `isHidden` is not, for a reason
   worth writing down — a layer-hosting view sizes its `IOSurfaceLayer` frame and `contentsScale` in
   `layout()`, which does not run on a hidden subtree, so an un-hide after a scale change presents
   stale geometry. The genuine open item is **hit-testing, not visibility**: SwiftUI's
   `.allowsHitTesting(false)` suppresses a whole composed subtree, but AppKit's `hitTest → nil` does
   nothing for `NSTrackingArea`s, which are rect-based and keep firing. A hidden tab's terminal keeps a
   tracking area over the visible tab's. It presents as a mouse-reporting TUI in a background tab
   following the cursor in the foreground one, and nothing on this page named it before now.

### Wave R, and two batches that would be mistakes

Eleven renderer batches, every one landing `Sources/SlopDeskMacUI/Pane/Mac*.swift` and **deleting
nothing from `Pane/`** except the four macOS arms. Cheap and independent first (the scrims, the
overlays, the pills, the find bar, the hint mode), then the two leaves, then `MacSplitCanvasView` last
because it mounts everything and is written once. `MacCommandNavigator` **joins** its SwiftUI twin
rather than replacing it — `binding_rows.rs` files the verb `Both`.

**The order is the mount graph, read upward.** Every batch below is a file nothing else in `Pane/`
mounts, until R9. That is not a scheduling preference — it is the only order in which a batch can be
finished, because a Mac part whose mounter is still SwiftUI has nowhere to be put.

| | Ports | Lines | Mounted by | |
| --- | --- | --- | --- | --- |
| **R1** | `PaneResizeScrim` + `PaneRecedeScrim` | 62 | R11 | ✅ 58 |
| **R2** | `PaneStatusPills` | 180 | R9, R10 | ✅ 58 |
| **R3** | `PromptJumpFlashOverlay` + `LinkHighlightOverlay` + `ViCursorOverlay` | 261 | R9 | ✅ 58 |
| **R4** | `ViModeOverlay` + `HintModeOverlay` | 510 | R9 | ✅ 58 |
| **R5** | `TerminalFindBar` | 302 | R9 | ✅ 58 |
| **R6** | `PaneDivider` | 152 | R11 | ✅ 58 |
| **R7** | `PaneDropOverlay` + `PaneDropReceiver` | 285 | R11 | ✅ 58 |
| **R8** | `PaneMoveAffordance` (the grab pill) | 449 | R11 | ✅ 58 |
| **R9** | `TerminalLeafView` + `BuildStatusPlaceholderView` | 413 | R11 | ✅ 60 |
| **R10** | `GuiLeafView` | 1,005 | R11 | ✅ 61 |
| **R11** | `SplitContainer` + `PaneContainer` + `SatellitePaneContent` | 754 | R12 | ✅ 61 |
| **R12** | `ContentColumn` + `SlateEmptyState` + `IslandChipStack` | 376 | `MacContentColumn` | ✅ 61 |

**R12 was added while R11 was being scoped, and the table was wrong before it.** R11's "Mounted by"
read `MacContentColumn`, which was true of the column and false of the mount: the column called a
factory that mounted `ContentColumn`, and `ContentColumn` is what mounts `SplitContainer`. A ported
canvas with an unported mounter is a batch that cannot land. See increment 61 for why naming the
remainder beat widening R11 to swallow it.

R1–R8 are fully parallel — no file in the left column names another, and the dependency arrows in
`Pane/` that look like exceptions (`HintModeOverlay` "naming" `TerminalLeafView`, `PaneDivider`
"naming" `SplitContainer`) are doc comments, not mounts. R9 and R10 follow R2–R5. R11 follows all.

**716 lines are iOS-only and must not be read by any of them**: `TerminalInputHost` (395),
`PaneMoveEscapeResponder` (221) and `TerminalLetterboxContainer` (100) are whole-file iOS and stay
behind as `SlopDeskPhoneUI`'s, as do the three iOS arms inside `TerminalLeafView` and `TerminalFindBar`.
An agent porting R5 or R9 that reads its file top-to-bottom will port an arm the Mac never compiles.

**Risk 3 is R9's, not a follow-up.** The `NSTrackingArea` that keeps firing under a hidden tab lands
with the terminal leaf, and there is no later batch where it becomes cheaper to notice.

- **Closing the satellite edge early cannot work.** `SatellitePaneHost.contentView` mounts
  `PaneContainer`; porting only the drag strip leaves an `NSHostingView` *plus* a third grab-pill
  spelling — strictly worse than today. The ledger already says nothing here is independently
  schedulable; an agent chasing the count will try it anyway.
- **A shared `MacPaneParts.swift` written up front.** Increments 52/53 settled this: merge shells only
  with both halves standing still. Write the duplication, then merge it as a 53-style follow-up.

### The fold, concretely

> **The numbers in this paragraph were wrong and are corrected below it (increment 62).** They were
> counted once, early, and never recounted while the target drained from both ends. Read the boxed
> census, not the prose.

**F2 first, not last** — reconcile the two roots (`SlopDeskPhoneApp`'s `@main` keeps it,
`WorkspaceRootView` becomes its scene root) so the tree has one root while 101 files move. Then **F1**,
resolving 54 platform directives across 40 files — the macOS arm deleted, the `#else` promoted, six
agents split by directory. ~~Then **F3**, the two Mac snapshot harnesses~~ — **done in increment 62**,
and neither of the two answers this plan weighed was the one that worked: the harness did not split and
nothing became a renderer. Both rigs simply stopped re-deriving material the Mac column already
resolves natively, which is why F3 no longer gates anything. Then **F4**, the move and
`Package.swift`. Then **F5**: every gate naming `Sources/SlopDeskClientUI/…` re-points, **and each one
is re-run against a deliberately broken tree afterwards** — a path rename is precisely how a gate
becomes absent while staying green, which 56f, 57b and the `repo_files` ordering bug in the
`decodeIfPresent` gate have now demonstrated three times.

#### The recount (increment 62)

**F2 is already done.** `SlopDeskPhoneApp` mounts `WorkspaceRootView` today and
`Sources/SlopDeskClientUI/` declares no `App` and no `Scene`. The tree has one root already; F2 is a
line to strike, not a step to take.

**F1 is 148 directives across 94 files, not 54 across 40 — and 80 of those files are one line each.**
The census, by bucket:

| Bucket | Files | What the fold does to it |
| --- | ---: | --- |
| **A** — whole-file `#if canImport(SwiftUI)` | 56 | one line, top and bottom |
| **B** — whole-file `#if os(iOS)` | 24 | already right |
| **C** — whole-file macOS-only | **0** | — |
| **D** — MIXED: an inner platform branch | **14** | **the whole of the real work** |
| **E** — no directive at all | 4 | see below |
| | 98 | 20,515 lines |

**Bucket C is empty, so NOTHING deletes.** All 20,515 lines survive the move; the diff is wrapper
normalisation plus fourteen files' inner-branch collapse. The plan's "the macOS arm deleted" describes
bucket D and only bucket D.

**Two of the fourteen declare the SAME TYPE TWICE**, once per arm — `SlateSearchField`
(`NSViewRepresentable` vs `View`) and `PaneMoveEscapeMonitor` (`NSViewRepresentable` vs a `View`
mounting `PaneMoveEscapeResponder`). Deleting only the `#if`/`#else`/`#endif` lines produces a
redeclaration error; each needs the macOS arm's BODY removed. Three more sharp edges in the same
fourteen: `SettingsInk.swift:156` is a three-arm `#if/#elseif canImport(UIKit)/#else` whose `#else`
drops a `13` fallback; `NotificationPermissionRow.swift:77` is the tree's only `#elseif os(iOS)`, so
the iOS body is the SECOND arm; and `ImageDecode.swift` is the only bucket-D file with no
`canImport(SwiftUI)` wrapper, so its first directive is not the one you expect.

**The four bucket-E files are the interesting finding, and they are not an oversight in the census.**
`DevicePanelChrome`, `PreferencesEnvironment`, `OverlayEnvironment` and `PreferencesStoreBinding` carry
no platform gate because they may hold no view — and §3's own rule says *a UI target holds views only;
anything that would compile without a view framework belongs in the shared logic target*. A file with
no directive in this target is therefore a question, not a leftover.

**The consequence the plan did not price: normalising bucket A to `#if os(iOS)` takes the phone's
tests out of `just check`.** Fifty-six files compile on the macOS triple today, because
`canImport(SwiftUI)` is TRUE there — which is what lets `Tests/SlopDeskClientUITests` run under `swift
test`. Make them `os(iOS)` and that suite can only run on a booted simulator
(`slopdesk-gate ios-tests`, deliberately NOT in `just check` because a headless gate cannot assume
one). Thirty-two test files would leave the default gate silently, and a suite that still exists but
no longer runs is worse than a deleted one.

So F1 gains a prerequisite, **F0: drain the phone's test target downward before gating it.** By the
same rule that governs the four bucket-E files — eighteen of those thirty-two files use no
`SlopDeskClientUI` symbol at all (several carry a dead `@testable import`), six reach only a namespace
`enum`, and four only a `static` member hung on a view type. Those belong below the UI split, where
they keep running on every platform forever. What is left after the drain is the handful that truly
build a view, and those are the ones the simulator gate is FOR.
