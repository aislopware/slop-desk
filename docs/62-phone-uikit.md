# 62 — The phone client becomes UIKit

The counterpart of `docs/56-client-ui-split.md` for the other half. That document forked one SwiftUI
target into an AppKit Mac and a SwiftUI phone; this one rewrites the phone in UIKit, so both shells
are imperative and every frame the product draws is one this repo placed by hand.

Read `docs/56` §2, §3 and its Stage-D ledger first, and `docs/60` §4–§5 for the shape of a staged
port that must stay green at every boundary. This document CORRECTS one ruling of `docs/56` §2 and
inherits the rest intact.

## 1. The correction: "iOS = SwiftUI" was a measurement, and the measurement moved

`docs/56:123-126` says:

> **iOS = SwiftUI.** At phone/tablet scale, with one pane on screen at a time and a system that hands
> you the keyboard, sheet and navigation behaviours for free, SwiftUI reaches the ceiling this product
> needs. The limitations that pushed macOS out — divider drags, cross-hosting-view drag-and-drop,
> secondary windows, a 40-row rail under a mouse — are macOS-shaped problems.

Two of those clauses are no longer true of this tree, and the ruling is reversed by the user
2026-08-28 on a ground the document did not weigh: the phone is where the latency budget is tightest,
and an imperative layer is the only one whose cost can be read off the code.

**"One pane on screen at a time" is false.** `SplitContainer.swift:98-125` mounts every tab of every
*retained* session simultaneously, and `:139-171` places every leaf of the active tab — visible and
zoom-hidden alike — from one `ForEach` over `SplitTreeRenderModel.layout(for:in:)`. The phone runs the
same split canvas the Mac does. `docs/56`'s own ledger calls that canvas "the expensive kind, and the
only one that is" (`docs/56:3900-3906`).

**"The limitations are macOS-shaped" is falsified by the phone's own escape hatches.** `docs/56` §1
argued the Mac out of SwiftUI by counting where SwiftUI had already failed there: 53 AppKit imports,
13 `NSViewRepresentable`, 32 `swiftui-introspect` sites. The same census on the phone — taken BEFORE
stage A, and left at that reading on purpose: it is the evidence the campaign was argued from, so
`PhoneRootKeyResponder` and `SlopDeskPhoneApp` appear below as the files that existed then (stage A
folded the first into `PhoneAppDelegate` and split the second in two):

| | count | detail |
| --- | --- | --- |
| `import UIKit` in `Sources/SlopDeskPhoneUI` | 10 | `TerminalInputHost`, `PhoneRootKeyResponder`, `PaneMoveEscapeResponder`, `SimulatorScreenView`, `AndroidScreenView`, `DeviceSoftKeyboard`, `PhonePanelSheet`, `CodeSidebarWebView`, `ImageDecode`, `SlopDeskPhoneApp` |
| `UIViewRepresentable` reachable from the phone shell | **7** | five in `SlopDeskPhoneUI`, one in `SlopDeskVideoClientPhone`, one vendored (§2.4). `UIViewControllerRepresentable`: **0** |
| the terminal renderer | already a `UIView` | `GhosttyTerminalView.swift:2995` — `GhosttyLayerBackedView: UIView`, wrapped at `:2953` |
| the video renderer | already a `UIView` | `Sources/SlopDeskVideoClientPhone/MetalLayerBackedView.swift`, 1,260 lines, wrapped by 129 |
| the two device screens | already `UIView`s | `SimulatorScreenView.swift:54` and `AndroidScreenView.swift:46` — **only 29 of 363 and 25 of 389 lines are SwiftUI** |
| the app delegate | already exists | `PhoneRootKeyResponder.swift:46` — `UIResponder, UIApplicationDelegate`, mounted by `@UIApplicationDelegateAdaptor` at `SlopDeskPhoneApp.swift:50` |
| first-responder arbitration | already UIKit-shaped | `Sources/SlopDeskWorkspaceCore/iOS/PaneFocusCoordinator.swift:9-25` |
| key repeat | already UIKit-shaped | `KeyRepeater.swift:4-6` — "UIKit fires `pressesBegan`/`pressesEnded` EXACTLY ONCE per physical key" |
| `swiftui-introspect` | **0 call sites, 0 declared dependencies** (was 0 and 1) | The manifest row and its `Package.resolved` pin went with the SwiftUI app scene — the dependency existed to reach the `NSWindow` a `WindowGroup` hides, so it had no subject left. `Package.swift:145` and `:604` keep the reason in prose |

Every hard interaction on the phone has already fallen out of SwiftUI and landed in UIKit: the
keyboard, the terminal surface, the video surface, both device screens, the code panel's webview, the
escape monitor, the app delegate. **Roughly 3,400 of the phone's 19,300 UI lines are already
hand-written `UIView`s and `UIResponder`s.** What is left in SwiftUI is the arrangement around them,
and that is exactly the reading `docs/56` §1 took as a verdict on the Mac.

**And the iPad is a DESKTOP-SHAPED client, which is a requirement rather than an inference.** Stated
by the user 2026-08-28, alongside the UIKit reversal: *the iOS app has to be responsive, and the iPad
layout should be close to the desktop's, because the aspect ratios are close.* Nothing in `docs/56`
says otherwise — its own line is *"the two shells ship the SAME product: every feature the Mac has,
the phone and the iPad have, laid out for the device"* — but "laid out for the device" was being read
as "laid out for a phone, stretched", and on a 13-inch panel at 4:3 that is the wrong reading. What it
means concretely, and where each half lands:

| | the requirement | stage |
| --- | --- | --- |
| the shell | `UISplitViewController` in `.regular` shows navigator + content SIDE BY SIDE, the Mac's two columns; `.compact` collapses to the phone's one | D |
| the split canvas | unchanged — the canvas is already the Mac's, and §3.3 places it by solved rect on both idioms | E |
| the chrome | every constraint reads `safeAreaLayoutGuide` + `UITraitCollection.horizontalSizeClass`, never `UIDevice.current.userInterfaceIdiom` — a Slide Over iPad is `.compact` and must draw the phone's arrangement | C–H |
| the overlays | `.formSheet`/`.popover` in `.regular`, `.pageSheet` in `.compact` — the same summon, the presentation the size class asks for | F |
| re-layout | `traitCollectionDidChange` / `viewWillTransition(to:with:)` re-run the arrangement; the canvas re-solves rather than re-parenting, which §3.6 already forbids | D–E |

Responsive here means SIZE CLASS, not device: the one gate that is allowed to ask the idiom is the
live-video ceiling (`PhoneAppDelegate`, one stream on a phone and two on a pad), because that is a
question about the hardware rather than about the window. Every other branch asks the trait
collection, and §4's rules gain one for it at stage I.

**The clause that survives is worth stating, because it is what §8 protects.** SwiftUI does hand you
sheets, keyboard avoidance, Dynamic Type and safe-area insets. UIKit hands you the same four as
objects you configure rather than behaviour you inherit; §3.8 names each with the API that replaces it,
because a port that silently loses a system behaviour is the failure this document exists to prevent.

**And `#Preview` is still 0, on both halves.** The design loop is a render to PNG and a pair of eyes
(§5.2), which UIKit runs identically — the argument `docs/56:40-42` made for the Mac.

**One `CLAUDE.md` line this campaign owes an edit.** *"Rust is the default; perf parity is enough to
move existing Swift. Only SwiftUI/AppKit justifies staying in Swift."* UIKit is not named there, and
after this campaign the phone's justification for Swift is UIKit. The rule's intent is unchanged — a
view framework justifies Swift, nothing else does — but the sentence has to say `SwiftUI/AppKit/UIKit`
or it reads as a ban on the thing this document plans. That edit belongs in stage A's commit, with the
`lint-invariants` rule that quotes it.

## 2. The inventory

`Sources/SlopDeskPhoneUI` is **86 files, 17,541 lines**; `Sources/SlopDeskVideoClientPhone` 3 files,
1,759; `Apps/ClientApp-iOS` one `@main` (235) and eleven test files. For scale, the AppKit half that
replaced the same surfaces on the Mac is **87 files, 32,257 lines**.

Four buckets, each a claim about the file rather than a size estimate:

- **(a) layout** — becomes a `UIView`/`UIViewController`. Arrangement, tokens and actuation; it
  decides nothing a second renderer would decide again.
- **(b) decision** — a view that is really a state machine. §7 names the crate.
- **(c) inversion** — an existing representable. The wrapper dies, the `UIView` becomes primary.
- **(d) deletion** — goes, and nothing replaces it.

> **⚠️ Read bucket (b) the way `docs/56` increment 54 says to read a ledger row.** The "non-UI logic
> in a view" method over-reports; `docs/56:3971-3980` records why, and this tree has already been
> drained by increments 15–87. `rust/slopdesk-workspace` is **34,079 lines across 74 modules**, and
> its module names are a directory listing of this UI: `open_quickly`, `command_navigator`,
> `palette_rows`, `palette_card`, `global_search`, `toast`, `pane_switcher`, `hint_overlay`,
> `peek_reply`, `connect_form`, `find_bar`, `vi_hints`, `phone_key`, `key_repeat`, `list_nav`,
> `split_zoom`, `pane_drop`, `drop_zone`, `status_pill`, `chip_notice`, `cheat_sheet`, `panel_tabs`,
> `rail_list`, `sidebar_row`, `git_line`, `gui_readout`, `grid_readout`. Bucket (b) is therefore
> **small**, and that is the campaign's most important number: **this is a rendering port, not a logic
> port.** §7 states the nine things that genuinely remain.

**The counting convention, stated because the tables below carry hybrids.** Every file gets exactly
ONE bucket, so the four numbers sum to the file count. A row marked `a + b` is counted **(a)** — the
file becomes a view, and its decision residue is a line in §7, which is the ledger that actually
governs it. A row marked `c → d` is counted **(c)**, because the wrapper is what the port acts on and
its disappearance is the act. **(d) counts whole files only**; a dead member inside a surviving file is
noted in its row and does not move the file's bucket.

Totals across the **89 files surveyed** — `Sources/SlopDeskPhoneUI` (86, of which 3 are the
`Chrome/`+environment files counted in §2.2) and `Sources/SlopDeskVideoClientPhone` (3):

| bucket | count | |
| --- | --- | --- |
| **(a)** layout → `UIView`/`UIViewController` | **72** | §2.1 24 · §2.2 16 · §2.3 32 |
| **(b)** decision → a Rust module | **8** | `PromptJumpFlashOverlay`, `OverlayKeyRepeat`, `SimulatorStageView`, `AndroidStageView`, `SimulatorRunningCard`, `SimulatorBezelView`, `DevicePanelChrome`, `CodePanelSurfaces` |
| **(c)** representable that inverts | **6** | §2.4's seven minus the vendored `GhosttyTerminalView.swift`, which is not one of the 89 (§8) |
| **(d)** deleted outright | **3** | `SidebarColumnVisibility.swift`, `OverlayEnvironment.swift`, `PreferencesEnvironment.swift` |

**Five files stop existing, not three** — the two `(c)`/`(b)` rows that dissolve rather than invert
(`PaneMoveEscapeResponder.swift`, `OverlayKeyRepeat.swift`) end deleted too. And seven member-level
deletions ride along inside surviving files: `View.panePointer`, `PaneDivider.resizePointer`,
`DeviceSoftKeyboard.hasHost`, `SlateCardModifier` + `slateCard(radius:fill:)`,
`ContentColumn.onConnect`'s dead default, and `TerminalRenderingView`'s SwiftUI shape with
`BuildStatusPlaceholderView`'s conformance to it.

### 2.1 `Pane/` — the canvas: 23 files, 5,383 lines

| file | lines | bucket | why |
| --- | --- | --- | --- |
| `GuiLeafView.swift` | 1028 | a + **b** | the video leaf and eight nested chrome types. `body` is split at `:120-123` **because the type-checker timed out** — a fact about SwiftUI that ceases to exist. `liveSurface` `:398-473` rebuilds ~10 injector closures and 6 telemetry sinks **on every render**, which is how a read-only flip re-gates. (b): the control-bar gates `showsControlBar` `:332`, `showsModeToggles` `:561-570`, `hasLatchedMode` `:338` |
| `TerminalInputHost.swift` | 630 | **c** | `UIViewRepresentable` `:69` over `TerminalInputHostView: UIView, UIKeyInput` `:95-520`. ~85% decision, and every rule is already Rust's (`PhoneKey`, `KeyRepeater`). `keyCommands` `:252-264`, `handle(_:)` `:301-336` |
| `PaneMoveAffordance.swift` | 506 | a + **b** | `PaneMoveHandle` `:79-295` is a state machine wearing a View (`@GestureState`, a three-case `Phase`, three release paths). `PaneMoveOverlay` `:300-461` is declaration over `PaneDropGeometry`. `View.panePointer(_:)` `:67-69` is a **deliberate iOS no-op** — (d) |
| `TerminalLeafView.swift` | 369 | a | drawing and triggers only; policy is `TerminalLeafPolicy` / `PaneStatusPillPresentation` |
| `SplitContainer.swift` | 352 | a | **the identity-preserving compositor**, and the architectural centre. §3.2, §3.3, §3.6 are all about this file |
| `ViModeOverlay.swift` | 309 | a + **b** | `ViKeyHintReflow` `:232-308` is a **SwiftUI `Layout` conformance** — `makeCache`/`sizeThatFits`/`placeSubviews`. It cannot port; it has to be re-derived. §7 |
| `TerminalFindBar.swift` | 298 | a | `FindTogglePill` `:231` is genuinely reused by `GlobalSearchView`. Two `DispatchQueue.main.async` focus hops `:103,106` |
| `PaneContainer.swift` | 246 | a | per-pane wrapper; `.onDrop` delegate at `:193-204` |
| `PaneMoveEscapeResponder.swift` | 221 | **c → d** | `UIViewRepresentable` `:63` over a zero-size first responder. A `UIViewController` has `pressesBegan` and `keyCommands`, so **the whole file dissolves** rather than inverting |
| `HintModeOverlay.swift` | 201 | a | iOS-only, no Mac twin. Carries a live defect: `:51-52` dereferences `model.surface`/`cellMetrics()` **unobserved**, so badges do not re-place on a font-size or resize change |
| `PaneDivider.swift` | 200 | a + **b** | the second per-frame path. `releaseDrag()` `:141-145` is an idempotence latch. `resizePointer` `:169-175` is **computed and discarded** — (d), Mac symmetry only |
| `PaneDropReceiver.swift` | 182 | a | a `nonisolated struct: DropDelegate` — a protocol adapter. Becomes a `UIDropInteractionDelegate`; five `MainActor.assumeIsolated` sites (§4 hazard 4) |
| `PaneStatusPills.swift` | 156 | a | six near-identical two-case `switch pill.fill` ladders `:83-132`, where `FindTogglePillAppearance.resolve` already shows the one-value collapse. A cleanup the port should take |
| `PhoneRootKeyResponder.swift` | 154 | a | already `UIResponder, UIApplicationDelegate`. Under UIKit its "why the app delegate, not a view" rationale `:10-22` **stops being a workaround** |
| `LinkHighlightOverlay.swift` | 104 | a | the module's one `Canvas` `:90-98` → `CAShapeLayer`. Two `let _ =` observation-registration hacks `:67-70` whose ORDER is load-bearing — under `withObservationTracking` the read block IS the list, so the hack becomes the mechanism |
| `PromptJumpFlashOverlay.swift` | 103 | **b** | a state machine wearing a View: epoch guard → `withTransaction(disablesAnimations)` → `Task.yield()` → `withAnimation` → `sleep` → unmount, `:54-80`. The sequence is the logic |
| `TerminalLetterboxContainer.swift` | 100 | a | one of only two `GeometryReader`s; math already `TerminalLetterbox`'s |
| `PaneDropOverlay.swift` | 97 | a | mapping only; two enum→`Color` switches |
| `PaneFileImporter.swift` | 93 | a | `.fileImporter` → `UIDocumentPickerViewController` |
| `ViCursorOverlay.swift` | 60 | a | one rect; geometry delegated |
| `BuildStatusPlaceholderView.swift` | 60 | a | conforms to `TerminalRenderingView`; §2.4 changes what that protocol is |
| `PaneRecedeScrim.swift` | 38 | a → **merge** | AppKit already collapsed both scrims into one `MacPaneScrims.swift`. The phone should too |
| `PaneResizeScrim.swift` | 25 | a → **merge** | ditto |

`Columns/`: `NavigatorColumn.swift` (580, **a**) is the module's one `List(selection:)` + `.searchable`
+ `.swipeActions` + `ViewThatFits` surface — the single largest SwiftUI-machinery concentration and
§3.4's first collection view. `ContentColumn.swift` (117, **a**) is a mount point with **no `@State` at
all**, and carries a live defect: `onConnect` defaults to `{}` and the sole call site
(`WorkspaceRootView.swift:103`) omits it, so the empty state's only action does nothing on iOS
(`:32,92-94`).

Roots: `WorkspaceRootView.swift` (359, **a**) is the split shell plus three seam-wiring closures;
`SlopDeskPhoneApp.swift` (273, **a→(c)**) is the `App` scene — §6 stage A.

### 2.2 `Overlays/` + `Chrome/` + the two environment files — 20 files, 4,276 lines

**Zero `UIViewRepresentable`, zero `PreferenceKey`, zero `NotificationCenter`, zero `List`, zero
`UIResponder` work, zero dead files.** Every ranking, scoring, filtering and index-arithmetic
candidate is already behind `CSlopDeskFFI`; these are marshalling shells with a key-`switch` on top.

| file | lines | bucket | why |
| --- | --- | --- | --- |
| `Overlays/OpenQuicklyView.swift` | 715 | a | `pageStep` `:82` → FFI; highlight `:347-365` → `FuzzyMatcher`; action rank `:483` → `OpenQuicklyModel`; selection `:489-503` → `ListNavigation`. The 60-line key router `:631-691` is a `switch` whose every arm is one FFI call |
| `Overlays/CommandNavigatorView.swift` | 484 | a | `CommandNavigatorModel.filtered` is a one-line body over `wsSearchRanked` |
| `Overlays/PeekReplyOverlay.swift` | 347 | a | `PeekReplyTarget.queuePosition` `:153`, `PeekReplyFormatter` `:324,333` |
| `Overlays/PaletteView.swift` | 330 | a | the cleanest — owns no state but a focus flag and a hover gate |
| `Overlays/GlobalSearchView.swift` | 328 | a | one real local decision: `queryBinding` `:245-253` re-runs the search on every keystroke, undebounced (§5.1) |
| `Overlays/ToastStackView.swift` | 321 | a + timer | `:194-205` is a hover-pausable sampled dwell loop on `Task.sleep`. §4 hazard 6 |
| `Overlays/OverlayHostView.swift` | 274 | a | mount and routing; the `ActiveSheet` priority chain `:170-176` becomes an explicit presentation swap |
| `Overlays/PaneSwitcherOverlay.swift` | 270 | a | owns **no** `@State` |
| `Chrome/ConnectionPill.swift` | 212 | a | `ConnectionReading.*` throughout |
| `Overlays/ConnectHostView.swift` | 190 | a | one stored/cancelled `Task` `:169-181` — the shape §4 hazard 6 generalises |
| `Overlays/InstrumentChip.swift` | 186 | a + timer | `:133-137` |
| `Overlays/ClipboardConfirmCard.swift` | 153 | a | pure renderer |
| `Overlays/IslandChipStack.swift` | 150 | a | two-owner copy-receipt tie-break `:49` |
| `Overlays/KeyboardCheatSheetView.swift` | 90 | a | `CheatSheetContent.dealt` |
| `Overlays/CopyReceiptChip.swift` | 51 | a + timer | `:45-48` |
| `Chrome/TabBadgeView.swift` | 51 | a | `StatusPresentation.tabBadge` |
| `Overlays/OverlayKeyRepeat.swift` | 49 | **b → d** | typed on `KeyEquivalent` and `KeyPress.Phases`, neither of which UIKit has. It is not ported; it **merges into `rust/slopdesk-workspace::key_repeat`**, which already owns the phone's hardware repeat latch. §7 |
| `Chrome/SidebarColumnVisibility.swift` | 32 | **d** | `NavigationSplitViewVisibility` adapter, with no `NavigationSplitView` under it after stage D |
| `Overlays/OverlayEnvironment.swift` | 20 | **d** | `@Entry` slot; a controller is handed its coordinator at `init` |
| `PreferencesEnvironment.swift` | 23 | **d** | ditto |

