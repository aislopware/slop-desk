# 22 — Workspace UI Architecture (the Aislopdesk multiplexer)

Status: design, ready to implement.
Floor: macOS 26 / iOS 26, Swift tools 6.0, Swift 6 language mode (strict concurrency).
Scope: the APPLICATION layer only. The protocol / transport / terminal byte-pipeline / video
pipeline / inspector channel are PROVEN — this document wraps them, never reinvents them.

This is the synthesis of four rival designs and three judge verdicts. The base is
**domain-model-first** (tree-of-intent vs table-of-liveness, the only test story that survives the
concrete-actor reality). It is grafted with the native shell from **swiftui-native-first**, the pure
`LayoutSolver`/`FocusResolver` + virtual-clock `CommandInterpreter` from **tmux-power-user-first**, and
the single-switch responsive projection (`CompactLayoutResolver`) from **mobile-responsive-first**.

---

## 0. The non-negotiable resolution: the test seam (the universal blocker)

Every judge flagged the same LOAD-BEARING fact, verified against the code:

- `AislopdeskClient` is a concrete `public actor` (`Sources/AislopdeskClient/AislopdeskClient.swift:42`) with
  `init(ackInterval:)`. There is **no protocol seam**.
- `ConnectionViewModel.makeClient` is `@Sendable () -> AislopdeskClient` — returns the *concrete* type
  (`Sources/AislopdeskClientUI/Connection/ConnectionViewModel.swift:54,82`).
- `InputBarModel.submit/sendRaw/sendText` also take the concrete `AislopdeskClient`.
- The only existing `ConnectionViewModel` test stands up a **real `HostServer`** — forbidden for new
  tests (project memory: pool deadlock).
- The only genuine in-process no-network seam that exists today is
  `LoopbackByteChannel.pair()` for the Inspector (`Sources/AislopdeskInspector/InspectorChannel.swift:145`).

So the "inject a `FakeAislopdeskClient` via `makeClient`" strategy that designs 2/3/4 assumed is **NOT
constructible**. We do NOT introduce a protocol over `AislopdeskClient` (that perturbs the proven core and
buys nothing the architecture needs). Instead we resolve it structurally — three layered facts make
the whole new surface testable with zero `HostServer`:

1. **Pure domain (the bulk, ~85% of new logic) has no client at all.** The pane tree, the layout
   solver, the focus resolver, the compact projection, the command interpreter, and the persistence
   codec are pure value types and free functions. Plain synchronous `XCTest`, no async, no network,
   no stub.

2. **The store's session lifecycle is tested via a `makeSession` factory seam — NOT `makeClient`.**
   The injectable unit is the whole `PaneSession`, not the client inside it. `WorkspaceStore` is
   constructed with `makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle`. Tests inject a
   `FakePaneSession` that records `pause/resume/teardown` and never builds a real `AislopdeskClient`. This
   lets us assert reconcile correctness (`registry.keys == leafIDs`), teardown ordering, and
   scenePhase fan-out **without a single socket**. Production injects `LivePaneSession.make`, which
   builds the real `ConnectionViewModel` exactly as today.

3. **`AislopdeskClient()` is socket-free at construction.** `connect()` builds the transport lazily
   (`AislopdeskClient.swift:153`). So the few tests that want a *real un-connected* `LivePaneSession` can
   build one (no `HostServer`, no socket) and assert structural wiring — but the default and primary
   path is the `FakePaneSession`.

`PaneSessionHandle` is a tiny protocol the **store** depends on (so it can be faked); it is NOT a
protocol over `AislopdeskClient` and does not touch the proven core. `LivePaneSession` conforms to it and
owns the real `ConnectionViewModel` verbatim.

```swift
@MainActor public protocol PaneSessionHandle: AnyObject, Identifiable {
    var id: PaneID { get }
    var kind: PaneKind { get }
    func pause() async      // fans to connection AND inspector channel (single fan-out point)
    func resume() async
    func teardown() async   // delegates to ConnectionViewModel teardown order, closes inspector
}
```

This is the spine of the entire test strategy and is honored everywhere below.

---

## 1. Chosen architecture + rationale

### 1.1 The cut: tree of intent vs table of liveness

The workspace is two cleanly separated things:

- **The tree of intent** — a pure, value-typed, `Codable` `Workspace { tabs: [Tab] }`, where each
  `Tab` owns a recursive `PaneNode` tree whose leaves carry a `PaneID` + a value-typed `PaneSpec`
  (kind + endpoint, NEVER a live object). Every layout mutation (split, close, resize, zoom, focus,
  reorder, rename, add/close tab) is a PURE function returning a new tree. This is the
  serialization format and ~85% of the test surface.

- **The table of liveness** — a `[PaneID: any PaneSessionHandle]` registry inside the one
  `@MainActor @Observable WorkspaceStore`. Each handle is 1:1 with a `PaneID` and wraps the PROVEN
  per-session objects (one `ConnectionViewModel` + its `TerminalViewModel` + `InputBarModel`, plus
  optional `InspectorViewModel/Client` for claudeCode, or a `RemoteWindowModel` for remoteGUI).

