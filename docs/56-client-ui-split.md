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

`rust/slopdesk-workspace/src/settings_catalog.rs` now holds what a settings page can be set TO: the
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
`systemImage` and `isMacOSOnly` read the catalog row keyed by `rawValue`, and `SettingsSection.ordered`
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
keyword blob the search field also matches. It is `rust/slopdesk-workspace/src/settings_rows.rs`,
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
on iOS, no `LaunchServices` deep-link, no `NSSound`. `rust/slopdesk-workspace/src/settings_layout.rs`
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
setting — which is also why `VideoHostSettingsView`, whose four sections each land on reconnect,
places its own.

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
`slopdesk_workspace::settings_layout`, described down to which platform sees which group. That was
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
no longer keeps is a window.

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