### 2.3 `DesignSystem/`, `Panel/`, `CodeSidebar/`, video — 42 files, 6,943 lines

**`DesignSystem/` (18 files, 1,909 lines) — 16 of 18 are thin token→SwiftUI-modifier adapters with
ZERO observable-model reads.** No `@Observable`, no `.task`, no `Timer`, no `NotificationCenter`, one
`DispatchQueue`. Every value arrives as a plain `let`. They become token→UIKit adapters mechanically,
and they are the campaign's one genuine carve-out (§6 stage C). The four with real logic:

- `SlateKit.swift:71-76` — `background(pressed:)` is an XOR previewing the latch the click lands on;
  `:108-141` `SlatePlateStyle` wraps a `View` **solely to hold an ack counter**, which in UIKit is a
  property on a `UIControl`.
- `StatusDotView.swift:136-138` — `AgentSpinnerView` mounts `TimelineView(.animation)` and redraws at
  display refresh. **The only 60 fps work in the whole directory**, and the first `CADisplayLink` the
  port introduces. §4 hazard 6.
- `SlateOverlayControls.swift:104-106` — the directory's only `DispatchQueue`, a deferred focus grab.
- `VectorIconView.swift:21-39` — a `Canvas`, even-odd fill, over `SVGPath` → `CAShapeLayer`.

**Dead: `SlateCardModifier` + `slateCard(radius:fill:)` (`SlateComponents.swift:93,130`) have zero
call sites repo-wide** — bucket (d).

**`Panel/` (18 files, 3,151 lines).** `SimulatorScreenView` (363, **c**) and `AndroidScreenView`
(389, **c**) are 90%+ already `UIView`: `AVSampleBufferDisplayLayer`, raw `touchesBegan/Moved/Ended`,
a pinch throttle on `ProcessInfo.systemUptime`, a deterministic pointer-index sort so jitter cannot
swap fingers (`AndroidScreenView.swift:228-229`), measured at 69.5 and 25.3 fps under drag. Dropping
the wrapper is near-zero cost. `SimulatorStageView` (445, **b**) and `AndroidStageView` (270, **b**)
are state machines wearing Views — `press` at `AndroidStageView.swift:171-186` is load-bearing (flip
the latch first, then actuate with the new value). `SimulatorDeviceList` (361) / `AndroidDeviceList`
(301) are (a) and become collection views. The two consoles (252 / 229) are (a) and are §3.4's
strongest case — `AndroidConsoleView.swift:113-118` records **0.78 ms hit / 1.50 ms miss at 600 rows**.
`SimulatorRunningCard` (154, **b**) owns a 2-second thumbnail poll per visible card — N cards, N
concurrent tasks. `SimulatorBezelView` (139, **b**) is ~50% coordinate math. `PhonePanelSheet` (292,
**a**) holds the one real layout algorithm, and it **already measures with `UIFont`** (`:207-213`), so
it ports verbatim. `DeviceSoftKeyboard` (130) has **no SwiftUI View at all** — a `UIView, UIKeyInput`
registry; dead member `hasHost` `:58`. `DevicePanelChrome.loadingVeilState` `:96-101` is (b).

**`CodeSidebar/` (3 files, 642).** `CodePanelSurfaces` (486, **b**) is the heaviest file in the
survey: seven observable models, five `.task(id:)`, five `.onChange`, and three documented past bugs
its port must not lose — the poll task deliberately **outside** the workbench switch (`:155-157`), the
ensure-retry and device-poll on **separate** restart keys (`:243-245`), and the `.onAppear`/
`.onDisappear` park/resume pair without which leaving the tab strands a host encoder and two
websockets (`:252`). `CodeSidebarWebView` (81, **c**). `DeviceSurfaces` (75, **a**).

**`SlopDeskVideoClientPhone/` (3 files, 1,759).** `MetalLayerBackedView` (1,260) is a `UIView` with
**zero SwiftUI** — the phone's whole remote-desktop input engine, deliberately using raw
`touchesBegan/Moved/Ended` rather than gesture recognizers because a recognizer arbitrates against the
SwiftUI canvas above and a 300 ms failure requirement is 300 ms of a click already made (`:71-74`).
`VideoLayerRepresentable` (129, **c**). `VideoPaneView` (370, **a**) is a parameter-passing shell.

### 2.4 The representables that invert — bucket (c), complete

| wrapper | lines | wraps | after |
| --- | --- | --- | --- |
| `Sources/SlopDeskVideoClientPhone/VideoLayerRepresentable.swift:15` | 129 | `MetalLayerBackedView: UIView` (1,260) | deleted. The ~18 closures crossing per update become properties the pane controller sets, in the before/after-`activate` order the file documents at `:1-8` and `:54-88` — that order is correctness, not style |
| `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift:69` | 630 | `TerminalInputHostView: UIView, UIKeyInput` | the `UIResponder` becomes the pane controller's own input surface |
| `Sources/SlopDeskPhoneUI/Pane/PaneMoveEscapeResponder.swift:63` | 221 | a zero-size first responder | **dissolves.** A `UIViewController` has `pressesBegan` and `keyCommands`; the `GCKeyboard.coalesced` arm-time gate `:206` and the weak displaced-responder handback `:139-167` move onto the canvas controller |
| `Sources/SlopDeskPhoneUI/Panel/Simulator/SimulatorScreenView.swift:334` | 363 | `SimulatorScreenUIView` | added as a subview |
| `Sources/SlopDeskPhoneUI/Panel/Android/AndroidScreenView.swift:364` | 389 | `AndroidScreenUIView` | ditto |
| `Sources/SlopDeskPhoneUI/CodeSidebar/CodeSidebarWebView.swift:46` | 81 | a pooled `WKWebView` in a clipping `UIView` `:42` | the pool hands the page straight to a controller; `updateUIView`'s four hand-written constraints `:62-79` become the controller's |
| `ThirdParty/ghostty/.../GhosttyTerminalView.swift:2953` | — | `GhosttyLayerBackedView: UIView` `:2995` | §8: **vendored.** What changes is not this file but the seam it satisfies |

**The seam loses a shape, and that is a ledger row of its own.**
`Sources/SlopDeskWorkspaceCore/Terminal/TerminalRenderingView.swift:47-51` has two:
`shared`/`make(model:isFocused:)` returning a SwiftUI `View`, and `nativeShared`/`makeNative(...)`
returning the `NSView`. The SwiftUI shape exists because "the phone has no `NSView`" (`:89`). After
this port the phone asks for a `UIView`; the SwiftUI shape has **no consumer on either platform** and
is deleted, along with `BuildStatusPlaceholderView.swift`'s SwiftUI conformance.

## 3. The architecture

Nothing below is invented. `SlopDeskMacUI` is 32,257 lines of exactly this problem — solved, shipped
and ratcheted — and the phone's job is to apply its method with the UIKit substitutions named. There
are four substitutions that are not one-for-one, and each is called out.

### 3.1 State → view invalidation: `withObservationTracking`, and the generation guard

The models are already right. `Sources/SlopDeskPhoneUI` contains **zero** `@StateObject`, **zero**
`@ObservedObject` and **zero** `@EnvironmentObject`: every model it reads — `WorkspaceStore`,
`OverlayCoordinator`, `AppConnection`, `TerminalViewModel`, `WorkspaceChromeState`,
`SimulatorSidebarModel`, `AndroidSidebarModel`, `CodeSidebarModel` — is an `@Observable` macro type
held in plain `@State`. `@Observable` is not a SwiftUI feature; it is `Observation`, and its imperative
consumer is `withObservationTracking(_:onChange:)`.

`SlopDeskMacUI` uses it in **46 files**. The idiom is `MacSplitCanvasView.swift:500-519`, verbatim:

```swift
private func follow() {
    generation &+= 1
    let generation = generation
    withObservationTracking {
        _ = drag.move
        _ = paneDrag?.drag
        _ = CodeSidebarKeyboardState.shared.ownsKeyboard
    } onChange: { [weak self] in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                self.relayout(in: self.container)
                self.follow()
            }
        }
    }
}
```

Four properties are load-bearing, each answering something SwiftUI did for free:

- **The read block IS the dependency list.** SwiftUI derived it from `body`; here it is written. A
  property read outside it does not invalidate — a bug class SwiftUI did not have, and §4's answer is
  a rule rather than vigilance. `LinkHighlightOverlay.swift:67-70` is the tell that this tree already
  understands the problem: two `let _ =` reads exist purely to register dependencies, with a header
  (`:44-52`) documenting the bug that came from getting the order wrong. Under
  `withObservationTracking` that hack becomes the mechanism.
- **`onChange` fires BEFORE the mutation and exactly once**, so the callback hops to the next main
  turn and re-arms — the `DispatchQueue.main.async` plus the trailing `self.follow()`.
- **The generation counter is what makes `teardown` final.** `teardown()` bumps it, so an already
  scheduled callback finds `generation != self.generation` and returns. Without it a torn-down view
  re-arms tracking on a live model — §4 hazard 2.
- **`[weak self]` is mandatory**: `withObservationTracking` retains `onChange` for as long as the
  observed object lives, and the observed objects here are app-lifetime.

**The phone changes nothing about this.** It is `Observation`, not AppKit.

**The four properties are now a TYPE, not a prologue.**
``SlopDeskClientCore/ObservationFollow`` is the shape above written once, and it is the canon for
every new follower on both shells:

```swift
ObservationFollow.arm(self,
    read: { $0.chrome.sidebarCollapsed },
    apply: { shell, collapsed in shell.split.applyCollapse(sidebarCollapsed: collapsed) })
```

Three of the four properties stop being discipline and become signatures. `[weak self]` is not
written at the call site because the owner is held weakly by construction. The generation counter is
the owner's own lifetime — a wake that finds it gone does not re-arm — with `stop()` left for the one
case a lifetime cannot cover, a shell detached but retained. And the hazard with no symptom, a
tracked read that lands OUTSIDE the block or a work-only read that lands INSIDE it, is unspellable:
`read` returns the value, `apply` receives it and runs outside the tracking block. The fourth — that
`onChange` fires *before* the mutation, so the wake must hop a main turn — stays a mechanism, and now
lives in exactly one place. `Tests/SlopDeskClientCoreTests/ObservationFollowTests.swift` asserts all
four, which the eleven lines inside 88 private methods could not be.

**⚠️ THE ONE PROPERTY THE TYPE DOES NOT INHERIT: arming is not idempotent.** The prologue's generation
counter had a second job nobody wrote down — bumping it on re-entry KILLED the previous arm, so a
method that re-followed simply displaced itself. `arm` bumps nothing, so two calls leave two live
chains and every change applies twice. A site that re-follows because its SUBJECT moved (a leaf
re-arming on the newly focused pane, a card on the newly selected device — the bug already written and
fixed once in `PhoneSimulatorDeviceList`) stores its handle and uses the replacing overload:

```swift
focusFollow = ObservationFollow.arm(self, replacing: focusFollow,
    read: { $0.pane.title },
    apply: { shell, title in shell.titleLabel.stringValue = title })
```

`previous` is by value rather than `inout` because the first `apply` runs synchronously: an `inout`
would still be exclusively borrowed if that apply re-entered and wrote the same property, trapping at
exactly the re-entrant sites the overload is for. **The conversion pass must classify each of the 88
sites as one-shot or re-arming; a re-arming site converted with the plain `arm` reintroduces the
multiplying chain silently.**

**The classification, audited 2026-08-28.** A follow method's real call sites are its own recursive
re-arm plus its entry points, so *two* means one-shot and *three or more* means it re-arms. Thirteen
sites re-arm, and every one of them carries a hand-written generation counter — except the fourteenth,
which did not:

| Re-arming site | Mac | Phone |
| --- | --- | --- |
| `GuiLeafView` (7 calls) · `SplitCanvasView` ×2 (4) · `PaneContainerView` (3) · `TerminalLeafView` (3–4) | ✅ | ✅ |
| `NavigatorColumnViewController` (4) · `PhoneSimulatorConsoleView` (3) | — | ✅ |
| `AndroidStageView` (3) | ❌ **was unguarded — fixed** | ✅ |

`MacAndroidStageView` had the same two entry points as its phone twin (`init` and `waitOutVeil()`) and
never had the counter, so every veil timeout armed a second permanent chain: one model change then ran
`mountScreen`/`rebuildHeader`/`setConsole` once per timeout the stage had survived. Both halves of that
pair are converted to `replacing:` ahead of the general pass — the Mac one because it was a live bug,
the phone one so the clone pair keeps one shape. **Everything else is still held.**

⚠️ That pair also carries a trap for whoever converts the rest: `unmount()` means different things on
the two shells. The phone's is teardown and correctly calls `stop()`; the Mac's is *also* the
mid-flight screen swap (`mountScreen` calls it on every device-key change, from inside `apply`), so a
`stop()` there would leave the stage dead after the first device switch. Match the ROLE, not the name.

Converting the 88 existing sites is a mechanical pass held until the UIKit rebuild lands — a canon
change made while those files are being written is churn, not consolidation. Until then the
hand-written form is still correct and the invariant ledger carries the resulting
`no-cross-target-clone` pairs as `known`, noted as dissolving when the conversion runs. **Write no new
one.**

**One conversion is genuinely delicate and has a test on it already.**
`WorkspaceRootView.swift:154` is `.onChange(of: activeTabCount, initial: true)`, and
`Apps/ClientApp-iOS/Tests/SidebarAutoHideWiringTests.swift:60` pins the `initial: true` semantics.
`withObservationTracking` has no `initial` — it fires only on change — so the conversion is an explicit
call *followed by* arming, in that order, and the reversed order is a real bug the test catches.

### 3.2 View identity and diffing: a keyed dictionary, reconciled

SwiftUI's `.id(PaneID)` becomes `[PaneID: UIViewController]`, reconciled against the model's key set.
`MacSplitCanvasView.applyPanes(_:tab:)` (`:305-345`) is the reference and it is four steps: remove the
keys the model dropped (calling `teardown()` first), mint the keys it added, set the frame on every
survivor, push the two per-pane flags. The dictionary IS the identity, so the "never reuse a surface
across panes" hazard that `SplitContainer.swift:170` states in a comment becomes structural.

The invariant this protects is **keep-all-mounted** (`SplitContainer.swift:1-12`,
`MacSplitCanvasView.swift:3-9`): an inactive tab's subtree is never unmounted, because unmounting kills
the libghostty surface and the return shows a soft-reset screen rebuilt from the lossy ring replay.
SwiftUI states it as `.opacity(isActive ? 1 : 0)` + `.allowsHitTesting(isActive)` +
`.accessibilityHidden(!isActive)` (`SplitContainer.swift:112-114`).

**In UIKit it is `alpha`, never `isHidden`.** `MacSplitCanvasView.swift:336-338` gives the reason and
it holds identically on iOS: a layer-hosting leaf sizes its surface and picks its `contentsScale` in
`layoutSubviews`, and **`layoutSubviews` does not run on a hidden subtree** — so un-hiding after a
display change presents stale geometry. `MetalLayerBackedView.swift:1215-1225` is exactly such a leaf:
it sets `contentsScale` and `drawableSize` in `layoutSubviews` and nowhere else. `alpha = 0` keeps the
view in both trees, and it is precisely what `.opacity(0)` already lowers to
(`CALayer.opacity = 0`) — so this is a spelling of today's behaviour, not an approximation of it.

**Substitution 1, and it is SMALLER on iOS.** `docs/56` risk 3, restated at
`MacSplitCanvasView.swift:19-23`: `.allowsHitTesting(false)` suppressed a composed subtree whole, but
AppKit's `hitTest → nil` does not touch an `NSTrackingArea`, which is rect-based and keeps firing under
a hidden tab — so the Mac must state hit-testing and interactivity separately. **iOS has no tracking
areas.** `isUserInteractionEnabled = false` on the layer root suppresses touch delivery to the whole
subtree and there is no hover to leak. What must still be stated separately is accessibility
(`accessibilityElementsHidden`) and the two per-pane flags, because those are model pushes rather than
framework behaviour.

### 3.3 Layout: solved rects for the canvas, Auto Layout for the chrome

Decided by measurement class, and the measurement is already in the tree.

**The canvas places by frame, in `layoutSubviews`.** `SplitLayoutSolver.solve(_:in:minLeaf:)`
(`Sources/SlopDeskWorkspaceModel/Domain/Tree/SplitLayoutSolver.swift:25-45`) turns a `SplitNode` into
`[PaneID: CGRect]` through `slopdesk_ws_solve_layout`, and its own doc states the budget:
*"`solve(_:in:minLeaf:)` runs on every layout pass, and a parse plus an allocation per frame is the one
kind of regression `CLAUDE.md` says vetoes a port."* The absolute rects exist before Auto Layout could
be asked anything. `MacSplitCanvasView.swift:11-17` draws the conclusion: *"there is nothing left for
Auto Layout to solve: a constraint pair rewritten sixty times a second during a divider drag would be
the same placement bought through the engine."*