The store **reconciles** the two: after every tree mutation, `reconcile()` diffs
`tree.allLeafIDs()` against `registry.keys`, materializes missing leaves (via `makeSession`) and
tears down orphaned ones (via the proven teardown order). The tree never holds a session; the
registry never holds layout.

### 1.2 Why this is the best base

- The hardest correctness surface (recursive split/close/zoom arithmetic, geometric focus,
  persistence round-trip, compact flattening) is 100% pure — deterministic `XCTest`, no client.
- The four byte-pipeline invariants are satisfied **by construction**: keying the registry by
  identity guarantees one `ConnectionViewModel` (hence one ordered-OUT stream, one events consumer,
  one `ReconnectManager`) per pane, never shared.
- Persistence falls out for free — the tree is already `Codable`.
- Responsive is a pure VIEW-time projection of the SAME tree: compact = render only the focused
  leaf (an always-on zoom). One model, two renderings — never two models.
- It survives the concrete-actor reality: the testable layers don't depend on a fakeable client at
  all; the one layer that touches the client is faked at the `PaneSession` boundary.

### 1.3 Grafts that make it the best a top team could ship

- **Native shell (from swiftui-native-first):** `NavigationSplitView` is the responsive spine —
  free sidebar+detail, native macOS source-list, and the compact collapse-to-stack. The ONLY
  size-class branch in the app is in `WorkspaceRootView.detail`. `.draggable`/`.dropDestination` for
  tab reorder. `.geometryGroup()` + a resize-forwarding throttle to protect the proven
  `sendResize` path.
- **One geometry source of truth (from tmux-power-user-first):** a pure `LayoutSolver` produces a
  single `[PaneID: CGRect]` map consumed by BOTH the rendered layout AND `FocusResolver.neighbor`,
  so "move focus left" can never disagree with what the user sees. Plus a pure `CommandInterpreter`
  driven by a virtual clock (reusing the `ManualRepeatScheduler` pattern) so keyboard intent
  mapping is unit-tested.
- **One responsive switch + pure projection (from mobile-responsive-first):** the compact layout is
  the pure `CompactLayoutResolver` (tree + focus + swipe -> next focus / page index), unit-tested on
  macOS with zero UIKit. Compact = exactly one mounted `TerminalInputHost`, which structurally
  sidesteps the iOS two-first-responder race on phone.
- **One fan-out site:** `pause/resume` route through `PaneSessionHandle.pause()/resume()` (which
  internally covers connection + inspector channel), iterated in a `TaskGroup` that is AWAITED
  before suspend.
- **Video resource ceiling:** `.onAppear/.onDisappear` activate-gating + a store-level cap on
  concurrent live video panes.

---

## 2. Data model (full Swift sketches)

All pure-domain types are `Sendable + Codable + Equatable`, no `import SwiftUI`, no `import
AislopdeskClient`. They live under `Sources/AislopdeskClientUI/Workspace/Domain/`.

```swift
// ---- Identity ----
public struct PaneID: Hashable, Codable, Sendable { public let raw: UUID; public init() { raw = UUID() } }
public struct TabID:  Hashable, Codable, Sendable { public let raw: UUID; public init() { raw = UUID() } }

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical } // h = side-by-side, v = stacked

// ---- Leaf intent (what a pane IS and where it points — never a live object) ----
public enum PaneKind: String, Codable, Sendable, Equatable { case terminal, claudeCode, remoteGUI }

public struct Endpoint: Codable, Sendable, Equatable { public var host: String; public var port: UInt16 }
public struct VideoEndpoint: Codable, Sendable, Equatable {
    public var host: String; public var mediaPort: UInt16; public var cursorPort: UInt16
    public var windowID: UInt32; public var title: String
}

public struct PaneSpec: Codable, Sendable, Equatable {
    public var kind: PaneKind
    public var title: String
    public var endpoint: Endpoint?       // terminal / claudeCode
    public var video: VideoEndpoint?     // remoteGUI
}

// ---- THE TREE (recursive value type). N-ary split: parallel children + fractions. ----
// Invariant: fractions.count == children.count; sum(fractions) ≈ 1.0 (epsilon).
public indirect enum PaneNode: Codable, Sendable, Equatable {
    case leaf(PaneID, PaneSpec)
    case split(SplitAxis, children: [PaneNode], fractions: [Double])
}

public enum FocusDirection: Sendable { case left, right, up, down, next, previous }

// ---- PURE OPS (all return a NEW node; all unit-tested with no client) ----
public extension PaneNode {
    func allLeafIDs() -> [PaneID]                            // pre-order; drives compact pages
    func spec(for id: PaneID) -> PaneSpec?
    func contains(_ id: PaneID) -> Bool
    func splitting(_ target: PaneID, axis: SplitAxis, newLeaf: (PaneID, PaneSpec)) -> PaneNode
    func closing(_ target: PaneID) -> PaneNode?             // nil if tree empties; collapses singletons; renormalizes
    func updatingSpec(_ id: PaneID, _ transform: (inout PaneSpec) -> Void) -> PaneNode
    func settingFractions(at path: [Int], to fractions: [Double]) -> PaneNode   // clamped upstream
}

public struct Tab: Codable, Sendable, Equatable, Identifiable {
    public let id: TabID
    public var name: String
    public var root: PaneNode
    public var focusedPane: PaneID
    public var zoomedPane: PaneID?     // nil = normal; non-nil = that leaf maximized (presentation flag)
}

public struct Workspace: Codable, Sendable, Equatable {
    public var schemaVersion: Int      // forward migration
    public var tabs: [Tab]
    public var activeTabID: TabID?
    // PURE: addTab / closeTab / moveTab(from:to:) / renameTab + delegations into the active tab's root.
}
```

