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
`MacVectorIconView`), and `check-supervisor.sh` fails the build if a `some View` appears in the floor.

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
  — `PeekReplyTarget`, `PeekReplyFormatter`, `PendingToolSummary` — which is most of why the card is
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
  now empty and gone**: the host's whole card machinery is `#if os(iOS)`, and `check-supervisor.sh`
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
  clicks at all — and the modal as its sibling. `check-supervisor.sh` gates the regression directly:
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
  were invisible because a build of forty-one EMPTY files is a green build — `make check-ios` was
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
  phone mints a plain `WKWebView`, and check-supervisor keeps the subclass's name out of every file but
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
  in `WorkspaceOverlayKeyToggles`, which carried overlays only. All of it is bound now, check-supervisor
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

### Increment 15 — the phone's key path

`Sources/SlopDeskWorkspaceCore/iOS/` held four files that were rules about bytes with no view in
them: `KeyEncoding` (the C0 fold, the arrows' CSI-vs-SS3 introducer, the xterm meta prefix),
`InputRouting` (which of the phone's two input paths a press takes, and the chord it makes for the
binding table), `KeyboardAccessoryDecision` (one threshold), and `FloatingCursorMapping` (a travel
accumulator and its arrow bytes). All four are `slopdesk_workspace::phone_key` now, reached through
`slopdesk_phone_*` in `slopdesk-ffi`, and the four Swift files are one — `PhoneKey.swift`, which
holds the vocabulary a responder builds a press in and nothing else.

Three things are worth recording beyond the move itself.

THE CRATE IS `slopdesk-workspace`, NOT `slopdesk-terminal`. The terminal crate reads the host→client
byte stream and says so in its own charter; this writes the client→host one. Its real sibling is
`send_keys`, which is already there — both turn a key into PTY bytes, and they must never disagree
about what a key MEANS. They stay separate functions because they are asked by different things: one
reads a NAME a human wrote in a preset (`<C-c>`), the other reads a live `UIKey` whose vocabulary is
a HID usage and a flag word, and whose answer depends on a mode the far side set. A test rather than
a call keeps them honest: `send_keys_agrees_on_every_special` asserts all twenty-six special keys
encode byte-for-byte what `send_keys::key_token` gives their names, in the mode-reset form.

THE MODE IS THREADED, NEVER REMEMBERED. Nothing in the crate holds DECCKM: the caller reads it off
the live terminal model per press and passes it in. A remembered copy would be one parse behind the
screen the user is looking at, which is exactly how arrows go dead in vim.

TWO THINGS CHANGED IN THE MOVE, both deliberately. The `arrowFallback` closure is gone — it existed
for arrows before the pure table modelled them, the table models them now, and it had no production
caller. And the floating cursor's emit loop is a division rather than a chain of subtractions: the
Swift `while accumulated >= threshold` was unbounded below a finite delta, so a degenerate
`UITextInput` coordinate would have spun it for the rest of the process's life. The count is the
same and the remainder is one rounding instead of many.

What did NOT move: `KeyRepeater` and `ManualRepeatScheduler` (a `DispatchSourceTimer` machine and
its virtual-time double — a scheduler, not a rule), `FocusGenerationGuard` and `PaneFocusCoordinator`
(a `becomeFirstResponder` race, which only exists where UIKit does).

And the finding this increment surfaced, which was the largest outstanding parity gap in the app:
THE PHONE'S TERMINAL COULD NOT RECEIVE A KEYSTROKE. `TerminalInputHost` was named by
`GhosttyLayerBackedView`, by doc 17 §2.5 and by half the headers in that directory as the owner of
iOS physical-key and IME forwarding, and it existed nowhere in the repo — only in comments. That is
why every file above had tests and no production caller: they were the prepared pieces of a responder
nobody built. Increment 16 builds it.

### Increment 16 — the responder, and the identity the rules were keyed by

`Sources/SlopDeskClientUI/Pane/TerminalInputHost.swift` is the UIKit half: a `UIViewRepresentable`
over a zero-sized, touch-transparent `TerminalInputHostView` that holds first responder for the pane,
overrides `pressesBegan`/`pressesEnded`, conforms to `UIKeyInput` for the software keyboard's commits,
and owns the `⌃ esc ⇥ ← ↓ ↑ →` accessory row. It mounts from `TerminalLeafView` under the renderer
and registers with `WorkspaceStore.focusCoordinator`, which closes the `PaneFocusCoordinator` header's
own ⚠️ — that seam had no producer until now. The phone can type.

ONE VIEW, TWO PATHS — the earlier increment's header claimed a press responder and a text proxy had to
be separate views because "the responder order between them is undefined". That is a claim about two
FIRST RESPONDERS, and it is not the design that was needed. `pressesBegan` runs `PhoneKey.route`
first and only then decides whether to call `super`: a press routed to the encoder never reaches
UIKit's text system, and one routed to the proxy is a press this view never touches. The order is
ours, explicitly, rather than UIKit's. One responder, and the header was corrected.

THE BIGGER FINDING, WHICH SENT INCREMENT 15 BACK FOR A REWRITE: a key's IDENTITY cannot be read off
what it COMMITTED. Both the deleted Swift original and this port's first cut keyed the special-key
table by `UIKey.characters` — `"\r"`, `"\t"`, the four private-use arrow scalars. Nineteen keys commit
nothing a table can match, so all nineteen were silently dropped: Home, End, Page Up/Down, Insert,
forward Delete and F1–F12. That is `docs/29`'s deferred item #7, which had been sitting open since
2026-07-07 as "add to the `isSpecial` whitelist". It is not a whitelist bug. `UIKey.keyCode` — a USB
HID keyboard usage — is the only signal on a press that means the same key under every layout, every
input method and every modifier, so `KeyPress` now carries the usage and ONE string (`base`, for the
two questions that are genuinely about the layout: which C0 byte a ⌃ fold lands on, and which
character a binding is keyed by). `UIKey.characters` crosses nowhere. Off the usage the whole nav and
function block is one table row each, `SpecialKey` has twenty-six cases, and the accessory row's
plates are synthesized presses through the same encoder rather than a byte table of their own.

Three smaller things fell out of the same change. ⌘ on a special key now sends NOTHING — the old
identity branch answered before the ⌘ check, so ⌘Esc wrote an ESC to the PTY. `Home`/`End` join the
arrows in taking the live DECCKM introducer, which is the cursor block xterm actually defines. And
`NamedChordKey` widened from six cases to all eleven of `key_naming::NamedKey`, so Home, End, the page
keys and ⌃⇧Space (the Vi-mode chord, under the same non-⇧-modifier rule the Mac's dispatcher applies
to its own key code) are bindable from a phone for the first time.

STILL NOT HERE: `UITextInput`. iOS shows CJK candidates in the keyboard's own bar and commits through
`insertText`, so typing Chinese works today; what the conformance would add is INLINE composition
display and the space-bar-drag floating cursor. `PhoneKey`'s `FloatingCursor` is the prepared, tested
half of the second and stays caller-less until then — the one remaining seam of that shape in this
directory, and it is named here so it does not become another `TerminalInputHost`.

### Increment 17 — what Settings offers, once

`rust/slopdesk-settings/src/settings_catalog.rs` now holds what a settings page can be set TO: the
eight-section taxonomy with its titles, glyphs, order and the one row that needs a Mac; ten option
groups with their labels and their honesty captions; and the three scalar ladders with their bounds,
their magnitude stops and their readouts. `rust/slopdesk-ffi/src/settings_catalog.rs` marshals it as
this boundary's list idiom — a count plus indexed accessors — and
`Sources/SlopDeskClientCore/Settings/SettingsCatalog.swift` is the one reader.
`SettingsOption.swift` and `SettingsOptionCatalog.swift` are deleted; the `SettingsSection` and
`ApplyTiming` enums inside `SettingsView.swift` are gone as data.

WHY IT MOVED, given it had already moved once. The Swift catalog existed because a `Picker`'s choices
written as inline `Text("…").tag(…)` children are unreachable to a test and drift from the enum they
tag. Nothing in that argument is about the view boundary — the table is strings and numbers with no
framework in it, which by the repo's own rule means nothing kept it in Swift. What made it urgent is
the split itself: two halves of the UI were about to render the same choices from two frameworks, and
a card grid has no `…`, so a group that drifted would offer a DIFFERENT set of options per platform
with nothing on screen saying so.

`SettingsSection` STAYS an enum, and that is the interesting part. `SettingsSectionContent` maps a
section to a `some View` through an exhaustive `switch`, which is the one thing about a section that
cannot leave Swift. So the enum survives as a DISPATCH key with no data on it: `title`,
`systemImage` read the catalog row keyed by `rawValue`, and `SettingsSection.ordered`
— a `compactMap` over the catalog, not `allCases` — is what both lists render. Declaration order here
is no longer the contract; the boundary's is.

THE PIN THAT COULD NOT CROSS, and the drift it caught immediately. Exhaustiveness needs a Swift
enum's `allCases`, which the boundary cannot see, so `SettingsOptionCatalogTests` keeps it and drops
everything else it used to assert (the labels, the captions, the order and the readouts are pinned in
Rust now; restating them here would be the mirror fixture the port removed). It earned its keep on the
first run: five tokens had been written in the port's own idiom — `after_current`, `context_menu`,
`copy_or_paste`, `restore_last_session`, `new_window` — where what is on disk is hyphenated. A token
is not a name this table chooses; it is already in a user's `UserDefaults`, so it is quoted, which is
why `multiple_tabs` and `block_hollow` stay underscored next to five hyphenated neighbours.

That failure is also why the test asserts NO DUPLICATES as loudly as no gaps. Four of these enums have
a non-failable `init(rawValue:)` that repairs to a default rather than returning `nil`, so a
misspelled token does not vanish into the `compactMap` where a missing card would be visible — it
becomes a second card writing the default, identical on screen to the real one. The duplicate is the
only trace it leaves.

Two doors exist for reasons worth naming. `slopdesk_settings_option_menu_label` crosses the folded
`label — caption` form rather than letting the near side concatenate it: where the en dash goes and
what a captionless row reads as are rules, and a rule spelled in two languages is two rules.
`slopdesk_settings_density_token` names the density group's two tokens because density is the one
group the store persists as a bare string, with no enum to round-trip through — without it the near
side would spell `"compact"` itself, in the card art's test and in two `?? "comfortable"` fallbacks.
`check-supervisor` ratchets both, that the two deleted files stay deleted, and that no settings view
spells a choice's own words.

### Increment 18 — a setting is named once

Increment 17 moved what Settings OFFERS (the choices behind each control). This one moves what
Settings CONTAINS: the 57-row table behind the All Settings list — each key with its label, its
one-line description, its default, whether it is edited inline or jumps to a section, and the
keyword blob the search field also matches. It is `rust/slopdesk-settings/src/settings_rows.rs`,
crossed by eleven doors in `rust/slopdesk-ffi/src/settings_rows.rs`.
`Sources/SlopDeskWorkspaceCore/Workspace/Store/AllSettingsCatalog.swift` keeps its name and its whole
public API — every caller compiles untouched, and all eighteen of its existing tests pass unchanged —
but it went from ~700 lines of table to ~175 of marshalling.

WHY A HEADLESS FILE STILL HAD TO MOVE. This one was already the right shape: a searchable list cannot
be assembled out of view bodies, so the catalog existed for a good reason and had no UI in it. But it
had only moved half of what was duplicated. The catalog held `"Copy on Select"` and its sentence for
the searchable list; the Controls page's own toggle row held the same words again, in a different
target, for the same key. Thirty-one labels were like that, and two had already drifted — the same row
was `"Hide Mouse While Typing"` in one place and `"Hide Mouse When Typing"` in the other,
`"Long-Command Notification"` against `"Long-Command Completion"`. Nothing was broken by either; the
list and the page simply called the same knob different things, and nobody was in a position to
notice. `settingLabel(key)` is the near side of the fix and `check-supervisor` is the ratchet: it
parses the labels straight out of the Rust table and fails on any settings view that types one.

THE DESCRIPTION DELIBERATELY DOES NOT CROSS. Measured before deciding: of the thirty-one shared rows,
twenty-two have descriptions that differ, and most differ on purpose. A flat index of 57 keys read by
someone hunting a name needs a different sentence than a subtitle under a section header that has
already said what the section is about. Two registers, two sentences — one name. Forcing twenty-two
copy decisions to make a number look tidier would have been the port serving itself.

THE KEYS STAY SWIFT, because they are `Defaults.Key` names and a `UserDefaults` binding cannot leave
Swift. The boundary quotes them exactly as it quotes any value already on disk, and
`AllSettingsCatalogTests` — which needs the Swift namespace to say it — remains the pin that every
advertised key is a real `SettingsKey` and every surfaced key has a row. The five typed render fields
(`font-family`, `cursor-style`, …) are not `SettingsKey`s at all, so `AllSettingsCatalog.RenderKey`
names them; without it a view asking for one of those rows' words would have retyped the key to avoid
retyping the label.

ONE ROW'S DEFAULT IS DECIDED TWICE ON PURPOSE. `follow-session-focus` defaults On for a Mac and Off
for a phone (docs/45 §8.2), and each side decides it independently — Swift on `#if os(iOS)`, Rust on
`cfg!(target_os = "ios")`. That is honest rather than duplicated, because the xcframework is built
per SLICE, so the Rust constant is a property of the artifact and the Swift one a property of the
compile. They can only disagree if those two come apart, which no compile-time check on either side
can see, so `testTheSharedFocusRowPrintsTheDefaultTheResetRestores` asserts it at runtime.

### Increment 19 — a platform gate is data

The macOS Settings window is the largest surface still waiting on stage D, and the thing standing in
its way was not its size. It was that 2100 lines of `body` carried **thirty-seven `#if os(macOS)`
directives**, and stage D's rule is that `SlopDeskMacUI` may not carry one. Rewriting that page in
AppKit meant deciding, thirty-seven times, what each gate had been for — with no way to check the
answer, because a preprocessor directive has no runtime form. Nobody could ask how many there were,
which groups they hid, or whether the phone was missing something it should have had.

Every one of them was a FACT ABOUT A GROUP wearing a compiler directive's clothes: there is no Dock
on iOS, no `LaunchServices` deep-link, no `NSSound`. `rust/slopdesk-settings/src/settings_layout.rs`
makes that fact a `Platform` field. `groups(section, mac)` filters by the half that asked, so the Mac
renderer asks with `mac = true`, the phone with `mac = false`, and **neither carries a gate**. The
table also holds what a page IS — the group headers, their order, each group's apply-timing footer,
each row's subtitle and which widget KIND it draws — because once the shape is being described
anyway, leaving half of it in a view body would just be the same drift with fewer places to look.

`mac` is an ARGUMENT rather than the compiled slice, and that is the whole payoff. The xcframework is
built per slice, so the table could have been filtered by `cfg!` for free — but then "which groups
does the phone show" would still have no runtime form, and the property would have been given away
again at the last moment. `SettingsLayoutTests.testAskingAsEachHalfFromOneProcessGivesTwoPages` is
the assertion that could not previously be written: one process, two pages. The test it replaces
(`testGeneralPageSurfacesOSIntegrationOnMacOSOnly`) had an `#if os(macOS)` down its middle, so its
iOS expectation was dead text in every macOS run.

WHAT STAYS IN EACH RENDERER, and it is two things. A row carries a KEY but not a BINDING —
`@Default(.onLaunch)` is a Swift property wrapper over `UserDefaults` — so key → binding is a `switch`
in each half, the same shape `AllSettingsListView.inlineControl(for:)` already had. And a `Control`
names a widget KIND, never a widget: what a toggle looks like is the half's own business, which is
the point of splitting them. The General page is the first ported, and its `body` went from five
hand-written `Section`s with three gates to a `ForEach` over the table.

A LABEL FOUND A SECOND REGISTER. Increment 18 said a row's label is one string; the General page
proved that too strong, and the counter-example is exact. Under a `Close Confirmation` header the row
is "Closing a tab"; in a headerless list of fifty-seven keys the same row must say "Close Confirmation
· Tab" or name nothing at all. So `SettingRow` gains `page_label`, empty for all but two rows, folded
by `page_label()` so no renderer knows which are which — the same index-vs-page split the description
already had, reaching the label only where it must. `a_page_label_exists_only_where_it_differs` pins
the count, because every override is a place two strings can drift.

ONE GATE IS LEFT, on purpose. `SettingsLayout.Half.current` is a single `#if os(macOS)` in
`SettingsControls.swift`, and it exists only while one target still renders both halves; it dies when
`SlopDeskMacUI` takes Settings, at which point each shell names its own half. `check-supervisor`
ratchets that it stays exactly one, that the ten layout doors are called by the near side and named by
the header, and that no view types a group header the table already holds.

### Increment 20 — the Shell, Controls and Appearance pages

Three more pages render from the table, which took `SettingsView.swift` from 2102 lines and
thirty-seven gates to 1656 and twenty-one. Each page contributed something the General page had not
needed, and each also surfaced a real gap that the description forced into view.

SHELL brought the four TAB BADGE settings and, with them, a Reset All that could not restore
`tabBadge.busyDelaySeconds` — advertising the row was what made the omission fail a test instead of
sitting there. It also killed a brittle assertion: `a_page_label_exists_only_where_it_differs` had
pinned the override COUNT at two, and the count grew to six on this page. A count is not the
invariant; the invariant is that a page label exists exactly where the index label is QUALIFIED, and
checking that at all first required normalising two qualifier styles (`" · "` against an em dash) to
one.

CONTROLS brought the three link-behaviour pickers, which had each spelled their own choices inline, and
the two SECURE INPUT settings, which were not advertised anywhere. It also brought a new element:
`Control::Note`, prose belonging to a GROUP rather than to any setting — the Open With footnote
explaining why per-target "Open in…" panes cannot exist for a remote host. Forcing that into `Bespoke`
would have put the words back in a view, which is the thing the table removes.

APPEARANCE is the page where the halves diverge in three ways at once, and it is the reason a ROW
carries a platform of its own rather than only a group. Groups the phone omits (Window, Dock Icon);
groups both draw identically (Tabs, Appearance); and one position where each half draws a DIFFERENT
thing for the same two settings — the Mac's live caret preview with its colour wells against the
phone's two plain rows. A gate that means "drawn differently" is not the same gate as one that means
"unavailable", and only the second may cost the phone a capability (§3).

> 🔁 **The cursor half of that is void** (increment 29). The two Cursor groups were never a "drawn
> differently" gate — the preview is pure SwiftUI, and the phone's two plain rows were three settings
> short of it. One `Platform::Both` group now. Window and Dock Icon still make the paragraph's point.

Two additions came with it. `Control::Stepper` is `Slider`'s sibling, and the rule for choosing is
whether the useful values are a handful of MAGNITUDES — scrollback depth, which is a ladder with stops
— or any literal count in a range, like a window's 80 columns. And a group may now have an EMPTY
title, meaning it supplies its own header: `FontSettingsView` draws four sections of its own, so
claiming one header for it in the table would have been a lie. `CursorPreviewView` went the other way
— it drew exactly one section called "Cursor", which is the same header the phone's version needs, so
it gives that up and the table supplies it to both.

Eight more settings became advertised rows here: `shell.autoHideTabsPanel`, the four `window.*`
numbers, `desktopWindow.presentation` and `satelliteWindow.backgroundPointer` — and none of the seven
window keys was in any reset set, so Reset All had been silently skipping every one of them.

### Increment 21 — the Agents and Advanced pages

The last two gated pages, which took `SettingsView.swift` to 1613 lines and twelve directives. What
remains in that file belongs to the pages still to come, not to any page already described.

AGENTS is the page where describing a table caught a DUPLICATE. Its Agent Behaviour group carried
notify-on-complete and notify-on-input, and so does the Shell page's Code Agent group — the same two
keys with a live control on each, which one flat table forbids by construction because a row may
belong to only one page. Notifications belong with notifications, so the Agents copies went. The page
also brought the first rows whose backing is not a `Defaults.Key`: the two host flags ride the
`video-prefs.json` sidecar, so they are keyed the way the typed render fields are and restored with
the model they belong to. A sidecar flag is a `Bool?` whose `nil` means "the daemon decides", and it
decides differently per flag — prevent-sleep off, resume-on-recovery ON — so the unset default is
NAMED on `AgentPreferences` rather than spelled at the control, which is what a toggle reading `nil`
as `false` had got wrong.

ADVANCED is where a group that looked macOS-only turned out not to be. The OSC 52 and OSC 0/2
privileges gate what a REMOTE escape sequence may do on the CLIENT, and a phone attached to the same
host sees the same sequences, so Privileges is `Both`; only the three surfaces backed by a Mac — the
`SLOPDESK_*` override box, the video host sidecar, the `~/.config` file — are `Mac`. Its four rows
also settled where a CONDITION lives: the two clipboard menus are drawn disabled while the master
switch above them is off, and that is a condition on another setting's VALUE, so it is the renderer's
and the row stays in the table. Same rule as the window steppers and the custom link schemes.

Five pages now render from one table. Three surfaces still draw themselves as bespoke groups — the
font specimen, the video host flags, the flat index — and of those only the video flags name a
control shape the table cannot yet express: an optional number with an unset state.

### Increment 22 — the last two pages, and where a timing chip belongs

Editor and Key Bindings finish the set. Neither has rows to describe — the chord editor is one
surface with sections of its own, and the Editor page is RESERVED and says so in the empty-state
voice — so both are single bespoke groups. Describing them anyway is the point: a page that resolves
to NO groups is indistinguishable, to a renderer, from a page whose groups this build predates, so
"nothing to show here" has to be a statement rather than an absence. `every_page_the_navigator_lists_is_described_for_both_halves` pins it.

Placing them found a rule the port had been getting wrong since the first page. `settingsGroup` put
a timing chip under every headed group, which is right for a list of controls and wrong for a
surface: "Applies immediately" under "No File Editor Yet" answers a question nothing on the page
asked, and the four Advanced and Agents surfaces had quietly acquired chips they never had before
the port. The chip belongs where an EDIT does, so it is now drawn only where some row names a
setting — which is also why the video surface, whose four sections each land on reconnect, placed its
own. (🔁 That surface is gone — increment 31 describes its six settings as rows, so the chip comes
from the group like everyone else's.)

### Increment 23 — the font surface stops being one bespoke block

`FontSettingsView` was a single headerless bespoke group drawing four sections of its own, and three
of those four were ordinary lists of rows wearing a surface's clothes. They are groups now — Text,
Ligatures, Style & Rendering — and only Font Family stays bespoke, for a reason worth naming: it is
a pair of SCOPE TABS, and a tab whose choice picks which other controls exist is not a row. That is
the line between a control and a surface, and it is sharper than "this looks complicated".

Four option lists came with them, and all four had been inline `Text(…).tag(…)` children — the exact
shape the option catalog exists to remove, still standing because nothing walked into this file
after the first lift. Eleven settings became advertised rows: the three derived face families, the
fallback list, auto-match, line height, the two ligature settings, bold, italic and blending. None
had been searchable, and all eleven had always been restored by `resetAll()` — the model they are
fields of comes back whole — so this is a gap in what the index KNEW, not in what a reset reached.

The stepper changed shape to take font size. Its readout used to cross finished, which works only
while every stepper's value is an integer; font size is a `Double` the flat index's raw editor may
set to `13.5`, and a reader handed `readout(13)` prints a number the model does not hold. The UNIT
crosses now — `" px"` or nothing — and each side composes the readout from the value it actually
has, which is one door fewer as well as one lie fewer.

### Increment 24 — the Mac's Settings window is AppKit

The four increments above finished the SHAPE port: every page in the navigator now comes back from
`slopdesk_settings::settings_layout`, described down to which platform sees which group. That was
the blocker, because `SlopDeskMacUI` may not carry an `#if os(…)` and Settings was where most of
them lived. With the shape a value, the Mac can draw its own page.

It does, in six files under `Sources/SlopDeskMacUI/Settings`: a window with a real
`NSSplitViewController`, a `.sourceList` navigator over `SettingsCatalog.sections`, a key → closure
binding table, five AppKit controls that carry their own handler, a row builder, and a page that
walks the groups. None of them spells a section title, a group header, a row label, an option name
or a range — the same property `check-supervisor` ratchets on the SwiftUI side, holding here by
construction rather than by a grep.

**A control KIND is not a control.** `Control.cards` is answered by a tile grid on the phone and by
an `NSSegmentedControl` here: a card grid is how a touch target shows art per option, and a window
with a mouse has a control for exactly this that carries the system's focus ring and keyboard
traversal for free. Same schema, different drawing — which is the entire argument for splitting the
halves, finally paid out rather than asserted.

**A rebuild is the update.** Three rows are conditioned on another setting's VALUE — the window
steppers on the size mode, the custom link schemes on the detection mode, the line-height multiplier
on the line-height mode — and those conditions are dynamic rather than layout, so the table lists
every row and the renderer decides. SwiftUI gets the invalidation from the framework; AppKit has
nothing to hang it on, so a write rebuilds the section's stack on the next turn of the run loop.
That is a few dozen views on a click, not a frame loop, and the alternative is a dependency graph
maintained by hand per row.

**A bespoke surface is drawn ONCE, and hosted.** Every described row is deliberately drawn twice —
that is the split. A `Control.bespoke` group is not a control kind: it is a card that writes
someone's `~/.claude/settings.json`, a searchable index of two hundred keys, a free-text override
box. There is nothing for the halves to differ about, and drawing one twice would be two chances to
get the same words wrong. So the twelve of them live in `SettingsBespokeSurfaces.swift`, both halves
resolve an id through `SettingsBespokeSurface`, and the Mac hosts the result in an `NSHostingView`.
Six had been page-local `private var`s in `SettingsView.swift` and are structs now, each owning the
display-time state it used to borrow from its page.

Two of those moves fixed something on the way. The raw-override box used to be cleared by a callback
threaded down from the All-Settings list two groups below — which only worked while one page
happened to own both — and now re-renders from `store.rawOverrides`, so a reset clears it wherever
either one is drawn. And the ✎ jump reports a SECTION ID instead of writing a
`Binding<SettingsSection>`: the two halves navigate differently, and neither owns the other's
selection type.

**What was deleted.** `SlopDeskSettingsScene`, `SettingsView`, and the `SettingsEscapeDismisser`
monitor. The scene supplied ⌘, for free, so the Mac app declares it in `CommandGroup(replacing:
.appSettings)`. Esc is `cancelOperation(_:)` on the window — the responder chain's own path, where
two hardware rounds of `NSEvent`-monitor workarounds used to stand — and it still asks
`slopdesk_video::escape_monitor` through `SettingsEscapePolicy` for the modifier rule and the
chord-recorder veto. Those are decisions; only the thing that asked them was SwiftUI's.

`SettingsView.swift` keeps the per-section structs, because the phone's sheet renders them. What it
no longer keeps is a window. (It is `SettingsPages.swift` as of increment 34 — the file outlived its
name by nine increments.)

### Increment 25 — the first-launch checklist, and a card that was written twice

The guided checklist is an AppKit sheet on the workspace window now
(`SlopDeskMacUI/FirstLaunch`), presented with `beginSheet` rather than a SwiftUI `.sheet` modifier.
Everything it draws is `FirstLaunchModel`'s — the step set, the order, "Step N of M", each step's
title, subtitle and glyph, which step is first and which is last — so the file names no step and no
wording, and the phone's `FirstLaunchView` renders the same model into a sheet of its own.

**Two of the four steps are the Mac's alone**, and they are drawn here in AppKit: registering as the
default terminal is LaunchServices and installing the CLI is `/usr/local/bin`, neither of which the
phone has a version of. The other two exist on both platforms, so they are drawn ONCE in SwiftUI and
reached through `FirstLaunchStepSurface`, which the Mac hosts — the same division increment 24 made
between a control KIND, which each half draws its own way, and a SURFACE, which there is nothing to
differ about.

That division cuts the other way too, and it is what this increment was actually worth. The
OS-integration rows and the CLI-install card each existed TWICE: once as a first-launch step and once
as a Settings group, in two SwiftUI structs, with four titles and four subtitles typed on both sides.
They had already begun to drift — only one of the two marked its first-launch step complete. They are
`MacOSIntegrationRows` and `MacCLIInstallCard` now, one view each, and the Mac's settings page reaches
for the same two rather than hosting a SwiftUI copy. So `SettingsBespokeSurface` has no arm for
`os-integration` or `cli-install`, and says why: a surface is drawn once, but "once" means once per
platform that HAS it, and the phone has neither.

`FirstLaunchView.swift` went from five platform gates to one — the on-launch picker, where
`.radioGroup` is a macOS-only style. `SettingsBespokeSurfaces.swift` went from seven to one. The
shared target is down to 96.

### Increment 26 — the two surfaces that were never cards

The overlay layer is finished. Six of the eight tenants were PICKERS — you summon one, skim it and
dismiss it in a second — and each became a borderless `NSPanel` over the workspace window
(increments before this one). The last two were never pickers: Connect-to-Host is a FORM you fill in
and commit, and the pane/tab close confirmation is a QUESTION. Both are what the platform's own modal
exists for, so neither is owed a card and neither rides `MacOverlayPanel`. They are
`MacConnectSheet` — a real `beginSheet` over the workspace window, the same presentation the
first-launch checklist uses — and `MacCloseConfirmation`, an `NSAlert` sheet.

**What that removes is the last SwiftUI mount over the Mac's split**, which is the thing §3.5 was
counting to. `MacWorkspaceRootView` no longer attaches `OverlayHostView` at all, and
`check-supervisor.sh` fails the build if it comes back. The measurement behind the rule has not
changed: an `NSHostingView` claims every hit inside its own bounds, so an always-mounted SwiftUI
layer over the split makes the window click-dead everywhere its ink is not.

Two things moved BELOW the view layer on the way, because both halves ask them now:

- `ConnectPresentation.shouldCloseAfterConnect(status:)` — a failed connect leaves the form UP with
  the reason inline; every other terminal status dismisses it. One line, and the only rule the two
  drawings of the form share.
- `CloseConfirmationCopy` — which line a parked close deserves. It is not a constant: it depends on
  which of the two parks is armed, on whether a configured policy ACTUALLY gated the park (one raised
  purely for the project-loss warning must not claim "a process is still running" over an idle
  shell), and on whether the close takes a project's last pane with it. Both can apply at once.
  Three branches and a join is exactly the amount of logic that drifts when two halves each carry it,
  so the Mac's `NSAlert` and the phone's `.alert` read the same `request(store:)` → `title` /
  `message`. `check-supervisor.sh` fails either half that respells a line of it.

With the host now the phone's alone, the four summoned cards inside it dropped their dead macOS arms
— a fixed dialog width the phone never wanted, and an `.onExitCommand` twin for an `.onKeyPress`
that already works on both. The palette's opt-in snapshot probe retired for the reason the cheat
sheet's did one increment earlier: the Mac's palette is an `NSPanel` that `ImageRenderer` cannot
render, so the probe was photographing the phone's card on a Mac and telling a reviewer nothing.

The shared target is down to 81, and the biggest remaining block is the pane canvas.

### Increment 27 — one chord editor, drawn twice, and only one half records

Settings ▸ Key Bindings is `Platform::Both` in the Rust layout table, and the table already says why:
a phone with a hardware keyboard runs the same bindings, and the LIST is worth reading with none. So
this is the first bespoke group the Mac draws ITSELF (`MacKeybindingsEditor`) rather than hosting the
shared SwiftUI surface — because its recorder is an `NSEvent` monitor scoped to the Settings window,
and a monitor is not a view to put in an `NSHostingView`.

**Only the Mac records, and the phone says why rather than growing a second recorder.**
`KeybindingCapture` resolves a macOS VIRTUAL KEY CODE through `slopdesk_video::key_naming` — the same
table the dispatcher builds chords from, which is what makes a recorded chord the chord that fires.
`UIKey` carries a HID usage instead, a different numbering, so a capture UI on the phone would have to
invent a second answer to "what key is this". That is the duplicate the split exists to prevent, so
the phone renders every row and its effective chord and offers the global reset, and nothing else.
`check-supervisor.sh` pins both directions: the phone may not reach for `KeybindingCapture`, the Mac
must, and neither half may respell the registry read or the search filter.

> 🔁 **The second paragraph is void** (increment 30). "A second answer to what key is this" was the
> wrong reading of the duplicate rule: the HID usage IS the identity, and the phone had been building
> chords off it against this very table on every terminal keystroke since increment 15. Both halves
> record now, each off its own crate's table, pinned to each other by a test in `slopdesk-ffi`.

The monitor moved across as a plain view rather than an `NSViewRepresentable`, and its two hard-won
details came with it: it captures ONLY events destined for its own key window (an unscoped local
monitor fires for every window in the process, so clicking "Press a key…" and then clicking away used
to swallow every keystroke app-wide and record the first as a bogus chord), and it stands down when
that window resigns key. What changed is the teardown edge — `viewDidMoveToWindow` with no window,
because the AppKit page rebuilds its sections whenever a value gates another row, and a discarded
page mid-capture must not leave a monitor behind or leave Esc permanently disowned.

`KeybindingsEditorView.swift` went from four platform gates to none. The shared target is at 77.

### Increment 28 — the design floor stops riding the draining target

Stage D ends with a rename: `SlopDeskClientUI` holds only what the phone renders and becomes
`SlopDeskPhoneUI`. That promise could not be kept as written, and the reason had been sitting in plain
sight since the AppKit half started drawing: **the token layer is not the phone's**. `SlopDeskMacUI`
reads about two hundred of those constants — 254 `Slate.Metric.space` alone — so renaming the target
around them would have left an AppKit-only module importing the phone's, which is precisely the common
view ancestor §3 forbids. `SlopDeskSlate` is that floor lifted out from under the drain, and it lands
now rather than on rename day because every port from here on reads it instead of adding to the debt.

**The line is a VALUE, never a drawing**, and it is ratcheted rather than described: `SlopDeskSlate`
may not declare a `some View`, a `: View`, a `: Shape` or a representable, and it may not import
either UI target. Let one view in and the next mark to be ported has somewhere to be written that both
halves can see — which is how two renderers quietly become one renderer plus a fallback, with nothing
red to show for it, because a hosted SwiftUI view compiles perfectly well inside an AppKit window.

What crossed is the whole token ladder (`SlateDesign.swift` — `Slate.Native` and every `Color` rung
over it, the terminal profile, the metric/type/motion ladders, `ProjectTint`'s deal), the status
mark's geometry and its wandering tempo, the vector artwork and its `d`-string reader, the appearance
pin, the nerd splice's AppKit half, the chrome field's jump-free configuration, and
`StatusPresentation` — which reads as a view file and is not: it maps a state to a hue and a
silhouette, and the Mac has been calling it through `NSColor(...)` since the navigator crossed.

Four things came apart on the way, each along the same seam. `AgentSpinner` was a SwiftUI `View` with
the cadence hanging off it as statics — the maths is the floor's (`AgentSpinner.phase`/`.lit`, which
the Mac already called), the drawing is `AgentSpinnerView`. `VectorIconView` left `SVGPath`.
`DottedRing` left `StatusDot`. And `slateShadow` — an `Elevation` rung CAST — left the rungs behind,
because casting a shadow is a view modifier while the radius and the offset are values the Mac reads
into a `CALayer`. The ratchet found the last one; it was not on the list.

The measurement that says it was worth doing: **28 of the 41 `SlopDeskMacUI` files that imported the
draining target no longer do.** The twelve that remain each name a specific SwiftUI mount stage D has
not lifted yet — `CodePanelSurfaces`, `SatellitePaneHost`, `RailStatusRollupMount`,
`WorkspaceColumnHosts`, `PaneDragCoordinator`, `FirstLaunchStepSurface`, `SettingsBespokeSurface`,
`OverlayHostView`, `CodeSidebarWebViewPool` — which is now a list of what stage D has left to do
rather than an ambient dependency on the phone.

The tests followed their code: `SlopDeskSlateTests` holds the seven suites that assert VALUES (the
two spellings of a rung are one colour, a bed deals the same way twice, the spinner's closed-form
integral really is its rate integrated, a transcribed `d` string parses to the drawing it was copied
from). The two assertions in them that needed a renderer — the ring's `Shape` path and the search
field's coordinator — moved the other way, into `SlopDeskClientUITests`.

This reverses the 2026-06-24 ruling that the token layer stays inside the view target with no separate
SPM product. That decision was correct on its own terms and is void on ours: it was taken when there
was exactly ONE UI target to compile the constants into, and there are two.

### Increment 29 — the caret section was never AppKit

Increment 19 read Appearance → Cursor as the table's showcase of a gate that means *drawn
differently*: the Mac's live preview with its colour wells, the phone's `cursor-style` +
`cursor-style-blink` as two plain rows, one header either way and — the table said so in a comment —
"the same capability either way". It was not the same capability. The phone had no cursor colour, no
text-colour-under-cursor and no opacity slider, three settings it could not reach from anywhere but
the All-Settings index. That is a gate that means *unavailable*, which §3 does not allow.

The stated reason was that the preview is AppKit. It never was. `CursorPreviewView` is stock SwiftUI
to the last line: `ColorPicker`, `Slider`, the shared `CursorCaret`, and a `Color`↔hex bridge that
resolves through `Color.resolve(in:)` precisely so it would not need an `NSColor` — a choice its own
header documents, two lines under the `#if os(macOS)` that claimed the opposite. Nothing in the file
fails to compile for the iOS triple, and nothing did before either; the gate was inherited from the
days when the whole Settings page was Mac-only and was never re-read after the phone got one.

So: one `Platform::Both` group with the one bespoke row, and the phone's two stand-in rows deleted —
`cursor-style` and `cursor-style-blink` are still advertised settings, drawn now inside the surface
that also draws what they look like. `CursorPreviewSurface`, a wrapper whose entire body was the
`#if`, went with it; the door dispatches `CursorPreviewView` directly. The layout test that pinned
the divergence now asserts the opposite property — the `cursor-preview` row is reachable on BOTH
halves, checked per half so a gate reappearing on either side fails there.

It cost one duplicate title. Cursor was the only group name that appeared twice in the table, and the
test that permits a repeat when the platforms are disjoint now has no case to permit. The check stays
as written — the rule is about what one reader sees on one page, not about the table being globally
unique — but its comment no longer cites an example that has stopped existing.

This is the third gate of this shape (increments 11 and 12 were the first two), and the pattern is
worth naming: **a platform gate that outlives its reason reads exactly like one that still has it.**
The table's comment was the only place the claim was written down, and a comment cannot be compiled.
The check that would have caught it is the one the layout tests now make — assert the capability,
per half, by name.

### Increment 30 — the phone records a chord, and a section stops being macOS-only

Settings ▸ Key Bindings never appeared on the phone. Not gated inside the page — dropped from the
LIST, by a per-section `is_mac_only` flag that crossed the boundary for that one row. Meanwhile the
layout table called the group `Platform::Both` and said why, `KeybindingsEditorView` rendered every
binding, and the bespoke door had an arm for it. Two Rust tables disagreed, and the one that won was
the one that hid the page: the phone's editor was written, tested and unreachable.

The reason given for the flag was that recording a chord is an `NSEvent` monitor with no touch
equivalent, and increment 27 stated the sharper version — that `KeybindingCapture` resolves a macOS
virtual key code, `UIKey` carries a HID usage, and a phone recorder would have to invent a second
answer to "what key is this". **That was the wrong reading of the duplicate rule.** The HID usage is
not a second answer; it is *the* answer, and `slopdesk_workspace::phone_key` had been resolving live
presses against the same user-overridable binding table since increment 15. What was missing was one
function, not one table: `capture_verdict` — Esc cancels, Backspace and Forward Delete clear, and a
chord the config grammar can spell back binds — plus the recorder's two strictnesses, which are the
Mac's own: the space bar is no key, and a base that is neither ASCII nor a letter is refused.

The two rules genuinely do live in crates that cannot see each other — `slopdesk-workspace` takes two
dependencies on purpose and `slopdesk-video` is not one of them — so the agreement is pinned where
both are visible, in `slopdesk-ffi`, which is the pattern that crate already carries for the named-key
numbering. `the_two_recorders_agree_on_every_key_both_can_name` walks sixteen keys twice, once by HID
usage and once by virtual key code, and asserts the verdict AND the persisted spelling match. A phone
rebind written under a token the Mac's lookup never builds is a shortcut that simply stops firing;
that is the failure this test exists for, and it is invisible from either side alone.

`KeybindingCaptureHost` is the near half: a zero-sized, non-interactive `UIView` that holds first
responder while one row is armed. It is deliberately not a `UIKeyInput`, so arming a row does not
raise the software keyboard over the list, and it passes nothing on down the chain — a chain that saw
Esc would dismiss the sheet the user was recording in. `PhoneKey.Press.init(_ key: UIKey)` moved out
of `TerminalInputHost` on the way, because two views reading a `UIKey` is exactly where a second
answer to "which key is this" would actually have appeared.

Then the flag died. With Key Bindings reachable, `is_mac_only` was true of nothing — so it is gone
from the Rust section table, from the boundary (`slopdesk_settings_section_is_mac_only`), from the
header, from `SettingsCatalog.Section`, and with it `compactSections` and `SettingsSection.compact`.
The phone's sheet lists `SettingsSection.ordered`, the same eight the Mac's navigator does. What still
differs by half is the GROUPS inside a page, which the layout table gates as data and per row — the
distinction increment 19 drew, now with nothing on the other side of it.

One user-visible lie went with it: the phone's editor header has always read "Click a shortcut to
record a replacement; Backspace clears it, Esc cancels." It is true now.


### Increment 31 — the video flags stop being a surface

`Control::Bespoke`'s doc says the hatch is for a group that is not a list of settings at all, and
warns in as many words that reaching for it to avoid describing a plain control puts the row's words
back in a view. `video-host` was a list of six settings. It held four section titles, six labels,
four ranges, five defaults, a pacer picker and a symmetric-FEC warning — all of them literals in a
SwiftUI body, none of them reachable from the all-settings index. A reader searching Settings for
`FEC`, or for `sharpen`, matched nothing at all.

The reason the table gave for the hatch was real and the conclusion did not follow. A
`VideoPreferences` field is an OPTIONAL, and unset is a state the described controls have no shape
for — so the surface had drawn a leading "Set" switch beside every field and the word `default` where
the value would be. But what unset MEANS is "the value the daemon would have picked anyway", which is
a default, and a row that reads its default through a named constant is what the two sidecar-backed
agent flags have done since they were described. `VideoPreferences` now names all six
(`qpSharpDefault` … `pacerDefault`) beside `AgentPreferences`' pair, the bindings read through them,
and an untouched field still writes nothing — the sidecar carries a value only once someone sets one,
so a fresh install's env overlay is empty exactly as before.

What the table gained is the shape of the thing: three new `Stepper` ranges (the QP band, the two FEC
counts), one new `Ladder` with stops (`Off` · `0.5x` · `1x` · `2x`), one new option `Group` for the
pacer, six rows in `settings_rows`, and the FEC warning as a `Control::Note` — which is what that
control is for and what the hand-placed triangle-and-`HStack` had been standing in for.

The split fell out of it. The five host flags are folded into `video-prefs.json` and read by hostd at
launch, so a phone editing one would write a file nothing on that device opens; `video-sharpen` is
`MetalVideoRenderer`'s own unsharp pass, in the client, on whichever device is doing the looking — and
a phone screen at a 1x stream is precisely where it earns its keep. So the first three groups are
`Platform::Mac` and the fourth is `Platform::Both`, which is one more setting the phone reaches than
it did, and `only_the_client_side_video_row_reaches_the_phone` asserts it per KEY rather than per
group, so moving a row between groups cannot quietly move it between platforms.


### Increment 32 — the menu bar goes home, and the port's leftovers go

Four types in the two UI targets had no caller left, and all four are the same kind of leftover: the
AppKit port replaced the surface that mounted them and nobody swept up behind it.

`SlateCompactIsland` was the chip a selected tab is stamped out of, with `SlateMorphScope` and
`AnyTransition.plateIgnite` — a `matchedGeometryEffect` plate that travelled between chips inside one
project island. Both tab surfaces that mounted it are AppKit now (`MacSidebarRow`, `MacPanelTabGroup`),
and the AppKit one opens the plate from `Slate.Anim.plateIgniteScale` directly. The RULE was never in
the view; it is the token, and the token is in `SlopDeskSlate` where both halves reach it — so deleting
three SwiftUI types cost the design nothing and retired two of the three `matchedGeometryEffect` morphs
the motion ledger still listed.

`SidebarScrollCapturer` was an `NSViewRepresentable` mounted inside the SwiftUI navigator's scroll view
to hand the drag coordinator an `NSScrollView` for edge auto-scroll. `MacNavigatorColumn` sets
`paneDrag.sidebarScrollProvider` from the scroll view it owns, so the representable had been dead since
the navigator crossed — and the auto-scroll it fed is live, which is the only reason deleting it is safe
rather than a silent feature loss.

`MacActionRadios` was the first-launch step's vertical radio group, on the reasoning that a step is one
question with a whole card to ask it in. The steps draw differently now; the pop-up and the segments
beside it still have callers, and this one did not.

`WorkspaceCommands` moved rather than died. A menu bar is macOS's, it names no view from the draining
floor (only `WorkspaceBindingRegistry` and SwiftUI), and the whole-file `#if os(macOS)` it wore in
`SlopDeskClientUI` was the tell — docs/56 §3 says a gate that spans a whole file is a file in the wrong
target. In `SlopDeskMacUI` the gate is the target, so the file has none, and `package` came off three
declarations that only ever had it to cross a boundary that is now internal.


### Increment 33 — the paste confirmation's words move to Rust, its alert moves to AppKit

`PasteProtectionSheet` wore the same whole-file `#if os(macOS)` that increment 32's `WorkspaceCommands`
did, and for the same reason: an `NSAlert` is macOS's. It moves to `SlopDeskMacUI/Terminal`, where the
gate is the target.

**Its caller is not under `Sources/`.** `ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift`
is the libghostty embedder, added to the two Xcode app targets by `enable-macos-renderer.sh` /
`enable-ios-renderer.sh` and compiled by neither `swift build` nor `make quick`'s macOS half. It is
where `PasteSafetyAnalyzer`, `PastePrecheck`, `ClipboardWritePolicy`, `RightClickPasteInterceptPolicy`
and `PasteTransform` are all reached from — so a grep over `Sources/` reports that whole cluster as
dead, and it is not. Anything moved or renamed here is verified by hand:
`bash scripts/enable-macos-renderer.sh && xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj
-scheme ClientApp-macOS -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`, then
`git checkout -- Apps/ClientApp-macOS/project.yml && xcodegen generate --spec Apps/ClientApp-macOS/project.yml`.

What is new is what did NOT move with it. The sheet was carrying four sentences of its own — three
headings, two OSC-52 reasons, the "Paste Anyway" button — plus a 28-line preview renderer that capped
the payload and rewrote its control characters in caret notation. None of that is AppKit. All of it is
now `slopdesk_terminal::paste`, beside the four dangers it describes: `Ask` (heading / button /
reason), `descriptions` (one line per flagged bit, derived from the same four constants) and `preview`
(the cap and the caret notation). The sheet is 139 lines down to 86, and none of the remainder is a
decision or a sentence.

The reason to move COPY, not just logic, is that here the copy IS the guard. A danger the mask can trip
and no sentence names renders as a blank bullet — a warning that looks like a rendering bug. Deriving
the lines from the same four bit constants in one file makes that unrepresentable, and
`every_danger_the_mask_can_trip_has_a_sentence` asserts it. `check-supervisor` pins both halves: the
crate must keep `Ask` / `descriptions` / `preview`, and the sheet may not spell a heading, a button
title or a preview cap of its own.

The preview's caret notation earns its own test either way. A preview that rendered the payload raw
would let the escape sequence the user is being warned about run inside the warning itself, which is
the one bug in this cluster that a reviewer cannot see by reading the dialog.

Two private copies of the `(out, cap)` retry reader collapsed on the way past — `AllSettingsCatalog`'s
and `SettingsCatalog`'s were the same ten lines, and the paste face would have been a third. It is
`wsDelivered(capacity:_:)` in `SlopDeskWorkspaceModel` now, beside `wsTransform`, and each face names
only how much of an answer it expects to fit inline.


### Increment 34 — a file called SettingsView that had not held a SettingsView since increment 24

`SettingsView.swift` was 1229 lines and declared no `SettingsView`. Increment 24 deleted that type with
the SwiftUI settings scene and left the file named for it; nine increments later it had become a grab
bag — the taxonomy enum, the section dispatch, a timing chip, a system-permission row, eight page
structs, an agent-card state derivation and an `EnvironmentValues` slot. Nothing in it was wrong. It
was just five things wearing one name, and the name was a tenth thing that no longer existed.

It is five files now, each named for what it holds: `SettingsTaxonomy.swift` (the `SettingsSection`
dispatch key), `NotificationPermissionRow.swift` (a settings ROW that edits no setting — it shows the
state of an OS grant, which is why it was never an arm of the Shell page's switch),
`AgentSettingsCard.swift` (the two `nil`-controller answers plus the environment slot that feeds them,
reader and writer together), the timing chip folded into `SettingsControls.swift` beside the
`timingFooter` that was already placing it, and `SettingsPages.swift` — the eight page structs.

`SettingsSectionContent` stayed WITH the pages rather than with the taxonomy, which is the one part
of this that is a decision rather than a move. It is the only door to eight `private` structs; putting
it in the taxonomy file meant widening all eight to `internal` to keep one caller compiling, and a
file split that trades encapsulation for tidiness is not a split worth making.

**The rewrite that was considered and rejected.** The Mac half renders all eight sections generically
— `MacSettingsPage` walks `settings_layout` and names no section, no group, no row, in 236 lines over
a 427-line `MacSettingsBindings`. The phone spends 1046 hand-written lines on the same eight pages, so
collapsing it into one table-walker looks like the obvious next move. It is not, for two reasons, both
measured rather than assumed:

- `MacSettingsBindings`'s own header already ruled on it: a shared accessor has to be closures over
  `Defaults[...]`, and a closure read is invisible to SwiftUI's dependency tracking, so a page built
  over one stops redrawing when a value changes under it. `@Default` is a property wrapper precisely
  because that observation is the point. The reason has not expired.
- The suspicion that the hand-written half was silently missing rows did not survive a count. The
  table lists 76 rows for the phone; every one of them has an arm. There is no coverage gap to fix,
  and the AppKit half needs 962 lines to be generic where the phone needs 1046 to be explicit — so
  there is no size win either.

What the duplication actually costs is the STORAGE MAPPING, twice. Every word, every option list,
every group and every platform gate is still read from the one table.


### Increment 35 — the phone gets the file drop it was never actually barred from

`GuiLeafView`'s drag-drop upload — a file dropped on a live desktop pane, sent over the dedicated
PATH-4 connection — was `#if os(macOS)` across three sites: the hover `@State`, the `.dropDestination`
plus its highlight and progress overlay, and the two helpers behind them. Nothing in that path is
macOS's. `FileUploadCoordinator` is Foundation over the Network-backed `FileTransferClient`;
`.dropDestination(for: URL.self)` is SwiftUI's on both platforms; `FileDropHighlight` and
`FileUploadOverlay` are plain SwiftUI in the same file. `PaneDropReceiver` — the terminal pane's
drop — was never gated at all, which is what made this one look like the odd one out rather than a
platform rule.

The one thing that genuinely differs is the GRANT. A URL dropped on iOS arrives security-scoped: it
names a file the app may read only between `startAccessingSecurityScopedResource()` and its stop, and
the upload's read spans the whole transfer rather than one call. So the scope is taken in
`FileUploadCoordinator`, inside the Task that already outlives the drop callback — and taken
UNCONDITIONALLY, because the API answers `false` for a URL that needs no grant. The stop is balanced
against that answer rather than against the platform, which is why this needed no gate of its own.

What is left is a device difference, not a platform one: an iPhone has no cross-app drag, so the
destination never lights there; an iPad has, and now uploads. `GuiLeafView` is down from 13 gates to
10, and the three that went were the only ones in it that were a MISSING FEATURE rather than a thing
the platform cannot do. The remaining ten are immersive system-key capture (nine — a `CGEventTap`,
which iOS has no equivalent of and no way to intercept the Home gesture with) and detach-into-window.


### Increment 36 — a whole-file `#if os(macOS)`, taken at its word

§3 calls a whole-file `#if os(macOS)` in `SlopDeskClientUI` the tell that the file is in the wrong
target. `Chrome/RailStatusRollup.swift` was one: 387 lines under a single gate, and the only callers
were `MacWorkspaceRootView`, `MacTitlebarBand` and `MacNavigatorColumn`.

The question worth asking before moving it was the increment-35 question — is this a MISSING FEATURE
on the phone or a genuine platform difference? Here it is neither, and that third answer is the one
that decides the destination. The cluster hangs off the TITLEBAR: beside the traffic lights, on the
sidebar toggle's band, parked against the navigator column's gutter, sliding to the toggle when the
column collapses. Every one of those is a window's furniture. What it WRAPS — walk to whatever agent
is waiting — is `WorkspaceStore.jumpToOldestAttentionPane()`, which both shells already reach through
the `.jumpToAttention` binding. Same capability, laid out for a window, which is exactly the split
the two shells exist for. So it moved to `SlopDeskMacUI` rather than being copied to the phone.

Three things moved with it, and one had to widen:

  * `RailStatusRollupTests` → `SlopDeskMacUITests`. It lost its own `#if os(macOS)` in the process —
    the gate was only there because the target it sat in also compiles for a phone.
  * The pixel probe → `Tests/SlopDeskMacUITests/MacRailStatusRollupRender.swift`, a rig of its own
    rather than a section of `MacChromeSnapshotRender`. That one photographs real `NSView`s through
    `CALayer.render(in:)`; every part of this frame is pure SwiftUI, and the hosted path composites
    through a window whose backing greys the authored cream — which would make the one thing the
    image exists to judge, the ground the marks stand on, a lie. *(Both halves of that reasoning
    expired in increment 46: the marks became `NSView`s, which `ImageRenderer` cannot draw at all,
    and the cream is authored on the recipe's ground view rather than taken from the backing. The rig
    is a `MacChromeSnapshotRender` now.)*
  * `StatusDotView` went `internal` → `package`. It is the SwiftUI half of the shared mark and the
    band is still hosted SwiftUI, so the alternative was a second drawing of the same
    `StatusDotStyle` — the one-implementation rule, at the level of a mark. The widening carries its
    own expiry in its doc comment: when the cluster becomes `MacStatusMarkView`s it goes back to
    `internal`. A widened access level that outlives its caller reads exactly like one that still
    has it, which is the same failure mode as a stale platform gate. *(Collected in increment 46, on
    time.)*

`MacTitlebarBand` dropped `import SlopDeskClientUI` entirely — the rollup mount was the only thing it
took from there. `SlopDeskMacUITests` gained `SFSafeSymbols`: the probe
draws the toggle and the search plate as footprints, and both are named glyphs.


### Increment 37 — the cancel key, spelled once

Four shared surfaces — `ViModeOverlay`, `HintModeOverlay`, `TerminalFindBar`, `CommandNavigatorView`
— each carried the same five-line gate: `.onExitCommand` on macOS, `.onKeyPress(.escape, phases:
.down)` everywhere else. Three of them also carried their own paragraph explaining it.

This one does NOT collapse into a shared API, and the census is worth stating precisely because the
two halves LOOK interchangeable: macOS routes Esc through the responder chain (`cancelOperation(_:)`,
which AppKit also sends for ⌘.), so `.onExitCommand` fires from anywhere below the view; iOS has no
`cancelOperation`, and `.onKeyPress` needs the view or a descendant to hold keyboard focus. The
narrower half is the only half iOS has. That difference is exactly what these surfaces depend on —
their primary exit is the terminal renderer's own `keyDown`, and the modifier is the net for an Esc
that lands in the overlay's chain instead.

So the gate stays and moves: `View.slateCancelKey(perform:)` in the design system, one `#if`, one
paragraph. 4 gates → 1, and the day SwiftUI unifies the two there is one place to change.

The three phone-only cards (`PaletteView`, `OpenQuicklyView`, `GlobalSearchView`) deliberately do NOT
adopt it and now say so in a comment that names the modifier: their Mac counterparts are
`MacOverlayPanel` windows taking Esc in AppKit proper, so the SwiftUI card only ever runs on the
phone and has no second half to carry. A reader converting them "for consistency" would be adding a
macOS branch to a view macOS never mounts.

`SlopDeskClientUI` is now at 53 `#if os(macOS)` across 22 files.


### Increment 38 — a palette verb declares its platform, in Rust

Increment 35's lens found a feature the phone was denied. This one found the opposite failure, in the
one surface whose whole job is to say what the app can do: three verbs the phone was OFFERED and
could not run.

  * **Pin Window** — routed to `OverlayCoordinator.togglePinWindow`, which defaults to an empty
    closure and which no phone root binds.
  * **Detach Pane into Window** — a `.store` row whose run arm was `#if os(macOS) store.detachActivePane() #else _ = store #endif`.
  * **Reattach All Panes** — runs, but folds back a set that on a shell which cannot detach is always
    empty.

None of the palette's existing suites could see this, and the reason is structural: every actuator on
the coordinator defaults to an empty closure, so **a row that is listed and inert is
indistinguishable, at the keystroke, from a row that ran and had nothing to do** — and every one of
those suites runs on a Mac, where all three are real. `check-supervisor.sh` already carried the rule
in words ("an action that is absent on a platform is fine; an action that is listed and inert is
not") and ratcheted three coordinator hooks by name, but a rule that has to name its instances only
ever catches the instances someone thought of. `togglePinWindow` was excused there on the grounds
that "the palette row itself records" being a macOS no-op — and a comment recording it is not the row
being absent.

So the platform became a FIELD, exactly as it is on a settings group: `rust/slopdesk-workspace/src/palette_rows.rs`,
reusing `settings_layout::Platform` rather than respelling it. `ActionsPaletteSource.catalog` is now
`declared.filter { PaletteRowPlatform.lists($0.id) }`, and the `#if` inside `detachPane`'s run arm is
gone — a row whose platform is data has no business branching on one.

Three things make it hold:

  * **The far side fails OPEN.** An id the table does not declare is LISTED. Failing closed would let
    a typo delete a verb in exactly the silence this module exists to end.
  * **The supervisor closes it instead** — the Swift catalog's `action.*` ids and the Rust table's
    must be the same set, in both directions, and no `#if os(` may reappear in the catalog.
  * **The table takes `mac` as an argument**, not `cfg!`. That is what lets a Mac test ask what the
    PHONE lists, which is the only place the answer was ever interesting. `PaletteRowPlatformTests`
    asks it four ways, including that nothing OTHER than the three window verbs is withheld from
    either half — a phone is not a reduced product.

**Half done, deliberately.** The same three verbs are still listed by the binding registry, which
drives the cheat sheet and the keybindings editor, and `WorkspaceBindingRouting`'s `.detachPane` arm
still carries its own `#if`. That is 78 rows in a different id space (`pane.detach`, `view.pinWindow`)
and it gets its own table and its own increment; the routing gate stays until then, because until the
registry declares platforms it is the only thing stopping a rebound chord from stranding a pane.

### Increment 39 — the other half of it: a keybinding names its platform too

The other half of increment 38, and the half that mattered more. The registry the palette mirrors is
not one surface: it is the cheat sheet, the keybindings editor, the `ctl` verb list, and — the part
that made this more than a list that lies — `chordTable`, which the keyboard dispatcher resolves
against. **A bound chord does not reach the terminal.** So on the phone ⌥⌘P was taken away from the
PTY in order to run `case .detachPane: #if os(macOS) … #endif`, an arm with nothing in its else, and
the keybindings editor offered to rebind a chord onto an action that half cannot perform. Dropping
the row drops the chord, and the key falls through to the pane the way an unbound chord should.

`rust/slopdesk-workspace/src/binding_rows.rs` is the same shape as `palette_rows.rs` — 77 rows over
`settings_layout::Platform`, three of them `Mac` — and `WorkspaceBindingRegistry.bindings` is now
`declared.filter { BindingRowPlatform.lists($0.id) }`, with the raw array private for the same reason
the palette's is: a caller who wanted it would be asking for the rows this half cannot run.

**A SECOND table, not one shared with the palette.** They are two id spaces over two vocabularies
with partial overlap in both directions: this verb is `pane.detach` here and `action.detachPane`
there, ~45 rows here have no palette entry at all (every focus move, every resize nudge, every scroll
jump), and the palette has rows the registry does not (`action.connect`, `action.copyPath`). One
table keyed by either spelling could not answer for the other's rows; one keyed by both would be a
join maintained by hand. Two complete tables, each pinned to its own Swift list, is what makes "a new
verb declares a platform" true on both sides rather than on whichever side someone remembered — and
`binding_rows::tests::the_two_tables_withhold_the_same_feature` is the one place both are in scope,
so the two spellings of one feature cannot drift apart.

The filter is on the REGISTRY, not on each display surface, precisely because `chordTable` is one of
the readers. `BindingRowPlatformTests` pins that consequence directly: on a phone build there is no
`pane.detach` row and no chord anywhere in the table resolving to `.detachPane`.

The nine generated `pane.select.N` slots are minted by a loop and are deliberately **undeclared** —
they are `Both`, and the table declares the one collapsed representative (`pane.selectN`) the cheat
sheet shows in their place. The supervisor's id-set pin excludes that family by name rather than by
a grep that quietly fails to match it, and the routing gate is gone: `check-supervisor.sh` now fails
on any `#if os(` in either the registry or its routing.

### Increment 40 — one CGEventTap gate instead of seven, and the pane's last gate is data

`GuiLeafView` carried **ten** `#if os(macOS)` blocks, and nine of them were one feature: immersive
system-key capture. The tap itself is a genuine platform impossibility — `CGEvent.tapCreate` has no
iOS counterpart and will not get one — so §3 says keep the gate. What §3 also says is that such a
gate must be spelled **exactly once**, the way `Image.decoded(_:)` names `NSImage`/`UIImage` once for
the whole client and `View.slateCancelKey(perform:)` names the two cancel keys once for every
overlay. Immersive capture is a LIFECYCLE rather than a call — engage on mount, suspend on focus and
injectability edges, re-engage from the model's remembered wish, tear down on unmount, plus a toggle
with four outcomes — so left at the call site it was a stored property, three view modifiers, a
computed read, a toggle body and two private helpers, each an invisible empty `#else`.

`Sources/SlopDeskClientCore/Input/PaneImmersiveCapture.swift` is that one place: a macOS half that is a
thin policy layer over `SystemKeyCaptureController`, and a phone half where every method is a no-op.
The pane holds one and branches on nothing.

**A no-op twin is only safe when the affordance disappears with it.** A toggle drawn where the tap
does nothing is exactly the listed-and-inert defect increments 38 and 39 closed, so the footer reads
`PaneImmersiveCapture.isSupported` — capability as data — rather than carrying its own gate for the
chip and again for the mode-group's "does this group have anything to show".

The tenth gate was the detach ⇄ reattach button, and it is now `BindingRowPlatform.lists("pane.detach")`.
That button is the FOURTH surface for one verb, after the palette row, the chord and the keybindings
editor; reading the same declaration the other three read is what stops a fourth answer from drifting.
`BindingRowPlatform` went `public` for exactly that caller, and says so.

`GuiLeafView`: **10 gates → 0.** `SystemKeyCaptureController` keeps its whole-file `#if os(macOS)`.

> **Amended, increment 54.** The paragraph that stood here said the controller had to stay in the
> draining floor because it "cannot ascend to `SlopDeskMacUI` before its only caller does". That is
> true and it was the trap: it only ever considered ASCENDING. A `CGEvent` tap draws nothing, so the
> direction was never up — the controller and the `PaneImmersiveCapture` seam both **descended** to
> `SlopDeskClientCore/Input/`, beside `SystemKeyCapturePolicy`, the seam that made the tap testable in
> the first place. §3's rule is directional in both senses: an actuator that draws nothing belongs
> with the logic it actuates for, whichever way that is.

### Increment 41 — the drag block: fourteen spellings of two facts

The canvas drag block (`PaneDragCoordinator`, `SplitContainer`, `PaneMoveAffordance`, `PaneDivider`)
carried **14** platform gates. Censused against §3's three buckets, every one of them was (b) — a
genuine impossibility — and the defect was not that they existed but that two facts were spelled
fourteen times.

**The classification that had to be checked rather than assumed.** `.pointerStyle` looked like an
iPad gap worth closing: iOS 18 added pointer APIs and this project targets iOS 26. The SDK says
otherwise — `iPhoneOS26.5.sdk/…/SwiftUI.swiftinterface:20442` marks `struct PointerStyle`
`@available(iOS, unavailable)`, every member likewise, and no `pointerStyle(_:)` modifier exists on
the iOS triple at all. A gate that survives a real check is worth more than one nobody questioned.

Two facts, now spelled once each:

  * **`PanePointer` + `View.panePointer(_:)`** — the cursor. In the `SlateCancelKey` register: a plain
    enum both halves can name, one `#if` inside one function. It took the *decision* out of the gate
    with it — "a seam at its min-weight floor shows the one-way arrow, a dead seam keeps the two-way
    glyph" was compiled on macOS only, i.e. a rule half the readers never saw. `PaneDivider` is now at
    **zero** gates: only the drawing is platform-shaped, and the rule is plain Swift.
  * **One region in `PaneDragCoordinator`** with three seams — `platformCursorLocation()`,
    `platformDragFrame(at:drag:)`, `platformDragEnded()`. `update`, `end` and `updateDetachedDrag`
    now read identically on both halves; the macOS stored properties moved down beside the seams they
    serve. The file header states the gate budget so a fourth reads as a regression.

`PaneMoveEscapeMonitor` became a two-half type whose phone side mounts and does nothing — a SINK
(§3.5), not a second implementation. **This is a real capability gap and is recorded as one:** the
Mac's half is a local `NSEvent` monitor precisely *because* the drag holds no first responder, so
`.onKeyPress(.escape)` cannot substitute. Escape-to-cancel on iPad needs a `UIPress` responder over
the canvas — a feature, not a gate fix. *(Paid in increment 44, which is exactly that responder.)*

**14 gates → 6.** `PaneDragCoordinator` 7→3, `SplitContainer` 3→1, `PaneDivider` 2→0,
`PaneMoveAffordance` 2→2 while absorbing three from the other two files.

#### Why the coordinator still cannot ascend

`DropTargetFrameReader` has exactly **one** consumer left (`SplitContainer.swift:96`) — the other
three drop targets already register from AppKit (`MacNavigatorColumn` for `.sidebarList` and
`.newTabZone`, `MacSidebarRow` for `.sidebarRow`), so the representable is a leftover from before the
navigator crossed. But it cannot simply move: it is mounted as the background of `SplitContainer`'s
`GeometryReader`, i.e. the COMPOSITOR rect, and the hosting view's frame is not that rect —
`ContentColumn` applies `slateIsland(clearingBand:)`'s moat and then the panel-rail padding. An
AppKit-side registration would be off by the island moat, and off by a *different, animating* amount
during a collapse. Either `SplitContainer` is ported whole, or the moat moves out of SwiftUI into the
AppKit column so the hosting view's frame IS the canvas.

One of the three type anchors was free and is gone: `NavigatorColumn.swift` declared
`var paneDrag: PaneDragCoordinator?` that nothing in the file ever read, and no call site ever passed
— a property whose doc comment promised sidebar rows as drop targets on a half that never made them
one. Same class as increment 14. Two anchors remain (`ContentColumn`, `SplitContainer`), and both are
live.

### Increment 42 — the code sidebar's keyboard duel goes up where it belongs

Increment 13 left the pool's Mac keyboard machine "walled off at the bottom of the class behind the
only `#if` that survives", and called that good enough. It was not: §3 says a platform gate inside a
shared file means the FILE is in the wrong target, and this was two hundred lines of it. The pool's
subject is projects and their warm pages — one law on both halves. Key windows, responder chains and
`makeFirstResponder` are one platform's window machinery and no law at all on the other.

`Sources/SlopDeskMacUI/CodeSidebar/MacCodeSidebarKeyboard.swift` now holds the duel: the key-window
observers, `sidebarFocusMemory`, `lastKeyboardOwner`, the resign classification, the remount hand-back,
the ⌥⌘R toggle, the orphan repair, `holdsFirstResponder`. The pool keeps a `keyboard` seam that is
simply **nil on the phone** rather than an empty branch, and `CodeSidebarWKWebView` reports its three
responder moments through it.

**Installation, without editing a wiring file.** `SlopDeskMacUI` sits above `SlopDeskClientUI`, so
nothing in the pool can construct the duel — it has to be installed from above. Rather than add a
line to `SlopDeskMacApp`, `activeTabID` moved into the MacUI extension as a computed property
forwarding to `MacCodeSidebarKeyboard.shared`, so the composition line that was already there
(`SlopDeskMacApp.swift:296`) is verbatim what brings the duel up. Every other Mac entry point touches
`shared` too, so no single call site is load-bearing.

**One deliberate behaviour delta, strictly safer:** the window observers used to arm on the first
`CodeSidebarWebViewPool.shared` access and now arm at app composition, which is earlier — an observer
armed before there is a window has nothing to do. The side benefit is that headless ClientUI tests
touching the pool register no AppKit notification observers at all.

**8 gates → 2.** The survivors are the import (a pooled page is an `NSView` here and a `UIView`
there; `NSAppearance` and `UIColor.clear` have no neutral spelling) and the MINT — subclass-vs-plain,
chrome polarity, base-canvas kill, which were three gates for three decisions and are now one `#if`
for all three. That last one could reach zero by moving mint-and-dress into `CodeSidebarWebView.swift`,
which is already two per-platform halves; it was left alone because it changes the pool's documented
subject, and this increment's subject was the duel.

Eight `internal` → `package` widenings in `CodeSidebarFocusPolicy` pay for the move, each for the one
caller that crossed. `CodeSidebarFocusPolicyTests` is unchanged — `@testable` never cared.

### Increment 43 — the pool takes the last two gates off, and neither was a choice

Increment 42 left the pool at two gates and named the way out of both in the same breath. This is
that follow-up, and it moved the mint SIDEWAYS rather than up: `CodeSidebarWebView.swift` already
compiles as two per-platform halves, so a decision that genuinely differs per platform costs it no
seam it did not already have — while the same decision inside the pool is a `#if` in the middle of a
law with no platform in it.

`CodeSidebarPageMint` is an ungated `@MainActor enum` with one `private static func finish` (the
`isInspectable` and `underPageBackgroundColor` tail, one spelling for both) and one
`page(projectRoot:configuration:)` declared inside each existing half. The pool builds the
`WKWebViewConfiguration` — the faces, the five user scripts, the clipboard bridge, every one of them
platform-blind — and takes back a dressed page **whose class it never learns**. The three decisions
the mint makes (subclass-vs-plain, chrome polarity, base-canvas kill) are now stated once, in the
file's header, and each half below only spells them.

The AppKit/UIKit import went with it, which was the surprise. The pool still touches exactly one
platform member — `window`, in `protectedProjectRoots()` and `mountedPage()` — and it needs no import
to: `window` is inherited from `NSView` here and `UIView` there, and WebKit already brings its own
superclass's framework into scope. That is not a trick. It is the fact the pool's whole design rests
on, that `WKWebView` IS the platform's view type on both halves.

**2 gates → 0, and it is pinned that way.** The pool is the first file in the code-sidebar cluster to
carry no `#if os(` at all, which is stronger than the four-file whole-file-gate ban above it and gets
its own ratchet in `scripts/check-supervisor.sh`. The failure message says what a new gate would mean
rather than how to spell it away: whatever it guards belongs in `MacCodeSidebarKeyboard.swift` (up)
or `CodeSidebarWebView.swift` (sideways), because those are the two files that already have halves.

This is also the first entry on the ledger below — **kind 2**, the pool going *down* below both
halves, needs no AppKit rewrite and removes three of the thirteen imports. It could not start while
the file named a platform framework. Now it can.

### Increment 44 — the iPad gets its escape-to-cancel, which increment 41 recorded as owed

Increment 41 turned `PaneMoveEscapeMonitor` into a two-half type and wrote its phone side as a SINK —
correctly labelled at the time as a real capability gap rather than a gate, with the mechanism it
would need named on the spot. §3's rule is that layout diverges and capability does not, so a sink
that stays a sink is a debt, not a design. This pays it.

`PaneMoveEscapeResponder` is the phone's half: a zero-sized, touch-transparent `UIViewRepresentable`
that takes first responder for exactly as long as the drag is in flight, and reads Esc off
`pressesBegan`. The two halves are ONE implementation of one behaviour — neither knows what
cancelling means, and the single mount in `SplitContainer` (which carries no gate) supplies the
closure both call. What differs is only the mechanism, and it differs because it must: UIKit has no
local event monitor, and `slateCancelKey`'s `.onKeyPress(.escape)` wants keyboard focus, which is
precisely what a `DragGesture` never takes.

Three things the shape had to answer for, and does:

  * **What arms the grab.** The drag, edge-triggered — *and* a hardware keyboard being attached
    (`GCKeyboard.coalesced`, read at arm time so a keyboard paired after launch is seen). That gate
    is not politeness. `TerminalInputHostView` is a `UIKeyInput`, so taking first responder off it
    dismisses the software keyboard, whose animation makes SwiftUI's keyboard avoidance re-lay the
    canvas out *under the moving finger*. A user with no hardware keyboard has no Esc to press and
    loses nothing by the view staying inert.
  * **What the keyboard is handed back to.** Whoever held it, remembered weakly, restored by
    identity, and **only if this view still actually holds it** — a spring-loaded tab reveal can move
    first responder through `PaneFocusCoordinator` mid-drag, and forcing the remembered owner back
    then would take the keyboard off the pane the user just landed on. Same shape as
    `MacCodeSidebarKeyboard`'s `lastKeyboardOwner`, with the one difference UIKit forces: AppKit
    publishes `window.firstResponder` and UIKit does not, so the outgoing owner is found by walking
    the window for `isFirstResponder`, once per drag.
  * **Which key it is.** By HID usage, through `PhoneKey.Press.init(_ key: UIKey)` — the module's one
    `UIKey` reader, now shared by three views instead of two. A press identified by the character it
    committed is the defect that cost the phone its whole nav block (`docs/29` #7). Modifiers are
    deliberately not consulted, which is the Mac's rule too, so ⌘Esc and ⌥Esc bail out on both.

**One delta, stated rather than hidden.** The Mac's monitor swallows Esc and returns every other key
untouched, so typing during a drag still reaches the terminal. Here the keyboard is the drag's for
its whole duration: a non-cancel press goes on down this view's chain, which is the canvas's SIBLING
and not the terminal's ancestor, so it reaches nothing. That is the price of the only mechanism iOS
offers, it is bounded by the length of a held gesture, and it is the same trade
`KeybindingCaptureView` makes while a row records.

Gate count is unchanged (the fact was already spelled once, around the type). What changed is that
both halves are now real.

### Increment 45 — the pool goes down, and takes the page with it

The first item off the ledger below, and the first Stage D move that deletes MacUI imports rather
than rewriting a surface. `CodeSidebarWebViewPool`, `CodeSidebarFocusPolicy` and the page itself now
live in `SlopDeskClientCore`, below both UI halves.

**What made it possible was increment 43, and what nearly stopped it was one line of colour.** The
mint had to travel with the pool — the pool calls it — and the mint set `underPageBackgroundColor`
from `Slate.theme`. `SlopDeskSlate` *depends on* `SlopDeskClientCore`, so reading a token from down
there is a dependency cycle, not a widening. The line did not have to travel, though: both mounts
already re-apply that colour on the very update that creates the page, and they must, because a
pooled page outlives a theme switch and a creation-time snapshot flashes the old tone on a scroll
bounce. The mount's write was never redundant with the mint's — it **outranked** it, and the mint's
was the redundant one. Deleting it left the mint reading no design token at all.

**A page is not a view, which is the ruling this increment rests on.** `WKWebView` *is* the
platform's view class, so `CodeSidebarPage.swift` has `#if os(macOS)` / AppKit / UIKit in it and
belongs below the split anyway: nothing in it lays anything out, reads a token, or names a
`some View`. ClientCore already imports AppKit or UIKit in five files. What stayed up in
`SlopDeskClientUI` is the MOUNT — a clipping container and one representable per half — which is
exactly the part that does lay out, and does read a token.

| Went down to `SlopDeskClientCore` | Why it could |
| --- | --- |
| `CodeSidebarWebViewPool` (410) | a resource manager: projects, warm pages, an LRU |
| `CodeSidebarFocusPolicy` (+ its tests) | pure decisions, `canImport(AppKit)` only |
| the mint + `CodeSidebarWKWebView` → `CodeSidebarPage` | a page is a view CLASS, not a drawn surface |

Five `internal` → `package` widenings pay for it (`webView(for:url:)`, `noteRemount`, `loadState`,
`CodeSidebarWebLoadState` and its `veiled`), each for the mount or the panel column that now reads it
from one target up. `ClientCore` still imports SwiftUI nowhere — the pool's `import SwiftUI` was
already dead and went with the move.

**Two of thirteen imports gone, not three.** The ledger below estimated three, counting the three
MacUI files that reach the pool. Only two of them reached it *alone* — `WorkspaceKeyDispatcher` and
`MacCodeSidebarKeyboard` — and both dropped `import SlopDeskClientUI` outright. `MacCodePanelColumn`
also takes `CodePanelSurfaces` and `SlopDeskMacApp` also takes the SwiftUI mounts, so both keep the
import with a narrowed comment. Eleven remain, and every one of them is now kind 1 or kind 3: what is
left is AppKit rewrites and the canvas.

The supervisor gains the other half of the pin: the pool file must not exist in `SlopDeskClientUI`
again, which is the ascent rather than the gate.

### Increment 45b — a second git-line renderer, kept alive by its own tests

Found while sweeping for what else was in the wrong place. `PaneGitSummary.compactLine` folded the
git counts into one flat string and had **zero** call sites anywhere — `Sources/`, `Tests/`,
`ThirdParty/`. The rail's git line is `SidebarGitLine.segments`, which emits per-segment ink instead
of a string, and the two disagreed: `~` for a conflict in the live one, `=` in the dead one. Twelve
assertions in `PaneGitSummaryTests` were the only thing compiling the wrong spelling. Renderer and
assertions deleted; the wire-fold tests, which are what every renderer reads, stay.

**Two other candidates from the same sweep were NOT dead, and the check that saved them is worth
recording.** `PasteTransform` and `TerminalContextMenu.Item` both look unreferenced from `Sources/`
— and both are live, built into a real `NSMenu` by
`ThirdParty/ghostty/integration/GhosttySurface/GhosttyTerminalView.swift`. The ghostty embedder's
Swift lives in `ThirdParty/`, not `Sources/`, so a `Sources/`-only grep reports the entire live
paste/clipboard cluster as dead. Any dead-code claim in this repo has to grep `ThirdParty/` too.

### Increment 46 — the band's marks cross, and the Mac stops drawing anything in SwiftUI

The first of the ledger's kind-1 surfaces, and the cheapest by design. `RailStatusRollup`'s three
status marks were hosted `StatusDotView`s — the last reason any `SlopDeskMacUI` file imported
`SlopDeskClientUI` for a *drawing*. They are `MacStatusMarkView`s now, in a `MacRailStatusMarksView`
cluster, and the import is gone. **11 → 10.**

`RailStatusMarks` stays a SwiftUI `View`, deliberately: its `markGap`, `width` and band-rung padding
are read from the SwiftUI side by `RailStatusRollupMount` and by `RailStatusRollupTests`. What
crossed is the cluster's *body*, as one `NSViewRepresentable`. The place stayed; the painting moved.
`style(for:active:)` and `label(for:)` remain the only source of both answers.

Everything the slot promised is preserved, and one thing is spelled better than it was. The hit box
is one `StatusDot.footprint` wide and the full rung tall; an unlit slot refuses `hitTest` outright,
which kills press, hover **and** its own tooltip in a single refusal, so the pointer falls through to
the cluster's summary tooltip — exactly what `.allowsHitTesting(false)` under an outer `.help` used
to achieve by stacking two rules.

**Two things were given up, and both are recorded rather than hidden:**

  * **The lit/unlit hue cross-fade** (`Slate.Anim.smallFade`). A SwiftUI animation cannot reach
    inside a representable, and the AppKit equivalent — a `CATransition` over the mark's layer —
    would ride every display-link tick of the working slot and smear it. The rows and the tab chips
    have always taken the straight step for these same marks, so the band now matches them. Getting
    it back needs an ink-interpolating property on `MacStatusMarkView`, not a layer transition.
  * **`ImageRenderer` in the pixel rig.** It draws nothing for an `NSViewRepresentable`, so the marks
    would have photographed as holes in a PNG that still got written — a snapshot that lies is worse
    than no snapshot. The rig moved to the `MacChromeSnapshotRender` recipe (an `NSHostingView` in a
    borderless `.aqua` window over a ground view painted `Slate.Native.Surface.field`, captured
    through `CALayer.render(in:)`), and its row stand-ins now use the shipping `MacStatusMarkView`.
    The old header's objection to hosting — that it greys the cream — was a property of that
    harness, not of hosting: the cream is authored on the ground view here.

**A stale comment, caught in passing.** `MacStatusMark`'s header named the collapsed-sidebar tab
strip as a remaining SwiftUI mark. It is not: `MacTabStrip.swift:326` had already crossed. After this
increment **no `SlopDeskMacUI` file uses `StatusDotView` at all.**

**And two widenings collected on time.** `StatusDotView` and `AgentSpinnerView` were `package` for
exactly one cross-target caller each, under comments promising `internal` again the moment that
caller crossed. It has, so they are — a widened access level that outlives its caller reads exactly
like one that still has it. Both are `internal` now, with one in-target caller apiece, and neither
expires: after the rename this target is the phone's, and a SwiftUI mark is what the phone should
have.

### Increment 47 — the checklist's two shared steps cross, and the words go down instead

The second kind-1 surface, and the first that could not be done by moving a drawing alone.
`MacFirstLaunchSheet` hosted `FirstLaunchStepSurface` for its two CROSS-PLATFORM steps — On-Launch
and the Claude-hooks install — and that host was the file's whole reason to import
`SlopDeskClientUI`. They are `MacOnLaunchCard` and `MacClaudeHooksCard` now, plain `NSStackView`s
beside the two macOS-only cards the sheet already drew. **10 → 9.**

`FirstLaunchStepSurface` STAYS, and is `private`. It is the phone's renderer, not a corpse: deleting
it is the mistake this workstream already made once. What it lost is the `package` its one
cross-target caller bought — collected on the schedule increment 46 set for `StatusDotView`.

**The expensive half of this increment was the lift, not the rewrite.** Unlike the band's marks —
where `style(for:active:)` was already the one source of the answer — the checklist's answers were
all inside the SwiftUI view, because there had only ever been one renderer to hold them. Two
renderers would have made every one of them a pair: the picker's two option labels, the four notes
and blurbs, the fold from six `InstallState`s to three control shapes, the rule that shows the
"connect a session" note, and the rule that an install landing `installedInactive` still TICKS the
step. They are `FirstLaunchStepPresentation` in `SlopDeskClientCore` now, and both halves read them.
The `nil`-controller fallback went down with them: `AgentSettingsCard.installState(_:)` forwards to
`FirstLaunchStepPresentation.hooksState(_:)` rather than spelling `?? .disconnected` a second time
where the Mac cannot reach it — that fallback exists because the iOS sheet once shipped a card
claiming an integration was installed, and it does not get to exist twice.

**One thing stayed with each drawing, and only because it must.** `SlopDeskSlate` DEPENDS on
`SlopDeskClientCore`, so an ink cannot descend to an answer without becoming a cycle. A badge names
its own silhouette — one SF-Symbol name both halves ask for — and each renderer spells the hue:
`Slate.StatusInk.ok` in SwiftUI, `Slate.Native.StatusInk.ok` in AppKit. The badge cases are two, so
that is two lines per half. A `Slate.hooksInk(_:)` pair beside `attentionInk(_:)` would collapse even
those, and is the only thing left owed here.

**A card inside a card, caught in passing.** The hosted bodies each wrapped themselves in a SwiftUI
`FirstLaunchCard` and then landed inside the sheet's own AppKit card — a hairline and a raised fill
drawn twice, one inset from the other, on exactly the two steps that were hosted. The AppKit bodies
are bare content; the sheet's chrome is the only chrome.

An `NSStackView` of radios needed one thing SwiftUI's `Picker` gave for free and AppKit does not:
`MacOnLaunchRadios` resolves a pick to an OPTION VALUE rather than a button index, because AppKit's
implicit radio grouping answers "whichever button is `.on`" and a third option would otherwise read
as the first. The picker has two options today. It is one line either way, and only one of them
stays right when a third arrives.

### Increment 48 — the git dialect goes to Rust, and only the writing stays

Not a UI crossing at all — the OTHER prong of the mandate, and it landed in the file the sidebar
header reads. `main ↑2 ↓1 +3 !4 ?5 ~1 $2` is a language: which runs a line has, in what order, what
each one means, the weight it is set at, and the ladder it sheds down as the column narrows. All of
that is `slopdesk_workspace::git_line` now, with `SidebarGitLine` in `SlopDeskClientCore` as the face
(docs/55 §4b — "a glyph is not text").

**What is left on this side is the writing, and the split is where a disagreement can live.** A run
crosses as a role, one GLYPH and a number. Putting `↑` next to `2` is not a decision anyone can
disagree with; choosing `↑` is. That distinction is not theoretical here: increment 45 deleted a
`PaneGitSummary.compactLine` that spelled a conflict `=` where the live renderer spelled it `~`, and
the two compiled side by side for as long as both existed. `scripts/check-supervisor.sh` now bans a
sigil literal in the face outright — a second dialect cannot be born without typing one of them.

**The one string this side supplies is the branch**, because the text is the caller's own. It is a
NAME, which is why it truncates rather than compacting, and why the rule carries only the one bit it
reads from it: whether there was a name at all. The word "detached" is a label like any other and
stays with the writing.

**Two API shapes changed, and both got smaller.** `compactStatus(shedding(status, to:))` was always
called as a pair and is one call now, because the rule folds both in one crossing — a caller holding
a half-shed line was never something the dialect meant to offer. And `MacGitLineView` holds the
SUMMARY rather than the spelled segments: the ladder folds from counts, so a view keeping only the
written form would have to hand a half-answer back to be re-read at a narrower width.

`SidebarGitLine.weight(_ role:)` is gone entirely. The rung rides along on the segment, filled in by
the same crossing that decided the run exists, so there is no second role→weight table on this side
to disagree with the one in Rust.

### Increment 49 — the bespoke settings surfaces, and four labels that had already drifted

The third kind-1 surface and the largest yet: `MacSettingsRows` hosted `SettingsBespokeSurface` for
every group the layout table marks `Control.bespoke(id)` — the reserved Editor page, the Claude-hooks
card, the notification-permission row, the live caret preview, the font specimen, the All-Settings
index, the Advanced groups. Those are `MacSettingsBespokeSurfaces`, `MacCursorPreviewSurface`,
`MacFontFamilySurface`, `MacAllSettingsIndex` and `MacAdvancedSurfaces` now. **9 → 8**, and the
Settings window no longer hosts a SwiftUI view anywhere.

**`Control.bespoke(id)` is the layout table admitting a group is not a list of settings**, so this
increment is the one where the words outnumber the widgets. Four faces went down: what the
cross-platform surfaces SAY and which control their state picks
(`SettingsBespokePresentation`, 462 lines), the index's wording and its option-group table
(`SettingsIndexPresentation`), the config file's resolved path and its two actions
(`SettingsConfigFile`), and the hex ↔ RGB bridge the two colour wells persist through
(`CursorColorHex`). The Mac's five surfaces read them, the phone's rewritten views read them, and
neither re-decides.

**The fold is smaller than "which widget", on purpose.** A renderer already knows the SHAPE of a
key's storage — it holds the binding — so what descends is the three things storage cannot say:
which OPTION GROUP a token picks from, which LADDER a number steps along, and which key is shown
read-only. The alternative was measured rather than imagined: `AllSettingsListView` spelled thirteen
option lists inline as `Text(…).tag(…)`, and **four had already drifted** from
`slopdesk_settings::settings_catalog`, which has held the same lists all along — "Context Menu" vs
"Context menu", "Copy or Paste" vs "Copy or paste", "Home" vs "Home Directory". Naming the group is
what makes a fourteenth list impossible to type. The scroll multiplier was the same shape in
numbers: its range, granularity and `%.2f×` readout are `Ladder::ScrollMultiplier`'s, and both halves
had re-typed all three at the control.

**The fourth drift was a third spelling, and it needed a fix rather than a lift.**
`FirstLaunchStepPresentation` had `OnLaunchBehavior.title` typed out — "Restore Last Session" — while
Settings → General read `ON_LAUNCH` and said "Restore session". Two names for one choice, on two
surfaces a reader sees within a minute of each other, and increment 47 had just finished making that
pair single-spelled *for the checklist*. `title` forwards to `SettingsCatalog.label(.onLaunch,)` now,
and the note under the picker interpolates it rather than repeating it — prose that names a choice
the picker above it spells differently is the same drift, and reads worse.

**A lookup that was typed at three call sites is one function.** `SettingsLayout.label(for:)` is the
page label of a key. The row table wanted it, `SettingsControls.settingLabel(_:)` wanted it, and — the
reason it could not just stay at the row table — the Mac's cursor surface wants it too: a BESPOKE
surface draws settings, so the cursor group's style and blink rows sit inside `cursor-preview` rather
than being described by the table, and they must still be called what the table would have called
them.

**What stayed with each half is the same three things as every increment since 19**, and the list has
not grown: the binding (`@Default` is a property wrapper, and SwiftUI observing the read is its whole
point), the widget, and the hue — `SlopDeskSlate` depends on `SlopDeskClientCore`, so an ink cannot
descend without becoming a cycle. `SettingsProseInk` is the role, resolved to `SettingsInk.ok` in
SwiftUI and `Slate.Native.StatusInk.ok` in AppKit. `os-integration`, `cli-install`, `raw-overrides`
and `config-file` are `Platform::Mac` in the layout table and keep their words with their single
renderer, exactly as `MacOSIntegrationRows`' and `MacCLIInstallCard`'s already do — a surface with
one half has nothing to spell once.

### Increment 50 — the pointer tables, and the mirror that was a third copy

Two lookup tables libghostty hands the embedder — `GHOSTTY_ACTION_MOUSE_SHAPE` (OSC 22) and
`GHOSTTY_ACTION_MOUSE_VISIBILITY` (`mouse-hide-while-typing`) — are `slopdesk_terminal::pointer`
now. Both are the §4 convention's degenerate case: one scalar in, one scalar out, nothing to size
and nothing to free.

**The deletion is the point, and it is not the table.** `PointerShapeMapping.swift` used to open with
`OSCPointerShape`, a 34-case Swift enum mirroring `ghostty_action_mouse_shape_e`, whose entire reason
to exist was that the table below it wanted something to `switch` over. That made THREE copies of one
declaration order — libghostty's header, the Swift mirror, and the table — of which any two could
drift while the third still compiled, and nothing about a drift is loud: a resize handle starts
showing a hand. `MouseVisibility` was the same shape at two cases. The raw `int32_t` travels now, and
the crate that owns the meaning validates it by `match`, not by `transmute`.

**What stayed on this side is the discriminant, so it is what the tests pin.** `PointerShapeToken`
is `Int32`-raw-valued 0–14 and those numbers ARE the wire; `slopdesk-ffi`'s suite asserts all fifteen
through the door rather than against the Rust enum, because the number Swift receives is the number
the door returns. The Swift suites no longer restate the table — repeating it here is the mirror
`CLAUDE.md` bans — and assert only the crossing: that each discriminant lands on the right case, and
that visibility is not inverted on the way back. The GUI keeps the one `PointerShapeToken → NSCursor`
switch, with its macOS-15 `columnResize`/`rowResize` availability handling, because that is drawing.

**The two unknowns fold into one answer on purpose.** A shape macOS has no native cursor for
(nineteen of the thirty-four) and a value from a newer or corrupt libghostty both mean KEEP the
current cursor, so the surface needs one branch rather than two, and the door spells it as a negative
sentinel — `SLOPDESK_POINTER_TOKEN_NONE` — because "no change" is not an error, it is the commonest
answer of all. Visibility fails the other way for the same reason read backwards: only the explicit
hidden value hides, because a pointer wrongly shown is a cosmetic miss during typing and a pointer
wrongly hidden is a person moving a mouse they cannot see, with no gesture that brings it back.

### Increment 51 — the panel's four surfaces, and a ledger row that was counting one file

The right column's body — the workbench mount, the open gate, the desktop placeholder, the two
device surfaces, the five poll loops, the collapse fade and the two toast reports — is
`MacCodePanelSurfaces` now. What each surface SAYS is `CodePanelPresentation` in
`SlopDeskClientCore`, and the phone's renderer (`CodePanelSurfaces`, `#if os(iOS)`) reads every word
and every fold out of it rather than restating them.

**The fold is the shared part, not the words.** `CodePanelPresentation.workbench(…)` takes the phase,
the active root, the opened set and the awaited key and returns one of four states, and its ORDER is
load-bearing in a way no prose about "the empty state" would have caught: the open gate outranks the
root, which outranks the awaited key, which outranks the no-project placeholder. Drawn twice from a
prose description, that ordering had already drifted once — the Mac deferred the poll behind the gate
and the phone did not — so what descended is the `switch`, and each half only decides what a
`PanelEmptyState` LOOKS like.

**The poll loop is one task and it sits outside the state switch, on both halves.** The first draft
of the phone's renderer hung a `.task(id:)` on three of the four branches, which reads correctly and
is a live bug: those branches are the phases the poll itself moves through, so every transition the
poll caused would cancel and restart the poll that caused it. The Mac has no `.task(id:)` to misuse —
AppKit has no equivalent at all — so it carries `keyed(_:on:)`, a `[LoopID: (key, Task)]` dictionary
that starts a loop when its key appears, leaves it alone while the key holds, and cancels it when the
key goes nil. Five loops, one rule, and the rule is written once.

**The mount identity excludes the load state on purpose.** `SurfacePlan.identity` folds the surface,
the project root and the collapse, and deliberately not the veil or the poll keys: remounting a
pooled `WKWebView` mid-navigation unparents a live page in order to hand it straight back, so a key
that included the first paint would remount at exactly the moment the pool exists to avoid. The veil
is followed separately, as an alpha on a sibling.

**And the ledger row was wrong, which is worth more than the increment.** It read
`CodePanelSurfaces | 632`, as if the file were the debt. The four surfaces host **~4,100 further
lines** of device-panel SwiftUI — `SimulatorStageView`, `SimulatorDeviceList`, `AndroidStageView`,
`AndroidScreenView` and their eleven siblings — which the row never named, so "one 632-line file
between here and the canvas" was off by a factor of seven. The import did not fall to 7 either: it
MOVED, from `MacCodePanelColumn` to `MacCodePanelSurfaces`, and now names the two device surfaces and
nothing else. That is the honest shape of a big surface crossing — the seam narrows first and the
count moves later — and the ledger says so below.

### Increment 52 — the device panels cross, and one seam closes instead of narrowing

The ~4,100 lines increment 51 discovered are rewritten. `MacSimulatorSurface` and `MacAndroidSurface`
are the two AppKit surfaces `MacCodePanelSurfaces` mounts; the SwiftUI originals stayed and are the
phone's, all fifteen of them `#if os(iOS)` now. `SlopDeskMacUI` imports `SlopDeskClientUI` in **seven**
files, down from eight, and `WorkspaceColumnHosts` is back to one factory — the pane canvas.

**A seam that narrows before it closes is the honest signal.** `WorkspaceColumnHosts.codePanelSurfaces`
handed over the whole right column until increment 51 cut it to two device surfaces, and increment 52
left it with nothing to hand over. Read as a count the middle step looks like a wasted increment; read
as a seam it is the useful half — the narrowing is what made the remaining debt nameable, and the
ledger row that had been wrong for four increments only fell out of naming it.

**Two of the fifteen files were never a view decision.** `SimulatorScreenNSView` (314 lines) and
`AndroidScreenNSView` (379) are plain `NSView`s over an `AVSampleBufferDisplayLayer` — they moved to
`SlopDeskDevicePanels` verbatim, and the move DELETED an import edge rather than adding one, because
both already imported the floor they now live in. This is kind 2, three increments after kind 2 was
declared finished, and the lesson is that "not a view" is a property of a file rather than of a
target: it hid inside `SimulatorScreenView.swift` behind an `#if os(macOS)` for as long as the
representable wrapper above it made the file look like SwiftUI.

**`DeviceKeyEvent` went down with them, and that is the increment's one real bug caught.** Reading
`event.modifierFlags` into `InputModifiers` is not a drawing either, but it sat in `SlopDeskClientUI`
because the screen views did. When they became `NSView`s one target down, the extension above them
was suddenly a call UP — and the AppKit half quietly grew a private six-line copy of the modifier
fold, with a comment saying the two spellings would have to be kept in step by hand. They would not
have been. The file is in the floor now, gated on `canImport` rather than `os(…)`, and the copy is
deleted.

**Two tests moved down and stopped testing half the product.** `DeviceConsoleInkTests` asserted on
`Slate.Text.tertiary` — a `Color`, i.e. the SwiftUI half's hue — which is why it lived in
`SlopDeskClientUITests` and why, the moment there were two renderers, it could only ever cover one.
It asserts the ROLE now (`.tertiary`, `.alarm`) and lives beside the fold. `SimulatorBezelFitTests`
moved for the same reason: `rotationEffect` does not change layout, and neither does a rotation on a
`CALayer`, so fitting a quarter-turned phone against swapped bounds is both halves' problem.

**What was deliberately NOT built.** Both AppKit halves grew a `Mac*Parts.swift` of shells — spinner,
search plate, plate tray, glyph button, veil, row shell, flow grid — and roughly nine of them touch no
device type at all. Merging them into one `MacDevicePanelParts.swift` was declined *while both
increments were in flight*, because merging two moving targets is how a shared abstraction gets
written against neither. It is a follow-up with both halves standing still, and it is the only shape
in which the "Android is a fourth tab, not a second half of Simulators" rule can safely bend: shells
with no device type in their signature are not a device abstraction.

### Increment 53 — the eleven shells merge, and the follow-up 52 deferred is paid

Increment 52 declined the merge *while both halves were in flight*, and named the condition under which
it would be safe: both standing still, and the line drawn at the signature. That is this increment.
**1530 lines became 969** — `MacDevicePanelParts.swift` (655) holds the eleven chrome shells, and each
`Mac*Parts.swift` keeps exactly the four declarations that name a device type (153 and 161).

**The test is mechanical, and it is the whole reason this bend is safe.** A declaration merged if no
device type appears in its signature. `MacDevicePanelLoop`, `macDevicePanelCapsLabel`,
`macDevicePanelLabel`, `MacDevicePanelSectionHeader`, `MacDevicePanelPlateTray`,
`MacDevicePanelGlyphButton`, `MacDevicePanelSpinner`, `MacDevicePanelSearchPlate`,
`MacDevicePanelVeil`, `MacDevicePanelRowShell` and `MacDevicePanelGrid` take `String`, `NSView`,
`SFSymbol` or nothing. What stayed takes a `SimulatorInk`, a `SimulatorDevice`, a `SimulatorFact` —
or the Android four. The "Android is a fourth tab, not a second half of Simulators" rule is not bent
by a spinner: the two panels share no byte of protocol, and a shared spinner is not a claim that they
do. `check-supervisor.sh` now pins that line in both directions — no device type name may appear in
the merged file, and each merged class may be declared in exactly one place.

**Two shells were supersets rather than duplicates, and taking the superset was pixel-neutral.**
`RowShell` differed by an `active` flag and a `cardBorderWidth`; the Android rows never set `active`,
so the simulator's shape is a strict widening for them. `SearchPlate` differed by a `setQuery` the
simulator never called. Merging a pair where one side is strictly larger is the only merge that
cannot silently change a drawing — and the argument for why the Android rows carry NO active state
moved to `MacAndroidDeviceRow`, the class it is actually about, rather than staying in a file that no
longer holds the shell.

**One string was being spelled in the renderer, and only one half had noticed.** `"Copy \(label)"` was
built inside the AppKit simulator view while the Android half — the same sentence — already asked
`AndroidPresentation.copyTitle`. `SimulatorPresentation.copyTitle` now exists, both renderers ask it,
and a ratchet bans `"Copy \(` from every renderer. This is the split's own rule catching a leak the
split created: two renderers make a word spelled at the drawing a word that can drift, and the drift
had already started.

### Increment 54 — kind 2 was not finished, and the canvas was where it hid

The ledger below said kind 2 closed at increment 45 and that everything left was "AppKit rewrites and
the canvas". Both halves of that sentence were wrong in the same way: **the canvas was full of kind 2.**
Five parallel sweeps over `Sources/SlopDeskClientUI/Pane/` moved **~2,900 lines of decision** down to
`SlopDeskClientCore` and wrote ~2,400 lines of test against it — and **not one line of AppKit was
written to do it.** `Sources/SlopDeskClientCore/Pane/` is 3,617 lines now and did not exist a week ago.

**Why the ledger could not see it.** Kind 2 was counted by IMPORT EDGES — a file was kind 2 if moving
it dropped a `SlopDeskMacUI` → `SlopDeskClientUI` edge. Every file in this increment was invisible to
that count, because the canvas is one edge no matter how much logic is inside it. The census that found
them asks a different question, and it is the one §3 actually states: *does this declaration name a
`View`?* `PaneDragResolver` did not. `TerminalFindBarModel` did not. Neither did the five gates deciding
whether the vi key-hint bar is up, nor the four statics deciding which drop zone a point is in.

**What moved, by sweep.** The drag vocabulary and `PaneDragCoordinator` itself (723 lines, kind 3 in the
ledger below — see the amendment there); the external-drop path (`actuate`, the accepted UTTypes, the
provider precedence, the overlay's tint verdict); `TerminalFindBarModel` whole, plus the find bar's
words, the three status pills folded into ONE value, the vi key-hint tables and Hint Mode's rules; the
terminal and GUI leaf statics, the letterbox placement, the canvas spine's focus/zone/pointer verdicts,
the resize-scrim reducer; and `PaneImmersiveCapture` + `SystemKeyCaptureController`.

**Three renderer-side defects fell out of the moves, and each is the split's own argument.**
`PaneMoveOverlay.zoneLabel` said `title ?? "pane"` while the chip beside it said
`title.isEmpty ? "pane" : title`, so an untitled pane made the chip read `"swap "` with a trailing
space. `SecureInputPill` had a fixed-colour escape hatch and a test; `SyncInputPill` had the hatch and
no test. `"Copy \(label)"` was built in one renderer and asked of `AndroidPresentation` in the other
(increment 53). Every one is a rule that was spelled at a drawing, and every one only became findable
because a second renderer forced the question of where it is spelled.

**Two `ViewThatFits` became arithmetic**, which is the shape §2 keeps predicting: `ViewThatFits` is a
SwiftUI *measurement*, so a layout expressed in it cannot be asked by AppKit at all. The vi card is a
`Layout` over `ViKeyHintLayout.layout(forWidth:gap:columnWidth:)` now, and the numbers are readable
from either half. (`PanelTabs` was the first.)

**Two enums were nested inside `View`s and could not be reached.** `SlateEmptyState.Cause` and the drop
zone's ink roles are verdicts about the CONNECTION and the POINTER, not about a drawing; nesting them
in a `struct … : View` made them unreachable from AppKit for a reason that had nothing to do with
either. They are `PaneEmptyCause` and `DropZoneInk` in `SlopDeskClientCore` now.

**And the count moved anyway: 7 → 5.** `MacSidebarRow` and `MacNavigatorColumn` took nothing from
`SlopDeskClientUI` but `PaneDragCoordinator`, so both import lines simply went away when it descended.
That is the check on this whole increment being real work rather than tidying: a sweep that only sorted
files would have left the number alone.

### Increment 55 — one engraved caps heading, six copies

A one-line follow-up from increment 53, and it is here because of what the grep turned up. Merging the
device panels' shells produced `macDevicePanelCapsLabel`; grepping for the constant that makes it —
`Slate.Typeface.instrumentTracking` — found the same four-attribute dictionary open-coded **five more
times**, in `MacPalette`, `MacOpenQuickly`, `MacPeekReply`, `MacCheatSheetPanel` and
`MacKeybindingsEditor`. Five of the six even carried their own copy of the comment explaining the
kerning.

`Chrome/MacCapsLabel.swift` is the one recipe, in two spellings because the call sites genuinely differ:
four of them already own an `NSTextField` and want only the string, two want a finished label. The label
spelling goes through the string spelling, and a ratchet pins that it keeps doing so.

**The ink is deliberately NOT shared.** The six sites disagree — `State.header` on a device panel,
`Overlay.tertiary` on a summoned card, `Text.tertiary` in Settings — and they are right to: an
overlay's ink ladder is not a page's. What is shared is the FACE, the caps and the tracking. So the
colour stays a required argument, and a call site cannot inherit the wrong one by omission. This is the
same line increment 53 drew between chrome and protocol, one layer down: a *typographic* rule is
shared, a *semantic* one is the surface's own.

The ban is on the kerning constant rather than on the shape, because that is the tell a seventh copy
cannot avoid spelling.

### Increment 56a — an import that had been dead for three increments

`SlopDeskSplitViewController` imported `SlopDeskClientUI` and said why in a comment: *"the three hosted
columns, until each is rewritten in AppKit"*. All three were rewritten — increments 46, 51 and 52 — and
the comment outlived them. The import is one line and the ledger counted it as one fifth of the
remaining debt.

**How it was proved, and why the proof matters more than the deletion.** A grep for the target's name
finds the import line and nothing else, which proves only that nobody wrote the module's name. The test
that matters is the opposite one: every capitalised `struct`/`enum`/`class`/`actor`/`protocol`/
`typealias`/`func` name declared anywhere under `Sources/SlopDeskClientUI/` — **219 of them** — tested
against this file with its comments stripped. Zero hits. `import SwiftUI` fell to the same test in the
same breath: not one SwiftUI symbol survives in the file.

The comment-stripping is the load-bearing part. Three of this file's doc comments still described the
columns as `NSHostingController`s inheriting a `\.preferencesStore` WindowGroup environment, and one
named `NavigatorColumn` — a type in the *other* target. A textual grep would have called each of those
a live use. They are corrected in place rather than deleted, because the threading they justify is
still there and now has a better reason: an init parameter is a compile error to forget, where an
environment key was a silent `nil`.

A stale import is not free. It is what makes the ledger a count of files rather than a count of work,
and it is why increment 54 found 2,900 lines hiding behind a single edge.

> **Correction, increment 57a — the census above has a hole, and it is the word "capitalised".**
> Swift's most common cross-target symbol is not a type: it is a `func` on `View`, and those are
> lowercase by convention. `overlayCoordinator(_:)` and `preferencesStore(_:)` are both declared in
> `SlopDeskClientUI`, both applied in `SlopDeskMacUI`, and **neither is in the 219.** The census would
> have returned "zero hits" for a file that used them on every line.
>
> It reached the right answer here — this file genuinely used nothing, and the build proves it — but
> it reached it for a reason narrower than the one written down, and a method reused on a file where
> the answer differs would delete a live import. The test is every declared name, of any case,
> including bare `func`s at file scope and in extensions. 57a runs both censuses and reports both
> counts; anything later that cites "56a's method" means the corrected one.



### Increment 56b — the window's sidebar toggle, and the second import falls

`MacWorkspaceRootView` took exactly two things from the draining floor. `WindowSidebarToggle` was a
47-line `package` SwiftUI view with no other caller; `\.preferencesStore` was an environment key
declared over there.

The toggle is `Chrome/MacWindowSidebarToggle.swift` now, and the SwiftUI original is **deleted** rather
than gated. The phone never drew it and could not: it has no window corner, no traffic lights and no
split item to collapse. A macOS-only control sitting on the shared floor is the exact arrangement stage
D exists to end.

Two things were lost on the way across and both were checked rather than assumed. The glyph's
`symbolEffect(.bounce.down)` has no AppKit equivalent short of reimplementing it — which is the ruling
``MacPlateIconButton`` already made for every other plate in this target, so the Mac spends the FILL
rung alone. And the plate still does not latch: what this button turns on is a COLUMN that is either
visibly there or visibly not, so a half-lit plate would restate, in the chrome's faintest channel, the
one fact the window is already shouting. The tooltip is what flips.

The environment key became an **init parameter** threaded from `SlopDeskMacApp`. That is not a
sideways move: the only consumer below is inside a column that inherits no WindowGroup environment, so
the value was ALREADY being forwarded explicitly one hop down. A parameter is a compile error to
forget; the key was a silent `nil`.

### Increment 56c — the canvas's last kind 2, before a line of AppKit is written

Increment 54 swept ~2,900 lines out of the canvas. A census afterwards found what it missed, and the
timing is the entire argument for doing it now: anything still misfiled when the AppKit rewrite starts
gets **translated by hand into a second language**, which breaks "one implementation, never two" in the
same commit that claims to honour it.

Four things descended or were named:

- The four rect helpers under `PaneMoveAffordance`'s own `// MARK: Geometry helpers (pure rect math)`
  banner. They survived increment 54 for the reason that increment recorded about itself — a method on
  a `View` is not a view, but nothing that is not one can reach it. They are `PaneDropGeometry`'s now,
  with the rail's magic `48`/`0.12` NAMED, and the round-trip property finally testable: every point
  that RESOLVES to a dock is inside the rail that dock DRAWS. Resolution and preview were separate
  arithmetic with separate constants, and nothing had been stopping them drifting into a canvas that
  docks from 28pt in while showing a band that starts at 12.
- `NSItemProvider.loadURLValue()` / `loadTextValue()` — **Foundation, not SwiftUI**. Only the three-line
  `ProviderBundle(info: DropInfo)` adapter was ever SwiftUI, and the `NSDraggingInfo` path will need
  the loaders byte-identically.
- `PromptJumpFlashOverlay`'s `peak = 0.28` and its bare `300`ms, onto a named rung. The file's own
  header had already flagged it: *one duration, three spellings*.
- `PaneDivider`'s `hairline = 1`, onto the `Slate.Metric` rung that already existed.

And one thing that **cannot** descend, which is the more interesting half. `PaneStatusPills.fillColor`
returns a `Color`; `Color` is Slate's; Slate sits ABOVE `SlopDeskClientCore`. Pushing the token down to
meet the ink would make the floor import the ladder standing on it. So the ink stays a NAME below
(`PaneStatusPillInk`) and each renderer keeps its own four lines — the `ToastPresentation` deal exactly,
with the same obligation: the halves are **ratcheted as a pair**, with the cases read out of the enum
rather than listed in the gate, so a third ink is red in both renderers until both answer it. The gate
pins whichever halves exist today, because a ratchet written after the second renderer arrives is a
ratchet written too late.

### Increment 56d — `staticMirror`, a dead branch deleted before it could be ported

A defaulted-`false` parameter threaded through `SplitContainer`, `PaneContainer`, `GuiLeafView` and
`TerminalLeafView`, branched at ~20 sites, and carried as a dead argument on four `SlopDeskClientCore`
predicates. **No production caller ever passed `true`.** The only `true` in the repo was in three unit
tests — a feature kept alive by its own tests, which is the finding increment 45b already recorded once
about a second git-line renderer.

It is deleted, and the timing is the whole value. Those ~20 branches were about to be translated into
AppKit by hand for a path nothing reaches. A dead flag in one language is cheap; the same flag alive in
two is expensive forever, and a rewrite is exactly the moment it gets committed by accident. This is the
single highest-leverage deletion available before the canvas port, and it cost no design decision at all.

> **A claim in the plan that did not survive checking.** The same increment was to delete
> `SlateProjectIsland` as having "no caller outside its own file". It has two — `SlateSnapshotRender`
> and `MacRailStatusRollupRender`, both snapshot-render harnesses, one of them under
> `Tests/SlopDeskMacUITests` reaching into `SlopDeskClientUI`. So it stays, and it joins the rename's
> list rather than this increment's: a ClientUI view whose only readers are test harnesses, including
> one on the Mac side, is an edge the rename still has to answer for.

### Increment 56e — the cursor-following chip, and a table that had to move to survive

`PaneDragChipPanel` was already a borderless `NSPanel` — a panel is not a view, and there is no SwiftUI
spelling of "a window above every other window that never takes a click". What was SwiftUI was its
`contentView`: an `NSHostingView` over a ~40-line capsule. That capsule is hand-drawn AppKit now
(``MacPaneDragChipPanel``), the original is deleted, and the phone loses nothing — the whole block was
already inside `#if os(macOS)`, because a platform with one window and no cursor has nothing for a
cursor-following cross-window chip to do. iOS leaves the sink nil, which is the seam's designed answer.

`DropTargetFrameReader` stayed behind in a file of its own. It is the one genuine kind 3, ~40 lines, and
increment 58 deletes it when the island moat moves into AppKit.

**The part that was not in the plan.** The chip's `Mark` → `SFSymbol` table lived at the foot of
`PaneMoveAffordance.swift`, and its header claimed a property it was about to lose: *both of this
module's drop chips come through here, so a new mark cannot reach one and miss the other*. That was true
only while both chips were SwiftUI. The moment one became AppKit it could no longer reach into the
draining target, leaving two futures — spelled twice, or moved down.

It moved down, to `Slate/PaneDropChipArt.swift`, and the four capsule metrics went with it. This is not
tidiness, and the reason is specific to this pair: **both chips can be on screen in the same drag.** The
in-tree ghost chip is showing while the cursor is over the canvas; the panel takes over the moment it
leaves. A user drags slowly from canvas to sidebar and sees both. A half-step of padding or a slightly
different rim does not read as two files disagreeing — it reads as the chip glitching.

The move also retired a literal: the cancel rim's raw `0.4`, off the opacity ladder by 0.05, in the one
place where being off the ladder cost most. It was the single value keeping the two chips from being
provably identical. Snapped to `Slate.Opacity.dim` rather than minted as a rung, because a rim alpha is
not a new question.

`Package.swift` had already anticipated the home: Slate carries `SFSafeSymbols` precisely so *the marks
are named as `SFSymbol`s, and both renderers ask for the same artwork*.

### Increment 56f — five environment injections nobody reads

`SlopDeskMacApp` handed its scene root three of the draining target's environment keys —
`\.preferencesStore`, `\.agentHooksController`, `\.overlayCoordinator` — and re-applied all three to
every satellite root against the hosting-root env trap. Each carried a comment explaining which deep
view needed it.

**Every reader of all three is a phone view.** Each has an AppKit twin the Mac mounts instead, and every
twin takes its dependency as an init parameter: `MacSettingsBespokeSurfaces(agentHooks:)`,
`MacFirstLaunchSheet`, and — since 56b — `MacWorkspaceRootView(preferences:)`. Five of the six
injections were writing into a subtree with nobody listening.

The sixth is live and stays: a satellite mounts `SatellitePaneRootView` → `PaneContainer`, which reads
`\.overlayCoordinator`, and an `NSHostingView` root really does inherit nothing. It dies with increment
62. The main scene's copy of that same key is dead for the opposite reason — the canvas gets it from
`WorkspaceColumnHosts` at its own hosting root, not from the scene.

**Why this is a gate and not a tidy-up.** A dead injection costs nothing at runtime, cannot fail a
test, and survives every rewrite that removes its last reader. So it accumulates, and worse, it reads
to the next person as evidence that a subtree still resolves keys it stopped resolving three increments
ago — which is exactly how 56a's stale import survived three column rewrites. Both are the same defect:
**a line that documents an arrangement which has stopped being true**, in a form nothing can fail on.
The ratchet bans the two dead keys outright and pins the satellite decorator at exactly one.

Writing the gate found two holes in the gate. The first draft anchored the ban to the start of a line,
so `.a().b()` chained on one line walked through it; the second counted matching LINES rather than
occurrences, so two keys on one line counted as one. Both were caught by trying to break it rather than
by reading it — which is the only way a ratchet gets tested, since a green gate and an absent gate look
identical.

### Increment 57a — an injection in the wrong file, and the third import

`SlopDeskMacApp`'s last `SlopDeskClientUI` symbol was `overlayCoordinator(_:)` — a lowercase `func` on
`View`, applied in exactly one place, wrapped in a `decorate: (AnyView) -> AnyView` closure and threaded
two hops down into `SatellitePaneHost.contentView`. The whole target imported the draining floor for
five lines that name no AppKit at all.

**The key is declared in the same target as the view that reads it.** `\.overlayCoordinator` lives in
`SlopDeskClientUI`; `PaneContainer`, which reads it, lives in `SlopDeskClientUI`. The hosting-root trap
56f described is real and unchanged — an `NSHostingView` root inherits nothing — but the answer to it
was never the caller's to spell. `contentView` takes the coordinator as a plain `SlopDeskClientCore`
value now and applies the modifier itself, and the parameter is deliberately NON-optional: the slot is
`OverlayCoordinator?` because a preview may have none, but a satellite window always has one, and a
defaulted `nil` is exactly the shape that silently mounts a pane whose drop toasts go nowhere.

`SatellitePaneWindows`'s own `import SwiftUI` fell with it — it was there for `AnyView` in the closure
type and nothing else. Its `SlopDeskClientUI` import stays: that file mounts `SatellitePaneHost`.

**The census that proved it, and why 56a's would have missed this.** 56a tested only CAPITALISED
declaration names. `overlayCoordinator(_:)` and `preferencesStore(_:)` are lowercase `func`s on `View`
and would have walked straight through. So both halves were run against the file with its comments
stripped: **215 capitalised declarations, 0 hits; 311 `func` names, 12 raw hits and all twelve false
positives** — argument labels (`of:`, `title:`, `body:`), members of types from other targets
(`DockProgressController.apply`, `ClipboardMonitor.run`), parameter names, the `App`'s own `body`, and
`SlopDeskMacApp`'s own `private var overlayCoordinator`. **Ledger: 3 → 2.**

### Increment 57b — `enabled:`, and two ratchets 56c was owed

**`enabled:` was `staticMirror`'s corpse.** 56d deleted the flag; what survived it was the parameter the
flag used to feed. `PaneContainer` passed a literal `true`, `PaneDropReceiver` stored it, and
`PaneDropGate.acceptsDrag` branched on it — one reachable value through three files, with the receiver's
doc comment still describing `false` as "the static-mirror (ImageRenderer) path", a path that no longer
exists. 56d's reason applies verbatim one call deeper: an `NSDraggingDestination`'s `draggingEntered`
would have re-typed the guard by hand for something nothing reaches. The five test assertions came with
it, and the one that had to go was `enabled: false` — *"a static-mirror pass never engages the live
overlay"*, the suite pinning the dead branch, which is 45b's finding for the third time.

**And 56c ratcheted one of three ink tables.** `PaneStatusPillInk` was pinned as a pair because it
resolves to a `Color` and therefore cannot descend below Slate. `DropZoneInk` and `GuiUploadTint` are
the identical arrangement for the identical reason and were missed — so 56c's own sentence, *a ratchet
written after the second renderer arrives is a ratchet written too late*, was written and then not
applied to its own siblings. Both are gated now, cases read out of the enum, pinning whichever halves
exist today.

Writing them turned up two holes, both found by breaking the gate rather than by reading it. The `\b`
after the case name is load-bearing: without it `case \.accent` also matches `case .accentMuted:`, so a
half that dropped the accent rung would have passed for the rung it dropped. And the enum-name match was
a PREFIX match — `/^package enum DropZoneInk/` still matches `DropZoneInkRung`, so an enum renamed out
from under the gate would keep parsing and the gate would keep passing against a table nothing declares.
That is the same class as 56f's line anchor and its line-vs-occurrence count: a green gate and an absent
gate look identical, and the only way to tell them apart is to try to break one.

**The `Tests/` edge (see §3.5 step 5).** The "neither half imports the other" gate globbed `Sources/`
only, so `Tests/` was unopposed, and two Mac snapshot harnesses — `MacChromeSnapshotRender` and
`MacRailStatusRollupRender` — reach into `SlopDeskClientUI` for `SlateProjectIsland`, `SlateSearchField`,
`SlatePlateStyle` and `StatusDotView`. A `@testable import` is a stronger edge than a plain one, and the
fold is blocked by a Mac test target naming the draining floor exactly as hard as by a Mac source file
naming it. The gate covers both spellings and all four edges; the two files are an explicit,
subset-checked allowlist scoped to that one edge, so a THIRD crossing is red immediately while paying
the debt passes. Where a shared pixel-verify harness should live is a design call, not a lint fix — 56d's
`SlateProjectIsland` note already flagged this exact pair as "an edge the rename still has to answer
for", and this is what makes that debt fail loudly instead of sitting in a doc.

> **Three of the four symbols named above were already fiction when this was written** — see increment
> 62, which paid the debt. `SlateSearchField`, `SlatePlateStyle` and `StatusDotView` appear in those
> two files only inside doc comments, and `MacChromeSnapshotRender` used nothing from the floor at
> all. The gate was right and its comment was wrong, which is the failure mode a ledger that names
> symbols has and a ledger that checks imports does not.

### Increment 57c — wave P's first three, and an amendment 56c owes itself

**P1, P2 and P3 landed together; what they have in common is the point.** Each moved something that is
not a drawing out of a view that is about to be written twice, and in each case the thing that moved was
an ORDERING or a BALANCE — the two shapes a hand-translation into a second language loses first, because
neither one has a type.

- **P1 — `TerminalPaneWiring`.** Five wire/clear pairs out of a 555-line `View` body. The load-bearing
  part is not the closures, it is that `clearSecureInput` releases the process-global
  `EnableSecureEventInput` *above* its `guard let model`. Behind the guard, the release is skipped for
  exactly the pane that most needs it — one whose model has already gone — and the lock outlives the
  app's own window, taking the keyboard out of every other app. No crash, no log; the user reports that
  typing stopped working everywhere.
- **P2 — `PaneCanvasDragController`.** The tear-off's two steps are ordered: the drop placement is
  recorded BEFORE `store.detachPaneToWindow`, because `detachedPanes` mutates synchronously inside that
  call and the satellite coordinator reads the placement as it opens the window. Reversed, the window
  still opens — at the centre-cascade instead of under the cursor, and only when the reader wins the
  race. An occasionally-wrong-place window is the worst failure shape there is, and until this descended
  it was pinned by a comment.
- **P3 — `PaneMoveEscapeMonitorController`.** An `NSEvent` monitor and an FFI call behind an
  `NSViewRepresentable` whose `makeNSView` returned a bare `NSView()` — SwiftUI's only way to hang a
  LIFETIME on something that is not a drawing, which is the whole tell. Increment 54 ruled on this exact
  shape for `SystemKeyCaptureController`; a monitor draws nothing either.

**Running them found what writing them could not.** The three ports were written by agents that cannot
build, and two shipped defects no compiler or lint could see. The monitor cancelled nothing once
disarmed — correct — and still returned "swallow", so a keyDown already in flight when the drag
committed ended the drag AND made the user's Escape vanish: no sheet closed, no overlay dismissed, once,
under a race. And a test asserted `move?.zone == .none` where `.none` on a `PaneDropZone?` is
`Optional.none` — it reads as "no landing" and means "no drag", type-checks either way, so the case
meant to pin a masked preview was asserting its opposite. **Both are arguments for the same rule: a
batch is not done when it is written, it is done when its suite has run.**

**P7 is already paid.** The three ungated pair-tables this page lists — `FindTogglePillAppearance`,
`PaneStatusPillFill`, `DropZoneLabelInk` — are rows in `named_ink_tables` now, so all six tables that
resolve to a `Color` are pinned as pairs. The first of them was not a future risk but 56c's stated
failure already realised: both halves shipping, its own header naming the invariant, nothing checking it.

**The amendment 56c owes itself.** 56c's title claims the canvas's *last* kind 2 was closed before a
line of AppKit was written. `TerminalLeafView` was standing there the whole time — 555 lines holding
five callback pairs, a connect decision, an autotype decision and a process-global lock. The claim was
not wrong about the file it examined; it was wrong to generalise from one file to "the canvas". Wave P's
second sweep found ~445 more lines of not-a-drawing after the first found ~2,900. **A sweep that finds a
tail is not a failed sweep — but a sweep that reports "last" is a claim about files it never opened.**

### Increment 57d — wave P's last three, and the kind-3 row that was never geometry

**P5 closed the only kind 3 on the ledger by deleting the thing that made it one.** The row read
*"the compositor rect differs from the hosting view's frame by the island moat"*, and every word of it
was true — `ContentColumn` applied the moat one level above the canvas, so the hosting view's frame and
the canvas differed by it, and by a *differently animating* amount while a column collapsed. That is
what `DropTargetFrameReader` existed to work around: a `GeometryReader` inside `SplitContainer`
publishing the screen rect the AppKit view above it could not compute. Move the moat down into
`MacContentColumn`'s constraints and the difference is **zero**. The reader is deleted rather than
ported and registration is the three lines `MacNavigatorColumn` already spends on `.sidebarList`.

**The row was never a fact about geometry. It was a fact about where a modifier had been applied** —
which is the general shape worth carrying into wave R: a blocker phrased as a measurement is worth
re-reading as a statement about layering, because the second kind can be dissolved and the first cannot.

- **P4 — the leaf seam grows a second shape.** Both factories offered one: a SwiftUI `AnyView`. On the
  Mac that buries the Metal surface under an `NSHostingView` that claims the hit-test over the one view
  which must take every keystroke — the exact hit-claim stage D spent five increments removing. So the
  seam widens instead of the canvas thickening: `nativeShared` hands back the `NSView`, `shared` stays
  and is **permanently** not deprecated, because the phone has no `NSView`. One seam, two shapes, picked
  by which framework is drawing.
- **P6 — two values that did not need a pair.** The accent ring's alpha was spelled three times, the
  third in `MacGlobalSearch` — AppKit, drawing the ON chip of the very pill whose header pins that the
  find bar and the global-search bar render identically. Both proposing comments undercounted their own
  spellings.

**P6's finding is the one this page did not have.** The ink of that pair was already filed as a realised
failure; the ALPHA was the same failure one dimension over and nothing had named it. A `Color` table
cannot descend below `SlopDeskSlate` and so must be pinned as a pair — but an alpha ladder is
frameworkless, and **a frameworkless value descends to the floor where a pair would only have reported
the drift after it shipped.** So before pinning a pair, ask whether the value has a colour in it. If it
does not, a pair is the wrong answer and the floor was available the whole time.

**What only a click can check, and what a gate can.** P4's registration lives in an app target no
`Package.swift` builds, so `swift build` never compiles the embedder at all — the pair is verified by
`enable-macos-renderer.sh` plus `xcodebuild`, and `** BUILD SUCCEEDED **` is the entire pass criterion.
That leaves the half-registration failure invisible to every suite: only `shared` set ships a Mac that
cannot mount natively, only `nativeShared` ships iOS the BUILD-STATUS placeholder, and neither is a
compile error. Hence the census down to `GhosttyRendererSeam.install()` alone — written through
`spells`, because the embedder names `nativeShared` five times in doc comments explaining the seam and a
raw grep reads its own explanation as a registrar.

### Increment 58 — wave R's first eight, and three things the fan-out found that no batch owned

**R1–R8 landed together**, twelve files under `Sources/SlopDeskMacUI/Pane/` (4,616 lines) against seven
new suites in `Tests/SlopDeskMacUITests/`. Nothing was deleted from `Pane/`, as the wave's rule says.
The batches themselves went as the table predicted; what is worth writing down is what came back from
the *edges* of a parallel fan-out, because all three were invisible from inside any single batch.

**The AppKit spelling of a SwiftUI modifier is not the identically-named one, and the brief got it
wrong.** Every batch was told to render `.opacity(x)` as `withAlphaComponent(x)`. They are not the same
function: `.opacity` **scales** a colour's own alpha and `withAlphaComponent` **replaces** it, so they
agree only for as long as the underlying colour is opaque. Under the terminal's paper they agree today
and would diverge the day a profile's glass face carries alpha — silently, and in the one direction that
matters, since the *recede* veil exists to keep a pane readable and replacing its alpha makes it the
heavier of the two. `Slate` already had the right verb (`slateScalingAlpha`) and already said this at
its own definition. The lesson is not about alpha: **a port brief that names the destination API is
asserting an equivalence, and the equivalence is the part to check.** Name the *behaviour* to preserve.

**The cross-half invariant that could not be written as a test, split into two that could.**
`PaneStatusPillInk` is ratcheted as a pair so both renderers must answer every case — but a ratchet
reading two files structurally cannot see whether they answer the **same**, and the obvious test for
that (compare the SwiftUI table's `Color` against the AppKit table's `NSColor`) has to name both UI
halves at once, which §3.5 step 5 forbids and should keep forbidding. Neither deleting the invariant nor
buying a third tracked exception is right. Split it instead: `check-supervisor.sh` pins that the two
tables name **corresponding rungs**, and `SlateNativeTokenTests` pins that a corresponding rung **is the
same colour**. Together they state what the illegal test wanted to, from inside the floor. **A
cross-half invariant is usually two legal halves that meet at the token layer** — worth reaching for
before an exception, since the pair-ratchet's blind spot is structural and will recur.

- **A computed property over a non-observable tracker is not observable, and reads as a rendering bug.**
  `TerminalViewModel.isAlternateScreen` derived from `modeTracker.mode`, which nothing observes, so a
  view reading it never re-rendered on an alt-screen transition. Fixed with a stored twin updated in
  `ingestPass` and cleared beside both `modeTracker.reset()` sites. Found by a batch agent in a file
  **no batch owned** — which is the argument for letting a fan-out report outside its lane even while
  it may only edit inside it.
- **Parallel batches drift at their shared API before either is wrong.** R4 called
  `MacPaneStatusPillCloseView(help:ink:)`; R2 had defined `(help:fill:)`. Neither batch could have seen
  it, and the tiebreak is not "whoever landed first" — it is the SwiftUI original, which spends
  `Slate.Text.secondary` unconditionally and therefore means `.chrome`.

### Increment 59 — the lint's own hang, and why the fold was scheduled to trigger it

**`make lint` could not fail; it could only stop returning.** `check-supervisor.sh`'s `spells` helper
takes a pattern and a file list, and forty bans build that list from a
`$(repo_files 'Sources/SomeTarget/**/*.swift')` splat. A splat matching nothing expands to nothing, at
which point the inner `grep -lE` has no file operands, falls back to stdin, and blocks forever. Three of
these sat wedged for the better part of three hours. It is the worst available failure direction — a
hung gate reports neither pass nor fail — and it is only reachable under an invocation whose stdin stays
open, which is why it never showed in a shell that closes it and did show under an agent.

**The fold was going to trigger this on the day it succeeded.** Draining `SlopDeskClientUI` to empty is
the entire point of F1–F4, and several bans glob exactly that directory. F5's rule — re-run every
re-pointed gate against a deliberately broken tree — now has a fourth demonstration behind it, and a
sharper one than the first three: those gates went *green while blind*, this one would not have gone
anywhere at all.

**Guarded at the choke point, and the answer is `return 1` rather than a shout.** An empty corpus is the
correct and expected state for a draining target, where the ban really is trivially satisfied; only a
caller knows whether its own corpus was meant to be non-empty. So that judgement stays where the
knowledge is — in the per-gate vacuity floors that count their list before they call. **A floor that
reports and returns is not a floor if its caller runs on regardless**, which is what `fail` does here by
design, and was the second half of this bug.

### Increment 60 — the terminal leaf, and risk 3 was never about visibility

**R9 landed, and risk 3 closes with it.** The row read "hide/collapse", and the hide half was already
settled — `alphaValue = 0`, never `isHidden`, because a layer-hosting view sizes its `IOSurfaceLayer`
frame and `contentsScale` in `layout()`, which does not run on a hidden subtree. The half that was
actually open had nothing to do with visibility: **SwiftUI's `.allowsHitTesting(false)` suppresses a
composed subtree, and AppKit has no equivalent, because `hitTest → nil` does nothing whatsoever to an
`NSTrackingArea`.** Tracking areas are rect-based and keep firing however the view answers, so a hidden
tab's terminal keeps one live over the visible tab's — presenting as a mouse-reporting TUI in a
background tab that follows the cursor in the foreground one. The sweep walks the occluded leaf's
descendants and takes their areas down, re-queued on the main queue so an area a descendant re-installs
during the pass is gone again before it can fire once.

**This is trap 4 from the platform ledger arriving a third time** (`963c25ff` was hover through a modal
card; the pointer shield was the second). Each time it was found by a symptom rather than by looking,
and each time the fix was local. The general form is worth stating once: **`NSTrackingArea` is the one
piece of AppKit that does not participate in the view hierarchy's own answers about who is in front.**
Anything reasoning about occlusion must take the areas down explicitly.

- **A completion closure cannot cross into `runAnimationGroup`, and a view can.** The handler is
  `@Sendable` while the whole leaf is main-actor, so a bare `(() -> Void)?` is a data race as far as the
  compiler can see — correctly, since nothing in the closure's *type* promises the main thread even
  though AppKit always delivers it there. An `NSView` crosses freely: `@MainActor` classes are
  implicitly `Sendable`. Taking a view to retire rather than a closure to run is the shape
  `MacPaneMoveAffordance`, `MacSimulatorSurface` and `MacSimulatorStageView` had each already reached
  alone, which is usually the sign that the type system is describing the domain rather than obstructing
  it.
- **The placeholder is ported faithfully, including something that looks wrong.** It paints with the
  CHROME ink ladder while sitting on the terminal's glass, which has an on-glass vocabulary of its own.
  Changing it in the AppKit half alone would convert a debatable authoring choice into a genuine
  cross-renderer divergence, in the one panel a developer reads when something is *already* broken. It
  is flagged at the file head instead, so it moves in one change or not at all.

### Increment 61 — the GUI leaf, the canvas, and the last hosted view

**R10, R11 and R12 landed, and with R12 there is no `NSHostingView` left anywhere in the workspace
window.** The ledger's last two edges were the same edge reached two ways — the pane canvas, hosted in
the content column and hosted in a satellite window — and both are closed: R11 wrote
`MacSatellitePaneRootView` and deleted `SatellitePaneContent.swift` outright, R12 wrote
`MacContentCanvas` and deleted `WorkspaceColumnHosts.swift`, the factory seam that had already narrowed
to one call. `SlopDeskMacUI` no longer imports `SlopDeskClientUI` at all.

**R12 was not in the plan, and the reason it had to exist is the rule that scheduled R11.** "A surface
is ported WHOLE" put `SplitContainer` and the twenty-odd files under it in one batch — but the SwiftUI
view that MOUNTED that container was `ContentColumn`, which is also three other things: the empty
state, the island's chip stack, and the swap between them. R11 could port the panes and still not be
mountable, because the thing that mounts them was not in it. The tell was visible before the batch ran
(`MacContentColumn` still called the factory) and the honest split was to name the remainder rather
than widen R11 — a batch that grows to swallow its own mounter is how "ported whole" stops meaning
anything.

**A frameworkless table descends; only a `Color` table pairs (P6, third application).** `SlateEmptyState`
carried four `static func`s — symbol, title, caption, action label — spelled inside a `some View` the
other renderer cannot import, which this repo's own `PaneCanvasPolicy` header already names as the tell
that a rule never belonged to a view. They are `String`s, so they went to `PaneEmptyCause` in
`SlopDeskClientCore` and the test moved with them (`SlateEmptyStateTests` → `PaneEmptyCopyTests`). Two
renderers now read one table instead of two pinned halves, and there is nothing left for a ratchet to
keep honest. `CopyReceiptChip.dwell` went the same way, onto `CopyReceipt` beside `ChipNotice.dwell`
which was already there.

- **THE HIT-TRANSPARENCY MISTAKE HAS A SECOND FACE IN APPKIT.** The SwiftUI chip stack's note says the
  flag is per chip and never on the stack, because `allowsHitTesting(false)` on an ancestor deafens
  everything composed into it — the connection chip's `Button` included. AppKit adds a failure the
  SwiftUI half cannot have: a container whose `hitTest` returns SELF swallows every point inside its
  bounds *even where no chip is drawn*, which over a terminal is a dead rectangle sitting at the prompt
  line. So three separate statements replace one modifier — the stack answers `nil` for itself, each
  paper capsule answers `nil` for itself, and only the alert chip answers with a view.
- **A `Timer` block is `@Sendable`, and a bare closure is not — even inside a `@MainActor` class.** The
  chip's dwell expiry could not be captured; it is a stored property reached back through `[weak self]`.
  This is the same shape increment 60 recorded for `runAnimationGroup` completions (`@MainActor` classes
  are implicitly `Sendable`, closures are not), arriving through a different API. Two APIs, one rule:
  **hold the thing, do not capture the call.**
- **A tracked read that only runs on one branch stops tracking.** `MacContentCanvas` resolves the empty
  cause UNCONDITIONALLY inside `withObservationTracking`, not inside the `if` that decides whether the
  empty state is shown. Reading it only on the empty branch would deregister the connection the moment a
  tab exists, so the state would come back later still saying whatever it said last time. SwiftUI's
  re-evaluated body has no such trap; every hand-rolled `withObservationTracking` in this target does.
- **`isHidden` is still forbidden, and R12 is where it would have looked safe.** "No active tab" does
  not mean "no mounted tabs" — the retained sessions' tabs are still mounted under the canvas, and
  hiding it would stop `layout()` for all of them. The canvas fades to `alphaValue = 0`; only the empty
  state, which owns no surface, may hide.
- **The supervisor caught a doc link, again.** The chip-stack header named `MacPaperCapsuleView` for a
  type that ships as `MacNoticeCapsuleView`. That is the second time in this wave a gate has caught a
  file naming a symbol it guessed rather than one it declares (58's was `GuiUploadTint`'s row pointing
  at the wrong file), and both times the guess was in prose, where nothing else in the build looks.

### Increment 62 — F3, and a debt ledger that named its symbols and went stale

**F3 is paid, and it cost a twentieth of what the ledger said.** Increment 57b recorded two Mac
snapshot rigs crossing into the draining floor for "`SlateProjectIsland`, `SlateSearchField`,
`SlatePlateStyle` and `StatusDotView`", allowlisted them, and left the design call for the fold.
Checked against the tree in this increment, **three of those four names appear only inside doc
comments**, and `MacChromeSnapshotRender` used *nothing at all* — its `@testable import` had been dead
since increment 46 moved the marks to `NSView`s, and 46's own note ("after this increment no
`SlopDeskMacUI` file uses `StatusDotView` at all") is the sentence that emptied the claim without
anybody re-reading the gate it was written into. The real debt was one rig and two SwiftUI helpers:
`SlateProjectIsland` and the `slateChromeFieldPlate()` modifier, twelve lines of body between them.

**What paid it was not a move and not a port — it was reading the SHIPPING tokens.** Both helpers were
re-derivations of material the Mac column already resolves natively, so `MacRailStatusRollupRender`
now spells the bed as `Slate.Native.ProjectTint.bed(at: 0)` at `islandRadiusCompact` inside
`projectIslandInset`, and the field plate as `Slate.Native.State.hover` behind a `hairline` of
`Slate.Native.Line.field` at `radiusControl` — exactly what `MacNavigatorColumn` sets on its own
`plate` layer. This is strictly better than what it replaced, and for a reason that outlives F3: a
fixture that re-derives a colour through the *other* renderer's spelling cannot show a drift between
the two spellings, which is the one thing a Mac pixel rig exists to catch. The gate's own comment had
predicted the shape of the fix ("a harness moving, or the views it mounts becoming AppKit") and got
the third option wrong — nothing moved and nothing became a view; the fixture stopped deriving.

**Both halves of the edge are now facts.** The `Tests/` import ban lost its allowlist and is flat, the
way its own retirement note prescribed; and `Package.swift` lost `SlopDeskClientUI` from
`SlopDeskMacUITests`' `dependencies:`, with a new manifest gate beside the increment-61 one that cut
the same edge for `Sources/`. Both were break-tested. The stale manifest comment justifying the
dependency ("the chord suites drive the real `WorkspaceKeyDispatcher` against seams the shared view
target still owns") named a dispatcher that lives in `Sources/SlopDeskMacUI/Input/` — a third stale
justification found in the same hour as the first two.

**What this increment is really about:**

- **A debt ledger that names the symbols it is waiting on rots silently.** Nothing re-checks a comment.
  The allowlist stayed *correct* the whole time — the two files did import the floor — while its
  stated reason decayed to fiction, and every later reader (including the fold plan at §3.5 step 5 and
  the F3 sentence in the plan itself) inherited the fiction. What replaced it checks only the thing
  that cannot rot: whether the import line exists. **Ratchet the fact, describe the reason, and never
  let the description become the check.**
- **A dead `@testable import` is invisible to the compiler and loud to a gate.** Two of the three
  imports removed here (`SlopDeskClientUI` in `MacChromeSnapshotRender`, `SlopDeskClientCore` in
  `MacRailStatusRollupRender`) resolved to nothing at all. Swift does not warn on an unused import, so
  the only proof is deletion plus a build — and the only thing that made anyone look was a gate
  counting them as a blocker.
- **The `some View`-in-the-floor ratchet did its job by being un-negotiable.** The obvious cheap fix —
  move `SlateProjectIsland` down into `SlopDeskSlate` where both halves can see it — is exactly the
  "two renderers become one renderer plus a fallback" failure the floor gate was written for, and
  being unable to take it is what forced the better answer.

### Increment 63 — the fold lands, and five gates that agreed for the wrong reason

**`SlopDeskClientUI` is gone.** 98 files are `Sources/SlopDeskPhoneUI/`, the `.library(name:
"SlopDeskClientUI")` product is deleted, the five-dependency `SlopDeskPhoneUI` stub target it was
going to become is deleted, and every file in the target carries exactly one directive: the whole-file
`#if os(iOS)` of §3. F1, F4, F4c and F5 landed together, because they had to — renaming the target is
what ARMS the gate that forbids a macOS arm inside it, so the move could not be green on its own.

**F1 came in at 80 + 14 + 4, and the recount's three buckets each behaved differently.** The 80 with a
whole-file guard were one `perl` line. The 14 with inner arms were four agents split by directory, and
every trap the recount predicted was real: `SlateSearchField` and `PaneMoveEscapeMonitor` each needed
the macOS arm's BODY deleted (the iOS declaration survives with an identical name and signature, so
their call sites never noticed); `SettingsInk.swift:156` dropped both the `NSFont` arm and the bare
`13` fallback; `NotificationPermissionRow.swift:77`'s `#elseif os(iOS)` chain had no trailing `#else`,
so nothing was lost promoting the second arm.

**Bucket E's question had an answer, and it was neither of the two on offer.** The four
directive-less files do not descend and did not stay as they were: every one of them is *typed* in
SwiftUI — two are `EnvironmentValues` extensions, one vends a `Binding`, one is a `@MainActor enum` of
`Color`s — so `SlopDeskClientCore` cannot name them and §3's "belongs in the shared logic target" does
not apply. They needed the guard ADDED, and they needed it urgently rather than cosmetically: with the
other 80 files gated to `os(iOS)`, an unguarded file still compiles on the macOS host triple, against
types that no longer exist there. Left alone they would have broken `swift build` outright.

**F0 was paid by dissolving the target, not by guarding it.** The recount priced normalising bucket A
as "thirty-two test files leave the default gate silently"; increment 62 drained that to eleven, and
this increment took the last step the drain implied. `Tests/SlopDeskPhoneUITests` is no longer a
SwiftPM target at all. On the macOS triple `SlopDeskPhoneUI` now compiles to nothing, so `@testable
import`ing it yields an EMPTY module — a suite over it can only be files that fail to compile or,
guarded to match, assert nothing, and neither is a test. Six files moved to
`Apps/ClientApp-iOS/Tests/`, where `make check-ios-tests` runs them on a booted simulator; three
`ImageRenderer` visual rigs moved with them, ported AppKit → UIKit with every `SLOPDESK_*` env name,
`XCTSkip` message and `print` line byte-identical, because those strings are the interface the
pixel-verify recipes drive. Two were deleted: the `L0Placeholder` whose entire purpose was keeping an
otherwise-empty target compiling, and `SlateSearchFieldCoordinatorTests`, which drove the AppKit arm
this increment deleted.

**FIVE GATES WENT ON PASSING WHILE THE THING THEY WATCHED MOVED OUT FROM UNDER THEM.** This is the
increment's real finding, and it is the same failure as increment 62's ledger wearing five costumes.
A rename does not break a gate; it makes the gate true about something else.

| Gate | Still green because | What it now asserts |
| --- | --- | --- |
| `mac_target_block` / `mac_test_block` | the `awk` anchored on `name: "SlopDeskMacUI"` alone, which also matches the `.library(…)` PRODUCT line — so it read a second, spurious region starting in the products list. Increment 63 put `.library(name: "SlopDeskPhoneUI", …)` in exactly that gap | anchored on the `.target(` line, so it reads one target's own block |
| `ui_edges` | a blanket rename turned two of its four entries into a duplicate and a SELF-edge (`PhoneUI` may not import `PhoneUI`) — a rule no file can break | two halves, two edges |
| `ui_test_edges` | `[[ -d "${test_dir}" ]] \|\| continue` — the phone's `Tests/` directory ceased to exist and the ban went quiet | a missing directory is a stale ledger, and FAILS |
| `SettingsControls.swift` "exactly one `#if os(`" | `Half.current`'s `#if os(macOS)` became a constant, and the whole-file guard took the slot. The count still read 1 | `Half.current` exists AND does not fork |
| `test-touched.sh` scripts/ attribution | it named `SlopDeskPhoneUITests`, so a scripts-only edit would have attributed to a target that no longer exists and run clean | the two suites that actually own the gate-contract tests |

All five, plus the two manifest edges, were re-run against a deliberately broken tree — F5's stated
obligation, and the reason it is stated: **four of the five were caught by re-pointing, not by
running.** A gate re-run without being re-aimed proves only that it still exits 0.

**A rule stated as a COUNT cannot say which thing it counted.** The `SettingsControls` ratchet is the
cleanest specimen: "exactly one `#if os(`" was written about `Half.current`, kept reading 1 after
`Half.current` stopped having one, and would have gone on passing forever. It is replaced by a
target-wide gate that names the SHAPE it wants — every file in `SlopDeskPhoneUI` carries exactly two
directives, one `#if os(iOS)` at column 0 and one `#endif` — which also closes a hole the old
platform ban never covered: an inner `#if os(iOS)`, always true in this target, sailed straight
through a check that only forbade the platforms the phone does not build for.

**Two duplicates the fold exposed, both now collapsed.** Deleting the AppKit arm of `slateCancelKey`
left it byte-identical to the `.onKeyPress(.escape, phases: .down)` that `PaletteView`,
`OpenQuicklyView` and `GlobalSearchView` each wrote inline — all three under a comment explaining that
they were deliberately NOT using the modifier *because it exists to carry the macOS responder-chain
half*. The reason was true when written and the code outlived it. Separately, `MountTestPaneSession`
turned out to be byte-identical to `FakePaneSession` from `@MainActor` to its closing brace, and the
iOS bundle already compiles the real one — so the phone's copy went with the move rather than through
it. The Mac's copy stays: `SlopDeskMacUITests` genuinely cannot reach `FakePaneSession`.

**A blanket rename across DATED records falsifies them.** The sweep that renamed the target also
rewrote 30 night-handoff, plan and superseded-design documents, so a 2026 handoff came to cite
`Sources/SlopDeskPhoneUI/Workspace/Views/PaneStatusIndicator.swift` — a path that did not exist on its
date and does not exist now. This document was swept too, which turned F5's own instruction into
"every gate naming `Sources/SlopDeskPhoneUI/…` re-points" — re-points to *what*? All 30 were restored
to their committed text after proving, file by file, that every difference was a `ClientUI`/`PhoneUI`
token and nothing else. **A record is a claim about a date. Only live reference docs get swept** —
here that is 22, 30-ui-architecture, 46, 47, 48 and `ui-shell/current-state/`.

### Increment 64 — the palette listed 33 of 77, and only a phone could tell

The split was structurally done at 63. This is the first increment about what the split *promised*:
the iOS app differs in LAYOUT, never in capability.

`WorkspaceBindingRegistry` declares 77 rows and `ActionsPaletteSource` hand-wrote 33. On a Mac that
gap is invisible — the menu bar reaches every binding, so the palette's job there is speed, not
access. A phone has no menu bar. With no hardware keyboard attached the palette IS the command
surface, so roughly 45 verbs — every focus move, every resize nudge, every scroll jump, Vi mode,
hint mode, the block jumps, Release Stuck Input, Paste as Keystrokes — could not be said at all.
`binding_rows.rs`'s own module doc had already written the number down ("~45 rows with no palette
entry at all") as an argument for keeping two id spaces. It was right about the id spaces and the
sentence was also a bug report.

Two things landed, and the second is why the first is not a second catalog.

**The rows are DERIVED.** `registryRows` reads `WorkspaceBindingRegistry.bindings` — already
filtered by `binding_rows.rs`, so a half that cannot run a verb never sees a row for it and the new
source carries no platform gate of its own. Two verbs are excluded, and that is the whole exclusion:
`.commandPalette` (it opens the surface you are reading) and `.selectPane` (the nine ⌘1…⌘9 chords
collapse to one display row whose TITLE promises a range, so answering Return by selecting pane 1
would be a row that lies). Hint chips come from each verb's own chord, so a rebind moves the glyph.

**And the join is derived too.** `coveredActions` is read off the catalog's own rows rather than
listed beside them, which was only possible after the second half of the change: 24 catalog rows
carried a `.store` closure that restated its `route` arm line for line, so every verb the palette
and the keyboard share had two implementations. One had already drifted — `action.splitRight` called
`splitActivePane(axis:kind:)` where `route` called `newTerminalPane(.split(axis:))`. They happen to
agree today. Nothing said they had to.

Those 24 rows are `.binding(_)` now, and six `PaletteAction` cases went with them (`openCheatSheet`,
`toggleSidebar`, `toggleCodeSidebar`, `focusCodePanel`, `togglePinWindow`, `closeWindow`) — each of
which named a registry verb and then re-implemented that verb's route arm inside the coordinator.
`OverlayCoordinator.routeBinding` hands `route` the overlay switches it asks for, which makes it the
third caller of the one dispatch, beside `WorkspaceKeyDispatcher` (the Mac's NSEvent monitor) and
`WorkspaceStore.overlayKeyToggles` (the phone's per-pane interceptor).

Two smaller consequences fell out. Recents used to be five hand-picked `recordRecentCommand` calls
buried in five run arms, so the MRU block answered "which verbs did someone remember to instrument";
every accepted verb is a recent now. And `PaletteCategory` gained `.focus`, because the registry has
a Focus category and the palette had nowhere to put it.

| Gate | Where | What it pins |
| --- | --- | --- |
| `PaletteReachesEveryBindingTests` | `Tests/SlopDeskClientCoreTests` | every binding runs from some row; no verb listed twice; no id collision; every derived row lands in a section `commandOrder` walks; every hint chip equals the registry glyph |
| derivation shape | `check-supervisor.sh` | `registryRows` reads `WorkspaceBindingRegistry.bindings` and `coveredActions` reads `declared` — a transcribed list would go stale in silence |
| no seventh case | `check-supervisor.sh` | the six deleted `PaletteAction` cases stay deleted; a row that names a registry verb IS that verb |

The reach test is asserted as a SHAPE, not a count — a new binding is reachable the day it is
declared. That is the lesson increment 63 paid for five times over: a gate stated as a number goes
green about the wrong thing the moment its subject moves.

### Increment 65 — three clipboard questions the phone answered on the user's behalf

The same class as 64 and a worse instance of it: not a verb the phone could not reach, but a
DECISION the phone made for you, silently, while showing you the switch that was supposed to make it.

`GhosttyTerminalView`'s `confirm_read_clipboard_cb` had a `#else` arm that auto-approved both an
unsafe paste and an OSC-52 clipboard READ — the second one ignoring `TerminalControls.clipboardRead`
entirely — and `write_clipboard_cb`'s `.confirm` arm dropped the write. So on one account, on one
mesh, `clipboard-read = ask` read as **Allow** and `clipboard-write = ask` as **Deny**, depending
only on which device you picked up. Settings ▸ Controls offered all three on the phone.

Every word the two halves say is still `slopdesk_terminal::paste`'s. What the halves were each
deciding for themselves was the SHAPE — bullets or the ask's reason, whether the preview is shown at
all, the bullet glyph, the caption — so that is what crossed, as `ClipboardConfirmPresentation` in
`SlopDeskClientCore`, including `informativeText` (the single-string join an `NSAlert` needs, which
is a serialisation and not a layout, so it is composed once rather than beside a dialog).

Two things about the phone's renderer are departures from the overlay family, both on purpose:

- **An in-window layer, not a `.sheet`.** Connect, Settings and First Launch are real sheets because
  the user summons them. This one is raised by a remote PROGRAM at a time nobody chose, and the
  system's modal stack silently declines a second presentation — behind an open sheet the
  presentation would be dropped with libghostty still holding the request, which is a hang, not a
  wrong answer.
- **The floor absorbs and does not dismiss.** A tap beside the card is not an answer to "may this
  program read your clipboard?", so it does nothing — exactly as an `NSAlert` has no click-away. The
  floor is still a real control, so the terminal underneath cannot be typed into while the question
  is up.

The Mac's `PasteProtectionSheet` adopted the shared type in the follow-up: its private
`informativeText` was, from the moment `ClipboardConfirmPresentation` existed, a second copy of the
same join, and adoption was a pure deletion. `check-supervisor.sh` now pairs the two renderers on it
the way it already pairs `MacCloseConfirmation` and `OverlayHostView` on `CloseConfirmationCopy`:
each half must READ the shared type, and neither may respell the bullet or the caption.

`ClipboardConfirmRequests` is the seam the two frameworks force: `NSAlert.beginSheetModal(for:)` can
be called from inside a C callback because the presenter IS a function, and SwiftUI has no such
function. So the callback asks a mailbox and a mounted card drains it. Two rules live there rather
than in the renderer, because both are about libghostty's state and not about drawing: a request is
answered exactly once (the entry is removed BEFORE the completion runs), and a second question
QUEUES rather than replacing — replacing would decide the older one, which is the whole gap.

### Increment 66 — ⌃⌘O flipped a `Bool` nobody drew

The third of the same family, and the one that shows why "is it wired?" is the wrong question. The
Command Navigator was wired end to end on the Mac: `row("view.commandNavigator", Platform::Both)` in
`binding_rows.rs`, the action in `WorkspaceBindingRegistry`, the arm in `WorkspaceBindingRouting`, the
fan-out in `WorkspaceStore+Blocks`, and — this is the part that made it invisible — the SINK itself,
`onRequestBlockNavigator = { chrome.isVisible.toggle() }`, bound in the SHARED `TerminalPaneWiring`
and called from `MacTerminalLeafView.attach()`. Six links, all live. What the Mac did not have was a
READER of `CommandNavigatorChrome.isVisible`. The chord took a keystroke away from the PTY, toggled a
flag, and nothing happened — and no gate can see that, because every gate this repo has asks whether
a producer exists.

`MacCommandNavigatorView` is that reader. It is a SECOND DRAWING, not a port: the row filed
`Platform::Both` means both halves render, so the phone's `CommandNavigatorView` stays exactly where
it is (docs/56 §3.5 step 4). Everything underneath was already shared before this increment —
`TerminalBlockModel.blocks(filter:)`, `CommandNavigatorModel.filtered(_:query:)`, `ListNavigation`,
`WorkspaceStore.jumpToNavigatorBlockInActivePane`, `OutlinePresentation`, `FuzzyMatcher`,
`HoverSelectionGate` — so what crossed here was only the card's own vocabulary:
`CommandNavigatorPresentation` (a placeholder, four zero-state sentences, three footer hints, two
help strings) and `CommandNavigatorMetrics` (`panelWidth` 480, `resultsMaxHeight` 320), on the
`PaletteMetrics` / `FindBarMetrics` precedent. **The phone adopted them in the same change** — a
shared type with one consumer is not a shared type, it is a third copy waiting to be forgotten.

Two things the AppKit half had to answer that the SwiftUI half never did:

- **The card is `.above` everything in the leaf, not a slot beside the chip column.** `cover(_:)` is
  `fill(_:below:)`'s other side. A modal over a pane that leaves its own chrome clickable is not modal.
- **`TerminalPointerShield` had to learn a second question.** It was bound to
  `overlay.anyModalVisible`, which is the OVERLAY COORDINATOR's flag — and the navigator is mounted
  inside one leaf, deliberately, so a card over one pane does not deafen the sidebar. An
  `NSTrackingArea` is rect-based, so a mouse-reporting TUI under the card would go on receiving
  pointer positions through it. The shield is process-wide either way, so the two questions can only
  be joined at the binding: `overlay.anyModalVisible || MacPaneCardShield.isPresenting`.

### Increment 67 — the rename walked through forty thousand lines of comment

Increment 63 folded the shared SwiftUI target into `SlopDeskPhoneUI`. The manifest was ratcheted, the
imports were ratcheted, the tests moved — and the prose was not, because nothing had ever asked it a
question. Nine live citations of `SlopDeskClientUI/…/Foo.swift` were left pointing at a target that no
longer exists, each one a sentence telling a reader where the other half of a decision lives; a DocC
link into a deleted module renders as prose and reads as a fact. Eleven more were already stale from
earlier moves, including two `rust/slopdesk-superd/src/spawn.rs` (it is `slopdesk-posix/src/pty.rs`)
and one `rust/slopdesk-screend/src/overprint.rs` (it is `slopdesk-sanitize`'s).

`live_docs_cite_files_that_exist` had gated the sixteen documents `CLAUDE.md` sends a reader to since
the day `docs/45` claimed a mitigation for a test that had moved to Rust. Its sibling,
`source_comments_cite_files_that_exist`, does the same for the other half of the prose, and the rule is
SHAPE so it cannot decay: a backticked token with a slash in it and a source suffix on the end IS a
path claim, so it must resolve — as a repo path or as the tail of one. What it deliberately does not
check is NAMES. A module name is not a path, and history that says "it descended from the old shared
SwiftUI target" is honest and stays legal; what is not legal is sending someone to a file.

The one judgement in it is `_addressable_first_segments`, and it is derived rather than listed: a
citation is a claim about THIS tree only when its first segment is a repo root or a directory one
level inside `Sources` / `Tests` / `Apps`. Everything else a comment legitimately quotes —
libghostty upstream's `Helpers/Cursor.swift`, `Carbon/HIToolbox/Events.h`, a runtime
`$XDG_CONFIG_HOME/slopdesk/config.toml` — is not in the tree and must not be, and a gate demanding
otherwise would be demanding the comment lie.

### Increment 68 — the phone had one notification surface because a `#if` said so

`CommandCompletionNotifier` was `#if os(macOS)` from line 166 to the end of the file, and
`ClientComposition`'s header called the three nil sinks on iOS "the honest statement that the in-app
toast is its only notification surface". It was not honest, it was circular: the toast was the only
surface because the poster refused to compile, and `UserNotifications` is the same framework on both
triples. A phone is the device MOST likely to be face-down while a long build runs, which makes this
the one platform where a banner is not a nicety.

The gate is gone — the file now has zero preprocessor directives — and both entry points install all
three sinks over one `CommandCompletionNotifier` and one `PaneNotificationRouter`. What differs is the
ACTUATION inside the closures, which is what a sink is for: the Mac bounces its Dock tile and plays
`NSSound(named:)`, and the phone attaches a `UNNotificationSound` to the request it is already
building. `AgentSoundPolicy` is untouched — one decision, two presenters.

`bannerSound` returns `.default` for BOTH agent edges, deliberately. `Submarine` and `Glass` are
`/System/Library/Sounds` files iOS does not ship, and `UNNotificationSound(named:)` resolves against
the app bundle, so naming them would fall back to the default anyway while READING as if the phone
had the Mac's two-tone vocabulary. Bundling two audio files to invent one is a second sound world.
What survives the trip is the part the two toggles actually control: ring, or stay silent.

Nothing was needed in `Info.plist` and no capability was added. iOS local notifications require no
entitlement — the runtime grant IS the capability, and the notifier's lazy `requestAuthorization`
asks for it on the first event that survives the toggles. `aps-environment` belongs to remote push,
which this app does not do. The real limitation is stated rather than hidden: `handleScenePhase`
pauses the connection on background, so an event arriving while the phone is locked lands on the next
foreground. Closing that gap needs a push channel, not a plist key.

### Increment 69 — the numbers both languages knew, and the gate that could not see them

`check-shared-constants.py` is birth control: it stops a number being spelled on both sides in the
first place, and says nothing the day one of the two spellings moves. That makes its BLIND SPOTS the
interesting part, and they are now written down in the file's header rather than discovered one pair
at a time — pairing is by normalised NAME, so a Swift default ARGUMENT (`HintLabelAssigner`'s bare
`4096` against `link::MAX_SCAN_COLUMNS`) pairs with nothing; it fires only on EQUAL values, so a pair
that has already drifted reads as two different constants; `SWIFT_BIT` sees only the
`Self(rawValue: 1 << N)` form; the enum pass needs explicit discriminants on BOTH sides; strings are
out of scope entirely. Two of the five were closed rather than just named: an expression evaluator
(`int` literals, `*`, `+`, `<<` — no names, no parens, no `eval`) so that `15 * 1024 * 1024` is read
as a number at all, and a HOMONYM allowlist re-keyed from the bare name to `(file, name)`.

That re-keying is the finding, not the tidying. A name-keyed entry exempts every pair sharing that
name in every file, forever — so `currentSchemaVersion`, written for three unrelated stores whose
versions are 1, 1 and 3, was silently covering a FOURTH pair that was the real thing:
`TreeWorkspace.currentSchemaVersion = 12` against `slopdesk_tree::CURRENT_SCHEMA_VERSION = 12`,
the two halves of the comparison that decides whether a saved workspace loads or is set aside.

Seven doors were what the pairs it could finally see turned into: `slopdesk_ws_schema_version`,
`slopdesk_ws_max_string_bytes`, `slopdesk_phone_floating_cursor_run_capacity`,
`slopdesk_replay_constant`, `slopdesk_video_packetizer_flag`,
`slopdesk_video_reassembler_frame_flag`, and two more indices on `slopdesk_workspace_constant`.
Four of them are INDEX-SHAPED — one door vending a small family read together — because a family of
five should not become five entry points, and an index nobody defined answers a value the family
cannot hold (`-1` where the answers are lengths, `0` where they are bit masks). The flag doors earn
their place twice over: a bit position is the worst thing in the tree to transcribe, because the word
is ORed on one side and ANDed apart on the other, nothing on the wire pins it, and a side that
disagrees produces no decode failure — just a keyframe encoded as a delta.
`slopdesk_settings_stepper_unit` was deleted in the same change for
`slopdesk_settings_stepper_readout(stepper, value, …)`: the unit crossed so that each side could
compose the readout from the value it holds, both sides then did, and only one of them dropped a
whole value's fraction.

One latent bug fell out of the audit rather than out of a test. `FloatingCursor.feed` sized its
output buffer by hand and had no retry, while `encode` beside it did — and the Rust door writes
NOTHING when `needed > cap`. The buffer was large enough today, so the failure was not reachable
yet; the day the arrow cap or the escape width moved, the phone would have shipped a run of NUL
bytes to the PTY and no test would have said which side did it. The capacity is a door now, and the
caller retries like its neighbour.

### Increment 70 — the phone drew a VI pill over a dispatch with no caller

Copy Mode and Hint Mode were reachable on the phone — the chord armed, the pill drew — and no key
ever reached either dispatch. The audit's premise was that the copy-mode vocabulary lived in the
`NSEvent` adapter and had to be lifted; it did not. `handleCopyModeKey` and `handleHintKey` were
already pure and already shared, over an abstract `CopyModeKey` / `HintKey`. What was missing was the
phone's three-line adapter INTO them, and a responder that asked the mode before it asked the text
proxy.

The ORDER is the whole bug in one line. Copy mode's vocabulary is mostly bare letters, and bare
letters are exactly what `PhoneKey.routesToKeyEncoding(_:)` hands to the text-input proxy — so asked
in the other order, `j` composes into the shell while the pill says VI. `takesModalKeys` is now
checked first in `TerminalInputHost`, routed through the same `KeyRepeater` as everything else, and
`insertText` is covered too so the on-screen keyboard works and not only a hardware one. Inside the
mode, hint is asked before copy (hint can be armed ON TOP of copy — `f` is one of the ways in), and a
⌘ combination is never taken: on macOS the app's dispatcher intercepts those before the surface sees
them, and on iOS every press reaches the responder, so the exemption has to be stated. ⌃⇧Space stays
a workspace chord inside vi mode for the same reason.

`slopdesk_phone_modal_key(hid_usage)` is the door — a projection of the ONE HID table that
`special_key()` already reads, not a second table, and it takes a USAGE rather than a whole press
because nothing about the answer reads the layout or the modifiers (`⌃v` in copy mode is the
visual-block key, not an Escape). Seven values, six keys and a NONE; everything else, special or not,
reaches the mode as its CHARACTER, which is the same collapse the Mac's adapter ends on.

Two `#if canImport(AppKit)` gates came off in the same change, and each was hiding a live defect
rather than a platform difference. `copyToPasteboard` was an EMPTY closure on the phone while every
caller raised the `COPIED` receipt anyway — a yank that reported a copy that had reached no
pasteboard, over `ClientPasteboard.write(_:)`, which is cross-platform and always was. `beep` was a
no-op, and the honest phone analogue is not a sound: a Mac's speaker is on, a phone is usually
SILENCED, so the audible half of a beep is the half a phone throws away. `.rigid` haptic — a short
hard tap, because the cue is a REFUSAL — survives the ring switch and needs no audio session the
terminal does not own.

### Increment 71 — the settings index advertised every key on both halves

Increment 64 gave a palette verb a platform and increment 65 gave a keybinding one. The FLAT INDEX
behind Advanced → All Settings still had none, and it is the surface where a listed row does the most
damage, because a row there is not a menu line that does nothing when pressed — it is either a live
control or a ✎ into a page. The phone rendered a working switch over `notifications.bounceDock`,
writing a `UserDefaults` value no Dock on that device will ever read, and four rows — the two
Dock-icon flags and the two secure-input flags — rendered a ✎ that jumped to Appearance and Controls
pages carrying no such group at all. Every one of those decisions was already made, once, in
`settings_layout`: the enclosing group is `Platform::Mac`, and has been since the layout table
landed.

So the index does not get a `platform` column. It ASKS the page table — a row is advertised on the
half that draws a control for it. A column would have been the same answer written down a second
time in a table nothing joins to the first, which is the `MIN_WEIGHT`/`MAX_DEPTH` shape docs/55 §8
names one register up: two spellings of one meaning, agreeing right until somebody moves a group
between pages. The counter-argument for keeping every key listed was that a key still compiles and
round-trips on iOS. True, and beside the point — what the phone rendered was not a key.

Eight keys are named by no layout row at all, because a `Control::Bespoke` group names no keys: the
five font families, the auto-match flag and the two cursor fields, each edited by a hand-built
surface. Those fail OPEN, the same default `palette_rows` and `binding_rows` take, for the same
reason: withholding a row on a guess is silent, while advertising one is visible and is what a test
can bound. The Rust gate walks `Section::ALL` → `groups(section, mac)` → `rows(group, mac)` — the
same walk a renderer makes — and asserts the index matches it, so the derivation cannot drift from
what is actually drawn; a second gate pins that every undescribed key is a `HasDedicatedTab` jump
rather than an inline control nobody can reach. `slopdesk_settings_row_shown(index, mac)` is the
door, `mac` rather than a far-side `cfg!` for `BindingRowPlatform`'s reason: the flag has to cross so
a Mac can ask what the phone lists, which is the only place the answer is interesting.

Two rows in the older tables were wrong in the same way and were flipped with them.
`action.secureKeyboardEntry` / `view.secureKeyboardEntry` toggle a process-global `AppKit` call, and
`TerminalViewModel.refreshSecureInput()` is a literal `false` off macOS — that row is chord-LESS, so
what it cost the phone was a cheat-sheet line and a keybindings editor offering to bind a chord onto
it, not a stolen key. `action.closeWindow` / `window.close` is subtler, and the audit that found it
had the chord wrong (⌘⇧W, not ⌘W): its routing arm is not an empty closure but a FALLBACK to
`WorkspaceStore.requestCloseWindow()`, which parks `pendingWindowClose` — and the only reader of that
park is the Mac's `windowShouldClose` gate. The phone's close confirmation answers the pane and tab
parks and has no arm for this one, so there was no phone-side meaning to preserve. Downstream, the
phone's `AllSettingsListView` lost the Dock-bounce case and its `@Default` binding: a case kept for a
row the list withholds is a control nobody reaches, which is the defect this increment closes, one
register in.

Making the index derive its platform also settled a claim the layout had been making unchecked, and
it was wrong. `notifications.agentSoundTaskComplete` and `notifications.agentSoundAwaitInput` were
`Platform::Mac` on the stated grounds that they name `NSSound` files iOS does not ship. What the two
toggles decide is not the FILE, it is ring or stay silent — `AgentSoundPolicy` decides that once and
each half spends the verdict its own way, macOS on Submarine/Glass and the phone on the default
`UNNotificationSound` attached to the banner, which `CommandCompletionNotifier.bannerSound(for:)`
already documents at length. Both rows are `Both` now, and the phone's Shell page had been carrying
their bindings all along, unreachable behind a gate that should not have been there. The audit
reported them as inert phone toggles; they were the one thing on its list that worked.

### Increment 72 — the phone could read the terminal and take nothing out of it

Selecting text is the oldest thing a terminal does, and the phone could not do it. The Mac's path is
a press, a motion and a release forwarded to libghostty, which owns the selection state, its
painting, its granularity and the extraction — the AppKit view only forwards. A phone has none of
those events, because a touch is ambiguous until it has lasted long enough to say what it is, so the
long press synthesises the SAME triple: `.began` → `sendMousePos` + `PRESS`, `.changed` →
`sendMousePos` (the head extends), `.ended` → `RELEASE` and the edit menu. Nothing on this path
measures a cell: the touch point crosses as POINTS and libghostty resolves the cell, so there is no
second copy of the grid geometry.

Contention with the scroll pan is settled by a STATE FLAG, not `require(toFail:)` — the latter would
put 0.4s on the pane's commonest gesture to buy an arbitration the flag settles for free, and the two
are already disjoint (a finger that travelled far enough to pan cancelled the press long before
recognition). The flag is held one runloop turn past the release, because UIKit does not guarantee a
tap fails just because the finger rested, and a stray tap would send press+release and wipe the
selection; a generation counter keeps an older gesture's deferred clear from un-arming a newer press.

Edge autoscroll is armed in `.changed` and pumped from `renderTick`, since a finger held still at the
edge produces no more events and the tick is the only thing left running. The ramp, the two
thresholds and the "does a release present a menu" rule live in
`Sources/SlopDeskClientCore/Pane/TerminalTouchSelection.swift` rather than in the UIKit view — pure,
so the ramp is pinnable without a touch, and reachable the day a trackpad drag on an iPad runs
through it.

`UIEditMenuInteraction` is built from the SAME `TerminalContextMenu.items` + `isEnabled` the Mac's
`menu(for:)` uses, with the same symbols, and every Mac item is carried: Cut through the same
`CutSelectionPolicy`, Paste through the same `PastePrecheck` and the clipboard-confirm seam, "Paste
File Base64-Encoded…" through a document picker into the same `PasteTransform.base64`. The system's
`suggestedActions` are dropped deliberately — they are a `UITextInput`'s Copy/Paste, and two Copies
with different meanings in one menu is worse than none. Two ceilings are honest ones: word-granularity
snapping would need a second copy of `vimotion`'s word walk (the fork's delta carries no word range
and no click count), and the LINK items need `detectedLink(at:)`, which still lives in the macOS
block.

Two sinks the audit sent this change after were bound on the way: `onResizeSettled` → a present, with
NO settle burst (this half's `drawNow` is size-unconditional, unlike the Mac's async present, so the
burst array would have been copied for nothing), and `onReclaimKeyboardFocus` → a pane-local re-claim
over the smallest ancestor subtree holding exactly ONE focusable host. That last one contradicts the
audit and is documented in the code as interim: `PaneFocusCoordinator.reassertFocus(_:)` is keyed by
`PaneID`, and the renderer view carries none — the real home for the binding is
`TerminalPaneWiring`, where `live.id` and the coordinator are both in hand. Two smaller gaps fell out
of the same attach: `onClipboardWrite` was unbound, so the `COPIED · N` chip the phone DOES draw never
lit, and `isAlternateScreen` read a hardcoded `false` in the paste backstop.

### Increment 73 — three hooks the overlays stopped listening to, and nobody said so

`onRequestCopyMode`, `onCopyConfirmation` and `onRequestViKeyHints` were declared, documented, fired
from four call sites and asserted by six tests. Nothing in either half of the client bound one of
them. Both overlays had moved to the OBSERVABLE twins — `copyModeBadgeActive`, `showViKeyHints`,
`copyReceipt` — because the renderer's `keyDown` reads `isCopyMode` from inside the AttributeGraph
update path and must not register a SwiftUI dependency. The callbacks were what that migration left
behind, and firing an unbound optional is a silent no-op, so nothing ever failed.

The tests are why it lasted. A test that binds the sink and counts its calls PASSES — it proves the
model fires, which was true, and says nothing about whether anything is listening. Two of them were
rewritten to pin the CONSEQUENCE rather than the call: idempotent `enterCopyMode` is now pinned by
typing a pending count and re-entering (a re-arm would call `resetViState` and swallow it), and the
copy receipt is pinned by its own label and epoch, which is what the chip actually draws.

The ratchet is `every_injected_sink_has_someone_who_binds_it` in `scripts/check-invariants.py`, and
it is deliberately not a name list: it collects every `public var onX: (…)` declared under `Sources`
and requires an assignment somewhere in PRODUCT code — `Sources`, `Apps` or `ThirdParty`, including
the declaring file, since an `init` that stores the closure to `self` is a binding made by whoever
calls it. Tests do not count, which is the whole point. It reads 75 sinks today and finds none
unbound. This is the shape the two-headed client makes easy: a sink one half binds and the other does
not looks alive from everywhere except the half that is silent.

### Increment 74 — the phone veiled every pane and drew nothing over them

⌃⇥ opened on the phone. `store.paneSwitcher` armed, `PaneRecedeScrim` veiled every pane, and the card
that says WHICH pane you are walking towards did not exist — because `check-supervisor.sh` forbade
it by name: "the ⌃⇥ readout is AppKit only". The ban's premise was that the phone has no modifier
stream, so a SwiftUI half could never render. That is a statement about the opening CHORD, and the
chord was never the only way in: the binding row is `Platform::Both` and the palette carries the same
row, which the phone can now reach without a keyboard (increment 64). A veiled workspace with no way
to step, commit or cancel is a soft lockup, and a gate was holding it in place.

The gate is inverted rather than deleted. The phone's half must now EXIST, both halves must read
`PaneSwitcherRowsBuilder`/`PaneSwitcherMetrics`, `allowsHitTesting` stays banned in the shared overlay
host (that ban is about an always-mounted full-bleed layer eating the split's clicks, which a card
mounted only while its state is live is not), and a new clause fails the build if the phone's card
ever mentions `revealPaneTree` — because `commitPaneSwitcher()` unwinds the follow-along preview
before it stages focus and refuses a candidate whose pane closed under the gesture, and a view
reaching past it has neither guard, silently.

The three verbs a modifier release performs on the Mac become touch: a row TAP commits (spelled
walk → step ×N → `commitPaneSwitcher()`, measured against the LIVE switcher at tap time so a ⌃⇥
arriving between draw and tap cannot land the commit N rows off), the backdrop CANCELS (every other
phone card dismisses without acting on the floor, and a forward open highlights the PREVIOUS pane, so
committing a stray tap would teleport the reader out of the pane they were in), and two chevrons in
the title bar STEP — the same `SlatePlateButton` pair the find bar already steps matches with, not a
new vocabulary.

Three more measurements moved below the view, because neither window bound survives a phone: the 400
floor exceeds a 390 pt screen and the 66% ceiling (whose premise is the workspace BEHIND) answers 390
with a 257 pt card, so `compactWidth(container:)` keeps only the ceiling; `listHeight` exists because
SwiftUI cannot be asked for a `fittingSize` and a `ScrollView` claims every point offered, which stood
a two-row card at 70% of the screen. The walk itself is shared in CANDIDATE index space — rows drop
closed panes, the ring does not.

One gap stays open and is not papered over: on an iPad with a hardware keyboard, Esc/↩ while the card
is up still reach the PTY, because nothing in `TerminalKeyInterceptor`/`WorkspaceBindingRouting`
claims them for an open switcher the way `WorkspaceKeyDispatcher` does on the Mac. A focus-stealing
`.onKeyPress` would have closed it by breaking the ⌃⇥ step path that works today.

### Increment 75 — the clipboard ring the phone could see but never fill

`SlopDeskPasteboard` was a whole-file `#if os(macOS)`, so `ClipboardMonitor` and `ClipboardSyncEngine`
compiled to nothing on the phone and ⌥⌘V opened onto a permanent "No recent clips". The target is
live on both triples now, over a `SystemPasteboard` shim that carries the board, its `changeCount`,
its plain text, and one pure platform fact: `unattendedContentReadIsPermitted`.

That fact is the honest part, and it is why this increment does NOT claim parity. Since iOS 16,
reading `UIPasteboard.string` for content the app did not write, with no paste gesture behind it,
raises a system "Allow Paste?" alert — so a one-second poll would put a modal on screen once per new
clip, unprompted. `changeCount` does not prompt. What ships is therefore split by DIRECTION: the
host→phone pull is whole (writing needs no permission), the phone's own clips reach the ring on the
reads the user asked for (`currentLocalClipboard()` records what it reads, so ⌥⌘V, the palette and
the paste plate all fill it), and the phone→host push is NOT on the timer. The monitor still runs on
iOS and still consumes `changeCount` so the seen count stays honest; it snapshots content only where
the platform fact permits it. The alternative was a poll that silently never fires, which reads like
a feature.

One pre-existing bug fell out: `GuiPastePlateMenu` calls `store.currentLocalClipboard()` from its
`body`, so on iOS it already raised the paste alert on every render.

`CodeFontSync.installedFontRatio` lost its `#if` the other way — it is CoreText now
(`CTFontCreateWithName` + ascent/descent/leading), so the code editor's line height is computed from
the real face on both platforms instead of a fallback constant. `CTFontCreateWithName` never fails
(it substitutes), where `NSFont(name:)` returned nil, so a `resolves(_:to:)` probe compares the family
AND the PostScript name; the ratios are bit-identical to the AppKit body on every case tested (Menlo
`1.1640625`, Monaco `1.33349609375`, Courier `1.0`, nil for a face that is not installed).

The pane's grab pill is REVEALED on touch rather than on hover, and the decision lives in
`PaneDragVocabulary` as `PaneGrabPill.isRevealed(input:hovering:isDragging:)` so all three renderers
read one rule. A long press over that strip would have to win against the gestures the pane surface
already spends it on (selection, the edit menu), and an affordance you must guess at by pressing is
not one; iPadOS draws its own grabber permanently for the same reason. The cost is bounded because
the move layer only mounts where a move is possible. The second half of the same unreachability was
`DragGesture(minimumDistance: 2)` — a mouse's slop, which on touch turned nearly every tap on the
strip into a drag and left "tap to focus" unreachable from the other side; `minimumDragDistance` is
10 for touch and stays 2 for the pointer. Still open, and flagged rather than guessed at:
`Slate.GrabPill.stripHeight` is 14 pt against a 44 pt touch minimum, and the rung is shared with both
AppKit strips.

Last, a phone can send a file into a pane. `PaneFileImportPolicy` answers the one question a picker
has that a drop does not — there is no zone — by choosing `DropZone.insertPath`, the only cell live
for every content kind and the only one that does not commit something off a single tap: the path
lands at the prompt, editable. From there it walks the SAME four steps `performDrop` does, so there
is no second drop engine.

### Increment 76 — the one double implementation that stays, pinned instead of deleted

`WorkspaceTopology.init(entries:)` and `slopdesk_wire::document::topology::from_document` read the
same flat cells into the same shape in two languages. `CLAUDE.md` bans that outright, and every other
instance in this repo was closed by deleting the Swift. This one is not, and the reason is on the
record rather than in a preference:

- **`entries()`/`init(entries:)` ARE the marshalling.** The topology crosses the boundary as the
  document's own bytes (`docs/55` §4b). Deleting the Swift ingestion deletes the crossing, so the
  "port it" move here is not a port — it is a redesign of every door that takes a workspace.
- **The measured veto.** `WorkspaceMarshalBenchTests` times the shipped encoder and decoder on the
  path a port would actually use: a realistic workspace (3 sessions × 5 tabs × 4 panes, 244 entries)
  costs **~2.8 ms** to project, encode, decode and ingest, and a hoarder's (1,042 entries) costs
  **~12.6 ms**. `WorkspaceStore.tree` re-ingests on every divider-drag frame, where the 120 Hz budget
  is 8,333 µs. A third of a frame per gesture at the small size and a missed frame at the large one is
  a *measured* regression, which `CLAUDE.md` names as the only thing that can veto a port.

So the pair stays, and what is owed instead is the thing `docs/55` §7 step 6 asks for: a
**differential**. `Tests/SlopDeskWorkspaceModelTests/WorkspaceTopologyIngestionDifferentialTests.swift`
is the repo's third, after `TreeWorkspaceRepairDifferentialTests` and
`SessionTemplateRepairDifferentialTests`, and the first written for a pair that is still double.

Its shape is set by the fact that **there is no "ingest this document" door**. The applier is the only
entry that takes cells, so the harness marshals RAW cells into `slopdesk_ws_apply_intent` and rides on
one intent that must change nothing: `setSyncInput(armed: false)` on a tab the fixture never arms.
Two consequences are load-bearing and each is asserted rather than assumed. First, a status byte
carries two answers — the door returns `rejectedNotFound` for "no workspace here" *before* it reads
the op, and `set_sync_input` returns the same byte for a tab that is gone — so the harness probes with
an op byte no arm claims, **derived from `WorkspaceIntentOp.allCases`** so an op added tomorrow cannot
silently turn the probe into a real intent. Second, the no-op needs a target, so one anchor session
stays out of the blast radius; the walk skips its three objects, and a companion test asserts the
anchor's field vocabulary is a SUBSET of what the walk still reaches, so the skip cannot quietly
shrink coverage.

Both sides are compared as **cells** — Swift's ingestion re-projected through `entries()`, the crate's
answer already being its own projection. That is stronger than field-by-field, and it is sayable
without either language's type vocabulary. Every ratchet in the file is a SHAPE, never a count or a
name list: the corruption walk is derived from `entries()` itself, so a field added to the projection
joins the corpus that day; the pane vocabulary is walked through `slopdesk_ws_pane_fields(0|1)` and
the root exclusions through `slopdesk_ws_reserved_root_fields`, so the partition is asked for, not
transcribed.

What it covers: every cell the projection writes, corrupted four ways (missing, retired to zero
length, one unparseable byte, forty bytes of noise); every structural cell truncated to *every* prefix
of itself; every topology-half pane field broken the same four ways; every liveness field and every
reserved root field asserted to reach neither ingestion; 47 hand-built degenerate documents (a tab with
no `layoutStructure`, a weight cell of the wrong arity, zero and NaN weights, `activePaneID` and
`zoomedPaneID` naming absent panes, a live closed-tab ring entry, a detached pane shadowed by a tree
leaf, a closed tab with no back-pointer, a session whose every tab is unusable, a `hostDisplayName`
that is not UTF-8, a document holding nothing but pane liveness); the nesting cap, where both layout
decoders must refuse at the same level; and a string clamped at the scalar boundary.

Four Rust tests were deleted, and only those — `a_weight_cell_of_the_wrong_arity_degrades_to_an_even_split`,
`a_zero_weight_is_repaired_rather_than_trusted`, `a_session_whose_tabs_are_all_unusable_is_dropped_rather_than_invented`
and `a_focus_naming_an_absent_pane_falls_back_to_the_first_leaf`. Each was the crate's half of a MIRROR
FIXTURE: the same input written twice in two languages, which is the shape `docs/55` §8 records as the
way every cross-language bug here was born. Their absolute assertions survive on the Swift side, where
the value is the one a person sees. The fifteen Rust tests with no Swift counterpart stayed — the
round-trip, the write rules (`a_topology_write_removes_what_the_new_value_no_longer_names`,
`…_leaves_liveness_and_projects_alone`), the two vocabulary predicates, the project-key precedence and
the caps — and a comment above `mod tests` says why re-adding one of the four re-creates the pair.

Three things are **not** covered, and are written down rather than left to be rediscovered:

1. **Two field codecs, only the frame pinned.** Swift's scalar decoders wrap
   `slopdesk_workspace::state_codec`; the crate's ingestion uses `slopdesk_wire::document::codec`.
   Only the snapshot FRAME is pinned between them (`rust/slopdesk-ffi/tests/snapshot_codec_parity.rs`).
   This suite is therefore also a differential over the two codecs for layouts, weights, uuid lists,
   detached panes and strings — but only at the inputs it happens to build.
2. **A layout over 65,536 nodes.** `state_codec::decode_layout` bounds its walk at `MAX_ENTRY_COUNT`;
   `wire::codec::decode_layout` has no such bound. Swift would refuse a layout the crate accepts. It is
   deliberately unpinned: the fixture is ~1.2 MB and would collide with the answer snapshot's own entry
   cap, so the test would be measuring the harness.
3. **A document nested to `MAX_DEPTH + 1`.** Twelve splits over a leaf decodes and ingests on BOTH
   sides — they agree — and then `apply::accept()` refuses every intent against it. The document
   renders and can never be gestured on. The differential pins the agreement; the frozen state itself
   is a real behaviour with no owner.

The Rust half is green (`cargo test`: 354 + 11 passing; `cargo clippy -D clippy::pedantic` clean).

### Increment 77 — every divider you dragged was renamed on the next launch

`rust/slopdesk-workspace/src/persist.rs` was the client's `workspace.json` ported from the pane up —
kinds, specs, weights, split nodes — with **no caller**: `lib.rs` re-exported four functions, no door
reached them, and `check-invariants.py` carried the module in `STRANDED_RUST_MODULES` as registered
debt. What it did NOT have was the wrapper those pieces live in: sessions, tabs, the schema version,
the refusals. So the file was still read and written end to end by `SplitNode+Codable.swift` and the
`Codable` conformances beside it — two implementations, which is the one thing `CLAUDE.md` forbids
outright. The interesting part is not that there were two. It is that they had already stopped
agreeing, in the way a stranded port always eventually does: nobody was diffing them, because one of
them never ran. Finishing it was therefore two jobs, not one — grow the module to the whole document,
then put it behind doors — and only the second was what the audit that found this had scoped.

**The disagreement is one line and a person feels it every launch.** A `{"split": {…}}` object with
no `id` — what a hand-edited file, or a file written before ids existed, carries — was named in
Swift by `?? SplitNodeID()`: a fresh UUID, per load. The crate DERIVES it from the seam's place in the
tree (`persist::derived_split_id(path, axis, children)`), so two loads of one file name the same
divider the same way. Divider drags persist as `splitNode/<id>/weight`. Under the Swift decoder
every drag a person had ever made was orphaned on the next launch and every seam snapped back to its
default — no crash, no log, no failing test, and no way to tell it from "the app forgot", which is
what it was.

**Four doors, `docs/55` §4 shape, and one of them is not the name the audit proposed.** `_encode`
takes the document's own cells plus its blob and answers file bytes; `_decode` takes bytes, a
pre-minted id pool and two out-params (a refusal byte, a claimed version) and answers an encoded
snapshot; `_status` exports the refusal table by arm order, exactly as
`slopdesk_ws_state_file_status` does, so no arm is transcribed on the Swift side. The fourth was
going to be "which ids did the decode mint", and it is instead
**`slopdesk_ws_workspace_file_minted_ids(bytes, len) -> usize`**, which answers the POOL SIZE. The
audit's version had no work to do: the snapshot the decode returns already carries every id the
repair minted, so asking again is asking the answer about itself. What Swift genuinely cannot know
is how many identities the parse will spend, and it cannot know it because knowing needs the parse.
That matters more than it sounds: the crate holds no entropy on purpose, and a pool that runs dry
REPEATS its last entry — two panes with one id, re-minted apart on every load, which is the divider
defect again wearing the pane's clothes. The size is asked of the file, and `check-supervisor.sh`
pins that it stays asked.

**The asymmetry the port makes explicit**: a SplitNodeId is DERIVED because it names a seam inside
the file, and a PaneId is MINTED because it joins to a live process registry the file knows nothing
about. The tree crosses as the document's own cells for the reason increment 76 gives — there is no
`#[repr(C)]` flattening of a split tree that is not a second grammar to keep in step — so
`Codec/WorkspaceFile.swift` is the fourth file of that shape and decides nothing: no version check,
no tolerance rule, no repair. The repair runs INSIDE the door, which is forced rather than chosen,
because the cells cannot spell the two shapes a file can hold and a document cannot (a session with
no tab, a leaf with no spec).

**Deleted: 273 lines of `SplitNode+Codable.swift`, and 262 more across six files** — `Session`'s
hand-written `init(from:)`/`encode(to:)` pair and its `SpecEntry`, `TreeWorkspace`'s `CodingKeys`
and decoder, `PaneSpec`'s extension, `VideoEndpoint`'s, and `Codable` off `PaneID`, `SessionID`,
`TabID`, `SplitNodeID`, `SplitWeight`, `WeightedChild`, `DetachedPane`, `Tab`. `PaneKind` and
`SplitAxis` KEEP theirs: they are vocabulary values inside the device-prefs templates, which
`docs/55` §8 puts outside this boundary. `WorkspacePersistence` lost its encoder, its `maxItems`
(the cap is `persist::MAX_PANES`) and its normalize-on-load guard, and is now three lines of read,
three of write. 568 lines of Swift out under `Sources/`, 159 in — and the 159 are a marshaller.

**The two decode-repair suites were re-pointed, not deleted and not mirrored.** Every case that
asserted a repair through the Swift decoder now asserts it through the door, which is the same
coverage against the implementation that runs. What did NOT survive is the half of
`SplitNodeCodableTests` that re-asserted repairs the crate's own `split_tree` tests already own —
the empty-split drop, the single-child collapse, the same-axis flatten, the duplicate re-mint, the
weight clamp. Writing those in Swift again would have produced exactly the cross-language mirror
fixture `docs/55` §8 names as how every cross-language bug in this repo was born. The file is
`WorkspaceFileRoundTripTests` now and says only what this side can say: a real arrangement survives
whole, two saves are byte-identical, garbage and a foreign `schemaVersion` fail soft. The defect
itself is pinned three times, once per layer —
`persist::the_same_file_names_the_same_dividers_on_every_load`, `slopdesk-ffi`'s
`two_loads_of_one_file_name_its_dividers_the_same_way` (two loads, two DIFFERENT pools, identical
seam ids), and `SplitNodeDecodeRepairTests.testTheSameFileNamesTheSameDividersOnEveryLoad`.

Two things are owed rather than done. **The first save after this lands rewrites the whole file**:
Foundation escaped `/` as `\/` and wrote no trailing newline, and `slopdesk_ids::json` does
the opposite — the same one-time diff the state-file port took, and it changes no value. And the
decode is now **sharper** than the code it replaces in one place: a detached entry with no spec is
dropped rather than carried, so a file holding one loses that satellite instead of loading a pane
nothing can draw. That is the repair's existing rule applied where Swift had not been applying it,
and the round-trip fixture that used to omit the spec row now carries one.

`cargo test` is green (698 + 4 in `slopdesk-ffi`, 551 in `slopdesk-workspace`), clippy and nightly
rustfmt clean, `check-invariants` down one stranded module.

### Increment 78 — the footer asked the clipboard a question it could only answer with an alert

Increment 75 flagged this on its way past and did not fix it: `GuiPastePlateMenu.canPasteCurrent` called
`store.currentLocalClipboard()`, and it is read from `body` — `.disabled(!canPasteCurrent)` on "Paste as
Keystrokes". Since iOS 16 a read of `UIPasteboard.string` for content the app did not write raises the
modal "Allow Paste?" alert, so every render of a remote-GUI pane's footer could put that alert on screen
unprompted. `SystemPasteboard`'s header exists to say precisely that, and the type it says it in had no
way to ask anything else.

So it does now. `SystemPasteboard.hasPlainText` is the PROBE — `availableType(from: [.string]) != nil` on
AppKit, `hasStrings` on UIKit, the same two-spelling shape `plainText` already has one line up — and it is
the `has*` half of the sentence the header always carried: it discloses nothing, so iOS answers it in
silence. `ClientPasteboard.hasText()` forwards to it rather than forking a third time, which also puts the
probe on the test-safe per-process board the reads already use.

The distinction then lives in the headless model rather than in a view. `ClipboardPasteMenu.canPaste` now
takes `clipboardHasText: Bool`, and the `String?` spelling is gone: an enablement predicate that CAN take
content is one that will. The two ways to obtain that `Bool` are the two ways the two halves work.
The Mac holds the content because it rebuilds its menu in `pasteMenu.onClick`, at menu OPEN, and reduces
it through the new `isPastable(_:)`. SwiftUI has no equivalent moment — a `Menu`'s content is a
`@ViewBuilder` evaluated WITH the body — so the phone asks `WorkspaceStore.localClipboardHasText()`, the
enablement sibling of `currentLocalClipboard()`, and reads content only inside the Button's action, which
is the tap the user made.

The sibling's difficulty is the FALLBACK, not the probe. `currentLocalClipboard()` is
`clipboardTextProvider?() ?? clipboardRing.first`, so a probe that consulted only the board would grey out
a paste that would have worked off the ring head — on a headless store, or on a board the platform will
not read. A `false` from the probe means the live read comes back `nil`, which is the same condition that
hands the paste to the ring, so the ring is exactly where the probe looks next. One case stays looser than
the paste and it is the price of not reading: a board holding only whitespace probes TRUE, because the
platforms answer "has a string" rather than "has a string worth typing", so the item is lit and the tap's
own `isPastable` guard makes it a no-op. A wasted tap, against an alert nobody asked for.

The sweep for the same shape found no second instance. `ClientPasteboard.text()` has two other callers —
the Android stage's paste verb and the composition's provider — and both are fire-time. The palette gates
no row on the clipboard. `ClipboardPasteMenu.rows(store.clipboardRing)`, which stays where it is inside
the plate's body, reads the app's OWN recorded history and not the board, so it cannot prompt; that is
asserted now rather than assumed.

What the tests pin is the SHAPE, not a count of call sites. `GuiPastePlateRenderTests` (iOS triple, since
`SlopDeskPhoneUI` is `#if os(iOS)` end to end) injects both clipboard seams and drives the plate through
the two levels of body evaluation a render performs — the plate's own, then `SlatePlateMenu`'s, which is
where the `@ViewBuilder` finally runs — then asserts the content provider was called ZERO times and the
probe at least once, so "no content read" cannot be satisfied by a render that evaluated nothing.
`ClipboardRingTests` pins the probe's agreement with what a paste would actually find, ring fallback
included, in all four combinations. A `check-supervisor.sh` gate — no `currentLocalClipboard(` in a
`SlopDeskPhoneUI` file outside a closure body — would be a real ratchet on top of these, and is left
unwritten here only because another change owns that file.

### Increment 79 — the phone could see a path in the terminal and had nothing to do with it

Increment 72 gave the phone the long-press menu and named what it could not carry: "the LINK items need
`detectedLink(at:)`, which still lives in the macOS block." It did. Right-clicking a path or a URL on the
Mac prepends Open / Copy Path / Reveal in Finder / Change Directory Here above the standard menu; the
phone's menu offered the standard items and nothing about the thing under the finger — not the wrong
items, none. Everything else was already shared. The policy that says what each item does is pure and
platform-free, the item list is one table both menus render, and the only thing on the Mac's side of the
gate was the question *what is this point on*.

**The gate was not lifted, because lifting it would have preserved the wrong thing.** The embedder's
`detectedLink(at:)` carried its own copy of the cell arithmetic and its doc comment said so — it
"mirrors" `TerminalViewModel.hoveredLinkPath(rows:cwd:schemes:metrics:pointX:pointY:)`, the pure version
one floor down. A citation is not a shared implementation. Worse, the mirror had the two halves the wrong
way round: the pure copy had no production caller at all (its status-bar consumer was removed increments
ago and the renderer stopped calling it when the cache landed), so the copy that actually ran on every
⌘-hover, ⌘click and right-click was the one inside a `#if os(macOS)` in a file no `Package.swift` target
compiles — unreachable from the macOS test runner, and pinned only through a function nothing ran. So the
arithmetic collapsed into `SlopDeskWorkspaceCore/Terminal/TerminalLinkHitTest.swift`, answering with the
LINK rather than with a path (`resolvedAbsolute ?? raw` is the hover seam's own reading, at its one call
site), `hoveredLinkPath` was deleted, and its test file was retargeted onto the function production runs.
Four callers of one function now, where there were two functions serving three-and-a-half.

What stayed in the embedder is the part that touches libghostty: the `(viewport rows → detected links)`
snapshot, now `GhosttyLinkSnapshot` above the platform fork, one per view. It is the cache that makes a
⌘-hover cost arithmetic instead of a full `viewportTextRows()` C-ABI re-read per mouseMoved, and it keys
on the same three generations as before. The phone gains two invalidation sites the Mac's `scrollWheel`
already had for exactly this reason — the pan, and the selection drag's edge autoscroll — because both
move the viewport while bumping no key, and on this half the release that ends that very drag is what
asks which link the menu is for.

**The set is the Mac's, from `TerminalContextMenu.linkItems(for:)` unchanged**: a path offers Open, Copy
Path, Reveal in Finder and Change Directory Here; a URL offers Open Link and Copy URL, because a URL has
no Finder target and you cannot `cd` into one. The Mac separates them from the standard items with an
`NSMenuItem` rule and the phone makes them the first inline group, which is the same rule in UIKit's
spelling — layout differs, the offer does not. Actuation stopped being two switches at the same time: the
renderer's `performLinkAction` is deleted and both halves dispatch through `LinkActionActuator`, whose
`actuate` is now `public` rather than `package` for the reason the embedder always forces — it is compiled
by the Xcode app targets and by no target in this package, so `package` is invisible to it. That is also
why a `Slate` token could not have been the home for anything here. Two things fell out of the merge: a
link copied from the terminal now lights the `COPIED · N` chip and goes through `ClientPasteboard` like
every other copy in the app, neither of which the AppKit copy did.

Last, **a fingertip is not a cursor**, and it gets ONE shot: no hover, no correction, the menu opens on
release. A cell is about 8 × 17 points and a contact patch is tens of points across, so
`TerminalTouchSelection.linkHitSlop` (10 pt) widens the phone's hit-test and the Mac passes nothing at
all. It is beside the other touch numbers rather than in the design floor because it is a distance a
FINGER is wrong by, not a measurement of a drawing — and it is deliberately narrower than
`longPressAllowableMovement`: a press that held still enough to be recognised should not then be re-aimed
further than it was allowed to drift. The exact-cell pass runs first for every caller, so a slop can only
ever add an answer where there was none, and the pointer's reading is bit-for-bit what it was. The link is
resolved at the RELEASE point, which is where the menu anchors and what the Mac's `menu(for:)` reads.

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
     The supervisor's "one allowed gate" rule (`check-supervisor.sh`, the `SlopDeskPhoneUI` whole-file
     exemption) is the shape the target must be left in, not the shape it is in now.
   - **Two test files cross the halves and no ratchet sees them.** `ui_edges` in
     `check-supervisor.sh` globs `Sources/…` only, so `Tests/SlopDeskMacUITests/MacRailStatusRollupRender.swift:31`
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
   `enable-macos-renderer.sh` + `xcodebuild` recipe, so P4 lands as its own commit with that recipe in
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
tests out of `make check`.** Fifty-six files compile on the macOS triple today, because
`canImport(SwiftUI)` is TRUE there — which is what lets `Tests/SlopDeskClientUITests` run under `swift
test`. Make them `os(iOS)` and that suite can only run on a booted simulator
(`scripts/check-ios-tests.sh`, deliberately NOT in `make check` because a headless gate cannot assume
one). Thirty-two test files would leave the default gate silently, and a suite that still exists but
no longer runs is worse than a deleted one.

So F1 gains a prerequisite, **F0: drain the phone's test target downward before gating it.** By the
same rule that governs the four bucket-E files — eighteen of those thirty-two files use no
`SlopDeskClientUI` symbol at all (several carry a dead `@testable import`), six reach only a namespace
`enum`, and four only a `static` member hung on a view type. Those belong below the UI split, where
they keep running on every platform forever. What is left after the drain is the handful that truly
build a view, and those are the ones the simulator gate is FOR.