There are exactly two per-frame paths in the phone tree and both are gesture-driven, not clock-driven:
a divider drag (`SplitContainer.swift:224-230` → `store.setDividerWeightLive` → full re-solve; the
handle rebuilds and `PaneDivider.swift:151-164`'s ratio readout re-renders each frame) and the
pane-move ghost chip tracking the drag location (`PaneMoveAffordance.swift:~314`). Both get
`layoutSubviews` and `frame` assignment.

**Everything else gets Auto Layout.** The band, the rail, the tab strip, the sidebar rows, the overlay
cards, the accessory bar, the device panel chrome: constant constraint counts, laid out on a state
change rather than a clock, and each needs at least one of `safeAreaLayoutGuide`,
`UIKeyboardLayoutGuide` or `UIFontMetrics` — all three constraint-shaped, all three otherwise
re-derived by hand. `SlopDeskMacUI` reaches for `NSStackView` for exactly these; the phone's
counterpart is `UIStackView` under the same rule.

**Two files sit between the two answers.** `SimulatorBezelView.swift:42-113` is ~50% coordinate math
under a `GeometryReader`, with a load-bearing z-order (buttons under body); it goes to manual layout
because the arithmetic is already there. `ViModeOverlay.swift:232-308`'s `ViKeyHintReflow` is a flow
layout — it *could* be a `UICollectionViewFlowLayout`, but the accumulate-and-place loop is a solver
and §7 sends it to Rust.

**The bar this split must clear** is `macui_memos.rs` M1: `MacGitLineView` choosing a spelling by
asking each candidate its width cost **59–65 µs in `draw(_:)` and 16.8–17.5 µs in
`intrinsicContentSize`, per layout pass**, because AppKit asks both on every one — against 50–52 µs to
build the ladder once and 5 ns per read after. UIKit asks `intrinsicContentSize` on every layout pass
too, and `NavigatorColumn.swift:481-540`'s `IOSGitLineView` is the same view. So any phone view that
measures text to choose a layout memoizes; §4 proposes the ratchet.

### 3.4 Lists: `UICollectionViewDiffableDataSource`, but only where reuse pays

**Where a diffable data source is right.** The test is *unbounded row count* — rows whose number is a
function of the user's project rather than of the design:

| surface | section identifier | item identifier | why |
| --- | --- | --- | --- |
| the navigator / rail (`Columns/NavigatorColumn.swift:122-175`) | the `SidebarSections.sections(_:tabOrder:query:)` section kind — the rail is already built as sections by `rust/slopdesk-workspace`'s `rail_list`/`sidebar_row` through `RailRowsBuilder` (776) | the row's stable `PaneID`/`row.id` (already `.tag(row.id)` at `:189`) | `docs/56` §1 counts "a 40-row rail" as a reason the Mac left SwiftUI; the phone has the same rows on a smaller screen, plus `.searchable` filtering them live |
| Open Quickly, palette, global search, command navigator | one section per `OpenQuicklySection` (`OpenQuicklyView.swift:529-534`); the other three are single-section | the item's own id | `OpenQuicklyView.swift:204-233` records the corpus at **127 candidates × 5 sources**, re-ranked per keystroke |
| the two device consoles (`SimulatorConsoleView.swift`, `AndroidConsoleView.swift`) | one section | the log line's sequence number | `AndroidConsoleView.swift:113-118` measures **0.78 ms hit / 1.50 ms miss at 600 rows**, and logcat carries the whole system |
| the two device lists (`SimulatorDeviceList.swift`, `AndroidDeviceList.swift`) | the `DeviceSection` kind | the device udid/serial | already `LazyVGrid(.adaptive)` — a `UICollectionViewCompositionalLayout` with `.estimated` items is the direct translation, and the animation key `sections.flatMap(\.rowIdentities)` (`:170`, `:149`) is *already* a snapshot identifier list |

`NSDiffableDataSourceSnapshot` wants `Hashable` identifiers and gets them: `PaneID`, `TabID` and
`SplitNodeID` are `public struct … : Hashable, Sendable`
(`Sources/SlopDeskWorkspaceModel/Domain/PaneSpec.swift:16`, `Domain/Tree/TreeIdentity.swift:22`), and
the row readings below them are value types. `apply(_:animatingDifferences:)` on the main queue
replaces the reconcile loop. **The identifier must be the id, never the rendered content**, or a
status change re-creates the cell instead of reconfiguring it — and `SidebarRowReading` changes on
every agent-state edge.

**Where it is wrong, and the Mac is the evidence.** `docs/56` §2 says "`NSCollectionView`/`NSOutlineView`
where a list is a list", and the shipped AppKit does **not** do that: `MacNavigatorColumn` reconciles a
`[RowID: MacSidebarRowView]` dictionary into an `NSStackView` inside an `NSScrollView` (`:64-65`,
`:499`), and `MacOpenQuicklyView` does the same with `column: NSStackView` (`:53`, `:307`). For a
bounded row count that is correct: N rows cost N layout objects and no dequeue bookkeeping, and a row
may keep a live subview.

So the rule is: **a reusable cell may not own an irreplaceable resource.** The split canvas is
therefore never a collection view — its leaves own libghostty surfaces, `CAMetalLayer`s and pooled
`WKWebView`s, and `SplitContainer.swift:1-12` exists to say they are never torn down. The tab strip,
the panel tab strip, the cheat sheet and the fact lines are `UIStackView`s. The seven surfaces above
are collection views. Anything else is decided by counting its rows before it is written.

### 3.5 The responder chain, and `ownsKeyboard`

The least new work in the port, because the arbitration was written for UIKit in the first place.

`PaneFocusCoordinator` (`Sources/SlopDeskWorkspaceCore/iOS/PaneFocusCoordinator.swift`, 205) is already
the resign-before-become arbiter, already generation-guarded by `FocusGenerationGuard`, and its header
(`:9-25`) explains why: `becomeFirstResponder` is honoured a runloop hop later, so two rapid focus
changes land out of order and a stale callback steals focus back to the pane you just left. It drives
a `FocusableInputHost` protocol (`:58-65`) of exactly two methods, deliberately, so UIKit stays out of
the file (`:47-50`). Today its one producer is `TerminalInputHostView`; after the port its producer is
the pane view controller, and **the protocol does not change**.

`@FocusState` (19 sites) goes away entirely. Each is either the coordinator's job or the
`DispatchQueue.main.async { field = true }` idiom that appears **six** times
(`OpenQuicklyView.swift:452`, `CommandNavigatorView.swift:156`, `PeekReplyOverlay.swift:299`,
`GlobalSearchView.swift:282`, `ConnectHostView.swift:149`, `SlateOverlayControls.swift:104-106`) plus
twice more in `TerminalFindBar.swift:103,106` — all of them one-runloop-hop workarounds for a backing
responder that does not exist during the appear tick. In UIKit that is `viewDidAppear` calling
`becomeFirstResponder()` on a responder that has existed since `viewDidLoad`. **Eight hops delete.**

**`ownsKeyboard` is unchanged and stays where it is.**
`CodeSidebarKeyboardState.shared.ownsKeyboard` (`Sources/SlopDeskClientCore/CodeSidebar/CodeSidebarKeyboardState.swift:23`)
is read by both shells identically — `SplitContainer.swift:151` and `MacSplitCanvasView.swift:320`
both pass it into `CodeSidebarKeyboardState.paneRendersFocused(workspaceFocused:sidebarOwnsKeyboard:)`.
It is a *rendering* gate and a *claim* gate at once: a pane that renders unfocused also stops re-taking
the keyboard the editor is using. Under UIKit the rendering half is a property push and the claim half
is `PaneFocusCoordinator`'s, which is where it already was.

**Substitution 2, and it is a win rather than a match.** `UIResponder.keyCommands` and
`pressesBegan(_:with:)` reach the chain *before* the text input system, which is what `PhoneKey`'s
proxy-or-encoder question needs (`PhoneKey.swift:7-13`) — some presses a terminal needs raw (⌃C is
`0x03`, not the letter `c`) and some are the visible half of an unfinished composition. That works
today through 630 lines of representable and a zero-sized `UIView`
(`TerminalInputHost.swift:95-520`); after the port it works through a responder the pane controller
owns, and `PhoneRootKeyResponder`'s "why the app delegate, not a view" rationale (`:10-22`) stops
being a workaround.

**Substitution 3, and it is a loss that must be re-founded.** `OverlayKeyRepeat.swift` is typed on
`KeyPress.Phases` (`.down`, `.repeat`) and `KeyEquivalent`, and **UIKit has no repeat phase at all** —
`KeyRepeater.swift:4-6` says so. The overlays' arrow-key auto-repeat therefore stops being a SwiftUI
whitelist and starts being a second consumer of the same latch the terminal already uses. §7.

### 3.6 `UIViewController` containment for the split tree

The tree is `SplitNode`, an `indirect enum` of `leaf(PaneID)` and
`split(id:axis:children:[WeightedChild])` (`Domain/Tree/SplitNode.swift:150-152`). The containment
shape is **deliberately flat, not recursive**, and that is the most important decision in this section.

`SplitContainer.swift:6-12`: *"Branch nodes are NOT walked into nested HStacks/VStacks here — the
solver already produced absolute rects, so we place every leaf + divider ABSOLUTELY in ONE ZStack keyed
`.id(PaneID)`. This honors the repo guardrail 'drive geometry in one structure, never tree-relocate a
pane on a mode change'."* A recursive container hierarchy would re-parent a pane whenever a split is
added or a zoom toggles, and re-parenting a `UIViewController` calls
`willMove(toParent:)`/`didMove(toParent:)` — precisely the teardown keep-all-mounted forbids.

So the hierarchy is three levels and no more:

```
PhoneWorkspaceController              UISplitViewController          — stage D
└── PaneCanvasController              UIViewController               — owns the tab layers
    └── PaneTabLayerView              UIView, one per mounted tab, alpha 0 unless active
        ├── PaneController.view       one per PaneID, frame from the solver
        ├── PaneDividerView           one per DividerHandle, active tab only
        └── PaneMoveOverlayView       the drag layer, active tab only
```

`PaneController` is a `UIViewController` rather than a bare view because it owns a first responder, a
keyboard accessory view and — for a terminal or video leaf — a resource with a lifetime:
`addChild`/`didMove` once at mint, `removeFromParent` only at real teardown. Everything below it is
`UIView`, because nothing below it owns a responder or a lifecycle.

Splits, zooms and resizes never touch this hierarchy. They re-emit rects.

### 3.7 The 60 fps pane, and its update loop

Two renderers, both already `CAMetalLayer`- or `AVSampleBufferDisplayLayer`-backed `UIView`s, both
already display-link-paced, neither reached by SwiftUI's update loop except through one representable
each.

- **Video.** `MetalLayerBackedView` owns the layer (`layerClass` at `:81`) and sets exactly two
  properties, in `layoutSubviews` (`:1215-1225`). The pacing is `FramePacer`
  (`Sources/SlopDeskVideoClient/FramePacer.swift`), and the ownership is worth stating because it is
  the opposite of the usual: **the pacer owns the `CADisplayLink` and PULLS; the pipeline never
  pushes.** `start(view: UIView)` (`:880`) adds a link to `RunLoop.main` in `.common` through an
  `@objc` proxy (`:193-200`), and `configureCadence` (`:896-903`) sets
  `preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum:, preferred:)`. The render callback
  runs **synchronously inside the link tick** via `MainActor.assumeIsolated`
  (`VideoWindowPipeline.swift:426-441`), because a `Task { @MainActor }` there would cost 0–16 ms of
  present jitter (`:427-433`). None of that changes.
- **Terminal.** `GhosttyLayerBackedView: UIView` at `GhosttyTerminalView.swift:2995`, wrapped at
  `:2953`. Same inversion, vendored file — §8.

**The win is not a faster frame; it is the removal of an update path that had no business existing.**
`VideoLayerRepresentable.updateUIView` (`:90-123`) reassigns ~18 closures and re-calls `activate` on
**every** update, and it is safe only because `VideoWindowPipeline.activate` early-returns on an
unchanged connection (`:255`). `updateUIView` runs whenever the enclosing `body` re-evaluates —
a toast arriving, a status pill flipping, a divider moving. §5.1(b) says how to measure that.

**One thing the survey flagged and this document does not resolve.** The phone calls
`pipeline.activate(...)` from `makeUIView`, **before the view has a window**, so
`view.window?.windowScene?.screen.maximumFramesPerSecond` (`VideoWindowPipeline.swift:335`) resolves to
0; macOS has an `NSScreen.main` fallback at the same site (`:333`) and iOS has none, and `updateUIView`
re-calls `activate` but it early-returns once a session exists. On that reading the first iOS session
asks for a preferred 30 Hz on a 120 Hz panel. **Confirm what `slopdesk_present_resolve_tick_rate`
returns for `displayMaxHz == 0` before treating this as a defect** — but note that the port fixes it
either way, because a controller activates the pipeline in `viewDidAppear`, when there is a window.

### 3.8 The four system behaviours SwiftUI was handing over

| behaviour | SwiftUI today | UIKit | used by |
| --- | --- | --- | --- |
| modal presentation | `.sheet` × 11, `.fullScreenCover`, `.popover`, the `ActiveSheet` priority chain (`OverlayHostView.swift:170-176`) | `present(_:animated:)`; `UISheetPresentationController` + `detents` for the sheets, `.fullScreen` for the cover, `UIPopoverPresentationController` for `SimulatorLocationPopover`; the chain becomes an explicit `presentedViewController` swap | Connect, Palette, Open Quickly, Peek Reply, Global Search, the code panel, the cheat sheet |
| keyboard avoidance | implicit safe-area growth | `view.keyboardLayoutGuide` (+ `followsUndockedKeyboard` for the iPad split keyboard) | every overlay with a field; the terminal accessory bar, which today reads `keyboardWillChangeFrameNotification` by hand (`TerminalInputHost.swift:139-158`) — **that observer deletes** |
| Dynamic Type | implicit on `Font.system` | `UIFontMetrics(forTextStyle:).scaledFont(for:)`, applied **inside** the `Slate.Typeface` adapter so no call site scales by hand | all chrome text |
| safe area | implicit | `view.safeAreaLayoutGuide`; `additionalSafeAreaInsets` for the island moat | the band, the rail, the island |

`presentationDetents` is used **zero** times today, so nothing is lost; what must carry is the sheet
*priority* logic, which is already pure and moves down with §7. `.fullScreenCover`'s "a cover does not
inherit the presenter's environment" workaround (`WorkspaceRootView.swift:171,177`) **disappears**,
because a presented controller is handed its dependencies.

Three smaller mappings the design system needs: `.onHover` (pervasive in `DesignSystem/`) →
`UIHoverGestureRecognizer`; `.help` + `.contextMenu` → `UIContextMenuInteraction`;
`.keyboardShortcut(.cancelAction/.defaultAction)` and `.onKeyPress(.escape)` → `UIKeyCommand`.

## 4. The safety argument

Imperative UIKit has failure modes declarative SwiftUI structurally prevented. Each below names its
countermeasure and then says whether a `rust/slopdesk-invariants` rule can decide it — because a
countermeasure that lives only in a review survives exactly as long as the reviewer's attention.

The precedent for the enforceable half is in the tree: `rules/macui_memos.rs` is the family the Mac's
AppKit port produced, each rule carrying a MEASURED cost and a break-test (M1 the git line's ladder,
M2 Open Quickly's corpus, M3 the canvas's unthemed-leaf cache, M4 the GUI leaf's pane kind, M5 the
container's pane count). The phone owes the same family. The seven rules below belong in one new
`phoneui_memos` module beside the others under `rust/slopdesk-invariants/src/rules/` — written at
stage I, which is why no path is cited here — each with a break-test that seeds the drift and
asserts the rule fires — and each failure message naming this document's section, so the rules are not
restated in `CLAUDE.md`.

**Two mechanics of that crate govern everything below and are worth stating once.** A rule is a free
`fn(&Tree) -> Report` built from declarative `Claim` values, and it **lands by being added to
`registry()` in `src/rules/mod.rs` by hand** — the header there says it: *"there is no macro, no
inventory crate and no link-time registration… A rule that is written but not registered is a rule
that runs never."* Its break-test is a sibling `#[cfg(test)] mod tests` in the same file, built with
`crate::tests::Fixture`, because — as `lib.rs` puts it — *"a rule's break-test is a unit test because a
`Report` is a value."* `just invariants-test` runs them, and two registry-level tests backstop the set
(`every_rule_name_is_unique`, `the_live_tree_satisfies_every_rule`).

**And there is a hazard in the crate itself that this campaign creates, which §4.8 states in full:** a
`Claim` whose pattern is a SwiftUI *spelling* does not fail when the SwiftUI goes — it passes over a
tree that no longer contains anything it can catch.

### Hazard 1 — retain cycles in target/action and delegate wiring

**What SwiftUI prevented.** A `View` is a value; it cannot be captured, so an action closure could not
close over it.

**Countermeasure.** `addTarget(_:action:for:)` and UIKit's delegate properties are `unowned`/`weak` by
Apple's convention and need no discipline. The risk is entirely in *our* stored closures, and there are
a lot of them: `onResizeBegin`/`onResizeChange`/`onResizeEnd`/`onReset` (`SplitContainer.swift:218-245`),
`onChanged`/`onEnded`/`onTap`/`onInterrupted` (`:291-313`), the ~18 video sinks
(`VideoLayerRepresentable.swift:38-53`), and `WorkspaceRootView`'s three seam-wiring closures
(`:211-263`). The rule is the one `docs/60` C.1 reached from the other direction — *split the sink from
the thing that owns the client* — plus `[weak self]` at every stored-closure site.

**Enforceable?** Partly. A rule can require that a closure-typed stored property in the phone targets
is `[weak self]`-captured where it captures anything — text-decidable and break-testable. It cannot
decide a cycle through two objects neither of which is `self`. Proposed:
**`phone-closure-sinks-are-weak`**.

### Hazard 2 — `[weak self]` discipline in escaping closures

**Countermeasure**, and it is stronger than a convention: the §3.1 idiom pairs `[weak self]` with a
**generation counter**, and the generation is what makes it correct. `[weak self]` alone lets a
re-armed callback from an *earlier* tracking scope fire against a live `self` that has since been
re-wired. `MacSplitCanvasView.swift:500-519` and its `teardown()` at `:521-529` are the pair; every
phone controller that follows a model copies both halves.

**Enforceable? Yes, and this is the highest-value new rule.** `withObservationTracking` has exactly one
legal shape in this tree and it is checkable as text: every `withObservationTracking(` under
`Sources/SlopDeskPhoneUI` must sit in a method whose body also contains `generation &+= 1`, and its
`onChange` must contain `[weak self]` and a `generation == self.generation` guard. Proposed:
**`phone-observation-is-generation-guarded`**, break-tested by seeding a tracking site with the guard
removed. A companion floor (`Claim::Populated`) keeps it from passing by reading an empty tree, the way
`design_ratchets.rs:56-62` already does.

### Hazard 3 — use-after-free through stale index paths

**What SwiftUI prevented.** `ForEach` handed the *element*, never an index; a row's identity was its
`Identifiable` id.

**Countermeasure.** An `IndexPath` from a collection-view callback is resolved through the diffable
data source's `itemIdentifier(for:)` — never by subscripting a stored array — and every action is keyed
by the identifier. This is `macui_memos.rs` M2's claim arriving from a different direction: *"a clamp
or a ⌘-digit resolved against a freshly-derived corpus answers about rows the user is not looking at,
because the corpus can have moved under the selection since the draw that showed it."* Here the corpus
moves under the index path, and the seven collection surfaces of §3.4 are all live-filtered.

**Enforceable? Yes, narrowly and usefully.** Ban array subscripting by index path in the phone targets
— the shapes `[indexPath.item]` and `[indexPath.row]` — which forces `itemIdentifier(for:)`. Proposed:
**`phone-rows-resolve-by-identifier`**.

### Hazard 4 — main-thread violations and background `UIView` mutation

**What SwiftUI prevented.** Less than it seems — this hazard exists today. What changes is the blast
radius: a background write to `@State` was a runtime warning; a background `view.frame = …` is a
corrupted layout tree.

**Countermeasure.** Swift 6 is already on (`Apps/ClientApp-iOS/project.yml:105`) and
`UIView`/`UIViewController` are `@MainActor` in the SDK, so the compiler decides most of it. The
residue is where the tree deliberately crosses threads and would have to silence the compiler to do
it: `KeyRepeater`'s production `DispatchRepeatScheduler` fires on a background serial queue
(`KeyRepeater.swift:36-41`) and hops back with `Task { @MainActor [weak self] in }`
(`TerminalInputHost.swift:~124`); the video decode and stats callbacks; the device panels' socket
reads, which are one place now — `DeviceSocketSink.say` hops off the `slopdesk-devicelink` reader
thread with `DispatchQueue.main.async`, deliberately NOT `Task { @MainActor }`, because a reader
thread delivers back to back and two enqueued `Task`s carry no mutual ordering where a serial queue
does; screend/superd replies. `MainActor.assumeIsolated` is legal only
where the caller has already guaranteed isolation — `MacSplitCanvasView.swift:507` is inside a
`DispatchQueue.main.async`, which is the guarantee; `VideoWindowPipeline.swift:426-441` is inside a
`CADisplayLink` callback, which is another. `PaneDropReceiver.swift` has **five** such sites
(`:88,101,119,129,143`) and each must keep its justification when it becomes a
`UIDropInteractionDelegate`.

**Enforceable? Yes.** Ban `MainActor.assumeIsolated` in the phone targets unless the enclosing lines
name `DispatchQueue.main.async` or a display-link callback; ban `nonisolated(unsafe)` outright, since
neither has a use here that is not a silenced diagnostic. Proposed:
**`phone-assume-isolated-is-earned`**.

### Hazard 5 — dangling observers and KVO

**Countermeasure.** Keep the near-absence. The observation mechanism is `Observation`, whose
registration dies with the closure; there is **no KVO** in the phone tree and there should be none
after. `NotificationCenter` appears three times in `Sources/SlopDeskPhoneUI` and once in
`TerminalInputHost.swift:139-144` — and that one *deletes*, because
`keyboardWillChangeFrameNotification` becomes `keyboardLayoutGuide` (§3.8). Where a block-based
`addObserver(forName:object:queue:using:)` remains, its token must be stored and removed; the
selector-based form is auto-removed since iOS 9 and is the safer default.

**Enforceable? Yes.** Every `addObserver(forName:` in the phone targets must have a `removeObserver` in
the same file. Proposed: **`phone-notification-tokens-are-retired`**.

### Hazard 6 — timer and `CADisplayLink` lifetime

**This is the hazard the port creates**, and it is the only one where UIKit is strictly worse.
`.task(id:)` cancelled its work when the view left the tree. There are **eleven** such lifetimes today:
three dwell loops (`ToastStackView.swift:194-205`, `InstrumentChip.swift:133-137`,
`CopyReceiptChip.swift:45-48`), one 1 Hz `TimelineView` (`GuiLeafView.swift:501`), one
`TimelineView(.animation)` at display rate (`StatusDotView.swift:136-138`), one 2-second thumbnail poll
**per visible card** (`SimulatorRunningCard.swift:64,143-152`), five `.task(id:)` orchestration loops
in `CodePanelSurfaces.swift:158,235,246,284,292`, plus `ConnectHostView`'s stored/cancelled task and
`PromptJumpFlashOverlay`'s epoch-keyed sequence.

**Three different mechanisms, and they must not be confused:**

- **A dwell or poll timer becomes a `Task` stored on the controller and cancelled in `deinit`** — the
  shape `ConnectHostView.swift:169-181` already uses, generalised. `.task(id:)`'s epoch keying becomes:
  on a new epoch, cancel the stored task, then start another. `CodePanelSurfaces.swift:243-245`'s
  "separate restart keys with different cadences" is a correctness constraint on this translation, not
  a style note.
- **A `CADisplayLink` retains its target**, so a controller holding one is retained by the run loop and
  never deallocates — it keeps rendering into a layer nobody can see. The countermeasure is a proxy:
  the link's target is a small `final class` holding a `weak` back-reference, and `invalidate()` is
  called from an explicit teardown, **never only from `deinit`**, which by construction cannot run
  while the link is alive. `FramePacer.swift:193-200` already ships exactly this proxy, and
  `AgentSpinnerView` is the first new consumer.
- **`Timer.scheduledTimer` is banned.** It retains its target too, with worse ergonomics; the tree uses
  it **zero** times today and should stay at zero.

**Enforceable? Two of three.** `Timer.scheduledTimer` is a text ban. A `CADisplayLink(` in the phone
targets must have an `invalidate()` in the same file — text-decidable, and it catches the real case (a
link created and never invalidated anywhere). Whether `invalidate()` is *reached* is not text-decidable
and stays a review item. Proposed: **`phone-display-links-are-invalidated`**,
**`phone-has-no-scheduled-timers`**.

### Hazard 7 — reentrancy during `layoutSubviews`

**What SwiftUI prevented.** `body` was pure; it could not mutate the model it read.

**Countermeasure, and it is a rule about direction.** `layoutSubviews` may read the model and set
frames. It may not write the model, because a write invalidates observation, which schedules a
relayout, which calls `layoutSubviews` — an unbounded loop with no `setNeedsLayout` in sight to blame.
The canvas is where it bites, because it *does* report geometry back:
`SplitContainer.swift:206-208` calls `drag.reportSolvedLayout(frames, isActive:)` and `:121-122`
`drag.reportContainerBounds(bounds)`. Today those are `.onAppear`/`.onChange`, which run outside
layout. Under UIKit they must be dispatched out of `layoutSubviews`, or guarded by equality against
the last reported value — which `MacSplitCanvasView` already keeps as `lastReportedBounds` (`:56`).

Two more sources SwiftUI absorbed: `intrinsicContentSize` must not measure anything that can change
during layout (this is M1's other half), and
`UICollectionViewDiffableDataSource.apply(_:animatingDifferences:)` from inside a layout pass is a
documented crash — which matters because six of the seven collection surfaces re-filter on a keystroke
that also resizes their container.

**Enforceable? The part that matters, yes.** Ban mutating `store.` / `coordinator.` calls inside a
`layoutSubviews` body in the phone targets, by locating the method's brace range and checking the known
mutator prefixes — the technique `macui_memos.rs` M2 already uses to ban a method growing back.
Proposed: **`phone-layout-does-not-write-the-store`**. The `lastReportedBounds` de-duplication is a
review item; the recursion it prevents is not statically visible.

### Hazard 8 (§4.8) — the ratchets that go quietly vacuous

**This one is not about UIKit; it is about the gate, and it is the hazard nobody would notice.** A
`slopdesk-invariants` rule that bans a SwiftUI *spelling* does not turn red when the SwiftUI leaves —
it turns **green forever**, over a tree in which the thing it was protecting can now happen freely.
`Claim::NoneUnder`/`NoFileUnder` over a root that no longer contains a match passes vacuously
(`claim.rs:1186-1275`), which is exactly why `Claim::Populated` floors exist — and a `Populated` floor
counting *files* stays satisfied while the *pattern* stops matching any of them.

Four live rules fail this way under this port, and each must be re-spelled in the stage that empties
it, not after:

| rule | the spelling it bans | why it stops catching anything |
| --- | --- | --- |
| `design-token-leaks` (`design_ratchets.rs:37`) | `\.font\(\.system\(size: ?[0-9]`, `cornerRadius[(:] *[0-9]`, `\.frame\(height: ?[0-9]` | two of three arms are SwiftUI-only. `UIFont.systemFont(ofSize: 13)` and an `NSLayoutConstraint` are unmatched, and the idiomatic `view.layer.cornerRadius = 8` uses ` = `, which the radius arm's `[(:]` misses. The `Populated{min 60}` floor stays green at 86 files, **so nothing announces the loss** |
| `overlay-host-ambient-layer` (`overlay_split.rs:56-62`) | `Lacks{ allowsHitTesting }` on the overlay host | the UIKit spellings of the identical hazard — `isUserInteractionEnabled = false`, a `hitTest(_:with:)` returning `nil` — are unnamed. The rule sits permanently green over a host that can still eat every click across the split |
| `one-clear-key` (`phone_parity.rs:303`) | `Image\(systemSymbol: \.xmarkCircleFill\)` under `Panel/` | UIKit spells it `UIImage(systemSymbol:)` |
| `panel-vocabulary`'s and `panel_floor`'s representable bans | `NSViewRepresentable` / `UIViewRepresentable` under PhoneUI | a UIKit phone cannot write a representable at all, so the ban has nothing left to catch |

**And one rule's premise dissolves rather than its pattern.** `silent-paste-probe`
(`phone_parity.rs:386-387`) exists because *"the Mac's twin may read content because it builds its menu
in `onClick`; SwiftUI has no equivalent moment, which is why this rule is the phone's alone."* UIKit
gives the phone that moment back, so the rule is not re-aimed — it is **retired with its reason
recorded**, which is a different act and needs saying so in the commit.

**The countermeasure is procedural and it is a stage exit condition.** Before a stage's rules are
re-aimed, each is **break-tested against the ported tree** — seed the drift in UIKit spelling and
assert the rule still fires. A rule that cannot be made to fire is a rule that has stopped working,
and the stage does not land until it does. Two of the pins above have a nastier variant worth naming
separately: `Claim::Names`/`Mentions` read `source.text` **raw** (`claim.rs:1063-1069`), so a needle
surviving only in a *comment* satisfies them. `panel_floor.rs:87-98`'s two `Names{"UIViewRepresentable"}`
pins on `SimulatorScreenView.swift` and `AndroidScreenView.swift` are in exactly that state —
`SimulatorScreenView.swift:11` already carries the word in prose — so after stage G each either goes
red or passes over a comment. **Both outcomes are wrong**, and neither is visible without looking.

Three more fragilities the port will meet, recorded so the person who meets them does not think they
found a bug: `Lacks{ PHONE_HOST, "draws" }` (`overlay_split.rs:337`) is a **bare substring**, so a
UIKit `draw(_ rect:)` override or a `drawsAsynchronously` false-fires a message about the stage-D
ledger; `Lacks{ OverlayHostView.swift, r"ToastStackView\(" }` (`split_surfaces.rs:158`) pins a SwiftUI
*initializer*, which `addSubview(toastStack)` slips while re-creating the hazard; and
`source_comments_cite_files_that_exist` (`repo_invariants.rs:790`) requires every backticked
`…/*.swift` path in a comment to resolve, so a stage that renames files reds it once per stale
citation across ~40,000 lines of header prose. That last one is not a defect — it is the campaign's
free reference-integrity check, and it should be welcomed rather than worked around.

### Hazard 9 (§4.9) — a member name `UIResponder` already owns

**The one hazard on this list that SwiftUI could not have.** A `@State` lives in a struct that inherits
from nothing, so any name was free. Every view in the UIKit shell inherits `UIResponder`'s vocabulary,
and a stored property that reuses one of those names is not a shadow — it is an *override* against an
incompatible type. The compiler catches it, so it never ships; what it costs is a build, and it has now
cost two: `61eab344` unshadowed `UIView.isFocused`, and stage I found `TerminalFindBarView` storing
`private let next: SlatePlateVerbButton`, which is `UIResponder.next`. Both were written by naming a
button after what it does. Twice is this campaign's own bar for minting a rule, so
`phone-members-avoid-responder-names` (`phoneui_memos.rs`) is that rule.

**Its anchor is the interesting part, and it is §4.8's lesson pointed the other way.** `next` is a
correct name for a *local*, and the shell holds six — a ban on the bare word would red on all six. That
is precisely how this stage's first cut of H4 and of the §8 import ban died: a rule whose premise is
false on live code gets suppressed, and a suppressed rule protects nothing. So the pattern requires a
**four-space indent**, which under this tree's `swiftformat` config is the member level and nothing
else. It under-reports — a stored property in a *nested* type sits at eight and is missed — and that is
the right direction: a miss costs one compiler error, a false positive costs the rule. Measured
2026-08-29: 0 matches at member level, 6 locals deeper.

**One standing gap this campaign should close while it is in here.** `ink_floor.rs` registers seven
rules and holds five test functions; `fold-gate-condition`, `two-test-trees` and `drop-chip-and-pill`
have **no break-test anywhere** in the crate, against `CLAUDE.md`'s "each rule carries a break-test"
contract. All three are rules this port touches.

### The two that stay review-only, said out loud

A cycle between two objects neither of which is `self`, and whether a `CADisplayLink`'s `invalidate()`
is reached on every path. Both are found by the same tool — Instruments' Leaks and Allocations on a
device — and §6 names that run as a stage's exit condition rather than pretending a text rule covers
it.

## 5. Performance — what this port is FOR

`CLAUDE.md`: *"perf parity is enough to move existing Swift… A measured regression is the only veto."*
That cuts both ways. Parity is the bar, so no claim below is required to be a win — but a claim without
its measurement is not a claim, and this section's job is to make each falsifiable before the code is
written.

### 5.1 Where UIKit can beat the SwiftUI it replaces

**(a) No `body` re-evaluation.** *Mechanism:* SwiftUI invalidates a `body` when any observed property
that body read changes, and re-runs the whole function to produce a value tree it then diffs.
`withObservationTracking` invalidates a *named* set and runs a *named* apply — the Mac's canvas names
exactly three reads (`MacSplitCanvasView.swift:503-505`), where `SplitContainer.body` re-evaluates
through `tabLayer` → `PaneContainer` for every tab of every retained session. The sharpest instance is
`GuiLeafView.swift:398-473`, whose `liveSurface` rebuilds ~10 injector closures and 6 telemetry sinks
on every render — and whose `body` had to be manually split at `:120-123` **because the type-checker
timed out**, a cost that vanishes entirely. *Measure:* an `OSSignposter` interval around the canvas
relayout, sampled over a 5-second divider drag and a 20-toast burst, before and after, on the same
device at the same thermal state. This repo has already been bitten by load-sensitive thresholds —
three Swift tests read machine load as a regression — so a quiet machine is part of the method.

**(b) The representable update path disappears.** *Mechanism:* §3.7 —
`VideoLayerRepresentable.updateUIView` reassigns ~18 closures and re-calls `activate` on every `body`
re-evaluation, and the same holds for the two device screens and the webview. *Measure:* a counter in
`updateUIView` (and in the post-port property push) over a fixed 60-second scripted session. The
post-port number should equal the count of real property changes; the pre-port number is whatever
`body` invalidation produced. This is the single most likely large win and the easiest to falsify.

**(c) Cell reuse on the seven unbounded surfaces.** *Mechanism:* §3.4. *Measure:* the tree already
carries the pre-port numbers, which is unusual and worth exploiting —
`OpenQuicklyView.swift:204-233` records 125 µs ranking + 20 µs row minting per keystroke and notes it
*"was previously paid twice"*; `AndroidConsoleView.swift:113-118` records 0.78/1.50 ms at 600 rows;
`SimulatorConsoleView.swift:139-150` records 0.87–1.66 ms per derivation. The post-port numbers go
beside them, in the same comments.

**(d) `CALayer` work avoided.** *Mechanism:* SwiftUI composes modifiers into layers eagerly — a
`.background` + `.overlay` + `.slateShadow` + `.clipShape` stack is several backing layers — where a
hand-written view draws the same result with one layer's `cornerRadius`/`borderWidth`/`shadowPath`.
`shadowPath` in particular is the difference between an offscreen pass and none, and `Slate.Elevation`
has five rungs that every card, chip, pill and overlay wears. *Measure:* Instruments' Core Animation
"Color Offscreen-Rendered Yellow" over the palette, the toast stack and the rail, before and after.
**This is the one claim that can plausibly lose** — a hand-rolled shadow without an explicit
`shadowPath` is slower than SwiftUI's — so it is measured before it is believed.

**(e) Direct `CADisplayLink` pacing.** *Mechanism:* already in place for both surfaces; the port
removes an indirection, not a pacing decision. **Claim parity, not a win**, and measure it as parity:
`FramePacer.drainTelemetry()` (`:465`) plus a dropped-frame count over a fixed stream. The one place a
real win may hide is §3.7's `displayMaxHz == 0` question.

**(f) `drawRect` vs layer-backed compositing — and the answer is mostly "neither".** A `draw(_:)`
override forces a CPU-rasterized backing store; layer properties do not. So chrome that is rectangles,
rounded rectangles, strokes and text uses layer properties and `UILabel`; only a genuine *drawing* —
`SlateVectorArt`'s `SVGPath` glyphs, `SlateStatusMark`'s geometry, `SimulatorBezelView`, the two
`Canvas` sites (`LinkHighlightOverlay.swift:90`, `PhonePanelMark` at `PhonePanelSheet.swift:274`) —
becomes a `CAShapeLayer` where the path is static and a `draw` override only where it is not.
`MacNavigatorColumn.swift:713` overrides `draw` for exactly one thing. *Measure:* the count of
`draw(_:)` overrides in the phone target at each stage boundary, plus a Time Profiler sample during a
rail scroll.

**(g) One thing that is not a UIKit win but the port should take anyway.**
`GlobalSearchView.swift:245-253` re-runs `store.runGlobalSearch` on every keystroke with no debounce.
That is a defect in either framework; the port is when it is noticed.

### 5.2 What harness exists, and the answer is: almost none

This had to be checked rather than assumed, and the finding is uncomfortable enough to be §6's
governing constraint.

- **`just check` runs ZERO iOS assertions.** `check: lint build test miri golden check-ios
  check-ios-bundle check-macos-apps`. `check-ios` is `slopdesk-gate ios` — the binary is
  `rust/slopdesk-devtools/src/bin/gate.rs`, and the body is `gates::xcode::ios_typecheck`, an
  `xcodebuild … build` against `generic/platform=iOS Simulator`. It **type-checks and nothing more**.
  `check-ios-bundle` (added 2026-08-30, when it was split out of `check-ios` to get its 25-minute
  build out of `quick` — `docs/46`) does not change that sentence: `build-for-testing` COMPILES the
  bundle and executes none of it.
  `check-ios-tests` — whose own comment says *"`slopdesk-gate ios-tests` is the only thing in the repo
  that executes an assertion on the iOS triple"* — is **deliberately not in `check`**, because it boots
  a simulator (`justfile:421-431`). When it is run it is strict: `xcode.rs:373-390` asserts
  `declared_tests == executed_tests`, so a silently-skipped test is a gate failure.
- **`test-touched` cannot see this campaign at all.** `gates/touched.rs:67-74` — `PATHSPEC =
  ["Package.swift","Package.resolved","Sources","Tests","golden","scripts"]`. **`Apps/` is absent**, so
  an edit confined to `Apps/ClientApp-iOS` — which is stage A in its entirety, and part of most later
  stages — selects no test target. `just quick` on such a commit runs the linters and the stamped
  gates, and zero tests.
- **There is no pixel recipe, no perf recipe, no bench recipe.** Not "they are opt-in" — `just --list`
  contains no `pixel*`, `verify*`, `perf*`, `bench*` or `snapshot*` target. The four `gui-*` recipes
  (`justfile:440-453`) drive `slopdesk-guigate` and are macOS-only.
- **The phone's only test home is `Apps/ClientApp-iOS/Tests/`**, eleven files, ~50 methods.
  `Package.swift:975-988` explains why there is no SwiftPM suite: `SlopDeskPhoneUI` is `#if os(iOS)`
  end to end, so on the host triple it compiles to an empty module.
- **The pixel rigs are opt-in and have no golden.** `SlateSnapshotRender.swift` renders through
  `ImageRenderer` → `.uiImage` → `.pngData()` and every test is `XCTSkip` unless its `SLOPDESK_*` env
  var is set (`:42,76,183,253,316,388`). **No pixel hashing, no diffing, no golden files.** The header
  says so at `:6`: *"It is NOT a pixel-diff CI gate."*
- **`slopdesk-perfbench` and `slopdesk-framewatch` are host-side** (`docs/61` §1 rows 5–6), driving the
  encoder and an `SCStream`. Neither is Swift any more — `slopdesk-perfbench` dissolved into
  `rust/slopdesk-loopback-validate` and `slopdesk-framewatch` is `rust/slopdesk-instruments`'
  `slopdesk-framewatch` bin — and neither can measure a client frame time either way.

- **The one piece of client frame instrumentation that exists measures the wrong layer.**
  `FramePacer.drainTelemetry()` (`:465-469`) → `PacerTelemetrySnapshot(lateFrames:presentGaps:depth:)`
  → `SlopDeskVideoClientSession.swift:912-929` → `RemoteWindowModel.swift:130,155` →
  `GuiPaneReadout.swift:77-84` → `GuiStatsReadout` (`GuiLeafView.swift:262-269`). It measures **video
  frame presentation** on the Metal path, it runs only inside a live GUI app and never in the test
  bundle, and it has no hook into SwiftUI body evaluation or UIKit layout cost. It cannot answer the
  question §5.1(a) asks.
- **And the instrument that could answer it is not in the tree.** There are **zero** references to
  `os_signpost`, `OSSignposter` or MetricKit anywhere under `Sources/` or `Apps/`. Every signpost §5.1
  proposes is new code.

So the six measurements in §5.1 have **no existing harness**; every one is an Instruments run plus a
signpost that has to be added first. That is not a reason to skip them — it is why §6 makes "the
measurement exists" a stage exit condition rather than a follow-up, and why §5.1(a)'s before-number can
only be taken at stage E.0 and never again.

**And there is a trap inside the one rig that does exist.** `SlateSnapshotRender.swift:63-66` and
`:464-469` state that `ImageRenderer` paints an *unavailable placeholder* for a representable — *"If a
tile in this sheet ever becomes a `UIViewRepresentable`, this render starts lying (an empty box in a
PNG that still gets written)."* A UIKit port makes every tile a `UIView`. So the rig must move to
`UIGraphicsImageRenderer` over an offscreen `UIWindow` — mirroring the Mac's
`MacChromeSnapshotRender` — **in the same commit as the first tile it draws**, and it will not fail
loudly if that is forgotten. This is the single most dangerous silent failure in the campaign, and
§6 stage C owns it.

### 5.3 What the port costs, stated honestly

`SlopDeskMacUI` is 32,257 lines where the SwiftUI it replaced was smaller. The phone should expect the
same direction: ~19,300 lines of phone UI becoming ~28,000–33,000. The gain is not fewer lines; it is
that every one of them is a line somebody chose.

## 6. The plan: ONE demolition, then a rebuild

> ⚠️ **THIS SECTION WAS REWRITTEN ON 2026-08-28. The nine-stage incremental plan it used to hold was
> OVERRULED BY THE USER, twice in one session, the second time in as many words:**
>
> > *"Bỏ hết SwiftUI đi cho tôi, để không phải bridge phức tạp. Code thuần appkit/uikit theo cách sạch
> > nhất."*
> >
> > *"Không cần phải giữ cái gì để build được code cả, cứ đập bỏ hết luôn trong 1 lượt rồi xây lại từ
> > đầu những thứ đã đập. Chứ cái trò vừa đập vừa vá mất thời gian lắm."*
>
> — *delete every last piece of SwiftUI so there is no bridging at all; write plain UIKit the cleanest
> way. Keep nothing merely to hold the build up: demolish the lot in ONE pass and rebuild what was
> demolished. The demolish-and-patch dance wastes too much time.*
>
> The stage structure below survives ONLY as the rebuild's inventory and spec — what each cluster
> contains, what it must do, and which hazards it hits. It is no longer a schedule of separately-green
> commits, and the exit conditions it used to state per stage do not apply.

**§§1–5 and 7–8 are unaffected.** The correction, the inventory, the architecture, the eight hazards
and the performance argument are all statements about UIKit and about this tree; none of them depended
on the pacing. Only the pacing changed.

### What "one pass" means, precisely

**A red tree during the rebuild is expected and acceptable.** That is the whole content of the
user's instruction, and it inverts this repo's usual reflex. There is no per-cluster green, no
`UIHostingController` scaffolding, no coexisting second spelling and no compatibility shim — every one
of those is a thing kept alive *to hold the build up*, which is exactly what was banned. The tree gates
again at the first milestone where the app target compiles as pure UIKit, not before.

**Scope of the demolition — phone only:**

| Deleted | Count | How |
| --- | --- | --- |
| `Sources/SlopDeskPhoneUI/` outside `DesignSystem/` | 66 files, ~15,400 lines | `git rm` — all committed, all recoverable |
| `Apps/ClientApp-iOS/` SwiftUI files | 7 files | `git rm` |
| `Sources/SlopDeskVideoClientPhone/` SwiftUI files | 2 files | `git rm` |
| `Sources/SlopDeskPhoneUI/DesignSystem/` | 18 files | **edited, never `git rm`** — the SwiftUI half is cut, the hand-written UIKit half stays |

**Out of scope, deliberately.** `Sources/SlopDeskMacUI/` (8 SwiftUI files), `Sources/SlopDeskSlate/`
(5) and `Sources/SlopDeskVideoClientMac/` (3) are a separate and much smaller crossing. `SlateDesign.swift`'s
`Color` bridges feed the Mac's remaining SwiftUI, so deleting them here breaks the Mac shell for no phone
benefit. The Mac is already at its AppKit floor (~65 files import AppKit against 14 representable
wrappers); it is not what the user is describing.

### The carve-out is CANCELLED

The previous plan bought itself a bounded exception: `DesignSystem/` could hold both spellings of each
token adapter, counted and ratcheted down. **That exception no longer exists**, and neither does the
argument that supported it. It was reasoning from a premise — "each stage must leave the tree able to
build and run" — that the user has now rejected. `CLAUDE.md`'s *"One implementation, never two
languages… not a fallback"* applies here without the softening: the eighteen files keep exactly one
spelling, the UIKit one, and the SwiftUI declarations are cut in the demolition commit along with
everything that mounted them.

The `UIHostingController` argument is cancelled with it. A hosting controller is precisely the "bridge
phức tạp" the user named; there is no stage in which one is mounted, and the count that was to start at
1 and fall to 0 starts at 0.

`HostedRaster`'s hosted-SwiftUI overload — written earlier the same day, before the directive — is a
casualty of the same rule and is deleted rather than kept for the tests. Its `UIView` overload,
already proven on real pixels, is the whole rig.

### The order

1. **Demolish**, in one commit, with the ratchet ledger re-aimed or parked in that same commit — a
   `slopdesk-invariants` that is red for the length of a rebuild has stopped being a ledger, so each
   rule whose target just vanished is deleted (it asserted a SwiftUI shape), re-aimed (it asserts a
   product law that survives, spelled differently), or parked against the cluster that restores it.
   The `Populated` / `AtLeast` FLOORS need new numbers in the same pass: they fail on the deletion
   alone, whatever else holds.
2. **Rebuild in dependency order**, fanned out by cluster with strict file ownership: app entry →
   `DesignSystem/` (already UIKit) → the shell → the canvas → the overlays → the panels → the
   navigator → `CodeSidebar/`. The stage sections below are those clusters' specs.
3. **Gate once**, at the first milestone that compiles: the closeout chain, then `just quick`, then
   `just check-ios-tests` on a booted simulator — the one gate nothing else runs.
4. **Flip the ratchet to a ban.** `import SwiftUI` under the phone tree goes from a count to zero and
   then to a `NoFileUnder` prohibition, which is the user's sentence written as law: SwiftUI does not
   come back.

### Cluster A — the process

**Moves.** `Apps/ClientApp-iOS/AppMain.swift` (235) and `Sources/SlopDeskPhoneUI/SlopDeskPhoneApp.swift`
(273). The `@main struct ClientAppMain` keeps its six seam registrations (`:72-222`) and stops calling
`SlopDeskPhoneApp.main()`; `SlopDeskPhoneApp: App` becomes `PhoneAppDelegate: UIResponder,
UIApplicationDelegate` and `PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate`. The root window's
`rootViewController` is one `UIHostingController(rootView: WorkspaceRootView(...))`.

- `init()` `:76-124` → `application(_:didFinishLaunchingWithOptions:)`.
- `installNotificationSinks` `:139-186` → the delegate; the static `notificationRouter` retention
  (`:40`) becomes a stored property, which is what it wanted to be.
- `@Environment(\.scenePhase)` `:51` + `handleScenePhase` `:248-271` → the four scene callbacks.
  **Keep the `lifecycleTask` serialisation (`:252`, `await prev?.value`) — UIKit has no equivalent**,
  and it is what makes `beginBackgroundTask` → `saveImmediately` → `pauseAll` → `connection.pause` →
  `endBackgroundTask` atomic against a fast background/foreground flap.
- The four `.task` blocks `:207-234` → scene-owned `Task`s cancelled in `sceneDidDisconnect`. **This is
  a semantics change and must be recorded:** today two scenes each run their own clipboard poll.
- `@UIApplicationDelegateAdaptor(PhoneRootKeyResponder.self)` `:50` → `PhoneRootKeyResponder` merges
  into the real delegate, and its `:10-22` rationale stops being a workaround.
- `Apps/ClientApp-iOS/Info.plist:21-25` and `project.yml:81-82` declare
  `UIApplicationSupportsMultipleScenes: true` **with no `UISceneConfigurations` array**, which works
  today only because `WindowGroup` supplies the scene. Stage A adds it.

**Invariant rules re-aimed.**

- `ui_split::the_ui_split_holds_its_shape` — its `rescued_by` is `^import (SwiftUI|AppKit|UIKit)$`
  (`ui_split.rs:69`), so UIKit is **already accepted** and the framework claim needs no change. But its
  `PerFileCounts` (`:110-122`) pins `Apps/ClientApp-iOS/AppMain.swift` to exactly two `#if/#endif`
  directives, one `^#if os\(iOS\)$` and one `^#endif$` — and this stage changes that file's shape.
  Re-count, do not delete.
- `phone_parity::the_phone_dispatches_chords_at_the_root` (`phone-root-key-rung`) — **red.** It is
  `Claim::Matches{ pattern: r"UIApplicationDelegateAdaptor\(PhoneRootKeyResponder\.self\)" }`
  (`phone_parity.rs:89`), and that adaptor exists **only** to bridge UIKit into a SwiftUI `App`. Its
  second claim — `PhoneRootKeyPolicy.rung` is asked rather than re-spelled — survives verbatim and is
  the half that mattered. Re-aim the first at the real delegate; keep the second; re-run both
  break-tests.
- `two_shells::no_body_crosses_the_ui_split` (`no-cross-target-clone`) — `NoCloneAcross{ window: 8,
  floor: 50 }` over the two UI targets, with a `known` ledger of **seven pairs** (`two_shells.rs:108-141`).
  This stage rewrites one half of `SlopDeskMacApp`/`SlopDeskPhoneApp`. **The rule fails in both
  directions** — a pair that stops cloning is an unpaid ledger entry exactly as a new clone is a
  violation — so **every stage that rewrites a file named in the ledger updates it in the same
  commit.** The whole map, stated once here rather than rediscovered per stage:

  | pair | stage |
  | --- | --- |
  | `MacApp/SlopDeskMacApp.swift` ↔ `SlopDeskPhoneApp.swift` (annotated *"waiting on `ClientNotificationSinks` being called from the phone half"*) | A |
  | `App/MacWorkspaceRootView.swift` ↔ `WorkspaceRootView.swift` | D |
  | `Pane/MacGuiLeafView.swift` ↔ `Pane/GuiLeafView.swift` (*"the largest remaining pair, and the next one worth a floor"*) | E.1 |
  | `Pane/MacTerminalLeafView.swift` ↔ `Pane/TerminalLeafView.swift` | E.1 |
  | `Pane/MacPromptJumpFlashOverlay.swift` ↔ `Pane/PromptJumpFlashOverlay.swift` | E.3 |
  | `Pane/MacTerminalFindBar.swift` ↔ `Pane/TerminalFindBar.swift` | E.3 |
  | `Panel/MacCodePanelSurfaces.swift` ↔ `CodeSidebar/CodePanelSurfaces.swift` (*"waiting on `CodeServerEnsure` being called from the phone half"*) | G |

  Two of the seven carry a comment naming the shared symbol they are waiting on. **Those two are debts
  this port can pay rather than re-pin**, and paying one is the only outcome that removes a row.

**Tests red→green.** None break. `PlatformDefaultsTests`, `NotificationsOnIOSTests` and
`UnfollowingFocusOnIOSTests` must stay green through it, and — because `test-touched`'s pathspec does
not include `Apps/` — a hand-run `just check-ios-tests` is the stage's **only** automated proof. The
gate DERIVES both numbers — `xcode::declared_tests` scans the directory, `xcode::executed_tests` reads
the simulator's summary — and asserts declared == executed, so a suite that stops running is as loud
as one that fails. **Do not restate the count here**: an earlier revision of this line pinned "11
files, 49 declared tests", the SwiftUI demolition took six of those files, and the prose was wrong for
as long as nobody re-ran the gate. The gate is the SSOT; this document names the mechanism only.

The bundle shrank rather than broke. Six suites went with the views they photographed
(`SidebarAutoHideWiringTests`, `SlateSnapshotRender`, `ToastStateGalleryTests`, `OverlayKeyRepeatTests`,
`GuiPastePlateRenderTests`, `ToastStackViewTests`); `HostedRasterTests` replaced the `ImageRenderer`
rig's self-proof; and `ConnectionPillTests` was RELOCATED, not dropped — its one assertion never
touched the pill, so it now lives in `Tests/SlopDeskWorkspaceCoreTests/RemoteWindowModelTests.swift`
where `swift test` runs it on every gate instead of only this one. Every later stage in this document
runs this gate for the same reason stage A did.

One of those six was only PART photograph. `SidebarAutoHideWiringTests` also pinned the auto-hide
seam, whose subject is not a view and did not go with them: the arbitration is
`slopdesk_settings::chrome`, tested in Rust, and the Swift half — the marshalling into
`CSidebarState` and the guarded write-back — is pinned by
`Tests/SlopDeskClientCoreTests/ChromeAutoHideTests.swift`, written when the suite was deleted. Neither
re-asserts the other's half; a Swift copy of Rust's arbitration would be the cross-language mirror the
one-implementation rule bars.

**Un-landable if:** the scene configuration cannot be supplied without an
`Info.plist`/`project.yml` change that XcodeGen regenerates away. `project.yml` is the SSOT (`:2-4`),
so the key goes there.

**LANDED 2026-08-28, and five things went differently from the plan above.** Each is a decision, not
a slip:

1. **The scene delegate is registered in CODE, not in `project.yml`.** `UISceneConfigurations` wants
   the runtime's module-qualified class NAME (`SlopDeskPhoneUI.PhoneSceneDelegate`) as a literal
   string, which is exactly the shape the "un-landable if" above was worried about — a rename that
   type-checks and launches to a black window. `application(_:configurationForConnecting:options:)`
   returns a `UISceneConfiguration` whose `delegateClass` is the class itself, so `project.yml` keeps
   only the `UIApplicationSupportsMultipleScenes` key it already had and a rename is a compile error.
2. **`PhoneRootKeyResponder.swift` is DELETED, not moved.** Merging it into the real delegate deleted
   the `attach(store:overlay:chrome:)` hop and the three weak references it existed to hold: the
   delegate owns the composition, so the rung reads it directly. `phone-root-key-rung`'s first claim
   was re-aimed off the adaptor onto the two halves the adaptor stood in for — `AppMain` naming
   `PhoneAppDelegate.main()`, and this class overriding `pressesBegan` — because either alone is a
   delegate that never sees a key.
3. **The four `.task` blocks became PROCESS loops, not scene loops.** The plan said scene-owned tasks
   cancelled in `sceneDidDisconnect`, and said the duplication must be recorded. Recording it was not
   enough: an iPad with two windows was running two clipboard pollers against one pasteboard and two
   auto-reconnects against one connection, which is a defect the port is allowed to fix rather than
   carry. They start once in `didFinishLaunching`, against the one composition.
4. **A SECOND ledger row was paid, because rewriting the file exposed it.** `no-cross-target-clone`
   fired on `AppearanceApplier.resolveTerminalColors` — eight lines written identically in both
   shells, invisible while the pair carried a `known` entry for the notification sinks. It is
   `ClientNotificationSinks`' neighbour now: `SlopDeskClientCore/App/ClientTerminalPalette.swift`,
   called by both, with `SlopDeskSlate` declared as a direct dependency of `SlopDeskClientCore` the
   way `SlopDeskTerminal` already is. The ledger is SIX pairs.
5. **Both installs run in `init()`, ahead of the composition — not in `didFinishLaunching`.** The
   plan put them where the `App`'s `init` had them, which reads as the same moment and is not:
   `PhoneAppDelegate` builds the composition in its own `init`, and `PreferencesStore` asks the
   terminal-colour seam as it comes up. Installed after, the FIRST config a pane sees resolves
   against an unfilled closure and the cells come up in libghostty's own palette until something
   dirties the config — a wrong-colours-on-cold-launch bug with no error anywhere. The Mac shell has
   always installed both ahead of `ClientComposition(deviceClass:)`; keeping the order identical is
   what makes the two shells one launch sequence rather than two that happen to agree.

**And the stage's only automated proof was already red before the stage.** `check-ios-tests` had not
been run since `43d3db6d` *"settings are a config file, and the onboarding is deleted"*, which deleted
`FirstLaunchModel` and two of this bundle's four test files but left a third,
`PlatformDefaultsTests.testFirstLaunchKnowsItIsOnIOS`, calling `FirstLaunchModel.currentPlatform` — a
bundle that has not COMPILED since. `swift test` never saw it, because the iOS test bundle is not in
its target graph, and neither is `Apps/` in `test-touched`'s pathspec: the gate that covers this file
is the one gate nothing runs automatically. The test went with the feature it asserted about; the two
that remain are the two that were ever about the `#if os(iOS)` constants. The lesson is the one the
stage note above already states — run `just check-ios-tests` by hand in any commit touching `Apps/`,
because nothing else will.

**And one regression the deletion campaign had already caused, closed in the same pass.**
`golden-check` failed with *"frozen key with NO reader: `inputMotionCoalesce`"* — the fourteen
coalescer vectors were pinned by `Tests/SlopDeskVideoHostTests/InputMotionCoalesceGoldenVectorTests`,
which went with the Swift daemon. The implementation had ALREADY been
`slopdesk_video::input_routing::coalesce_plan` (the Swift held the events and asked Rust which
survived), so the replay moved to `rust/slopdesk-video/tests/golden_vectors.rs` and goes in and out as
wire bytes — which pins the codec too. A symbol gate could not have seen this; only the corpus's own
reader check did.

### Stage B — injection replaces the environment

**Moved.** The two `@Entry` key files are deleted, and every consumer takes the value as an `init`
parameter: `WorkspaceRootView`, `ContentColumn`, `PaneContainer`, `TerminalLeafView`,
`CodePanelSurfaces`, `PhonePanelSheet`, plus `SplitContainer`, which reads neither and carries both
down the canvas to every pane.

**This lands entirely in SwiftUI and was still required**, because a `UIViewController` has no
environment to inherit and every ported surface would otherwise need both paths. It is stage B rather
than stage A only because stage A had to be the smallest possible commit.

**LANDED WIDER THAN PLANNED: three environment dependencies died, not two.** The survey counted the
two `@Entry` keys and missed `.environment(chrome)` — `ContentColumn` injecting the
`WorkspaceChromeState` that `TerminalLeafView` reads back as
`@Environment(WorkspaceChromeState.self)`, for the open-in-code-panel reveal. It is an `@Observable`
in the environment rather than an `@Entry` key, which is why a grep for `@Entry` did not see it, and
it fails in UIKit for the identical reason: a controller inherits no environment either. It travels
the SAME four-view chain the coordinator does, so threading it here cost one parameter per view and
saved re-opening all four files in stage E.

**And the "un-landable if" was already the argument FOR the change.** A consumer reached only through
a `.sheet`/`.fullScreenCover` cannot inherit the presenter's custom environment — which is why
`WorkspaceRootView` re-injected both keys on the cover and `PhonePanelSheet` re-injected one of them
again underneath. SwiftUI's presentation boundary has the hole a `UIViewController` has; the
workaround was the mechanism all along, and deleting the keys deleted three re-injections with them.

**Tests.** No change — every one of these files is `#if os(iOS)`, so `swift test` compiles none of it
and `just check-ios` + `just check-ios-tests` are the whole verdict (§ stage A's finding).

### Stage C — the design floor, in UIKit

**Moves.** `Sources/SlopDeskPhoneUI/DesignSystem/`, 18 files, 1,909 lines, to a `Slate*` UIKit family:
`UIView` subclasses and `UIView` decorations reading the same `Slate.*` tokens
(`Slate.Metric`, `.Text`, `.Surface`, `.Line`, `.State`, `.Typeface`, `.Anim`, `.Elevation`,
`SlateOverlayInk`, `StatusDot`, `StatusMark`, `AgentSpinner`, `BrailleCell`, `VectorIcon`, `SVGPath`).
**`SlopDeskSlate` is not touched** (§8).

Four files carry the real work: `SlateKit.swift`'s `SlatePlateStyle` becomes a `UIControl` subclass
whose ack counter is a property rather than a wrapped `View`; `StatusDotView.swift`'s
`TimelineView(.animation)` becomes the campaign's first `CADisplayLink`, through `FramePacer`'s
existing proxy shape (`:193-200`); `VectorIconView.swift`'s `Canvas` becomes a `CAShapeLayer`;
`SlateOverlayControls.swift:104-106`'s deferred focus becomes `becomeFirstResponder()` in
`viewDidAppear`. `SlateCardModifier`/`slateCard(radius:fill:)` were **deleted rather than ported** —
zero call sites repo-wide — and that deletion is already LANDED, taken during stage A because a
spelling with no reader is not a floor this stage owes a second spelling of, and deleting it early is
one fewer file for stage C to translate. The count above is therefore the pre-deletion one.

**This stage opens the carve-out**, and it also **owns the snapshot rig**: `SlateSnapshotRender.swift`
must move from `ImageRenderer` to `UIGraphicsImageRenderer` over an offscreen `UIWindow` in this same
commit (§5.2's silent failure). `ToastStateGalleryTests` and `ToastStackViewTests` rasterise on **every**
gate run (unlike the skipped rigs — `project.yml:152-153` is stale on this point), so they fail loudly
and are the stage's real proof.

**Invariant rules re-aimed.** `design_ratchets::design_tokens_are_not_bypassed` (`design-token-leaks`)
is §4.8's headline case and **it is re-spelled in this stage or it is never re-spelled** — its
`RAW_LITERALS` regex (`design_ratchets.rs:37`) must gain `UIFont\.systemFont\(ofSize: ?[0-9]`,
`\.cornerRadius *= *[0-9]` and the constraint-constant spelling, and its break-test must be re-seeded
in UIKit so the rule is proven to still fire. `panel_shells::one_design_floor_two_renderers`
(`design-floor`) bans `": View|some View|NSViewRepresentable|UIViewRepresentable|: Shape"` under
`Sources/SlopDeskSlate` (`:402-412`) — **`UIView` and `UIViewController` are not in that alternation**,
so the floor that keeps Slate values-only would admit a `UIView` subclass. Widen it here, before there
is a UIKit adapter that could land in the wrong directory.

**New invariant rules.** `phone-display-links-are-invalidated` and `phone-has-no-scheduled-timers` land
here, because this is the first `CADisplayLink`. Plus the carve-out's counter:
**`phone-design-system-doubling-only-falls`**, a `Claim` on the count of `DesignSystem/` files holding
both spellings.

**Un-landable if:** the snapshot rig cannot be re-founded — in which case the campaign has no visual
regression signal at all and should stop here rather than proceed blind.

### Stage D — the shell

**Moves.** `WorkspaceRootView.swift` (359) → `PhoneWorkspaceController: UISplitViewController(style:
.doubleColumn)`. `NavigatorColumn` and `ContentColumn` become hosting controllers (still SwiftUI).
`.toolbar` (`:109`, builder `:274-308`) → `navigationItem`, the principal `ConnectionPill` →
`titleView`, `Menu{} primaryAction:` (`:328-351`) → `UIBarButtonItem(menu:primaryAction:)`. The three
`.overlay` layers (`:113-139`) become child controllers. `.sheet` (`:162`) → `.pageSheet` +
`presentationControllerDidDismiss`; `.fullScreenCover` (`:172`) → `.fullScreen`.
`Chrome/SidebarColumnVisibility.swift` (32) is **deleted** —
`NavigationSplitViewVisibility` → `UISplitViewController.DisplayMode`.

**Invariant rules re-aimed.** `ui_seams::a_test_target_is_the_same_edge` (`ui-test-edges`) pins the
three overlay hooks — `overlay.toggleSidebar =`, `overlay.toggleCodeSidebar =`,
`overlay.focusCodePanel =` — in `Sources/SlopDeskPhoneUI/WorkspaceRootView.swift` by path
(`ui_seams.rs:59-75`), and a path-named claim whose file vanishes is **red, not silent**
(`report.rs:120-126`). Re-aim at the controller; its `Absent` claim on
`Chrome/WindowSidebarToggle.swift` (`:146`) is untouched, and its `Populated{min 1}` on
`Apps/ClientApp-iOS/Tests` is what keeps the whole rule from going vacuous. `no-cross-target-clone`'s
`MacWorkspaceRootView`/`WorkspaceRootView` row is updated here (stage A's table).
`two_shells::the_shared_vocabulary_only_shrinks` — `OverlapUnder{ ceiling: 28, floor: 34 }`
(`two_shells.rs:235`) over capitalised phrases shared Mac↔Phone — will move in **either** direction as
this stage re-words toolbar and sidebar strings, and trips a ceiling or a floor. Expect to re-derive
it here and again at stage H, and do not "fix" it by re-wording a user-visible string.

**Tests red→green.** `SidebarAutoHideWiringTests` (16 methods): five are typed on
`NavigationSplitViewVisibility` (`:193,210,221,232,244`) and are rewritten against `DisplayMode`; the
other eleven must stay green untouched.
`testAutoModeAtLaunchCollapsesSingleTabFromDefaultState` (`:60`) is the one that pins §3.1's
`initial: true` conversion, and it is the stage's most valuable test.

**The iPad arrangement is this stage's headline, not a side effect** (§1). `.regular` shows navigator
and content side by side — the Mac's two columns, on a panel whose aspect ratio is the Mac's — and
`.compact` collapses to the phone's single column. The switch is
`UISplitViewController`'s own `preferredDisplayMode` driven by the horizontal SIZE CLASS, never by
`userInterfaceIdiom`: an iPad in Slide Over is `.compact` and must draw the phone's arrangement, and
an iPhone Pro Max in landscape is still `.compact`. `viewWillTransition(to:with:)` re-runs the
arrangement inside the coordinator's animation block; the canvas below re-solves rects rather than
re-parenting anything (§3.6).

**Un-landable if:** `UISplitViewController`'s compact/regular collapse behaviour cannot reproduce
`NavigationSplitView`'s on the iPhone — a real risk, since the two have different opinions about what
"collapsed" means. The mitigation is that `WorkspaceChromeState` already owns the *intent*
(`sidebarCollapsed`), so the controller is told rather than asked.

### Stage E — the canvas

The largest stage and the one the port is for. Four commits, because one commit for the canvas is a
commit nobody can review.

- **E.0 — the containment.** `SplitContainer.swift` (352) + `PaneContainer.swift` (246) →
  `PaneCanvasController` + `PaneTabLayerView` + `PaneController`, per §3.6. Keep-all-mounted stated as
  `alpha`, `isUserInteractionEnabled` and `accessibilityElementsHidden` (§3.2). The leaves stay hosting
  controllers for one commit. **The measurement §5.1(a) is taken here**, and it is the only place the
  before-number can still be taken.
- **E.1 — the leaves invert.** `TerminalLeafView.swift` (369) and `GuiLeafView.swift` (1,028) become
  controllers; `TerminalInputHost.swift` (630) and `VideoLayerRepresentable.swift` (129) are deleted,
  their `UIView`s becoming the controllers' own (§2.4). `TerminalRenderingView`'s SwiftUI shape is
  deleted with `BuildStatusPlaceholderView`'s conformance, and the factory gains
  `phoneShared`/`makePhone(model:isFocused:)` returning a `UIView`. `keyboardWillChangeFrameNotification`
  (`TerminalInputHost.swift:139-158`) is replaced by `keyboardLayoutGuide`. **The measurement §5.1(b)
  is taken here.**
- **E.2 — the drag and the divider.** `PaneMoveAffordance.swift` (506) + `PaneDivider.swift` (200) +
  `PaneDropReceiver.swift` (182) + `PaneDropOverlay.swift` (97). `DragGesture` →
  `UIPanGestureRecognizer` with the same slop; `.onDrop` → `UIDropInteraction`.
  `PaneMoveEscapeResponder.swift` (221) **dissolves** into the canvas view — but NOT, as this plan
  first wrote it, into its `pressesBegan` alone. ⚠️ **That door is unreachable for this key**: during a
  drag the terminal is first responder and Escape is a byte it legitimately consumes (`\u{1b}`), so
  `TerminalLeafView.pressesBegan` forwards on only what it did NOT take and the cancel never arrives.
  The landed shape is a `UIKeyCommand` published while — and only while — a pane is in the air, because
  UIKit resolves key commands up the responder chain BEFORE delivering the press, and the canvas is an
  ancestor of every pane; `pressesBegan` stays as the second net for a focused pane that is not a
  terminal. Both gates are the same gate, and it is not an optimisation: a command left installed at
  rest would take Escape away from the shell for the whole session.
  `PaneDivider.resizePointer` (`:169-175`) and `View.panePointer` (`PaneMoveAffordance.swift:67-69`)
  are deleted as dead. **`phone-layout-does-not-write-the-store` lands here**, because
  `reportSolvedLayout`/`reportContainerBounds` are its subject.
- **E.3 — the decorations.** `HintModeOverlay` (201), `ViModeOverlay` (309), `LinkHighlightOverlay`
  (104), `ViCursorOverlay` (60), `PromptJumpFlashOverlay` (103), `TerminalFindBar` (298),
  `TerminalLetterboxContainer` (100), `PaneStatusPills` (156), and the two scrims merged into one file
  the way `MacPaneScrims.swift` already is. `ViKeyHintReflow` is the one that cannot be translated and
  goes to Rust in stage I — until then it is the last hosting controller inside the canvas.
  `HintModeOverlay.swift:51-52`'s unobserved dereference is fixed here, because
  `withObservationTracking`'s read block makes it visible.

**Invariant rules re-aimed.** `pane_wiring.rs` names `Sources/SlopDeskPhoneUI/Pane/TerminalInputHost.swift`
(`:16`) and `Pane/TerminalLeafView.swift` (`:57`) by path and scans `Sources/SlopDeskPhoneUI/Pane`
(`:43,101`); every claim re-aims at the controller that replaced its subject, with its break-test. Its
`phone-key-path` half (`:170`) survives untouched — `TerminalInputHost` is already a `UIKey`-reading
responder, and after E.1 so is the pane controller. `ui_seams.rs` asserts three files stay deleted
(`Chrome/WindowSidebarToggle.swift`, `Pane/DropTargetFrameReader.swift`,
`DesignSystem/SlateProjectIsland.swift` at `:146,182,455`) — the deletion claims are unaffected. Its
`canvas-registration` rule (`:211-221`) bans five `Slate.Metric.*` token names under PhoneUI and is
framework-blind, so it survives verbatim. **One rule here goes vacuous by its own design and that is
worth knowing before it is mistaken for a pass:** `command_surface::canvas-drag-decides-once` guards
its bans with `if !tree.has(renderer) { continue; }` (`command_surface.rs:81-83`), so renaming the
canvas silently disarms it — deliberate in the crate, dangerous in this stage. Re-point it in E.0, in
the same commit as the rename. `sidecar_seams.rs:203-208` bans a re-armed `Task { [weak self] in` …
`guard !Task.isCancelled` window under `Sources/SlopDeskPhoneUI/` and survives — which is a live
constraint on how E.1's leaf tasks are written, not a bystander. **Four of the seven
`no-cross-target-clone` ledger rows update in this stage** — `MacGuiLeafView`/`GuiLeafView` and
`MacTerminalLeafView`/`TerminalLeafView` in E.1, `MacPromptJumpFlashOverlay`/`PromptJumpFlashOverlay`
and `MacTerminalFindBar`/`TerminalFindBar` in E.3 — which makes stage E the ledger's heaviest, and the
direction is the one to watch: **a UIKit phone whose bodies now resemble the AppKit Mac's more closely
adds clone pairs**, at an 8-line window. This is the one place the port makes an existing rule harder
rather than easier to satisfy, and the answer when it fires is to hoist the shared body into
`SlopDeskClientCore`, never to perturb one side until the window breaks.

**Un-landable if:** keep-all-mounted cannot be held. Everything else in this stage is recoverable; a
tab switch that tears down a libghostty surface is a product regression the user sees immediately, and
it is the one thing to test by hand at every commit boundary.

### Stage F — the overlays

**Moves.** The 16 files of §2.2 that are (a), plus `OverlayHostView.swift` (274) →
`OverlayPresenter` on the workspace controller. `.sheet`/`.fullScreenCover`/`.popover` →
`present(_:animated:)`. The three dwell timers become stored `Task`s (§4 hazard 6). The eight
`DispatchQueue.main.async` focus hops delete (§3.5). Open Quickly, palette, global search and command
navigator get diffable data sources (§3.4). **The measurement §5.1(c) is taken here.**

**`Overlays/OverlayKeyRepeat.swift` and `OverlayKeyRepeatTests.swift` are re-founded, not ported** —
§7. The test is four assertions about which keys may auto-repeat; after the merge it is a Rust test in
`key_repeat`, and the phone keeps a thin one proving `pressesBegan`/`pressesEnded` reach it.

**Invariant rules re-aimed — the heaviest stage for §4.8.**

- `overlay_split::the_overlay_host_holds_no_ambient_layer` — `Lacks{ PHONE_HOST, "allowsHitTesting" }`
  (`:56-62`). Re-spell to `isUserInteractionEnabled` and a `hitTest(_:with:)` override, or the rule
  goes green over a host that can eat every click across the split. Its sibling
  `Lacks{ PHONE_HOST, "draws" }` (`:337`) is a **bare substring** that a `draw(_ rect:)` override
  false-fires — anchor it before it cries wolf and someone deletes it.
- `split_surfaces.rs:158`'s `Lacks{ OverlayHostView.swift, r"ToastStackView\(" }` pins a SwiftUI
  initializer. `addSubview(toastStack)` slips it while re-creating the hazard exactly.
- `latency_ratchets::three_projections_read_once_per_pass` (`three-projections`) — the loudest break in
  the campaign. It pins exact SwiftUI body lines (`^ *let built = sections$`, `^ *let shown = visible$`,
  `^ *private func rows\(_ shown: \[DeviceLogLine\]\)`, `^ *private func list\(_ shown: \[(Simulator|Android)Device\]\)`)
  across five hard-named PhoneUI files (`latency_ratchets.rs:123-169`). `OpenQuicklyView.swift` is the
  one this stage empties; the other four fall in stage G. **The perf claim it encodes is real** — the
  ~145 µs/keystroke re-rank and the 0.78–1.50 ms 600-row filter — so it is re-pinned onto the
  data-source's snapshot builder, never dropped. Its break-test fixture literally writes
  `-> some View` (`:409`) and has to be rewritten with it.
- `phone_parity::silent-paste-probe` is **retired, not re-aimed.** Its stated reason
  (`phone_parity.rs:386-387`) is that *"SwiftUI has no equivalent moment"* to the Mac's `onClick` menu
  build. UIKit gives the phone that moment, so the rule's premise is gone; the commit records that,
  because a retired rule with no reason recorded is indistinguishable from a deleted one.
- `overlay_split::split-global-search` (`:204`) survives, and its header was **written for exactly this
  migration** — worth reading before touching anything else in this stage.

**Un-landable if:** the `ActiveSheet` priority chain (`:170-176`) cannot be expressed as a presentation
swap without a visible double-animation. The mitigation is `present` with `animated: false` for a swap
and `true` for a first present, which is a decision the chain can carry.

### Stage G — the panels

**Moves.** `Panel/` (18 files, 3,151) and `CodeSidebar/` (3 files, 642).
`SimulatorScreenView`/`AndroidScreenView` invert for almost nothing; the two consoles and the two
device lists become collection views; `SimulatorStageView`/`AndroidStageView`'s state machines become
controllers with the latch orders preserved (`AndroidStageView.swift:171-186` is load-bearing).
`CodeSidebarWebView` inverts. `DeviceSoftKeyboard.hasHost` (`:58`) is deleted as dead.

**`CodePanelSurfaces.swift` (486) is the hard one**, and its three documented past bugs are the
stage's acceptance criteria: the poll task outside the workbench switch (`:155-157`), the separate
restart keys (`:243-245`), and the park/resume pair without which leaving the tab strands a host
encoder and two websockets (`:252`). Each becomes a named test.

**Invariant rules re-aimed — six named breaks and one trap.**

- `panel_floor::both_device_panels_draw_on_both_platforms` — two `Claim::Names{ needle:
  "UIViewRepresentable" }` on `SimulatorScreenView.swift` and `AndroidScreenView.swift`
  (`panel_floor.rs:87-98`), whose messages say *"lost its UIKit half"*. **The trap:** `Names` reads text
  raw, and `SimulatorScreenView.swift:11` already carries the word in a comment — so after the
  inversion the rule either reds or passes over prose, and **both are wrong**. Re-aim at the `UIView`
  subclass declaration. The rule's `#if os(macOS)`/`#elseif os(iOS)` gate and its tree-wide key-table
  ban survive untouched.
- `panel_floor::the_code_panel_crosses` — same shape, same trap, on
  `CodeSidebar/CodeSidebarWebView.swift` (`:178-183`), which is genuinely a `UIViewRepresentable` today
  (`:46`).
- `panel_shells::one_panel_vocabulary_four_surfaces` (`panel-vocabulary`) — `Claim::Exactly{ path:
  CodePanelSurfaces.swift, pattern: r"\.task\(id: pollKey\)", count: 1 }` (`panel_shells.rs:78-85`).
  `.task(id:)` has no UIKit spelling; the count goes to 0 and the rule fires. Its message — *"a task per
  branch restarts the loop it caused"* — is the same claim `CodePanelSurfaces.swift:155-157` documents,
  so re-aim it at the controller's single poll `Task` and keep the message verbatim. The same rule's
  `NoneUnder{ NSViewRepresentable }` ban under `CodeSidebar/` goes vacuous (§4.8) and is retired.
- `phone_parity::panel-named-surface` — `ForEach\(PanelTabs\.all` (`:257`) is SwiftUI-only. The claim
  it encodes is that the tab strip is minted from `PanelTabs`, not hand-listed; re-spell against the
  `UIStackView` build.
- `phone_parity::one-clear-key` — `Image\(systemSymbol: \.xmarkCircleFill\)` under `Panel/` (`:303`)
  becomes `UIImage(systemSymbol:)` and goes vacuous. §4.8.
- `latency_ratchets::three-projections` — the remaining four files (both consoles, both device lists).
  Same treatment as stage F.
- `chrome_split.rs:237`'s `Mentions{ PHONE_PANEL, ["PanelTabs", "CodePanelSurfaces(", "AndroidMarkPath"] }`
  pins a **constructor call** with a trailing `(`. Green iff the type keeps its name; red the moment it
  becomes `CodePanelSurfacesController`. Update the needle, not the name.
- `no-cross-target-clone`'s last row —
  `Panel/MacCodePanelSurfaces.swift` ↔ `CodeSidebar/CodePanelSurfaces.swift` — closes here, and its
  ledger comment says what would remove it rather than re-pin it: *"waiting on `CodeServerEnsure` being
  called from the phone half."* The `.task(id:)` rewrite above is the moment that call can land.
- Survives untouched: `device_law.rs` (`:60` `device-panel-law`, `:191`
  `client-pasteboard-and-open` — which gets *sharper*, since its bans already target
  `UIPasteboard.general.string = ` and `UIApplication.shared.open(url)` — and `:315`
  `device-list-sectioning`), `panel_predicates.rs:59`, `panel_shells::device-panel-twins`
  (`NoFileUnder` rescued by `#if os(iOS)`, which a UIKit file still needs), and
  `transport_lanes.rs:65`.

**Un-landable if:** the pooled `WKWebView`'s keyboard ownership (`CodeSidebarKeyboardState`) breaks
under a controller hierarchy. It should not — the pool already vends the page and owns the navigation
delegate (`CodeSidebarWebViewPool.swift:106,195`) — but it is the one thing to test by hand.

### Stage H — the navigator

**Moves.** `Columns/NavigatorColumn.swift` (580) and `Columns/ContentColumn.swift` (117). The
`List(selection:)` becomes a `UICollectionView` with a compositional list layout and a diffable data
source keyed on `SidebarSections`' sections and the row ids (§3.4). `.searchable` →
`UISearchController`; `.swipeActions` → `UISwipeActionsConfiguration`; `.contextMenu` →
`UIContextMenuConfiguration`; `ViewThatFits(in: .horizontal)` (`:493-502`) → `IOSGitLineView`'s
measured ladder, memoized, against `macui_memos.rs` M1's numbers. `ContentColumn.onConnect`'s dead
default (`:32,92-94`) is either wired or deleted — it cannot stay as a button that does nothing.

**The last hosting controllers fall here**, and **the measurement §5.1(f) is taken**:
`draw(_:)` override count, plus a Time Profiler sample of a rail scroll.

**New invariant rule.** ~~The phone's M1 equivalent — the git line stays MEASURED, not re-measured —
lands in `phoneui_memos.rs` with the same three arms and the same break-test the Mac's has.~~
**PAID, AND NOT WHERE THIS PROMISED.** It landed inside `macui_memos::the_git_line_stays_measured`,
which was re-aimed to cover `SidebarGitLineView.swift` alongside the Mac's half rather than cloned
into a second file. That is the better shape and the same one this stage keeps arriving at: the rule
is about the git line, not about a shell, so a second copy per shell would have been the very
duplication the stage spent itself deleting. **No git-line rule is owed to `phoneui_memos.rs`.**

**Invariant rules re-aimed.** `chrome_split::split-navigator` (`chrome_split.rs:39`) is name-based and
survives. `two_shells::the_shared_vocabulary_only_shrinks` is re-derived for the second and last time,
since this stage re-words the rail's strings. **`MacNavigatorColumn`/`NavigatorColumn` is NOT in
`no-cross-target-clone`'s `known` ledger**, and that is the fact to hold onto: stage H is where the
phone adopts the Mac's memoized-ladder answer wholesale, so it is the likeliest stage in the campaign
to mint a *new* clone pair against a rule with an 8-line window and no waiver for it. The answer is
`SlopDeskClientCore`, not a new ledger row — a row is a debt, and this one would be incurred on
purpose.

**Un-landable if:** `UICollectionView`'s selection cannot reproduce the tag-based selection binding
(`:127-130`) across a live filter. It can, through `itemIdentifier(for:)` — which is §4 hazard 3's
whole point.

### Stage I — the ratchets flip, and the leftovers

**Moves.** Nothing large, with ONE exception the stage found rather than planned:

- **The close confirmation had no phone half at all**, and that was a hang rather than a gap.
  `WorkspaceStore.requestClosePaneTree(_:)` PARKS the close and returns, waiting for a UI answer;
  the SwiftUI `.alert` on the deleted `OverlayHostView` was that answer, and nothing succeeded it.
  Between the demolition and this stage a navigator swipe on a pane a policy gated simply did
  nothing — no dialog, no close, and the park still armed for every later attempt.
  `Overlays/PhoneCloseConfirmation.swift` is the successor: a `UIAlertController` reconciled off
  `CloseConfirmationCopy.request(store:)` through one `ObservationFollow`, presented from
  `WorkspaceRootViewController` rather than mounted in `PhoneOverlayLayerView`. It is the SECOND
  natively-presented overlay, beside the cheat sheet, and for the sibling reason: it is summoned by a
  deliberate gesture, so the layer's drop-a-second-`present` hazard cannot reach it. `stage-d-ledger`
  is re-aimed off a `Claim::Mentions` — which the copy file's own header satisfied — onto
  `Claim::Matches` on the CALL, plus two claims that both halves resolve the park they raise.
  (This used to read "noted for a later stage, not fixed here: `pendingTabCloseID` has no phone caller,
  so a phone tab close never parks". Resolved in stage I as a JUSTIFIED FLOOR, not a defect: the phone
  has no tab-close VERB to route. `MacTabStrip.swift` is Mac-only, the phone registers no
  `WorkspaceBindingRegistry` — its `UIKeyCommand`s are all local overlay confirm/dismiss — and its cheat
  sheet lists no Close Tab. The `×` in `PaneStatusPillsView` is a status-pill dismiss, not a tab close;
  its own comment merely COMPARES its plate to the tab row's. So the park has no caller because nothing
  on the phone can ask for it, and minting a phone tab-close verb to give the park a caller would be
  adding a feature to satisfy a ledger. The reconciler still answers it the day such a verb appears.)
- **The edge pin descends, and the reason it had not was false.** `MacViewEdges.swift` and
  `Pane/ViewEdges.swift` held character-identical bodies under a header explaining that
  "`NSLayoutConstraint` and `UILayoutConstraint` are the same name on two frameworks that are not the
  same type, so this cannot descend to the floor". There is no `UILayoutConstraint` — UIKit vends
  `NSLayoutConstraint` and both layout anchors under those exact names, and Auto Layout is ONE API on
  both platforms. The only differing word was the host's type. Both files are deleted for one
  `Support/ViewEdges.swift` in `SlopDeskClientCore` over a `package typealias SlateHostView`; all six
  call sites already imported ClientCore, so nothing else changed. Worth reading twice as a method
  note: the duplication was not defended by inertia but by a HEADER, and a header that answers the
  question convincingly is why nobody re-asked it for a week.

  **`SlateHostView` unlocks the clone residue that was previously un-liftable**, and that is the more
  valuable half. Every "these two anchor blocks are identical and cannot descend" verdict in this
  campaign — the GUI leaf's seven chrome overlays, the control bar's `build()` block — rested on the
  same premise as the header above, and it is the same premise. Auto Layout is one API; the only
  per-shell word is the view type, and ClientCore now names it. A shared LAYOUT is worth lifting where
  a shared CALL is not: two anchor blocks can drift by 2pt and nothing goes red, whereas two call
  sites into one implementation cannot drift at all. Use that as the discriminator when clearing
  `no-cross-target-clone`'s residue — lift what can drift, and widen the rule's noise set for the
  scaffolding that cannot, rather than raising its window, which blinds it everywhere at once.
- **THREE NAMES ARE THE WHOLE DIFFERENCE**, and `Support/SlateHostTypes.swift` now says so in one
  place: `SlateHostView`, `SlateColor`, `SlateFont`. The alias above moved here from `ViewEdges.swift`
  with two siblings, because every later "this cannot descend" in the residue turned out to be one of
  the three wearing a longer sentence — a shared `NSAttributedString` build needs only the colour and
  the font to have names, and `NSAttributedString`, `.font` and `.foregroundColor` are one API on both
  platforms. ⚠️ Typealiases, NOT protocols, and the moment a shared body needs a member only one
  framework has, that body has found a REAL divergence and belongs back in its shell. The alias is not
  a licence to paper over one.
- **Core Graphics was never two APIs either.** `SlopDeskSlate/SlateVectorDraw.swift` takes the two mark
  drawings both shells had transcribed — the stroked lucide glyph and the braille cell's eight dots —
  and the ink crosses as a `CGColor`, resolved at the call site because that is the only place the
  trait environment is right. The braille half also retired a divergence nobody had named: the Mac's
  rail mark is drawn in an UNFLIPPED view and mirrored its own y, the Mac's standalone spinner is
  flipped and did not, and the phone's did neither — three loops, one geometry. The shared body takes
  the `anchor` the dots are measured from and a `step` of ±1, so each shell's arithmetic survives
  VERBATIM rather than being algebraically rearranged into a last-bit difference.
- **The pane KIND stopped being asked for twice.** `macui-leaf-kind` pinned `cachedPaneKind` inside the
  Mac leaf, so the day the leaf's logic descended into `GuiLeafCore` the rule went red for a cache that
  had not moved — and it had been blind all along to the site that mattered as much: both control bars
  ran `store.tree.spec(for:)?.kind == .desktop`, a full DFS over every session, tab and split node,
  once per plate sync, for the privacy shield. The kind now rides to the bars inside `GuiLeafChrome`,
  and the rule pins the pair that actually holds — the cache exists one floor down, and no shell
  re-derives it above.
- **The control bar's four callbacks descend as a protocol**, which is the clearest case yet for the
  drift discriminator above: a forgotten wiring compiles, draws, and does nothing when pressed. Nothing
  goes red and only a person tapping it finds out. `GuiLeafControlBarWiring` /
  `GuiLeafCollapsedChipWiring` + `GuiLeafCore.wireControls(bar:chip:)` set all four at once, so the set
  cannot go half-wired.
- **⚠️ A RATCHET'S TWO FAILURE MODES ARE SYMMETRIC, and this stage hit both in one sitting.** A false
  GREEN and a false RED destroy a rule's value equally, and every instance was fixed the same way — by
  making the rule read the BEHAVIOUR instead of a text shape. False greens: `ink_floor`'s five
  `case \.{needle}` templates were blind to `case let .fixed(tone)`; `design_ratchets`' Auto Layout
  clause could not see a NEGATIVE `constant:`, which is half of every pinned pair; and three separate
  `Claim::Mentions` were satisfiable by the guarded file's OWN PROSE, because `Mentions` reads raw —
  including one whose subject, `CodePanelSurfaces`, had died with SwiftUI and whose bare needle was
  matching the substring inside the class name `MacCodePanelSurfaces`. False reds: `panel_shells`'
  `: CALayer` matched a function PARAMETER rather than a subclass, and `no-cross-target-clone` reported
  the DEDUP FIX as a clone, because two call sites forwarding the same six views under the same six
  labels are eight lines of agreement. That last one is fixed in the normaliser (`claim.rs`'s
  `forwards_itself`) and NOT by raising the window — `two_shells.rs` measured 73% of shared windows as
  ordinary logic, so a wider window blinds the rule everywhere at once. `pad: Slate.Metric.space2` is
  deliberately still counted: which rung a corner takes is a decision two halves could get different.
  ⚠️ AND THE RULE WAS RIGHT THE NEXT TWO TIMES IT FIRED ON THAT SAME PAIR, which is the reason the
  normaliser was narrowed rather than the window raised. Firing #2: the rungs were parameters on a
  header claiming `SlopDeskSlate` sat above `SlopDeskClientCore`; the edge runs the other way
  (`Package.swift:475`), so `GuiLeafChromeLayout` reads `Slate.Metric` itself now and both callers
  lost an identical eight-line call — a rule firing on a duplication a wrong comment was holding in
  place. Firing #3, once that cleared: the MOUNT ORDER underneath it — floor, six overlays, drop
  highlight last — eight more identical lines, and `addSubview` is one API with add-order z-order on
  both frameworks, so it was another shared decision and not a spelling. It is `mount(…)` now; the
  only word left in either shell is `conceal`, a closure, because `alphaValue`/`isHidden` and
  `layer.opacity`/`accessibilityElementsHidden` are different states rather than one state twice.
- **The `split-panel-chrome` park is paid.** A predecessor left the phone half red on purpose rather
  than re-aim it, because its subject had been SPLIT rather than renamed — the controller stopped
  reading the three symbols by handing each surface to a sibling — and "which file must read which
  symbol" is the panel's architecture, not a gate's. Settled here as PER FILE on both shells: a file
  that draws a tab reads the shared list, a file that draws the Android mark reads the shared path, and
  each workbench reads the shared clipped-titlebar metric. The Mac gained two claims it never had.
- ~~The design-system carve-out retires: the SwiftUI spellings are gone, and
  `phone-design-system-doubling-only-falls` becomes an equality at zero.~~ **PAID, and the counter is
  deliberately NOT written.** Stage C proposed it as the carve-out's own guard — a count of
  `DesignSystem/` files holding BOTH spellings, allowed to fall and never rise. A file cannot hold
  both spellings when one of them cannot be imported anywhere in the tree, so the rule would go in
  measuring zero against a subject that no longer has a way to exist. That is the vacuous green this
  crate's whole doctrine refuses, and writing it would leave a reader believing the doubling is
  watched by a rule that is really watched by `no_declarative_framework_survives`. The carve-out
  retires with its guard un-needed rather than with its guard at zero.
- ~~The hosting-controller ratchet becomes zero, and `import SwiftUI` under
  `Sources/SlopDeskPhoneUI` becomes a `Claim::NoneUnder`~~ **PAID, and it landed WIDER than this
  bullet asked.** `ui_split::no_declarative_framework_survives` bans `^\s*import SwiftUI` AND
  `canImport(SwiftUI)` across the whole Swift tree — `Sources`, `Apps` and `Tests`, all sixteen
  targets — because a per-target ban is the right shape for a migration and the wrong shape for a
  finished one: the next target to regress is by definition the one nobody has repaired. It reads
  `View::Statements`, not `Code`: four files carry the import's name in PROSE recording that it is
  gone, and the `canImport` half is not line-anchored, so a tokenizer that blanks comments while
  keeping line structure is the only view that reads both halves right. The two narrow bans it
  subsumes were DELETED rather than left underneath it. `ui_split.rs`'s `rescued_by` is narrowed to
  `^import (AppKit|UIKit)\b`, which is the fact that says the port is finished.
- ~~`SlopDeskSlate`'s **SwiftUI spelling loses its last consumer**~~ **PAID.** `Slate` vends
  `NSColor`/`UIColor` and no `Color`; the Mac reads `NSColor` and the phone reads `UIColor`. The
  `Color` half, `SlateDesign.swift`'s SwiftUI import and `Text.nerdAware`'s SwiftUI splice are gone.
  ⚠️ And the UIKit half did not land BESIDE the AppKit one, it **replaced the need for one**.
  `SlateNativeText.swift` held the splice typed on `NSFont`/`NSColor`, and a character-identical twin
  (NerdAwareText, in the phone's own design-system directory, deleted in the merge — named without
  backticks because the path is gone and a citation to it would go red) was typed on
  `UIFont`/`UIColor` — same name, same labels, same five statements. The diff was TWO TYPE NAMES, and
  this floor already vends both as one name each (`SlateNativeFont`, `SlateNativeColor`). One body
  now, no twin, and the `#if` shrank to what it was really gating all along: which framework declares
  `NSAttributedString.Key.foregroundColor`. `NSAttributedString` is Foundation on both platforms and
  `init?(name:size:)`/`pointSize` are spelled identically on `NSFont` and `UIFont`, so the merge was a
  deletion rather than a rewrite — the third instance of this stage's one finding, after
  `SlateVectorDraw` and `SlatePlate`. `SlopDeskFontFaces` lost a stale claim in the same pass: its
  header still named `Text.nerdAware`, a SwiftUI splice site that no longer exists, and its `runs(of:)`
  note still said "both splice sites". `SlopDeskSlate` ends this
  campaign importing no SwiftUI at all — every surviving occurrence of the word under that target is
  prose recording what was deleted, which is exactly why the ban above had to read `Statements`.
  `Slate.Native` keeps its name: it is a leftover of the SwiftUI era, and flattening it into `Slate`
  would sweep ~400 call sites for a cosmetic win (`SlateDesign.swift:287-290` records the trade).
- ~~`Package.swift:596`'s dead `SwiftUIIntrospect` dependency row is removed.~~ **PAID.** The row is
  gone, its `Package.resolved` pin with it, and `Package.swift:145` and `:604` now carry the reason in
  prose: the dependency existed to reach the `NSWindow` a `WindowGroup` hides, so it left with the
  SwiftUI app scene rather than being deleted on its own. §2's census row (0 call sites, 1 declared
  dependency) is now 0 and 0.
- ~~`ink_floor.rs:331`'s `AtLeast{ "static func paneStatusPillFill", 2 }` loses its subject~~ **PAID,
  and it landed as the opposite operator.** Once both renderers read `Slate.Native.*` the `Color`
  overload had no reader, so the count dropped — but the fix is not a smaller floor, it is
  `Exactly { count: 1 }`. A floor of one would still call the per-framework PAIR healthy, which is
  the exact regression the rule exists for; the ceiling is the half that was always meant and could
  not be written while two spellings were legitimate. The `Slate.Native.` prefix on the call-site
  needle is load-bearing beside it: a half that kept a `paneStatusPillFill` of its own satisfies the
  bare name and nothing else.
- ~~The three rules with **no break-test anywhere** — `fold-gate-condition`, `two-test-trees`,
  `drop-chip-and-pill` — get one~~ **PAID**, because all three are rules this campaign touched and
  `CLAUDE.md` requires it. This was the debt the port found rather than created, and paying it while
  the tree was fresh in someone's head is what let each seed be the drift the rule actually fears
  rather than a syntactic negation of its claim. Three tests, thirteen seeds
  (`the_fold_re_opened_from_either_side_is_red`, `a_copied_relaxation_list_is_red`,
  `a_re_derived_chip_number_or_a_second_pill_switch_is_red`), and two findings that only writing them
  could produce:
  - **A write onto a symlink FOLLOWS it.** The first draft of the copy seed wrote the phone tree's
    `.swiftlint.yml` without removing the link, so the bytes landed in the shared list, the link
    stayed a link, and the test passed for the wrong reason — a break-test that agreed with the rule
    while seeding nothing. The link is removed first now. This is the same false green the ⚠️ above
    enumerates, caught in the tooling rather than in the tree.
  - **A ban whose subject was renamed reads zero files and agrees with everybody.** The fold's third
    seed points the ledger at a target name the manifest no longer holds, which is the failure a
    census can never self-report — and it is not hypothetical: `split-panel-chrome` had SHIPPED it,
    its `CodePanelSurfaces` needle satisfied by the SUBSTRING inside the class name
    `MacCodePanelSurfaces` while the type itself had died with SwiftUI.
- **The host-type vocabulary is reconciled to ONE spelling, and the second one was this stage's own
  mistake.** `SlateHostTypes.swift` was written here to name the three genuinely-per-shell types —
  and two of them, the colour and the font, `SlopDeskSlate` had ALREADY been vending for the whole
  campaign as `SlateNativeColor`/`SlateNativeFont` (`SlateDesign.swift:72-81`). So a stage whose
  finding is "the copies were paying for a type name" shipped a second name for two of them. The
  fix is not symmetric between the three: `SlateNativeColor`/`SlateNativeFont` stay, because
  `SlopDeskClientCore` DEPENDS ON `SlopDeskSlate` (`Package.swift:475`) and the lower floor wins;
  `SlateHostView` stays in `ClientCore` alone, because the design floor's own rule is "a value,
  never a drawing" (`panel_shells::one_design_floor_two_renderers`) and a view type has no business
  there. Which leaves Slate vending the two VALUES and ClientCore the one VIEW, a split that reads
  as an accident and is not. One file uses `SlateColor` (`Pane/DecorationDropBlob.swift`, five
  sites) and nothing uses `SlateFont`.
- **⚠️ AND THE OTHER HALF OF THAT SAME FACT WAS WRITTEN BACKWARDS IN THREE HEADERS.**
  `Pane/GuiLeafChromeLayout.swift`, `Pane/PaneDropGeometry.swift` and `Overlays/OverlayCardLayout.swift`
  each asserted that `SlopDeskSlate` sits ABOVE `SlopDeskClientCore` and `Slate.Metric` "cannot be named
  from here" — the exact opposite of `Package.swift:475`, and falsified two directories over by
  `Pane/DecorationDivider.swift` spending `Slate.Metric.space2` in the clear. All three are corrected,
  each recording the old sentence so the correction cannot be re-reverted by someone reading only the
  new one. **The cost was not cosmetic**: in `GuiLeafChromeLayout` the belief made the rungs
  PARAMETERS, and two callers spelling the same argument list is what `no-cross-target-clone` then
  fired on. A wrong fact in a header travels further than a wrong line of code, because the next
  author reads it as settled and writes the third copy — which is what happened. Ratchet requested as
  `slate-is-below-clientcore` in the `phoneui_memos.rs` family: the `Package.swift` edge itself, so the
  ban cannot go vacuous, plus a `NoneUnder` prose ban narrow enough to admit the three corrections.
- **A reported third duplication INSIDE `SlopDeskClientCore` was checked and is NOT one**, and the
  check is worth keeping because the report was plausible. The parallel dedup landed
  `Overlays/OverlayDwell.swift` and `Pane/DecorationChipDwell.swift` in one pass, and one agent
  flagged them as the same sampler written twice — same `timer`/`onExpire` pair, same
  `MainActor.assumeIsolated` tick. Read side by side they are two different clocks. `OverlayDwell`
  SAMPLES at `dwellTick` and can be FROZEN, because the Mac holds a toast's countdown under the
  pointer and a single `Timer(total)` has nothing to freeze. `DecorationChipDwell` is ONE SHOT with
  an IDENTITY GATE, because a chip re-targeted mid-dwell must restart only when the content is a
  different event. Neither behaviour is reachable from the other's shape, and what they actually
  share is four lines of Foundation: a `Timer` field, a weak capture, `assumeIsolated`, and an
  idempotent `stop()`. ⚠️ THIS IS THE FALSE-POSITIVE SIDE OF THE SAME COIN as the clone rule's
  firing #1 — a shared SPELLING that carries no shared decision — and it is why the shingler was
  NOT widened to compare within one target. Inside a single module that spelling coincidence is
  the common case, not the exception; the cross-target rule earns its keep precisely because two
  shells drawing the same surface have no innocent reason to agree line for line.
- **One reconciliation genuinely left open**, and the parallel pass made it bigger rather than
  smaller: `Support/SlateHostTypes.swift`'s `SlateColor`/`SlateFont` still duplicate
  `SlopDeskSlate`'s `SlateNativeColor`/`SlateNativeFont`. When this was first logged, one file used
  `SlateColor` and nothing used `SlateFont`; `Pane/DecorationHintLabel.swift` has since taken both.
  The fix is mechanical — re-point the call sites at the Slate names and delete the two aliases,
  leaving `SlateHostView` as the one thing `SlateHostTypes.swift` is for — and it is deferred only
  because those files were owned by running agents.
- `repo_invariants::source_comments_cite_files_that_exist` should be **green with no exemptions added**
  by the end of this stage. Nine stages of renames will have reddened it repeatedly; every fix was a
  real stale citation, and the final green is the campaign's cheapest proof that no header comment
  still describes a file that no longer exists.
- ~~The `phoneui_memos.rs` family is completed with the measurements §5 collected.~~ **DONE**, ten
  rules: `phone-sink-closures-are-weak`, `phone-observation-is-generation-guarded`,
  `phone-rows-resolve-by-identifier`, `phone-assume-isolated-is-earned`,
  `phone-notification-tokens-are-retired`, `phone-display-links-are-invalidated`,
  `phone-has-no-scheduled-timers`, `phone-layout-does-not-write-the-store`,
  `slate-is-below-clientcore` and `clientcore-places-never-draws`. Two hazards were re-cut against
  what the tree actually holds rather than against §4's guess: §4.4's "an `assumeIsolated` must sit
  near a `DispatchQueue.main.async`" is falsified by 29 live hop-free sites, so the rule bans the
  off-main-queue family instead and every `assumeIsolated` is earned by construction; and §8's
  "the shared floor imports neither AppKit nor UIKit" is falsified by 23 live files, so the rule
  pins what the floor DOES — no view subclass, no `draw(_:)` override. H1 and H7 are brace-block
  scans rather than line bans, because "inside a closure body" and "inside a `layoutSubviews`
  body" are not line predicates. The two hazards §4 names as review-only are left ruleless.
- ~~**Candidate, to MEASURE rather than assume: `check-ios` builds the `ClientApp-iOSTests` scheme
  too.**~~ **TAKEN**, as a second `build-for-testing` inside `ios_typecheck` sharing the one
  `.build/ios-dd`. The contention this was deferred over does not arise: the two invocations are
  SEQUENTIAL within one gate rather than two gates racing a cache, which is what `.work/ios-test-dd`
  was separated to avoid. It is the mirror image of the library scheme that was removed for being a
  strict SUBSET of what the app already compiles — the test bundle is a strict SUPERSET, and it is
  the half that went unbuildable for weeks with every gate green. RUNNING the assertions stays in
  `check-ios-tests`, because that needs a booted simulator and `quick` must not. Stage A found the iOS test bundle had not compiled since `43d3db6d`, because the only gate
  that compiles it is the one gate nothing runs automatically (above). `stamp::Scope::Ios` already
  hashes all of `Apps/ClientApp-iOS`, `Tests/` included, so a second `build-for-testing` invocation
  inside `ios_typecheck` would put that compile into `just quick` for free on a warm stamp — and, if
  it shared a derived-data path, would leave `ios_tests` almost nothing to build. Both halves have a
  cost the repo's bar says must be measured, not argued: `quick` grows a scheme, and one shared DD
  re-introduces the two-xcodebuilds-one-cache contention that the separate `.work/ios-test-dd` exists
  to avoid. Deferred to here rather than taken during a port stage for exactly that reason.

**The last three leftovers, closed.** The stage's own list held three items it had recorded rather
than fixed. All three are answered, and only one of them was a defect:

- **`Slate.DropPreview` is minted** (`Sources/SlopDeskSlate/PaneDropPreviewArt.swift`). The five stroke
  figures of the drop preview — the whole-area rim, the slab's finer rim and its wash, the lifted
  source's wash, and the dash pattern — were declared in `MacPaneMoveAffordance.swift` and again in
  `PaneMoveAffordanceView.swift`, each half carrying a comment saying it was waiting for exactly this
  rung. They were the **last pair in the client spelled across a FRAMEWORK boundary**, which is a worse
  position than the pair `Slate.GrabPill` was minted for: those two renderers are both AppKit and could
  at least be diffed by a reader who opened both, where an AppKit file and a UIKit file share no import
  and no compiler. Both halves now read the rung, both private enums are deleted, and
  `drop-preview-figures` (`ink_floor.rs`) pins it from both ends — every half must READ all five, and
  no half may re-DECLARE one, under the minted spelling or under the three retired AppKit names.
- **`pendingTabCloseID`'s missing phone caller is a justified floor, not a gap** — see the stage-D entry
  above. The phone has no tab-close verb to route.
- **`TerminalFindBarView`'s `next` → `nextMatch` was a real pre-existing compile error at HEAD**, and it
  is now verified rather than reported: `git show HEAD:` has `final class TerminalFindBarView: UIView`
  storing `private let next: SlatePlateVerbButton`, and `next` is `UIResponder`'s. That is the second
  time this shell has hit that hazard (`61eab344` was `UIView.isFocused`), so it earned Hazard 9 (§4.9)
  and the rule `phone-members-avoid-responder-names`.

**And a tenth site of the false dependency edge.** `ink_floor.rs` — its module header and the
`named-ink-tables` rule — justified keeping `DropZoneInk`'s and `GuiUploadTint`'s lookups per-renderer
"because `Color` is Slate's own and Slate sits above the logic floor". Slate sits below. The conclusion
survives off the real constraint, which runs the other way: those two enums are declared in
`SlopDeskClientCore`, which is above Slate, so Slate cannot NAME them. `PaneStatusPillInk` is the
control that proves it — it lives in `SlopDeskWorkspaceModel`, one of Slate's own dependencies, and
that is why `Slate.Native.paneStatusPillFill` could exist while these two cannot. Which also names a
follow-on for whoever wants it: move the two enums down to `SlopDeskWorkspaceModel` and both lookups
descend as the pill's did. Not done here — `DropZoneInk` has an `init(ffiCode:)`, so the move carries an
FFI decode across a target boundary, and that is a design change with its own gate.

**Un-landable if:** nothing. This stage is bookkeeping, and it is a stage rather than a footnote
because `docs/61` §1 row 12 records the rule: *"removing a name is the last step of finishing the port,
never a step of its own."*

## 7. What moves to Rust instead of to UIKit

The port's real prize, and the honest headline is that it is **small** — because `docs/56` increments
15–87 already took it. `rust/slopdesk-workspace` (34,079 lines), `-terminal` (9,135), `-devicepanel`
(7,874), `-codepanel` (1,340) and `-fuzzy` (633) already own the decisions these views render. Nine
things remain, each named with its crate and with what is left for the view.

> **CLOSED 2026-08-30.** All nine landed, and two did not land as this section wrote them. Item 4 is
> a FLOOR, not a port — `docs/67`'s seven-reason booking is the later and better ruling, and the
> content agrees: two one-line comparisons have no decision in them to cross. Item 7's premise was
> wrong — the two delays are two MEASUREMENTS, not one duplication, and both already crossed on
> their own; what was actually duplicated was the WAIT, in three spellings, now `DeviceVeilWait`.
> Item 2's stack rules crossed as written. Per-item status is inline below.

1. ✅ **LANDED — `Overlays/OverlayKeyRepeat.swift` (49) → `rust/slopdesk-workspace::key_repeat`.** It is a
   whitelist of which keys may auto-repeat, typed on `KeyEquivalent` and `KeyPress.Phases` — and UIKit
   has neither. So it is not ported; it **merges** into the crate that already owns the phone's
   hardware repeat latch and its 350/50 ms cadence. The overlays become a second consumer of
   `KeyRepeater` rather than a parallel policy with the same name and a different concern. *Left for
   the view:* calling `keyDown`/`keyUp` from `pressesBegan`/`pressesEnded`.

2. ✅ **LANDED 2026-08-30 — `SlopDeskClientCore/Overlays/OverlayCoordinator.swift` (771) — the toast queue → `rust/slopdesk-workspace::toast`.**
   `toast.rs`'s own header scopes this out deliberately: *"the card's lifecycle — the push, the de-dupe
   by id, the dwell timer and its epoch — stays with the coordinator that owns the clock."* That was
   right while the clock was `.task(id:)`. Under UIKit the clock becomes an explicit `Task`, which is
   the moment to split it: the **rules** (de-dupe by id, cap and trim, order, dwell duration, epoch
   assignment) are pure and cross; the **clock** stays Swift because a timer is an actuator.
   *Left for the view:* one stored `Task` per card and a `dismiss` call.

   **LANDED 2026-08-30 as `toast::push`, and it answers POSITIONS rather than cards.** The stack is
   four entries, so the ids cross as one NUL-separated run and what comes back is one byte per
   survivor — nothing is copied. The pushed card is deliberately absent from the answer: it is
   always last, so returning it would be asking Rust to hand back the argument. `CAP` is the
   crate's now, for the reason `veil_delay` is: two shells that trim to different depths disagree
   about which pane spoke last. The near side keeps the epoch stamp and the array the view reads.

3. ✅ **LANDED — the palette selection machine, same file → `rust/slopdesk-workspace::palette_rows`.**
   `rankedResults` `:423`, `moveSelection` `:521`, `moveSelectionToFirst` `:528`, `moveSelectionToLast`
   `:534`. `list_nav.rs` already vends `clamped_selection`, `quick_pick` and `wrapped_index`; what is
   Swift is the composition of those with the ranked rows, which is a fold. *Left for the view:*
   scrolling to the selected index path.

4. 🚫 **SUPERSEDED — `SlopDeskClientCore/Overlays/HoverSelectionGate.swift` (56) → `rust/slopdesk-workspace`.**
   `admitHover(at:)`, `noteHoverDrivenSelection()`, `shouldAutoScrollOnSelectionChange()` — pointer-vs-
   keyboard arbitration, pure and already testable. It gains urgency in UIKit because the auto-scroll
   it gates becomes `scrollToItem(at:at:animated:)`, which is a real actuator with a real cost.
   *Left for the view:* the hover recognizer and the scroll call.

   **NOT PORTED, and this item is superseded.** `docs/67` books it `ShellDeDuplication` — a
   decision `AppKit` and `UIKit` would each otherwise write, hoisted so the two cannot disagree —
   and that booking is both later and right. Read the file: it is `location != lastPointerLocation`
   and `!selectionIsHoverDriven`, two comparisons over two stored bits. There is no decision in it
   to move; crossing it would buy a C ABI call and a handle for a pointer-equality test. The
   urgency this item claimed — that the scroll became a real actuator — argues for the gate
   EXISTING, which it does, not for which language it is written in.

5. ✅ **LANDED — `ViModeOverlay.swift:232-308` `ViKeyHintReflow` → `rust/slopdesk-workspace::vi_hints`.** A SwiftUI
   `Layout` conformance doing width accumulation and manual x/y placement, which **cannot port** — the
   protocol does not exist in UIKit. Half of it is already
   `ViKeyHintPresentation.layout(forWidth:gap:columnWidth:)`; the accumulate-and-place loop is a flow
   solver and belongs beside `split_layout`. Note the two defects the survey found while it is being
   moved: `slots(for:cache:)` is resolved **twice per layout pass** (`:254,265`) and `updateCache`
   re-measures all three columns on any subview invalidation. *Left for the view:* measuring each
   label (only the platform can) and setting the frames the solver returns.

6. ✅ **LANDED — `SimulatorBezelView.swift:42-113` → `rust/slopdesk-devicepanel::geometry`.** Bleed, viewport and
   scale arithmetic — ~50% of the file, under a `GeometryReader`, with a load-bearing z-order. The
   crate already holds `geometry.rs` and `sim_place.rs`. *Left for the view:* the artwork and the
   press latch.

7. 🔁 **RE-SCOPED — `Panel/DevicePanelChrome.swift:96-101` `loadingVeilState` → `rust/slopdesk-devicepanel`.** An
   asymmetric delay policy (immediate down, delayed up, nil on cancellation) that exists **twice** with
   different numbers — 400 ms here for Android, 600 ms in `SimulatorPresentation.loadingVeil` for the
   simulator. Two spellings of one idea, which is the shape `docs/56` spent forty increments removing.
   *Left for the view:* the `Task.sleep`.

   **RE-SCOPED 2026-08-30: the premise was wrong, and the real duplication was elsewhere.** The two
   numbers are not two spellings of one idea — 400 ms was measured against the simulator server's
   0.09 s first keyframe and 600 ms against the Android bridge's 0.83 s, and both already cross on
   their own doors (`slopdesk_simulator_veil_delay_ms`, `slopdesk_android_veil_delay_ms`). Merging
   them would throw away both measurements. What WAS duplicated is the wait itself — `guard
   isAwaiting`, sleep, cancellation check — which existed in three spellings: the simulator's, the
   phone's Android helper, and the Mac Android stage inlining it. That is now `DeviceVeilWait`, one
   helper in `SlopDeskDevicePanels/Shared` that all three call with their own delay. It stays Swift:
   a sleep and a cancellation check is structured concurrency, which is `docs/67`'s `SwiftRuntime`
   floor and the one shape a door cannot carry.

8. ✅ **LANDED — `GuiLeafView.swift`'s control-bar gates → `rust/slopdesk-ffi::gui_readout`.** `showsControlBar`
   `:332`, `showsModeToggles` `:561-570`, `hasLatchedMode` `:338`, `activationKey` `:323`,
   `isDesktopUploadTarget` `:315`. `RemoteGUIDisplay.resolve` already crosses at `:110-117`, and these
   are the same kind of question about the same model. The Mac's `MacGuiLeafView` answers them too, so
   they are already two spellings.

9. ✅ **LANDED — `SlopDeskClientCore/Overlays/OpenQuicklySources.swift` → `rust/slopdesk-workspace::open_quickly`.**
   The section assembler — `sections(store:folders:agents:current:filter:query:)` — is the one piece of
   the Open Quickly path that never crossed, and the survey confirms it holds no FFI call. Every one of
   its inputs is already a Rust-derived reading.

**And one that stays Swift, deliberately.** `PhonePanelSheet.swift:207-213`'s `labelCost` measures a
string with `UIFont.systemFont` and hands the width to `PanelTabs.labelling(...)`. The measurement
cannot cross — only the platform can measure its own text — and the fold already has. That is the
correct shape and it is worth naming, because it is the shape items 5 and 6 land in too: **the
platform measures, Rust decides, the view places.**

## 8. What this does NOT do

- ~~**`SlopDeskMacUI` is not in scope, and is not touched.**~~ **THIS ONE DID NOT SURVIVE THE
  CAMPAIGN, and the reason it did not is the campaign's central finding.** It was written on the
  premise that the phone gets what the Mac has, so only the phone half moves. What stage I actually
  found is that a great many Mac bodies had character-identical phone twins whose justification —
  "these are two frameworks" — was factually false: Auto Layout, Core Graphics, QuartzCore,
  `NSAttributedString` and Foundation are ONE API under one set of names on both platforms, and the
  only genuinely two-typed things are the view, the colour and the font. Deleting a twin means
  deleting BOTH copies into a shared floor, which is `CLAUDE.md`'s "one implementation, never two"
  taken literally. So `SlopDeskMacUI` is edited throughout stage I — `MacGuiLeafView`,
  `MacHintModeOverlay`, `MacToastStack`, `MacConnectSheet`, `MacGlobalSearch`, `MacGuiPaneOverlays`
  and more. ⚠️ What still holds, and is the claim that mattered, is that **no Mac BEHAVIOUR changes
  and no Mac surface is redesigned**: every edit replaces a body with a call to the same body on the
  floor. `ui_split.rs`'s two "neither half imports the other" claims are untouched and still green —
  the shared code went DOWN into `SlopDeskClientCore` and `SlopDeskSlate`, never sideways.

- **`SlopDeskSlate` declares zero view types, and ends the campaign with zero SwiftUI.** ⚠️ THE
  MEASUREMENT THIS BULLET WAS WRITTEN ON IS SPENT: it said "imports SwiftUI in five files", and the
  count is now **0** — the `Color` spelling and the `Text.nerdAware` splice lost their last consumers
  and went. What replaced them is not nothing: **6 files import AppKit or UIKit** behind `#if`
  (`SlateNativeText`, `SlateVectorDraw`, `SlatePlate` and the three around them), because a floor that
  vends `NSColor`/`UIColor` and splices an `NSAttributedString` must name the framework that declares
  them. So "framework-free" was never the invariant and should not be restated as one. The invariant
  that IS load-bearing is narrower and unchanged: **zero `View` types, and no drawing** —
  `slopdesk-invariants` fails the build if a `some View` lands here, and
  `panel_shells::one_design_floor_two_renderers` keeps the floor to values. A `CGContext` ladder like
  `SlateVectorDraw` is admitted because Core Graphics is one API and the ladder is a VALUE-to-path
  decision; a view type is not, which is why `SlateHostView` lives in `SlopDeskClientCore` instead. The port consumes the same tokens the SwiftUI does and **never forks
  them** — the phone's adapters live in `Sources/SlopDeskPhoneUI/DesignSystem/`, where they already do
  (`slateGlyphAck`, `SlatePlateStyle`, `slateShadow`, `slatePaperCard` are all in `DesignSystem/`, not
  in `Slate`). What changes at stage I is a *removal*: the `Color` spelling and the SwiftUI splice lose
  their last consumer and go, leaving `NSColor`/`UIColor` and the two native halves.

- **`SlopDeskWorkspaceCore` does not become UIKit. `SlopDeskClientCore` PARTLY DID, deliberately, and
  the old wording did not survive either.** It said both "import no view framework today
  (`docs/56:3893`) and must not start", with `PaneFocusCoordinator` and `PhoneKey` naming `UIKit`
  behind `#if os(iOS)` for a *type* as the two exceptions. `SlopDeskWorkspaceCore` is still exactly
  that. `SlopDeskClientCore` is not: **23 of its files now import AppKit or UIKit**, all behind `#if`,
  and that is the shape stage I's dedup arrives in rather than a leak. The reason is the same one
  everywhere in this section — a body that PLACES views (`GuiLeafChromeLayout`, `OverlayCardLayout`,
  `ViewEdges`, the `Decoration*` family) needs `NSLayoutConstraint` and a host type, and Auto Layout
  is one API, so the body is one body. ⚠️ The line that actually holds, and the one to defend, is
  **placement and values, never drawing and never a view SUBCLASS**: nothing in `SlopDeskClientCore`
  declares an `NSView`/`UIView` subclass or overrides `draw(_:)`. `SlateHostView` is a typealias, not
  a class. When that line moves, this bullet is wrong again — so check it against the tree rather
  than quoting it.

- **`ThirdParty/ghostty` is vendored and is not rewritten.**
  `GhosttyTerminalView.swift:2953`'s `UIViewRepresentable` stays in the file. What changes is the seam
  it satisfies: `TerminalRendererFactory` gains a `UIView` shape, the app target's
  `GhosttyRendererSeam.install()` (`AppMain.swift:72-74`) registers that instead, and the
  representable becomes unreachable dead code inside a vendored tree — which is where dead vendored
  code belongs. Deleting it is a fork of the vendor and is not this campaign's business. (`docs/56`'s
  own memory records the trap: the embedder Swift lives in `ThirdParty/`, not `Sources/`, so a
  `Sources/` grep calls a live cluster dead.)

- **No feature is dropped for being hard in UIKit.** `docs/56` §3: *"Layout diverges; capability does
  not."* Every surface listed in §2 has a UIKit form in §3, including the ones that look like SwiftUI
  specialities — `ViewThatFits` (stage H), the `Layout` conformance (§7 item 5), `.searchable`,
  `.swipeActions`, `.fileImporter`, `TimelineView`.

- **No wire change, no golden regeneration, no host change.** This campaign does not touch
  `golden/golden_vectors.json`, `docs/20`, or anything under `Sources/SlopDeskHost` /
  `rust/slopdesk-host*`. If a stage finds itself editing the wire, the stage is wrong.

- **It is not a Rust rewrite of the view layer, and §7 is bounded on purpose.** `CLAUDE.md`'s "Rust is
  the default" governs *decisions*; a `UIView` is not one. §7 names nine files because nine is what the
  survey found, and the temptation to grow that list mid-campaign is the temptation `docs/56` increment
  54 warns about from the opposite direction — the ledger's unit is the declaration, not the file.

- **It does not fix `just check`'s blindness to iOS, and that is the biggest open risk — at two
  layers, not one.** *Above:* `check-ios-tests` stays out of `check` for the reason `justfile:421-431`
  gives — it boots a simulator — and `test-touched`'s pathspec (`touched.rs:67-74`) does not include
  `Apps/`, so the tree's default loop type-checks the phone and asserts nothing about it. *Below:* the
  ratchets that would have caught the drift go **quietly vacuous** when the SwiftUI spellings they ban
  disappear (§4.8) — `design-token-leaks`, `overlay-host-ambient-layer`, `one-clear-key` and every
  representable ban stay green over a tree they can no longer see into. So the campaign can regress the
  design floor and the overlay host without a single red anywhere. Making `check-ios-tests` a default
  gate is a decision about the inner loop's cost and not this document's to take. What this document
  does instead is the only thing available: name the simulator run as every stage's exit condition,
  require each re-aimed rule to be **break-tested in its UIKit spelling before the stage lands**, and
  put the automated proof where it can exist — eleven test files, the two rigs that rasterise on every
  run, and ten new `phoneui_memos.rs` rules.

- **Three surveyed things that look in-scope and are not.** `Sources/SlopDeskDevicePanels` (9,662) is
  the panels' *domain* and stays — only its `SimulatorScreenSurface` (370) is a `UIView`, and it is
  already one. `Sources/SlopDeskVideoClient` (the platform-free engine, including `FramePacer` and
  `VideoWindowPipeline`) is not a UI target and stays; only `SlopDeskVideoClientPhone`'s 129-line
  wrapper goes. And `Apps/ClientApp-iOS/project-video.yml` — the renderer-disabled variant — is not a
  port target, but it is a constraint: `AppMain.swift` must keep compiling with both `CGhostty` and
  `SlopDeskVideoClientPhone` absent, at every stage.