### 2.1 Geometry (pure, the focus/divider source of truth)

```swift
public struct DividerHandle: Sendable, Equatable {            // one per gap between siblings
    public let path: [Int]; public let index: Int            // addresses split node + which divider
    public let axis: SplitAxis; public let rect: CGRect
}
public struct SolvedLayout: Sendable, Equatable {
    public let frames: [PaneID: CGRect]
    public let dividers: [DividerHandle]
}

public enum LayoutSolver {
    // Pure: resolve fractions × size into exact rects + divider rects, clamped to minLeaf.
    public static func solve(_ root: PaneNode, in size: CGSize, minLeaf: CGSize) -> SolvedLayout
}

public enum FocusResolver {
    // Geometric neighbor against the SAME rects the user sees (never tree-position heuristics).
    public static func neighbor(of pane: PaneID, _ dir: FocusDirection, in solved: SolvedLayout) -> PaneID?
    public static func cycle(_ leaves: [PaneID], from: PaneID, forward: Bool) -> PaneID  // .next/.previous wrap
}
```

### 2.2 Compact projection (pure, the phone layout)

```swift
public struct CompactPage: Sendable, Equatable { public let id: PaneID; public let kind: PaneKind; public let title: String }
public enum CompactLayoutResolver {
    public static func pages(for tab: Tab) -> [CompactPage]                 // = root.allLeafIDs() projected
    public static func selectedIndex(for tab: Tab) -> Int                   // index of focusedPane
    // swipe → next focus is owned by the carousel's TabView selection binding + store.move (no
    // parallel resolver seam).
}
```

### 2.3 The live layer (NOT Codable; @MainActor; wraps the proven objects)

```swift
@MainActor public protocol PaneSessionHandle: AnyObject, Identifiable {
    var id: PaneID { get }
    var kind: PaneKind { get }
    func pause() async
    func resume() async
    func teardown() async
}

// Production handle. Owns the proven per-session objects verbatim.
@MainActor @Observable public final class LivePaneSession: PaneSessionHandle {
    public let id: PaneID
    public let kind: PaneKind
    public let connection: ConnectionViewModel                       // owns ordered-OUT drain + single events loop + ReconnectManager
    public let inputBar: InputBarModel                               // per-pane B1 dedup ring
    public let inspector: (model: InspectorViewModel, client: InspectorClient?)?  // claudeCode only
    public let remoteWindow: RemoteWindowModel?                      // remoteGUI only
    public var terminalModel: TerminalViewModel { connection.terminalModel }

    public static func make(_ spec: PaneSpec,
                            makeClient: @escaping @Sendable () -> AislopdeskClient,
                            makeInspector: @MainActor (Endpoint) -> InspectorClient?) -> LivePaneSession

    public func pause() async  { await connection.pause();  await inspector?.client?.pause()  } // (close+resub for inspector)
    public func resume() async { await connection.resume(); /* re-subscribe inspector from lastSeq */ }
    public func teardown() async { await connection.disconnect(); inspector?.client.flatMap { _ = $0 }; remoteWindow?.close() }
}

@MainActor @Observable public final class WorkspaceStore {
    public private(set) var workspace: Workspace                     // pure tree (single source of truth)
    private var registry: [PaneID: any PaneSessionHandle] = [:]      // liveness side-table

    // INJECTION SEAM (the test seam — NOT makeClient). Production passes LivePaneSession.make(...).
    private let makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle
    public let liveVideoCap: Int                                     // resource ceiling for remoteGUI

    public init(restoring: Workspace? = nil,
                makeSession: @escaping @MainActor (PaneSpec) -> any PaneSessionHandle,
                liveVideoCap: Int = 2)

    // Intent → pure tree mutation → reconcile registry.
    public func addTab(kind: PaneKind)
    public func closeTab(_ id: TabID)
    public func selectTab(_ id: TabID)
    public func moveTab(from: IndexSet, to: Int)
    public func renameTab(_ id: TabID, _ name: String)

    public func split(_ id: PaneID, axis: SplitAxis, kind: PaneKind)
    public func closePane(_ id: PaneID)
    public func focus(_ id: PaneID)
    public func move(_ dir: FocusDirection)         // FocusResolver against last SolvedLayout
    public func toggleZoom()
    public func setFractions(tab: TabID, path: [Int], to: [Double])

    public func handle(for id: PaneID) -> (any PaneSessionHandle)?
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    public func pauseAll() async                    // TaskGroup over allSessions, AWAITED
    public func resumeAll() async

    private func reconcile()                         // diff allLeafIDs() vs registry.keys
}
```

`reconcile()` is the single audited seam. Its contract (tested): after any op,
`Set(registry.keys) == Set(workspace.tabs.flatMap { $0.root.allLeafIDs() })`, it is idempotent, and a
compact↔regular projection flip does NOT call it (projection is view-only; the tree is unchanged).

