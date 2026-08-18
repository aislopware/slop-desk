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

  **The third is the ⌃⇥ readout, and it closes the ambient layer.** `MacPaneSwitcher` is an `NSPanel`
  that `ignoresMouseEvents` outright — the readout's whole gesture lives on the keyboard, so a click
  during it belongs to the workspace — and it never becomes key, because stealing focus mid-gesture
  would break the `flagsChanged` release that COMMITS the switch. Its rows and its measurements were
  already below the view (`PaneSwitcherRowsBuilder`, `PaneSwitcherMetrics` in `SlopDeskClientCore`),
  so the port is the drawing and nothing else. Unlike the cheat sheet and the toasts this surface has
  ONE half rather than two: the phone has no modifier stream to open ⌃⇥ with, the SwiftUI overlay
  could never render there, and it was deleted rather than kept as a cross-language mirror.

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
  neither `PaneSwitcherOverlay` nor an `allowsHitTesting` may reappear in that file.
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
- **E — the Rust port (§4).**

## 4. What moves to Rust

The split makes a second question answerable: with the view layer split by platform, everything left
that is neither AppKit nor SwiftUI is pure logic, and this repo's standing rule is that pure logic is
Rust (`CLAUDE.md`: "Rust is the default; perf parity is enough to move existing Swift. Only
SwiftUI/AppKit justifies staying in Swift"). The port list and its order live in §5 of this doc as
each stage lands.
