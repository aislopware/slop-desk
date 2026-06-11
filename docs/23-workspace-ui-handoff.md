# 23 — Workspace UI Handoff (honest end-of-WF-build status)

> **STATUS: CURRENT.** This is the truthful wake-up picture after the WORKSPACE UI build
> (WF2 pure domain → WF3 multi-session store → WF4 SwiftUI shell → WF5 pane content → WF6
> keyboard/palette/compact/iOS-focus → WF7 adversarial review fixes). It states what is
> COMPLETE + proven HEADLESSLY (build / iOS typecheck / unit tests) vs. what is only
> COMPILED + REVIEWED and still needs a real GUI / device runtime pass, the exact
> build/run commands, the required hardware verification checklist, the deferred
> followups, and the honest caveats.
>
> Architecture authority for this layer is [`22-workspace-architecture.md`](22-workspace-architecture.md).
> The proven byte-pipeline / transport / video / inspector cores below this layer are
> documented in [`21-HANDOFF.md`](21-HANDOFF.md) and are **out of scope** here — they are
> proven and were not touched by this build.

## Headline

- **595 XCTest tests pass, 0 failures**, on Swift 6 strict concurrency / Swift tools 6.0 /
  Xcode 26.5 / arm64 / macOS 26.5 (~23s full suite). `swift build` is **warning- and
  error-clean**. `scripts/check-ios.sh` (the iOS-triple typecheck of the `#if os(iOS)`
  sources) reports **`** BUILD SUCCEEDED **` / `iOS typecheck OK`**.
- The full WORKSPACE UI layer (the multiplexer) is **built and committed** on branch
  `feat/workspace-ui`: a vertical tab sidebar, recursive tmux-style split panes, three pane
  content kinds, a responsive desktop↔mobile compact carousel, a keyboard command model +
  command palette, an iOS focus-generation guard, and debounced persistence — all sitting on
  top of the proven per-`PaneID` session registry that preserves the four byte-pipeline
  invariants by construction.
- **What is PROVEN headlessly is the DOMAIN + STORE + the pure responsive/focus/command
  logic** (the unit-tested layers below). **What is only COMPILED + REVIEWED is the SwiftUI
  view layer and every live pipeline it drives** — the rendered terminal surface, the live
  PATH-2 video decode, the iOS first-responder / key-repeat / IME interaction, and the live
  inspector second channel. SwiftUI views are not unit-tested here (deliberately — no
  HostServer-backed tests, pool-deadlock rule), so none of the view-level behaviour is
  claimed to "work" until the hardware/GUI checklist below is run.
- **The honest count discrepancy:** the build brief quoted "597 tests". The actual headless
  total is **595 XCTest** (0 failures) — see the count note below. There is also a
  swift-testing runner present that executes **0 tests** (no swift-testing suites in this
  package). All workspace suites are green.

## What shipped (the feature list)

The WORKSPACE UI is the application-layer multiplexer described in docs/22. Everything below
is built and committed on `feat/workspace-ui`:

- **Vertical tab sidebar** — `NavigationSplitView` with a `TabSidebarView` of workspace tabs
  (kind glyph + title + close), select / reorder (drag) / rename / close, active-tab
  reselection by identity. Decorative kind glyphs are `.accessibilityHidden(true)`.
- **Recursive tmux-style split panes** — a `PaneNode` binary split tree (h/v) rendered by
  `PaneTreeView` → `SplitContainer` with draggable dividers, per-pane chrome
  (`PaneChromeView`: split-h / split-v / close / zoom), focus affordance, and **zoom**
  (one leaf full-bleed). Geometry is solved by the pure `LayoutSolver`; focus by the pure
  `FocusResolver`. Every leaf carries `.id(PaneID)` so a tree reshape / tab switch / zoom
  **never tears down the live model session**.