---

## 3. Split-pane render + resize

There is no native cross-platform N-way resizable splitter (`NSSplitView`/`HSplitView` is AppKit-only
and explicitly forbidden), so this is the ONE hand-rolled view — minimal, with all math pushed into
the pure `LayoutSolver`/`PaneNode.settingFractions`.

```swift
struct PaneTreeView: View {
    let node: PaneNode
    let path: [Int]
    let store: WorkspaceStore
    let tab: TabID

    var body: some View {
        switch node {
        case let .leaf(id, spec):
            PaneLeafView(handle: store.handle(for: id), spec: spec, isFocused: store.isFocused(id))
                .id(id)                                   // STABLE identity → never reuse a surface/Coordinator across panes
                .onTapGesture { store.focus(id) }
        case let .split(axis, children, fractions):
            SplitContainer(axis: axis, fractions: fractions,
                           onResize: { newFractions in store.setFractions(tab: tab, path: path, to: newFractions) }) { i in
                PaneTreeView(node: children[i], path: path + [i], store: store, tab: tab)
            }
            .geometryGroup()                              // stop child re-layout mid-drag
        }
    }
}
```

- **Render:** `SplitContainer` is a single `GeometryReader`; children are laid out along `axis` with
  `.frame(width/height: fraction × total)`, native `Divider()` between each pair, overlaid with an
  8pt `DividerHandle` (`.onHover { NSCursor.resizeLeftRight }` on macOS; a wider `contentShape` hit
  area on iOS-regular touch).
- **Resize:** the handle's `DragGesture` converts translation to a fraction delta and calls the pure
  `PaneNode.settingFractions` via the store, clamped to `minFraction = 160pt / total`. Ratios live in
  the model (resolution-independent, persists, round-trips). The OUT path is protected: resize
  forwarding to the host is **throttled** (write the model live for layout, but forward
  `sendResize` only on drag-ended + a low-rate sample) so a continuous drag does not flood
  `TIOCSWINSZ`; the proven `lastSentSize` coalescing absorbs duplicates. `reset()` is NEVER called on
  a transient hide/zoom.
- **Zoom/maximize:** `Tab.zoomedPane` is a presentation flag. `PaneTreeView` checks it at the top and
  renders only that leaf full-bleed; the tree and the registry are untouched (no materialize/teardown
  on zoom). This is the cleanest possible — zoom is presentation, not tree surgery.
- **Min sizes:** enforced at the model boundary (clamp) AND in `.frame(minWidth/minHeight:)`. Below
  the floor the responsive layer collapses to compact rather than crushing panes.

---

## 4. Responsive desktop ↔ mobile

The breakpoint is `@Environment(\.horizontalSizeClass)` as the PRIMARY signal, with a width fallback
for macOS (no size class): `isCompact = (hSizeClass == .compact) || (width < compactWidthThreshold)`,
where `compactWidthThreshold == 460` is a DETAIL-area width (so the macOS minimum window's ~500pt
detail resolves regular). Computed once in `WorkspaceRootView`; it is the ONLY adaptation switch in
the app.

```swift
struct WorkspaceRootView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var body: some View {
        NavigationSplitView {
            TabSidebarView(store: store)                  // native source-list rail
        } detail: {
            GeometryReader { geo in
                let compact = (hSizeClass == .compact) || (geo.size.width < WorkspaceLayout.compactWidthThreshold)
                if compact { PaneCarouselView(store: store) }   // single mounted leaf, pure projection
                else       { PaneTreeView(node: activeRoot, path: [], store: store, tab: activeTabID) }
            }
        }
        .frame(minWidth: 720, minHeight: 480)            // min size on the SHELL, not pane views
    }
}
```

- **Regular (macOS, iPad full-screen, iPad regular split):** `NavigationSplitView` sidebar (tab rail)
  + full recursive `PaneTreeView` with draggable dividers, zoom, multi-pane visible. The
  `minWidth: 720` lives on the shell.
- **Compact (iPhone, iPad slide-over):** the SAME tree is flattened by `CompactLayoutResolver.pages`
  into an ordered list and shown in a `TabView(.page)` carousel — exactly ONE leaf visible at a time
  (the focused one, an always-on zoom). Page selection is BOUND to `tab.focusedPane`, and
  first-responder is driven EXPLICITLY on focus change (not on `.onAppear`) via the
  `PaneFocusCoordinator`. The sidebar collapses into the `NavigationSplitView` stack
  (toolbar/back-swipe). No visible dividers; `split` still mutates the tree (so it round-trips to
  desktop) but compact just gains a swipe page.
- **Key property:** the tree is IDENTICAL in both modes. A 3-pane Mac split opens on iPhone as 3
  swipeable pages — lossless. A size-class flip (iPad multitasking) must NOT call `reconcile()`, drop
  focus, or tear down sessions — the projection swap is view-only and idempotent.
- **Structural win:** compact = one mounted `TerminalInputHost`, so the iOS two-first-responder race
  is sidestepped on phone entirely. The regular-iPad path is the only place that needs the focus
  coordinator (below).

---

## 5. Keyboard / command model

A pure command-intent layer drives both platforms; SwiftUI `Commands` (macOS menu bar + iPad
hardware-keyboard `UIKeyCommand`) and `.keyboardShortcut` are thin adapters over a tested core.

```swift
public enum WorkspaceCommand: Sendable, Equatable {
    case splitHorizontal, splitVertical          // ⌘D / ⇧⌘D
    case closePane, closeTab                      // ⌘W / ⇧⌘W
    case newTab, nextTab, prevTab                 // ⌘T / ⌃⇥ / ⌃⇧⇥
    case selectTab(Int)                           // ⌘1…⌘9
    case focus(FocusDirection)                    // ⌥⌘←/→/↑/↓
    case cycleFocus(forward: Bool)                // ⌘] / ⌘[
    case toggleZoom                               // ⇧⌘↩
    case renameTab                                // ⌘R
}

@MainActor public final class CommandInterpreter {           // pure logic, virtual-clock testable
    public init(clock: any RepeatSchedulerClock = .continuous)   // reuse ManualRepeatScheduler pattern
    public var bindings: [KeyChord: WorkspaceCommand]
    public func feed(_ chord: KeyChord) -> WorkspaceCommand?     // nil = consumed / no match
}

public func apply(_ c: WorkspaceCommand, to store: WorkspaceStore)
```

- **macOS:** `WorkspaceCommands: Commands` adds "Pane" + "Tab" menus with the shortcuts above —
  native menu-bar discoverability. Each item calls `apply(_:to:)`.
- **iPad hardware keyboard:** the same SwiftUI `Commands` surface as `UIKeyCommand` in the ⌘-hold
  HUD; focus is published via `FocusState<PaneID?>` + `.focusedSceneValue` so commands act on the
  focused pane.
- **Compact iPhone (no hardware keyboard):** on-screen affordances — `.contextMenu` on the pane
  header (split/close/zoom), swipe between leaves, tab drawer. The command model degrades
  gracefully.
- **CONFLICT RULE (load-bearing):** the terminal must keep receiving raw bytes. All workspace
  shortcuts are ⌘/⌥-prefixed — combos `TerminalInputHost.encode` returns `nil` for, so plain keys and
  Ctrl-letters flow to the focused terminal untouched. Focus-move uses ⌥⌘+arrows specifically
  because plain arrows belong to the shell. No bare-key binding ever.

---

## 6. Persistence / restore

The pure `Workspace` value type IS the format — already `Codable`. `WorkspaceStore` persists it
(debounced on mutation + on `scenePhase == .background`) to
`Application Support/Aislopdesk/workspace.json` (app container on iOS); `SceneStorage("selectedTab")` holds
only the active `TabID` for fast scene restoration.

- **Codable shape:** `Workspace { schemaVersion, tabs, activeTabID }`,
  `Tab { id, name, root, focusedPane, zoomedPane }`, `PaneNode = .leaf(PaneID, PaneSpec) |
  .split(axis, children, fractions)`, `PaneSpec { kind, title, endpoint?, video? }`. The `indirect
  enum` Codable conformance is **hand-written** with an explicit `type` discriminator key
  (`PaneNode+Codable.swift`) so the JSON is stable, reviewable, and versionable — NOT synthesized.
- **Versioning + safety:** top-level `schemaVersion: Int`; decode failure falls back to a single
  default terminal tab rather than crashing. Byte-stable round-trip tests guard the hand-rolled
  Codable (silent-corruption surface).
- **RESTORED vs RECONNECTED (the discipline):** persistence restores SHAPE and INTENT, never live
  connections. On launch `WorkspaceStore(restoring:)` decodes the tree; the registry starts empty;
  `reconcile()` materializes an *idle* `LivePaneSession` per leaf but does NOT auto-connect. Each leaf
  view's `.task` triggers `connect()` lazily only when first projected (desktop: visible panes;
  compact: the focused page) — restoring a 12-pane workspace does not slam 12 sockets at launch.
  Video panes restore with the endpoint pre-filled in the form but NOT auto-opened (UDP is
  user-initiated). Stable `PaneID`/`TabID` survive the round-trip so focus/zoom references stay
  valid. Deliberately NOT persisted: live objects, byte buffers, sessionIDs (a relaunch is a fresh
  session — the host's tail-retention is for live pause/resume, not cold restart).

---

## 7. Seam integration plan

Every proven seam is CALLED, never reopened — re-parented from "one global" to "one per PaneID".

- **TerminalRendererFactory** (`Terminal/TerminalRenderingView.swift:76`, registered once in
  `AppMain.swift`): `PaneLeafView` for `.terminal`/`.claudeCode` renders
  `TerminalScreenView(model: handle.terminalModel)`, which calls `TerminalRendererFactory.make`. The
  factory is stateless; N leaves = N `make` calls, each with its own `TerminalViewModel`. `.id(PaneID)`
  on the leaf forces SwiftUI to give each its own `GhosttySurface` and never reuse one across panes
  (the `TerminalScreenView` `@State` capture hazard). **PaneID is stable for the session's lifetime —
  only a true session swap changes it; resize/focus/zoom re-renders never do.**
- **VideoWindowFactory** (`Video/VideoWindowSeam.swift:69`, registered once in `AppMain.swift`):
  `.remoteGUI` leaves render `RemoteWindowPanel(model: handle.remoteWindow!, showCloseButton: false)`
  (the one genuine edit — add `showCloseButton: Bool = false` so pane chrome owns close; current
  init is `(model:)` only at `RemoteWindowPanel.swift:85`, Close hardcoded at line 99). The panel
  calls `VideoWindowFactory.make`. Each leaf's `MetalLayerBackedView` owns its own
  `VideoWindowPipeline`; SwiftUI `dismantle` fires `deactivate()` on removal (backstop preserved).
  `activate`/`deactivate` is gated on `.onAppear/.onDisappear` (decode only on-screen/focused panes),
  and the store enforces `liveVideoCap` to bound the 2N-UDP-sockets / N-VTDecompression /
  N-CVDisplayLink ceiling.
- **Inspector** (`Inspector/InspectorPanel.swift`, `InspectorChannel.swift`): a `.claudeCode` leaf is
  a per-pane composite — `TerminalScreenView` + `InspectorPanel(model: handle.inspector.model,
  client: handle.inspector.client)`, ratio held in the pane's own state. The store opens
  NWConnection #2 per claudeCode pane via `makeInspector` (the genuinely missing app-glue, wired
  here). Single-consumer rule holds: the panel's own `.task` is the sole `events()` drain;
  read-only — no path back to the OUT stream.