- **Three pane content kinds** (the proven seams, re-parented from the retired single-session
  `ClientRootView` to one-per-`PaneID`):
  - `.terminal` → `TerminalScreenView` (renderer factory seam) + a per-pane `InputBarView`
    bound to that pane's own connection client. Fresh user panes show a `ConnectionView`
    (host/port + Connect) until dialed in; configured/restored panes auto-connect on appear.
  - `.claudeCode` → the same terminal composite PLUS a toggleable read-only `InspectorPanel`
    over that pane's inspector second channel (macOS side-by-side, iOS bottom sheet).
  - `.remoteGUI` → a live `RemoteWindowPanel` (PATH-2 video), with the pane chrome owning
    close. Video activation is **routed through the cap-enforcing store** (see WF7 fix #1).
- **Responsive desktop ↔ mobile compact** — one pure switch (`WorkspaceLayout.isCompact`):
  regular renders the full split tree (`PaneTreeView`); compact renders a one-leaf-at-a-time
  `PaneCarouselView` (TabView paging, swipe + ⌘]/⌘[, header tab/add/prev/next). iOS uses the
  `horizontalSizeClass` as the primary signal; macOS falls back to a 460pt detail-width gate
  so the minimum macOS window resolves **regular** (WF7 fix #10). `CompactLayoutResolver`
  flattens the tree to an ordered leaf list.
- **Keyboard command model + command palette** — a pure `CommandInterpreter` (KeyChord →
  WorkspaceCommand default-bindings table), a SwiftUI `WorkspaceCommands` menu surface
  (Cmd/Opt-only shortcuts so plain keys + Ctrl-letters flow to the focused terminal), and a
  `CommandPaletteView` that reads the same `defaultBindings` for its shortcut hints.
- **iOS focus-generation guard + single-focus coordinator** — `FocusGenerationGuard`
  (monotonic generation to drop stale focus claims) + `PaneFocusCoordinator` (the
  iPad-regular multi-visible single-first-responder arbiter), threaded into `TerminalInputHost`
  / `InputBarView` so each visible terminal host registers under its `PaneID`.
- **Persistence** — `WorkspacePersistence` (Codable v1, schemaVersion-gated load) + a
  debounced `scheduleSave` (generation-guarded, WF7 fix #8) driven by the store. The
  automation/bootstrap path is **non-persisting** under `hasAutomationEnvironment()` so a
  check-script run never overwrites the developer's `workspace.json` (WF7 fix #16).

## Per-layer status

### COMPLETE + PROVEN HEADLESSLY (unit / integration — `swift test`, 595 / 0)

| Layer | Source | What the tests prove |
|-------|--------|----------------------|
| **Pure domain** — pane tree, geometry, focus, compact flatten, command table, Codable | `Workspace/Domain/*` (`PaneNode`, `PaneSpec`, `Tab`, `Workspace`, `LayoutSolver`, `FocusResolver`, `CompactLayoutResolver`) | tree split/close/normalize (epsilon kernel one source of truth, WF7 #22), solved geometry, focus succession, compact leaf-ordering, Codable round-trip, conflict-rule binding table |
| **Responsive switch** | `Store/WorkspaceLayout.swift` | `isCompact` — size-class primary + 460pt detail-width fallback; width 500 + regular → regular, width 500 + compact → compact (WF7 #10 regression assertions) |
| **Multi-session store + registry** | `Store/*` (`WorkspaceStore`, `LivePaneSession`, `PaneSessionHandle`, `CommandInterpreter`, `WorkspacePersistence`) | reconcile invariant `Set(registry.keys) == Set(allLeafIDs)`; one `LivePaneSession` ⇒ one `ConnectionViewModel` per `PaneID`; awaited pause/resume fan-out; lazy connect; `liveVideoCap` policy via the `FakePaneSession` seam; id-keyed self-pruning teardown tasks (WF7 #2); inspector resume→teardown race (WF7 #6 regression test, loopback seam); video pause/resume self-suspend (WF7 #15) |
| **iOS focus logic** | `iOS/FocusGenerationGuard.swift`, `iOS/PaneFocusCoordinator.swift` | generation-guard drops stale claims; coordinator single-first-responder arbitration (pure, macOS-unit-tested) |
| **Persistence policy** | `Store/WorkspacePersistence.swift` | schemaVersion `==` gate (WF7 #19); decode-or-default; automation no-persist (WF7 #16) |

Workspace suites green: `WorkspaceTests`, `WorkspaceStoreReconcileTests`, `WorkspacePersistenceTests`,
`ScenePhaseFanOutTests`, `LiveVideoCapTests`, `InspectorGlueTests`, `CommandInterpreterTests`,
`CommandRoutingTests`, `CompactLayoutResolverTests`, `FocusResolverTests`, `FocusGenerationGuardTests`,
`InspectorPanelTests`, `InspectorTransportTests`.

> **Count note (honest).** The headless suite is **595 XCTest tests, 0 failures**
> (re-verified, ~23s). The "597" in the build brief does not match the artifact in the
> repo at this SHA; the delta is most likely two WF7 test-file edits (e.g. the
> `CompactLayoutResolver.focus(after:swipe:)` 5 swipe-only tests deleted in WF7 #20, plus
> regression tests added in #6/#10/#15). The number to trust is the one `swift test`
> emits: **595 / 0**.

### COMPILED + REVIEWED but NOT RUN (needs a real GUI / device runtime pass)

These build cleanly (`swift build` + `scripts/check-ios.sh`) and were adversarially reviewed,
but are **never executed in a test** — SwiftUI views, the live render/decode pipelines, and
iOS `UIResponder` glue need a window-server / device. **None of this is claimed to "work".**

| Layer | Source | Why not run / what is unverified |
|-------|--------|----------------------------------|
| **SwiftUI shell + views** | `Workspace/Views/*` (`WorkspaceRootView`, `TabSidebarView`, `PaneTreeView`, `SplitContainer`, `PaneChromeView`, `PaneLeafView`, `PaneCarouselView`, `WorkspaceCommands`, `FocusedValues+Workspace`, `CommandPaletteView`) | Views only lay out; not unit-tested (no HostServer-backed tests — pool-deadlock rule). Divider drag, zoom, focus affordance, sidebar reorder, carousel paging, palette presentation are **visually unverified**. |
| **Rendered terminal surface across reshape** | `PaneLeafView` terminal composite + the `TerminalRendererFactory` seam (renderer is the gated libghostty `GhosttyTerminalView`, out-of-scope here) | The MODEL session survives tab switch / compact flip (registry-owned, `.id(PaneID)`). The **rendered `GhosttySurface` is currently rebuilt** on a branch-type flip / tab switch until surface ownership moves out of the transient view — see deferred followup #1/#3 below. Needs `scripts/check-macos.sh` to confirm prior output survives a tab A→B→A round trip. |
| **Live PATH-2 video decode** | `PaneLeafView.RemoteGUIPaneView` → `RemoteWindowPanel` (the proven `AislopdeskVideoClient` core) | Activation is routed through `store.activateVideo(live.id)` (cap-enforcing) and renders a gated "Video paused — too many live windows" placeholder over `liveVideoCap` (default 2). The **store policy is unit-tested via the FakePaneSession seam (`LiveVideoCapTests`)**, but the live decode (UDP / VTDecompression / Metal / CADisplayLink) is **only startable from a real unlocked GUI session with a capturing host** — see `scripts/check-video.sh` + the CGS_REQUIRE_INIT constraint below. |
| **iOS first-responder / key-repeat / IME / floating-cursor** | `iOS/TerminalInputHost.swift`, `InputBarView.swift` (WF6 edits), `iOS/KeyRepeater`, `iOS/IMEProxyTextView`, `iOS/FloatingCursorController`, `iOS/KeyboardAccessoryBar` | Compiles for iOS (`scripts/check-ios.sh`); the underlying cadence/mapping logic is pure + macOS-unit-tested. On-device key-repeat under real presses, IME multi-stage composition, floating-cursor gesture, and the iPad-regular multi-pane first-responder hand-off (`PaneFocusCoordinator`) are **unverified** — needs a real device. |
| **Live inspector second channel** | `PaneLeafView.ClaudeCodePaneView` → `InspectorPanel`; `LivePaneSession.subscribeInspector` | The subscribe/fold/resume-race LOGIC is unit-tested (loopback seam). But there is **no host-side inspector serving yet** — the live `NWConnection #2` JSONL stream from a real Claude-Code host is unverified end-to-end. |
| **App shell + scenePhase** | `AislopdeskClientApp.swift` (serialized scenePhase chain, WF7 #5), `Video/RemoteWindowPanel.swift` (showCloseButton) | The serialized iOS background→foreground pause/resume chain is iOS-isolated glue verified only via `check-ios.sh` compile + the store-level `ScenePhaseFanOutTests`; the actual app lifecycle transition on a device is unverified. |

## Build & verify (exact commands)

```sh
# 1. Headless build — all SwiftPM targets, warning + error clean
swift build --package-path /Volumes/Lacie/Workspace/oss/aislopdesk

# 2. iOS-triple typecheck of the #if os(iOS) sources — must end "** BUILD SUCCEEDED **"
cd /Volumes/Lacie/Workspace/oss/aislopdesk && bash scripts/check-ios.sh

# 3. Full test suite — 595 XCTest, 0 failures (~23s)
swift test --package-path /Volumes/Lacie/Workspace/oss/aislopdesk
```

The workspace UI views compile via `swift build` but the rendered terminal/video pipelines
only come alive in the app targets (with the gated libghostty renderer wired — see
`docs/21-HANDOFF.md` "Activating the libghostty renderer"). The headless `swift build` /
`swift test` never see the app target, the xcframework, or `CGhostty`.

## REQUIRED hardware / GUI runtime verification checklist

None of these can run from a sandboxed bash agent. They are the gap between "compiled +
reviewed" and "proven".

1. **macOS GUI smoke — `scripts/check-macos.sh`.** Build the macOS `.app`, open it, drive
   it, `screencapture` a PNG, read the pixels. Verify: the sidebar renders tabs; a split
   produces two visible panes with a draggable divider; zoom full-bleeds one leaf; the
   command palette opens. Run the terminal round trip with `--connect` + `AISLOPDESK_AUTOTYPE`
   (type → host exec → render, asserted by a host-side marker with a COMPUTED value, not just
   a live socket).
2. **Terminal surface liveness across tab switch (the load-bearing check).** Type into tab
   A's terminal, switch to tab B and back, **assert tab A's prior output is still on screen.**
   The model session survives (registry-owned); the *rendered surface* may currently be
   rebuilt — this check is what catches the view-lifecycle teardown that model-only tests
   cannot. (See deferred followup #1/#3.)
3. **PATH-2 live video — `scripts/check-video.sh`.** MUST be run **from a REAL unlocked GUI
   session** (a logged-in, unlocked desktop). A bash-agent context hits
   **`CGS_REQUIRE_INIT`** (no window-server connection) and `SCStream`/`VTCompressionSession`
   HANG without a window-server + Screen-Recording TCC session. Grant TCC (Screen Recording
   on the host; Accessibility + Post Event for input injection), run capture/encode →
   decode/render for one GUI window, then verify the `liveVideoCap` gate: open more
   `.remoteGUI` panes than the cap (default 2) and confirm the over-cap panes show the
   "Video paused" placeholder and open **no** decode stack.
4. **iPad-regular multi-pane first-responder pass (real device).** On an iPad in regular
   width with 2+ visible terminal panes, tap each pane and confirm the keyboard routes to the
   tapped pane only (the `PaneFocusCoordinator` single-first-responder arbitration), and that
   the `FocusGenerationGuard` drops stale claims during rapid switches. Also exercise
   key-repeat cadence, IME multi-stage composition, and the floating-cursor gesture in
   `TerminalInputHost`.
5. **iOS compact carousel pass (real device / simulator).** Confirm swipe + ⌘]/⌘[ page
   between leaves, the header add/prev/next work, and a regular↔compact rotation flip does
   **not** tear down the live model session (`.id(PaneID)` survival).
6. **Live inspector end-to-end.** There is **no host-side inspector serving yet** — once a
   real Claude-Code host serves the `NWConnection #2` JSONL stream, verify a `.claudeCode`
   pane's `InspectorPanel` populates (full replay → live) and survives pause/resume.

## Deferred followups (documented, NOT implemented this phase)

From the WF7 review (the confirmed findings deferred as larger/riskier), plus the structural
items the fixes themselves flagged:

1. **[high] Terminal-surface liveness across tab switch / compact flip — the root cause.**
   The MODEL session survives a tab switch, but the rendered `GhosttySurface` is rebuilt on a
   branch-type flip / tab switch because surface ownership lives in the transient layer view.
   The reviewer's preferred "keep all tabs mounted in a ZStack" approach is **wrong** — it
   would fire `onAppear` video activation for every `.remoteGUI` pane in every tab on launch
   and blow past `liveVideoCap`. The correct minimal direction is **(C)** a bounded
   scrollback/replay byte ring in `TerminalViewModel` replayed into `surface` on re-attach,
   **or (A/B)** moving `GhosttySurface` ownership into the registry-resident `LivePaneSession`
   / a single persistently-mounted pane-host that re-parents the same `.id(PaneID)` hosts per
   mode. All touch the proven renderer / `TerminalViewModel` core (out of scope) and need
   their own pass to stay Swift-6-strict-concurrency clean. **Comment-honesty was done
   in-phase** (the over-broad "no session teardown" doc claims in `WorkspaceRootView` /
   `PaneCarouselView` were narrowed to "the MODEL/registry session survives"); the behavior
   fix is the followup. Verify with check #2 above.
2. **[medium] Reactive auto-promote of gated video panes.** When a `liveVideoCap` slot frees,
   a gated `.remoteGUI` pane currently only re-checks on the next `.onAppear` / identity
   refresh. A clean reactive version would have `deactivateVideo` nudge gated panes to
   re-attempt `activateVideo`. Ship the gate now (done); the reactive auto-promote is the
   followup.
3. **[medium] reconcile() AWAIT teardown before materialize.** Today orphan teardown is
   launched in a tracked (quiesce-awaitable) Task, NOT awaited before materialize, so a
   same-tick close+reopen of a video pane could transiently exceed the resource ceiling. The
   fix is to make `reconcile()` async and await teardown first — structural, ripples async
   through the whole synchronous mutation surface + init. Documented in the reconcile
   docstring.
4. **[medium] Collapse the keyboard-binding duplication.** `WorkspaceCommands`
   `.keyboardShortcut` declarations and `CommandInterpreter.defaultBindings` are two tables
   for the same chords. Derive the SwiftUI shortcuts from `defaultBindings` via a
   `KeyChord → (KeyEquivalent, EventModifiers)` adapter (one source of truth). Touches the
   load-bearing conflict-rule keyboard surface, so it needs full `check-ios.sh` + macOS build
   + WF6 keyboard tests re-run. (The unused `CommandInterpreter.clock` seam — the safe-now
   micro-slice — can be dropped independently.)
5. **[low] Per-device `liveVideoCap`.** The cap is a single `Int` (default 2). A real
   per-device ceiling (phone vs. iPad vs. Mac, by decode budget) is a followup once the live
   decode path is measured on each device class.
6. **[low] Outer-window geometry for the compact breakpoint.** The 460pt gate measures the
   detail area, not the outer window. Measuring outer-window geometry is a refinement once
   the responsive switch is exercised on real window resizes.
7. **[followup] Schema `migrate(from:to:)` seam.** The persistence load is a strict `==` v1
   gate; a real migration seam is only needed when v2 is introduced.

## Honest caveats

- **The view layer is COMPILED + REVIEWED, not run.** Everything proven here is the domain /
  store / pure-logic layers. The SwiftUI views, the rendered terminal surface, the live video
  decode, the iOS first-responder interaction, and the live inspector are **only as good as
  the hardware checklist that has not yet been run**. Do not report any view-level behaviour
  as "working" until checks 1–6 above pass.
- **`liveVideoCap` is enforced in PRODUCTION only via the view's `store.activateVideo` call.**
  `setVideoActive` remains on the `PaneSessionHandle` protocol (the store + pause/resume call
  it) so it could not be made non-public; the cap now holds because the view routes through
  `store.activateVideo`/`deactivateVideo` on every path (tree + carousel). The unit tests pin
  the **store policy** (FakePaneSession seam); the **view-routes-through-store** invariant is
  guarded by the single-site code structure, not a SwiftUI test — confirm it live in check #3.
- **No host-side inspector serving yet** — the `.claudeCode` inspector second channel is
  wired and its client logic is unit-tested, but there is no host emitting the live JSONL
  stream, so the end-to-end inspector is unverified (check #6).
- **595 ≠ 597.** Trust the `swift test` artifact (595 / 0), not the brief's number.
- **The proven cores below this layer were NOT touched** — byte pipeline, transport, video
  protocol/orchestration, inspector parse, libghostty binding. They remain as documented in
  `docs/21-HANDOFF.md`. The renderer/video factories stay as the `AppMain` seams.
- **No new HostServer-backed tests were added** (pool-deadlock rule); the inspector
  resume/teardown regression test uses a loopback seam, not HostServer.