- **Input host** (`iOS/TerminalInputHost.swift`): per-leaf `InputBarView(model: handle.inputBar,
  client: handle.connection.activeClient)`. On iOS each focused leaf gets its own `TerminalInputHost`
  (own `Coordinator`, own serial drain). `.id(PaneID)` so SwiftUI never reuses a Coordinator across
  pane connections.
- **Connection model** (`Connection/ConnectionViewModel.swift`): used verbatim, one per
  `LivePaneSession`, constructed with the threaded `makeClient`. The store never reaches into the OUT
  stream or events loop; it only calls public `connect/disconnect/pause/resume`.
- **App shell:** `Apps/Shared/AppMain.swift` is UNCHANGED — factory registration stays the single
  launch-time site; it remains the ONLY importer of `CGhostty`/`AislopdeskVideoClient`.
  `AislopdeskClientApp.swift` swaps its two `@State` vars for one `@State private var store:
  WorkspaceStore`, renders `WorkspaceRootView(store:)`, fans `handleScenePhase` over
  `store.allSessions` in an AWAITED `TaskGroup`, and migrates the automation seams (below).
- **Automation seams (env var names unchanged so `check-macos.sh`/`check-video.sh` keep working):**
  `AISLOPDESK_AUTOCONNECT_HOST/PORT/AISLOPDESK_AUTOTYPE` move into `WorkspaceStore.bootstrapFromEnvironment()`
  targeting `tabs[0]`'s first leaf; `AISLOPDESK_VIDEO_AUTOCONNECT_*` migrate out of the retired
  `ClientRootView` into the same bootstrap. Re-run both runtime scripts from a real unlocked GUI
  session after migration — they are the only runtime proof.

### iOS first-responder coordination (built net-new — does NOT exist today)

`TerminalInputHost.swift:52` does a bare `DispatchQueue.main.async { becomeFirstResponder() }` with
NO generation counter and NO resign-before-become. For the regular-iPad multi-visible-pane path we add:

```swift
public struct FocusGenerationGuard: Sendable {           // pure, macOS-testable (like FloatingCursorMapping)
    public mutating func begin() -> Int                  // bump + return current generation
    public func isCurrent(_ gen: Int) -> Bool            // drop stale async callbacks
}
@MainActor public final class PaneFocusCoordinator {     // single-focus owner
    public func focus(_ id: PaneID)                      // resign outgoing IMEProxyTextView BEFORE incoming becomes FR
}
```

The async `becomeFirstResponder` captures the generation at dispatch and no-ops if stale. Compact
mode (one mounted host) needs none of this. This surface is only typecheck-covered by
`check-ios.sh` — **a real-device pass on iPad-regular is required** and is NOT assumed free.

---

## 8. Test strategy (NO HostServer)

Honors the load-bearing constraint: ~85% of new logic is pure (no client), and the session layer is
faked at the `PaneSessionHandle` boundary — never via a fake `AislopdeskClient` (which is impossible) and
never via a real `HostServer` (forbidden).

### Pure unit (plain XCTest, synchronous, no client, no async) — the bulk
- `PaneNodeTests`: split (each axis, root/nested/deep), close (collapse singleton, empty→nil,
  refocus neighbor, renormalize fractions), `allLeafIDs` ordering, `updatingSpec`.
- `LayoutSolverTests`: exact rects for known trees/sizes; minLeaf clamping; 3-deep nesting; divider
  rects.
- `FocusResolverTests`: directional neighbor against solved rects (left/right/up/down, ties, edges);
  cycle wrap. tmux-nav fidelity pinned here.
- `CompactLayoutResolverTests`: pages order = pre-order leaves; selectedIndex; swipe→next focus. This
  IS the phone layout — tested on macOS with zero UIKit.
- `FractionTests`: setFractions clamp + redistribute; sum ≈ 1; idempotent no-op.
- `WorkspaceTests`: addTab/closeTab/moveTab/selectTab/rename; close active tab reselects neighbor.
- `WorkspacePersistenceTests`: byte-stable JSON round-trip; hand-written `PaneNode` Codable preserves
  deep nesting + fractions; schemaVersion mismatch fallback.
- `CommandInterpreterTests`: chord→command mapping; virtual-clock timeout; rebinding; unknown chord
  consumed. Reuses the `ManualRepeatScheduler` pattern.
- `FocusGenerationGuardTests`: generation bump + stale-callback rejection (pure).

### Store / session (FakePaneSession via the makeSession seam — NO HostServer, NO real client)
- `WorkspaceStoreReconcileTests`: inject `makeSession: { spec in FakePaneSession(spec) }`. Assert
  after split the registry gains exactly one handle for the new PaneID; after closePane the handle is
  torn down (FakePaneSession records `teardown()`); `Set(registry.keys) ==
  Set(allLeafIDs)` after every op; reconcile idempotent; a compact↔regular flag flip does NOT mutate
  the registry.
- `ScenePhaseFanOutTests`: N FakePaneSessions; `pauseAll()`/`resumeAll()` calls `pause()`/`resume()`
  on EVERY handle, AWAITED (TaskGroup), including the inspector-bearing ones.
- `LiveVideoCapTests`: opening more than `liveVideoCap` remoteGUI panes is gated (FakePaneSession
  flags activation).

### Inspector glue (the ONE real in-process seam that exists)
- Reuse `LoopbackByteChannel.pair()` (as in `InspectorPanelTests`) to drive a claudeCode handle's
  `InspectorViewModel` and assert it folds without touching the terminal stream.

### View glue (typecheck + out-of-band, NOT unit-tested)
- `PaneTreeView`/`SplitContainer`/`WorkspaceRootView`/`PaneCarouselView` bodies are thin (all math in
  the pure ops). Covered by `swift build` (headless) + `scripts/check-ios.sh` (iOS triple typecheck)
  + the runtime `scripts/check-macos.sh`/`scripts/check-video.sh` (env vars preserved; must run from
  a real unlocked GUI session).

Net: `swift build` + `swift test` (425 existing + new pure/fake tests) + `check-ios.sh` stay green.
No new `HostServer` instance is created.

---

## 9. File-by-file map

### Create — pure domain (`Sources/AislopdeskClientUI/Workspace/Domain/`)
- `PaneNode.swift` — recursive enum + pure ops.
- `PaneSpec.swift` — `PaneKind`, `Endpoint`, `VideoEndpoint`, `PaneSpec`.
- `Tab.swift` — `Tab`, `TabID`, `PaneID`, `SplitAxis`, `FocusDirection`.
- `Workspace.swift` — `Workspace` + tab-level pure ops.
- `PaneNode+Codable.swift` — hand-written discriminated Codable + schemaVersion.
- `LayoutSolver.swift` — `SolvedLayout`, `DividerHandle`, `LayoutSolver.solve`.
- `FocusResolver.swift` — geometric neighbor + cycle.
- `CompactLayoutResolver.swift` — pages / selectedIndex / swipe focus.

### Create — store + commands (`Sources/AislopdeskClientUI/Workspace/Store/`)
- `WorkspaceStore.swift` — store + registry + reconcile + bootstrapFromEnvironment.
- `PaneSessionHandle.swift` — protocol + `LivePaneSession`.
- `WorkspaceLayout.swift` — pure isCompact decision (size-class/width).
- `WorkspacePersistence.swift` — debounced load/save.
- `CommandInterpreter.swift` — pure command state machine + `WorkspaceCommand` + `apply`.

### Create — views (`Sources/AislopdeskClientUI/Workspace/Views/`)
- `WorkspaceRootView.swift` — `NavigationSplitView` shell + the one responsive switch.
- `TabSidebarView.swift` — native source-list rail (add/close/reorder/rename/status/kind glyphs).
- `PaneTreeView.swift` — recursive walker.
- `SplitContainer.swift` — GeometryReader layout + draggable divider (+ `DividerHandle` view).
- `PaneCarouselView.swift` — compact `TabView(.page)` pager.
- `PaneLeafView.swift` — kind switch → existing TerminalScreenView / RemoteWindowPanel / claude composite.
- `PaneChromeView.swift` — focus ring, header, per-pane close/zoom.
- `WorkspaceCommands.swift` — macOS/iPad `Commands` + `.keyboardShortcut`.
- `FocusedValues+Workspace.swift` — `@FocusedValue` keys for store + focused pane.

### Create — iOS glue (`Sources/AislopdeskClientUI/iOS/`, `#if os(iOS)`)
- `FocusGenerationGuard.swift` — pure guard value type (macOS-testable).
- `PaneFocusCoordinator.swift` — single-focus owner (resign-before-become).

### Modify
- `Sources/AislopdeskClientUI/AislopdeskClientApp.swift` — one `@State store`; scenePhase fan-out (awaited
  TaskGroup over `allSessions`); migrate `AISLOPDESK_AUTOCONNECT_*`/`AISLOPDESK_AUTOTYPE` to store pane-0.
- `Sources/AislopdeskClientUI/Video/RemoteWindowPanel.swift` — add `showCloseButton: Bool = false` init
  param; gate the Close row on it.
- `Sources/AislopdeskClientUI/ClientRootView.swift` — retire: role split into `PaneLeafView` +
  `WorkspaceRootView`; migrate `AISLOPDESK_VIDEO_AUTOCONNECT_*` out. Keep as a thin shim or delete.

### Unchanged (asserted)
- `Apps/Shared/AppMain.swift` — factory registration stays the single launch-time site.

### Tests (`Tests/AislopdeskClientUITests/Workspace/`)
- `PaneNodeTests.swift`, `LayoutSolverTests.swift`, `FocusResolverTests.swift`,
  `CompactLayoutResolverTests.swift`, `FractionTests.swift`, `WorkspaceTests.swift`,
  `WorkspacePersistenceTests.swift`, `CommandInterpreterTests.swift`,
  `FocusGenerationGuardTests.swift`, `WorkspaceStoreReconcileTests.swift`,
  `ScenePhaseFanOutTests.swift`, `LiveVideoCapTests.swift`, `Support/FakePaneSession.swift`.

---

## 10. Ordered implementation plan

Each workstream is independently buildable + testable. Dependencies are explicit.

### WF2 — Pure domain model (no client, no SwiftUI)
Build the tree, ops, geometry, compact projection, command interpreter, persistence codec. 100%
pure-unit-tested. `swift build`/`swift test` green. No dependency on the live layer.
Depends on: nothing.

### WF3 — Multi-session store + registry
`PaneSessionHandle` protocol, `LivePaneSession` (wrapping the proven objects), `WorkspaceStore` +
`reconcile()` + fan-out + video cap. Tested with `FakePaneSession` via `makeSession`. NO HostServer.
Depends on: WF2.

### WF4 — UI shell: sidebar + splits (regular width)
`WorkspaceRootView` (`NavigationSplitView`), `TabSidebarView`, `PaneTreeView`, `SplitContainer`,
`PaneChromeView`. Renders the tree, draggable dividers (throttled resize), zoom. `AislopdeskClientApp`
swap to one `@State store`; scenePhase fan-out. Typecheck + headless build + `check-macos.sh`.
Depends on: WF3.

### WF5 — Pane content integration (the seams)
`PaneLeafView` kind switch wiring `TerminalScreenView` / `RemoteWindowPanel`(+`showCloseButton`) /
claude composite (`InspectorPanel` + NWConnection #2). Per-pane `InputBarView`/`TerminalInputHost`.
`.id(PaneID)` everywhere. Migrate automation seams; retire `ClientRootView`. Re-run
`check-macos.sh`/`check-video.sh` from a real GUI session.
Depends on: WF4.

### WF6 — Keyboard + responsive + polish
`WorkspaceCommands` + `.keyboardShortcut`; `CommandInterpreter` wiring; `PaneCarouselView` (compact)
bound to focus; `PaneFocusCoordinator` + `FocusGenerationGuard` for iPad-regular focus; tab
reorder (`.draggable`/`.dropDestination`); persistence debounce; `check-ios.sh` + real-device iPad
pass.
Depends on: WF5 (uses real content panes), WF2 (CommandInterpreter, CompactLayoutResolver).

---

## 11. Resolved concerns (every judge point)

1. **Concrete-actor / no fakeable client** → resolved by the `makeSession` factory seam +
   `PaneSessionHandle` (store-level protocol, not over `AislopdeskClient`) + socket-free `AislopdeskClient()`
   construction. No protocol over the proven core.
2. **`.id(PaneID)` identity hazard** → explicit `.id` on every leaf host (terminal, video, input);
   PaneID stable for a session's lifetime; runtime-identity assertion in reconcile tests.
3. **iOS first-responder race (built net-new, NOT reused)** → `FocusGenerationGuard` +
   `PaneFocusCoordinator` (resign-before-become); compact sidesteps it; required real-device pass.
4. **scenePhase fan-out** → one site, AWAITED `TaskGroup` over `PaneSessionHandle.pause()` covering
   connection + inspector channel.
5. **Resize storm** → throttle forwarding (drag-ended + low-rate sample) + `lastSentSize` coalescing
   + `.geometryGroup()`; never `reset()` on transient hide/zoom.
6. **Persistence corruption** → hand-written discriminated Codable + schemaVersion + byte-stable
   round-trip tests + decode-failure fallback; persist value tree + endpoints only; lazy
   connect-on-view.
7. **Video resource ceiling** → `liveVideoCap` + `.onAppear/.onDisappear` activate-gating.
8. **`RemoteWindowPanel` Close** → add `showCloseButton: Bool = false`; keep dismantle→`deactivate()`
   backstop; default preserves any remaining sheet callers until `ClientRootView` retirement audited.
9. **macOS has no size class** → width fallback in the one responsive switch; size-class flip must
   not call reconcile / drop focus / tear down sessions (idempotent projection).
10. **Automation-seam migration** → env var names unchanged; moved to store pane-0; re-run both
    runtime scripts from a real unlocked GUI session.
